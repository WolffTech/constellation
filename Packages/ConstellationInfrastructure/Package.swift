// swift-tools-version: 6.0

// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

// Adapters that touch the outside world: SQLite (GRDB), Keychain, and OpenSSH.
// `constellation-askpass` is the tiny executable ssh runs for passwords,
// passphrases and host-key confirmations; it forwards each prompt to the app.
let package = Package(
    name: "ConstellationInfrastructure",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ConstellationStorage", targets: ["ConstellationStorage"]),
        .library(name: "ConstellationOpenSSH", targets: ["ConstellationOpenSSH"]),
        .executable(name: "constellation-askpass", targets: ["constellation-askpass"]),
    ],
    dependencies: [
        .package(path: "../ConstellationCore"),
        .package(path: "../ConstellationTerminal"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "ConstellationStorage",
            dependencies: [
                .product(name: "ConstellationCore", package: "ConstellationCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ConstellationOpenSSH",
            dependencies: [
                .product(name: "ConstellationCore", package: "ConstellationCore"),
                .product(name: "ConstellationTerminal", package: "ConstellationTerminal"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "constellation-askpass",
            dependencies: ["ConstellationOpenSSH"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConstellationStorageTests",
            dependencies: ["ConstellationStorage"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConstellationOpenSSHTests",
            dependencies: [
                "ConstellationOpenSSH",
                "constellation-askpass",
                .product(name: "ConstellationTerminal", package: "ConstellationTerminal"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
