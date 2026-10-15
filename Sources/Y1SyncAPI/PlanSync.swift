import Foundation
import Y1SyncCore

/// A comparison of the library with the player, with everything the window shows.
struct PlanContext {
    var player: API.Player
    var libraryTracks: [Track]
    var selected: [Track]
    var reports: [TrackReport]
    var albumIssues: [AlbumReport]
    var artists: [LibraryArtist]
    var plan: SyncPlan
    var pending: [String: Int]
    var excluded: Set<String>
    var freeBytes: Int64
}

extension API {
    func makeEngine(_ s: Settings, _ p: Player) -> SyncEngine {
        SyncEngine(artworkOptimizer: s.resizeArtwork ? ArtworkOptimizer(maxDimension: maxArt(for: p)) : nil)
    }

    /// Emits at most a handful of progress lines per second.
    func throttledProgress(_ label: String) -> @Sendable (Int, Int) -> Void {
        let emitter = self.emitter
        let step = 20
        return { done, total in
            guard done == total || done % step == 0 else { return }
            emitter.progress(total > 0 ? Double(done) / Double(total) : nil, "\(label) \(done) of \(total)")
        }
    }

    // MARK: - Plan

    func makePlan(_ a: JSON) async throws -> PlanContext {
        let s = settings.load()
        guard let folder = s.libraryFolder, !folder.isEmpty else {
            throw APIError("Choose your music folder first.")
        }
        let library = URL(fileURLWithPath: folder)
        guard FileManager.default.fileExists(atPath: library.path) else {
            throw APIError("The music folder \(folder) was not found.")
        }
        let p = try player(a)

        let cache = ScanCache(root: library)
        let found = await LibraryScanner(formats: p.firmware.formats)
            .scan(root: library, cache: cache, progress: throttledProgress("Reading tags…"))
        guard !found.isEmpty else { throw APIError("No supported audio files in that folder.") }

        emitter.progress(nil, "Checking files…")
        let checked = await TrackHealth(maxEmbeddedArtPixels: maxArt(for: p), limits: s.limits)
            .checkAll(found, cache: cache)

        // Merges the user made on the player apply here too, so the plan matches
        // the player and the old spellings are not copied back.
        let playable = MergeRules.apply(s.mergeRules, to: checked.filter(\.isPlayable).map(\.track))
        let ruled = Dictionary(playable.map { ($0.sourceURL, $0) }, uniquingKeysWith: { a, _ in a })
        var withArt: Set<String> = []
        for r in checked where r.hasEmbeddedArt {
            let t = ruled[r.track.sourceURL] ?? r.track
            withArt.insert(FATName.foldedKey("\(t.effectiveAlbumArtist)/\(t.effectiveAlbum)"))
        }

        let audit = LibraryAudit()
        let albumIssues = audit.audit(playable, artworkPresent: withArt)
        let libraryTracks = audit.unifyAlbumArtists(playable, using: albumIssues)
        let artists = SyncSelection.group(libraryTracks)
        let excluded = Set(s.excludedAlbums)
        let selected = SyncSelection.filter(libraryTracks, excluding: excluded)

        emitter.progress(nil, "Looking at the player…")
        let onDevice = makeEngine(s, p).scanDevice(root: p.root)
        let planner = SyncPlanner()
        let pending = SyncSelection.pendingCounts(in: planner.plan(library: libraryTracks, deviceFiles: onDevice))
        let plan = planner.plan(library: selected, deviceFiles: onDevice)

        let free = (try? p.root.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init)
            ?? DeviceFinder().candidates().first { $0.url.standardizedFileURL.path == p.root.standardizedFileURL.path }?.freeBytes
            ?? 0
        return PlanContext(player: p, libraryTracks: libraryTracks, selected: selected, reports: checked,
                           albumIssues: albumIssues, artists: artists, plan: plan, pending: pending,
                           excluded: excluded, freeBytes: free)
    }

    static func reasonText(_ r: SyncAction.Reason) -> String? {
        switch r {
        case .new: nil
        case .truncated: "cut off — will be replaced"
        case .changed: "differs from the library"
        }
    }

    func plan(_ a: JSON) async throws -> JSON {
        let c = try await makePlan(a)
        emitter.progress(1, "Done")
        return planJSON(c)
    }

    func planJSON(_ c: PlanContext) -> JSON {
        let report = SyncReport(plan: c.plan)
        let broken = c.reports.filter { !$0.isPlayable }
        let warned = c.reports.filter { $0.isPlayable && !$0.issues.isEmpty }
        let selectedAlbums = c.artists.flatMap(\.albums).filter { !c.excluded.contains($0.id) }.count
        let albumCount = c.artists.flatMap(\.albums).count

        let artists = c.artists.map { artist -> JSON in
            ["id": artist.id, "name": artist.name, "albums": artist.albums.map { al -> JSON in
                ["id": al.id, "title": al.title, "artist": al.artist, "trackCount": al.trackCount,
                 "bytes": al.bytes, "included": !c.excluded.contains(al.id), "pending": c.pending[al.id] ?? 0]
            }]
        }
        let actions = c.plan.actions.prefix(400).map { act -> JSON in
            var j: JSON = ["devicePath": act.devicePath, "kind": act.kind == .replace ? "replace" : "copy"]
            if let why = API.reasonText(act.reason) { j["why"] = why }
            return j
        }
        let albums = report.albums.map { al -> JSON in
            ["artist": al.artist, "album": al.album, "added": al.added, "replaced": al.replaced,
             "bytes": al.bytes, "reasons": al.reasons.sorted()]
        }
        let brokenJSON = broken.map { r -> JSON in
            ["name": r.track.sourceURL.lastPathComponent, "path": r.track.sourceURL.path,
             "reasons": r.issues.filter(\.isBlocking).map(\.describe)]
        }
        let warnedJSON = warned.map { r -> JSON in
            ["name": r.track.sourceURL.lastPathComponent, "notes": r.issues.map(\.describe)]
        }
        let albumIssuesJSON = c.albumIssues.filter { !$0.issues.isEmpty }.map { r -> JSON in
            ["artist": r.albumArtist, "album": r.album, "notes": r.issues.map(\.describe)]
        }
        let collisions = c.plan.collisions.map { (path, tracks) -> JSON in
            ["path": path, "count": tracks.count]
        }
        return [
            "player": ["name": c.player.name, "path": c.player.root.path, "firmware": c.player.firmware.rawValue,
                       "freeBytes": c.freeBytes] as JSON,
            "stats": ["toCopy": c.plan.actions.count, "albums": albumCount, "selectedAlbums": selectedAlbums,
                      "bytesToCopy": c.plan.bytesToCopy, "freeBytes": c.freeBytes,
                      "alreadyThere": c.plan.upToDate.count, "broken": broken.count,
                      "added": report.added, "replaced": report.replaced,
                      "renamedByMerges": c.selected.filter { !$0.tagEdits.isEmpty }.count] as JSON,
            "notEnoughSpace": c.plan.bytesToCopy > c.freeBytes && !c.plan.actions.isEmpty,
            "artists": artists, "report": albums, "actions": actions,
            "actionsTotal": c.plan.actions.count, "broken": brokenJSON, "warnings": warnedJSON,
            "albumIssues": albumIssuesJSON, "collisions": collisions,
            "text": report.text,
        ]
    }

    // MARK: - Sync

    static func progressText(_ p: SyncProgress, elapsed: TimeInterval) -> String {
        var text = "\(min(p.completed + 1, p.total)) of \(p.total)"
        if elapsed > 3, p.bytesCopied > 0 {
            let speed = Double(p.bytesCopied) / elapsed
            text += " · \(ByteFormat.string(Int64(speed)))/s"
            let left = Double(p.bytesTotal - p.bytesCopied) / speed
            if elapsed > 8 {
                if left < 90 { text += " · under a minute left" }
                else {
                    let minutes = Int((left / 60).rounded())
                    text += minutes < 60 ? " · about \(minutes) min left"
                                         : " · about \(minutes / 60) h \(minutes % 60) min left"
                }
            }
        }
        return text
    }

    func sync(_ a: JSON) async throws -> JSON {
        let s = settings.load()
        let c = try await makePlan(a)
        let p = c.player
        if c.plan.actions.isEmpty && s.playlistName.trimmingCharacters(in: .whitespaces).isEmpty {
            return ["copied": 0, "replaced": 0, "failed": [JSON](), "bytesCopied": 0, "cancelled": false,
                    "summary": "Everything selected is already on the player.", "changes": [JSON](), "verified": 0]
        }

        let engine = makeEngine(s, p)
        let started = Date()
        let emitter = self.emitter, stop = self.stop
        let result: SyncResult
        do {
            result = try engine.execute(plan: c.plan, deviceRoot: p.root, progress: { pr in
                emitter.progress(pr.bytesTotal > 0 ? Double(pr.bytesCopied) / Double(pr.bytesTotal) : 1,
                                 API.progressText(pr, elapsed: Date().timeIntervalSince(started)))
            }, cancel: { stop.isSet })
        } catch let e as DeviceError {
            throw APIError(e.description)
        }

        let name = s.playlistName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !result.cancelled {
            _ = try? PlaylistWriter().write(name: name, tracks: c.selected, deviceRoot: p.root)
        }

        var changes = result.changes
        await enrichAfterSync(c, s, &changes)

        // The player lists songs from its own saved list, not the card.
        var listNote = ""
        let copied = Set(result.changes.map(\.devicePath))
        let pairs = c.plan.actions.filter { copied.contains($0.devicePath) }.map { (track: $0.track, devicePath: $0.devicePath) }
        if let u = try? PlayerLibraryCache.update(deviceRoot: p.root, adding: pairs, dropDeadEntries: false), u.added > 0 {
            listNote = "Added \(u.added) to the player's song list."
        }

        var summary = result.cancelled ? "Stopped. Copied \(result.copied)" : "Copied \(result.copied)"
        if result.replaced > 0 { summary += ", replaced \(result.replaced)" }
        summary += " — \(ByteFormat.string(result.bytesCopied)) written."
        if result.artworkShrunk > 0 { summary += " Resized art on \(result.artworkShrunk) file(s)." }
        if !result.failed.isEmpty { summary += " \(result.failed.count) failed." }
        if result.verified > 0 { summary += " Every copied file was read back from the player and matched." }
        if !listNote.isEmpty { summary += " " + listNote }

        return [
            "copied": result.copied, "replaced": result.replaced, "bytesCopied": result.bytesCopied,
            "artworkShrunk": result.artworkShrunk, "verified": result.verified, "cancelled": result.cancelled,
            "failed": result.failed.map { ["path": $0.path, "error": $0.error] as JSON },
            "summary": summary, "listNote": listNote,
            "changes": changes.map { ch -> JSON in
                ["devicePath": ch.devicePath, "title": ch.title, "artist": ch.artist, "album": ch.album,
                 "replaced": ch.wasReplaced, "notes": ch.summary, "lyrics": ch.lyricsAdded, "cover": ch.coverFetched]
            },
        ]
    }

    /// Lyrics and missing covers for what was just copied (both are opt-in).
    func enrichAfterSync(_ c: PlanContext, _ s: Settings, _ changes: inout [FileChange]) async {
        guard s.fetchLyrics || s.fetchCovers else { return }
        let enricher = Enricher(maxArtDimension: maxArt(for: c.player))
        let all = c.selected
        let root = c.player.root
        let emitter = self.emitter

        if s.fetchCovers {
            let selectedKeys = Set(all.map(SyncSelection.albumKey(for:)))
            let missing = Set(c.albumIssues.filter { $0.issues.contains(.noArtwork) }
                .map { FATName.foldedKey("\($0.albumArtist)/\($0.album)") }).intersection(selectedKeys)
            if !missing.isEmpty {
                emitter.progress(nil, "Looking up album art…")
                let r = await enricher.addCovers(for: all, albumsMissingArt: missing, deviceRoot: root)
                if r.coversEmbedded > 0 {
                    let fixed = Set(all.filter {
                        missing.contains(FATName.foldedKey("\($0.effectiveAlbumArtist)/\($0.effectiveAlbum)"))
                    }.map(\.effectiveAlbum))
                    for i in changes.indices where fixed.contains(changes[i].album) { changes[i].coverFetched = true }
                }
            }
        }
        if s.fetchLyrics {
            _ = await enricher.addLyrics(for: all, deviceRoot: root) { done, total, title in
                emitter.progress(total > 0 ? Double(done) / Double(total) : 1, "Lyrics \(done)/\(total) — \(title)")
            }
            for i in changes.indices {
                let audio = root.appendingPathComponent(changes[i].devicePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                changes[i].lyricsAdded = FileManager.default.fileExists(
                    atPath: audio.deletingPathExtension().appendingPathExtension("lrc").path)
            }
        }
    }
}
