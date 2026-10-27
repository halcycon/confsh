# SPDX-License-Identifier: MIT
# EdgeOS `interfaces wireguard` dialect -> UCI network wireguard interface + peers.
. /src/tests/lib.sh

K1="FeK6ZuPJm4863djMSGkYsmKn3KR4LdZ1AxJrCkoUrcs="
K2="t3MVDt25/Awbp0s80QpVOGHTOMNWcQN8n7wn6h8W7rc="
PID1="peer_$(printf '%s' "$K1" | tr -cd 'A-Za-z0-9')"
PID2="peer_$(printf '%s' "$K2" | tr -cd 'A-Za-z0-9')"

out=$(cs <<EOF
configure
set interfaces wireguard wg0 private-key $K1
set interfaces wireguard wg0 listen-port 51820
set interfaces wireguard wg0 address 10.0.0.1/24
set interfaces wireguard wg0 peer $K1 allowed-ips 10.0.0.2/32
set interfaces wireguard wg0 peer $K1 allowed-ips 10.0.0.3/32
set interfaces wireguard wg0 peer $K1 endpoint demo.wg.example:51820
set interfaces wireguard wg0 peer $K1 persistent-keepalive 25
set interfaces wireguard wg0 peer $K1 route-allowed-ips true
edit interfaces wireguard wg0 peer $K2
set description "roaming phone"
set allowed-ips 10.0.0.4/32
set disable
top
show interfaces wireguard wg0
commit
EOF
) || fail "wireguard script failed: $out"

contains "$out" "+address 10.0.0.1/24"
contains "$out" "+peer $K1 {"
contains "$out" "+    allowed-ips 10.0.0.2/32"
contains "$out" "+    endpoint demo.wg.example:51820"
contains "$out" "+    route-allowed-ips true"
contains "$out" "+private-key ********"

eq "$(uci get network.wg0)" "interface"
eq "$(uci get network.wg0.proto)" "wireguard"
eq "$(uci get network.wg0.private_key)" "$K1"
eq "$(uci get network.wg0.listen_port)" "51820"
eq "$(uci get network.wg0.addresses)" "10.0.0.1/24"
eq "$(uci get "network.$PID1")" "wireguard_wg0"
eq "$(uci get "network.$PID1.public_key")" "$K1"
eq "$(uci get "network.$PID1.allowed_ips")" "10.0.0.2/32 10.0.0.3/32"
eq "$(uci get "network.$PID1.endpoint_host")" "demo.wg.example"
eq "$(uci get "network.$PID1.endpoint_port")" "51820"
eq "$(uci get "network.$PID1.persistent_keepalive")" "25"
eq "$(uci get "network.$PID1.route_allowed_ips")" "1"
eq "$(uci get "network.$PID2.public_key")" "$K2"
eq "$(uci get "network.$PID2.description")" "roaming phone"
eq "$(uci get "network.$PID2.disabled")" "1"

out=$(confsh show configuration interfaces wireguard wg0)
contains "$out" "peer $K1 {"
contains "$out" "    allowed-ips 10.0.0.3/32"
contains "$out" "    persistent-keepalive 25"
contains "$out" "private-key ********"
contains "$out" 'description "roaming phone"'

out=$(confsh show configuration commands interfaces wireguard wg0)
contains "$out" "set interfaces wireguard wg0 peer $K1 allowed-ips '10.0.0.2/32'"
contains "$out" "set interfaces wireguard wg0 peer $K1 endpoint 'demo.wg.example:51820'"
contains "$out" "set interfaces wireguard wg0 peer $K2 disable"
contains "$out" "set interfaces wireguard wg0 private-key '********'"

# modify a scalar: '>' marker and the real UCI edit header
out=$(cs <<EOF
configure
set interfaces wireguard wg0 listen-port 51821
show interfaces wireguard wg0
compare
EOF
) || fail "modify failed: $out"
contains "$out" ">listen-port 51821"
contains "$out" "[edit network interface wg0]"

# validation
for bad in "wg0 peer notabase64key allowed-ips 10.0.0.9/32" \
	"wg0 listen-port 999999" \
	"wg0 mtu abc" \
	"wg0 peer $K1 allowed-ips 300.1" \
	"wg0 bogus x"; do
	out=$(printf 'configure\nset interfaces wireguard %s\n' "$bad" | confsh -s 2>&1) && fail "'$bad' must fail"
	contains "$out" "failed"
done

# completion
out=$(cs <<EOF
configure
_confsh_be complete set ""
echo --roots
_confsh_be complete set interfaces ""
echo --iface
_confsh_be complete set interfaces wireguard ""
echo --tag
_confsh_be complete set interfaces wireguard wg0 ""
echo --peer
_confsh_be complete set interfaces wireguard wg0 peer ""
echo --rai
_confsh_be complete set interfaces wireguard wg0 peer $K1 route-allowed-ips ""
EOF
) || fail "completion failed: $out"
contains "$out" "interfaces"
contains "$(printf '%s\n' "$out" | sed -n '/--roots/,/--iface/p')" "wireguard"
contains "$(printf '%s\n' "$out" | sed -n '/--iface/,/--tag/p')" "wg0"
contains "$(printf '%s\n' "$out" | sed -n '/--tag/,/--peer/p')" "private-key"
contains "$(printf '%s\n' "$out" | sed -n '/--peer/,/--rai/p')" "$K1"
contains "$(printf '%s\n' "$out" | sed -n '/--rai/,$p')" "true"

# deletes: one allowed-ip, a whole peer, then the whole interface
cs <<EOF || fail "deletes failed"
configure
delete interfaces wireguard wg0 peer $K1 allowed-ips 10.0.0.3/32
delete interfaces wireguard wg0 peer $K2
commit
EOF
eq "$(uci get "network.$PID1.allowed_ips")" "10.0.0.2/32"
uci -q get "network.$PID2" && fail "$PID2 should be gone"

cs <<EOF || fail "delete interface failed"
configure
delete interfaces wireguard wg0
commit
EOF
uci -q get network.wg0 && fail "wg0 should be gone"
uci -q get "network.$PID1" && fail "$PID1 should be gone"
contains "$(confsh show configuration interfaces wireguard wg0)" "Configuration under specified path is empty"
