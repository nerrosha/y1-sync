import Foundation

/// A problem with how an album is tagged, rather than with an individual file.
public enum AlbumIssue: Sendable, Hashable {
    /// Tracks of one album disagree about the album artist, so the device
    /// splits them across several folders.
    case splitAlbumArtist(values: [String])
    /// No track numbers, so the browser falls back to alphabetical order.
    case missingTrackNumbers(count: Int)
    /// Two tracks claim the same position.
    case duplicateTrackNumbers([Int])
    /// Numbering has holes — often a partial rip or a missing download.
    case incompleteNumbering(missing: [Int], highest: Int)
    /// No embedded art and no cover file to fall back on.
    case noArtwork

    public var describe: String {
        switch self {
        case .splitAlbumArtist(let values):
            return "album artist disagrees across tracks (\(values.joined(separator: " / "))) — "
                 + "the album will split into separate folders"
        case .missingTrackNumbers(let count):
            return "\(count) track(s) have no track number — they will sort alphabetically"
        case .duplicateTrackNumbers(let numbers):
            return "duplicate track number(s): \(numbers.map(String.init).joined(separator: ", "))"
        case .incompleteNumbering(let missing, let highest):
            let shown = missing.prefix(8).map(String.init).joined(separator: ", ")
            let extra = missing.count > 8 ? ", …" : ""
            return "missing track(s) \(shown)\(extra) of \(highest)"
        case .noArtwork:
            return "no cover art"
        }
    }
}

public struct AlbumReport: Sendable {
    public var albumArtist: String
    public var album: String
    public var trackCount: Int
    public var issues: [AlbumIssue]
    /// Suggested album artist when the tags disagree — the most common value.
    public var suggestedAlbumArtist: String?
}

/// Groups a library into albums and reports what would make browsing worse
/// on the device.
///
/// This matters more on the player than on a Mac: Rockbox navigates the
/// folder tree, so a mistagged album genuinely becomes several folders with
/// one track each, and unnumbered tracks genuinely play out of order.
public struct LibraryAudit: Sendable {
    public init() {}

    public func audit(_ tracks: [Track], artworkPresent: Set<String> = []) -> [AlbumReport] {
        // Group by album title alone, so that a split album artist can be
        // detected rather than hidden by the grouping.
        var groups: [String: [Track]] = [:]
        for t in tracks {
            groups[FATName.foldedKey(t.effectiveAlbum), default: []].append(t)
        }

        var reports: [AlbumReport] = []

        for (_, group) in groups {
            var issues: [AlbumIssue] = []

            let artists = group.map(\.effectiveAlbumArtist)
            let counts = artists.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            let distinct = Array(counts.keys).sorted()

            var suggested: String?
            if distinct.count > 1 {
                issues.append(.splitAlbumArtist(values: distinct))
                // A compilation legitimately varies the *track* artist, so
                // the winner is whichever album artist appears most often.
                suggested = counts.max { a, b in
                    a.value == b.value ? a.key > b.key : a.value < b.value
                }?.key
            }

            let numbered = group.compactMap(\.trackNumber).filter { $0 > 0 }
            let unnumbered = group.count - numbered.count
            if unnumbered > 0 {
                issues.append(.missingTrackNumbers(count: unnumbered))
            }

            if !numbered.isEmpty {
                let numCounts = numbered.reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
                let dupes = numCounts.filter { $0.value > 1 }.keys.sorted()
                if !dupes.isEmpty { issues.append(.duplicateTrackNumbers(dupes)) }

                // Only meaningful when the album looks fully numbered;
                // otherwise "missing" is just the unnumbered tracks again.
                if unnumbered == 0, let highest = numbered.max(), highest > 1 {
                    let present = Set(numbered)
                    let missing = (1...highest).filter { !present.contains($0) }
                    if !missing.isEmpty {
                        issues.append(.incompleteNumbering(missing: missing, highest: highest))
                    }
                }
            }

            let representative = group[0]
            let key = FATName.foldedKey(
                "\(representative.effectiveAlbumArtist)/\(representative.effectiveAlbum)")
            if !artworkPresent.contains(key) {
                issues.append(.noArtwork)
            }

            guard !issues.isEmpty else { continue }
            reports.append(AlbumReport(
                albumArtist: suggested ?? representative.effectiveAlbumArtist,
                album: representative.effectiveAlbum,
                trackCount: group.count,
                issues: issues,
                suggestedAlbumArtist: suggested
            ))
        }

        return reports.sorted {
            ($0.albumArtist, $0.album) < ($1.albumArtist, $1.album)
        }
    }

    /// A track whose own album tag disagrees with what most of its physical
    /// folder-mates say — the signature of a file that ended up mixed into
    /// someone else's folder while keeping its own, internally consistent
    /// tags. This is a different signal from `splitAlbumArtist` above: that
    /// one groups by *tag*, so it can never see a stray file, since a track
    /// with someone else's tags is, by definition, filed under that other
    /// album's group rather than flagged against the folder it actually sits
    /// in.
    public struct StrayTrack: Sendable, Identifiable {
        public var id: String { path }
        public var path: String
        public var taggedAlbum: String
        public var folderMajorityAlbum: String
        public var siblingCount: Int

        public var describe: String {
            "tagged as \"\(taggedAlbum)\" but sits among \(siblingCount) tracks "
            + "tagged \"\(folderMajorityAlbum)\" — check it's in the right place"
        }
    }

    /// Only checked when a folder has a clear majority album (more than half
    /// its tracks agree) — a folder that is a genuine grab-bag of many
    /// different albums has no majority to compare against, and flagging
    /// every track in it would just be noise.
    public func strayTracks(_ tracks: [Track], minimumSiblings: Int = 3) -> [StrayTrack] {
        var byFolder: [String: [Track]] = [:]
        for t in tracks {
            byFolder[t.sourceURL.deletingLastPathComponent().path, default: []].append(t)
        }

        var strays: [StrayTrack] = []
        for (_, siblings) in byFolder {
            guard siblings.count >= minimumSiblings else { continue }

            let counts = siblings.reduce(into: [String: Int]()) {
                $0[FATName.foldedKey($1.effectiveAlbum), default: 0] += 1
            }
            guard let majority = counts.max(by: { $0.value < $1.value }),
                  majority.value * 2 > siblings.count
            else { continue }

            let majorityLabel = siblings.first {
                FATName.foldedKey($0.effectiveAlbum) == majority.key
            }?.effectiveAlbum ?? majority.key

            for t in siblings where FATName.foldedKey(t.effectiveAlbum) != majority.key {
                strays.append(StrayTrack(
                    path: t.sourceURL.path, taggedAlbum: t.effectiveAlbum,
                    folderMajorityAlbum: majorityLabel, siblingCount: siblings.count))
            }
        }
        return strays.sorted { $0.path < $1.path }
    }

    /// Apply the audit's album-artist suggestion so an album lands in one
    /// folder. Only fills the grouping used for layout — the files on disk
    /// are never modified.
    public func unifyAlbumArtists(_ tracks: [Track], using reports: [AlbumReport]) -> [Track] {
        var fix: [String: String] = [:]
        for r in reports {
            if let suggested = r.suggestedAlbumArtist {
                fix[FATName.foldedKey(r.album)] = suggested
            }
        }
        guard !fix.isEmpty else { return tracks }

        return tracks.map { t in
            guard let name = fix[FATName.foldedKey(t.effectiveAlbum)] else { return t }
            var copy = t
            copy.albumArtist = name
            return copy
        }
    }
}
