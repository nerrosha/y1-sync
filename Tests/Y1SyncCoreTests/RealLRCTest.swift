import XCTest
@testable import Y1SyncCore

/// Parses an .lrc actually produced by LRCLIB during a live sync, rather than
/// a hand-written fixture. Skips when that file isn't present.
final class RealLRCTest: XCTestCase {
    func testParsesRealLRCLibOutput() throws {
        let path = "/tmp/y1netdev2/Music/Radiohead/Pablo Honey/01 Creep.lrc"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                          "no live-fetched lyrics available")

        let text = try String(contentsOfFile: path, encoding: .utf8)
        let lines = LRC.parse(text)

        XCTAssertGreaterThan(lines.count, 10, "a real song should have many lines")
        XCTAssertTrue(lines.allSatisfy { $0.time >= 0 })
        XCTAssertEqual(lines, lines.sorted { $0.time < $1.time }, "must come out in order")
        XCTAssertFalse(lines.contains { $0.text.hasPrefix("[") }, "no stray timestamps in text")

        print("real file: \(lines.count) lines, first = "
              + "\(lines[0].time)s '\(lines[0].text)'")
        XCTAssertNil(LRC.activeIndex(of: lines, at: 0))
        XCTAssertNotNil(LRC.activeIndex(of: lines, at: lines[0].time + 0.5))
    }
}
