import SwiftUI
import Y1SyncCore

/// Shows what the sync did, and lets you play the files straight off the
/// device to confirm the artwork and lyrics actually landed.
struct ResultsView: View {
    let changes: [FileChange]
    let skipped: [TrackReport]
    let deviceRoot: URL

    @State private var player = PlayerModel()
    @State private var selection: FileChange.ID?
    @FocusState private var listFocused: Bool

    @Environment(\.palette) private var p

    private var selected: FileChange? {
        changes.first { $0.id == selection }
    }

    private var improvedCount: Int {
        changes.filter(\.didAnything).count
    }

    var body: some View {
        HStack(alignment: .top, spacing: Pixel.gap) {
            list
                .frame(width: 330)
                .frame(maxHeight: .infinity, alignment: .top)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: selection) { _, new in
            guard let change = changes.first(where: { $0.id == new }) else { return }
            UISound.cursor.play()
            player.load(deviceURL(for: change))
        }
        .onDisappear { player.stop() }
    }

    // MARK: - List

    private var list: some View {
        PixelBox(title: "Copied") {
            Text(countLabel(changes.count, "file")).font(.pixel(13)).lineLimit(1)
            if improvedCount > 0 {
                Tag(text: "\(improvedCount) improved", kind: .good)
            }
        } content: {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(changes) { change in
                            Button { selection = change.id } label: {
                                ListRow(selected: change.id == selection) {
                                    row(change, selected: change.id == selection)
                                }
                            }
                            .buttonStyle(.plain)
                            .id(change.id)
                        }

                        // Skipped files were previously only counted; naming
                        // them is the only way to know what to go and fix.
                        if !skipped.isEmpty {
                            skippedSection
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .onChange(of: selection) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
            // Arrow keys move through the list, like the player's own menu.
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onMoveCommand(perform: move)
        }
        .onAppear { listFocused = true }
    }

    @ViewBuilder
    private var skippedSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.square.fill")
                .font(.system(size: 12, weight: .bold))
                .accessibilityHidden(true)
            Text("Skipped — won't play")
                .font(.pixel(14, bold: true))
                .lineLimit(1)
        }
        .foregroundStyle(p.bad)
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 8)
        .padding(.top, 12).padding(.bottom, 4)

        ForEach(skipped, id: \.track.sourceURL) { report in
            VStack(alignment: .leading, spacing: 2) {
                Text(report.track.sourceURL.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.ink)
                    .lineLimit(1)
                ForEach(report.issues.filter(\.isBlocking), id: \.self) { issue in
                    Text(issue.describe).font(.system(size: 11))
                        .foregroundStyle(p.inkSoft).lineLimit(2)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    /// Text inherits the row's foreground so it stays readable on the ink bar;
    /// the secondary line uses inkSoft only when the row is not selected.
    private func row(_ change: FileChange, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(change.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text("\(change.artist) — \(change.album)")
                .font(.system(size: 11)).lineLimit(1)
                .foregroundStyle(selected ? p.card : p.inkSoft)
            if change.didAnything {
                // The point of the whole app: what got fixed.
                FlowLayout(spacing: 4) {
                    ForEach(change.summary, id: \.self) { tag in
                        Tag(text: tag, kind: .good)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func move(_ direction: MoveCommandDirection) {
        guard !changes.isEmpty else { return }
        let index = changes.firstIndex { $0.id == selection }
        switch direction {
        case .down: selection = changes[min((index ?? -1) + 1, changes.count - 1)].id
        case .up: selection = changes[max((index ?? 1) - 1, 0)].id
        default: break
        }
    }

    private func deviceURL(for change: FileChange) -> URL {
        deviceRoot.appendingPathComponent(
            change.devicePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let change = selected {
            PixelBox(title: "Now playing") {
                Text(URL(fileURLWithPath: change.devicePath).lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(p.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } content: {
                HStack(alignment: .top, spacing: 12) {
                    artworkView
                    VStack(alignment: .leading, spacing: 6) {
                        field("Artist", change.artist)
                        field("Title", change.title)
                        field("Album", change.album)
                        HStack(spacing: 6) {
                            if let size = player.artworkSize {
                                Tag(text: "cover \(size)", kind: .info)
                            }
                            if let from = change.artFrom, change.artTo != nil {
                                Tag(text: "was \(from), −\(ByteFormat.string(change.artBytesSaved))",
                                    kind: .good)
                            }
                        }
                    }
                }

                transport

                if let error = player.loadError {
                    Notice(kind: .bad, text: error)
                }

                lyricsView
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            EmptyState(title: "No track selected",
                       message: "Select a file on the left to play it straight off the player "
                           + "and check its artwork and lyrics. ↑ ↓ move through the list.")
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label + ":").font(.pixel(13)).lineLimit(1)
                .frame(width: 52, alignment: .trailing)
            PixelField {
                Text(value).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private var artworkView: some View {
        Group {
            if let image = player.artwork {
                Image(nsImage: image)
                    .resizable().interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    p.paper
                    Image(systemName: "music.note").font(.system(size: 30))
                        .foregroundStyle(p.inkSoft)
                }
            }
        }
        .frame(width: 128, height: 128)
        .clipped()
        .padding(Pixel.unit)
        .pixelFrame(fill: p.card, border: p.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(player.artwork == nil ? "No cover art" : "Cover art")
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Button { player.seek(to: player.currentTime - 10) } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(PixelButtonStyle(compact: true))
            .accessibilityLabel("Back 10 seconds")

            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(PixelButtonStyle(compact: true))
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button { player.seek(to: player.currentTime + 10) } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(PixelButtonStyle(compact: true))
            .accessibilityLabel("Forward 10 seconds")

            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 0.01))
                .tint(p.accent)
                .accessibilityLabel("Position")

            Text("\(PlayerModel.timeString(player.currentTime)) / \(PlayerModel.timeString(player.duration))")
                .font(.pixel(13))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .disabled(player.duration == 0)
    }

    @ViewBuilder
    private var lyricsView: some View {
        if player.hasLyrics {
            // Auto-scrolling highlighted lyrics are the clearest proof the
            // .lrc timings line up with the audio — the active line is the
            // same ink bar as a selected list row.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(player.lyrics) { line in
                            let active = line.index == player.activeLyricIndex
                            ListRow(selected: active) {
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                            }
                            .id(line.index)
                            .onTapGesture { player.seek(to: line.time) }
                            .accessibilityAddTraits(.isButton)
                        }
                    }
                }
                .padding(Pixel.unit * 2)
                .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity, alignment: .top)
                .pixelFrame(fill: p.card, border: p.ink)
                .onChange(of: player.activeLyricIndex) { _, index in
                    guard let index else { return }
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        } else {
            Notice(kind: .info, text: "No lyrics file for this track")
        }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct ResultsView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ResultsView(changes: PreviewData.changes,
                        skipped: PreviewData.skippedReports,
                        deviceRoot: PreviewData.deviceRoot)
                .previewDisplayName("With fixes and a skipped file")
            ResultsView(changes: [PreviewData.changes[0]], skipped: [],
                        deviceRoot: PreviewData.deviceRoot)
                .previewDisplayName("Nothing selected")
        }
        .padding(20)
        .frame(width: 900, height: 560)
        .background(Palette.day.paper)
        .themed()
    }
}
