# confsh — EdgeOS/Vyatta-style CLI for OpenWrt

`confsh` gives OpenWrt the `configure` / `set` / `commit` /
`show configuration` workflow that EdgeRouter and VyOS users already
know. It is an optional front end over UCI. LuCI, `uci` and your scripts
keep working, and removing the package leaves the router exactly as
configured.

```text
root@router:~$ configure
[edit]
root@router# edit network interface lan
[edit network interface lan]
root@router# set ipaddr 10.0.0.1
[edit network interface lan]
root@router# show
 device br-lan
>ipaddr 10.0.0.1
 netmask 255.255.255.0
 proto static
[edit network interface lan]
root@router# commit-confirm 5 comment "new LAN subnet"
commit-confirm: changes will be reverted in 5 minutes unless you type 'confirm'
[edit network interface lan]
root@router# confirm
Commit confirmed
```

**Status: v0.1, early, looking for testers.** Tested in OpenWrt 25.12
and 24.10 containers; not yet run on many real routers. Use
`commit-confirm` when changing anything that could cut off your access.

- Full syntax, every command, and an **EdgeOS → confsh cheat sheet**:
  [docs/COMMANDS.md](docs/COMMANDS.md)
- Design, limits and roadmap: [docs/DESIGN.md](docs/DESIGN.md)

## Install

Requires OpenWrt 24.10 or newer, any architecture (one package fits all).
It pulls in `bash`, `ucode` and the ucode `fs`/`uci`/`ubus` modules from
the official feeds, so the router needs internet access while
installing.

Packages are on the [latest release](https://github.com/halcycon/confsh/releases/latest).
They aren't signed with a key your router knows, so allow that one file
explicitly.

OpenWrt 25.12 and newer (apk):

```sh
cd /tmp
wget -O confsh.apk https://github.com/halcycon/confsh/releases/download/v0.3.0/confsh-0.3.0-r1.apk
apk update
apk add --allow-untrusted ./confsh.apk
```

OpenWrt 24.10 (opkg):

```sh
cd /tmp
wget -O confsh.ipk https://github.com/halcycon/confsh/releases/download/v0.3.0/confsh_0.3.0-r1_all.ipk
opkg update
opkg install ./confsh.ipk
```

(`-O` matters: OpenWrt's `wget` otherwise names the file after GitHub's
download redirect.)

Then log in over SSH as usual and run `confsh`.

Building it into your own firmware: add
`src-git confsh https://github.com/halcycon/confsh.git` to `feeds.conf`,
run `./scripts/feeds update confsh && ./scripts/feeds install confsh`,
and select *Utilities → Shells → confsh*.

Removing it (`apk del confsh` / `opkg remove confsh`) leaves your
configuration untouched.

## Commands

Paths follow the UCI file layout:
`<config> <section-type> <section> <option> <value>`, for example
`set firewall zone @1 masq 1` or `set network interface lan ipaddr 10.0.0.1`.
`@N` is the N-th section of a type, as in `uci show`. New sections are
always created with a name. See the
[cheat sheet](docs/COMMANDS.md#edgeos-cheat-sheet) for EdgeOS equivalents.

Some areas also accept EdgeOS's own syntax: `port-forward`
(`set port-forward rule 1 forward-to address …`) and `service nat`
(`set service nat rule 5010 type masquerade`). More are on the way: see
[EdgeOS paths](docs/COMMANDS.md#edgeos-paths), and
[DIALECTS.md](docs/DIALECTS.md) if you want to write one.

| Mode | Commands |
|------|----------|
| Operational | `configure`, `show configuration [commands]`, `show system commit`, `show interfaces [wireguard \| wireless [clients]]`, `show firewall [zones\|forwardings\|rules]`, `show nat rules`, `show nat translations`, `show ip route`, `show arp`, `show dhcp leases`, `show version` |
| Configuration | `set`, `delete`, `edit`, `up`, `top`, `show`, `compare`, `discard`, `commit [comment …]`, `commit-confirm [min]`, `confirm`, `rollback N`, `run <op command>`, `exit [discard]` |

Things that differ from EdgeOS:

- `commit` also saves. UCI writes to flash on commit, so `save` only
  prints a notice.
- `commit-confirm` reverts by restoring the previous config files and
  reloading services, not by rebooting. If the router reboots before you
  `confirm`, the change is reverted at boot before the network comes up.
- Keys and passwords are shown as `********` in `show`/`compare` output
  (set `CONFSH_SHOW_SECRETS=1` to see them), so output is safe to paste.
- Uncommitted changes made with the `uci` command (`/tmp/.uci`) are
  visible inside confsh. confsh warns about them and won't commit the same
  config until they're committed or reverted, or you use `commit force`.
  LuCI's pending changes are kept separate (rpcd stages them per session).

Tab completion covers config names, section types, sections, options
and known values. Other packages can extend it:

- Schema hints: `/usr/share/confsh/schema/*.json`
- Op commands: executables under `/usr/libexec/confsh/op/…`

## Testing and feedback

Most useful right now:

1. Install it and work through the
   [cheat sheet](docs/COMMANDS.md#edgeos-cheat-sheet) on a spare or
   lab router.
2. Try `commit-confirm 2`, then drop your SSH session and check that
   the change reverts. Also try rebooting before `confirm`.
3. Tell us which EdgeOS commands you reach for that are missing.
4. If you're migrating, a **sanitised** EdgeOS `config.boot` (passwords,
   keys and public IPs removed) helps design the EdgeOS-path layer.

Report problems and ideas as
[GitHub issues](https://github.com/halcycon/confsh/issues). Include
`show version`, the commands you ran, and the output.

## Development

```sh
tests/run.sh            # all tests, in the official openwrt/rootfs container
tests/run.sh t-archive  # one test
```

Needs podman or docker. See [AGENTS.md](AGENTS.md) for repo conventions.

## License

MIT. See [LICENSE](LICENSE).
