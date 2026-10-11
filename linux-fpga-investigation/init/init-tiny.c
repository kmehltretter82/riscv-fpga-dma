// SPDX-License-Identifier: GPL-2.0-only
/* Freestanding initramfs controller for the Cheshire Linux+iDMA smoke test. */

#include "mininit.h"

static const char fail_prefix[] = "FPGA-LINUX-DMA-FAIL: ";

int mininit_main(void)
{
	unsigned long dma_errors, submitted, completed, timeouts, cache_ops;
	char *log;

	mi_setup_console(fail_prefix);
	mi_puts("FPGA-LINUX-DMA: init started");
	mi_mount_one(fail_prefix, "proc", "/proc", "proc");
	mi_mount_one(fail_prefix, "sysfs", "/sys", "sysfs");
	mi_mount_one(fail_prefix, "debugfs", "/sys/kernel/debug", "debugfs");

	mi_load_module(fail_prefix, "/lib/modules/cheshire-idma.ko", "");
	mi_load_module(fail_prefix, "/lib/modules/dmatest.ko",
		       "iterations=8 threads_per_chan=1 max_channels=1 "
		       "test_buf_size=4096 timeout=10000 verbose=1 run=1 wait=1");

	dma_errors = mi_read_ulong(
		fail_prefix, "/sys/kernel/debug/dma-api/error_count");
	submitted = mi_read_ulong(
		fail_prefix, "/sys/module/cheshire_idma/parameters/submitted");
	completed = mi_read_ulong(
		fail_prefix, "/sys/module/cheshire_idma/parameters/completed");
	timeouts = mi_read_ulong(
		fail_prefix, "/sys/module/cheshire_idma/parameters/timeouts");
	cache_ops = mi_read_ulong(
		fail_prefix, "/sys/module/cheshire_idma/parameters/cache_ops");
	log = mi_kernel_log(fail_prefix);

	mi_puts_part("FPGA-LINUX-DMA:");
	mi_kv(" submitted=", submitted);
	mi_kv(" completed=", completed);
	mi_kv(" timeouts=", timeouts);
	mi_kv(" dma_api_errors=", dma_errors);
	mi_kv(" cache_ops=", cache_ops);
	mi_write(MI_STDOUT, "\n", 1);

	if (!mi_contains(log, "summary 8 tests, 0 failures"))
		mi_fail(fail_prefix, "missing successful dmatest summary", -1);
	if (!mi_contains(log,
			 "Cheshire whole-cache FENCE DMA maintenance enabled"))
		mi_fail(fail_prefix,
			"missing noncoherent cache-maintenance marker", -1);
	if (submitted != 8 || completed != 8 || timeouts || dma_errors)
		mi_fail(fail_prefix, "counter invariant", -1);
	if (cache_ops < 24)
		mi_fail(fail_prefix, "noncoherent cache-operation count", -1);

	mi_puts("FPGA-LINUX-DMA-PASS");
	mi_poweroff();
}
