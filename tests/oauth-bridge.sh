#!/bin/bash
# Behaviour suite for skills/bring-my-gui/scripts/oauth-bridge.sh.
#
# RUN IT INSIDE A DISPOSABLE CONTAINER ONLY. It installs packages, shadows
# /usr/bin/xdg-open, rewrites ~/.config/mimeapps.list and runs commands as
# `nobody`. On a workstation that is vandalism, not a test run.
#
#   docker run --rm -v "$PWD:/repo:ro" ubuntu:24.04 \
#     bash -c 'apt-get update -qq && bash /repo/tests/oauth-bridge.sh'
#   docker exec <container> bash /repo/tests/oauth-bridge.sh     # CI
#
# Three stages, because the things worth asserting need different setups:
# stage A needs the distro's genuine xdg-open (its fallback chain is what the
# shim must not bounce off), stage B needs a stub in its place (an opener that
# records argv is the only way to prove delegation happened at all), stage C
# puts that stub in the shim's own directory (the install has to move it aside
# and still find it on the next install).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BRIDGE="$HERE/../skills/bring-my-gui/scripts/oauth-bridge.sh"
URL_LOG=/tmp/bring-my-gui/open-urls.log
SEEN=/tmp/bring-my-gui/watch.seen
STUB_LOG=/tmp/bmg-stub-opener.log
MIMEAPPS="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
PASSED=0
FAILED=0

ok()  { PASSED=$((PASSED+1)); echo "PASS  $1"; }
bad() { FAILED=$((FAILED+1)); echo "FAIL  $1 -- $2"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want [$2] got [$3]"; }
note(){ echo "NOTE  $1"; }

log_lines()  { [ -f "$URL_LOG" ] && wc -l <"$URL_LOG" | tr -d ' ' || echo 0; }
last_url()   { [ -s "$URL_LOG" ] && tail -1 "$URL_LOG" | cut -f2- || echo ""; }
clear_log()  { mkdir -p /tmp/bring-my-gui; : >"$URL_LOG"; rm -f "$SEEN"; }
proc_count() { ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' '; }
stamp()      { date +%s; }

# Run a shell command as an unprivileged user, whichever tool this image has.
as_nobody() {
  if command -v su >/dev/null 2>&1; then su -s /bin/sh nobody -c "$1"
  elif command -v chroot >/dev/null 2>&1; then chroot --userspec=65534:65534 / sh -c "$1"
  else return 99; fi
}

# Everything install touches, in one string: a byte-level before/after compare
# is the only honest way to assert "left as found". xdg-mime is consulted too
# because a desktop entry can outlive its file through mimeinfo.cache.
state_fingerprint() {
  hash -r   # bash caches resolved paths; without this a deleted alias still "exists"
  if [ -f "$MIMEAPPS" ]; then
    md5sum "$MIMEAPPS" | cut -d' ' -f1
  else
    echo "mimeapps:absent"
  fi
  for a in xdg-open x-www-browser www-browser sensible-browser gnome-open; do
    printf '%s=%s\n' "$a" "$(command -v "$a" 2>/dev/null || echo none)"
  done
  ls /usr/local/bin 2>/dev/null | sort | tr '\n' ' '
  for f in /usr/share/applications/bmg-* "$HOME"/.local/share/applications/bmg-*; do
    [ -e "$f" ] && printf '%s ' "$f"
  done; echo
  if command -v xdg-mime >/dev/null 2>&1; then
    printf 'https=%s cursor=%s\n' \
      "$(XDG_UTILS_DEBUG_LEVEL=0 xdg-mime query default x-scheme-handler/https 2>/dev/null)" \
      "$(XDG_UTILS_DEBUG_LEVEL=0 xdg-mime query default x-scheme-handler/cursor 2>/dev/null)"
  fi
}

# A failed assertion must not leave the container's opener stubbed: CI runs
# more steps in the same container after this suite.
GENUINE=""
STUB=""
CSTUB_ACTIVE=""
cleanup() {
  [ -n "$STUB" ] && [ -f "$STUB.genuine" ] && mv -f "$STUB.genuine" "$STUB"
  [ -n "$STUB" ] && [ -z "$GENUINE" ] && rm -f "$STUB"
  [ -n "$CSTUB_ACTIVE" ] && rm -f /usr/local/bin/xdg-open /usr/local/bin/xdg-open.bmg-orig
  return 0
}
trap cleanup EXIT

echo "=== bridge suite: $BRIDGE"
[ -f "$BRIDGE" ] || { echo "FATAL: bridge script not found at $BRIDGE" >&2; exit 2; }

# ---------------------------------------------------------------- stage A ---
# The genuine opener must exist before install: the shim records it as its
# delegate, and without it the bounce assertion has nothing to bounce off.
command -v xdg-open >/dev/null ||
  { command -v apt-get >/dev/null && apt-get install -y -qq xdg-utils >/dev/null 2>&1; } ||
  { command -v dnf     >/dev/null && dnf install -y -q xdg-utils >/dev/null 2>&1; } ||
  { command -v apk     >/dev/null && apk add --no-cache xdg-utils >/dev/null 2>&1; } || true
hash -r
GENUINE=$(command -v xdg-open 2>/dev/null || echo "")
[ -n "$GENUINE" ] && echo "genuine opener: $GENUINE" \
  || note "no xdg-utils in this image — the bounce assertion is weaker here"

FINGERPRINT_BEFORE=$(state_fingerprint)
PRE_MIMEAPPS=""
if [ -f "$MIMEAPPS" ]; then PRE_MIMEAPPS=$(mktemp); cp "$MIMEAPPS" "$PRE_MIMEAPPS"; fi
restore_pre_mimeapps() {
  rm -f "$MIMEAPPS" "$MIMEAPPS".bmg-*
  [ -n "$PRE_MIMEAPPS" ] && cp "$PRE_MIMEAPPS" "$MIMEAPPS"
  return 0
}

bash "$BRIDGE" install >/dev/null || { echo "FATAL: install failed" >&2; exit 2; }
hash -r

# -- capture ---------------------------------------------------------------
clear_log
xdg-open "https://example.com/plain" 2>/dev/null
eq "url in first position is captured" "https://example.com/plain" "$(last_url)"

clear_log
xdg-open "https://example.com/once" 2>/dev/null
eq "one invocation writes one line" "1" "$(log_lines)"

clear_log
x-www-browser --new-window "https://example.com/flagged" 2>/dev/null
eq "url after a flag is captured" "https://example.com/flagged" "$(last_url)"

clear_log
xdg-open "HTTPS://EXAMPLE.COM/UPPER" 2>/dev/null
eq "an upper-case scheme is still a web url" "HTTPS://EXAMPLE.COM/UPPER" "$(last_url)"

clear_log
xdg-open "https://example.com/with
newline" 2>/dev/null
eq "a url with an embedded newline stays one log line" "1" "$(log_lines)"

if command -v xdg-mime >/dev/null 2>&1; then
  eq "xdg-mime default for https is the bridge entry" "bmg-open.desktop" \
     "$(XDG_UTILS_DEBUG_LEVEL=0 xdg-mime query default x-scheme-handler/https 2>/dev/null)"
fi

if [ -n "$GENUINE" ]; then
  clear_log
  "$GENUINE" "https://example.com/absolute" >/dev/null 2>&1
  eq "the genuine opener called by absolute path lands in the log" "https://example.com/absolute" "$(last_url)"
fi

# -- non-root caller -------------------------------------------------------
# The agent installs as root; the GUI app often runs as someone else. The dir
# and the log are created by root (here: by `watch`) and must stay writable.
rm -f "$URL_LOG" "$SEEN"
bash "$BRIDGE" watch 1 0 >/dev/null 2>&1 || true
if as_nobody "xdg-open https://example.com/nonroot" >/dev/null 2>&1; rc=$?; [ "$rc" -ne 99 ]; then
  eq "a non-root caller's url lands in the root-created log" "https://example.com/nonroot" "$(last_url)"
  rm -f "$URL_LOG" "$SEEN"
  as_nobody "xdg-open https://example.com/nonroot-first" >/dev/null 2>&1
  eq "a non-root caller can create the log itself" "https://example.com/nonroot-first" "$(last_url)"
  bash "$BRIDGE" url >/dev/null 2>&1 && ok "root can read a log the non-root caller created" \
    || bad "root can read a log the non-root caller created" "url failed"
else
  note "no su/chroot here — non-root capture not asserted"
fi

# -- watch -----------------------------------------------------------------
clear_log
( sleep 2; xdg-open "https://example.com/while-waiting" 2>/dev/null ) &
got=$(bash "$BRIDGE" watch 20 2>/dev/null)
eq "watch reports a url that arrives while it waits" "https://example.com/while-waiting" "$got"
wait

clear_log
xdg-open "https://example.com/just-before" 2>/dev/null
sleep 2
got=$(bash "$BRIDGE" watch 5 60 2>/dev/null)
eq "watch reports a url from just before it started" "https://example.com/just-before" "$got"

got=$(bash "$BRIDGE" watch 2 60 2>/dev/null || true)
eq "watch does not re-hand a URL it already printed" "" "$got"

xdg-open "https://example.com/retry" 2>/dev/null
got=$(bash "$BRIDGE" watch 5 60 2>/dev/null)
eq "watch reports a newer URL after a retry" "https://example.com/retry" "$got"

clear_log
xdg-open "https://example.com/peek" 2>/dev/null
eq "url prints the last captured URL" "https://example.com/peek" "$(bash "$BRIDGE" url 2>/dev/null)"
got=$(bash "$BRIDGE" watch 5 60 2>/dev/null)
eq "watch lookback still sees a URL after url peek" "https://example.com/peek" "$got"

clear_log
if bash "$BRIDGE" watch 2 60 >/dev/null 2>&1; then
  bad "watch fails when the window holds nothing" "exit 0, expected non-zero"
else
  ok "watch fails when the window holds nothing"
fi

clear_log
printf '%s\thttps://example.com/first\n%s\thttps://example.com/second\n' "$(stamp)" "$(stamp)" >>"$URL_LOG"
got=$(bash "$BRIDGE" watch 5 60 2>/dev/null | tr '\n' ' ')
eq "two urls in one second are both handed out, oldest first" "https://example.com/first https://example.com/second " "$got"
got=$(bash "$BRIDGE" watch 2 60 2>/dev/null || true)
eq "neither is handed out twice" "" "$got"

clear_log
( sleep 1; printf '%s\thttps://example.com/pair-a\n%s\thttps://example.com/pair-b\n' "$(stamp)" "$(stamp)" >>"$URL_LOG" ) &
got=$(bash "$BRIDGE" watch 10 0 2>/dev/null | tr '\n' ' ')
wait
eq "two urls landing in one poll are both handed out" "https://example.com/pair-a https://example.com/pair-b " "$got"

clear_log
printf '%s\thttps://example.com/ahead\n' "$(( $(stamp) + 1 ))" >>"$URL_LOG"
got=$(bash "$BRIDGE" watch 3 60 2>/dev/null)
eq "a stamp a second ahead of the clock is still recent" "https://example.com/ahead" "$got"

clear_log
if bash "$BRIDGE" watch 30s >/dev/null 2>&1; then
  bad "watch rejects a non-numeric timeout" "exit 0"
else
  rc=$?; eq "watch rejects a non-numeric timeout" "2" "$rc"
fi

# -- bounce ----------------------------------------------------------------
before=$(proc_count)
timeout 10 xdg-open "mailto:bounce@example.com" >/dev/null 2>&1
sleep 2
after=$(proc_count)
if [ "$after" -le $((before + 20)) ]; then
  ok "a non-web scheme does not multiply processes ($before -> $after)"
else
  bad "a non-web scheme does not multiply processes" "$before -> $after"
fi

# -- left as found ---------------------------------------------------------
# A registration made by someone else after install outlives uninstall.
printf 'x-scheme-handler/foo=foo.desktop\n' >>"$MIMEAPPS"
bash "$BRIDGE" uninstall >/dev/null
if grep -q '^x-scheme-handler/foo=foo.desktop$' "$MIMEAPPS" 2>/dev/null && ! grep -q 'bmg-' "$MIMEAPPS"; then
  ok "a third-party mimeapps entry written after install survives uninstall"
else
  bad "a third-party mimeapps entry written after install survives uninstall" "$(cat "$MIMEAPPS" 2>/dev/null || echo absent)"
fi
restore_pre_mimeapps
bash "$BRIDGE" install >/dev/null; hash -r

# An install that predates the backup (old script, or markers lost) must not
# make uninstall "restore" a file that already carried our keys.
rm -f "$MIMEAPPS.bmg-orig" "$MIMEAPPS.bmg-absent" "$MIMEAPPS.bmg-installed"
bash "$BRIDGE" install >/dev/null
bash "$BRIDGE" uninstall >/dev/null
eq "uninstall over an install that predates the backup leaves no dangling default" "$FINGERPRINT_BEFORE" "$(state_fingerprint)"

bash "$BRIDGE" install >/dev/null
bash "$BRIDGE" handler cursor "echo %U" >/dev/null
bash "$BRIDGE" install >/dev/null
bash "$BRIDGE" uninstall >/dev/null
eq "uninstall after install, handler, install restores link handling" "$FINGERPRINT_BEFORE" "$(state_fingerprint)"

# ---------------------------------------------------------------- stage B ---
# Delegation is invisible from the outside, so the real opener is swapped for
# one that records what it was asked to open. Without a genuine opener the
# stub still goes to /usr/bin/xdg-open — the path the shim falls back to.
STUB="${GENUINE:-/usr/bin/xdg-open}"
[ -n "$GENUINE" ] && mv "$GENUINE" "$GENUINE.genuine"
mkdir -p "$(dirname "$STUB")"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\n' "$STUB_LOG" >"$STUB"
chmod 755 "$STUB"
: >"$STUB_LOG"
bash "$BRIDGE" install >/dev/null
hash -r

# The stub is silent, so anything on stderr here is the shim's own noise.
err=$(xdg-open "mailto:delegated@example.com" 2>&1 >/dev/null)
if grep -q "delegated@example.com" "$STUB_LOG" 2>/dev/null && [ -z "$err" ]; then
  ok "a non-web scheme reaches the real opener under the xdg-open name, quietly"
else
  bad "a non-web scheme reaches the real opener under the xdg-open name, quietly" "stub called: $(grep -c delegated "$STUB_LOG" 2>/dev/null), stderr: [$err]"
fi

: >"$STUB_LOG"
x-www-browser "mailto:aliased@example.com" >/dev/null 2>&1
if grep -q "aliased@example.com" "$STUB_LOG" 2>/dev/null; then
  bad "a browser alias never delegates" "stub was called through x-www-browser"
else
  ok "a browser alias never delegates"
fi

# An app the real opener launched inherits BMG_DELEGATED; its own non-web
# opens must still reach the opener once (the guard is a depth cap, not a wall).
: >"$STUB_LOG"
err=$(BMG_DELEGATED=1 xdg-open "mailto:from-launched-app@example.com" 2>&1 >/dev/null)
if grep -q "from-launched-app@example.com" "$STUB_LOG" 2>/dev/null && [ -z "$err" ]; then
  ok "an app launched through the opener can still open a non-web link"
else
  bad "an app launched through the opener can still open a non-web link" "stub was never called"
fi
: >"$STUB_LOG"
BMG_DELEGATED=2 xdg-open "mailto:too-deep@example.com" >/dev/null 2>&1
if grep -q "too-deep@example.com" "$STUB_LOG" 2>/dev/null; then
  bad "delegation stops at depth two" "stub was called at depth 2"
else
  ok "delegation stops at depth two"
fi

bash "$BRIDGE" uninstall >/dev/null
if [ -n "$GENUINE" ]; then mv "$GENUINE.genuine" "$GENUINE"; else rm -f "$STUB"; fi
STUB=""
hash -r

# ---------------------------------------------------------------- stage C ---
# The real opener lives in the shim's own directory. install has to move it
# aside, point the shim at the copy, and find that copy again on re-install.
CSTUB=/usr/local/bin/xdg-open
if [ -e "$CSTUB" ]; then
  note "$CSTUB already exists — same-dir opener case not asserted"
else
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\n' "$STUB_LOG" >"$CSTUB"
  chmod 755 "$CSTUB"
  CSTUB_ACTIVE=1
  csum=$(md5sum <"$CSTUB")
  hash -r
  bash "$BRIDGE" install >/dev/null
  bash "$BRIDGE" install >/dev/null
  hash -r
  : >"$STUB_LOG"
  xdg-open "mailto:same-dir@example.com" >/dev/null 2>&1
  if grep -q "same-dir@example.com" "$STUB_LOG" 2>/dev/null; then
    ok "an opener in the shim's own dir still gets non-web schemes after a double install"
  else
    bad "an opener in the shim's own dir still gets non-web schemes after a double install" "stub was never called"
  fi
  bash "$BRIDGE" uninstall >/dev/null
  hash -r
  eq "uninstall puts the same-dir opener back" "$csum" "$(md5sum <"$CSTUB" 2>/dev/null)"
  rm -f "$CSTUB"
  CSTUB_ACTIVE=""
  hash -r
fi

echo "=== $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
