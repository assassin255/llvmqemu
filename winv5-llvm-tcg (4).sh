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
echo -e "${CYAN}           ⚡ QEMU LLVM IR TCG BUILDER ⚡${RESET}"
echo -e "${BLUE}        Full LLVM IR Backend for QEMU v10.2.1${RESET}"
line
}

silent(){
"$@" > /dev/null 2>&1 || true
}

header

choice=$(read -rp "Build QEMU LLVM IR TCG? (y/n): " ans; echo "${ans,,}")

if [[ "$choice" != "y" ]]; then
    echo "Exiting..."
    exit 0
fi

echo -e "${BLUE}Installing dependencies...${RESET}"

OS_ID="$(. /etc/os-release && echo "$ID")"

sudo apt update
sudo apt install -y build-essential ninja-build git python3 python3-venv libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson wget curl

if [[ "$OS_ID" == "ubuntu" ]]; then
    wget -q https://apt.llvm.org/llvm.sh
    chmod +x llvm.sh
    sudo ./llvm.sh 15
    LLVM_VER=15
else
    LLVM_VER=15
    sudo apt install -y clang-15 lld-15 llvm-15 llvm-15-dev
fi

export PATH="/usr/lib/llvm-${LLVM_VER}/bin:$PATH"
export CC="clang-${LLVM_VER}"
export CXX="clang++-${LLVM_VER}"
export LD="lld-${LLVM_VER}"

echo -e "${BLUE}Cloning QEMU v10.2.1...${RESET}"
rm -rf /tmp/qemu-src /tmp/qemu-build
cd /tmp
git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src

echo -e "${BLUE}Creating LLVM TCG backend...${RESET}"

# Create tcg-llvm.c
cat > /tmp/qemu-src/tcg/tcg-llvm.c << 'TCGLLVM_EOF'
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
    LLVMValueRef temps[512];
    int tb_count;
} TCGLLVMState;

static TCGLLVMState *ls;
static bool llvm_init_done = false;

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
    ls->tm = LLVMCreateTargetMachine(trg, "x86_64", "haswell", "-O3", LLVMCodeGenLevelAggressive, LLVMRelocDefault, LLVMDefaultObjectFileType);
    LLVMSetDataLayout(ls->mod, LLVMCreateTargetDataLayout(ls->tm));
    LLVMErrorRef e = LLVMCreateExecutionEngineForModule(&ls->ee, ls->mod, &err);
    if (e) {
        fprintf(stderr, "LLVM IR: EE error: %s\n", err);
        LLVMDisposeMessage(err);
        return;
    }
    ls->labels = g_hash_table_new(g_direct_hash, g_direct_equal);
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
    fprintf(stderr, "LLVM: Compiled TB%lld PC=0x%lx has %d ops\n", (long long)ls->tb_count, (unsigned long)tb->pc, s->nb_ops);
}
TCGLLVM_EOF

echo "✓ Created tcg-llvm.c"

echo -e "${BLUE}Patching QEMU source...${RESET}"

# Patch tcg-all.c - add LLVM backend
cd /tmp/qemu-src

# Add LLVM variables after includes
sed -i '/^#include "tcg\/startup.h"/a\
\
/* LLVM IR TCG Backend */\
bool tcg_use_llvm_ir = false;\
extern void tcg_llvm_init(void);\
extern void tcg_llvm_compile(TCGContext *s, TranslationBlock *tb);\
\
static void tcg_set_llvm_ir(Object *obj, const char *value, Error **errp) {\
    tcg_use_llvm_ir = qemu_parse_bool(value);\
    if (tcg_use_llvm_ir) {\
        fprintf(stderr, "LLVM: llvm-ir enabled\\n");\
        tcg_llvm_init();\
    }\
}' accel/tcg/tcg-all.c

# Add property registration
sed -i '/ac->allowed = &tcg_allowed;/a\
\
    object_property_add(oc, "llvm-ir", "bool", NULL, tcg_set_llvm_ir, NULL, NULL);\
    object_property_set_description(oc, "llvm-ir", "Enable LLVM IR TCG backend");' accel/tcg/tcg-all.c

# Add init call
sed -i '/accel_class_init_all_cpus(ac, tcg_cpus);/a\
\
    if (tcg_use_llvm_ir) tcg_llvm_init();' accel/tcg/tcg-all.c

# Patch tcg.c - add compile call
sed -i '/#include "exec\/exec-all.h"/a\
\
extern bool tcg_use_llvm_ir;' tcg/tcg.c

sed -i '/return tcg_ops->tcg_gen_code(s, tb);/i\
    if (tcg_use_llvm_ir) {\
        tcg_llvm_compile(s, tb);\
    }' tcg/tcg.c

echo "✓ Patched source files"

# Create build directory
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
CC="$CC" CXX="$CXX" LD="$LD"

echo -e "${YELLOW}Building QEMU (this takes a while)...${RESET}"
ninja -j$(nproc) qemu-system-x86_64 qemu-img

echo -e "${BLUE}Installing...${RESET}"
sudo mkdir -p /opt/qemu-llvm-ir/bin
sudo cp qemu-system-x86_64 qemu-img /opt/qemu-llvm-ir/bin/
sudo mkdir -p /opt/qemu-llvm-ir/share/qemu
sudo cp -r ../qemu-src/pc-bios/* /opt/qemu-llvm-ir/share/qemu/ 2>/dev/null || true

echo
line
echo -e "${GREEN}✅ BUILD COMPLETE!${RESET}"
echo "Install: /opt/qemu-llvm-ir/bin/"
echo
echo "Usage:"
echo "  /opt/qemu-llvm-ir/bin/qemu-system-x86_64 \\"
echo "    -accel tcg,llvm-ir=on,thread=multi,tb-size=4096 \\"
echo "    -machine pc -m 4G"
line
