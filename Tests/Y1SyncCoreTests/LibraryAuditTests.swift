import XCTest
@testable import Y1SyncCore

final class LibraryAuditTests: XCTestCase {
    private func track(
        _ title: String,
        artist: String = "Artist",
        albumArtist: String? = nil,
        album: String = "Album",
        n: Int? = nil
    ) -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/lib/\(title).mp3"),
              title: title, artist: artist, albumArtist: albumArtist,
              album: album, trackNumber: n, fileSize: 100)
    }

    /// The whole point: on the device a split album artist becomes several
    /// folders each holding one track.
    func testDetectsSplitAlbumArtistAndSuggestsTheCommonOne() {
        let tracks = [
            track("a", albumArtist: "Radiohead", n: 1),
            track("b", albumArtist: "Radiohead", n: 2),
            track("c", albumArtist: "radiohead ft. someone", n: 3),
        ]
        let report = try? XCTUnwrap(LibraryAudit().audit(tracks).first)
        XCTAssertNotNil(report)
        XCTAssertTrue(report!.issues.contains { if case .splitAlbumArtist = $0 { return true }; return false })
        XCTAssertEqual(report!.suggestedAlbumArtist, "Radiohead", "majority value should win")
    }

    func testUnifyAlbumArtistPutsAlbumInOneFolder() {
        let tracks = [
            track("a", albumArtist: "Radiohead", n: 1),
            track("b", albumArtist: "Radiohead", n: 2),
            track("c", albumArtist: "radiohead ft. someone", n: 3),
        ]
        let audit = LibraryAudit()
        let fixed = audit.unifyAlbumArtists(tracks, using: audit.audit(tracks))

        let folders = Set(fixed.map { ($0 as Track).effectiveAlbumArtist })
        XCTAssertEqual(folders.count, 1, "all tracks should now group together")

        let layout = DeviceLayout()
        let dirs = Set(fixed.map { (layout.path(for: $0) as NSString).deletingLastPathComponent })
        XCTAssertEqual(dirs.count, 1)
    }

    func testFlagsMissingTrackNumbers() {
        let tracks = [track("a", n: 1), track("b")]
        let report = LibraryAudit().audit(tracks).first
        XCTAssertTrue(report?.issues.contains {
            if case .missingTrackNumbers(let c) = $0 { return c == 1 }; return false
        } ?? false)
    }

    func testFlagsDuplicateTrackNumbers() {
        let tracks = [track("a", n: 1), track("b", n: 1)]
        let report = LibraryAudit().audit(tracks).first
        XCTAssertTrue(report?.issues.contains {
            if case .duplicateTrackNumbers(let n) = $0 { return n == [1] }; return false
        } ?? false)
    }

    func testFlagsGapsOnlyWhenFullyNumbered() {
        // 1 and 3 present, 2 missing.
        let gapped = LibraryAudit().audit([track("a", n: 1), track("c", n: 3)])
        XCTAssertTrue(gapped.first?.issues.contains {
            if case .incompleteNumbering(let missing, _) = $0 { return missing == [2] }; return false
        } ?? false)

        // With an unnumbered track present, "missing" would be misleading.
        let partial = LibraryAudit().audit([track("a", n: 1), track("c", n: 3), track("x")])
        XCTAssertFalse(partial.first?.issues.contains {
            if case .incompleteNumbering = $0 { return true }; return false
        } ?? true)
    }

    func testCleanAlbumWithArtworkProducesNoReport() {
        let tracks = [track("a", albumArtist: "A", n: 1), track("b", albumArtist: "A", n: 2)]
        let key = FATName.foldedKey("A/Album")
        XCTAssertTrue(LibraryAudit().audit(tracks, artworkPresent: [key]).isEmpty)
    }

    func testReportsMissingArtwork() {
        let tracks = [track("a", albumArtist: "A", n: 1)]
        let report = LibraryAudit().audit(tracks).first
        XCTAssertTrue(report?.issues.contains(.noArtwork) ?? false)
    }

    // MARK: - Stray tracks (right tags, wrong folder)

    private func trackAt(_ folder: String, _ title: String, album: String) -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/lib/\(folder)/\(title).mp3"),
              title: title, artist: "Whoever", album: album, fileSize: 100)
    }

    func testFlagsATrackThatDisagreesWithItsFolderMajority() {
        let tracks = [
            trackAt("Mixed", "1", album: "Real Album"),
            trackAt("Mixed", "2", album: "Real Album"),
            trackAt("Mixed", "3", album: "Real Album"),
            trackAt("Mixed", "4", album: "Somebody Else's Song"),
        ]
        let strays = LibraryAudit().strayTracks(tracks)
        XCTAssertEqual(strays.count, 1)
        XCTAssertEqual(strays.first?.taggedAlbum, "Somebody Else's Song")
        XCTAssertEqual(strays.first?.folderMajorityAlbum, "Real Album")
    }

    func testNoMajorityMeansNothingIsFlagged() {
        // A genuine grab-bag folder — every track a different album — has no
        // majority to compare against, so flagging any one of them as the
        // "odd one out" would be arbitrary noise.
        let tracks = [
            trackAt("Grabbag", "1", album: "Album One"),
            trackAt("Grabbag", "2", album: "Album Two"),
            trackAt("Grabbag", "3", album: "Album Three"),
        ]
        XCTAssertTrue(LibraryAudit().strayTracks(tracks).isEmpty)
    }

    func testSmallFolderIsNotCheckedAtAll() {
        // Two tracks in a folder don't establish a meaningful "majority" —
        // it would just be flagging whichever one happens to differ.
        let tracks = [
            trackAt("Tiny", "1", album: "A"),
            trackAt("Tiny", "2", album: "B"),
        ]
        XCTAssertTrue(LibraryAudit().strayTracks(tracks).isEmpty)
    }

    func testConsistentFolderFlagsNothing() {
        let tracks = (1...4).map { trackAt("Clean", "\($0)", album: "Same Album") }
        XCTAssertTrue(LibraryAudit().strayTracks(tracks).isEmpty)
    }
}

final class TrackHealthTests: XCTestCase {
    func testEmptyFileIsBlocking() async {
        let t = Track(sourceURL: URL(fileURLWithPath: "/nope.mp3"), fileSize: 0)
        let report = await TrackHealth().check(t)
        XCTAssertEqual(report.issues, [.emptyFile])
        XCTAssertFalse(report.isPlayable)
    }

    func testMissingFileIsReportedNotCrashed() async {
        let t = Track(sourceURL: URL(fileURLWithPath: "/definitely/missing.mp3"), fileSize: 1234)
        let report = await TrackHealth().check(t)
        XCTAssertFalse(report.isPlayable)
    }

    func testBlockingClassification() {
        XCTAssertTrue(TrackIssue.zeroDuration.isBlocking)
        XCTAssertTrue(TrackIssue.noAudioTrack.isBlocking)
        // Oversized art is worth fixing but the track still plays.
        XCTAssertFalse(TrackIssue.oversizedEmbeddedArt(bytes: 9_000_000, pixels: "3000x3000").isBlocking)
        XCTAssertFalse(TrackIssue.missingTags(["title"]).isBlocking)
    }

    func testOversizedArtMessageMentionsTheRisk() {
        let msg = TrackIssue.oversizedEmbeddedArt(bytes: 5_000_000, pixels: "3000x3000").describe
        XCTAssertTrue(msg.contains("crash"))
    }
}
