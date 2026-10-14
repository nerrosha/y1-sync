import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Y1SyncCore

final class AlbumArtTests: XCTestCase {
    /// Build a PNG in memory to stand in for embedded cover art.
    private func samplePNG(size: Int) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.5, green: 0.8, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try XCTUnwrap(ctx.makeImage())

        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// Rockbox on the Y1 is built with `EXT "bmp"` and reads uncompressed
    /// BMPs only — a JPEG or RLE-compressed BMP shows as no artwork at all.
    func testProducesUncompressedBMP() throws {
        let png = try samplePNG(size: 500)
        let bmp = try XCTUnwrap(AlbumArtExporter(maxDimension: 240).makeBMP(from: png))

        XCTAssertEqual(Array(bmp.prefix(2)), Array("BM".utf8), "must be a BMP")

        let compression = bmp.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 30, as: UInt32.self) }
        XCTAssertEqual(compression, 0, "Rockbox cannot decode compressed BMPs")

        let bpp = bmp.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt16.self) }
        XCTAssertTrue(bpp == 24 || bpp == 32, "unexpected bit depth \(bpp)")
    }

    func testDownscalesToRequestedMaxDimension() throws {
        let png = try samplePNG(size: 900)
        let bmp = try XCTUnwrap(AlbumArtExporter(maxDimension: 200).makeBMP(from: png))

        let width = bmp.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 18, as: Int32.self) }
        let height = bmp.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 22, as: Int32.self) }
        XCTAssertEqual(width, 200)
        XCTAssertEqual(abs(height), 200)
    }

    func testRejectsGarbageInput() {
        XCTAssertNil(AlbumArtExporter().makeBMP(from: Data("not an image".utf8)))
    }

    func testDoesNotOverwriteExistingCover() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("y1art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A cover the user placed themselves must be left alone.
        let existing = dir.appendingPathComponent("cover.bmp")
        try Data("mine".utf8).write(to: existing)

        let wrote = await AlbumArtExporter().writeCover(
            from: URL(fileURLWithPath: "/nonexistent.mp3"), into: dir)
        XCTAssertFalse(wrote)
        XCTAssertEqual(try Data(contentsOf: existing), Data("mine".utf8))
    }
}
