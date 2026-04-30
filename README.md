# llvmqemu — `-accel llvm` for QEMU 11.0.0

A proper `−accel llvm` accelerator for QEMU 11.0.0, implemented as a
QOM subtype of the TCG accelerator.

## What this is

This repository provides patch files and a one-shot build script that add a
new `-accel llvm` accelerator to QEMU 11.0.0.  Guest execution currently uses
TCG's existing infrastructure; the "llvm" name is registered as a distinct,
selectable accelerator with clean hook points for a future LLVM ORC JIT backend.

### Architecture

```
Guest binary
    │
    ▼  TCG frontend (target disassembler → TCG IR)
TCG IR  (platform-independent intermediate representation)
    │
    ├─ [now]    TCG backend  (native JIT via existing TCG)
    └─ [future] LLVM ORC JIT (IR → optimized native code via LLVM)
```

### QOM type hierarchy

```
TYPE_ACCEL ("accel")
  └── TYPE_TCG_ACCEL  ("tcg-accel")           [QEMU 11.0.0 built-in]
        └── TYPE_LLVM_ACCEL ("llvm-accel")    ← accel/llvm/llvm-accel.c

TYPE_ACCEL_OPS ("accel-ops")
  └── ACCEL_OPS_NAME("tcg")  ("tcg-accel-ops")  [QEMU 11.0.0 built-in]
        └── ACCEL_OPS_NAME("llvm") ("llvm-accel-ops")  ← same file
```

The LLVM accelerator inherits *all* of TCG's initialization, CPU
realize/unrealize hooks, vCPU thread management (round-robin / MTTCG
scheduler), and GDB stub support.  The single override is `ac->name = "llvm"`,
which makes the accelerator selectable and visible to the user.

## Repository layout

```
accel/
  llvm/
    llvm-accel.c          — accelerator implementation (151 lines)
    meson.build           — Meson/Ninja build rules
patches/
  0001-accel-add-llvm-subdir.patch   — patch for accel/meson.build
old/
  tcg-all.c               — previous approach (TCG extension, archived)
  tcg-llvm.c              — previous stub (archived)
  *.sh                    — previous build scripts (archived)
build-qemu-llvm-v11.sh    — one-shot build & verification script
README.md                 — this file
```

## Quick start

```bash
chmod +x build-qemu-llvm-v11.sh
./build-qemu-llvm-v11.sh
```

The script will:
1. Install build dependencies (Debian/Ubuntu)
2. Clone QEMU 11.0.0 from GitHub
3. Copy `accel/llvm/` into the QEMU source tree
4. Patch `accel/meson.build` to add `subdir('llvm')`
5. Configure and build (`x86_64-softmmu` target)
6. Verify that `qemu-system-x86_64 -accel help` lists `llvm`

### Manual application (without the build script)

```bash
# 1. Clone QEMU 11.0.0
git clone --depth=1 --branch v11.0.0 https://github.com/qemu/qemu.git qemu-src

# 2. Copy the accelerator source
mkdir -p qemu-src/accel/llvm
cp accel/llvm/llvm-accel.c  qemu-src/accel/llvm/
cp accel/llvm/meson.build   qemu-src/accel/llvm/

# 3. Patch accel/meson.build
patch -d qemu-src -p1 < patches/0001-accel-add-llvm-subdir.patch

# 4. Build
cd qemu-src
./configure --target-list=x86_64-softmmu --enable-tcg --disable-docs
ninja -C build -j$(nproc)

# 5. Test
./build/qemu-system-x86_64 -accel help
# → Accelerators supported in this build:
# →   tcg
# →   llvm          ← new!
```

## Using `-accel llvm`

```bash
./qemu-src/build/qemu-system-x86_64 \
    -accel llvm \
    -machine pc \
    -m 256 \
    -nographic \
    -kernel /boot/vmlinuz \
    -append "console=ttyS0"
```

All standard QEMU TCG options work with `-accel llvm`:
- `-accel llvm,thread=single` / `thread=multi`
- `-accel llvm,tb-size=256`
- `-accel llvm,one-insn-per-tb=on`

## Future work

- [ ] Hook into `tcg_gen_code()` to capture TCG IR per translation block
- [ ] Translate TCG IR → LLVM IR using LLVM C API
- [ ] JIT-compile LLVM IR via LLVM ORC ExecutionSession
- [ ] Replace TCG-generated code pointer with LLVM-compiled function
- [ ] Optimization passes (inlining, loop opts, SIMD vectorization)
- [ ] Profile-guided recompilation of hot translation blocks

## Tested with

- QEMU 11.0.0 (tag `v11.0.0`)
- Ubuntu 22.04 / 24.04 (x86-64 host)
- Meson ≥ 1.0, Ninja, GCC 12 / Clang 15
