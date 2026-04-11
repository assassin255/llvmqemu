#!/usr/bin/env bash
set -euo pipefail

SRC_URL="${SRC_URL:-https://archive.org/download/qemu-llvm-src.tar/qemu-llvm-src.tar.gz}"
PREFIX="${PREFIX:-/opt/qemu-llvm-ir}"
BUILD_ROOT="${BUILD_ROOT:-/tmp/qemu-llvm-build-$$}"
ARCHIVE_PATH="${ARCHIVE_PATH:-/tmp/qemu-llvm-src.tar.gz}"
LLVM_VER="${LLVM_VER:-16}"
JOBS="${JOBS:-$(nproc)}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run this script as root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  build-essential git pkg-config ninja-build meson \
  python3 python3-venv python3-pip \
  flex bison texinfo gettext \
  curl ca-certificates xz-utils \
  libglib2.0-dev libpixman-1-dev zlib1g-dev \
  libslirp-dev libfdt-dev libcap-ng-dev libattr1-dev \
  libaio-dev libseccomp-dev liburing-dev \
  clang-${LLVM_VER} llvm-${LLVM_VER} llvm-${LLVM_VER}-dev llvm-${LLVM_VER}-tools lld-${LLVM_VER}

if ! command -v llvm-config-${LLVM_VER} >/dev/null 2>&1; then
  echo "Missing llvm-config-${LLVM_VER} after package install."
  exit 1
fi

rm -f "$ARCHIVE_PATH"
curl -fL --retry 3 --retry-delay 2 -o "$ARCHIVE_PATH" "$SRC_URL"

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
tar -xf "$ARCHIVE_PATH" -C "$BUILD_ROOT"

SRC_ROOT="$(find "$BUILD_ROOT" -maxdepth 3 -type f -name configure -printf '%h\n' | head -n 1)"
if [ -z "$SRC_ROOT" ]; then
  echo "Could not locate QEMU source root after extraction."
  exit 1
fi

cd "$SRC_ROOT"
rm -rf build
mkdir -p build
cd build

../configure \
  --prefix="$PREFIX" \
  --target-list=x86_64-softmmu \
  --enable-tcg \
  --enable-slirp \
  --disable-docs \
  --disable-werror \
  --disable-gtk \
  --disable-sdl \
  --disable-vnc \
  --disable-spice \
  --disable-plugins

ninja -j"$JOBS" qemu-system-x86_64 qemu-img
ninja install

ACCEL_HELP_LOG="${ACCEL_HELP_LOG:-$BUILD_ROOT/accel-help.log}"
"$PREFIX/bin/qemu-system-x86_64" -accel help | tee "$ACCEL_HELP_LOG"

if ! grep -qi '\bllvm\b' "$ACCEL_HELP_LOG"; then
  echo "llvm was not listed by -accel help"
  exit 1
fi

echo "LLVM accel is present."
echo "Built and installed to $PREFIX"
echo "Binary: $PREFIX/bin/qemu-system-x86_64"
echo "Help log: $ACCEL_HELP_LOG"
