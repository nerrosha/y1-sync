import AppKit

/// Short interface sounds. The files live in `Resources/Sounds/<name>.mp3`
/// (optional, bring your own — see the README there). A missing file just
/// means silence, never an error.
///
/// Sounds respect two switches: the app's own "Sounds" toggle and macOS's
/// "Play user interface sound effects" setting.
@MainActor
enum UISound: String, CaseIterable {
    case cursor, confirm, success, error, open

    private static var cache: [UISound: NSSound] = [:]

    func play() {
        guard AppSettings.soundsEnabled, Self.systemAllowsUISounds else { return }
        guard let sound = Self.sound(for: self) else { return }
        // Restart rather than overlap when triggered quickly (tab hopping).
        sound.stop()
        sound.play()
    }

    private static func sound(for kind: UISound) -> NSSound? {
        if let cached = cache[kind] { return cached }
        guard let dir = ResourceLocator.directory("Sounds") else { return nil }
        for ext in ["mp3", "wav", "aif", "aiff", "m4a"] {
            let url = dir.appendingPathComponent("\(kind.rawValue).\(ext)")
            if let s = NSSound(contentsOf: url, byReference: true) {
                s.volume = 0.45
                cache[kind] = s
                return s
            }
        }
        return nil
    }

    /// System Settings › Sound › "Play user interface sound effects".
    private static var systemAllowsUISounds: Bool {
        let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.systemsound")
        if let enabled = domain?["com.apple.sound.uiaudio.enabled"] as? Int { return enabled != 0 }
        return true
    }
}
