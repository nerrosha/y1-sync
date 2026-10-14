import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Y1SyncCore

final class ID3v2Tests: XCTestCase {

    // MARK: - Fixture building

    /// Build an ID3v2 tag by hand so the parser is tested against bytes we
    /// fully control, including a fake audio payload after the tag.
    private func makeMP3(
        version: UInt8 = 3,
        frames: [(String, Data)],
        audio: Data = Data(repeating: 0xAA, count: 512),
        padding: Int = 0
    ) -> Data {
        var frameData = Data()
        for (id, body) in frames {
            frameData.append(contentsOf: Array(id.utf8))
            frameData.append(contentsOf: version == 4
                             ? ID3v2.makeSyncsafe(body.count)
                             : ID3v2.makeBigEndian(body.count))
            frameData.append(contentsOf: [0, 0])
            frameData.append(body)
        }
        frameData.append(Data(repeating: 0, count: padding))

        var out = Data()
        out.append(contentsOf: Array("ID3".utf8))
        out.append(version)
        out.append(0)
        out.append(0)
        out.append(contentsOf: ID3v2.makeSyncsafe(frameData.count))
        out.append(frameData)
        out.append(audio)
        return out
    }

    private func jpeg(size: Int, quality: Double = 0.9) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Noise, so the encoder cannot trivially compress it to nothing.
        for i in 0..<40 {
            ctx.setFillColor(CGColor(red: Double(i % 7) / 7.0, green: 0.4, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: i * 13 % size, y: i * 29 % size, width: size / 4, height: size / 4))
        }
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    // MARK: - Parsing

    func testParsesFramesAndFindsAudioOffset() {
        let mp3 = makeMP3(frames: [("TIT2", Data([0x00] + Array("Song".utf8)))])
        let tag = ID3v2.parse(mp3)
        XCTAssertEqual(tag?.majorVersion, 3)
        XCTAssertEqual(tag?.frames.count, 1)
        XCTAssertEqual(tag?.frames.first?.id, "TIT2")
        XCTAssertEqual(mp3.count - (tag?.audioOffset ?? 0), 512, "audio should follow the tag")
    }

    func testReturnsNilWhenThereIsNoTag() {
        XCTAssertNil(ID3v2.parse(Data(repeating: 0xFF, count: 100)))
        XCTAssertNil(ID3v2.parse(Data()))
    }

    func testStopsAtPaddingRatherThanReadingGarbage() {
        let mp3 = makeMP3(frames: [("TIT2", Data([0x00] + Array("S".utf8)))], padding: 64)
        XCTAssertEqual(ID3v2.parse(mp3)?.frames.count, 1)
    }

    /// v2.3 uses plain big-endian frame sizes, v2.4 uses syncsafe ones.
    /// Reading a v2.4 file with v2.3 rules silently truncates frames.
    func testHandlesBothFrameSizeEncodings() {
        let body = Data([0x00] + Array(repeating: UInt8(0x41), count: 200))
        for version: UInt8 in [3, 4] {
            let mp3 = makeMP3(version: version, frames: [("TIT2", body)])
            let tag = ID3v2.parse(mp3)
            XCTAssertEqual(tag?.frames.first?.body.count, body.count, "v2.\(version)")
        }
    }

    // MARK: - Artwork extraction

    func testExtractsArtworkFromAPIC() throws {
        let art = try jpeg(size: 64)
        let mp3 = makeMP3(frames: [("APIC", ID3v2.makeAPICBody(jpeg: art))])
        XCTAssertEqual(ID3v2.artwork(in: mp3), art)
    }

    func testExtractsArtworkPastAUnicodeDescription() {
        // UTF-16 descriptions terminate with two nulls, not one.
        var body = Data()
        body.append(0x01)                                  // UTF-16 encoding
        body.append(contentsOf: Array("image/jpeg".utf8))
        body.append(0x00)
        body.append(0x03)
        body.append(contentsOf: [0x00, 0x00])              // empty UTF-16 description
        let payload = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02])
        body.append(payload)

        let mp3 = makeMP3(frames: [("APIC", body)])
        XCTAssertEqual(ID3v2.artwork(in: mp3), payload)
    }

    // MARK: - Rewriting

    func testReplacingArtworkPreservesAudioBytesExactly() throws {
        let audio = Data((0..<1024).map { UInt8($0 % 251) })
        let big = try jpeg(size: 400)
        let mp3 = makeMP3(frames: [("APIC", ID3v2.makeAPICBody(jpeg: big))], audio: audio)

        let small = Data([0xFF, 0xD8, 0xAB, 0xCD])
        let rewritten = try XCTUnwrap(ID3v2.replacingArtwork(in: mp3, with: small))

        let tag = try XCTUnwrap(ID3v2.parse(rewritten))
        XCTAssertEqual(rewritten.suffix(from: tag.audioOffset), audio,
                       "audio must survive byte-for-byte")
        XCTAssertEqual(ID3v2.artwork(in: rewritten), small)
    }

    func testReplacingArtworkKeepsOtherFrames() throws {
        let title = Data([0x00] + Array("Keep Me".utf8))
        let mp3 = makeMP3(frames: [
            ("TIT2", title),
            ("APIC", ID3v2.makeAPICBody(jpeg: try jpeg(size: 64))),
            ("TPE1", Data([0x00] + Array("Artist".utf8))),
        ])
        let rewritten = try XCTUnwrap(ID3v2.replacingArtwork(in: mp3, with: Data([0xFF, 0xD8])))
        let tag = try XCTUnwrap(ID3v2.parse(rewritten))

        XCTAssertEqual(tag.frames.first { $0.id == "TIT2" }?.body, title)
        XCTAssertNotNil(tag.frames.first { $0.id == "TPE1" })
        XCTAssertEqual(tag.frames.filter { $0.id == "APIC" }.count, 1, "exactly one picture")
    }

    func testRemovesDuplicatePictureFrames() throws {
        let art = try jpeg(size: 64)
        let mp3 = makeMP3(frames: [
            ("APIC", ID3v2.makeAPICBody(jpeg: art)),
            ("APIC", ID3v2.makeAPICBody(jpeg: art)),
        ])
        let rewritten = try XCTUnwrap(ID3v2.replacingArtwork(in: mp3, with: Data([0xFF, 0xD8])))
        XCTAssertEqual(ID3v2.parse(rewritten)?.frames.filter { $0.id == "APIC" }.count, 1)
    }

    func testSyncsafeRoundTrip() {
        for value in [0, 1, 127, 128, 255, 100_000, 268_435_455] {
            XCTAssertEqual(ID3v2.syncsafe(ID3v2.makeSyncsafe(value)), value)
        }
        // Syncsafe bytes must never have the high bit set, or they could be
        // mistaken for an MPEG frame sync.
        for b in ID3v2.makeSyncsafe(268_435_455) { XCTAssertEqual(b & 0x80, 0) }
    }
}

final class ArtworkOptimizerTests: XCTestCase {
    private func jpeg(size: Int) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for i in 0..<40 {
            ctx.setFillColor(CGColor(red: Double(i % 7) / 7.0, green: 0.4, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: i * 13 % size, y: i * 29 % size, width: size / 4, height: size / 4))
        }
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    func testShrinksOversizedArtToTheLimit() throws {
        let big = try jpeg(size: 1400)
        let small = try XCTUnwrap(ArtworkOptimizer(maxDimension: 500).shrink(big))

        let src = try XCTUnwrap(CGImageSourceCreateWithData(small as CFData, nil))
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0

        XCTAssertLessThanOrEqual(max(w, h), 500)
        XCTAssertLessThan(small.count, big.count)
    }

    func testLeavesAlreadySmallJPEGAlone() throws {
        // Re-encoding a small cover would only lose quality for no gain.
        let already = try jpeg(size: 300)
        XCTAssertNil(ArtworkOptimizer(maxDimension: 500).shrink(already))
    }

    func testOnlyRewritesFormatsItUnderstands() {
        // MP3 via ID3v2, FLAC via metadata blocks. Other containers are
        // copied untouched rather than risking a bad rewrite.
        XCTAssertTrue(ArtworkOptimizer.isRewritable(URL(fileURLWithPath: "/a/b.mp3")))
        XCTAssertTrue(ArtworkOptimizer.isRewritable(URL(fileURLWithPath: "/a/b.flac")))
        XCTAssertFalse(ArtworkOptimizer.isRewritable(URL(fileURLWithPath: "/a/b.m4a")))
    }

    func testCopyOptimisingShrinksArtAndKeepsAudio() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("y1art-opt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let audio = Data((0..<2048).map { UInt8($0 % 251) })
        var mp3 = Data()
        let body = ID3v2.makeAPICBody(jpeg: try jpeg(size: 1200))
        var frameData = Data()
        frameData.append(contentsOf: Array("APIC".utf8))
        frameData.append(contentsOf: ID3v2.makeBigEndian(body.count))
        frameData.append(contentsOf: [0, 0])
        frameData.append(body)
        mp3.append(contentsOf: Array("ID3".utf8))
        mp3.append(contentsOf: [3, 0, 0])
        mp3.append(contentsOf: ID3v2.makeSyncsafe(frameData.count))
        mp3.append(frameData)
        mp3.append(audio)

        let src = dir.appendingPathComponent("in.mp3")
        let dst = dir.appendingPathComponent("out.mp3")
        try mp3.write(to: src)

        let result = try ArtworkOptimizer(maxDimension: 500).copyOptimising(from: src, to: dst)
        XCTAssertTrue(result.didRewrite)
        XCTAssertLessThan(result.newArtBytes ?? .max, result.originalArtBytes ?? 0)

        let out = try Data(contentsOf: dst)
        let tag = try XCTUnwrap(ID3v2.parse(out))
        XCTAssertEqual(out.suffix(from: tag.audioOffset), audio, "audio must be untouched")
    }

    func testNonRewritableFormatIsStillCopied() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("y1art-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appendingPathComponent("in.flac")
        let dst = dir.appendingPathComponent("out.flac")
        try Data("not really flac".utf8).write(to: src)

        let result = try ArtworkOptimizer().copyOptimising(from: src, to: dst)
        XCTAssertFalse(result.didRewrite)
        XCTAssertEqual(try Data(contentsOf: dst), Data("not really flac".utf8))
    }
}
