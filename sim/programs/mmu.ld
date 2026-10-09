/* SPDX-License-Identifier: CERN-OHL-S-2.0
 * Copyright 2026 Romain Dolbeau
 * Source location: https://github.com/MelkhiorVintageComputing/RD68031
 */

/* RD68031 -- the link map of the MMU test programs (sim/programs/mmu_*.S).
 *
 * flat.ld's, with two more sections at fixed addresses in the 64 KB of the
 * core harness's 32-bit port: the translation tables at $9000 and the pages
 * they map to at $C000, so that a program's descriptors and the data a test
 * expects to read through them are in the image, at physical addresses the
 * program and the testbench both know -- sim/programs/mmu_common.inc. */

ENTRY(_start)

MEMORY
{
  ram (rwx) : ORIGIN = 0x00000000, LENGTH = 0x00010000
}

SECTIONS
{
  .vectors 0x00000000 : { KEEP(*(.vectors)) } > ram

  .text 0x00001000 :
  {
    *(.text.startup)
    *(.text*)
    *(.rodata*)
  } > ram

  .data : { *(.data*) } > ram
  .bss  : { __bss_start = .; *(.bss*) *(COMMON) __bss_end = .; } > ram

  /* The results area at $8000 is the program's own; nothing is linked there. */
  ASSERT(. <= 0x8000, "an MMU test program runs into its results area")

  .tables 0x00009000 : { KEEP(*(.tables)) } > ram
  ASSERT(. <= 0xC000, "the translation tables run into the pages")
  .pages  0x0000C000 : { KEEP(*(.pages)) } > ram
  ASSERT(. <= 0xE000, "the pages run into the user area")

  _end = .;

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
