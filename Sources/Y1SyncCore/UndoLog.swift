import Foundation

/// One reversible filesystem action.
public enum UndoEntry: Codable, Sendable, Equatable {
    /// A plain rename — reversed by moving `to` back to `from`.
    case moved(from: String, to: String)
    /// Something that would otherwise have been deleted, moved into
    /// quarantine instead — reversed by moving it back to `originalPath`.
    case quarantined(originalPath: String, quarantineName: String)
    /// An album tag rewritten in place — reversed by writing `album` back.
    case retagged(path: String, album: String)
    /// Tags rewritten in place — reversed by writing `old` back and removing `remove`.
    case retaggedFields(path: String, old: [String: String], remove: [String])
}

public struct UndoSession: Codable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    /// What produced this session, shown to the user — "tidy", "remove duplicates".
    public var label: String
    public var entries: [UndoEntry]
}

/// Records a reversible operation on a device as it happens.
///
/// Nothing this tool deletes is ever actually deleted here: a file that
/// would be removed is moved into a hidden quarantine folder on the device
/// instead (`.y1sync/trash/<session>`), and a plain rename is just logged as
/// a from/to pair. Call `finish` once the operation completes to persist it
/// as the device's one undoable session.
public final class UndoRecorder: @unchecked Sendable {
    private let deviceRoot: URL
    private let sessionID = UUID()
    private var entries: [UndoEntry] = []
    private let lock = NSLock()

    public init(deviceRoot: URL) {
        self.deviceRoot = deviceRoot
    }

    private var quarantineDir: URL {
        UndoLog.trashRoot(deviceRoot: deviceRoot).appendingPathComponent(sessionID.uuidString)
    }

    /// Move `url` into quarantine instead of deleting it. `path` is its
    /// device-relative location, used to restore it to the right place later.
    @discardableResult
    public func quarantine(_ url: URL, path: String) -> Bool {
        let name = UUID().uuidString
        let dest = quarantineDir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            return false
        }
        lock.lock()
        entries.append(.quarantined(originalPath: path, quarantineName: name))
        lock.unlock()
        return true
    }

    public func recordRetag(path: String, old: [String: String], remove: [String]) {
        lock.lock()
        entries.append(.retaggedFields(path: path, old: old, remove: remove))
        lock.unlock()
    }

    public func recordMove(from: String, to: String) {
        lock.lock()
        entries.append(.moved(from: from, to: to))
        lock.unlock()
    }

    /// Persist this as the device's one undoable session. Undo only ever
    /// covers the most recent operation, so whatever the previous session
    /// had quarantined is permanently discarded here — that is what actually
    /// frees the space a deletion promised, once you've moved on.
    public func finish(label: String) {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        UndoLog.replace(deviceRoot: deviceRoot,
                        with: UndoSession(id: sessionID, date: Date(), label: label, entries: snapshot))
    }
}

public enum UndoLog {
    static func logURL(deviceRoot: URL) -> URL {
        deviceRoot.appendingPathComponent(".y1sync/undo-log.json")
    }

    static func trashRoot(deviceRoot: URL) -> URL {
        deviceRoot.appendingPathComponent(".y1sync/trash")
    }

    static func replace(deviceRoot: URL, with session: UndoSession) {
        let fm = FileManager.default
        if let old = mostRecent(deviceRoot: deviceRoot) {
            try? fm.removeItem(at: trashRoot(deviceRoot: deviceRoot).appendingPathComponent(old.id.uuidString))
        }
        try? fm.createDirectory(at: logURL(deviceRoot: deviceRoot).deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: logURL(deviceRoot: deviceRoot))
        }
    }

    /// The device's one undoable session, if any.
    public static func mostRecent(deviceRoot: URL) -> UndoSession? {
        guard let data = try? Data(contentsOf: logURL(deviceRoot: deviceRoot)) else { return nil }
        return try? JSONDecoder().decode(UndoSession.self, from: data)
    }

    public struct UndoOutcome: Sendable {
        public var restored = 0
        public var failed: [String] = []

        public init(restored: Int = 0, failed: [String] = []) {
            self.restored = restored
            self.failed = failed
        }
    }

    /// Reverse the most recently recorded session and remove it from the
    /// log — this is single-level undo, so it cannot itself be undone.
    @discardableResult
    public static func undoMostRecent(deviceRoot: URL) -> UndoOutcome? {
        guard let session = mostRecent(deviceRoot: deviceRoot) else { return nil }
        var outcome = UndoOutcome()
        let fm = FileManager.default

        func full(_ relative: String) -> URL {
            deviceRoot.appendingPathComponent(relative.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }

        // Reverse in the opposite order actions were recorded, in case a
        // later action depended on an earlier one already having happened.
        for entry in session.entries.reversed() {
            switch entry {
            case .moved(let from, let to):
                let src = full(to), dst = full(from)
                guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else {
                    outcome.failed.append(from); continue
                }
                do {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: src, to: dst)
                    outcome.restored += 1
                } catch { outcome.failed.append(from) }

            case .retaggedFields(let path, let old, let remove):
                let file = full(path)
                var back: [String: String?] = old.mapValues { Optional($0) }
                for name in remove { back[name] = .some(nil) }
                if fm.fileExists(atPath: file.path), TagEditor.write(back, in: file) {
                    outcome.restored += 1
                } else { outcome.failed.append(path) }

            case .retagged(let path, let album):
                let file = full(path)
                if fm.fileExists(atPath: file.path), AlbumRetagger.setAlbum(album, in: file) {
                    outcome.restored += 1
                } else { outcome.failed.append(path) }

            case .quarantined(let originalPath, let quarantineName):
                let src = trashRoot(deviceRoot: deviceRoot)
                    .appendingPathComponent(session.id.uuidString).appendingPathComponent(quarantineName)
                let dst = full(originalPath)
                guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else {
                    outcome.failed.append(originalPath); continue
                }
                do {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: src, to: dst)
                    outcome.restored += 1
                } catch { outcome.failed.append(originalPath) }
            }
        }

        try? fm.removeItem(at: logURL(deviceRoot: deviceRoot))
        try? fm.removeItem(at: trashRoot(deviceRoot: deviceRoot).appendingPathComponent(session.id.uuidString))
        return outcome
    }

    /// Permanently discard the most recent session without restoring it —
    /// frees the space it was holding without waiting for the next
    /// destructive operation to do it implicitly.
    @discardableResult
    public static func forgetMostRecent(deviceRoot: URL) -> Bool {
        guard let session = mostRecent(deviceRoot: deviceRoot) else { return false }
        let fm = FileManager.default
        try? fm.removeItem(at: trashRoot(deviceRoot: deviceRoot).appendingPathComponent(session.id.uuidString))
        try? fm.removeItem(at: logURL(deviceRoot: deviceRoot))
        return true
    }
}
