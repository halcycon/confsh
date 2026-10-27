# SPDX-License-Identifier: GPL-2.0-only
# shellcheck shell=bash

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

contains() {
	printf '%s\n' "$1" | grep -qF -- "$2" ||
		fail "expected output to contain: $2"$'\n'"--- output ---"$'\n'"$1"
}

not_contains() {
	if printf '%s\n' "$1" | grep -qF -- "$2"; then
		fail "expected output not to contain: $2"$'\n'"--- output ---"$'\n'"$1"
	fi
}

eq() {
	[ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

# Run a confsh script from stdin; prints combined output.
cs() {
	confsh -s 2>&1
}
