#!/bin/bash
# QEMU LLVM IR - Full Install Script with all dependencies
# Chạy: sudo bash install-qemu-llvm-full.sh

set -e

echo "=== Installing QEMU LLVM IR with all dependencies ==="
echo ""

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "Cannot detect OS"
    exit 1
fi

echo "Detected OS: $OS"

# Install base dependencies
echo ""
echo "=== Installing base dependencies ==="

if [ "$OS" = "debian" ] || [ "$OS" = "ubuntu" ]; then
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg \
        libc6 \
        libglib2.0-0 \
        libpixman-1-0 \
        libz1 \
        libncursesw6 \
        libtinfo6 \
        libslirp0 \
        libgio2.0-0 \
        libgobject2.0-0 \
        libglib2.0-dev \
        libfdt1 \
        libfdt-dev \
        libpng-dev \
        libjpeg-dev \
        libsdl2-2.0-0 \
        libsdl2-dev \
        libspice-protocol-dev \
        libspice-server-dev \
        libusbredirparser-dev \
        libacl1-dev \
        libattr1-dev \
        libaudit-dev \
        libbrlapi-dev \
        libcap-dev \
        libcap-ng-dev \
        libcacard-dev \
        libcurl4-gnutls-dev \
        libdbus-1-dev \
        libepoxy-dev \
        libfuse-dev \
        libgnutls28-dev \
        libgtk-3-dev \
        liblttng-ust-dev \
        libncurses6-dev \
        libnfs-dev \
        libnl-3-dev \
        libnuma-dev \
        libopus-dev \
        libpulse-dev \
        librbd-dev \
        libsasl2-dev \
        libseccomp-dev \
        libsndfile1-dev \
        libspice-server-dev \
        libssh-4-dev \
        libusb-1.0-0-dev \
        libvdeplug-dev \
        libvirglrenderer-dev \
        libvncserver1-dev \
        libxen-dev \
        numactl \
        uuid-dev \
        x11proto-randr-dev \
        x11proto-render-dev \
        x11proto-xext-dev \
        x11-utils \
        xauth \
        zlib1g-dev \
        bridge-utils \
        iptables \
        kmod \
        openssl \
        cpu-checker \
        ovmf \
        seabios \
        vgabios

elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ]; then
    dnf install -y \
        glib2 \
        pixman \
        zlib \
        ncurses-libs \
        libusbredirparser \
        SDL2 \
        spice-server \
        libvirt \
        libvirt-client \
        qemu-img \
        qemu-kvm \
        bridge-utils \
        libguestfs-tools \
        libiscsi \
        numactl \
        uuid \
        seccomp \
        gnutls \
        fuse \
        vde2 \
        net-tools \
        xauth \
        pixman-devel \
        glib2-devel \
        zlib-devel

elif [ "$OS" = "alpine" ]; then
    apk add --no-cache \
        qemu \
        libvirt \
        bridge-utils \
        iptables \
        vde2 \
        slirp4netns \
        usbredir \
        spice-protocol \
        sdl2 \
        mesa \
        mesa-dri-swrast \
        llvm \
        clang
fi

echo ""
echo "=== Extracting QEMU LLVM IR ==="

QEMU_DIR="/opt/qemu-llvm-ir"

# Check if tarball exists
if [ ! -f "qemu-llvm-ir.tar.gz" ]; then
    echo "Error: qemu-llvm-ir.tar.gz not found!"
    echo "Please upload the file first"
    exit 1
fi

# Create directory
mkdir -p "$QEMU_DIR"

# Extract
tar -xzf qemu-llvm-ir.tar.gz -C /opt/

# Set permissions
chmod +x "$QEMU_DIR/bin/qemu-system-x86_64"
chmod +x "$QEMU_DIR/bin/qemu-img"
chmod +x "$QEMU_DIR/bin/"qemu-*

# Create symlink
ln -sf "$QEMU_DIR/bin/qemu-system-x86_64" /usr/local/bin/qemu-system-x86_64

echo ""
echo "=== Verifying installation ==="

# Check if QEMU runs
if qemu-system-x86_64 --version >/dev/null 2>&1; then
    echo "SUCCESS! QEMU LLVM IR is installed."
    qemu-system-x86_64 --version
else
    echo "WARNING: QEMU may have missing libraries."
    echo "Checking..."
    ldd "$QEMU_DIR/bin/qemu-system-x86_64" | grep "not found"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Usage:"
echo '  qemu-system-x86_64 \'
echo '    -accel tcg,llvm-ir=on,thread=multi,tb-size=3096 \'
echo '    -machine pc -m 4G -smp 4 \'
echo '    -drive file=your-vm.img,format=raw,if=ide \'
echo '    -vnc :1'
