import Foundation

/// A single audio file discovered in the local library.
public struct Track: Sendable, Hashable {
    public var sourceURL: URL
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var durationSeconds: Double?
    public var fileSize: Int64
    /// From tagging tools like beets/Picard's AcousticBrainz plugin. Absent
    /// on most files — every feature that reads these treats them as
    /// best-effort, never required.
    public var genre: String?
    public var bpm: Double?
    /// Positive mood labels from an `AB:MOOD`-style tag, e.g. ["happy", "sad"]
    /// (each mood is scored by an independent classifier, so a track can
    /// genuinely land positive on more than one, or none).
    public var moods: [String]
    /// What the audio is: "FLAC", "ALAC", "AAC", "MP3"… plus its sample rate
    /// and bit depth where the file says (nil for lossy formats that don't).
    public var codec: String?
    public var sampleRate: Int?
    public var bitDepth: Int?
    /// Tags to write into the file when it is copied to the player (set by the
    /// user's remembered merges); the library file itself is never changed.
    public var tagEdits: [String: String] = [:]

    public init(
        sourceURL: URL,
        title: String? = nil,
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        durationSeconds: Double? = nil,
        fileSize: Int64 = 0,
        genre: String? = nil,
        bpm: Double? = nil,
        moods: [String] = [],
        codec: String? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil
    ) {
        self.sourceURL = sourceURL
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.durationSeconds = durationSeconds
        self.fileSize = fileSize
        self.genre = genre
        self.bpm = bpm
        self.moods = moods
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }

    /// Tags are frequently missing or blank on files that came from odd
    /// sources, so every display value falls back to something usable rather
    /// than surfacing an empty string.
    public var effectiveTitle: String {
        title.flatMap(Self.nonBlank) ?? sourceURL.deletingPathExtension().lastPathComponent
    }

    public var effectiveArtist: String {
        artist.flatMap(Self.nonBlank) ?? "Unknown Artist"
    }

    /// Compilations tag each track with a different `artist` but share an
    /// `albumArtist`; grouping on the wrong one scatters an album across the
    /// device, so prefer album artist and only fall back to artist.
    public var effectiveAlbumArtist: String {
        albumArtist.flatMap(Self.nonBlank)
            ?? artist.flatMap(Self.nonBlank)
            ?? "Unknown Artist"
    }

    public var effectiveAlbum: String {
        album.flatMap(Self.nonBlank) ?? "Unknown Album"
    }

    public var fileExtension: String {
        sourceURL.pathExtension.lowercased()
    }

    static func nonBlank(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Audio containers the Y1's launcher (InniClassic) scans and plays. Used to filter
/// the library scan; anything else on disk is ignored rather than copied and left
/// invisible on the player.
public enum SupportedFormat: String, CaseIterable, Sendable {
    case mp3, flac, ogg, opus, m4a, m4b, aac, wav, ape, wma

    public static func isSupported(_ ext: String) -> Bool {
        SupportedFormat(rawValue: ext.lowercased()) != nil
    }
}
