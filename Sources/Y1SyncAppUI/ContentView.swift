import SwiftUI
import Y1SyncCore

/// The window shell: flat paper, a top bar (title, tabs, appearance, sound),
/// whichever screen is selected, and a bottom status bar with the player
/// state and the live activity of both models.
struct ContentView: View {
    @State private var model = AppModel()
    @State private var deviceModel = DeviceModel()
    @State private var tab: Tab = .sync
    @State private var showAlbumPicker = false
    @State private var soundsOn = AppSettings.soundsEnabled
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .auto

    @Environment(\.palette) private var p

    enum Tab: Hashable { case sync, results, device, duplicates }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            rule
            screen
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            rule
            statusBar
        }
        // Start at the very top of the window, beside the traffic lights,
        // instead of below the (hidden) title bar's safe area.
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(p.ink)
        .background(p.paper.ignoresSafeArea())
        .frame(minWidth: 900, minHeight: 680)
        .onAppear {
            model.refreshDevices()
            // Notice the player being plugged in or out without Refresh.
            model.startWatchingVolumes()
            deviceModel.deviceChanged(to: model.selectedDevice?.url)
        }
        .onChange(of: model.libraryTracks.count) { deviceModel.libraryTracks = model.libraryTracks }
        .onChange(of: model.selectedDevice?.url) { _, url in
            // The Device and Duplicates tabs hold a scan of one specific
            // player; never let it act on a different one.
            deviceModel.deviceChanged(to: url)
        }
        .onChange(of: model.lastChanges.count) { _, count in
            // Jump to the results as soon as there is something to inspect.
            if count > 0 { tab = .results }
        }
        .onChange(of: model.phase) { _, phase in
            switch phase {
            case .done: UISound.success.play()
            case .failed: UISound.error.play()
            default: break
            }
        }
        // Remember settings between launches.
        .onChange(of: model.playlistName) { model.saveSettings() }
        .onChange(of: model.resizeArtwork) { model.saveSettings() }
        .onChange(of: model.fetchLyrics) { model.saveSettings() }
        .onChange(of: model.fetchCovers) { model.saveSettings() }
        .onChange(of: model.autoCompare) { model.saveSettings() }
        .sheet(isPresented: $showAlbumPicker) {
            AlbumPickerView(model: model).themed()
        }
    }

    /// A one-unit ink line between the chrome and the screen.
    private var rule: some View {
        Rectangle().fill(p.ink).frame(height: Pixel.unit)
            .accessibilityHidden(true)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 18) {
            Text("Y1 SYNC")
                .font(.pixel(22, bold: true))
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)

            PixelTabBar(tabs: tabs, selection: $tab)
                .fixedSize()

            Spacer(minLength: 0)

            Button {
                appearance = appearance.next
                UISound.cursor.play()
            } label: {
                Text(appearance.title).lineLimit(1)
            }
            .buttonStyle(PixelButtonStyle(compact: true))
            .fixedSize()
            .help("Appearance: \(appearance.title) — click to switch")
            .accessibilityLabel("Appearance: \(appearance.title)")

            Button {
                soundsOn.toggle()
                AppSettings.soundsEnabled = soundsOn
                if soundsOn { UISound.confirm.play() }
            } label: {
                Image(systemName: soundsOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .frame(width: 18)
            }
            .buttonStyle(PixelButtonStyle(compact: true))
            .fixedSize()
            .help(soundsOn ? "Turn interface sounds off" : "Turn interface sounds on")
            .accessibilityLabel(soundsOn ? "Sounds on" : "Sounds off")
        }
        // The title bar is hidden and the content runs under it: leave room
        // for the traffic lights and keep this row (29pt tabs) on the same
        // line as them — their centre is ~14pt from the top of the window.
        .padding(.leading, 78)
        .padding(.trailing, 20)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .frame(height: 40, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(p.paper)
    }

    private var tabs: [PixelTab<Tab>] {
        [
            PixelTab(id: .sync, title: "Sync"),
            PixelTab(id: .results, title: "Results",
                     badge: model.lastChanges.isEmpty ? nil : model.lastChanges.count),
            PixelTab(id: .device, title: "Device"),
            PixelTab(id: .duplicates, title: "Dupes",
                     badge: deviceModel.duplicates.isEmpty ? nil : deviceModel.duplicates.count),
        ]
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            playerState
                .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            activity
                .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 20)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(p.paper)
    }

    @ViewBuilder
    private var playerState: some View {
        HStack(spacing: 8) {
            if let device = model.selectedDevice {
                Image(systemName: "checkmark.square.fill")
                    .foregroundStyle(p.good)
                    .accessibilityHidden(true)
                Text("\(device.name) connected · \(device.details)")
            } else {
                Image(systemName: "exclamationmark.square.fill")
                    .foregroundStyle(p.warn)
                    .accessibilityHidden(true)
                Text(Wording.noPlayer)
            }
        }
        .font(.pixel(13))
        .foregroundStyle(p.ink)
        .lineLimit(1)
        .layoutPriority(1)
    }

    @ViewBuilder
    private var activity: some View {
        if model.phase == .syncing {
            activityRow(model.progressLabel.isEmpty ? "Copying…" : model.progressLabel,
                        progress: model.progressFraction)
        } else if model.phase == .scanning {
            activityRow(model.progressLabel.isEmpty ? "Scanning library…" : model.progressLabel,
                        progress: nil)
        } else if deviceModel.isBusy {
            activityRow(deviceModel.status.isEmpty ? "Working…" : deviceModel.status,
                        progress: deviceModel.progress)
        }
    }

    private func activityRow(_ label: String, progress: Double?) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(p.inkSoft)
                .lineLimit(1)
                .truncationMode(.tail)
            if let progress {
                PixelProgress(value: progress).frame(width: 180)
            }
        }
    }

    // MARK: - Screens

    @ViewBuilder
    private var screen: some View {
        switch tab {
        case .sync:
            SyncScreen(model: model, showAlbumPicker: $showAlbumPicker)
        case .results:
            if let root = model.lastDeviceRoot, !model.lastChanges.isEmpty {
                ResultsView(changes: model.lastChanges,
                            skipped: model.reports.filter { !$0.isPlayable },
                            deviceRoot: root)
            } else {
                EmptyState(title: "Nothing synced yet",
                           message: "Run a sync and every copied file shows up here — "
                               + "play it straight off the player to check its cover and lyrics.")
            }
        case .device:
            DeviceView(model: deviceModel, device: model.selectedDevice)
        case .duplicates:
            DuplicatesView(model: deviceModel)
        }
    }
}

// Previews use PreviewProvider rather than #Preview: the #Preview macro
// needs a plugin that only ships with full Xcode, so with just the Command
// Line Tools installed it breaks `swift build`. PreviewProvider works with both.
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ContentView().themed().frame(width: 980, height: 720)
                .preferredColorScheme(.light)
            ContentView().themed().frame(width: 980, height: 720)
                .preferredColorScheme(.dark)
        }
    }
}
