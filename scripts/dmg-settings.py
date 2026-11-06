# The install window: dmgbuild settings for make-dmg.sh. Sizes are in points; the artwork is 720x460.
import os

app = defines["app"]
name = os.path.basename(app)
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/Artifloam.icns")
background = defines["background"]
format = "UDZO"
hide_extension = [name]

window_rect = ((200, 140), (720, 460))
default_view = "icon-view"
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_size = 128
text_size = 13
arrange_by = None
# Finders that show hidden files would otherwise place these out of view and add a scroller.
hidden = {item: (535, 235) for item in [".background.tiff", ".VolumeIcon.icns", ".DS_Store", ".fseventsd", ".Trashes"]}
icon_locations = {name: (185, 235), "Applications": (535, 235), **hidden}
