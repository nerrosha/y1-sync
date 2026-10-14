import Foundation

/// One file that needs to move.
public struct SyncAction: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Not on the device at all.
        case copy
        /// Present but a different size — a truncated or interrupted earlier copy.
        case replace
    }

    /// Why the file is planned — shown to the user instead of a bare "replace".
    public enum Reason: Sendable, Hashable {
        /// Not on the player yet.
        case new
        /// The copy on the player is shorter than the source: an interrupted copy.
        case truncated
        /// Present, but its audio differs from the source.
        case changed
    }

    public var kind: Kind
    public var track: Track
    public var devicePath: String
    public var reason: Reason

    public init(kind: Kind, track: Track, devicePath: String, reason: Reason? = nil) {
        self.kind = kind
        self.track = track
        self.devicePath = devicePath
        self.reason = reason ?? (kind == .copy ? .new : .changed)
    }
}

/// The result of comparing a local library against what is already on the player.
public struct SyncPlan: Sendable {
    public var actions: [SyncAction]
    /// Tracks already present and the right size — nothing to do.
    public var upToDate: [Track]
    /// Local tracks that would land on the same device path as another track.
    /// Reported rather than silently overwritten.
    public var collisions: [String: [Track]]

    public init(actions: [SyncAction] = [], upToDate: [Track] = [], collisions: [String: [Track]] = [:]) {
        self.actions = actions
        self.upToDate = upToDate
        self.collisions = collisions
    }

    public var bytesToCopy: Int64 {
        actions.reduce(0) { $0 + $1.track.fileSize }
    }

    public var isEmpty: Bool { actions.isEmpty }
}

/// Describes a file already on the device, as seen by the scanner.
public struct DeviceFile: Sendable, Hashable {
    public var path: String
    public var size: Int64
    /// Where the file lives, so the planner can read its audio size when the
    /// total size disagrees with the source. Nil in tests and for plain lists.
    public var url: URL?

    public init(path: String, size: Int64, url: URL? = nil) {
        self.path = path
        self.size = size
        self.url = url
    }
}

public struct SyncPlanner: Sendable {
    public var layout: DeviceLayout

    public init(layout: DeviceLayout = DeviceLayout()) {
        self.layout = layout
    }

    /// Compare the library against the device contents.
    ///
    /// Matching is by destination path and size. Size is a deliberately cheap
    /// proxy for "same file": hashing every track would mean reading the whole
    /// library and the whole device on every sync, which on a USB 2.0
    /// mass-storage player costs minutes for no practical gain.
    ///
    /// Total size alone is not enough: tags are rewritten on the way across
    /// (cover shrunk, album artist corrected) and Lyrics / Find art embed
    /// covers on the player later, so a correctly synced file is almost never
    /// the same size as its source. When the totals differ, the audio payload
    /// sizes (the file minus its metadata) are compared instead — the audio is
    /// never touched, so equal payloads mean "already there".
    public func plan(library: [Track], deviceFiles: [DeviceFile]) -> SyncPlan {
        var fileByPath: [String: DeviceFile] = [:]
        for file in deviceFiles {
            fileByPath[FATName.foldedKey(file.path)] = file
        }

        var actions: [SyncAction] = []
        var upToDate: [Track] = []
        var claimedBy: [String: [Track]] = [:]

        for track in library {
            let path = layout.path(for: track)
            let key = FATName.foldedKey(path)
            claimedBy[key, default: []].append(track)

            // Only the first track claiming a path is planned; the rest are
            // reported as collisions so the user can fix the tags.
            guard claimedBy[key]?.count == 1 else { continue }

            if let existing = fileByPath[key] {
                let audio = Self.audioSizes(existing, track)
                if existing.size == track.fileSize || (audio != nil && audio!.device == audio!.source) {
                    upToDate.append(track)
                } else {
                    // Compare payloads when we can: a smaller total can just be
                    // a shrunk cover, but a smaller payload is a cut-off copy.
                    let short = audio.map { $0.device < $0.source } ?? (existing.size < track.fileSize)
                    actions.append(SyncAction(kind: .replace, track: track, devicePath: path,
                                              reason: short ? .truncated : .changed))
                }
            } else {
                actions.append(SyncAction(kind: .copy, track: track, devicePath: path))
            }
        }

        let collisions = claimedBy.filter { $0.value.count > 1 }
        return SyncPlan(actions: actions, upToDate: upToDate, collisions: collisions)
    }

    /// Audio payload sizes of the copy on the player and of its source, when
    /// both are known (MP3 and FLAC only).
    static func audioSizes(_ onDevice: DeviceFile, _ track: Track) -> (device: Int64, source: Int64)? {
        guard let url = onDevice.url,
              let theirs = AudioSize.of(url, size: onDevice.size),
              let ours = AudioSize.of(track.sourceURL, size: track.fileSize) else { return nil }
        return (theirs, ours)
    }
}
