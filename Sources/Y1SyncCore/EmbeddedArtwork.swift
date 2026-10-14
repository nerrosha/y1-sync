import Foundation
import CoreGraphics
import ImageIO

/// One place to read cover art out of a file, whatever the container.
///
/// MP3 stores it in an ID3 APIC frame, FLAC in a metadata PICTURE block.
/// Everything that displays or checks artwork goes through here so the two
/// formats behave identically.
public enum EmbeddedArtwork {
    public static func read(from url: URL) -> Data? {
        switch url.pathExtension.lowercased() {
        case "flac":
            guard let meta = FLAC.read(url), let picture = FLAC.frontCover(meta) else { return nil }
            return picture.data
        case "mp3":
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return ID3v2.artwork(in: data)
        default:
            return nil
        }
    }

    /// Pixel size and image type of encoded data, without fully decoding it.
    public static func info(_ data: Data) -> (width: Int?, height: Int?, type: String?) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return (nil, nil, nil)
        }
        let type = CGImageSourceGetType(src) as String?
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return (nil, nil, type) }
        return (props[kCGImagePropertyPixelWidth] as? Int,
                props[kCGImagePropertyPixelHeight] as? Int,
                type)
    }
}
