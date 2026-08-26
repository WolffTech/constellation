<!-- SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech> -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Obtaining corresponding source

Each official release includes a matching `Constellation-<version>-source.zip`
archive on the [GitHub Releases](https://github.com/WolffTech/constellation/releases)
page.

The archive contains the Constellation source, populated Ghostty and FreeRDP
submodules, exact Swift package sources, native dependency source archives,
interface definitions, and build scripts used for that release. Xcode, Zig, and
Apple system frameworks are standard build tools or system libraries and are
not included. Private signing credentials are not required for a local build.

The current development source is available in the
[Constellation repository](https://github.com/WolffTech/constellation).

Anyone who redistributes a Constellation binary is responsible for satisfying
the source-distribution requirements in section 6 of GPLv3.
