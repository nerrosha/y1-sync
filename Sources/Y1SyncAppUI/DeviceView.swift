import SwiftUI
import AppKit
import Y1SyncCore

/// Operations on the player itself: tidy names, clear junk, add lyrics and art,
/// build smart playlists.
struct DeviceView: View {
    @Bindable var model: DeviceModel
    let device: Device?

    @State private var confirmTidy = false
    @State private var confirmForget = false
    @State private var confirmRepair = false
    @State private var confirmRemoveBroken = false
    // Remembered between launches.
    @AppStorage("deviceWantLyrics") private var wantLyrics = true
    @AppStorage("deviceWantCovers") private var wantCovers = true
    @AppStorage("playlistsMood") private var wantMoodPlaylists = true
    @AppStorage("playlistsTempo") private var wantTempoPlaylists = true
    @AppStorage("playlistsGenre") private var wantGenrePlaylists = true

    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: Pixel.gap) {
            header

            if let session = model.undoSession {
                UndoBanner(
                    title: "You can undo the last \(session.label) (\(countLabel(session.entries.count, "change"))).",
                    detail: "Only this most recent operation can be restored — running another "
                        + "tidy or cleanup permanently drops it.",
                    onUndo: {
                        Task {
                            let outcome = await model.undoLastOperation()
                            model.status = "Restored \(countLabel(outcome?.restored ?? 0, "item"))."
                            if let failed = outcome?.failed, !failed.isEmpty {
                                model.status += " \(failed.count) could not be restored."
                                UISound.error.play()
                            } else {
                                UISound.success.play()
                            }
                        }
                    },
                    onDiscard: { confirmForget = true })
            }

            if model.hasScanned, let plan = model.tidyPlan {
                ScrollView {
                    HStack(alignment: .top, spacing: Pixel.gap) {
                        tidySection(plan)
                            .frame(maxWidth: .infinity)
                        VStack(spacing: Pixel.gap) {
                            healthSection
                            enrichSection
                            smartPlaylistsSection
                        }
                        .frame(width: 320)
                    }
                }
            } else if device == nil {
                EmptyState(title: "No player",
                           message: Wording.noPlayer + ". It shows up here by itself.")
            } else {
                EmptyState(title: "Nothing scanned yet",
                           message: "Reads what is already on it — nothing is changed until you "
                               + "confirm. Then tidy names, clear junk, add lyrics and covers.")
            }

            Spacer(minLength: 0)
            resultLine
        }
        // The confirm overlay only blocks clicks; this also stops ⌘R/⌘Z and Tab focus
        // from reaching the controls behind it (a rescan would swap the plan under it).
        .disabled(confirmTidy || confirmForget)
        .foregroundStyle(p.ink)
        .pixelConfirm(isPresented: $confirmTidy,
                      title: "Tidy the player",
                      message: tidyMessage,
                      confirmTitle: "Tidy") {
            UISound.confirm.play()
            Task {
                await model.applyTidy()
                UISound.success.play()
            }
        }
        .pixelConfirm(isPresented: $confirmForget,
                      title: "Discard undo history",
                      message: "Frees the space it was holding right away. This can't be undone.",
                      confirmTitle: "Discard") {
            model.forgetUndoSession()
        }
        .pixelConfirm(isPresented: $confirmRepair,
                      title: "Replace broken files",
                      message: "Each broken file moves to the undo quarantine and the intact copy from "
                          + "your library is copied in its place. Files without a replacement stay as they are.",
                      confirmTitle: "Replace") {
            UISound.confirm.play()
            Task { await model.fixBroken(removeUnrepairable: false); UISound.success.play() }
        }
        .pixelConfirm(isPresented: $confirmRemoveBroken,
                      title: "Remove broken files",
                      message: "Broken files with no intact copy in your library move to the undo quarantine, "
                          + "so they stop showing up as tracks that don't play. Undo brings them back "
                          + "until the next tidy or cleanup.",
                      confirmTitle: "Remove") {
            UISound.confirm.play()
            Task { await model.fixBroken(removeUnrepairable: true); UISound.success.play() }
        }
        .onChange(of: model.removeJunk) { AppSettings.removeJunk = model.removeJunk }
    }

    private var tidyMessage: String {
        guard let plan = model.tidyPlan else { return "" }
        return "Rename \(countLabel(plan.moves.count, "file"))? Files are moved, never overwritten — any "
            + "collision is reported instead. \(countLabel(plan.leftoverFolders.count, "leftover folder")) "
            + "with no audio are removed after salvaging any cover art. You can undo this "
            + "from the banner until the next tidy or cleanup."
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Device")
                .font(.pixel(18, bold: true))
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            if model.hasScanned {
                Tag(text: countLabel(model.tracks.count, "track"))
            }
            Text(device?.displayLabel ?? "No player")
                .font(.system(size: 12))
                .foregroundStyle(p.inkSoft)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                guard let device else { return }
                UISound.cursor.play()
                Task { await model.scan(deviceRoot: device.url) }
            } label: {
                Label(model.hasScanned ? "Rescan" : "Scan player", systemImage: "magnifyingglass")
            }
            .buttonStyle(PixelButtonStyle(kind: model.hasScanned || confirmForget ? .normal : .primary))
            .fixedSize()
            .disabled(device == nil || model.isBusy)
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    // MARK: - Tidy

    private func tidySection(_ plan: TidyPlan) -> some View {
        PixelBox(title: "Tidy") {
            Text("The player shows filenames, not tags — so renaming into one consistent "
                 + "Artist/Album/NN Title scheme changes what you see while browsing.")
                .font(.system(size: 12))
                .foregroundStyle(p.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                Stat(value: "\(plan.moves.count)", caption: "to rename")
                Stat(value: "\(plan.junk.count)", caption: "junk files")
                Stat(value: ByteFormat.string(plan.junkBytes), caption: "reclaims", kind: .good)
                Stat(value: "\(plan.emptyDirectories.count)", caption: "empty folders")
                Stat(value: "\(plan.leftoverFolders.count)", caption: "leftovers")
            }

            if !plan.leftoverFolders.isEmpty {
                Text("Leftovers are pre-tidy folders whose tracks have all moved out, leaving "
                     + "only a cover or rip log — any cover art is copied to the new album folder first.")
                    .font(.system(size: 11))
                    .foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PixelToggle("Also remove hidden macOS files (._*, .DS_Store)", isOn: $model.removeJunk)
                .help("macOS creates these when writing to the player. They are invisible on "
                      + "your Mac but the player lists them.")

            if !plan.moves.isEmpty {
                preview("Preview renames (\(plan.moves.count))", plan.moves.prefix(200).map(\.describe))
            }
            if !plan.junk.isEmpty {
                preview("Preview junk files (\(plan.junk.count))", plan.junk.prefix(200).map(\.path))
            }

            HStack(spacing: 12) {
                Button {
                    UISound.open.play()
                    confirmTidy = true
                } label: {
                    Label("Tidy the player", systemImage: "wand.and.stars")
                }
                // Only one primary at a time: the open dialog owns it.
                .buttonStyle(PixelButtonStyle(kind: confirmTidy || confirmForget ? .normal : .primary))
                .fixedSize()
                .disabled(plan.isEmpty || model.isBusy)

                Text("Music is only ever moved, never overwritten.")
                    .font(.system(size: 11))
                    .foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
    }

    private func preview(_ title: String, _ lines: [String]) -> some View {
        DisclosureGroup {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 160)
            .pixelFrame(fill: p.paper, border: p.line, width: 2)
        } label: {
            Text(title).font(.pixel(15, bold: true)).lineLimit(1)
        }
        .tint(p.ink)
    }

    // MARK: - Health

    private var healthSection: some View {
        PixelBox(title: "Broken files") {
            Text("Plays the start and the end of every file on the player, so cut-off copies "
                 + "show up too. Nothing is changed until you choose.")
                .font(.system(size: 12))
                .foregroundStyle(p.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            if let broken = model.brokenFiles {
                if broken.isEmpty {
                    Notice(kind: .good, text: "All files play fine.")
                } else {
                    let fixable = broken.filter { $0.replacement != nil }.count
                    Notice(kind: .bad, text: "\(countLabel(broken.count, "broken file")); "
                           + "\(fixable) can be replaced from your library.")
                    if model.libraryTracks.isEmpty {
                        Text("Scan the music folder on the Sync tab first to find replacements.")
                            .font(.system(size: 11)).foregroundStyle(p.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(broken) { b in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(b.devicePath).font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(b.reasons.joined(separator: "; ") + (b.replacement == nil
                                         ? "" : " — replacement found"))
                                        .font(.system(size: 11)).foregroundStyle(p.inkSoft)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                    .pixelFrame(fill: p.paper, border: p.line, width: 2)
                }
            }

            HStack(spacing: 10) {
                Button(model.brokenFiles == nil ? "Check files" : "Check again") {
                    UISound.cursor.play()
                    Task { await model.checkHealth() }
                }
                .buttonStyle(PixelButtonStyle(compact: true)).fixedSize()
                .disabled(model.isBusy)

                if let broken = model.brokenFiles, !broken.isEmpty {
                    if broken.contains(where: { $0.replacement != nil }) {
                        Button("Replace") { confirmRepair = true }
                            .buttonStyle(PixelButtonStyle(compact: true)).fixedSize()
                            .disabled(model.isBusy)
                    }
                    if broken.contains(where: { $0.replacement == nil }) {
                        Button("Remove the rest") { confirmRemoveBroken = true }
                            .buttonStyle(PixelButtonStyle(compact: true)).fixedSize()
                            .disabled(model.isBusy)
                    }
                }
            }
        }
    }

    // MARK: - Enrich

    private var enrichSection: some View {
        PixelBox(title: "Lyrics + covers") {
            Text("Looks up the \(countLabel(model.tracks.count, "track")) on the player. Sends artist, album "
                 + "and track names to LRCLIB and MusicBrainz.")
                .font(.system(size: 12))
                .foregroundStyle(p.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                PixelToggle("Synced lyrics", isOn: $wantLyrics)
                PixelToggle("Missing covers", isOn: $wantCovers)
            }

            HStack(spacing: 12) {
                Button("Fetch") {
                    UISound.confirm.play()
                    Task {
                        await model.enrich(lyrics: wantLyrics, covers: wantCovers)
                        UISound.success.play()
                    }
                }
                .buttonStyle(PixelButtonStyle())
                .fixedSize()
                .disabled(model.isBusy || (!wantLyrics && !wantCovers))
                Text("Existing lyrics are never overwritten.")
                    .font(.system(size: 11)).foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Smart playlists

    private var smartPlaylistsSection: some View {
        PixelBox(title: "Smart playlists") {
            Text("Builds playlists from mood, tempo and genre tags already on the files — no "
                 + "network, and a track without the tag is just skipped.")
                .font(.system(size: 12))
                .foregroundStyle(p.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                PixelToggle("Mood", isOn: $wantMoodPlaylists)
                PixelToggle("Tempo", isOn: $wantTempoPlaylists)
                PixelToggle("Genre", isOn: $wantGenrePlaylists)
            }

            HStack(spacing: 12) {
                Button("Build") {
                    UISound.confirm.play()
                    Task {
                        await model.buildSmartPlaylists(
                            moods: wantMoodPlaylists, bpm: wantTempoPlaylists, genres: wantGenrePlaylists)
                    }
                }
                .buttonStyle(PixelButtonStyle())
                .fixedSize()
                .disabled(model.isBusy
                          || (!wantMoodPlaylists && !wantTempoPlaylists && !wantGenrePlaylists))
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Result

    /// Outcome of the last operation. Live progress is in the global status bar.
    @ViewBuilder
    private var resultLine: some View {
        if !model.isBusy && !model.status.isEmpty {
            Notice(kind: outcomeKind(model.status), text: model.status)
        }
    }

    /// Failures and "nothing found" read as a warning, not as neutral info.
    private func outcomeKind(_ status: String) -> Kind {
        status.contains("could not be") || status.hasPrefix("No ") ? .warn : .info
    }
}

struct DeviceView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            planReady.previewDisplayName("Plan ready")
            DeviceView(model: DeviceModel(), device: nil)
                .previewDisplayName("No player connected")
        }
        .padding(20)
        .frame(width: 900, height: 620)
        .background(Palette.day.paper)
        .themed()
    }

    private static var planReady: some View {
        let model = DeviceModel()
        model.tracks = [PreviewData.track("Airbag")]
        model.tidyPlan = PreviewData.tidyPlan
        return DeviceView(model: model, device: PreviewData.device)
    }
}
