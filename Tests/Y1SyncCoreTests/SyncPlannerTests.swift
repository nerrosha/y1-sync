import XCTest
@testable import Y1SyncCore

final class SyncPlannerTests: XCTestCase {
    private func track(
        _ name: String,
        artist: String? = "Artist",
        albumArtist: String? = nil,
        album: String? = "Album",
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        size: Int64 = 100
    ) -> Track {
        Track(
            sourceURL: URL(fileURLWithPath: "/lib/\(name).mp3"),
            title: name,
            artist: artist,
            albumArtist: albumArtist,
            album: album,
            trackNumber: trackNumber,
            discNumber: discNumber,
            fileSize: size
        )
    }

    func testPlansCopyForMissingFile() {
        let plan = SyncPlanner().plan(library: [track("Song")], deviceFiles: [])
        XCTAssertEqual(plan.actions.count, 1)
        XCTAssertEqual(plan.actions.first?.kind, .copy)
        XCTAssertTrue(plan.upToDate.isEmpty)
    }

    func testSkipsFileAlreadyPresentWithSameSize() {
        let t = track("Song", size: 100)
        let path = DeviceLayout().path(for: t)
        let plan = SyncPlanner().plan(
            library: [t],
            deviceFiles: [DeviceFile(path: path, size: 100)]
        )
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.upToDate.count, 1)
    }

    func testReplacesFileWithDifferentSize() {
        // A partially-written file from an interrupted copy must be redone.
        let t = track("Song", size: 100)
        let path = DeviceLayout().path(for: t)
        let plan = SyncPlanner().plan(
            library: [t],
            deviceFiles: [DeviceFile(path: path, size: 40)]
        )
        XCTAssertEqual(plan.actions.first?.kind, .replace)
    }

    func testDeviceComparisonIsCaseInsensitive() {
        // The device is FAT32; treating paths case-sensitively would re-copy
        // everything on every run.
        let t = track("Song", size: 100)
        let path = DeviceLayout().path(for: t).uppercased()
        let plan = SyncPlanner().plan(
            library: [t],
            deviceFiles: [DeviceFile(path: path, size: 100)]
        )
        XCTAssertTrue(plan.isEmpty, "uppercase device path should still match")
    }

    func testReportsCollisionsInsteadOfOverwriting() {
        // Two distinct files that sanitise to the same device path.
        let a = track("Song?", size: 1)
        let b = track("Song*", size: 2)
        let plan = SyncPlanner().plan(library: [a, b], deviceFiles: [])
        XCTAssertEqual(plan.actions.count, 1, "only one file may claim the path")
        XCTAssertEqual(plan.collisions.count, 1)
        XCTAssertEqual(plan.collisions.values.first?.count, 2)
    }

    func testBytesToCopySumsOnlyPlannedActions() {
        let present = track("Have", size: 500)
        let missing = track("Need", size: 250)
        let plan = SyncPlanner().plan(
            library: [present, missing],
            deviceFiles: [DeviceFile(path: DeviceLayout().path(for: present), size: 500)]
        )
        XCTAssertEqual(plan.bytesToCopy, 250)
    }
}

final class DeviceLayoutTests: XCTestCase {
    func testZeroPadsTrackNumbersSoBrowserSortsCorrectly() {
        let layout = DeviceLayout()
        let t = Track(sourceURL: URL(fileURLWithPath: "/a.mp3"),
                      title: "Song", artist: "A", album: "B", trackNumber: 2)
        XCTAssertTrue(layout.path(for: t).hasSuffix("/02 Song.mp3"))
    }

    func testPrefixesDiscNumberForMultiDiscSets() {
        let layout = DeviceLayout()
        let t = Track(sourceURL: URL(fileURLWithPath: "/a.mp3"),
                      title: "Song", artist: "A", album: "B",
                      trackNumber: 1, discNumber: 2)
        XCTAssertTrue(layout.path(for: t).hasSuffix("/2-01 Song.mp3"))
    }

    func testSingleDiscDoesNotGetDiscPrefix() {
        let layout = DeviceLayout()
        let t = Track(sourceURL: URL(fileURLWithPath: "/a.mp3"),
                      title: "Song", artist: "A", album: "B",
                      trackNumber: 1, discNumber: 1)
        XCTAssertTrue(layout.path(for: t).hasSuffix("/01 Song.mp3"))
    }

    func testGroupsCompilationByAlbumArtistNotTrackArtist() {
        // Otherwise a compilation scatters one folder per guest artist.
        let layout = DeviceLayout()
        let t = Track(sourceURL: URL(fileURLWithPath: "/a.mp3"),
                      title: "Song", artist: "Guest",
                      albumArtist: "Various Artists", album: "Comp")
        XCTAssertTrue(layout.path(for: t).hasPrefix("/Music/Various Artists/Comp/"))
    }

    func testUntaggedFileFallsBackToFilename() {
        let layout = DeviceLayout()
        let t = Track(sourceURL: URL(fileURLWithPath: "/lib/mystery.mp3"))
        XCTAssertEqual(layout.path(for: t), "/Music/Unknown Artist/Unknown Album/mystery.mp3")
    }
}
