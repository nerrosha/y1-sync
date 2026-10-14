// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Y1Sync",
    // macOS 14 is the floor for @Observable, used by the SwiftUI app target.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Y1SyncCore", targets: ["Y1SyncCore"]),
        .executable(name: "y1sync", targets: ["y1sync"]),
        .executable(name: "Y1SyncApp", targets: ["Y1SyncApp"]),
    ],
    targets: [
        .target(name: "Y1SyncCore"),
        .executableTarget(name: "y1sync", dependencies: ["Y1SyncCore"]),
        // Views and models live here, not in the executable: Xcode Previews
        // build a debug dylib of the owning target, and only library targets
        // can produce one.
        .target(name: "Y1SyncAppUI", dependencies: ["Y1SyncCore"]),
        .executableTarget(name: "Y1SyncApp", dependencies: ["Y1SyncAppUI"]),
        .testTarget(name: "Y1SyncCoreTests", dependencies: ["Y1SyncCore"]),
    ]
)
