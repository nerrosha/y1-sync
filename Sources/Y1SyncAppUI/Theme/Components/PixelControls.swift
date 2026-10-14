import SwiftUI

// MARK: - Buttons

/// Pixel button. `.primary` is the single accent-coloured action on a screen;
/// everything else is `.normal`. Pressing removes the inner shade and nudges
/// the face down a pixel.
struct PixelButtonStyle: ButtonStyle {
    enum Kind { case primary, normal }
    var kind: Kind = .normal
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, kind: kind, compact: compact)
    }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let compact: Bool
        @Environment(\.palette) private var p
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            let primary = kind == .primary
            let u = Pixel.unit
            configuration.label
                .font(.pixel(compact ? 13 : 15, bold: primary))
                .foregroundStyle(primary ? p.onAccent : p.ink)
                .padding(.horizontal, compact ? 10 : 16)
                .padding(.vertical, compact ? 4 : 7)
                .padding(.bottom, pressed ? 0 : u)          // room for the shade
                .padding(.top, pressed ? u : 0)
                .background(
                    ZStack(alignment: .bottom) {
                        PixelRect(notch: u).fill(p.ink)
                        PixelRect(notch: u).fill(primary ? p.accent : p.card).padding(u)
                        if !pressed {
                            // Inner bottom shade — the classic pixel "bevel".
                            Rectangle().fill(primary ? p.accentShade : p.line)
                                .frame(height: u)
                                .padding(.horizontal, u * 2)
                                .padding(.bottom, u)
                        }
                    }
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Checkbox

enum CheckState: Equatable { case on, off, mixed }

/// Pixel checkbox; can show "some but not all" for an artist with only part
/// of their albums ticked.
struct PixelCheckbox: View {
    let state: CheckState
    var label: String?
    let action: () -> Void

    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    PixelFrame(fill: p.card, border: p.ink, width: 2)
                    switch state {
                    case .on: Rectangle().fill(p.ink).padding(5)
                    case .mixed: Rectangle().fill(p.ink).frame(height: 3).padding(.horizontal, 5)
                    case .off: EmptyView()
                    }
                }
                .frame(width: 16, height: 16)
                if let label {
                    Text(label).font(.system(size: 13)).foregroundStyle(p.ink).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label ?? "")
        .accessibilityValue(state == .on ? "On" : state == .mixed ? "Partly selected" : "Off")
    }
}

/// `PixelCheckbox` bound to a Bool.
struct PixelToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        PixelCheckbox(state: isOn ? .on : .off, label: title) { isOn.toggle() }
    }
}

// MARK: - Fields

/// Pixel frame around an input or a value (device picker, search, paths).
struct PixelField<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minHeight: 30)
            .pixelFrame(fill: p.card, border: p.ink, width: 2)
    }
}

struct PixelTextField: View {
    let placeholder: String
    @Binding var text: String
    var systemImage: String?
    @Environment(\.palette) private var p

    var body: some View {
        PixelField {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(p.inkSoft)
                    .accessibilityHidden(true)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(p.ink)
        }
    }
}

// MARK: - Tabs

struct PixelTab<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    var badge: Int?
}

/// Plain pixel tabs: the active one is a solid ink block. ⌘1…⌘4 switch.
struct PixelTabBar<ID: Hashable>: View {
    let tabs: [PixelTab<ID>]
    @Binding var selection: ID
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let active = tab.id == selection
                Button {
                    guard !active else { return }
                    selection = tab.id
                    UISound.cursor.play()
                } label: {
                    HStack(spacing: 6) {
                        Text(tab.title).font(.pixel(16, bold: active))
                        if let badge = tab.badge, badge > 0 {
                            Text("\(badge)").font(.pixel(12, bold: true))
                                .foregroundStyle(active ? p.ink : p.card)
                                .padding(.horizontal, 5)
                                .background(PixelRect(notch: 2).fill(active ? p.card : p.ink))
                        }
                    }
                    .foregroundStyle(active ? p.card : p.ink)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(active ? PixelRect(notch: Pixel.unit).fill(p.ink) : nil)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .help("\(tab.title) (⌘\(index + 1))")
                .accessibilityLabel(tab.title)
                // The badge is otherwise visual only.
                .accessibilityValue(tab.badge.map { $0 > 0 ? "\($0)" : "" } ?? "")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }
}

// MARK: - Progress

/// A row of chunky blocks filled left to right.
struct PixelProgress: View {
    var value: Double
    var blocks = 20
    @Environment(\.palette) private var p

    var body: some View {
        let filled = Int((min(max(value, 0), 1) * Double(blocks)).rounded(.down))
        HStack(spacing: 2) {
            ForEach(0..<blocks, id: \.self) { i in
                Rectangle().fill(i < filled ? p.accent : p.line)
                    .frame(height: 10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}
