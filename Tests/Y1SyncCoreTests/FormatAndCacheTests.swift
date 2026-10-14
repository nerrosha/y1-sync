import XCTest
@testable import Y1SyncCore

final class FormatAndCacheTests: XCTestCase {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: PlayerLimits

    func testLimitsFlagOnlyWhatExceedsThem() {
        let hiRes = Track(sourceURL: URL(fileURLWithPath: "/a.flac"), codec: "FLAC", sampleRate: 96_000, bitDepth: 24)
        let cd = Track(sourceURL: URL(fileURLWithPath: "/b.flac"), codec: "FLAC", sampleRate: 44_100, bitDepth: 16)
        let alac = Track(sourceURL: URL(fileURLWithPath: "/c.m4a"), codec: "ALAC", sampleRate: 44_100, bitDepth: 16)
        let mp3 = Track(sourceURL: URL(fileURLWithPath: "/d.mp3"), codec: "MP3")

        XCTAssertNil(PlayerLimits.none.problem(for: hiRes))
        let rate = PlayerLimits(maxSampleRate: 48_000)
        XCTAssertNotNil(rate.problem(for: hiRes)); XCTAssertNil(rate.problem(for: cd))
        let bits = PlayerLimits(maxBitDepth: 16)
        XCTAssertNotNil(bits.problem(for: hiRes)); XCTAssertNil(bits.problem(for: cd))
        XCTAssertNil(bits.problem(for: mp3))            // unknown depth is never flagged
        let noALAC = PlayerLimits(allowALAC: false)
        XCTAssertNotNil(noALAC.problem(for: alac)); XCTAssertNil(noALAC.problem(for: cd))
    }

    func testLabelsAndSummary() {
        let a = Track(sourceURL: URL(fileURLWithPath: "/a.flac"), codec: "FLAC", sampleRate: 44_100, bitDepth: 16)
        let b = Track(sourceURL: URL(fileURLWithPath: "/b.flac"), codec: "FLAC", sampleRate: 44_100, bitDepth: 16)
        let c = Track(sourceURL: URL(fileURLWithPath: "/c.mp3"), codec: "MP3")
        XCTAssertEqual(PlayerLimits.label(for: a), "FLAC 16-bit 44.1 kHz")
        let s = PlayerLimits.summary(of: [a, b, c])
        XCTAssertEqual(s.first?.count, 2); XCTAssertEqual(s.last?.label, "MP3")
    }

    func testUnsupportedFileIsReportedWithoutDecoding() async {
        let t = Track(sourceURL: URL(fileURLWithPath: "/nonexistent.flac"), fileSize: 1000,
                      codec: "FLAC", sampleRate: 192_000, bitDepth: 24)
        let r = await TrackHealth(limits: PlayerLimits(maxSampleRate: 96_000)).check(t)
        XCTAssertFalse(r.isPlayable)
        XCTAssertTrue(r.issues.contains { if case .unsupportedByPlayer = $0 { true } else { false } })
    }

    // MARK: M4A format

    private func atom(_ t: String, _ body: Data) -> Data { MP4Tags.atom(Array(t.utf8), body) }

    func testReadsALACDepthAndRate() throws {
        var cfg = Data(repeating: 0, count: 36)       // version/flags … sampleRate
        cfg[9] = 24
        cfg.replaceSubrange(24..<28, with: MP4Tags.put32(96_000))
        // Audio sample entry: 6 reserved + 2 index, 8 bytes version/vendor, channels, bits, … rate 16.16
        var entryBody = Data(repeating: 0, count: 28)
        entryBody[18] = 0; entryBody[19] = 16          // sample size field (wrong for ALAC)
        let entry = atom("alac", entryBody + atom("alac", cfg))
        let stsd = atom("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + entry)
        let moov = atom("moov", atom("trak", atom("mdia", atom("minf", atom("stbl", stsd)))))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a")
        try (atom("ftyp", Data("M4A ".utf8) + Data(count: 4)) + moov).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let f = MP4Tags.audioFormat(url)
        XCTAssertEqual(f?.codec, "ALAC"); XCTAssertEqual(f?.bitDepth, 24); XCTAssertEqual(f?.sampleRate, 96_000)
    }

    // MARK: ScanCache

    func testSecondScanReadsNothingNew() async throws {
        let lib = try dir(), cacheDir = try dir()
        defer { try? FileManager.default.removeItem(at: lib); try? FileManager.default.removeItem(at: cacheDir) }
        let file = lib.appendingPathComponent("a.mp3")
        try Data(repeating: 1, count: 100).write(to: file)

        let first = ScanCache(root: lib, directory: cacheDir)
        var tracks = await LibraryScanner().scan(root: lib, cache: first)
        XCTAssertEqual(tracks.count, 1)
        // Pretend a tag was read: a cache hit returns the stored value, not a re-read.
        var t = tracks[0]; t.title = "From cache"
        first.store(t, stamp: ScanCache.stamp(of: file)!); first.save()

        tracks = await LibraryScanner().scan(root: lib, cache: ScanCache(root: lib, directory: cacheDir))
        XCTAssertEqual(tracks.first?.title, "From cache")

        // A changed file is read again.
        try Data(repeating: 2, count: 150).write(to: file)
        tracks = await LibraryScanner().scan(root: lib, cache: ScanCache(root: lib, directory: cacheDir))
        XCTAssertNotEqual(tracks.first?.title, "From cache")
    }

    func testHealthyIsRememberedOnlyForSameChecks() throws {
        let lib = try dir(), cacheDir = try dir()
        defer { try? FileManager.default.removeItem(at: lib); try? FileManager.default.removeItem(at: cacheDir) }
        let file = lib.appendingPathComponent("a.mp3")
        try Data(repeating: 1, count: 100).write(to: file)
        let t = Track(sourceURL: file, fileSize: 100)

        let cache = ScanCache(root: lib, directory: cacheDir)
        XCTAssertNil(cache.healthyArt(for: t, signature: "x"))
        cache.markHealthy(t, signature: "x", hasEmbeddedArt: true); cache.save()
        let again = ScanCache(root: lib, directory: cacheDir)
        XCTAssertEqual(again.healthyArt(for: t, signature: "x"), true)
        XCTAssertNil(again.healthyArt(for: t, signature: "y"))
        try Data(repeating: 3, count: 120).write(to: file)
        XCTAssertNil(again.healthyArt(for: t, signature: "x"))
    }
}
