<p align="center">
  <img src="Assets/AppIcon.png" width="160" alt="Constellation logo">
</p>

<h1 align="center">Constellation</h1>

<p align="center">
  A native macOS workspace for your remote machines: SSH, RDP, and VNC sessions in one window.
</p>

Constellation keeps a library of machines, each with its addresses and
connection profiles, and opens sessions to them as tabs. SSH runs in terminal
tabs powered by [libghostty](https://github.com/ghostty-org/ghostty), RDP is
embedded through [FreeRDP](https://github.com/FreeRDP/FreeRDP), and VNC through
[RoyalVNCKit](https://github.com/royalapplications/royalvnc). Passwords and
passphrases live only in the macOS Keychain.

> [!NOTE]
> Constellation does not create a VPN or relay traffic. Your LAN, corporate
> VPN, or Tailscale network stays responsible for reachability.

## Features

- Save a machine once with several addresses (LAN, VPN, Tailscale) and one or
  more profiles per protocol
- SSH tabs with a Metal-rendered terminal, app-managed fonts and themes, and
  your own OpenSSH configuration, keys, and agent
- Embedded RDP sessions with NLA, HiDPI rendering, shared clipboard text, and
  a Trust Store that remembers accepted certificates
- Embedded VNC sessions, with a hand-off to Apple's Screen Sharing app
- Keychain-backed credentials, a saved workspace that reopens your tabs, and
  reconnect without leaking processes
- Help › Save Support Bundle… collects diagnostics without host names,
  account names, or secrets
- Help › Acknowledgements lists every bundled open-source component

## Install

Constellation requires macOS 15 or later on Apple silicon.

1. Download `Constellation-<version>.zip` from [GitHub Releases](https://github.com/WolffTech/constellation/releases) when one is available, or [build from source](#build-from-source).
2. Unzip it and move **Constellation.app** to **Applications**.
3. Open Constellation and add your first machine.

Releases are signed with a Developer ID certificate and notarized by Apple.
`Constellation-<version>.zip.sha256` beside each download holds its checksum.

## Build from source

You need Xcode 26 or later with its Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`) and Homebrew's `cmake` and
`xcodegen`.

```sh
git clone --recurse-submodules https://github.com/WolffTech/constellation.git
cd constellation
Scripts/build-libghostty.sh   # GhosttyKit.xcframework from the pinned Ghostty commit
Scripts/build-freerdp.sh      # FreeRDPKit.xcframework from the pinned FreeRDP tag
xcodegen generate
open Constellation.xcodeproj
```

`Scripts/build-libghostty.sh` downloads the pinned Zig toolchain into
`.tools/`. `Scripts/build-freerdp.sh` builds the pinned OpenSSL source release
before FreeRDP. Rerun either build script after bumping its dependencies.
`Constellation.xcodeproj` is generated from `project.yml`; edit the spec, not
the project.

To run the tests:

```sh
xcodebuild -project Constellation.xcodeproj -scheme Constellation \
  -destination 'platform=macOS,arch=arm64' \
  -onlyUsePackageVersionsFromResolvedFile test
swift test --package-path Packages/ConstellationInfrastructure --disable-automatic-resolution
swift test --package-path Packages/ConstellationRemoteDesktop --disable-automatic-resolution
swift test --package-path Packages/ConstellationTerminal
```

The terminal tests open real surfaces and need a window server. Suites that
talk to a live host skip themselves unless `CONSTELLATION_TEST_*` variables
point at one.

### Releasing

`Scripts/release.sh <version>` builds a Release archive, signs it with
Developer ID and the Hardened Runtime, notarizes it, staples the ticket, and
writes the zip to `build/release/<version>/`. Pushing a `v<version>` tag runs
the same script on GitHub Actions and publishes the result as a release;
see `.github/workflows/release.yml` for the secrets it needs.

## Security and privacy

See [`SECURITY.md`](SECURITY.md) for how to report a vulnerability and how
pinned dependencies are updated, and [`PRIVACY.md`](PRIVACY.md) for what the
app stores and what leaves your Mac.

## Third-party notices

Bundled open-source components and their licenses are listed in
[`App/Licenses/manifest.json`](App/Licenses/manifest.json) and shown in the
app under Help › Acknowledgements.
