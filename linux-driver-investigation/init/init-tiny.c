// SPDX-License-Identifier: GPL-2.0-only
/* Freestanding controller for the interrupt-driven DMAengine matrix. */

#include "mininit.h"

static const char fail_prefix[] = "FPGA-LINUX-DMA-IRQ-FAIL: ";

#define P(name) mi_read_ulong(						\
	fail_prefix, "/sys/module/cheshire_idma/parameters/" name)
#define C(name) mi_read_ulong(						\
	fail_prefix, "/sys/module/cheshire_idma_irq_test/parameters/" name)

int mininit_main(void)
{
	unsigned long dma_errors;
	unsigned long p_submitted, p_completed, p_completion_irqs, p_error_irqs;
	unsigned long p_spurious, p_callbacks, p_success, p_read, p_write;
	unsigned long p_aborted, p_abort_requests, p_abort_terminals;
	unsigned long p_abort_timeouts, p_queued_terminated, p_freed;
	unsigned long p_max_sw, p_max_hw, p_slverr, p_decerr, p_records;
	unsigned long p_full, p_unexpected, p_cache;
	unsigned long c_pass, c_rc, c_cache, c_guards, c_payload;
	unsigned long c_duplicates, c_timeouts, c_queue_order, c_threads;
	unsigned long c_serial_sub, c_serial_done, c_serial_checks;
	unsigned long c_queue_sub, c_queue_done, c_queue_checks;
	unsigned long c_concurrent_sub, c_concurrent_done, c_concurrent_checks;
	unsigned long c_error_sub, c_error_done, c_error_success;
	unsigned long c_error_read, c_error_write, c_error_abort;
	unsigned long c_error_mismatch, c_error_clean;
	unsigned long c_term_sub, c_term_callbacks, c_term_checks, c_recovery;
	char *log;

	mi_setup_console(fail_prefix);
	mi_puts("FPGA-LINUX-DMA-IRQ: init started");
	mi_mount_one(fail_prefix, "proc", "/proc", "proc");
	mi_mount_one(fail_prefix, "sysfs", "/sys", "sysfs");
	mi_mount_one(fail_prefix, "debugfs", "/sys/kernel/debug", "debugfs");

	mi_load_module(fail_prefix, "/lib/modules/cheshire-idma.ko",
		       "expected_slverr_addr=0x40000000 "
		       "expected_decerr_addr=0x50000000");
	mi_load_module(fail_prefix,
		       "/lib/modules/cheshire-idma-irq-test.ko", "");

	dma_errors = mi_read_ulong(
		fail_prefix, "/sys/kernel/debug/dma-api/error_count");
	p_submitted = P("submitted");
	p_completed = P("hw_completed");
	p_completion_irqs = P("completion_irqs");
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
	p_queued_terminated = P("queued_terminated");
	p_freed = P("descriptors_freed");
	p_max_sw = P("max_software_queue");
	p_max_hw = P("max_hardware_active");
	p_slverr = P("slverr");
	p_decerr = P("decerr");
	p_records = P("buserr_records");
	p_full = P("fifo_full_seen");
	p_unexpected = P("unexpected");
	p_cache = P("cache_ops");

	c_pass = C("pass");
	c_rc = C("test_rc");
	c_serial_sub = C("serial_submitted");
	c_serial_done = C("serial_completed");
	c_serial_checks = C("serial_checks");
	c_queue_sub = C("queue_submitted");
	c_queue_done = C("queue_completed");
	c_queue_checks = C("queue_checks");
	c_queue_order = C("queue_order_failures");
	c_concurrent_sub = C("concurrent_submitted");
	c_concurrent_done = C("concurrent_completed");
	c_concurrent_checks = C("concurrent_checks");
	c_threads = C("thread_failures");
	c_error_sub = C("error_submitted");
	c_error_done = C("error_completed");
	c_error_success = C("error_success");
	c_error_read = C("error_read_failed");
	c_error_write = C("error_write_failed");
	c_error_abort = C("error_aborted");
	c_error_mismatch = C("error_mismatch");
	c_error_clean = C("error_clean_checks");
	c_term_sub = C("terminate_submitted");
	c_term_callbacks = C("terminate_callbacks");
	c_term_checks = C("terminate_checks");
	c_recovery = C("recovery_checks");
	c_guards = C("guard_failures");
	c_payload = C("payload_failures");
	c_duplicates = C("callback_duplicates");
	c_timeouts = C("timeouts");
	c_cache = C("cache_ops_delta");
	log = mi_kernel_log(fail_prefix);

	mi_puts_part("FPGA-LINUX-DMA-IRQ: provider");
	mi_kv(" submitted=", p_submitted);
	mi_kv(" completed=", p_completed);
	mi_kv(" completion_irqs=", p_completion_irqs);
	mi_kv(" error_irqs=", p_error_irqs);
	mi_kv(" spurious=", p_spurious);
	mi_kv(" callbacks=", p_callbacks);
	mi_kv(" success=", p_success);
	mi_kv(" read=", p_read);
	mi_kv(" write=", p_write);
	mi_kv(" aborted=", p_aborted);
	mi_kv(" abort_requests=", p_abort_requests);
	mi_kv(" abort_terminals=", p_abort_terminals);
	mi_kv(" abort_timeouts=", p_abort_timeouts);
	mi_kv(" queued_terminated=", p_queued_terminated);
	mi_kv(" freed=", p_freed);
	mi_kv(" max_sw=", p_max_sw);
	mi_kv(" max_hw=", p_max_hw);
	mi_kv(" slverr=", p_slverr);
	mi_kv(" decerr=", p_decerr);
	mi_kv(" records=", p_records);
	mi_kv(" full=", p_full);
	mi_kv(" unexpected=", p_unexpected);
	mi_kv(" cache_ops=", p_cache);
	mi_write(MI_STDOUT, "\n", 1);

	mi_puts_part("FPGA-LINUX-DMA-IRQ: client");
	mi_kv(" pass=", c_pass);
	mi_kv(" rc=", c_rc);
	mi_kv(" serial=", c_serial_sub);
	mi_write(MI_STDOUT, "/", 1);
	mi_put_ulong(c_serial_done);
	mi_write(MI_STDOUT, "/", 1);
	mi_put_ulong(c_serial_checks);
	mi_kv(" queue=", c_queue_sub);
	mi_write(MI_STDOUT, "/", 1);
	mi_put_ulong(c_queue_done);
	mi_write(MI_STDOUT, "/", 1);
	mi_put_ulong(c_queue_checks);
	mi_kv(" order_fail=", c_queue_order);
	mi_kv(" concurrent=", c_concurrent_sub);
	mi_write(MI_STDOUT, "/", 1);
	mi_put_ulong(c_concurrent_done);
	mi_write(MI_STDOUT, "/", 1);
	mi_put_ulong(c_concurrent_checks);
	mi_kv(" thread_fail=", c_threads);
	mi_kv(" errors=", c_error_sub);
	mi_write(MI_STDOUT, "/", 1);
	mi_put_ulong(c_error_done);
	mi_kv(" success=", c_error_success);
	mi_kv(" read=", c_error_read);
	mi_kv(" write=", c_error_write);
	mi_kv(" abort=", c_error_abort);
	mi_kv(" mismatch=", c_error_mismatch);
	mi_kv(" clean=", c_error_clean);
	mi_kv(" terminate=", c_term_sub);
	mi_kv(" callbacks=", c_term_callbacks);
	mi_kv(" checks=", c_term_checks);
	mi_kv(" recovery=", c_recovery);
	mi_kv(" guards=", c_guards);
	mi_kv(" payload=", c_payload);
	mi_kv(" duplicates=", c_duplicates);
	mi_kv(" timeouts=", c_timeouts);
	mi_kv(" cache_ops=", c_cache);
	mi_kv(" dma_api_errors=", dma_errors);
	mi_write(MI_STDOUT, "\n", 1);

	mi_print_log_matches(log, "bus-error direction=");
	mi_print_log_matches(log, "error-job=");
	mi_print_log_matches(log, "FPGA-LINUX-DMA-IRQ-CLIENT-PASS");

	if (!mi_contains(log,
			 "Cheshire whole-cache FENCE DMA maintenance enabled"))
		mi_fail(fail_prefix,
			"missing noncoherent cache-maintenance marker", -1);
	if (!mi_contains(log, "FPGA-LINUX-DMA-IRQ-CLIENT-PASS"))
		mi_fail(fail_prefix, "missing client pass marker", -1);
	if (p_submitted != 67 || p_completed != 67 ||
	    p_completion_irqs != 67 || p_error_irqs != 4 || p_spurious ||
	    p_callbacks != 66 || p_success != 62 || p_read != 2 ||
	    p_write != 2 || p_aborted != 1 || p_abort_requests != 1 ||
	    p_abort_terminals != 1 || p_abort_timeouts ||
	    p_queued_terminated != 7 || p_freed != 74 || p_max_sw != 32 ||
	    p_max_hw != 1 || p_slverr != 2 || p_decerr != 2 ||
	    p_records != 4 || p_full || p_unexpected || p_cache != 216)
		mi_fail(fail_prefix, "provider counter invariant", -1);
	if (c_pass != 1 || c_rc || c_serial_sub != 8 || c_serial_done != 8 ||
	    c_serial_checks != 8 || c_queue_sub != 16 || c_queue_done != 16 ||
	    c_queue_checks != 16 || c_queue_order || c_concurrent_sub != 32 ||
	    c_concurrent_done != 32 || c_concurrent_checks != 32 ||
	    c_threads || c_error_sub != 9 || c_error_done != 9 ||
	    c_error_success != 5 || c_error_read != 2 || c_error_write != 2 ||
	    c_error_abort || c_error_mismatch || c_error_clean != 5 ||
	    c_term_sub != 8 || c_term_callbacks || c_term_checks != 8 ||
	    c_recovery != 1 || c_guards || c_payload || c_duplicates ||
	    c_timeouts || c_cache != 216 || dma_errors)
		mi_fail(fail_prefix, "client counter invariant", -1);

	mi_puts("FPGA-LINUX-DMA-IRQ-PASS");
	mi_poweroff();
}
