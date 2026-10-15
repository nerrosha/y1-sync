import Foundation
#if os(Windows)
import WinSDK
#endif

/// A removable volume that looks like it could be the player.
public struct Device: Sendable, Hashable {
    public var name: String
    public var url: URL
    public var totalBytes: Int64
    public var freeBytes: Int64
    /// True when a `.rockbox` folder is present, i.e. custom firmware is installed.
    public var hasRockbox: Bool

    public init(name: String, url: URL, totalBytes: Int64, freeBytes: Int64, hasRockbox: Bool) {
        self.name = name
        self.url = url
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.hasRockbox = hasRockbox
    }
}

public enum DeviceError: Error, CustomStringConvertible {
    case noDeviceFound
    case ambiguous([Device])
    case notWritable(URL)
    case insufficientSpace(needed: Int64, free: Int64)

    public var description: String {
        switch self {
        case .noDeviceFound:
            return """
            No removable volume found. Connect the Y1 by USB and enable USB \
            storage on the player itself — it does not mount until you do.
            """
        case .ambiguous(let devices):
            let names = devices.map(\.name).joined(separator: ", ")
            return "Several removable volumes are connected (\(names)). Pass --device to choose one."
        case .notWritable(let url):
            return "\(url.path) is not writable — it may be mounted read-only."
        case .insufficientSpace(let needed, let free):
            return """
            Not enough space: need \(ByteFormat.string(needed)), \
            \(ByteFormat.string(free)) free.
            """
        }
    }
}

public struct DeviceFinder: Sendable {
    public init() {}

    /// Every mounted volume that is removable or ejectable. The Y1 exposes
    /// plain USB mass storage with no distinguishing vendor string, so this
    /// cannot identify it definitively — it narrows to candidates and lets the
    /// caller confirm rather than guessing and writing to the wrong disk.
    public func candidates() -> [Device] {
        #if os(Windows)
        return windowsCandidates()
        #else
        return macCandidates()
        #endif
    }

    #if os(Windows)
    /// Removable drives (USB sticks, SD cards and players that mount as one), plus any
    /// other non-system drive that already looks like a Y1.
    func windowsCandidates() -> [Device] {
        let mask = GetLogicalDrives()
        var found: [Device] = []
        for i in 0..<26 where mask & (1 << UInt32(i)) != 0 {
            let letter = String(UnicodeScalar(UInt8(65 + i)))
            let root = "\(letter):\\"
            let kind = root.withCString(encodedAs: UTF16.self) { GetDriveTypeW($0) }
            let url = URL(fileURLWithPath: root)
            let fm = FileManager.default
            let looksLikeY1 = fm.fileExists(atPath: url.appendingPathComponent(".rockbox").path)
                || fm.fileExists(atPath: url.appendingPathComponent(".y1_library_cache.json").path)
                || fm.fileExists(atPath: url.appendingPathComponent("Y1_Themes").path)
            guard kind == 2 || (kind == 3 && letter != "C" && looksLikeY1) else { continue }

            var label = [UInt16](repeating: 0, count: 261)
            _ = root.withCString(encodedAs: UTF16.self) { r in
                GetVolumeInformationW(r, &label, DWORD(label.count), nil, nil, nil, nil, 0)
            }
            let name = String(decoding: label.prefix { $0 != 0 }, as: UTF16.self)
            var free = ULARGE_INTEGER(), total = ULARGE_INTEGER(), totalFree = ULARGE_INTEGER()
            _ = root.withCString(encodedAs: UTF16.self) { r in GetDiskFreeSpaceExW(r, &free, &total, &totalFree) }

            found.append(Device(
                name: name.isEmpty ? "\(letter):" : name,
                url: url,
                totalBytes: Int64(total.QuadPart),
                freeBytes: Int64(free.QuadPart),
                hasRockbox: fm.fileExists(atPath: url.appendingPathComponent(".rockbox").path)))
        }
        return found
    }
    #else
    func macCandidates() -> [Device] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsInternalKey,
        ]

        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return mounted.compactMap { url -> Device? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let removable = (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false)
            let internalDisk = values.volumeIsInternal ?? false
            guard removable, !internalDisk else { return nil }

            let rockbox = FileManager.default.fileExists(
                atPath: url.appendingPathComponent(".rockbox").path
            )

            return Device(
                name: values.volumeName ?? url.lastPathComponent,
                url: url,
                totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                freeBytes: Int64(values.volumeAvailableCapacity ?? 0),
                hasRockbox: rockbox
            )
        }
    }
    #endif

    /// Pick a single device, preferring one that has Rockbox installed.
    public func resolve(preferredName: String?) throws -> Device {
        let found = candidates()
        if let name = preferredName {
            guard let match = found.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { throw DeviceError.noDeviceFound }
            return match
        }

        if found.isEmpty { throw DeviceError.noDeviceFound }
        if found.count == 1 { return found[0] }

        let rockboxed = found.filter(\.hasRockbox)
        if rockboxed.count == 1 { return rockboxed[0] }

        throw DeviceError.ambiguous(found)
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}
