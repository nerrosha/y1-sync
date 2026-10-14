import Foundation

/// Rewrites the album tag of files in place. Only tags change — the audio bytes
/// are streamed through untouched — and each file is swapped in atomically.
public enum AlbumRetagger {
    public struct Outcome: Sendable {
        public var changed = 0
        public var failed: [String] = []
        public init() {}
    }

    /// The album tag as stored in the file, nil if unreadable or unsupported.
    public static func currentAlbum(of url: URL) -> String? {
        if FLAC.isFLAC(url) { return FLAC.read(url, includePictures: false)?["ALBUM"] }
        guard url.pathExtension.lowercased() == "mp3",
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let tag = ID3v2.parse(data) else { return nil }
        return tag.frames.first { $0.id == "TALB" }.flatMap { text(of: $0.body) }
    }

    /// A text frame body: one encoding byte, then the string.
    static func text(of body: Data) -> String? {
        guard let enc = body.first else { return nil }
        let raw = body.dropFirst()
        let encoding: String.Encoding = switch enc {
        case 1: .utf16
        case 2: .utf16BigEndian
        case 3: .utf8
        default: .isoLatin1
        }
        return String(data: raw, encoding: encoding)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")).nonEmpty
    }

    /// Set the album tag; false when the format cannot be rewritten or it failed.
    @discardableResult
    public static func setAlbum(_ album: String, in url: URL) -> Bool {
        if FLAC.isFLAC(url) {
            guard let meta = FLAC.read(url, includePictures: false) else { return false }
            var fields = meta.fields
            fields["ALBUM"] = album
            let temp = url.deletingLastPathComponent().appendingPathComponent(".y1sync-tag-\(UUID().uuidString).flac")
            defer { try? FileManager.default.removeItem(at: temp) }
            guard (try? FLAC.rewrite(from: url, to: temp, fields: fields)) == true,
                  (try? FileManager.default.replaceItemAt(url, withItemAt: temp)) != nil else { return false }
            return true
        }
        guard url.pathExtension.lowercased() == "mp3",
              let data = try? Data(contentsOf: url),
              let out = ID3v2.rewriting(data, textFrames: ["TALB": album]) else { return false }
        return (try? out.write(to: url, options: .atomic)) != nil
    }

    /// Retag `tracks` (files on the player) and record the old value of each in
    /// `undo`, so Undo can put every title back.
    public static func setAlbum(_ album: String, for tracks: [Track], deviceRoot: URL,
                                undo: UndoRecorder? = nil) -> Outcome {
        var outcome = Outcome()
        let engine = SyncEngine()
        for t in tracks {
            let path = engine.devicePath(of: t.sourceURL, root: deviceRoot)
            guard let old = currentAlbum(of: t.sourceURL) ?? t.album else { outcome.failed.append(path); continue }
            if old == album { continue }
            if setAlbum(album, in: t.sourceURL) {
                undo?.recordRetag(path: path, oldAlbum: old)
                outcome.changed += 1
            } else {
                outcome.failed.append(path)
            }
        }
        return outcome
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
