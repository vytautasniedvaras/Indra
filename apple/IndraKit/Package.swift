// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IndraKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "IndraKitCore", targets: ["IndraKitCore"]),
        .library(name: "IndraKitNet", targets: ["IndraKitNet"]),
        .library(name: "IndraKitAppleGlue", targets: ["IndraKitAppleGlue"]),
    ],
    targets: [
        .target(
            name: "IndraKitCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "IndraKitNet",
            dependencies: ["IndraKitCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Apple-only bridges. Sources are fully #if-gated so the target
        // compiles to nothing on Linux (swift test builds every target).
        .target(
            name: "IndraKitAppleGlue",
            dependencies: ["IndraKitCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IndraKitCoreTests",
            dependencies: ["IndraKitCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IndraKitNetTests",
            dependencies: ["IndraKitNet"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
