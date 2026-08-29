<!-- SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech> -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Third-party software notices

Constellation incorporates the following third-party software. Complete license
texts are bundled with the app and stored in [`App/Licenses`](App/Licenses).

## Ghostty

libghostty renders the terminal in SSH tabs. The AppKit surface, keyboard and text-input code in ConstellationTerminal is adapted from Ghostty.app.

- Upstream: [https://github.com/ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)
- Version: commit da5ddcb08
- License: MIT
- License text: [`ghostty.txt`](App/Licenses/ghostty.txt)

## FreeRDP and WinPR

RDP protocol, codecs and channels behind RDP sessions.

- Upstream: [https://github.com/FreeRDP/FreeRDP](https://github.com/FreeRDP/FreeRDP)
- Version: 3.30.0
- License: Apache-2.0
- License text: [`freerdp.txt`](App/Licenses/freerdp.txt)

## OpenSSL

TLS and cryptography for RDP, linked statically into the FreeRDP kit.

- Upstream: [https://openssl-library.org](https://openssl-library.org)
- Version: 3.5.8
- License: Apache-2.0
- License text: [`openssl.txt`](App/Licenses/openssl.txt)

## MD4 and MD5 (Solar Designer)

Hash implementations WinPR compiles in so NTLM authentication does not need OpenSSL's legacy provider.

- Upstream: [https://openwall.info/wiki/people/solar/software/public-domain-source-code/md5](https://openwall.info/wiki/people/solar/software/public-domain-source-code/md5)
- Version: bundled with WinPR
- License: Public domain
- License text: [`md4-md5.txt`](App/Licenses/md4-md5.txt)

## RoyalVNCKit

VNC protocol and framebuffer view behind VNC sessions.

- Upstream: [https://github.com/royalapplications/royalvnc](https://github.com/royalapplications/royalvnc)
- Version: 1.1.0
- License: MIT
- License text: [`royalvnckit.txt`](App/Licenses/royalvnckit.txt)

## D3DES

DES implementation used by RoyalVNCKit for VNC authentication.

- Upstream: [https://github.com/royalapplications/royalvnc](https://github.com/royalapplications/royalvnc)
- Version: 5.09, bundled with RoyalVNCKit
- License: Public domain with Olivetti and Oracle modifications
- License text: [`d3des.txt`](App/Licenses/d3des.txt)

## CryptoSwift

Cryptography used by RoyalVNCKit for VNC authentication.

- Upstream: [https://github.com/royalapplications/CryptoSwift](https://github.com/royalapplications/CryptoSwift)
- Version: royalapplications fork
- License: zlib
- License text: [`cryptoswift.txt`](App/Licenses/cryptoswift.txt)

## GRDB

SQLite access for the machine library and the certificate trust store.

- Upstream: [https://github.com/groue/GRDB.swift](https://github.com/groue/GRDB.swift)
- Version: 7.11.1
- License: MIT
- License text: [`grdb.txt`](App/Licenses/grdb.txt)

## Sparkle

In-app updates, embedded as the prebuilt framework the Sparkle project publishes.

- Upstream: [https://github.com/sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)
- Version: 2.9.6
- License: MIT; bundled components (bspatch, ed25519, SHA-1) under compatible permissive licenses
- License text: [`sparkle.txt`](App/Licenses/sparkle.txt)

## FreeType

Font rasterization inside libghostty.

- Upstream: [https://freetype.org](https://freetype.org)
- Version: 2.13.2
- License: FreeType License
- License text: [`freetype.txt`](App/Licenses/freetype.txt)

## libpng

PNG support for FreeType.

- Upstream: [http://www.libpng.org/pub/png/libpng.html](http://www.libpng.org/pub/png/libpng.html)
- Version: 1.6.43
- License: PNG Reference Library License v2
- License text: [`libpng.txt`](App/Licenses/libpng.txt)

## zlib

Compression used by libpng and FreeType.

- Upstream: [https://zlib.net](https://zlib.net)
- Version: 1.3.1
- License: zlib
- License text: [`zlib.txt`](App/Licenses/zlib.txt)

## Oniguruma

Regular expressions for libghostty's link and search matching.

- Upstream: [https://github.com/kkos/oniguruma](https://github.com/kkos/oniguruma)
- Version: 6.9.9
- License: BSD-2-Clause
- License text: [`oniguruma.txt`](App/Licenses/oniguruma.txt)

## glslang

Shader compilation for libghostty's renderer.

- Upstream: [https://github.com/KhronosGroup/glslang](https://github.com/KhronosGroup/glslang)
- Version: 14.2.0
- License: BSD-3-Clause, BSD-2-Clause, MIT, Apache-2.0
- License text: [`glslang.txt`](App/Licenses/glslang.txt)

## SPIRV-Cross

Shader translation for libghostty's Metal renderer.

- Upstream: [https://github.com/KhronosGroup/SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)
- Version: 13.1.1
- License: Apache-2.0
- License text: [`spirv-cross.txt`](App/Licenses/spirv-cross.txt)

## simdutf

Fast UTF-8 validation and transcoding in libghostty.

- Upstream: [https://github.com/simdutf/simdutf](https://github.com/simdutf/simdutf)
- Version: 5.2.8
- License: MIT (or Apache-2.0)
- License text: [`simdutf.txt`](App/Licenses/simdutf.txt)

## Highway

SIMD primitives for libghostty's terminal parser.

- Upstream: [https://github.com/google/highway](https://github.com/google/highway)
- Version: 1.2.0
- License: Apache-2.0 (or BSD-3-Clause)
- License text: [`highway.txt`](App/Licenses/highway.txt)

## Wuffs

Image decoding in libghostty.

- Upstream: [https://github.com/google/wuffs](https://github.com/google/wuffs)
- Version: commit 7411f48
- License: Apache-2.0 (or MIT)
- License text: [`wuffs.txt`](App/Licenses/wuffs.txt)

## GNU libintl (gettext runtime)

Message translation runtime bundled by libghostty on macOS. It is linked statically; the open build scripts in this repository let you relink Constellation against a modified libintl.

- Upstream: [https://www.gnu.org/software/gettext/](https://www.gnu.org/software/gettext/)
- Version: 0.24
- License: LGPL-2.1-or-later
- License text: [`libintl.txt`](App/Licenses/libintl.txt)

## Dear ImGui

libghostty's inspector UI.

- Upstream: [https://github.com/ocornut/imgui](https://github.com/ocornut/imgui)
- Version: 1.92.5-docking
- License: MIT
- License text: [`imgui.txt`](App/Licenses/imgui.txt)

## Dear Bindings

C bindings for Dear ImGui used by libghostty.

- Upstream: [https://github.com/dearimgui/dear_bindings](https://github.com/dearimgui/dear_bindings)
- Version: 0.17
- License: MIT
- License text: [`dear-bindings.txt`](App/Licenses/dear-bindings.txt)

## stb_image and stb_image_resize

Image loading in libghostty.

- Upstream: [https://github.com/nothings/stb](https://github.com/nothings/stb)
- Version: 2.28 / 0.97
- License: MIT or public domain
- License text: [`stb.txt`](App/Licenses/stb.txt)

## libxev

Event loop for libghostty's I/O thread.

- Upstream: [https://github.com/mitchellh/libxev](https://github.com/mitchellh/libxev)
- Version: commit 9ce8e8e
- License: MIT
- License text: [`libxev.txt`](App/Licenses/libxev.txt)

## libvaxis

Terminal UI library used by libghostty.

- Upstream: [https://github.com/rockorager/libvaxis](https://github.com/rockorager/libvaxis)
- Version: 0.6.0
- License: MIT
- License text: [`vaxis.txt`](App/Licenses/vaxis.txt)

## zigimg

Image library pulled in by libvaxis.

- Upstream: [https://github.com/zigimg/zigimg](https://github.com/zigimg/zigimg)
- Version: commit d695acd
- License: MIT
- License text: [`zigimg.txt`](App/Licenses/zigimg.txt)

## z2d

2D vector drawing for libghostty's box-drawing glyphs. Its source is available unmodified from the upstream repository, as the MPL requires.

- Upstream: [https://github.com/vancluever/z2d](https://github.com/vancluever/z2d)
- Version: 0.12.1
- License: MPL-2.0
- License text: [`z2d.txt`](App/Licenses/z2d.txt)

## zf

Fuzzy matching in libghostty.

- Upstream: [https://github.com/natecraddock/zf](https://github.com/natecraddock/zf)
- Version: 0.11.0
- License: MIT
- License text: [`zf.txt`](App/Licenses/zf.txt)

## zig-objc

Objective-C runtime bindings for libghostty on macOS.

- Upstream: [https://github.com/mitchellh/zig-objc](https://github.com/mitchellh/zig-objc)
- Version: commit c8de82f
- License: MIT
- License text: [`zig-objc.txt`](App/Licenses/zig-objc.txt)

## uucode

Unicode properties and grapheme segmentation in libghostty.

- Upstream: [https://github.com/jacobsandlund/uucode](https://github.com/jacobsandlund/uucode)
- Version: 0.2.0
- License: MIT; includes Unicode Character Database data under the Unicode License
- License text: [`uucode.txt`](App/Licenses/uucode.txt)

## JetBrains Mono

Fallback terminal font embedded in libghostty.

- Upstream: [https://github.com/JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono)
- Version: 2.304
- License: SIL Open Font License 1.1
- License text: [`jetbrains-mono.txt`](App/Licenses/jetbrains-mono.txt)

## Symbols Nerd Font

Symbol glyphs embedded in libghostty.

- Upstream: [https://github.com/ryanoasis/nerd-fonts](https://github.com/ryanoasis/nerd-fonts)
- Version: 3.4.0
- License: MIT
- License text: [`nerd-fonts.txt`](App/Licenses/nerd-fonts.txt)
