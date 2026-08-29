# SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
# SPDX-License-Identifier: GPL-3.0-only

# dmgbuild layout for the release image. Scripts/build-dmg.sh passes the app
# and the background with -D app=<path> -D background=<path> (dmgbuild
# exec's this file without __file__). Icon coordinates are icon centres in
# the 640x400 window; render-background.swift draws the arrow and caption to
# match.

import os

app = defines["app"]  # noqa: F821 (injected by dmgbuild)

format = "ULFO"  # lzfse; every supported macOS reads it and it is smaller than UDZO
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = [os.path.basename(app)]

background = defines["background"]  # noqa: F821; dmgbuild also picks up the @2x file
window_rect = ((200, 200), (640, 400))
default_view = "icon-view"
icon_size = 128
text_size = 12
icon_locations = {
    os.path.basename(app): (170, 190),
    "Applications": (470, 190),
}
show_status_bar = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
