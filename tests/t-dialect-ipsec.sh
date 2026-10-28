# SPDX-License-Identifier: MIT
# EdgeOS `vpn ipsec` dialect -> OpenWrt /etc/config/ipsec (strongswan swanctl).
. /src/tests/lib.sh
export PATH="/src/tests/stubs:$PATH"
: > /etc/config/ipsec   # strongswan ships this; create it for the test

out=$(cs <<'EOF'
configure
set vpn ipsec ike-group IKE1 proposal 1 encryption aes256
set vpn ipsec ike-group IKE1 proposal 1 hash sha256
set vpn ipsec ike-group IKE1 proposal 1 dh-group 14
set vpn ipsec esp-group ESP1 proposal 1 encryption aes256
set vpn ipsec esp-group ESP1 proposal 1 hash sha256
set vpn ipsec esp-group ESP1 proposal 1 dh-group 14
set vpn ipsec site-to-site peer 198.51.100.10 authentication mode pre-shared-secret
set vpn ipsec site-to-site peer 198.51.100.10 authentication pre-shared-secret s3cr3t
set vpn ipsec site-to-site peer 198.51.100.10 ike-group IKE1
set vpn ipsec site-to-site peer 198.51.100.10 local-address 192.0.2.1
set vpn ipsec site-to-site peer 198.51.100.10 tunnel 1 local prefix 192.168.1.0/24
set vpn ipsec site-to-site peer 198.51.100.10 tunnel 1 remote prefix 192.168.2.0/24
set vpn ipsec site-to-site peer 198.51.100.10 tunnel 1 esp-group ESP1
show vpn ipsec
commit
EOF
) || fail "ipsec script failed: $out"

contains "$out" "+ike-group IKE1 {"
contains "$out" "encryption aes256"
contains "$out" "dh-group 14"
contains "$out" "+esp-group ESP1 {"
contains "$out" "peer 198.51.100.10 {"
contains "$out" "pre-shared-secret ********"
contains "$out" "esp-group ESP1"
contains "$out" "prefix 192.168.1.0/24"

eq "$(uci get ipsec.ike_IKE1)" "crypto_proposal"
eq "$(uci get ipsec.ike_IKE1.encryption_algorithm)" "aes256"
eq "$(uci get ipsec.ike_IKE1.hash_algorithm)" "sha256"
eq "$(uci get ipsec.ike_IKE1.dh_group)" "modp2048"
eq "$(uci get ipsec.esp_ESP1)" "crypto_proposal"
eq "$(uci get ipsec.esp_ESP1.encryption_algorithm)" "aes256"
eq "$(uci get ipsec.peer_198_51_100_10)" "remote"
eq "$(uci get ipsec.peer_198_51_100_10.enabled)" "1"
eq "$(uci get ipsec.peer_198_51_100_10.gateway)" "198.51.100.10"
eq "$(uci get ipsec.peer_198_51_100_10.authentication_method)" "psk"
eq "$(uci get ipsec.peer_198_51_100_10.pre_shared_key)" "s3cr3t"
eq "$(uci get ipsec.peer_198_51_100_10.local_ip)" "192.0.2.1"
eq "$(uci get ipsec.peer_198_51_100_10.crypto_proposal)" "ike_IKE1"
eq "$(uci get ipsec.peer_198_51_100_10.tunnel)" "peer_198_51_100_10_t1"
eq "$(uci get ipsec.peer_198_51_100_10_t1)" "tunnel"
eq "$(uci get ipsec.peer_198_51_100_10_t1.local_subnet)" "192.168.1.0/24"
eq "$(uci get ipsec.peer_198_51_100_10_t1.remote_subnet)" "192.168.2.0/24"
eq "$(uci get ipsec.peer_198_51_100_10_t1.crypto_proposal)" "esp_ESP1"

out=$(confsh show configuration vpn ipsec)
contains "$out" "ike-group IKE1 {"
contains "$out" "        dh-group 14"
contains "$out" "peer 198.51.100.10 {"
contains "$out" "            esp-group ESP1"

out=$(confsh show configuration commands vpn ipsec)
contains "$out" "set vpn ipsec ike-group IKE1 proposal 1 encryption 'aes256'"
contains "$out" "set vpn ipsec site-to-site peer 198.51.100.10 tunnel 1 local prefix '192.168.1.0/24'"
contains "$out" "set vpn ipsec site-to-site peer 198.51.100.10 authentication pre-shared-secret '********'"

# op command (stubbed swanctl)
contains "$(confsh show vpn ipsec sa)" "ESTABLISHED"

# validation
for bad in "ike-group IKE1 proposal 2 encryption aes256" \
	"ike-group IKE1 proposal 1 encryption bogus" \
	"ike-group IKE1 proposal 1 dh-group abc" \
	"ike-group IKE1 proposal 1 dh-group 99" \
	"ike-group BAD-NAME proposal 1 encryption aes256" \
	"site-to-site peer 198.51.100.10 bogus x"; do
	out=$(printf 'configure\nset vpn ipsec %s\n' "$bad" | confsh -s 2>&1) && fail "'$bad' must fail"
	contains "$out" "failed"
done
contains "$(printf 'configure\nset vpn ipsec ike-group IKE1 proposal 2 encryption aes256\n' | confsh -s 2>&1)" "proposal 1"
contains "$(printf 'configure\nset vpn ipsec ike-group BAD-NAME proposal 1 encryption aes256\n' | confsh -s 2>&1)" "underscore"

# AEAD (GCM) cipher must not be combined with a hash
out=$(cs <<'EOF'
configure
set vpn ipsec ike-group GCM proposal 1 encryption aes256gcm128
set vpn ipsec ike-group GCM proposal 1 hash sha256
EOF
) && fail "GCM+hash must fail"
contains "$out" "AEAD"

# deleting a group still referenced by the peer/tunnel must be refused
contains "$(printf 'configure\ndelete vpn ipsec ike-group IKE1\n' | confsh -s 2>&1)" "in use"
contains "$(printf 'configure\ndelete vpn ipsec esp-group ESP1\n' | confsh -s 2>&1)" "in use"

# completion
out=$(cs <<'EOF'
configure
_confsh_be complete set vpn ""
echo --root
_confsh_be complete set vpn ipsec ""
echo --kinds
_confsh_be complete set vpn ipsec ike-group ""
echo --groups
_confsh_be complete set vpn ipsec ike-group IKE1 proposal 1 encryption ""
echo --enc
_confsh_be complete set vpn ipsec site-to-site peer ""
echo --peers
EOF
) || fail "completion failed: $out"
contains "$out" "ipsec"
contains "$(printf '%s\n' "$out" | sed -n '/--root/,/--kinds/p')" "site-to-site"
contains "$(printf '%s\n' "$out" | sed -n '/--kinds/,/--groups/p')" "IKE1"
contains "$(printf '%s\n' "$out" | sed -n '/--groups/,/--enc/p')" "aes256"
contains "$(printf '%s\n' "$out" | sed -n '/--enc/,/--peers/p')" "198.51.100.10"

# deletes
cs <<'EOF' || fail "delete subnet failed"
configure
delete vpn ipsec site-to-site peer 198.51.100.10 tunnel 1 remote prefix 192.168.2.0/24
commit
EOF
uci -q get ipsec.peer_198_51_100_10_t1.remote_subnet && fail "remote_subnet should be gone"

cs <<'EOF' || fail "delete peer failed"
configure
delete vpn ipsec site-to-site peer 198.51.100.10
delete vpn ipsec ike-group IKE1
delete vpn ipsec esp-group ESP1
commit
EOF
uci -q get ipsec.peer_198_51_100_10 && fail "peer should be gone"
uci -q get ipsec.peer_198_51_100_10_t1 && fail "tunnel should be gone"
uci -q get ipsec.ike_IKE1 && fail "ike-group should be gone"
contains "$(confsh show configuration vpn ipsec)" "Configuration under specified path is empty"
