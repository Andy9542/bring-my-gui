#!/bin/bash
# Run the CI job locally: the same images, the same steps, in Docker.
# This is a mirror of .github/workflows/stack.yml — when a step changes
# there, change it here, the step names match on purpose.
#
#   tests/ci-local.sh                         # the four CI images, in parallel
#   tests/ci-local.sh ubuntu:24.04 alpine:3.21
#   KEEP=1 tests/ci-local.sh fedora:41        # leave a failed container up
#
# Why a mirror instead of "just run the suite": CI differs from a laptop in
# two ways that have already produced a green-here-red-there:
#  - GitHub's ubuntu runners run with fs.protected_regular=2 (Ubuntu's
#    default). Dev boxes, sandboxes and Docker Desktop VMs mostly have 0, and
#    the bridge suite passed locally while CI was red for exactly that. This
#    script sets 2 for the duration — sudo on a Linux host, nsenter into the
#    Docker Desktop VM otherwise — and puts the old value back on exit.
#    PROTECTED_REGULAR=skip leaves the kernel alone.
#  - CI is amd64; Apple silicon runs the arm64 images. Same scripts, not
#    always the same package contents — a green run here is a strong hint,
#    CI is the word.
#
# Env: KEEP=1 (keep failed containers), PROTECTED_REGULAR=skip,
#      LOGDIR=<dir> (default: a fresh mktemp dir), RES, VNC_PASS.
# Exit 0 only when every image passed. Needs bash (3.2 is enough) and docker.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SKILL=/repo/skills/bring-my-gui
RES="${RES:-1280x800}"
VNC_PASS="${VNC_PASS:-ci-demo}"
LOGDIR="${LOGDIR:-$(mktemp -d "${TMPDIR:-/tmp}/bmg-ci.XXXXXX")}"
KEEP="${KEEP:-}"
DEFAULT_IMAGES="ubuntu:24.04 debian:bookworm-slim fedora:41 alpine:3.21"
[ $# -gt 0 ] && IMAGES="$*" || IMAGES="$DEFAULT_IMAGES"

command -v docker >/dev/null 2>&1 || { echo "docker is needed" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "docker daemon not reachable" >&2; exit 2; }
mkdir -p "$LOGDIR"

# ------------------------------------------------- fs.protected_regular ---
# Read/write the sysctl of the kernel that runs the containers. On a Linux
# host that is this kernel; under Docker Desktop it is the VM's, reachable
# through a privileged container in the VM's pid namespace.
PR_HOW=""      # sudo | vm | "" (not touched)
PR_OLD=""
pr_read() {
  case "$PR_HOW" in
    sudo) cat /proc/sys/fs/protected_regular 2>/dev/null ;;
    vm)   docker run --rm --privileged --pid=host alpine:3.21 \
            nsenter -t 1 -m -p -- cat /proc/sys/fs/protected_regular 2>/dev/null ;;
  esac
}
pr_write() {  # $1 = value
  case "$PR_HOW" in
    sudo) sudo -n sysctl -q -w "fs.protected_regular=$1" >/dev/null 2>&1 ;;
    vm)   docker run --rm --privileged --pid=host alpine:3.21 \
            nsenter -t 1 -m -p -- sysctl -q -w "fs.protected_regular=$1" >/dev/null 2>&1 ;;
  esac
}
pr_setup() {
  [ "${PROTECTED_REGULAR:-}" = skip ] && { echo "fs.protected_regular: left alone (PROTECTED_REGULAR=skip)"; return; }
  if [ "$(uname -s)" = Linux ] && [ -r /proc/sys/fs/protected_regular ] && sudo -n true 2>/dev/null; then
    PR_HOW=sudo
  elif docker run --rm --privileged --pid=host alpine:3.21 nsenter -t 1 -m -p -- true >/dev/null 2>&1; then
    PR_HOW=vm
  else
    echo "fs.protected_regular: cannot reach the container kernel's sysctl (no passwordless sudo, no privileged docker)." >&2
    echo "  The non-root cases of the bridge suite run softer than on CI. PROTECTED_REGULAR=skip silences this." >&2
    return
  fi
  PR_OLD=$(pr_read)
  case "$PR_OLD" in ''|*[!0-9]*) echo "fs.protected_regular: unreadable, left alone" >&2; PR_HOW=""; PR_OLD=""; return ;; esac
  if [ "$PR_OLD" -ge 1 ]; then
    echo "fs.protected_regular=$PR_OLD already (as on CI)"; PR_OLD=""
  elif pr_write 2; then
    echo "fs.protected_regular: 0 -> 2 for this run (via $PR_HOW), restored on exit"
  else
    echo "fs.protected_regular: could not set 2 via $PR_HOW, left at $PR_OLD" >&2; PR_OLD=""
  fi
}
pr_restore() {
  [ -n "$PR_OLD" ] || return 0
  pr_write "$PR_OLD" && echo "fs.protected_regular: back to $PR_OLD" || echo "WARN: could not restore fs.protected_regular=$PR_OLD" >&2
}
trap pr_restore EXIT

# ---------------------------------------------------------------- one image ---
# Mirrors the job's steps in order. Runs in the background per image; stdout
# goes to $LOGDIR/<tag>.log, the outcome to $LOGDIR/<tag>.rc.
run_image() {  # $1 = image
  local image=$1 tag c port banner failed=""
  tag=$(printf '%s' "$image" | tr ':/' '--')
  c="bmg-ci-$tag-$$"
  step() {  # $1 = name, rest = command; stops the image on the first failure
    [ -n "$failed" ] && return 0
    echo; echo "##### [$image] $1"
    if "${@:2}"; then return 0; fi
    failed=$1
    echo "##### [$image] FAILED: $1"
    docker exec "$c" sh -c 'tail -n 40 /tmp/bring-my-gui/*.log' 2>/dev/null || true
    return 0
  }
  docker rm -f "$c" >/dev/null 2>&1 || true

  step "Start $image with the VNC port published" \
    docker run -d --name "$c" -p 127.0.0.1::5900 -v "$REPO:/repo:ro" "$image" sleep 1200
  port=$(docker port "$c" 5900/tcp 2>/dev/null | head -1 | sed 's/.*://')

  step "Bootstrap bash (minimal images ship only sh)" \
    docker exec "$c" sh -c '
      command -v bash >/dev/null && exit 0
      command -v apk >/dev/null && exec apk add --no-cache bash
      command -v apt-get >/dev/null && { apt-get update -qq && exec apt-get install -y -qq bash; }
      exit 1'

  step "setup.sh resolves every binary from the local package index" \
    docker exec "$c" bash "$SKILL/scripts/setup.sh"

  step "Required binaries are on PATH" \
    docker exec "$c" sh -c '
      for b in Xvfb x11vnc openbox setxkbmap xwininfo; do
        command -v $b >/dev/null || { echo "missing: $b"; exit 1; }
      done'

  step "gui-stack.sh start" \
    docker exec -e "RES=$RES" -e "VNC_PASS=$VNC_PASS" "$c" bash "$SKILL/scripts/gui-stack.sh" start

  step "gui-stack.sh status" \
    docker exec "$c" bash "$SKILL/scripts/gui-stack.sh" status

  step "VNC auth file was written (fresh images have no ~/.vnc)" \
    docker exec "$c" sh -c 'test -s "$HOME/.vnc/passwd"'

  step "Xvfb runs at the requested geometry" \
    docker exec -e "RES=$RES" "$c" sh -c 'DISPLAY=:0 xwininfo -root | grep -q "geometry ${RES}+0+0"'

  step "Cyrillic keysyms are pre-loaded on reserved keycodes" \
    docker exec "$c" sh -c 'DISPLAY=:0 xmodmap -pk | grep -q "0x1000430 (U0430)"'

  rfb_handshake() {
    [ -n "$port" ] || { echo "no published port"; return 1; }
    if command -v timeout >/dev/null 2>&1; then
      banner=$(timeout 10 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; head -c 12 <&3" 2>/dev/null)
    else
      banner=$(bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; head -c 12 <&3" 2>/dev/null)
    fi
    echo "server greeting on 127.0.0.1:$port: $banner"
    case "$banner" in RFB*) return 0 ;; *) echo "no RFB banner on the published port"; return 1 ;; esac
  }
  step "A host-side client reaches it — RFB handshake on the published port" rfb_handshake

  step "A GUI app actually maps a window" \
    docker exec "$c" sh -c '
      command -v xclock >/dev/null ||
        { command -v dnf     >/dev/null && dnf install -y -q /usr/bin/xclock; } ||
        { command -v yum     >/dev/null && yum install -y -q /usr/bin/xclock; } ||
        { command -v apt-get >/dev/null && apt-get install -y -qq x11-apps; } ||
        { command -v apk     >/dev/null && apk add --no-cache xclock; }
      command -v xclock >/dev/null || { echo "could not install an xclock binary"; exit 1; }
      nohup env DISPLAY=:0 xclock -update 1 -geometry 700x700+160+50 </dev/null >/dev/null 2>&1 &
      sleep 4
      DISPLAY=:0 xwininfo -root -tree | grep -i xclock'

  step "OAuth bridge behaviour suite" \
    docker exec "$c" bash /repo/tests/oauth-bridge.sh

  if [ -n "$failed" ] && [ -n "$KEEP" ]; then
    echo "##### [$image] kept for inspection: docker exec -it $c bash   (docker rm -f $c when done)"
  else
    docker rm -f "$c" >/dev/null 2>&1 || true
  fi
  if [ -n "$failed" ]; then echo "FAIL	$image	$failed"; else echo "PASS	$image"; fi
}

# --------------------------------------------------------------------- run ---
pr_setup
echo "images: $IMAGES"
echo "logs:   $LOGDIR"
started=$(date +%s)
pids=""
for image in $IMAGES; do
  tag=$(printf '%s' "$image" | tr ':/' '--')
  run_image "$image" >"$LOGDIR/$tag.log" 2>&1 &
  pids="$pids $!"
done
# shellcheck disable=SC2086
wait $pids

echo
echo "=== results ($(( $(date +%s) - started ))s)"
rc=0
for image in $IMAGES; do
  tag=$(printf '%s' "$image" | tr ':/' '--')
  line=$(grep -E '^(PASS|FAIL)	' "$LOGDIR/$tag.log" | tail -1)
  case "$line" in
    PASS*) printf '  ok    %-24s %s\n' "$image" "$LOGDIR/$tag.log" ;;
    FAIL*) rc=1; printf '  FAIL  %-24s at: %s\n        %s\n' "$image" "${line#*	*	}" "$LOGDIR/$tag.log"
           grep -E '^(FAIL|FATAL) ' "$LOGDIR/$tag.log" | head -8 | sed 's/^/        /' ;;
    *)     rc=1; printf '  ???   %-24s no verdict — see %s\n' "$image" "$LOGDIR/$tag.log" ;;
  esac
done
exit $rc
