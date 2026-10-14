import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Extracts embedded cover art and writes it as `cover.bmp` next to the album.
///
/// Rockbox's `search_albumart_files` looks for `cover.bmp` in the track's
/// folder, and this build is compiled with `EXT "bmp"` — it will not read the
/// JPEG that is embedded in most files. Art therefore has to be transcoded to
/// BMP at sync time or the player shows nothing.
public struct AlbumArtExporter: Sendable {
    /// Long edge of the written bitmap. The Y1 panel is 480x360 and the theme
    /// shows art at 192px, so anything beyond ~300px is wasted space on a
    /// device where storage and decode time both matter.
    public var maxDimension: Int

    public init(maxDimension: Int = 240) {
        self.maxDimension = maxDimension
    }

    /// Pull embedded artwork out of an audio file, if it has any.
    public func embeddedArtwork(in url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }

    /// Transcode arbitrary image data to a downscaled BMP.
    public func makeBMP(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        // Let ImageIO do the downscale while decoding: far cheaper than
        // decoding a full-size cover and resampling afterwards.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.bmp.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Write `cover.bmp` into `albumDirectory` unless one is already there.
    /// Returns true when a file was written.
    @discardableResult
    public func writeCover(from sourceTrack: URL, into albumDirectory: URL) async -> Bool {
        let cover = albumDirectory.appendingPathComponent("cover.bmp")
        if FileManager.default.fileExists(atPath: cover.path) { return false }

        guard let raw = await embeddedArtwork(in: sourceTrack),
              let bmp = makeBMP(from: raw) else { return false }

        try? FileManager.default.createDirectory(at: albumDirectory, withIntermediateDirectories: true)
        do {
            try bmp.write(to: cover, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Write one cover per album folder for a set of synced tracks.
    /// Only the first track of each album is inspected — covers within an
    /// album are effectively always identical, and decoding every file would
    /// dominate sync time for no benefit.
    @discardableResult
    public func exportCovers(
        for tracks: [Track],
        layout: DeviceLayout,
        deviceRoot: URL
    ) async -> Int {
        var seen = Set<String>()
        var written = 0

        for track in tracks {
            let devicePath = layout.path(for: track)
            let albumDir = (devicePath as NSString).deletingLastPathComponent
            guard seen.insert(FATName.foldedKey(albumDir)).inserted else { continue }

            let dir = deviceRoot.appendingPathComponent(
                albumDir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
            if await writeCover(from: track.sourceURL, into: dir) { written += 1 }
        }
        return written
    }
}
