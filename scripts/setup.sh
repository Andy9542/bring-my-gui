#!/bin/bash
# bring-my-gui setup: install the forwarding stack. Idempotent.
# apt branch tested live; dnf/apk branches are best-effort — if the final
# check fails, install the named binaries with the distro's package search.
# If this script can't run at all (no bash/sudo), SKILL.md § Manual stack
# lists the packages and commands by hand.
set -e

need() { command -v "$1" >/dev/null 2>&1; }

# root agents often have no sudo binary at all
SUDO=sudo
if [ "$(id -u)" = 0 ] || ! need sudo; then SUDO=""; fi

# package sets per family; per-family notes below
if need apt-get; then
  $SUDO apt-get update -qq
  $SUDO apt-get install -y \
    xvfb x11vnc openbox autocutsel xclip xdotool x11-xkb-utils x11-utils
elif need dnf; then
  # setxkbmap lives in xorg-x11-xkb-utils (NOT xkbutils!);
  # xwininfo lives in xorg-x11-utils.
  # No pipe: piping dnf through tail would swallow its exit status under set -e.
  # autocutsel is absent in many dnf repos — clipboard bridge degrades to
  # x11vnc's own PRIMARY<->client sync; warn, don't fail.
  $SUDO dnf install -y xorg-x11-server-Xvfb x11vnc openbox xclip xdotool \
    xorg-x11-xkb-utils xorg-x11-utils
  need autocutsel || echo "WARN: autocutsel not in dnf — clipboard bridge partial" >&2
elif need apk; then
  # UNTESTED branch; alpine splits xorg oddly — final `need` check is the
  # source of truth, fix names from `apk search` output if it fails.
  $SUDO apk add xorg-server-xvfb x11vnc openbox xclip xdotool \
    xorg-x11-xkb-utils xorg-x11-utils
  need autocutsel || echo "WARN: autocutsel not in apk — clipboard bridge partial" >&2
else
  echo "FATAL: no apt/dnf/apk — install manually: xvfb x11vnc openbox autocutsel xclip xdotool setxkbmap xwininfo" >&2
  exit 1
fi

# source of truth: binaries on PATH, not package exit codes
miss=""
for b in Xvfb x11vnc openbox setxkbmap xwininfo; do
  need "$b" || miss="$miss $b"
done
[ -z "$miss" ] || { echo "FATAL: still missing:$miss — find them with your package search (apk search / dnf provides / apt search) and retry" >&2; exit 1; }
echo "bring-my-gui: stack installed OK"
