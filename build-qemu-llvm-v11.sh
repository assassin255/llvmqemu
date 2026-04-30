#!/usr/bin/env bash
# build-qemu-llvm-v11.sh
#
# Build QEMU 11.0.0 with the -accel llvm accelerator patch applied.
#
# Usage:
#   chmod +x build-qemu-llvm-v11.sh
#   ./build-qemu-llvm-v11.sh
#
# After a successful build, test with:
#   ./qemu-src/build/qemu-system-x86_64 -accel help
#   (output must include "llvm" as an available accelerator)
#
# Run a guest with the LLVM accelerator:
#   ./qemu-src/build/qemu-system-x86_64 \
#       -accel llvm \
#       -machine pc -m 256 -nographic \
#       -kernel /boot/vmlinuz ...
#
# Requirements:
#   - Debian / Ubuntu (x86-64) host
#   - ~4 GB disk space, ≥2 GB RAM
#   - Internet access (clones QEMU 11.0.0 from GitHub)
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_TAG="v11.0.0"
QEMU_REPO="https://github.com/qemu/qemu.git"
QEMU_SRC="${SCRIPT_DIR}/qemu-src"

# ─────────────────────────────────────────────────────────────────────────────
log()  { printf '\e[1;32m[llvm-accel]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[llvm-accel]\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31m[llvm-accel]\e[0m %s\n' "$*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. Install build dependencies
# ─────────────────────────────────────────────────────────────────────────────
log "Step 1/5 — installing build dependencies …"
if command -v apt-get &>/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        git build-essential python3 python3-pip \
        ninja-build pkg-config meson \
        libglib2.0-dev libpixman-1-dev \
        flex bison libslirp-dev
else
    warn "apt-get not found — assuming build deps are already installed."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Clone QEMU 11.0.0
# ─────────────────────────────────────────────────────────────────────────────
log "Step 2/5 — fetching QEMU ${QEMU_TAG} …"
if [ ! -d "${QEMU_SRC}/.git" ]; then
    git clone --depth=1 --branch "${QEMU_TAG}" "${QEMU_REPO}" "${QEMU_SRC}"
else
    log "  (source already present at ${QEMU_SRC}, skipping clone)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Apply the LLVM accelerator patch
# ─────────────────────────────────────────────────────────────────────────────
log "Step 3/5 — applying LLVM accelerator files …"

# 3a. Copy accel/llvm/
mkdir -p "${QEMU_SRC}/accel/llvm"
cp "${SCRIPT_DIR}/accel/llvm/llvm-accel.c"  "${QEMU_SRC}/accel/llvm/"
cp "${SCRIPT_DIR}/accel/llvm/meson.build"   "${QEMU_SRC}/accel/llvm/"
log "  copied accel/llvm/ → ${QEMU_SRC}/accel/llvm/"

# 3b. Patch accel/meson.build to add subdir('llvm')
ACCEL_MESON="${QEMU_SRC}/accel/meson.build"
if grep -q "subdir('llvm')" "${ACCEL_MESON}"; then
    log "  accel/meson.build already patched, skipping."
else
    # Insert "  subdir('llvm')" after the "  subdir('whpx')" line
    sed -i "/subdir('whpx')/a \\  subdir('llvm')" "${ACCEL_MESON}"
    log "  patched ${ACCEL_MESON}"
    # Sanity check
    grep -q "subdir('llvm')" "${ACCEL_MESON}" || \
        die "Failed to insert subdir('llvm') into accel/meson.build"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Configure + build
# ─────────────────────────────────────────────────────────────────────────────
log "Step 4/5 — configuring QEMU …"
cd "${QEMU_SRC}"

./configure \
    --target-list="x86_64-softmmu" \
    --enable-tcg \
    --disable-docs \
    --disable-werror

log "  building (this takes 10–20 min on a typical machine) …"
ninja -C build -j"$(nproc)"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Smoke test
# ─────────────────────────────────────────────────────────────────────────────
log "Step 5/5 — verifying -accel llvm is registered …"

QEMU_BIN="${QEMU_SRC}/build/qemu-system-x86_64"
ACCEL_LIST="$("${QEMU_BIN}" -accel help 2>&1 || true)"

echo "${ACCEL_LIST}"

if echo "${ACCEL_LIST}" | grep -q '\bllvm\b'; then
    log ""
    log "✓  SUCCESS: '-accel llvm' is available!"
    log ""
    log "   Binary : ${QEMU_BIN}"
    log "   Usage  : ${QEMU_BIN} -accel llvm -machine pc -m 256 ..."
else
    die "FAIL: 'llvm' not found in -accel help output — check build logs."
fi
