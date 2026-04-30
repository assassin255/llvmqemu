/*
 * QEMU LLVM JIT accelerator
 *
 * Registers as the "llvm" accelerator: use with -accel llvm
 *
 * This accelerator extends QEMU's TCG (Tiny Code Generator) by registering
 * a separate "llvm" accelerator name.  It inherits all of TCG's
 * infrastructure via QOM type inheritance:
 *
 *   - Guest-code translation (TCG frontend: disassembler → TCG IR)
 *   - vCPU thread management (round-robin or MTTCG scheduler)
 *   - CPU realize / unrealize hooks
 *   - GDB stub / single-step support
 *   - tcg_allowed flag management
 *
 * The only override performed here is ac->name = "llvm", which makes the
 * accelerator selectable via `-accel llvm` and visible in `-accel help`.
 *
 * Architecture (current / planned):
 *
 *   Guest binary
 *       │
 *       ▼  TCG frontend (target-specific disassembler → TCG IR)
 *   TCG IR  (platform-independent intermediate representation)
 *       │
 *       ├─[now]──► TCG backend (native code generation via TCG)
 *       └─[future] LLVM ORC JIT backend (optimizing IR → native code)
 *
 * QOM type hierarchy implemented by this file:
 *
 *   TYPE_ACCEL ("accel")
 *     └── TYPE_TCG_ACCEL  ("tcg-accel")           [QEMU built-in]
 *           └── TYPE_LLVM_ACCEL ("llvm-accel")    ← this file
 *
 *   TYPE_ACCEL_OPS ("accel-ops")
 *     └── ACCEL_OPS_NAME("tcg") ("tcg-accel-ops") [QEMU built-in]
 *           └── ACCEL_OPS_NAME("llvm")             ← this file
 *               ("llvm-accel-ops")
 *
 * How accel lookup works (QEMU 11.0.0):
 *   accel_find("llvm")
 *     → looks for ACCEL_CLASS_NAME("llvm") = "llvm-accel"      ✓
 *   accel_init_ops_interfaces(ac)
 *     → looks for ac->name + "-ops" = "llvm-accel-ops"         ✓
 *       = ACCEL_OPS_NAME("llvm")
 *   tcg_accel_ops_init() (inherited ops_init) calls
 *     qemu_tcg_mttcg_enabled() → TCG_STATE(current_accel())
 *     This works because our AccelState IS-A TCGState (QOM subtype). ✓
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/module.h"
#include "qemu/accel.h"
#include "accel/accel-ops.h"
#include "accel/accel-cpu-ops.h"

/*
 * String constants — defined locally to avoid depending on tcg-all.c internals.
 * These resolve to the same values as TYPE_TCG_ACCEL and ACCEL_OPS_NAME("tcg")
 * defined within the TCG source tree.
 */
#define TYPE_LLVM_ACCEL  ACCEL_CLASS_NAME("llvm")   /* "llvm-accel"     */
#define TYPE_TCG_ACCEL   ACCEL_CLASS_NAME("tcg")    /* "tcg-accel"      */

/* =========================================================================
 * AccelClass — "llvm-accel"
 * ========================================================================= */

static void llvm_accel_class_init(ObjectClass *oc, const void *data)
{
    AccelClass *ac = ACCEL_CLASS(oc);

    /*
     * Override the accelerator name.
     *
     * This is the *only* change relative to the TCG parent class:
     *   - `-accel help` lists "llvm"
     *   - `-accel llvm` on the command line selects this accelerator
     *
     * All other AccelClass fields are inherited from tcg_accel_class_init():
     *   ac->init_machine      = tcg_init_machine
     *   ac->cpu_common_realize   = tcg_exec_realizefn
     *   ac->cpu_common_unrealize = tcg_exec_unrealizefn
     *   ac->get_stats         = tcg_get_stats
     *   ac->allowed           = &tcg_allowed
     *   ac->gdbstub_supported_sstep_flags = tcg_gdbstub_supported_sstep_flags
     *   … (QOM properties: thread, tb-size, split-wx, one-insn-per-tb)
     */
    ac->name = "llvm";
}

static const TypeInfo llvm_accel_type = {
    .name       = TYPE_LLVM_ACCEL,  /* "llvm-accel" */
    .parent     = TYPE_TCG_ACCEL,   /* "tcg-accel"  */
    .class_init = llvm_accel_class_init,
    /*
     * instance_size / instance_init / instance_finalize are all inherited
     * from TYPE_TCG_ACCEL.  Our AccelState allocation shares TCGState
     * layout — TCG_STATE(current_accel()) works correctly because our
     * type is a QOM subtype of TYPE_TCG_ACCEL.
     */
};
module_obj(TYPE_LLVM_ACCEL);

/* =========================================================================
 * AccelOpsClass — "llvm-accel-ops"
 * =========================================================================
 *
 * Inherits from ACCEL_OPS_NAME("tcg") = "tcg-accel-ops", which carries:
 *
 *   ops->ops_init = tcg_accel_ops_init
 *
 * tcg_accel_ops_init sets up:
 *   - ops->create_vcpu_thread  (mttcg or rr scheduler)
 *   - ops->kick_vcpu_thread
 *   - ops->handle_interrupt    (tcg_handle_interrupt or icount variant)
 *   - ops->cpu_reset_hold
 *   - ops->supports_guest_debug / insert/remove_breakpoint
 *
 * The .abstract = true flag mirrors the TCG ops type; QEMU's accel machinery
 * requires the ops class to be abstract (it is never instantiated directly).
 */

static void llvm_accel_ops_class_init(ObjectClass *oc, const void *data)
{
    /* Inherit everything from TCG AccelOpsClass — nothing to override yet. */
    (void)oc;
    (void)data;
}

static const TypeInfo llvm_accel_ops_type = {
    .name       = ACCEL_OPS_NAME("llvm"),   /* "llvm-accel-ops" */
    .parent     = ACCEL_OPS_NAME("tcg"),    /* "tcg-accel-ops"  */
    .class_init = llvm_accel_ops_class_init,
    .abstract   = true,
};
module_obj(ACCEL_OPS_NAME("llvm"));

/* =========================================================================
 * Type registration
 * ========================================================================= */

static void llvm_accel_register_types(void)
{
    type_register_static(&llvm_accel_type);
    type_register_static(&llvm_accel_ops_type);
}

type_init(llvm_accel_register_types);
