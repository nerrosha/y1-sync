import Foundation

public struct SyncProgress: Sendable {
    public var completed: Int
    public var total: Int
    public var bytesCopied: Int64
    public var bytesTotal: Int64
    public var currentPath: String
}

public struct SyncResult: Sendable {
    public var copied: Int
    public var replaced: Int
    public var failed: [(path: String, error: String)]
    public var bytesCopied: Int64
    /// Files whose oversized embedded cover was shrunk on the way across.
    public var artworkShrunk: Int = 0
    /// Bytes saved by shrinking artwork.
    public var artworkBytesSaved: Int64 = 0
    /// Per-file record of what was done, for showing the user.
    public var changes: [FileChange] = []
    /// Stopped early by the user; what was already copied is complete.
    public var cancelled = false
    /// Files whose size and head/tail were read back from the player and matched.
    public var verified = 0
}

/// Reads what is already on the device and performs the copies.
public struct SyncEngine: Sendable {
    public var layout: DeviceLayout
    /// When set, oversized embedded cover art is shrunk during the copy.
    /// Stock Innioasis firmware reads art from the file's own tags and lags or
    /// misbehaves on large images, so this is on by default.
    public var artworkOptimizer: ArtworkOptimizer?

    public init(layout: DeviceLayout = DeviceLayout(),
                artworkOptimizer: ArtworkOptimizer? = ArtworkOptimizer()) {
        self.layout = layout
        self.artworkOptimizer = artworkOptimizer
    }

    /// Enumerate audio already on the player, as device-absolute paths.
    public func scanDevice(root: URL) -> [DeviceFile] {
        // Both sides must be canonical before any prefix comparison: the
        // directory enumerator hands back fully resolved paths, so an
        // unresolved root (e.g. /tmp, a symlink to /private/tmp) would fail to
        // match and make every file on the device look missing.
        let root = Self.canonical(root)
        let musicRoot = root.appendingPathComponent(
            layout.musicRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
        guard let e = FileManager.default.enumerator(
            at: musicRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [DeviceFile] = []
        for case let url as URL in e {
            guard SupportedFormat.isSupported(url.pathExtension) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let size = values?.fileSize.map(Int64.init) ?? 0
            out.append(DeviceFile(path: devicePath(of: url, root: root), size: size, url: url))
        }
        return out
    }

    /// Resolve symlinks and normalise, so two URLs naming the same file
    /// always produce the same string.
    static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// macOS aliases `/tmp`, `/var` and `/etc` to `/private/...`. Both spellings
    /// name the same file, but symlink resolution only rewrites paths that
    /// exist, so a root and a file can end up spelled differently.
    static func spellings(of path: String) -> [String] {
        if path.hasPrefix("/private/") {
            return [path, String(path.dropFirst("/private".count))]
        }
        for aliased in ["/tmp", "/var", "/etc"] where path == aliased || path.hasPrefix(aliased + "/") {
            return [path, "/private" + path]
        }
        return [path]
    }

    /// Convert a filesystem URL under the mount point into a device-absolute
    /// path (`/Music/...`), which is what playlists and the planner use.
    ///
    /// `resolvingSymlinksInPath()` only rewrites components that actually
    /// exist on disk, so a root and a file can disagree about whether they are
    /// spelled `/tmp/...` or `/private/tmp/...`. Both spellings of each are
    /// tried rather than assuming they normalise to the same form.
    public func devicePath(of url: URL, root: URL) -> String {
        let roots = Self.spellings(of: Self.canonical(root).path)
            + Self.spellings(of: root.standardizedFileURL.path)
        let paths = Self.spellings(of: Self.canonical(url).path)
            + Self.spellings(of: url.standardizedFileURL.path)

        for r in roots {
            let prefix = r.hasSuffix("/") ? String(r.dropLast()) : r
            guard !prefix.isEmpty else { continue }
            for p in paths where p.hasPrefix(prefix) {
                let rest = String(p.dropFirst(prefix.count))
                return rest.hasPrefix("/") ? rest : "/" + rest
            }
        }

        let p = Self.canonical(url).path
        return p.hasPrefix("/") ? p : "/" + p
    }

    /// Execute a plan. Each file is written to a temporary name, flushed to the
    /// card, read back (size, first and last 64 KB, bypassing the OS cache) and
    /// only then moved into place — so an interrupted, short or garbled copy can
    /// neither replace a good file nor look complete. `cancel` is polled between
    /// chunks; a stop leaves every finished file intact and removes the partial one.
    public func execute(
        plan: SyncPlan,
        deviceRoot: URL,
        progress: (@Sendable (SyncProgress) -> Void)? = nil,
        cancel: (@Sendable () -> Bool)? = nil
    ) throws -> SyncResult {
        let fm = FileManager.default

        let free = (try? deviceRoot.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init) ?? .max
        if plan.bytesToCopy > free {
            throw DeviceError.insufficientSpace(needed: plan.bytesToCopy, free: free)
        }

        var result = SyncResult(copied: 0, replaced: 0, failed: [], bytesCopied: 0)
        var bytes: Int64 = 0
        var lastReport = Date.distantPast

        // With an optimizer the cover/tag rewrite happens on the Mac, a couple
        // of files ahead of the one being written to the player.
        let preparer = artworkOptimizer.map { Preparer(actions: plan.actions, optimizer: $0) }
        defer { preparer?.stop() }

        for (index, action) in plan.actions.enumerated() {
            if cancel?() == true { result.cancelled = true; break }

            let dest = deviceRoot.appendingPathComponent(
                action.devicePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
            let tmp = dest.deletingLastPathComponent()
                .appendingPathComponent(".y1sync-\(UUID().uuidString).part")
            var prepared: Preparer.Item?
            let fileStart = bytes

            do {
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                var change = FileChange(devicePath: action.devicePath, track: action.track)
                change.wasReplaced = action.kind == .replace

                var source = action.track.sourceURL
                if let preparer {
                    let item = preparer.take(index)
                    prepared = item
                    if let error = item.error { throw error }
                    source = item.url
                    if let r = item.result, r.didRewrite, let was = r.originalArtBytes, let now = r.newArtBytes {
                        result.artworkShrunk += 1
                        result.artworkBytesSaved += Int64(was - now)
                        change.artFrom = r.fromPixels
                        change.artTo = r.toPixels
                        change.artBytesSaved = Int64(was - now)
                    }
                }

                try Self.copyVerified(from: source, to: tmp, cancel: cancel) { n in
                    bytes += Int64(n)
                    if Date().timeIntervalSince(lastReport) > 0.2 {
                        lastReport = Date()
                        progress?(SyncProgress(completed: index, total: plan.actions.count,
                                               bytesCopied: bytes, bytesTotal: plan.bytesToCopy,
                                               currentPath: action.devicePath))
                    }
                }

                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: tmp, to: dest)

                if action.kind == .replace { result.replaced += 1 } else { result.copied += 1 }
                result.verified += 1
                result.bytesCopied = bytes
                result.changes.append(change)
            } catch is CancelledError {
                bytes = fileStart
                try? fm.removeItem(at: tmp)
                if let prepared, prepared.isTemp { try? fm.removeItem(at: prepared.url) }
                result.cancelled = true
                break
            } catch {
                bytes = fileStart
                try? fm.removeItem(at: tmp)
                result.failed.append((action.devicePath, error.localizedDescription))
            }
            if let prepared, prepared.isTemp { try? fm.removeItem(at: prepared.url) }

            progress?(SyncProgress(
                completed: index + 1,
                total: plan.actions.count,
                bytesCopied: bytes,
                bytesTotal: plan.bytesToCopy,
                currentPath: action.devicePath
            ))
        }

        result.bytesCopied = bytes
        return result
    }

    struct CancelledError: Error {}
    struct VerifyError: Error, LocalizedError {
        var reason: String
        var errorDescription: String? { "the copy on the player did not match (\(reason))" }
    }

    /// Chunked copy with a flush and a read-back check. Throws before anything
    /// is moved into place if the card did not keep what was written.
    static func copyVerified(from source: URL, to tmp: URL, cancel: (@Sendable () -> Bool)?,
                             onBytes: (Int) -> Void) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let reader = try FileHandle(forReadingFrom: source)
        let writer = try FileHandle(forWritingTo: tmp)
        defer { try? reader.close(); try? writer.close() }

        var total: Int64 = 0
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            if cancel?() == true { throw CancelledError() }
            try writer.write(contentsOf: chunk)
            total += Int64(chunk.count)
            onBytes(chunk.count)
        }
        // Force the data out of the OS write cache onto the card.
        try writer.synchronize()
        try writer.close()

        // Read back, bypassing the cache so this really comes from the card.
        let size = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? -1
        guard size == total else { throw VerifyError(reason: "size \(size) instead of \(total)") }
        let check = try FileHandle(forReadingFrom: tmp)
        defer { try? check.close() }
        _ = fcntl(check.fileDescriptor, F_NOCACHE, 1)
        let src = try FileHandle(forReadingFrom: source)
        defer { try? src.close() }
        let window = 64 * 1024
        for offset in [0, max(0, Int(total) - window)] {
            try check.seek(toOffset: UInt64(offset)); try src.seek(toOffset: UInt64(offset))
            let a = try check.read(upToCount: window) ?? Data()
            let b = try src.read(upToCount: window) ?? Data()
            guard a == b else { throw VerifyError(reason: "contents differ at \(offset)") }
        }
    }
}

/// Prepares files (cover shrink, album-artist tag) on the Mac in a background
/// thread, a few files ahead of the one being written to the player.
final class Preparer: @unchecked Sendable {
    struct Item {
        var url: URL
        var isTemp: Bool
        var result: ArtworkOptimizer.Result?
        var error: Error?
    }

    private let cond = NSCondition()
    private var items: [Int: Item] = [:]
    private var consumed = 0
    private var stopped = false
    private let ahead = 2
    private let folder: URL

    init(actions: [SyncAction], optimizer: ArtworkOptimizer) {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("y1sync-prepare-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folder = self.folder
        Thread.detachNewThread { [self] in
            for (i, action) in actions.enumerated() {
                cond.lock()
                while i >= consumed + ahead && !stopped { cond.wait() }
                let quit = stopped
                cond.unlock()
                if quit { return }

                let out = folder.appendingPathComponent("\(i).\(action.track.fileExtension)")
                var item = Item(url: out, isTemp: true)
                do {
                    item.result = try optimizer.copyOptimising(
                        from: action.track.sourceURL, to: out, albumArtist: action.track.albumArtist)
                } catch {
                    item.error = error
                    try? FileManager.default.removeItem(at: out)
                }
                cond.lock()
                items[i] = item
                cond.broadcast()
                cond.unlock()
            }
        }
    }

    /// The prepared file for action `index`; waits until it is ready.
    func take(_ index: Int) -> Item {
        cond.lock()
        while items[index] == nil && !stopped { cond.wait() }
        let item = items.removeValue(forKey: index)
            ?? Item(url: folder, isTemp: false, error: SyncEngine.CancelledError())
        consumed = index + 1
        cond.broadcast()
        cond.unlock()
        return item
    }

    func stop() {
        cond.lock()
        stopped = true
        cond.broadcast()
        cond.unlock()
        try? FileManager.default.removeItem(at: folder)
    }
}
