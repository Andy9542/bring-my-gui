#!/bin/bash
# bring-my-gui stack manager: Xvfb + openbox + autocutsel + x11vnc
# Usage:  gui-stack.sh start|stop|restart|status
# Env:    DISPLAY_NUM=0 RES=1920x1080 VNC_PORT=5900+DISPLAY_NUM VNC_PASS=sandboxgui WATCHDOG=1
# Logs:   /tmp/bring-my-gui/*.log
# If this script can't run in the sandbox at all — see SKILL.md § Manual stack
# for the same sequence as plain commands.
#
# Deliberate choices (do not "fix" without reading skill references/gotchas.md):
#  - setxkbmap us (NOT us,ru): group-switching desyncs; instead the whole
#    Cyrillic alphabet is pre-loaded onto reserved multimedia keycodes via
#    xmodmap (deterministic; the dynamic -add_keysyms allocator drifts and
#    kills individual letters over time — stage-3 recipe in gotchas).
#  - -xdamage TWICE: single flag lets x11vnc disable XDamage on renderer
#    "misses" → full-screen polling → constant repaint flicker.
#  - -skip_keycodes 184: nosymbol keycode whose lost release blocks all input.
#  - no -encodings flag: not an x11vnc option, kills the server.
#  - pkill -x only: pkill -f matches this script's own cmdline.
#  - pidfile per display: several stacks can coexist (:0, :1, ...).
set -u

DISPLAY_NUM="${DISPLAY_NUM:-0}"
RES="${RES:-1920x1080}"
VNC_PORT="${VNC_PORT:-$((5900+DISPLAY_NUM))}"
VNC_PASS="${VNC_PASS:-sandboxgui}"
VNC_PASSWD_FILE="$HOME/.vnc/passwd"
LOGDIR="/tmp/bring-my-gui"; mkdir -p "$LOGDIR"
PIDFILE="$LOGDIR/stack-$DISPLAY_NUM.pids"
WD_PIDFILE="$LOGDIR/watchdog-$DISPLAY_NUM.pid"
export DISPLAY=":$DISPLAY_NUM"
unset WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS

pid_get() {  # $1 = label -> pid or empty
  [ -f "$PIDFILE" ] && awk -v l="$1" '$1==l && $2!=""{print $2}' "$PIDFILE"
}

stack_ok() {  # Xvfb AND x11vnc of THIS display alive (pidfile, fallback pgrep)
  local xv vnc
  xv=$(pid_get XVFB); vnc=$(pid_get X11VNC)
  { [ -n "$xv" ] && kill -0 "$xv" 2>/dev/null && [ -n "$vnc" ] && kill -0 "$vnc" 2>/dev/null; } && return 0
  pgrep -f "Xvfb :$DISPLAY_NUM( |\$)" >/dev/null \
    && pgrep -f "x11vnc .*display :$DISPLAY_NUM( |\$)" >/dev/null
}

ensure_x11_unix() {
  [ -d /tmp/.X11-unix ] || mkdir -p /tmp/.X11-unix
  chmod 1777 /tmp/.X11-unix 2>/dev/null || true
}

start_stack() {  # assumes this display's stack is down
  ensure_x11_unix
  [ -f "$VNC_PASSWD_FILE" ] && VNC_PASSWD_SET=1 || VNC_PASSWD_SET=0
  : >"$PIDFILE"
  Xvfb "$DISPLAY" -screen 0 "${RES}x24" -ac +extension RANDR +render -noreset \
    &>"$LOGDIR/xvfb-$DISPLAY_NUM.log" &
  echo "XVFB $!" >>"$PIDFILE"
  sleep 2
  setxkbmap -layout us -model pc105 2>/dev/null || true
  # deterministic Cyrillic mapping on reserved keycodes (stage-3, gotchas).
  # Keysyms MUST be Unicode-range 0x01000000|code (clients send "U0435" =
  # 0x1000435); bare 0x0435 is a different, unmatched keysym.
  if command -v python3 >/dev/null && command -v xmodmap >/dev/null; then
    python3 - <<'PYEOF'
kcs=[191,192,193,194,195,196,197,198,199,200,201,202,212,213,214,215,
     216,217,218,219,220,221,222,223,225,226,227,249,250,251,252,253,254]
alpha="абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
open('/tmp/cyr.xmodmap','w').write("\n".join(
    f"keycode {kc} = 0x{0x1000000|ord(c):07x} 0x{0x1000000|ord(c.upper()):07x}"
    for kc,c in zip(kcs,alpha))+"\n")
PYEOF
    xmodmap /tmp/cyr.xmodmap 2>/dev/null || true
  else
    echo "WARN: python3/xmodmap absent — Cyrillic pre-load skipped (non-Latin input may degrade)" >&2
  fi
  openbox &>/dev/null & echo "OPENBOX $!" >>"$PIDFILE"
  if command -v autocutsel >/dev/null; then
    autocutsel -fork -selection CLIPBOARD &>/dev/null & echo "CUTSEL_C $!" >>"$PIDFILE"
    autocutsel -fork -selection PRIMARY   &>/dev/null & echo "CUTSEL_P $!" >>"$PIDFILE"
  fi
  [ -f "$VNC_PASSWD_FILE" ] || x11vnc -storepasswd "$VNC_PASS" "$VNC_PASSWD_FILE" >/dev/null
  x11vnc -display "$DISPLAY" -forever -shared -rfbauth "$VNC_PASSWD_FILE" \
    -listen 0.0.0.0 -rfbport "$VNC_PORT" -threads -defer 2 -wait 5 \
    -xkb -add_keysyms -skip_keycodes 184 -nowireframe -xdamage -xdamage \
    -speeds 10000,1000,1 &>"$LOGDIR/x11vnc-$DISPLAY_NUM.log" &
  echo "X11VNC $!" >>"$PIDFILE"
  sleep 1
}

stop_watchdog() {
  [ -f "$WD_PIDFILE" ] && { kill "$(cat "$WD_PIDFILE")" 2>/dev/null; rm -f "$WD_PIDFILE"; }
}

kill_stack() {  # only THIS display's processes (pidfile; stragglers; legacy -x)
  stop_watchdog
  if [ -s "$PIDFILE" ]; then
    awk '$2!=""{print $2}' "$PIDFILE" | while read -r p; do kill "$p" 2>/dev/null; done
    rm -f "$PIDFILE"
  else
    pkill -x autocutsel 2>/dev/null; pkill -x openbox 2>/dev/null
    pkill -x x11vnc 2>/dev/null;    pkill -x Xvfb 2>/dev/null
  fi
  # stragglers: a crashed run's watchdog can restart the stack AFTER a newer
  # run overwrote the pidfile, leaving untracked processes on this display.
  # Display-scoped -f is safe here: this script's own cmdline never contains
  # "Xvfb :N" / "x11vnc ... :N".
  pkill -f "Xvfb :$DISPLAY_NUM( |\$)" 2>/dev/null
  pkill -f "x11vnc .*display :$DISPLAY_NUM( |\$)" 2>/dev/null
  sleep 1
}

cmd_start() {
  if stack_ok; then
    echo "stack already running on $DISPLAY (port $VNC_PORT)"; return 0
  fi
  start_stack
  stack_ok || { echo "FATAL: stack failed — see $LOGDIR/xvfb-$DISPLAY_NUM.log $LOGDIR/x11vnc-$DISPLAY_NUM.log" >&2; return 1; }
  echo "stack up: display $DISPLAY, res $RES"
  echo "VNC ready: port $VNC_PORT, password: $( [ "${VNC_PASSWD_SET:-0}" = 1 ] && echo '(stored in ~/.vnc/passwd)' || echo "$VNC_PASS" )"
  echo "connect from host: vnc://localhost:$VNC_PORT   (macOS: Finder -> Cmd+K)"
  if [ "${WATCHDOG:-0}" = 1 ] && { [ ! -f "$WD_PIDFILE" ] || ! kill -0 "$(cat "$WD_PIDFILE" 2>/dev/null)" 2>/dev/null; }; then
    ( while true; do
        sleep 10
        stack_ok || { echo "[$(date)] display $DISPLAY stack died, restarting" >>"$LOGDIR/watchdog.log"
                       kill_stack; start_stack; }
      done ) </dev/null >/dev/null 2>&1 & echo $! >"$WD_PIDFILE"
    echo "watchdog on (pid $(cat "$WD_PIDFILE"))"
  fi
  return 0
}

cmd_status() {
  local fail=0 p
  for l in XVFB X11VNC OPENBOX; do
    p=$(pid_get "$l")
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "$l OK (pid $p)"; else echo "$l DEAD"; [ "$l" != OPENBOX ] && fail=1; fi
  done
  if (exec 3<>/dev/tcp/127.0.0.1/"$VNC_PORT") 2>/dev/null; then
    echo "port $VNC_PORT open"; exec 3>&- 3<&-
  else echo "port $VNC_PORT CLOSED"; fail=1; fi
  [ -f "$WD_PIDFILE" ] && kill -0 "$(cat "$WD_PIDFILE")" 2>/dev/null \
    && echo "watchdog OK" || echo "watchdog off"
  xwininfo -root -tree 2>/dev/null | sed -n '1,8p'
  return $fail
}

case "${1:-}" in
  start)   cmd_start ;;
  stop)    kill_stack; echo "stack down ($DISPLAY)" ;;
  restart) kill_stack; cmd_start ;;
  status)  cmd_status ;;
  *) echo "usage: $0 start|stop|restart|status   (env: DISPLAY_NUM RES VNC_PORT VNC_PASS WATCHDOG)" >&2; exit 2 ;;
esac
