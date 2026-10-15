import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Image work the app needs (cover size checks and shrinking), with ImageIO on
/// the Mac and ffmpeg elsewhere.
enum ImageTools {
    struct Info {
        var width: Int?
        var height: Int?
        /// Uniform-type style name, e.g. "public.jpeg".
        var type: String?
    }

    #if canImport(ImageIO)

    static func info(_ data: Data) -> Info {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return Info() }
        let type = CGImageSourceGetType(src) as String?
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return Info(width: nil, height: nil, type: type) }
        return Info(width: props[kCGImagePropertyPixelWidth] as? Int,
                    height: props[kCGImagePropertyPixelHeight] as? Int, type: type)
    }

    /// Scale so the long edge is at most `maxPixel`. JPEG when `jpegQuality` is set, else BMP.
    static func thumbnail(_ data: Data, maxPixel: Int, jpegQuality: Double?) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        let kind = jpegQuality != nil ? UTType.jpeg : UTType.bmp
        guard let dest = CGImageDestinationCreateWithData(out, kind.identifier as CFString, 1, nil) else { return nil }
        if let q = jpegQuality {
            CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
        } else {
            CGImageDestinationAddImage(dest, thumb, nil)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    #else

    static func info(_ data: Data) -> Info {
        guard let r = ExternalTool.run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                   "stream=width,height,codec_name", "-of", "json", "-i", "pipe:0"],
                                       stdin: data),
              r.status == 0,
              let json = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any],
              let s = (json["streams"] as? [[String: Any]])?.first else { return Info() }
        let names = ["mjpeg": "public.jpeg", "png": "public.png", "bmp": "com.microsoft.bmp",
                     "gif": "com.compuserve.gif", "webp": "org.webmproject.webp", "tiff": "public.tiff"]
        let codec = s["codec_name"] as? String ?? ""
        return Info(width: s["width"] as? Int, height: s["height"] as? Int, type: names[codec] ?? "public.\(codec)")
    }

    static func thumbnail(_ data: Data, maxPixel: Int, jpegQuality: Double?) -> Data? {
        let scale = "scale=w='min(\(maxPixel),iw)':h='min(\(maxPixel),ih)':force_original_aspect_ratio=decrease"
        var args = ["-v", "error", "-i", "pipe:0", "-vf", scale, "-frames:v", "1"]
        if let q = jpegQuality {
            args += ["-c:v", "mjpeg", "-q:v", String(max(2, min(31, Int((1 - q) * 20) + 2))), "-f", "image2pipe", "-"]
        } else {
            args += ["-c:v", "bmp", "-f", "image2pipe", "-"]
        }
        guard let r = ExternalTool.run("ffmpeg", args, stdin: data), r.status == 0, !r.stdout.isEmpty else { return nil }
        return r.stdout
    }

    #endif
}
