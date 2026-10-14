import XCTest
@testable import Y1SyncCore

final class LRCTests: XCTestCase {
    func testParsesStandardTimestamps() {
        let lines = LRC.parse("""
        [00:19.16] When you were here before
        [00:24.09] Couldn't look you in the eye
        """)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].time, 19.16, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "When you were here before")
        XCTAssertEqual(lines[1].time, 24.09, accuracy: 0.001)
    }

    func testHandlesMinutesCorrectly() {
        let lines = LRC.parse("[02:05.50]late line")
        XCTAssertEqual(lines.first?.time ?? 0, 125.5, accuracy: 0.001)
    }

    func testAcceptsMillisecondsAndMissingFraction() {
        XCTAssertEqual(LRC.parse("[00:10.123]a").first?.time ?? 0, 10.123, accuracy: 0.001)
        XCTAssertEqual(LRC.parse("[00:10]a").first?.time ?? 0, 10, accuracy: 0.001)
    }

    /// A repeated chorus is often written once with several timestamps.
    func testExpandsMultipleTimestampsOnOneLine() {
        let lines = LRC.parse("[00:10.00][01:10.00]chorus")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.text), ["chorus", "chorus"])
        XCTAssertEqual(lines[1].time, 70, accuracy: 0.001)
    }

    /// [ar:...] and friends are metadata, not lyrics — showing them would put
    /// junk at the top of the song.
    func testSkipsMetadataHeaders() {
        let lines = LRC.parse("""
        [ar:Radiohead]
        [ti:Creep]
        [by:someone]
        [00:19.16]real line
        """)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "real line")
    }

    func testSortsOutOfOrderLines() {
        let lines = LRC.parse("""
        [00:30.00]third
        [00:10.00]first
        [00:20.00]second
        """)
        XCTAssertEqual(lines.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(lines.map(\.index), [0, 1, 2])
    }

    func testIgnoresGarbageAndEmptyInput() {
        XCTAssertTrue(LRC.parse("").isEmpty)
        XCTAssertTrue(LRC.parse("just some text\nno timestamps").isEmpty)
        XCTAssertTrue(LRC.parse("[99:99.99]bad").isEmpty, "seconds must be < 60")
    }

    func testKeepsEmptyLyricLines() {
        // Instrumental breaks are legitimately blank but still timed.
        let lines = LRC.parse("[00:05.00]\n[00:10.00]words")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "")
    }

    // MARK: - Highlighting

    func testActiveIndexTracksPlayback() {
        let lines = LRC.parse("[00:10.00]a\n[00:20.00]b\n[00:30.00]c")
        XCTAssertNil(LRC.activeIndex(of: lines, at: 5), "nothing before the first line")
        XCTAssertEqual(LRC.activeIndex(of: lines, at: 10), 0)
        XCTAssertEqual(LRC.activeIndex(of: lines, at: 19.9), 0)
        XCTAssertEqual(LRC.activeIndex(of: lines, at: 20), 1)
        XCTAssertEqual(LRC.activeIndex(of: lines, at: 999), 2, "stays on the last line")
    }

    func testActiveIndexOnEmptyLyrics() {
        XCTAssertNil(LRC.activeIndex(of: [], at: 10))
    }

    func testLoadsFileBesideAudio() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let audio = dir.appendingPathComponent("01 Song.mp3")
        try Data("audio".utf8).write(to: audio)
        try "[00:01.00]hi".write(to: dir.appendingPathComponent("01 Song.lrc"),
                                atomically: true, encoding: .utf8)

        XCTAssertEqual(LRC.load(besideAudio: audio).first?.text, "hi")
        XCTAssertTrue(LRC.load(besideAudio: dir.appendingPathComponent("missing.mp3")).isEmpty)
    }
}

final class FileChangeTests: XCTestCase {
    private func change() -> FileChange {
        FileChange(devicePath: "/Music/A/B/01 T.mp3",
                   track: Track(sourceURL: URL(fileURLWithPath: "/lib/a.mp3"),
                                title: "T", artist: "A", album: "B"))
    }

    func testUntouchedFileReportsNothing() {
        XCTAssertFalse(change().didAnything)
        XCTAssertTrue(change().summary.isEmpty)
    }

    func testSummarisesEachKindOfFix() {
        var c = change()
        c.artFrom = "1600x1600"
        c.artTo = "500x500"
        c.lyricsAdded = true
        c.albumArtistCorrected = "Some Artist"

        XCTAssertTrue(c.didAnything)
        let joined = c.summary.joined(separator: "; ")
        XCTAssertTrue(joined.contains("1600x1600 → 500x500"))
        XCTAssertTrue(joined.contains("lyrics added"))
        XCTAssertTrue(joined.contains("Some Artist"))
    }
}
