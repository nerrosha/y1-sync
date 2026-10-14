import XCTest
@testable import Y1SyncCore

final class SyncSelectionTests: XCTestCase {
    private func track(
        _ title: String, artist: String = "Artist", albumArtist: String? = nil,
        album: String = "Album", size: Int64 = 100
    ) -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/lib/\(artist)/\(album)/\(title).mp3"),
              title: title, artist: artist, albumArtist: albumArtist,
              album: album, fileSize: size)
    }

    func testGroupsByAlbumArtistThenAlbum() {
        let tracks = [
            track("a", artist: "Kino", album: "Gruppa krovi"),
            track("b", artist: "Kino", album: "Gruppa krovi"),
            track("c", artist: "Kino", album: "Zvezda"),
            track("d", artist: "Aphex Twin", album: "Drukqs"),
        ]
        let groups = SyncSelection.group(tracks)

        XCTAssertEqual(groups.map(\.name), ["Aphex Twin", "Kino"])
        XCTAssertEqual(groups[1].albums.map(\.title), ["Gruppa krovi", "Zvezda"])
        XCTAssertEqual(groups[1].albums[0].trackCount, 2)
        XCTAssertEqual(groups[1].trackCount, 3)
        XCTAssertEqual(groups[1].bytes, 300)
    }

    func testCompilationStaysOneAlbum() {
        // Guest artists differ but album artist is shared: one album, not three.
        let tracks = [
            track("1", artist: "A", albumArtist: "Various Artists", album: "Hits"),
            track("2", artist: "B", albumArtist: "Various Artists", album: "Hits"),
            track("3", artist: "C", albumArtist: "Various Artists", album: "Hits"),
        ]
        let groups = SyncSelection.group(tracks)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].albums.count, 1)
        XCTAssertEqual(groups[0].albums[0].trackCount, 3)
    }

    func testKeyIgnoresCase() {
        XCTAssertEqual(SyncSelection.albumKey(for: track("x", artist: "MGMT", album: "Oracular Spectacular")),
                       SyncSelection.albumKey(for: track("y", artist: "mgmt", album: "oracular spectacular")))
    }

    func testCaseVariantsGroupTogether() {
        let groups = SyncSelection.group([
            track("x", artist: "MGMT", album: "Congratulations"),
            track("y", artist: "mgmt", album: "congratulations"),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].albums.count, 1)
        XCTAssertEqual(groups[0].albums[0].trackCount, 2)
    }

    func testNaturalSortOrder() {
        let groups = SyncSelection.group([
            track("a", artist: "10cc"), track("b", artist: "2 Unlimited"), track("c", artist: "abba"),
        ])
        XCTAssertEqual(groups.map(\.name), ["2 Unlimited", "10cc", "abba"])
    }

    func testFilterDropsOnlyExcludedAlbums() {
        let keep = track("keep", album: "Keep")
        let drop = track("drop", album: "Drop")
        let excluded: Set = [SyncSelection.albumKey(for: drop)]

        let out = SyncSelection.filter([keep, drop], excluding: excluded)
        XCTAssertEqual(out, [keep])
    }

    func testEmptyExclusionKeepsEverything() {
        let tracks = [track("a"), track("b", album: "Other")]
        XCTAssertEqual(SyncSelection.filter(tracks, excluding: []), tracks)
    }

    func testUnknownExclusionKeysAreHarmless() {
        // A remembered exclusion for an album no longer in the library must not
        // affect anything else.
        let tracks = [track("a")]
        XCTAssertEqual(SyncSelection.filter(tracks, excluding: ["gone/forever"]), tracks)
    }

    func testPendingCountsPerAlbum() {
        let a1 = track("1", album: "A"), a2 = track("2", album: "A"), b1 = track("3", album: "B")
        let plan = SyncPlanner().plan(library: [a1, a2, b1], deviceFiles: [])
        let counts = SyncSelection.pendingCounts(in: plan)
        XCTAssertEqual(counts[SyncSelection.albumKey(for: a1)], 2)
        XCTAssertEqual(counts[SyncSelection.albumKey(for: b1)], 1)
    }

    func testPlanningOnFilteredLibraryCopiesOnlySelected() {
        let keep = track("keep", album: "Keep"), drop = track("drop", album: "Drop")
        let selected = SyncSelection.filter([keep, drop],
                                            excluding: [SyncSelection.albumKey(for: drop)])
        let plan = SyncPlanner().plan(library: selected, deviceFiles: [])
        XCTAssertEqual(plan.actions.map(\.track), [keep])
    }
}
