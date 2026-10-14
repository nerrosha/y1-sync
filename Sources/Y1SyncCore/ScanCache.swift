import Foundation

/// Remembers what was learned about each file, so a second scan only reads the
/// files that changed. Reading tags and checking audio off a USB player costs
/// time in proportion to bytes read (about 5 MB/s), so skipping unchanged files
/// is the whole speed-up.
///
/// A file counts as unchanged when its size and modification time are the same.
/// Tag edits and copies change both, so stale entries are never trusted. The
/// cache lives on the Mac (never on the player) and is safe to delete.
public final class ScanCache: @unchecked Sendable {
    struct Stamp: Codable, Equatable { var size: Int64; var mtime: Double }

    struct CachedTrack: Codable {
        var stamp: Stamp
        var title, artist, albumArtist, album: String?
        var trackNumber, discNumber, year: Int?
        var durationSeconds: Double?
        var genre: String?
        var bpm: Double?
        var moods: [String]
        var codec: String?
        var sampleRate, bitDepth: Int?
    }

    struct Healthy: Codable {
        var stamp: Stamp
        /// Which checks passed (art limit, format limits, tail check…).
        var signature: String
        var hasEmbeddedArt: Bool
    }

    struct Store: Codable {
        var version = ScanCache.version
        var tracks: [String: CachedTrack] = [:]
        var healthy: [String: Healthy] = [:]
    }

    static let version = 2

    private let root: URL
    private let fileURL: URL
    private var store: Store
    private let lock = NSLock()
    private var dirty = false

    public init(root: URL, directory: URL? = nil) {
        self.root = root.standardizedFileURL
        let dir = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Y1Sync", isDirectory: true)
        // FNV-1a of the folder path: one cache file per folder or player.
        var h: UInt64 = 0xcbf29ce484222325
        for b in self.root.path.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        fileURL = dir.appendingPathComponent("scan-\(String(h, radix: 16)).json")
        if let data = try? Data(contentsOf: fileURL),
           let s = try? JSONDecoder().decode(Store.self, from: data), s.version == Self.version {
            store = s
        } else {
            store = Store()
        }
    }

    // MARK: Keys

    private func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root.path) ? String(path.dropFirst(root.path.count)) : path
    }

    static func stamp(of url: URL) -> Stamp? {
        // A fresh URL: a URL object caches its resource values, which would hide a change.
        let fresh = URL(fileURLWithPath: url.path)
        guard let v = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = v.fileSize, let date = v.contentModificationDate else { return nil }
        return Stamp(size: Int64(size), mtime: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    // MARK: Tags

    func track(for url: URL, stamp: Stamp) -> Track? {
        lock.lock(); defer { lock.unlock() }
        guard let c = store.tracks[key(url)], c.stamp == stamp else { return nil }
        return Track(sourceURL: url, title: c.title, artist: c.artist, albumArtist: c.albumArtist,
                     album: c.album, trackNumber: c.trackNumber, discNumber: c.discNumber, year: c.year,
                     durationSeconds: c.durationSeconds, fileSize: stamp.size, genre: c.genre,
                     bpm: c.bpm, moods: c.moods, codec: c.codec, sampleRate: c.sampleRate,
                     bitDepth: c.bitDepth)
    }

    func store(_ t: Track, stamp: Stamp) {
        lock.lock(); defer { lock.unlock() }
        store.tracks[key(t.sourceURL)] = CachedTrack(
            stamp: stamp, title: t.title, artist: t.artist, albumArtist: t.albumArtist, album: t.album,
            trackNumber: t.trackNumber, discNumber: t.discNumber, year: t.year,
            durationSeconds: t.durationSeconds, genre: t.genre, bpm: t.bpm, moods: t.moods,
            codec: t.codec, sampleRate: t.sampleRate, bitDepth: t.bitDepth)
        dirty = true
    }

    // MARK: Health

    /// Whether the file passed the same checks (`signature`) while unchanged.
    /// Returns whether it carries embedded art, nil when it must be checked again.
    public func healthyArt(for track: Track, signature: String) -> Bool? {
        guard let stamp = Self.stamp(of: track.sourceURL) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let h = store.healthy[key(track.sourceURL)], h.stamp == stamp, h.signature == signature
        else { return nil }
        return h.hasEmbeddedArt
    }

    public func markHealthy(_ track: Track, signature: String, hasEmbeddedArt: Bool) {
        guard let stamp = Self.stamp(of: track.sourceURL) else { return }
        lock.lock(); defer { lock.unlock() }
        store.healthy[key(track.sourceURL)] = Healthy(stamp: stamp, signature: signature,
                                                      hasEmbeddedArt: hasEmbeddedArt)
        dirty = true
    }

    // MARK: Persist

    /// Drop entries for files no longer present, then write the cache out.
    public func save(keeping urls: [URL]? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let urls {
            let live = Set(urls.map(key))
            let before = store.tracks.count + store.healthy.count
            store.tracks = store.tracks.filter { live.contains($0.key) }
            store.healthy = store.healthy.filter { live.contains($0.key) }
            if store.tracks.count + store.healthy.count != before { dirty = true }
        }
        guard dirty, let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        dirty = false
    }
}
