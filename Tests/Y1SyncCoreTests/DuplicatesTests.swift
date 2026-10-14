import XCTest
@testable import Y1SyncCore

final class DuplicatesTests: XCTestCase {
    private func track(
        _ title: String, artist: String = "A", ext: String = "mp3",
        size: Int64 = 100, duration: Double? = 200
    ) -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/lib/\(UUID().uuidString).\(ext)"),
              title: title, artist: artist, album: "Album",
              durationSeconds: duration, fileSize: size)
    }

    // MARK: - Normalisation

    func testStripsDecorationsThatHideDuplicates() {
        let a = Duplicates.normalise("Creep (Remastered 2011)")
        let b = Duplicates.normalise("Creep")
        XCTAssertEqual(a, b)
    }

    func testStripsBracketsAndFeatureCredits() {
        XCTAssertEqual(Duplicates.normalise("Song [Explicit]"), "song")
        XCTAssertEqual(Duplicates.normalise("Song feat. Someone"), "song someone")
    }

    func testIgnoresCaseAndPunctuation() {
        XCTAssertEqual(Duplicates.normalise("Don't Look Back!"),
                       Duplicates.normalise("dont look back"))
    }

    // MARK: - Grouping

    func testFindsSameSongInTwoFormats() {
        let groups = Duplicates().find(in: [
            track("Creep", ext: "mp3", size: 5_000_000),
            track("Creep", ext: "flac", size: 30_000_000),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.tracks.count, 2)
    }

    func testDifferentSongsAreNotGrouped() {
        XCTAssertTrue(Duplicates().find(in: [track("One"), track("Two")]).isEmpty)
    }

    func testSameTitleByDifferentArtistsIsNotADuplicate() {
        let groups = Duplicates().find(in: [
            track("Home", artist: "Artist One"),
            track("Home", artist: "Artist Two"),
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    /// A 30-second interlude sharing a name with the full track is not a
    /// duplicate, and neither is a long live version.
    func testDurationSeparatesUnrelatedTracksWithTheSameName() {
        let groups = Duplicates().find(in: [
            track("Intro", duration: 25),
            track("Intro", duration: 240),
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    func testNearIdenticalDurationsStillGroup() {
        let groups = Duplicates().find(in: [
            track("Song", duration: 200),
            track("Song", duration: 202),
        ])
        XCTAssertEqual(groups.count, 1)
    }

    func testUnknownDurationsAreStillCompared() {
        let groups = Duplicates().find(in: [
            track("Song", duration: nil),
            track("Song", duration: nil),
        ])
        XCTAssertEqual(groups.count, 1)
    }

    // MARK: - Which copy to keep

    func testPrefersLosslessOverLossy() {
        let mp3 = track("Song", ext: "mp3", size: 8_000_000)
        let flac = track("Song", ext: "flac", size: 30_000_000)
        let group = Duplicates().find(in: [mp3, flac]).first
        XCTAssertEqual(group?.recommendedKeeper?.fileExtension, "flac")
    }

    func testAmongSameFormatPrefersLargerFile() {
        let small = track("Song", ext: "mp3", size: 3_000_000)
        let big = track("Song", ext: "mp3", size: 9_000_000)
        let group = Duplicates().find(in: [small, big]).first
        XCTAssertEqual(group?.recommendedKeeper?.fileSize, 9_000_000)
    }

    func testWastedBytesExcludesTheKeeper() {
        let group = Duplicates().find(in: [
            track("Song", ext: "flac", size: 30_000_000),
            track("Song", ext: "mp3", size: 5_000_000),
            track("Song", ext: "mp3", size: 4_000_000),
        ]).first
        XCTAssertEqual(group?.wastedBytes, 9_000_000, "everything except the FLAC")
    }

    /// Regression test for a real bug found against a live device: when two
    /// exact duplicates tie on both format and size (the common case — the
    /// same rip copied twice), the plain quality-based keeper used to fall
    /// back to scan order. Tag completeness breaks that tie sensibly when the
    /// copies' tags actually differ.
    func testTiesPreferTheBetterTaggedCopy() {
        let untagged = Track(sourceURL: URL(fileURLWithPath: "/lib/a.flac"),
                              title: "Song", artist: nil, album: nil,
                              durationSeconds: 200, fileSize: 30_000_000)
        let tagged = Track(sourceURL: URL(fileURLWithPath: "/lib/b.flac"),
                            title: "Song", artist: "Real Artist", album: "Real Album",
                            trackNumber: 3, durationSeconds: 200, fileSize: 30_000_000)
        let group = DuplicateGroup(key: "k", tracks: [untagged, tagged])
        XCTAssertEqual(group.recommendedKeeper?.sourceURL, tagged.sourceURL)
    }

    /// Regression test for the same live-device bug in the case that actually
    /// bit: exact duplicates with byte-identical tags (same rip, copied
    /// twice), where tag completeness is a no-op tie. One copy had already
    /// survived a `tidy` pass into its correct location; the other was a
    /// stray left behind when tidy found that spot already taken. Without a
    /// location-aware tiebreak, `recommendedKeeper` recommended deleting the
    /// well-organised copy and keeping the stray — the opposite of what a
    /// user would want.
    func testOnDeviceLocationTiebreakPrefersTheAlreadyTidiedCopy() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("y1sync-dupes-test-\(UUID().uuidString)")
        let layout = DeviceLayout()
        let base = Track(sourceURL: URL(fileURLWithPath: "/ignored.flac"),
                          title: "Song", artist: "Real Artist", album: "Real Album",
                          trackNumber: 3, durationSeconds: 200, fileSize: 30_000_000)

        var tidied = base
        tidied.sourceURL = URL(fileURLWithPath: layout.path(for: base), relativeTo: root)

        var stray = base
        stray.sourceURL = root.appendingPathComponent("Music/Some Other Folder/03 03 - Song.flac")

        let group = DuplicateGroup(key: "k", tracks: [stray, tidied])
        XCTAssertEqual(group.recommendedKeeper(onDeviceRoot: root)?.sourceURL.path, tidied.sourceURL.path)
    }

    func testUntitledTracksAreNotAllGroupedTogether() {
        let a = Track(sourceURL: URL(fileURLWithPath: "/lib/x.mp3"), fileSize: 1)
        let b = Track(sourceURL: URL(fileURLWithPath: "/lib/y.mp3"), fileSize: 1)
        // Both fall back to their filenames, which differ.
        XCTAssertTrue(Duplicates().find(in: [a, b]).isEmpty)
    }
}

final class DeviceLayoutNumberingTests: XCTestCase {
    /// Untagged files fall back to their filename, which usually already has
    /// the track number: prefixing again produced "09 09 Ode to the Mets".
    func testDoesNotDoubleUpTrackNumbers() {
        let layout = DeviceLayout()
        let t = Track(sourceURL: URL(fileURLWithPath: "/lib/09 Ode to the Mets.mp3"),
                      title: "09 Ode to the Mets", artist: "A", album: "B", trackNumber: 9)
        XCTAssertTrue(layout.path(for: t).hasSuffix("/09 Ode to the Mets.mp3"),
                      "got \(layout.path(for: t))")
    }

    func testStillPrefixesWhenTitleHasNoNumber() {
        let layout = DeviceLayout()
        let t = Track(sourceURL: URL(fileURLWithPath: "/lib/a.mp3"),
                      title: "Ode to the Mets", artist: "A", album: "B", trackNumber: 9)
        XCTAssertTrue(layout.path(for: t).hasSuffix("/09 Ode to the Mets.mp3"))
    }

    func testDoesNotStripALeadingNumberThatIsPartOfTheTitle() {
        // "1979" is the song name, not track 19.
        let layout = DeviceLayout()
        let t = Track(sourceURL: URL(fileURLWithPath: "/lib/a.mp3"),
                      title: "1979", artist: "A", album: "B", trackNumber: 4)
        XCTAssertTrue(layout.path(for: t).hasSuffix("/04 1979.mp3"))
    }

    func testRecognisesOtherSeparators() {
        XCTAssertTrue(DeviceLayout.startsWithTrackNumber("09. Song", 9))
        XCTAssertTrue(DeviceLayout.startsWithTrackNumber("9 - Song", 9))
        XCTAssertFalse(DeviceLayout.startsWithTrackNumber("09 Song", 3))
    }
}

final class DuplicateVersionTests: XCTestCase {
    private func track(_ title: String, duration: Double = 200) -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/lib/\(UUID().uuidString).flac"),
              title: title, artist: "A", album: "Album",
              durationSeconds: duration, fileSize: 1000)
    }

    /// A live take is a different recording, not a duplicate — stripping
    /// "(live)" made Paramore's studio and live "Pressure" collide.
    func testLiveVersionIsNotADuplicateOfTheStudioTake() {
        XCTAssertTrue(Duplicates().find(in: [
            track("Pressure"), track("Pressure (live)"),
        ]).isEmpty)
    }

    func testInstrumentalMixIsNotADuplicate() {
        XCTAssertTrue(Duplicates().find(in: [
            track("Soma"), track("Soma (instrumental mix)"),
        ]).isEmpty)
    }

    func testAcousticAndRemixStayDistinct() {
        XCTAssertTrue(Duplicates().find(in: [
            track("Song"), track("Song (acoustic)"), track("Song (Remix)"),
        ]).isEmpty)
    }

    /// Remaster and explicit markers describe the same recording, so those
    /// must still collapse together.
    func testRemasterAndExplicitStillMatch() {
        XCTAssertEqual(Duplicates().find(in: [
            track("Creep"), track("Creep (Remastered 2011)"),
        ]).count, 1)
        XCTAssertEqual(Duplicates().find(in: [
            track("Song"), track("Song [Explicit]"),
        ]).count, 1)
    }

    func testTwoLiveVersionsOfTheSameSongStillMatchEachOther() {
        XCTAssertEqual(Duplicates().find(in: [
            track("Pressure (live)"), track("Pressure (Live)"),
        ]).count, 1)
    }
}

final class DuplicateAutoCleanTests: XCTestCase {
    private func t(_ name: String, album: String?, ext: String = "flac", size: Int64 = 1000,
                   rate: Int? = 44_100, bits: Int? = 16, artist: String = "A") -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/m/\(name).\(ext)"), title: "Song", artist: artist,
              album: album, durationSeconds: 200, fileSize: size,
              codec: ext.uppercased(), sampleRate: rate, bitDepth: bits)
    }

    func testSameSongSameAlbumIsSafe() {
        let g = DuplicateGroup(key: "k", tracks: [t("a", album: "Siamese Dream"),
                                                  t("b", album: "Siamese Dream (UK Caroline)")])
        XCTAssertTrue(g.isSafeToAutoClean())
    }

    func testMissingAlbumTagDoesNotBlock() {
        let g = DuplicateGroup(key: "k", tracks: [t("a", album: "Album"), t("b", album: nil)])
        XCTAssertTrue(g.isSafeToAutoClean())
    }

    func testDifferentAlbumsNeedADecision() {
        let g = DuplicateGroup(key: "k", tracks: [t("a", album: "Album"), t("b", album: "Greatest Hits")])
        XCTAssertFalse(g.isSafeToAutoClean())
    }

    func testPlayableCopyBeatsLargerOneOverTheLimit() {
        let hiRes = t("hi", album: "X", size: 90_000, rate: 192_000, bits: 24)
        let cd = t("cd", album: "X", size: 30_000)
        let g = DuplicateGroup(key: "k", tracks: [hiRes, cd])
        XCTAssertEqual(g.keeper(limits: .none)?.sourceURL, hiRes.sourceURL)
        let limits = PlayerLimits(maxSampleRate: 48_000)
        XCTAssertEqual(g.keeper(limits: limits)?.sourceURL, cd.sourceURL)
        XCTAssertTrue(g.isSafeToAutoClean(limits: limits))
    }

    func testNotSafeWhenNoCopyIsPlayable() {
        let g = DuplicateGroup(key: "k", tracks: [t("a", album: "X", rate: 192_000, bits: 24),
                                                  t("b", album: "X", rate: 96_000, bits: 24)])
        XCTAssertFalse(g.isSafeToAutoClean(limits: PlayerLimits(maxSampleRate: 48_000)))
    }
}
