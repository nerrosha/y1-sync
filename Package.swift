// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "Y1SyncCore", targets: ["Y1SyncCore"]),
    .library(name: "Y1SyncAPI", targets: ["Y1SyncAPI"]),
    .executable(name: "y1sync", targets: ["y1sync"]),
]
var targets: [Target] = [
    .target(name: "Y1SyncCore"),
    // The commands behind the Windows window (and anything else that wants the
    // engine as JSON): `y1sync api`.
    .target(name: "Y1SyncAPI", dependencies: ["Y1SyncCore"]),
    .executableTarget(name: "y1sync", dependencies: ["Y1SyncCore", "Y1SyncAPI"]),
    .testTarget(name: "Y1SyncCoreTests", dependencies: ["Y1SyncCore"]),
    .testTarget(name: "Y1SyncAPITests", dependencies: ["Y1SyncAPI", "Y1SyncCore"]),
]

// The Mac app is SwiftUI; the Windows build is the engine and the command-line
// tool, with a separate window (see windows/).
#if !os(Windows)
products.append(.executable(name: "Y1SyncApp", targets: ["Y1SyncApp"]))
// Views and models live here, not in the executable: Xcode Previews build a debug
// dylib of the owning target, and only library targets can produce one.
targets.append(.target(name: "Y1SyncAppUI", dependencies: ["Y1SyncCore"]))
targets.append(.executableTarget(name: "Y1SyncApp", dependencies: ["Y1SyncAppUI"]))
#endif

let package = Package(
    name: "Y1Sync",
    // macOS 14 is the floor for @Observable, used by the SwiftUI app target.
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
