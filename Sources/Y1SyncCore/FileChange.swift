import Foundation

/// What the sync actually did to one file, so the result can be shown and
/// checked rather than just counted.
public struct FileChange: Sendable, Hashable, Identifiable {
    public var id: String { devicePath }

    public var devicePath: String
    public var sourceURL: URL
    public var title: String
    public var artist: String
    public var album: String

    public var wasReplaced = false
    /// Original embedded art dimensions, when it was resized.
    public var artFrom: String?
    public var artTo: String?
    public var artBytesSaved: Int64 = 0
    /// Album artist rewritten to keep an album in one folder.
    public var albumArtistCorrected: String?
    public var lyricsAdded = false
    public var coverFetched = false

    public init(devicePath: String, track: Track) {
        self.devicePath = devicePath
        self.sourceURL = track.sourceURL
        self.title = track.effectiveTitle
        self.artist = track.effectiveArtist
        self.album = track.effectiveAlbum
    }

    /// Short human summary of everything done to this file.
    public var summary: [String] {
        var out: [String] = []
        if let from = artFrom, let to = artTo {
            out.append("cover \(from) → \(to)")
        }
        if let name = albumArtistCorrected {
            out.append("album artist → \(name)")
        }
        if coverFetched { out.append("cover found online") }
        if lyricsAdded { out.append("lyrics added") }
        if wasReplaced { out.append("replaced damaged copy") }
        return out
    }

    public var didAnything: Bool { !summary.isEmpty }
}
