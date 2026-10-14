import XCTest
@testable import Y1SyncCore

/// Serves canned HTTP responses so the decoding and request shape can be
/// tested without depending on a live service.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let (code, body) = Self.handler?(request) ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: code,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
}

final class LyricsFetcherTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
        super.tearDown()
    }

    private func track() -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/lib/a.mp3"),
              title: "Creep", artist: "Radiohead", album: "Pablo Honey",
              durationSeconds: 238.6)
    }

    func testPrefersSyncedLyricsOverPlain() async {
        StubProtocol.handler = { _ in
            (200, Data(#"{"syncedLyrics":"[00:01.00]hi","plainLyrics":"hi","instrumental":false}"#.utf8))
        }
        let got = await LyricsFetcher(session: stubSession()).fetch(for: track())
        XCTAssertEqual(got?.best, "[00:01.00]hi")
    }

    func testFallsBackToPlainLyrics() async {
        StubProtocol.handler = { _ in
            (200, Data(#"{"plainLyrics":"just words","instrumental":false}"#.utf8))
        }
        let got = await LyricsFetcher(session: stubSession()).fetch(for: track())
        XCTAssertEqual(got?.best, "just words")
    }

    func testNotFoundReturnsNilRatherThanThrowing() async {
        StubProtocol.handler = { _ in (404, Data()) }
        let got = await LyricsFetcher(session: stubSession()).fetch(for: track())
        XCTAssertNil(got, "a missing song must not fail the sync")
    }

    func testMalformedJSONIsHandled() async {
        StubProtocol.handler = { _ in (200, Data("not json".utf8)) }
        let got = await LyricsFetcher(session: stubSession()).fetch(for: track())
        XCTAssertNil(got)
    }

    /// Duration disambiguates a radio edit from an album cut; without it the
    /// returned timings can be for a different version of the song.
    func testSendsDurationAndIdentifiesItself() async {
        StubProtocol.handler = { _ in (200, Data(#"{"plainLyrics":"x"}"#.utf8)) }
        _ = await LyricsFetcher(session: stubSession()).fetch(for: track())

        let url = StubProtocol.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("duration=239"), "duration should be sent, rounded")
        XCTAssertTrue(url.contains("artist_name=Radiohead"))
        XCTAssertNotNil(StubProtocol.lastRequest?
            .value(forHTTPHeaderField: "User-Agent"), "services ask callers to identify themselves")
    }

    func testInstrumentalTrackWritesNoFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("y1lrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lyrics = Lyrics(synced: "[00:01.00]la", plain: nil, isInstrumental: true)
        let wrote = LyricsFetcher().writeLRC(lyrics,
                                             besideDevicePath: "/Music/A/B/01 T.mp3",
                                             deviceRoot: dir)
        XCTAssertFalse(wrote)
    }

    func testWritesLRCBesideTheTrack() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("y1lrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lyrics = Lyrics(synced: "[00:01.00]la", plain: nil, isInstrumental: false)
        XCTAssertTrue(LyricsFetcher().writeLRC(lyrics,
                                               besideDevicePath: "/Music/A/B/01 T.mp3",
                                               deviceRoot: dir))

        let lrc = dir.appendingPathComponent("Music/A/B/01 T.lrc")
        XCTAssertEqual(try String(contentsOf: lrc, encoding: .utf8), "[00:01.00]la")
    }

    func testDoesNotOverwriteExistingLyrics() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("y1lrc-\(UUID().uuidString)")
        let target = dir.appendingPathComponent("Music/A/B")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lrc = target.appendingPathComponent("01 T.lrc")
        try Data("mine".utf8).write(to: lrc)

        let lyrics = Lyrics(synced: "[00:01.00]new", plain: nil, isInstrumental: false)
        XCTAssertFalse(LyricsFetcher().writeLRC(lyrics,
                                                besideDevicePath: "/Music/A/B/01 T.mp3",
                                                deviceRoot: dir))
        XCTAssertEqual(try String(contentsOf: lrc, encoding: .utf8), "mine")
    }
}

final class CoverFetcherTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
        super.tearDown()
    }

    func testStripsQuotesThatWouldBreakTheQuery() {
        // An unescaped quote turns the Lucene query into a syntax error.
        let f = CoverFetcher()
        XCTAssertFalse(f.escaped("The \"Best\" Of").contains("\""))
        XCTAssertFalse(f.escaped("back\\slash").contains("\\"))
    }

    func testParsesReleaseGroupsAndFallsBackToReleases() async {
        StubProtocol.handler = { _ in
            (200, Data(#"{"release-groups":[{"id":"rg-1"}]}"#.utf8))
        }
        let ids = await CoverFetcher(session: stubSession())
            .search(entity: "release-group", query: "x", limit: 3)
        XCTAssertEqual(ids, ["rg-1"])

        StubProtocol.handler = { _ in (200, Data(#"{"releases":[{"id":"r-9"}]}"#.utf8)) }
        let releases = await CoverFetcher(session: stubSession())
            .search(entity: "release", query: "x", limit: 3)
        XCTAssertEqual(releases, ["r-9"])
    }

    func testEmptyBodyIsNotTreatedAsArtwork() async {
        StubProtocol.handler = { _ in (200, Data()) }
        let art = await CoverFetcher(session: stubSession()).downloadFront(id: "x")
        XCTAssertNil(art)
    }

    func testMissingArtReturnsNil() async {
        StubProtocol.handler = { _ in (404, Data()) }
        let art = await CoverFetcher(session: stubSession()).downloadFront(id: "x")
        XCTAssertNil(art)
    }

    func testRequestsTheConfiguredSize() async {
        StubProtocol.handler = { _ in (200, Data([0xFF, 0xD8])) }
        _ = await CoverFetcher(session: stubSession(), size: 250).downloadFront(id: "abc")
        XCTAssertTrue(StubProtocol.lastRequest?.url?.absoluteString.hasSuffix("front-250") ?? false)
    }
}

final class LyricsMatchingTests: XCTestCase {
    private func result(synced: Bool, duration: Double) -> LyricsFetcher.LRCLibResponse {
        LyricsFetcher.LRCLibResponse(
            trackName: "T", artistName: "A", duration: duration,
            instrumental: false,
            plainLyrics: "words",
            syncedLyrics: synced ? "[00:01.00]words" : nil)
    }

    private func track(duration: Double?) -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/a.mp3"),
              title: "T", artist: "A", album: "B", durationSeconds: duration)
    }

    /// Synced lyrics are the reason to use LRCLIB at all, so they win even
    /// when a plain-text entry matches the duration better.
    func testPrefersSyncedOverCloserDuration() {
        let picked = LyricsFetcher().pickBest(
            [result(synced: false, duration: 200), result(synced: true, duration: 400)],
            for: track(duration: 200))
        XCTAssertNotNil(picked.syncedLyrics)
    }

    func testAmongSyncedPicksClosestDuration() {
        let picked = LyricsFetcher().pickBest(
            [result(synced: true, duration: 100), result(synced: true, duration: 205)],
            for: track(duration: 200))
        XCTAssertEqual(picked.duration, 205)
    }

    func testHandlesUnknownLocalDuration() {
        let picked = LyricsFetcher().pickBest(
            [result(synced: false, duration: 100), result(synced: true, duration: 300)],
            for: track(duration: nil))
        XCTAssertNotNil(picked.syncedLyrics, "should still prefer synced")
    }
}

final class TrackHealthDurationTests: XCTestCase {
    /// Random bytes frequently decode as a fraction of a second of noise,
    /// passing every structural check; length is what gives them away.
    func testSuspiciouslyShortIsBlocking() {
        XCTAssertTrue(TrackIssue.suspiciouslyShort(0.7).isBlocking)
        XCTAssertTrue(TrackIssue.suspiciouslyShort(0.7).describe.contains("0.7s"))
    }
}
