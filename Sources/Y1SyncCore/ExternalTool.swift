import Foundation

/// Runs the helper programs (ffmpeg / ffprobe) the Windows build uses where
/// the Mac build uses AVFoundation and ImageIO. Nothing here is used on macOS.
enum ExternalTool {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    /// `ffmpeg` / `ffprobe`: next to the program, in `Y1SYNC_TOOLS`, or on PATH.
    static func locate(_ name: String) -> URL? {
        #if os(Windows)
        let file = name + ".exe"
        let separator: Character = ";"
        #else
        let file = name
        let separator: Character = ":"
        #endif
        var folders: [String] = []
        if let custom = ProcessInfo.processInfo.environment["Y1SYNC_TOOLS"] { folders.append(custom) }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent().path { folders.append(exe) }
        folders.append(FileManager.default.currentDirectoryPath)
        if let path = ProcessInfo.processInfo.environment["PATH"] ?? ProcessInfo.processInfo.environment["Path"] {
            folders.append(contentsOf: path.split(separator: separator).map(String.init))
        }
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(file)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static var isAvailable: Bool { locate("ffmpeg") != nil && locate("ffprobe") != nil }

    /// Run `tool`, optionally feeding `stdin`, and collect everything it prints.
    static func run(_ tool: String, _ arguments: [String], stdin: Data? = nil,
                    timeout: TimeInterval = 180) -> Output? {
        guard let exe = locate(tool) else { return nil }
        let process = Process()
        process.executableURL = exe
        process.arguments = arguments
        let out = Pipe(), err = Pipe(), inp = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = inp

        do { try process.run() } catch { return nil }

        let group = DispatchGroup()
        final class Box: @unchecked Sendable { var out = Data(); var err = Data() }
        let box = Box()
        group.enter()
        DispatchQueue.global().async { box.out = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { box.err = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        DispatchQueue.global().async {
            if let stdin { try? inp.fileHandleForWriting.write(contentsOf: stdin) }
            try? inp.fileHandleForWriting.close()
        }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        group.wait()
        return Output(status: process.terminationStatus, stdout: box.out, stderr: box.err)
    }
}

/// What ffprobe says about a file.
struct MediaInfo {
    var duration: Double?
    var hasAudio: Bool
    var codec: String?
    var sampleRate: Int?
    var bitDepth: Int?
    /// Lower-cased tag names (title, artist, album, album_artist, track, disc, date, genre…).
    var tags: [String: String]
}

enum PlatformMedia {
    static func probe(_ url: URL) -> MediaInfo? {
        guard let r = ExternalTool.run("ffprobe", ["-v", "error", "-show_format", "-show_streams",
                                                   "-of", "json", url.path]),
              r.status == 0,
              let json = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any] else { return nil }
        let streams = json["streams"] as? [[String: Any]] ?? []
        let audio = streams.first { ($0["codec_type"] as? String) == "audio" }
        let format = json["format"] as? [String: Any] ?? [:]

        var tags: [String: String] = [:]
        for source in [audio?["tags"], format["tags"]] {
            for (k, v) in (source as? [String: Any]) ?? [:] {
                if let s = v as? String, tags[k.lowercased()] == nil { tags[k.lowercased()] = s }
            }
        }
        let duration = (format["duration"] as? String).flatMap(Double.init)
            ?? (audio?["duration"] as? String).flatMap(Double.init)
        let bits = (audio?["bits_per_raw_sample"] as? String).flatMap(Int.init)
            ?? (audio?["bits_per_sample"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        return MediaInfo(duration: duration, hasAudio: audio != nil,
                         codec: (audio?["codec_name"] as? String)?.uppercased(),
                         sampleRate: (audio?["sample_rate"] as? String).flatMap(Int.init),
                         bitDepth: bits, tags: tags)
    }

    /// Decode `length` seconds from `start`; nil when real samples came out.
    static func decodeSlice(_ url: URL, start: Double, length: Double) -> String? {
        guard let r = ExternalTool.run("ffmpeg", ["-v", "error", "-ss", String(start), "-t", String(length),
                                                  "-i", url.path, "-vn", "-f", "s16le", "-"]) else {
            return "ffmpeg is not installed"
        }
        if r.status != 0 {
            let why = String(decoding: r.stderr, as: UTF8.self).split(separator: "\n").first.map(String.init)
            return why ?? "decode failed"
        }
        return r.stdout.count > 4096 ? nil : "produced no audio samples"
    }

    static func embeddedArtwork(in url: URL) -> Data? {
        guard let r = ExternalTool.run("ffmpeg", ["-v", "error", "-i", url.path, "-an", "-map", "0:v:0",
                                                  "-c", "copy", "-f", "image2pipe", "-"]),
              r.status == 0, !r.stdout.isEmpty else { return nil }
        return r.stdout
    }
}

extension FileManager {
    /// Put `replacement` in the place of `original`. `replaceItemAt` is not
    /// implemented in Foundation on Windows, so there the old file is moved aside
    /// first and only deleted once the new one is in place.
    @discardableResult
    func swapFile(_ original: URL, with replacement: URL) throws -> Bool {
        #if os(Windows)
        let aside = original.deletingLastPathComponent()
            .appendingPathComponent(".y1sync-old-\(UUID().uuidString)")
        try moveItem(at: original, to: aside)
        do {
            try moveItem(at: replacement, to: original)
        } catch {
            try? moveItem(at: aside, to: original)   // put the old file back
            throw error
        }
        try? removeItem(at: aside)
        return true
        #else
        return try replaceItemAt(original, withItemAt: replacement) != nil
        #endif
    }
}

/// What this build needs from the machine it runs on.
public enum Capabilities {
    /// True when media files can be read here: always on the Mac, and on other
    /// systems when ffmpeg and ffprobe are installed next to the program or on PATH.
    public static var canReadMedia: Bool {
        #if canImport(AVFoundation)
        true
        #else
        ExternalTool.isAvailable
        #endif
    }
}
