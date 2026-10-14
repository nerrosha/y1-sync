import Foundation

/// What a sync would do, grouped by album — the "show me before you write" view.
public struct SyncReport: Sendable {
    public struct Album: Sendable, Identifiable {
        public var id: String { "\(artist)/\(album)" }
        public var artist: String
        public var album: String
        public var added = 0
        public var replaced = 0
        public var bytes: Int64 = 0
        /// Why files on the player are being replaced, e.g. "cut off".
        public var reasons: Set<String> = []
    }

    public var albums: [Album]
    public var added: Int
    public var replaced: Int
    public var bytes: Int64
    /// Tracks already on the player, left alone.
    public var unchanged: Int

    public init(plan: SyncPlan) {
        var map: [String: Album] = [:]
        var added = 0, replaced = 0
        for a in plan.actions {
            let artist = a.track.effectiveAlbumArtist, album = a.track.effectiveAlbum
            var entry = map["\(artist)/\(album)"] ?? Album(artist: artist, album: album)
            entry.bytes += a.track.fileSize
            if a.kind == .replace {
                entry.replaced += 1; replaced += 1
                entry.reasons.insert(Self.reason(a.reason))
            } else {
                entry.added += 1; added += 1
            }
            map["\(artist)/\(album)"] = entry
        }
        albums = map.values.sorted {
            ($0.artist.lowercased(), $0.album.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased())
        }
        self.added = added
        self.replaced = replaced
        bytes = plan.bytesToCopy
        unchanged = plan.upToDate.count
    }

    static func reason(_ r: SyncAction.Reason) -> String {
        switch r {
        case .new: "new"
        case .truncated: "cut off"
        case .changed: "differs from the library"
        }
    }

    /// Plain-text version, for pasting or saving.
    public var text: String {
        var lines = ["Y1 Sync — what would change", ""]
        lines.append("Add \(added) track(s), replace \(replaced), \(ByteFormat.string(bytes)) to write; "
                     + "\(unchanged) already on the player. Nothing is deleted.")
        lines.append("")
        for a in albums {
            var line = "\(a.artist) — \(a.album): "
            var parts: [String] = []
            if a.added > 0 { parts.append("+\(a.added)") }
            if a.replaced > 0 { parts.append("replace \(a.replaced) (\(a.reasons.sorted().joined(separator: ", ")))") }
            line += parts.joined(separator: ", ") + " · \(ByteFormat.string(a.bytes))"
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// What a tidy would do, with the renames that cannot happen called out in advance.
public struct TidyPreview: Sendable {
    public struct FolderMove: Sendable, Identifiable {
        public var id: String { "\(from) → \(to)" }
        public var from: String
        public var to: String
        public var count: Int
        /// How many of them would be refused because the target file exists.
        public var blocked: Int
    }

    public var folders: [FolderMove]
    /// Renames whose destination is already taken (the same song stored twice).
    public var blocked: [TidyAction]

    public init(plan: TidyPlan, deviceRoot: URL) {
        let fm = FileManager.default
        var blocked: [TidyAction] = []
        var seen = Set<String>()
        var groups: [String: FolderMove] = [:]
        var order: [String] = []

        for m in plan.moves {
            guard case .move(let to) = m.kind else { continue }
            let key = FATName.foldedKey(to)
            let full = deviceRoot.appendingPathComponent(to.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            let taken = fm.fileExists(atPath: full.path) || !seen.insert(key).inserted
            if taken { blocked.append(m) }

            let f = (m.path as NSString).deletingLastPathComponent
            let t = (to as NSString).deletingLastPathComponent
            let gid = "\(f) → \(t)"
            if groups[gid] == nil { groups[gid] = FolderMove(from: f, to: t, count: 0, blocked: 0); order.append(gid) }
            groups[gid]!.count += 1
            if taken { groups[gid]!.blocked += 1 }
        }
        folders = order.compactMap { groups[$0] }
        self.blocked = blocked
    }
}
