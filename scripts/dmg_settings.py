from pathlib import Path


repo_root = Path(__file__).resolve().parents[1]
app = defines.get("app", "dist/localvoxtral.app")

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
background = str(repo_root / "assets" / "dmg-background.png")

window_rect = ((200, 200), (600, 400))
icon_size = 128
text_size = 13
icon_locations = {
    "localvoxtral.app": (150, 185),
    "Applications": (450, 185),
}

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
