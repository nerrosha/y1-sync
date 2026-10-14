import Foundation

/// Finds the app's own resource folders (fonts, sounds).
///
/// These are deliberately not SwiftPM resources: SwiftPM puts its resource
/// bundle at the root of the .app, which breaks code signing. Instead
/// `build-app.sh` copies `Resources/<name>` into `Contents/Resources/<name>`,
/// and during development (`swift run`, Xcode previews) the repo's own
/// `Resources/<name>` folder is used.
enum ResourceLocator {
    static func directory(_ name: String) -> URL? {
        let fm = FileManager.default

        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(name, isDirectory: true),
           fm.fileExists(atPath: bundled.path) {
            return bundled
        }

        // <repo>/Sources/Y1SyncAppUI/Theme/ResourceLocator.swift → <repo>
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Theme
            .deletingLastPathComponent()   // Y1SyncAppUI
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo
        let dev = repo.appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        return fm.fileExists(atPath: dev.path) ? dev : nil
    }
}
