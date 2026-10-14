import XCTest
@testable import Y1SyncCore

final class SyncEngineTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("y1sync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// Regression: NSTemporaryDirectory() on macOS lives under /var, a symlink
    /// to /private/var. Comparing an unresolved root against resolved
    /// enumerator paths made every device file invisible, so each sync
    /// re-copied the entire library.
    func testDevicePathIsStableAcrossSymlinkedRoots() throws {
        let engine = SyncEngine()
        let unresolved = URL(fileURLWithPath: "/tmp/y1sync-symlink-probe")
        let file = unresolved.appendingPathComponent("Music/A/B/01 Song.mp3")
        XCTAssertEqual(engine.devicePath(of: file, root: unresolved),
                       "/Music/A/B/01 Song.mp3")

        // Same file named through the resolved path must yield the same result.
        let resolvedFile = URL(fileURLWithPath: "/private/tmp/y1sync-symlink-probe")
            .appendingPathComponent("Music/A/B/01 Song.mp3")
        XCTAssertEqual(engine.devicePath(of: resolvedFile, root: unresolved),
                       "/Music/A/B/01 Song.mp3")
    }

    func testScanDeviceFindsExistingAudioAndIgnoresOtherFiles() throws {
        try makeFile(tmp.appendingPathComponent("Music/Artist/Album/01 A.mp3"), bytes: 10)
        try makeFile(tmp.appendingPathComponent("Music/Artist/Album/cover.jpg"), bytes: 5)

        let found = SyncEngine().scanDevice(root: tmp)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.path, "/Music/Artist/Album/01 A.mp3")
        XCTAssertEqual(found.first?.size, 10)
    }

    func testSyncIsIdempotent() throws {
        let src = tmp.appendingPathComponent("lib/song.mp3")
        try makeFile(src, bytes: 128)
        let device = tmp.appendingPathComponent("device")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)

        let track = Track(sourceURL: src, title: "Song", artist: "A",
                          album: "B", trackNumber: 1, fileSize: 128)
        let engine = SyncEngine()

        let first = SyncPlanner().plan(library: [track], deviceFiles: engine.scanDevice(root: device))
        XCTAssertEqual(first.actions.count, 1)
        _ = try engine.execute(plan: first, deviceRoot: device)

        // Second run must find the file already present and plan nothing.
        let second = SyncPlanner().plan(library: [track], deviceFiles: engine.scanDevice(root: device))
        XCTAssertTrue(second.isEmpty, "re-sync should be a no-op")
        XCTAssertEqual(second.upToDate.count, 1)
    }

    func testTruncatedFileIsReplaced() throws {
        let src = tmp.appendingPathComponent("lib/song.mp3")
        try makeFile(src, bytes: 128)
        let device = tmp.appendingPathComponent("device")
        let dest = device.appendingPathComponent("Music/A/B/01 Song.mp3")
        try makeFile(dest, bytes: 0)   // interrupted earlier copy

        let track = Track(sourceURL: src, title: "Song", artist: "A",
                          album: "B", trackNumber: 1, fileSize: 128)
        let engine = SyncEngine()
        let plan = SyncPlanner().plan(library: [track], deviceFiles: engine.scanDevice(root: device))

        XCTAssertEqual(plan.actions.first?.kind, .replace)
        let result = try engine.execute(plan: plan, deviceRoot: device)
        XCTAssertEqual(result.replaced, 1)

        let size = try FileManager.default
            .attributesOfItem(atPath: dest.path)[.size] as? Int
        XCTAssertEqual(size, 128)
    }

    func testExecuteLeavesNoPartialFilesBehind() throws {
        let src = tmp.appendingPathComponent("lib/song.mp3")
        try makeFile(src, bytes: 64)
        let device = tmp.appendingPathComponent("device")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)

        let track = Track(sourceURL: src, title: "Song", artist: "A", album: "B", fileSize: 64)
        let engine = SyncEngine()
        let plan = SyncPlanner().plan(library: [track], deviceFiles: [])
        _ = try engine.execute(plan: plan, deviceRoot: device)

        let leftovers = FileManager.default
            .enumerator(at: device, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "part" } ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testMissingSourceIsReportedNotFatal() throws {
        let device = tmp.appendingPathComponent("device")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)

        let ghost = Track(sourceURL: tmp.appendingPathComponent("lib/gone.mp3"),
                          title: "Gone", artist: "A", album: "B", fileSize: 10)
        let plan = SyncPlanner().plan(library: [ghost], deviceFiles: [])
        let result = try SyncEngine().execute(plan: plan, deviceRoot: device)

        XCTAssertEqual(result.copied, 0)
        XCTAssertEqual(result.failed.count, 1)
    }

    // MARK: Verified copy and cancel

    private func library(_ n: Int, bytes: Int = 3_000_000) throws -> [Track] {
        try (1...n).map { i in
            let src = tmp.appendingPathComponent("lib/s\(i).mp3")
            try makeFile(src, bytes: bytes)
            return Track(sourceURL: src, title: "S\(i)", artist: "A", album: "B",
                         trackNumber: i, fileSize: Int64(bytes))
        }
    }

    func testEveryCopiedFileIsVerifiedAndIdentical() throws {
        let tracks = try library(3)
        let device = tmp.appendingPathComponent("device")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        let plan = SyncPlanner().plan(library: tracks, deviceFiles: [])
        let result = try SyncEngine().execute(plan: plan, deviceRoot: device)
        XCTAssertEqual(result.copied, 3)
        XCTAssertEqual(result.verified, 3)
        XCTAssertFalse(result.cancelled)
        for a in plan.actions {
            let copy = device.appendingPathComponent(a.devicePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: a.track.sourceURL))
        }
    }

    func testCancelKeepsFinishedFilesAndLeavesNoPartial() throws {
        let tracks = try library(4)
        let device = tmp.appendingPathComponent("device")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        let plan = SyncPlanner().plan(library: tracks, deviceFiles: [])
        let done = Counter()
        let result = try SyncEngine().execute(plan: plan, deviceRoot: device,
                                              progress: { p in if p.completed >= 1 { done.bump() } },
                                              cancel: { done.value > 0 })
        XCTAssertTrue(result.cancelled)
        XCTAssertGreaterThanOrEqual(result.copied, 1)
        XCTAssertLessThan(result.copied, 4)
        let files = FileManager.default.enumerator(at: device, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        XCTAssertTrue(files.filter { $0.pathExtension == "part" }.isEmpty)
        XCTAssertEqual(files.filter { $0.pathExtension == "mp3" }.count, result.copied)
    }

}

final class PlaylistWriterTests: XCTestCase {
    func testWritesExtm3uWithDeviceAbsolutePaths() {
        let t = Track(sourceURL: URL(fileURLWithPath: "/lib/a.mp3"),
                      title: "Song", artist: "A", album: "B",
                      trackNumber: 1, durationSeconds: 123.6)
        let body = PlaylistWriter().contents(name: "Mix", tracks: [t])

        XCTAssertTrue(body.hasPrefix("#EXTM3U"))
        XCTAssertTrue(body.contains("#EXTINF:124,A - Song"), "duration should round")
        XCTAssertTrue(body.contains("/Music/A/B/01 Song.mp3"))
    }

    func testUnknownDurationUsesMinusOne() {
        let t = Track(sourceURL: URL(fileURLWithPath: "/lib/a.mp3"), title: "S", artist: "A")
        XCTAssertTrue(PlaylistWriter().contents(name: "M", tracks: [t]).contains("#EXTINF:-1,"))
    }

    // MARK: - Playlist folder detection

    private func makeDevice() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("playlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Different Y1 firmware builds name the playlist folder differently —
    /// this must use whichever one the firmware already created, not assume
    /// a name and create a second, ignored folder next to it.
    func testUsesTheFirmwareYPlaylistsFolderWhenItAlreadyExists() throws {
        let device = try makeDevice()
        defer { try? FileManager.default.removeItem(at: device) }
        try FileManager.default.createDirectory(
            at: device.appendingPathComponent("Y1_Playlists"), withIntermediateDirectories: true)

        XCTAssertEqual(PlaylistWriter.playlistFolder(deviceRoot: device).lastPathComponent, "Y1_Playlists")
    }

    func testUsesPlainPlaylistsFolderWhenThatsWhatExists() throws {
        let device = try makeDevice()
        defer { try? FileManager.default.removeItem(at: device) }
        try FileManager.default.createDirectory(
            at: device.appendingPathComponent("Playlists"), withIntermediateDirectories: true)

        XCTAssertEqual(PlaylistWriter.playlistFolder(deviceRoot: device).lastPathComponent, "Playlists")
    }

    func testFallsBackToCreatingPlaylistsWhenNoneExist() throws {
        let device = try makeDevice()
        defer { try? FileManager.default.removeItem(at: device) }
        XCTAssertEqual(PlaylistWriter.playlistFolder(deviceRoot: device).lastPathComponent, "Playlists")
    }

    func testWritingActuallyLandsInTheDetectedFolder() throws {
        let device = try makeDevice()
        defer { try? FileManager.default.removeItem(at: device) }
        try FileManager.default.createDirectory(
            at: device.appendingPathComponent("Y1_Playlists"), withIntermediateDirectories: true)

        let track = Track(sourceURL: URL(fileURLWithPath: "/lib/song.mp3"),
                          title: "Song", artist: "A", album: "B", fileSize: 100)
        _ = try PlaylistWriter().write(name: "Test", tracks: [track], deviceRoot: device)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Y1_Playlists/Test.m3u8").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Playlists/Test.m3u8").path),
            "must not also create a second, unused folder")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

/// Writes a scratch file to a real player to prove flush + read-back work on FAT.
/// Set Y1_REAL_DEVICE_DIR to a folder on the player; the scratch folder is removed afterwards.
final class RealDeviceCopyTests: XCTestCase {
    func testVerifiedCopyOnRealPlayer() throws {
        guard let dir = ProcessInfo.processInfo.environment["Y1_REAL_DEVICE_DIR"] else { throw XCTSkip("no player") }
        let base = URL(fileURLWithPath: dir).appendingPathComponent(".y1sync-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).bin")
        try Data((0..<(20 * 1024 * 1024)).map { UInt8($0 & 255) }).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        let dst = base.appendingPathComponent("x.part")
        let t0 = Date()
        try SyncEngine.copyVerified(from: src, to: dst, cancel: nil) { _ in }
        let secs = Date().timeIntervalSince(t0)
        print("REAL COPY OK: 20 MB in \(String(format: "%.1f", secs))s")
        XCTAssertEqual(try Data(contentsOf: dst).count, 20 * 1024 * 1024)
    }
}
