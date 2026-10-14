import Foundation
import AVFoundation
import ImageIO

/// Something wrong with a file, found before it reaches the player.
public enum TrackIssue: Sendable, Hashable {
    /// The file could not be opened or parsed at all.
    case unreadable(String)
    /// Zero bytes on disk — usually an interrupted download.
    case emptyFile
    /// Parses, but contains no audio stream.
    case noAudioTrack
    /// Parses, but reports no playable length — typically truncated.
    case zeroDuration
    /// Claims to hold audio but produces no decodable samples.
    case undecodable(String)
    /// Decodes, but is far too short to be a real track.
    case suspiciouslyShort(Double)
    /// Embedded cover art large enough to risk exhausting the player's buffer.
    case oversizedEmbeddedArt(bytes: Int, pixels: String?)
    /// Embedded art in a format the player cannot decode from inside the file.
    case undecodableEmbeddedArt(String)
    /// Tags the browser needs in order to file the track sensibly.
    case missingTags([String])
    /// Outside the limits the user set for the player (see `PlayerLimits`).
    case unsupportedByPlayer(String)

    /// Blocking issues mean the file should not be copied at all — it would
    /// occupy space and fail to play. Warnings are worth fixing but harmless.
    public var isBlocking: Bool {
        switch self {
        case .unreadable, .emptyFile, .noAudioTrack, .zeroDuration, .undecodable,
             .suspiciouslyShort, .unsupportedByPlayer:
            return true
        case .oversizedEmbeddedArt, .undecodableEmbeddedArt, .missingTags:
            return false
        }
    }

    public var describe: String {
        switch self {
        case .unreadable(let why): return "unreadable — \(why)"
        case .emptyFile: return "empty file (0 bytes)"
        case .noAudioTrack: return "no audio stream"
        case .zeroDuration: return "no playable audio — likely truncated"
        case .undecodable(let why): return "audio will not decode — \(why)"
        case .suspiciouslyShort(let s):
            return String(format: "only %.1fs of audio — not a real track", s)
        case .oversizedEmbeddedArt(let bytes, let px):
            let size = ByteFormat.string(Int64(bytes))
            return "embedded cover is \(size)\(px.map { " (\($0))" } ?? "") — can crash the player"
        case .undecodableEmbeddedArt(let kind):
            return "embedded cover is \(kind); the player only decodes embedded JPEG"
        case .missingTags(let fields):
            return "missing \(fields.joined(separator: ", "))"
        case .unsupportedByPlayer(let why):
            return "the player may not play it — \(why)"
        }
    }
}

public struct TrackReport: Sendable {
    public var track: Track
    public var issues: [TrackIssue]
    /// Whether the file carries cover art in its own tags. Stock Innioasis
    /// firmware reads art from here, so this — not a cover file — is what
    /// decides if the album shows artwork.
    public var hasEmbeddedArt: Bool = false

    public init(track: Track, issues: [TrackIssue], hasEmbeddedArt: Bool = false) {
        self.track = track
        self.issues = issues
        self.hasEmbeddedArt = hasEmbeddedArt
    }

    public var isPlayable: Bool { !issues.contains(where: \.isBlocking) }
}

/// Validates files before they are copied.
///
/// The player has far less headroom than a Mac: a file that plays fine in
/// Music can be truncated, headerless, or carry a 5 MB cover that exhausts
/// the album-art buffer. Checking here means a bad file never takes up space
/// on the device.
public struct TrackHealth: Sendable {
    /// Embedded art above this is treated as risky. Rockbox decodes embedded
    /// JPEG into a shared buffer; a few hundred KB is already far more than
    /// a 480x360 screen can use.
    public var maxEmbeddedArtBytes: Int
    /// Longest edge, in pixels, considered safe to decode on-device.
    public var maxEmbeddedArtPixels: Int

    /// Decode a short slice of each file to prove it really plays.
    public var deepCheck: Bool
    /// Anything shorter than this is treated as broken. Random bytes often
    /// decode as a fraction of a second of noise, which passes every other
    /// check; no real song is this short.
    public var minimumDuration: Double
    /// Also decode the last seconds. A cut-off download or interrupted copy
    /// keeps a valid start and a header that still claims the full length, so
    /// only the end shows it. Costs a seek per file, so it is off for the
    /// pre-copy check and on when auditing what is already on the player.
    public var checkTail: Bool
    /// Only decide playability: skip cover-art and missing-tag findings, which
    /// cost extra reads and don't matter when auditing files already on the player.
    public var audioOnly: Bool
    /// Formats the player is known (to the user) not to play.
    public var limits: PlayerLimits

    public init(maxEmbeddedArtBytes: Int = 1024 * 1024,
                maxEmbeddedArtPixels: Int = 1000,
                deepCheck: Bool = true,
                minimumDuration: Double = 1.0,
                checkTail: Bool = false,
                audioOnly: Bool = false,
                limits: PlayerLimits = .none) {
        self.limits = limits
        self.checkTail = checkTail
        self.audioOnly = audioOnly
        self.maxEmbeddedArtBytes = maxEmbeddedArtBytes
        self.maxEmbeddedArtPixels = maxEmbeddedArtPixels
        self.deepCheck = deepCheck
        self.minimumDuration = minimumDuration
    }

    /// Decode the first slice of audio. Returns a reason on failure, nil when
    /// the file yields real samples.
    func decodeFailure(_ asset: AVURLAsset, duration: Double? = nil) async -> String? {
        if let why = await decodeSlice(asset, start: 0, length: 2) { return why }
        guard checkTail, let duration, duration > 8 else { return nil }

        if FLAC.isFLAC(asset.url) {
            // FLAC can't seek cheaply, so decoding the tail would read the
            // whole file. Look at the end of the file first; only a file that
            // looks cut off is then confirmed by actually decoding its tail.
            guard let reason = FLAC.truncationReason(asset.url) else { return nil }
            return await decodeSlice(asset, start: duration - 3, length: 3) != nil ? reason : nil
        }
        if await decodeSlice(asset, start: duration - 3, length: 3) != nil {
            return "the end of the file is missing — cut off"
        }
        return nil
    }

    func decodeSlice(_ asset: AVURLAsset, start: Double, length: Double) async -> String? {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                return "no audio stream"
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            guard reader.canAdd(output) else { return "unsupported audio format" }
            reader.add(output)

            // A couple of seconds is enough to catch a bad header or a stream
            // that decodes to nothing, without reading whole albums.
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                           duration: CMTime(seconds: length, preferredTimescale: 600))
            guard reader.startReading() else {
                return reader.error?.localizedDescription ?? "could not start decoding"
            }

            var bytes = 0
            while let buffer = output.copyNextSampleBuffer() {
                bytes += CMSampleBufferGetTotalSampleSize(buffer)
                if bytes > 4096 { break }   // enough to prove it decodes
            }

            if reader.status == .failed {
                return reader.error?.localizedDescription ?? "decode failed"
            }
            return bytes > 0 ? nil : "produced no audio samples"
        } catch {
            return error.localizedDescription
        }
    }

    public func check(_ track: Track) async -> TrackReport {
        var issues: [TrackIssue] = []

        if track.fileSize == 0 {
            return TrackReport(track: track, issues: [.emptyFile])
        }

        if let why = limits.problem(for: track) {
            return TrackReport(track: track, issues: [.unsupportedByPlayer(why)])
        }

        let asset = AVURLAsset(url: track.sourceURL)
        var durationSeconds: Double?

        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if audioTracks.isEmpty { issues.append(.noAudioTrack) }

            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            durationSeconds = seconds.isFinite ? seconds : nil
            if !duration.isNumeric || seconds <= 0 {
                issues.append(.zeroDuration)
            } else if seconds < minimumDuration {
                issues.append(.suspiciouslyShort(seconds))
            }
        } catch {
            // A parse failure here is the signature of a corrupt or
            // half-downloaded file, so report it rather than throwing.
            return TrackReport(track: track, issues: [.unreadable(error.localizedDescription)])
        }

        // Header checks alone are not enough: 3 KB of random bytes happens to
        // contain valid MPEG frame syncs, so AVFoundation will happily report
        // "1 audio track, 0.52s". Only pulling real samples out proves the
        // file will actually play.
        if deepCheck, !issues.contains(where: \.isBlocking) {
            if let why = await decodeFailure(asset, duration: durationSeconds) {
                issues.append(.undecodable(why))
            }
        }

        if audioOnly { return TrackReport(track: track, issues: issues) }

        let art = await artworkIssues(for: track.sourceURL)
        issues.append(contentsOf: art.issues)

        var missing: [String] = []
        if Track.nonBlank(track.title ?? "") == nil { missing.append("title") }
        if Track.nonBlank(track.artist ?? "") == nil
            && Track.nonBlank(track.albumArtist ?? "") == nil { missing.append("artist") }
        if Track.nonBlank(track.album ?? "") == nil { missing.append("album") }
        if !missing.isEmpty { issues.append(.missingTags(missing)) }

        return TrackReport(track: track, issues: issues, hasEmbeddedArt: art.present)
    }

    func artworkIssues(for url: URL) async -> (issues: [TrackIssue], present: Bool) {
        // Read via the shared reader: AVFoundation exposes no artwork for
        // FLAC, so a lossless library would look like it had no covers.
        var artwork = EmbeddedArtwork.read(from: url)

        if artwork == nil {
            let asset = AVURLAsset(url: url)
            if let items = try? await asset.load(.commonMetadata) {
                for item in items where item.commonKey == .commonKeyArtwork {
                    if let data = try? await item.load(.dataValue) { artwork = data; break }
                }
            }
        }

        if let data = artwork {
            var issues: [TrackIssue] = []
            let info = EmbeddedArtwork.info(data)

            // Rockbox only decodes embedded JPEG (apps/playback.c checks
            // AA_TYPE_JPG); this does not apply to stock firmware, so it is
            // only reported, never blocking.
            if let type = info.type, type != "public.jpeg" {
                issues.append(.undecodableEmbeddedArt(shortName(type)))
            }

            let tooManyBytes = data.count > maxEmbeddedArtBytes
            let tooManyPixels = max(info.width ?? 0, info.height ?? 0) > maxEmbeddedArtPixels
            if tooManyBytes || tooManyPixels {
                let px = (info.width != nil && info.height != nil)
                    ? "\(info.width!)x\(info.height!)" : nil
                issues.append(.oversizedEmbeddedArt(bytes: data.count, pixels: px))
            }
            return (issues, true)
        }
        return ([], false)
    }

    func imageInfo(_ data: Data) -> (width: Int?, height: Int?, type: String?) {
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

    func shortName(_ uti: String) -> String {
        uti.replacingOccurrences(of: "public.", with: "").uppercased()
    }

    /// Check a whole library, in parallel batches.
    /// Identifies which checks were run, so a cached "fine" is only reused
    /// for the same checks.
    public var signature: String {
        "v1|art\(maxEmbeddedArtPixels)/\(maxEmbeddedArtBytes)|deep\(deepCheck)|tail\(checkTail)"
            + "|audio\(audioOnly)|min\(minimumDuration)"
            + "|rate\(limits.maxSampleRate ?? 0)|bits\(limits.maxBitDepth ?? 0)|alac\(limits.allowALAC)"
    }

    /// With a `cache`, files that passed these exact checks and have not
    /// changed since are not opened again. Only files with no findings at all
    /// are remembered, so warnings and problems are always re-evaluated.
    public func checkAll(_ tracks: [Track], cache: ScanCache?) async -> [TrackReport] {
        guard let cache else { return await checkAll(tracks) }
        let sig = signature
        var known: [TrackReport] = []
        var todo: [Track] = []
        for t in tracks {
            if let art = cache.healthyArt(for: t, signature: sig) {
                known.append(TrackReport(track: t, issues: [], hasEmbeddedArt: art))
            } else { todo.append(t) }
        }
        let fresh = await checkAll(todo)
        for r in fresh where r.issues.isEmpty {
            cache.markHealthy(r.track, signature: sig, hasEmbeddedArt: r.hasEmbeddedArt)
        }
        cache.save()
        let position = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1.sourceURL, $0) })
        return (known + fresh).sorted { (position[$0.track.sourceURL] ?? 0) < (position[$1.track.sourceURL] ?? 0) }
    }

    public func checkAll(_ tracks: [Track]) async -> [TrackReport] {
        var reports: [TrackReport] = []
        reports.reserveCapacity(tracks.count)

        // Bounded concurrency: unbounded task groups over a large library
        // open thousands of files at once and hit the descriptor limit.
        let batchSize = 8
        var index = 0
        while index < tracks.count {
            let slice = Array(tracks[index..<min(index + batchSize, tracks.count)])
            let batch = await withTaskGroup(of: TrackReport.self) { group -> [TrackReport] in
                for t in slice { group.addTask { await check(t) } }
                var out: [TrackReport] = []
                for await r in group { out.append(r) }
                return out
            }
            reports.append(contentsOf: batch)
            index += batchSize
        }

        // Task groups complete out of order; restore library order.
        let position = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1.sourceURL, $0) })
        return reports.sorted { (position[$0.track.sourceURL] ?? 0) < (position[$1.track.sourceURL] ?? 0) }
    }
}
