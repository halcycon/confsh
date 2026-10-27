# SPDX-License-Identifier: GPL-2.0-only
# Multi-value options: set appends, delete <value> removes one item.
. /src/tests/lib.sh

cs <<'EOF' || fail "list script failed"
configure
set network interface lan dns 1.1.1.1
set network interface lan dns 8.8.8.8
set network interface lan dns 1.1.1.1
set system timeserver ntp server 2.openwrt.pool.ntp.org
delete network device @0 ports eth1
commit
EOF

eq "$(uci get network.lan.dns)" "1.1.1.1 8.8.8.8"
eq "$(uci get system.ntp.server)" "0.openwrt.pool.ntp.org 1.openwrt.pool.ntp.org 2.openwrt.pool.ntp.org"
eq "$(uci get network.@device[0].ports)" "eth0"

cs <<'EOF' || fail "list delete failed"
configure
delete network interface lan dns 1.1.1.1
commit
EOF

eq "$(uci get network.lan.dns)" "8.8.8.8"

out=$(cs <<'EOF'
configure
delete network interface lan dns 4.4.4.4
EOF
) && fail "deleting a missing value must fail"
contains "$out" "does not contain '4.4.4.4'"

# Without a hint or an existing list, set replaces a scalar.
cs <<'EOF' || fail "scalar set failed"
configure
set network interface lan netmask 255.255.0.0
commit
EOF
eq "$(uci get network.lan.netmask)" "255.255.0.0"
