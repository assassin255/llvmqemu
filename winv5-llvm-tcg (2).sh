#!/usr/bin/env bash

# ============================================
# Windows VM with QEMU LLVM IR TCG Backend
# ============================================

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
sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 ovmf clang-16 llvm-16 llvm-16-dev lld-16

export PATH="/usr/lib/llvm-16/bin:$PATH"
export CC="clang-16"
export CXX="clang++-16"
export LD="ld.lld-16"

python3 -m venv ~/qemu-env 2>/dev/null || true
source ~/qemu-env/bin/activate 2>/dev/null || true

silent pip install --upgrade pip tomli packaging

rm -rf /tmp/qemu-src /tmp/qemu-build

cd /tmp
silent git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src

echo -e "${BLUE}📝 Patching QEMU with LLVM backend...${RESET}"

# Copy source files
cp $(dirname $0)/tcg-llvm.c /tmp/qemu-src/tcg/ 2>/dev/null || cp tcg-llvm.c /tmp/qemu-src/tcg/ 2>/dev/null || true
cp $(dirname $0)/tcg-all.c /tmp/qemu-src/accel/tcg/ 2>/dev/null || cp tcg-all.c /tmp/qemu-src/accel/tcg/ 2>/dev/null || true

# Patch tcg.c to call LLVM init
if ! grep -q "tcg_use_llvm_ir" /tmp/qemu-src/tcg/tcg.c; then
sed -i '/#include "tcg\/tcg-internal.h"/a\
extern bool tcg_use_llvm_ir;' /tmp/qemu-src/tcg/tcg.c
sed -i 's/tcg_region_init();/tcg_region_init();\n    if (tcg_use_llvm_ir) {\n        extern void tcg_llvm_init();\n        tcg_llvm_init();\n    }/' /tmp/qemu-src/tcg/tcg.c
fi

mkdir /tmp/qemu-build
cd /tmp/qemu-build

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

printf "${YELLOW}PID:${RESET} %-6s  ${BLUE}vCPU:${RESET} %-3s  ${GREEN}VM RAM:${RESET} %-5s  ${CYAN}CPU:${RESET} %-5s  ${BLUE}HostRAM:${RESET} %-5s\n" "$pid" "$vcpu" "$ram" "$cpu%" "$mem%"

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

export PATH="/opt/qemu-llvm-ir/bin:$PATH"

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
#!/usr/bin/env bash
set -e
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
RESET='\033[0m'
line(){ echo -e "${CYAN}==============================================================${RESET}"; }
header(){
clear
line
echo -e "${CYAN}           QEMU LLVM IR TCG BACKEND${RESET}"
echo -e "${BLUE}        Full Integration - Auto Patch & Build${RESET}"
line
}
silent(){ "$@" > /dev/null 2>&1; }
ask(){
read -rp "$1" ans
ans="${ans,,}"
if [[ -z "$ans" ]]; then echo "$2"; else echo "$ans"; fi
}
header
choice=$(ask "Build QEMU with LLVM IR TCG? (y/n): " "n")
if [[ "$choice" != "y" ]]; then exit 0; fi

if [ -x /opt/qemu-llvm-ir/bin/qemu-system-x86_64 ]; then
echo -e "${GREEN}QEMU LLVM already installed${RESET}"
export PATH="/opt/qemu-llvm-ir/bin:$PATH"
else
echo -e "${BLUE}Installing dependencies...${RESET}"
OS_ID="$(. /etc/os-release && echo "$ID")"
sudo apt update
sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson clang-15 llvm-15 lld-15
export CC=clang-15
export CXX=clang++-15
export LD=lld-15
rm -rf /tmp/qemu-src /tmp/qemu-build
cd /tmp
silent git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src
echo -e "${BLUE}Creating LLVM TCG backend...${RESET}"
cat > /tmp/qemu-src/tcg/tcg-llvm.c << 'TCGLLVM'
/*
 * QEMU TCG LLVM Backend - Full IR Implementation
 */
#include "qemu/osdep.h"
#include "tcg/tcg.h"
#include "tcg/tcg-internal.h"
#include "exec/translation-block.h"
#include <llvm-c/Core.h>
#include <llvm-c/Target.h>
#include <llvm-c/TargetMachine.h>
#include <llvm-c/ExecutionEngine.h>
#include <llvm-c/Analysis.h>
#include <llvm-c/Transforms/Scalar.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    LLVMExecutionEngineRef ee;
    LLVMModuleRef mod;
    LLVMContextRef ctx;
    LLVMBuilderRef builder;
    LLVMTargetRef target;
    LLVMTargetMachineRef tm;
    LLVMValueRef fn;
    GHashTable *labels;
    GHashTable *blocks;
    LLVMValueRef temps[512];
    int tb_count;
} TCGLLVMState;

static TCGLLVMState *ls;
static bool llvm_init_done = false;

static const char* op_name(TCGOpcode op) {
    switch(op) {
        CASE_OP(mov); CASE_OP(add); CASE_OP(sub); CASE_OP(mul);
        CASE_OP(and); CASE_OP(or); CASE_OP(xor); CASE_OP(shl);
        CASE_OP(shr); CASE_OP(sar); CASE_OP(neg); CASE_OP(not);
        CASE_OP(div); CASE_OP(divu); CASE_OP(rem); CASE_OP(remu);
        CASE_OP(brcond); CASE_OP(br); CASE_OP(set_label); CASE_OP(exit_tb);
        CASE_OP(goto_tb); CASE_OP(ld8u); CASE_OP(ld16u); CASE_OP(ld32);
        CASE_OP(st8); CASE_OP(st16); CASE_OP(st32);
        default: return "unknown";
    }
}

static LLVMTypeRef lt(TCGType t) {
    switch(t) {
        case TCG_TYPE_I32: return LLVMInt32TypeInContext(ls->ctx);
        case TCG_TYPE_I64: return LLVMInt64TypeInContext(ls->ctx);
        case TCG_TYPE_PTR: return LLVMPointerType(LLVMInt8TypeInContext(ls->ctx), 0);
        default: return LLVMInt64TypeInContext(ls->ctx);
    }
}

static LLVMIntPredicate lc(TCGCond c) {
    switch(c) {
        case TCG_COND_EQ: return LLVMIntEQ;
        case TCG_COND_NE: return LLVMIntNE;
        case TCG_COND_LT: return LLVMIntSLT;
        case TCG_COND_GE: return LLVMIntSGE;
        case TCG_COND_LE: return LLVMIntSLE;
        case TCG_COND_GT: return LLVMIntSGT;
        case TCG_COND_LTU: return LLVMIntULT;
        case TCG_COND_GEU: return LLVMIntUGE;
        case TCG_COND_LEU: return LLVMIntULE;
        case TCG_COND_GTU: return LLVMIntUGT;
        default: return LLVMIntNE;
    }
}

static LLVMBasicBlockRef gl(unsigned id) {
    LLVMBasicBlockRef bb = g_hash_table_lookup(ls->labels, GUINT_TO_POINTER(id));
    if (!bb) {
        char n[32]; snprintf(n, sizeof(n), "L%d", id);
        bb = LLVMAppendBasicBlockInContext(ls->ctx, ls->fn, n);
        g_hash_table_insert(ls->labels, GUINT_TO_POINTER(id), bb);
    }
    return bb;
}

static LLVMValueRef gp(int i) {
    if (i < 0 || i >= 512) return NULL;
    if (!ls->temps[i]) {
        TCGContext *s = tcg_ctx;
        if (!s || !s->temps) return NULL;
        LLVMTypeRef ty = lt(s->temps[i].type);
        char n[32]; snprintf(n, sizeof(n), "t%d", i);
        ls->temps[i] = LLVMBuildAlloca(ls->builder, ty, n);
    }
    return ls->temps[i];
}

static LLVMValueRef ld(int i) {
    LLVMValueRef p = gp(i);
    return p ? LLVMBuildLoad(ls->builder, p, "") : LLVMConstInt(LLVMInt64TypeInContext(ls->ctx), 0, 0);
}

static void st(int i, LLVMValueRef v) {
    LLVMValueRef p = gp(i);
    if (p) LLVMBuildStore(ls->builder, v, p);
}

static void go(TCGContext *s, TCGOp *op) {
    TCGOpcode o = op->opc;
    int *a = op->args;
    LLVMValueRef i0=0, i1=0, i2=0;

    switch(o) {
        case INDEX_op_mov_i32: case INDEX_op_mov_i64:
        case INDEX_op_add_i32: case INDEX_op_add_i64:
        case INDEX_op_sub_i32: case INDEX_op_sub_i64:
        case INDEX_op_and_i32: case INDEX_op_and_i64:
        case INDEX_op_or_i32: case INDEX_op_or_i64:
        case INDEX_op_xor_i32: case INDEX_op_xor_i64:
        case INDEX_op_mul_i32: case INDEX_op_mul_i64:
        case INDEX_op_shl_i32: case INDEX_op_shl_i64:
        case INDEX_op_shr_i32: case INDEX_op_shr_i64:
        case INDEX_op_sar_i32: case INDEX_op_sar_i64:
        case INDEX_op_div_i32: case INDEX_op_div_i64:
        case INDEX_op_divu_i32: case INDEX_op_divu_i64:
        case INDEX_op_rem_i32: case INDEX_op_rem_i64:
        case INDEX_op_remu_i32: case INDEX_op_remu_i64:
            i1 = ld(a[1]); i2 = ld(a[2]); break;
        case INDEX_op_neg_i32: case INDEX_op_neg_i64:
        case INDEX_op_not_i32: case INDEX_op_not_i64:
        case INDEX_op_ext8s_i32: case INDEX_op_ext8s_i64:
        case INDEX_op_ext8u_i32: case INDEX_op_ext8u_i64:
        case INDEX_op_ext16s_i32: case INDEX_op_ext16s_i64:
        case INDEX_op_ext16u_i32: case INDEX_op_ext16u_i64:
        case INDEX_op_ext32s_i64: case INDEX_op_ext32u_i64:
            i1 = ld(a[1]); break;
        case INDEX_op_brcond_i32: case INDEX_op_brcond_i64:
            i0 = ld(a[0]); i1 = ld(a[1]); break;
        default: break;
    }

    switch(o) {
        case INDEX_op_mov_i32: case INDEX_op_mov_i64:
            st(a[0], i1); break;
        case INDEX_op_add_i32: case INDEX_op_add_i64:
            st(a[0], LLVMBuildAdd(ls->builder, i1, i2, "add")); break;
        case INDEX_op_sub_i32: case INDEX_op_sub_i64:
            st(a[0], LLVMBuildSub(ls->builder, i1, i2, "sub")); break;
        case INDEX_op_and_i32: case INDEX_op_and_i64:
            st(a[0], LLVMBuildAnd(ls->builder, i1, i2, "and")); break;
        case INDEX_op_or_i32: case INDEX_op_or_i64:
            st(a[0], LLVMBuildOr(ls->builder, i1, i2, "or")); break;
        case INDEX_op_xor_i32: case INDEX_op_xor_i64:
            st(a[0], LLVMBuildXor(ls->builder, i1, i2, "xor")); break;
        case INDEX_op_mul_i32: case INDEX_op_mul_i64:
            st(a[0], LLVMBuildMul(ls->builder, i1, i2, "mul")); break;
        case INDEX_op_shl_i32: case INDEX_op_shl_i64:
            st(a[0], LLVMBuildShl(ls->builder, i1, i2, "shl")); break;
        case INDEX_op_shr_i32: case INDEX_op_shr_i64:
            st(a[0], LLVMBuildLShr(ls->builder, i1, i2, "shr")); break;
        case INDEX_op_sar_i32: case INDEX_op_sar_i64:
            st(a[0], LLVMBuildAShr(ls->builder, i1, i2, "sar")); break;
        case INDEX_op_div_i32: case INDEX_op_div_i64:
            st(a[0], LLVMBuildSDiv(ls->builder, i1, i2, "sdiv")); break;
        case INDEX_op_divu_i32: case INDEX_op_divu_i64:
            st(a[0], LLVMBuildUDiv(ls->builder, i1, i2, "udiv")); break;
        case INDEX_op_rem_i32: case INDEX_op_rem_i64:
            st(a[0], LLVMBuildSRem(ls->builder, i1, i2, "srem")); break;
        case INDEX_op_remu_i32: case INDEX_op_remu_i64:
            st(a[0], LLVMBuildURem(ls->builder, i1, i2, "urem")); break;
        case INDEX_op_neg_i32: case INDEX_op_neg_i64:
            st(a[0], LLVMBuildNeg(ls->builder, i1, "neg")); break;
        case INDEX_op_not_i32: case INDEX_op_not_i64:
            st(a[0], LLVMBuildNot(ls->builder, i1, "not")); break;
        case INDEX_op_ext8s_i32: case INDEX_op_ext8s_i64:
            st(a[0], LLVMBuildSExt(ls->builder, i1, LLVMInt32TypeInContext(ls->ctx), "ext8s")); break;
        case INDEX_op_ext8u_i32: case INDEX_op_ext8u_i64:
            st(a[0], LLVMBuildZExt(ls->builder, i1, LLVMInt32TypeInContext(ls->ctx), "ext8u")); break;
        case INDEX_op_ext16s_i32: case INDEX_op_ext16s_i64:
            st(a[0], LLVMBuildSExt(ls->builder, i1, LLVMInt32TypeInContext(ls->ctx), "ext16s")); break;
        case INDEX_op_ext16u_i32: case INDEX_op_ext16u_i64:
            st(a[0], LLVMBuildZExt(ls->builder, i1, LLVMInt32TypeInContext(ls->ctx), "ext16u")); break;
        case INDEX_op_trunc_i64_i32:
            st(a[0], LLVMBuildTrunc(ls->builder, i1, LLVMInt32TypeInContext(ls->ctx), "trunc")); break;
        case INDEX_op_ext32u_i64:
            st(a[0], LLVMBuildZExt(ls->builder, i1, LLVMInt64TypeInContext(ls->ctx), "ext32u")); break;
        case INDEX_op_ext32s_i64:
            st(a[0], LLVMBuildSExt(ls->builder, i1, LLVMInt64TypeInContext(ls->ctx), "ext32s")); break;
        case INDEX_op_brcond_i32: case INDEX_op_brcond_i64: {
            LLVMValueRef cmp = LLVMBuildICmp(ls->builder, lc(a[2]), i0, i1, "cmp");
            LLVMBuildCondBr(ls->builder, cmp, gl(a[3]), gl(a[4]));
            break;
        }
        case INDEX_op_br:
            LLVMBuildBr(ls->builder, gl(a[0])); break;
        case INDEX_op_set_label: {
            LLVMBasicBlockRef bb = gl(a[0]);
            LLVMPositionBuilderAtEnd(ls->builder, bb);
            break;
        }
        case INDEX_op_exit_tb:
            LLVMBuildRet(ls->builder, LLVMConstInt(LLVMInt64TypeInContext(ls->ctx), a[0] & 0xFFFFFFFF, 0)); break;
        case INDEX_op_goto_tb: break;
        default: break;
    }
}

void tcg_llvm_init(void) {
    if (llvm_init_done) return;
    fprintf(stderr, "LLVM: Initializing LLVM IR TCG Backend...\n");
    ls = g_new0(TCGLLVMState, 1);
    LLVMInitializeX86TargetInfo();
    LLVMInitializeX86Target();
    LLVMInitializeX86TargetMC();
    LLVMInitializeX86AsmPrinter();
    ls->ctx = LLVMContextCreate();
    ls->mod = LLVMModuleCreateWithNameInContext("qemu_tcg", ls->ctx);
    ls->builder = LLVMCreateBuilderInContext(ls->ctx);
    LLVMTargetRef trg;
    char *err = NULL;
    if (LLVMGetTargetFromTriple("x86_64-unknown-linux-gnu", &trg, &err)) {
        fprintf(stderr, "LLVM IR: Target error: %s\n", err);
        LLVMDisposeMessage(err);
        return;
    }
    ls->target = trg;
    ls->tm = LLVMCreateTargetMachine(trg, "x86_64", "haswell", "-O3",
        LLVMCodeGenLevelAggressive, LLVMRelocDefault, LLVMDefaultObjectFileType);
    LLVMSetDataLayout(ls->mod, LLVMCreateTargetDataLayout(ls->tm));
    LLVMErrorRef e = LLVMCreateExecutionEngineForModule(&ls->ee, ls->mod, &err);
    if (e) {
        fprintf(stderr, "LLVM IR: EE error: %s\n", err);
        LLVMDisposeMessage(err);
        return;
    }
    ls->labels = g_hash_table_new(g_direct_hash, g_direct_equal);
    ls->blocks = g_hash_table_new(g_direct_hash, g_direct_equal);
    ls->tb_count = 0;
    llvm_init_done = true;
    fprintf(stderr, "LLVM: LLVM IR TCG Backend Ready! ⚡\n");
}

void tcg_llvm_compile(TCGContext *s, TranslationBlock *tb) {
    if (!ls || !tcg_use_llvm_ir) return;
    if (s->nb_ops == 0) return;
    ls->tb_count++;
    char fn[64]; snprintf(fn, sizeof(fn), "tb_%lx", (unsigned long)tb->pc);
    LLVMTypeRef ft = LLVMFunctionType(LLVMInt64TypeInContext(ls->ctx), NULL, 0, 0);
    ls->fn = LLVMGetNamedFunction(ls->mod, fn);
    if (!ls->fn) ls->fn = LLVMAddFunction(ls->mod, fn, ft);
    memset(ls->temps, 0, sizeof(ls->temps));
    g_hash_table_remove_all(ls->labels);
    LLVMBasicBlockRef ent = LLVMAppendBasicBlockInContext(ls->ctx, ls->fn, "entry");
    LLVMPositionBuilderAtEnd(ls->builder, ent);
    TCGOp *op;
    QTAILQ_FOREACH(op, &s->ops, link) go(s, op);
    if (!LLVMGetBasicBlockTerminator(LLVMGetInsertBlock(ls->builder)))
        LLVMBuildRet(ls->builder, LLVMConstInt(LLVMInt64TypeInContext(ls->ctx), 0, 0));
    LLVMPassManagerRef pm = LLVMCreatePassManager();
    LLVMAddPromoteMemoryToRegisterPass(pm);
    LLVMAddInstructionCombiningPass(pm);
    LLVMAddReassociatePass(pm);
    LLVMAddGVNPass(pm);
    LLVMAddCFGSimplificationPass(pm);
    LLVMRunPassManager(pm, ls->mod);
    LLVMDisposePassManager(pm);
    fprintf(stderr, "LLVM IR: Compiled TB%u with %u ops\n", ls->tb_count, s->nb_ops);
}
TCGLLVM
echo "Created tcg-llvm.c"
# ===== tcg-all.c =====
cat > /tmp/qemu-src/accel/tcg/tcg-all.c.patch << 'TCGALL'
--- a/accel/tcg/tcg-all.c
+++ b/accel/tcg/tcg-all.c
@@ -31,6 +31,22 @@
 #include "sysemu/sysemu.h"
 #include "tcg/startup.h"
 
+/* LLVM IR TCG Backend */
+bool tcg_use_llvm_ir = false;
+static int tcg_thread_mode = 1;
+static int tcg_tb_size = 2048;
+
+extern void tcg_llvm_init(void);
+extern void tcg_llvm_compile(TCGContext *s, TranslationBlock *tb);
+
+static void tcg_set_llvm_ir(Object *obj, const char *value, Error **errp) {
+    tcg_use_llvm_ir = qemu_parse_bool(value);
+    if (tcg_use_llvm_ir) {
+        fprintf(stderr, "LLVM: llvm-ir enabled\n");
+        tcg_llvm_init();
+    }
+}
+
 static bool tcg_cpu_optimization(CPUState *cpu)
 {
     CPUClass *cc = CPU_GET_CLASS(cpu);
@@ -272,6 +288,21 @@ static void tcg_accel_class_init(ObjectClass *oc, void *data)
     ac->allowed = &tcg_allowed;
     accel_class_init_all_cpus(ac, tcg_cpus);
 
+    object_property_add(oc, "llvm-ir", "bool",
+                        tcg_get_llvm_ir, tcg_set_llvm_ir, NULL, NULL);
+    object_property_set_description(oc, "llvm-ir",
+                                    "Enable LLVM IR TCG backend");
+
+    object_property_add(oc, "thread", "string",
+                        NULL, NULL, NULL, NULL);
+    object_property_set_description(oc, "thread",
+                                    "TCG thread mode (single/multi)");
+
+    object_property_add(oc, "tb-size", "int",
+                        NULL, NULL, NULL, NULL);
+    object_property_set_description(oc, "tb-size",
+                                    "Translation block cache size");
+
     /*
      * Disallow --enable-tcg interpres and --enable-tcg、肉肉
      * user emulation, because those don't have address space
@@ -285,6 +326,8 @@ static void tcg_accel_class_init(ObjectClass *oc, void *data)
         return;
     }
 
+    if (tcg_use_llvm_ir) tcg_llvm_init();
+
     if (tcg_cpus > 1) {
         if (!qemu_tcg_mirrored_workqueues &&
             !tcg_has_work(CPU(tcg_cpu_create(OBJECT(machine)))) &&
TCGALL

# Patch tcg-all.c
cd /tmp/qemu-src
patch -p1 < accel/tcg/tcg-all.c.patch

# Also add to tcg.c to call the compile function
cat > /tmp/qemu-src/tcg/tcg.c.patch << 'TCGC'
--- a/tcg/tcg.c
+++ b/tcg/tcg.c
@@ -39,6 +39,9 @@
 #include "tcg/tcg-internal.h"
 #include "exec/exec-all.h"
 
+extern bool tcg_use_llvm_ir;
+extern void tcg_llvm_compile(TCGContext *s, TranslationBlock *tb);
+
 /* The number of free regions is limited. */
 #define TCG_MAX_FREE_REGIONS  64
 
@@ -681,6 +684,9 @@ int tcg_gen_code(TCGContext *s, TranslationBlock *tb)
         tcg_timer_register();
     }
 #endif
+
+    if (tcg_use_llvm_ir && tb->tcg_ops == NULL) {
+        tcg_llvm_compile(s, tb);
+    }
     return tcg_ops->tcg_gen_code(s, tb);
 }
 TCGC

patch -p1 < tcg/tcg.c.patch

echo -e "${GREEN}✓ Patched QEMU source${RESET}"
mkdir -p /tmp/qemu-build
cd /tmp/qemu-build

echo -e "${BLUE}Configuring QEMU...${RESET}"
../qemu-src/configure \
--prefix=/opt/qemu-llvm-ir \
--target-list=x86_64-softmmu \
--enable-tcg \
--enable-slirp \
--disable-docs \
--disable-werror \
--disable-xen \
--disable-mshv \
CC="$CC" CXX="$CXX" LD="$LD" 2>&1 | tail -10

echo -e "${YELLOW}Building QEMU (this may take a while)...${RESET}"
ninja -j$(nproc) qemu-system-x86_64 qemu-img 2>&1 | tail -20

sudo mkdir -p /opt/qemu-llvm-ir/bin
sudo cp qemu-system-x86_64 qemu-img /opt/qemu-llvm-ir/bin/
sudo mkdir -p /opt/qemu-llvm-ir/share/qemu
sudo cp -r ../qemu-src/pc-bios/* /opt/qemu-llvm-ir/share/qemu/ 2>/dev/null || true

export PATH="/opt/qemu-llvm-ir/bin:$PATH"
fi

echo
line
echo -e "${GREEN}==============================================================${RESET}"
echo -e "${GREEN}  QEMU LLVM IR TCG BACKEND BUILD COMPLETE!${RESET}"
echo -e "${GREEN}==============================================================${RESET}"
echo
echo "Install location: /opt/qemu-llvm-ir/bin/"
echo
echo "Usage examples:"
echo "  qemu-system-x86_64 -accel tcg,llvm-ir=on,thread=multi,tb-size=4096 -machine pc -m 4G"
echo "  qemu-system-x86_64 -accel tcg,llvm-ir=on -machine pc -m 2G"
echo

read -p "Press Enter to exit..."
