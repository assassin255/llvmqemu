#!/bin/bash
# QEMU LLVM IR - Fixed Install Script
# Chạy: sudo bash install-qemu-llvm-full.sh

set -e

echo "=== Installing QEMU LLVM IR with all dependencies ==="
echo ""

# Remove problematic yarn repo if exists
rm -f /etc/apt/sources.list.d/yarn.list 2>/dev/null || true

echo "=== Updating package list ==="
apt-get update || true

echo ""
echo "=== Installing dependencies ==="

apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    gnupg \
    libc6 \
    libglib2.0-0 \
    libpixman-1-0 \
    zlib1g \
    libncurses6 \
    libtinfo6 \
    libslirp0 \
    libfdt1 \
    libpng-dev \
    libjpeg-dev \
    libsdl2-0 \
    libspice-protocol-dev \
    libspice-server1 \
    libusbredirparser1 \
    libacl1 \
    libattr1 \
    libaudit1 \
    libbrlapi-dev \
    libcap2 \
    libcap-ng0 \
    libcacard0 \
    libcurl4 \
    libdbus-1-3 \
    libepoxy0 \
    libfuse2 \
    libgnutls28-dev \
    libgtk-3-0 \
    liblttng-ust0 \
    libncurses6 \
    libnfs13 \
    libnl-3-3 \
    libnuma0 \
    libopus0 \
    libpulse0 \
    librbd1 \
    libsasl2-2 \
    libseccomp2 \
    libsndfile1 \
    libssh-4 \
    libusb-1.0-0 \
    libvdeplug3 \
    libvirglrenderer1 \
    libvncserver1 \
    numactl \
    uuid-dev \
    xauth \
    bridge-utils \
    iptables \
    kmod \
    openssl \
    cpu-checker \
    ovmf \
    seabios \
    vgabios \
    pkg-config \
    git \
    build-essential \
    python3 \
    ninja-build \
    libglib2.0-dev \
    libfdt-dev

echo ""
echo "=== Checking QEMU binary ==="

if [ -f "/opt/qemu-llvm-ir/bin/qemu-system-x86_64" ]; then
    echo "Found QEMU binary, checking libraries..."
    
    # Check for missing libs
    MISSING=$(ldd /opt/qemu-llvm-ir/bin/qemu-system-x86_64 2>&1 | grep "not found" || true)
    
    if [ -n "$MISSING" ]; then
        echo "Missing libraries detected:"
        echo "$MISSING"
        echo ""
        
        # Try to find and install missing packages
        for lib in $MISSING; do
            LIBNAME=$(echo "$lib" | grep -oP '^\S+(?=\s*=>)' | sed 's/\.so.*//' | head -1)
            if [ -n "$LIBNAME" ]; then
                apt-get install -y "${LIBNAME}"-dev 2>/dev/null || true
            fi
        done
    else
        echo "All required libraries found!"
    fi
fi

echo ""
echo "=== Verifying QEMU ==="

if /opt/qemu-llvm-ir/bin/qemu-system-x86_64 --version 2>/dev/null; then
    echo ""
    echo "✅ SUCCESS! QEMU LLVM IR is ready."
else
    echo ""
    echo "❌ QEMU still has issues. Let me check what's missing..."
    
    # Show exact error
    /opt/qemu-llvm-ir/bin/qemu-system-x86_64 2>&1 || true
    
    # Try ldconfig
    echo ""
    echo "Running ldconfig..."
    ldconfig
    
    # Try again
    echo ""
    echo "Retrying..."
    /opt/qemu-llvm-ir/bin/qemu-system-x86_64 --version 2>&1 || true
fi

echo ""
echo "=== Installation complete ==="
