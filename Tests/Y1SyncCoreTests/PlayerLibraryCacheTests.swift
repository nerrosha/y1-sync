import XCTest
@testable import Y1SyncCore

/// The player lists songs from `.y1_library_cache.json`, not from the card, so
/// files copied after its last scan are invisible until the list is updated.
final class PlayerLibraryCacheTests: XCTestCase {
    private var device: URL!

    override func setUpWithError() throws {
        device = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("y1cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: device) }

    @discardableResult
    private func addFile(_ rel: String) throws -> URL {
        let url = device.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 16).write(to: url)
        return url
    }

    private func entry(_ path: String, title: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["trackNum": 1, "genre": "Rock", "composer": "Unknown Composer", "title": title,
         "albumArtist": "A", "album": "B", "path": "/storage/sdcard0" + path, "year": "2001", "artist": "A"]
            .merging(extra) { $1 }
    }

    private func writeCache(_ entries: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["music": entries, "books": []])
        try data.write(to: PlayerLibraryCache.fileURL(device))
    }

    private func readCache() throws -> [[String: Any]] {
        let top = try JSONSerialization.jsonObject(with: Data(contentsOf: PlayerLibraryCache.fileURL(device))) as! [String: Any]
        return top["music"] as! [[String: Any]]
    }

    private func track(_ url: URL, title: String, n: Int = 1) -> Track {
        Track(sourceURL: url, title: title, artist: "Gone Fludd", albumArtist: "GONE.Fludd",
              album: "VK Acoustic", trackNumber: n, year: 2023, fileSize: 16, genre: "Rock")
    }

    func testStatusFindsTracksThePlayerCannotSeeAndDeadEntries() throws {
        let known = try addFile("Music/A/B/01 Known.flac")
        let fresh = try addFile("Music/GONE.Fludd/VK/01 New.flac")
        try writeCache([entry("/Music/A/B/01 Known.flac", title: "Known"),
                        entry("/Music/A/B/02 Gone.flac", title: "Gone")])

        let s = try XCTUnwrap(PlayerLibraryCache.status(
            deviceRoot: device, deviceTracks: [track(known, title: "Known"), track(fresh, title: "New")]))
        XCTAssertEqual(s.cached, 2)
        XCTAssertEqual(s.missing.map(\.sourceURL.lastPathComponent), ["01 New.flac"])
        XCTAssertEqual(s.stale, ["/Music/A/B/02 Gone.flac"])
        XCTAssertFalse(s.isInSync)
    }

    func testSyncAddsMissingDropsDeadAndKeepsOtherEntriesUntouched() throws {
        let known = try addFile("Music/A/B/01 Known.flac")
        let fresh = try addFile("Music/GONE.Fludd/VK/03 New.flac")
        try writeCache([entry("/Music/A/B/01 Known.flac", title: "Known", extra: ["composer": "Someone", "weird": 7]),
                        entry("/Music/A/B/02 Gone.flac", title: "Gone")])

        let r = try PlayerLibraryCache.sync(deviceRoot: device,
                                            deviceTracks: [track(known, title: "Known"), track(fresh, title: "New", n: 3)])
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.removed, 1)

        let after = try readCache()
        XCTAssertEqual(after.count, 2)
        let kept = try XCTUnwrap(after.first { $0["title"] as? String == "Known" })
        XCTAssertEqual(kept["composer"] as? String, "Someone", "the firmware's own entry is not rewritten")
        XCTAssertEqual(kept["weird"] as? Int, 7)

        let new = try XCTUnwrap(after.first { $0["title"] as? String == "New" })
        XCTAssertEqual(new["path"] as? String, "/storage/sdcard0/Music/GONE.Fludd/VK/03 New.flac")
        XCTAssertEqual(new["trackNum"] as? Int, 3)
        XCTAssertEqual(new["artist"] as? String, "Gone Fludd")
        XCTAssertEqual(new["albumArtist"] as? String, "GONE.Fludd")
        XCTAssertEqual(new["year"] as? String, "2023")
        XCTAssertEqual(new["composer"] as? String, "Unknown Composer")
        XCTAssertEqual(Set(new.keys), Set(kept.keys.filter { $0 != "weird" }), "same fields the firmware writes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: device.appendingPathComponent(".y1_library_cache.json.y1sync-backup").path))
    }

    func testRunningTwiceChangesNothingTheSecondTime() throws {
        let fresh = try addFile("Music/A/B/01 New.flac")
        try writeCache([])
        let tracks = [track(fresh, title: "New")]
        XCTAssertEqual(try PlayerLibraryCache.sync(deviceRoot: device, deviceTracks: tracks).added, 1)
        let r = try PlayerLibraryCache.sync(deviceRoot: device, deviceTracks: tracks)
        XCTAssertEqual(r.added + r.removed, 0)
        XCTAssertEqual(try readCache().count, 1)
        XCTAssertTrue(PlayerLibraryCache.status(deviceRoot: device, deviceTracks: tracks)!.isInSync)
    }

    func testNoListMeansNothingToDo() throws {
        let fresh = try addFile("Music/A/B/01 New.flac")
        XCTAssertNil(PlayerLibraryCache.status(deviceRoot: device, deviceTracks: [track(fresh, title: "N")]))
        XCTAssertEqual(try PlayerLibraryCache.sync(deviceRoot: device, deviceTracks: [track(fresh, title: "N")]).added, 0)
        XCTAssertFalse(PlayerLibraryCache.exists(deviceRoot: device))
    }

    func testMatchingIgnoresCaseAndUnicodeForm() throws {
        let f = try addFile("Music/Кино/Группа/01 Песня.flac")
        let decomposed = "/Music/Кино/Группа/01 Песня.flac".decomposedStringWithCanonicalMapping
        try writeCache([entry(decomposed.uppercased(), title: "Песня")])
        XCTAssertTrue(PlayerLibraryCache.status(deviceRoot: device, deviceTracks: [track(f, title: "Песня")])!.isInSync)
    }

    func testEntriesWithAnUnknownMountPrefixKeepTheirs() throws {
        let f = try addFile("Music/A/B/01 Known.flac")
        let n = try addFile("Music/A/B/02 New.flac")
        try writeCache([["trackNum": 1, "genre": "x", "composer": "x", "title": "Known", "albumArtist": "A",
                         "album": "B", "path": "/mnt/sdcard/Music/A/B/01 Known.flac", "year": "1", "artist": "A"]])
        try PlayerLibraryCache.sync(deviceRoot: device, deviceTracks: [track(f, title: "Known"), track(n, title: "New", n: 2)])
        let added = try XCTUnwrap(readCache().first { $0["title"] as? String == "New" })
        XCTAssertEqual(added["path"] as? String, "/mnt/sdcard/Music/A/B/02 New.flac")
    }
}
