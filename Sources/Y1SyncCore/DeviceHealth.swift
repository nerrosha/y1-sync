import Foundation

/// A file on the player that will not play, and — when the library has an
/// intact copy of the same song — what could replace it.
public struct BrokenFile: Sendable, Identifiable {
    public var id: String { report.track.sourceURL.path }
    public var report: TrackReport
    /// Path on the player, e.g. `/Music/A/B/01 Song.flac`.
    public var devicePath: String
    /// An intact copy in the library, already checked to play.
    public var replacement: Track?

    public var reasons: [String] { report.issues.filter(\.isBlocking).map(\.describe) }
}

/// Finds files on the player that are broken, and fixes them.
///
/// Sync only vets files *before* copying; anything already on the player —
/// copied before this check existed, cut short by an unplugged cable, or
/// corrupted since — was never looked at. This audits what is really there.
public struct DeviceHealth: Sendable {
    /// Judges one file. Injectable so tests need no real audio.
    public var check: @Sendable (Track) async -> TrackReport
    /// Two copies count as the same song when their lengths agree this closely.
    public var durationTolerance: Double

    public init(check: (@Sendable (Track) async -> TrackReport)? = nil,
                durationTolerance: Double = 5) {
        self.check = check ?? { await TrackHealth(checkTail: true, audioOnly: true).check($0) }
        self.durationTolerance = durationTolerance
    }

    // MARK: Scan

    /// Check every track on the player (bounded concurrency — thousands of
    /// open files at once would hit the descriptor limit) and pair each broken
    /// one with a good library copy where there is one.
    public func scan(
        deviceTracks: [Track], deviceRoot: URL, library: [Track],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [BrokenFile] {
        let engine = SyncEngine()
        var reports: [TrackReport] = []
        var index = 0
        let batch = 8
        while index < deviceTracks.count {
            let slice = Array(deviceTracks[index..<min(index + batch, deviceTracks.count)])
            let done = await withTaskGroup(of: TrackReport.self) { group -> [TrackReport] in
                for t in slice { group.addTask { await check(t) } }
                var out: [TrackReport] = []
                for await r in group { out.append(r) }
                return out
            }
            reports.append(contentsOf: done)
            index += batch
            progress?(min(index, deviceTracks.count), deviceTracks.count)
        }

        var broken: [BrokenFile] = []
        for report in reports where !report.isPlayable {
            var item = BrokenFile(
                report: report,
                devicePath: engine.devicePath(of: report.track.sourceURL, root: deviceRoot))
            for candidate in Self.candidates(for: report.track, in: library, tolerance: durationTolerance) {
                if await check(candidate).isPlayable { item.replacement = candidate; break }
            }
            broken.append(item)
        }
        return broken.sorted { $0.devicePath < $1.devicePath }
    }

    /// Library tracks that are the same recording as `track`: same normalised
    /// artist and title, similar length. Lossless first, then larger.
    static func candidates(for track: Track, in library: [Track], tolerance: Double) -> [Track] {
        let artist = Duplicates.normalise(track.effectiveArtist)
        let title = Duplicates.normalise(track.effectiveTitle)
        return library.filter { other in
            guard Duplicates.normalise(other.effectiveArtist) == artist,
                  Duplicates.normalise(other.effectiveTitle) == title else { return false }
            if let a = track.durationSeconds, let b = other.durationSeconds {
                return abs(a - b) <= tolerance
            }
            return true
        }
        .sorted {
            let l0 = Duplicates.isLossless($0), l1 = Duplicates.isLossless($1)
            return l0 != l1 ? l0 : $0.fileSize > $1.fileSize
        }
    }

    // MARK: Fix

    public struct Outcome: Sendable {
        public var replaced = 0
        public var removed = 0
        public var failed: [String] = []
        public init() {}
    }

    /// Move the broken files into quarantine (so Undo can bring them back),
    /// then copy each good library copy into the same place. Files without a
    /// replacement are only removed when `removeUnrepairable` is set.
    public func fix(
        _ items: [BrokenFile], deviceRoot: URL, removeUnrepairable: Bool,
        engine: SyncEngine = SyncEngine(),
        label: String = "repair broken files"
    ) -> Outcome {
        var outcome = Outcome()
        let undo = UndoRecorder(deviceRoot: deviceRoot)
        var actions: [SyncAction] = []

        for item in items {
            guard item.replacement != nil || removeUnrepairable else { continue }
            guard undo.quarantine(item.report.track.sourceURL, path: item.devicePath) else {
                outcome.failed.append(item.devicePath)
                continue
            }
            if let good = item.replacement {
                actions.append(SyncAction(kind: .copy, track: good, devicePath: item.devicePath))
            } else {
                outcome.removed += 1
            }
        }

        if !actions.isEmpty {
            let plan = SyncPlan(actions: actions)
            if let result = try? engine.execute(plan: plan, deviceRoot: deviceRoot) {
                outcome.replaced = result.copied
                outcome.failed.append(contentsOf: result.failed.map(\.path))
            } else {
                outcome.failed.append(contentsOf: actions.map(\.devicePath))
            }
        }

        undo.finish(label: label)
        return outcome
    }
}
