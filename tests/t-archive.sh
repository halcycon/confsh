# SPDX-License-Identifier: MIT
# Commit archive, rollback, commit-confirm (timeout, confirm, reboot).
. /src/tests/lib.sh

export CONFSH_CONFIRM_SECONDS_PER_MINUTE=1

cs <<'EOF' || fail "commits failed"
configure
set system system @0 hostname one
commit comment one
set system system @0 hostname two
commit comment two
EOF

out=$(confsh show system commit)
contains "$out" "0   "
contains "$out" "two"
contains "$out" "via baseline"

cs <<'EOF' || fail "rollback failed"
configure
rollback 1
EOF
eq "$(uci get system.@system[0].hostname)" "one"
contains "$(confsh show system commit)" "rollback to revision 1"

out=$(cs <<'EOF'
configure
rollback 99
EOF
) && fail "invalid revision must fail"
contains "$out" "Invalid revision '99'"

# Not confirmed: reverted by the detached timer.
out=$(cs <<'EOF'
configure
set system system @0 hostname risky
commit-confirm 2
set system system @0 hostname other
commit || echo COMMIT-BLOCKED
EOF
) || fail "commit-confirm failed: $out"
contains "$out" "reverted in 2 minutes"
contains "$out" "COMMIT-BLOCKED"
eq "$(uci get system.@system[0].hostname)" "risky"
sleep 4
eq "$(uci get system.@system[0].hostname)" "one"
contains "$(confsh show system commit)" "not confirmed in time"

# Confirmed: kept.
cs <<'EOF' || fail "confirm failed"
configure
set system system @0 hostname kept
commit-confirm 2
confirm
EOF
sleep 4
eq "$(uci get system.@system[0].hostname)" "kept"

# Reboot before confirming: the init script reverts at boot.
cs <<'EOF' || fail "commit-confirm (boot) failed"
configure
set system system @0 hostname lost
commit-confirm 60
EOF
eq "$(uci get system.@system[0].hostname)" "lost"
/usr/libexec/confsh/backend confirm-boot
eq "$(uci get system.@system[0].hostname)" "kept"
[ -e /etc/confsh/confirm.json ] && fail "confirm marker should be gone"
true
