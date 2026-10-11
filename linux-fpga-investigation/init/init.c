// SPDX-License-Identifier: GPL-2.0-only
/* Minimal initramfs controller for the Cheshire Linux+iDMA smoke test. */

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
	dprintf(STDOUT_FILENO, "FPGA-LINUX-DMA-FAIL: %s: %s\n", what,
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

int main(void)
{
	unsigned long dma_errors, nr_submitted, nr_completed, nr_timeouts;
	unsigned long cache_ops;
	char *log;

	setvbuf(stdout, NULL, _IONBF, 0);
	puts("FPGA-LINUX-DMA: init started");
	mount_one("proc", "/proc", "proc");
	mount_one("sysfs", "/sys", "sysfs");
	mount_one("devtmpfs", "/dev", "devtmpfs");
	mount_one("debugfs", "/sys/kernel/debug", "debugfs");

	load_module("/lib/modules/cheshire-idma.ko", "");
	load_module("/lib/modules/dmatest.ko",
		"iterations=8 threads_per_chan=1 max_channels=1 "
		"test_buf_size=4096 timeout=10000 verbose=1 run=1 wait=1");

	dma_errors = read_ulong("/sys/kernel/debug/dma-api/error_count");
	nr_submitted = read_ulong("/sys/module/cheshire_idma/parameters/submitted");
	nr_completed = read_ulong("/sys/module/cheshire_idma/parameters/completed");
	nr_timeouts = read_ulong("/sys/module/cheshire_idma/parameters/timeouts");
	cache_ops = read_ulong("/sys/module/cheshire_idma/parameters/cache_ops");
	log = kernel_log();

	printf("FPGA-LINUX-DMA: submitted=%lu completed=%lu timeouts=%lu "
	       "dma_api_errors=%lu cache_ops=%lu\n", nr_submitted, nr_completed,
	       nr_timeouts, dma_errors, cache_ops);

	if (!strstr(log, "summary 8 tests, 0 failures")) {
		errno = EIO;
		fail("missing successful dmatest summary");
	}
	if (!strstr(log, "Cheshire whole-cache FENCE DMA maintenance enabled")) {
		errno = EIO;
		fail("missing noncoherent cache-maintenance marker");
	}
	if (nr_submitted != 8 || nr_completed != 8 || nr_timeouts || dma_errors) {
		errno = EIO;
		fail("counter invariant");
	}
	/* Each copy maps a source and bidirectional destination, then unmaps it. */
	if (cache_ops < 24) {
		errno = EIO;
		fail("noncoherent cache-operation count");
	}

	free(log);
	puts("FPGA-LINUX-DMA-PASS");
	sync();
	reboot(LINUX_REBOOT_CMD_POWER_OFF);
	for (;;)
		syscall(SYS_sched_yield);
}
