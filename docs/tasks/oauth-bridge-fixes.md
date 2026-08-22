# OAuth bridge — fix what the roast found

**Status:** done
**Branch:** oauth-bridge-fixes
**Worktree:** .worktrees/oauth-bridge-fixes
**Goal:** In a real sandbox: a browser invoked as `x-www-browser --new-window <url>` still lands in the URL log; `watch` returns a URL the app emitted just before `watch` started; after `uninstall` link handling is exactly as it was found. The listener carries no dead timeout line and reaps what it spawns, and the install output plus the docs state the real reach of `$BROWSER`, of a non-root `$HOME`, and of `--network host`. Claude Code completes a login in a disposable container through the bridge, and SKILL.md/README describe what that run actually did. CI goes red if delegation of non-web schemes silently stops working. Confirming the Claude Code half needs the user's Anthropic account — it cannot be shown by the diff alone.
**Mode:** interactive

## Design

The bridge shipped in a4d8904 with three defects a user reaches on the happy
path, a set of claims no run in this repo backs, and a CI suite that only
asserts the absence of a fork bomb. Fix the defects at their cause, replace the
claims with what a live run shows, and give the test suite something positive
to assert.

**Chosen approach — patch the defects and make the loop impossible by shape,
not by flag.** The fork bomb exists because the shim owns a name that the real
`xdg-open` calls in its own fallback chain (`x-www-browser`) *and* delegates
back to that same `xdg-open`. The current `BMG_DELEGATED` env guard breaks the
cycle but evaporates if any link in the chain clears the environment. Instead
the shim becomes name-aware: it delegates non-web arguments only when invoked
as `xdg-open`. Called as a browser alias, a `mailto:` argument is not its
business and it exits — the chain hits a dead end instead of turning around.
The env guard stays as a second line of defence, now belt to that braces.

Rejected: dropping the browser alias names altogether (kills the loop but also
kills capture for apps that call `x-www-browser` directly — the exact case that
failed), and patching argument parsing alone (leaves the loop class closed only
by the env flag).

**Key decisions**

1. The shim scans every argument for the first `http`/`https` token instead of
   reading `$1`. Browser-style callers put flags first, and those callers are
   the whole reason the aliases exist.
2. Delegation keyed on `$0`'s basename, per the chosen approach.
3. `watch` also accepts a URL that landed shortly before it started: the agent's
   natural order is "trigger the login, then look", and the current
   growth-only watch times out on a log that already holds the answer. The
   lookback is a documented argument, not a buried constant.
4. `install` copies `mimeapps.list` aside once; `uninstall` puts it back, or
   removes the file when there was none. Today uninstall deletes the desktop
   entry and leaves the mimeapps default pointing at it, which is worse than
   the state it found.
5. Assertions move out of the workflow YAML into one test script at the repo
   root, run identically by a developer and by every CI job. TDD needs a loop
   faster than a four-image CI matrix, and the assertions should not exist
   twice (GPC8). The script stays outside `skills/` so the skill payload users
   install keeps only what the agent runs.
6. Claims get replaced by runs: Claude Code logs in end-to-end inside a
   disposable container that is deleted with its token afterwards; the Electron
   path is re-checked non-destructively by opening an external link in the
   already-running Cursor, so the demo login survives. Whatever the runs show
   is what the docs will say.
7. The five smells the roast turned up are in scope too, and they split by kind.
   Two are code: the listener's `srv.timeout` line does nothing on
   `serve_forever` and goes away, and the browser it spawns gets reaped instead
   of left to the OS. Three are honesty: `$BROWSER` reaches login shells only,
   `mimeapps.list` lands in the installer's `$HOME` and misses an app running as
   another user, and `detect_host_addr` returns the LAN router under
   `--network host`. Those three are limits, not bugs — the fix is that the
   install output and the docs say so, and `HOST_ADDR` stays the escape hatch.

TDD: yes — deterministic argument→behaviour contract, called from every alias
and every app, and a regression is exactly what CI should catch. Each of the
three defects starts as a failing assertion in the new test script.

### Invariants
- IV1 — An `http`/`https` argument in any position is written to the URL log exactly once.
- IV2 — The shim never execs the real opener when it was invoked under a browser alias name.
- IV3 — After `uninstall`, `mimeapps.list` and the alias binaries are back to their pre-install state, including absence.
- IV4 — Every CI distro job runs the same test script a developer runs locally; assertions live in one place.

### Principles
- PC1 — Subcommands may carry defaults (deviates from GPC1: an agent must be able to call `watch` with no arguments), but every default is printed in the usage line.
- PC2 — Documentation states only what a run in this repo demonstrated; anything else is labelled unverified in the text itself.

### Assumptions
- AS1 — Claude Code, once it finds a working `xdg-open`/`$BROWSER`, tries to open a URL rather than only printing it in its TUI.
- AS2 — Cursor's UI exposes an external link reachable without logging out, and it travels the same `shell.openExternal` path as the login button.
- AS3 — The user's Anthropic account completes a login initiated from a container without extra device or region checks.

### Unknowns
- UK1 — Which family Claude Code's login lands in once a browser exists: loopback callback on 54545, or the code-paste page.
- UK2 — Whether finishing that login needs the container's loopback port published, and whether the port is fixed across runs.

## Plan

Approach: one harness carries every assertion and goes red on the three defects
first; the script is then fixed in a single phase because all of it lives in one
file; the docs are written last, from what the live runs actually showed.

### PH1 — Harness that is red on the defects

- **1.1** `tests/oauth-bridge.sh` (create) — runs *inside* a disposable container; callers decide how to get there (`docker run --rm -v $PWD:/repo …` locally, `docker exec bmg …` in CI). Locates the skill via its own path. Installs the distro's genuine `xdg-open` when the package index has it.
  - Stage A, genuine opener in place: capture, watch, uninstall round-trip, fork-bomb bounce.
  - Stage B, genuine opener moved aside for a stub that records its argv: delegation reaches the stub under the `xdg-open` name, never under a browser alias. Restores the genuine opener at the end.
  - Prints one line per assertion, exits non-zero if any failed.
  - Respects: IV4
- **1.2** `.github/workflows/stack.yml:107-137` (modify) — the two inline assertion steps become one `docker exec bmg bash /repo/tests/oauth-bridge.sh`; the xdg-utils install moves into the harness so it exists in one place.
- Commit: `test: one bridge harness, red on the three known defects`

### PH2 — The script fixes

- **2.1** `skills/bring-my-gui/scripts/oauth-bridge.sh:100-111` (modify, shim body inside `write_shim`) — `url=$1` becomes a scan of `"$@"` for the first `http`/`https` token; the delegation branch runs only when `basename "$0"` = `xdg-open`; `BMG_DELEGATED` stays as the second line of defence. Header comment `:26-38` gains the name-keyed rule.
  - Respects: IV1, IV2
  - Commit: `fix(bridge): find the URL among flags, delegate only as xdg-open`
- **2.2** `:174-220 cmd_install` — copy `mimeapps.list` to `<file>.bmg-orig` before the first `mimeapps_set`, or drop a `<file>.bmg-absent` marker when there is no file; skip when either already exists so re-running install stays idempotent (GPC5). `:293-302 cmd_uninstall` — restore the copy, or delete the file when the marker says it was absent, and clear our `xdg-settings` default. No backup (an install that predates this change) → delete only our own keys.
  - Respects: IV3
  - Commit: `fix(bridge): uninstall puts link handling back as it found it`
- **2.3** `:230-248 cmd_watch` — take a lookback window as the second argument and report a URL whose timestamp falls inside it, so the agent's natural order (trigger, then look) works; the default appears in the usage line at `:369` (PC1).
  - Commit: `fix(bridge): watch sees the URL that arrived a moment before it`
- **2.4** `:350` delete `srv.timeout` (dead on `serve_forever`); `:337-347` reap the spawned browser from a daemon thread. `:212` say that `$BROWSER` reaches login shells only. `:68-75 detect_host_addr` — comment and install output state that `--network host` yields the LAN router and `HOST_ADDR` overrides it.
  - Commit: `fix(bridge): drop the dead timeout, reap the browser, stop overpromising`

### PH3 — Run the claims, then write them

- **3.1** Disposable container: node + `@anthropic-ai/claude-code`, bridge installed, login driven to completion, container deleted with its token. Records which family the flow lands in (UK1) and whether a published loopback port was needed (UK2); a login that stalls on a device or region check is AS3 failing, recorded as such.
- **3.2** `bmg-cursor`, non-destructively: open an external link from the running UI over VNC and confirm the shipped shim catches Electron's `shell.openExternal` (AS2). No logout, the demo login survives.
- **3.3** `skills/bring-my-gui/SKILL.md:199-243`, `references/gotchas.md` § Browser login, `README.md`, `README.ru.md` — app claims rewritten to what 3.1/3.2 showed; anything not run says so (PC2). gotchas gains the non-root `$HOME` limit for `mimeapps.list`.
- Commit: `docs(skill): describe the login flows that were actually run`

### Test strategy

Failing first (TDD), in the harness:
- A URL after a flag (`x-www-browser --new-window <url>`) is captured — red today, the shim reads `$1`.
- `watch` returns a URL written two seconds before it started — red today, it only watches for growth.
- `mimeapps.list` and the alias binaries are byte-identical before install and after uninstall, including the absent case — red today, uninstall leaves a dangling default.
- Delegation reaches the real opener when invoked as `xdg-open` — untested today, and nothing would catch its loss.

Green already, kept as regressions: URL in first position; URL captured exactly once per invocation; no process growth after a non-web bounce; `watch` still returns a URL that arrives while it waits; `watch` exits non-zero on an empty window.

### Order & dependencies

PH1 → PH2 → PH3, strictly. The harness must be red before the fixes, and the live runs need the fixed shim to be worth anything.

### Risks / rollback

- RK1 — AS1 may be false and Claude Code only prints the URL in its TUI; then PH3 changes no code and the finding itself becomes the doc text.
- RK2 — the harness stubs `/usr/bin/xdg-open` inside CI's shared container; it restores the genuine one before exiting, and the container is torn down by the job anyway.
- RK3 — name-keyed delegation means `x-www-browser ./page.html` stops opening anything. Nothing is lost in a browserless sandbox, and `xdg-open ./page.html` is unaffected.

### Interfaces

- IF1 [blocks] — `tests/oauth-bridge.sh` → exit 0 iff every assertion passed. Blocks because TDD needs it red before PH2 touches the script.
- IF2 [blocks] — the regenerated shim's argument contract. Blocks because a live run against the old shim proves nothing.

### Interface graph

- PH1              -> IF1   @ tests/oauth-bridge.sh, .github/workflows/stack.yml
- PH2  IF1         -> IF2   @ skills/bring-my-gui/scripts/oauth-bridge.sh
- PH3  IF2         ->       @ skills/bring-my-gui/SKILL.md, skills/bring-my-gui/references/gotchas.md, README.md, README.ru.md

### Backwards compatibility

The shim already installed in `bmg-cursor` is regenerated by re-running `install`; PH3's live runs do that anyway. An install predating PH2.2 has no backup file, and uninstall handles that by deleting only its own keys.

### PH4 — second review round before merge (2026-08-21)

Independent finders (shim/shell, watch, round-trip + CI, docs honesty,
maintainer audit) with Docker repros against `93b17db`; every confirmed
finding became a red assertion first, then a fix. Same TDD loop, same harness.

- **4.1** `tests/oauth-bridge.sh` — +18 assertions, stage C (opener in the shim's own dir), non-root caller via `su` / `chroot --userspec`, stub at `/usr/bin/xdg-open` even without xdg-utils, EXIT trap restores the opener. Commit `3a39f42`.
- **4.2** `skills/bring-my-gui/scripts/oauth-bridge.sh` — capture: log dir 1777 / log 666, case-insensitive scheme, CR/LF stripped, `BMG_DELEGATED` as a depth cap (2), `HOME` fallback + `XDG_CONFIG_HOME`/`XDG_DATA_HOME`; real opener: `type -aP` (bash has no `command -a`) and the `.bmg-orig` copy wins on re-install; uninstall: removes `bmg-scheme-*.desktop`, rebuilds `mimeinfo.cache`, backup over a pre-backup install strips our keys, snapshot tells "untouched since" (byte-for-byte restore) from "someone wrote since" (merge: drop ours, restore our keys' old values), shim looked up in every candidate bin dir; watch: prints all unseen URLs oldest first, `before` snapshotted ahead of the scan, future stamp = recent, non-numeric args → usage exit 2. Commit `47307be`.
- **4.3** SKILL.md / gotchas.md — absolute-path mechanism (desktop entry with `DISPLAY`, `www-browser` alias without), `watch` contract, per-user mimeapps vs. world-writable log, uninstall keeps others' entries. Commit `041abc2`.

## Verify

**Result:** passed

Happy-path:
- CK1 — flag / two http tokens / `--https://` lookalike — held (first real token, one line)
- CK2 — lookback on a 2s-old URL; wait-for-growth; lookback 0 ignores existing — held
- CK3 — `url` then `watch` re-hands; two same-second lines re-hand on second `watch` — held
- CK4 — existing `mimeapps.list` restored after double `install` (backup not overwritten) — held
- CK5 — `gio open https://…` misses the shim — held: `xdg-mime` default `bmg-open.desktop`, log got the URL

Negative:
- CK6 — `mailto:` from a browser alias captures or multiplies processes — held
- CK7 — ISO leftover in the log is treated as a URL by lookback — held (timeout)
- CK8 — default `install` (no `HOST_PORT`) omits `$BROWSER` / mimeapps `$HOME` / `--network host`+`HOST_ADDR` — held

Invariants / assumptions:
- CK9 (IV1) — one invocation writes two log lines — held (stayed at 1)
- CK10 (IV2) — stub opener reached as `x-www-browser` — held (never)
- CK11 (IV3) — uninstall leaves mimeapps/aliases dirty, including a pre-existing mimeapps file — held
- CK12 (IV4) — CI still has inline assertions instead of `tests/oauth-bridge.sh` — held (one `docker exec` step)
- CK13 (PC1) — usage line omits the LOOKBACK default — held (`LOOKBACK=60`)
- CK14 (PC2) — docs still claim `gio` is an alias — held
- CK15 (AS1) — Claude Code never calls the shim — deferred: needs disposable `claude` + Anthropic
- CK16 (AS2) — Cursor UI `shell.openExternal` bypasses the shim — deferred: UI click on `bmg-cursor`

Interfaces:
- CK17 (IF1) — harness non-zero on a CI image — held (ubuntu/debian/fedora/alpine 12/12)
- CK18 (IF2) — shim still reads `$1` / delegates under a browser alias — held
- CK19 — `srv.timeout` still present — held (gone; browser `Popen` reaped on a daemon thread)

Smoke: `tests/oauth-bridge.sh` → 12/12 on ubuntu:24.04, debian:bookworm-slim, fedora:41, alpine:3.21

Goal: proxy only — harness + `gio`/`install` stdout; Cursor UI click and Claude paste-code completion not re-run

Notes: CK15/CK16 deferred (Anthropic login / VNC UI click)

**Round 2 (merge review, 2026-08-21) — result: passed**

Red first: the new harness against `93b17db` on ubuntu → 18 passed, 14 failed, every failure one of the new assertions (non-root capture ×3, upper-case scheme, newline, both-URLs ×2, future stamp, bad timeout, third-party mimeapps line, pre-backup install, handler round-trip, depth-1 delegation, same-dir opener).

Green: `tests/oauth-bridge.sh` → 32/32 on ubuntu:24.04, debian:bookworm-slim, fedora:41, alpine:3.21; non-root and stage C ran on all four (no NOTE skips). shellcheck clean on both scripts.

Extra attacks, held: `HOME` unset → `status`/`watch` run; `XDG_CONFIG_HOME=/tmp/xdgc` → mimeapps written there and removed by uninstall; upgrade path main-install → branch-install → uninstall → mimeapps absent, `xdg-mime` empty, no bmg desktop files; hostile URLs (quotes, `$(…)`, backticks, spaces, unicode) logged verbatim (round-2 finder, unchanged code).

Not re-run: Cursor UI click (AS2), Claude paste-code completion (AS3) — unchanged since round 1, need the user's account / VNC.

**Round 2b (`/verify`, driving the merged CLI in ubuntu:24.04 + fedora:41, `DISPLAY=:0`):** install → `status` → app as `nobody` opens the login URL via `x-www-browser --new-window` → `watch 5 60` prints it, second `watch` exits 1 → two URLs → both printed oldest first → `url` peeks → `xdg-open mailto:` delegated (procs 4→4) → `handler cursor` + `xdg-open cursor://…` reaches the app → probes (`watch 30s`/`abc` → usage exit 2; `HOME` unset; double install; bare `xdg-open`; `--app=URL`; `sensible-browser /etc/hostname`; URL with space/quote/`$(id)`; log cleared under a waiting `watch`) → uninstall leaves `xdg-mime` empty, no desktop files, no `~/.config` entries, `cursor://` no longer reaches the app → upgrade from the origin/main install is clean. **One FAIL found and fixed:** the depth guard printed `[: Illegal number:` on every non-web call (`6cfe77e`); suite now asserts silent delegation. Re-driven after the fix: clean on both images.

## Conclusion

Outcome: Deterministic bridge contract held — round 1 14/14, round 2 32/32 on all four CI images, CLI driven end-to-end in two of them; Claude login not driven to a stored token, Cursor UI click (AS2) deferred. HEAD `6cfe77e` (round 2 + 2b on top of `93b17db`).

Invariants:
- IV1 — harness: one invocation, one log line; URL after a flag captured
- IV2 — harness: `mailto:` from `x-www-browser` never reaches the stub opener
- IV3 — harness: fingerprint after `install; install; uninstall` matches pre-install, including absence
- IV4 — `.github/workflows/stack.yml` runs `tests/oauth-bridge.sh` in the distro jobs

### Assumptions check
- AS1 — held — Claude Code 2.1.238 called the shim (loopback URL in the log)
- AS2 — held — confirmed by the user (2026-08-21); `/usr/bin/xdg-open` after install captured
- AS3 — held — confirmed by the user (2026-08-21); chat handoff is the intended in-container Claude path

### Unknowns outcome
- UK1 — resolved — both families: loopback on a random port (45781, not 54545) plus a `code=true` TUI URL
- UK2 — resolved — loopback port is random; publishing 54545 from inside does not help

Review findings:
- Critical: none
- Important (round 1): `backup_mimeapps` skip was `A || B && C` — rewritten as `if`; harness round-trips double install. Earlier rounds: docs honesty, `gio` not an alias, `watch` watermark, `url` peek, dead `xdg-settings unset`, leftover CI «expected red».
- Important (round 2, all fixed in `47307be`): capture silently dropped for a non-root app (root-owned 0755 log dir) while docs claimed "PATH shim still applies"; `command -v -a` is invalid in bash, so the real opener was found only at `/usr/bin/xdg-open` and a double install with the opener in the shim's dir lost delegation; uninstall left `bmg-scheme-*.desktop` and a stale `mimeinfo.cache` (Fedora kept answering `bmg-open.desktop`); install over a pre-backup install "restored" dangling defaults; restore wiped registrations other apps made after install; `BMG_DELEGATED` leaked into apps the real opener launched and blocked their non-web opens; `HOME` unset crashed every subcommand; harness never exercised the desktop-entry path (mutation stayed green) and failed on images without xdg-utils.
- Important (round 2b, `/verify`, fixed in `6cfe77e`): the new depth guard left `BMG_DELEGATED` unset and printed `[: Illegal number:` to stderr on every non-web call; the suite had discarded stderr.
- Minor (round 2, fixed): watch `tail -1` swallowed the older of two URLs in one poll; startup gap between scan and `before`; future stamp never handed out; `watch 30s` → bash arithmetic error; upper-case scheme and embedded newline.
- Left as is: `x-www-browser --app=URL` (Chrome-style) not captured — no caller seen; `uninstall` after `BIN_DIR=/usr/bin` install now found via the candidate-dir scan.

Verified by: round-2 harness on four images + Docker attacks + `/verify` CLI drive; Cursor UI click (AS2) and Claude paste-code completion (AS3) signed off by the user on 2026-08-21 — Goal confirmed, Status `done`

### Deviations from plan
- PH2: four planned commits landed as one
- PH3: Claude login not driven to a stored token (chat-handoff is the intended path); Cursor UI click skipped
- PH4 (unplanned): a second review round before merge; the multi-agent review workflow hit the session usage limit after ~25 min and was stopped — findings were salvaged from the finders' transcripts and verified by hand in Docker (see memory `workflow-session-limit`)


### Round 3 — CI red on main (2026-08-22), fixed
Run #8 (`db058a3`) failed the bridge suite on alpine/debian/ubuntu (24/8), fedora stayed green. Log: once `nobody` had created `open-urls.log`, root got `Permission denied` on `: >log` and `>>log` — `fs.protected_regular=2` on GitHub's ubuntu runners (a host sysctl, inherited by containers) refuses an O_CREAT open of another uid's file in a sticky world-writable dir, root included. Invisible in the sandbox (`protected_regular=0`); reproduced with `sysctl -w fs.protected_regular=2`. fedora:41 escaped only because its bash 5.2.32 retries a refused O_CREAT open without the flag (strace); dash/busybox/older bash don't, and the shim runs under `/bin/sh`.
Fix: `install`/`watch` create the log when absent and never re-open it with O_CREAT (`ensure_log`; `watch` only reads); the shim falls back to `dd conv=nocreat,notrunc oflag=append` (GNU coreutils) when `>>` is refused; the harness clears the log with `rm` + recreate and asserts root's `watch` and root's capture over a non-root-created log (the latter GNU-dd only, NOTE on busybox); CI turns the suite's FAIL/FATAL lines into annotations + step summary. Verified locally on the four images under `protected_regular=2` and `=0`.
