# confsh command reference

> SPDX-License-Identifier: MIT

confsh has two modes, like EdgeOS:

- **Operational mode**: what you get when you run `confsh`.
  Prompt `root@router:~$`. Status commands (`show …`) plus normal shell
  commands.
- **Configuration mode**: entered with `configure`. Prompt shows the
  edit level:

  ```text
  [edit network interface lan]
  root@router#
  ```

Press <kbd>Tab</kbd> anywhere for completions (configs, section types,
sections, options, known values, op commands).

## Paths

Every configuration path has up to five words, following the layout of
the files in `/etc/config`:

```text
<config> <section-type> <section> <option> <value>
network  interface      lan       ipaddr   192.168.1.1
```

| Word | Meaning | Example |
|------|---------|---------|
| config | File in `/etc/config` | `network`, `firewall`, `dhcp`, `system`, `dropbear` |
| section-type | The word after `config` in the file | `interface`, `zone`, `rule`, `host` |
| section | Section name, or `@N` = the N-th section of that type (from 0) | `lan`, `@1` |
| option | Option name | `ipaddr`, `masq`, `dest_port` |
| value | One value; quote it if it contains spaces | `10.0.0.1`, `"Allow SSH"` |

`uci show <config>` prints the same structure (`firewall.@zone[1].masq`
is `firewall zone @1 masq` in confsh).

**Sections.** Many OpenWrt sections have no name (firewall zones and
rules, `dnsmasq`, `system`). Address those as `@N`. `@N` counts named
sections too, exactly like `uci`'s `@type[N]`. When `set` mentions a
section name that does not exist, confsh creates a **named** section of
that type, so new firewall rules, hosts, routes and so on get stable
names:

```text
set firewall rule allow_ssh dest_port 22     # creates rule 'allow_ssh'
```

Section names may contain letters, digits and `_`.

**Lists.** Options that hold several values (`dns`, `server`, zone
`network`, bridge `ports`, …) behave like EdgeOS multi-value nodes:
each `set` adds one value, `delete … <value>` removes one value, and
`delete … <option>` removes them all. confsh treats an option as a list
when it already is one, or when its schema hint says so.

**Edit level.** The path you `edit` into is prepended to every command,
so these are equivalent:

```text
set network interface lan ipaddr 10.0.0.1

edit network interface lan
set ipaddr 10.0.0.1
```

## Configuration mode

| Command | What it does |
|---------|--------------|
| `set <path> <value>` | Set an option, add a list value, or create a named section (`set <config> <type> <name>`). A boolean option with no value is set to `1` |
| `delete <path> [<value>]` | Remove one list value, an option, a section, or every section of a type (`delete firewall rule`). Deleting a whole config is refused |
| `edit <path>` | Move the edit level down to a config, type or section. Creates a missing named section |
| `up` / `top` | Move the edit level up one word / to the top |
| `show [<path>]` | Show the working configuration at the current level. Changed lines are marked: `+` added, `-` removed, `>` changed |
| `compare` | Show only your uncommitted changes (`[edit …]` headers with `-`/`+` lines) |
| `discard` | Throw away all uncommitted changes |
| `commit [force] [comment <text>]` | Write the changes to `/etc/config`, reload the affected services, and archive a revision |
| `commit-confirm [<minutes>] [comment <text>]` | Commit, then revert automatically unless you type `confirm` within `<minutes>` (default 10) |
| `confirm` | Keep a pending `commit-confirm` |
| `rollback <N>` | Restore revision N from `show system commit` and reload (asks first) |
| `save` | Prints a notice: `commit` already saved to flash |
| `run <op command>` | Run an operational command, e.g. `run show interfaces` |
| `exit [discard]` | Leave configuration mode. Refused while changes are uncommitted unless you add `discard` |

Notes:

- Changes are private to your session until `commit`. LuCI's pending
  changes are kept separate.
- `commit` refuses when a config you changed was also changed outside
  the session since `configure` (LuCI, another session, a script), or
  when the `uci` command has uncommitted changes to it in `/tmp/.uci`.
  Sort those out first, or use `commit force`.
- `commit-confirm` survives losing your SSH session. If the router
  reboots before you `confirm`, the change is reverted at boot before the
  network starts.
- While a `commit-confirm` is pending, further commits are refused.

## Operational mode

| Command | Shows |
|---------|-------|
| `configure` | Enter configuration mode |
| `show configuration [<config> [<type> [<section>]]]` | Committed configuration as a tree |
| `show configuration commands [<config> …]` | Committed configuration as `set` commands |
| `show system commit` | Archived revisions (newest is 0), with user and comment |
| `show interfaces` | Logical interfaces: device, protocol, state, addresses |
| `show ip route` | IPv4 routing table (extra args go to `ip route show`) |
| `show arp` | IPv4 neighbour table |
| `show dhcp leases` | dnsmasq DHCPv4 leases |
| `show nat translations` | Connection tracking table (`conntrack -L` if installed) |
| `show version` | Firmware, target, board, kernel, uptime |

`show` on its own lists what's available. Other packages can add
commands (see [Extending](#extending)).

## Running commands non-interactively

```sh
confsh show interfaces                    # one operational command

confsh -s <<'EOF'                         # a script; stops at the first error
configure
set system system @0 hostname gw1
commit comment "rename"
EOF
```

In `-s` mode, a failing command stops the script and uncommitted changes
are dropped. `rollback` doesn't ask for confirmation there.

## EdgeOS cheat sheet

The same intent expressed in confsh on a stock OpenWrt config. Every
line here is exercised by `tests/t-cheatsheet.sh`.

**System**

| EdgeOS | confsh |
|--------|--------|
| `set system host-name gw1` | `set system system @0 hostname gw1` |
| `set system time-zone Europe/London` | `set system system @0 zonename Europe/London`<br>`set system system @0 timezone GMT0BST,M3.5.0/1,M10.5.0` |
| `set system ntp server 0.uk.pool.ntp.org` | `set system timeserver ntp server 0.uk.pool.ntp.org` |
| `set service ssh port 2222` | `set dropbear dropbear @0 Port 2222` |
| `set system offload ipv4 forwarding enable` | `set firewall defaults @0 flow_offloading 1`<br>`set firewall defaults @0 flow_offloading_hw 1` |

`zonename` is the label LuCI shows; `timezone` is the POSIX TZ string
the system actually uses. LuCI sets both, so set both.

**Interfaces.** OpenWrt splits EdgeOS's `interfaces ethernet ethX`
into a *device* (port, bridge, VLAN) and a logical *interface* (`lan`,
`wan`) that carries the addressing.

| EdgeOS | confsh |
|--------|--------|
| `set interfaces ethernet eth1 address 192.168.10.1/24` | `set network interface lan ipaddr 192.168.10.1`<br>`set network interface lan netmask 255.255.255.0` |
| `set interfaces ethernet eth0 address dhcp` | `set network interface wan proto dhcp` |
| `set interfaces ethernet eth1 vif 10 address 192.168.20.1/24` | `set network device vlan10 type 8021q`<br>`set network device vlan10 ifname eth1`<br>`set network device vlan10 vid 10`<br>`set network device vlan10 name eth1.10`<br>`set network interface iot device eth1.10`<br>`set network interface iot proto static`<br>`set network interface iot ipaddr 192.168.20.1`<br>`set network interface iot netmask 255.255.255.0`<br>`set firewall zone @0 network iot` |

The VLAN example is for a plain NIC. On switches with DSA bridge VLANs
the device side uses `bridge-vlan` sections instead.

**DHCP and DNS**

| EdgeOS | confsh |
|--------|--------|
| `set service dhcp-server shared-network-name LAN subnet 192.168.10.0/24 start 192.168.10.100 stop 192.168.10.199` | `set dhcp dhcp lan start 100`<br>`set dhcp dhcp lan limit 100` |
| `… subnet … lease 43200` | `set dhcp dhcp lan leasetime 12h` |
| `… static-mapping printer mac-address 00:11:22:33:44:55`<br>`… static-mapping printer ip-address 192.168.10.20` | `set dhcp host printer name printer`<br>`set dhcp host printer mac 00:11:22:33:44:55`<br>`set dhcp host printer ip 192.168.10.20` |
| `set system name-server 1.1.1.1` | `set dhcp dnsmasq @0 server 1.1.1.1` |

OpenWrt's DHCP range is `start` (offset in the subnet) plus `limit`
(number of addresses), not first and last addresses.

**Routing, NAT, firewall**

| EdgeOS | confsh |
|--------|--------|
| `set protocols static route 10.0.0.0/8 next-hop 192.168.10.254` | `set network route corp interface lan`<br>`set network route corp target 10.0.0.0`<br>`set network route corp netmask 255.0.0.0`<br>`set network route corp gateway 192.168.10.254` |
| `set service nat rule 5010 outbound-interface eth0`<br>`set service nat rule 5010 type masquerade` | `set firewall zone @1 masq 1` (zone `@1` is `wan` on a stock config) |
| `set port-forward rule 1 original-port 443`<br>`set port-forward rule 1 forward-to address 192.168.10.10` | `set firewall redirect nas_https name NAS-HTTPS`<br>`set firewall redirect nas_https src wan`<br>`set firewall redirect nas_https proto tcp`<br>`set firewall redirect nas_https src_dport 443`<br>`set firewall redirect nas_https dest lan`<br>`set firewall redirect nas_https dest_ip 192.168.10.10`<br>`set firewall redirect nas_https dest_port 443`<br>`set firewall redirect nas_https target DNAT` |
| `set firewall name WAN_LOCAL rule 20 action accept`<br>`… destination port 22`<br>`… protocol tcp` | `set firewall rule allow_ssh name Allow-SSH-WAN`<br>`set firewall rule allow_ssh src wan`<br>`set firewall rule allow_ssh proto tcp`<br>`set firewall rule allow_ssh dest_port 22`<br>`set firewall rule allow_ssh target ACCEPT` |

OpenWrt's firewall is zone-based: rules say which zone traffic comes
from (`src`) and goes to (`dest`, omitted for traffic to the router
itself) instead of attaching named rule sets to interfaces.

**Operational**

| EdgeOS | confsh |
|--------|--------|
| `show interfaces` | `show interfaces` |
| `show ip route` | `show ip route` |
| `show arp` | `show arp` |
| `show dhcp leases` | `show dhcp leases` |
| `show nat translations` | `show nat translations` |
| `show configuration` / `show configuration commands` | same |
| `show system commit` | same |
| `show version` | same |

## Not yet supported

- EdgeOS-style paths (`interfaces ethernet eth0 …`) and importing an
  EdgeOS `config.boot`. Planned; real configs from testers will shape the
  mapping.
- `load`, `merge`, `save <file>`, `rename`, `copy`, `comment` nodes.
- `?` for inline help (use <kbd>Tab</kbd>).
- Per-user permissions: confsh runs as the logged-in user (normally
  root).

## Extending

Packages can add to confsh without depending on it.

**Op commands.** Executables under `/usr/libexec/confsh/op/`. The path
is the command: `/usr/libexec/confsh/op/show/offload` becomes
`show offload`. Remaining words are passed as arguments. A directory can
contain an executable `.run` to make the directory itself runnable.

**Schema hints.** JSON files in `/usr/share/confsh/schema/`, merged
together, used for completion and list detection:

```json
{
  "myapp": {
    "instance": {
      "enabled": { "type": "bool" },
      "mode":    { "values": [ "fast", "safe" ], "strict": true },
      "peer":    { "list": true }
    }
  }
}
```

`values` are completion suggestions; with `"strict": true` they are also
enforced. Options not in any hint are always accepted.
