import Foundation

/// Reads and rewrites a few text tags of an MP4/M4A file (the `ilst` atom).
///
/// Only the metadata atoms change. The audio (`mdat`) is copied byte for byte;
/// when the new metadata is a different size and the file keeps its index
/// (`moov`) before the audio, the chunk offsets in `stco`/`co64` are shifted so
/// the file still plays.
public enum MP4Tags {
    /// Vorbis-style field name → iTunes atom type.
    static let names: [String: [UInt8]] = [
        "ALBUM": [0xA9, 0x61, 0x6C, 0x62],        // ©alb
        "ARTIST": [0xA9, 0x41, 0x52, 0x54],       // ©ART
        "ALBUMARTIST": [0x61, 0x41, 0x52, 0x54],  // aART
    ]

    // MARK: Atom parsing

    struct Atom {
        var type: [UInt8]
        var start: Int
        var header: Int
        var end: Int
        var bodyStart: Int { start + header }
    }

    static func atoms(in data: Data, from: Int, to: Int) -> [Atom]? {
        var out: [Atom] = []
        var pos = from
        while pos < to {
            guard pos + 8 <= to else { return nil }
            var size = Int(be32(data, pos))
            let type = Array(data[data.startIndex + pos + 4 ..< data.startIndex + pos + 8])
            var header = 8
            if size == 1 {
                guard pos + 16 <= to else { return nil }
                size = Int(be64(data, pos + 8)); header = 16
            } else if size == 0 {
                size = to - pos
            }
            guard size >= header, pos + size <= to else { return nil }
            out.append(Atom(type: type, start: pos, header: header, end: pos + size))
            pos += size
        }
        return out
    }

    static func be32(_ d: Data, _ i: Int) -> UInt32 {
        let b = d.startIndex + i
        return UInt32(d[b]) << 24 | UInt32(d[b + 1]) << 16 | UInt32(d[b + 2]) << 8 | UInt32(d[b + 3])
    }
    static func be64(_ d: Data, _ i: Int) -> UInt64 { UInt64(be32(d, i)) << 32 | UInt64(be32(d, i + 4)) }
    static func put32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    static func atom(_ type: [UInt8], _ body: Data) -> Data {
        Data(put32(UInt32(body.count + 8)) + type) + body
    }

    // MARK: Read

    public static func read(_ url: URL, fields: [String]) -> [String: String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let ilst = locateIlst(data) else { return [:] }
        var out: [String: String] = [:]
        for item in atoms(in: data, from: ilst.bodyStart, to: ilst.end) ?? [] {
            guard let (name, _) = names.first(where: { $0.value == item.type }),
                  fields.contains(name),
                  let child = atoms(in: data, from: item.bodyStart, to: item.end)?.first(where: { $0.type == Array("data".utf8) }),
                  child.end - child.bodyStart > 8,
                  let s = String(data: data[data.startIndex + child.bodyStart + 8 ..< data.startIndex + child.end], encoding: .utf8),
                  !s.isEmpty else { continue }
            out[name] = s
        }
        return out
    }

    private static func locateIlst(_ data: Data) -> Atom? {
        guard let top = atoms(in: data, from: 0, to: data.count),
              var cur = top.first(where: { $0.type == Array("moov".utf8) }) else { return nil }
        for name in ["udta", "meta", "ilst"] {
            // `meta` is a full box: version and flags come first.
            let from = cur.bodyStart + (cur.type == Array("meta".utf8) ? 4 : 0)
            guard let kids = atoms(in: data, from: from, to: cur.end),
                  let next = kids.first(where: { $0.type == Array(name.utf8) }) else { return nil }
            cur = next
        }
        return cur
    }

    // MARK: Write

    /// Apply `changes` (nil removes a field). False when the file is not a
    /// well-formed MP4 or is fragmented.
    @discardableResult
    public static func write(_ changes: [String: String?], in url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let out = rewriting(data, changes: changes) else { return false }
        return (try? out.write(to: url, options: .atomic)) != nil
    }

    static func rewriting(_ data: Data, changes: [String: String?]) -> Data? {
        guard let top = atoms(in: data, from: 0, to: data.count),
              let moov = top.first(where: { $0.type == Array("moov".utf8) }),
              !top.contains(where: { $0.type == Array("moof".utf8) }) else { return nil }

        let moovBody = data.subdata(in: data.startIndex + moov.bodyStart ..< data.startIndex + moov.end)
        guard var newBody = editChild(moovBody, "udta", initial: Data(), { udta in
            editChild(udta, "meta", initial: emptyMetaBody(), { meta in
                guard meta.count >= 4 else { return nil }
                let prefix = meta.prefix(4)
                let inner = Data(meta.dropFirst(4))
                guard let withIlst = editChild(inner, "ilst", initial: Data(), { ilst in
                    editIlst(ilst, changes)
                }) else { return nil }
                return Data(prefix) + withIlst
            })
        }) else { return nil }

        let delta = (newBody.count + 8) - (moov.end - moov.start)
        if delta != 0 {
            // The audio sits after the index: its offsets move with the index's size.
            shiftChunkOffsets(&newBody, by: delta, ifAtLeast: moov.end)
        }
        var out = data.subdata(in: data.startIndex ..< data.startIndex + moov.start)
        out.append(atom(Array("moov".utf8), newBody))
        out.append(data.subdata(in: data.startIndex + moov.end ..< data.endIndex))
        return out
    }

    private static func emptyMetaBody() -> Data {
        // version/flags, then the `hdlr` iTunes expects before `ilst`.
        let hdlr = Data([0, 0, 0, 0, 0, 0, 0, 0]) + Data("mdir".utf8) + Data("appl".utf8)
            + Data(repeating: 0, count: 9)
        return Data([0, 0, 0, 0]) + atom(Array("hdlr".utf8), hdlr)
    }

    /// Replace the body of child `name` (creating it from `initial` if absent).
    private static func editChild(_ body: Data, _ name: String, initial: Data,
                                  _ transform: (Data) -> Data?) -> Data? {
        let type = Array(name.utf8)
        guard let kids = atoms(in: body, from: 0, to: body.count) else { return nil }
        if let kid = kids.first(where: { $0.type == type }) {
            let inner = body.subdata(in: body.startIndex + kid.bodyStart ..< body.startIndex + kid.end)
            guard let new = transform(inner) else { return nil }
            return body.subdata(in: body.startIndex ..< body.startIndex + kid.start)
                + atom(type, new)
                + body.subdata(in: body.startIndex + kid.end ..< body.endIndex)
        }
        guard let new = transform(initial) else { return nil }
        return body + atom(type, new)
    }

    private static func editIlst(_ ilst: Data, _ changes: [String: String?]) -> Data? {
        guard let items = atoms(in: ilst, from: 0, to: ilst.count) else { return nil }
        var result = Data()
        var handled = Set<String>()
        for item in items {
            let raw = ilst.subdata(in: ilst.startIndex + item.start ..< ilst.startIndex + item.end)
            if let (name, type) = names.first(where: { $0.value == item.type }), let change = changes[name] {
                handled.insert(name)
                if let value = change { result += makeItem(type, value) }
                continue
            }
            result += raw
        }
        for (name, change) in changes.sorted(by: { $0.key < $1.key }) where !handled.contains(name) {
            if let type = names[name], let value = change { result += makeItem(type, value) }
        }
        return result
    }

    private static func makeItem(_ type: [UInt8], _ value: String) -> Data {
        let data = Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data(value.utf8)
        return atom(type, atom(Array("data".utf8), data))
    }

    /// Add `delta` to every chunk offset that points at or after `threshold`.
    private static func shiftChunkOffsets(_ moovBody: inout Data, by delta: Int, ifAtLeast threshold: Int) {
        func walk(_ from: Int, _ to: Int) {
            guard let kids = atoms(in: moovBody, from: from, to: to) else { return }
            for k in kids {
                let t = String(decoding: k.type, as: UTF8.self)
                if ["trak", "mdia", "minf", "stbl"].contains(t) {
                    walk(k.bodyStart, k.end)
                } else if t == "stco" || t == "co64" {
                    let wide = t == "co64"
                    let count = Int(be32(moovBody, k.bodyStart + 4))
                    var p = k.bodyStart + 8
                    for _ in 0..<count {
                        guard p + (wide ? 8 : 4) <= k.end else { return }
                        let base = moovBody.startIndex + p
                        if wide {
                            var v = be64(moovBody, p)
                            if Int(v) >= threshold { v = UInt64(Int(v) + delta) }
                            for i in 0..<8 { moovBody[base + i] = UInt8(v >> UInt64(56 - 8 * i) & 255) }
                        } else {
                            var v = Int(be32(moovBody, p))
                            if v >= threshold { v += delta }
                            for (i, b) in put32(UInt32(truncatingIfNeeded: v)).enumerated() { moovBody[base + i] = b }
                        }
                        p += wide ? 8 : 4
                    }
                }
            }
        }
        walk(0, moovBody.count)
    }
}
