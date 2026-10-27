# SPDX-License-Identifier: GPL-2.0-only
# Operational mode commands and tab completion.
. /src/tests/lib.sh

out=$(confsh show configuration network)
contains "$out" "interface lan {"
contains "$out" "    ipaddr 192.168.1.1"
contains "$out" "device @0 {"

out=$(confsh show configuration commands network interface lan)
contains "$out" "set network interface lan ipaddr '192.168.1.1'"

out=$(confsh show configuration commands firewall rule @0)
contains "$out" "set firewall rule @0 name 'Allow-DHCP-Renew'"

out=$(confsh show 2>&1) && fail "bare show should list completions and fail"
contains "$out" "Possible completions:"
contains "$out" "configuration"

out=$(confsh show nosuch 2>&1) && fail "unknown op command must fail"
contains "$out" "Invalid command: show nosuch"

contains "$(confsh show version)" "Version:"

out=$(cs <<'EOF'
configure
run show configuration commands system timeserver ntp
echo "--set-opts"
_confsh_be complete set network interface lan ""
echo "--labels"
_confsh_be complete set firewall rule ""
echo "--values"
_confsh_be complete set firewall zone @1 input ""
echo "--delete-values"
_confsh_be complete delete network device @0 ports ""
echo "--edit-level"
edit network interface
_confsh_be complete set lan pro
echo "--op"
_confsh_be complete op-show ip ""
EOF
) || fail "completion script failed: $out"
contains "$out" "set system timeserver ntp server '0.openwrt.pool.ntp.org'"
contains "$out" "dns_search"
contains "$out" "@1"
contains "$out" "REJECT"
contains "$out" "eth1"
contains "$out" "proto"
contains "$out" "route"
