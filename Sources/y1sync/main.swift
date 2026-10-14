import Foundation
import Y1SyncCore

// A deliberately dependency-free CLI: it is the verifiable core of the app,
// and the SwiftUI front-end calls the same Y1SyncCore APIs.

func printUsage() {
    print("""
    y1sync — sync a music library to an Innioasis Y1

    USAGE:
      y1sync devices
      y1sync scan  <library-folder>
      y1sync check <library-folder>
      y1sync dupes <library-folder> [--apply]
      y1sync tidy   [--device <name>] [--to <path>] [--apply]
      y1sync enrich [--device <name>] [--to <path>] [--lyrics] [--fetch-covers]
      y1sync plan  <library-folder> [--device <name>] [--to <path>]
      y1sync sync  <library-folder> [--device <name>] [--to <path>] [--playlist <name>]
      y1sync undo  [--device <name>] [--to <path>] [--apply | --forget]
      y1sync artists [--device <name>] [--to <path>]
      y1sync albums [--device <name>] [--to <path>]
      y1sync library [--device <name>] [--to <path>] [--apply]
      y1sync formats [--device <name>] [--to <path>]
      y1sync health [--device <name>] [--to <path>] [--library <folder>] [--repair] [--remove]
      y1sync playlists [--device <name>] [--to <path>] [--mood] [--tempo] [--genre]

    COMMANDS:
      devices   List removable volumes that could be the player.
      scan      Read tags from a library folder and show what was found.
      check     Find broken files, oversized cover art and tagging problems.
      dupes     Find the same song stored more than once. Shows a plan unless
                --apply is given, same as tidy.
      tidy      Rename files already on the player into one consistent layout,
                remove macOS junk, and clear pre-tidy folders left holding
                only a stray cover/log once their tracks have moved out
                (salvaging the cover first). Shows a plan unless --apply is given.
      enrich    Add lyrics and missing covers to what is already on the player.
      plan      Show what a sync would copy, without writing anything.
      sync      Copy missing tracks to the player.
      artists   List artists filed under more than one spelling ("The X" and "X",
                different capitals). Changes nothing.
      albums    List albums that are really one album split by their tags (a typo,
                an edition, a single downloaded alone). Changes nothing.
      library   Compare the player's own song list (.y1_library_cache.json) with the
                card. The player shows songs from that list, so tracks copied after
                its last scan are invisible on it. --apply adds the missing tracks
                and drops entries for files that are gone (a backup is kept).
      formats   List the audio formats on the player (codec, bit depth, sample rate).
      health    Check every file already on the player: decodes the start and the
                end of each one, so cut-off copies show up too. Lists broken
                files with an intact copy from --library when there is one.
                --repair replaces them from the library; --remove also removes
                the ones with no replacement. Everything goes through the
                undo quarantine, nothing is deleted outright.
      undo      Reverse the most recent tidy or dupes --apply. Nothing tidy or
                dupes removes is ever really deleted right away — it moves
                into a hidden quarantine folder on the device, and undo moves
                it straight back. Only the single most recent run is kept:
                starting a new tidy or dupes --apply permanently discards
                whatever the previous one had quarantined. With no flag,
                shows what would be restored; --apply restores it; --forget
                discards it for good without restoring, to free the space
                sooner.
      playlists Build playlists from mood/tempo/genre tags already on the
                files (written by tools like beets or Picard's AcousticBrainz
                plugin — most libraries won't have them, and tracks without
                the tag are just skipped). With none of --mood/--tempo/--genre
                given, builds all three. No network involved.

    OPTIONS:
      --device <name>    Volume name, when more than one is connected.
      --to <path>        Target a folder directly instead of a mounted volume.
      --playlist <name>  Also write /Playlists/<name>.m3u8 covering the library.
      --max-art <px>     Longest edge for embedded cover art (default 500).
      --keep-art         Do not resize oversized embedded cover art.
      --copy-broken      Copy files that fail the health check anyway.
      --split-albums     Do not unify album artists that disagree.
      --apply            Actually perform a tidy (otherwise it only reports).
      --covers           Also write cover.bmp per album (Rockbox only; stock
                         Innioasis firmware reads art from the file's tags).
      --lyrics           Fetch synced lyrics from LRCLIB and write .lrc files.
      --fetch-covers     Find missing album art on the Cover Art Archive and
                         embed it. Only albums with no art are looked up.

    --lyrics and --fetch-covers send artist, album and track names to LRCLIB and
    MusicBrainz to look them up. Both are free and need no account.

    Stock Innioasis firmware reads album art from each file's own metadata and
    struggles above roughly 500x500, so oversized art is resized by default.
    The player does not mount until you enable USB storage on the device.
    """)
}

struct Args {
    var command: String?
    var positional: [String] = []
    var device: String?
    var to: String?
    var playlist: String?
    var maxArt = 500
    var keepArt = false
    var copyBroken = false
    var splitAlbums = false
    var covers = false
    var fetchLyrics = false
    var fetchCovers = false
    var apply = false
    var forget = false
    var library: String?
    var repair = false
    var removeBroken = false
    var wantMood = false
    var wantTempo = false
    var wantGenre = false

    init(_ argv: [String]) {
        var rest = Array(argv.dropFirst())
        command = rest.first
        if !rest.isEmpty { rest.removeFirst() }

        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--device": device = rest[safe: i + 1]; i += 2
            case "--to": to = rest[safe: i + 1]; i += 2
            case "--playlist": playlist = rest[safe: i + 1]; i += 2
            case "--max-art": maxArt = Int(rest[safe: i + 1] ?? "") ?? 500; i += 2
            case "--keep-art": keepArt = true; i += 1
            case "--copy-broken": copyBroken = true; i += 1
            case "--split-albums": splitAlbums = true; i += 1
            case "--covers": covers = true; i += 1
            case "--lyrics": fetchLyrics = true; i += 1
            case "--fetch-covers": fetchCovers = true; i += 1
            case "--apply": apply = true; i += 1
            case "--forget": forget = true; i += 1
            case "--library": library = rest[safe: i + 1]; i += 2
            case "--repair": repair = true; i += 1
            case "--remove": removeBroken = true; i += 1
            case "--mood": wantMood = true; i += 1
            case "--tempo": wantTempo = true; i += 1
            case "--genre": wantGenre = true; i += 1
            default: positional.append(rest[i]); i += 1
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func resolveTarget(_ args: Args) -> URL {
    if let to = args.to {
        let url = URL(fileURLWithPath: (to as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
        else { fail("\(url.path) is not a folder") }
        return url
    }
    do {
        let device = try DeviceFinder().resolve(preferredName: args.device)
        print("Device: \(device.name) — \(ByteFormat.string(device.freeBytes)) free"
              + (device.hasRockbox ? " (Rockbox installed)" : ""))
        return device.url
    } catch let e as DeviceError {
        fail(e.description)
    } catch {
        fail(error.localizedDescription)
    }
}

func libraryFolder(_ args: Args) -> URL {
    guard let path = args.positional.first else { fail("no library folder given") }
    return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
}

/// Scan, health-check and tidy the library. Shared by check / plan / sync so
/// they always agree about what is broken.
func prepareLibrary(_ args: Args, root: URL) async
    -> (good: [Track], reports: [TrackReport], albums: [AlbumReport]) {

    let tracks = await LibraryScanner().scan(root: root)
    guard !tracks.isEmpty else { fail("no supported audio files under \(root.path)") }

    let health = TrackHealth(maxEmbeddedArtPixels: args.maxArt)
    let reports = await health.checkAll(tracks)
    let good = args.copyBroken ? tracks : reports.filter(\.isPlayable).map(\.track)

    // An album counts as having artwork if any of its tracks carries embedded
    // art — that is where stock Innioasis firmware reads it from.
    var withArt: Set<String> = []
    for r in reports where r.hasEmbeddedArt {
        withArt.insert(FATName.foldedKey(
            "\(r.track.effectiveAlbumArtist)/\(r.track.effectiveAlbum)"))
    }

    let audit = LibraryAudit()
    let albums = audit.audit(good, artworkPresent: withArt)
    let tidied = args.splitAlbums ? good : audit.unifyAlbumArtists(good, using: albums)

    return (tidied, reports, albums)
}

func printIssues(_ reports: [TrackReport], _ albums: [AlbumReport]) {
    let broken = reports.filter { !$0.isPlayable }
    let warned = reports.filter { $0.isPlayable && !$0.issues.isEmpty }

    if !broken.isEmpty {
        print("\nBroken — will not be copied:")
        for r in broken {
            print("  \(r.track.sourceURL.lastPathComponent)")
            for i in r.issues where i.isBlocking { print("      \(i.describe)") }
        }
    }

    if !warned.isEmpty {
        print("\nWorth fixing:")
        for r in warned.prefix(40) {
            print("  \(r.track.sourceURL.lastPathComponent)")
            for i in r.issues { print("      \(i.describe)") }
        }
        if warned.count > 40 { print("  … and \(warned.count - 40) more") }
    }

    if !albums.isEmpty {
        print("\nAlbums:")
        for a in albums.prefix(40) {
            print("  \(a.albumArtist) — \(a.album)  (\(a.trackCount) tracks)")
            for i in a.issues { print("      \(i.describe)") }
        }
        if albums.count > 40 { print("  … and \(albums.count - 40) more") }
    }

    let strays = LibraryAudit().strayTracks(reports.map(\.track))
    if !strays.isEmpty {
        print("\nPossibly misplaced (right tags, wrong folder):")
        for s in strays.prefix(40) {
            print("  \(s.path)")
            print("      \(s.describe)")
        }
        if strays.count > 40 { print("  … and \(strays.count - 40) more") }
    }
}

let args = Args(CommandLine.arguments)

switch args.command {
case "devices":
    let found = DeviceFinder().candidates()
    if found.isEmpty {
        print("No removable volumes found.")
        print("Connect the Y1 and enable USB storage on the player — it does not mount otherwise.")
    } else {
        for d in found {
            print("\(d.name)\t\(ByteFormat.string(d.freeBytes)) free of \(ByteFormat.string(d.totalBytes))"
                  + (d.hasRockbox ? "\t[Rockbox]" : ""))
            print("  \(d.url.path)")
        }
    }

case "scan":
    let root = libraryFolder(args)
    let tracks = await LibraryScanner().scan(root: root)
    if tracks.isEmpty { print("No supported audio files under \(root.path)") }
    for t in tracks {
        print("\(t.effectiveAlbumArtist) — \(t.effectiveAlbum) — \(t.effectiveTitle)"
              + "  [\(t.fileExtension), \(ByteFormat.string(t.fileSize))]")
    }
    print("\n\(tracks.count) track(s)")

case "check":
    let root = libraryFolder(args)
    let (good, reports, albums) = await prepareLibrary(args, root: root)
    print("Checked \(reports.count) file(s): \(good.count) good, "
          + "\(reports.count - good.count) broken.")
    printIssues(reports, albums)
    if reports.allSatisfy({ $0.issues.isEmpty }) && albums.isEmpty {
        print("\nNothing to fix.")
    }

case "dupes":
    let root = libraryFolder(args)
    let tracks = await LibraryScanner().scan(root: root)
    guard !tracks.isEmpty else { fail("no supported audio files under \(root.path)") }

    let groups = Duplicates().find(in: tracks)
    if groups.isEmpty {
        print("Scanned \(tracks.count) file(s). No duplicates found.")
        break
    }

    let wasted = groups.reduce(Int64(0)) { $0 + $1.wastedBytes }
    print("Scanned \(tracks.count) file(s). \(groups.count) duplicate group(s), "
          + "\(ByteFormat.string(wasted)) recoverable.\n")

    var removed = 0
    var freed: Int64 = 0
    var failed = 0
    let undo = UndoRecorder(deviceRoot: root)

    for g in groups {
        let keeper = g.recommendedKeeper(onDeviceRoot: root)
        print("\(g.tracks[0].effectiveArtist) — \(g.tracks[0].effectiveTitle)")
        for t in g.tracks.sorted(by: { $0.fileSize > $1.fileSize }) {
            let isKeeper = t.sourceURL == keeper?.sourceURL
            let mark = isKeeper ? "keep  " : "remove"
            print("  \(mark) [\(t.fileExtension), \(ByteFormat.string(t.fileSize))] \(t.sourceURL.path)")
            if args.apply, !isKeeper {
                let relativePath = SyncEngine().devicePath(of: t.sourceURL, root: root)
                if undo.quarantine(t.sourceURL, path: relativePath) {
                    removed += 1
                    freed += t.fileSize
                } else {
                    failed += 1
                    print("    failed to remove")
                }
            }
        }
        print("")
    }

    if args.apply {
        undo.finish(label: "remove duplicates")
        print("Removed \(removed) file(s), freed \(ByteFormat.string(freed))."
              + (failed > 0 ? " \(failed) failed." : "")
              + (removed > 0 ? " Run 'y1sync undo' if this was a mistake." : ""))
    } else {
        print("Nothing was deleted. Re-run with --apply to remove the flagged duplicates.")
    }

case "tidy":
    let target = resolveTarget(args)
    let tracks = await LibraryScanner().scan(root: target)
    guard !tracks.isEmpty else { fail("no audio found on \(target.path)") }

    let tidy = DeviceTidy()
    let plan = tidy.plan(deviceRoot: target, tracks: tracks)

    print("Scanned \(tracks.count) track(s) on the device.")
    print("Renames: \(plan.moves.count)   Junk files: \(plan.junk.count) "
          + "(\(ByteFormat.string(plan.junkBytes)))   Empty folders: \(plan.emptyDirectories.count)"
          + "   Leftover folders: \(plan.leftoverFolders.count)")

    if plan.isEmpty {
        print("\nAlready tidy.")
        break
    }

    for m in plan.moves.prefix(30) { print("  \(m.describe)") }
    if plan.moves.count > 30 { print("  … and \(plan.moves.count - 30) more renames") }
    if !plan.junk.isEmpty {
        print("\nJunk (macOS sidecar files — never anything the player uses):")
        for j in plan.junk.prefix(30) { print("  \(j.describe)") }
        if plan.junk.count > 30 { print("  … and \(plan.junk.count - 30) more junk file(s)") }
    }
    for l in plan.leftoverFolders.prefix(30) { print("  \(l.describe)") }
    if plan.leftoverFolders.count > 30 {
        print("  … and \(plan.leftoverFolders.count - 30) more leftover folders")
    }

    guard args.apply else {
        print("\nNothing changed. Re-run with --apply to do it.")
        break
    }

    let result = tidy.apply(plan, deviceRoot: target) { done, total in
        FileHandle.standardError.write(Data("\r  \(done)/\(total)   ".utf8))
    }
    FileHandle.standardError.write(Data("\r".utf8))
    print("\nRenamed \(result.moved), removed \(result.junkRemoved) junk file(s) "
          + "(\(ByteFormat.string(result.bytesFreed))), "
          + "\(result.directoriesRemoved) empty folder(s), "
          + "\(result.leftoverFoldersRemoved) leftover folder(s)"
          + (result.coversSalvaged > 0 ? " (\(result.coversSalvaged) cover(s) salvaged first)" : "") + ".")
    if result.playlistsRepaired > 0 {
        print("Updated \(result.playlistsRepaired) playlist(s) to match the new paths.")
    }
    for f in result.failures.prefix(20) { print("  \(f)") }

case "enrich":
    let target = resolveTarget(args)
    guard args.fetchLyrics || args.fetchCovers else {
        fail("nothing to do — pass --lyrics and/or --fetch-covers")
    }

    let tracks = await LibraryScanner().scan(root: target)
    guard !tracks.isEmpty else { fail("no audio found on \(target.path)") }
    print("Found \(tracks.count) track(s) on the device.")

    // Enrich in place: the files here are the ones the player reads.
    let enricher = Enricher(layout: DeviceLayout(), maxArtDimension: args.maxArt,
                            inPlace: true)

    if args.fetchCovers {
        let health = TrackHealth(maxEmbeddedArtPixels: args.maxArt)
        let reports = await health.checkAll(tracks)
        var withArt: Set<String> = []
        for r in reports where r.hasEmbeddedArt {
            withArt.insert(FATName.foldedKey(
                "\(r.track.effectiveAlbumArtist)/\(r.track.effectiveAlbum)"))
        }
        var missing: Set<String> = []
        for t in tracks {
            let key = FATName.foldedKey("\(t.effectiveAlbumArtist)/\(t.effectiveAlbum)")
            if !withArt.contains(key) { missing.insert(key) }
        }

        if missing.isEmpty {
            print("Album art: every album already has a cover.")
        } else {
            print("Album art: looking up \(missing.count) album(s)…")
            let r = await enricher.addCovers(for: tracks, albumsMissingArt: missing,
                                             deviceRoot: target) { done, total, label in
                FileHandle.standardError.write(Data("\r  \(done)/\(total) \(label)      ".utf8))
            }
            FileHandle.standardError.write(Data("\r".utf8))
            print("Album art: embedded into \(r.coversEmbedded) file(s)"
                  + (r.coversFromLocalFile > 0 ? " (\(r.coversFromLocalFile) from a local cover file)" : "") + ".")
            for name in r.coversNotFound.prefix(20) { print("  not found: \(name)") }
        }
    }

    if args.fetchLyrics {
        print("Lyrics: looking up \(tracks.count) track(s)…")
        let r = await enricher.addLyrics(for: tracks, deviceRoot: target) { done, total, title in
            FileHandle.standardError.write(Data("\r  \(done)/\(total) \(title)      ".utf8))
        }
        FileHandle.standardError.write(Data("\r".utf8))
        print("Lyrics: wrote \(r.lyricsWritten) .lrc file(s), \(r.lyricsNotFound) not found.")
    }

    print("\nEject the player before unplugging it.")

case "plan", "sync":
    let root = libraryFolder(args)
    let target = resolveTarget(args)
    let (tracks, reports, albums) = await prepareLibrary(args, root: root)

    let engine = SyncEngine(
        artworkOptimizer: args.keepArt ? nil : ArtworkOptimizer(maxDimension: args.maxArt))
    let onDevice = engine.scanDevice(root: target)
    let plan = SyncPlanner().plan(library: tracks, deviceFiles: onDevice)

    print("Library: \(reports.count) file(s)   Playable: \(tracks.count)   "
          + "Already on device: \(plan.upToDate.count)")
    print("To copy: \(plan.actions.count) (\(ByteFormat.string(plan.bytesToCopy)))")

    if !plan.collisions.isEmpty {
        print("\nName collisions — only the first of each is copied:")
        for (path, group) in plan.collisions {
            print("  \(path)")
            for t in group { print("    \(t.sourceURL.path)") }
        }
    }

    if args.command == "plan" {
        printIssues(reports, albums)
        print("\nWould copy:")
        for a in plan.actions.prefix(50) {
            print("  \(a.kind == .replace ? "replace" : "copy")  \(a.devicePath)")
        }
        if plan.actions.count > 50 { print("  … and \(plan.actions.count - 50) more") }
        break
    }

    if plan.isEmpty && args.playlist == nil {
        print("Nothing to do.")
        printIssues(reports, albums)
        break
    }

    do {
        let result = try engine.execute(plan: plan, deviceRoot: target) { p in
            let pct = p.bytesTotal > 0 ? Int(Double(p.bytesCopied) / Double(p.bytesTotal) * 100) : 100
            FileHandle.standardError.write(Data("\r[\(pct)%] \(p.completed)/\(p.total) ".utf8))
        }
        FileHandle.standardError.write(Data("\r".utf8))
        print("Copied \(result.copied), replaced \(result.replaced), "
              + "\(ByteFormat.string(result.bytesCopied)) written.")
        if result.artworkShrunk > 0 {
            print("Cover art: resized on \(result.artworkShrunk) file(s), "
                  + "\(ByteFormat.string(result.artworkBytesSaved)) saved.")
        }
        for f in result.failed { print("  failed: \(f.path) — \(f.error)") }

        if args.covers {
            let n = await AlbumArtExporter()
                .exportCovers(for: tracks, layout: DeviceLayout(), deviceRoot: target)
            if n > 0 { print("Wrote \(n) cover.bmp file(s).") }
        }

        if args.fetchCovers {
            // Only albums the audit flagged as having no art are looked up,
            // so a normal sync makes no network requests at all.
            let missing = Set(albums.filter { $0.issues.contains(.noArtwork) }
                .map { FATName.foldedKey("\($0.albumArtist)/\($0.album)") })
            if missing.isEmpty {
                print("Album art: nothing missing.")
            } else {
                print("Album art: looking up \(missing.count) album(s)…")
                let r = await Enricher(maxArtDimension: args.maxArt)
                    .addCovers(for: tracks, albumsMissingArt: missing, deviceRoot: target)
                print("Album art: embedded into \(r.coversEmbedded) file(s)"
                  + (r.coversFromLocalFile > 0 ? " (\(r.coversFromLocalFile) from a local cover file)" : "") + ".")
                for name in r.coversNotFound { print("  not found: \(name)") }
            }
        }

        if args.fetchLyrics {
            print("Lyrics: looking up \(tracks.count) track(s)…")
            let r = await Enricher().addLyrics(for: tracks, deviceRoot: target) { done, total, title in
                FileHandle.standardError.write(Data("\r  \(done)/\(total) \(title)      ".utf8))
            }
            FileHandle.standardError.write(Data("\r".utf8))
            print("Lyrics: wrote \(r.lyricsWritten) .lrc file(s), "
                  + "\(r.lyricsNotFound) not found.")
        }

        if let name = args.playlist {
            let url = try PlaylistWriter().write(name: name, tracks: tracks, deviceRoot: target)
            print("Playlist: \(url.lastPathComponent) (\(tracks.count) entries)")
        }

        printIssues(reports, albums)
        print("\nEject the player before unplugging it.")
    } catch let e as DeviceError {
        fail(e.description)
    } catch {
        fail(error.localizedDescription)
    }

case "artists":
    let target = resolveTarget(args)
    let onCard = await LibraryScanner().scan(root: target)
    let found = SimilarArtists().find(in: onCard)
    if found.isEmpty { print("No artist is spelled two ways (\(onCard.count) tracks)."); break }
    for g in found {
        print("\(g.trackCount) tracks, suggested spelling “\(g.suggested)”")
        for v in g.variants { print("    \(v.tracks.count)  “\(v.name)”") }
    }

case "albums":
    let target = resolveTarget(args)
    let onCard = await LibraryScanner().scan(root: target)
    let groups = SimilarAlbums().find(in: onCard)
    if groups.isEmpty { print("No album looks split (\(onCard.count) tracks)."); break }
    for g in groups {
        print("\(g.albumArtist) — \(g.trackCount) tracks, suggested name “\(g.suggested)”")
        for v in g.variants { print("    \(v.tracks.count)  “\(v.title)”") }
        if g.sharedSongs > 0 { print("    \(g.sharedSongs) song(s) appear under more than one name") }
    }

case "library":
    let target = resolveTarget(args)
    guard PlayerLibraryCache.exists(deviceRoot: target) else {
        print("This player keeps no song list (\(PlayerLibraryCache.fileName)) — it builds its own."); break
    }
    let onCard = await LibraryScanner().scan(root: target)
    guard let st = PlayerLibraryCache.status(deviceRoot: target, deviceTracks: onCard) else { fail("could not read the song list") }
    print("On the card: \(onCard.count) track(s). In the player's list: \(st.cached).")
    print("Invisible on the player: \(st.missing.count). Dead entries: \(st.stale.count).")
    var byArtist: [String: Int] = [:]
    for t in st.missing { byArtist[t.effectiveAlbumArtist, default: 0] += 1 }
    for (a, n) in byArtist.sorted(by: { $0.value > $1.value }).prefix(30) { print("  \(n)  \(a)") }
    if st.isInSync { print("\nIn sync."); break }
    guard args.apply else { print("\nNothing changed. Re-run with --apply to update the list."); break }
    let r = try PlayerLibraryCache.sync(deviceRoot: target, deviceTracks: onCard)
    print("\nUpdated the player's song list: \(r.added) added, \(r.removed) removed. Backup: \(PlayerLibraryCache.fileName).y1sync-backup")

case "formats":
    let target = resolveTarget(args)
    let cache = ScanCache(root: target)
    let start = Date()
    let found = await LibraryScanner().scan(root: target, cache: cache)
    guard !found.isEmpty else { fail("no audio found on \(target.path)") }
    print(String(format: "%d file(s) read in %.1fs", found.count, Date().timeIntervalSince(start)))
    for row in PlayerLimits.summary(of: found) { print(String(format: "%5d  %@", row.count, row.label)) }

case "health":
    let target = resolveTarget(args)
    let onPlayer = await LibraryScanner().scan(root: target)
    guard !onPlayer.isEmpty else { fail("no audio found on \(target.path)") }
    var lib: [Track] = []
    if let path = args.library {
        lib = await LibraryScanner().scan(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }
    print("Checking \(onPlayer.count) file(s) on the player…")
    let health = DeviceHealth()
    let broken = await health.scan(deviceTracks: onPlayer, deviceRoot: target, library: lib) { done, total in
        FileHandle.standardError.write(Data("\r  \(done)/\(total)   ".utf8))
    }
    FileHandle.standardError.write(Data("\r".utf8))
    if broken.isEmpty { print("All \(onPlayer.count) files decode fine."); break }

    print("\(broken.count) broken file(s):")
    for b in broken {
        print("  \(b.devicePath)")
        print("      \(b.reasons.joined(separator: "; "))")
        print("      " + (b.replacement.map { "can be replaced from \($0.sourceURL.path)" }
                          ?? (args.library == nil ? "no library given (--library <folder>)" : "no intact copy in the library")))
    }
    guard args.repair else { print("\nNothing changed. Re-run with --repair to fix them."); break }
    let out = health.fix(broken, deviceRoot: target, removeUnrepairable: args.removeBroken)
    print("\nReplaced \(out.replaced), removed \(out.removed)."
          + (out.failed.isEmpty ? "" : " Failed: \(out.failed.count)")
          + " Run 'y1sync undo' to reverse.")

case "undo":
    let target = resolveTarget(args)
    guard let session = UndoLog.mostRecent(deviceRoot: target) else {
        print("Nothing to undo.")
        break
    }

    if args.forget {
        UndoLog.forgetMostRecent(deviceRoot: target)
        print("Discarded the \"\(session.label)\" session — its space is now free. It cannot be restored.")
        break
    }

    print("Last undoable operation: \"\(session.label)\" (\(session.entries.count) change(s)).")
    guard args.apply else {
        print("Re-run with --apply to restore it, or --forget to discard it for good.")
        break
    }

    let outcome = UndoLog.undoMostRecent(deviceRoot: target) ?? .init()
    print("Restored \(outcome.restored) item(s).")
    for f in outcome.failed {
        print("  could not restore \(f) — something else is already there")
    }

case "playlists":
    let target = resolveTarget(args)
    let tracks = await LibraryScanner().scan(root: target)
    guard !tracks.isEmpty else { fail("no audio found on \(target.path)") }

    let anySpecified = args.wantMood || args.wantTempo || args.wantGenre
    let builder = SmartPlaylistBuilder()
    do {
        let result = try builder.writeAll(
            tracks: tracks, deviceRoot: target,
            moods: anySpecified ? args.wantMood : true,
            bpm: anySpecified ? args.wantTempo : true,
            genres: anySpecified ? args.wantGenre : true)

        if result.written.isEmpty {
            print("No mood/tempo/genre tags found (or none had enough tracks to make a playlist).")
        } else {
            print("Wrote \(result.written.count) playlist(s):")
            for (name, count) in result.written.sorted(by: { $0.key < $1.key }) {
                print("  \(name) — \(count) track(s)")
            }
        }
    } catch {
        fail(error.localizedDescription)
    }

case "help", "--help", "-h", nil:
    printUsage()

default:
    fail("unknown command '\(args.command ?? "")' — run 'y1sync help'")
}
