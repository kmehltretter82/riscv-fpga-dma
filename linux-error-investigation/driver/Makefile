obj-m += cheshire-idma.o

# virt-dma.h is intentionally private to drivers/dma.  This out-of-tree
# prototype uses it only to prove the Linux integration path before proposing
# an in-tree driver and binding.
ccflags-y += -I$(srctree)/drivers/dma
