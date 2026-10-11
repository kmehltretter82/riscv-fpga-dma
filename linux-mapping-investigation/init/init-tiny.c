// SPDX-License-Identifier: GPL-2.0-only
/* Freestanding controller for the positive and negative DMA-mapping matrix. */

#include "mininit.h"

static const char fail_prefix[] = "FPGA-LINUX-DMA-MAPPING-FAIL: ";

#define P(name) mi_read_ulong(\
	fail_prefix, "/sys/module/cheshire_idma/parameters/" name)
#define C(name) mi_read_ulong(\
	fail_prefix, "/sys/module/cheshire_idma_mapping_test/parameters/" name)
#define N(name) mi_read_ulong(\
	fail_prefix, "/sys/module/cheshire_idma_api_negative/parameters/" name)

static int file_contains(const char *path, const char *needle)
{
	char buffer[512];
	long fd;
	long length;

	fd = mi_syscall4(MI_NR_openat, MI_AT_FDCWD, (long)path,
			 MI_O_RDONLY | MI_O_CLOEXEC, 0);
	if (fd < 0)
		mi_fail(fail_prefix, path, fd);
	length = mi_syscall3(MI_NR_read, fd, (long)buffer, sizeof(buffer) - 1);
	mi_syscall1(MI_NR_close, fd);
	if (length < 0)
		mi_fail(fail_prefix, path, length);
	buffer[length] = '\0';
	return mi_contains(buffer, needle);
}

static void write_text(const char *path, const char *text)
{
	long fd;
	long result;

	fd = mi_syscall4(MI_NR_openat, MI_AT_FDCWD, (long)path,
			 MI_O_RDWR | MI_O_CLOEXEC, 0);
	if (fd < 0)
		mi_fail(fail_prefix, path, fd);
	result = mi_syscall3(MI_NR_write, fd, (long)text, mi_strlen(text));
	mi_syscall1(MI_NR_close, fd);
	if (result != (long)mi_strlen(text))
		mi_fail(fail_prefix, path, result);
}

static unsigned long count_matches(const char *text, const char *needle)
{
	unsigned long count = 0;
	mi_size_t text_length = mi_strlen(text);
	mi_size_t needle_length = mi_strlen(needle);
	mi_size_t index;

	if (!needle_length || needle_length > text_length)
		return 0;
	for (index = 0; index <= text_length - needle_length; index++) {
		if (mi_starts_with(text + index, text_length - index, needle)) {
			count++;
			index += needle_length - 1;
		}
	}
	return count;
}

static __attribute__((noreturn)) void run_negative(void)
{
	unsigned long free_before;
	unsigned long free_after;
	unsigned long errors;
	unsigned long n_pass;
	unsigned long n_cases;
	unsigned long n_cleanup;
	unsigned long p_cache;
	long n_rc;
	char *log;

	if (!file_contains("/sys/kernel/debug/dma-api/disabled", "N"))
		mi_fail(fail_prefix, "DMA API debug disabled", -1);
	if (mi_read_ulong(fail_prefix,
			  "/sys/kernel/debug/dma-api/error_count"))
		mi_fail(fail_prefix, "pre-existing DMA API error", -1);
	write_text("/sys/kernel/debug/dma-api/all_errors", "1\n");
	if (mi_read_ulong(fail_prefix,
			  "/sys/kernel/debug/dma-api/all_errors") != 1)
		mi_fail(fail_prefix, "all_errors did not latch", -1);
	if (!file_contains("/sys/kernel/debug/dma-api/driver_filter",
			   "cheshire-idma-irq-investigation"))
		mi_fail(fail_prefix, "DMA API driver filter mismatch", -1);

	mi_load_module(fail_prefix, "/lib/modules/cheshire-idma.ko", "");
	free_before = mi_read_ulong(
		fail_prefix, "/sys/kernel/debug/dma-api/num_free_entries");
	if (mi_read_ulong(fail_prefix,
			  "/sys/kernel/debug/dma-api/error_count"))
		mi_fail(fail_prefix, "provider load caused DMA API error", -1);
	mi_load_module(fail_prefix,
		       "/lib/modules/cheshire-idma-api-negative.ko", "");

	errors = mi_read_ulong(
		fail_prefix, "/sys/kernel/debug/dma-api/error_count");
	free_after = mi_read_ulong(
		fail_prefix, "/sys/kernel/debug/dma-api/num_free_entries");
	n_pass = N("pass");
	n_rc = (long)N("test_rc");
	n_cases = N("cases");
	n_cleanup = N("cleanup");
	p_cache = P("cache_ops");
	log = mi_kernel_log(fail_prefix);

	mi_puts_part("FPGA-LINUX-DMA-API-NEGATIVE: client");
	mi_kv(" pass=", n_pass);
	mi_puts_part(" rc=");
	mi_put_long(n_rc);
	mi_kv(" cases=", n_cases);
	mi_kv(" cleanup=", n_cleanup);
	mi_kv(" errors=", errors);
	mi_kv(" free_before=", free_before);
	mi_kv(" free_after=", free_after);
	mi_kv(" cache_ops=", p_cache);
	mi_write(MI_STDOUT, "\n", 1);
	mi_print_log_matches(log, "DMA-API:");

	if (n_pass != 1 || n_rc || n_cases != 5 || n_cleanup != 5)
		mi_fail(fail_prefix, "negative client counter invariant", -1);
	if (errors != 5 || free_before != free_after)
		mi_fail(fail_prefix, "DMA API accounting invariant", -1);
	if (P("submitted") || P("hw_completed") || P("completion_irqs") ||
	    P("error_irqs") || P("callbacks_queued") || P("success") ||
	    P("read_failed") || P("write_failed") || P("aborted") ||
	    P("buserr_records") || P("unexpected"))
		mi_fail(fail_prefix, "negative test touched iDMA", -1);
	if (file_contains("/sys/kernel/debug/dma-api/dump",
			  "cheshire-idma-irq-investigation"))
		mi_fail(fail_prefix, "provider mapping leaked", -1);
	if (count_matches(log,
			  "DMA-API: cheshire-idma-irq-investigation") != 5 ||
	    count_matches(log, "device driver failed to check map error") != 1 ||
	    count_matches(log, "device driver frees DMA memory with different size") != 1 ||
	    count_matches(log, "device driver syncs DMA memory with different direction") != 1 ||
	    count_matches(log, "device driver syncs DMA sg list with different entry count") != 1 ||
	    count_matches(log, "device driver tries to free DMA memory it has not allocated") != 1)
		mi_fail(fail_prefix, "DMA API warning signature invariant", -1);
	if (mi_contains(log, "Kernel panic") || mi_contains(log, "Oops:"))
		mi_fail(fail_prefix, "unexpected kernel fault", -1);

	mi_puts("FPGA-LINUX-DMA-API-NEGATIVE-PASS");
	mi_puts("FPGA-LINUX-DMA-MAPPING-PASS");
	mi_poweroff();
}

int mininit_main(void)
{
	unsigned long force;
	unsigned long expected_jobs;
	unsigned long expected_singles;
	unsigned long expected_single_bytes;
	unsigned long expected_cache;
	unsigned long expected_proofs;
	unsigned long expected_bounce_checks;
	unsigned long dma_errors;
	unsigned long p_submitted, p_completed, p_completion_irqs;
	unsigned long p_error_irqs, p_spurious, p_empty_error;
	unsigned long p_callbacks, p_success, p_read, p_write, p_aborted;
	unsigned long p_abort_requests, p_abort_terminals, p_abort_timeouts;
	unsigned long p_queued_terminated, p_freed, p_max_sw, p_max_hw;
	unsigned long p_slverr, p_decerr, p_records, p_full, p_unexpected;
	unsigned long p_cache;
	unsigned long c_pass, c_force, c_jobs, c_callbacks, c_cache;
	unsigned long c_callback_failures, c_cookie_failures, c_timeouts;
	unsigned long c_guards, c_payload, c_mapping_failures, c_proofs;
	unsigned long c_bounce_checks, c_single_jobs, c_single_bytes;
	unsigned long c_nonpage, c_unaligned, c_cross4k, c_cross64k, c_cross1m;
	unsigned long c_sg_original, c_sg_source, c_sg_destination;
	unsigned long c_sg_chunks, c_sg_bytes, c_sg_checks;
	unsigned long c_coherent_jobs, c_coherent_bytes, c_coherent_checks;
	unsigned long c_coherent_nonbounce, c_max_mapping, c_cache_before;
	long c_rc;
	char *log;

	mi_setup_console(fail_prefix);
	mi_puts("FPGA-LINUX-DMA-MAPPING: init started");
	mi_mount_one(fail_prefix, "proc", "/proc", "proc");
	mi_mount_one(fail_prefix, "sysfs", "/sys", "sysfs");
	mi_mount_one(fail_prefix, "debugfs", "/sys/kernel/debug", "debugfs");
	if (file_contains("/proc/cmdline", "dma_api_negative=1"))
		run_negative();

	force = file_contains("/proc/cmdline", "swiotlb=4096,force");
	expected_jobs = force ? 271 : 272;
	expected_singles = force ? 4 : 5;
	expected_single_bytes = force ? 73987 : 1122820;
	expected_cache = force ? 811 : 814;
	expected_proofs = force ? 538 : 540;
	expected_bounce_checks = force ? 269 : 0;

	mi_load_module(fail_prefix, "/lib/modules/cheshire-idma.ko", "");
	mi_load_module(fail_prefix,
		       "/lib/modules/cheshire-idma-mapping-test.ko",
		       force ? "expect_force=1" : "expect_force=0");

	dma_errors = mi_read_ulong(
		fail_prefix, "/sys/kernel/debug/dma-api/error_count");
	p_submitted = P("submitted");
	p_completed = P("hw_completed");
	p_completion_irqs = P("completion_irqs");
	p_error_irqs = P("error_irqs");
	p_spurious = P("spurious_completion_irqs");
	p_empty_error = P("empty_error_irqs");
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
	c_rc = (long)C("test_rc");
	c_force = C("force_detected");
	c_jobs = C("hw_jobs");
	c_callbacks = C("callbacks");
	c_callback_failures = C("callback_failures");
	c_cookie_failures = C("cookie_failures");
	c_timeouts = C("timeouts");
	c_guards = C("guard_failures");
	c_payload = C("payload_failures");
	c_mapping_failures = C("mapping_failures");
	c_proofs = C("mapping_proofs");
	c_bounce_checks = C("bounce_source_checks");
	c_single_jobs = C("single_jobs");
	c_single_bytes = C("single_bytes");
	c_nonpage = C("nonpage_cases");
	c_unaligned = C("unaligned_cases");
	c_cross4k = C("cross_4k_cases");
	c_cross64k = C("cross_64k_cases");
	c_cross1m = C("cross_1m_cases");
	c_sg_original = C("sg_original_nents");
	c_sg_source = C("sg_source_mapped_nents");
	c_sg_destination = C("sg_destination_mapped_nents");
	c_sg_chunks = C("sg_chunks");
	c_sg_bytes = C("sg_bytes");
	c_sg_checks = C("sg_checks");
	c_coherent_jobs = C("coherent_jobs");
	c_coherent_bytes = C("coherent_bytes");
	c_coherent_checks = C("coherent_checks");
	c_coherent_nonbounce = C("coherent_nonbounce_proofs");
	c_max_mapping = C("max_mapping_size_seen");
	c_cache_before = C("cache_ops_before");
	c_cache = C("cache_ops_delta");
	log = mi_kernel_log(fail_prefix);

	mi_puts_part("FPGA-LINUX-DMA-MAPPING: provider");
	mi_kv(" submitted=", p_submitted);
	mi_kv(" completed=", p_completed);
	mi_kv(" completion_irqs=", p_completion_irqs);
	mi_kv(" error_irqs=", p_error_irqs);
	mi_kv(" callbacks=", p_callbacks);
	mi_kv(" success=", p_success);
	mi_kv(" freed=", p_freed);
	mi_kv(" max_sw=", p_max_sw);
	mi_kv(" max_hw=", p_max_hw);
	mi_kv(" cache_ops=", p_cache);
	mi_write(MI_STDOUT, "\n", 1);

	mi_puts_part("FPGA-LINUX-DMA-MAPPING: client");
	mi_kv(" pass=", c_pass);
	mi_puts_part(" rc=");
	mi_put_long(c_rc);
	mi_kv(" force=", c_force);
	mi_kv(" jobs=", c_jobs);
	mi_kv(" callbacks=", c_callbacks);
	mi_kv(" singles=", c_single_jobs);
	mi_kv(" single_bytes=", c_single_bytes);
	mi_kv(" sg=", c_sg_original);
	mi_write(MI_STDOUT, "/", 1);
	mi_put_ulong(c_sg_source);
	mi_write(MI_STDOUT, "/", 1);
	mi_put_ulong(c_sg_destination);
	mi_kv(" chunks=", c_sg_chunks);
	mi_kv(" bytes=", c_sg_bytes);
	mi_kv(" coherent=", c_coherent_jobs);
	mi_kv(" proofs=", c_proofs);
	mi_kv(" bounce_checks=", c_bounce_checks);
	mi_kv(" cache_before=", c_cache_before);
	mi_kv(" cache_ops=", c_cache);
	mi_kv(" dma_api_errors=", dma_errors);
	mi_write(MI_STDOUT, "\n", 1);

	mi_print_log_matches(log, "DMA-MAPPING-");
	if (!mi_contains(log,
			 "Cheshire whole-cache FENCE DMA maintenance enabled"))
		mi_fail(fail_prefix, "missing cache-maintenance marker", -1);
	if (!mi_contains(log, force ?
			 "FPGA-LINUX-DMA-MAPPING-SWIOTLB-CLIENT-PASS" :
			 "FPGA-LINUX-DMA-MAPPING-DIRECT-CLIENT-PASS"))
		mi_fail(fail_prefix, "missing client pass marker", -1);
	if (mi_contains(log, "DMA-API: device driver maps memory" ) ||
	    mi_contains(log, "DMA-API: device driver frees DMA memory" ) ||
	    mi_contains(log, "DMA-API: dma dma_map_sg"))
		mi_fail(fail_prefix, "DMA API debug signature in log", -1);

	if (p_submitted != expected_jobs || p_completed != expected_jobs ||
	    p_completion_irqs != expected_jobs || p_error_irqs || p_spurious ||
	    p_empty_error || p_callbacks != expected_jobs ||
	    p_success != expected_jobs || p_read || p_write || p_aborted ||
	    p_abort_requests || p_abort_terminals || p_abort_timeouts ||
	    p_queued_terminated || p_freed != expected_jobs ||
	    p_max_sw != 265 || p_max_hw != 1 || p_slverr || p_decerr ||
	    p_records || p_full || p_unexpected ||
	    p_cache != expected_cache + 1)
		mi_fail(fail_prefix, "provider counter invariant", -1);
	if (c_pass != 1 || c_rc || c_force != force ||
	    c_jobs != expected_jobs || c_callbacks != expected_jobs ||
	    c_callback_failures || c_cookie_failures || c_timeouts || c_guards ||
	    c_payload || c_mapping_failures || c_proofs != expected_proofs ||
	    c_bounce_checks != expected_bounce_checks ||
	    c_single_jobs != expected_singles ||
	    c_single_bytes != expected_single_bytes || c_nonpage != 1 ||
	    c_unaligned != 1 || c_cross4k != 1 || c_cross64k != 1 ||
	    c_cross1m != !force || c_sg_original != 265 ||
	    c_sg_source != 265 || c_sg_destination != 265 ||
	    c_sg_chunks != 265 || c_sg_bytes != 1051520 ||
	    c_sg_checks != 265 || c_coherent_jobs != 2 ||
	    c_coherent_bytes != 66314 || c_coherent_checks != 2 ||
	    c_coherent_nonbounce != 4 || !c_max_mapping || c_cache_before != 1 ||
	    c_cache != expected_cache || dma_errors)
		mi_fail(fail_prefix, "client counter invariant", -1);

	mi_puts(force ? "FPGA-LINUX-DMA-MAPPING-SWIOTLB-PASS" :
		       "FPGA-LINUX-DMA-MAPPING-DIRECT-PASS");
	mi_puts("FPGA-LINUX-DMA-MAPPING-PASS");
	mi_poweroff();
}
