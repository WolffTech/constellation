#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
# SPDX-License-Identifier: GPL-3.0-only

"""Regenerates App/Licenses (manifest.json + license texts) for Help › Acknowledgements.

Run after bumping a dependency, after the native kits have been built (the
Zig package cache and the SwiftPM checkouts must exist). Sources are the
submodules, Zig's package cache (matched by a file each package is known to
contain, not by hash), the SwiftPM checkouts, the pinned OpenSSL build, and — for
the few packages that ship no license file — the upstream text over HTTPS.
"""
import glob
import json
import os
import re
import subprocess
import tarfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "App", "Licenses")
ZIG_CACHE = os.path.expanduser("~/.cache/zig/p")
HOME = os.path.expanduser("~")


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def read(path):
    if not os.path.isabs(path):
        path = os.path.join(ROOT, path)
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def from_tarball(marker, license_name):
    """Text of `license_name` from the cached Zig tarball containing `marker`."""
    for path in sorted(glob.glob(os.path.join(ZIG_CACHE, "*.tar.gz"))):
        with tarfile.open(path, "r:gz") as tar:
            names = tar.getnames()
            if not any(n.endswith("/" + marker) or n == marker for n in names):
                continue
            for n in names:
                if n.endswith("/" + license_name) or n == license_name:
                    return tar.extractfile(n).read().decode("utf-8", "replace")
            raise SystemExit(f"{path} matched {marker} but has no {license_name}")
    raise SystemExit(f"no cached Zig package contains {marker}; run Scripts/build-libghostty.sh")


def checkout_file(name, file="LICENSE"):
    candidates = glob.glob(os.path.join(ROOT, "Packages", "*", ".build", "checkouts", name, file))
    candidates += glob.glob(os.path.join(HOME, "Library", "Developer", "Xcode", "DerivedData", "*", "SourcePackages", "checkouts", name, file))
    if not candidates:
        raise SystemExit(f"SwiftPM checkout for {name} not found; build once first")
    return candidates[0]


def from_checkout(name, file="LICENSE"):
    return read(checkout_file(name, file))


def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read().decode("utf-8", "replace")


def leading_comment(path):
    text = read(path)
    match = re.match(r"\s*/\*(.*?)\*/", text, re.S)
    if not match:
        raise SystemExit(f"no leading comment in {path}")
    return "\n".join(line.strip(" *") for line in match.group(1).splitlines()).strip() + "\n"


def leading_comments(path, count):
    text = read(path)
    matches = re.findall(r"/\*(.*?)\*/", text, re.S)[:count]
    if len(matches) != count:
        raise SystemExit(f"expected {count} leading comments in {path}")
    notices = [
        "\n".join(line.strip(" *") for line in match.splitlines()).strip()
        for match in matches
    ]
    return "\n\n".join(notices) + "\n"


def stb_notice(path):
    text = read(path)
    index = text.rfind("This software is available under 2 licenses")
    if index < 0:
        raise SystemExit(f"no license block in {path}")
    return "\n".join(line.lstrip("/ ") for line in text[index:].splitlines()).strip() + "\n"


ghostty_commit = run("git", "-C", "Vendor/ghostty", "rev-parse", "--short", "HEAD")
freerdp_tag = run("git", "-C", "Vendor/freerdp", "describe", "--tags")
openssl_prefix = os.path.join(ROOT, "Vendor", "build", "openssl")
openssl_version = run(os.path.join(openssl_prefix, "bin", "openssl"), "version").split()[1]

GHOSTTY = "https://github.com/ghostty-org/ghostty"

# (slug, name, version, license, url, summary, loader)
NOTICES = [
    ("ghostty", "Ghostty", f"commit {ghostty_commit}", "MIT", GHOSTTY,
     "libghostty renders the terminal in SSH tabs. The AppKit surface, keyboard and text-input code in ConstellationTerminal is adapted from Ghostty.app.",
     lambda: read("Vendor/ghostty/LICENSE")),
    ("freerdp", "FreeRDP and WinPR", freerdp_tag, "Apache-2.0", "https://github.com/FreeRDP/FreeRDP",
     "RDP protocol, codecs and channels behind RDP sessions.",
     lambda: read("Vendor/freerdp/LICENSE")),
    ("openssl", "OpenSSL", openssl_version, "Apache-2.0", "https://openssl-library.org",
     "TLS and cryptography for RDP, linked statically into the FreeRDP kit.",
     lambda: read(os.path.join(openssl_prefix, "LICENSE.txt"))),
    ("md4-md5", "MD4 and MD5 (Solar Designer)", "bundled with WinPR", "Public domain", "https://openwall.info/wiki/people/solar/software/public-domain-source-code/md5",
     "Hash implementations WinPR compiles in so NTLM authentication does not need OpenSSL's legacy provider.",
     lambda: leading_comment("Vendor/freerdp/winpr/libwinpr/crypto/md5.c")),
    ("royalvnckit", "RoyalVNCKit", "1.1.0", "MIT", "https://github.com/royalapplications/royalvnc",
     "VNC protocol and framebuffer view behind VNC sessions.",
     lambda: from_checkout("royalvnc")),
    ("d3des", "D3DES", "5.09, bundled with RoyalVNCKit", "Public domain with Olivetti and Oracle modifications", "https://github.com/royalapplications/royalvnc",
     "DES implementation used by RoyalVNCKit for VNC authentication.",
     lambda: leading_comments(checkout_file("royalvnc", "Sources/d3des/d3des.c"), 2)),
    ("cryptoswift", "CryptoSwift", "royalapplications fork", "zlib", "https://github.com/royalapplications/CryptoSwift",
     "Cryptography used by RoyalVNCKit for VNC authentication.",
     lambda: from_checkout("CryptoSwift")),
    ("grdb", "GRDB", "7.11.1", "MIT", "https://github.com/groue/GRDB.swift",
     "SQLite access for the machine library and the certificate trust store.",
     lambda: from_checkout("GRDB.swift")),
    ("freetype", "FreeType", "2.13.2", "FreeType License", "https://freetype.org",
     "Font rasterization inside libghostty.",
     lambda: from_tarball("include/freetype/freetype.h", "LICENSE.TXT")),
    ("libpng", "libpng", "1.6.43", "PNG Reference Library License v2", "http://www.libpng.org/pub/png/libpng.html",
     "PNG support for FreeType.",
     lambda: from_tarball("png.h", "LICENSE")),
    ("zlib", "zlib", "1.3.1", "zlib", "https://zlib.net",
     "Compression used by libpng and FreeType.",
     lambda: from_tarball("zlib.h", "LICENSE")),
    ("oniguruma", "Oniguruma", "6.9.9", "BSD-2-Clause", "https://github.com/kkos/oniguruma",
     "Regular expressions for libghostty's link and search matching.",
     lambda: from_tarball("src/oniguruma.h", "COPYING")),
    ("glslang", "glslang", "14.2.0", "BSD-3-Clause, BSD-2-Clause, MIT, Apache-2.0", "https://github.com/KhronosGroup/glslang",
     "Shader compilation for libghostty's renderer.",
     lambda: from_tarball("glslang/Public/ShaderLang.h", "LICENSE.txt")),
    ("spirv-cross", "SPIRV-Cross", "13.1.1", "Apache-2.0", "https://github.com/KhronosGroup/SPIRV-Cross",
     "Shader translation for libghostty's Metal renderer.",
     lambda: from_tarball("spirv_cross.hpp", "LICENSE")),
    ("simdutf", "simdutf", "5.2.8", "MIT (or Apache-2.0)", "https://github.com/simdutf/simdutf",
     "Fast UTF-8 validation and transcoding in libghostty.",
     lambda: fetch("https://raw.githubusercontent.com/simdutf/simdutf/v5.2.8/LICENSE-MIT")),
    ("highway", "Highway", "1.2.0", "Apache-2.0 (or BSD-3-Clause)", "https://github.com/google/highway",
     "SIMD primitives for libghostty's terminal parser.",
     lambda: from_tarball("hwy/highway.h", "LICENSE")),
    ("wuffs", "Wuffs", "commit 7411f48", "Apache-2.0 (or MIT)", "https://github.com/google/wuffs",
     "Image decoding in libghostty.",
     lambda: from_tarball("release/c/wuffs-v0.4.c", "LICENSE")),
    ("libintl", "GNU libintl (gettext runtime)", "0.24", "LGPL-2.1-or-later", "https://www.gnu.org/software/gettext/",
     "Message translation runtime bundled by libghostty on macOS. It is linked statically; the open build scripts in this repository let you relink Constellation against a modified libintl.",
     lambda: from_tarball("gettext-runtime/intl/COPYING.LIB", "gettext-runtime/intl/COPYING.LIB")),
    ("imgui", "Dear ImGui", "1.92.5-docking", "MIT", "https://github.com/ocornut/imgui",
     "libghostty's inspector UI.",
     lambda: from_tarball("imgui.h", "LICENSE.txt")),
    ("dear-bindings", "Dear Bindings", "0.17", "MIT", "https://github.com/dearimgui/dear_bindings",
     "C bindings for Dear ImGui used by libghostty.",
     lambda: fetch("https://raw.githubusercontent.com/dearimgui/dear_bindings/main/LICENSE.txt")),
    ("stb", "stb_image and stb_image_resize", "2.28 / 0.97", "MIT or public domain", "https://github.com/nothings/stb",
     "Image loading in libghostty.",
     lambda: stb_notice("Vendor/ghostty/src/stb/stb_image.h")),
    ("libxev", "libxev", "commit 9ce8e8e", "MIT", "https://github.com/mitchellh/libxev",
     "Event loop for libghostty's I/O thread.",
     lambda: from_tarball("src/main.zig", "LICENSE") if False else from_named_tarball("libxev-", "LICENSE")),
    ("vaxis", "libvaxis", "0.6.0", "MIT", "https://github.com/rockorager/libvaxis",
     "Terminal UI library used by libghostty.",
     lambda: from_named_tarball("vaxis-", "LICENSE")),
    ("zigimg", "zigimg", "commit d695acd", "MIT", "https://github.com/zigimg/zigimg",
     "Image library pulled in by libvaxis.",
     lambda: from_named_tarball("zigimg-", "LICENSE")),
    ("z2d", "z2d", "0.12.1", "MPL-2.0", "https://github.com/vancluever/z2d",
     "2D vector drawing for libghostty's box-drawing glyphs. Its source is available unmodified from the upstream repository, as the MPL requires.",
     lambda: fetch("https://www.mozilla.org/media/MPL/2.0/index.txt")),
    ("zf", "zf", "0.11.0", "MIT", "https://github.com/natecraddock/zf",
     "Fuzzy matching in libghostty.",
     lambda: from_named_tarball("zf-", "LICENSE")),
    ("zig-objc", "zig-objc", "commit c8de82f", "MIT", "https://github.com/mitchellh/zig-objc",
     "Objective-C runtime bindings for libghostty on macOS.",
     lambda: from_named_tarball("zig_objc-", "LICENSE")),
    ("uucode", "uucode", "0.2.0", "MIT; includes Unicode Character Database data under the Unicode License", "https://github.com/jacobsandlund/uucode",
     "Unicode properties and grapheme segmentation in libghostty.",
     lambda: from_named_tarball("uucode-", "LICENSE.md") + "\n\n" + fetch("https://www.unicode.org/license.txt")),
    ("jetbrains-mono", "JetBrains Mono", "2.304", "SIL Open Font License 1.1", "https://github.com/JetBrains/JetBrainsMono",
     "Fallback terminal font embedded in libghostty.",
     lambda: from_tarball("fonts/ttf/JetBrainsMono-Regular.ttf", "OFL.txt")),
    ("nerd-fonts", "Symbols Nerd Font", "3.4.0", "MIT", "https://github.com/ryanoasis/nerd-fonts",
     "Symbol glyphs embedded in libghostty.",
     lambda: from_tarball("SymbolsNerdFontMono-Regular.ttf", "LICENSE")),
]


def from_named_tarball(prefix, license_name):
    matches = sorted(glob.glob(os.path.join(ZIG_CACHE, prefix + "*.tar.gz")))
    if not matches:
        raise SystemExit(f"no cached Zig package named {prefix}*")
    with tarfile.open(matches[-1], "r:gz") as tar:
        for n in tar.getnames():
            if n.endswith("/" + license_name):
                return tar.extractfile(n).read().decode("utf-8", "replace")
    raise SystemExit(f"{matches[-1]} has no {license_name}")


def main():
    os.makedirs(OUT, exist_ok=True)
    for stale in glob.glob(os.path.join(OUT, "*")):
        os.remove(stale)
    manifest = []
    for slug, name, version, license, url, summary, loader in NOTICES:
        text = loader().replace("\r\n", "\n").rstrip() + "\n"
        file = f"{slug}.txt"
        with open(os.path.join(OUT, file), "w", encoding="utf-8") as f:
            f.write(text)
        manifest.append({"name": name, "version": version, "license": license, "url": url, "summary": summary, "file": file})
        print(f"{name}: {len(text)} bytes")
    with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")
    write_third_party_notices(manifest)


def write_third_party_notices(manifest):
    lines = [
        "<!-- SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech> -->",
        "<!-- SPDX-License-Identifier: GPL-3.0-only -->",
        "",
        "# Third-party software notices",
        "",
        "Constellation incorporates the following third-party software. Complete license",
        "texts are bundled with the app and stored in [`App/Licenses`](App/Licenses).",
        "",
    ]
    for notice in manifest:
        lines.extend([
            f"## {notice['name']}",
            "",
            notice["summary"],
            "",
            f"- Upstream: [{notice['url']}]({notice['url']})",
            f"- Version: {notice['version']}",
            f"- License: {notice['license']}",
            f"- License text: [`{notice['file']}`](App/Licenses/{notice['file']})",
            "",
        ])
    with open(os.path.join(ROOT, "THIRD_PARTY_NOTICES.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


if __name__ == "__main__":
    main()
