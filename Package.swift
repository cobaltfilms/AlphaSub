// swift-tools-version: 5.10
import PackageDescription

// AlphaSub — open core.
//
// This package is the open-source foundation of AlphaSub, the native macOS
// subtitling app (https://alpha-sub.com): the frame-accurate subtitle data
// model and the freely available subtitle format handlers. Professional
// broadcast/cinema delivery formats, the app UI, on-device AI, and licensing
// are part of the AlphaSub application and are not included here.
let package = Package(
    name: "AlphaSub",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlphaSubCore", targets: ["AlphaSubCore"]),
        .library(name: "AlphaSubFormats", targets: ["AlphaSubFormats"]),
    ],
    targets: [
        // Frame-accurate subtitle data model + format protocols/registry.
        .target(
            name: "AlphaSubCore",
            path: "Sources/AlphaSub/Core",
            resources: []
        ),
        .testTarget(
            name: "AlphaSubCoreTests",
            dependencies: ["AlphaSubCore"],
            path: "Tests/CoreTests"
        ),

        // Freely available subtitle format importers/exporters.
        .target(
            name: "AlphaSubFormats",
            dependencies: ["AlphaSubCore"],
            path: "Sources/AlphaSub/Formats"
        ),
        .testTarget(
            name: "AlphaSubFormatsTests",
            dependencies: ["AlphaSubFormats"],
            path: "Tests/FormatTests"
        ),
    ]
)
