import Foundation

/// Minimal ID3v2 reader/writer, enough to replace embedded cover art without
/// touching the audio.
///
/// Re-encoding the audio to change a picture would be slow and lossy, so this
/// rewrites only the tag and copies the original MPEG frames through
/// byte-for-byte.
public enum ID3v2 {
    public struct Frame {
        public var id: String
        public var flags: UInt16
        public var body: Data
    }

    public struct Tag {
        public var majorVersion: UInt8
        public var revision: UInt8
        public var flags: UInt8
        public var frames: [Frame]
        /// Offset in the file where audio begins.
        public var audioOffset: Int
    }

    /// ID3 sizes are "syncsafe": 7 bits per byte, so the pattern never looks
    /// like an MPEG frame sync.
    static func syncsafe(_ bytes: [UInt8]) -> Int {
        var value = 0
        for b in bytes { value = (value << 7) | Int(b & 0x7F) }
        return value
    }

    static func makeSyncsafe(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
         UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    static func bigEndian(_ bytes: [UInt8]) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    static func makeBigEndian(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// Parse the tag at the start of `data`. Returns nil when there is none.
    public static func parse(_ data: Data) -> Tag? {
        guard data.count >= 10 else { return nil }
        let bytes = [UInt8](data.prefix(10))
        guard bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return nil } // "ID3"

        let major = bytes[3]
        guard major == 3 || major == 4 else { return nil } // v2.2 uses 3-char ids
        let flags = bytes[5]
        let tagSize = syncsafe(Array(bytes[6..<10]))
        let audioOffset = 10 + tagSize

        var cursor = 10
        // An extended header, when present, sits before the first frame.
        if flags & 0x40 != 0, data.count >= cursor + 4 {
            let ext = [UInt8](data[cursor..<cursor + 4])
            let extSize = major == 4 ? syncsafe(ext) : bigEndian(ext)
            cursor += major == 4 ? extSize : extSize + 4
        }

        var frames: [Frame] = []
        let end = min(audioOffset, data.count)

        while cursor + 10 <= end {
            let header = [UInt8](data[cursor..<cursor + 10])
            // Padding is zero-filled; the first null id means we're done.
            if header[0] == 0 { break }

            guard let id = String(bytes: header[0..<4], encoding: .isoLatin1) else { break }
            let sizeBytes = Array(header[4..<8])
            // v2.4 made frame sizes syncsafe; v2.3 left them plain big-endian.
            let size = major == 4 ? syncsafe(sizeBytes) : bigEndian(sizeBytes)
            let frameFlags = UInt16(header[8]) << 8 | UInt16(header[9])

            let bodyStart = cursor + 10
            let bodyEnd = bodyStart + size
            guard size >= 0, bodyEnd <= end else { break }

            frames.append(Frame(id: id, flags: frameFlags,
                                body: data.subdata(in: bodyStart..<bodyEnd)))
            cursor = bodyEnd
        }

        return Tag(majorVersion: major, revision: bytes[4], flags: flags,
                   frames: frames, audioOffset: audioOffset)
    }

    /// Build an APIC frame body holding a JPEG front cover.
    public static func makeAPICBody(jpeg: Data) -> Data {
        var body = Data()
        body.append(0x00)                                   // ISO-8859-1 text
        body.append(contentsOf: Array("image/jpeg".utf8))
        body.append(0x00)                                   // mime terminator
        body.append(0x03)                                   // picture type: front cover
        body.append(0x00)                                   // empty description
        body.append(jpeg)
        return body
    }

    /// Serialise a tag back to bytes.
    static func serialise(_ tag: Tag, frames: [Frame]) -> Data {
        var frameData = Data()
        for f in frames {
            var idBytes = Array(f.id.utf8)
            // Frame ids are always exactly four characters.
            while idBytes.count < 4 { idBytes.append(0x20) }
            frameData.append(contentsOf: idBytes.prefix(4))
            frameData.append(contentsOf: tag.majorVersion == 4
                             ? makeSyncsafe(f.body.count)
                             : makeBigEndian(f.body.count))
            frameData.append(UInt8(f.flags >> 8))
            frameData.append(UInt8(f.flags & 0xFF))
            frameData.append(f.body)
        }

        var out = Data()
        out.append(contentsOf: Array("ID3".utf8))
        out.append(tag.majorVersion)
        out.append(tag.revision)
        // Drop the unsynchronisation and extended-header bits: neither is
        // reproduced here, so advertising them would misdescribe the tag.
        out.append(tag.flags & ~0xC0)
        out.append(contentsOf: makeSyncsafe(frameData.count))
        out.append(frameData)
        return out
    }

    /// Encode a text frame body as ISO-8859-1 where possible, UTF-16 otherwise.
    /// Falling back matters for non-Latin artist names, which would otherwise
    /// be written as mangled bytes.
    public static func makeTextBody(_ value: String) -> Data {
        var body = Data()
        if let latin = value.data(using: .isoLatin1) {
            body.append(0x00)
            body.append(latin)
        } else {
            body.append(0x01)                       // UTF-16 with BOM
            body.append(contentsOf: [0xFF, 0xFE])   // little-endian BOM
            for unit in Array(value.utf16) {
                body.append(UInt8(unit & 0xFF))
                body.append(UInt8(unit >> 8))
            }
        }
        return body
    }

    /// Rewrite `data`, optionally replacing the embedded picture and any text
    /// frames given as frame-id to value. Returns nil when there is no tag.
    public static func rewriting(
        _ data: Data,
        artwork jpeg: Data? = nil,
        textFrames: [String: String] = [:]
    ) -> Data? {
        guard let tag = parse(data), tag.audioOffset <= data.count else { return nil }

        var frames = tag.frames
        if jpeg != nil {
            // Drop every existing picture frame; some files carry several.
            frames = frames.filter { $0.id != "APIC" && $0.id != "PIC" }
        }
        if !textFrames.isEmpty {
            frames = frames.filter { textFrames[$0.id] == nil }
        }
        for (id, value) in textFrames.sorted(by: { $0.key < $1.key }) {
            frames.append(Frame(id: id, flags: 0, body: makeTextBody(value)))
        }
        if let jpeg {
            frames.append(Frame(id: "APIC", flags: 0, body: makeAPICBody(jpeg: jpeg)))
        }

        var out = serialise(tag, frames: frames)
        out.append(data.subdata(in: tag.audioOffset..<data.count))
        return out
    }

    /// Rewrite `data` so its embedded picture frames are replaced by `jpeg`.
    public static func replacingArtwork(in data: Data, with jpeg: Data) -> Data? {
        rewriting(data, artwork: jpeg)
    }

    /// Extract the first embedded picture, if any.
    public static func artwork(in data: Data) -> Data? {
        guard let tag = parse(data) else { return nil }
        guard let frame = tag.frames.first(where: { $0.id == "APIC" }) else { return nil }
        return pictureData(fromAPIC: frame.body)
    }

    static func pictureData(fromAPIC body: Data) -> Data? {
        guard body.count > 4 else { return nil }
        let bytes = [UInt8](body)
        var i = 1                                   // skip text encoding

        while i < bytes.count, bytes[i] != 0 { i += 1 }   // mime type
        guard i < bytes.count else { return nil }
        i += 1                                      // mime terminator
        guard i < bytes.count else { return nil }
        i += 1                                      // picture type

        let encoding = bytes[0]
        if encoding == 1 || encoding == 2 {
            // UTF-16 descriptions terminate with two zero bytes.
            while i + 1 < bytes.count, !(bytes[i] == 0 && bytes[i + 1] == 0) { i += 1 }
            i += 2
        } else {
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            i += 1
        }

        guard i < bytes.count else { return nil }
        return body.subdata(in: i..<body.count)
    }
}
