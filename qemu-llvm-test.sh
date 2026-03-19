#!/usr/bin/env bash
set -euo pipefail

TARBALL="${1:-$(dirname "$0")/qemu-llvm.tar.gz}"
DEST_DIR="${2:-/opt}"
INSTALL_ROOT="${DEST_DIR%/}/qemu-llvm-ir"
BIN="${INSTALL_ROOT}/bin/qemu-system-x86_64"

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

if [[ ! -f "$TARBALL" ]]; then
  echo "error: tarball not found: $TARBALL" >&2
  exit 1
fi

rm -rf "$INSTALL_ROOT"
mkdir -p "$DEST_DIR"
tar -xzf "$TARBALL" -C "$DEST_DIR"

if [[ ! -x "$BIN" ]]; then
  echo "error: expected binary not found: $BIN" >&2
  exit 1
fi

echo "installed: $BIN"
echo "version:"
"$BIN" --version | sed -n '1,5p'

echo "running smoke test..."
timeout 5s "$BIN" -accel llvm -machine pc -m 128M -nographic -nodefaults -display none -serial none -monitor none -S \
  >/tmp/qemu-llvm-from-tar.smoke.out 2>/tmp/qemu-llvm-from-tar.smoke.err || true

if grep -qiE 'error|failed|fatal|unsupported' /tmp/qemu-llvm-from-tar.smoke.err /tmp/qemu-llvm-from-tar.smoke.out; then
  echo "smoke test failed:" >&2
  sed -n '1,120p' /tmp/qemu-llvm-from-tar.smoke.out >&2 || true
  sed -n '1,120p' /tmp/qemu-llvm-from-tar.smoke.err >&2 || true
  exit 1
fi

echo "smoke test ok"
echo "built: $BIN"
