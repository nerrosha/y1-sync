import XCTest
@testable import Y1SyncCore

final class DeviceTidyTests: XCTestCase {
    private var device: URL!

    override func setUpWithError() throws {
        device = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tidy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: device)
    }

    private func write(_ relative: String, bytes: Int = 32) throws -> URL {
        let url = device.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func track(at url: URL, title: String, artist: String,
                       album: String, n: Int?) -> Track {
        Track(sourceURL: url, title: title, artist: artist, albumArtist: artist,
              album: album, trackNumber: n, fileSize: 32)
    }

    func testPlansRenameIntoStandardLayout() throws {
        let url = try write("Music/Weird Folder (2012)/random name.mp3")
        let t = track(at: url, title: "Dreaming", artist: "Mac DeMarco", album: "2", n: 2)

        let plan = DeviceTidy().plan(deviceRoot: device, tracks: [t])
        XCTAssertEqual(plan.moves.count, 1)
        guard case .move(let to) = plan.moves[0].kind else { return XCTFail("expected a move") }
        XCTAssertEqual(to, "/Music/Mac DeMarco/2/02 Dreaming.mp3")
    }

    func testFileAlreadyInPlaceIsNotMoved() throws {
        let url = try write("Music/Mac DeMarco/2/02 Dreaming.mp3")
        let t = track(at: url, title: "Dreaming", artist: "Mac DeMarco", album: "2", n: 2)
        XCTAssertTrue(DeviceTidy().plan(deviceRoot: device, tracks: [t]).moves.isEmpty)
    }

    func testApplyMovesTheFile() throws {
        let url = try write("Music/Odd/name.mp3")
        let t = track(at: url, title: "Song", artist: "A", album: "B", n: 1)

        let tidy = DeviceTidy()
        let result = tidy.apply(tidy.plan(deviceRoot: device, tracks: [t]), deviceRoot: device)

        XCTAssertEqual(result.moved, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Music/A/B/01 Song.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Overwriting would destroy a track; the collision is reported instead.
    func testNeverOverwritesAnExistingFile() throws {
        _ = try write("Music/A/B/01 Song.mp3", bytes: 999)
        let url = try write("Music/Odd/name.mp3")
        let t = track(at: url, title: "Song", artist: "A", album: "B", n: 1)

        let tidy = DeviceTidy()
        let result = tidy.apply(tidy.plan(deviceRoot: device, tracks: [t]), deviceRoot: device)

        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.failures.count, 1)
        // The original target must be untouched.
        let kept = try Data(contentsOf: device.appendingPathComponent("Music/A/B/01 Song.mp3"))
        XCTAssertEqual(kept.count, 999)
    }

    func testIdentifiesMacOSJunk() {
        XCTAssertTrue(DeviceTidy.isJunk("._01 Song.flac"))
        XCTAssertTrue(DeviceTidy.isJunk(".DS_Store"))
        XCTAssertTrue(DeviceTidy.isJunk(".Trashes"))
        XCTAssertFalse(DeviceTidy.isJunk("01 Song.flac"))
        XCTAssertFalse(DeviceTidy.isJunk("_underscore.mp3"))
    }

    func testFindsAppleDoubleSidecarByProbing() throws {
        // These are invisible to directory enumeration on a real FAT volume,
        // so they can only be found by testing the sibling path.
        let real = try write("Music/A/B/01 Song.mp3")
        _ = try write("Music/A/B/._01 Song.mp3", bytes: 82)

        let sidecar = try XCTUnwrap(DeviceTidy.appleDoubleSibling(of: real))
        XCTAssertEqual(sidecar.lastPathComponent, "._01 Song.mp3")
        XCTAssertNil(DeviceTidy.appleDoubleSibling(of: sidecar), "no sidecar of a sidecar")
    }

    func testRemovesJunkAndReportsBytes() throws {
        _ = try write("Music/A/B/01 Song.mp3")
        _ = try write("Music/A/B/.DS_Store", bytes: 100)

        let tidy = DeviceTidy()
        let plan = tidy.plan(deviceRoot: device, tracks: [])
        XCTAssertFalse(plan.junk.isEmpty)

        let result = tidy.apply(plan, deviceRoot: device)
        XCTAssertGreaterThan(result.junkRemoved, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Music/A/B/.DS_Store").path))
        // The music must survive.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Music/A/B/01 Song.mp3").path))
    }

    func testKeepsJunkWhenAskedTo() throws {
        _ = try write("Music/A/.DS_Store", bytes: 10)
        let tidy = DeviceTidy()
        let result = tidy.apply(tidy.plan(deviceRoot: device, tracks: []),
                                deviceRoot: device, removeJunk: false)
        XCTAssertEqual(result.junkRemoved, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Music/A/.DS_Store").path))
    }

    func testRemovesFoldersLeftEmpty() throws {
        let url = try write("Music/Old Folder/name.mp3")
        let t = track(at: url, title: "Song", artist: "A", album: "B", n: 1)

        let tidy = DeviceTidy()
        let result = tidy.apply(tidy.plan(deviceRoot: device, tracks: [t]), deviceRoot: device)

        XCTAssertEqual(result.moved, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Music/Old Folder").path),
            "the emptied folder should be gone")
    }

    /// Regression coverage for the confusion a real user hit: after tidy
    /// moves tracks out, the old pre-tidy folder is left holding only a
    /// cover image — which looks exactly like "the album vanished" when
    /// browsing. The cover should be salvaged into the new album folder and
    /// the empty shell removed.
    func testLeftoverFolderSalvagesCoverThenRemoves() throws {
        let url = try write("Music/Old Artist Folder/01 Song.mp3")
        try Data(repeating: 0xFF, count: 10).write(
            to: device.appendingPathComponent("Music/Old Artist Folder/cover.jpg"))
        let t = track(at: url, title: "Song", artist: "A", album: "B", n: 1)

        let tidy = DeviceTidy()
        let plan = tidy.plan(deviceRoot: device, tracks: [t])
        XCTAssertEqual(plan.leftoverFolders.count, 1)

        let result = tidy.apply(plan, deviceRoot: device)

        XCTAssertEqual(result.leftoverFoldersRemoved, 1)
        XCTAssertEqual(result.coversSalvaged, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Music/Old Artist Folder").path),
            "the leftover shell should be gone")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Music/A/B/cover.jpg").path),
            "the cover should have moved to the new album folder")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Music/A/B/01 Song.mp3").path),
            "the track itself must still be there")
    }

    func testLeftoverFolderWithNoCoverIsStillRemoved() throws {
        let url = try write("Music/Old Folder/01 Song.mp3")
        _ = try write("Music/Old Folder/ripinfo.log", bytes: 5)
        let t = track(at: url, title: "Song", artist: "A", album: "B", n: 1)

        let tidy = DeviceTidy()
        let result = tidy.apply(tidy.plan(deviceRoot: device, tracks: [t]), deviceRoot: device)

        XCTAssertEqual(result.leftoverFoldersRemoved, 1)
        XCTAssertEqual(result.coversSalvaged, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Music/Old Folder").path))
    }

    /// A folder is only truly a "leftover" once every track that used to
    /// live there has actually moved out. The plan can't foresee a
    /// destination collision (that's only known once a move is attempted),
    /// so it may optimistically list such a folder as removable — but apply
    /// re-checks the real filesystem before deleting anything, so a track
    /// left behind by a collision is never lost.
    func testFolderStillHoldingATrackAfterCollisionIsNotDeleted() throws {
        _ = try write("Music/A/B/01 Song.mp3")
        let staying = try write("Music/Old Folder/01 Song.mp3")
        let moving = try write("Music/Old Folder/02 Other.mp3")
        let t1 = track(at: staying, title: "Song", artist: "A", album: "B", n: 1)
        let t2 = track(at: moving, title: "Other", artist: "A", album: "B", n: 2)

        let tidy = DeviceTidy()
        let plan = tidy.plan(deviceRoot: device, tracks: [t1, t2])
        let result = tidy.apply(plan, deviceRoot: device)

        XCTAssertEqual(result.leftoverFoldersRemoved, 0,
                       "the surviving track means this folder was never actually a leftover shell")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Music/Old Folder/01 Song.mp3").path),
            "the track that couldn't move must survive")
    }

    /// A playlist names tracks by device-absolute path. Renaming a track
    /// without updating any playlist that pointed at it would leave the
    /// playlist silently broken — the next thing to notice would be the
    /// player refusing to play a "missing" track.
    func testRenameRepairsPlaylistPaths() throws {
        let url = try write("Music/Odd/name.mp3")
        let t = track(at: url, title: "Song", artist: "A", album: "B", n: 1)

        let playlist = device.appendingPathComponent("Y1_Playlists/Mix.m3u8")
        try FileManager.default.createDirectory(at: playlist.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "#EXTM3U\n#EXTINF:200,A - Song\n/Music/Odd/name.mp3\n"
            .write(to: playlist, atomically: true, encoding: .utf8)

        let tidy = DeviceTidy()
        let result = tidy.apply(tidy.plan(deviceRoot: device, tracks: [t]), deviceRoot: device)

        XCTAssertEqual(result.playlistsRepaired, 1)
        let updated = try String(contentsOf: playlist, encoding: .utf8)
        XCTAssertTrue(updated.contains("/Music/A/B/01 Song.mp3"))
        XCTAssertFalse(updated.contains("/Music/Odd/name.mp3"))
        XCTAssertTrue(updated.contains("#EXTINF:200,A - Song"), "the comment line must survive untouched")
    }

    func testPlaylistUntouchedWhenNothingItReferencesMoves() throws {
        let url = try write("Music/A/B/01 Song.mp3")
        let t = track(at: url, title: "Song", artist: "A", album: "B", n: 1)

        let playlist = device.appendingPathComponent("Y1_Playlists/Mix.m3u8")
        try FileManager.default.createDirectory(at: playlist.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let original = "#EXTM3U\n/Music/A/B/01 Song.mp3\n"
        try original.write(to: playlist, atomically: true, encoding: .utf8)

        let tidy = DeviceTidy()
        let result = tidy.apply(tidy.plan(deviceRoot: device, tracks: [t]), deviceRoot: device)

        XCTAssertEqual(result.playlistsRepaired, 0, "nothing moved, so nothing to repair")
        XCTAssertEqual(try String(contentsOf: playlist, encoding: .utf8), original)
    }

    func testPlanningChangesNothingOnDisk() throws {
        let url = try write("Music/Odd/name.mp3")
        _ = try write("Music/Odd/.DS_Store")
        let t = track(at: url, title: "Song", artist: "A", album: "B", n: 1)

        _ = DeviceTidy().plan(deviceRoot: device, tracks: [t])

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Music/Odd/.DS_Store").path))
    }
}

final class ChangeReportTests: XCTestCase {
    func testSyncReportGroupsByAlbum() {
        func t(_ n: String, _ album: String) -> Track {
            Track(sourceURL: URL(fileURLWithPath: "/l/\(n).flac"), title: n, artist: "A", album: album, fileSize: 100)
        }
        let plan = SyncPlan(actions: [
            SyncAction(kind: .copy, track: t("1", "X"), devicePath: "/Music/A/X/01 1.flac"),
            SyncAction(kind: .copy, track: t("2", "X"), devicePath: "/Music/A/X/02 2.flac"),
            SyncAction(kind: .replace, track: t("3", "Y"), devicePath: "/Music/A/Y/03 3.flac", reason: .truncated),
        ], upToDate: [t("4", "Z")])
        let r = SyncReport(plan: plan)
        XCTAssertEqual(r.albums.count, 2)
        XCTAssertEqual(r.added, 2); XCTAssertEqual(r.replaced, 1); XCTAssertEqual(r.unchanged, 1)
        XCTAssertEqual(r.albums.last?.reasons, ["cut off"])
        XCTAssertTrue(r.text.contains("A — X: +2"))
    }

    func testTidyPreviewFlagsRenamesThatWouldBeRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Music/A/New"), withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("Music/A/New/01 One.flac"))   // target already taken
        let plan = TidyPlan(moves: [
            TidyAction(path: "/Music/A/Old/01 One.flac", kind: .move(to: "/Music/A/New/01 One.flac"), bytes: 1),
            TidyAction(path: "/Music/A/Old/02 Two.flac", kind: .move(to: "/Music/A/New/02 Two.flac"), bytes: 1),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let pv = TidyPreview(plan: plan, deviceRoot: root)
        XCTAssertEqual(pv.blocked.count, 1)
        XCTAssertEqual(pv.folders.count, 1)
        XCTAssertEqual(pv.folders.first?.count, 2)
        XCTAssertEqual(pv.folders.first?.blocked, 1)
    }
}
