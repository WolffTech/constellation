<!-- SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech> -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

<p align="center">
  <img src="Assets/AppIcon.png" width="160" alt="Constellation logo">
</p>

<h1 align="center">Constellation</h1>

<p align="center">
  Local shell, SSH, RDP, and VNC sessions in one native macOS app.
</p>

Constellation saves your remote machines and opens each session in a tab. It uses [libghostty](https://github.com/ghostty-org/ghostty) for SSH, [FreeRDP](https://github.com/FreeRDP/FreeRDP) for RDP, and [RoyalVNCKit](https://github.com/royalapplications/royalvnc) for VNC.

> [!NOTE]
> Constellation does not create a VPN or relay traffic. Connect to your LAN, VPN, or Tailscale network before starting a session.

## What it does

- Saves multiple addresses and connection profiles for each machine
- Opens sessions in tabs and restores the tabs from your previous workspace
- Opens the current Mac's login shell from the built-in This Mac sidebar entry
- Runs SSH sessions in a Metal-rendered terminal that uses your existing OpenSSH configuration, keys, and agent
- Supports custom terminal fonts, themes, and Ghostty configuration
- Runs RDP sessions with NLA, HiDPI rendering, shared clipboard text, and a trust store for accepted certificates
- Opens VNC sessions in Constellation or Apple's Screen Sharing app
- Stores credentials in the macOS Keychain

## Installation

Constellation requires an Apple silicon Mac running macOS 15 or later.

1. Download the signed `.dmg` from [GitHub Releases](https://github.com/WolffTech/constellation/releases) when one is available, or [build from source](#build-from-source).
2. Open the disk image and drag Constellation to `/Applications`.
3. Launch Constellation from `/Applications` and add a machine.

### Updates

Constellation uses [Sparkle](https://sparkle-project.org) to check GitHub Releases for updates. Choose **Constellation → Check for Updates…**, or enable automatic checks in **Settings → Updates**.

In-app updates work only after you copy Constellation to `/Applications`. macOS translocates apps launched from a disk image or `~/Downloads`, so Sparkle cannot update them in place.

## Build from source

Install Xcode 26 or later, then run:

```sh
brew install cmake xcodegen
xcodebuild -downloadComponent MetalToolchain
git clone --recurse-submodules https://github.com/WolffTech/constellation.git
cd constellation
Scripts/build-libghostty.sh
Scripts/build-freerdp.sh
xcodegen generate
open Constellation.xcodeproj
```

The build scripts download the pinned Zig and OpenSSL versions, then compile the pinned Ghostty and FreeRDP versions.

Forks that distribute their own builds must replace `SUFeedURL` and `SUPublicEDKey` in `project.yml`. Otherwise, those builds will check Constellation's official update feed and trust its release signatures.

## License

Constellation is free software licensed under [GPL-3.0-only](LICENSE). Third-party attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and details about the source archive included with each release are in [SOURCE.md](SOURCE.md).
