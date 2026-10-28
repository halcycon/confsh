# SPDX-License-Identifier: MIT
# Archives, commit-confirm snapshots and session deltas hold secrets:
# not readable by other users.
. /src/tests/lib.sh

# busybox has neither stat(1) nor find -printf.
perm() {
	# shellcheck disable=SC2012
	ls -ld "$1" | cut -c2-10
}

cs <<'EOF' || fail "setup failed"
configure
set network interface wg0 private_key SECRET=
commit-confirm 5
EOF

eq "$(perm /etc/confsh)" "rwx------"
eq "$(perm /etc/confsh/archive)" "rwx------"
eq "$(perm /etc/confsh/confirm-pre.tar.gz)" "rw-------"
for f in /etc/confsh/archive/*.tar.gz; do
	eq "$(perm "$f")" "rw-------"
done
eq "$(perm /var/run/confsh/sessions)" "rwx------"

# Archives written by earlier versions become private on the next commit.
chmod 755 /etc/confsh/archive
cs <<'EOF' || fail "confirm/commit failed"
configure
confirm
set system system @0 hostname perms
commit
EOF
eq "$(perm /etc/confsh/archive)" "rwx------"
