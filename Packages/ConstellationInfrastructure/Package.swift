// swift-tools-version: 6.0
import PackageDescription

// OpenSSH integration: builds ssh command lines and serves the AskPass helper.
// `constellation-askpass` is the tiny executable ssh runs for passwords,
// passphrases and host-key confirmations; it forwards each prompt to the app.
let package = Package(
    name: "ConstellationInfrastructure",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ConstellationOpenSSH", targets: ["ConstellationOpenSSH"]),
        .executable(name: "constellation-askpass", targets: ["constellation-askpass"]),
    ],
    dependencies: [
        .package(path: "../ConstellationTerminal"),
    ],
    targets: [
        .target(
            name: "ConstellationOpenSSH",
            dependencies: [.product(name: "ConstellationTerminal", package: "ConstellationTerminal")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "constellation-askpass",
            dependencies: ["ConstellationOpenSSH"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConstellationOpenSSHTests",
            dependencies: ["ConstellationOpenSSH", "constellation-askpass"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
