#!/bin/bash
# Builds a Homa-enabled Linux kernel for Apple's `container` tool.
# Usage: Linux/kernel/build.sh
# Output: Linux/kernel/out/vmlinux-<version>-homa, used with `container run -k`.
set -euo pipefail

KERNEL_VERSION=6.17.8
KERNEL_SHA256=5a8de64a75fca706c01c6c0a77cf75a74618439db195e25f1f0268af6b2fb1da
HOMA_COMMIT=53f79638e00ac719b0b390e4c98cb547cce8134d
# apple/containerization revision whose kernel/config-arm64 is the base config.
CONTAINERIZATION_COMMIT=f24df2ac817df66fe149a80103251dec987c32dc
IMAGE=homa-kernel-build:0.1

DIR=$(cd "$(dirname "$0")" && pwd)
CACHE="$DIR/cache"
mkdir -p "$CACHE" "$DIR/out"

tarball="$CACHE/linux-$KERNEL_VERSION.tar.xz"
if [[ ! -f $tarball ]]; then
  curl -fSL -o "$tarball" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz"
fi
echo "$KERNEL_SHA256  $tarball" | shasum -a 256 -c -

if [[ ! -d $CACHE/HomaModule ]]; then
  git clone --quiet https://github.com/PlatformLab/HomaModule.git "$CACHE/HomaModule"
fi
git -C "$CACHE/HomaModule" cat-file -e "$HOMA_COMMIT^{commit}" 2>/dev/null \
  || git -C "$CACHE/HomaModule" fetch --quiet origin

curl -fsSL -o "$CACHE/config-arm64" \
  "https://raw.githubusercontent.com/apple/containerization/$CONTAINERIZATION_COMMIT/kernel/config-arm64"

container build -t "$IMAGE" -f "$DIR/Containerfile" "$DIR"
container run --rm --cpus 8 --memory 12g \
  -v "$DIR:/work" \
  -e KERNEL_VERSION="$KERNEL_VERSION" \
  -e HOMA_COMMIT="$HOMA_COMMIT" \
  "$IMAGE" /work/build-in-container.sh
