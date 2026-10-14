import Foundation
import Observation
import Y1SyncCore

/// Everything that operates on the player itself rather than on a sync:
/// tidying names, clearing junk, finding duplicates, adding lyrics and art.
@MainActor
@Observable
final class DeviceModel {
    enum Busy: Equatable {
        case idle
        case scanning
        case tidying
        case checking
        case enriching(String)
    }

    var busy: Busy = .idle
    var status: String = ""
    var progress: Double = 0

    var tracks: [Track] = []
    var tidyPlan: TidyPlan?
    /// The tidy plan with renames that would be refused flagged in advance.
    var tidyPreview: TidyPreview?
    var duplicates: [DuplicateGroup] = []

    /// Library tracks, used to find an intact copy of a broken file. Set by
    /// the window from the Sync tab's scan; empty until the library is scanned.
    /// What the player's own play log says about the music on it.
    var stats: ListeningStats?
    /// Albums ticked for removal on the Listening tab.
    var removalPicks: Set<String> = []
    /// Called with the albums removed to free space, so sync stops copying them back.
    var onAlbumsRemoved: (@MainActor ([LibraryAlbum]) -> Void)?
    var libraryTracks: [Track] = [] { didSet { refreshSuggestedRules() } }
    /// Differences between the library's spelling and the player's, offered as merge rules.
    var suggestedRules: [MergeRule] = []

    func refreshSuggestedRules() {
        guard !tracks.isEmpty, !libraryTracks.isEmpty else { suggestedRules = []; return }
        suggestedRules = MergeRules.learn(library: libraryTracks, device: tracks, existing: mergeRules)
    }
    /// Result of the last health check; nil until one has run.
    var brokenFiles: [BrokenFile]?
    /// How the player's own song list compares with the card; nil when the
    /// player keeps none or nothing has been scanned.
    var playerList: PlayerLibraryCache.Status?
    /// Albums that browse as several although they are one (typo, edition, stray single).
    var similarAlbums: [SimilarAlbumGroup] = []
    /// Artists spelled more than one way.
    var similarArtists: [SimilarArtistGroup] = []

    /// Groups the user has chosen to act on, by group id.
    var selectedDuplicates: Set<String> = []

    var maxArtDimension = 500
    var removeJunk = AppSettings.removeJunk
    /// Merges to repeat on every sync, so the library's old spellings do not come back.
    var mergeRules = AppSettings.mergeRules {
        didSet { AppSettings.mergeRules = mergeRules; refreshSuggestedRules() }
    }
    /// Formats the user told the app the player cannot play.
    var limits = AppSettings.playerLimits {
        didSet { AppSettings.playerLimits = limits; brokenFiles = nil }
    }

    private(set) var deviceRoot: URL?
    /// The one operation that can currently be undone, if any.
    var undoSession: UndoSession?

    var isBusy: Bool { busy != .idle }
    var hasScanned: Bool { !tracks.isEmpty }

    var reclaimableBytes: Int64 {
        duplicates.filter { selectedDuplicates.contains($0.id) }
                  .reduce(0) { $0 + $1.wastedBytes(limits: limits) }
    }

    /// Groups that can be cleaned without asking (see `isSafeToAutoClean`).
    var safeDuplicates: [DuplicateGroup] {
        duplicates.filter { $0.isSafeToAutoClean(deviceRoot: deviceRoot, limits: limits) }
    }

    func isSafeToAutoClean(_ group: DuplicateGroup) -> Bool {
        group.isSafeToAutoClean(deviceRoot: deviceRoot, limits: limits)
    }

    /// Tick exactly the groups that are safe to clean up.
    func selectSafeDuplicates() {
        selectedDuplicates = Set(safeDuplicates.map(\.id))
    }

    /// Forget the previous player's scan when a different one is selected
    /// (or the selected one is unplugged), so tidy, duplicate cleanup and
    /// undo can never act on a device other than the one on screen.
    func deviceChanged(to root: URL?) {
        guard root?.standardizedFileURL != deviceRoot?.standardizedFileURL else { return }
        guard !isBusy else { return }
        deviceRoot = root
        tracks = []
        tidyPlan = nil
        duplicates = []
        brokenFiles = nil
        playerList = nil
        similarAlbums = []
        similarArtists = []
        selectedDuplicates = []
        progress = 0
        undoSession = root.flatMap { UndoLog.mostRecent(deviceRoot: $0) }
        status = ""
    }

    /// Read everything on the player. Nothing is modified.
    func scan(deviceRoot root: URL) async {
        deviceRoot = root
        undoSession = UndoLog.mostRecent(deviceRoot: root)
        busy = .scanning
        status = "Reading the player…"
        progress = 0

        let cache = ScanCache(root: root)
        let found = await Task.detached(priority: .userInitiated) { [weak self] in
            await LibraryScanner().scan(root: root, cache: cache) { done, total in
                Task { @MainActor in
                    self?.progress = total > 0 ? Double(done) / Double(total) : 1
                    self?.status = "Reading the player… \(done) of \(total)"
                }
            }
        }.value
        tracks = found

        guard !found.isEmpty else {
            status = "No audio found on the player."
            busy = .idle
            return
        }

        status = "Working out what to tidy…"
        let plan = await Task.detached(priority: .userInitiated) {
            DeviceTidy().plan(deviceRoot: root, tracks: found)
        }.value
        tidyPlan = plan
        tidyPreview = TidyPreview(plan: plan, deviceRoot: root)
        playerList = PlayerLibraryCache.status(deviceRoot: root, deviceTracks: found)
        similarAlbums = SimilarAlbums().find(in: found)
        similarArtists = SimilarArtists().find(in: found)
        refreshSuggestedRules()
        stats = ListeningStats(entries: ScrobbleLog.read(deviceRoot: root), deviceTracks: found)
        removalPicks = []

        let dupes = await Task.detached(priority: .userInitiated) {
            Duplicates().find(in: found)
        }.value
        duplicates = dupes
        selectedDuplicates = []

        status = "\(found.count) track(s) · \(plan.moves.count) to rename · "
               + "\(plan.junk.count) junk file(s) · \(dupes.count) duplicate group(s)"
        busy = .idle
    }

    /// Give every track of a group the same album title, so the player shows one
    /// album. Only the album tag changes (audio untouched); Undo restores each
    /// file's old title. Folders follow once the player is tidied.
    func mergeAlbums(_ group: SimilarAlbumGroup, into title: String) async {
        guard let root = deviceRoot, !isBusy else { return }
        busy = .tidying
        status = "Merging into “\(title)”…"
        let tracks = group.variants.flatMap(\.tracks)
        let outcome = await Task.detached(priority: .userInitiated) { () -> (AlbumRetagger.Outcome, [Track], UUID) in
            let undo = UndoRecorder(deviceRoot: root)
            let out = AlbumRetagger.setAlbum(title, for: tracks, deviceRoot: root, undo: undo)
            undo.finish(label: "merge albums")
            return (out, tracks, undo.sessionID)
        }.value
        if outcome.0.changed > 0 {
            mergeRules = MergeRules.adding(MergeRules.albumRules(from: group, into: title, session: outcome.2), to: mergeRules)
        }
        busy = .idle

        var text = "\(countLabel(outcome.0.changed, "file")) now in “\(title)”."
        if !outcome.0.failed.isEmpty { text += " \(outcome.0.failed.count) could not be changed." }
        await scan(deviceRoot: root)
        // Tags changed in place, so the player's copy of them is stale.
        let engine = SyncEngine()
        let pairs = self.tracks.filter { t in group.variants.contains { v in v.tracks.contains { $0.sourceURL == t.sourceURL } } }
            .map { (track: $0, devicePath: engine.devicePath(of: $0.sourceURL, root: root)) }
        _ = try? PlayerLibraryCache.update(deviceRoot: root, adding: pairs, dropDeadEntries: false, replaceExisting: true)
        playerList = PlayerLibraryCache.status(deviceRoot: root, deviceTracks: self.tracks)
        status = text + " Tidy the player to move them into one folder."
    }

    /// Give an artist one spelling everywhere (album artist; a track's own
    /// artist only where it was that exact spelling). Tags only; Undo restores.
    func mergeArtists(_ group: SimilarArtistGroup, into name: String) async {
        guard let root = deviceRoot, !isBusy else { return }
        busy = .tidying
        status = "Merging into “\(name)”…"
        let tracks = group.variants.flatMap(\.tracks)
        let (out, session) = await Task.detached(priority: .userInitiated) { () -> (TagEditor.Outcome, UUID) in
            let undo = UndoRecorder(deviceRoot: root)
            let r = ArtistRetagger.setAlbumArtist(name, for: tracks, deviceRoot: root, undo: undo)
            undo.finish(label: "merge artists")
            return (r, undo.sessionID)
        }.value
        if out.changed > 0 {
            mergeRules = MergeRules.adding(MergeRules.artistRules(from: group, into: name, session: session), to: mergeRules)
        }
        busy = .idle

        var text = "\(countLabel(out.changed, "file")) now under “\(name)”."
        if !out.failed.isEmpty {
            text += " \(out.failed.count) could not be changed (unsupported or damaged file)."
        }
        await scan(deviceRoot: root)
        let engine = SyncEngine()
        let touched = Set(tracks.map(\.sourceURL))
        let pairs = self.tracks.filter { touched.contains($0.sourceURL) }
            .map { (track: $0, devicePath: engine.devicePath(of: $0.sourceURL, root: root)) }
        _ = try? PlayerLibraryCache.update(deviceRoot: root, adding: pairs, dropDeadEntries: false, replaceExisting: true)
        playerList = PlayerLibraryCache.status(deviceRoot: root, deviceTracks: self.tracks)
        status = text + " Tidy the player to move them into one folder."
    }

    /// Tick the least-listened albums until about `bytes` would be freed.
    func pickLeastListened(freeing bytes: Int64) {
        guard let stats else { return }
        removalPicks = Set(stats.leastListened(freeing: bytes).map(\.id))
    }

    var removalBytes: Int64 {
        stats?.albums.filter { removalPicks.contains($0.id) }.reduce(0) { $0 + $1.bytes } ?? 0
    }

    /// Move the ticked albums (and their lyrics files) into the undo quarantine,
    /// and tell sync to stop copying them back.
    func removePickedAlbums() async -> (albums: Int, files: Int, freed: Int64, failed: Int) {
        guard let root = deviceRoot, let stats else { return (0, 0, 0, 0) }
        let chosen = stats.albums.filter { removalPicks.contains($0.id) }
        let result = await Task.detached(priority: .userInitiated) { () -> (Int, Int, Int64, Int) in
            let undo = UndoRecorder(deviceRoot: root)
            let engine = SyncEngine()
            var files = 0, failed = 0
            var freed: Int64 = 0
            for album in chosen {
                for t in album.tracks {
                    let path = engine.devicePath(of: t.sourceURL, root: root)
                    if undo.quarantine(t.sourceURL, path: path) { files += 1; freed += t.fileSize } else { failed += 1 }
                    let lrc = t.sourceURL.deletingPathExtension().appendingPathExtension("lrc")
                    if FileManager.default.fileExists(atPath: lrc.path) {
                        undo.quarantine(lrc, path: engine.devicePath(of: lrc, root: root))
                    }
                }
            }
            if files > 0 { undo.finish(label: "free up space") }
            return (chosen.count, files, freed, failed)
        }.value
        if result.1 > 0 {
            onAlbumsRemoved?(chosen.map {
                LibraryAlbum(id: $0.id, artist: $0.artist, title: $0.title, trackCount: $0.tracks.count, bytes: $0.bytes)
            })
            await rescanAndRefreshList(status)
        }
        return (result.0, result.1, result.2, result.3)
    }

    /// Teach the player's song list about what is on the card now. Without
    /// this, files copied since the player last scanned stay invisible on it.
    /// Returns a short note for the status line ("" when nothing was needed).
    @discardableResult
    func updatePlayerList() async -> String {
        guard let root = deviceRoot, !tracks.isEmpty else { return "" }
        let found = tracks
        let result = await Task.detached(priority: .userInitiated) {
            try? PlayerLibraryCache.sync(deviceRoot: root, deviceTracks: found)
        }.value
        playerList = PlayerLibraryCache.status(deviceRoot: root, deviceTracks: found)
        guard let result, result.added + result.removed > 0 else { return "" }
        return "Player's song list updated: \(result.added) added, \(result.removed) removed."
    }

    /// Rescan after a change and keep the player's song list in step.
    private func rescanAndRefreshList(_ text: String) async {
        guard let root = deviceRoot else { return }
        await scan(deviceRoot: root)
        let note = await updatePlayerList()
        status = note.isEmpty ? text : text + " " + note
    }

    /// Decode the start and end of every file on the player and list the ones
    /// that will not play. Nothing is changed.
    func checkHealth() async {
        guard let root = deviceRoot, !tracks.isEmpty, !isBusy else { return }
        busy = .checking
        progress = 0
        status = "Checking \(countLabel(tracks.count, "file"))…"
        let found = tracks
        let library = libraryTracks
        let health = TrackHealth(checkTail: true, audioOnly: true, limits: limits)
        let cache = ScanCache(root: root)
        let signature = health.signature
        let check: @Sendable (Track) async -> TrackReport = { t in
            // Unchanged files that passed the same checks last time are not opened again.
            if let art = cache.healthyArt(for: t, signature: signature) {
                return TrackReport(track: t, issues: [], hasEmbeddedArt: art)
            }
            let r = await health.check(t)
            if r.issues.isEmpty { cache.markHealthy(t, signature: signature, hasEmbeddedArt: r.hasEmbeddedArt) }
            return r
        }
        let result = await Task.detached(priority: .userInitiated) { [weak self] in
            defer { cache.save() }
            return await DeviceHealth(check: check).scan(deviceTracks: found, deviceRoot: root, library: library) { done, total in
                Task { @MainActor in
                    self?.progress = total > 0 ? Double(done) / Double(total) : 1
                    self?.status = "Checking \(done) of \(total)…"
                }
            }
        }.value
        brokenFiles = result
        busy = .idle
        status = result.isEmpty
            ? "All \(countLabel(found.count, "file")) play fine."
            : "\(countLabel(result.count, "broken file")) found."
    }

    /// Replace broken files from the library (and optionally remove the ones
    /// with no intact copy). Reversible with Undo.
    func fixBroken(removeUnrepairable: Bool) async {
        guard let root = deviceRoot, let items = brokenFiles, !items.isEmpty, !isBusy else { return }
        busy = .tidying
        status = "Repairing…"
        let outcome = await Task.detached(priority: .userInitiated) {
            DeviceHealth().fix(items, deviceRoot: root, removeUnrepairable: removeUnrepairable)
        }.value
        busy = .idle
        var text = "Replaced \(outcome.replaced), removed \(outcome.removed)."
        if !outcome.failed.isEmpty { text += " \(outcome.failed.count) could not be fixed." }
        await rescanAndRefreshList(text)
        brokenFiles = nil
    }

    /// Rename files into the standard layout and clear macOS junk.
    func applyTidy() async {
        guard let root = deviceRoot, let plan = tidyPlan else { return }
        busy = .tidying
        progress = 0

        let keepJunk = !removeJunk
        let result = await Task.detached(priority: .userInitiated) { [weak self] in
            DeviceTidy().apply(plan, deviceRoot: root, removeJunk: !keepJunk) { done, total in
                Task { @MainActor in
                    self?.progress = total > 0 ? Double(done) / Double(total) : 1
                    self?.status = "\(done) of \(total)…"
                }
            }
        }.value

        status = "Renamed \(result.moved), removed \(result.junkRemoved) junk file(s) "
               + "(\(ByteFormat.string(result.bytesFreed))), "
               + "\(result.directoriesRemoved) empty folder(s), "
               + "\(result.leftoverFoldersRemoved) leftover folder(s)"
               + (result.coversSalvaged > 0 ? " (\(result.coversSalvaged) cover(s) salvaged)" : "") + "."
        if !result.failures.isEmpty {
            let clashes = result.failures.filter { $0.hasSuffix("already exists") }.count
            status += " \(result.failures.count) could not be moved"
            status += clashes > 0
                ? " — \(clashes) already exist in the target folder (the same song is on the player twice). Remove the extra copies in the Dupes tab, then tidy again."
                : "."
        }
        busy = .idle

        // Paths changed underneath us, so the old scan is stale. This also
        // refreshes undoSession to the tidy we just ran.
        await rescanAndRefreshList(status)
    }

    /// Reverse the most recent tidy or duplicate cleanup. Only ever the
    /// single most recent one — starting a new destructive operation
    /// permanently discards whatever this would have restored.
    func undoLastOperation() async -> UndoLog.UndoOutcome? {
        guard let root = deviceRoot else { return nil }
        let undone = UndoLog.mostRecent(deviceRoot: root)
        let outcome = UndoLog.undoMostRecent(deviceRoot: root)
        // Undoing a merge also forgets its rules, or the next sync would redo it.
        if let undone { mergeRules.removeAll { $0.sessionID == undone.id } }
        await rescanAndRefreshList(status)
        return outcome
    }

    /// Permanently discard the undoable operation without restoring it,
    /// freeing the space it was holding right away.
    func forgetUndoSession() {
        guard let root = deviceRoot else { return }
        UndoLog.forgetMostRecent(deviceRoot: root)
        undoSession = nil
    }

    /// Build playlists from mood/tempo/genre tags already on the tracks —
    /// no network involved, and tracks missing a tag are simply skipped.
    func buildSmartPlaylists(moods: Bool, bpm: Bool, genres: Bool) async {
        guard let root = deviceRoot, !tracks.isEmpty else { return }
        let all = tracks
        let result = await Task.detached(priority: .userInitiated) {
            try? SmartPlaylistBuilder().writeAll(
                tracks: all, deviceRoot: root, moods: moods, bpm: bpm, genres: genres)
        }.value

        guard let result, !result.written.isEmpty else {
            status = "No mood/tempo/genre tags found (or not enough tracks for a playlist)."
            return
        }
        status = "Wrote \(result.written.count) playlist(s): "
               + result.written.keys.sorted().joined(separator: ", ")
    }

    /// Add lyrics and missing covers to what is already on the player.
    func enrich(lyrics: Bool, covers: Bool) async {
        guard let root = deviceRoot, !tracks.isEmpty else { return }
        guard lyrics || covers else { return }

        let all = tracks
        let limit = maxArtDimension
        let enricher = Enricher(maxArtDimension: limit, inPlace: true)

        if covers {
            busy = .enriching("covers")
            status = "Checking which albums have no art…"

            let reports = await Task.detached(priority: .userInitiated) {
                await TrackHealth(maxEmbeddedArtPixels: limit).checkAll(all)
            }.value

            var withArt: Set<String> = []
            for r in reports where r.hasEmbeddedArt {
                withArt.insert(FATName.foldedKey(
                    "\(r.track.effectiveAlbumArtist)/\(r.track.effectiveAlbum)"))
            }
            var missing: Set<String> = []
            for t in all {
                let key = FATName.foldedKey("\(t.effectiveAlbumArtist)/\(t.effectiveAlbum)")
                if !withArt.contains(key) { missing.insert(key) }
            }

            if missing.isEmpty {
                status = "Every album already has a cover."
            } else {
                let result = await enricher.addCovers(
                    for: all, albumsMissingArt: missing, deviceRoot: root
                ) { [weak self] done, total, label in
                    Task { @MainActor in
                        self?.progress = total > 0 ? Double(done) / Double(total) : 1
                        self?.status = "Art \(done)/\(total) — \(label)"
                    }
                }
                status = "Embedded art into \(result.coversEmbedded) file(s)"
                       + (result.coversFromLocalFile > 0
                          ? " (\(result.coversFromLocalFile) from a local cover file)" : "") + "."
            }
        }

        if lyrics {
            busy = .enriching("lyrics")
            let result = await enricher.addLyrics(for: all, deviceRoot: root) { [weak self] done, total, title in
                Task { @MainActor in
                    self?.progress = total > 0 ? Double(done) / Double(total) : 1
                    self?.status = "Lyrics \(done)/\(total) — \(title)"
                }
            }
            status = "Wrote \(result.lyricsWritten) lyrics file(s); "
                   + "\(result.lyricsNotFound) not found."
        }

        progress = 1
        busy = .idle
    }

    /// Delete the non-recommended copies in the selected duplicate groups.
    /// Only ever removes files the user explicitly selected. Nothing is
    /// really gone right away — it moves into quarantine, undoable via
    /// `undoLastOperation()` until the next tidy or cleanup runs.
    func deleteSelectedDuplicates() async -> (removed: Int, freed: Int64, failed: Int) {
        var removed = 0, failed = 0
        var freed: Int64 = 0
        guard let root = deviceRoot else { return (0, 0, 0) }
        let undo = UndoRecorder(deviceRoot: root)

        for group in duplicates where selectedDuplicates.contains(group.id) {
            guard let keeper = group.recommendedKeeper(onDeviceRoot: root, limits: limits) else { continue }
            for track in group.tracks where track.sourceURL != keeper.sourceURL {
                let path = SyncEngine().devicePath(of: track.sourceURL, root: root)
                if undo.quarantine(track.sourceURL, path: path) {
                    removed += 1
                    freed += track.fileSize
                } else {
                    failed += 1
                }
            }
        }

        if removed > 0 {
            undo.finish(label: "remove duplicates")
            await rescanAndRefreshList(status)
        }
        return (removed, freed, failed)
    }
}
