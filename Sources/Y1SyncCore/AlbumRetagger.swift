import Foundation

/// Album-title edits (merging a split album) — a thin layer over `TagEditor`.
public enum AlbumRetagger {
    public typealias Outcome = TagEditor.Outcome

    /// The album tag as stored in the file, nil if unreadable or unsupported.
    public static func currentAlbum(of url: URL) -> String? {
        TagEditor.read(url, fields: ["ALBUM"])["ALBUM"]
    }

    @discardableResult
    public static func setAlbum(_ album: String, in url: URL) -> Bool {
        TagEditor.write(["ALBUM": album], in: url)
    }

    /// Give every track the same album title, recording each old one for Undo.
    public static func setAlbum(_ album: String, for tracks: [Track], deviceRoot: URL,
                                undo: UndoRecorder? = nil) -> Outcome {
        TagEditor.apply({ _ in ["ALBUM": album] }, to: tracks, deviceRoot: deviceRoot, undo: undo)
    }
}

/// Artist-name edits (merging one artist spelled two ways).
public enum ArtistRetagger {
    /// Set the album artist of every track to `name`. A track's own ARTIST is
    /// changed too, but only when it is exactly the spelling being replaced —
    /// "A feat. B" credits are never touched.
    public static func setAlbumArtist(_ name: String, for tracks: [Track], deviceRoot: URL,
                                      undo: UndoRecorder? = nil) -> TagEditor.Outcome {
        TagEditor.apply({ t in
            var changes = ["ALBUMARTIST": name]
            let replaced = t.albumArtist ?? t.artist
            if let replaced, t.artist == replaced, replaced != name { changes["ARTIST"] = name }
            return changes
        }, to: tracks, deviceRoot: deviceRoot, undo: undo)
    }
}
