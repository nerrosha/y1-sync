import Foundation

/// A file on the device that should move or go away.
public struct TidyAction: Sendable, Identifiable {
    public enum Kind: Sendable {
        /// Rename/move into the standard Artist/Album/NN Title layout.
        case move(to: String)
        /// macOS metadata sidecar, safe to delete.
        case junk
        /// Directory left empty afterwards.
        case emptyDirectory
        /// A pre-tidy album folder whose tracks have all moved to this one
        /// destination album folder, leaving only non-audio companions
        /// (cover art, rip logs, lyric files) behind. Whichever cover image
        /// is found there at apply time is copied across before this folder
        /// is removed.
        case leftoverFolder(destinationAlbum: String)
    }

    public var id: String { path }
    public var path: String
    public var kind: Kind
    public var bytes: Int64

    public init(path: String, kind: Kind, bytes: Int64) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
    }

    public var describe: String {
        switch kind {
        case .move(let to): return "\(path)  →  \(to)"
        case .junk: return "delete \(path)"
        case .emptyDirectory: return "remove empty folder \(path)"
        case .leftoverFolder(let dest):
            return "remove leftover folder \(path) (moving any cover art to \(dest))"
        }
    }
}

public struct TidyPlan: Sendable {
    public var moves: [TidyAction]
    public var junk: [TidyAction]
    public var emptyDirectories: [TidyAction]
    public var leftoverFolders: [TidyAction]

    public init(moves: [TidyAction] = [], junk: [TidyAction] = [],
                emptyDirectories: [TidyAction] = [], leftoverFolders: [TidyAction] = []) {
        self.moves = moves
        self.junk = junk
        self.emptyDirectories = emptyDirectories
        self.leftoverFolders = leftoverFolders
    }

    public var junkBytes: Int64 { junk.reduce(0) { $0 + $1.bytes } }
    public var isEmpty: Bool {
        moves.isEmpty && junk.isEmpty && emptyDirectories.isEmpty && leftoverFolders.isEmpty
    }
}

/// Reorganises files that are already on the player.
///
/// This matters more than it sounds: stock Innioasis firmware displays the
/// *filename*, not the title tag, so inconsistent names are exactly what you
/// see while browsing. Tidying renames in place using the tags already in
/// each file — no source library needed.
public struct DeviceTidy: Sendable {
    public var layout: DeviceLayout

    public init(layout: DeviceLayout = DeviceLayout()) {
        self.layout = layout
    }

    /// macOS writes these onto FAT volumes; they are not music and the player
    /// may list them as phantom tracks.
    public static func isJunk(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store" || name == ".Spotlight-V100"
            || name == ".Trashes" || name == ".fseventsd"
    }

    /// Work out what to rename and what to delete.
    public func plan(deviceRoot: URL, tracks: [Track]) -> TidyPlan {
        var plan = TidyPlan()
        let fm = FileManager.default
        let engine = SyncEngine()

        // Renames, driven by each file's own tags.
        for track in tracks {
            let current = engine.devicePath(of: track.sourceURL, root: deviceRoot)
            let target = layout.path(for: track)
            guard FATName.foldedKey(current) != FATName.foldedKey(target) else { continue }
            plan.moves.append(TidyAction(path: current, kind: .move(to: target),
                                         bytes: track.fileSize))
        }

        // Leftover folders: once every track that used to live in a pre-tidy
        // folder has moved to one single destination album, whatever is left
        // (cover art, rip logs, lyric files) is orphaned clutter — salvage a
        // cover into the new album folder, then the whole thing can go.
        // Skipped when a folder's tracks scattered to more than one
        // destination, since there is no single obvious place to salvage to.
        var tracksBySourceDir: [String: [String]] = [:]
        var moveTarget: [String: String] = [:]
        for track in tracks {
            let current = engine.devicePath(of: track.sourceURL, root: deviceRoot)
            let dir = (current as NSString).deletingLastPathComponent
            tracksBySourceDir[dir, default: []].append(current)
        }
        for action in plan.moves {
            guard case .move(let to) = action.kind else { continue }
            moveTarget[FATName.foldedKey(action.path)] = to
        }

        for (dir, paths) in tracksBySourceDir {
            // Every track that used to live here must have an actual move —
            // if even one stayed put (already correctly placed, or blocked
            // by a duplicate at the destination), the folder still has music.
            let destParents = paths.map { path in
                moveTarget[FATName.foldedKey(path)].map { ($0 as NSString).deletingLastPathComponent }
            }
            guard destParents.allSatisfy({ $0 != nil }) else { continue }
            let uniqueDestinations = Set(destParents.compactMap { $0 })
            guard uniqueDestinations.count == 1, let dest = uniqueDestinations.first else { continue }

            plan.leftoverFolders.append(TidyAction(
                path: dir, kind: .leftoverFolder(destinationAlbum: dest), bytes: 0))
        }

        guard let walker = fm.enumerator(at: deviceRoot,
                                         includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                         options: []) else { return plan }

        var directories: [URL] = []
        for case let url as URL in walker {
            // The undo store's own quarantine folder — never treat its
            // contents as junk, empty, or a leftover shell to clean up.
            if url.pathComponents.contains(".y1sync") {
                walker.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true {
                directories.append(url)
            } else if Self.isJunk(url.lastPathComponent) {
                plan.junk.append(TidyAction(
                    path: engine.devicePath(of: url, root: deviceRoot),
                    kind: .junk,
                    bytes: values?.fileSize.map(Int64.init) ?? 0))
            }

            // macOS presents "._X" as the resource fork of "X" and hides it
            // from readdir, so these can never be found by walking a
            // directory — only by probing the exact sibling path. The player
            // reads raw FAT and does see them.
            if let sidecar = Self.appleDoubleSibling(of: url) {
                plan.junk.append(TidyAction(
                    path: engine.devicePath(of: sidecar, root: deviceRoot),
                    kind: .junk,
                    bytes: Self.size(of: sidecar)))
            }
        }

        // Deepest first, so a folder emptied by clearing its children is seen.
        for dir in directories.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let meaningful = contents.filter { !Self.isJunk($0) }
            if meaningful.isEmpty && !contents.isEmpty || contents.isEmpty {
                plan.emptyDirectories.append(TidyAction(
                    path: engine.devicePath(of: dir, root: deviceRoot),
                    kind: .emptyDirectory, bytes: 0))
            }
        }

        return plan
    }

    public struct TidyResult: Sendable {
        public var moved = 0
        public var junkRemoved = 0
        public var directoriesRemoved = 0
        public var leftoverFoldersRemoved = 0
        public var coversSalvaged = 0
        public var playlistsRepaired = 0
        public var bytesFreed: Int64 = 0
        public var failures: [String] = []
    }

    /// Apply a plan. Renames happen first so that folders emptied by the moves
    /// are then eligible for removal.
    public func apply(_ plan: TidyPlan, deviceRoot: URL,
                      removeJunk: Bool = true,
                      progress: (@Sendable (Int, Int) -> Void)? = nil) -> TidyResult {
        let fm = FileManager.default
        var result = TidyResult()
        let total = plan.moves.count + (removeJunk ? plan.junk.count : 0)
        var done = 0
        var successfulMoves: [(from: String, to: String)] = []
        let undo = UndoRecorder(deviceRoot: deviceRoot)

        for action in plan.moves {
            guard case .move(let target) = action.kind else { continue }
            let from = deviceRoot.appendingPathComponent(
                action.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            let to = deviceRoot.appendingPathComponent(
                target.trimmingCharacters(in: CharacterSet(charactersIn: "/")))

            done += 1
            progress?(done, total)
            guard from != to, fm.fileExists(atPath: from.path) else { continue }

            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                // Never clobber an existing file; report instead.
                if fm.fileExists(atPath: to.path) {
                    result.failures.append("\(target) already exists")
                    continue
                }
                try fm.moveItem(at: from, to: to)
                result.moved += 1
                successfulMoves.append((from: action.path, to: target))
                undo.recordMove(from: action.path, to: target)
            } catch {
                result.failures.append("\(action.path): \(error.localizedDescription)")
            }
        }

        if removeJunk {
            for action in plan.junk {
                let url = deviceRoot.appendingPathComponent(
                    action.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                done += 1
                progress?(done, total)
                if (try? fm.removeItem(at: url)) != nil {
                    result.junkRemoved += 1
                    result.bytesFreed += action.bytes
                }
            }
        }

        for action in plan.leftoverFolders {
            guard case .leftoverFolder(let destinationAlbum) = action.kind else { continue }
            let dir = deviceRoot.appendingPathComponent(
                action.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            guard fm.fileExists(atPath: dir.path) else { continue }

            // The plan assumed every track here would move, but a collision
            // above may have left one behind — re-check against the real
            // filesystem rather than trusting that assumption.
            let stillHasAudio = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .contains { SupportedFormat.isSupported(($0 as NSString).pathExtension) }
            guard !stillHasAudio else { continue }

            if let cover = Self.firstCoverImage(in: dir) {
                let destDir = deviceRoot.appendingPathComponent(
                    destinationAlbum.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                let destCover = destDir.appendingPathComponent("cover." + cover.pathExtension.lowercased())
                if !fm.fileExists(atPath: destCover.path) {
                    try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    if (try? fm.copyItem(at: cover, to: destCover)) != nil {
                        result.coversSalvaged += 1
                    }
                }
            }

            if undo.quarantine(dir, path: action.path) {
                result.leftoverFoldersRemoved += 1
            }
        }

        undo.finish(label: "tidy")

        result.playlistsRepaired = Self.repairPlaylists(
            movedFrom: successfulMoves, deviceRoot: deviceRoot)

        // The plan's list is stale by now — the moves above emptied folders
        // that were still occupied when it was built — so rediscover them.
        result.directoriesRemoved = removeEmptyDirectories(under: deviceRoot,
                                                           removingJunk: removeJunk)
        return result
    }
}

extension DeviceTidy {
    /// The hidden `._name` sidecar beside `url`, if one exists.
    ///
    /// These cannot be discovered by enumeration — macOS folds them into the
    /// file they belong to — so each candidate path is probed directly.
    static func appleDoubleSibling(of url: URL) -> URL? {
        let name = url.lastPathComponent
        guard !name.hasPrefix("._") else { return nil }
        let sidecar = url.deletingLastPathComponent().appendingPathComponent("._" + name)
        return FileManager.default.fileExists(atPath: sidecar.path) ? sidecar : nil
    }

    /// Rewrite any `.m3u8` playlist path that pointed at a file this tidy run
    /// just renamed.
    ///
    /// A playlist references tracks by device-absolute path; renaming a
    /// track without updating any playlist that named it would leave the
    /// playlist silently pointing at nothing. `.m3u8` is searched for
    /// wherever it lives, since a playlist folder is a naming convention the
    /// firmware chooses, not something this tool should assume.
    static func repairPlaylists(movedFrom moves: [(from: String, to: String)],
                                deviceRoot: URL) -> Int {
        guard !moves.isEmpty else { return 0 }
        let rename = Dictionary(uniqueKeysWithValues:
            moves.map { (FATName.foldedKey($0.from), $0.to) })

        let fm = FileManager.default
        guard let walker = fm.enumerator(at: deviceRoot,
                                         includingPropertiesForKeys: nil, options: []) else { return 0 }

        var repaired = 0
        for case let url as URL in walker {
            guard url.pathExtension.lowercased() == "m3u8" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            var changed = false
            let lines = text.components(separatedBy: "\n").map { line -> String in
                guard !line.hasPrefix("#"), !line.trimmingCharacters(in: .whitespaces).isEmpty,
                      let newPath = rename[FATName.foldedKey(line)] else { return line }
                changed = true
                return newPath
            }

            guard changed else { continue }
            if (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil {
                repaired += 1
            }
        }
        return repaired
    }

    /// The first image file directly inside `dir`, preferring an obvious
    /// "cover" name if there is one — picked at apply time, not plan time,
    /// since the plan only needs to know a folder is a leftover, not what's
    /// in it.
    static func firstCoverImage(in dir: URL) -> URL? {
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "gif"]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let images = names.filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        let preferred = images.first { $0.lowercased().contains("cover") || $0.lowercased().contains("front") }
        guard let name = preferred ?? images.first else { return nil }
        return dir.appendingPathComponent(name)
    }

    static func size(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}

extension DeviceTidy {
    /// Remove directories that hold nothing worth keeping, deepest first so a
    /// parent emptied by clearing its children is also collected.
    ///
    /// The device root itself is never removed.
    func removeEmptyDirectories(under root: URL, removingJunk: Bool) -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isDirectoryKey],
                                         options: []) else { return 0 }

        var directories: [URL] = []
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                directories.append(url)
            }
        }

        var removed = 0
        for dir in directories.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            guard dir != root else { continue }
            let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["keep"]

            // With junk removal off, a folder holding a .DS_Store is still in
            // use — deleting it would take the file the caller asked to keep.
            let disposable = removingJunk
                ? contents.allSatisfy(Self.isJunk)
                : contents.isEmpty

            guard disposable else { continue }
            if (try? fm.removeItem(at: dir)) != nil { removed += 1 }
        }
        return removed
    }
}
