# SPDX-License-Identifier: MIT
# Anonymous (@N) and named sections, type checks, edit levels.
. /src/tests/lib.sh

cs <<'EOF' || fail "section script failed"
configure
set firewall rule @1 enabled 0
set firewall rule allow_ssh name Allow-SSH
edit firewall rule allow_ssh
set dest_port 22
set target ACCEPT
up
set allow_ssh proto tcp
top
edit network interface iot
set proto static
set ipaddr 192.168.50.1
commit
EOF

eq "$(uci get firewall.@rule[1].enabled)" "0"
eq "$(uci get firewall.@rule[1].name)" "Allow-Ping"
eq "$(uci get firewall.allow_ssh)" "rule"
eq "$(uci get firewall.allow_ssh.dest_port)" "22"
eq "$(uci get firewall.allow_ssh.proto)" "tcp"
eq "$(uci get network.iot.ipaddr)" "192.168.50.1"

out=$(cs <<'EOF'
configure
set firewall rule @9 enabled 0
EOF
) && fail "missing @N must fail"
contains "$out" "is not valid"

out=$(cs <<'EOF'
configure
set network device lan name x
EOF
) && fail "type mismatch must fail"
contains "$out" "has type 'interface'"

out=$(cs <<'EOF'
configure
set nosuchconfig foo bar baz 1
EOF
) && fail "unknown config must fail"
contains "$out" "[nosuchconfig] is not valid"

out=$(cs <<'EOF'
configure
set firewall defaults @0 input MAYBE
EOF
) && fail "strict enum must fail"
contains "$out" "expected one of ACCEPT, REJECT, DROP"

out=$(cs <<'EOF'
configure
delete network
EOF
) && fail "deleting a whole config must fail"
contains "$out" "Refusing to delete all of 'network'"

cs <<'EOF' || fail "delete section/type failed"
configure
delete network interface iot
delete firewall rule
commit
EOF
uci -q get network.iot && fail "iot should be deleted"
uci -q get firewall.@rule[0] && fail "all rules should be deleted"
true
