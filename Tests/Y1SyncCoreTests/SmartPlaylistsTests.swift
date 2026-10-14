import XCTest
@testable import Y1SyncCore

final class SmartPlaylistsTests: XCTestCase {
    private func track(_ title: String, artist: String = "Artist",
                       genre: String? = nil, bpm: Double? = nil, moods: [String] = []) -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/lib/\(artist)/\(title).mp3"),
              title: title, artist: artist, album: "Album", fileSize: 100,
              genre: genre, bpm: bpm, moods: moods)
    }

    // MARK: - Mood parsing

    func testParsesOnlyPositiveMoodLabels() {
        let moods = LibraryScanner.parseMoods("Not acoustic;Not aggressive;Happy;Not party;Sad")
        XCTAssertEqual(moods, ["happy", "sad"])
    }

    func testMissingMoodTagParsesToEmpty() {
        XCTAssertEqual(LibraryScanner.parseMoods(nil), [])
    }

    // MARK: - Grouping

    func testGroupsByMoodAndATrackCanAppearInSeveralGroups() {
        let tracks = [
            track("a", moods: ["happy", "party"]),
            track("b", moods: ["sad"]),
        ]
        let groups = SmartPlaylistBuilder().byMood(tracks)
        XCTAssertEqual(Set(groups.keys), ["happy", "party", "sad"])
        XCTAssertEqual(groups["happy"]?.count, 1)
    }

    func testTracksWithNoMoodsAreNotGroupedAnywhere() {
        let groups = SmartPlaylistBuilder().byMood([track("a", moods: [])])
        XCTAssertTrue(groups.isEmpty)
    }

    func testGroupsByBPMRange() {
        let tracks = [
            track("slow", bpm: 70), track("mid", bpm: 100),
            track("fast", bpm: 130), track("veryfast", bpm: 180),
            track("untagged", bpm: nil),
        ]
        let groups = SmartPlaylistBuilder().byBPM(tracks)
        XCTAssertEqual(groups["Slow (under 90 BPM)"]?.count, 1)
        XCTAssertEqual(groups["Mid-tempo (90-119 BPM)"]?.count, 1)
        XCTAssertEqual(groups["Upbeat (120-149 BPM)"]?.count, 1)
        XCTAssertEqual(groups["Fast (150 BPM and up)"]?.count, 1)
        XCTAssertEqual(groups.values.reduce(0) { $0 + $1.count }, 4, "the untagged track is skipped, not miscategorized")
    }

    func testGroupsByGenre() {
        let tracks = [track("a", genre: "Indie Rock"), track("b", genre: "Indie Rock"), track("c", genre: nil)]
        let groups = SmartPlaylistBuilder().byGenre(tracks)
        XCTAssertEqual(groups["Indie Rock"]?.count, 2)
        XCTAssertEqual(groups.count, 1)
    }

    /// Regression test: a genre tag is often a whole list crammed into one
    /// field with mixed separators between rips. Without splitting, "Indie
    /// Rock", "Indie Rock, Rock" and "Indie Rock;Rock" each became their own
    /// near-duplicate playlist instead of "Indie Rock" pulling in all three.
    func testSplitsAMultiGenreTagSoATrackJoinsEveryGenreItLists() {
        let tracks = [
            track("a", genre: "Alternative Rock;Rock;Indie Rock"),
            track("b", genre: "Pop, Rock"),
            track("c", genre: "Indie Rock"),
        ]
        let groups = SmartPlaylistBuilder().byGenre(tracks)
        XCTAssertEqual(groups["Indie Rock"]?.count, 2, "tracks a and c")
        XCTAssertEqual(groups["Rock"]?.count, 2, "tracks a and b")
        XCTAssertEqual(groups["Alternative Rock"]?.count, 1)
        XCTAssertEqual(groups["Pop"]?.count, 1)
        XCTAssertNil(groups["Alternative Rock;Rock;Indie Rock"], "the raw unsplit string must not appear")
    }

    // MARK: - Writing

    func testWritesOnlyGroupsMeetingTheMinimum() throws {
        let device = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smartlists-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: device) }

        let tracks = [
            track("a", moods: ["happy"]), track("b", moods: ["happy"]), track("c", moods: ["happy"]),
            track("d", moods: ["sad"]), // only one track — below the minimum
        ]

        let result = try SmartPlaylistBuilder().writeAll(
            tracks: tracks, deviceRoot: device, bpm: false, genres: false, minimumTracks: 3)

        XCTAssertEqual(result.written.count, 1)
        XCTAssertEqual(result.written["Mood - Happy"], 3)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Playlists/Mood - Happy.m3u8").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Playlists/Mood - Sad.m3u8").path))
    }

    func testDisablingAKindSkipsIt() throws {
        let device = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smartlists-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: device) }

        let tracks = (1...3).map { track("t\($0)", genre: "Rock") }
        let result = try SmartPlaylistBuilder().writeAll(
            tracks: tracks, deviceRoot: device, moods: false, bpm: false, genres: true, minimumTracks: 3)

        XCTAssertEqual(result.written, ["Genre - Rock": 3])
    }
}
