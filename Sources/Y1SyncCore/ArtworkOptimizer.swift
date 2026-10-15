import Foundation

/// Shrinks oversized embedded cover art on its way to the player.
///
/// The player's launcher reads artwork from the file's own metadata. Huge images
/// can exhaust its memory (the stock firmware crashed on them), but InniClassic
/// shows covers close to full screen and asks for at least 600x600, ideally
/// 1000x1000, so the default keeps 1000 px. This rewrites the tag on the *copy*
/// that goes to the device; the original library file is never modified.
public struct ArtworkOptimizer: Sendable {
    /// Longest edge kept on the device.
    public var maxDimension: Int
    /// JPEG quality for the re-encoded cover.
    public var quality: Double

    public init(maxDimension: Int = 1000, quality: Double = 0.85) {
        self.maxDimension = maxDimension
        self.quality = quality
    }

    public struct Result: Sendable {
        public var didRewrite: Bool
        public var originalArtBytes: Int?
        public var newArtBytes: Int?
        public var note: String?
        /// Pixel dimensions before and after, e.g. "1600x1600" -> "500x500".
        public var fromPixels: String?
        public var toPixels: String?
    }

    /// Pixel dimensions of encoded image data, for reporting.
    public func dimensions(_ data: Data) -> String? {
        let i = ImageTools.info(data)
        guard let w = i.width, let h = i.height else { return nil }
        return "\(w)x\(h)"
    }

    /// True when this container's tags can be rewritten in place.
    public static func isRewritable(_ url: URL) -> Bool {
        ["mp3", "flac"].contains(url.pathExtension.lowercased())
    }

    /// Downscale `image` to a JPEG no larger than `maxDimension` on its long
    /// edge. Returns nil when the image is already small enough.
    public func shrink(_ data: Data) -> Data? {
        let info = ImageTools.info(data)
        if let w = info.width, let h = info.height, max(w, h) <= maxDimension, info.type == "public.jpeg" {
            return nil   // already small enough, and already JPEG
        }
        return ImageTools.thumbnail(data, maxPixel: maxDimension, jpegQuality: quality)
    }

    /// Copy `source` to `destination`, shrinking embedded art on the way and
    /// optionally correcting the album artist tag.
    ///
    /// Falls back to a plain copy whenever the file has no tag, no art, or art
    /// that is already small — so this is always safe to run over a library.
    /// The source file is never modified.
    @discardableResult
    public func copyOptimising(
        from source: URL,
        to destination: URL,
        albumArtist: String? = nil
    ) throws -> Result {
        guard Self.isRewritable(source) else {
            try FileManager.default.copyItem(at: source, to: destination)
            return Result(didRewrite: false, originalArtBytes: nil, newArtBytes: nil,
                          note: "\(source.pathExtension.lowercased()) tags are not rewritten")
        }

        if FLAC.isFLAC(source) {
            return try copyOptimisingFLAC(from: source, to: destination, albumArtist: albumArtist)
        }

        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let art = ID3v2.artwork(in: data)

        // TPE2 is the album-artist frame; writing it keeps a compilation
        // together in tag-driven library views, not just in the folder tree.
        var textFrames: [String: String] = [:]
        if let albumArtist { textFrames["TPE2"] = albumArtist }

        var smaller: Data?
        if let art, let shrunk = shrink(art), shrunk.count < art.count {
            smaller = shrunk
        }

        guard smaller != nil || !textFrames.isEmpty,
              let rewritten = ID3v2.rewriting(data, artwork: smaller, textFrames: textFrames)
        else {
            try data.write(to: destination, options: .atomic)
            return Result(didRewrite: false,
                          originalArtBytes: art?.count, newArtBytes: art?.count)
        }

        try rewritten.write(to: destination, options: .atomic)
        return Result(didRewrite: smaller != nil,
                      originalArtBytes: art?.count,
                      newArtBytes: smaller?.count ?? art?.count,
                      fromPixels: smaller != nil ? art.flatMap(dimensions) : nil,
                      toPixels: smaller.flatMap(dimensions))
    }
}

extension ArtworkOptimizer {
    /// FLAC equivalent of `copyOptimising`: rebuild the metadata blocks with a
    /// smaller cover, streaming the audio frames through unchanged.
    func copyOptimisingFLAC(
        from source: URL,
        to destination: URL,
        albumArtist: String?
    ) throws -> Result {
        guard let meta = FLAC.read(source) else {
            try FileManager.default.copyItem(at: source, to: destination)
            return Result(didRewrite: false, originalArtBytes: nil, newArtBytes: nil,
                          note: "not a readable FLAC")
        }

        let existing = FLAC.frontCover(meta)
        var smaller: Data?
        var newSize: (width: Int, height: Int)?

        if let art = existing?.data, let shrunk = shrink(art), shrunk.count < art.count,
           let dims = dimensions(shrunk) {
            let parts = dims.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 {
                smaller = shrunk
                newSize = (parts[0], parts[1])
            }
        }

        // Only touch the album artist when it actually differs, so a plain
        // copy stays a plain copy.
        var fields: [String: String]?
        if let albumArtist,
           meta["ALBUMARTIST"] != albumArtist, meta["ALBUM ARTIST"] != albumArtist {
            var updated = meta.fields
            updated["ALBUMARTIST"] = albumArtist
            updated["ALBUM ARTIST"] = nil     // avoid two disagreeing spellings
            fields = updated
        }

        guard smaller != nil || fields != nil else {
            try FileManager.default.copyItem(at: source, to: destination)
            return Result(didRewrite: false,
                          originalArtBytes: existing?.data.count,
                          newArtBytes: existing?.data.count)
        }

        let wrote = try FLAC.rewrite(from: source, to: destination,
                                     artwork: smaller, artworkSize: newSize, fields: fields)
        guard wrote else {
            try FileManager.default.copyItem(at: source, to: destination)
            return Result(didRewrite: false,
                          originalArtBytes: existing?.data.count,
                          newArtBytes: existing?.data.count)
        }

        return Result(didRewrite: smaller != nil,
                      originalArtBytes: existing?.data.count,
                      newArtBytes: smaller?.count ?? existing?.data.count,
                      fromPixels: smaller != nil && existing != nil
                        ? "\(existing!.width)x\(existing!.height)" : nil,
                      toPixels: newSize.map { "\($0.width)x\($0.height)" })
    }
}
