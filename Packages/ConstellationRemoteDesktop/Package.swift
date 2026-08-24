// swift-tools-version: 6.0
import PackageDescription

// Remote desktop adapters. `ConstellationRemoteDesktop` defines the session
// surface the app shell uses; `ConstellationVNC` wraps RoyalVNCKit and
// `ConstellationRDP` wraps FreeRDP through a C bridge, so the app never
// imports either library directly.
let package = Package(
    name: "ConstellationRemoteDesktop",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ConstellationRemoteDesktop", targets: ["ConstellationRemoteDesktop"]),
        .library(name: "ConstellationVNC", targets: ["ConstellationVNC"]),
        .library(name: "ConstellationRDP", targets: ["ConstellationRDP"]),
    ],
    dependencies: [
        // Tag 1.1.0. Pinned by revision because RoyalVNCKit depends on a CryptoSwift
        // branch, which SwiftPM refuses beneath a version-pinned dependency.
        .package(url: "https://github.com/royalapplications/royalvnc.git", revision: "92d4427c73817d8f849bb289ff190aa4b40c44ea"),
    ],
    targets: [
        // Protocol-neutral session surface the app shell talks to.
        .target(
            name: "ConstellationRemoteDesktop",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ConstellationVNC",
            dependencies: [
                "ConstellationRemoteDesktop",
                .product(name: "RoyalVNCKit", package: "royalvnc"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConstellationVNCTests",
            dependencies: ["ConstellationVNC"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // FreeRDP static libraries + OpenSSL, built by Scripts/build-freerdp.sh.
        // The symlinks point into Vendor/build/freerdp, which is gitignored.
        .binaryTarget(name: "FreeRDPKit", path: "FreeRDPKit.xcframework"),
        // C bridge: owns every FreeRDP pointer and callback.
        .target(
            name: "CConstellationRDP",
            dependencies: ["FreeRDPKit"],
            cSettings: [
                // The xcframework carries no headers (see build-freerdp.sh);
                // FreeRDPHeaders links to Vendor/build/freerdp/headers.
                .headerSearchPath("../../FreeRDPHeaders"),
            ]
        ),
        .target(
            name: "ConstellationRDP",
            dependencies: ["ConstellationRemoteDesktop", "CConstellationRDP", "FreeRDPKit"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                // WinPR's Apple sources use CoreFoundation via Foundation;
                // FreeRDP's keyboard-layout detection uses Carbon (HIToolbox).
                .linkedFramework("Foundation"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "ConstellationRDPTests",
            dependencies: ["ConstellationRDP"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
