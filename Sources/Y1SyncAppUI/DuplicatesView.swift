import SwiftUI
import AppKit
import Y1SyncCore

/// Lists songs stored more than once, with a recommended copy to keep.
///
/// Removal is opt-in per group and confirmed: getting this wrong destroys
/// music, so nothing is selected by default.
struct DuplicatesView: View {
    @Bindable var model: DeviceModel

    @State private var confirmDelete = false
    /// Result of the last removal. Kept outside the list so it still shows
    /// when the re-scan finds no duplicates left.
    @State private var outcome: (text: String, kind: Kind)?

    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: Pixel.gap) {
            header

            if model.duplicates.isEmpty {
                if let outcome {
                    Notice(kind: outcome.kind, text: outcome.text)
                }
                EmptyState(title: model.hasScanned ? "No duplicates" : "Nothing scanned yet",
                           message: model.hasScanned
                               ? "Every song on the player is stored once."
                               : "Scan the player on the Device tab to look for duplicates.")
            } else {
                autoCleanBox
                ScrollView {
                    LazyVStack(spacing: Pixel.gap) {
                        ForEach(model.duplicates) { group in
                            groupBox(group)
                        }
                    }
                    .padding(.trailing, 6).padding(.bottom, 6)
                }
                footer
            }
        }
        // As on the Device tab: keep Tab focus and keys from changing the
        // selection behind the open confirmation.
        .disabled(confirmDelete)
        .foregroundStyle(p.ink)
        .pixelConfirm(isPresented: $confirmDelete,
                      title: "Remove extra copies",
                      message: "Keeps the copy marked keep in each of "
                          + "\(countLabel(model.selectedDuplicates.count, "group")). The others move to a hidden quarantine folder on the player — "
                          + "you can undo this from the Device tab until the next tidy or cleanup.",
                      confirmTitle: "Remove") {
            UISound.confirm.play()
            Task {
                let r = await model.deleteSelectedDuplicates()
                let text = "Removed \(countLabel(r.removed, "file")) (\(ByteFormat.string(r.freed))). Undo is on the Device tab."
                    + (r.failed > 0 ? " \(r.failed) could not be removed." : "")
                outcome = (text, r.failed == 0 ? .good : (r.removed == 0 ? .bad : .warn))
                (r.failed > 0 ? UISound.error : UISound.success).play()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Duplicates")
                .font(.pixel(18, bold: true))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if !model.duplicates.isEmpty {
                let total = model.duplicates.reduce(Int64(0)) { $0 + $1.wastedBytes(limits: model.limits) }
                Tag(text: countLabel(model.duplicates.count, "group"))
                Tag(text: "\(ByteFormat.string(total)) recoverable", kind: .good)
            }
            Spacer()
            if !model.duplicates.isEmpty {
                let all = model.selectedDuplicates.count == model.duplicates.count
                Button(all ? "Deselect all" : "Select all") {
                    model.selectedDuplicates = all ? [] : Set(model.duplicates.map(\.id))
                    outcome = nil
                }
                .buttonStyle(PixelButtonStyle(compact: true))
                .fixedSize()
            }
        }
    }

    // MARK: - Automatic clean-up

    /// One button for the common case: the same song, same album, stored twice.
    @ViewBuilder
    private var autoCleanBox: some View {
        let safe = model.safeDuplicates
        let rest = model.duplicates.count - safe.count
        let freed = safe.reduce(Int64(0)) { $0 + $1.wastedBytes(limits: model.limits) }
        PixelBox(title: "Clean up automatically") {
            if safe.isEmpty {
                Text("None of these can be cleaned without a decision: each is the same song on "
                     + "different albums, or has no copy the player can play. Check them below.")
                    .font(.system(size: 13)).foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(autoCleanText(safe: safe.count, rest: rest, freed: freed))
                    .font(.system(size: 13)).foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    UISound.open.play()
                    outcome = nil
                    model.selectSafeDuplicates()
                    confirmDelete = true
                } label: {
                    Label("Clean up \(countLabel(safe.count, "group"))", systemImage: "sparkles")
                }
                .buttonStyle(PixelButtonStyle(kind: confirmDelete ? .normal : .primary))
                .fixedSize()
                .disabled(model.isBusy)
            }
        }
    }

    private func autoCleanText(safe: Int, rest: Int, freed: Int64) -> String {
        var text = "\(countLabel(safe, "group")) are the same song on the same album. "
        text += "The best copy stays (lossless first, then larger, then the one in the right folder, "
        text += "and always one the player can play); the rest go to quarantine and free "
        text += ByteFormat.string(freed) + "."
        if rest > 0 { text += " The other \(rest) are marked “check first” — they are on different albums." }
        return text
    }

    // MARK: - Group

    private func groupBox(_ group: DuplicateGroup) -> some View {
        let keeper = model.deviceRoot.map { group.recommendedKeeper(onDeviceRoot: $0, limits: model.limits) }
            ?? group.keeper(limits: model.limits)
        let isOn = model.selectedDuplicates.contains(group.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PixelCheckbox(state: isOn ? .on : .off,
                              label: "\(group.tracks[0].effectiveArtist) — \(group.tracks[0].effectiveTitle)") {
                    if isOn { model.selectedDuplicates.remove(group.id) }
                    else { model.selectedDuplicates.insert(group.id) }
                    outcome = nil
                    UISound.cursor.play()
                }
                Spacer(minLength: 8)
                if !model.isSafeToAutoClean(group) { Tag(text: "check first", kind: .warn) }
                Tag(text: "frees \(ByteFormat.string(group.wastedBytes(limits: model.limits)))")
            }

            ForEach(group.tracks.sorted { $0.fileSize > $1.fileSize }, id: \.sourceURL) { track in
                let isKeeper = track.sourceURL == keeper?.sourceURL
                HStack(spacing: 8) {
                    Tag(text: isKeeper ? "keep" : "extra", kind: isKeeper ? .good : .warn)
                        .frame(width: 56, alignment: .leading)
                    Text("\(track.fileExtension) · \(ByteFormat.string(track.fileSize))")
                        .font(.pixel(12))
                        .lineLimit(1)
                        .frame(width: 90, alignment: .leading)
                    Text(track.sourceURL.lastPathComponent)
                        .font(.system(size: 13))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([track.sourceURL])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(PixelButtonStyle(compact: true))
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(track.sourceURL.lastPathComponent) in Finder")
                }
                .padding(.leading, 24)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelFrame(fill: p.card, border: p.ink)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let outcome {
                Notice(kind: outcome.kind, text: outcome.text)
            }
            HStack(spacing: 12) {
                Text(model.selectedDuplicates.isEmpty
                     ? "Tick the groups you want cleaned up."
                     : "Keeps the copy marked keep in \(countLabel(model.selectedDuplicates.count, "group")), frees "
                       + ByteFormat.string(model.reclaimableBytes) + ".")
                    .font(.system(size: 13))
                    .lineLimit(2)
                Spacer()
                Button {
                    UISound.open.play()
                    outcome = nil
                    confirmDelete = true
                } label: {
                    Label("Remove extra copies", systemImage: "trash")
                }
                // Only one primary at a time: the open dialog owns it.
                .buttonStyle(PixelButtonStyle(kind: .normal))
                .fixedSize()
                .disabled(model.selectedDuplicates.isEmpty || model.isBusy)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelFrame(fill: p.card, border: p.ink)
    }
}

struct DuplicatesView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            groupsFound.previewDisplayName("Groups found")
            noDuplicates.previewDisplayName("No duplicates")
        }
        .padding(20)
        .frame(width: 900, height: 560)
        .background(Palette.day.paper)
        .themed()
    }

    private static var groupsFound: some View {
        let model = DeviceModel()
        model.tracks = [PreviewData.track("Airbag")]
        model.duplicates = PreviewData.duplicateGroups
        return DuplicatesView(model: model)
    }

    private static var noDuplicates: some View {
        let model = DeviceModel()
        model.tracks = [PreviewData.track("Airbag")]
        return DuplicatesView(model: model)
    }
}
