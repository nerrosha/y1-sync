# Contributing

Thanks for helping. The most useful thing right now is **reports from other firmware**
(stock Innioasis, Rockbox, other launchers): which formats play, what the player does with
large covers, which files it keeps. Open an issue and say what you found.

## Reporting a problem

Please include:
- your firmware (stock / JJ Launcher / InniClassic / Rockbox) and version, and what the app showed in the **Firmware** row;
- macOS version;
- what you did, what you expected, what happened;
- for a file that will not play: its format (the **Formats** box on the Device tab lists them) and what the player says.

## Code

```bash
swift build
swift test        # full Xcode needed for XCTest
```

- Keep the engine (`Sources/Y1SyncCore`) free of UI and cover new behaviour with tests.
- Never convert or re-encode a user's audio, and never delete without a way back (the undo folder).
- Match the surrounding style; no third-party dependencies.
- Small, focused pull requests are easiest to review.
