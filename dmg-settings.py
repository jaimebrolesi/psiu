# dmgbuild settings for Psiu.dmg, used by build-dmg.sh. They lay out the installer window
# without Finder, so the same .dmg comes out on a Mac and on a GitHub runner.
# Paths come from build-dmg.sh: dmgbuild -s dmg-settings.py -D app=... -D background=... -D icon=...

app = defines["app"]

format = "UDZO"
filesystem = "HFS+"
files = [app]
# Finder shows the link's name as is, without translating it: it stays in English, like the bilingual background.
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]   # icon of the mounted volume (desktop, sidebar and window title)

background = defines["background"]   # 640 x 400, with 1x and 2x in one .tiff
window_rect = ((200, 120), (640, 428))   # the height counts the 28 pt title bar: 400 of content
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

arrange_by = None
icon_size = 112
text_size = 13
# Lined up with the background's arrow.
icon_locations = {"Psiu.app": (170, 190), "Applications": (470, 190)}
