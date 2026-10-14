import Foundation

/// One album in the library, as offered in the "choose what to sync" list.
public struct LibraryAlbum: Sendable, Hashable, Identifiable {
    /// Stable selection key — see `SyncSelection.albumKey(for:)`.
    public var id: String
    public var artist: String
    public var title: String
    public var trackCount: Int
    public var bytes: Int64

    public init(id: String, artist: String, title: String, trackCount: Int, bytes: Int64) {
        self.id = id
        self.artist = artist
        self.title = title
        self.trackCount = trackCount
        self.bytes = bytes
    }
}

/// An album artist and their albums, for the grouped selection list.
public struct LibraryArtist: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var albums: [LibraryAlbum]

    public init(id: String, name: String, albums: [LibraryAlbum]) {
        self.id = id
        self.name = name
        self.albums = albums
    }

    public var trackCount: Int { albums.reduce(0) { $0 + $1.trackCount } }
    public var bytes: Int64 { albums.reduce(0) { $0 + $1.bytes } }
}

/// Choosing a subset of the library to put on the player.
///
/// The selection is stored as the set of albums the user switched *off*,
/// not the ones switched on: an album added to the library later should
/// sync by default rather than silently never reach the player.
///
/// Excluding an album only stops it being copied — nothing already on the
/// player is ever removed because of it.
public enum SyncSelection {
    /// Key identifying the album a track belongs to. Uses the same
    /// album-artist/album pair the device layout groups folders by, folded
    /// the way FAT compares names, so it survives case-only tag differences.
    ///
    /// Compute it on tracks *after* album-artist unification, so every track
    /// of a compilation shares one key.
    public static func albumKey(for track: Track) -> String {
        FATName.foldedKey("\(track.effectiveAlbumArtist)/\(track.effectiveAlbum)")
    }

    public static func artistKey(for track: Track) -> String {
        FATName.foldedKey(track.effectiveAlbumArtist)
    }

    /// Group tracks into artists → albums, both sorted the way Finder sorts
    /// names ("2 Unlimited" before "10cc", case-insensitive).
    public static func group(_ tracks: [Track]) -> [LibraryArtist] {
        struct AlbumAcc { var artist: String; var title: String; var count = 0; var bytes: Int64 = 0 }

        var albums: [String: AlbumAcc] = [:]
        var albumsByArtist: [String: Set<String>] = [:]
        var artistName: [String: String] = [:]

        for t in tracks {
            let aKey = albumKey(for: t)
            let rKey = artistKey(for: t)
            var acc = albums[aKey] ?? AlbumAcc(artist: t.effectiveAlbumArtist, title: t.effectiveAlbum)
            acc.count += 1
            acc.bytes += t.fileSize
            albums[aKey] = acc
            albumsByArtist[rKey, default: []].insert(aKey)
            if artistName[rKey] == nil { artistName[rKey] = t.effectiveAlbumArtist }
        }

        let before: (String, String) -> Bool = {
            $0.localizedStandardCompare($1) == .orderedAscending
        }

        return albumsByArtist.map { rKey, keys in
            let list = keys.compactMap { k -> LibraryAlbum? in
                guard let a = albums[k] else { return nil }
                return LibraryAlbum(id: k, artist: a.artist, title: a.title,
                                    trackCount: a.count, bytes: a.bytes)
            }
            .sorted { before($0.title, $1.title) }
            return LibraryArtist(id: rKey, name: artistName[rKey] ?? rKey, albums: list)
        }
        .sorted { before($0.name, $1.name) }
    }

    /// The tracks that remain once the excluded albums are taken out.
    public static func filter(_ tracks: [Track], excluding excluded: Set<String>) -> [Track] {
        guard !excluded.isEmpty else { return tracks }
        return tracks.filter { !excluded.contains(albumKey(for: $0)) }
    }

    /// How many tracks of each album still need copying, keyed by album key.
    /// Lets the picker show "3 new" next to an album.
    public static func pendingCounts(in plan: SyncPlan) -> [String: Int] {
        var out: [String: Int] = [:]
        for action in plan.actions {
            out[albumKey(for: action.track), default: 0] += 1
        }
        return out
    }
}
