OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
  code (rwx) : ORIGIN = 0x20000000, LENGTH = 64K
}

SECTIONS {
  .text : {
    *(.text.start)
    *(.text)
    *(.text.*)
  } > code

  .rodata : ALIGN(16) {
    *(.rodata)
    *(.rodata.*)
  } > code

  .data : ALIGN(16) {
    *(.data)
    *(.data.*)
    *(.sdata)
    *(.sdata.*)
  } > code

  .bss : ALIGN(16) {
    __bss_start = .;
    *(.bss)
    *(.bss.*)
    *(.sbss)
    *(.sbss.*)
    __bss_end = .;
  } > code

  __global_pointer$ = ADDR(.data) + 0x800;
  __stack_top = ORIGIN(code) + LENGTH(code) - 16;

  /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}

PROVIDE(__dma_base_addr__ = 0x01000000);

