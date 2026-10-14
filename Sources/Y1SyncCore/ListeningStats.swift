import Foundation

/// One line of the player's own play log (`.scrobbler.log`, the AudioScrobbler
/// 1.1 format the Innioasis firmware writes by itself).
public struct ScrobbleEntry: Sendable, Hashable {
    public var artist: String
    public var album: String
    public var title: String
    public var seconds: Int
    /// "L" in the log; "S" means the track was skipped and does not count.
    public var listened: Bool
    public var date: Date
}

public enum ScrobbleLog {
    public static let fileName = ".scrobbler.log"

    /// Tab-separated: artist, album, title, track number, seconds, L/S, unix time.
    public static func parse(_ text: String) -> [ScrobbleEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, let when = TimeInterval(f[6].trimmingCharacters(in: .whitespaces)),
                  !f[0].isEmpty, !f[2].isEmpty else { return nil }
            return ScrobbleEntry(artist: f[0], album: f[1], title: f[2], seconds: Int(f[4]) ?? 0,
                                 listened: f[5] == "L", date: Date(timeIntervalSince1970: when))
        }
    }

    public static func read(deviceRoot: URL) -> [ScrobbleEntry] {
        let url = deviceRoot.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return [] }
        return parse(text)
    }
}

/// An album on the player together with how much it has been listened to.
public struct AlbumUsage: Sendable, Identifiable {
    public var id: String
    public var artist: String
    public var title: String
    public var tracks: [Track]
    public var bytes: Int64
    public var plays: Int
    public var lastPlayed: Date?
}

/// What the play log says about the music on the player.
public struct ListeningStats: Sendable {
    public struct Ranked: Sendable, Identifiable {
        public var id: String
        public var name: String
        public var detail: String
        public var plays: Int
    }

    public var plays: Int
    public var seconds: Int
    public var first: Date?
    public var last: Date?
    public var topArtists: [Ranked]
    public var topAlbums: [Ranked]
    /// Every album on the player, most-played first.
    public var albums: [AlbumUsage]

    public init(entries: [ScrobbleEntry], deviceTracks: [Track]) {
        let heard = entries.filter(\.listened)
        plays = heard.count
        seconds = heard.reduce(0) { $0 + $1.seconds }
        first = entries.map(\.date).min()
        last = entries.map(\.date).max()

        // Artists and albums as the log spells them, merged when only case,
        // accents or "The" differ.
        var artists: [String: (name: [String: Int], plays: Int)] = [:]
        var albumsTop: [String: (artist: String, album: String, plays: Int)] = [:]
        for e in heard {
            let k = SimilarArtists.base(e.artist)
            var a = artists[k] ?? ([:], 0)
            a.name[e.artist, default: 0] += 1; a.plays += 1
            artists[k] = a
            let ak = k + "|" + SimilarAlbums.base(e.album)
            var b = albumsTop[ak] ?? (e.artist, e.album, 0)
            b.plays += 1
            albumsTop[ak] = b
        }
        topArtists = artists.map { k, v in
            Ranked(id: k, name: v.name.max { $0.value < $1.value }?.key ?? k, detail: "", plays: v.plays)
        }.sorted { ($1.plays, $0.name) < ($0.plays, $1.name) }
        topAlbums = albumsTop.map { k, v in
            Ranked(id: k, name: v.album, detail: v.artist, plays: v.plays)
        }.sorted { ($1.plays, $0.name) < ($0.plays, $1.name) }

        // Each play goes to the player's copy of that song, matched by title and
        // artist; when the song is on two albums the one whose album name
        // matches the log gets it.
        var bySong: [String: [Track]] = [:]
        for t in deviceTracks {
            bySong[Duplicates.normalise(t.effectiveTitle) + "|" + SimilarArtists.base(t.effectiveArtist), default: []].append(t)
        }
        var playsByTrack: [URL: Int] = [:]
        var lastByTrack: [URL: Date] = [:]
        for e in heard {
            let key = Duplicates.normalise(e.title) + "|" + SimilarArtists.base(e.artist)
            guard let candidates = bySong[key] else { continue }
            let target = candidates.first { SimilarAlbums.base($0.effectiveAlbum) == SimilarAlbums.base(e.album) }
                ?? candidates[0]
            playsByTrack[target.sourceURL, default: 0] += 1
            lastByTrack[target.sourceURL] = max(lastByTrack[target.sourceURL] ?? .distantPast, e.date)
        }

        var groups: [String: AlbumUsage] = [:]
        for t in deviceTracks {
            let key = SyncSelection.albumKey(for: t)
            var g = groups[key] ?? AlbumUsage(id: key, artist: t.effectiveAlbumArtist, title: t.effectiveAlbum,
                                              tracks: [], bytes: 0, plays: 0, lastPlayed: nil)
            g.tracks.append(t)
            g.bytes += t.fileSize
            g.plays += playsByTrack[t.sourceURL] ?? 0
            if let d = lastByTrack[t.sourceURL] { g.lastPlayed = max(g.lastPlayed ?? .distantPast, d) }
            groups[key] = g
        }
        albums = groups.values.sorted {
            ($1.plays, $0.artist.lowercased(), $0.title.lowercased()) < ($0.plays, $1.artist.lowercased(), $1.title.lowercased())
        }
    }

    /// The albums to remove to free about `target` bytes: never played first,
    /// then least played, then longest ago; bigger albums first among equals.
    public func leastListened(freeing target: Int64) -> [AlbumUsage] {
        let order = albums.sorted { a, b in
            if a.plays != b.plays { return a.plays < b.plays }
            if a.lastPlayed != b.lastPlayed { return (a.lastPlayed ?? .distantPast) < (b.lastPlayed ?? .distantPast) }
            return a.bytes > b.bytes
        }
        var picked: [AlbumUsage] = []
        var total: Int64 = 0
        for a in order where total < target {
            picked.append(a); total += a.bytes
        }
        return picked
    }
}
