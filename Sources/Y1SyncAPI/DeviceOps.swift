import Foundation
import Y1SyncCore

extension API {
    // MARK: - Reading the player

    func scanDevice(_ p: Player, label: String = "Reading the player…") async -> [Track] {
        await LibraryScanner().scan(root: p.root, cache: ScanCache(root: p.root),
                                    progress: throttledProgress(label))
    }

    /// After anything changed on the card: rescan and keep the player's own song list in step.
    func afterChange(_ p: Player) async -> String {
        let tracks = await scanDevice(p)
        guard !tracks.isEmpty,
              let r = try? PlayerLibraryCache.sync(deviceRoot: p.root, deviceTracks: tracks),
              r.added + r.removed > 0 else { return "" }
        return "Player's song list updated: \(r.added) added, \(r.removed) removed."
    }

    func iso(_ d: Date?) -> Any { d.map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull() }

    func deviceScan(_ a: JSON) async throws -> JSON {
        let p = try player(a)
        let s = settings.load()
        let found = await scanDevice(p)
        let undo = UndoLog.mostRecent(deviceRoot: p.root)
        var out: JSON = [
            "player": ["name": p.name, "path": p.root.path, "firmware": p.firmware.rawValue,
                       "detected": p.detected.rawValue, "chosen": p.overridden] as JSON,
            "trackCount": found.count,
            "mergeRules": settings.asJSON()["mergeRules"] ?? [],
            "limits": settings.asJSON()["limits"] ?? [:],
            "undo": undo.map { u -> JSON in
                ["label": u.label, "changes": u.entries.count, "date": iso(u.date)]
            } ?? NSNull(),
        ]
        guard !found.isEmpty else { out["empty"] = true; return out }

        emitter.progress(nil, "Working out what to tidy…")
        let tidy = DeviceTidy().plan(deviceRoot: p.root, tracks: found)
        let preview = TidyPreview(plan: tidy, deviceRoot: p.root)
        out["tidy"] = [
            "renames": tidy.moves.count, "junk": tidy.junk.count, "junkBytes": tidy.junkBytes,
            "emptyFolders": tidy.emptyDirectories.count, "leftovers": tidy.leftoverFolders.count,
            "blocked": preview.blocked.count,
            "folders": preview.folders.prefix(200).map { f -> JSON in
                ["from": f.from, "to": f.to, "count": f.count, "blocked": f.blocked]
            },
            "moveLines": tidy.moves.prefix(200).map(\.describe),
            "junkLines": tidy.junk.prefix(200).map(\.path),
            "removeJunk": s.removeJunk,
        ] as JSON

        if let list = PlayerLibraryCache.status(deviceRoot: p.root, deviceTracks: found) {
            out["songList"] = ["inSync": list.isInSync, "missing": list.missing.count,
                               "stale": list.stale.count, "cached": list.cached] as JSON
        }

        out["similarAlbums"] = SimilarAlbums().find(in: found).map { g -> JSON in
            ["id": g.id, "albumArtist": g.albumArtist, "suggested": g.suggested, "trackCount": g.trackCount,
             "sharedSongs": g.sharedSongs,
             "variants": g.variants.map { ["title": $0.title, "count": $0.tracks.count] as JSON }]
        }
        out["similarArtists"] = SimilarArtists().find(in: found).map { g -> JSON in
            ["id": g.id, "suggested": g.suggested, "trackCount": g.trackCount,
             "variants": g.variants.map { ["name": $0.name, "count": $0.tracks.count] as JSON }]
        }

        let engine = SyncEngine()
        out["duplicates"] = Duplicates().find(in: found).map { g -> JSON in
            let keeper = g.recommendedKeeper(onDeviceRoot: p.root, limits: s.limits)
            let paths = g.tracks.map { engine.devicePath(of: $0.sourceURL, root: p.root) }
            return ["id": dupeID(g, root: p.root), "title": g.tracks[0].effectiveTitle,
                    "artist": g.tracks[0].effectiveArtist,
                    "wasted": g.wastedBytes(limits: s.limits),
                    "safe": g.isSafeToAutoClean(deviceRoot: p.root, limits: s.limits),
                    "tracks": zip(g.tracks, paths).sorted { $0.0.fileSize > $1.0.fileSize }.map { (t, path) -> JSON in
                        ["path": path, "ext": t.fileExtension, "size": t.fileSize,
                         "keep": t.sourceURL == keeper?.sourceURL, "album": t.effectiveAlbum] as JSON
                    }]
        }

        let formats = PlayerLimits.summary(of: found).map { ["label": $0.label, "count": $0.count] as JSON }
        out["formats"] = formats
        out["flagged"] = found.filter { s.limits.problem(for: $0) != nil }.count

        let stats = ListeningStats(entries: ScrobbleLog.read(deviceRoot: p.root), deviceTracks: found)
        out["listening"] = [
            "plays": stats.plays, "seconds": stats.seconds, "first": iso(stats.first), "last": iso(stats.last),
            "topArtists": stats.topArtists.prefix(10).map { ["name": $0.name, "plays": $0.plays] as JSON },
            "topAlbums": stats.topAlbums.prefix(10).map { ["name": $0.name, "artist": $0.detail, "plays": $0.plays] as JSON },
            "albums": stats.leastListened(freeing: .max).map { al -> JSON in
                ["id": al.id, "artist": al.artist, "title": al.title, "bytes": al.bytes, "plays": al.plays,
                 "lastPlayed": iso(al.lastPlayed)]
            },
            "never": stats.albums.filter { $0.plays == 0 }.count, "albumCount": stats.albums.count,
        ] as JSON
        return out
    }

    func dupeID(_ g: DuplicateGroup, root: URL) -> String {
        let engine = SyncEngine()
        return stableID(g.key + "|" + g.tracks.map { engine.devicePath(of: $0.sourceURL, root: root) }.sorted().joined(separator: "\n"))
    }

    // MARK: - Tidy and song list

    func tidyApply(_ a: JSON) async throws -> JSON {
        let p = try player(a)
        let s = settings.load()
        if let remove = a.bool("removeJunk") { settings.update { $0.removeJunk = remove } }
        let found = await scanDevice(p)
        let plan = DeviceTidy().plan(deviceRoot: p.root, tracks: found)
        let emitter = self.emitter
        let r = DeviceTidy().apply(plan, deviceRoot: p.root, removeJunk: a.bool("removeJunk") ?? s.removeJunk) { done, total in
            emitter.progress(total > 0 ? Double(done) / Double(total) : 1, "\(done) of \(total)…")
        }
        var text = "Renamed \(r.moved), removed \(r.junkRemoved) junk file(s) (\(ByteFormat.string(r.bytesFreed))), "
            + "\(r.directoriesRemoved) empty folder(s), \(r.leftoverFoldersRemoved) leftover folder(s)"
            + (r.coversSalvaged > 0 ? " (\(r.coversSalvaged) cover(s) salvaged)" : "") + "."
        if !r.failures.isEmpty {
            let clashes = r.failures.filter { $0.hasSuffix("already exists") }.count
            text += " \(r.failures.count) could not be moved"
            text += clashes > 0
                ? " — \(clashes) already exist in the target folder (the same song is on the player twice). Remove the extra copies in the Dupes tab, then tidy again."
                : "."
        }
        let note = await afterChange(p)
        return ["message": note.isEmpty ? text : text + " " + note, "failures": r.failures.count]
    }

    func songListUpdate(_ a: JSON) async throws -> JSON {
        let p = try player(a)
        let found = await scanDevice(p)
        guard let r = try? PlayerLibraryCache.sync(deviceRoot: p.root, deviceTracks: found) else {
            return ["message": "The player keeps no song list, so there is nothing to update."]
        }
        let note = r.added + r.removed > 0
            ? "Player's song list updated: \(r.added) added, \(r.removed) removed."
            : "The player's song list is already up to date."
        return ["message": note]
    }

    // MARK: - Merging names

    /// Re-read what changed so the player's own copy of the tags is current.
    func refreshListEntries(_ p: Player, touched: Set<URL>) async {
        let after = await scanDevice(p)
        let engine = SyncEngine()
        let pairs = after.filter { touched.contains($0.sourceURL) }
            .map { (track: $0, devicePath: engine.devicePath(of: $0.sourceURL, root: p.root)) }
        _ = try? PlayerLibraryCache.update(deviceRoot: p.root, adding: pairs, dropDeadEntries: false, replaceExisting: true)
    }

    func mergeAlbums(_ a: JSON) async throws -> JSON {
        let p = try player(a)
        guard let id = a.string("groupId"), let title = a.string("into") else { throw APIError("missing group") }
        let found = await scanDevice(p)
        guard let group = SimilarAlbums().find(in: found).first(where: { $0.id == id }) else {
            throw APIError("That album group is no longer on the player. Rescan.")
        }
        let tracks = group.variants.flatMap(\.tracks)
        let undo = UndoRecorder(deviceRoot: p.root)
        let out = AlbumRetagger.setAlbum(title, for: tracks, deviceRoot: p.root, undo: undo)
        undo.finish(label: "merge albums")
        if out.changed > 0 {
            let session = undo.sessionID
            settings.update { $0.mergeRules = MergeRules.adding(MergeRules.albumRules(from: group, into: title, session: session), to: $0.mergeRules) }
        }
        await refreshListEntries(p, touched: Set(tracks.map(\.sourceURL)))
        var text = "\(countLabel(out.changed, "file")) now in “\(title)”."
        if !out.failed.isEmpty { text += " \(out.failed.count) could not be changed (unsupported or damaged file)." }
        return ["message": text + " Tidy the player to move them into one folder.", "changed": out.changed]
    }

    func mergeArtists(_ a: JSON) async throws -> JSON {
        let p = try player(a)
        guard let id = a.string("groupId"), let name = a.string("into") else { throw APIError("missing group") }
        let found = await scanDevice(p)
        guard let group = SimilarArtists().find(in: found).first(where: { $0.id == id }) else {
            throw APIError("That artist group is no longer on the player. Rescan.")
        }
        let tracks = group.variants.flatMap(\.tracks)
        let undo = UndoRecorder(deviceRoot: p.root)
        let out = ArtistRetagger.setAlbumArtist(name, for: tracks, deviceRoot: p.root, undo: undo)
        undo.finish(label: "merge artists")
        if out.changed > 0 {
            let session = undo.sessionID
            settings.update { $0.mergeRules = MergeRules.adding(MergeRules.artistRules(from: group, into: name, session: session), to: $0.mergeRules) }
        }
        await refreshListEntries(p, touched: Set(tracks.map(\.sourceURL)))
        var text = "\(countLabel(out.changed, "file")) now under “\(name)”."
        if !out.failed.isEmpty { text += " \(out.failed.count) could not be changed (unsupported or damaged file)." }
        return ["message": text + " Tidy the player to move them into one folder.", "changed": out.changed]
    }

    func ruleJSON(_ r: MergeRule) -> JSON {
        var j: JSON = ["id": r.id, "kind": r.kind.rawValue, "from": r.from, "to": r.to, "artists": r.artists]
        if let s = r.sessionID { j["sessionID"] = s.uuidString }
        return j
    }

    func rulesSuggest(_ a: JSON) async throws -> JSON {
        let p = try player(a)
        let s = settings.load()
        guard let folder = s.libraryFolder, FileManager.default.fileExists(atPath: folder) else { return ["suggested": [JSON]()] }
        let device = await scanDevice(p)
        let libURL = URL(fileURLWithPath: folder)
        let library = await LibraryScanner(formats: p.firmware.formats).scan(root: libURL, cache: ScanCache(root: libURL),
                                                                             progress: throttledProgress("Reading your library…"))
        let rules = MergeRules.learn(library: library, device: device, existing: s.mergeRules)
        return ["suggested": rules.map(ruleJSON)]
    }

    func rulesAdd(_ a: JSON) throws -> JSON {
        let list = (a["rules"] as? [JSON]) ?? []
        let new = list.compactMap { j -> MergeRule? in
            guard let kind = j.string("kind").flatMap(MergeRule.Kind.init(rawValue:)),
                  let from = j.string("from"), let to = j.string("to") else { return nil }
            return MergeRule(kind: kind, from: from, to: to, artists: j.strings("artists") ?? [],
                             sessionID: j.string("sessionID").flatMap(UUID.init(uuidString:)))
        }
        settings.update { $0.mergeRules = MergeRules.adding(new, to: $0.mergeRules) }
        return ["mergeRules": settings.asJSON()["mergeRules"] ?? []]
    }

    func rulesRemove(_ a: JSON) throws -> JSON {
        let id = a.string("id")
        settings.update { s in s.mergeRules.removeAll { $0.id == id } }
        return ["mergeRules": settings.asJSON()["mergeRules"] ?? []]
    }

    // MARK: - Broken files

    func healthScan(_ p: Player) async -> [BrokenFile] {
        let s = settings.load()
        let found = await scanDevice(p)
        var library: [Track] = []
        if let folder = s.libraryFolder, FileManager.default.fileExists(atPath: folder) {
            let url = URL(fileURLWithPath: folder)
            library = await LibraryScanner(formats: p.firmware.formats).scan(root: url, cache: ScanCache(root: url))
        }
        let health = TrackHealth(checkTail: true, audioOnly: true, limits: s.limits)
        let cache = ScanCache(root: p.root)
        let signature = health.signature
        let check: @Sendable (Track) async -> TrackReport = { t in
            if let art = cache.healthyArt(for: t, signature: signature) {
                return TrackReport(track: t, issues: [], hasEmbeddedArt: art)
            }
            let r = await health.check(t)
            if r.issues.isEmpty { cache.markHealthy(t, signature: signature, hasEmbeddedArt: r.hasEmbeddedArt) }
            return r
        }
        let emitter = self.emitter
        defer { cache.save() }
        return await DeviceHealth(check: check).scan(deviceTracks: found, deviceRoot: p.root, library: library) { done, total in
            if done == total || done % 8 == 0 {
                emitter.progress(total > 0 ? Double(done) / Double(total) : 1, "Checking \(done) of \(total)…")
            }
        }
    }

    func healthCheck(_ a: JSON) async throws -> JSON {
        let p = try player(a)
        let broken = await healthScan(p)
        return ["broken": broken.map { b -> JSON in
            ["path": b.devicePath, "reasons": b.reasons,
             "replacement": b.replacement.map { $0.sourceURL.path as Any } ?? NSNull()]
        }, "message": broken.isEmpty ? "Every file on the player plays fine."
                                      : "\(countLabel(broken.count, "broken file")) found."]
    }

    func healthFix(_ a: JSON) async throws -> JSON {
        let p = try player(a)
        let remove = a.bool("removeUnrepairable") ?? false
        let broken = await healthScan(p)
        guard !broken.isEmpty else { return ["message": "Nothing to fix."] }
        emitter.progress(nil, "Repairing…")
        let o = DeviceHealth().fix(broken, deviceRoot: p.root, removeUnrepairable: remove)
        var text = "Replaced \(o.replaced), removed \(o.removed)."
        if !o.failed.isEmpty { text += " \(o.failed.count) could not be fixed." }
        let note = await afterChange(p)
        return ["message": note.isEmpty ? text : text + " " + note]
    }

    // MARK: - Duplicates

    func dupesClean(_ a: JSON) async throws -> JSON {
        let p = try player(a)
        let s = settings.load()
        let found = await scanDevice(p)
        let ids = Set(a.strings("ids") ?? [])
        let onlySafe = a.bool("safe") ?? false
        let engine = SyncEngine()
        let undo = UndoRecorder(deviceRoot: p.root)
        var removed = 0, failed = 0
        var freed: Int64 = 0
        for g in Duplicates().find(in: found) {
            let chosen = onlySafe ? g.isSafeToAutoClean(deviceRoot: p.root, limits: s.limits) : ids.contains(dupeID(g, root: p.root))
            guard chosen, let keeper = g.recommendedKeeper(onDeviceRoot: p.root, limits: s.limits) else { continue }
            for t in g.tracks where t.sourceURL != keeper.sourceURL {
                if undo.quarantine(t.sourceURL, path: engine.devicePath(of: t.sourceURL, root: p.root)) {
                    removed += 1; freed += t.fileSize
                } else { failed += 1 }
            }
        }
        var text = "Removed \(countLabel(removed, "file")) (\(ByteFormat.string(freed)))."
        if failed > 0 { text += " \(failed) could not be removed." }
        if removed > 0 {
            undo.finish(label: "remove duplicates")
            let note = await afterChange(p)
            if !note.isEmpty { text += " " + note }
        }
        return ["message": text + (removed > 0 ? " Undo is on the Device tab." : ""), "removed": removed, "freed": freed]
    }

    // MARK: - Undo

    func undo(_ a: JSON) async throws -> JSON {
        let p = try player(a)
        let undone = UndoLog.mostRecent(deviceRoot: p.root)
        guard let outcome = UndoLog.undoMostRecent(deviceRoot: p.root) else { return ["message": "Nothing to undo."] }
        // Undoing a merge also forgets its rules, or the next sync would redo it.
        if let undone { settings.update { s in s.mergeRules.removeAll { $0.sessionID == undone.id } } }
        var text = "Restored \(countLabel(outcome.restored, "item"))."
        if !outcome.failed.isEmpty { text += " \(outcome.failed.count) could not be restored." }
        let note = await afterChange(p)
        return ["message": note.isEmpty ? text : text + " " + note, "failed": outcome.failed.count]
    }

    func undoForget(_ a: JSON) throws -> JSON {
        let p = try player(a)
        UndoLog.forgetMostRecent(deviceRoot: p.root)
        return ["message": "Undo history discarded."]
    }

    // MARK: - Free up space

    func freeRemove(_ a: JSON) async throws -> JSON {
        let p = try player(a)
        let ids = Set(a.strings("albumIds") ?? [])
        guard !ids.isEmpty else { throw APIError("Nothing selected.") }
        let found = await scanDevice(p)
        let stats = ListeningStats(entries: ScrobbleLog.read(deviceRoot: p.root), deviceTracks: found)
        let chosen = stats.albums.filter { ids.contains($0.id) }
        let engine = SyncEngine()
        let undo = UndoRecorder(deviceRoot: p.root)
        var files = 0, failed = 0
        var freed: Int64 = 0
        for album in chosen {
            for t in album.tracks {
                if undo.quarantine(t.sourceURL, path: engine.devicePath(of: t.sourceURL, root: p.root)) {
                    files += 1; freed += t.fileSize
                } else { failed += 1 }
                let lrc = t.sourceURL.deletingPathExtension().appendingPathExtension("lrc")
                if FileManager.default.fileExists(atPath: lrc.path) {
                    undo.quarantine(lrc, path: engine.devicePath(of: lrc, root: p.root))
                }
            }
        }
        if files > 0 {
            undo.finish(label: "free up space")
            // Sync must not copy them straight back.
            let keys = chosen.map(\.id)
            settings.update { s in s.excludedAlbums = Array(Set(s.excludedAlbums).union(keys)) }
        }
        var text = "Removed \(countLabel(chosen.count, "album")) (\(ByteFormat.string(freed))) from the player."
        text += failed > 0 ? " \(failed) files could not be moved." : " Undo is on the Device tab."
        let note = files > 0 ? await afterChange(p) : ""
        return ["message": note.isEmpty ? text : text + " " + note, "freed": freed]
    }

    // MARK: - Lyrics, covers, playlists

    func enrich(_ a: JSON) async throws -> JSON {
        let p = try player(a)
        let lyrics = a.bool("lyrics") ?? false, covers = a.bool("covers") ?? false
        guard lyrics || covers else { throw APIError("Pick lyrics, covers or both.") }
        let found = await scanDevice(p)
        guard !found.isEmpty else { throw APIError("No audio found on the player.") }
        let enricher = Enricher(maxArtDimension: maxArt(for: p), inPlace: true)
        let emitter = self.emitter
        var parts: [String] = []

        if covers {
            emitter.progress(nil, "Checking which albums have no art…")
            let reports = await TrackHealth(maxEmbeddedArtPixels: maxArt(for: p)).checkAll(found)
            var withArt: Set<String> = []
            for r in reports where r.hasEmbeddedArt {
                withArt.insert(FATName.foldedKey("\(r.track.effectiveAlbumArtist)/\(r.track.effectiveAlbum)"))
            }
            let missing = Set(found.map { FATName.foldedKey("\($0.effectiveAlbumArtist)/\($0.effectiveAlbum)") })
                .subtracting(withArt)
            if missing.isEmpty {
                parts.append("Every album already has a cover.")
            } else {
                let r = await enricher.addCovers(for: found, albumsMissingArt: missing, deviceRoot: p.root) { done, total, label in
                    emitter.progress(total > 0 ? Double(done) / Double(total) : 1, "Art \(done)/\(total) — \(label)")
                }
                parts.append("Embedded art into \(r.coversEmbedded) file(s)"
                             + (r.coversFromLocalFile > 0 ? " (\(r.coversFromLocalFile) from a local cover file)" : "") + ".")
            }
        }
        if lyrics {
            let r = await enricher.addLyrics(for: found, deviceRoot: p.root) { done, total, title in
                emitter.progress(total > 0 ? Double(done) / Double(total) : 1, "Lyrics \(done)/\(total) — \(title)")
            }
            parts.append("Wrote \(r.lyricsWritten) lyrics file(s); \(r.lyricsNotFound) not found.")
        }
        return ["message": parts.joined(separator: " ")]
    }

    func playlists(_ a: JSON) async throws -> JSON {
        let p = try player(a)
        let found = await scanDevice(p)
        guard !found.isEmpty else { throw APIError("No audio found on the player.") }
        let r = try SmartPlaylistBuilder().writeAll(
            tracks: found, deviceRoot: p.root,
            moods: a.bool("moods") ?? true, bpm: a.bool("tempo") ?? true, genres: a.bool("genres") ?? true)
        guard !r.written.isEmpty else {
            return ["message": "No mood/tempo/genre tags found (or not enough tracks for a playlist)."]
        }
        return ["message": "Wrote \(r.written.count) playlist(s): " + r.written.keys.sorted().joined(separator: ", ")]
    }
}
