import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Politeness limiter shared by the online lookups.
///
/// MusicBrainz asks for at most one request per second per client and will
/// block clients that ignore it. Both services also want a real User-Agent.
actor RateLimiter {
    private var nextAllowed = Date.distantPast
    private let interval: TimeInterval

    init(interval: TimeInterval) { self.interval = interval }

    func wait() async {
        let now = Date()
        if nextAllowed > now {
            try? await Task.sleep(nanoseconds: UInt64(nextAllowed.timeIntervalSince(now) * 1_000_000_000))
        }
        nextAllowed = Date().addingTimeInterval(interval)
    }
}

public enum ServiceAgent {
    /// Both APIs ask callers to identify themselves and provide contact info.
    public static let userAgent = "Y1Sync/1.0 ( https://github.com/ )"
}

// MARK: - Lyrics

public struct Lyrics: Sendable {
    /// Timestamped lines, ready to write as .lrc.
    public var synced: String?
    /// Fallback plain text.
    public var plain: String?
    public var isInstrumental: Bool

    public var best: String? { synced ?? plain }
}

/// Fetches lyrics from LRCLIB — a free, key-less, community lyrics database.
///
/// Stock Innioasis firmware reads `.lrc` files placed beside the audio, which
/// is the same mechanism LRCGET uses, so synced lyrics display on the player.
public struct LyricsFetcher: Sendable {
    private static let limiter = RateLimiter(interval: 0.25)
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    struct LRCLibResponse: Decodable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    public func fetch(for track: Track) async -> Lyrics? {
        // Exact lookup first: with a duration LRCLIB returns the matching
        // version of the song, so the timings line up with this file.
        if let exact = await exactMatch(for: track) { return exact }

        // /api/get returns 404 when the duration differs at all, which happens
        // constantly with re-encodes and slightly different rips. Searching
        // without a duration finds the song and lets us pick the closest.
        return await searchMatch(for: track)
    }

    private func request(_ url: URL) async -> Data? {
        await Self.limiter.wait()
        var request = URLRequest(url: url)
        request.setValue(ServiceAgent.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private func lyrics(from r: LRCLibResponse) -> Lyrics? {
        let synced = r.syncedLyrics.flatMap(Track.nonBlank)
        let plain = r.plainLyrics.flatMap(Track.nonBlank)
        guard synced != nil || plain != nil || r.instrumental == true else { return nil }
        return Lyrics(synced: synced, plain: plain, isInstrumental: r.instrumental ?? false)
    }

    func exactMatch(for track: Track) async -> Lyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [
            URLQueryItem(name: "artist_name", value: track.effectiveArtist),
            URLQueryItem(name: "track_name", value: track.effectiveTitle),
            URLQueryItem(name: "album_name", value: track.effectiveAlbum),
        ]
        if let seconds = track.durationSeconds, seconds > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(seconds.rounded()))))
        }
        components.queryItems = items
        guard let url = components.url, let data = await request(url) else { return nil }
        return (try? JSONDecoder().decode(LRCLibResponse.self, from: data)).flatMap(lyrics)
    }

    func searchMatch(for track: Track) async -> Lyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: track.effectiveArtist),
            URLQueryItem(name: "track_name", value: track.effectiveTitle),
        ]
        guard let url = components.url, let data = await request(url),
              let results = try? JSONDecoder().decode([LRCLibResponse].self, from: data),
              !results.isEmpty else { return nil }

        return lyrics(from: pickBest(results, for: track))
    }

    /// Prefer synced lyrics, then the closest duration to this file.
    func pickBest(_ results: [LRCLibResponse], for track: Track) -> LRCLibResponse {
        let target = track.durationSeconds
        return results.min { a, b in
            let aSynced = Track.nonBlank(a.syncedLyrics ?? "") != nil
            let bSynced = Track.nonBlank(b.syncedLyrics ?? "") != nil
            if aSynced != bSynced { return aSynced }
            guard let target else { return false }
            let aGap = abs((a.duration ?? .greatestFiniteMagnitude) - target)
            let bGap = abs((b.duration ?? .greatestFiniteMagnitude) - target)
            return aGap < bGap
        } ?? results[0]
    }

    /// Write lyrics as a `.lrc` file beside the track on the device.
    /// Returns false when there is nothing to write or a file already exists.
    @discardableResult
    public func writeLRC(_ lyrics: Lyrics, besideDevicePath path: String, deviceRoot: URL) -> Bool {
        guard let text = lyrics.best, !lyrics.isInstrumental else { return false }

        let audio = deviceRoot.appendingPathComponent(
            path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        let lrc = audio.deletingPathExtension().appendingPathExtension("lrc")
        if FileManager.default.fileExists(atPath: lrc.path) { return false }

        do {
            try FileManager.default.createDirectory(
                at: lrc.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: lrc, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Cover art

/// Finds album art on the Cover Art Archive, resolved through MusicBrainz.
///
/// Both are openly licensed and need no API key. Only albums that have no
/// artwork at all are looked up, so a sync does not hammer the services.
public struct CoverFetcher: Sendable {
    /// MusicBrainz asks for one request per second; this is shared process-wide.
    private static let limiter = RateLimiter(interval: 1.1)
    public var session: URLSession
    /// Requested size from the archive: 250, 500 or 1200.
    public var size: Int

    public init(session: URLSession = .shared, size: Int = 500) {
        self.session = session
        self.size = size
    }

    struct ReleaseSearch: Decodable {
        struct Entity: Decodable { var id: String }
        var releases: [Entity]?
        var releaseGroups: [Entity]?

        enum CodingKeys: String, CodingKey {
            case releases
            case releaseGroups = "release-groups"
        }
    }

    /// Look up candidate ids for an album.
    ///
    /// Release *groups* are tried first: a group covers every edition of an
    /// album, so its cover art is present far more often than that of one
    /// specific pressing (a cassette reissue frequently has none).
    func search(entity: String, query: String, limit: Int) async -> [String] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/\(entity)")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { return [] }

        await Self.limiter.wait()

        var request = URLRequest(url: url)
        request.setValue(ServiceAgent.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(ReleaseSearch.self, from: data)
            return (decoded.releaseGroups ?? decoded.releases ?? []).map(\.id)
        } catch {
            return []
        }
    }

    /// Resolve an artist/album pair to a MusicBrainz release id.
    public func findReleaseID(artist: String, album: String) async -> String? {
        let query = "artist:\"\(escaped(artist))\" AND release:\"\(escaped(album))\""
        return await search(entity: "release", query: query, limit: 5).first
    }

    func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "")
         .replacingOccurrences(of: "\"", with: "")
    }

    /// Download front cover art for a release or release-group id.
    public func downloadFront(id: String, kind: String = "release") async -> Data? {
        let url = URL(string: "https://coverartarchive.org/\(kind)/\(id)/front-\(size)")!
        var request = URLRequest(url: url)
        request.setValue(ServiceAgent.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }

    public func downloadFront(releaseID: String) async -> Data? {
        await downloadFront(id: releaseID, kind: "release")
    }

    public func fetch(artist: String, album: String) async -> Data? {
        let a = escaped(artist), b = escaped(album)

        // Release groups first — one group covers every pressing of an album,
        // so art is present much more often than on a single edition.
        let groups = await search(entity: "release-group",
                                  query: "artist:\"\(a)\" AND releasegroup:\"\(b)\"", limit: 3)
        for id in groups {
            if let art = await downloadFront(id: id, kind: "release-group") { return art }
        }

        // Fall back to individual releases, trying several: the top-scoring
        // match is often an obscure edition with no artwork attached.
        let releases = await search(entity: "release",
                                    query: "artist:\"\(a)\" AND release:\"\(b)\"", limit: 5)
        for id in releases {
            if let art = await downloadFront(id: id, kind: "release") { return art }
        }
        return nil
    }
}
