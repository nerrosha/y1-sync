import Foundation
import Y1SyncCore

/// Fixtures for SwiftUI previews only — never used at runtime.
///
/// Building these from real `Y1SyncCore` types (not hand-rolled preview-only
/// structs) means the canvas shows exactly what the real views render for
/// real data, and it stays honest if a type's shape changes.
enum PreviewData {
    static func track(
        _ title: String, artist: String = "Radiohead",
        album: String = "OK Computer", n: Int? = nil, ext: String = "flac"
    ) -> Track {
        Track(sourceURL: URL(fileURLWithPath: "/lib/\(title).\(ext)"),
              title: title, artist: artist, albumArtist: artist, album: album,
              trackNumber: n, durationSeconds: 214, fileSize: 32_000_000)
    }

    static var deviceRoot: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("preview-device")
    }

    static var device: Device {
        Device(name: "MP3PLAYER", url: deviceRoot,
              totalBytes: 116_000_000_000, freeBytes: 92_000_000_000, hasRockbox: false)
    }

    // MARK: - Results tab

    static var changes: [FileChange] {
        var withArt = FileChange(devicePath: "/Music/Radiohead/OK Computer/01 Airbag.flac",
                                 track: track("Airbag", n: 1))
        withArt.artFrom = "1600x1600"
        withArt.artTo = "500x500"
        withArt.artBytesSaved = 4_800_000
        withArt.lyricsAdded = true

        var renamed = FileChange(devicePath: "/Music/Radiohead/OK Computer/02 Paranoid Android.flac",
                                 track: track("Paranoid Android", n: 2))
        renamed.albumArtistCorrected = "Radiohead"
        renamed.lyricsAdded = true

        let plain = FileChange(devicePath: "/Music/Radiohead/OK Computer/03 Subterranean Homesick Alien.flac",
                               track: track("Subterranean Homesick Alien", n: 3))

        var replaced = FileChange(devicePath: "/Music/Radiohead/OK Computer/06 Karma Police.flac",
                                  track: track("Karma Police", n: 6))
        replaced.wasReplaced = true
        replaced.coverFetched = true

        return [withArt, renamed, plain, replaced]
    }

    static var skippedReports: [TrackReport] {
        [TrackReport(track: track("corrupt", n: 9, ext: "mp3"),
                     issues: [.suspiciouslyShort(0.7)]),
         TrackReport(track: track("empty", n: 10, ext: "mp3"),
                     issues: [.emptyFile])]
    }

    // MARK: - Device tab

    static var tidyPlan: TidyPlan {
        TidyPlan(
            moves: [
                TidyAction(path: "/Music/Weird Folder (2012)/random name.flac",
                          kind: .move(to: "/Music/Mac DeMarco/2/02 Dreaming.flac"),
                          bytes: 30_000_000),
                TidyAction(path: "/Music/1989-Звезда по имени солнце (1993)/01 Песня без слов.flac",
                          kind: .move(to: "/Music/Кино/Звезда по имени Солнце/01 Песня без слов.flac"),
                          bytes: 28_000_000),
            ],
            junk: (1...5).map {
                TidyAction(path: "/Music/Album \($0)/._track.flac", kind: .junk, bytes: 4096)
            },
            emptyDirectories: [
                TidyAction(path: "/Music/Old Folder", kind: .emptyDirectory, bytes: 0),
            ]
        )
    }

    // MARK: - Duplicates tab

    static var duplicateGroups: [DuplicateGroup] {
        [
            DuplicateGroup(key: "radiohead|pressure", tracks: [
                track("Pressure", album: "All We Know Is Falling", ext: "flac"),
                track("Pressure", album: "Singles Collection", ext: "mp3"),
            ]),
            DuplicateGroup(key: "the strokes|someday", tracks: [
                track("Someday", artist: "The Strokes", album: "Is This It", ext: "flac"),
                track("Someday", artist: "The Strokes", album: "The Singles", ext: "flac"),
                track("Someday", artist: "The Strokes", album: "Greatest Hits", ext: "mp3"),
            ]),
        ]
    }
}
