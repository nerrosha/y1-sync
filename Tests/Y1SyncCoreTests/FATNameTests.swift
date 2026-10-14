import XCTest
@testable import Y1SyncCore

final class FATNameTests: XCTestCase {
    func testReplacesForbiddenCharacters() {
        XCTAssertEqual(FATName.component("AC/DC"), "AC-DC")
        XCTAssertEqual(FATName.component("Where?"), "Where-")
        XCTAssertEqual(FATName.component("a:b*c|d"), "a-b-c-d")
    }

    func testForbiddenSlashCannotInjectDirectory() {
        // A tag containing a slash must not create a nested folder.
        XCTAssertFalse(FATName.component("Rock/Pop").contains("/"))
    }

    func testStripsTrailingDotsAndSpaces() {
        // FAT silently drops these, which would desync playlist paths.
        XCTAssertEqual(FATName.component("Album."), "Album")
        XCTAssertEqual(FATName.component("Album   "), "Album")
        XCTAssertEqual(FATName.component("  Album"), "Album")
    }

    func testCollapsesWhitespaceRuns() {
        XCTAssertEqual(FATName.component("A   B"), "A B")
    }

    func testNeverReturnsEmpty() {
        XCTAssertEqual(FATName.component(""), "Unknown")
        XCTAssertEqual(FATName.component("   "), "Unknown")
        XCTAssertEqual(FATName.component("..."), "Unknown")
    }

    func testEscapesReservedDeviceNames() {
        XCTAssertEqual(FATName.component("CON"), "CON_")
        XCTAssertEqual(FATName.component("com1"), "com1_")
        XCTAssertEqual(FATName.component("CONCERT"), "CONCERT")
    }

    func testTruncatesLongNamesWithoutTrailingJunk() {
        let long = String(repeating: "x", count: 200)
        let out = FATName.component(long)
        XCTAssertEqual(out.count, FATName.maxComponentLength)

        let dotted = String(repeating: "y", count: 63) + ".  "
        XCTAssertFalse(FATName.component(dotted).hasSuffix("."))
    }

    func testFilenameKeepsExtension() {
        XCTAssertEqual(FATName.filename(base: "Song: Live", ext: "mp3"), "Song- Live.mp3")
        XCTAssertEqual(FATName.filename(base: "Song", ext: ""), "Song")
    }

    func testFoldedKeyIsCaseInsensitive() {
        // FAT32 is case-insensitive; comparisons must agree or files re-copy forever.
        XCTAssertEqual(FATName.foldedKey("/Music/Album/A.mp3"),
                       FATName.foldedKey("/MUSIC/album/a.MP3"))
    }
}
