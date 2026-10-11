// SPDX-License-Identifier: GPL-2.0-only
/* Initramfs controller for the Cheshire interrupt-driven DMAengine matrix. */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/klog.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

static void fail(const char *what)
{
	dprintf(STDOUT_FILENO, "FPGA-LINUX-DMA-IRQ-FAIL: %s: %s\n", what,
		strerror(errno));
	sync();
	for (;;)
		syscall(SYS_sched_yield);
}

static void make_dir(const char *path)
{
	if (mkdir(path, 0755) && errno != EEXIST)
		fail(path);
}

static void mount_one(const char *src, const char *target, const char *type)
{
	make_dir(target);
	if (mount(src, target, type, 0, NULL) && errno != EBUSY)
		fail(target);
}

static void load_module(const char *path, const char *params)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);

	if (fd < 0)
		fail(path);
	if (syscall(SYS_finit_module, fd, params, 0))
		fail(path);
	close(fd);
}

static unsigned long read_ulong(const char *path)
{
	char buf[64];
	char *end;
	ssize_t n;
	unsigned long value;
	int fd = open(path, O_RDONLY | O_CLOEXEC);

	if (fd < 0)
		fail(path);
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		fail(path);
	buf[n] = '\0';
	errno = 0;
	value = strtoul(buf, &end, 0);
	if (errno || end == buf)
		fail(path);
	return value;
}

static char *kernel_log(void)
{
	int size = klogctl(10, NULL, 0);
	char *buf;
	int got;

	if (size < 1)
		fail("klogctl size");
	buf = calloc(1, (size_t)size + 1);
	if (!buf)
		fail("calloc kernel log");
	got = klogctl(3, buf, size);
	if (got < 0)
		fail("klogctl read");
	buf[got] = '\0';
	return buf;
}

static void print_log_matches(const char *log, const char *needle)
{
	const char *line = log;

	while (*line) {
		const char *end = strchr(line, '\n');
		size_t len = end ? (size_t)(end - line) : strlen(line);

		if (memmem(line, len, needle, strlen(needle))) {
			fwrite(line, 1, len, stdout);
			fputc('\n', stdout);
		}
		if (!end)
			break;
		line = end + 1;
	}
}

#define P(name) read_ulong("/sys/module/cheshire_idma/parameters/" name)
#define C(name) read_ulong("/sys/module/cheshire_idma_irq_test/parameters/" name)

int main(void)
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

	setvbuf(stdout, NULL, _IONBF, 0);
	puts("FPGA-LINUX-DMA-IRQ: init started");
	mount_one("proc", "/proc", "proc");
	mount_one("sysfs", "/sys", "sysfs");
	mount_one("devtmpfs", "/dev", "devtmpfs");
	mount_one("debugfs", "/sys/kernel/debug", "debugfs");

	load_module("/lib/modules/cheshire-idma.ko",
		"expected_slverr_addr=0x40000000 expected_decerr_addr=0x50000000");
	load_module("/lib/modules/cheshire-idma-irq-test.ko", "");

	dma_errors = read_ulong("/sys/kernel/debug/dma-api/error_count");
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
	log = kernel_log();

	printf("FPGA-LINUX-DMA-IRQ: provider submitted=%lu completed=%lu completion_irqs=%lu error_irqs=%lu spurious=%lu callbacks=%lu success=%lu read=%lu write=%lu aborted=%lu abort_requests=%lu abort_terminals=%lu abort_timeouts=%lu queued_terminated=%lu freed=%lu max_sw=%lu max_hw=%lu slverr=%lu decerr=%lu records=%lu full=%lu unexpected=%lu cache_ops=%lu\n",
	       p_submitted, p_completed, p_completion_irqs, p_error_irqs,
	       p_spurious, p_callbacks, p_success, p_read, p_write, p_aborted,
	       p_abort_requests, p_abort_terminals, p_abort_timeouts,
	       p_queued_terminated, p_freed, p_max_sw, p_max_hw, p_slverr,
	       p_decerr, p_records, p_full, p_unexpected, p_cache);
	printf("FPGA-LINUX-DMA-IRQ: client pass=%lu rc=%lu serial=%lu/%lu/%lu queue=%lu/%lu/%lu order_fail=%lu concurrent=%lu/%lu/%lu thread_fail=%lu errors=%lu/%lu success=%lu read=%lu write=%lu abort=%lu mismatch=%lu clean=%lu terminate=%lu callbacks=%lu checks=%lu recovery=%lu guards=%lu payload=%lu duplicates=%lu timeouts=%lu cache_ops=%lu dma_api_errors=%lu\n",
	       c_pass, c_rc, c_serial_sub, c_serial_done, c_serial_checks,
	       c_queue_sub, c_queue_done, c_queue_checks, c_queue_order,
	       c_concurrent_sub, c_concurrent_done, c_concurrent_checks,
	       c_threads, c_error_sub, c_error_done, c_error_success,
	       c_error_read, c_error_write, c_error_abort, c_error_mismatch,
	       c_error_clean, c_term_sub, c_term_callbacks, c_term_checks,
	       c_recovery, c_guards, c_payload, c_duplicates, c_timeouts,
	       c_cache, dma_errors);
	print_log_matches(log, "bus-error direction=");
	print_log_matches(log, "error-job=");
	print_log_matches(log, "FPGA-LINUX-DMA-IRQ-CLIENT-PASS");

	if (!strstr(log, "Cheshire whole-cache FENCE DMA maintenance enabled")) {
		errno = EIO;
		fail("missing noncoherent cache-maintenance marker");
	}
	if (!strstr(log, "FPGA-LINUX-DMA-IRQ-CLIENT-PASS")) {
		errno = EIO;
		fail("missing client pass marker");
	}
	if (p_submitted != 67 || p_completed != 67 ||
	    p_completion_irqs != 67 || p_error_irqs != 4 || p_spurious ||
	    p_callbacks != 66 || p_success != 62 || p_read != 2 ||
	    p_write != 2 || p_aborted != 1 || p_abort_requests != 1 ||
	    p_abort_terminals != 1 || p_abort_timeouts ||
	    p_queued_terminated != 7 || p_freed != 74 || p_max_sw != 32 ||
	    p_max_hw != 1 || p_slverr != 2 || p_decerr != 2 ||
	    p_records != 4 || p_full || p_unexpected || p_cache != 216) {
		errno = EIO;
		fail("provider counter invariant");
	}
	if (c_pass != 1 || c_rc || c_serial_sub != 8 || c_serial_done != 8 ||
	    c_serial_checks != 8 || c_queue_sub != 16 || c_queue_done != 16 ||
	    c_queue_checks != 16 || c_queue_order || c_concurrent_sub != 32 ||
	    c_concurrent_done != 32 || c_concurrent_checks != 32 || c_threads ||
	    c_error_sub != 9 || c_error_done != 9 || c_error_success != 5 ||
	    c_error_read != 2 || c_error_write != 2 || c_error_abort ||
	    c_error_mismatch || c_error_clean != 5 || c_term_sub != 8 ||
	    c_term_callbacks || c_term_checks != 8 || c_recovery != 1 ||
	    c_guards || c_payload || c_duplicates || c_timeouts ||
	    c_cache != 216 || dma_errors) {
		errno = EIO;
		fail("client counter invariant");
	}

	free(log);
	puts("FPGA-LINUX-DMA-IRQ-PASS");
	sync();
	reboot(LINUX_REBOOT_CMD_POWER_OFF);
	for (;;)
		syscall(SYS_sched_yield);
}
