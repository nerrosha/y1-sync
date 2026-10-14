import Foundation

/// One timed line of lyrics.
public struct LyricLine: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public var index: Int
    /// Seconds from the start of the track.
    public var time: TimeInterval
    public var text: String
}

/// Parser for `.lrc` files.
///
/// The format is `[mm:ss.xx] text`, but real files in the wild vary: hundredths
/// or thousandths, several timestamps on one line for a repeated chorus, and
/// `[ar:]`/`[ti:]` metadata headers that are not lyrics at all.
public enum LRC {
    public static func parse(_ text: String) -> [LyricLine] {
        var out: [(TimeInterval, String)] = []

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            var stamps: [TimeInterval] = []
            var cursor = line.startIndex

            // A line may carry several timestamps, all sharing one lyric.
            while cursor < line.endIndex, line[cursor] == "[" {
                guard let close = line[cursor...].firstIndex(of: "]") else { break }
                let inside = String(line[line.index(after: cursor)..<close])
                if let seconds = parseTimestamp(inside) {
                    stamps.append(seconds)
                } else if !inside.isEmpty, !inside.first!.isNumber {
                    // Metadata header such as [ar:Artist]; skip the whole line.
                    stamps.removeAll()
                    cursor = line.endIndex
                    break
                }
                cursor = line.index(after: close)
            }

            guard !stamps.isEmpty else { continue }
            let content = String(line[cursor...]).trimmingCharacters(in: .whitespaces)
            for s in stamps { out.append((s, content)) }
        }

        return out.sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(index: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    /// `mm:ss.xx`, `mm:ss.xxx` or `mm:ss`.
    static func parseTimestamp(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]) else { return nil }

        let secondsPart = parts[1].replacingOccurrences(of: ",", with: ".")
        guard let seconds = Double(secondsPart) else { return nil }
        guard minutes >= 0, seconds >= 0, seconds < 60 else { return nil }
        return minutes * 60 + seconds
    }

    /// Index of the line that should be highlighted at `time`, or nil before
    /// the first line starts.
    public static func activeIndex(of lines: [LyricLine], at time: TimeInterval) -> Int? {
        guard let first = lines.first, time >= first.time else { return nil }
        // Binary search for the last line whose timestamp has passed.
        var low = 0, high = lines.count - 1, found = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// Read and parse a `.lrc` sitting beside an audio file.
    public static func load(besideAudio url: URL) -> [LyricLine] {
        let lrc = url.deletingPathExtension().appendingPathExtension("lrc")
        guard let text = try? String(contentsOf: lrc, encoding: .utf8) else { return [] }
        return parse(text)
    }
}
