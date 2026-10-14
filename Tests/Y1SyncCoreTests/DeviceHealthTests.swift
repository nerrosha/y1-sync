import XCTest
@testable import Y1SyncCore

final class DeviceHealthTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("y1sync-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    @discardableResult
    private func write(_ rel: String, _ text: String) throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func track(_ url: URL, title: String = "Song", artist: String = "A", duration: Double? = 200) -> Track {
        Track(sourceURL: url, title: title, artist: artist, albumArtist: artist, album: "B",
              trackNumber: 1, durationSeconds: duration,
              fileSize: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
    }

    /// A checker that calls any file whose contents are "BAD" broken.
    private var judge: @Sendable (Track) async -> TrackReport {
        { t in
            let bad = (try? String(contentsOf: t.sourceURL, encoding: .utf8)) == "BAD"
            return TrackReport(track: t, issues: bad ? [.undecodable("test")] : [])
        }
    }

    func testScanFindsOnlyBrokenFilesAndNamesTheirDevicePath() async throws {
        let device = tmp.appendingPathComponent("player")
        let good = try write("player/Music/A/B/01 Fine.flac", "ok")
        let bad = try write("player/Music/A/B/02 Broken.flac", "BAD")

        let found = await DeviceHealth(check: judge).scan(
            deviceTracks: [track(good, title: "Fine"), track(bad, title: "Broken")],
            deviceRoot: device, library: [])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.devicePath, "/Music/A/B/02 Broken.flac")
        XCTAssertNil(found.first?.replacement)
    }

    func testScanOffersAnIntactLibraryCopyAndSkipsBrokenOnes() async throws {
        let device = tmp.appendingPathComponent("player")
        let bad = try write("player/Music/A/B/01 Song.flac", "BAD")
        let brokenLib = try write("lib/old/Song.flac", "BAD")
        let goodLib = try write("lib/new/Song.flac", "fine")

        let found = await DeviceHealth(check: judge).scan(
            deviceTracks: [track(bad)], deviceRoot: device,
            library: [track(brokenLib), track(goodLib), track(goodLib, title: "Other")])
        XCTAssertEqual(found.first?.replacement?.sourceURL, goodLib)
    }

    func testReplacementMustBeTheSameLength() {
        let a = track(URL(fileURLWithPath: "/l/a.flac"), duration: 200)
        let live = track(URL(fileURLWithPath: "/l/b.flac"), duration: 400)
        XCTAssertTrue(DeviceHealth.candidates(for: a, in: [live], tolerance: 5).isEmpty)
    }

    func testFixReplacesFromLibraryAndUndoNeverClobbersTheGoodCopy() async throws {
        let device = tmp.appendingPathComponent("player")
        let bad = try write("player/Music/A/B/01 Song.flac", "BAD")
        let goodLib = try write("lib/Song.flac", "fine audio")
        let item = BrokenFile(report: TrackReport(track: track(bad), issues: [.undecodable("x")]),
                              devicePath: "/Music/A/B/01 Song.flac", replacement: track(goodLib))

        let out = DeviceHealth(check: judge).fix([item], deviceRoot: device, removeUnrepairable: false,
                                                 engine: SyncEngine(artworkOptimizer: nil))
        XCTAssertEqual(out.replaced, 1)
        XCTAssertEqual(try String(contentsOf: bad, encoding: .utf8), "fine audio")

        // Undo never overwrites: the spot is now taken by the good copy, so the
        // broken one is left in quarantine instead of clobbering fine audio.
        let undone = UndoLog.undoMostRecent(deviceRoot: device)
        XCTAssertEqual(undone?.restored, 0)
        XCTAssertEqual(undone?.failed, ["/Music/A/B/01 Song.flac"])
        XCTAssertEqual(try String(contentsOf: bad, encoding: .utf8), "fine audio")
    }

    func testUnrepairableFilesAreOnlyRemovedWhenAsked() throws {
        let device = tmp.appendingPathComponent("player")
        let bad = try write("player/Music/A/B/01 Song.flac", "BAD")
        let item = BrokenFile(report: TrackReport(track: track(bad), issues: [.emptyFile]),
                              devicePath: "/Music/A/B/01 Song.flac", replacement: nil)
        let health = DeviceHealth(check: judge)

        XCTAssertEqual(health.fix([item], deviceRoot: device, removeUnrepairable: false).removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))

        XCTAssertEqual(health.fix([item], deviceRoot: device, removeUnrepairable: true).removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
        XCTAssertEqual(UndoLog.undoMostRecent(deviceRoot: device)?.restored, 1)
        XCTAssertEqual(try String(contentsOf: bad, encoding: .utf8), "BAD")
    }
}
