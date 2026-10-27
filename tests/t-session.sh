# SPDX-License-Identifier: GPL-2.0-only
# exit/discard, LuCI isolation, concurrent-edit protection.
. /src/tests/lib.sh

out=$(cs <<'EOF'
configure
set system system @0 hostname edge
exit || echo EXIT-REFUSED
discard
exit
echo LEFT
EOF
) || fail "exit script failed: $out"
contains "$out" "Cannot exit: configuration modified."
contains "$out" "EXIT-REFUSED"
contains "$out" "Changes have been discarded"
contains "$out" "LEFT"

out=$(cs <<'EOF'
configure
set system system @0 hostname edge
exit discard
set -o | grep -q errexit && echo BUILTIN-SET-RESTORED
EOF
) || fail "exit discard failed: $out"
contains "$out" "BUILTIN-SET-RESTORED"
eq "$(uci get system.@system[0].hostname)" "OpenWrt"

# Uncommitted `uci` CLI changes (/tmp/.uci) are always overlaid by libuci:
# confsh warns, and refuses to commit the same config unless forced.
uci set network.lan.ipaddr=9.9.9.9
out=$(cs <<'EOF'
configure
set system system @0 hostname edge
commit
set network interface lan netmask 255.255.0.0
commit || echo COMMIT-REFUSED
EOF
) || fail "uci-cli script failed: $out"
contains "$out" "uncommitted 'uci' changes exist for network"
contains "$out" "COMMIT-REFUSED"
eq "$(uci get system.@system[0].hostname)" "edge"
grep -q 255.255.0.0 /etc/config/network && fail "network must not be committed"
grep -q 9.9.9.9 /etc/config/network && fail "uci CLI change must not be committed"
uci revert network

# A config changed behind the session's back blocks commit unless forced.
out=$(cs <<'EOF'
configure
set network interface lan proto static
set network interface lan ipaddr 10.9.9.1
uci set network.wan.proto=pppoe; uci commit network
commit || echo COMMIT-REFUSED
commit force
EOF
) || fail "stale script failed: $out"
contains "$out" "COMMIT-REFUSED"
contains "$out" "network changed outside this session"
eq "$(uci get network.lan.ipaddr)" "10.9.9.1"
eq "$(uci get network.wan.proto)" "pppoe"
