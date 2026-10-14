import Y1SyncCore

// Shared wording so every screen says the same thing the same way.

/// "1 file" / "3 files". Pass `plural` for irregular words.
func countLabel(_ n: Int, _ singular: String, plural: String? = nil) -> String {
    "\(n) " + (n == 1 ? singular : (plural ?? singular + "s"))
}

enum Wording {
    /// The one sentence used wherever no player is mounted.
    static let noPlayer = "No player — turn on USB storage on the Y1"
}

extension Device {
    /// "Y1 · 3.2 GB free · Rockbox": how a player is named everywhere.
    var displayLabel: String { name + " · " + details }

    /// "3.2 GB free · Rockbox" — also used by the status bar's "Y1 connected · …".
    var details: String {
        "\(ByteFormat.string(freeBytes)) free" + (hasRockbox ? " · Rockbox" : "")
    }
}
