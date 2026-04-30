#!/usr/bin/env bash
###############################################################################
# ⚡ WINDOWS VM MANAGER + QEMU LLVM IR TCG ⚡
# Build QEMU v10.2.1 với LLVM IR TCG Backend + Windows VM Manager
###############################################################################

set -e

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
RESET='\033[0m'

line(){ echo -e "${CYAN}══════════════════════════════════════════════════════${RESET}"; }

header(){
clear
line
echo -e "${CYAN}           ⚡ WINDOWS VM + LLVM-TCG MANAGER ⚡${RESET}"
echo -e "${BLUE}        QEMU Full LLVM IR TCG Virtualization${RESET}"
line
}

silent(){
"$@" > /dev/null 2>&1
}

ask(){
read -rp "$1" ans
ans="${ans,,}"
if [[ -z "$ans" ]]; then
echo "$2"
else
echo "$ans"
fi
}

# ============================================================
# BUILD QEMU WITH LLVM IR TCG BACKEND
# ============================================================
build_qemu_llvm() {
echo -e "${BLUE}🚀 Building QEMU LLVM IR TCG Backend...${RESET}"

# Detect OS
OS_ID="$(. /etc/os-release && echo "$ID")"
OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

# Install dependencies
echo -e "${YELLOW}📦 Installing dependencies...${RESET}"
sudo apt update
sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 ovmf clang-16 llvm-16 llvm-16-dev lld-16

# Setup LLVM
export PATH="/usr/lib/llvm-16/bin:$PATH"
export CC="clang-16"
export CXX="clang++-16"
export LD="ld.lld-16"

# Clone QEMU
echo -e "${YELLOW}📥 Cloning QEMU v10.2.1...${RESET}"
rm -rf /tmp/qemu-src /tmp/qemu-build
cd /tmp
silent git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src

# Copy patch files
cp ${BASH_SOURCE%/*}/tcg-llvm.c /tmp/qemu-src/tcg/
cp ${BASH_SOURCE%/*}/tcg-all.c /tmp/qemu-src/accel/tcg/

# Add LLVM init call to tcg.c
if ! grep -q "tcg_llvm_init();" /tmp/qemu-src/tcg/tcg.c; then
    sed -i '/tcg_region_init();/a\    if (tcg_use_llvm_ir) { tcg_llvm_init(); }' /tmp/qemu-src/tcg/tcg.c
fi

# Configure
echo -e "${YELLOW}⚙️ Configuring QEMU...${RESET}"
mkdir /tmp/qemu-build
cd /tmp/qemu-build

../qemu-src/configure \
--prefix=/opt/qemu-llvm-ir \
--target-list=x86_64-softmmu \
--enable-tcg \
--enable-slirp \
--disable-docs \
--disable-werror \
--disable-xen \
--disable-mshv \
--disable-gtk \
--disable-sdl \
--disable-spice \
--disable-vnc \
--disable-plugins \
--disable-debug-info \
CC="$CC" CXX="$CXX" LD="$LD"

# Build
echo -e "${YELLOW}🔨 Building QEMU (this may take a while)...${RESET}"
ninja -j"$(nproc)" qemu-system-x86_64 qemu-img

# Install
echo -e "${YELLOW}📀 Installing QEMU...${RESET}"
sudo mkdir -p /opt/qemu-llvm-ir/bin
sudo cp qemu-system-x86_64 qemu-img /opt/qemu-llvm-ir/bin/
sudo mkdir -p /opt/qemu-llvm-ir/share/qemu
sudo cp -r /tmp/qemu-src/pc-bios/* /opt/qemu-llvm-ir/share/qemu/ 2>/dev/null || true

echo -e "${GREEN}✅ QEMU LLVM IR TCG Build Complete!${RESET}"
echo -e "${BLUE}   Installed to: /opt/qemu-llvm-ir/bin/qemu-system-x86_64${RESET}"
}

# ============================================================
# MAIN SCRIPT
# ============================================================

header

# Check if QEMU already exists
if [ -x /opt/qemu-llvm-ir/bin/qemu-system-x86_64 ]; then
    echo -e "${GREEN}⚡ QEMU LLVM IR already installed${RESET}"
    export PATH="/opt/qemu-llvm-ir/bin:$PATH"
else
    choice=$(ask "👉 Build QEMU LLVM IR TCG? (y/n): " "n")
    if [[ "$choice" == "y" ]]; then
        build_qemu_llvm
        export PATH="/opt/qemu-llvm-ir/bin:$PATH"
    fi
fi

# Main menu
echo
line
echo -e "${CYAN}🖥️ MAIN MENU${RESET}"
line
echo "1) Create Windows VM"
echo "2) Manage Running VM"
line

read -rp "👉 Select: " main_choice

case "$main_choice" in
2)
    echo
    line
    echo -e "${CYAN}🚀 RUNNING VM LIST${RESET}"
    line
    
    VM_LIST=$(pgrep -f '^qemu-system')
    
    if [[ -z "$VM_LIST" ]]; then
        echo -e "${RED}❌ No VM running${RESET}"
    else
        for pid in $VM_LIST; do
            cmd=$(tr '\0' ' ' < /proc/$pid/cmdline)
            vcpu=$(echo "$cmd" | sed -n 's/.*-smp \([^ ,]*\).*/\1/p')
            ram=$(echo "$cmd" | sed -n 's/.*-m \([^ ]*\).*/\1/p')
            cpu=$(ps -p $pid -o %cpu=)
            mem=$(ps -p $pid -o %mem=)
            printf "${YELLOW}PID:${RESET} %-6s  ${BLUE}vCPU:${RESET} %-3s  ${GREEN}RAM:${RESET} %-5s  ${CYAN}CPU:${RESET} %-5s  ${BLUE}HostRAM:${RESET} %-5s\n" "$pid" "$vcpu" "$ram" "$cpu%" "$mem%"
        done
    fi
    
    line
    read -rp "Enter PID to stop (Enter skip): " kill_pid
    if [[ -n "$kill_pid" && -d "/proc/$kill_pid" ]]; then
        kill "$kill_pid" 2>/dev/null || true
        echo -e "${GREEN}✔ VM stopped${RESET}"
    fi
    ;;
esac

echo
line
echo -e "${CYAN}🪟 Select Windows Version${RESET}"
line

echo "1) Windows Server 2012 R2"
echo "2) Windows Server 2022"
echo "3) Windows 11 LTSB"
echo "4) Windows 10 LTSB 2015"
echo "5) Windows 10 LTSC 2023"

line

read -rp "👉 Select: " win_choice

case "$win_choice" in
1) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no" ;;
2) WIN_NAME="Windows Server 2022"; WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img"; USE_UEFI="no" ;;
3) WIN_NAME="Windows 11 LTSB"; WIN_URL="https://archive.org/download/win_20260203/win.img"; USE_UEFI="yes" ;;
4) WIN_NAME="Windows 10 LTSB 2015"; WIN_URL="https://archive.org/download/win_20260208/win.img"; USE_UEFI="no" ;;
5) WIN_NAME="Windows 10 LTSC 2023"; WIN_URL="https://archive.org/download/win_20260215/win.img"; USE_UEFI="no" ;;
*) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no" ;;
esac

case "$win_choice" in
3|4|5)
RDP_USER="Admin"
RDP_PASS="Tam255Z"
;;
*)
RDP_USER="administrator"
RDP_PASS="Tamnguyenyt@123"
;;
esac

echo -e "${BLUE}🪟 Downloading $WIN_NAME...${RESET}"

if [[ ! -f win.img ]]; then
    aria2c -x16 -s16 --continue --file-allocation=none "$WIN_URL" -o win.img
fi

read -rp "Extra disk size GB (default 20): " extra_gb
extra_gb="${extra_gb:-20}"

qemu-img resize win.img "+${extra_gb}G" 2>/dev/null || true

cpu_host=$(grep -m1 "model name" /proc/cpuinfo | sed 's/^.*: //')

cpu_model="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse,model-id=${cpu_host}"

read -rp "CPU cores (default 4): " cpu_core
cpu_core="${cpu_core:-4}"

read -rp "RAM GB (default 4): " ram_size
ram_size="${ram_size:-4}"

if [[ "$win_choice" == "4" ]]; then
    NET_DEVICE="-device e1000e,netdev=n0"
else
    NET_DEVICE="-device virtio-net-pci,netdev=n0"
fi

if [[ "$USE_UEFI" == "yes" ]]; then
    BIOS_OPT="-bios /usr/share/qemu/OVMF.fd"
else
    BIOS_OPT=""
fi

# Check for KVM
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    echo -e "${GREEN}⚡ KVM detected → Hardware acceleration${RESET}"
    CPU_OPT="-cpu host"
    ACCEL_OPT="-accel kvm"
else
    echo -e "${YELLOW}⚡ No KVM → Using TCG${RESET}"
    CPU_OPT="-cpu $cpu_model"
    
    # LLVM TCG option
    use_llvm=$(ask "Use LLVM IR TCG Backend? (y/n): " "y")
    if [[ "$use_llvm" == "y" ]]; then
        ACCEL_OPT="-accel tcg,llvm-ir=on,thread=multi,tb-size=4096"
    else
        ACCEL_OPT="-accel tcg,thread=multi"
    fi
fi

echo -e "${YELLOW}⌛ Starting VM...${RESET}"

qemu-system-x86_64 \
-machine q35,hpet=off \
$CPU_OPT \
-smp "$cpu_core" \
-m "${ram_size}G" \
$ACCEL_OPT \
-rtc base=localtime \
$BIOS_OPT \
-drive file=win.img,if=virtio,cache=unsafe,aio=threads,format=raw \
-netdev user,id=n0,hostfwd=tcp::3389-:3389 \
$NET_DEVICE \
-device virtio-mouse-pci \
-device virtio-keyboard-pci \
-nodefaults \
-global ICH9-LPC.disable_s3=1 \
-global ICH9-LPC.disable_s4=1 \
-smbios type=1,manufacturer="Dell Inc.",product="PowerEdge R640" \
-global kvm-pit.lost_tick_policy=discard \
-no-user-config \
-display none \
-vga virtio \
-daemonize \
> /dev/null 2>&1 || true

sleep 3

use_rdp=$(ask "Open public RDP tunnel? (y/n): " "n")

if [[ "$use_rdp" == "y" ]]; then
    wget -q https://github.com/kami2k1/tunnel/releases/latest/download/kami-tunnel-linux-amd64.tar.gz
    tar -xzf kami-tunnel-linux-amd64.tar.gz
    chmod +x kami-tunnel
    
    apt install -y tmux 2>/dev/null || true
    
    tmux kill-session -t kami 2>/dev/null || true
    tmux new-session -d -s kami "./kami-tunnel 3389"
    
    sleep 4
    
    PUBLIC=$(tmux capture-pane -pt kami -p | sed 's/\x1b\[[0-9;]*m//g' | grep -i 'public' | grep -oE '[a-zA-Z0-9\.\-]+:[0-9]+' | head -n1)
    
    line
    echo -e "${GREEN}🚀 WINDOWS VM DEPLOYED${RESET}"
    line
    
    printf "${CYAN}%-14s${RESET} %s\n" "OS" "$WIN_NAME"
    printf "${CYAN}%-14s${RESET} %s\n" "CPU CORES" "$cpu_core"
    printf "${CYAN}%-14s${RESET} %s GB\n" "RAM" "$ram_size"
    printf "${CYAN}%-14s${RESET} %s\n" "HOST CPU" "$cpu_host"
    line
    printf "${YELLOW}%-14s${RESET} %s\n" "RDP ADDRESS" "$PUBLIC"
    printf "${YELLOW}%-14s${RESET} %s\n" "USERNAME" "$RDP_USER"
    printf "${YELLOW}%-14s${RESET} %s\n" "PASSWORD" "$RDP_PASS"
    line
    echo -e "${GREEN}STATUS${RESET} : RUNNING"
    echo -e "${GREEN}MODE${RESET}   : Headless / RDP"
    line
fi
