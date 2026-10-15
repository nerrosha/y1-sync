import Foundation
import Y1SyncCore

/// Everything the app remembers between runs, in one JSON file.
struct Settings: Codable, Equatable {
    var libraryFolder: String?
    var devicePath: String?
    var resizeArtwork = true
    /// Nil follows the firmware (1000 px for InniClassic, 500 otherwise).
    var maxArtDimension: Int?
    var fetchLyrics = false
    var fetchCovers = false
    var playlistName = ""
    var excludedAlbums: [String] = []
    var mergeRules: [MergeRule] = []
    var limits = PlayerLimits.none
    /// Firmware the user picked by hand, by player name.
    var firmwareByPlayer: [String: String] = [:]
    var removeJunk = true
}

final class SettingsStore: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var cached: Settings?

    init(directory: URL? = nil) {
        let dir = directory ?? SettingsStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("settings.json")
    }

    static func defaultDirectory() -> URL {
        if let custom = ProcessInfo.processInfo.environment["Y1SYNC_DATA"] { return URL(fileURLWithPath: custom) }
        #if os(Windows)
        if let appData = ProcessInfo.processInfo.environment["APPDATA"] {
            return URL(fileURLWithPath: appData).appendingPathComponent("Y1Sync")
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Y1Sync")
    }

    func load() -> Settings {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        var s = Settings()
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            s = decoded
        }
        cached = s
        return s
    }

    func save(_ s: Settings) {
        lock.lock(); defer { lock.unlock() }
        cached = s
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    func update(_ change: (inout Settings) -> Void) {
        var s = load()
        change(&s)
        save(s)
    }

    func asJSON() -> JSON {
        guard let data = try? JSONEncoder().encode(load()),
              let obj = try? JSONSerialization.jsonObject(with: data) as? JSON else { return [:] }
        return obj
    }

    /// Merge `patch` (same keys as the stored JSON) into the settings.
    func apply(patch: JSON) throws {
        var merged = asJSON()
        for (k, v) in patch { merged[k] = v }
        let data = try JSONSerialization.data(withJSONObject: merged)
        save(try JSONDecoder().decode(Settings.self, from: data))
    }
}
