import Foundation

public typealias JSON = [String: Any]

/// Writes one JSON object per line. The window reads these lines as they arrive,
/// so progress shows while a long command is still running.
public final class Emitter: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: (Data) -> Void

    public init(sink: @escaping (Data) -> Void) { self.sink = sink }

    public static func stdout() -> Emitter {
        Emitter { data in
            FileHandle.standardOutput.write(data)
        }
    }

    public func send(_ object: JSON) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        sink(data)
    }

    /// `fraction` nil means "working, no known end".
    public func progress(_ fraction: Double?, _ label: String) {
        send(["event": "progress", "fraction": fraction.map { $0 as Any } ?? NSNull(), "label": label])
    }
}

public struct APIError: Error, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Thread-safe "the user pressed Stop".
public final class StopSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    public init() {}
    public var isSet: Bool { lock.lock(); defer { lock.unlock() }; return on }
    public func set() { lock.lock(); on = true; lock.unlock() }
    public func reset() { lock.lock(); on = false; lock.unlock() }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? { (self[key] as? Int) ?? (self[key] as? Double).map(Int.init) }
    func double(_ key: String) -> Double? { (self[key] as? Double) ?? (self[key] as? Int).map(Double.init) }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }
    func strings(_ key: String) -> [String]? { self[key] as? [String] }
}

/// A short stable id for things the window refers to later (FNV-1a).
func stableID(_ text: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return String(h, radix: 16)
}

func countLabel(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
