import Foundation

/// One spelling of an artist name, with the tracks filed under it.
public struct ArtistVariant: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var tracks: [Track]
}

/// One artist whose name is spelled more than one way — "The Smashing Pumpkins"
/// and "Smashing Pumpkins", "Sombr" and "sombr" — so the player lists them twice
/// and the card gets a folder for each.
public struct SimilarArtistGroup: Sendable, Identifiable {
    public var id: String { variants.map(\.name).sorted().joined(separator: "|") }
    public var variants: [ArtistVariant]
    public var suggested: String
    public var trackCount: Int { variants.reduce(0) { $0 + $1.tracks.count } }
}

/// Finds artists filed under several spellings of the same name.
///
/// Names count as the same when they match after ignoring case, accents,
/// punctuation and a leading "The" — safe on its own. A one-letter typo is only
/// believed when the two also share an album title, so "Lil Peep" and
/// "Lil Pump" are never joined.
public struct SimilarArtists: Sendable {
    public init() {}

    public func find(in tracks: [Track]) -> [SimilarArtistGroup] {
        var byName: [String: [Track]] = [:]
        for t in tracks { byName[t.effectiveAlbumArtist, default: []].append(t) }
        let variants = byName.map { ArtistVariant(name: $0.key, tracks: $0.value) }.sorted { $0.name < $1.name }

        var parent = Array(variants.indices)
        func root(_ i: Int) -> Int { parent[i] == i ? i : { parent[i] = root(parent[i]); return parent[i] }() }
        for i in variants.indices {
            for j in variants.indices where j > i && Self.same(variants[i], variants[j]) {
                parent[root(j)] = root(i)
            }
        }
        var clusters: [Int: [ArtistVariant]] = [:]
        for i in variants.indices { clusters[root(i), default: []].append(variants[i]) }

        return clusters.values.filter { $0.count > 1 }.map { cluster in
            let best = cluster.max {
                $0.tracks.count != $1.tracks.count ? $0.tracks.count < $1.tracks.count
                    // On a tie prefer the properly capitalised spelling.
                    : ($0.name == $0.name.lowercased()) && ($1.name != $1.name.lowercased())
            }!
            return SimilarArtistGroup(variants: cluster.sorted { $0.tracks.count > $1.tracks.count }, suggested: best.name)
        }.sorted { $0.suggested < $1.suggested }
    }

    static func base(_ name: String) -> String {
        var s = SimilarAlbums.base(name)
        if s.hasPrefix("the ") { s.removeFirst(4) }
        return s
    }

    static func same(_ a: ArtistVariant, _ b: ArtistVariant) -> Bool {
        let x = base(a.name), y = base(b.name)
        if x == y, !x.isEmpty { return true }
        guard SimilarAlbums.isTypo(x, y) else { return false }
        let albumsA = Set(a.tracks.map { SimilarAlbums.base($0.effectiveAlbum) })
        return b.tracks.contains { albumsA.contains(SimilarAlbums.base($0.effectiveAlbum)) }
    }
}
