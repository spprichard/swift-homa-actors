#!/bin/bash
# Runs a command in a Linux Swift container booted on the Homa-enabled kernel
# built by kernel/build.sh. The package is mounted at /src and builds into
# .build-linux so it does not disturb the macOS .build directory.
#
# Usage:
#   Linux/run.sh                 # build, test, and run the Homa actor demo
#   Linux/run.sh <command...>    # run an arbitrary command, e.g. bash
set -euo pipefail

SWIFT_IMAGE=swift:6.4.0-noble
KERNEL_VERSION=6.17.8

DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$DIR")
KERNEL="$DIR/kernel/out/vmlinux-$KERNEL_VERSION-homa"
[[ -f $KERNEL ]] || { echo "Missing $KERNEL; run Linux/kernel/build.sh first." >&2; exit 1; }

if [[ $# -eq 0 ]]; then
  set -- bash -c '
    set -euo pipefail
    uname -r
    grep -i homa /proc/net/protocols
    swift build --scratch-path .build-linux -c release
    swift test --scratch-path .build-linux
    .build-linux/release/actor-demo server-homa 7317 0.0.0.0 &
    server=$!
    sleep 2
    timeout 60 .build-linux/release/actor-demo client-homa 7317 127.0.0.1
    kill $server'
fi

tty=()
[[ -t 0 ]] && tty=(-it)

exec container run --rm ${tty[@]+"${tty[@]}"} --cpus 4 --memory 6g \
  -k "$KERNEL" \
  -v "$ROOT:/src" -w /src \
  "$SWIFT_IMAGE" "$@"
