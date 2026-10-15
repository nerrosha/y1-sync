import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

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
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
        #else
        return EmbeddedArtwork.read(from: url) ?? PlatformMedia.embeddedArtwork(in: url)
        #endif
    }

    /// Transcode arbitrary image data to a downscaled BMP.
    public func makeBMP(from data: Data) -> Data? {
        ImageTools.thumbnail(data, maxPixel: maxDimension, jpegQuality: nil)
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
