import Foundation

extension FLAC {
    /// A cheap "is the end of this file there?" check that needs no decoding.
    ///
    /// FLAC has no seek table in most rips, so asking AVFoundation for the last
    /// seconds makes it decode the whole file — gigabytes over USB for a
    /// library. Instead: STREAMINFO says how many samples the stream holds,
    /// and the last frame header in the final bytes of the file says where the
    /// stream actually ends. A copy that was cut off ends many seconds short.
    ///
    /// Returns a description when the file looks cut off, nil when it looks
    /// complete *or when this cannot tell* (unknown length, no frame found).
    /// A header found by chance can fool it, so a positive is only a suspicion
    /// — callers confirm by decoding the tail before calling a file broken.
    public static func truncationReason(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let info = streamInfo(url), info.totalSamples > 0, info.sampleRate > 0,
              info.maxBlock > 0 else { return nil }
        let (total, sampleRate, maxBlock, minBlock) = (info.totalSamples, info.sampleRate, info.maxBlock, info.minBlock)
        let audioOffset = info.audioOffset
        guard let end = try? handle.seekToEnd(), end > audioOffset else { return nil }
        let window = min(UInt64(256 * 1024), end - audioOffset)
        guard (try? handle.seek(toOffset: end - window)) != nil,
              let tail = try? handle.read(upToCount: Int(window)) else { return nil }
        let bytes = [UInt8](tail)

        // Last valid frame header, searching backwards.
        var i = bytes.count - 6
        while i >= 0 {
            if bytes[i] == 0xFF, bytes[i + 1] & 0xFE == 0xF8,
               let frame = parseFrameHeader(bytes, at: i, fixedBlock: minBlock == maxBlock ? maxBlock : nil) {
                let streamEnd = frame.firstSample + frame.blockSize
                let missing = total - streamEnd
                // Tolerate a block or two: encoders differ on how the short
                // last frame is described.
                guard missing > 2 * maxBlock else { return nil }
                let seconds = Double(missing) / Double(sampleRate)
                return String(format: "the file ends about %.0f s before the track does — cut off", seconds)
            }
            i -= 1
        }
        return nil
    }

    struct FrameHeader { var firstSample: Int; var blockSize: Int }

    /// Parse and CRC-8 check a frame header at `i`; nil if it is not one.
    static func parseFrameHeader(_ b: [UInt8], at i: Int, fixedBlock: Int?) -> FrameHeader? {
        guard i + 6 <= b.count else { return nil }
        let variable = b[i + 1] & 0x01 == 1
        let blockCode = Int(b[i + 2] >> 4), rateCode = Int(b[i + 2] & 0x0F)
        guard blockCode != 0, rateCode != 15, b[i + 3] & 0x01 == 0 else { return nil }

        // UTF-8 style number: frame number (fixed) or sample number (variable).
        var p = i + 4
        let lead = b[p]
        let extra: Int
        switch lead {
        case 0x00...0x7F: extra = 0
        case 0xC0...0xDF: extra = 1
        case 0xE0...0xEF: extra = 2
        case 0xF0...0xF7: extra = 3
        case 0xF8...0xFB: extra = 4
        case 0xFC...0xFD: extra = 5
        case 0xFE: extra = 6
        default: return nil
        }
        guard p + 1 + extra <= b.count else { return nil }
        var number = extra == 0 ? Int(lead) : Int(lead) & (0x3F >> extra)
        p += 1
        for _ in 0..<extra {
            guard b[p] & 0xC0 == 0x80 else { return nil }
            number = number << 6 | Int(b[p] & 0x3F)
            p += 1
        }

        var blockSize: Int
        switch blockCode {
        case 1: blockSize = 192
        case 2...5: blockSize = 576 << (blockCode - 2)
        case 6:
            guard p < b.count else { return nil }
            blockSize = Int(b[p]) + 1; p += 1
        case 7:
            guard p + 1 < b.count else { return nil }
            blockSize = (Int(b[p]) << 8 | Int(b[p + 1])) + 1; p += 2
        default: blockSize = 256 << (blockCode - 8)
        }
        switch rateCode {
        case 12: p += 1
        case 13, 14: p += 2
        default: break
        }
        guard p < b.count, crc8(b[i..<p]) == b[p] else { return nil }

        let first = variable ? number : number * (fixedBlock ?? blockSize)
        return FrameHeader(firstSample: first, blockSize: blockSize)
    }

    static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? crc << 1 ^ 0x07 : crc << 1 }
        }
        return crc
    }
}
