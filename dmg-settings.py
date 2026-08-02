# dmgbuild settings for the release disk image. dmgbuild writes the Finder
# layout (.DS_Store) directly instead of scripting Finder, which is why it works
# on a headless CI runner where create-dmg's AppleScript silently fails.
#
#   dmgbuild -s dmg-settings.py -D app=export/Momentary.app Momentary Momentary.dmg
#
# Geometry matches docs/background.tiff (source: docs/background.html):
# 660×400 window, 128pt icons centered at (165, 210) and (495, 210). The arrow drawn in
# that image is aimed at these positions, so moving one means regenerating the other.

app = defines.get("app", "export/Momentary.app")  # noqa: F821

files = [(app, "Momentary.app")]
symlinks = {"Applications": "/Applications"}

background = "docs/background.tiff"
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 12
icon_locations = {
    "Momentary.app": (165, 210),
    "Applications": (495, 210),
}

format = "UDZO"
