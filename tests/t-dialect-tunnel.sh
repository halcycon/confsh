# SPDX-License-Identifier: MIT
# EdgeOS `interfaces tunnel` dialect -> OpenWrt network gre/gretap/ipip tunnels.
. /src/tests/lib.sh

out=$(cs <<'EOF'
configure
set interfaces tunnel tun0 encapsulation gre
set interfaces tunnel tun0 local-ip 192.0.2.1
set interfaces tunnel tun0 remote-ip 203.0.113.1
set interfaces tunnel tun0 address 10.0.0.1/30
set interfaces tunnel tun0 mtu 1400
set interfaces tunnel tun0 ttl 64
show interfaces tunnel tun0
commit
EOF
) || fail "tunnel script failed: $out"

contains "$out" "+encapsulation gre"
contains "$out" "local-ip 192.0.2.1"
contains "$out" "address 10.0.0.1/30"

eq "$(uci get network.tun0)" "interface"
eq "$(uci get network.tun0.proto)" "gre"
eq "$(uci get network.tun0.ipaddr)" "192.0.2.1"
eq "$(uci get network.tun0.peeraddr)" "203.0.113.1"
eq "$(uci get network.tun0.mtu)" "1400"
eq "$(uci get network.tun0.ttl)" "64"
eq "$(uci get network.tun0_net)" "interface"
eq "$(uci get network.tun0_net.proto)" "static"
eq "$(uci get network.tun0_net.device)" "@tun0"
eq "$(uci get network.tun0_net.ipaddr)" "10.0.0.1"
eq "$(uci get network.tun0_net.netmask)" "255.255.255.252"

cs <<'EOF' || fail "gretap failed"
configure
set interfaces tunnel tun1 encapsulation gre-bridge
set interfaces tunnel tun1 local-ip 192.0.2.3
commit
EOF
eq "$(uci get network.tun1.proto)" "gretap"

out=$(confsh show configuration commands interfaces tunnel tun0)
contains "$out" "set interfaces tunnel tun0 encapsulation 'gre'"
contains "$out" "set interfaces tunnel tun0 address '10.0.0.1/30'"
contains "$out" "set interfaces tunnel tun0 remote-ip '203.0.113.1'"

for bad in "tun0 encapsulation bogus" "tun0 local-ip notanip" "tun0 address 10.0.0.1" \
	"tun0 address 2001:db8::1/64" "tun0 mtu abc"; do
	out=$(printf 'configure\nset interfaces tunnel %s\n' "$bad" | confsh -s 2>&1) && fail "'$bad' must fail"
	contains "$out" "failed"
done

# must refuse hijacking an existing non-tunnel interface (the stock 'lan')
out=$(printf 'configure\nset interfaces tunnel lan encapsulation gre\n' | confsh -s 2>&1) && fail "clobbering lan must fail"
contains "$out" "not a tunnel"
eq "$(uci get network.lan.proto)" "static"

# deleting encapsulation resets proto to gre (never leaves no protocol)
cs <<'EOF' || fail "reset proto failed"
configure
delete interfaces tunnel tun1 encapsulation
commit
EOF
eq "$(uci get network.tun1.proto)" "gre"

out=$(cs <<'EOF'
configure
_confsh_be complete set interfaces tunnel ""
echo --name
_confsh_be complete set interfaces tunnel tun0 ""
echo --opts
_confsh_be complete set interfaces tunnel tun0 encapsulation ""
echo --encap
EOF
) || fail "completion failed: $out"
contains "$out" "tun0"
contains "$(printf '%s\n' "$out" | sed -n '/--name/,/--opts/p')" "encapsulation"
contains "$(printf '%s\n' "$out" | sed -n '/--opts/,/--encap/p')" "gre-bridge"

cs <<'EOF' || fail "delete address failed"
configure
delete interfaces tunnel tun0 address
commit
EOF
uci -q get network.tun0_net && fail "tun0_net should be gone"

cs <<'EOF' || fail "delete tunnel failed"
configure
delete interfaces tunnel tun0
delete interfaces tunnel tun1
commit
EOF
uci -q get network.tun0 && fail "tun0 should be gone"
contains "$(confsh show configuration interfaces tunnel tun0)" "Configuration under specified path is empty"
