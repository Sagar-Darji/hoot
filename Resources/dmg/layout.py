"""Writes Finder's layout for Hoot's install window (the .DS_Store saved next to this file as DS_Store).

package.sh reuses the saved DS_Store, so this only needs running again when the window's layout changes:

    python3 -m venv /tmp/dmg && /tmp/dmg/bin/pip install ds_store mac_alias
    diskutil image create blank --size 200m --volumeName Hoot --fs APFS /tmp/layout.dmg
    diskutil image attach /tmp/layout.dmg
    mkdir /Volumes/Hoot/.background && cp Resources/dmg/background.tiff /Volumes/Hoot/.background/
    /tmp/dmg/bin/python3 Resources/dmg/layout.py /Volumes/Hoot
    cp /Volumes/Hoot/.DS_Store Resources/dmg/DS_Store && diskutil eject /Volumes/Hoot

Finder finds the background through an alias to /Volumes/Hoot/.background/background.tiff, so the
disk image's volume name has to stay "Hoot". The sizes and positions match InstallerBackground.swift.
"""
import sys

from ds_store import DSStore
from mac_alias import Alias

WIDTH, HEIGHT = 640, 400                 # the background, in points
TITLE_BAR = 32                           # Finder's window height includes its title bar
APP, APPLICATIONS = (170, 196), (470, 196)
BACKGROUND_COLOUR = (0.42, 0.29, 0.70)   # shown for a moment before the picture loads

mount = sys.argv[1]
alias = Alias.for_file(mount + '/.background/background.tiff')
window = {
    'WindowBounds': '{{360, 380}, {%d, %d}}' % (WIDTH, HEIGHT + TITLE_BAR),
    'ShowStatusBar': False, 'ShowToolbar': False, 'ShowPathbar': False, 'ShowSidebar': False,
    'ShowTabView': False, 'ContainerShowSidebar': False, 'PreviewPaneVisibility': False, 'SidebarWidth': 0,
}
icon_view = {
    'viewOptionsVersion': 1,
    'backgroundType': 2,
    'backgroundImageAlias': alias.to_bytes(),
    'backgroundColorRed': BACKGROUND_COLOUR[0],
    'backgroundColorGreen': BACKGROUND_COLOUR[1],
    'backgroundColorBlue': BACKGROUND_COLOUR[2],
    'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'gridSpacing': 100.0,
    'arrangeBy': 'none',
    'showIconPreview': True, 'showItemInfo': False, 'labelOnBottom': True,
    'textSize': 13.0, 'iconSize': 128.0,
    'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
}
with DSStore.open(mount + '/.DS_Store', 'w+') as d:
    d['.']['vSrn'] = ('long', 1)
    d['.']['bwsp'] = window
    d['.']['icvp'] = icon_view
    d['.']['icvl'] = ('type', b'icnv')
    d['Hoot.app']['Iloc'] = APP
    d['Applications']['Iloc'] = APPLICATIONS
print('Wrote', mount + '/.DS_Store')
