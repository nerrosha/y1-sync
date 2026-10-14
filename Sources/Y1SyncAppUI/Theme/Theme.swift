import SwiftUI

// MARK: - Palette

/// The whole colour set for one appearance. Deliberately small: paper, ink,
/// one accent, and three status colours. Views read it from the environment
/// (`@Environment(\.palette)`), so day/night is a single swap at the root.
///
/// Every text/background pair was checked against WCAG AA (4.5:1).
struct Palette: Sendable, Equatable {
    /// Window background.
    var paper: Color
    /// Inside of boxes and buttons.
    var card: Color
    /// Text, pixel borders, selected tab/row fill.
    var ink: Color
    /// Secondary text.
    var inkSoft: Color
    /// Faint separators and the shade inside buttons.
    var line: Color
    /// The one accent — primary button, progress, focus.
    var accent: Color
    var accentShade: Color
    var onAccent: Color
    var good: Color
    var warn: Color
    var bad: Color
    var isNight: Bool

    static let day = Palette(
        paper: Color(hex: 0xF3EFE6), card: .white, ink: Color(hex: 0x1A1A1A),
        inkSoft: Color(hex: 0x5A554B), line: Color(hex: 0xD6D0C4),
        accent: Color(hex: 0x2D6CDF), accentShade: Color(hex: 0x1D4AA0), onAccent: .white,
        good: Color(hex: 0x2F7D3B), warn: Color(hex: 0xB04E14), bad: Color(hex: 0xC42B2B),
        isNight: false)

    static let night = Palette(
        paper: Color(hex: 0x16151A), card: Color(hex: 0x211F26), ink: Color(hex: 0xECE8DE),
        inkSoft: Color(hex: 0xA9A39A), line: Color(hex: 0x3A3742),
        accent: Color(hex: 0x6E9BFF), accentShade: Color(hex: 0x4A6FD0), onAccent: Color(hex: 0x0E0D12),
        good: Color(hex: 0x7FD18B), warn: Color(hex: 0xF2A65A), bad: Color(hex: 0xFF7A7A),
        isNight: true)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Metrics

enum Pixel {
    /// One "pixel" of the pixel-art chrome: border width and corner notch.
    static let unit: CGFloat = 3
    static let gap: CGFloat = 16
}

// MARK: - Environment

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette = .day
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Picks the day or night palette from the effective appearance.
private struct ThemeRoot: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.environment(\.palette, scheme == .dark ? .night : .day)
    }
}

extension View {
    /// Apply once at the root of a window or sheet.
    func themed() -> some View { modifier(ThemeRoot()) }
}

// MARK: - Fonts

/// Pixelify Sans (SIL OFL, has Cyrillic) for everything that is chrome —
/// titles, tabs, buttons, labels, numbers. Lists, paths and longer help text
/// stay in the system font, which reads better at small sizes. If the font
/// failed to register, `Font.custom` falls back to the system font.
extension Font {
    /// The pixel face only for headings and big numbers: at body sizes it is hard
    /// to read, so smaller text (buttons, tabs, labels) uses the system font.
    static func pixel(_ size: CGFloat, bold: Bool = false) -> Font {
        if size < 18 { return .system(size: size + 1, weight: bold ? .semibold : .medium) }
        return .custom(bold ? "PixelifySans-SemiBold" : "PixelifySans-Regular", size: size, relativeTo: .body)
    }
}

// MARK: - Appearance override

/// Follow macOS, or force day / night.
enum Appearance: String, CaseIterable {
    case auto, day, night

    static let storageKey = "appearance"

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: nil
        case .day: .light
        case .night: .dark
        }
    }

    var next: Appearance {
        switch self {
        case .auto: .day
        case .day: .night
        case .night: .auto
        }
    }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .day: "Day"
        case .night: "Night"
        }
    }
}
