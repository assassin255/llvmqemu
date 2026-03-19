#!/usr/bin/env bash
set -euo pipefail

TARBALL="${1:-$(dirname "$0")/qemu-llvm.tar.gz}"
DEST_DIR="${2:-/opt}"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
  build-essential git python3 python3-pip python3-venv \
  ninja-build meson pkg-config libglib2.0-dev libpixman-1-dev \
  flex bison wget curl \
  libslirp-dev libfdt-dev libzstd-dev libbpf-dev \
  llvm-16 llvm-16-dev llvm-16-runtime \
  clang-16 libclang-16-dev lld-16

ln -sf /usr/bin/llvm-config-16 /usr/bin/llvm-config
ln -sf /usr/bin/clang-16 /usr/bin/clang

rm -rf "${DEST_DIR}/qemu-src" "${DEST_DIR}/qemu-llvm-build" "${DEST_DIR}/qemu-llvm-ir"
mkdir -p "$DEST_DIR"
tar -xzf "$TARBALL" -C "$DEST_DIR"

cd "${DEST_DIR}/qemu-llvm-build"
ninja -j"$(nproc)" qemu-system-x86_64
ninja -j"$(nproc)" install
