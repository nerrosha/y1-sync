import SwiftUI

/// "You can undo the last tidy" — shown until the next destructive run.
struct UndoBanner: View {
    let title: String
    let detail: String
    let onUndo: () -> Void
    let onDiscard: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.square.fill")
                .font(.system(size: 18))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.pixel(15, bold: true))
                Text(detail).font(.system(size: 12)).foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Discard", action: onDiscard)
                .buttonStyle(PixelButtonStyle(compact: true))
            Button("Undo", action: onUndo)
                .buttonStyle(PixelButtonStyle(compact: true))
                .keyboardShortcut("z", modifiers: .command)
        }
        .padding(14)
        .foregroundStyle(p.ink)
        .pixelFrame(fill: p.card, border: p.ink)
    }
}

/// Pixel confirmation box that replaces the system dialog. Return confirms,
/// Esc or a click outside cancels.
private struct PixelConfirm: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    let confirmTitle: String
    let onConfirm: () -> Void
    @Environment(\.palette) private var p

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack {
                    p.paper.opacity(0.75)
                        .ignoresSafeArea()
                        .onTapGesture { isPresented = false }
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 14) {
                        Text(title).font(.pixel(20, bold: true))
                        Text(message).font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("Cancel") { isPresented = false }
                                .buttonStyle(PixelButtonStyle())
                                .keyboardShortcut(.cancelAction)
                            Button(confirmTitle) {
                                isPresented = false
                                onConfirm()
                            }
                            .buttonStyle(PixelButtonStyle(kind: .primary))
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 440)
                    .foregroundStyle(p.ink)
                    .pixelFrame(fill: p.card, border: p.ink)
                    .onAppear { UISound.open.play() }
                }
            }
        }
    }
}

extension View {
    func pixelConfirm(isPresented: Binding<Bool>, title: String, message: String,
                      confirmTitle: String, onConfirm: @escaping () -> Void) -> some View {
        modifier(PixelConfirm(isPresented: isPresented, title: title, message: message,
                              confirmTitle: confirmTitle, onConfirm: onConfirm))
    }
}
