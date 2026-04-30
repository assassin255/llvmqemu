# accel/llvm/meson.build
#
# Build rules for the QEMU LLVM JIT accelerator (-accel llvm).
#
# The LLVM accelerator is a QOM subtype of the TCG accelerator.
# It inherits all TCG machinery and registers under the name "llvm",
# making `-accel llvm` available as a distinct accelerator choice.
#
# Current status: functional stub — guest execution uses TCG's existing
# backend while the "llvm" name is registered.
#
# Future CONFIG_LLVM: when LLVM is detected, llvm-jit.cpp will be compiled
# in and TCG translation blocks will be post-processed through LLVM ORC JIT.

llvm_ss = ss.source_set()
llvm_ss.add(files('llvm-accel.c'))

# Add to system emulation build.
# (User-mode emulation inherits TCG's user-mode paths via QOM; the accel
# type registration from llvm-accel.c is compiled into system binaries only.)
system_ss.add_all(llvm_ss)
