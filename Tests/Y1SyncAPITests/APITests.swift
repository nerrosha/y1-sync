import XCTest
import Foundation
@testable import Y1SyncAPI
import Y1SyncCore

final class APITests: XCTestCase {
    private var dir: URL!
    private var lines: [JSON] = []
    private var api: API!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("y1api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        api = API(emitter: Emitter { [unowned self] data in
            if let obj = try? JSONSerialization.jsonObject(with: data) as? JSON { self.lines.append(obj) }
        }, dataDirectory: dir.appendingPathComponent("data"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testPingAnswers() async {
        let r = await api.handle(["cmd": "ping"])
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual((r["data"] as? JSON)?["pong"] as? Bool, true)
    }

    func testUnknownCommandIsAnError() async {
        let r = await api.handle(["cmd": "nope"])
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertTrue((r["error"] as? String ?? "").contains("nope"))
    }

    func testSettingsRoundTripAndPatch() async throws {
        _ = await api.handle(["cmd": "settings.set", "patch": ["playlistName": "Daily", "excludedAlbums": ["a/b"]]])
        let r = await api.handle(["cmd": "settings.get"])
        let data = try XCTUnwrap(r["data"] as? JSON)
        XCTAssertEqual(data["playlistName"] as? String, "Daily")
        XCTAssertEqual(data["excludedAlbums"] as? [String], ["a/b"])
        XCTAssertEqual(data["resizeArtwork"] as? Bool, true)       // untouched default

        // A second instance reads the same file.
        let again = API(emitter: Emitter { _ in }, dataDirectory: dir.appendingPathComponent("data"))
        let r2 = await again.handle(["cmd": "settings.get"])
        XCTAssertEqual((r2["data"] as? JSON)?["playlistName"] as? String, "Daily")
    }

    func testPlanNeedsAMusicFolder() async {
        let r = await api.handle(["cmd": "plan", "device": dir.path])
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertTrue((r["error"] as? String ?? "").lowercased().contains("music folder"))
    }

    func testPlayerMustExist() async {
        _ = await api.handle(["cmd": "settings.set", "patch": ["libraryFolder": dir.path]])
        let r = await api.handle(["cmd": "plan", "device": dir.appendingPathComponent("missing").path])
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertTrue((r["error"] as? String ?? "").contains("not available"))
    }

    func testEmptyPlayerScansAsEmpty() async throws {
        let player = dir.appendingPathComponent("player")
        try FileManager.default.createDirectory(at: player, withIntermediateDirectories: true)
        let r = await api.handle(["cmd": "device.scan", "device": player.path])
        let data = try XCTUnwrap(r["data"] as? JSON)
        XCTAssertEqual(data["empty"] as? Bool, true)
        XCTAssertEqual(data["trackCount"] as? Int, 0)
    }

    func testFirmwareChoiceIsRemembered() async throws {
        let player = dir.appendingPathComponent("player")
        try FileManager.default.createDirectory(at: player, withIntermediateDirectories: true)
        _ = await api.handle(["cmd": "firmware.set", "name": "player", "firmware": "rockbox"])
        let r = await api.handle(["cmd": "device.scan", "device": player.path])
        let p = try XCTUnwrap((r["data"] as? JSON)?["player"] as? JSON)
        XCTAssertEqual(p["firmware"] as? String, "rockbox")
        XCTAssertEqual(p["chosen"] as? Bool, true)
    }

    func testRulesCanBeAddedAndRemoved() async throws {
        _ = await api.handle(["cmd": "rules.add", "rules": [["kind": "album", "from": "Malcom Todd", "to": "Malcolm Todd", "artists": ["malcolm todd"]]]])
        let first = await api.handle(["cmd": "settings.get"])
        var rules = try XCTUnwrap((first["data"] as? JSON)?["mergeRules"] as? [JSON])
        XCTAssertEqual(rules.count, 1)
        let id = try XCTUnwrap(rules[0]["from"] as? String)
        XCTAssertEqual(id, "Malcom Todd")
        let ruleID = MergeRule(kind: .album, from: "Malcom Todd", to: "x", artists: ["malcolm todd"]).id
        _ = await api.handle(["cmd": "rules.remove", "id": ruleID])
        let second = await api.handle(["cmd": "settings.get"])
        rules = try XCTUnwrap((second["data"] as? JSON)?["mergeRules"] as? [JSON])
        XCTAssertTrue(rules.isEmpty)
    }
}
