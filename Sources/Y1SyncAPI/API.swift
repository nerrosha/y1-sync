import Foundation
import Y1SyncCore

/// The engine as JSON commands. One request in, progress lines while it works,
/// one result line out. The Windows window drives everything through this;
/// the Mac app uses the same engine directly.
///
/// Every command is stateless: it reads the saved settings and the files on
/// disk, so the window can be closed and reopened at any point. Scans are
/// cached by size and modification time, which keeps repeating them cheap.
public final class API: @unchecked Sendable {
    let emitter: Emitter
    let settings: SettingsStore
    public let stop = StopSwitch()

    public init(emitter: Emitter, dataDirectory: URL? = nil) {
        self.emitter = emitter
        self.settings = SettingsStore(directory: dataDirectory)
    }

    /// Run one request (`{"cmd": "...", ...}`) and build the final line to send.
    public func handle(_ request: JSON) async -> JSON {
        guard let cmd = request.string("cmd") else { return fail("missing \"cmd\"") }
        do {
            stop.reset()
            let data = try await run(cmd, request)
            return ["event": "result", "ok": true, "data": data]
        } catch let e as APIError {
            return fail(e.message)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    func fail(_ message: String) -> JSON { ["event": "result", "ok": false, "error": message] }

    func run(_ cmd: String, _ a: JSON) async throws -> JSON {
        switch cmd {
        case "ping": return ["pong": true, "ffmpeg": Capabilities.canReadMedia, "version": API.version]
        case "settings.get": return settings.asJSON()
        case "settings.set":
            try settings.apply(patch: a["patch"] as? JSON ?? [:])
            return settings.asJSON()
        case "devices": return devicesJSON()
        case "firmware.set": return try setFirmware(a)

        case "plan": return try await plan(a)
        case "sync": return try await sync(a)

        case "device.scan": return try await deviceScan(a)
        case "tidy.apply": return try await tidyApply(a)
        case "songlist.update": return try await songListUpdate(a)
        case "merge.albums": return try await mergeAlbums(a)
        case "merge.artists": return try await mergeArtists(a)
        case "rules.suggest": return try await rulesSuggest(a)
        case "rules.add": return try rulesAdd(a)
        case "rules.remove": return try rulesRemove(a)
        case "health.check": return try await healthCheck(a)
        case "health.fix": return try await healthFix(a)
        case "dupes.clean": return try await dupesClean(a)
        case "undo": return try await undo(a)
        case "undo.forget": return try undoForget(a)
        case "free.remove": return try await freeRemove(a)
        case "enrich": return try await enrich(a)
        case "playlists": return try await playlists(a)
        default: throw APIError("unknown command \"\(cmd)\"")
        }
    }

    public static let version = "1.0.0"

    // MARK: - Player

    struct Player {
        var root: URL
        var name: String
        var detected: Firmware
        var firmware: Firmware
        var overridden: Bool
    }

    func player(_ a: JSON) throws -> Player {
        guard let path = a.string("device") ?? settings.load().devicePath, !path.isEmpty else {
            throw APIError("No player selected. Connect the player and pick it in the Sync tab.")
        }
        let root = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw APIError("\(path) is not available. Is the player plugged in with USB storage on?")
        }
        let name = DeviceFinder().candidates().first { $0.url.standardizedFileURL.path == root.standardizedFileURL.path }?.name
            ?? root.lastPathComponent
        let detected = Firmware.detect(deviceRoot: root)
        let chosen = settings.load().firmwareByPlayer[name].flatMap(Firmware.init(rawValue:))
        return Player(root: root, name: name, detected: detected, firmware: chosen ?? detected, overridden: chosen != nil)
    }

    func maxArt(for p: Player) -> Int { settings.load().maxArtDimension ?? p.firmware.maxArtPixels }

    func devicesJSON() -> JSON {
        var entries = DeviceFinder().candidates().map { d in
            (name: d.name, url: d.url, total: d.totalBytes, free: d.freeBytes)
        }
        // A folder the person picked by hand (a player the system does not call
        // removable, or a plain folder) still counts as their player.
        if let saved = settings.load().devicePath, !saved.isEmpty,
           !entries.contains(where: { $0.url.standardizedFileURL.path == URL(fileURLWithPath: saved).standardizedFileURL.path }),
           FileManager.default.fileExists(atPath: saved) {
            let url = URL(fileURLWithPath: saved)
            let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
                .volumeAvailableCapacity.map(Int64.init) ?? 0
            entries.append((name: url.lastPathComponent, url: url, total: 0, free: free))
        }
        let list = entries.map { d -> JSON in
            let detected = Firmware.detect(deviceRoot: d.url)
            let chosen = settings.load().firmwareByPlayer[d.name].flatMap(Firmware.init(rawValue:))
            return ["name": d.name, "path": d.url.path, "totalBytes": d.total, "freeBytes": d.free,
                    "detectedFirmware": detected.rawValue, "firmware": (chosen ?? detected).rawValue,
                    "firmwareChosen": chosen != nil]
        }
        let firmwares = Firmware.allCases.map { f -> JSON in
            ["id": f.rawValue, "title": f.title, "summary": f.summary]
        }
        return ["devices": list, "firmwares": firmwares]
    }

    func setFirmware(_ a: JSON) throws -> JSON {
        guard let name = a.string("name") else { throw APIError("missing name") }
        settings.update { s in
            if let id = a.string("firmware"), Firmware(rawValue: id) != nil { s.firmwareByPlayer[name] = id }
            else { s.firmwareByPlayer[name] = nil }
        }
        return devicesJSON()
    }

    // MARK: - JSON for engine types

    func trackJSON(_ t: Track, devicePath: String? = nil) -> JSON {
        var j: JSON = ["title": t.effectiveTitle, "artist": t.effectiveArtist, "album": t.effectiveAlbum,
                       "albumArtist": t.effectiveAlbumArtist, "size": t.fileSize,
                       "format": PlayerLimits.label(for: t), "path": t.sourceURL.path]
        if let n = t.trackNumber { j["track"] = n }
        if let d = devicePath { j["devicePath"] = d }
        return j
    }
}

extension API {
    /// `y1sync api`: read one request line from stdin, answer on stdout.
    /// A later line saying `stop` asks a running copy to finish its current file and stop.
    public static func serveStdio() async {
        let emitter = Emitter.stdout()
        guard let line = readLine(strippingNewline: true),
              let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? JSON else {
            emitter.send(["event": "result", "ok": false, "error": "expected one JSON request on stdin"])
            return
        }
        let api = API(emitter: emitter)
        Thread.detachNewThread {
            while let next = readLine(strippingNewline: true) {
                if next.trimmingCharacters(in: .whitespaces) == "stop" { api.stop.set() }
            }
        }
        emitter.send(await api.handle(request))
    }
}
