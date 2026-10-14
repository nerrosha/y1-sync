import Foundation

/// Reads and rewrites a few text tags in place — only tags: the audio bytes are
/// streamed through untouched and the file is swapped in atomically.
///
/// Fields are named the Vorbis way: `ALBUM`, `ALBUMARTIST`, `ARTIST`. FLAC uses
/// them directly (and clears the other spellings of album artist); MP3 maps
/// them to `TALB`, `TPE2`, `TPE1`.
public enum TagEditor {
    static let mp3Frames = ["ALBUM": "TALB", "ALBUMARTIST": "TPE2", "ARTIST": "TPE1"]
    static let albumArtistSpellings = ["ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"]

    /// Current values of `fields` (missing ones are absent from the result).
    public static func read(_ url: URL, fields: [String]) -> [String: String] {
        var out: [String: String] = [:]
        if FLAC.isFLAC(url) {
            guard let meta = FLAC.read(url, includePictures: false) else { return out }
            for f in fields {
                let names = f == "ALBUMARTIST" ? albumArtistSpellings : [f]
                if let v = names.compactMap({ meta[$0] }).first(where: { !$0.isEmpty }) { out[f] = v }
            }
            return out
        }
        if isMP4(url) { return MP4Tags.read(url, fields: fields) }
        guard url.pathExtension.lowercased() == "mp3",
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let tag = ID3v2.parse(data) else { return out }
        for f in fields {
            if let id = mp3Frames[f], let frame = tag.frames.first(where: { $0.id == id }),
               let v = text(of: frame.body) { out[f] = v }
        }
        return out
    }

    /// Apply `changes` (nil removes a field; MP3 cannot remove, only set).
    /// False when the format cannot be rewritten or the write failed.
    @discardableResult
    public static func write(_ changes: [String: String?], in url: URL) -> Bool {
        if FLAC.isFLAC(url) {
            guard let meta = FLAC.read(url, includePictures: false) else { return false }
            var fields = meta.fields
            for (name, value) in changes {
                if name == "ALBUMARTIST" { albumArtistSpellings.forEach { fields[$0] = nil } }
                fields[name] = value
            }
            let temp = url.deletingLastPathComponent().appendingPathComponent(".y1sync-tag-\(UUID().uuidString).flac")
            defer { try? FileManager.default.removeItem(at: temp) }
            guard (try? FLAC.rewrite(from: url, to: temp, fields: fields)) == true,
                  (try? FileManager.default.replaceItemAt(url, withItemAt: temp)) != nil else { return false }
            return true
        }
        if isMP4(url) { return MP4Tags.write(changes, in: url) }
        guard url.pathExtension.lowercased() == "mp3", let data = try? Data(contentsOf: url) else { return false }
        var frames: [String: String] = [:]
        for (name, value) in changes {
            guard let id = mp3Frames[name], let value else { continue }
            frames[id] = value
        }
        guard !frames.isEmpty, let out = ID3v2.rewriting(data, textFrames: frames) else { return false }
        return (try? out.write(to: url, options: .atomic)) != nil
    }

    static func isMP4(_ url: URL) -> Bool { ["m4a", "mp4", "m4b"].contains(url.pathExtension.lowercased()) }

    /// A text frame body: one encoding byte, then the string.
    static func text(of body: Data) -> String? {
        guard let enc = body.first else { return nil }
        let encoding: String.Encoding = switch enc {
        case 1: .utf16
        case 2: .utf16BigEndian
        case 3: .utf8
        default: .isoLatin1
        }
        let s = String(data: body.dropFirst(), encoding: encoding)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return s?.isEmpty == false ? s : nil
    }

    /// Apply `changes` to each track's file, writing every previous value to
    /// `undo` first so Undo can restore it. Files already holding the new
    /// values are left alone.
    public struct Outcome: Sendable {
        public var changed = 0
        public var failed: [String] = []
        public init() {}
    }

    public static func apply(_ changes: (Track) -> [String: String], to tracks: [Track],
                             deviceRoot: URL, undo: UndoRecorder?) -> Outcome {
        var outcome = Outcome()
        let engine = SyncEngine()
        for t in tracks {
            let wanted = changes(t)
            guard !wanted.isEmpty else { continue }
            let path = engine.devicePath(of: t.sourceURL, root: deviceRoot)
            let old = read(t.sourceURL, fields: Array(wanted.keys))
            let toSet = wanted.filter { old[$0.key] != $0.value }
            if toSet.isEmpty { continue }
            if write(toSet.mapValues { Optional($0) }, in: t.sourceURL) {
                undo?.recordRetag(path: path, old: old.filter { toSet[$0.key] != nil },
                                  remove: toSet.keys.filter { old[$0] == nil }.sorted())
                outcome.changed += 1
            } else {
                outcome.failed.append(path)
            }
        }
        return outcome
    }
}
