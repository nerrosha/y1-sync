import Foundation

/// A set of files that appear to be the same song.
public struct DuplicateGroup: Sendable, Identifiable {
    public var id: String { key }
    /// Normalised artist+title the group was matched on.
    public var key: String
    public var tracks: [Track]

    public init(key: String, tracks: [Track]) {
        self.key = key
        self.tracks = tracks
    }

    /// The one worth keeping: lossless over lossy, then largest file (a proxy
    /// for quality), then best-tagged. That last tiebreak matters more than it
    /// looks: exact duplicates are often byte-for-byte identical rips, so the
    /// first two comparisons are ties and the choice would otherwise fall to
    /// whatever order the scan happened to return files in — silently
    /// keeping a copy mistagged into the wrong artist/album folder over the
    /// correctly tagged one.
    public var recommendedKeeper: Track? { keeper(limits: .none) }

    /// Same choice, but a copy the player can play always beats one it cannot
    /// (a 192 kHz file the player rejects must never be kept over a playable one).
    public func keeper(limits: PlayerLimits) -> Track? {
        tracks.max { a, b in
            let aOK = limits.problem(for: a) == nil ? 1 : 0
            let bOK = limits.problem(for: b) == nil ? 1 : 0
            if aOK != bOK { return aOK < bOK }
            let aLossless = Duplicates.isLossless(a) ? 1 : 0
            let bLossless = Duplicates.isLossless(b) ? 1 : 0
            if aLossless != bLossless { return aLossless < bLossless }
            if a.fileSize != b.fileSize { return a.fileSize < b.fileSize }
            return DuplicateGroup.tagCompleteness(a) < DuplicateGroup.tagCompleteness(b)
        }
    }

    /// How many of the fields that matter for on-device browsing are actually
    /// present, rather than falling back to "Unknown Album" etc.
    static func tagCompleteness(_ t: Track) -> Int {
        var score = 0
        if t.album.flatMap(Track.nonBlank) != nil { score += 1 }
        if t.albumArtist.flatMap(Track.nonBlank) != nil { score += 1 }
        if t.artist.flatMap(Track.nonBlank) != nil { score += 1 }
        if t.title.flatMap(Track.nonBlank) != nil { score += 1 }
        if t.trackNumber != nil { score += 1 }
        return score
    }

    /// The one worth keeping, for duplicates found already sitting on the
    /// device: same quality tiebreak as `recommendedKeeper`, but before
    /// falling back to tag completeness it prefers whichever copy already
    /// lives at the path its own tags say it should — a copy left behind in
    /// its pre-tidy folder because `DeviceTidy` found the correct spot
    /// already taken by its twin. Tags are frequently byte-identical between
    /// exact duplicates (same rip copied twice), which makes tag
    /// completeness a no-op tiebreak in exactly this situation; without this,
    /// the choice falls to scan order and can recommend deleting the
    /// well-organised copy while keeping the stray one, leaving the library
    /// worse until the user notices and re-runs tidy.
    public func recommendedKeeper(onDeviceRoot deviceRoot: URL, layout: DeviceLayout = DeviceLayout(),
                                  limits: PlayerLimits = .none) -> Track? {
        tracks.max { a, b in
            let aOK = limits.problem(for: a) == nil ? 1 : 0
            let bOK = limits.problem(for: b) == nil ? 1 : 0
            if aOK != bOK { return aOK < bOK }
            let aLossless = Duplicates.isLossless(a) ? 1 : 0
            let bLossless = Duplicates.isLossless(b) ? 1 : 0
            if aLossless != bLossless { return aLossless < bLossless }
            if a.fileSize != b.fileSize { return a.fileSize < b.fileSize }

            let aTidy = Self.isAtTidyLocation(a, deviceRoot: deviceRoot, layout: layout) ? 1 : 0
            let bTidy = Self.isAtTidyLocation(b, deviceRoot: deviceRoot, layout: layout) ? 1 : 0
            if aTidy != bTidy { return aTidy < bTidy }

            return Self.tagCompleteness(a) < Self.tagCompleteness(b)
        }
    }

    private static func isAtTidyLocation(_ track: Track, deviceRoot: URL, layout: DeviceLayout) -> Bool {
        let expected = layout.path(for: track)
        let actual = SyncEngine().devicePath(of: track.sourceURL, root: deviceRoot)
        return FATName.foldedKey(expected) == FATName.foldedKey(actual)
    }

    /// Whether removing the extras can be done without asking: every copy is
    /// the same song on the same album (a copy with no album tag counts as
    /// belonging to it), and the copy kept is one the player can play. The
    /// same song on a single and on an album, or on a compilation, is left
    /// for the user — those are placements they may want both of.
    public func isSafeToAutoClean(deviceRoot: URL? = nil, limits: PlayerLimits = .none) -> Bool {
        let albums = Set(tracks.compactMap { t -> String? in
            guard t.album.flatMap(Track.nonBlank) != nil else { return nil }
            return Duplicates.normalise(t.effectiveAlbum)
        })
        guard albums.count <= 1 else { return false }
        let artists = Set(tracks.map { Duplicates.normalise($0.effectiveAlbumArtist) })
        guard artists.count == 1 else { return false }
        let kept = deviceRoot.map { recommendedKeeper(onDeviceRoot: $0, limits: limits) } ?? keeper(limits: limits)
        guard let kept, limits.problem(for: kept) == nil else { return false }
        return true
    }

    /// Bytes freed when only the keeper stays, for the given limits.
    public func wastedBytes(limits: PlayerLimits) -> Int64 {
        let kept = keeper(limits: limits)
        return tracks.filter { $0.sourceURL != kept?.sourceURL }.reduce(0) { $0 + $1.fileSize }
    }

    public var wastedBytes: Int64 {
        let keeper = recommendedKeeper
        return tracks.filter { $0.sourceURL != keeper?.sourceURL }
                     .reduce(0) { $0 + $1.fileSize }
    }
}

/// Finds the same song stored more than once.
///
/// Matching is on normalised artist + title rather than bytes: the usual case
/// is the same track from two different rips or formats, which are never
/// byte-identical but are still duplicates to a listener.
public struct Duplicates: Sendable {
    /// Treat tracks as the same song only if their durations are within this
    /// many seconds. Guards against a short intro and a full song sharing a
    /// title, and against live versions colliding with studio ones.
    public var durationTolerance: Double

    public init(durationTolerance: Double = 5) {
        self.durationTolerance = durationTolerance
    }

    static let losslessFormats: Set<String> = ["flac", "wv", "ape", "aiff", "aif", "wav"]

    public static func isLossless(_ track: Track) -> Bool {
        losslessFormats.contains(track.fileExtension)
    }

    /// Words inside brackets that mark a genuinely different recording. A
    /// live take is not a duplicate of the studio version, so brackets
    /// containing any of these are kept rather than stripped.
    static let versionMarkers: Set<String> = [
        "live", "acoustic", "remix", "demo", "instrumental", "edit", "version",
        "mix", "reprise", "unplugged", "radio", "extended", "cover", "session",
        "alternate", "rework", "intro", "outro", "interlude", "skit",
    ]

    /// Strip case, punctuation, and decorations that hide real duplicates —
    /// "(Remastered 2011)", "[Explicit]", "feat. X" — while preserving
    /// anything that marks a different recording.
    public static func normalise(_ s: String) -> String {
        var text = s.lowercased()

        for pattern in [#"\(([^)]*)\)"#, #"\[([^\]]*)\]"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            var result = ""
            var last = text.startIndex
            let ns = text as NSString

            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(match.range, in: text),
                      let inner = Range(match.range(at: 1), in: text) else { continue }
                let words = Set(text[inner].split(separator: " ").map(String.init))

                result += text[last..<range.lowerBound]
                // Keep the bracket contents when they name a distinct version.
                if !words.isDisjoint(with: versionMarkers) {
                    result += " " + text[inner] + " "
                } else {
                    result += " "
                }
                last = range.upperBound
            }
            result += text[last...]
            text = result
        }

        for noise in ["feat.", "featuring", "ft.", " - remaster", "remastered",
                      "explicit", "official audio", "official video", "hd", "hq"] {
            text = text.replacingOccurrences(of: noise, with: " ")
        }

        let kept = text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
        return String(String.UnicodeScalarView(kept))
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    public func find(in tracks: [Track]) -> [DuplicateGroup] {
        var buckets: [String: [Track]] = [:]
        for t in tracks {
            let key = "\(Self.normalise(t.effectiveArtist))|\(Self.normalise(t.effectiveTitle))"
            guard key != "|" else { continue }   // nothing to match on
            buckets[key, default: []].append(t)
        }

        var groups: [DuplicateGroup] = []
        for (key, candidates) in buckets where candidates.count > 1 {
            // Split a bucket further by duration so a 30-second interlude
            // sharing a name with the full track is not called a duplicate.
            for cluster in clusterByDuration(candidates) where cluster.count > 1 {
                groups.append(DuplicateGroup(key: key, tracks: cluster))
            }
        }
        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    func clusterByDuration(_ tracks: [Track]) -> [[Track]] {
        // Tracks with no known duration cannot be split apart safely, so they
        // stay together and are judged on name alone.
        let unknown = tracks.filter { $0.durationSeconds == nil }
        let known = tracks.filter { $0.durationSeconds != nil }
            .sorted { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }

        var clusters: [[Track]] = []
        for track in known {
            if var last = clusters.last,
               let anchor = last.first?.durationSeconds,
               abs((track.durationSeconds ?? 0) - anchor) <= durationTolerance {
                last.append(track)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([track])
            }
        }

        if !unknown.isEmpty {
            if clusters.isEmpty { clusters.append(unknown) }
            else { clusters[0].append(contentsOf: unknown) }
        }
        return clusters
    }
}
