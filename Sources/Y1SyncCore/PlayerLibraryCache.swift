import Foundation

/// The player's own list of songs.
///
/// Innioasis firmware does not browse the card when you open "Songs": it reads
/// `.y1_library_cache.json` at the root of the card, a list of every track it
/// knew about the last time it scanned. Files copied since then exist on the
/// card and play on a computer, but are invisible on the player until that list
/// learns about them — and moved or removed files linger in it as dead entries.
///
/// This keeps the list in step with the card. Existing entries are left exactly
/// as the firmware wrote them (including any fields we don't know about); only
/// missing tracks are added and entries for files that are gone are dropped.
public enum PlayerLibraryCache {
    public static let fileName = ".y1_library_cache.json"
    static let backupName = ".y1_library_cache.json.y1sync-backup"
    static let defaultMount = "/storage/sdcard0"

    public static func fileURL(_ deviceRoot: URL) -> URL {
        deviceRoot.appendingPathComponent(fileName)
    }

    public static func exists(deviceRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(deviceRoot).path)
    }

    /// How the list differs from what is on the card.
    public struct Status: Sendable {
        /// Entries the player already has.
        public var cached: Int
        /// Tracks on the card the player cannot see.
        public var missing: [Track]
        /// Device paths the list names but that no longer exist.
        public var stale: [String]

        public var isInSync: Bool { missing.isEmpty && stale.isEmpty }
    }

    public enum CacheError: Error, CustomStringConvertible {
        case unreadable
        public var description: String { "the player's library list could not be read" }
    }

    /// Compare the list with the tracks found on the card. Nil when the player
    /// keeps no list (the firmware then builds one itself).
    public static func status(deviceRoot: URL, deviceTracks: [Track]) -> Status? {
        guard let (_, entries) = try? load(deviceRoot) else { return nil }
        let engine = SyncEngine()
        let mount = mountPrefix(entries)

        var onCard: [String: Track] = [:]
        for t in deviceTracks { onCard[key(engine.devicePath(of: t.sourceURL, root: deviceRoot))] = t }

        var listed = Set<String>()
        var stale: [String] = []
        for e in entries {
            guard let path = e["path"] as? String else { continue }
            let rel = deviceRelative(path, mount: mount)
            listed.insert(key(rel))
            if onCard[key(rel)] == nil { stale.append(rel) }
        }
        let missing = onCard.filter { !listed.contains($0.key) }.map(\.value)
            .sorted { $0.sourceURL.path < $1.sourceURL.path }
        return Status(cached: entries.count, missing: missing, stale: stale.sorted())
    }

    public struct Result: Sendable {
        public var added = 0
        public var removed = 0
    }

    /// Add `adding` to the list (skipping what is already there) and, when
    /// `dropDeadEntries` is set, drop entries whose file no longer exists. The
    /// previous list is kept beside it as a backup. Does nothing if the player
    /// keeps no list.
    @discardableResult
    public static func update(
        deviceRoot: URL, adding: [(track: Track, devicePath: String)],
        dropDeadEntries: Bool = true
    ) throws -> Result {
        guard exists(deviceRoot: deviceRoot) else { return Result() }
        let (top, entries) = try load(deviceRoot)
        let mount = mountPrefix(entries)
        let fm = FileManager.default
        var result = Result()

        var kept: [[String: Any]] = []
        var listed = Set<String>()
        for e in entries {
            guard let path = e["path"] as? String else { kept.append(e); continue }
            let rel = deviceRelative(path, mount: mount)
            if dropDeadEntries,
               !fm.fileExists(atPath: deviceRoot.appendingPathComponent(rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).path) {
                result.removed += 1
                continue
            }
            listed.insert(key(rel))
            kept.append(e)
        }
        for item in adding where !listed.contains(key(item.devicePath)) {
            listed.insert(key(item.devicePath))
            kept.append(entry(for: item.track, devicePath: item.devicePath, mount: mount))
            result.added += 1
        }
        guard result.added > 0 || result.removed > 0 else { return result }

        var out = top
        out["music"] = kept
        let data = try JSONSerialization.data(withJSONObject: out, options: [])
        let url = fileURL(deviceRoot)
        let backup = deviceRoot.appendingPathComponent(backupName)
        try? fm.removeItem(at: backup)
        try? fm.copyItem(at: url, to: backup)
        try data.write(to: url, options: .atomic)
        return result
    }

    /// Bring the list fully in step with the card: add every missing track and
    /// drop dead entries.
    @discardableResult
    public static func sync(deviceRoot: URL, deviceTracks: [Track]) throws -> Result {
        let engine = SyncEngine()
        let pairs = deviceTracks.map { (track: $0, devicePath: engine.devicePath(of: $0.sourceURL, root: deviceRoot)) }
        return try update(deviceRoot: deviceRoot, adding: pairs, dropDeadEntries: true)
    }

    // MARK: - Internals

    private static func load(_ deviceRoot: URL) throws -> ([String: Any], [[String: Any]]) {
        guard let data = try? Data(contentsOf: fileURL(deviceRoot)),
              let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let music = top["music"] as? [[String: Any]] else { throw CacheError.unreadable }
        return (top, music)
    }

    /// FAT is case-insensitive and macOS may hand back decomposed Unicode.
    private static func key(_ devicePath: String) -> String { FATName.foldedKey(devicePath) }

    /// "/storage/sdcard0" or whatever the firmware recorded before "/Music/".
    private static func mountPrefix(_ entries: [[String: Any]]) -> String {
        for e in entries {
            if let p = e["path"] as? String, let r = p.range(of: "/Music/") {
                return String(p[p.startIndex..<r.lowerBound])
            }
        }
        return defaultMount
    }

    private static func deviceRelative(_ path: String, mount: String) -> String {
        path.hasPrefix(mount) ? String(path.dropFirst(mount.count)) : path
    }

    /// One entry in the firmware's own shape and defaults.
    static func entry(for t: Track, devicePath: String, mount: String) -> [String: Any] {
        [
            "trackNum": t.trackNumber ?? 0,
            "genre": Track.nonBlank(t.genre ?? "") ?? "Unknown Genre",
            "composer": "Unknown Composer",
            "title": t.effectiveTitle,
            "albumArtist": t.effectiveAlbumArtist,
            "album": t.effectiveAlbum,
            "path": mount + devicePath,
            "year": t.year.map(String.init) ?? "Unknown Year",
            "artist": t.effectiveArtist,
        ]
    }
}
