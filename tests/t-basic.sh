# SPDX-License-Identifier: MIT
# set / show / compare stage changes; commit writes them and archives.
. /src/tests/lib.sh

out=$(cs <<'EOF'
configure
set network interface lan ipaddr 10.0.0.1
set network interface guest proto static
show network interface lan
compare
EOF
) || fail "script failed: $out"

contains "$out" ">ipaddr 10.0.0.1"
contains "$out" " proto static"
contains "$out" "[edit network interface lan]"
contains "$out" "-ipaddr 192.168.1.1"
contains "$out" "+ipaddr 10.0.0.1"
contains "$out" "[edit network interface]"
contains "$out" "+guest {"

# Leaving the script without commit drops the session.
eq "$(uci get network.lan.ipaddr)" "192.168.1.1"
uci -q get network.guest && fail "guest must not exist before commit"

out=$(cs <<'EOF'
configure
set network interface lan ipaddr 10.0.0.1
commit comment first change
compare
EOF
) || fail "commit failed: $out"

contains "$out" "No changes between working and active configurations"
eq "$(uci get network.lan.ipaddr)" "10.0.0.1"

out=$(confsh show system commit)
contains "$out" "via cli"
contains "$out" "first change"
contains "$out" "via baseline"

out=$(cs <<'EOF'
configure
commit
EOF
)
contains "$out" "No configuration changes to commit"
