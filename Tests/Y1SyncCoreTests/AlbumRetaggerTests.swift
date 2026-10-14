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
