import Foundation
import CoreText

/// Registers the bundled fonts for this process. Safe to call more than once.
@MainActor
enum FontRegistry {
    private static var done = false

    static func registerAll() {
        guard !done else { return }
        done = true
        guard let dir = ResourceLocator.directory("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return }

        for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            // A font already registered (e.g. installed by the user) reports
            // an error here — harmless, the face is available either way.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
