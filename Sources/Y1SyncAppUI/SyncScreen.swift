import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Y1SyncCore

/// Sync tab: three numbered boxes — 1 Player, 2 Music, 3 Copy — so the order
/// is obvious without a wizard. The one primary button lives in box 3.
struct SyncScreen: View {
    @Bindable var model: AppModel
    @Binding var showAlbumPicker: Bool

    @State private var isDropTarget = false
    @State private var showFiles = true
    @Environment(\.palette) private var p

    var body: some View {
        HStack(alignment: .top, spacing: Pixel.gap) {
            VStack(spacing: Pixel.gap) {
                playerBox
                musicBox
                Spacer(minLength: 0)
            }
            .frame(width: 320)

            copyBox
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - 1 Player

    private var playerBox: some View {
        PixelBox(title: "Player", step: 1) {
            if model.devices.isEmpty {
                // The single most common reason a Y1 doesn't appear.
                Notice(kind: .warn,
                       text: Wording.noPlayer + ". It won't mount until you do.")
            } else {
                PixelField {
                    Menu {
                        ForEach(model.devices, id: \.url) { d in
                            Button(d.displayLabel) { model.choose(d) }
                        }
                    } label: {
                        Text(model.selectedDevice?.displayLabel ?? "Choose a player")
                            .font(.system(size: 14))
                            .foregroundStyle(p.ink)
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                }
            }

            if let notice = model.connectionNotice {
                // "… disconnected." is not a success.
                Notice(kind: model.selectedDevice == nil || notice.hasSuffix("disconnected.")
                           ? .warn : .good,
                       text: notice)
            }

            HStack(spacing: 12) {
                Button("Refresh") { model.refreshDevices() }
                    .buttonStyle(PixelButtonStyle(compact: true))
                    .fixedSize()
                PixelToggle("Compare on connect", isOn: $model.autoCompare)
                    .help("As soon as the player mounts, scan the music library and show "
                          + "what would be copied. Nothing is written until you press Sync.")
            }
        }
    }

    // MARK: - 2 Music

    private var musicBox: some View {
        PixelBox(title: "Music", step: 2) {
            VStack(spacing: 6) {
                Image(systemName: model.libraryFolder == nil ? "tray.and.arrow.down" : "folder.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isDropTarget ? p.accent : p.ink)
                    .accessibilityHidden(true)
                Text(model.libraryFolder?.lastPathComponent ?? "Drop a music folder here")
                    .font(.pixel(15, bold: true))
                    .lineLimit(1)
                if let folder = model.libraryFolder {
                    Text(folder.deletingLastPathComponent().path)
                        .font(.system(size: 13))
                        .foregroundStyle(p.inkSoft)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92)
            .pixelFrame(fill: isDropTarget ? p.paper : p.card,
                        border: isDropTarget ? p.accent : p.line, width: 2)
            .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { handleDrop($0) }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Drop a folder of music here")

            HStack(spacing: 12) {
                Button("Choose…") { chooseFolder() }
                    .buttonStyle(PixelButtonStyle())
                    .fixedSize()
                Spacer(minLength: 8)
                // The main "Scan and compare" button is in the Copy box; this
                // one appears once there is a result to refresh.
                if model.plan != nil {
                // Stays put while scanning (canScan is false then); the live
                // activity is in the status bar.
                Button {
                    UISound.cursor.play()
                    Task { await model.scanAndPlan() }
                } label: {
                    Label(model.plan == nil ? "Scan" : "Rescan", systemImage: "magnifyingglass")
                        .lineLimit(1)
                }
                .buttonStyle(PixelButtonStyle())
                .fixedSize()
                .disabled(!model.canScan || model.selectedDevice == nil)
                .keyboardShortcut("r", modifiers: .command)
                .help("Scan the music folder and compare it with the player — nothing is written")
                }
            }
        }
    }

    // MARK: - 3 Copy

    private var copyBox: some View {
        PixelBox(title: "Copy", step: 3) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.plan != nil {
                        summary
                    } else {
                        idle
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6).padding(.bottom, 4)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)

            Rectangle().fill(p.line).frame(height: 2)
                .accessibilityHidden(true)

            options
            action
        }
    }

    // MARK: Idle

    @ViewBuilder
    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            checklistRow(done: model.selectedDevice != nil,
                         text: model.selectedDevice != nil ? "Player connected" : "Connect the player")
            checklistRow(done: model.libraryFolder != nil,
                         text: model.libraryFolder != nil ? "Music folder chosen" : "Choose or drop a music folder")
            checklistRow(done: false, text: "Scan to see what will be copied")
            Text("Nothing is written until you press Sync.")
                .font(.system(size: 13)).foregroundStyle(p.inkSoft)
                .padding(.top, 4)
        }

        if case .failed(let message) = model.phase {
            Notice(kind: .bad, text: message)
        }
    }

    private func checklistRow(done: Bool, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: 16))
                .foregroundStyle(done ? p.good : p.inkSoft)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 15, weight: done ? .regular : .semibold))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Summary

    @ViewBuilder
    private var summary: some View {
        if let plan = model.plan {
            stats(plan)
            albumSelection

            if let device = model.selectedDevice, plan.bytesToCopy > device.freeBytes {
                Notice(kind: .bad, text: "Not enough free space on the player.")
            }
            if !plan.collisions.isEmpty {
                // Silently overwriting would lose files, so surface it.
                Notice(kind: .warn,
                       text: "\(countLabel(plan.collisions.count, "name collision")) — only the first file "
                           + "of each is copied. Fix the tags to keep both.")
            }

            issues

            if !plan.actions.isEmpty {
                DisclosureGroup(isExpanded: $showFiles) {
                    fileList(plan)
                        .padding(.top, 6)
                } label: {
                    Text("Files to copy (\(plan.actions.count))")
                        .font(.pixel(15, bold: true))
                        .lineLimit(1)
                }
                .tint(p.ink)
            } else {
                Notice(kind: .good, text: "Everything selected is already on the player.")
            }
        }
    }

    /// Stats on one row when they fit; otherwise split over two rows so the
    /// captions never get squeezed into wrapping.
    private func stats(_ plan: SyncPlan) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                primaryStats(plan)
                secondaryStats(plan)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    primaryStats(plan)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .top, spacing: 12) {
                    secondaryStats(plan)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func primaryStats(_ plan: SyncPlan) -> some View {
        Stat(value: "\(plan.actions.count)", caption: "to copy")
        Stat(value: model.hasExclusions
                ? "\(model.selectedAlbumCount)/\(model.albumCount)"
                : "\(model.albumCount)",
             caption: "albums")
        if let device = model.selectedDevice {
            Stat(value: ByteFormat.string(plan.bytesToCopy),
                 caption: "of \(ByteFormat.string(device.freeBytes)) free",
                 kind: plan.bytesToCopy > device.freeBytes ? .bad : nil)
        } else {
            Stat(value: ByteFormat.string(plan.bytesToCopy), caption: "size")
        }
    }

    @ViewBuilder
    private func secondaryStats(_ plan: SyncPlan) -> some View {
        Stat(value: "\(plan.upToDate.count)", caption: "already there")
        if model.brokenCount > 0 {
            Stat(value: "\(model.brokenCount)", caption: "broken", kind: .bad)
        }
    }

    private var albumSelection: some View {
        let newAlbums = model.libraryArtists.flatMap(\.albums)
            .filter { (model.pendingByAlbum[$0.id] ?? 0) > 0 }.count

        return HStack(spacing: 10) {
            Text(model.hasExclusions
                 ? "Syncing \(model.selectedAlbumCount) of \(model.albumCount) albums"
                 : "Syncing all \(model.albumCount) albums")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if newAlbums > 0 {
                Tag(text: "\(newAlbums) new", kind: .good)
            }
            Spacer(minLength: 8)
            Button("Choose albums…") {
                UISound.open.play()
                showAlbumPicker = true
            }
            .buttonStyle(PixelButtonStyle(compact: true))
            .fixedSize()
            .disabled(model.albumCount == 0 || model.isBusy)
        }
    }

    /// Why a file that is already on the player is being copied again.
    static func reasonText(_ reason: SyncAction.Reason) -> String? {
        switch reason {
        case .new: nil
        case .truncated: "cut off — will be replaced"
        case .changed: "differs from the library"
        }
    }

    private func fileList(_ plan: SyncPlan) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(plan.actions.prefix(200), id: \.devicePath) { action in
                let replace = action.kind == .replace
                HStack(spacing: 6) {
                    Text(replace ? "↻" : "+")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(replace ? p.warn : p.inkSoft)
                        .frame(width: 12)
                        .accessibilityLabel(replace ? "Replace" : "Copy")
                    Text(action.devicePath)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 4)
                    if let why = Self.reasonText(action.reason) {
                        Text(why).font(.system(size: 13)).foregroundStyle(p.warn)
                            .lineLimit(1).fixedSize()
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if plan.actions.count > 200 {
                Text("… and \(plan.actions.count - 200) more")
                    .font(.system(size: 13)).foregroundStyle(p.inkSoft)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelFrame(fill: p.card, border: p.line, width: 2)
    }

    // MARK: Issues

    @ViewBuilder
    private var issues: some View {
        let broken = model.reports.filter { !$0.isPlayable }
        let warned = model.reports.filter { $0.isPlayable && !$0.issues.isEmpty }

        if !broken.isEmpty {
            DisclosureGroup {
                issueList(brokenLines(broken))
            } label: {
                Notice(kind: .bad, text: "\(countLabel(broken.count, "file")) won't play — skipped")
            }
            .tint(p.ink)
        }

        if !warned.isEmpty || !model.albumIssues.isEmpty {
            DisclosureGroup {
                issueList(worthFixingLines(warned))
            } label: {
                Notice(kind: .warn, text: "Worth fixing")
            }
            .tint(p.ink)
        }

        if !model.strayTracks.isEmpty {
            DisclosureGroup {
                issueList(model.strayTracks.map { s in "\(s.path) — \(s.describe)" })
            } label: {
                Notice(kind: .warn,
                       text: "\(countLabel(model.strayTracks.count, "file")) possibly in the wrong folder")
            }
            .tint(p.ink)
        }
    }

    private func brokenLines(_ broken: [TrackReport]) -> [String] {
        broken.map { r in
            let what = r.issues.filter(\.isBlocking).map(\.describe).joined(separator: "; ")
            return "\(r.track.sourceURL.lastPathComponent) — \(what)"
        }
    }

    private func worthFixingLines(_ warned: [TrackReport]) -> [String] {
        var lines: [String] = []
        for r in warned.prefix(30) {
            let what = r.issues.map(\.describe).joined(separator: "; ")
            lines.append("\(r.track.sourceURL.lastPathComponent) — \(what)")
        }
        for a in model.albumIssues.prefix(20) {
            let what = a.issues.map(\.describe).joined(separator: "; ")
            lines.append("\(a.albumArtist) — \(a.album): \(what)")
        }
        return lines
    }

    private func issueList(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 13))
                    .foregroundStyle(p.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
    }

    // MARK: Pinned bottom

    private var options: some View {
        HStack(spacing: 12) {
            PixelTextField(placeholder: "Playlist name (optional)", text: $model.playlistName,
                           systemImage: "music.note.list")
                .frame(minWidth: 180, maxWidth: 240)

            // Oversized embedded art is the usual cause of the player
            // lagging or locking up, so resizing is on by default.
            PixelToggle("Art ≤ \(model.maxArtDimension)px", isOn: $model.resizeArtwork)
                .fixedSize()
                .help("Stock Innioasis firmware reads cover art from each file's tags "
                      + "and misbehaves on large images. The originals are never modified.")
            PixelToggle("Lyrics", isOn: $model.fetchLyrics)
                .fixedSize()
                .help("Fetch synced lyrics from LRCLIB and write .lrc files beside each "
                      + "track. Sends artist, album and track names to lrclib.net.")
            PixelToggle("Find art", isOn: $model.fetchCovers)
                .fixedSize()
                .help("Look up cover art on the Cover Art Archive for albums that have "
                      + "none, and embed it. Sends artist and album names to musicbrainz.org.")
            Spacer(minLength: 0)
        }
    }

    private var action: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.plan == nil {
                Button {
                    UISound.cursor.play()
                    Task { await model.scanAndPlan() }
                } label: {
                    Label("Scan and compare", systemImage: "magnifyingglass").lineLimit(1)
                }
                .buttonStyle(PixelButtonStyle(kind: .primary))
                .fixedSize()
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canScan || model.selectedDevice == nil)
                .help("Scan the music folder and compare it with the player — nothing is written")
            } else {
                Button {
                    UISound.confirm.play()
                    Task { await model.sync() }
                } label: {
                    Label(syncTitle, systemImage: "arrow.triangle.2.circlepath")
                        .lineLimit(1)
                }
                .buttonStyle(PixelButtonStyle(kind: .primary))
                .fixedSize()
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSync)
            }

            Text(nextStepHint)
                .font(.system(size: 13))
                .foregroundStyle(p.inkSoft)
                .lineLimit(2)

            switch model.phase {
            case .done(let message):
                Notice(kind: .good, text: message + "  Eject the player before unplugging.")
            case .failed(let message) where model.plan != nil:
                Notice(kind: .bad, text: message)
            default:
                EmptyView()
            }
        }
    }

    private var syncTitle: String {
        if let plan = model.plan, !plan.actions.isEmpty {
            let n = plan.actions.count
            return "Sync \(n) " + (n == 1 ? "track" : "tracks")
        }
        return "Sync"
    }

    /// Says what to do next — and so why the Sync button may be disabled.
    private var nextStepHint: String {
        guard let device = model.selectedDevice else { return "Connect the player first" }
        if model.libraryFolder == nil { return "Choose a music folder" }
        if model.phase == .scanning { return "Wait for the scan to finish" }
        guard let plan = model.plan else { return "Press “Scan and compare”" }
        if model.phase == .syncing { return "Keep the player connected" }
        if !plan.actions.isEmpty && plan.bytesToCopy > device.freeBytes {
            return "Not enough free space on the player"
        }
        if plan.actions.isEmpty {
            return model.playlistName.isEmpty
                ? "Everything is already on the player"
                : "Writes the playlist only — nothing to copy"
        }
        return "Copies only what's missing. Nothing on the player is deleted."
    }

    // MARK: - Folder input

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.setLibraryFolder(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return }
            Task { @MainActor in
                model.setLibraryFolder(url)
                UISound.confirm.play()
            }
        }
        return true
    }
}
