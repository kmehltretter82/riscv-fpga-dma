// SPDX-License-Identifier: GPL-2.0-only
/* Freestanding fail-closed controller for both Phase 11 noncoherent cells. */

#include "mininit.h"

static const char fail_prefix[] = "FPGA-LINUX-DMA-CACHE-FAIL: ";

#define P(name) mi_read_ulong(                                             \
	fail_prefix, "/sys/module/cheshire_idma/parameters/" name)
#define C(name) mi_read_ulong(                                             \
	fail_prefix, "/sys/module/cheshire_idma_cache_test/parameters/" name)

static long read_small_file(const char *path, char *buffer, mi_size_t size)
{
	long fd = mi_syscall4(MI_NR_openat, MI_AT_FDCWD, (long)path,
			      MI_O_RDONLY | MI_O_CLOEXEC, 0);
	long length;

	if (fd < 0)
		mi_fail(fail_prefix, path, fd);
	length = mi_syscall3(MI_NR_read, fd, (long)buffer, size - 1);
	mi_syscall1(MI_NR_close, fd);
	if (length <= 0)
		mi_fail(fail_prefix, path, length);
	buffer[length] = '\0';
	return length;
}

static void emit_record(const char *cell, const char *run,
			const char *expected, const char *observed,
			unsigned long cache_delta,
			unsigned long critical_delta,
			const char *source_ram, const char *dma_read,
			const char *destination_ram, const char *destination_cpu,
			unsigned long guards, unsigned long dma_errors)
{
	mi_puts_part("PHASE11_LINUX_RECORD cell=");
	mi_puts_part(cell);
	mi_puts_part(" run=");
	mi_puts_part(run);
	mi_puts_part(" expected_outcome=");
	mi_puts_part(expected);
	mi_puts_part(" observed_outcome=");
	mi_puts_part(observed);
	mi_puts_part(" cache_type=");
	mi_puts_part(cell);
	mi_kv(" cache_hook_delta=", cache_delta);
	mi_kv(" critical_cache_hook_delta=", critical_delta);
	mi_puts_part(" source_ram_pattern=");
	mi_puts_part(source_ram);
	mi_puts_part(" dma_read_pattern=");
	mi_puts_part(dma_read);
	mi_puts_part(" destination_ram_pattern=");
	mi_puts_part(destination_ram);
	mi_puts_part(" destination_cpu_pattern=");
	mi_puts_part(destination_cpu);
	mi_kv(" guard_failures=", guards);
	mi_kv(" dma_api_errors=", dma_errors);
	mi_write(MI_STDOUT, "\n", 1);
}

int mininit_main(void)
{
	char cmdline[512];
	const char *cell;
	unsigned long dma_errors;
	unsigned long p_submitted, p_completed, p_irqs, p_error_irqs;
	unsigned long p_spurious, p_callbacks, p_success, p_read, p_write;
	unsigned long p_aborted, p_abort_requests, p_abort_terminals;
	unsigned long p_abort_timeouts, p_queued, p_freed, p_max_sw, p_max_hw;
	unsigned long p_slverr, p_decerr, p_records, p_full, p_unexpected;
	unsigned long p_device_coherent;
	unsigned long p_stale_source_prearms;
	unsigned long c_pass, c_rc, c_jobs, c_callbacks, c_timeouts;
	unsigned long c_guards, c_payload, c_total;
	unsigned long c_pos_delta, c_pos_critical, c_pos_outcome;
	unsigned long c_src_delta, c_src_critical, c_src_outcome;
	unsigned long c_dst_delta, c_dst_critical, c_dst_outcome;
	char *log;

	mi_setup_console(fail_prefix);
	mi_puts("FPGA-LINUX-DMA-CACHE: init started");
	mi_mount_one(fail_prefix, "proc", "/proc", "proc");
	mi_mount_one(fail_prefix, "sysfs", "/sys", "sysfs");
	mi_mount_one(fail_prefix, "debugfs", "/sys/kernel/debug", "debugfs");
	read_small_file("/proc/cmdline", cmdline, sizeof(cmdline));
	if (mi_contains(cmdline, "phase11.cell=coherent"))
		cell = "cva6-wt-hardware-coherent";
	else
		mi_fail(fail_prefix, "missing/unknown phase11.cell", -1);

	mi_load_module(fail_prefix, "/lib/modules/cheshire-idma.ko", "");
	mi_load_module(fail_prefix,
		       "/lib/modules/cheshire-idma-cache-test.ko", "");

	dma_errors = mi_read_ulong(
		fail_prefix, "/sys/kernel/debug/dma-api/error_count");
	p_submitted = P("submitted");
	p_completed = P("hw_completed");
	p_irqs = P("completion_irqs");
	p_error_irqs = P("error_irqs");
	p_spurious = P("spurious_completion_irqs");
	p_callbacks = P("callbacks_queued");
	p_success = P("success");
	p_read = P("read_failed");
	p_write = P("write_failed");
	p_aborted = P("aborted");
	p_abort_requests = P("abort_requests");
	p_abort_terminals = P("abort_terminals");
	p_abort_timeouts = P("abort_timeouts");
	p_queued = P("queued_terminated");
	p_freed = P("descriptors_freed");
	p_max_sw = P("max_software_queue");
	p_max_hw = P("max_hardware_active");
	p_slverr = P("slverr");
	p_decerr = P("decerr");
	p_records = P("buserr_records");
	p_full = P("fifo_full_seen");
	p_unexpected = P("unexpected");
	p_device_coherent = P("device_coherent");
	p_stale_source_prearms = P("stale_source_prearms");

	c_pass = C("pass");
	c_rc = C("test_rc");
	c_jobs = C("jobs");
	c_callbacks = C("callbacks");
	c_timeouts = C("timeouts");
	c_guards = C("guard_failures");
	c_payload = C("payload_failures");
	c_total = C("cache_total_delta");
	c_pos_delta = C("positive_cache_delta");
	c_pos_critical = C("positive_critical_delta");
	c_pos_outcome = C("positive_outcome");
	c_src_delta = C("stale_source_cache_delta");
	c_src_critical = C("stale_source_critical_delta");
	c_src_outcome = C("stale_source_outcome");
	c_dst_delta = C("stale_destination_cache_delta");
	c_dst_critical = C("stale_destination_critical_delta");
	c_dst_outcome = C("stale_destination_outcome");
	log = mi_kernel_log(fail_prefix);

	emit_record(cell, "positive", "new_src", "new_src",
		    c_pos_delta, c_pos_critical, "new_src", "new_src",
		    "new_src", "new_src", c_guards, dma_errors);
	emit_record(cell, "stale-source", "old_src", "old_src",
		    c_src_delta, c_src_critical, "old_src", "old_src",
		    "old_src", "old_src", c_guards, dma_errors);
	emit_record(cell, "stale-destination", "old_dst_line8",
		    "old_dst_line8",
		    c_dst_delta, c_dst_critical, "new_src", "new_src",
		    "new_src", "old_dst_line8_other_new_src", c_guards,
		    dma_errors);

	mi_puts_part("FPGA-LINUX-DMA-CACHE: provider");
	mi_kv(" submitted=", p_submitted);
	mi_kv(" completed=", p_completed);
	mi_kv(" completion_irqs=", p_irqs);
	mi_kv(" error_irqs=", p_error_irqs);
	mi_kv(" callbacks=", p_callbacks);
	mi_kv(" success=", p_success);
	mi_kv(" freed=", p_freed);
	mi_kv(" max_sw=", p_max_sw);
	mi_kv(" max_hw=", p_max_hw);
	mi_kv(" unexpected=", p_unexpected);
	mi_kv(" stale_source_prearms=", p_stale_source_prearms);
	mi_write(MI_STDOUT, "\n", 1);

	if (!mi_contains(log, "PHASE11-CACHE-CLIENT-PASS"))
		mi_fail(fail_prefix, "missing client pass marker", -1);
	if (p_submitted != 3 || p_completed != 3 || p_irqs != 3 ||
	    p_error_irqs || p_spurious || p_callbacks != 3 || p_success != 3 ||
	    p_read || p_write || p_aborted || p_abort_requests ||
	    p_abort_terminals || p_abort_timeouts || p_queued || p_freed != 3 ||
	    p_max_sw != 1 || p_max_hw != 1 || p_slverr || p_decerr ||
	    p_records || p_full || p_unexpected || p_device_coherent != 1 ||
	    p_stale_source_prearms != 1)
		mi_fail(fail_prefix, "provider counter invariant", -1);
	if (c_pass != 1 || c_rc || c_jobs != 3 || c_callbacks != 3 ||
	    c_timeouts || c_guards || c_payload || c_total != 0 ||
	    c_pos_delta != 0 || c_pos_critical || c_pos_outcome != 1 ||
	    c_src_delta != 0 || c_src_critical || c_src_outcome != 2 ||
	    c_dst_delta != 0 || c_dst_critical || c_dst_outcome != 3 ||
	    dma_errors)
		mi_fail(fail_prefix, "client/cache counter invariant", -1);

	mi_puts_part("FPGA-LINUX-DMA-CACHE-PASS cell=");
	mi_puts(cell);
	mi_poweroff();
}
