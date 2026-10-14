import XCTest
@testable import Y1SyncCore

final class SimilarArtistsTests: XCTestCase {
    private func t(_ title: String, artist: String, album: String = "Siamese Dream", trackArtist: String? = nil) -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/m/\(artist)/\(album)/\(title).flac"),
              title: title, artist: trackArtist ?? artist, albumArtist: artist, album: album, fileSize: 1)
    }

    func testTheAndCaseVariantsAreOneArtist() {
        let tracks = (1...4).map { t("S\($0)", artist: "The Smashing Pumpkins") }
            + (5...6).map { t("S\($0)", artist: "Smashing Pumpkins") }
            + [t("A", artist: "Sombr", album: "X"), t("B", artist: "sombr", album: "Y")]
            + [t("Z", artist: "Radiohead", album: "OK Computer")]
        let groups = SimilarArtists().find(in: tracks)
        XCTAssertEqual(groups.count, 2)
        let pumpkins = try! XCTUnwrap(groups.first { $0.suggested.contains("Pumpkins") })
        XCTAssertEqual(pumpkins.suggested, "The Smashing Pumpkins", "the more common spelling")
        XCTAssertEqual(pumpkins.trackCount, 6)
        XCTAssertEqual(groups.first { $0.suggested.lowercased() == "sombr" }?.suggested, "Sombr", "on a tie the capitalised spelling wins")
    }

    func testTyposNeedASharedAlbumToBeBelieved() {
        let a = [t("1", artist: "Malcolm Todd", album: "Sweet Boy")]
        let sameAlbum = [t("2", artist: "Malcom Todd", album: "Sweet Boy")]
        XCTAssertEqual(SimilarArtists().find(in: a + sameAlbum).count, 1)

        let lilPeep = [t("1", artist: "Lil Peep", album: "Hellboy")]
        let lilPeer = [t("2", artist: "Lil Peer", album: "Other")]
        XCTAssertTrue(SimilarArtists().find(in: lilPeep + lilPeer).isEmpty, "alike names but nothing shared")
    }

    func testDifferentArtistsAreNotJoined() {
        let tracks = [t("1", artist: "The Strokes", album: "A"), t("2", artist: "The Stooges", album: "A"),
                      t("3", artist: "Her's", album: "B"), t("4", artist: "Hers", album: "C")]
        let groups = SimilarArtists().find(in: tracks)
        XCTAssertEqual(groups.count, 1, "only Her's / Hers")
        XCTAssertEqual(groups[0].variants.count, 2)
    }
}

final class ArtistRetaggerTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("artist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func le(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)]) }
    private func flac(_ fields: [String]) -> Data {
        var c = Data(); let v = Data("t".utf8); c.append(le(v.count)); c.append(v)
        let f = fields.map { Data($0.utf8) }; c.append(le(f.count))
        for x in f { c.append(le(x.count)); c.append(x) }
        var out = Data("fLaC".utf8)
        out.append(contentsOf: [0, 0, 0, 34]); out.append(Data(repeating: 0, count: 34))
        out.append(contentsOf: [0x84, UInt8(c.count >> 16), UInt8((c.count >> 8) & 255), UInt8(c.count & 255)])
        out.append(c); out.append(Data(repeating: 7, count: 2000)); return out
    }
    private func file(_ name: String, _ fields: [String]) throws -> (URL, Track) {
        let url = dir.appendingPathComponent("Music/X/Y/\(name).flac")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try flac(fields).write(to: url)
        let meta = FLAC.read(url)!
        return (url, Track(sourceURL: url, title: name, artist: meta["ARTIST"], albumArtist: meta["ALBUM_ARTIST"] ?? meta["ALBUMARTIST"],
                           album: "Y", fileSize: 1))
    }

    func testAlbumArtistIsSetAndOddSpellingsAreCleared() throws {
        let (url, track) = try file("a", ["TITLE=a", "ARTIST=Smashing Pumpkins", "ALBUM_ARTIST=Smashing Pumpkins", "ALBUM ARTIST=Smashing Pumpkins"])
        let out = ArtistRetagger.setAlbumArtist("The Smashing Pumpkins", for: [track], deviceRoot: dir)
        XCTAssertEqual(out.changed, 1)
        let m = try XCTUnwrap(FLAC.read(url))
        XCTAssertEqual(m["ALBUMARTIST"], "The Smashing Pumpkins")
        XCTAssertNil(m["ALBUM_ARTIST"]); XCTAssertNil(m["ALBUM ARTIST"])
        XCTAssertEqual(m["ARTIST"], "The Smashing Pumpkins", "track artist was the old spelling, so it follows")
    }

    func testFeaturedArtistCreditsAreNeverRewritten() throws {
        let (url, track) = try file("b", ["TITLE=b", "ARTIST=Lana Del Rey, Jon Batiste", "ALBUMARTIST=lana del rey"])
        ArtistRetagger.setAlbumArtist("Lana Del Rey", for: [track], deviceRoot: dir)
        let m = try XCTUnwrap(FLAC.read(url))
        XCTAssertEqual(m["ALBUMARTIST"], "Lana Del Rey")
        XCTAssertEqual(m["ARTIST"], "Lana Del Rey, Jon Batiste")
    }

    func testUndoRestoresOldSpellingsAndRemovesWhatWasAdded() throws {
        let (url, track) = try file("c", ["TITLE=c", "ARTIST=sombr"])          // no album artist tag at all
        let undo = UndoRecorder(deviceRoot: dir)
        ArtistRetagger.setAlbumArtist("Sombr", for: [track], deviceRoot: dir, undo: undo)
        undo.finish(label: "merge artists")
        XCTAssertEqual(FLAC.read(url)?["ALBUMARTIST"], "Sombr")

        XCTAssertEqual(UndoLog.undoMostRecent(deviceRoot: dir)?.restored, 1)
        let m = try XCTUnwrap(FLAC.read(url))
        XCTAssertNil(m["ALBUMARTIST"], "the tag that did not exist before is gone again")
        XCTAssertEqual(m["ARTIST"], "sombr")
    }
}
