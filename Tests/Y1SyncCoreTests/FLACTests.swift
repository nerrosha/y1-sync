import XCTest
@testable import Y1SyncCore

final class FLACTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Fixture

    private func le(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
              UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    private func blockHeader(type: UInt8, length: Int, last: Bool) -> Data {
        Data([(last ? 0x80 : 0x00) | type,
              UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
    }

    /// Build a minimal but structurally valid FLAC: STREAMINFO, a Vorbis
    /// comment, an optional picture, then fake "audio" bytes.
    private func makeFLAC(fields: [String: String], picture: Data? = nil,
                          audio: Data = Data(repeating: 0x5A, count: 4096)) -> Data {
        var out = Data("fLaC".utf8)

        let streamInfo = Data(repeating: 0, count: 34)
        var blocks: [(UInt8, Data)] = [(0, streamInfo)]

        var comment = Data()
        let vendor = Data("test".utf8)
        comment.append(le(vendor.count)); comment.append(vendor)
        let entries = fields.sorted { $0.key < $1.key }.map { Data("\($0.key)=\($0.value)".utf8) }
        comment.append(le(entries.count))
        for e in entries { comment.append(le(e.count)); comment.append(e) }
        blocks.append((4, comment))

        if let picture {
            blocks.append((6, FLAC.makePictureBlock(jpeg: picture, width: 100, height: 100)))
        }

        for (i, block) in blocks.enumerated() {
            out.append(blockHeader(type: block.0, length: block.1.count,
                                   last: i == blocks.count - 1))
            out.append(block.1)
        }
        out.append(audio)
        return out
    }

    // MARK: - Reading

    func testReadsVorbisComments() throws {
        let url = tmp.appendingPathComponent("a.flac")
        try makeFLAC(fields: ["TITLE": "Ode to the Mets",
                              "ALBUMARTIST": "The Strokes",
                              "ALBUM": "The New Abnormal"]).write(to: url)

        let meta = try XCTUnwrap(FLAC.read(url))
        XCTAssertEqual(meta["TITLE"], "Ode to the Mets")
        XCTAssertEqual(meta["albumartist"], "The Strokes", "lookup is case-insensitive")
        XCTAssertEqual(meta["ALBUM"], "The New Abnormal")
    }

    func testIgnoresNonFLACFiles() throws {
        let url = tmp.appendingPathComponent("b.flac")
        try Data("not a flac".utf8).write(to: url)
        XCTAssertNil(FLAC.read(url))
    }

    func testReadsEmbeddedPicture() throws {
        let url = tmp.appendingPathComponent("c.flac")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])
        try makeFLAC(fields: ["TITLE": "T"], picture: jpeg).write(to: url)

        let meta = try XCTUnwrap(FLAC.read(url))
        let cover = try XCTUnwrap(FLAC.frontCover(meta))
        XCTAssertEqual(cover.data, jpeg)
        XCTAssertEqual(cover.mimeType, "image/jpeg")
        XCTAssertEqual(cover.width, 100)
    }

    // MARK: - Round trips

    func testVorbisCommentRoundTrip() {
        let fields = ["TITLE": "Song", "ARTIST": "A", "ALBUM": "B"]
        var meta = FLAC.Metadata()
        FLAC.parseVorbisComment(FLAC.makeVorbisComment(fields), into: &meta)
        XCTAssertEqual(meta["TITLE"], "Song")
        XCTAssertEqual(meta["ARTIST"], "A")
        XCTAssertEqual(meta["ALBUM"], "B")
    }

    func testHandlesUnicodeTags() {
        var meta = FLAC.Metadata()
        FLAC.parseVorbisComment(
            FLAC.makeVorbisComment(["ARTIST": "Björk", "TITLE": "青春"]), into: &meta)
        XCTAssertEqual(meta["ARTIST"], "Björk")
        XCTAssertEqual(meta["TITLE"], "青春")
    }

    // MARK: - Writing

    /// The whole point of rewriting rather than re-encoding: the audio must
    /// come out identical, or the library is silently degraded.
    func testRewritePreservesAudioBytesExactly() throws {
        let src = tmp.appendingPathComponent("in.flac")
        let dst = tmp.appendingPathComponent("out.flac")
        let audio = Data((0..<8192).map { UInt8($0 % 251) })
        try makeFLAC(fields: ["TITLE": "T"],
                     picture: Data(repeating: 0xAB, count: 2000),
                     audio: audio).write(to: src)

        let newArt = Data([0xFF, 0xD8, 0x11, 0x22])
        XCTAssertTrue(try FLAC.rewrite(from: src, to: dst,
                                       artwork: newArt, artworkSize: (50, 50)))

        let (_, audioOffset) = try XCTUnwrap(FLAC.readBlocks(dst))
        let written = try Data(contentsOf: dst)
        XCTAssertEqual(written.suffix(from: Int(audioOffset)), audio,
                       "audio must survive byte-for-byte")
    }

    func testRewriteReplacesArtworkAndKeepsTags() throws {
        let src = tmp.appendingPathComponent("in.flac")
        let dst = tmp.appendingPathComponent("out.flac")
        try makeFLAC(fields: ["TITLE": "Keep Me", "ALBUM": "Also Keep"],
                     picture: Data(repeating: 0xAB, count: 5000)).write(to: src)

        let newArt = Data([0xFF, 0xD8, 0x99])
        XCTAssertTrue(try FLAC.rewrite(from: src, to: dst,
                                       artwork: newArt, artworkSize: (10, 10)))

        let meta = try XCTUnwrap(FLAC.read(dst))
        XCTAssertEqual(meta["TITLE"], "Keep Me")
        XCTAssertEqual(meta["ALBUM"], "Also Keep")
        XCTAssertEqual(FLAC.frontCover(meta)?.data, newArt)
        XCTAssertEqual(meta.pictures.count, 1, "old picture must be gone")
    }

    func testRewriteCanUpdateFields() throws {
        let src = tmp.appendingPathComponent("in.flac")
        let dst = tmp.appendingPathComponent("out.flac")
        try makeFLAC(fields: ["TITLE": "T", "ALBUMARTIST": "Wrong"]).write(to: src)

        XCTAssertTrue(try FLAC.rewrite(from: src, to: dst,
                                       fields: ["TITLE": "T", "ALBUMARTIST": "Right"]))
        XCTAssertEqual(try XCTUnwrap(FLAC.read(dst))["ALBUMARTIST"], "Right")
    }

    func testRewrittenFileIsStillParseable() throws {
        let src = tmp.appendingPathComponent("in.flac")
        let dst = tmp.appendingPathComponent("out.flac")
        try makeFLAC(fields: ["TITLE": "T"], picture: Data(repeating: 1, count: 100))
            .write(to: src)

        _ = try FLAC.rewrite(from: src, to: dst,
                             artwork: Data([0xFF, 0xD8]), artworkSize: (5, 5))

        // Reading it back exercises the block headers, including the last-block
        // flag — getting that wrong makes players reject the file.
        let blocks = try XCTUnwrap(FLAC.readBlocks(dst))
        XCTAssertFalse(blocks.blocks.isEmpty)
        XCTAssertEqual(blocks.blocks.first?.type, 0, "STREAMINFO must stay first")
        XCTAssertNotNil(FLAC.read(dst))
    }

    func testRefusesANonFLACSource() throws {
        let src = tmp.appendingPathComponent("in.flac")
        try Data("nope".utf8).write(to: src)
        XCTAssertFalse(try FLAC.rewrite(from: src,
                                        to: tmp.appendingPathComponent("out.flac"),
                                        artwork: Data([0xFF]), artworkSize: (1, 1)))
    }

    func testOptimizerNowAcceptsFLAC() {
        XCTAssertTrue(ArtworkOptimizer.isRewritable(URL(fileURLWithPath: "/a/b.flac")))
        XCTAssertTrue(ArtworkOptimizer.isRewritable(URL(fileURLWithPath: "/a/b.mp3")))
        XCTAssertFalse(ArtworkOptimizer.isRewritable(URL(fileURLWithPath: "/a/b.m4a")))
    }
}

/// The cheap end-of-file check that finds cut-off FLAC copies without decoding.
final class FLACTruncationTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flac-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private let block = 4096

    private func utf8(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        if n < 0x800 { return [0xC0 | UInt8(n >> 6), 0x80 | UInt8(n & 0x3F)] }
        return [0xE0 | UInt8(n >> 12), 0x80 | UInt8((n >> 6) & 0x3F), 0x80 | UInt8(n & 0x3F)]
    }

    /// A FLAC with real frame headers (valid CRC-8) and filler for samples.
    private func makeFLAC(frames: Int, claimed: Int) -> Data {
        var si = [UInt8](repeating: 0, count: 34)
        si[0] = UInt8(block >> 8); si[1] = UInt8(block & 0xFF)       // min block
        si[2] = si[0]; si[3] = si[1]                                  // max block
        let rate = 44100                                              // 20 bits
        si[10] = UInt8(rate >> 12); si[11] = UInt8((rate >> 4) & 0xFF)
        si[12] = UInt8((rate & 0x0F) << 4) | (1 << 1)                 // 2 channels, 16 bit (high bit 0)
        let total = claimed * block
        si[13] = 0xF0 | UInt8((total >> 32) & 0x0F)             // bps low bits + total high
        si[14] = UInt8((total >> 24) & 0xFF); si[15] = UInt8((total >> 16) & 0xFF)
        si[16] = UInt8((total >> 8) & 0xFF); si[17] = UInt8(total & 0xFF)

        var out = Data("fLaC".utf8)
        out.append(contentsOf: [0x80, 0, 0, 34])
        out.append(contentsOf: si)
        for n in 0..<frames {
            var h: [UInt8] = [0xFF, 0xF8, 0xC9, 0x18] + utf8(n)       // fixed, 4096, 44.1k, stereo/16
            h.append(FLAC.crc8(h[0...]))
            out.append(contentsOf: h)
            out.append(Data(repeating: UInt8(0x11 + n % 3), count: 300))
        }
        return out
    }

    func testCompleteFileIsNotFlagged() throws {
        let url = tmp.appendingPathComponent("ok.flac")
        try makeFLAC(frames: 120, claimed: 120).write(to: url)
        XCTAssertNil(FLAC.truncationReason(url))
    }

    func testCutOffFileIsFlaggedWithRoughMissingTime() throws {
        let url = tmp.appendingPathComponent("cut.flac")
        try makeFLAC(frames: 60, claimed: 120).write(to: url)       // half of 120*4096/44100 ≈ 11 s
        let why = try XCTUnwrap(FLAC.truncationReason(url))
        XCTAssertTrue(why.contains("cut off"), why)
        XCTAssertTrue(why.contains("5 s") || why.contains("6 s"), why)
    }

    func testFileMissingJustTheLastFrameIsTolerated() throws {
        let url = tmp.appendingPathComponent("almost.flac")
        try makeFLAC(frames: 119, claimed: 120).write(to: url)
        XCTAssertNil(FLAC.truncationReason(url))
    }

    func testUnknownLengthIsNeverFlagged() throws {
        let url = tmp.appendingPathComponent("unknown.flac")
        try makeFLAC(frames: 10, claimed: 0).write(to: url)
        XCTAssertNil(FLAC.truncationReason(url))
    }

    func testCRCRejectsLookalikeBytes() {
        // FF F8 followed by junk must not be taken for a frame header.
        let junk: [UInt8] = [0xFF, 0xF8, 0xC9, 0x18, 0x05, 0x00, 0x00, 0x00]
        XCTAssertNil(FLAC.parseFrameHeader(junk, at: 0, fixedBlock: 4096))
    }
}
