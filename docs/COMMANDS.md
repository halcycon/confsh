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

## EdgeOS paths

Some areas also accept EdgeOS's own syntax. Both forms change the same
UCI config, so you can mix them freely. Supported so far:

**`port-forward`** (stored as firewall redirects named `pf_<rule>`):

```text
set port-forward wan-interface eth0          # device, interface or zone; default zone wan
set port-forward lan-interface eth1          # default zone lan
set port-forward hairpin-nat enable          # reflection on every pf_ rule
set port-forward auto-firewall enable        # accepted; fw4 always allows DNAT'd traffic
set port-forward rule 1 description "NAS HTTPS"
set port-forward rule 1 original-port 443    # also ranges: 8000-8010
set port-forward rule 1 protocol tcp         # tcp | udp | tcp_udp (default)
set port-forward rule 1 forward-to address 192.168.1.10
set port-forward rule 1 forward-to port 8443 # defaults to original-port
delete port-forward rule 1
```

`show port-forward` (configuration mode) and
`show configuration [commands] port-forward` (operational mode) display
it in EdgeOS form. `edit port-forward rule 1` works as on EdgeOS. Port
forwards created in LuCI don't appear here, but they are still listed by
`show nat rules` and editable as `firewall redirect …`.

Interface names map to firewall zones: `wan-interface eth0` uses the
zone containing the network interface whose device is `eth0`.

**`interfaces openvpn`** (site-to-site, static key) → `config openvpn
<name>` in `/etc/config/openvpn`:

```text
set interfaces openvpn vtun0 mode site-to-site
set interfaces openvpn vtun0 local-address 10.9.8.1
set interfaces openvpn vtun0 remote-address 10.9.8.2
set interfaces openvpn vtun0 remote-host 203.0.113.9
set interfaces openvpn vtun0 shared-secret-key-file /etc/openvpn/s2s.key
set interfaces openvpn vtun0 encryption aes256
set interfaces openvpn vtun0 hash sha256
```

`local-address`/`remote-address` become the openvpn `ifconfig` pair;
`encryption`/`hash` map to `cipher`/`auth`; the device is named after the
instance (`dev vtun0`) for predictable firewall zones. Needs the openvpn
package (which provides `/etc/config/openvpn`). v1 covers site-to-site with
a static key; client/server/TLS are not yet exposed. Note OpenVPN 2.6
deprecates static-key mode and 2.7 removes it — prefer TLS for new tunnels.

**`interfaces tunnel`** (GRE / GRE-bridge / IPIP) → a `network` tunnel
interface plus a companion `<name>_net` static interface for the
tunnel's own L3 address:

```text
set interfaces tunnel tun0 encapsulation gre
set interfaces tunnel tun0 local-ip 192.0.2.1
set interfaces tunnel tun0 remote-ip 203.0.113.1
set interfaces tunnel tun0 address 10.0.0.1/30
set interfaces tunnel tun0 mtu 1400
```

`encapsulation gre|gre-bridge|ipip` maps to `proto gre|gretap|ipip`;
`local-ip`/`remote-ip` are the tunnel endpoints (`ipaddr`/`peeraddr`),
and `address` is assigned via the companion interface (`device '@tun0'`).

Next up: `service nat` and `interfaces ethernet … vif` (confsh), and
`interfaces wireguard` and `vpn ipsec` (contributed). Module authors:
see [DIALECTS.md](DIALECTS.md).

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
| `show interfaces wireguard [<interface>]` | Like `wg show`, plus each peer's description and its confsh path; handshake age and transfer |
| `show interfaces wireless` | Radios and SSIDs: band, live channel, mode, network, state, client count |
| `show interfaces wireless clients` | Associated stations: signal, rates, connected time, DHCP IP and hostname |
| `show firewall [zones\|forwardings\|rules]` | Firewall defaults (including offload), zones, forwardings, rules |
| `show nat rules` | Port forwards / DNAT, SNAT rules, masquerading zones |
| `show ip route` | IPv4 routing table (extra args go to `ip route show`) |
| `show arp` | IPv4 neighbour table |
| `show dhcp leases` | dnsmasq DHCPv4 leases |
| `show nat translations` | Connection tracking table (`conntrack -L` if installed) |
| `show version` | Firmware, target, board, kernel, uptime |

The firewall, NAT and WireGuard views include a **Section** column or
tag (for example `rule @3` or `[network wireguard_wg0 laptop]`). That's
the path to use with `set` and `delete`, which helps with sections
LuCI created without names.

`show interfaces wireguard` needs `wireguard-tools` (installed with
WireGuard support). Live wireless data needs `rpcd-mod-iwinfo`
(installed with LuCI).

### Secrets

Private keys, pre-shared keys and passwords (WireGuard `private_key` /
`preshared_key`, Wi-Fi `key`, PPPoE `password`, …) are shown as
`********` in `show`, `compare` and `show configuration [commands]`, so
output is safe to paste into an issue. To see them, run with
`CONFSH_SHOW_SECRETS=1`, e.g.
`CONFSH_SHOW_SECRETS=1 confsh show configuration commands`. `set`
stores what you type; nothing is hashed.

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

The VLAN example above is for a plain NIC (an 802.1Q device on top of
`eth1`). Routers with a built-in switch (DSA: ports named `lan1`,
`lan2`, … in a `br-lan` bridge) use `bridge-vlan` sections instead. See
[VLANs on a switch](#vlans-on-a-switch-dsa) below.

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
| `set port-forward rule 1 original-port 443`<br>`set port-forward rule 1 forward-to address 192.168.10.10` | Same EdgeOS syntax works as-is (see [EdgeOS paths](#edgeos-paths)). In UCI terms:<br>`set firewall redirect nas_https name NAS-HTTPS`<br>`set firewall redirect nas_https src wan`<br>`set firewall redirect nas_https proto tcp`<br>`set firewall redirect nas_https src_dport 443`<br>`set firewall redirect nas_https dest lan`<br>`set firewall redirect nas_https dest_ip 192.168.10.10`<br>`set firewall redirect nas_https dest_port 443`<br>`set firewall redirect nas_https target DNAT` |
| `set firewall name WAN_LOCAL rule 20 action accept`<br>`… destination port 22`<br>`… protocol tcp` | `set firewall rule allow_ssh name Allow-SSH-WAN`<br>`set firewall rule allow_ssh src wan`<br>`set firewall rule allow_ssh proto tcp`<br>`set firewall rule allow_ssh dest_port 22`<br>`set firewall rule allow_ssh target ACCEPT` |

OpenWrt's firewall is zone-based: rules say which zone traffic comes
from (`src`) and goes to (`dest`, omitted for traffic to the router
itself) instead of attaching named rule sets to interfaces.

**WireGuard.** The interface is a `network interface` with
`proto wireguard`. Each peer is its own section of type
`wireguard_<interface>`, so peers of `wg0` are `network wireguard_wg0
<name>`. Give peers a name when you create them. Peers created in LuCI
have no name: `show interfaces wireguard` prints the `@N` path for each.

| EdgeOS | confsh |
|--------|--------|
| `set interfaces wireguard wg0 address 10.0.0.1/24` | `set network interface wg0 proto wireguard`<br>`set network interface wg0 addresses 10.0.0.1/24` |
| `set interfaces wireguard wg0 listen-port 51820` | `set network interface wg0 listen_port 51820` |
| `set interfaces wireguard wg0 private-key /config/auth/wg.key` | `set network interface wg0 private_key SERVER_PRIVATE_KEY=` (the key itself, not a file) |
| `set interfaces wireguard wg0 peer LAPTOP_PUBLIC_KEY= allowed-ips 10.0.0.2/32`<br>`… peer LAPTOP_PUBLIC_KEY= description "Adam laptop"` | `set network wireguard_wg0 laptop public_key LAPTOP_PUBLIC_KEY=`<br>`set network wireguard_wg0 laptop description "Adam laptop"`<br>`set network wireguard_wg0 laptop allowed_ips 10.0.0.2/32` |
| `set interfaces wireguard wg0 route-allowed-ips true` | per peer: `set network wireguard_wg0 laptop route_allowed_ips 1` |
| `… peer SITE_B_PUBLIC_KEY= endpoint vpn.example.com:51820`<br>`… peer SITE_B_PUBLIC_KEY= persistent-keepalive 25`<br>`… peer SITE_B_PUBLIC_KEY= allowed-ips 192.168.50.0/24` | `set network wireguard_wg0 site_b public_key SITE_B_PUBLIC_KEY=`<br>`set network wireguard_wg0 site_b endpoint_host vpn.example.com`<br>`set network wireguard_wg0 site_b endpoint_port 51820`<br>`set network wireguard_wg0 site_b persistent_keepalive 25`<br>`set network wireguard_wg0 site_b allowed_ips 10.0.0.3/32`<br>`set network wireguard_wg0 site_b allowed_ips 192.168.50.0/24`<br>`set network wireguard_wg0 site_b route_allowed_ips 1` |
| `delete … peer SITE_B_PUBLIC_KEY= allowed-ips 192.168.50.0/24` | `delete network wireguard_wg0 site_b allowed_ips 192.168.50.0/24` |
| `delete interfaces wireguard wg0 peer LAPTOP_PUBLIC_KEY=` | `delete network wireguard_wg0 laptop` |
| firewall: allow UDP 51820 to the router | `set firewall rule wg_in name Allow-WireGuard`<br>`set firewall rule wg_in src wan`<br>`set firewall rule wg_in proto udp`<br>`set firewall rule wg_in dest_port 51820`<br>`set firewall rule wg_in target ACCEPT` |
| treat tunnel traffic like LAN | `set firewall zone @0 network wg0` (zone `@0` is `lan`) |
| `show interfaces wireguard wg0` / `sudo wg` | `show interfaces wireguard wg0` |

**Zones and forwardings: a guest network.** EdgeOS has no zones; this
is the OpenWrt way to get "guests reach the internet but not the LAN".
A forwarding allows traffic from one zone to another; without one,
the zone's `forward` policy applies.

| Step | confsh |
|------|--------|
| Interface | `set network interface guest proto static`<br>`set network interface guest ipaddr 192.168.30.1`<br>`set network interface guest netmask 255.255.255.0` |
| DHCP | `set dhcp dhcp guest interface guest`<br>`set dhcp dhcp guest start 100`<br>`set dhcp dhcp guest limit 50` |
| Zone | `set firewall zone guest name guest`<br>`set firewall zone guest network guest`<br>`set firewall zone guest input REJECT`<br>`set firewall zone guest output ACCEPT`<br>`set firewall zone guest forward REJECT` |
| Guest → internet | `set firewall forwarding guest_wan src guest`<br>`set firewall forwarding guest_wan dest wan` |
| Allow DNS and DHCP to the router | `set firewall rule guest_dns name Guest-DNS`<br>`set firewall rule guest_dns src guest`<br>`set firewall rule guest_dns dest_port 53`<br>`set firewall rule guest_dns target ACCEPT`<br>`set firewall rule guest_dhcp name Guest-DHCP`<br>`set firewall rule guest_dhcp src guest`<br>`set firewall rule guest_dhcp proto udp`<br>`set firewall rule guest_dhcp dest_port 67`<br>`set firewall rule guest_dhcp target ACCEPT` |

Check the result with `show firewall`.

**VLANs on a switch (DSA).** On routers with built-in switch ports,
VLANs are `bridge-vlan` sections on `br-lan`, and each VLAN becomes a
device `br-lan.<vid>`. Port flags: `:t` tagged, `:u` untagged, `*`
primary VLAN (PVID). **Quote values containing `*`** so the shell
doesn't expand them. Once any `bridge-vlan` exists, the existing LAN
must also have one (usually VLAN 1) and use `br-lan.1`, so do all of
this in one commit, ideally with `commit-confirm`:

| Step | confsh |
|------|--------|
| VLAN 1 (existing LAN, untagged) | `set network bridge-vlan lan_vlan1 device br-lan`<br>`set network bridge-vlan lan_vlan1 vlan 1`<br>`set network bridge-vlan lan_vlan1 ports 'eth0:u*'`<br>`set network bridge-vlan lan_vlan1 ports 'eth1:u*'`<br>`set network interface lan device br-lan.1` |
| VLAN 20, tagged on eth1 | `set network bridge-vlan lan_vlan20 device br-lan`<br>`set network bridge-vlan lan_vlan20 vlan 20`<br>`set network bridge-vlan lan_vlan20 ports eth1:t`<br>`set network interface cams device br-lan.20`<br>`set network interface cams proto static`<br>`set network interface cams ipaddr 192.168.40.1`<br>`set network interface cams netmask 255.255.255.0` |

Use your router's port names (`lan1`, `lan2`, … on most DSA devices).
Then add a firewall zone for the new interface as in the guest example.

**Wireless.** EdgeRouters have no Wi-Fi, so there's no EdgeOS
equivalent; this is OpenWrt's own model. A `wifi-device` is a radio; a
`wifi-iface` is an SSID on a radio, attached to a network.

| Task | confsh |
|------|--------|
| Enable a radio | `set wireless wifi-device radio0 disabled 0`<br>`set wireless wifi-device radio0 country GB`<br>`set wireless wifi-device radio0 channel 6` |
| Main SSID (WPA2/WPA3) | `set wireless wifi-iface default_radio0 ssid HomeNet`<br>`set wireless wifi-iface default_radio0 encryption sae-mixed`<br>`set wireless wifi-iface default_radio0 key "correct horse battery staple"` |
| Guest SSID on the guest network | `set wireless wifi-iface guest_radio0 device radio0`<br>`set wireless wifi-iface guest_radio0 mode ap`<br>`set wireless wifi-iface guest_radio0 network guest`<br>`set wireless wifi-iface guest_radio0 ssid Guest`<br>`set wireless wifi-iface guest_radio0 encryption psk2`<br>`set wireless wifi-iface guest_radio0 key "guest password"`<br>`set wireless wifi-iface guest_radio0 isolate 1` |
| Status | `show interfaces wireless`, `show interfaces wireless clients` |

**Operational**

| EdgeOS | confsh |
|--------|--------|
| `show interfaces` | `show interfaces` |
| `show ip route` | `show ip route` |
| `show arp` | `show arp` |
| `show dhcp leases` | `show dhcp leases` |
| `show nat translations` | `show nat translations` |
| `show nat rules` / `show port-forward` | `show nat rules` |
| `show firewall` | `show firewall` (config view; no per-rule counters yet) |
| `show configuration` / `show configuration commands` | same |
| `show system commit` | same |
| `show version` | same |

## Not yet supported

- EdgeOS-style paths beyond `port-forward`, `interfaces openvpn` and
  `interfaces tunnel` (see [EdgeOS paths](#edgeos-paths)), and importing
  an EdgeOS `config.boot`.
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
enforced. `"secret": true` masks the value in all output. A section type
ending in `*` matches by prefix (`"wireguard_*"` covers `wireguard_wg0`,
`wireguard_wg1`, …). Options not in any hint are always accepted.
