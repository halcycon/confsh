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

Status: **v0.1, early**. Design and roadmap: [docs/DESIGN.md](docs/DESIGN.md).

## Install

Requires OpenWrt 24.10+ (any architecture; the package is `PKGARCH:=all`).
Pulls in `bash`, `ucode` and the `fs`/`uci`/`ubus` ucode modules.

- **Feed**: add to `feeds.conf`:
  `src-git confsh https://github.com/halcycon/confsh.git`, then
  `./scripts/feeds update confsh && ./scripts/feeds install confsh`, and
  select *Utilities → Shells → confsh*.
- **Prebuilt**: install the `.apk` (25.12+) or `.ipk` (24.10) from
  Releases.

Run `confsh`, or make it the login shell for an account.

## Commands

Paths follow the UCI file layout:
`<config> <section-type> <section> <option> <value>`, for example
`set firewall zone @1 masq 1` or `set network interface lan ipaddr 10.0.0.1`.
Anonymous sections are `@N` (as in `uci show`). New sections are always
created with a name.

| Mode | Commands |
|------|----------|
| Operational | `configure`, `show configuration [commands]`, `show system commit`, `show interfaces`, `show ip route`, `show arp`, `show dhcp leases`, `show nat translations`, `show version` |
| Configuration | `set`, `delete`, `edit`, `up`, `top`, `show`, `compare`, `discard`, `commit [comment …]`, `commit-confirm [min]`, `confirm`, `rollback N`, `run <op command>`, `exit [discard]` |

Things that differ from EdgeOS:

- `commit` also saves. UCI writes to flash on commit, so `save` only
  prints a notice.
- `commit-confirm` reverts by restoring the previous config files and
  reloading services, not by rebooting. If the router reboots before you
  `confirm`, the change is reverted at boot before the network comes up.
- Uncommitted changes made with the `uci` command (`/tmp/.uci`) are
  visible inside confsh. confsh warns about them and won't commit the same
  config until they're committed or reverted, or you use `commit force`.
  LuCI's pending changes are kept separate (rpcd stages them per session).

Tab completion covers config names, section types, sections, options
and known values. Other packages can extend it:

- Schema hints: `/usr/share/confsh/schema/*.json`
- Op commands: executables under `/usr/libexec/confsh/op/…`

## Development

```sh
tests/run.sh            # all tests, in the official openwrt/rootfs container
tests/run.sh t-archive  # one test
```

Needs podman or docker. See [AGENTS.md](AGENTS.md) for repo conventions.

## License

GPL-2.0-only. See [LICENSE](LICENSE).
