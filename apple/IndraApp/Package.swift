// swift-tools-version: 6.0
// IndraApp — SwiftUI debug harness executable (Phase 4 scaffold; Phase 3 DoD
// "minimal SwiftUI harness view"). Deliberately a SwiftPM package, not an
// .xcodeproj: Xcode 16 opens Package.swift directly and ⌘R runs the @main
// SwiftUI executable on macOS. On Linux CI every source file is #if-gated, so
// this builds to a stub executable (structural check only).
import PackageDescription

let package = Package(
    name: "IndraApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../IndraKit")
    ],
    targets: [
        .executableTarget(
            name: "IndraApp",
            dependencies: [
                .product(name: "IndraKitCore", package: "IndraKit"),
                .product(name: "IndraKitNet", package: "IndraKit"),
                .product(name: "IndraKitAppleGlue", package: "IndraKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
