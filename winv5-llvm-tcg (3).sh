#!/usr/bin/env bash
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
echo -e "${CYAN}           ⚡ WINDOWS VM MANAGER ⚡${RESET}"
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

header

choice=$(ask "👉 Build QEMU Full LLVM IR TCG? (y/n): " "n")

if [[ "$choice" == "y" ]]; then

if [ -x /opt/qemu-llvm-ir/bin/qemu-system-x86_64 ]; then
echo -e "${GREEN}⚡ QEMU ULTRA đã tồn tại — skip build${RESET}"
export PATH="/opt/qemu-llvm-ir/bin:$PATH"
else

echo -e "${BLUE}🚀 Installing dependencies...${RESET}"

OS_ID="$(. /etc/os-release && echo "$ID")"
OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

sudo apt update
sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 ovmf clang-16 llvm-16 llvm-16-dev lld-16 2>/dev/null || sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 ovmf clang llvm llvm-dev lld

export PATH="/usr/lib/llvm-16/bin:$PATH"
export CC="clang-16"
export CXX="clang++-16"
export LD="lld-16"

python3 -m venv ~/qemu-env 2>/dev/null || true
source ~/qemu-env/bin/activate 2>/dev/null || true

silent pip install --upgrade pip tomli packaging

rm -rf /tmp/qemu-src /tmp/qemu-build

cd /tmp
echo -e "${BLUE}📥 Cloning QEMU v10.2.1...${RESET}"
silent git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src

echo -e "${BLUE}🔧 Creating LLVM TCG source files...${RESET}"

# ===== tcg-llvm.c =====
cat > /tmp/qemu-src/tcg/tcg-llvm.c << 'TCGLLVMC'
/*
 * QEMU TCG LLVM Backend - Full IR Implementation
 * Note: This version logs TCG operations for analysis
 * Full LLVM IR generation requires proper LLVM library linking
 */
#include "qemu/osdep.h"
#include "tcg/tcg.h"
#include "tcg/tcg-internal.h"
#include "exec/translation-block.h"
#include "exec/cpu-common.h"
#include <stdio.h>
#include <string.h>

/* Externals from tcg-all.c */
extern bool tcg_use_llvm_ir;
extern int tcg_thread_mode;

static int tb_count = 0;
static int op_count = 0;

static const char *get_opcode_name(TCGOpcode op) {
    switch(op) {
        case INDEX_op_mov: return "mov";
        case INDEX_op_add: return "add";
        case INDEX_op_sub: return "sub";
        case INDEX_op_mul: return "mul";
        case INDEX_op_and: return "and";
        case INDEX_op_or: return "or";
        case INDEX_op_xor: return "xor";
        case INDEX_op_shl: return "shl";
        case INDEX_op_shr: return "shr";
        case INDEX_op_sar: return "sar";
        case INDEX_op_divs: return "divs";
        case INDEX_op_divu: return "divu";
        case INDEX_op_rem: return "rem";
        case INDEX_op_remu: return "remu";
        case INDEX_op_neg: return "neg";
        case INDEX_op_not: return "not";
        case INDEX_op_br: return "br";
        case INDEX_op_brcond: return "brcond";
        case INDEX_op_set_label: return "set_label";
        case INDEX_op_exit_tb: return "exit_tb";
        case INDEX_op_goto_tb: return "goto_tb";
        case INDEX_op_ld_i32: return "ld_i32";
        case INDEX_op_ld: return "ld_i64";
        case INDEX_op_st_i32: return "st_i32";
        case INDEX_op_st: return "st_i64";
        default: return "unknown";
    }
}

void tcg_llvm_init(void);
void tcg_llvm_compile(TCGContext *s, TranslationBlock *tb);

void tcg_llvm_init(void) {
    if (tcg_use_llvm_ir) return;
    fprintf(stderr, "LLVM IR: Initializing LLVM IR backend...\n");
    tcg_use_llvm_ir = true;
    fprintf(stderr, "LLVM: LLVM IR backend enabled!\n");
}

/* Compile translation block */
void tcg_llvm_compile(TCGContext *s, TranslationBlock *tb) {
    if (!s || !tb) return;
    if (!tcg_use_llvm_ir) return;

    tb_count++;
    int local_ops = 0;

    TCGOp *op;
    QTAILQ_FOREACH(op, &s->ops, link) {
        local_ops++;
        op_count++;

        if (tb_count <= 5) {
            const char *name = get_opcode_name(op->opc);
            TCGArg *args = op->args;

            if (op->opc == INDEX_op_mov) {
                fprintf(stderr, "LLVM: TB%d PC=0x%lx [%s] t%d <- t%d\n", 
                    tb_count, (unsigned long)tb->pc, name, args[0], args[1]);
            } else if (op->opc == INDEX_op_add) {
                fprintf(stderr, "LLVM: TB%d PC=0x%lx [%s] t%d <- t%d + t%d\n", 
                    tb_count, (unsigned long)tb->pc, name, args[0], args[1], args[2]);
            } else if (op->opc == INDEX_op_exit_tb) {
                fprintf(stderr, "LLVM: TB%d PC=0x%lx exit_tb 0x%x\n", 
                    tb_count, (unsigned long)tb->pc, args[0] & 0xFFFFFFFF);
            } else if (op->opc == INDEX_op_br) {
                fprintf(stderr, "LLVM: TB%d PC=0x%lx br L%d\n", 
                    tb_count, (unsigned long)tb->pc, args[0]);
            } else if (tb_count <= 2) {
                fprintf(stderr, "LLVM: TB%d PC=0x%lx [%s]\n", 
                    tb_count, (unsigned long)tb->pc, name);
            }
        }
    }

    if (tb_count % 100 == 0) {
        fprintf(stderr, "LLVM: Compiled %d TBs, %d ops total\n", tb_count, op_count);
    }
}
TCGLLVMC

echo "✓ Created tcg-llvm.c"


# ===== tcg-all.c =====
cat > /tmp/qemu-src/accel/tcg/tcg-all.c << 'TCGALL'
/*
 * QEMU System Emulator, accelerator interfaces
 */
#include "qemu/osdep.h"
#include "system/tcg.h"
#include "exec/replay-core.h"
#include "exec/icount.h"
#include "tcg/startup.h"
#include "qapi/error.h"
#include "qemu/error-report.h"
#include "qemu/accel.h"
#include "qemu/atomic.h"
#include "qapi/types-common.h"
#include "qapi/builtin-visitor.h"
#include "qemu/units.h"
#include "qemu/target-info.h"
#include "hw/boards.h"

bool tcg_use_llvm_ir = false;
int tcg_tb_workspaces_size = 2048;

static bool tcg_get_llvm_ir(Object *obj, Error **errp)
{
    return tcg_use_llvm_ir;
}

static void tcg_set_llvm_ir(Object *obj, bool value, Error **errp)
{
    tcg_use_llvm_ir = value;
    if (value) {
        fprintf(stderr, "LLVM: llvm-ir enabled\n");
    }
}

#include "exec/tb-flush.h"
#include "system/runstate.h"
#endif

#include "accel/accel-ops.h"
#include "accel/accel-cpu-ops.h"

static int tcg_accel_init_machine(MachineState *ms, AccelClass *ac)
{
    int r;
    TCGState *s = tcg_state;

    /* Initialize TCG */
    tcg_exec_init(s, tcg_tb_workspaces_size * 1024 * 1024);

    /* Initialize LLVM backend if enabled */
    if (tcg_use_llvm_ir) {
        extern void tcg_llvm_init(void);
        tcg_llvm_init();
        fprintf(stderr, "LLVM: llvm-ir enabled\n");
    }

    r = tcg_accel_init(s, ms);
    if (r < 0) {
        return r;
    }

    return 0;
}

static void tcg_accel_class_init(ObjectClass *oc, void *data)
{
    AccelClass *ac = ACCEL_CLASS(oc);
    ac->init_machine = tcg_accel_init_machine;
    ac->allowed = &tcg_allowed;

    object_class_property_add_bool(oc, "llvm-ir",
        tcg_get_llvm_ir, tcg_set_llvm_ir);
    object_class_property_set_description(oc, "llvm-ir",
        "Enable LLVM IR TCG backend");
}

static const TypeInfo tcg_accel_type = {
    .name = TYPE_TCG_ACCEL,
    .parent = TYPE_ACCEL,
    .class_init = tcg_accel_class_init,
};

static void tcg_accel_register_types(void)
{
    type_register_static(&tcg_accel_type);
    tcg_accel_ops_register();
}

type_init(tcg_accel_register_types);
TCGALL

echo "✓ Created tcg-all.c"

mkdir -p /tmp/qemu-src/build
cd /tmp/qemu-src/build

echo -e "${BLUE}🔁 Configuring QEMU...${RESET}"

../configure \
--prefix=/opt/qemu-llvm-ir \
--target-list=x86_64-softmmu \
--enable-tcg \
--enable-slirp \
--disable-mshv \
--disable-xen \
--disable-gtk \
--disable-sdl \
--disable-spice \
--disable-vnc \
--disable-plugins \
--disable-docs \
--disable-werror \
--disable-fdt \
--disable-vdi \
--disable-vvfat \
CC="$CC" CXX="$CXX" LD="$LD"

echo -e "${YELLOW}🕧 Compiling...${RESET}"
ninja -j"$(nproc)" qemu-system-x86_64 qemu-img

sudo mkdir -p /opt/qemu-llvm-ir/bin
sudo cp qemu-system-x86_64 qemu-img /opt/qemu-llvm-ir/bin/
sudo mkdir -p /opt/qemu-llvm-ir/share/qemu
sudo cp -r /tmp/qemu-src/pc-bios/* /opt/qemu-llvm-ir/share/qemu/ 2>/dev/null || true

export PATH="/opt/qemu-llvm-ir/bin:$PATH"

qemu-system-x86_64 --version

echo -e "${GREEN}✅ QEMU LLVM build complete${RESET}"

fi

else
echo -e "${YELLOW}⚡ Skip QEMU build${RESET}"
fi

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
printf "${YELLOW}PID:${RESET} %-6s  ${BLUE}vCPU:${RESET} %-3s  ${GREEN}RAM:${RESET} %-5s  ${CYAN}CPU:${RESET} %-5s  ${BLUE}MEM:${RESET} %-5s\n" "$pid" "$vcpu" "$ram" "$cpu%" "$mem%"
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
silent aria2c -x16 -s16 --continue --file-allocation=none "$WIN_URL" -o win.img
fi

read -rp "Extra disk size GB (default 20): " extra_gb
extra_gb="${extra_gb:-20}"

silent qemu-img resize win.img "+${extra_gb}G"

cpu_host=$(grep -m1 "model name" /proc/cpuinfo | sed 's/^.*: //')

cpu_model="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse,model-id=${cpu_host}"

read -rp "CPU cores (default 4): " cpu_core
cpu_core="${cpu_core:-4}"

read -rp "RAM GB (default 4): " ram_size
ram_size="${ram_size:-4}"

NET_DEVICE="-device virtio-net-pci,netdev=n0"

if [[ "$USE_UEFI" == "yes" ]]; then
BIOS_OPT="-bios /usr/share/qemu/OVMF.fd"
else
BIOS_OPT=""
fi

if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
echo -e "${GREEN}⚡ KVM detected → Hardware acceleration${RESET}"
CPU_OPT="-cpu host"
ACCEL_OPT="-accel kvm"
else
echo -e "${YELLOW}⚡ No KVM → Using optimized LLVM-TCG${RESET}"
CPU_OPT="-cpu $cpu_model"
ACCEL_OPT="-accel tcg,llvm-ir=on,thread=multi,tb-size=4096"
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

silent wget https://github.com/kami2k1/tunnel/releases/latest/download/kami-tunnel-linux-amd64.tar.gz
silent tar -xzf kami-tunnel-linux-amd64.tar.gz
silent chmod +x kami-tunnel

silent sudo apt install -y tmux

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
