# SPDX-License-Identifier: MIT
# EdgeOS `interfaces openvpn` dialect -> OpenWrt /etc/config/openvpn (static key).
. /src/tests/lib.sh
: > /etc/config/openvpn   # openvpn package ships this; create it for the test

out=$(cs <<'EOF'
configure
set interfaces openvpn vtun0 mode site-to-site
set interfaces openvpn vtun0 local-address 10.9.8.1
set interfaces openvpn vtun0 remote-address 10.9.8.2
set interfaces openvpn vtun0 local-port 1194
set interfaces openvpn vtun0 remote-host 203.0.113.9
set interfaces openvpn vtun0 remote-port 1194
set interfaces openvpn vtun0 shared-secret-key-file /etc/openvpn/s2s.key
set interfaces openvpn vtun0 encryption aes256
set interfaces openvpn vtun0 hash sha256
show interfaces openvpn vtun0
commit
EOF
) || fail "openvpn script failed: $out"

contains "$out" "+local-address 10.9.8.1"
contains "$out" "+encryption aes256"

eq "$(uci get openvpn.vtun0)" "openvpn"
eq "$(uci get openvpn.vtun0.enabled)" "1"
eq "$(uci get openvpn.vtun0.dev)" "tun"
eq "$(uci get openvpn.vtun0.ifconfig)" "10.9.8.1 10.9.8.2"
eq "$(uci get openvpn.vtun0.port)" "1194"
eq "$(uci get openvpn.vtun0.remote)" "203.0.113.9"
eq "$(uci get openvpn.vtun0.rport)" "1194"
eq "$(uci get openvpn.vtun0.secret)" "/etc/openvpn/s2s.key"
eq "$(uci get openvpn.vtun0.cipher)" "AES-256-CBC"
eq "$(uci get openvpn.vtun0.auth)" "SHA256"

out=$(confsh show configuration commands interfaces openvpn vtun0)
contains "$out" "set interfaces openvpn vtun0 encryption 'aes256'"
contains "$out" "set interfaces openvpn vtun0 local-address '10.9.8.1'"
contains "$out" "set interfaces openvpn vtun0 hash 'sha256'"

for bad in "vtun0 encryption bogus" "vtun0 local-port 99999999" "vtun0 mode client" "vtun0 local-address nope"; do
	out=$(printf 'configure\nset interfaces openvpn %s\n' "$bad" | confsh -s 2>&1) && fail "'$bad' must fail"
	contains "$out" "failed"
done

out=$(cs <<'EOF'
configure
_confsh_be complete set interfaces openvpn ""
echo --name
_confsh_be complete set interfaces openvpn vtun0 ""
echo --opts
_confsh_be complete set interfaces openvpn vtun0 encryption ""
echo --enc
EOF
) || fail "completion failed: $out"
contains "$out" "vtun0"
contains "$(printf '%s\n' "$out" | sed -n '/--name/,/--opts/p')" "encryption"
contains "$(printf '%s\n' "$out" | sed -n '/--opts/,/--enc/p')" "aes256"

cs <<'EOF' || fail "delete option failed"
configure
delete interfaces openvpn vtun0 hash
commit
EOF
uci -q get openvpn.vtun0.auth && fail "auth should be gone"

cs <<'EOF' || fail "delete instance failed"
configure
delete interfaces openvpn vtun0
commit
EOF
uci -q get openvpn.vtun0 && fail "vtun0 should be gone"
contains "$(confsh show configuration interfaces openvpn vtun0)" "Configuration under specified path is empty"
