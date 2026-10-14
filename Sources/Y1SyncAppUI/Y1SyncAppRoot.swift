import SwiftUI
import AppKit

/// The app's entry point, exposed publicly so the thin `Y1SyncApp` executable
/// target can invoke it. Living in a library target rather than the
/// executable is what makes Xcode Previews work at all — Previews build a
/// debug dylib of the target a file belongs to, and executable targets can't
/// produce one (see the "ENABLE_DEBUG_DYLIB" error), while library targets
/// build as a dylib naturally.
public struct Y1SyncAppRoot: App {
    public init() {
        // Must happen before the first view asks for a custom font.
        FontRegistry.registerAll()
    }

    public var body: some Scene {
        WindowGroup("Y1 Sync") {
            RootView()
        }
        // Flat paper runs edge to edge; the title lives in the app's own top bar.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 780)
    }
}

/// Applies the appearance override above the theme, so the palette follows it.
struct RootView: View {
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .auto

    var body: some View {
        ContentView()
            .background(WindowPaper())
            .themed()
            .preferredColorScheme(appearance.colorScheme)
    }
}

/// Paints the NSWindow itself in the palette's paper, so live resize and the
/// album sheet never show the system window colour. Follows the appearance
/// override because it reads the themed palette.
private struct WindowPaper: View {
    @Environment(\.palette) private var p

    var body: some View {
        WindowBackgroundSetter(color: NSColor(p.paper))
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

private struct WindowBackgroundSetter: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> PaperView { PaperView() }

    func updateNSView(_ view: PaperView, context: Context) {
        view.color = color
    }

    final class PaperView: NSView {
        var color: NSColor? {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let color, let window else { return }
            window.backgroundColor = color
        }
    }
}
