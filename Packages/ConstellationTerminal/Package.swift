// swift-tools-version: 6.0

// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

// GhosttyKit.xcframework is a symlink into Vendor/ghostty/macos, produced by
// Scripts/build-libghostty.sh. Nothing outside this package imports GhosttyKit.
let package = Package(
    name: "ConstellationTerminal",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ConstellationTerminal", targets: ["ConstellationTerminal"]),
    ],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "GhosttyKit.xcframework"),
        .target(
            name: "ConstellationTerminal",
            dependencies: ["GhosttyKit"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "ConstellationTerminalTests",
            dependencies: ["ConstellationTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
