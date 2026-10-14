import XCTest
@testable import Y1SyncCore

final class SimilarAlbumsTests: XCTestCase {
    private func t(_ title: String, _ album: String, artist: String = "Malcolm Todd") -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/m/\(artist)/\(album)/\(title).flac"),
              title: title, artist: artist, albumArtist: artist, album: album, fileSize: 1)
    }

    private let standard = ["Harry Styles", "Make Me a Better Man", "Who's the Fool", "Chest Pain (I Love)", "Doll",
                            "Bleed", "Good Job Malcom", "Lying", "Walk to Class", "Florence", "Concrete", "I Do",
                            "Cheer Me On", "I'll Come Back for You"]

    /// The real case: a typo'd copy, a deluxe edition and a lone single.
    func testMalcolmToddsThreeAlbumsAreOne() {
        var tracks = standard.map { t($0, "Malcom Todd") }
        tracks += (standard.map { $0 == "Bleed" ? "Bleed feat. Omar Apollo" : $0 } + ["Attention", "Nemo", "Zip Up My Fly", "Original"])
            .map { t($0, "Malcolm Todd (still)") }
        tracks.append(t("Bleed", "Malcolm Todd"))
        tracks += ["Earrings", "Roommates", "Thailand"].map { t($0, "Sweet Boy") }    // a different album

        let groups = SimilarAlbums().find(in: tracks)
        XCTAssertEqual(groups.count, 1)
        let g = groups[0]
        XCTAssertEqual(Set(g.variants.map(\.title)), ["Malcom Todd", "Malcolm Todd (still)", "Malcolm Todd"])
        XCTAssertEqual(g.suggested, "Malcolm Todd (still)", "the fullest edition")
        XCTAssertEqual(g.trackCount, 14 + 18 + 1)
        XCTAssertGreaterThan(g.sharedSongs, 10, "merging will leave these as duplicates")
    }

    func testPartOneAndPartTwoStayApart() {
        let tracks = ["A", "B", "C"].map { t($0, "Pt. 1") } + ["D", "E", "F"].map { t($0, "Pt. 2") }
        XCTAssertTrue(SimilarAlbums().find(in: tracks).isEmpty)
    }

    func testStudioAndLiveAlbumsAreNotMergedBecauseTheirNamesMatch() {
        let studio = ["One", "Two", "Three", "Four"].map { t($0, "Songs", artist: "X") }
        let live = ["Alpha", "Beta", "Gamma", "Delta"].map { t($0, "Songs (Live)", artist: "X") }
        XCTAssertTrue(SimilarAlbums().find(in: studio + live).isEmpty, "same base name, no songs in common")
    }

    func testSameNameAndSongsUnderDifferentArtistsIsLeftAlone() {
        let a = ["One", "Two"].map { t($0, "Greatest Hits", artist: "A") }
        let b = ["One", "Two"].map { t($0, "Greatest Hits (Deluxe)", artist: "B") }
        XCTAssertTrue(SimilarAlbums().find(in: a + b).isEmpty)
    }

    func testTypoRule() {
        XCTAssertTrue(SimilarAlbums.isTypo("malcom todd", "malcolm todd"))
        XCTAssertTrue(SimilarAlbums.isTypo("siamese dream", "siamese dreem"))
        XCTAssertFalse(SimilarAlbums.isTypo("pt 1", "pt 2"))
        XCTAssertFalse(SimilarAlbums.isTypo("sweet boy", "sweet girl"))
        XCTAssertFalse(SimilarAlbums.isTypo("same name", "same name"))
        XCTAssertFalse(SimilarAlbums.isTypo("abc", "abd"), "too short to trust")
    }

    func testBaseNameDropsEditionNotesPunctuationAndAccents() {
        XCTAssertEqual(SimilarAlbums.base("Siamese Dream (Deluxe Edition) [2011]"), "siamese dream")
        XCTAssertEqual(SimilarAlbums.base("I Love You."), "i love you")
        XCTAssertEqual(SimilarAlbums.base("Café Del Mar"), "cafe del mar")
    }
}
