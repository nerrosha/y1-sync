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
            out.append(DeviceFile(path: devicePath(of: url, root: root), size: size))
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

    /// Execute a plan. Copies go to a temporary name and are then moved into
    /// place, so an interrupted or failed copy cannot leave a half-written
    /// file that later looks complete.
    public func execute(
        plan: SyncPlan,
        deviceRoot: URL,
        progress: (@Sendable (SyncProgress) -> Void)? = nil
    ) throws -> SyncResult {
        let fm = FileManager.default

        let free = (try? deviceRoot.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init) ?? .max
        if plan.bytesToCopy > free {
            throw DeviceError.insufficientSpace(needed: plan.bytesToCopy, free: free)
        }

        var copied = 0, replaced = 0
        var failures: [(String, String)] = []
        var bytes: Int64 = 0
        var shrunk = 0
        var saved: Int64 = 0
        var changes: [FileChange] = []

        for (index, action) in plan.actions.enumerated() {
            let dest = deviceRoot.appendingPathComponent(
                action.devicePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
            let tmp = dest.deletingLastPathComponent()
                .appendingPathComponent(".y1sync-\(UUID().uuidString).part")

            do {
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }

                var change = FileChange(devicePath: action.devicePath, track: action.track)
                change.wasReplaced = action.kind == .replace

                if let optimizer = artworkOptimizer {
                    // Write the corrected album artist so tag-driven library
                    // views group the album the same way the folders do.
                    let r = try optimizer.copyOptimising(
                        from: action.track.sourceURL, to: tmp,
                        albumArtist: action.track.albumArtist)
                    if r.didRewrite, let was = r.originalArtBytes, let now = r.newArtBytes {
                        shrunk += 1
                        saved += Int64(was - now)
                        change.artFrom = r.fromPixels
                        change.artTo = r.toPixels
                        change.artBytesSaved = Int64(was - now)
                    }
                } else {
                    try fm.copyItem(at: action.track.sourceURL, to: tmp)
                }

                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: tmp, to: dest)

                bytes += action.track.fileSize
                if action.kind == .replace { replaced += 1 } else { copied += 1 }
                changes.append(change)
            } catch {
                try? fm.removeItem(at: tmp)
                failures.append((action.devicePath, error.localizedDescription))
            }

            progress?(SyncProgress(
                completed: index + 1,
                total: plan.actions.count,
                bytesCopied: bytes,
                bytesTotal: plan.bytesToCopy,
                currentPath: action.devicePath
            ))
        }

        return SyncResult(copied: copied, replaced: replaced, failed: failures,
                          bytesCopied: bytes, artworkShrunk: shrunk,
                          artworkBytesSaved: saved, changes: changes)
    }
}
