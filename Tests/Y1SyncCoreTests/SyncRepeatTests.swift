import XCTest
@testable import Y1SyncCore

/// Regression: after a sync that rewrites tags (oversized cover shrunk, album
/// artist corrected), the copy's size differs from the source's, so the planner
/// used to treat every such file as "replace" on every later sync — re-copying
/// the whole library each time and wiping what Lyrics / Find art had added.
final class SyncRepeatTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("y1sync-repeat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: fixtures

    private func le(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    private func jpeg(side: Int) throws -> Data {
        try TestImages.make(side: side, format: .jpeg, blocks: 60)
    }

    /// FLAC with a Vorbis comment and a big cover, followed by fake audio.
    private func makeFLAC(cover: Data, audio: Int = 6000) -> Data {
        var comment = Data()
        let vendor = Data("t".utf8)
        comment.append(le(vendor.count)); comment.append(vendor)
        let fields = ["TITLE=Song", "ARTIST=A", "ALBUM=B", "TRACKNUMBER=1"].map { Data($0.utf8) }
        comment.append(le(fields.count))
        for f in fields { comment.append(le(f.count)); comment.append(f) }

        let blocks: [(UInt8, Data)] = [
            (0, Data(repeating: 0, count: 34)), (4, comment),
            (6, FLAC.makePictureBlock(jpeg: cover, width: 1600, height: 1600)),
        ]
        var out = Data("fLaC".utf8)
        for (i, b) in blocks.enumerated() {
            out.append(Data([(i == blocks.count - 1 ? 0x80 : 0) | b.0,
                             UInt8((b.1.count >> 16) & 0xFF), UInt8((b.1.count >> 8) & 0xFF), UInt8(b.1.count & 0xFF)]))
            out.append(b.1)
        }
        out.append(Data(repeating: 0x5A, count: audio))
        return out
    }

    private func setUpLibrary() throws -> (track: Track, device: URL) {
        let src = tmp.appendingPathComponent("lib/song.flac")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = makeFLAC(cover: try jpeg(side: 1600))
        try data.write(to: src)
        let device = tmp.appendingPathComponent("device")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        let track = Track(sourceURL: src, title: "Song", artist: "A", albumArtist: "A", album: "B",
                          trackNumber: 1, fileSize: Int64(data.count))
        return (track, device)
    }

    // MARK: tests

    func testSyncWithShrunkCoverIsNotReplannedAfterwards() throws {
        let (track, device) = try setUpLibrary()
        let engine = SyncEngine()

        let first = SyncPlanner().plan(library: [track], deviceFiles: engine.scanDevice(root: device))
        let result = try engine.execute(plan: first, deviceRoot: device)
        XCTAssertEqual(result.artworkShrunk, 1, "fixture must really change the file's size")

        let onDevice = engine.scanDevice(root: device)
        XCTAssertNotEqual(onDevice.first?.size, track.fileSize, "size differs after the cover shrank")

        let second = SyncPlanner().plan(library: [track], deviceFiles: onDevice)
        XCTAssertTrue(second.actions.isEmpty, "a file already synced must not be planned again")
        XCTAssertEqual(second.upToDate.count, 1)
    }

    func testCoverAddedLaterOnThePlayerDoesNotMakeItStale() throws {
        let (track, device) = try setUpLibrary()
        let engine = SyncEngine(artworkOptimizer: nil)
        _ = try engine.execute(plan: SyncPlanner().plan(library: [track], deviceFiles: []), deviceRoot: device)

        // Enrich on the player rewrites the metadata (here: a different cover).
        let file = device.appendingPathComponent("Music/A/B/01 Song.flac")
        let bigger = makeFLAC(cover: try jpeg(side: 900))
        try bigger.write(to: file)

        let plan = SyncPlanner().plan(library: [track], deviceFiles: engine.scanDevice(root: device))
        XCTAssertTrue(plan.actions.isEmpty)
    }

    func testTruncatedCopyIsStillReplacedWithAReason() throws {
        let (track, device) = try setUpLibrary()
        let file = device.appendingPathComponent("Music/A/B/01 Song.flac")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let full = try Data(contentsOf: track.sourceURL)
        try full.prefix(full.count - 3000).write(to: file)      // interrupted copy

        let plan = SyncPlanner().plan(library: [track], deviceFiles: SyncEngine().scanDevice(root: device))
        XCTAssertEqual(plan.actions.count, 1)
        XCTAssertEqual(plan.actions.first?.kind, .replace)
        XCTAssertEqual(plan.actions.first?.reason, .truncated)
    }

    func testChangedAudioIsReplacedAsChanged() throws {
        let (track, device) = try setUpLibrary()
        let file = device.appendingPathComponent("Music/A/B/01 Song.flac")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeFLAC(cover: try jpeg(side: 300), audio: 9000).write(to: file)   // longer audio

        let plan = SyncPlanner().plan(library: [track], deviceFiles: SyncEngine().scanDevice(root: device))
        XCTAssertEqual(plan.actions.first?.reason, .changed)
    }

    func testMissingFileHasNewReason() {
        let t = Track(sourceURL: URL(fileURLWithPath: "/lib/x.mp3"), title: "X", artist: "A", album: "B", fileSize: 10)
        XCTAssertEqual(SyncPlanner().plan(library: [t], deviceFiles: []).actions.first?.reason, .new)
    }

    // MARK: AudioSize

    func testAudioSizeIgnoresFLACMetadata() throws {
        let a = tmp.appendingPathComponent("a.flac"), b = tmp.appendingPathComponent("b.flac")
        try makeFLAC(cover: try jpeg(side: 1600)).write(to: a)
        try makeFLAC(cover: try jpeg(side: 100)).write(to: b)
        XCTAssertEqual(AudioSize.of(a, size: 0), 6000)
        XCTAssertEqual(AudioSize.of(a, size: 0), AudioSize.of(b, size: 0))
    }

    func testAudioSizeOfMP3SkipsID3v2() throws {
        let url = tmp.appendingPathComponent("a.mp3")
        var d = Data("ID3".utf8)
        d.append(contentsOf: [3, 0, 0, 0, 0, 0, 20])        // v2.3, syncsafe size 20
        d.append(Data(repeating: 0, count: 20))
        d.append(Data(repeating: 0xAA, count: 500))
        try d.write(to: url)
        XCTAssertEqual(AudioSize.of(url, size: Int64(d.count)), 500)

        let plain = tmp.appendingPathComponent("b.mp3")
        try Data(repeating: 0xAA, count: 500).write(to: plain)
        XCTAssertEqual(AudioSize.of(plain, size: 500), 500)
    }

    func testAudioSizeUnknownForFormatsWeDoNotRewrite() throws {
        let url = tmp.appendingPathComponent("a.m4a")
        try Data(repeating: 1, count: 50).write(to: url)
        XCTAssertNil(AudioSize.of(url, size: 50))
    }
}
