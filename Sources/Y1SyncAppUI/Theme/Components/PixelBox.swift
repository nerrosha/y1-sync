import SwiftUI

// MARK: - Shape

/// A rectangle with one-pixel notched corners — the classic pixel-art box.
struct PixelRect: Shape {
    var notch: CGFloat = Pixel.unit

    func path(in r: CGRect) -> Path {
        let n = min(notch, r.width / 2, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + n, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - n, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - n, y: r.minY + n))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + n))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - n))
        p.addLine(to: CGPoint(x: r.maxX - n, y: r.maxY - n))
        p.addLine(to: CGPoint(x: r.maxX - n, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + n, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + n, y: r.maxY - n))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - n))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + n))
        p.addLine(to: CGPoint(x: r.minX + n, y: r.minY + n))
        p.closeSubpath()
        return p
    }
}

/// Filled pixel box with a solid pixel border.
struct PixelFrame: View {
    var fill: Color
    var border: Color
    var width: CGFloat = Pixel.unit

    var body: some View {
        ZStack {
            PixelRect(notch: width).fill(border)
            PixelRect(notch: width).fill(fill).padding(width)
        }
        .accessibilityHidden(true)
    }
}

extension View {
    func pixelFrame(fill: Color, border: Color, width: CGFloat = Pixel.unit) -> some View {
        background(PixelFrame(fill: fill, border: border, width: width))
    }
}

// MARK: - Box

/// The standard content block: a white pixel box with an optional numbered
/// heading ("1  Player") so the order of things is obvious at a glance.
struct PixelBox<Content: View, Accessory: View>: View {
    var title: String?
    var step: Int?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let step {
                        Text("\(step)")
                            .font(.pixel(14, bold: true))
                            .foregroundStyle(p.card)
                            .frame(width: 22, height: 22)
                            .background(PixelRect(notch: 2).fill(p.ink))
                            .accessibilityLabel("Step \(step)")
                    }
                    Text(title).font(.pixel(18, bold: true))
                    Spacer(minLength: 8)
                    accessory
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .foregroundStyle(p.ink)
        .pixelFrame(fill: p.card, border: p.ink)
    }
}

extension PixelBox where Accessory == EmptyView {
    init(title: String? = nil, step: Int? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.step = step
        self.accessory = EmptyView()
        self.content = content()
    }
}

// MARK: - Small pieces

enum Kind { case good, warn, bad, info }

extension Palette {
    func color(for kind: Kind) -> Color {
        switch kind {
        case .good: good
        case .warn: warn
        case .bad: bad
        case .info: inkSoft
        }
    }
}

/// One line of status: an icon plus text in the status colour. Colour is
/// never the only signal — the icon says it too.
struct Notice: View {
    let kind: Kind
    let text: String
    @Environment(\.palette) private var p

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold))
                .accessibilityHidden(true)
            Text(text).font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(p.color(for: kind))
    }

    private var icon: String {
        switch kind {
        case .good: "checkmark.square.fill"
        case .warn: "exclamationmark.square.fill"
        case .bad: "xmark.square.fill"
        case .info: "info.square.fill"
        }
    }
}

/// Tiny bordered label: "lyrics added", "keep", "3 new".
struct Tag: View {
    let text: String
    var kind: Kind = .info
    @Environment(\.palette) private var p

    var body: some View {
        Text(text)
            .font(.pixel(12))
            .lineLimit(1)
            .foregroundStyle(kind == .info ? p.ink : p.color(for: kind))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .pixelFrame(fill: p.card, border: kind == .info ? p.line : p.color(for: kind), width: 2)
    }
}

/// Big pixel number with a caption under it.
struct Stat: View {
    let value: String
    let caption: String
    var kind: Kind?
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.pixel(28, bold: true))
                .foregroundStyle(kind.map { p.color(for: $0) } ?? p.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.system(size: 13)).foregroundStyle(p.inkSoft)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A list row; the selected one is a solid ink bar with a ">" marker,
/// like a menu on the player itself.
struct ListRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder var content: Content
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 6) {
            Text(">").font(.pixel(14, bold: true)).opacity(selected ? 1 : 0)
                .accessibilityHidden(true)
            content
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(selected ? p.card : p.ink)
        .background(selected ? p.ink : Color.clear)
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Centered message for a screen with nothing to show yet.
struct EmptyState: View {
    let title: String
    let message: String
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.pixel(22, bold: true))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(p.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: 420)
        .foregroundStyle(p.ink)
        .pixelFrame(fill: p.card, border: p.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
