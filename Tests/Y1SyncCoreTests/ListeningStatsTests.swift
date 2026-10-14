import XCTest
@testable import Y1SyncCore

final class ListeningStatsTests: XCTestCase {
    private func t(_ title: String, artist: String, album: String, size: Int64 = 100) -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/m/\(artist)/\(album)/\(title).flac"), title: title, artist: artist,
              albumArtist: artist, album: album, fileSize: size)
    }

    func testParsesTheFirmwareLog() {
        let log = """
        #AUDIOSCROBBLER/1.1
        #TZ/UNKNOWN
        #CLIENT/JJY 1.0
        Sombr\tI Barely Know Her\tdime\t\t225\tL\t1788361079\t
        Sombr\tI Barely Know Her\tcrushing\t\t200\tS\t1788361300\t
        broken line
        """
        let e = ScrobbleLog.parse(log)
        XCTAssertEqual(e.count, 2)
        XCTAssertTrue(e[0].listened); XCTAssertFalse(e[1].listened)
        XCTAssertEqual(e[0].seconds, 225)
        XCTAssertEqual(e[0].date.timeIntervalSince1970, 1788361079)
    }

    func testCountsPlaysPerAlbumAndSkipsSkipped() {
        let tracks = [t("dime", artist: "Sombr", album: "I Barely Know Her"),
                      t("crushing", artist: "Sombr", album: "I Barely Know Her"),
                      t("Luna", artist: "The Smashing Pumpkins", album: "Siamese Dream"),
                      t("Doll", artist: "Malcolm Todd", album: "Sweet Boy")]
        let entries = ScrobbleLog.parse("""
        sombr\tI Barely Know Her\tdime\t\t225\tL\t100\t
        Sombr\tI Barely Know Her\tdime\t\t225\tL\t200\t
        Sombr\tI Barely Know Her\tcrushing\t\t200\tS\t300\t
        Smashing Pumpkins\tSiamese Dream\tLuna\t\t200\tL\t400\t
        """)
        let s = ListeningStats(entries: entries, deviceTracks: tracks)
        XCTAssertEqual(s.plays, 3)
        XCTAssertEqual(s.topArtists.first?.plays, 2)                       // "sombr" and "Sombr" are one artist
        let byTitle = Dictionary(uniqueKeysWithValues: s.albums.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["I Barely Know Her"]?.plays, 2)
        XCTAssertEqual(byTitle["Siamese Dream"]?.plays, 1)                 // "The" ignored when matching
        XCTAssertEqual(byTitle["Sweet Boy"]?.plays, 0)
        XCTAssertNil(byTitle["Sweet Boy"]?.lastPlayed)
    }

    func testSuggestsNeverPlayedFirstUntilTheTargetIsMet() {
        let tracks = [t("a", artist: "A", album: "Loved", size: 500),
                      t("b", artist: "B", album: "Never Big", size: 400),
                      t("c", artist: "C", album: "Never Small", size: 100)]
        let s = ListeningStats(entries: ScrobbleLog.parse("A\tLoved\ta\t\t100\tL\t100\t"), deviceTracks: tracks)
        let picked = s.leastListened(freeing: 450)
        XCTAssertEqual(picked.map(\.title), ["Never Big", "Never Small"])
        XCTAssertFalse(picked.contains { $0.title == "Loved" })
        XCTAssertEqual(s.leastListened(freeing: 0).count, 0)
    }
}
