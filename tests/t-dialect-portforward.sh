# SPDX-License-Identifier: MIT
# EdgeOS `port-forward` dialect → fw4 redirects pf_<N>.
. /src/tests/lib.sh

out=$(cs <<'EOF'
configure
set port-forward wan-interface eth2
set port-forward lan-interface lan
set port-forward hairpin-nat enable
set port-forward auto-firewall enable
set port-forward rule 1 description "NAS HTTPS"
set port-forward rule 1 original-port 443
set port-forward rule 1 protocol tcp
set port-forward rule 1 forward-to address 192.168.1.10
set port-forward rule 1 forward-to port 8443
edit port-forward rule 2
set original-port 3389
set forward-to address 192.168.1.20
top
show port-forward
commit
EOF
) || fail "port-forward script failed: $out"

contains "$out" "+rule 1 {"
contains "$out" '+    description "NAS HTTPS"'
contains "$out" "+    forward-to {"
contains "$out" "+wan-interface eth2"

eq "$(uci get firewall.pf_1)" "redirect"
eq "$(uci get firewall.pf_1.target)" "DNAT"
eq "$(uci get firewall.pf_1.src)" "wan"
eq "$(uci get firewall.pf_1.dest)" "lan"
eq "$(uci get firewall.pf_1.proto)" "tcp"
eq "$(uci get firewall.pf_1.src_dport)" "443"
eq "$(uci get firewall.pf_1.dest_port)" "8443"
eq "$(uci get firewall.pf_1.reflection)" "1"
eq "$(uci get firewall.pf_1.name)" "NAS HTTPS"
eq "$(uci get firewall.pf_2.proto)" "tcpudp"
eq "$(uci get confsh.port_forward.wan_interface)" "eth2"

out=$(confsh show configuration port-forward)
contains "$out" "rule 1 {"
contains "$out" '    description "NAS HTTPS"'
contains "$out" "        address 192.168.1.10"
contains "$out" "    protocol tcp_udp"
contains "$out" "hairpin-nat enable"

out=$(confsh show configuration commands port-forward)
contains "$out" "set port-forward rule 1 forward-to address '192.168.1.10'"
contains "$out" "set port-forward rule 2 original-port '3389'"
contains "$out" "set port-forward wan-interface 'eth2'"

contains "$(confsh show configuration commands port-forward rule 1 forward-to port)" "set port-forward rule 1 forward-to port '8443'"
contains "$(confsh show nat rules)" "redirect pf_1"

out=$(cs <<'EOF'
configure
set port-forward rule 1 forward-to port 9443
show port-forward rule 1
compare
EOF
) || fail "modify failed: $out"
contains "$out" ">    port 9443"
contains "$out" "[edit firewall redirect pf_1]"

for bad in "rule abc" "rule 1 original-port 99999999" "wan-interface nosuch" \
	"auto-firewall disable" "rule 1 bogus x" "rule 1 protocol icmp" "rule 1 forward-to address 300.1"; do
	out=$(printf 'configure\nset port-forward %s\n' "$bad" | confsh -s 2>&1) && fail "'$bad' must fail"
	contains "$out" "failed"
done
contains "$(printf 'configure\nset port-forward wan-interface nosuch\n' | confsh -s 2>&1)" "Cannot map 'nosuch' to a firewall zone"
contains "$(printf 'configure\nset port-forward rule abc\n' | confsh -s 2>&1)" "expected a number"

out=$(cs <<'EOF'
configure
_confsh_be complete set ""
echo --pf
_confsh_be complete set port-forward ""
echo --rules
_confsh_be complete set port-forward rule ""
echo --proto
_confsh_be complete set port-forward rule 1 protocol ""
echo --zones
_confsh_be complete set port-forward wan-interface ""
echo --level
edit port-forward rule 1
_confsh_be complete set forward-to ""
EOF
) || fail "completion failed: $out"
contains "$out" "port-forward"
contains "$out" "hairpin-nat"
contains "$out" "tcp_udp"
contains "$out" "wan"
contains "$out" "address"
contains "$(printf '%s\n' "$out" | sed -n '/--rules/,/--proto/p')" "2"

cs <<'EOF' || fail "deletes failed"
configure
delete port-forward rule 1 forward-to port
delete port-forward rule 2
delete port-forward hairpin-nat
commit
EOF
uci -q get firewall.pf_1.dest_port && fail "dest_port should be gone"
uci -q get firewall.pf_2 && fail "pf_2 should be gone"
uci -q get firewall.pf_1.reflection && fail "reflection should be gone"

cs <<'EOF' || fail "delete all failed"
configure
delete port-forward
commit
EOF
uci -q get firewall.pf_1 && fail "pf_1 should be gone"
uci -q get confsh.port_forward && fail "settings should be gone"
contains "$(confsh show configuration port-forward)" "Configuration under specified path is empty"
