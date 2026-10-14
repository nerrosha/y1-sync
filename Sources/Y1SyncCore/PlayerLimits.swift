import Foundation

/// What the player is allowed to be given. The firmware's real limits are not
/// documented, so nothing is limited until the user sets a limit after finding
/// files that do not play; a file above a limit is then reported like any other
/// file that will not play (skipped on sync, replaced from the library when a
/// copy within the limits exists).
public struct PlayerLimits: Sendable, Equatable, Codable {
    /// Highest sample rate in Hz, nil for no limit.
    public var maxSampleRate: Int?
    /// Highest bit depth, nil for no limit.
    public var maxBitDepth: Int?
    public var allowALAC: Bool

    public init(maxSampleRate: Int? = nil, maxBitDepth: Int? = nil, allowALAC: Bool = true) {
        self.maxSampleRate = maxSampleRate
        self.maxBitDepth = maxBitDepth
        self.allowALAC = allowALAC
    }

    public static let none = PlayerLimits()
    public var isUnlimited: Bool { self == .none }

    /// Why `track` breaks the limits, nil when it is fine.
    public func problem(for track: Track) -> String? {
        if !allowALAC, track.codec == "ALAC" { return "ALAC (Apple Lossless) is not allowed" }
        if let max = maxSampleRate, let rate = track.sampleRate, rate > max {
            return "\(Self.kHz(rate)) is above the \(Self.kHz(max)) limit"
        }
        if let max = maxBitDepth, let bits = track.bitDepth, bits > max {
            return "\(bits)-bit is above the \(max)-bit limit"
        }
        return nil
    }

    public static func kHz(_ hz: Int) -> String {
        let k = Double(hz) / 1000
        return (k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)) + " kHz"
    }

    /// "FLAC 24-bit 96 kHz", "ALAC 16-bit 44.1 kHz", "MP3".
    public static func label(for track: Track) -> String {
        var parts = [track.codec ?? track.fileExtension.uppercased()]
        if let b = track.bitDepth, b > 0 { parts.append("\(b)-bit") }
        if let r = track.sampleRate { parts.append(kHz(r)) }
        return parts.joined(separator: " ")
    }

    /// Tracks per format, most common first.
    public static func summary(of tracks: [Track]) -> [(label: String, count: Int)] {
        Dictionary(grouping: tracks, by: { label(for: $0) })
            .map { (label: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }
}
