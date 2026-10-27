#!/bin/sh
# SPDX-License-Identifier: MIT
# Runs tests/t-*.sh inside the official OpenWrt rootfs container.
#   tests/run.sh [t-name ...]

set -eu

IMAGE=${CONFSH_TEST_IMAGE:-docker.io/openwrt/rootfs:x86-64-25.12.3}
ENGINE=${CONTAINER_ENGINE:-$(command -v podman || command -v docker)}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

exec "$ENGINE" run --rm -v "$ROOT:/src:ro,Z" "$IMAGE" /bin/sh /src/tests/in-container.sh "$@"
