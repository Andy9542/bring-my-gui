#!/bin/bash
# bring-my-gui OAuth bridge: finish a browser login for an app that runs in a
# sandbox with no usable browser. The app's "open this URL" call is captured
# and the URL is opened in the USER's host browser instead.
#
# Usage (in the sandbox):
#   oauth-bridge.sh install              # capture every http(s) open request
#   oauth-bridge.sh watch [SECONDS] [LOOKBACK]  # print a recent URL, or wait for one
#   oauth-bridge.sh url                  # print the last captured URL
#   oauth-bridge.sh handler SCHEME 'CMD %U'   # route app://… deep links back to the app
#   oauth-bridge.sh status | uninstall
# Usage (on the user's host, optional — see § listener below):
#   oauth-bridge.sh listen
#
# Env: BIN_DIR HOST_PORT HOST_ADDR BMG_TOKEN (install) / PORT BMG_TOKEN BIND ONCE TIMEOUT (listen)
# Log: /tmp/bring-my-gui/open-urls.log
#
# Why this exists and what it cannot do — SKILL.md § Browser login (OAuth).
# The short version: the browser ends up on the host, so the login's LAST step
# lands there too. Apps that poll their API for the token (Cursor) or print a
# code to paste (device-code flows) finish inside the sandbox with no extra
# work. Apps that need the redirect to hit http://localhost:PORT of the SANDBOX
# need that port published; apps that only accept a custom-scheme callback
# cannot be bridged this way at all.
#
# Deliberate choices (do not "fix" without reading references/gotchas.md):
#  - non-http schemes are passed to the REAL xdg-open, never to the host: a
#    cursor:// deep link belongs to the app in THIS sandbox, and the host's
#    copy of the same app would grab it.
#  - that delegation is name-keyed: only an invocation whose basename is
#    xdg-open execs the real opener. Called as x-www-browser the shim exits,
#    so xdg-open's own fallback chain (which calls x-www-browser) hits a dead
#    end instead of turning around. BMG_DELEGATED is a second line of defence
#    for the remaining bounce (gotchas § Browser login).
#  - the URL is the first http(s) token in argv, not $1: browser-style callers
#    put flags first (x-www-browser --new-window URL), and those callers are
#    why the aliases exist.
#  - the shim is a file on PATH, not an env var: the app is already running
#    (and was started by another process), so $BROWSER can't reach it.
#  - host address is resolved at install time and baked in: the shim is exec'd
#    by the app with the app's environment, not yours.
set -u

LOG_DIR="/tmp/bring-my-gui"
URL_LOG="$LOG_DIR/open-urls.log"
SEEN_FILE="$LOG_DIR/watch.seen"
SHIM_NAME="bmg-open"
DESKTOP_ID="bmg-open.desktop"
# Names other launchers call instead of xdg-open (Debian alternatives, GNOME).
ALIASES="xdg-open x-www-browser www-browser sensible-browser gnome-open"
MARKER="bring-my-gui URL handoff shim"
MIMEAPPS="$HOME/.config/mimeapps.list"
MIMEAPPS_ORIG="$MIMEAPPS.bmg-orig"
MIMEAPPS_ABSENT="$MIMEAPPS.bmg-absent"

mkdir -p "$LOG_DIR" 2>/dev/null || true

die() { echo "FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- install ---

# First writable dir; /usr/local/bin precedes /usr/bin in the default PATH of
# every mainstream image, which is what lets the shim shadow the real xdg-open.
pick_bin_dir() {
  local d
  for d in "${BIN_DIR:-}" /usr/local/bin "$HOME/.local/bin"; do
    [ -n "$d" ] || continue
    mkdir -p "$d" 2>/dev/null || continue
    [ -w "$d" ] && { echo "$d"; return 0; }
  done
  return 1
}

# Where the host is reachable from inside the sandbox. Docker Desktop provides
# host.docker.internal; on plain Linux docker it exists only with
# --add-host=host.docker.internal:host-gateway, so fall back to the gateway.
# --network host makes the default route the LAN router, not the user's
# machine: pass HOST_ADDR in that case, the guess will be wrong.
detect_host_addr() {
  [ -n "${HOST_ADDR:-}" ] && { echo "$HOST_ADDR"; return; }
  if getent hosts host.docker.internal >/dev/null 2>&1; then
    echo host.docker.internal; return
  fi
  ip route 2>/dev/null | awk '/^default/{print $3; exit}'
}

# The real handler, resolved BEFORE we shadow it (and never our own shim).
detect_real_xdg_open() {
  local c
  for c in $(command -v -a xdg-open 2>/dev/null) /usr/bin/xdg-open; do
    [ -x "$c" ] || continue
    grep -q "$MARKER" "$c" 2>/dev/null && continue
    echo "$c"; return 0
  done
  echo ""
}

write_shim() {  # $1=path $2=host $3=port $4=token $5=real xdg-open
  cat >"$1" <<'SHIM'
#!/bin/sh
# bring-my-gui URL handoff shim — generated, do not edit (oauth-bridge.sh install).
# Web URLs: logged for the agent + pushed to the user's host browser.
# Everything else (app:// deep links, file paths): handed to the real opener,
# because those callbacks belong to the app running HERE.
BMG_HOST='@HOST@'
BMG_PORT='@PORT@'
BMG_TOKEN='@TOKEN@'
BMG_REAL='@REAL@'
BMG_LOG=/tmp/bring-my-gui/open-urls.log

url=
for a in "$@"; do
  case "$a" in
    http://*|https://*) url=$a; break ;;
  esac
done
if [ -z "$url" ]; then
  # No web URL in argv. Delegate file paths and app:// links only when we
  # were invoked as xdg-open — as a browser alias this is not our job, and
  # returning into xdg-open's fallback chain is the fork bomb.
  [ "${0##*/}" = xdg-open ] || exit 0
  [ -n "${BMG_DELEGATED:-}" ] && exit 0
  [ -n "$BMG_REAL" ] && [ -x "$BMG_REAL" ] && { BMG_DELEGATED=1; export BMG_DELEGATED; exec "$BMG_REAL" "$@"; }
  exit 0
fi

mkdir -p /tmp/bring-my-gui 2>/dev/null
printf '%s\t%s\n' "$(date +%s 2>/dev/null || echo 0)" "$url" >>"$BMG_LOG" 2>/dev/null

[ -n "$BMG_PORT" ] || exit 0   # no listener configured: the agent reads the log
# One POST, whichever client this image happens to have. The URL travels as the
# body: no shell-quoting or percent-encoding to get wrong.
if command -v curl >/dev/null 2>&1; then
  curl -fsS --max-time 5 -X POST -H "X-Bmg-Token: $BMG_TOKEN" \
    --data-binary "$url" "http://$BMG_HOST:$BMG_PORT/" >/dev/null 2>&1
elif command -v nc >/dev/null 2>&1; then
  printf 'POST / HTTP/1.0\r\nHost: %s\r\nX-Bmg-Token: %s\r\nContent-Length: %s\r\n\r\n%s' \
    "$BMG_HOST" "$BMG_TOKEN" "${#url}" "$url" | nc "$BMG_HOST" "$BMG_PORT" >/dev/null 2>&1
elif [ -x /bin/bash ]; then
  BMG_URL=$url BMG_HOST=$BMG_HOST BMG_PORT=$BMG_PORT BMG_TOKEN=$BMG_TOKEN /bin/bash -c '
    exec 3<>/dev/tcp/"$BMG_HOST"/"$BMG_PORT" 2>/dev/null || exit 0
    printf "POST / HTTP/1.0\r\nX-Bmg-Token: %s\r\nContent-Length: %s\r\n\r\n%s" \
      "$BMG_TOKEN" "${#BMG_URL}" "$BMG_URL" >&3' >/dev/null 2>&1
fi
exit 0
SHIM
  sed -i.bak -e "s|@HOST@|$2|" -e "s|@PORT@|$3|" -e "s|@TOKEN@|$4|" -e "s|@REAL@|$5|" "$1" \
    && rm -f "$1.bak"
  chmod 755 "$1"
}

# xdg-open in "generic" mode (no desktop environment) reads mimeapps.list, so
# apps that call the REAL opener by absolute path still land on the shim.
mimeapps_set() {  # $1=mime/scheme key  $2=desktop id
  local f="$HOME/.config/mimeapps.list" tmp
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  tmp=$(mktemp) || return 1
  grep -v -E "^$(printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g')=" "$f" 2>/dev/null >"$tmp"
  grep -q '^\[Default Applications\]' "$tmp" || echo '[Default Applications]' >>"$tmp"
  awk -v k="$1" -v v="$2" '
    {print}
    /^\[Default Applications\]$/ && !done {print k "=" v; done=1}
  ' "$tmp" >"$f"
  rm -f "$tmp"
}

backup_mimeapps() {
  if [ -f "$MIMEAPPS_ORIG" ] || [ -f "$MIMEAPPS_ABSENT" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$MIMEAPPS")" 2>/dev/null || return 1
  if [ -f "$MIMEAPPS" ]; then
    cp "$MIMEAPPS" "$MIMEAPPS_ORIG"
  else
    : >"$MIMEAPPS_ABSENT"
  fi
}

# Predates this backup: drop only the keys we wrote, leave the rest.
mimeapps_drop_ours() {
  local f="$MIMEAPPS" tmp
  [ -f "$f" ] || return 0
  tmp=$(mktemp) || return 1
  grep -v -E "=$(printf '%s' "$DESKTOP_ID" | sed 's/[][\.*^$/]/\\&/g')$" "$f" >"$tmp"
  mv "$tmp" "$f"
  [ -s "$f" ] || rm -f "$f"
}

write_desktop() {  # $1=id $2=name $3=exec $4=scheme list (semicolon separated)
  local dir
  for dir in /usr/share/applications "$HOME/.local/share/applications"; do
    mkdir -p "$dir" 2>/dev/null || continue
    [ -w "$dir" ] || continue
    cat >"$dir/$1" <<EOF
[Desktop Entry]
Type=Application
Name=$2
Exec=$3
Terminal=false
NoDisplay=true
MimeType=$4
EOF
    command -v update-desktop-database >/dev/null 2>&1 \
      && update-desktop-database "$dir" >/dev/null 2>&1
    echo "$dir/$1"; return 0
  done
  return 1
}

cmd_install() {
  local bin real host port token shim
  bin=$(pick_bin_dir) || die "no writable bin dir (tried BIN_DIR, /usr/local/bin, ~/.local/bin)"
  real=$(detect_real_xdg_open)
  host=$(detect_host_addr)
  port="${HOST_PORT:-}"
  token="${BMG_TOKEN:-$(head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')}"
  shim="$bin/$SHIM_NAME"

  write_shim "$shim" "$host" "$port" "$token" "$real" || die "cannot write $shim"

  # The shim answers to every name a launcher might use. If the real opener
  # lives in this same dir we'd clobber it — keep a copy and point the shim at it.
  local a
  for a in $ALIASES; do
    if [ -f "$bin/$a" ] && ! grep -q "$MARKER" "$bin/$a" 2>/dev/null; then
      mv "$bin/$a" "$bin/$a.bmg-orig"
      [ "$real" = "$bin/$a" ] && { real="$bin/$a.bmg-orig"; write_shim "$shim" "$host" "$port" "$token" "$real"; }
    fi
    ln -sf "$SHIM_NAME" "$bin/$a"
  done

  write_desktop "$DESKTOP_ID" "Host browser (bring-my-gui)" "$shim %u" \
    "x-scheme-handler/http;x-scheme-handler/https;text/html;" >/dev/null || true
  backup_mimeapps
  mimeapps_set x-scheme-handler/http  "$DESKTOP_ID" 2>/dev/null || true
  mimeapps_set x-scheme-handler/https "$DESKTOP_ID" 2>/dev/null || true
  mimeapps_set text/html              "$DESKTOP_ID" 2>/dev/null || true
  xdg-settings set default-web-browser "$DESKTOP_ID" >/dev/null 2>&1 || true

  # CLIs that read $BROWSER instead of calling xdg-open: covers future shells,
  # not the app already running (relaunch it, or export by hand).
  if [ -w /etc/profile.d ] 2>/dev/null || mkdir -p /etc/profile.d 2>/dev/null; then
    echo "export BROWSER=$shim" >/etc/profile.d/bmg-browser.sh 2>/dev/null || true
  fi

  echo "OAuth bridge installed: $shim"
  echo "  captures: $ALIASES  (+ $DESKTOP_ID as default browser)"
  echo "  URL log:  $URL_LOG"
  echo "  \$BROWSER: login shells only (profile.d) — this shell: export BROWSER=$shim"
  local resolved; resolved=$(command -v xdg-open 2>/dev/null || true)
  if [ -n "$resolved" ] && ! grep -q "$MARKER" "$resolved" 2>/dev/null; then
    echo "WARN: xdg-open still resolves to $resolved — put $bin first: export PATH=$bin:\$PATH" >&2
  fi
  if [ -n "$port" ]; then
    echo "  host push: http://$host:$port  (user runs on the HOST:"
    echo "             BMG_TOKEN=$token PORT=$port bash scripts/oauth-bridge.sh listen )"
    echo "  note: auto host is $host — under --network host that is the LAN router; pass HOST_ADDR"
    [ -n "$host" ] || echo "WARN: host address unknown — pass HOST_ADDR=… and re-run install" >&2
  else
    echo "  host push: off — default flow: 'oauth-bridge.sh watch', hand the URL to the user"
    echo "  note: if you later set HOST_PORT, auto host is ${host:-unknown} — under --network host that is the LAN router; pass HOST_ADDR"
  fi
  echo "  note: mimeapps.list is written under this user (\$HOME=$HOME); an app"
  echo "        running as another user will not see it — PATH shim still applies"
}

# ------------------------------------------------------------------ watch ---

cmd_watch() {  # $1 = seconds to wait (default 180); $2 = lookback seconds (default 60)
  local timeout="${1:-180}" lookback="${2:-60}" before now deadline n line epoch url found found_n found_line seen_n seen_line i actual
  : >>"$URL_LOG" 2>/dev/null || die "cannot write $URL_LOG"
  seen_n=0 seen_line=""
  if [ -f "$SEEN_FILE" ]; then
    seen_n=$(sed -n '1p' "$SEEN_FILE")
    seen_line=$(sed -n '2p' "$SEEN_FILE")
    case "$seen_n" in *[!0-9]*|'') seen_n=0 ;; esac
  fi
  n=$(wc -l <"$URL_LOG")
  if [ "$seen_n" -gt 0 ]; then
    if [ "$n" -lt "$seen_n" ]; then
      seen_n=0
    else
      actual=$(sed -n "${seen_n}p" "$URL_LOG")
      [ "$actual" = "$seen_line" ] || seen_n=0
    fi
  fi
  now=$(date +%s)
  if [ -s "$URL_LOG" ] && [ "$lookback" -gt 0 ] 2>/dev/null; then
    found="" found_n=""
    i=0
    while IFS= read -r line; do
      i=$((i + 1))
      [ "$i" -gt "$seen_n" ] || continue
      epoch=${line%%	*}
      url=${line#*	}
      case "$epoch" in
        *[!0-9]*|'') continue ;;
      esac
      if [ "$epoch" -le "$now" ] && [ $((now - epoch)) -le "$lookback" ]; then
        found=$url
        found_n=$i
        found_line=$line
      fi
    done <"$URL_LOG"
    if [ -n "$found" ]; then
      printf '%s\n%s\n' "$found_n" "$found_line" >"$SEEN_FILE"
      printf '%s\n' "$found"
      return 0
    fi
  fi
  before=$(wc -l <"$URL_LOG")
  deadline=$(( now + timeout ))
  echo "watching $URL_LOG for a new URL (${timeout}s, lookback ${lookback}s) — trigger the login now" >&2
  while :; do
    n=$(wc -l <"$URL_LOG")
    if [ "$n" -gt "$before" ]; then
      line=$(tail -1 "$URL_LOG")
      printf '%s\n%s\n' "$n" "$line" >"$SEEN_FILE"
      printf '%s\n' "${line#*	}"
      return 0
    fi
    now=$(date +%s); [ "$now" -lt "$deadline" ] || break
    sleep 1
  done
  echo "no URL in ${timeout}s — the app may print the link in its own UI/log instead" >&2
  return 1
}

cmd_url() {
  [ -s "$URL_LOG" ] || { echo "no URL captured yet" >&2; return 1; }
  tail -1 "$URL_LOG" | cut -f2-
}

# ---------------------------------------------------------------- handler ---

# Route app-scheme callbacks (cursor://, vscode://, …) to the app in THIS
# sandbox. Only useful for links produced inside the sandbox: a redirect that
# happens in the host browser opens the host's app, which we cannot intercept.
cmd_handler() {
  local scheme="${1:-}" exec_line="${2:-}" id
  [ -n "$scheme" ] && [ -n "$exec_line" ] || die "usage: $0 handler SCHEME 'CMD %U'"
  case "$exec_line" in *%[uUfF]*) ;; *) exec_line="$exec_line %U" ;; esac
  id="bmg-scheme-$scheme.desktop"
  write_desktop "$id" "$scheme handler (bring-my-gui)" "$exec_line" \
    "x-scheme-handler/$scheme;" >/dev/null || die "no writable applications dir"
  mimeapps_set "x-scheme-handler/$scheme" "$id" || true
  echo "$scheme:// -> $exec_line"
}

# ----------------------------------------------------------------- status ---

cmd_status() {
  local bin shim resolved
  bin=$(pick_bin_dir 2>/dev/null) || bin=""
  shim="$bin/$SHIM_NAME"
  if [ -n "$bin" ] && [ -x "$shim" ]; then
    echo "shim: $shim"
    sed -n 's/^BMG_\(HOST\|PORT\|REAL\)=/  \1=/p' "$shim"
  else
    echo "shim: NOT INSTALLED"
  fi
  resolved=$(command -v xdg-open 2>/dev/null || echo "(none)")
  if grep -q "$MARKER" "$resolved" 2>/dev/null; then
    echo "xdg-open -> shim OK ($resolved)"
  else
    echo "xdg-open -> $resolved  (NOT the shim — check PATH order)"
  fi
  echo "captured URLs: $( [ -f "$URL_LOG" ] && wc -l <"$URL_LOG" || echo 0 )  ($URL_LOG)"
  [ -s "$URL_LOG" ] && echo "last: $(tail -1 "$URL_LOG" | cut -f2-)"
  return 0
}

cmd_uninstall() {
  local bin a; bin=$(pick_bin_dir 2>/dev/null) || return 0
  for a in $ALIASES; do
    if [ -L "$bin/$a" ] || grep -q "$MARKER" "$bin/$a" 2>/dev/null; then
      rm -f "$bin/$a"
    fi
    [ -f "$bin/$a.bmg-orig" ] && mv "$bin/$a.bmg-orig" "$bin/$a"
  done
  rm -f "$bin/$SHIM_NAME" /etc/profile.d/bmg-browser.sh \
        /usr/share/applications/"$DESKTOP_ID" "$HOME/.local/share/applications/$DESKTOP_ID"
  if [ -f "$MIMEAPPS_ORIG" ]; then
    mv "$MIMEAPPS_ORIG" "$MIMEAPPS"
    rm -f "$MIMEAPPS_ABSENT"
  elif [ -f "$MIMEAPPS_ABSENT" ]; then
    rm -f "$MIMEAPPS" "$MIMEAPPS_ABSENT"
  else
    mimeapps_drop_ours
  fi
  echo "OAuth bridge removed (URL log kept: $URL_LOG)"
}

# ----------------------------------------------------------------- listen ---
# HOST side, optional. Without it the flow is: agent runs `watch`, pastes the
# URL into the chat, the user clicks it. That needs nothing installed and keeps
# a human between the sandbox and the host browser.
#
# Security: the sandbox reaches the host over the docker bridge, not loopback,
# so the socket is bound on all interfaces and anyone on your LAN could push a
# URL at your browser. Hence: shared token, one-shot by default, and a timeout.

cmd_listen() {
  local port="${PORT:-${HOST_PORT:-5999}}" bind="${BIND:-0.0.0.0}"
  command -v python3 >/dev/null 2>&1 \
    || die "listen needs python3 on the host — use the default flow instead (agent hands you the link)"
  PORT="$port" BIND="$bind" BMG_TOKEN="${BMG_TOKEN:-}" ONCE="${ONCE:-1}" \
  TIMEOUT="${TIMEOUT:-600}" python3 - <<'PY'
import http.server, os, socket, subprocess, sys, threading, webbrowser

port, bind = int(os.environ["PORT"]), os.environ["BIND"]
token, once, timeout = os.environ["BMG_TOKEN"], os.environ["ONCE"] == "1", int(os.environ["TIMEOUT"])
if not token:
    print("WARN: no BMG_TOKEN — any host that can reach this port may open a URL here", file=sys.stderr)

def host_open(url):
    for cmd in (["open", url], ["xdg-open", url], ["cmd", "/c", "start", "", url]):
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            threading.Thread(target=p.wait, daemon=True).start()
            return True
        except OSError:
            continue
    return webbrowser.open(url)

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0)).decode(errors="replace").strip()
        if token and self.headers.get("X-Bmg-Token", "") != token:
            self.send_response(403); self.end_headers(); return
        if not body.startswith(("http://", "https://")):
            self.send_response(400); self.end_headers(); return
        self.send_response(204); self.end_headers()
        print(f"opening: {body}", flush=True)
        host_open(body)
        if once:
            threading.Thread(target=srv.shutdown, daemon=True).start()

srv = http.server.ThreadingHTTPServer((bind, port), H)
print(f"listening on {bind}:{port} ({'one-shot' if once else 'until killed'}, {timeout}s max)")
threading.Timer(timeout, lambda: threading.Thread(target=srv.shutdown, daemon=True).start()).start()
srv.serve_forever()
print("listener done")
PY
}

case "${1:-}" in
  install)   shift; cmd_install "$@" ;;
  watch)     shift; cmd_watch "$@" ;;
  url)       cmd_url ;;
  handler)   shift; cmd_handler "$@" ;;
  status)    cmd_status ;;
  uninstall) cmd_uninstall ;;
  listen)    cmd_listen ;;
  *) echo "usage: $0 install|watch [SEC=180] [LOOKBACK=60]|url|handler SCHEME 'CMD %U'|status|uninstall   (host: $0 listen)" >&2; exit 2 ;;
esac
