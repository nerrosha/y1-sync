import Foundation

/// Builds playlists from tags a library may already carry — mood, tempo and
/// genre — rather than from anything fetched online. Some tagging tools
/// (beets and Picard's AcousticBrainz plugins, in particular) write these
/// automatically; most libraries won't have them on every file, so every
/// grouping here simply skips a track that lacks the tag it needs.
public struct SmartPlaylistBuilder: Sendable {
    public init() {}

    /// One list per mood a track scored positively on. A track can land in
    /// several (each mood is an independent classifier) or none at all.
    public func byMood(_ tracks: [Track]) -> [String: [Track]] {
        var groups: [String: [Track]] = [:]
        for t in tracks {
            for mood in t.moods {
                groups[mood, default: []].append(t)
            }
        }
        return groups
    }

    public struct BPMRange: Sendable {
        public var name: String
        public var range: ClosedRange<Double>
        public init(_ name: String, _ range: ClosedRange<Double>) {
            self.name = name
            self.range = range
        }
    }

    public static let defaultBPMRanges: [BPMRange] = [
        BPMRange("Slow (under 90 BPM)", 0...89.999),
        BPMRange("Mid-tempo (90-119 BPM)", 90...119.999),
        BPMRange("Upbeat (120-149 BPM)", 120...149.999),
        BPMRange("Fast (150 BPM and up)", 150...100_000),
    ]

    public func byBPM(_ tracks: [Track], ranges: [BPMRange] = defaultBPMRanges) -> [String: [Track]] {
        var groups: [String: [Track]] = [:]
        for t in tracks {
            guard let bpm = t.bpm, let bucket = ranges.first(where: { $0.range.contains(bpm) }) else { continue }
            groups[bucket.name, default: []].append(t)
        }
        return groups
    }

    /// A genre tag is frequently a whole list crammed into one field, mixing
    /// separators between rips — "Alternative Rock;Rock;Britpop", "Pop, Rock"
    /// — rather than one clean value. Splitting it means "Indie Rock" pulls
    /// in every track tagged with it as part of a list, instead of each
    /// distinct raw string becoming its own near-duplicate playlist.
    public func byGenre(_ tracks: [Track]) -> [String: [Track]] {
        var groups: [String: [Track]] = [:]
        for t in tracks {
            for genre in Self.splitGenres(t.genre) {
                groups[genre, default: []].append(t)
            }
        }
        return groups
    }

    static func splitGenres(_ raw: String?) -> [String] {
        guard let raw, let nonBlank = Track.nonBlank(raw) else { return [] }
        return nonBlank.components(separatedBy: CharacterSet(charactersIn: ";,"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension SmartPlaylistBuilder {
    public struct WriteResult: Sendable {
        /// Playlist name to track count, for whatever actually got written.
        public var written: [String: Int] = [:]
        public init() {}
    }

    /// Write one `.m3u8` per group that clears `minimumTracks` — a playlist
    /// of one or two tracks isn't useful, and just adds clutter next to any
    /// real playlists the user has. Names are prefixed by kind so they sort
    /// together in the player's playlist folder.
    @discardableResult
    public func writeAll(
        tracks: [Track], deviceRoot: URL,
        moods: Bool = true, bpm: Bool = true, genres: Bool = true,
        minimumTracks: Int = 3, writer: PlaylistWriter = PlaylistWriter()
    ) throws -> WriteResult {
        var groups: [(name: String, tracks: [Track])] = []
        if moods {
            groups += byMood(tracks).map { (name: "Mood - \($0.key.capitalized)", tracks: $0.value) }
        }
        if bpm {
            groups += byBPM(tracks).map { (name: "Tempo - \($0.key)", tracks: $0.value) }
        }
        if genres {
            groups += byGenre(tracks).map { (name: "Genre - \($0.key)", tracks: $0.value) }
        }

        var result = WriteResult()
        for group in groups where group.tracks.count >= minimumTracks {
            let sorted = group.tracks.sorted {
                ($0.effectiveArtist, $0.effectiveAlbum, $0.trackNumber ?? 0)
                < ($1.effectiveArtist, $1.effectiveAlbum, $1.trackNumber ?? 0)
            }
            _ = try writer.write(name: group.name, tracks: sorted, deviceRoot: deviceRoot)
            result.written[group.name] = sorted.count
        }
        return result
    }
}
