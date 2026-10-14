# Y1 Sync

A macOS companion app for the Innioasis Y1. It scans a music library, works out
what is missing on the player, and copies only that — checking files are
playable and shrinking oversized cover art on the way.

Works with **stock Innioasis firmware** and **Rockbox-based firmware** (e.g.
InnioClassic) — a `.rockbox` folder on the volume is auto-detected and
preferred when picking among several connected drives. A couple of bits are
Rockbox-specific and opt-in (see `--covers` below).

## Why it works this way

The Y1 mounts as plain **USB mass storage** (not MTP), so this is ordinary file
I/O against `/Volumes/<name>` — no drivers, no libusb. Three details drive most
of the design:

- **FAT32 naming.** The volume is FAT32, which forbids `" * / : < > ? \ |`,
  strips trailing dots and spaces, and reserves DOS names like `CON`. Copying a
  file called `AC/DC – Live?.mp3` straight across either fails or lands under a
  name the player can't open. Every path component is normalised first, and
  because FAT is case-insensitive all comparisons fold case — otherwise every
  sync re-copies the whole library.
- **The folder tree is the UI.** The player browses the filesystem, so files are
  laid out `Artist/Album/NN Title.ext` with zero-padded track numbers (else
  "10" sorts before "2"). Compilations group by *album artist*, or one album
  scatters into a folder per guest artist.
- **FLAC needs its own parser.** AVFoundation does not expose Vorbis comments,
  so a lossless library reads back as "Unknown Artist / Unknown Album" through
  the common-metadata API. FLAC is parsed and rewritten directly.
- **macOS hides its own litter.** Writing to a FAT volume creates `._name`
  AppleDouble files, which macOS then folds into the file they describe —
  invisible to `readdir`, `ls -a` and `FileManager`, but plainly visible to the
  player. They can only be found by probing each sibling path.
- **Cover art must be small.** Stock Innioasis firmware reads artwork from each
  file's own tags, and a very large image can exhaust its memory — beyond about 1000 px the
  player lags and can lock up. Oversized art is therefore resized and re-embedded
  during the copy, rewriting only the ID3 tag so the audio frames pass through
  byte-for-byte. **Your original files are never modified.**
  (`--covers` additionally writes `cover.bmp` per album, which only Rockbox reads.)

- **Broken files are caught before they're copied.** Header checks alone are not
  enough: 3 KB of random bytes contains valid MPEG frame syncs, and AVFoundation
  will happily report "1 audio track, 0.52s". Each file is therefore decoded
  briefly to prove it yields real samples.

## Usage

Build:

```bash
./build-app.sh
```

That produces `build/Y1 Sync.app` and the `build/y1sync` CLI.

The player **does not mount until you enable USB storage on the device itself** —
this is the usual reason nothing appears.

### App

```bash
open "build/Y1 Sync.app"
```

**Sync tab** — pick the player, drop a music folder in, hit **Scan and compare**
to see exactly what would be copied, then **Sync to player**.

**Results tab** — after a sync, every copied file is listed with tags showing
what was fixed (`cover 1600x1600 → 1000x1000`, `lyrics added`, `album artist → …`),
plus a section listing any files that were **skipped** and why. Select a file
to play it **straight off the device**, with its embedded artwork and synced
lyrics highlighting in time with the audio. Click any lyric line to seek there.
This is the check that the files really are right, rather than trusting a
summary count.

**Device tab** — works on files already on the player, no source library
needed: **tidy** renames everything into the consistent `Artist/Album/NN
Title.ext` layout and clears junk (hidden `._*` sidecars, empty folders, and
pre-tidy folders whose tracks have all moved out — any cover art left behind
in one is copied to the new album folder first), and **enrich** fetches
missing lyrics/cover art in place. Both show a dry-run plan first and ask for
confirmation before touching anything.

**Duplicates tab** — finds tracks that are the same recording under different
names (tolerant of remaster/explicit-edition noise, but careful not to conflate
a studio cut with a genuinely different version like a live or acoustic take),
so you can delete the redundant copy or copies straight from the device.

**Nothing tidy or the Duplicates tab removes is actually deleted right away.**
It moves into a hidden quarantine folder on the device instead, and an "Undo"
banner appears offering to put it straight back. Only the single most recent
run is kept — starting another tidy or cleanup permanently drops whatever the
previous one was holding, which is also what actually frees the space.

**Smart playlists**, in the Device tab, build `.m3u8` playlists from mood,
tempo (BPM) and genre tags already on the files — the kind beets or Picard's
AcousticBrainz plugin write. No network call, and a track missing the tag is
just skipped rather than miscategorized.

### CLI

```bash
y1sync devices                          # list candidate volumes
y1sync tidy                             # rename device files consistently (dry run)
y1sync tidy   --apply                   # ...actually do it
y1sync enrich --lyrics --fetch-covers   # add lyrics/art to what's already there
y1sync playlists                        # build mood/tempo/genre playlists from tags
y1sync undo                             # show what the last tidy/dupes --apply would restore
y1sync undo --apply                     # ...restore it
y1sync scan  ~/Music                    # read tags, show what was found
y1sync check ~/Music                    # broken files, huge covers, tag problems, misplaced files
y1sync plan  ~/Music                    # dry run: what would be copied
y1sync sync  ~/Music --playlist "Daily" # copy, and write a playlist
```

Options: `--device <name>` to disambiguate, `--to <path>` to target a plain
folder (handy for testing), `--max-art <px>` to change the cover limit,
`--keep-art` to leave art untouched, `--copy-broken` to copy unplayable files
anyway, `--split-albums` to skip album-artist unification, `--covers` to also
write `cover.bmp` (Rockbox only).

## What it does

- Scans MP3, FLAC, OGG, Opus, M4A, AAC, WAV, WavPack, APE, Musepack, AIFF
- Verifies every file decodes; skips empty, truncated and corrupt ones
- Resizes oversized embedded cover art (default 1000px; InniClassic shows covers large and asks for 600–1000 px) during the copy
- Unifies album artists so a compilation lands in one folder, not one per guest
- Reports duplicate/missing track numbers, gaps, and untagged files
- Resizes oversized art in **MP3 and FLAC**, rewriting only the tag so audio is
  preserved byte-for-byte
- Tidies files already on the player into one consistent layout, clears the
  hidden macOS `._*` sidecars the player would otherwise list, and removes
  pre-tidy folders left holding only a stray cover/log once their tracks have
  moved out (salvaging the cover first)
- Finds duplicate recordings (tolerant of remaster noise, not fooled by a live
  or acoustic version of the same song) so you can delete the redundant copy
- Fetches synced lyrics from LRCLIB and writes `.lrc` files the player reads
- Finds missing album art on the Cover Art Archive and embeds it
- Reads tags via AVFoundation — no third-party dependencies
- Copies only what's missing, comparing by destination path and file size
- Detects truncated files from an interrupted copy and replaces them
- Copies to a temp name then moves into place, so a failure never leaves a
  half-written file that later looks complete
- Reports name collisions instead of silently overwriting
- Writes `.m3u8` playlists with device-absolute paths, and repairs any
  existing playlist whose paths a tidy run just renamed
- Builds mood/tempo/genre playlists from tags already on the files
- Flags a track whose own tags disagree with the rest of its physical
  folder — the signature of a file that ended up mixed into the wrong place
  while keeping its own, internally consistent tags
- Prefers a cover image already sitting in an album's own folder over
  fetching one online
- Quarantines rather than deletes, so tidy and duplicate cleanup are undoable
  until the next destructive run

## Online lookups

Both are opt-in (`--lyrics`, `--fetch-covers`), free, and need no account:

- **Lyrics** come from [LRCLIB](https://lrclib.net). Stock Innioasis firmware
  reads `.lrc` files placed beside the audio, so synced lyrics display on the
  player. Track duration is sent so a radio edit doesn't match an album cut.
- **Cover art** comes from the [Cover Art Archive](https://coverartarchive.org)
  via MusicBrainz, and only for albums that have no art at all. Release
  *groups* are searched first — a group covers every pressing of an album, so
  art is present far more often than on one specific edition.

These send artist, album and track names to those services. MusicBrainz asks for
one request per second, which the client respects.

## Design

A simple flat pixel style: warm paper with white pixel boxes and ink borders by
day, a dark version by night (follows macOS, or pick Auto / Day / Night with the
button in the top bar). The top bar holds the tabs — Sync, Results, Device,
Dupes (⌘1–⌘4) — and a status bar along the bottom shows the player and any work
in progress. The Sync tab is three numbered boxes: 1 Player, 2 Music, 3 Copy.
Everything is built from a small design system in `Sources/Y1SyncAppUI/Theme/`
(palette tokens, `PixelBox`, `PixelButtonStyle`, `Notice`, `PixelTabBar`, …).

- Text uses the system font; the pixel look comes from the borders and corners.
  Pixelify Sans (SIL OFL) is bundled in `Resources/Fonts`.
- Optional UI sounds go in `Resources/Sounds` (mute with the speaker button).
- No animations; colour is never the only signal (every status line has an icon).

Double-click `check.command` to build the app and run the tests in one go.

## Layout

```
Sources/Y1SyncCore/    engine — no UI, fully tested
Sources/y1sync/        CLI
Sources/Y1SyncAppUI/   SwiftUI views/models (a library, so Xcode Previews can build them)
Sources/Y1SyncApp/     thin executable that just launches Y1SyncAppUI
Tests/                 174 tests
```

Run the tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The ID3 rewriting is covered by tests that assert the audio payload survives
byte-for-byte, since a bug there would silently corrupt a music library.

`DEVELOPER_DIR` is needed because `xcode-select` points at the Command Line
Tools, which don't ship XCTest.

## License

The code is [MIT](LICENSE). Third-party files keep their own terms:

- `Resources/Fonts/PixelifySans-*` — SIL Open Font License 1.1 (`PixelifySans-OFL.txt`).
- Interface sounds are optional: put your own files in `Resources/Sounds` (see `Resources/Sounds/README.txt`). Without them the app is silent.

## Contact

Ideas, bug reports and offers: nerrosha4ever@gmail.com
