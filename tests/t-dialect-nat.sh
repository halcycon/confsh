# SPDX-License-Identifier: MIT
# EdgeOS `service nat` dialect → fw4 redirect / nat sections nat_<N>.
. /src/tests/lib.sh

out=$(cs <<'EOF'
configure
set service nat rule 1 description "SSH to NAS"
set service nat rule 1 inbound-interface eth2
set service nat rule 1 protocol tcp
set service nat rule 1 destination port 2222
set service nat rule 1 inside-address address 192.168.1.10
set service nat rule 1 inside-address port 22
set service nat rule 1 type destination
set service nat rule 5000 type source
set service nat rule 5000 outbound-interface eth2
set service nat rule 5000 source address 192.168.1.0/24
set service nat rule 5000 outside-address address 203.0.113.5
set service nat rule 5001 destination address 10.0.0.0/8
set service nat rule 5001 exclude
set service nat rule 5001 outbound-interface wan
set service nat rule 5001 type masquerade
edit service nat rule 5010
set description "masquerade for WAN"
set outbound-interface eth2
set type masquerade
top
show service nat
commit
EOF
) || fail "nat script failed: $out"

contains "$out" "+rule 1 {"
contains "$out" "+    inside-address {"
contains "$out" "+    type destination"

eq "$(uci get firewall.nat_1)" "redirect"
eq "$(uci get firewall.nat_1.target)" "DNAT"
eq "$(uci get firewall.nat_1.src)" "wan"
eq "$(uci get firewall.nat_1.dest)" "lan"
eq "$(uci get firewall.nat_1.src_dport)" "2222"
eq "$(uci get firewall.nat_1.dest_ip)" "192.168.1.10"
eq "$(uci get firewall.nat_1.dest_port)" "22"
eq "$(uci get firewall.nat_1.proto)" "tcp"
eq "$(uci get firewall.nat_5000)" "nat"
eq "$(uci get firewall.nat_5000.target)" "SNAT"
eq "$(uci get firewall.nat_5000.device)" "eth2"
eq "$(uci get firewall.nat_5000.src_ip)" "192.168.1.0/24"
eq "$(uci get firewall.nat_5000.snat_ip)" "203.0.113.5"
eq "$(uci get firewall.nat_5001.target)" "ACCEPT"
eq "$(uci get firewall.nat_5001.src)" "wan"
eq "$(uci get firewall.nat_5001.dest_ip)" "10.0.0.0/8"
eq "$(uci get firewall.nat_5010.target)" "MASQUERADE"

out=$(confsh show configuration service nat)
contains "$out" "rule 5000 {"
contains "$out" "    outbound-interface eth2"
contains "$out" "    exclude"
contains "$out" '    description "masquerade for WAN"'

out=$(confsh show nat rules)
contains "$out" "redirect nat_1"
contains "$out" "nat nat_5000"
printf '%s\n' "$out" | grep -qE '^nat nat_5000 .* SNAT +eth2 ' || fail "nat_5000 should show device eth2: $out"

# show … commands output (type listed last) replays to the same config.
cmds=$(confsh show configuration commands service nat)
contains "$cmds" "set service nat rule 1 inside-address address '192.168.1.10'"
contains "$cmds" "set service nat rule 5001 exclude"
before=$(uci show firewall | grep nat_ | sort)
{ echo configure; echo "delete service nat"; echo commit; } | confsh -s >/dev/null || fail "delete all failed"
uci -q get firewall.nat_1 && fail "rules should be deleted"
{ echo configure; printf '%s\n' "$cmds"; echo commit; } | confsh -s >/dev/null || fail "replay failed"
eq "$(uci show firewall | grep nat_ | sort)" "$before"

# Commit-time checks (EdgeOS-style commit errors); `commit force` overrides.
out=$(cs <<'EOF'
configure
set service nat rule 7 outbound-interface eth2
commit || echo REFUSED-UNTYPED
set service nat rule 7 type source
commit || echo REFUSED-NO-OUTSIDE
set service nat rule 7 outside-address address 203.0.113.9
set service nat rule 7 outside-address port 1024-2048
commit || echo REFUSED-PORTS
set service nat rule 7 protocol udp
commit
EOF
) || fail "check script failed: $out"
contains "$out" "service nat rule 7: type must be set"
contains "$out" "REFUSED-UNTYPED"
contains "$out" "service nat rule 7: outside-address address is required"
contains "$out" "REFUSED-NO-OUTSIDE"
contains "$out" "protocol must be tcp, udp or tcp_udp when 'outside-address port' is set"
contains "$out" "REFUSED-PORTS"
eq "$(uci get firewall.nat_7.snat_port)" "1024-2048"

out=$(printf 'configure\nset service nat rule 8 type destination\ncommit force\n' | confsh -s 2>&1) ||
	fail "commit force failed: $out"
eq "$(uci get firewall.nat_8)" "redirect"

# Invalid combinations fail at set time.
for bad in "rule 1 outbound-interface eth2" "rule 5010 inside-address address 192.168.1.5" \
	"rule 5010 outside-address address 1.2.3.4" "rule 5001 outside-address address 1.2.3.4" \
	"rule 1 exclude" "rule 1 protocol gre" "rule x type source" "rule 1 source address 10.0.0.0/33x"; do
	out=$(printf 'configure\nset service nat %s\n' "$bad" | confsh -s 2>&1) && fail "'$bad' must fail"
done
contains "$(printf 'configure\nset service nat rule 1 outbound-interface eth2\n' | confsh -s 2>&1)" \
	"'outbound-interface' is only valid for source and masquerade rules"
contains "$(printf 'configure\nset service nat rule 1 inbound-interface nosuch\n' | confsh -s 2>&1)" \
	"Cannot map 'nosuch' to a firewall zone"

out=$(cs <<'EOF'
configure
set service nat rule 1 inside-address port 2200
delete service nat rule 1 description
show service nat rule 1
_confsh_be complete set service nat rule ""
echo --keys
_confsh_be complete set service nat rule 1 ""
echo --types
_confsh_be complete set service nat rule 1 type ""
echo --ifaces
_confsh_be complete set service nat rule 1 inbound-interface ""
EOF
) || fail "modify/completion failed: $out"
contains "$out" ">    port 2200"
contains "$out" '-description "SSH to NAS"'
contains "$out" "5010"
contains "$out" "inside-address"
contains "$out" "masquerade"
contains "$out" "eth2"

# Rule 8 was forced in incomplete: it warns but no longer blocks other commits.
out=$(cs <<'EOF'
configure
delete service nat rule 1 inside-address port
delete service nat rule 5000 source
delete service nat rule 5010
commit
EOF
) || fail "deletes failed: $out"
contains "$out" "Warning: already in the committed configuration:"
contains "$out" "service nat rule 8: inbound-interface is required"
uci -q get firewall.nat_1.dest_port && fail "dest_port should be gone"
uci -q get firewall.nat_5000.src_ip && fail "src_ip should be gone"
uci -q get firewall.nat_5010 && fail "rule 5010 should be gone"
true
