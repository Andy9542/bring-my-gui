#!/bin/bash
# Behaviour suite for skills/bring-my-gui/scripts/oauth-bridge.sh.
#
# RUN IT INSIDE A DISPOSABLE CONTAINER ONLY. It installs packages, shadows
# /usr/bin/xdg-open and rewrites ~/.config/mimeapps.list. On a workstation that
# is vandalism, not a test run.
#
#   docker run --rm -v "$PWD:/repo:ro" ubuntu:24.04 \
#     bash -c 'apt-get update -qq && bash /repo/tests/oauth-bridge.sh'
#   docker exec <container> bash /repo/tests/oauth-bridge.sh     # CI
#
# Two stages, because the two things worth asserting need opposite setups:
# stage A needs the distro's genuine xdg-open (its fallback chain is what the
# shim must not bounce off), stage B needs a stub in its place (an opener that
# records argv is the only way to prove delegation happened at all).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BRIDGE="$HERE/../skills/bring-my-gui/scripts/oauth-bridge.sh"
URL_LOG=/tmp/bring-my-gui/open-urls.log
STUB_LOG=/tmp/bmg-stub-opener.log
PASSED=0
FAILED=0

ok()  { PASSED=$((PASSED+1)); echo "PASS  $1"; }
bad() { FAILED=$((FAILED+1)); echo "FAIL  $1 -- $2"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want [$2] got [$3]"; }

log_lines()  { [ -f "$URL_LOG" ] && wc -l <"$URL_LOG" | tr -d ' ' || echo 0; }
last_url()   { [ -s "$URL_LOG" ] && tail -1 "$URL_LOG" | cut -f2- || echo ""; }
clear_log()  { mkdir -p /tmp/bring-my-gui; : >"$URL_LOG"; }
proc_count() { ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' '; }

# Everything install touches, in one string: a byte-level before/after compare
# is the only honest way to assert "left as found".
state_fingerprint() {
  hash -r   # bash caches resolved paths; without this a deleted alias still "exists"
  if [ -f "$HOME/.config/mimeapps.list" ]; then
    md5sum "$HOME/.config/mimeapps.list" | cut -d' ' -f1
  else
    echo "mimeapps:absent"
  fi
  for a in xdg-open x-www-browser www-browser sensible-browser gnome-open; do
    printf '%s=%s\n' "$a" "$(command -v "$a" 2>/dev/null || echo none)"
  done
  ls /usr/local/bin 2>/dev/null | sort | tr '\n' ' '
}

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
  || echo "NOTE: no xdg-utils in this image — the bounce assertion is weaker here"

FINGERPRINT_BEFORE=$(state_fingerprint)

bash "$BRIDGE" install >/dev/null || { echo "FATAL: install failed" >&2; exit 2; }
hash -r

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
if bash "$BRIDGE" watch 2 60 >/dev/null 2>&1; then
  bad "watch fails when the window holds nothing" "exit 0, expected non-zero"
else
  ok "watch fails when the window holds nothing"
fi

before=$(proc_count)
timeout 10 xdg-open "mailto:bounce@example.com" >/dev/null 2>&1
sleep 2
after=$(proc_count)
if [ "$after" -le $((before + 20)) ]; then
  ok "a non-web scheme does not multiply processes ($before -> $after)"
else
  bad "a non-web scheme does not multiply processes" "$before -> $after"
fi

bash "$BRIDGE" uninstall >/dev/null
eq "uninstall leaves link handling as it was found" "$FINGERPRINT_BEFORE" "$(state_fingerprint)"

# ---------------------------------------------------------------- stage B ---
# Delegation is invisible from the outside, so the real opener is swapped for
# one that records what it was asked to open.
if [ -n "$GENUINE" ]; then
  mv "$GENUINE" "$GENUINE.genuine"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\n' "$STUB_LOG" >"$GENUINE"
  chmod 755 "$GENUINE"
fi
: >"$STUB_LOG"
bash "$BRIDGE" install >/dev/null
hash -r

xdg-open "mailto:delegated@example.com" >/dev/null 2>&1
if grep -q "delegated@example.com" "$STUB_LOG" 2>/dev/null; then
  ok "a non-web scheme reaches the real opener under the xdg-open name"
else
  bad "a non-web scheme reaches the real opener under the xdg-open name" "stub was never called"
fi

: >"$STUB_LOG"
x-www-browser "mailto:aliased@example.com" >/dev/null 2>&1
if grep -q "aliased@example.com" "$STUB_LOG" 2>/dev/null; then
  bad "a browser alias never delegates" "stub was called through x-www-browser"
else
  ok "a browser alias never delegates"
fi

bash "$BRIDGE" uninstall >/dev/null
[ -n "$GENUINE" ] && mv "$GENUINE.genuine" "$GENUINE"

echo "=== $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
