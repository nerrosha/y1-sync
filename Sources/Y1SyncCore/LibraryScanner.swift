import Foundation
import AVFoundation

/// Walks a folder of music and reads tags.
///
/// Metadata comes from AVFoundation so there is no third-party dependency —
/// it handles ID3, iTunes/MP4 and Vorbis-comment style keys behind one API.
public struct LibraryScanner: Sendable {
    public init() {}

    /// Find every supported audio file under `root`.
    public func findAudioFiles(under root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in e {
            guard SupportedFormat.isSupported(url.pathExtension) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Read tags for one file. Falls back to a bare Track (filename-derived)
    /// rather than throwing, so one unreadable file never aborts a whole scan.
    public func readTrack(at url: URL) async -> Track {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var track = Track(sourceURL: url, fileSize: size)

        // AVFoundation does not expose Vorbis comments, so FLAC has to be
        // parsed directly or a whole lossless library reads as "Unknown".
        if FLAC.isFLAC(url), let meta = FLAC.read(url, includePictures: false) {
            track.title = meta["TITLE"]
            track.artist = meta["ARTIST"]
            track.albumArtist = meta["ALBUMARTIST"] ?? meta["ALBUM ARTIST"] ?? meta["ALBUM_ARTIST"]
            track.album = meta["ALBUM"]
            track.trackNumber = Self.parseLeadingInt(meta["TRACKNUMBER"])
            track.discNumber = Self.parseLeadingInt(meta["DISCNUMBER"])
            track.year = (meta["DATE"] ?? meta["ORIGINALDATE"] ?? meta["YEAR"])
                .flatMap(Self.parseYear)
            track.genre = meta["GENRE"]
            track.bpm = meta["BPM"].flatMap(Double.init)
            track.moods = Self.parseMoods(meta["AB:MOOD"])

            // The length is in STREAMINFO; asking AVFoundation for it opens the
            // file a second time, which is slow on a USB player.
            track.codec = "FLAC"
            let info = FLAC.streamInfo(url)
            track.sampleRate = info?.sampleRate
            track.bitDepth = info?.bitsPerSample
            if let seconds = info?.duration {
                track.durationSeconds = seconds
            } else if let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric {
                track.durationSeconds = CMTimeGetSeconds(duration)
            }
            return track
        }

        if ["m4a", "mp4", "m4b"].contains(track.fileExtension), let f = MP4Tags.audioFormat(url) {
            track.codec = f.codec; track.sampleRate = f.sampleRate; track.bitDepth = f.bitDepth
        } else {
            track.codec = track.fileExtension.uppercased()
        }

        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return track }

        for item in items {
            guard let key = item.commonKey else { continue }
            let stringValue = try? await item.load(.stringValue)
            let numberValue = try? await item.load(.numberValue)

            switch key {
            case .commonKeyTitle:
                track.title = stringValue
            case .commonKeyArtist:
                track.artist = stringValue
            case .commonKeyAlbumName:
                track.album = stringValue
            case .commonKeyCreationDate:
                if let s = stringValue { track.year = Self.parseYear(s) }
            default:
                break
            }
            if track.trackNumber == nil, let n = numberValue?.intValue,
               key.rawValue.lowercased().contains("track") {
                track.trackNumber = n
            }
        }

        // Album artist and track/disc numbers are not exposed as common keys,
        // so read them from the format-specific metadata.
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                guard let items = try? await asset.loadMetadata(for: format) else { continue }
                for item in items {
                    guard let raw = item.key as? String ?? item.identifier?.rawValue else { continue }
                    let k = raw.lowercased()

                    // Skip identifier and sort-order fields. Substring matching
                    // would otherwise pick up MUSICBRAINZ_ALBUMARTISTID as the
                    // album artist and file the track under a raw UUID.
                    if k.contains("musicbrainz") || k.contains("acoustid")
                        || k.hasSuffix("id") || k.contains("sort") { continue }
                    let stringValue = try? await item.load(.stringValue)
                    // Loaded up front: `await` is not allowed inside a `??`
                    // autoclosure, and these tags are numeric about as often
                    // as they are strings.
                    let intValue = (try? await item.load(.numberValue))??.intValue

                    if track.albumArtist == nil,
                       k.contains("albumartist") || k.contains("album_artist")
                        || k.hasSuffix("aart") || k.contains("tpe2") {
                        track.albumArtist = stringValue
                    }
                    if track.trackNumber == nil,
                       k.contains("tracknumber") || k.hasSuffix("trkn") || k.contains("trck") {
                        track.trackNumber = Self.parseLeadingInt(stringValue) ?? intValue
                    }
                    if track.discNumber == nil,
                       k.contains("discnumber") || k.hasSuffix("disk") || k.contains("tpos") {
                        track.discNumber = Self.parseLeadingInt(stringValue) ?? intValue
                    }
                    if track.year == nil, k.contains("date") || k.contains("year") {
                        track.year = stringValue.flatMap(Self.parseYear)
                    }
                }
            }
        }

        if let d = try? await asset.load(.duration), d.isNumeric {
            track.durationSeconds = CMTimeGetSeconds(d)
        }
        return track
    }

    /// With a `cache`, files whose size and modification time are unchanged
    /// since the last scan are not read again.
    public func scan(root: URL, cache: ScanCache? = nil,
                     progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [Track] {
        var tracks: [Track] = []
        let urls = findAudioFiles(under: root)
        for (i, url) in urls.enumerated() {
            if let cache, let stamp = ScanCache.stamp(of: url) {
                if let hit = cache.track(for: url, stamp: stamp) {
                    tracks.append(hit)
                } else {
                    let t = await readTrack(at: url)
                    cache.store(t, stamp: stamp)
                    tracks.append(t)
                }
            } else {
                tracks.append(await readTrack(at: url))
            }
            progress?(i + 1, urls.count)
        }
        cache?.save(keeping: urls)
        return tracks
    }

    /// Tags store track numbers as "4", "4/12" or occasionally " 4 ".
    static func parseLeadingInt(_ s: String?) -> Int? {
        guard let s else { return nil }
        let digits = s.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Dates appear as "1998", "1998-04-20" or full timestamps.
    static func parseYear(_ s: String) -> Int? {
        let digits = s.prefix { $0.isNumber }
        guard digits.count == 4, let y = Int(digits) else { return nil }
        return y
    }

    /// An `AB:MOOD`-style tag lists every axis a classifier scored, each as
    /// either the label ("Happy") or "Not " plus the label ("Not acoustic").
    /// Only the positive ones describe the track.
    static func parseMoods(_ s: String?) -> [String] {
        guard let s else { return [] }
        return s.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("not ") }
            .map { $0.lowercased() }
    }
}
