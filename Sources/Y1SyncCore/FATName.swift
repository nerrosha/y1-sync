import Foundation

/// The Y1 mounts as USB mass storage over FAT32, which is far stricter than
/// APFS about names. Copying a file called `AC/DC – Live? *remaster*.mp3`
/// straight across either fails or silently produces a name the player can't
/// open, so every path component is normalised through here first.
public enum FATName {
    /// Characters FAT32 forbids outright. `/` is included because a tag value
    /// containing a slash would otherwise inject a directory level.
    static let forbidden: Set<Character> = ["\"", "*", "/", ":", "<", ">", "?", "\\", "|"]

    /// Names reserved by DOS heritage; still rejected by many FAT drivers even
    /// with an extension appended.
    static let reserved: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for i in 1...9 {
            names.insert("COM\(i)")
            names.insert("LPT\(i)")
        }
        return names
    }()

    /// FAT32's per-component limit is 255 UTF-16 units. We cut well short of
    /// it so that a deep Artist/Album/Track tree stays comfortably inside the
    /// overall path budget.
    public static let maxComponentLength = 64

    /// Sanitise one path component (a folder name or a filename *without* its
    /// extension). Never returns an empty string.
    public static func component(_ raw: String) -> String {
        var out = String()
        out.reserveCapacity(raw.count)

        for ch in raw {
            if forbidden.contains(ch) {
                // A dash reads better than dropping the character entirely:
                // "AC/DC" becomes "AC-DC" rather than "ACDC".
                out.append("-")
            } else if ch.isNewline || ch.unicodeScalars.allSatisfy({ $0.value < 0x20 }) {
                out.append(" ")
            } else {
                out.append(ch)
            }
        }

        // Collapse runs of whitespace introduced by the substitutions above.
        out = out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")

        // FAT drops trailing dots and spaces, which would make the name on the
        // device differ from what we recorded in the playlist.
        while let last = out.last, last == "." || last == " " {
            out.removeLast()
        }
        while let first = out.first, first == " " {
            out.removeFirst()
        }

        if out.count > maxComponentLength {
            out = String(out.prefix(maxComponentLength))
            while let last = out.last, last == "." || last == " " {
                out.removeLast()
            }
        }

        if out.isEmpty { return "Unknown" }

        if reserved.contains(out.uppercased()) {
            return out + "_"
        }

        return out
    }

    /// Sanitise a filename, preserving its extension.
    public static func filename(base: String, ext: String) -> String {
        let safeExt = ext.filter { $0.isLetter || $0.isNumber }
        let safeBase = component(base)
        return safeExt.isEmpty ? safeBase : "\(safeBase).\(safeExt)"
    }

    /// FAT32 is case-insensitive, so `Album/` and `album/` are the same folder.
    /// Any comparison of device paths has to fold case or it will report
    /// spurious differences and re-copy files that are already there.
    public static func foldedKey(_ path: String) -> String {
        path.lowercased()
    }
}
