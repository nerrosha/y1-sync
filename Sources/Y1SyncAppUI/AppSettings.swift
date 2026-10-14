import Foundation

/// Everything the app remembers between launches.
///
/// Plain `UserDefaults` (domain `local.y1sync`): the values are small, and
/// the app is not sandboxed, so a library folder can be stored as a path
/// rather than a security-scoped bookmark.
enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let libraryFolder = "libraryFolderPath"
        static let preferredDevice = "preferredDeviceName"
        static let playlistName = "playlistName"
        static let resizeArtwork = "resizeArtwork"
        static let maxArtDimension = "maxArtDimension"
        static let fetchLyrics = "fetchLyrics"
        static let fetchCovers = "fetchCovers"
        static let excludedAlbums = "excludedAlbums"
        static let autoCompare = "compareWhenPlayerConnects"
        static let removeJunk = "tidyRemovesJunk"
        static let sounds = "soundsEnabled"
    }

    /// The remembered library folder, but only if it is still there — a
    /// folder on an unplugged drive or one since deleted is dropped rather
    /// than offered and then failing on scan.
    static var libraryFolder: URL? {
        get {
            guard let path = defaults.string(forKey: Key.libraryFolder) else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { defaults.set(newValue?.path, forKey: Key.libraryFolder) }
    }

    /// Volume name of the player last chosen, so it is picked again when
    /// several removable drives are connected.
    static var preferredDeviceName: String? {
        get { defaults.string(forKey: Key.preferredDevice) }
        set { defaults.set(newValue, forKey: Key.preferredDevice) }
    }

    static var playlistName: String {
        get { defaults.string(forKey: Key.playlistName) ?? "" }
        set { defaults.set(newValue, forKey: Key.playlistName) }
    }

    static var resizeArtwork: Bool {
        get { bool(Key.resizeArtwork, default: true) }
        set { defaults.set(newValue, forKey: Key.resizeArtwork) }
    }

    static var maxArtDimension: Int {
        get {
            let v = defaults.integer(forKey: Key.maxArtDimension)
            return v > 0 ? v : 500
        }
        set { defaults.set(newValue, forKey: Key.maxArtDimension) }
    }

    static var fetchLyrics: Bool {
        get { bool(Key.fetchLyrics, default: false) }
        set { defaults.set(newValue, forKey: Key.fetchLyrics) }
    }

    static var fetchCovers: Bool {
        get { bool(Key.fetchCovers, default: false) }
        set { defaults.set(newValue, forKey: Key.fetchCovers) }
    }

    /// Albums switched off in "Choose albums", by `SyncSelection.albumKey`.
    static var excludedAlbums: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.excludedAlbums) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.excludedAlbums) }
    }

    /// Scan and compare automatically as soon as the player is plugged in.
    static var autoCompare: Bool {
        get { bool(Key.autoCompare, default: true) }
        set { defaults.set(newValue, forKey: Key.autoCompare) }
    }

    static var removeJunk: Bool {
        get { bool(Key.removeJunk, default: true) }
        set { defaults.set(newValue, forKey: Key.removeJunk) }
    }

    /// Short interface sounds (tab switch, sync start/finish, errors).
    static var soundsEnabled: Bool {
        get { bool(Key.sounds, default: true) }
        set { defaults.set(newValue, forKey: Key.sounds) }
    }

    /// `bool(forKey:)` reports false for a key never written, which would
    /// silently flip every default-on setting off on first launch.
    private static func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }
}
