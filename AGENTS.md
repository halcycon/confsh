# AGENTS.md

Human docs: [README.md](README.md), command reference
[docs/COMMANDS.md](docs/COMMANDS.md). Design and roadmap:
[docs/DESIGN.md](docs/DESIGN.md) — update both when behaviour changes.
Every cheat-sheet example in COMMANDS.md must also be in
`tests/t-cheatsheet.sh`.

## What this is

An EdgeOS/Vyatta-style configuration shell over OpenWrt UCI, packaged as
an OpenWrt feed (`confsh/Makefile`, `PKGARCH:=all`). Standalone: it must
work on any OpenWrt 24.10+ install and must not depend on the USG-PRO-4
tree ([halcycon/openwrt](https://github.com/halcycon/openwrt)), which
consumes it as a submodule at `package/confsh`.

## Layout

| Path | Role |
|------|------|
| `confsh/files/usr/bin/confsh` | Launcher (interactive, one-shot, `-s` script mode) |
| `confsh/files/usr/lib/confsh/confsh.bashrc` | bash front end: functions, prompt, completion |
| `confsh/files/usr/libexec/confsh/backend` | ucode entry point |
| `confsh/files/usr/share/ucode/confsh/` | backend modules (`cmd`, `tree`, `archive`, `complete`, `util`, `dialect`) |
| `confsh/files/usr/share/ucode/confsh/dialect/` | EdgeOS-path modules (API: `docs/DIALECTS.md`) |
| `confsh/files/usr/share/confsh/schema/` | schema hints (JSON) |
| `confsh/files/usr/libexec/confsh/op/` | op-mode command tree |
| `tests/` | container tests (`t-*.sh`), fixtures |

## Rules

1. UCI is the only source of truth. No shadow config, no daemon.
2. Never create anonymous sections; never create config files.
3. Session changes live in the session delta dir only. `cursor.changes()`
   also reports `/tmp/.uci` (libuci always overlays it), so derive
   session changes from the delta dir.
4. Config-mode functions exist only inside `configure`: `set` shadows
   the bash builtin. Inside the rc file use `builtin` when needed.
5. Every behaviour change gets a test in `tests/t-*.sh`; run
   `tests/run.sh` and shellcheck before committing.
6. ucode style follows OpenWrt (tabs, `'use strict';`, SPDX headers).
   ucode does not hoist function declarations: define before use.
   Dialect modules are scripts ending in `return { … }` (no `export`).
7. Dialect mounts are owned per `docs/DIALECTS.md`; VPN subtrees belong
   to @packerlschupfer (issue #2), so don't implement them here.

## Do not commit

Built `*.apk` / `*.ipk`, SDK trees, `bin/`, `dl/`, local `.config`.
