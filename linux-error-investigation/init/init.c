// SPDX-License-Identifier: GPL-2.0-only
/* Initramfs controller for the Cheshire Linux-visible AXI error matrix. */

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
	dprintf(STDOUT_FILENO, "FPGA-LINUX-DMA-ERROR-FAIL: %s: %s\n", what,
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
	int fd = open(path, O_RDONLY | O_CLOEXEC);

	if (fd < 0)
		fail(path);
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		fail(path);
	buf[n] = '\0';
	errno = 0;
	unsigned long value = strtoul(buf, &end, 0);
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

int main(void)
{
	unsigned long dma_errors;
	unsigned long p_submitted, p_completed, p_timeouts, p_success;
	unsigned long p_read_failed, p_write_failed, p_aborted;
	unsigned long p_slverr, p_decerr, p_records, p_full, p_unexpected;
	unsigned long c_submitted, c_completed, c_success;
	unsigned long c_read_failed, c_write_failed, c_aborted;
	unsigned long c_mismatch, c_clean, c_guards, c_cache_delta;
	char *log;

	setvbuf(stdout, NULL, _IONBF, 0);
	puts("FPGA-LINUX-DMA-ERROR: init started");
	mount_one("proc", "/proc", "proc");
	mount_one("sysfs", "/sys", "sysfs");
	mount_one("devtmpfs", "/dev", "devtmpfs");
	mount_one("debugfs", "/sys/kernel/debug", "debugfs");

	load_module("/lib/modules/cheshire-idma.ko",
		"expected_slverr_addr=0x40000000 expected_decerr_addr=0x50000000");
	load_module("/lib/modules/cheshire-idma-error-test.ko", "");

	dma_errors = read_ulong("/sys/kernel/debug/dma-api/error_count");
	p_submitted = read_ulong("/sys/module/cheshire_idma/parameters/submitted");
	p_completed = read_ulong("/sys/module/cheshire_idma/parameters/completed");
	p_timeouts = read_ulong("/sys/module/cheshire_idma/parameters/timeouts");
	p_success = read_ulong("/sys/module/cheshire_idma/parameters/success");
	p_read_failed = read_ulong("/sys/module/cheshire_idma/parameters/read_failed");
	p_write_failed = read_ulong("/sys/module/cheshire_idma/parameters/write_failed");
	p_aborted = read_ulong("/sys/module/cheshire_idma/parameters/aborted");
	p_slverr = read_ulong("/sys/module/cheshire_idma/parameters/slverr");
	p_decerr = read_ulong("/sys/module/cheshire_idma/parameters/decerr");
	p_records = read_ulong("/sys/module/cheshire_idma/parameters/buserr_records");
	p_full = read_ulong("/sys/module/cheshire_idma/parameters/fifo_full_seen");
	p_unexpected = read_ulong("/sys/module/cheshire_idma/parameters/unexpected");
	c_submitted = read_ulong("/sys/module/cheshire_idma_error_test/parameters/submitted");
	c_completed = read_ulong("/sys/module/cheshire_idma_error_test/parameters/completed");
	c_success = read_ulong("/sys/module/cheshire_idma_error_test/parameters/success");
	c_read_failed = read_ulong("/sys/module/cheshire_idma_error_test/parameters/read_failed");
	c_write_failed = read_ulong("/sys/module/cheshire_idma_error_test/parameters/write_failed");
	c_aborted = read_ulong("/sys/module/cheshire_idma_error_test/parameters/aborted");
	c_mismatch = read_ulong("/sys/module/cheshire_idma_error_test/parameters/callback_mismatch");
	c_clean = read_ulong("/sys/module/cheshire_idma_error_test/parameters/clean_checks");
	c_guards = read_ulong("/sys/module/cheshire_idma_error_test/parameters/guard_failures");
	c_cache_delta = read_ulong("/sys/module/cheshire_idma_error_test/parameters/cache_ops_delta");
	log = kernel_log();

	printf("FPGA-LINUX-DMA-ERROR: provider submitted=%lu completed=%lu "
	       "timeouts=%lu success=%lu read_failed=%lu write_failed=%lu "
	       "aborted=%lu slverr=%lu decerr=%lu records=%lu fifo_full_seen=%lu "
	       "unexpected=%lu\n", p_submitted, p_completed, p_timeouts,
	       p_success, p_read_failed, p_write_failed, p_aborted, p_slverr,
	       p_decerr, p_records, p_full, p_unexpected);
	printf("FPGA-LINUX-DMA-ERROR: client submitted=%lu completed=%lu "
	       "success=%lu read_failed=%lu write_failed=%lu aborted=%lu "
	       "callback_mismatch=%lu clean_checks=%lu guard_failures=%lu "
	       "cache_ops_delta=%lu dma_api_errors=%lu\n", c_submitted,
	       c_completed, c_success, c_read_failed, c_write_failed, c_aborted,
	       c_mismatch, c_clean, c_guards, c_cache_delta, dma_errors);
	print_log_matches(log, "bus-error direction=");
	print_log_matches(log, "job=");
	print_log_matches(log, "FPGA-LINUX-DMA-ERROR-CLIENT-PASS");

	if (!strstr(log, "Cheshire whole-cache FENCE DMA maintenance enabled")) {
		errno = EIO;
		fail("missing noncoherent cache-maintenance marker");
	}
	if (!strstr(log, "FPGA-LINUX-DMA-ERROR-CLIENT-PASS")) {
		errno = EIO;
		fail("missing client pass marker");
	}
	if (p_submitted != 9 || p_completed != 9 || p_timeouts ||
	    p_success != 5 || p_read_failed != 2 || p_write_failed != 2 ||
	    p_aborted || p_slverr != 2 || p_decerr != 2 || p_records != 4 ||
	    p_full || p_unexpected) {
		errno = EIO;
		fail("provider counter invariant");
	}
	if (c_submitted != 9 || c_completed != 9 || c_success != 5 ||
	    c_read_failed != 2 || c_write_failed != 2 || c_aborted ||
	    c_mismatch || c_clean != 5 || c_guards || c_cache_delta != 21 ||
	    dma_errors) {
		errno = EIO;
		fail("client counter invariant");
	}

	free(log);
	puts("FPGA-LINUX-DMA-ERROR-PASS");
	sync();
	reboot(LINUX_REBOOT_CMD_POWER_OFF);
	for (;;)
		syscall(SYS_sched_yield);
}
