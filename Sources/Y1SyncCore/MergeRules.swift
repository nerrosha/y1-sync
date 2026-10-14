import Foundation

/// A merge the user made on the player, remembered so a later sync does not undo it.
///
/// Merging two spellings only edits tags on the player; the library keeps the
/// old ones, so the next sync would copy them back and split the album or artist
/// again. A rule renames them on the way across (the library is never touched).
public struct MergeRule: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case album, artist }

    public var kind: Kind
    /// The spelling being replaced.
    public var from: String
    /// The spelling kept.
    public var to: String
    /// Albums only: the artist(s) the album belongs to, folded, so another
    /// artist's album with the same title is not renamed.
    public var artists: [String]
    /// The undoable operation that created it; undoing that forgets the rule.
    public var sessionID: UUID?

    public var id: String { "\(kind.rawValue)|\(MergeRules.fold(from))|\(artists.joined(separator: ","))" }

    public init(kind: Kind, from: String, to: String, artists: [String] = [], sessionID: UUID? = nil) {
        self.kind = kind
        self.from = from
        self.to = to
        self.artists = artists
        self.sessionID = sessionID
    }
}

public enum MergeRules {
    /// Case, accents and Unicode form ignored, as on the player's FAT card.
    public static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Rules for merging `variants` of one artist into `name`.
    public static func artistRules(from group: SimilarArtistGroup, into name: String, session: UUID?) -> [MergeRule] {
        group.variants.map(\.name).filter { $0 != name }
            .map { MergeRule(kind: .artist, from: $0, to: name, sessionID: session) }
    }

    public static func albumRules(from group: SimilarAlbumGroup, into title: String, session: UUID?) -> [MergeRule] {
        let artists = Array(Set(group.variants.flatMap(\.tracks).map { fold($0.effectiveAlbumArtist) })).sorted()
        return group.variants.map(\.title).filter { $0 != title }
            .map { MergeRule(kind: .album, from: $0, to: title, artists: artists, sessionID: session) }
    }

    /// Insert or replace (same spelling replaced, same artists).
    public static func adding(_ new: [MergeRule], to rules: [MergeRule]) -> [MergeRule] {
        var out = rules.filter { r in !new.contains { $0.id == r.id } }
        // A rule whose target is itself later renamed would be a chain; keep both, apply in order.
        out.append(contentsOf: new)
        return out
    }

    /// The library as it should look on the player. Tags are changed in the
    /// returned tracks only; `tagEdits` says what to write into each file when
    /// it is copied.
    public static func apply(_ rules: [MergeRule], to tracks: [Track]) -> [Track] {
        guard !rules.isEmpty else { return tracks }
        let artistRules = rules.filter { $0.kind == .artist }
        let albumRules = rules.filter { $0.kind == .album }
        return tracks.map { apply(artistRules, albumRules, to: $0) }
    }

    static func apply(_ artistRules: [MergeRule], _ albumRules: [MergeRule], to track: Track) -> Track {
        var t = track
        let originalArtistKey = fold(track.effectiveAlbumArtist)

        for r in artistRules {
            guard let current = t.albumArtist.flatMap(Track.nonBlank) ?? t.artist.flatMap(Track.nonBlank),
                  fold(current) == fold(r.from), current != r.to else { continue }
            // Same rule as the merge itself: a track's own artist is only
            // changed when it was exactly the spelling being replaced.
            if t.artist == current { t.artist = r.to; t.tagEdits["ARTIST"] = r.to }
            t.albumArtist = r.to
            t.tagEdits["ALBUMARTIST"] = r.to
        }
        let newArtistKey = fold(t.effectiveAlbumArtist)

        for r in albumRules {
            guard let album = t.album.flatMap(Track.nonBlank), fold(album) == fold(r.from), album != r.to,
                  r.artists.contains(newArtistKey) || r.artists.contains(originalArtistKey) else { continue }
            t.album = r.to
            t.tagEdits["ALBUM"] = r.to
        }
        return t
    }
}

extension MergeRules {
    /// Spellings in the library that the player already spells differently — the
    /// merges made before rules were remembered. A library song is matched to a
    /// player song by title and length, with a similar artist; the rule is only
    /// suggested when the album or artist names are alike (a typo, a leading
    /// "The", an edition tag) and at least two songs agree, so a single versus
    /// the album it is on is never mistaken for a rename.
    public static func learn(library: [Track], device: [Track], existing: [MergeRule] = []) -> [MergeRule] {
        var byTitle: [String: [Track]] = [:]
        for d in device { byTitle[Duplicates.normalise(d.effectiveTitle), default: []].append(d) }

        struct Vote: Hashable { var kind: MergeRule.Kind; var from: String; var to: String; var artist: String }
        var votes: [Vote: Int] = [:]

        for l in library {
            guard let candidates = byTitle[Duplicates.normalise(l.effectiveTitle)] else { continue }
            let match = candidates.first { d in
                if let a = l.durationSeconds, let b = d.durationSeconds, abs(a - b) > 3 { return false }
                return SimilarArtists.base(l.effectiveAlbumArtist) == SimilarArtists.base(d.effectiveAlbumArtist)
            }
            guard let d = match else { continue }

            let artistKey = fold(d.effectiveAlbumArtist)
            if l.effectiveAlbumArtist != d.effectiveAlbumArtist {
                votes[Vote(kind: .artist, from: l.effectiveAlbumArtist, to: d.effectiveAlbumArtist, artist: ""), default: 0] += 1
            }
            let la = l.effectiveAlbum, da = d.effectiveAlbum
            if la != da {
                let x = SimilarAlbums.base(la), y = SimilarAlbums.base(da)
                if x == y || SimilarAlbums.isTypo(x, y) {
                    votes[Vote(kind: .album, from: la, to: da, artist: artistKey), default: 0] += 1
                }
            }
        }

        let known = Set(existing.map(\.id))
        return votes.filter { $0.value >= 2 }
            .map { v, _ -> MergeRule in
                switch v.kind {
                case .artist: return MergeRule(kind: .artist, from: v.from, to: v.to)
                case .album:
                    return MergeRule(kind: .album, from: v.from, to: v.to,
                                     artists: [v.artist, fold(libraryArtist(v.from, in: library) ?? "")])
                }
            }
            .filter { !known.contains($0.id) }
            .sorted { ($0.kind.rawValue, $0.from) < ($1.kind.rawValue, $1.from) }
    }

    private static func libraryArtist(_ album: String, in library: [Track]) -> String? {
        library.first { $0.effectiveAlbum == album }?.effectiveAlbumArtist
    }
}
