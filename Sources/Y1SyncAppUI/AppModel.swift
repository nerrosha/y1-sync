import Foundation
import AppKit
import Observation
import Y1SyncCore

/// All sync state for the window. The heavy work runs off the main actor and
/// only the published snapshots hop back, so scanning a large library never
/// blocks the UI.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case planned
        case syncing
        case done(String)
        case failed(String)
    }

    var phase: Phase = .idle
    var devices: [Device] = []
    var selectedDevice: Device?

    private(set) var libraryFolder: URL?

    /// Every playable track in the library, after album-artist unification.
    var libraryTracks: [Track] = []
    /// The subset that will actually be synced — `libraryTracks` minus the
    /// albums switched off in "Choose albums".
    var tracks: [Track] = []
    var plan: SyncPlan?

    /// Albums switched off for syncing, by `SyncSelection.albumKey`.
    /// Remembered between launches; new albums are included by default.
    private(set) var excludedAlbums: Set<String> = []

    /// Library grouped by artist → album, for the album picker.
    var libraryArtists: [LibraryArtist] = []
    /// Tracks still to copy per album, ignoring the selection — so the picker
    /// can say "3 new" even for an album that is currently switched off.
    var pendingByAlbum: [String: Int] = [:]

    /// Health results for everything scanned, including files excluded from
    /// the sync because they will not play.
    var reports: [TrackReport] = []
    var albumIssues: [AlbumReport] = []
    var strayTracks: [LibraryAudit.StrayTrack] = []

    /// Longest edge for embedded cover art. Stock Innioasis firmware reads art
    /// from the file's tags and misbehaves above roughly this size.
    var maxArtDimension: Int = 1000
    var resizeArtwork = true

    /// Online lookups. Off by default: they send artist, album and track
    /// names to LRCLIB and MusicBrainz.
    var fetchLyrics = false
    var fetchCovers = false

    /// Scan and compare on its own as soon as the player is plugged in.
    var autoCompare = true

    /// Short "Player connected" style note shown under the device picker.
    var connectionNotice: String?

    /// What the last sync actually changed, shown in the results tab.
    var lastChanges: [FileChange] = []
    var lastDeviceRoot: URL?

    var brokenCount: Int { reports.filter { !$0.isPlayable }.count }
    var warningCount: Int { reports.filter { $0.isPlayable && !$0.issues.isEmpty }.count }

    var albumCount: Int { libraryArtists.reduce(0) { $0 + $1.albums.count } }
    var selectedAlbumCount: Int {
        libraryArtists.reduce(0) { n, artist in
            n + artist.albums.filter { !excludedAlbums.contains($0.id) }.count
        }
    }
    var hasExclusions: Bool { selectedAlbumCount < albumCount }

    var progressFraction: Double = 0
    var progressLabel: String = ""
    /// Set by the Stop button; polled by the copy between chunks.
    private let stopFlag = StopFlag()
    var isStopping = false

    /// Stop the copy after the current chunk. Files already copied stay.
    func stopSync() {
        stopFlag.set()
        isStopping = true
        progressLabel = "Stopping…"
    }

    /// Written to /Playlists when non-empty.
    var playlistName: String = ""

    private let finder = DeviceFinder()
    private let scanner = LibraryScanner()

    /// What is on the selected player, from the last scan — kept so a change
    /// of album selection can be re-planned instantly without rescanning.
    private var deviceFiles: [DeviceFile] = []
    private var volumeObservers: [any NSObjectProtocol] = []

    init() {
        libraryFolder = AppSettings.libraryFolder
        playlistName = AppSettings.playlistName
        maxArtDimension = AppSettings.maxArtDimension
        resizeArtwork = AppSettings.resizeArtwork
        fetchLyrics = AppSettings.fetchLyrics
        fetchCovers = AppSettings.fetchCovers
        autoCompare = AppSettings.autoCompare
        excludedAlbums = AppSettings.excludedAlbums
    }

    /// Persist the toggles and text fields the views bind to directly. The
    /// view calls this from `onChange`; the library folder, chosen player and
    /// album selection are saved by the methods that change them.
    func saveSettings() {
        AppSettings.playlistName = playlistName
        AppSettings.maxArtDimension = maxArtDimension
        AppSettings.resizeArtwork = resizeArtwork
        AppSettings.fetchLyrics = fetchLyrics
        AppSettings.fetchCovers = fetchCovers
        AppSettings.autoCompare = autoCompare
    }

    private func makeEngine() -> SyncEngine {
        SyncEngine(artworkOptimizer: resizeArtwork
                   ? ArtworkOptimizer(maxDimension: maxArtDimension) : nil)
    }

    var isBusy: Bool { phase == .scanning || phase == .syncing }

    var canScan: Bool {
        libraryFolder != nil && !isBusy
    }

    var canSync: Bool {
        guard let plan, selectedDevice != nil else { return false }
        guard !isBusy else { return false }
        return !plan.isEmpty || !playlistName.isEmpty
    }

    // MARK: - Devices

    /// Pick a device by the user's choice, remembering it for next launch.
    func choose(_ device: Device?) {
        guard device?.url != selectedDevice?.url else { return }
        selectedDevice = device
        if let device { AppSettings.preferredDeviceName = device.name }
        invalidatePlan()
    }

    func refreshDevices() {
        devices = finder.candidates()
        if let current = selectedDevice,
           !devices.contains(where: { $0.url == current.url }) {
            selectedDevice = nil
            invalidatePlan()
        }
        if selectedDevice == nil {
            selectedDevice = preferredDevice(in: devices)
        }
    }

    /// The remembered player if it is connected, else one running Rockbox,
    /// else the first candidate.
    private func preferredDevice(in list: [Device]) -> Device? {
        if let name = AppSettings.preferredDeviceName,
           let match = list.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match
        }
        return list.first(where: \.hasRockbox) ?? list.first
    }

    /// A plan is only valid for the device it was made against.
    private func invalidatePlan() {
        plan = nil
        deviceFiles = []
        pendingByAlbum = [:]
        if case .planned = phase { phase = .idle }
    }

    /// Watch for volumes being mounted and unmounted, so plugging the player
    /// in is noticed without pressing Refresh. Safe to call more than once.
    func startWatchingVolumes() {
        guard volumeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        let mount = center.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.volumeMounted(url) }
        }
        let unmount = center.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.volumeUnmounted(url) }
        }
        volumeObservers = [mount, unmount]
    }

    private func volumeMounted(_ url: URL?) {
        let before = Set(devices.map(\.url.standardizedFileURL))
        let previous = selectedDevice
        refreshDevices()

        // Only react to a removable volume that was not there a moment ago —
        // mounting a disk image or a network share is none of our business.
        guard let added = devices.first(where: {
            !before.contains($0.url.standardizedFileURL)
                && (url == nil || $0.url.standardizedFileURL == url!.standardizedFileURL)
        }) else { return }

        // Switch to it if nothing was selected, or it is the remembered player.
        let isPreferred = AppSettings.preferredDeviceName
            .map { added.name.caseInsensitiveCompare($0) == .orderedSame } ?? false
        if previous == nil || isPreferred {
            if selectedDevice?.url != added.url {
                selectedDevice = added
                invalidatePlan()
            }
        }

        guard selectedDevice?.url == added.url else {
            connectionNotice = "\(added.name) connected."
            return
        }
        connectionNotice = "\(added.name) connected — \(ByteFormat.string(added.freeBytes)) free."

        if autoCompare, canScan {
            Task { await scanAndPlan() }
        }
    }

    private func volumeUnmounted(_ url: URL?) {
        let wasSelected = selectedDevice
        refreshDevices()
        if let wasSelected, selectedDevice?.url != wasSelected.url {
            connectionNotice = "\(wasSelected.name) disconnected."
        }
    }

    // MARK: - Library

    func setLibraryFolder(_ url: URL) {
        guard url != libraryFolder else { return }
        libraryFolder = url
        AppSettings.libraryFolder = url
        plan = nil
        libraryTracks = []
        tracks = []
        libraryArtists = []
        pendingByAlbum = [:]
        deviceFiles = []
        reports = []
        albumIssues = []
        strayTracks = []
        if case .planned = phase { phase = .idle }
    }

    // MARK: - Album selection

    func isIncluded(_ album: LibraryAlbum) -> Bool {
        !excludedAlbums.contains(album.id)
    }

    func setIncluded(_ included: Bool, album: LibraryAlbum) {
        setIncluded(included, albums: [album])
    }

    func setIncluded(_ included: Bool, artist: LibraryArtist) {
        setIncluded(included, albums: artist.albums)
    }

    func setIncluded(_ included: Bool, albums: [LibraryAlbum]) {
        let keys = Set(albums.map(\.id))
        if included { excludedAlbums.subtract(keys) } else { excludedAlbums.formUnion(keys) }
        AppSettings.excludedAlbums = excludedAlbums
        replan()
    }

    /// Recompute what to copy from the cached scan — no disk access.
    private func replan() {
        tracks = SyncSelection.filter(libraryTracks, excluding: excludedAlbums)
        guard plan != nil else { return }
        plan = SyncPlanner().plan(library: tracks, deviceFiles: deviceFiles)
    }

    // MARK: - Scan

    func scanAndPlan() async {
        guard let library = libraryFolder else { return }
        guard !isBusy else { return }
        connectionNotice = nil
        phase = .scanning
        plan = nil
        progressLabel = "Reading tags…"

        let scanner = self.scanner
        let libraryCache = ScanCache(root: library)
        let found = await Task.detached(priority: .userInitiated) {
            await scanner.scan(root: library, cache: libraryCache)
        }.value

        guard !found.isEmpty else {
            libraryTracks = []
            tracks = []
            libraryArtists = []
            phase = .failed("No supported audio files in that folder.")
            return
        }

        guard let device = selectedDevice else {
            phase = .failed("No device selected.")
            return
        }

        // Verify files actually decode before planning: a truncated download
        // would otherwise occupy space on the player and fail to play.
        progressLabel = "Checking files…"
        let limit = maxArtDimension
        let limits = AppSettings.playerLimits
        let checked = await Task.detached(priority: .userInitiated) {
            await TrackHealth(maxEmbeddedArtPixels: limit, limits: limits)
                .checkAll(found, cache: libraryCache)
        }.value
        reports = checked

        // Merges the user made on the player apply here too, so the plan matches
        // the player and the old spellings are not copied back.
        let rules = AppSettings.mergeRules
        let playable = MergeRules.apply(rules, to: checked.filter(\.isPlayable).map(\.track))
        let ruled = Dictionary(playable.map { ($0.sourceURL, $0) }, uniquingKeysWith: { a, _ in a })
        var withArt: Set<String> = []
        for r in checked where r.hasEmbeddedArt {
            let t = ruled[r.track.sourceURL] ?? r.track
            withArt.insert(FATName.foldedKey("\(t.effectiveAlbumArtist)/\(t.effectiveAlbum)"))
        }

        // Unify album artists so a compilation lands in one folder rather
        // than one folder per guest artist.
        let audit = LibraryAudit()
        albumIssues = audit.audit(playable, artworkPresent: withArt)
        strayTracks = audit.strayTracks(playable)
        libraryTracks = audit.unifyAlbumArtists(playable, using: albumIssues)
        libraryArtists = SyncSelection.group(libraryTracks)
        tracks = SyncSelection.filter(libraryTracks, excluding: excludedAlbums)

        let engine = makeEngine()
        let root = device.url
        let onDevice = await Task.detached(priority: .userInitiated) {
            engine.scanDevice(root: root)
        }.value
        deviceFiles = onDevice

        let planner = SyncPlanner()
        pendingByAlbum = SyncSelection.pendingCounts(
            in: planner.plan(library: libraryTracks, deviceFiles: onDevice))
        plan = planner.plan(library: tracks, deviceFiles: onDevice)
        progressLabel = ""
        phase = .planned
    }

    /// Fetch lyrics and missing covers for what was just copied.
    private func enrich(deviceRoot: URL) async {
        guard fetchLyrics || fetchCovers else { return }
        let enricher = Enricher(maxArtDimension: maxArtDimension)
        let all = tracks

        if fetchCovers {
            let selectedKeys = Set(all.map(SyncSelection.albumKey(for:)))
            let missing = Set(albumIssues.filter { $0.issues.contains(.noArtwork) }
                .map { FATName.foldedKey("\($0.albumArtist)/\($0.album)") })
                .intersection(selectedKeys)
            if !missing.isEmpty {
                progressLabel = "Looking up album art…"
                let r = await enricher.addCovers(
                    for: all, albumsMissingArt: missing, deviceRoot: deviceRoot)
                progressLabel = "Embedded art into \(r.coversEmbedded) file(s)"
                if r.coversEmbedded > 0 {
                    let fixedAlbums = Set(all
                        .filter { missing.contains(FATName.foldedKey(
                            "\($0.effectiveAlbumArtist)/\($0.effectiveAlbum)")) }
                        .map(\.effectiveAlbum))
                    for i in lastChanges.indices where fixedAlbums.contains(lastChanges[i].album) {
                        lastChanges[i].coverFetched = true
                    }
                }
            }
        }

        if fetchLyrics {
            let r = await enricher.addLyrics(for: all, deviceRoot: deviceRoot) { [weak self] done, total, title in
                Task { @MainActor in
                    self?.progressLabel = "Lyrics \(done)/\(total) — \(title)"
                    self?.progressFraction = total > 0 ? Double(done) / Double(total) : 1
                }
            }
            progressLabel = "Wrote \(r.lyricsWritten) lyrics file(s)"

            // Mark the rows whose .lrc now exists, so the results list shows it.
            for i in lastChanges.indices {
                let audio = deviceRoot.appendingPathComponent(
                    lastChanges[i].devicePath
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                let lrc = audio.deletingPathExtension().appendingPathExtension("lrc")
                lastChanges[i].lyricsAdded = FileManager.default.fileExists(atPath: lrc.path)
            }
        }
    }

    // MARK: - Sync

    /// "12 of 388 · 8.2 MB/s · about 4 min left".
    nonisolated static func progressText(_ p: SyncProgress, elapsed: TimeInterval) -> String {
        var text = "\(min(p.completed + 1, p.total)) of \(p.total)"
        if elapsed > 3, p.bytesCopied > 0 {
            let speed = Double(p.bytesCopied) / elapsed
            text += " · \(ByteFormat.string(Int64(speed)))/s"
            let left = Double(p.bytesTotal - p.bytesCopied) / speed
            if elapsed > 8 { text += " · " + etaText(left) }
        }
        return text
    }

    nonisolated static func etaText(_ seconds: Double) -> String {
        if seconds < 90 { return "under a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min left" }
        return "about \(minutes / 60) h \(minutes % 60) min left"
    }

    func sync() async {
        guard let plan, let device = selectedDevice else { return }
        phase = .syncing
        progressFraction = 0
        stopFlag.reset()
        isStopping = false
        let started = Date()
        let stop = stopFlag

        let engine = makeEngine()
        let root = device.url
        let name = playlistName.trimmingCharacters(in: .whitespaces)
        let selected = tracks

        // Progress arrives from a background thread; funnel it back to the
        // main actor before touching observable state.
        let result: Result<SyncResult, Error> = await Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = try engine.execute(plan: plan, deviceRoot: root, progress: { p in
                    let elapsed = Date().timeIntervalSince(started)
                    Task { @MainActor in
                        guard let self, !self.isStopping else { return }
                        self.progressFraction = p.bytesTotal > 0
                            ? Double(p.bytesCopied) / Double(p.bytesTotal) : 1
                        self.progressLabel = Self.progressText(p, elapsed: elapsed)
                    }
                }, cancel: { stop.isSet })
                if !name.isEmpty {
                    try PlaylistWriter().write(name: name, tracks: selected, deviceRoot: root)
                }
                return .success(r)
            } catch {
                return .failure(error)
            }
        }.value

        var listNote = ""
        if case .success(let r) = result {
            lastChanges = r.changes
            lastDeviceRoot = root
            await enrich(deviceRoot: root)
            // The player lists songs from its own cached list, not the card:
            // without this, what was just copied stays invisible on it.
            let copied = Set(r.changes.map(\.devicePath))
            let pairs = plan.actions.filter { copied.contains($0.devicePath) }
                .map { (track: $0.track, devicePath: $0.devicePath) }
            if let u = try? PlayerLibraryCache.update(deviceRoot: root, adding: pairs, dropDeadEntries: false),
               u.added > 0 {
                listNote = "Added \(u.added) to the player's song list."
            }
        }

        switch result {
        case .success(let r):
            progressFraction = 1
            progressLabel = ""
            var summary = r.cancelled ? "Stopped. Copied \(r.copied)" : "Copied \(r.copied)"
            if r.replaced > 0 { summary += ", replaced \(r.replaced)" }
            summary += " — \(ByteFormat.string(r.bytesCopied)) written."
            if r.artworkShrunk > 0 {
                summary += " Resized art on \(r.artworkShrunk) file(s)."
            }
            if !r.failed.isEmpty { summary += " \(r.failed.count) failed." }
            if r.verified > 0 {
                summary += " Every copied file was read back from the player and matched."
            }
            if !listNote.isEmpty { summary += " " + listNote }
            // Rescan so the plan reflects what is now on the player, then
            // restore the summary — scanAndPlan() leaves phase at .planned,
            // which would otherwise hide the result immediately. (Phase is
            // reset first so the busy guard in scanAndPlan lets it run.)
            phase = .idle
            await scanAndPlan()
            if phase == .planned { phase = .done(summary) }
        case .failure(let error):
            let message = (error as? DeviceError)?.description ?? error.localizedDescription
            phase = .failed(message)
        }
    }
}

/// Thread-safe "stop requested" switch shared with the copy running off the main actor.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
}
