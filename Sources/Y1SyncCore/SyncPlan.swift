import Foundation

/// One file that needs to move.
public struct SyncAction: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Not on the device at all.
        case copy
        /// Present but a different size — a truncated or interrupted earlier copy.
        case replace
    }

    public var kind: Kind
    public var track: Track
    public var devicePath: String

    public init(kind: Kind, track: Track, devicePath: String) {
        self.kind = kind
        self.track = track
        self.devicePath = devicePath
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

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }
}

public struct SyncPlanner: Sendable {
    public var layout: DeviceLayout

    public init(layout: DeviceLayout = DeviceLayout()) {
        self.layout = layout
    }

    /// Compare the library against the device contents.
    ///
    /// Matching is by destination path and file size. Size is a deliberately
    /// cheap proxy for "same file": hashing every track would mean reading the
    /// entire library and the entire device on every sync, which on a
    /// USB 2.0 mass-storage player costs minutes for no practical gain.
    public func plan(library: [Track], deviceFiles: [DeviceFile]) -> SyncPlan {
        var sizeByPath: [String: Int64] = [:]
        for file in deviceFiles {
            sizeByPath[FATName.foldedKey(file.path)] = file.size
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

            if let existing = sizeByPath[key] {
                if existing == track.fileSize {
                    upToDate.append(track)
                } else {
                    actions.append(SyncAction(kind: .replace, track: track, devicePath: path))
                }
            } else {
                actions.append(SyncAction(kind: .copy, track: track, devicePath: path))
            }
        }

        let collisions = claimedBy.filter { $0.value.count > 1 }
        return SyncPlan(actions: actions, upToDate: upToDate, collisions: collisions)
    }
}
