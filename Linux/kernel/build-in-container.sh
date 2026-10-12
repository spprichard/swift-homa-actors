#!/bin/bash
# Runs inside the kernel-build container. Builds an arm64 kernel for Apple's
# `container` VMs with Homa compiled in (CONFIG_HOMA=y).
set -euo pipefail

: "${KERNEL_VERSION:?}" "${HOMA_COMMIT:?}"
WORK=/work
SRC=/kbuild

mkdir -p "$SRC"
tar -xf "$WORK/cache/linux-$KERNEL_VERSION.tar.xz" -C "$SRC" --strip-components=1

# Place HomaModule in the tree as net/homa.
mkdir -p "$SRC/net/homa"
git -C "$WORK/cache/HomaModule" archive "$HOMA_COMMIT" | tar -x -C "$SRC/net/homa"
# Local patches (e.g. the Linux 7.2 port) keep both ends of a test on the
# same Homa source; they are version-guarded and still build on 6.17.
for p in "$WORK"/*.patch; do
  [[ -e $p ]] || continue
  patch -p1 -d "$SRC/net/homa" < "$p"
done
cp "$SRC/net/homa/homa.h" "$SRC/include/uapi/linux/homa.h"

# Use the full object list from HomaModule's out-of-tree Makefile rather than
# Makefile.upstream, which covers only the stripped (__STRIP__) subset.
objs=$(make -s -f - print-objs <<'MK'
include /kbuild/net/homa/Makefile
print-objs: ; @echo $(HOMA_OBJS)
MK
)
cat > "$SRC/net/homa/Makefile" <<MK
obj-\$(CONFIG_HOMA) += homa.o
homa-y := $objs
MK

echo 'source "net/homa/Kconfig"' >> "$SRC/net/Kconfig"
echo 'obj-$(CONFIG_HOMA) += homa/' >> "$SRC/net/Makefile"

cp "$WORK/cache/config-arm64" "$SRC/.config"
cat "$WORK/homa.config" >> "$SRC/.config"

cd "$SRC"
make ARCH=arm64 olddefconfig
grep -q '^CONFIG_HOMA=y' .config || { echo "CONFIG_HOMA=y did not survive olddefconfig" >&2; exit 1; }
make ARCH=arm64 -j"$(nproc)" LOCALVERSION="-homa-${HOMA_COMMIT:0:8}" Image

mkdir -p "$WORK/out"
cp arch/arm64/boot/Image "$WORK/out/vmlinux-$KERNEL_VERSION-homa"
cp .config "$WORK/out/config-$KERNEL_VERSION-homa"
cp include/uapi/linux/homa.h "$WORK/out/homa.h"
echo "Built $WORK/out/vmlinux-$KERNEL_VERSION-homa"
