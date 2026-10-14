import XCTest
@testable import Y1SyncCore

final class AlbumRetaggerTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("retag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func le(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }

    private func flac(album: String, audio: Data = Data(repeating: 0x5A, count: 3000)) -> Data {
        var comment = Data(); let v = Data("t".utf8)
        comment.append(le(v.count)); comment.append(v)
        let fields = ["TITLE=Song", "ARTIST=A", "ALBUM=\(album)", "GENRE=Rock"].map { Data($0.utf8) }
        comment.append(le(fields.count))
        for f in fields { comment.append(le(f.count)); comment.append(f) }
        var out = Data("fLaC".utf8)
        out.append(contentsOf: [0, 0, 0, 34]); out.append(Data(repeating: 0, count: 34))
        out.append(contentsOf: [0x84, UInt8(comment.count >> 16), UInt8((comment.count >> 8) & 255), UInt8(comment.count & 255)])
        out.append(comment); out.append(audio)
        return out
    }

    func testRetaggingFLACChangesOnlyTheAlbumAndKeepsAudioBytes() throws {
        let url = dir.appendingPathComponent("a.flac")
        let audio = Data((0..<4000).map { UInt8($0 % 251) })
        try flac(album: "Malcom Todd", audio: audio).write(to: url)

        XCTAssertEqual(AlbumRetagger.currentAlbum(of: url), "Malcom Todd")
        XCTAssertTrue(AlbumRetagger.setAlbum("Malcolm Todd", in: url))

        let meta = try XCTUnwrap(FLAC.read(url))
        XCTAssertEqual(meta["ALBUM"], "Malcolm Todd")
        XCTAssertEqual(meta["TITLE"], "Song"); XCTAssertEqual(meta["GENRE"], "Rock")
        let offset = try XCTUnwrap(FLAC.streamInfo(url)).audioOffset
        XCTAssertEqual(try Data(contentsOf: url).suffix(from: Int(offset)), audio, "audio is byte-identical")
    }

    func testRetaggingMP3() throws {
        let url = dir.appendingPathComponent("a.mp3")
        var tag = Data(); let body = Data([3]) + Data("Old Album".utf8)
        tag.append(Data("TALB".utf8)); tag.append(contentsOf: ID3v2.makeBigEndian(body.count)); tag.append(contentsOf: [0, 0]); tag.append(body)
        var f = Data("ID3".utf8); f.append(contentsOf: [3, 0, 0]); f.append(contentsOf: ID3v2.makeSyncsafe(tag.count)); f.append(tag)
        f.append(Data(repeating: 0xAA, count: 400))
        try f.write(to: url)

        XCTAssertEqual(AlbumRetagger.currentAlbum(of: url), "Old Album")
        XCTAssertTrue(AlbumRetagger.setAlbum("New Album", in: url))
        XCTAssertEqual(AlbumRetagger.currentAlbum(of: url), "New Album")
        XCTAssertEqual(AudioSize.of(url, size: 0), 400)
    }

    func testUnsupportedFormatReportsFailureInsteadOfPretending() throws {
        let url = dir.appendingPathComponent("a.m4a")
        try Data(repeating: 1, count: 50).write(to: url)
        XCTAssertFalse(AlbumRetagger.setAlbum("X", in: url))
    }

    func testUndoPutsEveryOldTitleBack() throws {
        let device = dir!
        let url = device.appendingPathComponent("Music/A/Malcom Todd/01 Song.flac")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try flac(album: "Malcom Todd").write(to: url)
        let track = Track(sourceURL: url, title: "Song", artist: "A", album: "Malcom Todd", fileSize: 1)

        let undo = UndoRecorder(deviceRoot: device)
        let out = AlbumRetagger.setAlbum("Malcolm Todd", for: [track], deviceRoot: device, undo: undo)
        undo.finish(label: "merge albums")
        XCTAssertEqual(out.changed, 1)
        XCTAssertEqual(AlbumRetagger.currentAlbum(of: url), "Malcolm Todd")

        XCTAssertEqual(UndoLog.undoMostRecent(deviceRoot: device)?.restored, 1)
        XCTAssertEqual(AlbumRetagger.currentAlbum(of: url), "Malcom Todd")
    }

    func testFilesAlreadyOnTheRightTitleAreNotRewritten() throws {
        let url = dir.appendingPathComponent("a.flac")
        try flac(album: "Same").write(to: url)
        let before = try Data(contentsOf: url)
        let out = AlbumRetagger.setAlbum("Same", for: [Track(sourceURL: url, album: "Same", fileSize: 1)], deviceRoot: dir)
        XCTAssertEqual(out.changed, 0)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testCacheEntryTagsAreRefreshedWhenTagsChangeInPlace() throws {
        let device = dir!
        let url = device.appendingPathComponent("Music/A/B/01 Song.flac")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try flac(album: "New").write(to: url)
        let old: [String: Any] = ["trackNum": 1, "genre": "Rock", "composer": "Keep Me", "title": "Song", "albumArtist": "A",
                                  "album": "Old", "path": "/storage/sdcard0/Music/A/B/01 Song.flac", "year": "2020", "artist": "A"]
        try JSONSerialization.data(withJSONObject: ["music": [old], "books": []]).write(to: PlayerLibraryCache.fileURL(device))

        let track = Track(sourceURL: url, title: "Song", artist: "A", albumArtist: "A", album: "New", fileSize: 1)
        let r = try PlayerLibraryCache.update(deviceRoot: device, adding: [(track, "/Music/A/B/01 Song.flac")],
                                              dropDeadEntries: false, replaceExisting: true)
        XCTAssertEqual(r.replaced, 1)
        let top = try JSONSerialization.jsonObject(with: Data(contentsOf: PlayerLibraryCache.fileURL(device))) as! [String: Any]
        let e = (top["music"] as! [[String: Any]])[0]
        XCTAssertEqual(e["album"] as? String, "New")
        XCTAssertEqual(e["composer"] as? String, "Keep Me", "fields the firmware keeps are left alone")
    }
}

final class MergeRulesTests: XCTestCase {
    private func t(_ name: String, artist: String = "Malcolm Todd", album: String) -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/l/\(name).flac"), title: name, artist: artist,
              albumArtist: artist, album: album, fileSize: 1)
    }

    func testAlbumRuleRenamesOnlyThatArtistsAlbum() {
        let rule = MergeRule(kind: .album, from: "Malcom Todd", to: "Malcolm Todd (still)",
                             artists: [MergeRules.fold("Malcolm Todd")])
        let mine = t("a", album: "malcom todd")                       // case differs: still matches
        let other = t("b", artist: "Someone Else", album: "Malcom Todd")
        let out = MergeRules.apply([rule], to: [mine, other])
        XCTAssertEqual(out[0].album, "Malcolm Todd (still)")
        XCTAssertEqual(out[0].tagEdits, ["ALBUM": "Malcolm Todd (still)"])
        XCTAssertEqual(out[1].album, "Malcom Todd")
        XCTAssertTrue(out[1].tagEdits.isEmpty)
    }

    func testArtistRuleKeepsFeaturedCredits() {
        let rule = MergeRule(kind: .artist, from: "Smashing Pumpkins", to: "The Smashing Pumpkins")
        let own = Track(sourceURL: URL(fileURLWithPath: "/a.flac"), artist: "Smashing Pumpkins",
                        albumArtist: "Smashing Pumpkins", album: "X")
        let feat = Track(sourceURL: URL(fileURLWithPath: "/b.flac"), artist: "Smashing Pumpkins, Guest",
                         albumArtist: "Smashing Pumpkins", album: "X")
        let out = MergeRules.apply([rule], to: [own, feat])
        XCTAssertEqual(out[0].artist, "The Smashing Pumpkins"); XCTAssertEqual(out[0].albumArtist, "The Smashing Pumpkins")
        XCTAssertEqual(out[1].artist, "Smashing Pumpkins, Guest"); XCTAssertEqual(out[1].albumArtist, "The Smashing Pumpkins")
    }

    func testAlbumRuleStillMatchesAfterTheArtistWasMerged() {
        let artist = MergeRule(kind: .artist, from: "Smashing Pumpkins", to: "The Smashing Pumpkins")
        let album = MergeRule(kind: .album, from: "Siamese Dream (UK Caroline)", to: "Siamese Dream",
                              artists: [MergeRules.fold("Smashing Pumpkins")])
        let track = Track(sourceURL: URL(fileURLWithPath: "/a.flac"), artist: "Smashing Pumpkins",
                          albumArtist: "Smashing Pumpkins", album: "Siamese Dream (UK Caroline)")
        let out = MergeRules.apply([artist, album], to: [track])[0]
        XCTAssertEqual(out.albumArtist, "The Smashing Pumpkins"); XCTAssertEqual(out.album, "Siamese Dream")
    }

    func testAddingReplacesTheSameRule() {
        let a = MergeRule(kind: .album, from: "X", to: "Y", artists: ["a"])
        let b = MergeRule(kind: .album, from: "x", to: "Z", artists: ["a"])
        let out = MergeRules.adding([b], to: [a])
        XCTAssertEqual(out.count, 1); XCTAssertEqual(out[0].to, "Z")
    }

    func testCopyCarriesTheMergedTagsButLibraryStaysUntouched() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let device = tmp.appendingPathComponent("device")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        let src = tmp.appendingPathComponent("lib/a.mp3")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A tiny MP3 with an ID3v2 tag holding the old album.
        let frame = { (id: String, text: String) -> Data in
            let body = Data([3]) + Data(text.utf8)
            var size = body.count
            let sz = Data([UInt8(size >> 24 & 255), UInt8(size >> 16 & 255), UInt8(size >> 8 & 255), UInt8(size & 255)])
            size = 0
            return Data(id.utf8) + sz + Data([0, 0]) + body
        }
        let frames = frame("TALB", "Old Album") + frame("TPE1", "Artist")
        let n = frames.count
        let header = Data("ID3".utf8) + Data([3, 0, 0, UInt8(n >> 21 & 127), UInt8(n >> 14 & 127), UInt8(n >> 7 & 127), UInt8(n & 127)])
        try (header + frames + Data(repeating: 0xFF, count: 400)).write(to: src)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rule = MergeRule(kind: .album, from: "Old Album", to: "New Album", artists: [MergeRules.fold("Artist")])
        var track = Track(sourceURL: src, title: "S", artist: "Artist", album: "Old Album", trackNumber: 1,
                          fileSize: Int64((try Data(contentsOf: src)).count))
        track = MergeRules.apply([rule], to: [track])[0]
        let plan = SyncPlanner().plan(library: [track], deviceFiles: [])
        let r = try SyncEngine(artworkOptimizer: nil).execute(plan: plan, deviceRoot: device)
        XCTAssertEqual(r.copied, 1)

        let copied = device.appendingPathComponent(plan.actions[0].devicePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        XCTAssertEqual(TagEditor.read(copied, fields: ["ALBUM"])["ALBUM"], "New Album")
        XCTAssertEqual(TagEditor.read(src, fields: ["ALBUM"])["ALBUM"], "Old Album")
        XCTAssertTrue(plan.actions[0].devicePath.contains("New Album"))
    }
}

final class LearnRulesTests: XCTestCase {
    private func t(_ title: String, artist: String, album: String, dur: Double = 200) -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/x/\(artist)\(album)\(title).flac"), title: title, artist: artist,
              albumArtist: artist, album: album, durationSeconds: dur, fileSize: 1)
    }

    func testLearnsArtistAndAlbumSpellingsFromThePlayer() {
        let lib = ["One", "Two", "Three"].flatMap { [t($0, artist: "Smashing Pumpkins", album: "Siamese Dream (UK Caroline)"),
                                                     t($0, artist: "Malcolm Todd", album: "Malcom Todd")] }
        let dev = ["One", "Two", "Three"].flatMap { [t($0, artist: "The Smashing Pumpkins", album: "Siamese Dream"),
                                                     t($0, artist: "Malcolm Todd", album: "Malcolm Todd (still)")] }
        let rules = MergeRules.learn(library: lib, device: dev)
        XCTAssertTrue(rules.contains { $0.kind == .artist && $0.from == "Smashing Pumpkins" && $0.to == "The Smashing Pumpkins" })
        XCTAssertTrue(rules.contains { $0.kind == .album && $0.from == "Malcom Todd" && $0.to == "Malcolm Todd (still)" })
        // And the learned rules really make the library match the player.
        let applied = MergeRules.apply(rules, to: lib)
        XCTAssertEqual(Set(applied.map { "\($0.effectiveAlbumArtist)/\($0.effectiveAlbum)" }),
                       Set(dev.map { "\($0.effectiveAlbumArtist)/\($0.effectiveAlbum)" }))
    }

    func testSingleVersusAlbumIsNotARename() {
        let lib = [t("One", artist: "A", album: "One - Single"), t("Two", artist: "A", album: "One - Single")]
        let dev = [t("One", artist: "A", album: "The Album"), t("Two", artist: "A", album: "The Album")]
        XCTAssertTrue(MergeRules.learn(library: lib, device: dev).isEmpty)
    }

    func testOneMatchingSongIsNotEnough() {
        let lib = [t("One", artist: "Smashing Pumpkins", album: "X")]
        let dev = [t("One", artist: "The Smashing Pumpkins", album: "X")]
        XCTAssertTrue(MergeRules.learn(library: lib, device: dev).isEmpty)
    }
}
