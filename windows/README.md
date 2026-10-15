# Y1 Sync for Windows

> **Beta. Not tested on a real Windows PC or a real Innioasis Y1.**
> It is built and checked only on GitHub's Windows servers: the engine builds, its 251
> tests pass, and a script copies real files between folders and reads them back. What that
> cannot show is how the window looks and behaves on your screen, and how Windows sees the
> player (drive letters, USB speed, write caching). If something is off, please
> [open an issue](https://github.com/nerrosha/y1-sync/issues/new?template=bug_report.yml):
> every report gets fixed.

Same features as the Mac app: sync only what is missing, check every copied file by reading
it back, merge albums and artists spelled twice (and remember it), find broken and duplicate
files, tidy names, see what you really listen to and free up space. Audio is never converted.

## Install

Download from the [latest release](https://github.com/nerrosha/y1-sync/releases):

- **`Y1-Sync-Windows-setup.exe`**: installer (per user, no admin rights).
- **`Y1-Sync-Windows-portable.zip`**: unzip anywhere and run `Y1 Sync.exe`. Keep the other files and the runtime folder
  beside it.

Windows says it does not know the publisher (the app is not code-signed): **More info → Run anyway**.
The window uses Microsoft's WebView2, which Windows 10/11 already has.

**Turn on USB storage on the player itself.** It does not show up as a drive until you do.

## If the player is not listed

Y1 Sync lists removable drives, plus any other drive (except `C:`) that already looks like a Y1.
If yours is missing, press **Pick a folder…** in the Player box and choose its drive, for example `E:\`.

## How it is built

```
Y1 Sync.exe   the window (Tauri, web interface in windows/src)
y1sync.exe    the engine (Swift, the same code as the Mac app), spoken to as JSON: `y1sync api`
ffmpeg.exe    reads tags, checks that files decode, resizes covers (LGPL build, replaces what the
ffprobe.exe   Mac gets from AVFoundation and ImageIO)
```

Where the Mac app uses AVFoundation and ImageIO, the Windows build asks ffmpeg. FLAC, MP3 and M4A
tags are read and written by the app's own code, the same on both systems.

### Differences from the Mac app

- No "play a file straight from the player" in Results.
- Windows does not create the hidden `._` files macOS does, so that part of Tidy finds nothing.
- The read-back check after copying runs through the normal Windows file cache, so it is a little
  less strict than on the Mac, where the cache is bypassed.

### Build it yourself

You need the Swift 6.2 toolchain for Windows, Rust, Node 20 and ffmpeg.

```powershell
swift build -c release --product y1sync --static-swift-stdlib
# copy y1sync.exe, ffmpeg.exe, ffprobe.exe into windows/src-tauri/binaries/ as
#   y1sync-x86_64-pc-windows-msvc.exe, ffmpeg-x86_64-pc-windows-msvc.exe, ffprobe-x86_64-pc-windows-msvc.exe
cd windows
npm install
npx tauri icon app-icon.png
npx tauri build --bundles nsis
```

The workflow `.github/workflows/windows-app.yml` does exactly this.

### Try the window in a browser (any system)

```bash
swift build
Y1SYNC_BIN=.build/debug/y1sync Y1SYNC_DATA=/tmp/y1-data python3 windows/dev/bridge.py 8765
# open http://127.0.0.1:8765
```

## License

MIT, like the rest of the project. `ffmpeg.exe` and `ffprobe.exe` are the LGPL builds from
[BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds); their licence text ships beside them.
