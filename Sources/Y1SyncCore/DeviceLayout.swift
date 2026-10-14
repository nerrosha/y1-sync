import Foundation

/// Decides where a track lives on the player.
///
/// Rockbox browses the filesystem directly, so the folder tree *is* the
/// navigation UI. A flat dump of files is unusable on a click wheel; an
/// `Artist/Album/NN Title` tree means the built-in browser sorts correctly
/// without needing the tag database to be rebuilt on-device.
public struct DeviceLayout: Sendable {
    /// Root folder on the device that music is written under.
    public var musicRoot: String

    public init(musicRoot: String = "/Music") {
        self.musicRoot = musicRoot
    }

    /// Device-absolute path for a track, e.g. `/Music/Boards of Canada/Geogaddi/04 1969.mp3`.
    public func path(for track: Track) -> String {
        let artist = FATName.component(track.effectiveAlbumArtist)
        let album = FATName.component(track.effectiveAlbum)
        let base = FATName.component(numberedTitle(for: track))
        let name = FATName.filename(base: base, ext: track.fileExtension)
        return "\(musicRoot)/\(artist)/\(album)/\(name)"
    }

    /// Track numbers are zero-padded so the browser's lexical sort matches the
    /// album order; without padding "10" sorts before "2".
    func numberedTitle(for track: Track) -> String {
        let title = track.effectiveTitle
        guard let n = track.trackNumber, n > 0 else { return title }

        // Untagged files fall back to their filename, which usually already
        // begins with the track number — prefixing again gives "09 09 Title".
        if Self.startsWithTrackNumber(title, n) { return title }

        let padded = String(format: "%02d", n)
        // Multi-disc sets otherwise collide at "01 ..." for every disc.
        if let disc = track.discNumber, disc > 1 {
            return "\(disc)-\(padded) \(title)"
        }
        return "\(padded) \(title)"
    }

    /// True when `title` already opens with this track's number, in any of the
    /// common spellings: "09 ", "9 ", "09. ", "09 - ".
    static func startsWithTrackNumber(_ title: String, _ number: Int) -> Bool {
        let digits = title.prefix { $0.isNumber }
        guard !digits.isEmpty, Int(digits) == number else { return false }

        let rest = title.dropFirst(digits.count)
        guard let next = rest.first else { return true }
        return next == " " || next == "." || next == "-" || next == "_"
    }
}
