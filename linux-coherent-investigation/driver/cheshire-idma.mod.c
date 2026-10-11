#include <linux/module.h>
#include <linux/export-internal.h>
#include <linux/compiler.h>

MODULE_INFO(name, KBUILD_MODNAME);

__visible struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};

KSYMTAB_FUNC(cheshire_idma_test_prearm_source, "");
SYMBOL_FLAGS(cheshire_idma_test_prearm_source, 0x01);

MODULE_INFO(depends, "");

MODULE_ALIAS("of:N*T*Cpulp,cheshire-idma-v0.6.4-test");
MODULE_ALIAS("of:N*T*Cpulp,cheshire-idma-v0.6.4-testC*");
