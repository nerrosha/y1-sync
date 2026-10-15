import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Y1SyncCore

final class EnricherTests: XCTestCase {
    private var device: URL!

    override func setUpWithError() throws {
        device = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("enrich-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: device)
    }

    // MARK: - Fixtures

    private func le(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
              UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    private func blockHeader(type: UInt8, length: Int, last: Bool) -> Data {
        Data([(last ? 0x80 : 0x00) | type,
              UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
    }

    /// A minimal but structurally valid FLAC with no embedded picture.
    private func makeFLAC(fields: [String: String], audio: Data = Data(repeating: 0x5A, count: 4096)) -> Data {
        var out = Data("fLaC".utf8)
        var blocks: [(UInt8, Data)] = [(0, Data(repeating: 0, count: 34))]

        var comment = Data()
        let vendor = Data("test".utf8)
        comment.append(le(vendor.count)); comment.append(vendor)
        let entries = fields.sorted { $0.key < $1.key }.map { Data("\($0.key)=\($0.value)".utf8) }
        comment.append(le(entries.count))
        for e in entries { comment.append(le(e.count)); comment.append(e) }
        blocks.append((4, comment))

        for (i, block) in blocks.enumerated() {
            out.append(blockHeader(type: block.0, length: block.1.count, last: i == blocks.count - 1))
            out.append(block.1)
        }
        out.append(audio)
        return out
    }

    private func jpeg(size: Int = 40) throws -> Data {
        try TestImages.make(side: size, format: .jpeg, blocks: 0)
    }

    // MARK: - Local cover preferred over network

    func testUsesCoverAlreadyInTheAlbumFolderInsteadOfFetching() async throws {
        let albumDir = device.appendingPathComponent("Music/Real Artist/Real Album")
        try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)

        let trackURL = albumDir.appendingPathComponent("01 Song.flac")
        try makeFLAC(fields: ["TITLE": "Song", "ARTIST": "Real Artist", "ALBUM": "Real Album"])
            .write(to: trackURL)
        try jpeg().write(to: albumDir.appendingPathComponent("cover.jpg"))

        let track = Track(sourceURL: trackURL, title: "Song", artist: "Real Artist",
                          album: "Real Album", fileSize: 4096)
        let key = FATName.foldedKey("\(track.effectiveAlbumArtist)/\(track.effectiveAlbum)")

        // A fetcher that would fail the test if it were ever actually called —
        // the local file must short-circuit before this is reached.
        let poisoned = CoverFetcher(session: Self.neverCalledSession)
        let enricher = Enricher(covers: poisoned, inPlace: true)

        let result = await enricher.addCovers(for: [track], albumsMissingArt: [key], deviceRoot: device)

        XCTAssertEqual(result.coversEmbedded, 1)
        XCTAssertEqual(result.coversFromLocalFile, 1)
        XCTAssertTrue(result.coversNotFound.isEmpty)
        XCTAssertNotNil(EmbeddedArtwork.read(from: trackURL), "the local cover should now be embedded")
    }

    private static var neverCalledSession: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NeverCalledProtocol.self]
        return URLSession(configuration: config)
    }

    private final class NeverCalledProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            XCTFail("network should not be reached when a local cover file exists")
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }
}
