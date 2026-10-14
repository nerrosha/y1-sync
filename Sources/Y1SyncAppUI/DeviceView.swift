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
    @State private var chosenAlbum: [String: String] = [:]
    @State private var pendingMerge: SimilarAlbumGroup?
    @State private var chosenArtist: [String: String] = [:]
    @State private var pendingArtistMerge: SimilarArtistGroup?
    @State private var confirmRemoveBroken = false
    // Remembered between launches.
    @AppStorage("deviceWantLyrics") private var wantLyrics = true
    @AppStorage("deviceWantCovers") private var wantCovers = true
    @AppStorage("playlistsMood") private var wantMoodPlaylists = true
    @AppStorage("playlistsTempo") private var wantTempoPlaylists = true
    @AppStorage("playlistsGenre") private var wantGenrePlaylists = true

    @State private var section: Section = .fix
    @Environment(\.palette) private var p

    private enum Section: Hashable { case fix, listening, extras }
    @State private var freeTargetGB = 20
    @State private var confirmFree = false

    /// Things on the player that want attention, for the Fix tab's badge.
    private func issueCount(_ plan: TidyPlan) -> Int {
        (plan.moves.isEmpty ? 0 : 1) + (plan.junk.isEmpty ? 0 : 1)
            + model.similarArtists.count + model.similarAlbums.count + (model.brokenFiles?.count ?? 0)
            + ((model.playerList?.isInSync ?? true) ? 0 : 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Pixel.gap) {
            header

            if let session = model.undoSession {
                UndoBanner(
                    title: "You can undo the last \(session.label) (\(countLabel(session.entries.count, "change"))).",
                    detail: "Only the latest operation can be undone; the next one replaces it.",
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
                PixelTabBar(tabs: [PixelTab(id: Section.fix, title: "Fix", badge: issueCount(plan)),
                                   PixelTab(id: Section.listening, title: "Listening"),
                                   PixelTab(id: Section.extras, title: "Extras")],
                            selection: $section, shortcuts: false)
                ScrollView {
                    VStack(spacing: Pixel.gap) {
                        switch section {
                        case .fix:
                            tidySection(plan)
                            songListSection
                            similarArtistsSection
                            similarAlbumsSection
                            mergeRulesSection
                            healthSection
                            formatsSection
                        case .listening:
                            listeningSections
                        case .extras:
                            enrichSection
                            smartPlaylistsSection
                        }
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
                }
            } else if device == nil {
                EmptyState(title: "No player",
                           message: Wording.noPlayer + ". It shows up here by itself.")
            } else if model.isBusy {
                EmptyState(title: "Reading the player…",
                           message: "Reading every file's tags takes a minute on a full card. "
                               + "Nothing is changed.")
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
        .disabled(confirmTidy || confirmForget || confirmFree)
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
        .pixelConfirm(isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
                      title: "Merge albums",
                      message: "Sets the album name of \(pendingMerge.map { countLabel($0.trackCount, "song") } ?? "") to "
                          + "“\(pendingMerge.map { chosenAlbum[$0.id] ?? $0.suggested } ?? "")”. Only the tag changes, the audio "
                          + "is untouched, and Undo puts every old name back.",
                      confirmTitle: "Merge") {
            guard let group = pendingMerge else { return }
            UISound.confirm.play()
            let title = chosenAlbum[group.id] ?? group.suggested
            Task { await model.mergeAlbums(group, into: title); UISound.success.play() }
        }
        .pixelConfirm(isPresented: Binding(get: { pendingArtistMerge != nil }, set: { if !$0 { pendingArtistMerge = nil } }),
                      title: "Merge artists",
                      message: "Sets the artist of \(pendingArtistMerge.map { countLabel($0.trackCount, "song") } ?? "") to "
                          + "“\(pendingArtistMerge.map { chosenArtist[$0.id] ?? $0.suggested } ?? "")”. Only tags change, the "
                          + "audio is untouched, and Undo puts every old spelling back.",
                      confirmTitle: "Merge") {
            guard let group = pendingArtistMerge else { return }
            UISound.confirm.play()
            let name = chosenArtist[group.id] ?? group.suggested
            Task { await model.mergeArtists(group, into: name); UISound.success.play() }
        }
        .pixelConfirm(isPresented: $confirmFree,
                      title: "Free up space",
                      message: "Moves \(countLabel(model.removalPicks.count, "album")) "
                          + "(\(ByteFormat.string(model.removalBytes))) into the hidden undo folder on the player and "
                          + "stops sync from copying them back. Your library is not touched, and Undo on this "
                          + "tab brings everything back until the next cleanup.",
                      confirmTitle: "Remove") {
            UISound.confirm.play()
            Task {
                let r = await model.removePickedAlbums()
                model.status = "Removed \(countLabel(r.albums, "album")) (\(ByteFormat.string(r.freed))) from the player."
                    + (r.failed > 0 ? " \(r.failed) files could not be moved." : " Undo is above.")
                (r.failed > 0 ? UISound.error : UISound.success).play()
            }
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
                .font(.system(size: 13))
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
                .font(.system(size: 13))
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
                    .font(.system(size: 13))
                    .foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PixelToggle("Also remove hidden macOS files (._*, .DS_Store)", isOn: $model.removeJunk)
                .help("macOS creates these when writing to the player. They are invisible on "
                      + "your Mac but the player lists them.")

            if let pv = model.tidyPreview, !pv.blocked.isEmpty {
                Notice(kind: .warn,
                       text: "\(countLabel(pv.blocked.count, "rename")) will be skipped: a file with that "
                           + "name is already in the target folder, so the same song is on the player "
                           + "twice. Remove the extra copies in the Dupes tab first, then tidy.")
            }
            if let pv = model.tidyPreview, !pv.folders.isEmpty {
                preview("Preview by folder (\(pv.folders.count))", pv.folders.prefix(200).map {
                    "\($0.from)  →  \($0.to)  · \(countLabel($0.count, "file"))"
                        + ($0.blocked > 0 ? "  · \($0.blocked) skipped" : "")
                })
            }
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
                    .font(.system(size: 13))
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
                            .font(.system(size: 12, design: .monospaced))
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

    // MARK: - Player's song list

    @ViewBuilder
    private var songListSection: some View {
        if let list = model.playerList, !list.isInSync {
            PixelBox(title: "Player's song list") {
                Notice(kind: .warn, text: "\(countLabel(list.missing.count, "track")) on the card "
                       + "\(list.missing.count == 1 ? "is" : "are") not in the player's own song list, "
                       + "so \(list.missing.count == 1 ? "it doesn't" : "they don't") show up on the player"
                       + (list.stale.isEmpty ? "." : "; \(countLabel(list.stale.count, "entry", plural: "entries")) point to files that are gone."))
                Text("The player lists songs from its own saved list, not from the card. This adds "
                     + "the missing tracks to it (a backup of the list is kept). Your music is not touched.")
                    .font(.system(size: 13)).foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Update the list") {
                    UISound.confirm.play()
                    Task {
                        let note = await model.updatePlayerList()
                        model.status = note.isEmpty ? "The player's song list is already up to date." : note
                        UISound.success.play()
                    }
                }
                .buttonStyle(PixelButtonStyle(kind: .primary)).fixedSize()
                .disabled(model.isBusy)
            }
        }
    }

    // MARK: - Similar artists

    @ViewBuilder
    private var similarArtistsSection: some View {
        if !model.similarArtists.isEmpty {
            PixelBox(title: "Artists spelled twice") {
                Text("The player lists these as separate artists (and the card has a folder for each), "
                     + "but the name is the same apart from “The” or capital letters. Pick the spelling "
                     + "to keep; only the artist tags change.")
                    .font(.system(size: 13)).foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.similarArtists) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(group.variants) { v in
                            let chosen = (chosenArtist[group.id] ?? group.suggested) == v.name
                            Button { chosenArtist[group.id] = v.name; UISound.cursor.play() } label: {
                                ListRow(selected: chosen) {
                                    Text(v.name).font(.system(size: 13)).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(countLabel(v.tracks.count, "song")).font(.system(size: 13)).opacity(0.8)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(v.name), \(countLabel(v.tracks.count, "song"))")
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                        Button("Merge into “\(chosenArtist[group.id] ?? group.suggested)”") {
                            pendingArtistMerge = group
                        }
                        .buttonStyle(PixelButtonStyle(compact: true)).fixedSize()
                        .disabled(model.isBusy)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Similar albums

    @ViewBuilder
    private var similarAlbumsSection: some View {
        if !model.similarAlbums.isEmpty {
            PixelBox(title: "Albums split in two") {
                Text("These show up on the player as separate albums, but the songs are the same — "
                     + "a typo in the album name, an extra edition, or a song downloaded on its own. "
                     + "Pick the name to keep; only the album tag changes.")
                    .font(.system(size: 13)).foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.similarAlbums) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.albumArtist).font(.pixel(14, bold: true)).lineLimit(1)
                        ForEach(group.variants) { v in
                            let chosen = (chosenAlbum[group.id] ?? group.suggested) == v.title
                            Button { chosenAlbum[group.id] = v.title; UISound.cursor.play() } label: {
                                ListRow(selected: chosen) {
                                    Text(v.title).font(.system(size: 13)).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(countLabel(v.tracks.count, "song")).font(.system(size: 13)).opacity(0.8)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(v.title), \(countLabel(v.tracks.count, "song"))")
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                        if group.sharedSongs > 0 {
                            Text("\(countLabel(group.sharedSongs, "song")) exist in more than one — they will show as duplicates afterwards.")
                                .font(.system(size: 13)).foregroundStyle(p.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Merge into “\(chosenAlbum[group.id] ?? group.suggested)”") {
                            pendingMerge = group
                        }
                        .buttonStyle(PixelButtonStyle(compact: true)).fixedSize()
                        .disabled(model.isBusy)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Listening

    @ViewBuilder
    private var listeningSections: some View {
        if let stats = model.stats, stats.plays > 0 {
            statsBox(stats)
            rankBox("Most played artists", stats.topArtists.prefix(10).map { ($0.name, "", $0.plays) })
            rankBox("Most played albums", stats.topAlbums.prefix(10).map { ($0.name, $0.detail, $0.plays) })
            freeUpBox(stats)
        } else {
            PixelBox(title: "Listening") {
                Text("The player keeps a log of what you play (`.scrobbler.log`), but it is empty or missing. "
                     + "Listen to some music and scan again.")
                    .font(.system(size: 13)).foregroundStyle(p.inkSoft)
            }
        }
    }

    private func statsBox(_ stats: ListeningStats) -> some View {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        let hours = Double(stats.seconds) / 3600
        let never = stats.albums.filter { $0.plays == 0 }.count
        return PixelBox(title: "What you listen to") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], alignment: .leading, spacing: 12) {
                Stat(value: "\(stats.plays)", caption: "plays")
                Stat(value: String(format: "%.1f h", hours), caption: "listened")
                Stat(value: "\(stats.albums.count - never)/\(stats.albums.count)", caption: "albums played")
                Stat(value: "\(never)", caption: "never played", kind: never > 0 ? .warn : nil)
            }
            if let first = stats.first, let last = stats.last {
                Text("From the player's own log, \(df.string(from: first)) – \(df.string(from: last)). "
                     + "Anything played before the log started is not counted.")
                    .font(.system(size: 13)).foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rankBox(_ title: String, _ rows: [(String, String, Int)]) -> some View {
        let top = max(rows.map(\.2).max() ?? 1, 1)
        return PixelBox(title: title) {
            VStack(spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 10) {
                        Text(r.1.isEmpty ? r.0 : "\(r.0) — \(r.1)")
                            .font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        PixelProgress(value: Double(r.2) / Double(top)).frame(width: 140)
                        Text("\(r.2)").font(.system(size: 13, weight: .semibold))
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func freeUpBox(_ stats: ListeningStats) -> some View {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        let shown = Array(stats.leastListened(freeing: .max).prefix(60))
        return PixelBox(title: "Free up space") {
            Text("Albums are listed from the least listened to: never played first, then the ones "
                 + "not touched for longest. Pick how much to free, tick or untick, then remove. "
                 + "Removed albums go to the undo folder and sync will not copy them back.")
                .font(.system(size: 13)).foregroundStyle(p.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Menu {
                    ForEach([5, 10, 20, 50, 100], id: \.self) { gb in
                        Button("Free \(gb) GB") { freeTargetGB = gb }
                    }
                } label: { Text("Free \(freeTargetGB) GB") }
                    .menuStyle(.button).buttonStyle(PixelButtonStyle(compact: true)).fixedSize()
                Button("Pick the least listened") {
                    model.pickLeastListened(freeing: Int64(freeTargetGB) * 1_000_000_000)
                    UISound.cursor.play()
                }
                .buttonStyle(PixelButtonStyle(compact: true)).fixedSize()
                if !model.removalPicks.isEmpty {
                    Button("Clear") { model.removalPicks = [] }
                        .buttonStyle(PixelButtonStyle(compact: true)).fixedSize()
                }
                Spacer(minLength: 0)
            }

            VStack(spacing: 4) {
                ForEach(shown) { a in
                    let on = model.removalPicks.contains(a.id)
                    PixelCheckbox(state: on ? .on : .off, label: "\(a.artist) — \(a.title)") {
                        if on { model.removalPicks.remove(a.id) } else { model.removalPicks.insert(a.id) }
                    }
                    .overlay(alignment: .trailing) {
                        Text(a.plays == 0 ? "never played" : "\(a.plays) plays · " + (a.lastPlayed.map { df.string(from: $0) } ?? ""))
                            .font(.system(size: 12)).foregroundStyle(a.plays == 0 ? p.warn : p.inkSoft)
                            .padding(.trailing, 90)
                    }
                    .overlay(alignment: .trailing) {
                        Text(ByteFormat.string(a.bytes)).font(.system(size: 12)).foregroundStyle(p.inkSoft)
                    }
                }
                if stats.albums.count > shown.count {
                    Text("… and \(stats.albums.count - shown.count) more albums, played more")
                        .font(.system(size: 12)).foregroundStyle(p.inkSoft)
                }
            }

            HStack(spacing: 12) {
                Button {
                    UISound.open.play()
                    confirmFree = true
                } label: {
                    Label("Remove \(countLabel(model.removalPicks.count, "album"))", systemImage: "trash")
                }
                .buttonStyle(PixelButtonStyle(kind: confirmFree ? .normal : .primary))
                .fixedSize()
                .disabled(model.removalPicks.isEmpty || model.isBusy)
                Text(model.removalPicks.isEmpty ? "Nothing ticked." : "Frees " + ByteFormat.string(model.removalBytes) + ".")
                    .font(.system(size: 13)).foregroundStyle(p.inkSoft)
            }
        }
    }

    // MARK: - Remembered merges

    @ViewBuilder
    private var mergeRulesSection: some View {
        if !model.mergeRules.isEmpty || !model.suggestedRules.isEmpty {
            PixelBox(title: "Remembered merges") {
                Text("Your merges are repeated on every sync: files are renamed as they are copied, "
                     + "so the old spellings in your library do not come back. The library itself is "
                     + "never changed.")
                    .font(.system(size: 13)).foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.suggestedRules.isEmpty {
                    Notice(kind: .warn, text: "Your library spells \(countLabel(model.suggestedRules.count, "name")) "
                           + "differently from the player. Remember them, or the next sync copies the old "
                           + "spelling back and splits the album again.")
                    ForEach(model.suggestedRules) { rule in
                        HStack(spacing: 8) {
                            Tag(text: rule.kind == .album ? "album" : "artist", kind: .warn)
                            Text("“\(rule.from)”  →  “\(rule.to)”")
                                .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            Button("Remember") {
                                model.mergeRules = MergeRules.adding([rule], to: model.mergeRules)
                                UISound.cursor.play()
                            }
                            .buttonStyle(PixelButtonStyle(compact: true)).fixedSize()
                        }
                    }
                    if model.suggestedRules.count > 1 {
                        Button("Remember all") {
                            model.mergeRules = MergeRules.adding(model.suggestedRules, to: model.mergeRules)
                            UISound.success.play()
                        }
                        .buttonStyle(PixelButtonStyle(compact: true)).fixedSize()
                    }
                }
                ForEach(model.mergeRules) { rule in
                    HStack(spacing: 8) {
                        Tag(text: rule.kind == .album ? "album" : "artist")
                        Text("“\(rule.from)”  →  “\(rule.to)”")
                            .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Button("Forget") {
                            model.mergeRules.removeAll { $0.id == rule.id }
                            UISound.cursor.play()
                        }
                        .buttonStyle(PixelButtonStyle(compact: true)).fixedSize()
                        .help("Stop applying this merge on sync")
                    }
                }
            }
        }
    }

    // MARK: - Formats

    private var formatsSection: some View {
        let flagged = model.tracks.filter { model.limits.problem(for: $0) != nil }.count
        return PixelBox(title: "Formats on the player") {
            Text("Which formats and qualities are on the player. If some files will not play, "
                 + "set the highest quality it handles: files above it are flagged under "
                 + "Broken files, replaced from your library when a copy within the limit exists, "
                 + "and skipped on sync. Nothing is converted.")
                .font(.system(size: 13)).foregroundStyle(p.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            let summary = PlayerLimits.summary(of: model.tracks)
            VStack(spacing: 4) {
                ForEach(Array(summary.prefix(8)), id: \.label) { row in
                    ListRow(selected: false) {
                        Text(row.label).font(.system(size: 13))
                        Spacer(minLength: 6)
                        Text(countLabel(row.count, "song")).font(.system(size: 13)).opacity(0.8)
                    }
                }
                if summary.count > 8 {
                    Text("… and \(summary.count - 8) more formats")
                        .font(.system(size: 12)).foregroundStyle(p.inkSoft)
                }
            }

            HStack(spacing: 12) {
                Menu {
                    Button("No limit") { model.limits.maxSampleRate = nil }
                    ForEach([44_100, 48_000, 96_000, 192_000], id: \.self) { hz in
                        Button("Up to \(PlayerLimits.kHz(hz))") { model.limits.maxSampleRate = hz }
                    }
                } label: {
                    Text("Sample rate: " + (model.limits.maxSampleRate.map { "≤ " + PlayerLimits.kHz($0) } ?? "any"))
                }
                .menuStyle(.button).buttonStyle(PixelButtonStyle(compact: true)).fixedSize()

                Menu {
                    Button("No limit") { model.limits.maxBitDepth = nil }
                    ForEach([16, 24], id: \.self) { b in
                        Button("Up to \(b)-bit") { model.limits.maxBitDepth = b }
                    }
                } label: {
                    Text("Bit depth: " + (model.limits.maxBitDepth.map { "≤ \($0)" } ?? "any"))
                }
                .menuStyle(.button).buttonStyle(PixelButtonStyle(compact: true)).fixedSize()

                PixelToggle("Allow ALAC", isOn: $model.limits.allowALAC).fixedSize()
                Spacer(minLength: 0)
            }

            if flagged > 0 {
                Notice(kind: .warn, text: "\(countLabel(flagged, "song")) above these limits. "
                       + "Press “Check files” to see them and replace what can be replaced.")
            } else if !model.limits.isUnlimited {
                Notice(kind: .good, text: "Everything on the player is within these limits.")
            }
        }
    }

    // MARK: - Health

    private var healthSection: some View {
        PixelBox(title: "Broken files") {
            Text("Plays the start and the end of every file on the player, so cut-off copies "
                 + "show up too. Nothing is changed until you choose.")
                .font(.system(size: 13))
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
                            .font(.system(size: 13)).foregroundStyle(p.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(broken) { b in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(b.devicePath).font(.system(size: 13, design: .monospaced))
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(b.reasons.joined(separator: "; ") + (b.replacement == nil
                                         ? "" : " — replacement found"))
                                        .font(.system(size: 13)).foregroundStyle(p.inkSoft)
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
                .font(.system(size: 13))
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
                    .font(.system(size: 13)).foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Smart playlists

    private var smartPlaylistsSection: some View {
        PixelBox(title: "Smart playlists") {
            Text("Builds playlists from mood, tempo and genre tags already on the files — no "
                 + "network, and a track without the tag is just skipped.")
                .font(.system(size: 13))
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
