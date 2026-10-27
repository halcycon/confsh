# SPDX-License-Identifier: MIT
# WireGuard/wireless/firewall/NAT status commands and secret masking.
. /src/tests/lib.sh

export PATH="/src/tests/stubs:$PATH"
printf '%s\n' '1999999999 aa:bb:cc:00:11:22 192.168.1.50 laptop-adam *' > /tmp/dhcp.leases

cs <<'EOF' || fail "setup failed"
configure
set network interface wg0 proto wireguard
set network interface wg0 private_key SERVERPRIVATEKEY=
set network interface wg0 listen_port 51820
set network interface wg0 addresses 10.0.0.1/24
set network wireguard_wg0 laptop public_key LAPTOPPUBKEY=
set network wireguard_wg0 laptop description "Adam laptop"
set network wireguard_wg0 laptop preshared_key PSKSECRET=
set network wireguard_wg0 laptop allowed_ips 10.0.0.2/32
set firewall redirect nas_https name NAS-HTTPS
set firewall redirect nas_https src wan
set firewall redirect nas_https proto tcp
set firewall redirect nas_https src_dport 443
set firewall redirect nas_https dest lan
set firewall redirect nas_https dest_ip 192.168.1.10
set firewall forwarding lan_wan src lan
set firewall forwarding lan_wan dest wan
commit
EOF

out=$(confsh show interfaces wireguard)
contains "$out" "interface: wg0"
contains "$out" "peer: Adam laptop  [network wireguard_wg0 laptop]"
contains "$out" "latest handshake: 1m 5s ago"
contains "$out" "transfer: 1.20 MiB received, 3.40 MiB sent"
contains "$out" "allowed ips: 10.0.0.2/32, 192.168.50.0/24"
contains "$out" "[not in UCI config]"
contains "$out" "latest handshake: never"
not_contains "$out" "PRIVATEKEY"

out=$(confsh show interfaces wireguard wg9 2>&1) && fail "unknown wg interface must fail"
contains "$out" "'wg9' is not an active WireGuard interface"

out=$(confsh show interfaces wireless)
contains "$out" "radio0  2g    6        phy0-ap0   ap    HomeNet  lan      up     1"

out=$(confsh show interfaces wireless clients)
contains "$out" "aa:bb:cc:00:11:22"
contains "$out" "-52 dBm"
contains "$out" "144.4 Mbit/s"
contains "$out" "1h 2m 5s"
contains "$out" "laptop-adam"

out=$(confsh show firewall)
contains "$out" "Defaults: input REJECT, output ACCEPT, forward REJECT"
contains "$out" "zone @1"
contains "$out" "forwarding lan_wan  lan   wan"
contains "$out" "rule @0"

out=$(confsh show firewall forwardings)
contains "$out" "Forwardings"
not_contains "$out" "Zones"

out=$(confsh show nat rules)
contains "$out" "redirect nas_https"
contains "$out" "wan *:443"
contains "$out" "lan 192.168.1.10"
contains "$out" "Masquerading zones: wan"

# Secrets are masked in every view unless explicitly requested.
out=$(confsh show configuration network)
contains "$out" "private_key ********"
not_contains "$out" "SERVERPRIVATEKEY"
not_contains "$out" "PSKSECRET"
contains "$(confsh show configuration commands network wireguard_wg0)" "preshared_key '********'"
contains "$(CONFSH_SHOW_SECRETS=1 confsh show configuration commands network)" "SERVERPRIVATEKEY="
eq "$(uci get network.wg0.private_key)" "SERVERPRIVATEKEY="

out=$(cs <<'EOF'
configure
set wireless wifi-iface default_radio0 key "correct horse battery staple"
set wireless wifi-iface default_radio0 encryption sae
compare
_confsh_be complete set network wireguard_wg0 laptop ""
EOF
) || fail "masking script failed: $out"
contains "$out" "+key ********"
not_contains "$out" "correct horse"
contains "$out" "persistent_keepalive"

out=$(confsh show interfaces nosuch 2>&1) && fail "unknown interfaces subcommand must fail"
contains "$out" "Invalid command: show interfaces nosuch"
true
