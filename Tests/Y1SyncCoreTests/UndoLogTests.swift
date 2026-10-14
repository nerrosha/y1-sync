import XCTest
@testable import Y1SyncCore

final class UndoLogTests: XCTestCase {
    private var device: URL!

    override func setUpWithError() throws {
        device = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: device)
    }

    private func write(_ relative: String, contents: String = "x") throws -> URL {
        let url = device.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testNoSessionMeansNothingToUndo() {
        XCTAssertNil(UndoLog.mostRecent(deviceRoot: device))
        XCTAssertNil(UndoLog.undoMostRecent(deviceRoot: device))
    }

    func testQuarantineThenUndoRestoresTheOriginalFile() throws {
        let url = try write("Music/Old/file.txt", contents: "hello")

        let undo = UndoRecorder(deviceRoot: device)
        XCTAssertTrue(undo.quarantine(url, path: "/Music/Old/file.txt"))
        undo.finish(label: "test")

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "moved into quarantine")
        XCTAssertNotNil(UndoLog.mostRecent(deviceRoot: device))

        let outcome = try XCTUnwrap(UndoLog.undoMostRecent(deviceRoot: device))
        XCTAssertEqual(outcome.restored, 1)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello")
        XCTAssertNil(UndoLog.mostRecent(deviceRoot: device), "the session is consumed once undone")
    }

    func testMovedEntryReversesTheRename() throws {
        let url = try write("Music/Odd/name.mp3")

        let undo = UndoRecorder(deviceRoot: device)
        let dest = device.appendingPathComponent("Music/A/B/01 Song.mp3")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: dest)
        undo.recordMove(from: "/Music/Odd/name.mp3", to: "/Music/A/B/01 Song.mp3")
        undo.finish(label: "test")

        let outcome = try XCTUnwrap(UndoLog.undoMostRecent(deviceRoot: device))
        XCTAssertEqual(outcome.restored, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testStartingANewSessionForgetsThePreviousOne() throws {
        let first = try write("first.txt")
        let a = UndoRecorder(deviceRoot: device)
        a.quarantine(first, path: "/first.txt")
        a.finish(label: "first")
        let firstSessionID = try XCTUnwrap(UndoLog.mostRecent(deviceRoot: device)).id

        let second = try write("second.txt")
        let b = UndoRecorder(deviceRoot: device)
        b.quarantine(second, path: "/second.txt")
        b.finish(label: "second")

        let current = try XCTUnwrap(UndoLog.mostRecent(deviceRoot: device))
        XCTAssertNotEqual(current.id, firstSessionID)

        // Only the most recent session can be restored — the first one's
        // quarantined file is gone for good, freeing the space it held.
        let outcome = try XCTUnwrap(UndoLog.undoMostRecent(deviceRoot: device))
        XCTAssertEqual(outcome.restored, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testForgetDiscardsWithoutRestoring() throws {
        let url = try write("file.txt")
        let undo = UndoRecorder(deviceRoot: device)
        undo.quarantine(url, path: "/file.txt")
        undo.finish(label: "test")

        XCTAssertTrue(UndoLog.forgetMostRecent(deviceRoot: device))
        XCTAssertNil(UndoLog.mostRecent(deviceRoot: device))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "not restored")
    }

    func testUndoSkipsAnEntryWhoseDestinationIsNowOccupied() throws {
        let url = try write("Old/file.txt", contents: "quarantined copy")
        let undo = UndoRecorder(deviceRoot: device)
        undo.quarantine(url, path: "/Old/file.txt")
        undo.finish(label: "test")

        // Something else now occupies the spot this would restore to.
        _ = try write("Old/file.txt", contents: "a different file now lives here")

        let outcome = try XCTUnwrap(UndoLog.undoMostRecent(deviceRoot: device))
        XCTAssertEqual(outcome.restored, 0)
        XCTAssertEqual(outcome.failed, ["/Old/file.txt"])
        XCTAssertEqual(try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("file.txt"),
                                   encoding: .utf8), "a different file now lives here",
                       "must not clobber what's there now")
    }

    // MARK: - Integration with DeviceTidy

    func testUndoingATidyRunRestoresTheLeftoverFolder() throws {
        let trackURL = device.appendingPathComponent("Music/Old Artist Folder/01 Song.mp3")
        try FileManager.default.createDirectory(at: trackURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 32).write(to: trackURL)
        try "log".write(to: device.appendingPathComponent("Music/Old Artist Folder/rip.log"),
                        atomically: true, encoding: .utf8)

        let t = Track(sourceURL: trackURL, title: "Song", artist: "A", album: "B",
                      trackNumber: 1, fileSize: 32)
        let tidy = DeviceTidy()
        let result = tidy.apply(tidy.plan(deviceRoot: device, tracks: [t]), deviceRoot: device)
        XCTAssertEqual(result.leftoverFoldersRemoved, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Music/Old Artist Folder").path))

        let outcome = try XCTUnwrap(UndoLog.undoMostRecent(deviceRoot: device))
        XCTAssertGreaterThanOrEqual(outcome.restored, 2, "the move and the leftover-folder removal both reverse")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: device.appendingPathComponent("Music/Old Artist Folder/rip.log").path),
            "the leftover folder (and its rip log) should be back")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: trackURL.path), "the track should be back at its original spot")
    }
}
