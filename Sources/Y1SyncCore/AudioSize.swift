import Foundation

/// The size of a file's audio payload alone — the file minus its leading
/// metadata (ID3v2 tag, FLAC metadata blocks).
///
/// Sync rewrites tags on the way to the player (cover shrunk, album artist
/// corrected) and Lyrics / Find art embed covers there later, so the copy's
/// total size never equals the source's. The audio bytes are never touched,
/// though, so this number is the same on both sides and tells "already synced"
/// from "truncated or different" without reading whole files over USB.
///
/// Only the containers we rewrite (MP3, FLAC) have a meaningful value; for
/// everything else the file is copied byte for byte and the caller compares
/// total sizes.
public enum AudioSize {
    public static func of(_ url: URL, size: Int64) -> Int64? {
        if FLAC.isFLAC(url) {
            guard let offset = FLAC.readBlocks(url)?.audioOffset else { return nil }
            return max(0, (fileSize(url) ?? size) - Int64(offset))
        }
        guard url.pathExtension.lowercased() == "mp3" else { return nil }
        let total = fileSize(url) ?? size
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 10) else { return nil }
        try? handle.close()
        if let tag = tagBytes(head) { return max(0, total - Int64(tag)) }
        return total
    }

    /// Length of the ID3v2 tag at the start of `head` (10 header bytes), if any.
    static func tagBytes(_ head: Data) -> Int? {
        let b = [UInt8](head)
        guard b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return nil }
        let footer = b[3] == 4 && b[5] & 0x10 != 0 ? 10 : 0
        return 10 + footer
            + (Int(b[6] & 0x7F) << 21 | Int(b[7] & 0x7F) << 14 | Int(b[8] & 0x7F) << 7 | Int(b[9] & 0x7F))
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}
