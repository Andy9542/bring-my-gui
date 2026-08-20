#!/bin/bash
# bring-my-gui setup: install whatever provides the binaries, not a remembered
# package list. Names split and rename across distro generations; never hardcode
# a family-specific X11 package list. Source of truth: binaries the stack execs.
# If this script can't run (no bash), SKILL.md § Install by binary, then
# § Manual stack.
set -u

need() { command -v "$1" >/dev/null 2>&1; }

SUDO=sudo
if [ "$(id -u)" = 0 ] || ! need sudo; then SUDO=""; fi

if need apt-get; then
  PM=apt
elif need dnf; then
  PM=dnf
elif need yum; then
  PM=yum
elif need apk; then
  PM=apk
else
  echo "FATAL: no apt/dnf/yum/apk — install packages that provide: Xvfb x11vnc openbox setxkbmap xwininfo" >&2
  exit 1
fi

NEED="Xvfb x11vnc openbox setxkbmap xwininfo"
NICE="autocutsel xmodmap xclip xdotool python3 pgrep"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Install one manager-native package name. Failure must not kill the script:
# we try several guesses per binary.
pkg_install() {
  local pkg="$1"
  [ -n "$pkg" ] || return 1
  case "$PM" in
    apt) DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "$pkg" ;;
    dnf) $SUDO dnf install -y "$pkg" ;;
    yum) $SUDO yum install -y "$pkg" ;;
    apk) $SUDO apk add "$pkg" ;;
  esac
}

# Ask the index which package owns /usr/bin/<binary>. Description search
# (apt-cache search) ranks a GUI that mentions the tool above the package
# that ships the file.
APT_FILE_READY=0
ensure_apt_file_index() {
  [ "$PM" = apt ] || return 1
  [ "$APT_FILE_READY" = 1 ] && return 0
  if ! need apt-file; then
    pkg_install apt-file >/dev/null 2>&1 || return 1
  fi
  # apt-file has no -q; Contents download is required before search.
  $SUDO apt-file update >/dev/null 2>&1 || return 1
  APT_FILE_READY=1
}

# First search hit: the package that provides the binary file.
search_pkg() {
  local bin="$1" guess hit
  guess=$(lower "$bin")
  case "$PM" in
    apt)
      if ensure_apt_file_index; then
        apt-file --package-only search -x "/usr/bin/${bin}$" 2>/dev/null \
          | awk '/^[a-zA-Z0-9][a-zA-Z0-9.+-]*$/{print; exit}'
      fi
      ;;
    apk)
      hit=$(apk search -e "$guess" 2>/dev/null | sed 's/-[0-9].*$//;q')
      [ -n "$hit" ] && { echo "$hit"; return; }
      apk search -q "$guess" 2>/dev/null | sed 's/-[0-9].*$//;q'
      ;;
    dnf)
      dnf repoquery -q --whatprovides "/usr/bin/$bin" 2>/dev/null | head -1
      ;;
    yum)
      $SUDO yum -q whatprovides "/usr/bin/$bin" 2>/dev/null | awk '/^[[:alnum:]]/{print $1; exit}'
      ;;
  esac
}

provide() {
  local bin="$1" guess pkg
  need "$bin" && return 0
  guess=$(lower "$bin")

  # dnf/yum can install by the file they should provide — no name needed.
  if [ "$PM" = dnf ] || [ "$PM" = yum ]; then
    if $SUDO "$PM" install -y "/usr/bin/$bin" >/dev/null 2>&1 && need "$bin"; then return 0; fi
  fi

  # Package often equals the lowercased binary (xvfb, x11vnc, openbox, …).
  if pkg_install "$guess" >/dev/null 2>&1 && need "$bin"; then return 0; fi

  pkg=$(search_pkg "$bin" | awk 'NF{print; exit}')
  case "$pkg" in
    ''|*' '*) return 1 ;;
  esac
  if pkg_install "$pkg" && need "$bin"; then return 0; fi
  return 1
}

case "$PM" in
  apt) $SUDO apt-get update -qq ;;
  apk) $SUDO apk update -q ;;
esac

miss=""
for b in $NEED; do
  provide "$b" || miss="$miss $b"
done
for b in $NICE; do
  provide "$b" || echo "WARN: $b not installed — optional, stack degrades (search the repo for this binary if you need it)" >&2
done

[ -z "$miss" ] || {
  echo "FATAL: still missing:$miss — find which package owns /usr/bin/NAME on this distro, install, retry" >&2
  exit 1
}
echo "bring-my-gui: stack installed OK"
