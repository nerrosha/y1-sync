import Foundation

/// Writes Rockbox-compatible playlists.
///
/// Rockbox reads `.m3u8` as UTF-8 and plain `.m3u` as latin-1. Anything with
/// non-ASCII in a track name — which is most real libraries — must be `.m3u8`
/// or the names come out mangled on the player.
public struct PlaylistWriter: Sendable {
    public var layout: DeviceLayout

    public init(layout: DeviceLayout = DeviceLayout()) {
        self.layout = layout
    }

    /// Build the file body. Paths are device-absolute so the playlist keeps
    /// working regardless of which folder the user opens it from.
    public func contents(name: String, tracks: [Track]) -> String {
        var lines = ["#EXTM3U"]
        for t in tracks {
            let seconds = t.durationSeconds.map { Int($0.rounded()) } ?? -1
            lines.append("#EXTINF:\(seconds),\(t.effectiveArtist) - \(t.effectiveTitle)")
            lines.append(layout.path(for: t))
        }
        // Rockbox tolerates \n; keep it simple and consistent.
        return lines.joined(separator: "\n") + "\n"
    }

    /// Names different Y1 firmware builds have been seen using for the
    /// playlist folder — this is not a Rockbox convention, it varies per
    /// build (InnioClassic uses "Y1_Playlists"; others have used plain
    /// "Playlists" or "Playlist"). Checked in this order.
    static let playlistFolderCandidates = ["Y1_Playlists", "Playlists", "Playlist", "PLAYLIST"]

    /// Whichever playlist folder the firmware itself already created, so a
    /// playlist actually lands somewhere the player looks. Only falls back
    /// to creating a new "Playlists" folder when none of the known names
    /// exist yet — which may mean this firmware doesn't use one at all.
    public static func playlistFolder(deviceRoot: URL) -> URL {
        let fm = FileManager.default
        for name in playlistFolderCandidates {
            let candidate = deviceRoot.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        return deviceRoot.appendingPathComponent("Playlists")
    }

    /// Write a playlist into whichever playlist folder the firmware already
    /// created on this device.
    @discardableResult
    public func write(name: String, tracks: [Track], deviceRoot: URL) throws -> URL {
        let dir = Self.playlistFolder(deviceRoot: deviceRoot)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let filename = FATName.filename(base: name, ext: "m3u8")
        let url = dir.appendingPathComponent(filename)
        try contents(name: name, tracks: tracks).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
