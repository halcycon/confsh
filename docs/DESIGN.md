# confsh design

> SPDX-License-Identifier: MIT

`confsh` is an optional, EdgeOS/Vyatta-style configuration shell for
OpenWrt. It sits on top of UCI: nothing about the router changes unless
the user types `commit`, and LuCI, `uci` and shell scripts keep working
side by side.

It is a standalone package. It runs on any OpenWrt 24.10+ install
(apk or opkg), on any architecture, and does not depend on the
USG-PRO-4 tree that prompted it.

## Goals

1. **Muscle memory first.** `configure`, `set`, `delete`, `edit`,
   `show`, `compare`, `commit`, `commit-confirm`, `confirm`, `discard`,
   `exit discard`, `rollback`, `run show …` behave the way EdgeOS users
   expect.
2. **Zero lock-in.** UCI stays the single source of truth. No shadow
   config file, no daemon. Uninstalling confsh leaves the router exactly
   as configured.
3. **Coexist with LuCI.** Each CLI session stages changes in its own
   UCI delta directory, so LuCI's pending changes and the CLI's never
   mix (see [Concurrency](#concurrency) for the `uci` CLI caveat).
4. **Small and portable.** Architecture-independent package
   (`PKGARCH:=all`): ucode backend, bash front end. No compiled code.
5. **Extensible by other packages.** Schema hints and op-mode commands
   are plain files dropped into well-known directories.

## Non-goals (for now)

- Full EdgeOS config-tree parity. The *generic layer* exposes UCI
  directly; EdgeOS paths (`interfaces ethernet eth0 …`) come later as
  optional *dialect modules* for the most common trees only.
- Replacing LuCI, rpcd ACLs, or multi-user permissions. confsh runs as
  the logged-in (root) user.
- Reboot-based `commit-confirm` (EdgeOS default). confsh reverts by
  restoring files and reloading services.

## Architecture

```text
 user ── bash (confsh.bashrc) ──► /usr/libexec/confsh/backend (ucode)
          │  functions: set, delete,        │
          │  edit, show, commit, …          ├─► UCI (session delta dir)
          │  completion: complete -F        ├─► /etc/config (on commit)
          │                                 ├─► /sbin/reload_config
          └─ op mode: show … ───────────────┴─► /usr/libexec/confsh/op/… (plugins)
```

This mirrors the original Vyatta design (bash + programmable completion
+ a config backend), which is why it maps so naturally.

| Path | Purpose |
|------|---------|
| `/usr/bin/confsh` | Launcher: interactive shell, or `confsh <op command>` one-shot |
| `/usr/lib/confsh/confsh.bashrc` | bash functions, prompt, completion |
| `/usr/libexec/confsh/backend` | ucode entry point (one process per command) |
| `/usr/share/ucode/confsh/*.uc` | backend modules |
| `/usr/share/confsh/schema/*.json` | schema hints (lists, enums, booleans, known options) |
| `/usr/libexec/confsh/op/<word>/…` | op-mode command tree (executables) |
| `/etc/config/confsh` | confsh's own settings (archive size, confirm timeout) |
| `/etc/confsh/archive/` | commit revisions (kept across sysupgrade) |
| `/var/run/confsh/sessions/<pid>/` | per-session UCI delta dir + metadata |
| `/etc/init.d/confsh` | at boot, reverts an unconfirmed `commit-confirm` |

### Why bash + ucode

- ucode is OpenWrt's native scripting language, already present wherever
  LuCI is, with first-class `uci`, `ubus` and `fs` bindings.
- ucode has no line editor; bash gives history, editing and programmable
  completion for free. Each command is a short-lived backend process;
  completion is a backend call per <kbd>Tab</kbd>.
- klish (in the packages feed) is Cisco-style (immediate apply); its
  commit-style mode needs sysrepo + YANG models, too heavy for small
  routers.

## Modes

**Operational mode** (default after `confsh`): normal shell plus op
commands (`show interfaces`, `show ip route`, `show configuration`,
`show configuration commands`, `show system commit`, …). Prompt:
`root@router:~$`.

**Configuration mode** (`configure`): session created, config commands
defined, prompt shows the edit level:

```text
[edit network interface lan]
root@router#
```

`exit` refuses to leave with uncommitted changes (`exit discard` to
drop them). `run <op command>` runs an op-mode command from config mode.

## Generic layer: path grammar

```text
<config> <section-type> <section> <option> <value>
network  interface      lan       ipaddr   192.168.1.1
```

- `<config>`: a file in `/etc/config`. confsh never creates config files.
- `<section-type>`: as in `config interface 'lan'`. Included (rather than
  `network lan ipaddr`) because it gives tab completion a natural tree,
  matches the file syntax, and mirrors EdgeOS tag nodes
  (`interfaces ethernet eth0`). A section referenced with the wrong type
  is an error.
- `<section>`: a section name, or `@N` for the N-th section of that type
  (same index as `uci show`'s `@type[N]`), used for anonymous sections.
- `<option>`: an option name.
- `<value>`: one value; quote values containing spaces (as on EdgeOS).

The current `edit` level is prepended to every path.

### Anonymous sections (the hard part)

UCI anonymous sections (`config rule` with no name) have no stable
identity: `@rule[3]` shifts when rules are added or removed, while
EdgeOS expects stable tags (`rule 10`). Decisions:

1. confsh **displays** anonymous sections as `@N`. On input, `@N` means
   the N-th section of the type whether named or not (same as uci's
   `@type[N]`), so `dropbear dropbear @0` works whether the stock section
   is anonymous (older releases) or named `main` (25.12). It is resolved
   to the internal section ID at command time; inside one session the
   IDs in the delta are stable, so staged edits stay correct.
2. confsh **never creates** anonymous sections. `set firewall rule
   allow_ssh …` creates a *named* section `allow_ssh`; LuCI and fw4
   handle named sections fine.
3. Later (dialect layer / opt-in): offer `name-sections <config>
   <type>` to convert anonymous sections to stable names derived from
   their `name` option.

### Lists vs options (no UCI schema)

UCI itself has no schema, so confsh decides per option:

1. Existing value is a list → `set` appends (if not present), `delete …
   <value>` removes one item. This is EdgeOS multi-value node behaviour.
2. Schema hint says `list` → list semantics (an existing scalar becomes
   the first list item).
3. Otherwise → scalar option; `set` replaces.

### Schema hints

`/usr/share/confsh/schema/*.json`, deep-merged, keyed by config → type →
option:

```json
{
  "network": {
    "interface": {
      "proto":  { "values": ["static", "dhcp", "dhcpv6", "pppoe", "none"] },
      "dns":    { "list": true },
      "auto":   { "type": "bool" }
    }
  }
}
```

Used for: tab completion of options that do not exist yet, list
detection, enum completion/validation, booleans (`set … disabled` with
no value sets `1`). Hints are advisory: unknown options are always
accepted (UCI is open-ended). Other packages can ship their own hint
file.

## Commands (configuration mode)

| Command | Behaviour |
|---------|-----------|
| `set <path> [value]` | Create section / set option / append list item. Missing named sections are created automatically |
| `delete <path> [value]` | Remove list item, option, section, or all sections of a type. Deleting a whole config is refused |
| `edit <path>` / `up` / `top` | Change edit level (max depth: section). `edit` creates a missing named section |
| `show [path]` | Working config at level, with EdgeOS change markers (`+` added, `-` removed, `>` changed) |
| `compare` | Only the changes, EdgeOS style (`[edit …]` headers, `-`/`+` lines) |
| `discard` | Drop all staged changes |
| `commit [comment <text>]` | Write staged configs, archive revision, run `reload_config` |
| `commit-confirm [minutes] [comment <text>]` | Commit, then auto-revert unless `confirm` within N minutes (default 10) |
| `confirm` | Keep a pending commit-confirm |
| `rollback <N>` | Restore archived revision N to `/etc/config` and reload (asks first) |
| `save` | No-op notice: UCI commit already persists to flash |
| `run <op command>` | Run an op-mode command |
| `exit [discard]` | Leave config mode |

Op mode adds `show configuration [commands]` and `show system commit`
(revision list), plus the plugin tree below.

### Commit semantics vs EdgeOS

EdgeOS separates *commit* (apply to running system) and *save* (persist
to `config.boot`). UCI `commit` writes `/etc/config` on flash and
`reload_config` applies, so confsh's `commit` = EdgeOS `commit; save`.
`save` prints a notice instead of silently doing nothing.

### Concurrency

At `configure`, confsh records mtime+size of every `/etc/config` file.
`commit` refuses if a config it is about to write was changed by someone
else (LuCI apply, another session, a script) since then, because staged
deltas for anonymous sections may no longer line up. `commit force`
overrides. After a successful commit the stamps are refreshed.

**`uci` CLI staging (`/tmp/.uci`).** libuci's `uci_set_savedir()`
*appends* a delta path; the default `/tmp/.uci` always stays in the list
and ucode's binding cannot remove it (rpcd does, by clearing libuci's
internal list, which is why LuCI sessions are isolated). Consequences:

- Uncommitted `uci set …` changes are visible inside confsh (in both the
  working and committed views), exactly as `uci show` sees them.
- `cursor.changes()` reports them too, so confsh derives the session's
  changed configs from its own delta directory.
- `configure` warns when `/tmp/.uci` holds changes. `commit` refuses to
  write a config that also has `/tmp/.uci` changes (they would be baked
  in) unless `commit force`.

A clean fix needs a small ucode/libuci change (e.g. a cursor option to
reset delta paths); worth proposing upstream.

### Archive and rollback

- On every commit, `/etc/config` is tarred into
  `/etc/confsh/archive/<timestamp>.tar.gz` with an `index.json` entry
  (time, user, comment). The first commit also archives the pre-commit
  state as a baseline so `rollback 1` always exists.
- Revision 0 is the current config. `confsh.archive.max` (default 20)
  bounds the count. `/etc/confsh/` is listed in
  `/lib/upgrade/keep.d/confsh`.
- `rollback N` restores only the files present in that archive (configs
  for packages installed later are left alone), runs `reload_config`,
  then archives the result as a new revision.

### commit-confirm

1. Refuse if another confirm is pending.
2. Snapshot the pre-commit `/etc/config` to
   `/etc/confsh/confirm-pre.tar.gz`, then commit as usual.
3. Write `/etc/confsh/confirm.json` (random token, deadline) and start a
   detached timer (`setsid backend confirm-timeout <token>`), so the
   timer survives the SSH session dying — which is the point.
4. `confirm` removes the marker; the timer notices and exits. On timeout
   the timer restores the snapshot, reloads, logs via `logger -t confsh`,
   and archives the reverted state.
5. Marker and snapshot live on flash: if the router is power-cycled
   before `confirm`, `/etc/init.d/confsh` (START=11, before network and
   firewall) restores the snapshot at boot.

Further commits are refused while a confirm is pending.

## Op-mode plugin tree

`/usr/libexec/confsh/op/` is a directory tree; leaves are executables.
`show ip route` resolves to `op/show/ip/route`; remaining words are
passed as arguments. Completion lists directory entries. Any package
can add commands, e.g. `kmod-octeon-flowtable` could ship
`op/show/offload` without confsh depending on it.

Shipped: `show configuration [commands]`, `show system commit`,
`show interfaces`, `show ip route`, `show arp`, `show dhcp leases`,
`show nat translations`, `show version` (v0.1); `show interfaces
wireguard`, `show interfaces wireless [clients]`, `show firewall
[zones|forwardings|rules]`, `show nat rules` (v0.2).

Op commands that read live state use the `ubus` and `wg` CLIs (not the
ucode ubus binding) so tests can stub them (`tests/stubs/`).

### Secrets

Schema hints can mark options `"secret": true` (WireGuard keys, Wi-Fi
keys, PPPoE passwords). Their values are rendered as `********` in
`show`, `compare` and `show configuration [commands]`, and are not
offered by `delete` completion; `CONFSH_SHOW_SECRETS=1` disables
masking. Values are stored as typed (UCI has no hashing).

## Dialect layer (EdgeOS paths)

Tester priorities (from the original octeon-flowtable author), in
order: WireGuard; DNAT / port-forwards; firewall rules + zone
forwardings; VLAN interfaces (vif-style); Wi-Fi.

v0.2 covers all five in the generic layer (schema hints, status
commands, cheat sheet). Firewall zones/forwardings and Wi-Fi have no
EdgeOS equivalent worth emulating (EdgeOS has no zones and no radios),
so they stay UCI-native. The dialect layer targets the three where
EdgeOS syntax is genuinely nicer:

**WireGuard** — peers keyed by public key, as on EdgeOS:

```text
set interfaces wireguard wg0 address 10.0.0.1/24        → network.wg0 proto=wireguard, addresses
set interfaces wireguard wg0 listen-port 51820          → network.wg0.listen_port
set interfaces wireguard wg0 private-key <key>          → network.wg0.private_key
set interfaces wireguard wg0 peer <pub> allowed-ips X   → wireguard_wg0 section with public_key=<pub>
set interfaces wireguard wg0 peer <pub> description D   →   … .description
set interfaces wireguard wg0 peer <pub> endpoint H:P    →   … .endpoint_host / endpoint_port
set interfaces wireguard wg0 peer <pub> persistent-keepalive N
set interfaces wireguard wg0 route-allowed-ips true     → route_allowed_ips=1 on every peer
delete interfaces wireguard wg0 peer <pub>              → delete that section
```

The peer section is found by `public_key` (named or anonymous); new
ones are named `peer_<first 8 key chars, alnum>`. Completion offers
peer keys annotated with descriptions.

**Port forwards / DNAT**:

```text
set port-forward rule 1 description NAS     → firewall redirect pf_1: name
set port-forward rule 1 original-port 443   →   src_dport
set port-forward rule 1 protocol tcp_udp    →   proto tcpudp
set port-forward rule 1 forward-to address  →   dest_ip
set port-forward rule 1 forward-to port     →   dest_port
set port-forward wan-interface eth0         → src zone = zone containing eth0's interface
set port-forward lan-interface eth1         → dest zone, likewise
set port-forward hairpin-nat enable         → reflection=1 on all pf_* redirects
set service nat rule N type destination …   → same redirect mapping, inbound-interface → src zone
```

**vif VLANs** (802.1Q on a plain NIC):

```text
set interfaces ethernet eth1 vif 10 address 192.168.20.1/24
  → network device eth1_10 (type 8021q, ifname eth1, vid 10, name eth1.10)
  → network interface eth1_10 (device eth1.10, proto static, ipaddr/netmask)
set interfaces ethernet eth1 vif 10 address dhcp → proto dhcp
set interfaces ethernet eth1 vif 10 description X → kept as a comment option
```

DSA switch ports (`bridge-vlan`) have no EdgeOS vif equivalent and
stay UCI-native.

Implementation (v0.3, `confsh/dialect.uc`): paths whose first word is
not a UCI config name dispatch to modules under
`/usr/share/ucode/confsh/dialect/`. Modules mount grammar subtrees at
path prefixes (`port-forward`, `interfaces wireguard`, …; parent words
like `interfaces` are shared). The framework parses and validates,
completes, and renders `show` / `show configuration [commands]` in
EdgeOS form by diffing the module's render of the committed and working
cursors. Modules translate parsed commands into UCI and keep no other
state (globals go in `/etc/config/confsh`). Module API:
[DIALECTS.md](DIALECTS.md). `port-forward` is the reference module;
VPN subtrees are owned by @packerlschupfer
([#2](https://github.com/halcycon/confsh/issues/2)).

Later: an importer for an EdgeOS `config.boot` (parse → dialect →
staged UCI changes → `compare` → `commit`), driven by real tester
configs.

## Packaging and distribution

- Repo is an OpenWrt feed: package in `confsh/`. Users can
  `src-git confsh https://github.com/halcycon/confsh.git` in
  `feeds.conf`, or install the prebuilt apk/ipk.
- `DEPENDS:=+bash +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus`.
- CI: shellcheck + container tests on the official `openwrt/rootfs`
  image; package build with the OpenWrt SDK.

### Pulling into halcycon/openwrt (USG-PRO-4)

Same pattern as `luci-theme-proton2025`: a pinned git submodule at
`package/confsh` (the build system scans nested package dirs), selected
in the router seed. The USG offload package may add an
`op/show/offload` plugin. Neither repo requires the other.

## Testing

`tests/run.sh` runs every `tests/t-*.sh` inside the official
`openwrt/rootfs` container (real ucode, libuci, busybox). `reload_config`
is replaced via `CONFSH_RELOAD_CMD` because procd/ubus are not running
there, and `CONFSH_CONFIRM_SECONDS_PER_MINUTE` shortens commit-confirm
timers. Scripted use goes through `confsh -s` (commands on stdin, stop at
the first failure, uncommitted changes dropped). CI also builds the
package with the 25.12 (apk) and 24.10 (ipk) SDKs. Hardware testing
(commit-confirm over SSH, reload behaviour) is done on real routers.

## Milestones

1. **v0.1 generic layer** — modes, set/delete/edit/show/compare/commit,
   commit-confirm, archive/rollback, completion, op plugins, tests, CI.
2. **v0.2 tester priorities, generic layer** — WireGuard, port-forward,
   firewall, wireless status commands; schema hints (WireGuard peers,
   Wi-Fi, DSA VLANs); secret masking; cheat-sheet sections.
3. **v0.3 dialect** — framework + `port-forward` (done); then
   `service nat`, `interfaces ethernet … vif`. VPN subtrees
   (`interfaces wireguard`, `vpn ipsec`, `interfaces openvpn`,
   `interfaces tunnel`) contributed per #2.
4. **v0.4+** — `load`/`merge`/`save <file>` (diff engine), inline help
   (`?`), firewall rule counters, `config.boot` importer.
