#!/bin/bash
# QEMU LLVM IR - Install Script
# Chạy: sudo bash install-qemu-llvm.sh

set -e

QEMU_DIR="/opt/qemu-llvm-ir"

echo "Installing QEMU LLVM IR to $QEMU_DIR..."

# Create directory
sudo mkdir -p "$QEMU_DIR"

# Extract
sudo tar -xzf qemu-llvm-ir.tar.gz -C /opt/

# Set permissions
sudo chmod +x "$QEMU_DIR/bin/qemu-system-x86_64"
sudo chmod +x "$QEMU_DIR/bin/qemu-img"
sudo chmod +x "$QEMU_DIR/bin/"qemu-*

# Create symlink
sudo ln -sf "$QEMU_DIR/bin/qemu-system-x86_64" /usr/local/bin/qemu-system-x86_64

echo "Done!"
echo ""
echo "Test run:"
qemu-system-x86_64 --version
echo ""
echo "Usage example:"
echo '  qemu-system-x86_64 \'
echo '    -accel tcg,llvm-ir=on,thread=multi,tb-size=3096 \'
echo '    -machine pc -m 4G -smp 4 \'
echo '    -drive file=your-vm.img,format=raw,if=ide'
