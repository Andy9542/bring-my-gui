# bring-my-gui — Gotchas & Fixes

Live-debugged traps, ordered by how often they bite. Symptom → cause → fix.

## First-run surprises

**Connected — blank/gray screen with an X cursor**
The stack is fine: that's the openbox desktop with no app mapped. The app
either wasn't launched, died instantly (read its log), or was launched on a
different display than the stack (`DISPLAY=:1` app on `:0` stack — check with
`xwininfo -root -tree -display :N`). Fix the launch, don't touch the stack.

**Video plays but no sound**
VNC carries pixels and input only — no audio, by protocol. Browsers/media
players "work but are silent" and that will not change with flags. If audio
matters, it needs a separate path (PulseAudio-over-network etc.) — out of
scope for this skill; tell the user up front rather than debugging it.

## x11vnc

**Exits instantly, log says "Wayland sessions are not supported"**
Sandbox images export `WAYLAND_DISPLAY`; x11vnc misdetects the session type.
Fix (already in script): `unset WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS`
before start.

**Server dies after adding `-encodings ...`**
`-encodings` is passed to libvncserver but is not valid there; server exits
with a misleading wall of "renamed: -mouse, use -cursor" lines. Fix: never
pass `-encodings`; encoding is negotiated with the client automatically.

**Non-Latin keys (Cyrillic etc.) — three escalating stages**

Stage 0 — baseline: Xvfb default layout is `us`, a Cyrillic keysym has no
keycode, x11vnc drops the press.

Stage 1 (wrong fix, verified live): `setxkbmap -layout us,ru` → enables
x11vnc group-switching, which desyncs after a while; letters drop again.

Stage 2 (fragile): `-xkb -add_keysyms` — x11vnc dynamically binds each new
keysym to a keycode it picks. Works initially, then breaks non-deterministic­ly:
it overwrites shift-levels of occupied keycodes, its cache drifts from the
real keymap, and individual letters die (observed: it even bound a letter to
a keycode excluded via `-skip_keycodes`). Also the related stuck-key trap:
a lost key-release (client reconnect) leaves x11vnc blocked — log floods
`active keyboard: waiting until all keys are up, key_down=N`; one-shot cure
`x11vnc -R clear_all -display :N`, preventive `-skip_keycodes 184` for the
nosymbol code macOS clients emit.

Stage 3 (working, current): **pre-load the whole alphabet onto reserved
keycodes via xmodmap before starting x11vnc** — deterministic mapping,
nothing dynamic left to drift. Recipe: keep `setxkbmap -layout us`, then map
each letter (lower+upper) to a free multimedia keycode (191–202, 212–223,
225–227, 249–254 — XF86*/F13+ range nobody presses over VNC; verify with
`xmodmap -pk` that a keycode is free or harmless before overwriting).

**The keysym-range trap (cost a full debugging round):** clients send
Unicode-range keysyms — Cyrillic "е" arrives as `0x01000435` (x11vnc logs it
as `0x1000435 "U0435"`). Writing `keycode N = 0x0435 …` in xmodmap creates a
DIFFERENT, unmatched keysym — x11vnc won't find it, silently falls back to
the drifting allocator (stage 2), and you'll wrongly conclude the pre-load
"works" if you verify by grepping your own wrong pattern. Always write
`0x01000000 | unicode`. Symptom that betrays the wrong range: entries show
`(no name)` in `xmodmap -pk` output while x11vnc's log keeps printing
`added missing keysym … 0x100xxxx`.

```bash
python3 - <<'EOF'
kcs=[191,192,193,194,195,196,197,198,199,200,201,202,212,213,214,215,
     216,217,218,219,220,221,222,223,225,226,227,249,250,251,252,253,254]
alpha="абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
open('/tmp/cyr.xmodmap','w').write("\n".join(
    f"keycode {kc} = 0x{0x1000000|ord(c):07x} 0x{0x1000000|ord(c.upper()):07x}"
    for kc,c in zip(kcs,alpha))+"\n")
EOF
DISPLAY=:0 xmodmap /tmp/cyr.xmodmap
```

Applied live (no restart needed) — typing works immediately. If even stage 3
fails: switch transport to a TigerVNC server (`Xvnc`), different keyboard
path entirely.

**Keys drop intermittently + log floods "active keyboard: waiting until all keys are up. key_down=N"**
A stuck key: the client's key-release was lost during a reconnect, x11vnc now
believes a key is held and blocks ALL key injection until released. The
keycode is often `184` ("nosymbol" — a media/macro code macOS sends).
One-shot fix (from x11vnc's own log): `x11vnc -R clear_all -display :N`.
Preventive: `-skip_keycodes 184`; `-nowireframe` trims redraw churn. Shift_L
sticks the same way — same `clear_all` cures it. BUT if letters keep dying
with NO stuck-key messages in the log, you are at stage 2 of the keyboard
ladder above — the dynamic keysym allocator itself is the problem.

**Frame visibly redraws / flickers every few seconds**
Two distinct causes, check the log:
- `XDAMAGE is not working well... misses N/N` followed by `turning it off` —
  Electron-style renderers trip x11vnc's damage sanity check; x11vnc silently
  degrades to full-screen polling = constant repaint. Fix: pass `-xdamage`
  TWICE (documented: double flag = keep damage despite misses).
- Client reconnect loop (`Client … gone` lines seconds apart): every
  reconnect = full framebuffer resend (huge at 2× res) + visible repaint.
  Cause is client-side — macOS Screen Sharing drops under retina-sized
  streams. Fixes: TigerVNC client, or drop to 1.5× resolution.

**Input freezes after host idle/sleep (macOS Screen Sharing)**
Client-side modifier desync. Fix: reconnect the VNC session; or use TigerVNC
client.

## X server

**`_XSERVTransmkdir: ERROR: euid != 0` and x11vnc can't find the display**
`/tmp/.X11-unix` missing or wrong perms. Fix (in script): create it, `chmod 1777`.

**App window is 10×10 or unresponsive**
No window manager. Some apps (Java/Swing, some GTK dialogs) refuse to map or
size properly without one. The stack runs openbox for this reason.

## Latency

Tuning already baked into the script: XDamage on (delta regions, biggest win),
`-threads`, `-defer 2 -wait 5`, `-speeds 10000,1000,1` (LAN hint → light
compression). If still laggy when scrolling at 2× resolution:
- drop to 1.5× logical `RES` + scale factor 1.5 (−44% pixels, still sharp)
- or have the user switch to the TigerVNC client (better ZRLE decode than
  macOS Screen Sharing)

## Application

**Installed app won't start: `ldd` shows `not found`**
Packaged Electron/Qt builds often assume desktop libraries the sandbox
never had. Don't reach for a Debian package name from memory. Take the
missing `.so` from `ldd <binary>`, search the distro for that soname
(`apt-cache search`, `dnf provides '*/libfoo.so.2'`, `apk search`),
install the hit, re-run `ldd`. Electron-on-Linux commonly misses the
ALSA client library — same recipe, not a special case.

**Chromium/Electron crash in container: sandbox / SUID errors / shm**
Launch flags: `--no-sandbox --disable-gpu --disable-dev-shm-usage`
(last one: container `/dev/shm` is often 64M, Chromium wants more).

**UI tiny or blurry**
See SKILL.md § resolution: screen `RES` = 2× logical AND app scale factor 2.
Only-2× → tiny; only-logical → blurry. Both or compromise at 1.5×.

## Connectivity

**User cannot connect (connection refused / timeout)**
1. `gui-stack.sh status` in the sandbox — port open?
2. Port published? VNC port must be in `docker run -p` / `ports:`. If not and
   the container can't be recreated:
   - ssh into sandbox available? `ssh -L 5900:localhost:5900` from host.
   - last resort: websockify+noVNC sidecar (browser client, no VNC client
     needed) — but it still needs a published port; usually easier to
     recreate the container with `-p 5900:5900`.
3. Host-side firewall: Windows may prompt to allow the VNC *viewer* outbound
   on first connect (rare), corporate EDR can block arbitrary ports; Linux
   desktops rarely block outbound. Try `telnet host 5900` / `Test-NetConnection`
   from the host to distinguish network-block from server-down.

**No published port (immutable container / sbx without ports)**
First choice — publish it properly: for docker-sbx sandboxes the USER runs
`sbx ports <sandbox_name> --publish 5900:5900` on the host; plain docker =
recreate with `-p 5900:5900` or compose `ports:`. If the sandbox truly can't
publish anything: `ssh -L 5900:localhost:5900` when sshd exists; noVNC
sidecar (websockify) if only HTTP survives; `socat` to a port that IS
published. Don't expose VNC to 0.0.0.0 of a public IP to "make it work" —
see Security.

## Security

**Local-only by design; VNC is plaintext + password-weak**
The intended topology is sandbox → published port → same machine. That's fine.
Never expose the port beyond the user's machine (public IP, shared LAN you
don't control): if it ever comes up, tunnel — `ssh -L 5900:localhost:5900
user@sandbox`. Symptom you're in danger: x11vnc `-listen 0.0.0.0` + port
published on a routable IP.

## Host-OS quirks (client side)

**macOS (Screen Sharing, built-in)**
Clipboard pulls only while its window is focused. After host sleep/idle,
modifiers can desync → input freezes → reconnect the session. TigerVNC client
for macOS behaves better on both counts.

**Windows (TightVNC Viewer / TigerVNC Viewer — no built-in client)**
Install a viewer first; put that in the user instructions, not an afterthought.
Clipboard works natively (client syncs Windows clipboard ↔ VNC). Note: the
remote session is Linux — paste there is Ctrl+V; host-side ⌘/Win-modifiers do
not pass through except as Alt/Ctrl equivalents.

**Linux (Remmina / TigerVNC vncviewer / vinagre)**
Remmina is preinstalled on most distros. If colors/encoding glitch in Remmina,
switch its color depth setting or use `vncviewer` (TigerVNC). Clipboard via
`vncconfig`/parcellite on some lightweight hosts — usually just works.

## Clipboard (all hosts)
VNC client syncs with X selections; many apps (Electron incl.) use CLIPBOARD,
X tradition is PRIMARY. Bridge = autocutsel for both selections (in script).
Inside the session paste is Ctrl+V, not Cmd+V. macOS Screen Sharing pulls the
clipboard only when its window is focused.

## Process management

**Your shell dies when you clean up processes**
`pkill -f <pattern>` matches your own command line (the pattern is in it).
Always `pkill -x <exact-name>`. Same class of bug: checking a pidfile-based
watchdog by grepping for the script name.

**Everything dead after a while (container restarted, PID 1 = tini/init)**
Supervised-but-not-really sandboxes restart and kill background processes.
Options: `WATCHDOG=1` handles in-sandbox deaths; container restarts need the
user (or agent) to re-run `gui-stack.sh start` — installs persist, processes
don't. systemd is usually absent (check `ps -p 1`); don't bother with units.
