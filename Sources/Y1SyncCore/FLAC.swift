import Foundation

/// Reads FLAC metadata directly.
///
/// AVFoundation does not surface Vorbis comments for FLAC, so a library of
/// FLAC files reads back as "Unknown Artist / Unknown Album" through the
/// common-metadata API. FLAC's container is simple enough to parse properly,
/// which also gives access to the embedded PICTURE block.
public enum FLAC {
    /// Tag names are case-insensitive in Vorbis comments; values are UTF-8.
    public struct Metadata: Sendable {
        public var fields: [String: String] = [:]
        public var pictures: [Picture] = []

        public subscript(_ key: String) -> String? {
            fields[key.uppercased()]
        }
    }

    public struct Picture: Sendable {
        public var type: Int
        public var mimeType: String
        public var width: Int
        public var height: Int
        public var data: Data
    }

    enum BlockType: UInt8 {
        case streamInfo = 0, padding = 1, application = 2, seekTable = 3
        case vorbisComment = 4, cueSheet = 5, picture = 6
    }

    public static func isFLAC(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "flac"
    }

    /// Parse the metadata blocks at the head of a FLAC file.
    ///
    /// Only the metadata is read; the audio frames that follow are ignored,
    /// so this stays cheap even on large lossless files.
    ///
    /// `includePictures: false` seeks past embedded cover art instead of reading
    /// it — the art is typically 100 KB–1 MB per file, which on a USB 2.0 player
    /// reading ~5 MB/s is most of the time spent scanning tags.
    public static func read(_ url: URL, includePictures: Bool = true) -> Metadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else {
            return nil
        }

        var meta = Metadata()

        while true {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            let bytes = [UInt8](header)
            let isLast = bytes[0] & 0x80 != 0
            let type = BlockType(rawValue: bytes[0] & 0x7F)
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])

            // Guard against a corrupt length claiming a huge block.
            guard length >= 0, length < 64 * 1024 * 1024 else { break }

            switch type {
            case .vorbisComment:
                if let body = try? handle.read(upToCount: length), body.count == length {
                    parseVorbisComment(body, into: &meta)
                }
            case .picture where includePictures:
                if let body = try? handle.read(upToCount: length), body.count == length,
                   let picture = parsePicture(body) {
                    meta.pictures.append(picture)
                }
            default:
                _ = try? handle.seek(toOffset: handle.offsetInFile + UInt64(length))
            }

            if isLast { break }
        }

        return meta
    }

    static func parseVorbisComment(_ data: Data, into meta: inout Metadata) {
        var offset = 0

        func readUInt32LE() -> Int? {
            guard offset + 4 <= data.count else { return nil }
            let b = [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + 4])
            offset += 4
            return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        }

        // Vendor string, which we skip.
        guard let vendorLength = readUInt32LE(), vendorLength >= 0,
              offset + vendorLength <= data.count else { return }
        offset += vendorLength

        guard let count = readUInt32LE(), count >= 0, count < 10_000 else { return }

        for _ in 0..<count {
            guard let length = readUInt32LE(), length >= 0,
                  offset + length <= data.count else { return }
            let raw = data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + length)
            offset += length

            guard let entry = String(data: raw, encoding: .utf8),
                  let sep = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[entry.startIndex..<sep]).uppercased()
            let value = String(entry[entry.index(after: sep)...])
            // First occurrence wins; multi-value tags repeat the same key.
            if meta.fields[key] == nil { meta.fields[key] = value }
        }
    }

    static func parsePicture(_ data: Data) -> Picture? {
        var offset = 0
        let base = data.startIndex

        func readUInt32BE() -> Int? {
            guard offset + 4 <= data.count else { return nil }
            let b = [UInt8](data[base + offset ..< base + offset + 4])
            offset += 4
            return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        }

        func readString() -> String? {
            guard let length = readUInt32BE(), length >= 0, offset + length <= data.count
            else { return nil }
            let s = String(data: data.subdata(in: base + offset ..< base + offset + length),
                           encoding: .utf8)
            offset += length
            return s
        }

        guard let type = readUInt32BE(),
              let mime = readString(),
              readString() != nil,                 // description
              let width = readUInt32BE(),
              let height = readUInt32BE(),
              readUInt32BE() != nil,               // colour depth
              readUInt32BE() != nil,               // indexed colours
              let dataLength = readUInt32BE(),
              dataLength >= 0, offset + dataLength <= data.count
        else { return nil }

        let payload = data.subdata(in: base + offset ..< base + offset + dataLength)
        return Picture(type: type, mimeType: mime, width: width, height: height, data: payload)
    }

    /// Front cover if there is one, else the first picture present.
    public static func frontCover(_ meta: Metadata) -> Picture? {
        meta.pictures.first { $0.type == 3 } ?? meta.pictures.first
    }
}

// MARK: - Writing

extension FLAC {
    /// A raw metadata block, kept verbatim so blocks we do not understand
    /// (SEEKTABLE, CUESHEET, application data) survive a rewrite untouched.
    public struct Block {
        public var type: UInt8
        public var data: Data
    }

    public struct StreamInfo: Sendable {
        public var sampleRate: Int
        public var bitsPerSample: Int = 0
        public var totalSamples: Int
        public var minBlock: Int
        public var maxBlock: Int
        /// Where the audio frames begin, i.e. the size of all metadata.
        public var audioOffset: UInt64

        /// Length in seconds; nil when the encoder did not record the sample count.
        public var duration: Double? {
            totalSamples > 0 && sampleRate > 0 ? Double(totalSamples) / Double(sampleRate) : nil
        }
    }

    /// STREAMINFO plus the audio offset, reading only block headers and the
    /// 34-byte STREAMINFO body — every other block (cover art, seek table,
    /// comments) is skipped with a seek, so this costs a few KB of reads.
    public static func streamInfo(_ url: URL) -> StreamInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }

        var offset: UInt64 = 4
        var info: (rate: Int, bits: Int, total: Int, minB: Int, maxB: Int)?
        while true {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return nil }
            let b = [UInt8](header)
            let isLast = b[0] & 0x80 != 0
            let length = Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard length < 64 * 1024 * 1024 else { return nil }

            if b[0] & 0x7F == BlockType.streamInfo.rawValue, length >= 34 {
                guard let body = try? handle.read(upToCount: length), body.count == length else { return nil }
                let si = [UInt8](body)
                info = (Int(si[10]) << 12 | Int(si[11]) << 4 | Int(si[12] >> 4),
                        (Int(si[12] & 1) << 4 | Int(si[13] >> 4)) + 1,
                        Int(si[13] & 0x0F) << 32 | Int(si[14]) << 24 | Int(si[15]) << 16
                            | Int(si[16]) << 8 | Int(si[17]),
                        Int(si[0]) << 8 | Int(si[1]), Int(si[2]) << 8 | Int(si[3]))
            } else {
                guard (try? handle.seek(toOffset: offset + 4 + UInt64(length))) != nil else { return nil }
            }
            offset += 4 + UInt64(length)
            if isLast { break }
        }
        guard let info else { return nil }
        return StreamInfo(sampleRate: info.rate, bitsPerSample: info.bits, totalSamples: info.total,
                          minBlock: info.minB, maxBlock: info.maxB, audioOffset: offset)
    }

    /// Read every metadata block plus the offset where audio frames begin.
    public static func readBlocks(_ url: URL) -> (blocks: [Block], audioOffset: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else {
            return nil
        }

        var blocks: [Block] = []
        var offset: UInt64 = 4

        while true {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return nil }
            let bytes = [UInt8](header)
            let isLast = bytes[0] & 0x80 != 0
            let type = bytes[0] & 0x7F
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            guard length >= 0, length < 64 * 1024 * 1024 else { return nil }

            guard let body = try? handle.read(upToCount: length), body.count == length else {
                return nil
            }
            blocks.append(Block(type: type, data: body))
            offset += 4 + UInt64(length)

            if isLast { break }
        }

        return (blocks, offset)
    }

    /// Encode a PICTURE metadata block for a JPEG cover.
    public static func makePictureBlock(jpeg: Data, width: Int, height: Int) -> Data {
        func be(_ v: Int) -> Data {
            Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                  UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
        }

        var out = Data()
        out.append(be(3))                                   // front cover
        let mime = Data("image/jpeg".utf8)
        out.append(be(mime.count)); out.append(mime)
        out.append(be(0))                                   // empty description
        out.append(be(width))
        out.append(be(height))
        out.append(be(24))                                  // colour depth
        out.append(be(0))                                   // not indexed
        out.append(be(jpeg.count)); out.append(jpeg)
        return out
    }

    /// Encode a VORBIS_COMMENT block from a field dictionary.
    public static func makeVorbisComment(_ fields: [String: String],
                                         vendor: String = "Y1Sync") -> Data {
        func le(_ v: Int) -> Data {
            Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                  UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }

        var out = Data()
        let vendorData = Data(vendor.utf8)
        out.append(le(vendorData.count)); out.append(vendorData)

        let entries = fields.sorted { $0.key < $1.key }
            .map { Data("\($0.key)=\($0.value)".utf8) }
        out.append(le(entries.count))
        for e in entries { out.append(le(e.count)); out.append(e) }
        return out
    }

    /// Rewrite a FLAC file with replaced artwork and/or tag fields.
    ///
    /// Audio frames are copied through byte-for-byte — only the metadata
    /// blocks at the head of the file are rebuilt, so this is lossless and
    /// fast even on large files.
    @discardableResult
    public static func rewrite(
        from source: URL,
        to destination: URL,
        artwork: Data? = nil,
        artworkSize: (width: Int, height: Int)? = nil,
        fields: [String: String]? = nil
    ) throws -> Bool {
        guard let (blocks, audioOffset) = readBlocks(source) else { return false }

        var rebuilt: [Block] = []
        for block in blocks {
            switch BlockType(rawValue: block.type) {
            case .picture where artwork != nil:
                continue                       // replaced below
            case .padding:
                continue                       // dropped; it only wastes space
            case .vorbisComment where fields != nil:
                continue                       // replaced below
            default:
                rebuilt.append(block)
            }
        }

        if let fields {
            rebuilt.append(Block(type: BlockType.vorbisComment.rawValue,
                                 data: makeVorbisComment(fields)))
        }
        if let artwork, let size = artworkSize {
            rebuilt.append(Block(type: BlockType.picture.rawValue,
                                 data: makePictureBlock(jpeg: artwork,
                                                        width: size.width,
                                                        height: size.height)))
        }

        // STREAMINFO must stay first; everything else may follow in any order.
        if let i = rebuilt.firstIndex(where: { $0.type == BlockType.streamInfo.rawValue }), i != 0 {
            rebuilt.swapAt(0, i)
        }
        guard !rebuilt.isEmpty else { return false }

        var header = Data("fLaC".utf8)
        for (i, block) in rebuilt.enumerated() {
            let isLast = i == rebuilt.count - 1
            let length = block.data.count
            guard length < 1 << 24 else { return false }
            header.append((isLast ? 0x80 : 0x00) | (block.type & 0x7F))
            header.append(UInt8((length >> 16) & 0xFF))
            header.append(UInt8((length >> 8) & 0xFF))
            header.append(UInt8(length & 0xFF))
            header.append(block.data)
        }

        // Stream the audio rather than loading a whole lossless file into RAM.
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try input.seek(toOffset: audioOffset)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        try output.write(contentsOf: header)
        while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        return true
    }
}
