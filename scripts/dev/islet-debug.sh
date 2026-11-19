#!/bin/bash
#
# Drives a running Islet that was started with ISLET_DEBUG=1, so that every
# state of the island can be shown without touching the mouse or the hardware.
#
#   ISLET_DEBUG=1 build/Islet.app/Contents/MacOS/Islet &
#   scripts/dev/islet-debug.sh expand
#
# Commands: expand, collapse, hover, unhover, volume, mute, charging, low,
#           output, track, toggle, next, previous, snapshot:/absolute/path.png
#
# "toggle", "next" and "previous" press the player's buttons: they act on
# whatever is really playing, so use them with scripts/dev/fake-player.swift.
# "snapshot" makes Islet draw the island into a PNG by itself, which needs no
# screen-recording permission.

set -euo pipefail

case "${1:-}" in
    expand|collapse|hover|unhover|volume|mute|charging|low|output|track|toggle|next|previous|snapshot:/*.png) ;;
    *)
        echo "usage: $(basename "$0") expand|collapse|hover|unhover|volume|mute|charging|low|output|track|toggle|next|previous|snapshot:/absolute/path.png" >&2
        exit 64
        ;;
esac

# JavaScript for Automation posts the distributed notification without having
# to compile anything.
osascript -l JavaScript -e "
ObjC.import('Foundation');
\$.NSDistributedNotificationCenter.defaultCenter
    .postNotificationNameObjectUserInfoDeliverImmediately(
        'io.github.paulapc94.islet.debug', '$1', \$(), true);
" >/dev/null
