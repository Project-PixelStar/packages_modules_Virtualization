/*
 * Copyright 2022 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <common.h>

.set .L_MAIR_DEV_nGnRE,	0x04
.set .L_MAIR_MEM_WBWA,	0xff
.set .Lmairval, .L_MAIR_DEV_nGnRE | (.L_MAIR_MEM_WBWA << 8)

/* 4 KiB granule size for TTBR0_EL1. */
.set .L_TCR_TG0_4KB, 0x0 << 14
/* 4 KiB granule size for TTBR1_EL1. */
.set .L_TCR_TG1_4KB, 0x2 << 30
/* Disable translation table walk for TTBR1_EL1, generating a translation fault instead. */
.set .L_TCR_EPD1, 0x1 << 23
/* Translation table walks for TTBR0_EL1 are inner sharable. */
.set .L_TCR_SH_INNER, 0x3 << 12
/*
 * Translation table walks for TTBR0_EL1 are outer write-back read-allocate write-allocate
 * cacheable.
 */
.set .L_TCR_RGN_OWB, 0x1 << 10
/*
 * Translation table walks for TTBR0_EL1 are inner write-back read-allocate write-allocate
 * cacheable.
 */
.set .L_TCR_RGN_IWB, 0x1 << 8
/* Size offset for TTBR0_EL1 is 2**39 bytes (512 GiB). */
.set .L_TCR_T0SZ_512, 64 - 39
.set .Ltcrval, .L_TCR_TG0_4KB | .L_TCR_TG1_4KB | .L_TCR_EPD1 | .L_TCR_RGN_OWB
.set .Ltcrval, .Ltcrval | .L_TCR_RGN_IWB | .L_TCR_SH_INNER | .L_TCR_T0SZ_512

/* Stage 1 instruction access cacheability is unaffected. */
.set .L_SCTLR_ELx_I, 0x1 << 12
/* SP alignment fault if SP is not aligned to a 16 byte boundary. */
.set .L_SCTLR_ELx_SA, 0x1 << 3
/* Stage 1 data access cacheability is unaffected. */
.set .L_SCTLR_ELx_C, 0x1 << 2
/* EL0 and EL1 stage 1 MMU enabled. */
.set .L_SCTLR_ELx_M, 0x1 << 0
/* Privileged Access Never is unchanged on taking an exception to EL1. */
.set .L_SCTLR_EL1_SPAN, 0x1 << 23
/* All writable memory regions are treated as XN. */
.set .L_SCTLR_EL1_WXN, 0x1 << 19
/* SETEND instruction disabled at EL0 in aarch32 mode. */
.set .L_SCTLR_EL1_SED, 0x1 << 8
/* Various IT instructions are disabled at EL0 in aarch32 mode. */
.set .L_SCTLR_EL1_ITD, 0x1 << 7
.set .L_SCTLR_EL1_RES1, (0x1 << 11) | (0x1 << 20) | (0x1 << 22) | (0x1 << 28) | (0x1 << 29)
.set .Lsctlrval, .L_SCTLR_ELx_M | .L_SCTLR_ELx_C | .L_SCTLR_ELx_SA | .L_SCTLR_EL1_ITD | .L_SCTLR_EL1_SED
.set .Lsctlrval, .Lsctlrval | .L_SCTLR_ELx_I | .L_SCTLR_EL1_SPAN | .L_SCTLR_EL1_RES1 | .L_SCTLR_EL1_WXN

/**
 * This is a generic entry point for an image. It carries out the operations required to prepare the
 * loaded image to be run. Specifically, it zeroes the bss section using registers x25 and above,
 * prepares the stack, enables floating point, and sets up the exception vector. It preserves x0-x3
 * for the Rust entry point, as these may contain boot parameters.
 */
.section .init.entry, "ax"
.global entry
entry:
	/* Load and apply the memory management configuration, ready to enable MMU and caches. */

	adr x30, vector_table_panic
	msr vbar_el1, x30

	/*
	 * Our load address is set by the host so validate it before proceeding.
	 */
	adr x30, entry
	mov_i x29, entry
	cmp x29, x30
	b.eq 1f
	reset_or_hang
1:

	adrp x30, idmap
	msr ttbr0_el1, x30

	mov_i x30, .Lmairval
	msr mair_el1, x30

	mov_i x30, .Ltcrval
	/* Copy the supported PA range into TCR_EL1.IPS. */
	mrs x29, id_aa64mmfr0_el1
	bfi x30, x29, #32, #4

	msr tcr_el1, x30

	mov_i x30, .Lsctlrval

	/*
	 * Ensure everything before this point has completed, then invalidate any potentially stale
	 * local TLB entries before they start being used.
	 */
	isb
	tlbi vmalle1
	ic iallu
	dsb nsh
	isb

	/*
	 * Configure sctlr_el1 to enable MMU and cache and don't proceed until this has completed.
	 */
	msr sctlr_el1, x30
	isb

	/* Disable trapping floating point access in EL1. */
	mrs x30, cpacr_el1
	orr x30, x30, #(0x3 << 20)
	msr cpacr_el1, x30
	isb

	/* Zero out the bss section. */
	adr_l x29, bss_begin
	adr_l x30, bss_end
0:	cmp x29, x30
	b.hs 1f
	stp xzr, xzr, [x29], #16
	b 0b

1:	/* Copy the data section. */
	adr_l x28, data_begin
	adr_l x29, data_end
	adr_l x30, data_lma
2:	cmp x28, x29
	b.ge 3f
	ldp q0, q1, [x30], #32
	stp q0, q1, [x28], #32
	b 2b

3:	/* Prepare the exception handler stack (SP_EL1). */
	adr_l x30, init_eh_stack_pointer
	msr spsel, #1
	mov sp, x30

	/* Prepare the main thread stack (SP_EL0). */
	adr_l x30, init_stack_pointer
	msr spsel, #0
	mov sp, x30

	/* Set up exception vector. */
	adr x30, vector_table_el1
	msr vbar_el1, x30

	/*
	 * Set up Bionic-compatible thread-local storage.
	 *
	 * Note that TPIDR_EL0 can't be configured from rust_entry because the
	 * compiler will dereference it during function entry to access
	 * __stack_chk_guard and Rust doesn't support LLVM's
	 * __attribute__((no_stack_protector)).
	 */
	adr_l x30, __bionic_tls
	msr tpidr_el0, x30

	/* Call into Rust code. */
	bl rust_entry

	/* Loop forever waiting for interrupts. */
4:	wfi
	b 4b

