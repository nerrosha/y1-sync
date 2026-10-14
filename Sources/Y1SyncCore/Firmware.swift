import Foundation

/// The software running on the player. The Y1 runs several, and they differ in
/// what they play and show, so the app adapts instead of assuming one.
///
/// What each entry says comes from the project's own documentation (InniClassic's
/// README and tools, Rockbox's supported codecs). Where a detail is not known for
/// sure — the stock firmware's exact format list — the profile is inclusive and
/// says so; nothing is hidden on a guess.
public enum Firmware: String, CaseIterable, Codable, Sendable, Identifiable {
    case stock, launcher, rockbox

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stock: "Stock Innioasis"
        case .launcher: "JJ Launcher / InniClassic"
        case .rockbox: "Rockbox"
        }
    }

    /// One line shown next to the name.
    public var summary: String {
        switch self {
        case .stock:
            "The firmware the player shipped with. Shows file names, reads covers from the file's tags."
        case .launcher:
            "Community launcher (JJ Launcher, InniClassic). Keeps its own song list, shows covers large, writes a play log."
        case .rockbox:
            "Open-source firmware. Reads folders directly, plays the widest range of formats."
        }
    }

    /// File extensions the player's library scan picks up.
    public var formats: Set<String> {
        switch self {
        case .launcher, .stock:
            // The launcher's scan list. The stock firmware's own list is not
            // documented, so it is treated the same rather than hiding files.
            ["mp3", "flac", "wav", "ogg", "opus", "m4a", "m4b", "aac", "ape", "wma"]
        case .rockbox:
            ["mp3", "flac", "ogg", "opus", "m4a", "aac", "wav", "wv", "ape", "mpc", "aiff", "aif", "wma"]
        }
    }

    /// Longest edge of an embedded cover worth putting on the player.
    public var maxArtPixels: Int {
        switch self {
        case .launcher: 1000     // InniClassic asks for 600–1000 px; it shows covers near full screen
        case .stock, .rockbox: 500
        }
    }

    /// Keeps a song list file (`.y1_library_cache.json`) that must learn about new files.
    public var keepsSongList: Bool { self == .launcher }

    /// Writes `.scrobbler.log` (Rockbox only when its scrobbler is switched on).
    public var mayWritePlayLog: Bool { self != .stock }

    /// Look at the card for the marks each software leaves.
    public static func detect(deviceRoot: URL) -> Firmware {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: deviceRoot.appendingPathComponent(name).path) }
        if exists(".rockbox") { return .rockbox }
        if exists(PlayerLibraryCache.fileName) || exists("Y1_Themes") { return .launcher }
        if let log = try? String(contentsOf: deviceRoot.appendingPathComponent(ScrobbleLog.fileName), encoding: .utf8),
           log.contains("#CLIENT/JJY") { return .launcher }
        return .stock
    }
}
