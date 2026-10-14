import SwiftUI
import Y1SyncCore

/// Choose which albums go to the player.
///
/// Unticking an album only stops it being copied — nothing already on the
/// player is removed because of it.
struct AlbumPickerView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    @State private var query = ""
    @State private var expanded: Set<String> = []

    private var filtered: [LibraryArtist] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.libraryArtists }
        return model.libraryArtists.compactMap { artist in
            if artist.name.localizedCaseInsensitiveContains(q) { return artist }
            let albums = artist.albums.filter { $0.title.localizedCaseInsensitiveContains(q) }
            guard !albums.isEmpty else { return nil }
            var copy = artist
            copy.albums = albums
            return copy
        }
    }

    private var visibleAlbums: [LibraryAlbum] { filtered.flatMap(\.albums) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose albums")
                .font(.pixel(20, bold: true))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Text("Unticked albums are skipped. Nothing already on the player is removed, and "
                 + "albums you add to the library later are ticked by default.")
                .font(.system(size: 12))
                .foregroundStyle(p.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                PixelTextField(placeholder: "Search artists and albums", text: $query,
                               systemImage: "magnifyingglass")
                Button(query.isEmpty ? "Select all" : "Select shown") {
                    model.setIncluded(true, albums: visibleAlbums)
                }
                .buttonStyle(PixelButtonStyle(compact: true))
                .fixedSize()
                Button(query.isEmpty ? "Deselect all" : "Deselect shown") {
                    model.setIncluded(false, albums: visibleAlbums)
                }
                .buttonStyle(PixelButtonStyle(compact: true))
                .fixedSize()
            }

            list

            footer
        }
        .padding(20)
        .foregroundStyle(p.ink)
        .frame(minWidth: 580, idealWidth: 620, minHeight: 520, idealHeight: 640)
        .background(p.paper.ignoresSafeArea())
        .onExitCommand { dismiss() }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.selectedAlbumCount) of \(model.albumCount) albums selected")
                    .font(.pixel(14, bold: true))
                    .lineLimit(1)
                if let plan = model.plan {
                    Text(plan.isEmpty
                         ? "Everything selected is already on the player."
                         : countLabel(plan.actions.count, "track") + " to copy · " + ByteFormat.string(plan.bytesToCopy))
                        .font(.system(size: 11))
                        .foregroundStyle(p.inkSoft)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(PixelButtonStyle(kind: .primary))
                .fixedSize()
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { artist in
                    artistRow(artist)
                    if !query.isEmpty || expanded.contains(artist.id) {
                        ForEach(artist.albums) { album in
                            albumRow(album)
                        }
                    }
                }
            }
            .padding(Pixel.unit + 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pixelFrame(fill: p.card, border: p.ink)
        .overlay {
            if filtered.isEmpty {
                Text(model.libraryArtists.isEmpty ? "Scan the library first." : "Nothing matches “\(query)”.")
                    .font(.pixel(14))
                    .foregroundStyle(p.inkSoft)
            }
        }
    }

    private func artistRow(_ artist: LibraryArtist) -> some View {
        let on = artist.albums.filter { model.isIncluded($0) }.count
        let state: CheckState = on == 0 ? .off : (on == artist.albums.count ? .on : .mixed)
        let pending = artist.albums.reduce(0) { $0 + (model.pendingByAlbum[$1.id] ?? 0) }
        let isOpen = !query.isEmpty || expanded.contains(artist.id)

        return HStack(spacing: 8) {
            Button {
                if expanded.contains(artist.id) { expanded.remove(artist.id) } else { expanded.insert(artist.id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .heavy))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOpen ? "Collapse \(artist.name)" : "Expand \(artist.name)")

            PixelCheckbox(state: state) {
                model.setIncluded(state != .on, artist: artist)
                UISound.cursor.play()
            }
            .accessibilityLabel(artist.name)

            Text(artist.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer()
            if pending > 0 { Tag(text: "\(pending) new", kind: .good) }
            Text("\(artist.albums.count) album\(artist.albums.count == 1 ? "" : "s") · "
                 + ByteFormat.string(artist.bytes))
                .font(.system(size: 11))
                .foregroundStyle(p.inkSoft)
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .foregroundStyle(p.ink)
    }

    private func albumRow(_ album: LibraryAlbum) -> some View {
        let included = model.isIncluded(album)
        let pending = model.pendingByAlbum[album.id] ?? 0

        return HStack(spacing: 8) {
            PixelCheckbox(state: included ? .on : .off) {
                model.setIncluded(!included, album: album)
                UISound.cursor.play()
            }
            .accessibilityLabel(album.title)
            Text(album.title).font(.system(size: 13)).lineLimit(1)
                .foregroundStyle(included ? p.ink : p.inkSoft)
            Spacer()
            if pending > 0 { Tag(text: "\(pending) new", kind: .good) }
            Text("\(album.trackCount) track\(album.trackCount == 1 ? "" : "s") · "
                 + ByteFormat.string(album.bytes))
                .font(.system(size: 11))
                .foregroundStyle(p.inkSoft)
                .lineLimit(1)
        }
        .padding(.leading, 38).padding(.trailing, 8).padding(.vertical, 4)
    }
}

// Previews use PreviewProvider rather than #Preview: the #Preview macro
// needs a plugin that only ships with full Xcode, so with just the Command
// Line Tools installed it breaks `swift build`. PreviewProvider works with both.
struct AlbumPickerView_Previews: PreviewProvider {
    static var previews: some View {
        let model = AppModel()
        model.libraryArtists = SyncSelection.group([
            PreviewData.track("Airbag", n: 1),
            PreviewData.track("Karma Police", n: 6),
            PreviewData.track("Pyramid Song", album: "Amnesiac", n: 2),
            PreviewData.track("Gruppa krovi", artist: "Кино", album: "Группа крови", n: 1),
        ])
        return AlbumPickerView(model: model).themed()
    }
}
