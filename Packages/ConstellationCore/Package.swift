// swift-tools-version: 6.0

// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

// Domain types and the interfaces the app shell talks to. No I/O here: the
// GRDB and Keychain adapters live in ConstellationInfrastructure.
let package = Package(
    name: "ConstellationCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ConstellationCore", targets: ["ConstellationCore"]),
    ],
    targets: [
        .target(name: "ConstellationCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "ConstellationCoreTests",
            dependencies: ["ConstellationCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
