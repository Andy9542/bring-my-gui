---
name: bring-my-gui
description: Forward any GUI application from a headless local sandbox (docker container, agent sbx) to the user's host screen over VNC — works with macOS, Windows, or Linux hosts. Use whenever the user wants to run, see, or interact with a graphical app inside a sandbox — Electron/Chromium apps, browsers, IDEs, Qt/GTK tools, installers, wizards — or when a GUI app fails with "cannot open display" / "cannot connect to X server". Trigger on phrases like "пробросить GUI из докера", "открыть приложение из песочницы на хосте", "запустить GUI в контейнере", "show the app window on my machine", "headless browser with visible display", "VNC into the sandbox", "демо GUI приложения в контейнере", "bring my gui", even if VNC is not explicitly mentioned. Covers the full stack (Xvfb + x11vnc + window manager + clipboard bridge), HiDPI/retina scaling, non-Latin keyboard input, latency tuning, port publishing how-to (docker -p / sbx ports), and per-OS client quirks. Also covers browser logins from a browserless sandbox (OAuth in Cursor, Claude Code, gh, gcloud): trigger on "залогиниться в приложении внутри контейнера", "войти в аккаунт из песочницы", "sign in inside the container", "OAuth in docker without a browser", "app wants to open a browser but there is none". Local use only — not for exposing GUI over a network.
---

# Bring My GUI — forward a sandbox app to the user's screen

Run a graphical app inside a headless local Linux sandbox and show it on the
user's host machine via VNC. Battle-tested path:
**Xvfb (virtual display) + openbox (WM) + autocutsel (clipboard) + x11vnc (VNC)**.
Host-side, only a VNC client is needed — every desktop OS has one.

The agent's job in three moves: install, start the stack, launch the app with
the right toolkit flags. Then give the user the connect line for THEIR OS.

## Before you build — ask once, in one batch

Four answers change the setup; asking them all up front avoids rebuilds.
Skip any that context already answers, don't interrogate:

1. **Which app exactly?** Always ask unless the user named it. Get the exact
   name/binary and — if it's not in the sandbox yet — where to get it: distro
   package, or a download link from the user (.deb / AppImage / tarball).
2. **Host OS + screen?** (macOS retina 14"/16", Windows HiDPI laptop, 1080p
   external monitor…) → sets `RES`, scale factor, and the connect instructions.
   This is what makes the picture look "native" on the first connect — without
   it you get blurry or tiny UI on the first try and iterate with the user
   staring at a degraded screen.
3. **Can the sandbox publish a port?** → if already running and immutable,
   see gotchas § No published port. To publish: `docker run -p 5900:5900 …`
   (or compose `ports: ["5900:5900"]`); for docker-sbx sandboxes:
   `sbx ports <sandbox_name> --publish 5900:5900` — hand the exact command to
   the user, they run it on the host.
4. **Typing non-Latin text or heavy copy-paste?** → both are covered by the
   stack defaults, but worth verifying in the checklist (keyboard fix and
   clipboard bridge are the first things users report).

Scope: local host↔sandbox only. Remote/wan exposure of VNC is out of scope
and unsafe (gotchas § Security has the tunneling story if it ever comes up).

## App acquisition — check before anything else

The app must exist in the sandbox before there is anything to forward:

```bash
command -v <app> || ls /opt /usr/local 2>/dev/null | grep -i <app>
```

- **Found** → note the binary path, detect the toolkit (table below).
- **Not found** → ask the user ONCE: "install from distro repos, or do you
  have a link?" Then:
  - distro: search the repo for the **binary or app name**, not a package
    name remembered from another distro (`apt-cache search` / `dnf search` /
    `apk search`) → install the hit → confirm with `command -v`.
  - `.deb` link: `curl -fL -o /tmp/app.deb <url> && sudo apt install -y /tmp/app.deb`
    (resolves deps). If it then fails on a missing `.so`, that is a library
    gap — same rule as after any install, below.
  - AppImage link: `curl -fL -o ~/app.AppImage <url> && chmod +x ~/app.AppImage`
    — if it complains about FUSE: install whatever package provides the FUSE
    library, or run with `--appimage-extract-and-run`.
  - tarball: unpack to `~/apps/`, find the launcher binary, `ldd` it for
    missing libs before launching.
- After any install, sanity-check with `ldd` on the ACTUAL binary path
  (`command -v <app>` for packaged apps; the AppImage/tarball launcher you
  just downloaded — it won't be on PATH): `ldd <binary> | grep "not found"`
  → search the distro for each missing `.so` and install; don't copy a
  Debian package name onto Fedora/Alpine.

## Install by binary, not by package name

The stack is a set of **programs**, not a set of distro package names.
Those names split and rename across families and even across releases of
the same family — copying last sandbox's `apt install` line into this one
is how installs fail. `scripts/setup.sh` implements the recipe below; if
it cannot run (no bash, no package manager you recognize), do it by hand.

Required on PATH before `gui-stack.sh start`:

| Binary | Role |
|---|---|
| `Xvfb` | virtual display |
| `x11vnc` | VNC server |
| `openbox` | window manager (Java/GTK dialogs won't map without one) |
| `setxkbmap` | US layout; see gotchas § Non-Latin keys |
| `xwininfo` | verify the app window actually mapped |

Worth having; warn and continue if the repo has no provider:

| Binary | Role |
|---|---|
| `autocutsel` | CLIPBOARD↔PRIMARY bridge |
| `xmodmap` + `python3` | deterministic Cyrillic keysyms (gotchas § Non-Latin keys) |
| `xclip` / `xdotool` | extras the agent may use while debugging |
| `pgrep` | `gui-stack.sh` health fallback when the pidfile is stale |

Doing it by hand: ask for everything in ONE transaction first (dnf/yum take
file paths: `dnf install -y --skip-unavailable /usr/bin/Xvfb /usr/bin/x11vnc …`;
apt/apk take the lowercased names that exist), then resolve the leftovers one
by one. Eleven separate transactions cost minutes on a cold image.

Recipe for each missing binary — stop when `command -v` succeeds:

1. Skip if it's already on PATH.
2. If the manager can install **by file path**, do that: `dnf install /usr/bin/<Binary>` (yum too). On apt, the equivalent is "which package owns this file" (`apt-file search /usr/bin/<Binary>` — get `apt-file` with the same recipe if it's missing). This is the whole point — you never need the package's current name.
3. Try a package named like the binary, lowercased (`Xvfb` → `xvfb`). Often enough on apt and apk.
4. Otherwise **search the file**, not the description: description search ranks a GUI that *mentions* `xmodmap` above the package that ships `/usr/bin/xmodmap`. `apk search <Binary>`, `dnf provides /usr/bin/<Binary>`. Treat the name in the output as disposable — don't paste it into the next sandbox.
5. Re-check `command -v`. Still missing → FATAL for the required table, WARN for the optional table.

The scripts are bash. Minimal images (Alpine, distroless-ish) often have only `sh`: install whatever provides `bash` with the same recipe, then re-run `setup.sh`. Don't rewrite the stack in POSIX sh to dodge that.

## Quick start

All paths below are relative to this skill's directory.

```bash
# 1. Install stack (idempotent; resolves packages from binaries, any
#    apt/dnf/yum/apk distro). Needs bash — see § Install by binary.
bash scripts/setup.sh

# 2. Start display+VNC. Script defaults: RES=1920x1080, VNC_PORT=5900+DISPLAY_NUM,
#    VNC_PASS=sandboxgui. Override at least RES to match the user's screen
#    (2x their logical resolution, see § Choosing resolution).
RES=3024x1964 VNC_PASS=pick-a-pass bash scripts/gui-stack.sh start

# 3. Launch the app on the virtual display (survives the agent session).
#    The -u vars are mandatory: sandboxes export WAYLAND_DISPLAY and GTK/Qt
#    apps will try the Wayland backend and die. GDK_BACKEND/QT_QPA_PLATFORM
#    are belt-and-suspenders for apps with a hardcoded wayland preference.
nohup setsid env -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS \
  GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb DISPLAY=:0 \
  <APP COMMAND> </dev/null >/tmp/app.log 2>&1 & disown

# 4. Verify the window actually mapped
DISPLAY=:0 xwininfo -root -tree | grep -i <appname>

# 5. Only if the app then demands a login (most do): § Browser login (OAuth)
```

Then give the user the connect line **for their OS**:

| Host OS | Connect | Notes |
|---|---|---|
| macOS | Finder → ⌘K → `vnc://localhost:5900` (built-in Screen Sharing) | Clipboard syncs only while its window is focused; after host sleep, reconnect if input freezes |
| Windows | Install [TightVNC Viewer](https://www.tightvnc.com/download.php) or TigerVNC Viewer → connect `localhost:5900` | No built-in client; clipboard works natively in both |
| Linux | `remmina` (most distros) or `vncviewer localhost:5900` | Remmina often preinstalled; TigerVNC client = best perf |

In the session paste with **Ctrl+V** (obvious for Windows/Linux hosts; Mac
users: Cmd-V does not reach the sandbox — the session is Linux X11).

## Manual stack — when the scripts can't run

Containers vary wildly: no bash (busybox/POSIX sh only), read-only skill dir,
no sudo wrapper, stripped coreutils. If either script errors out or its
binaries are missing, don't debug the script — get the binaries onto PATH
(§ Install by binary), then run the same sequence by hand:

```bash
# deps: packages that provide Xvfb x11vnc openbox setxkbmap xwininfo
# (optional: autocutsel xmodmap xclip python3). Search, don't copy names
# from another distro. Then:
unset WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS
[ -d /tmp/.X11-unix ] || { mkdir -p /tmp/.X11-unix; chmod 1777 /tmp/.X11-unix; }
Xvfb :0 -screen 0 "${RES:-1920x1080}x24" -ac +extension RANDR -noreset & sleep 2
DISPLAY=:0 setxkbmap -layout us -model pc105
# Cyrillic pre-load onto reserved keycodes (deterministic; recipe explained
# in gotchas § Non-Latin keys, stage 3) — BEFORE x11vnc starts
python3 - <<'EOF'
kcs=[191,192,193,194,195,196,197,198,199,200,201,202,212,213,214,215,
     216,217,218,219,220,221,222,223,225,226,227,249,250,251,252,253,254]
alpha="абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
open('/tmp/cyr.xmodmap','w').write("\n".join(
    f"keycode {kc} = 0x{0x1000000|ord(c):07x} 0x{0x1000000|ord(c.upper()):07x}"
    for kc,c in zip(kcs,alpha))+"\n")
EOF
DISPLAY=:0 xmodmap /tmp/cyr.xmodmap
DISPLAY=:0 openbox & DISPLAY=:0 autocutsel -fork -selection CLIPBOARD &
DISPLAY=:0 autocutsel -fork -selection PRIMARY &
mkdir -p ~/.vnc && x11vnc -storepasswd "${VNC_PASS:-sandboxgui}" ~/.vnc/passwd
x11vnc -display :0 -forever -shared -rfbauth ~/.vnc/passwd -rfbport 5900 \
  -threads -defer 2 -wait 5 -xkb -add_keysyms -skip_keycodes 184 \
  -nowireframe -xdamage -xdamage -speeds 10000,1000,1 &
# then launch the app exactly as in Quick start step 3
```

The flags are not negotiable cargo cult — each prevents a live-debugged
failure (see references/gotchas.md). Keep them identical when hand-rolling.

## Port publishing — the user runs this on the host

The VNC port must reach the host before any client can connect. Give the user
the exact command for their sandbox type (they run it on the host, not you):

| Sandbox type | Command (host side) |
|---|---|
| docker sbx | `sbx ports <sandbox_name> --publish 5900:5900` |
| plain docker | recreate: `docker run -p 5900:5900 …` / compose `ports: ["5900:5900"]` |

If `5900` is already taken on the host, publish another one (`5901:5900`) and
have the client connect to the HOST port (left side of the pair).

## Browser login (OAuth) — the app wants a browser the sandbox lacks

You run **inside** the sandbox. The user's browser is on the host. Do not
install a browser in here (gotchas § In-sandbox browser).

Two kinds of app, two moves:

- **Desktop apps that launch a browser** (Cursor, other Electron, anything
  that calls `xdg-open` or `$BROWSER`). `gio open` is intercepted too, but
  through the default-browser desktop entry, not a `gio` alias. This is the
  case the bridge exists for. `install` intercepts the launch — including
  `/usr/bin/xdg-open` by absolute path, via that desktop entry. Then `watch`,
  paste the URL into the chat. Cursor polls for the token: once the user
  approves on the host, the app in here signs itself in.
- **CLIs that print a URL** (Claude Code). Hand that URL in the chat; the
  user pastes a code back if the TUI asks. Claude Code 2.1.238 *also* called
  the shim, with a loopback callback on a **random** port — you cannot
  publish that in advance from inside the container. The printed `code=true`
  URL is the path that works from in here.

```bash
bash scripts/oauth-bridge.sh install
bash scripts/oauth-bridge.sh watch 180 60
```

Trigger the login (click the app's button over VNC, or run its `login`
command). `watch` prints either a URL that just arrived or one from the last
60s. Give it to the user. Nothing is installed on the host.

`$BROWSER` from `profile.d` does not reach this already-running shell —
PATH `/usr/local/bin/xdg-open` does. `mimeapps.list` is written under this
user's `$HOME`; an app running as someone else will not see it (the PATH
shim still applies). `listen` on the host is opt-in and the user has to run
it; you cannot. Under `--network host` the auto-detected host is the LAN
router — pass `HOST_ADDR` if you ever use host-push.

**Before any of this:** a token env var (`ANTHROPIC_API_KEY`,
`CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` on the user's machine,
`GH_TOKEN`) beats a bridge.

What happens after "Approve" still depends on the app's last step:

- polls its API (Cursor) — wait, it signs itself in
- shows a code to paste (Claude Code TUI, device-code: gh, az) — user pastes
  into the app / your waiting prompt
- redirects to `http://localhost:PORT` **of this sandbox** — needs that port
  published with the same number both sides. Claude Code's browser path used
  a random port (45781 once), not 54545. From inside, prefer the paste-code
  URL
- redirects to `myapp://` — not bridgeable; the host's copy of the app
  swallows it

Deep links generated **inside** the sandbox are a different case and do work:
`oauth-bridge.sh handler cursor '/opt/cursor/AppRun --no-sandbox %U'`.

## Will the resolution be right on first connect?

Only if you asked the host/screen question (№2) and derived `RES` + scale
factor from it. The failure modes it prevents: blurry (`RES` = logical 1×),
tiny UI (`RES` = 2× without app scale factor). When the user's screen is
unknown and can't be asked, start at `RES=1920x1080`, scale
1× — safe on every OS, then offer the HiDPI upgrade once they can see
something.

## Choosing resolution and scale (the #1 quality decision)

VNC streams raw pixels, so match the user's screen instead of guessing:

1. Get the host's **logical** resolution from the answers (macOS 14" →
   1512×982, 16" → 1728×1117; Windows HiDPI at 150% on 1920×1080 panel →
   1280×720; plain 1080p → 1920×1080).
2. Set `RES` to **2× logical** (sharp AND normal-sized UI).
3. Tell the app to render at 2× via toolkit flag (table below). Screen pixels
   alone make everything tiny; logical resolution alone makes text blurry.

Toolkit launch flags (add to `<APP COMMAND>`):

| Toolkit | How to detect | Flags / env for launch | HiDPI |
|---|---|---|---|
| Electron/Chromium | crash mentions sandbox/SUID, or `grep -aiom1 'electron\|chrom' "$(command -v <app>)"` hits (strings are embedded in the binary — `ldd` will NOT show them) | `--no-sandbox --disable-gpu --disable-dev-shm-usage` | `--force-device-scale-factor=2` |
| Qt | `ldd ... \| grep libQt` | (nothing mandatory) | `QT_SCALE_FACTOR=2` |
| GTK3/4 | `ldd ... \| grep libgtk` | (nothing mandatory) | `GDK_SCALE=2` |
| Java/Swing | java process | needs a WM running (openbox in stack covers it) | `-Dsun.java2d.uiScale=2` |
| unknown | — | try plain launch first | none; fall back to RES=logical (1×) |

Compromise when the client lags on 2×: `RES=<1.5× logical>` and scale factor
1.5 (44% fewer pixels, still decent text).

## Script reference — scripts/gui-stack.sh

Subcommands: `start | stop | restart | status`. Env knobs:

- `DISPLAY_NUM` (default 0) — use `1` if `:0` is occupied by another stack
- `RES` (default `1920x1080` — neutral safe default; set it to 2× the user's
  logical resolution when you know it, see § resolution)
- `VNC_PORT` (default `5900+DISPLAY_NUM` — a second stack gets 5901 for free)
- `VNC_PASS` (default `sandboxgui`; stored once in `~/.vnc/passwd`, later
  starts reuse the file — the start output tells you which password is
  actually active)
- `WATCHDOG=1` — auto-restart stack if it dies (for long-lived sandboxes)

Multiple stacks coexist (one per `DISPLAY_NUM`); the script tracks per-display
pids, so stopping `:1` never touches `:0`.

`status` verifies processes, the listening port, and prints mapped windows.
Use it after every `start` — a silently dead x11vnc means the user stares at a
connection-refused dialog.

## Verify checklist (run all before telling the user "ready")

Use the SAME env as your start command (`DISPLAY_NUM`, `VNC_PORT`) — checking
display `:0` when the stack is on `:1` reports a healthy stack as dead.

```bash
# N=$DISPLAY_NUM of your start command
bash scripts/gui-stack.sh status                       # stack + port (pass env!)
DISPLAY=:N xwininfo -root -tree | head -20             # app window mapped, size sane
DISPLAY=:N pgrep -x autocutsel >/dev/null && echo "clipboard bridge up"   # bridge alive
tail -5 /tmp/app.log                                    # no crash loop
```

The clipboard bridge check only proves the in-sandbox CLIPBOARD↔PRIMARY
bridge is alive; the client↔sandbox half can only be tested by the user
(copy on host → Ctrl+V in the session). Say so when handing over.

Changing `RES` requires a full cycle: `stop` (the app dies with its X
connection — that's expected) → `start` with new `RES` → relaunch the app
with the new scale factor.

If the window is 10×10 or missing, the app died or needs flags — read
`/tmp/app.log`, check the toolkit table, iterate. Do not hand the user a
blank screen.

## When something breaks

Symptoms → fixes in references/gotchas.md. The hits that cover ~90%:

- x11vnc exits instantly → `WAYLAND_DISPLAY` set in sandbox (§ x11vnc)
- Non-Latin keys drop, some letters only, worsens over time → keyboard
  ladder in gotchas § Non-Latin keys; the script already applies stage 3
  (xmodmap pre-load). Never "fix" with `us,ru` and distrust `-add_keysyms`
  alone — it drifts and kills individual letters
- ALL input dead, log floods "waiting until all keys are up" → stuck key:
  `x11vnc -R clear_all -display :N`, then see § x11vnc
- Frame constantly repaints/flickers → two causes: XDamage self-disabled
  (fix: `-xdamage` twice) vs client reconnect loop (client-side) (§ x11vnc)
- Works, then input desyncs after host idle/sleep → host-client quirk,
  reconnect the session (§ per-OS)
- Laggy scroll on HiDPI → resolution/scale compromise (§ Latency)
- Electron `.deb` installs but won't start → `ldd` the binary, missing `.so`
  is a repo search (gotchas § App deps), not a Debian package name to copy
- User on Windows/Linux can't connect → client table above, firewall on host
  (§ Connectivity)
- App's login button does nothing / "no browser found" → § Browser login;
  if the URL never reaches the log, gotchas § Browser login

Read references/gotchas.md before improvising — most traps there were hit
live and cost debugging time.

## Sandbox hygiene

- Kill processes with `pkill -x <name>`, never `pkill -f <pattern>` — the
  pattern matches your own shell's command line and kills your session.
- The stack scripts log to `/tmp/bring-my-gui/`. App log: wherever step 3 put it.
- `stop` tears down the stack and (via the dying X server) the app too.
- Security: the VNC password is a convenience lock, not security. Localhost +
  published port = fine. Anything routable from beyond the user's machine =
  tunnel it (gotchas § Security).
