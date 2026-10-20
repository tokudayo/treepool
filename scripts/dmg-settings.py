"""Finder layout written directly by dmgbuild, including on headless CI runners."""
import sys
from pathlib import Path

from dmgbuild import build_dmg
from ds_store import DSStore

app, background_path, output = sys.argv[1:]
format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
background = background_path
window_rect = ((200, 200), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
icon_size = 128
text_size = 14
icon_locations = {"Treepool.app": (170, 190), "Applications": (490, 190)}

# dmgbuild 1.6.5 supports the Python shipped with Xcode. Apply the upstream
# Tahoe fix before compression: retain the image alias, omit its stale bookmark.
# https://github.com/dmgbuild/dmgbuild/pull/275
mount_path = None


def remember_mount(path, options):
    global mount_path
    mount_path = Path(path)


def finish_layout(event):
    if event.get("type") == "operation::finished" and event.get("operation") == "dsstore::create":
        with DSStore.open(str(mount_path / ".DS_Store"), "r+") as store:
            del store["."][b"pBBk"]


settings = {key: value for key, value in globals().copy().items() if not key.startswith("_")}
settings["create_hook"] = remember_mount
build_dmg(output, "Treepool", settings=settings, callback=finish_layout)
