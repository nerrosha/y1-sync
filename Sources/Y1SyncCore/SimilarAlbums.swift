import Foundation

/// One spelling of an album title, with the tracks filed under it.
public struct AlbumVariant: Sendable, Identifiable {
    public var id: String { title }
    public var title: String
    public var tracks: [Track]
}

/// Albums by one artist that are really the same album split by its tags:
/// a typo in one copy ("Malcom Todd"), a deluxe edition ("(still)"), or a
/// single that was downloaded on its own.
public struct SimilarAlbumGroup: Sendable, Identifiable {
    public var id: String { albumArtist + "|" + variants.map(\.title).sorted().joined(separator: "|") }
    public var albumArtist: String
    public var variants: [AlbumVariant]
    /// Title to merge into when the user has no preference: the fullest one.
    public var suggested: String
    /// Songs that appear under more than one title — merging will make these duplicates.
    public var sharedSongs: Int

    public var trackCount: Int { variants.reduce(0) { $0 + $1.tracks.count } }
}

/// Finds albums that browse as several albums although they are one.
///
/// Merely similar *names* are never enough ("Pt. 1" and "Pt. 2", a studio album
/// and its "(Live)" version): two titles are only linked when the names are
/// alike **and** at least half of the smaller album's songs also exist in the
/// other. Links chain, so a stray single joins the album its typo'd siblings
/// belong to.
public struct SimilarAlbums: Sendable {
    public init() {}

    public func find(in tracks: [Track]) -> [SimilarAlbumGroup] {
        var byArtist: [String: [Track]] = [:]
        for t in tracks { byArtist[FATName.foldedKey(t.effectiveAlbumArtist), default: []].append(t) }

        var groups: [SimilarAlbumGroup] = []
        for (_, artistTracks) in byArtist {
            var byTitle: [String: [Track]] = [:]
            for t in artistTracks { byTitle[t.effectiveAlbum, default: []].append(t) }
            let variants = byTitle.map { AlbumVariant(title: $0.key, tracks: $0.value) }
                .sorted { $0.title < $1.title }
            guard variants.count > 1 else { continue }

            var parent = Array(variants.indices)
            func root(_ i: Int) -> Int { parent[i] == i ? i : { parent[i] = root(parent[i]); return parent[i] }() }
            for i in variants.indices {
                for j in variants.indices where j > i && Self.linked(variants[i], variants[j]) {
                    parent[root(j)] = root(i)
                }
            }

            var clusters: [Int: [AlbumVariant]] = [:]
            for i in variants.indices { clusters[root(i), default: []].append(variants[i]) }
            for cluster in clusters.values where cluster.count > 1 {
                let suggested = cluster.max {
                    $0.tracks.count != $1.tracks.count ? $0.tracks.count < $1.tracks.count
                                                       : $0.title.count > $1.title.count
                }!.title
                groups.append(SimilarAlbumGroup(
                    albumArtist: cluster[0].tracks[0].effectiveAlbumArtist,
                    variants: cluster.sorted { $0.tracks.count > $1.tracks.count },
                    suggested: suggested, sharedSongs: Self.sharedSongs(cluster)))
            }
        }
        return groups.sorted { ($0.albumArtist, $0.suggested) < ($1.albumArtist, $1.suggested) }
    }

    // MARK: Matching

    static func linked(_ a: AlbumVariant, _ b: AlbumVariant) -> Bool {
        let x = base(a.title), y = base(b.title)
        guard x == y || isTypo(x, y) else { return false }
        let sa = songKeys(a), sb = songKeys(b)
        let smaller = min(sa.count, sb.count)
        guard smaller > 0 else { return false }
        let shared = sa.filter { k in sb.contains { songMatch(k, $0) } }.count
        return Double(shared) / Double(smaller) >= 0.5
    }

    /// Title without edition notes: lowercase, no (…) or […], letters and digits only.
    static func base(_ title: String) -> String {
        var s = title.lowercased()
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let kept = s.folding(options: .diacriticInsensitive, locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(kept)).split(separator: " ").joined(separator: " ")
    }

    /// One letter added, dropped or changed. Names with digits never count
    /// ("Pt. 1" / "Pt. 2" are different albums) and very short names are too
    /// easily confused.
    static func isTypo(_ a: String, _ b: String) -> Bool {
        guard a != b, a.count >= 6, b.count >= 6, abs(a.count - b.count) <= 1,
              !a.contains(where: \.isNumber), !b.contains(where: \.isNumber) else { return false }
        let x = Array(a), y = Array(b)
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
        if x.count == y.count { return Array(x[(i + 1)...]) == Array(y[(i + 1)...]) }
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        return Array(long[(i + 1)...]) == Array(short[i...])
    }

    static func songKeys(_ v: AlbumVariant) -> [String] {
        v.tracks.map { Duplicates.normalise($0.effectiveTitle) }.filter { !$0.isEmpty }
    }

    /// "bleed" matches "bleed omar apollo": one is the other plus extra credits.
    static func songMatch(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + " ") || b.hasPrefix(a + " ")
    }

    static func sharedSongs(_ cluster: [AlbumVariant]) -> Int {
        var seen: [String: Set<String>] = [:]
        for v in cluster { for k in Set(songKeys(v)) { seen[k, default: []].insert(v.title) } }
        return seen.values.filter { $0.count > 1 }.count
    }
}
