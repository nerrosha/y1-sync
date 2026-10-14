import XCTest
@testable import Y1SyncCore

final class MP4TagsTests: XCTestCase {
    private func atom(_ t: String, _ body: Data) -> Data { MP4Tags.atom(Array(t.utf8), body) }
    private func item(_ t: [UInt8], _ v: String) -> Data {
        MP4Tags.atom(t, atom("data", Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data(v.utf8)))
    }

    /// ftyp, moov(trak(mdia(minf(stbl(stco)))) [+ udta]), mdat — one chunk at the start of mdat.
    private func makeFile(withTags: Bool) -> (Data, audio: Data) {
        let audio = Data((0..<200).map { UInt8($0 & 255) })
        let ftyp = atom("ftyp", Data("M4A ".utf8) + Data(repeating: 0, count: 4))
        func moov(offset: UInt32) -> Data {
            let stco = atom("stco", Data([0, 0, 0, 0]) + Data(MP4Tags.put32(1)) + Data(MP4Tags.put32(offset)))
            let trak = atom("trak", atom("mdia", atom("minf", atom("stbl", stco))))
            var body = trak
            if withTags {
                let ilst = atom("ilst", item([0xA9, 0x61, 0x6C, 0x62], "Old Album") + item(Array("aART".utf8), "sombr"))
                let meta = atom("meta", Data([0, 0, 0, 0]) + ilst)
                body += atom("udta", meta)
            }
            return atom("moov", body)
        }
        let size = moov(offset: 0).count
        let offset = UInt32(ftyp.count + size + 8)
        return (ftyp + moov(offset: offset) + atom("mdat", audio), audio)
    }

    private func chunkOffset(_ d: Data) -> Int {
        let top = MP4Tags.atoms(in: d, from: 0, to: d.count)!
        let moov = top.first { $0.type == Array("moov".utf8) }!
        let r = d.range(of: Data("stco".utf8))!
        _ = moov
        return Int(MP4Tags.be32(d, r.upperBound - d.startIndex + 8))
    }

    private func tmp(_ d: Data) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a")
        try d.write(to: u); return u
    }

    func testReadsAndRewritesExistingTags() throws {
        let (file, audio) = makeFile(withTags: true)
        let url = try tmp(file); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(TagEditor.read(url, fields: ["ALBUM", "ALBUMARTIST"]), ["ALBUM": "Old Album", "ALBUMARTIST": "sombr"])
        XCTAssertTrue(TagEditor.write(["ALBUMARTIST": "Sombr", "ARTIST": "Sombr"], in: url))
        XCTAssertEqual(TagEditor.read(url, fields: ["ALBUM", "ALBUMARTIST", "ARTIST"]),
                       ["ALBUM": "Old Album", "ALBUMARTIST": "Sombr", "ARTIST": "Sombr"])
        let out = try Data(contentsOf: url)
        // Audio untouched and the chunk offset still points at it.
        let off = chunkOffset(out)
        XCTAssertEqual(out.subdata(in: off ..< off + audio.count), audio)
    }

    func testAddsTagsToFileWithoutAny() throws {
        let (file, audio) = makeFile(withTags: false)
        let url = try tmp(file); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(TagEditor.write(["ALBUM": "New"], in: url))
        XCTAssertEqual(TagEditor.read(url, fields: ["ALBUM"]), ["ALBUM": "New"])
        let out = try Data(contentsOf: url)
        let off = chunkOffset(out)
        XCTAssertEqual(out.subdata(in: off ..< off + audio.count), audio)
    }

    func testRemovesTagAndUndoRestores() throws {
        let (file, _) = makeFile(withTags: true)
        let url = try tmp(file); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(TagEditor.write(["ALBUM": nil], in: url))
        XCTAssertNil(TagEditor.read(url, fields: ["ALBUM"])["ALBUM"])
        XCTAssertEqual(TagEditor.read(url, fields: ["ALBUMARTIST"])["ALBUMARTIST"], "sombr")
    }

    func testRejectsGarbage() throws {
        let url = try tmp(Data("not an mp4 at all".utf8)); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(TagEditor.write(["ALBUM": "x"], in: url))
    }
}

final class MP4RealFileTests: XCTestCase {
    /// Set Y1_REAL_M4A to a copy of a real file to run this.
    func testRealFile() throws {
        guard let path = ProcessInfo.processInfo.environment["Y1_REAL_M4A"] else { throw XCTSkip("no file") }
        let url = URL(fileURLWithPath: path)
        let before = TagEditor.read(url, fields: ["ALBUM", "ALBUMARTIST", "ARTIST"])
        print("BEFORE", before)
        XCTAssertTrue(TagEditor.write(["ALBUMARTIST": "Sombr", "ARTIST": "Sombr"], in: url))
        print("AFTER", TagEditor.read(url, fields: ["ALBUM", "ALBUMARTIST", "ARTIST"]))
    }
}
