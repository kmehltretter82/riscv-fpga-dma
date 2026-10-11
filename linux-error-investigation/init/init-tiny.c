// SPDX-License-Identifier: GPL-2.0-only
/* Freestanding controller for the Linux-visible AXI error matrix. */

#include "mininit.h"

static const char fail_prefix[] = "FPGA-LINUX-DMA-ERROR-FAIL: ";

#define P(name) mi_read_ulong(						\
	fail_prefix, "/sys/module/cheshire_idma/parameters/" name)
#define C(name) mi_read_ulong(						\
	fail_prefix, "/sys/module/cheshire_idma_error_test/parameters/" name)

int mininit_main(void)
{
	unsigned long dma_errors;
	unsigned long p_submitted, p_completed, p_timeouts, p_success;
	unsigned long p_read_failed, p_write_failed, p_aborted;
	unsigned long p_slverr, p_decerr, p_records, p_full, p_unexpected;
	unsigned long c_submitted, c_completed, c_success;
	unsigned long c_read_failed, c_write_failed, c_aborted;
	unsigned long c_mismatch, c_clean, c_guards, c_cache_delta;
	char *log;

	mi_setup_console(fail_prefix);
	mi_puts("FPGA-LINUX-DMA-ERROR: init started");
	mi_mount_one(fail_prefix, "proc", "/proc", "proc");
	mi_mount_one(fail_prefix, "sysfs", "/sys", "sysfs");
	mi_mount_one(fail_prefix, "debugfs", "/sys/kernel/debug", "debugfs");

	mi_load_module(fail_prefix, "/lib/modules/cheshire-idma.ko",
		       "expected_slverr_addr=0x40000000 "
		       "expected_decerr_addr=0x50000000");
	mi_load_module(fail_prefix,
		       "/lib/modules/cheshire-idma-error-test.ko", "");

	dma_errors = mi_read_ulong(
		fail_prefix, "/sys/kernel/debug/dma-api/error_count");
	p_submitted = P("submitted");
	p_completed = P("completed");
	p_timeouts = P("timeouts");
	p_success = P("success");
	p_read_failed = P("read_failed");
	p_write_failed = P("write_failed");
	p_aborted = P("aborted");
	p_slverr = P("slverr");
	p_decerr = P("decerr");
	p_records = P("buserr_records");
	p_full = P("fifo_full_seen");
	p_unexpected = P("unexpected");
	c_submitted = C("submitted");
	c_completed = C("completed");
	c_success = C("success");
	c_read_failed = C("read_failed");
	c_write_failed = C("write_failed");
	c_aborted = C("aborted");
	c_mismatch = C("callback_mismatch");
	c_clean = C("clean_checks");
	c_guards = C("guard_failures");
	c_cache_delta = C("cache_ops_delta");
	log = mi_kernel_log(fail_prefix);

	mi_puts_part("FPGA-LINUX-DMA-ERROR: provider");
	mi_kv(" submitted=", p_submitted);
	mi_kv(" completed=", p_completed);
	mi_kv(" timeouts=", p_timeouts);
	mi_kv(" success=", p_success);
	mi_kv(" read_failed=", p_read_failed);
	mi_kv(" write_failed=", p_write_failed);
	mi_kv(" aborted=", p_aborted);
	mi_kv(" slverr=", p_slverr);
	mi_kv(" decerr=", p_decerr);
	mi_kv(" records=", p_records);
	mi_kv(" fifo_full_seen=", p_full);
	mi_kv(" unexpected=", p_unexpected);
	mi_write(MI_STDOUT, "\n", 1);

	mi_puts_part("FPGA-LINUX-DMA-ERROR: client");
	mi_kv(" submitted=", c_submitted);
	mi_kv(" completed=", c_completed);
	mi_kv(" success=", c_success);
	mi_kv(" read_failed=", c_read_failed);
	mi_kv(" write_failed=", c_write_failed);
	mi_kv(" aborted=", c_aborted);
	mi_kv(" callback_mismatch=", c_mismatch);
	mi_kv(" clean_checks=", c_clean);
	mi_kv(" guard_failures=", c_guards);
	mi_kv(" cache_ops_delta=", c_cache_delta);
	mi_kv(" dma_api_errors=", dma_errors);
	mi_write(MI_STDOUT, "\n", 1);

	mi_print_log_matches(log, "bus-error direction=");
	mi_print_log_matches(log, "job=");
	mi_print_log_matches(log, "FPGA-LINUX-DMA-ERROR-CLIENT-PASS");

	if (!mi_contains(log,
			 "Cheshire whole-cache FENCE DMA maintenance enabled"))
		mi_fail(fail_prefix,
			"missing noncoherent cache-maintenance marker", -1);
	if (!mi_contains(log, "FPGA-LINUX-DMA-ERROR-CLIENT-PASS"))
		mi_fail(fail_prefix, "missing client pass marker", -1);
	if (p_submitted != 9 || p_completed != 9 || p_timeouts ||
	    p_success != 5 || p_read_failed != 2 || p_write_failed != 2 ||
	    p_aborted || p_slverr != 2 || p_decerr != 2 || p_records != 4 ||
	    p_full || p_unexpected)
		mi_fail(fail_prefix, "provider counter invariant", -1);
	if (c_submitted != 9 || c_completed != 9 || c_success != 5 ||
	    c_read_failed != 2 || c_write_failed != 2 || c_aborted ||
	    c_mismatch || c_clean != 5 || c_guards || c_cache_delta != 21 ||
	    dma_errors)
		mi_fail(fail_prefix, "client counter invariant", -1);

	mi_puts("FPGA-LINUX-DMA-ERROR-PASS");
	mi_poweroff();
}
