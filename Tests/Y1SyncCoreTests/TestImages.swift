import Foundation
import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif
@testable import Y1SyncCore

/// Small test pictures. CoreGraphics on the Mac, ffmpeg elsewhere (the Windows
/// build installs it before running the tests).
enum TestImages {
    enum Format { case png, jpeg }

    /// A picture with `blocks` coloured rectangles, so JPEG cannot squeeze it to nothing.
    static func make(side: Int, format: Format, blocks: Int = 40, quality: Double = 0.9) throws -> Data {
        #if canImport(CoreGraphics)
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.5, green: 0.8, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        for i in 0..<blocks {
            ctx.setFillColor(CGColor(red: Double(i % 7) / 7.0, green: 0.4, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: i * 13 % side, y: i * 29 % side, width: side / 4, height: side / 4))
        }
        let data = NSMutableData()
        let kind = format == .png ? UTType.png : UTType.jpeg
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, kind.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()),
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
        #else
        var filters = "color=c=0x80cc99:s=\(side)x\(side):d=1,format=rgb24"
        for i in 0..<blocks {
            let r = 40 + (i % 7) * 30
            filters += ",drawbox=x=\(i * 13 % side):y=\(i * 29 % side):w=\(side / 4):h=\(side / 4):color=0x\(String(format: "%02x", r))66b3:t=fill"
        }
        let codec = format == .png ? ["-c:v", "png"] : ["-c:v", "mjpeg", "-q:v", "3"]
        let r = try XCTUnwrap(ExternalTool.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", filters,
                                                          "-frames:v", "1"] + codec + ["-f", "image2pipe", "-"]))
        XCTAssertEqual(r.status, 0, String(decoding: r.stderr, as: UTF8.self))
        return r.stdout
        #endif
    }
}
