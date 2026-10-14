import Foundation

public struct EnrichResult: Sendable {
    public var lyricsWritten: Int = 0
    public var coversEmbedded: Int = 0
    /// Of `coversEmbedded`, how many came from an image already sitting in
    /// the album's folder rather than a network lookup.
    public var coversFromLocalFile: Int = 0
    public var coversNotFound: [String] = []
    public var lyricsNotFound: Int = 0
}

/// Fills in what a library is missing, using free online sources.
///
/// Runs against files already on the device, after the copy: it only touches
/// tracks that actually shipped, and never modifies the source library.
/// Nothing here is required for a sync to succeed — every lookup fails soft.
public struct Enricher: Sendable {
    public var lyrics: LyricsFetcher
    public var covers: CoverFetcher
    public var layout: DeviceLayout
    /// Art fetched online is resized to this before embedding, same limit the
    /// player needs for its own art.
    public var maxArtDimension: Int
    /// When true the tracks are already on the device, so their existing
    /// location is used rather than where the layout *would* put them.
    /// Without this, enriching in place writes lyrics next to files that
    /// don't exist.
    public var inPlace: Bool

    public init(lyrics: LyricsFetcher = LyricsFetcher(),
                covers: CoverFetcher = CoverFetcher(),
                layout: DeviceLayout = DeviceLayout(),
                maxArtDimension: Int = 500,
                inPlace: Bool = false) {
        self.lyrics = lyrics
        self.covers = covers
        self.layout = layout
        self.maxArtDimension = maxArtDimension
        self.inPlace = inPlace
    }

    /// Where this track's file actually lives on the device.
    func devicePath(for track: Track, deviceRoot: URL) -> String {
        inPlace ? SyncEngine().devicePath(of: track.sourceURL, root: deviceRoot)
                : layout.path(for: track)
    }

    /// Fetch and write `.lrc` files for tracks that do not already have one.
    public func addLyrics(
        for tracks: [Track],
        deviceRoot: URL,
        progress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async -> EnrichResult {
        var result = EnrichResult()

        for (i, track) in tracks.enumerated() {
            progress?(i + 1, tracks.count, track.effectiveTitle)

            let path = devicePath(for: track, deviceRoot: deviceRoot)
            let lrc = deviceRoot
                .appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                .deletingPathExtension()
                .appendingPathExtension("lrc")
            if FileManager.default.fileExists(atPath: lrc.path) { continue }

            guard let found = await lyrics.fetch(for: track) else {
                result.lyricsNotFound += 1
                continue
            }
            if lyrics.writeLRC(found, besideDevicePath: path, deviceRoot: deviceRoot) {
                result.lyricsWritten += 1
            }
        }
        return result
    }

    /// Find cover art for albums that have none, and embed it into the files
    /// on the device.
    public func addCovers(
        for tracks: [Track],
        albumsMissingArt: Set<String>,
        deviceRoot: URL,
        progress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async -> EnrichResult {
        var result = EnrichResult()
        guard !albumsMissingArt.isEmpty else { return result }

        // Group the device files by album so each album is fetched once.
        var byAlbum: [String: [Track]] = [:]
        for t in tracks {
            let key = FATName.foldedKey("\(t.effectiveAlbumArtist)/\(t.effectiveAlbum)")
            guard albumsMissingArt.contains(key) else { continue }
            byAlbum[key, default: []].append(t)
        }

        let optimizer = ArtworkOptimizer(maxDimension: maxArtDimension)
        var index = 0

        for (_, group) in byAlbum {
            index += 1
            guard let first = group.first else { continue }
            let label = "\(first.effectiveAlbumArtist) — \(first.effectiveAlbum)"
            progress?(index, byAlbum.count, label)

            // A cover already sitting in the album's own folder (a rip's
            // Front.jpg, a cover.jpg someone dropped there) reflects what the
            // user actually chose for this release — prefer it over guessing
            // via a network lookup, and it works with no internet at all.
            let albumDir = deviceRoot.appendingPathComponent(
                devicePath(for: first, deviceRoot: deviceRoot)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                .deletingLastPathComponent()
            let localFile = DeviceTidy.firstCoverImage(in: albumDir)
            let raw: Data?
            let fromLocalFile: Bool
            if let localFile, let data = try? Data(contentsOf: localFile) {
                raw = data
                fromLocalFile = true
            } else {
                raw = await covers.fetch(artist: first.effectiveAlbumArtist, album: first.effectiveAlbum)
                fromLocalFile = false
            }

            guard let raw else {
                result.coversNotFound.append(label)
                continue
            }
            // Downsize before embedding: both a local file and the archive
            // can be much larger than the player should decode.
            guard let jpeg = optimizer.shrink(raw) ?? (raw.isEmpty ? nil : raw) else {
                result.coversNotFound.append(label)
                continue
            }

            let size = optimizer.dimensions(jpeg)
                .flatMap { dims -> (Int, Int)? in
                    let parts = dims.split(separator: "x").compactMap { Int($0) }
                    return parts.count == 2 ? (parts[0], parts[1]) : nil
                }

            for track in group {
                let path = devicePath(for: track, deviceRoot: deviceRoot)
                let file = deviceRoot.appendingPathComponent(
                    path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                guard ArtworkOptimizer.isRewritable(file) else { continue }

                if Self.embed(jpeg: jpeg, size: size, into: file) {
                    result.coversEmbedded += 1
                    if fromLocalFile { result.coversFromLocalFile += 1 }
                }
            }
        }
        return result
    }
}

extension Enricher {
    /// Write cover art into a file that is already on the device, handling
    /// both containers. FLAC needs its metadata blocks rebuilt rather than an
    /// ID3 tag, so embedding through ID3 alone silently skipped every FLAC.
    static func embed(jpeg: Data, size: (Int, Int)?, into file: URL) -> Bool {
        if FLAC.isFLAC(file) {
            guard let size else { return false }
            // Rewriting streams to a new file, so build beside it and swap in.
            let temp = file.deletingLastPathComponent()
                .appendingPathComponent(".y1sync-art-\(UUID().uuidString).flac")
            defer { try? FileManager.default.removeItem(at: temp) }

            guard (try? FLAC.rewrite(from: file, to: temp,
                                     artwork: jpeg, artworkSize: size)) == true else {
                return false
            }
            do {
                _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
                return true
            } catch {
                return false
            }
        }

        guard let data = try? Data(contentsOf: file),
              let rewritten = ID3v2.rewriting(data, artwork: jpeg) else { return false }
        return (try? rewritten.write(to: file, options: .atomic)) != nil
    }
}
