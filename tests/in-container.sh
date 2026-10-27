#!/bin/sh
# SPDX-License-Identifier: MIT
# Test driver; runs inside the OpenWrt container (see run.sh).

set -u

mkdir -p /var/lock /var/run
if ! command -v bash >/dev/null; then
	if command -v apk >/dev/null; then
		apk add -q bash >/dev/null
	else
		opkg update >/dev/null && opkg install bash >/dev/null
	fi || exit 1
fi
cp -a /src/confsh/files/. /

# procd/ubus are not running in the container.
export CONFSH_RELOAD_CMD=true

if [ $# -gt 0 ]; then
	tests=$(for t in "$@"; do echo "/src/tests/$t.sh"; done)
else
	tests=$(ls /src/tests/t-*.sh)
fi

pass=0
failed=0

for t in $tests; do
	rm -rf /etc/confsh /var/run/confsh /tmp/.uci
	cp /src/tests/fixtures/config/* /etc/config/

	name=$(basename "$t" .sh)

	if out=$(bash "$t" 2>&1); then
		pass=$((pass + 1))
		echo "ok   $name"
	else
		failed=$((failed + 1))
		echo "FAIL $name"
		echo "$out" | sed 's/^/     /'
	fi
done

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
