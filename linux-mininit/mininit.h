/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef CHESHIRE_LINUX_MININIT_H
#define CHESHIRE_LINUX_MININIT_H

typedef unsigned long mi_size_t;
typedef long mi_ssize_t;

enum {
	MI_AT_FDCWD = -100,
	MI_O_RDONLY = 0,
	MI_O_RDWR = 2,
	MI_O_CLOEXEC = 02000000,
	MI_S_IFCHR = 0020000,
	MI_EBUSY = 16,
	MI_EEXIST = 17,
	MI_STDOUT = 1,
};

enum {
	MI_NR_dup3 = 24,
	MI_NR_mknodat = 33,
	MI_NR_mkdirat = 34,
	MI_NR_mount = 40,
	MI_NR_openat = 56,
	MI_NR_close = 57,
	MI_NR_read = 63,
	MI_NR_write = 64,
	MI_NR_sync = 81,
	MI_NR_exit = 93,
	MI_NR_syslog = 116,
	MI_NR_sched_yield = 124,
	MI_NR_reboot = 142,
	MI_NR_finit_module = 273,
};

static inline long mi_syscall6(long number, long arg0, long arg1, long arg2,
			       long arg3, long arg4, long arg5)
{
	register long a0 __asm__("a0") = arg0;
	register long a1 __asm__("a1") = arg1;
	register long a2 __asm__("a2") = arg2;
	register long a3 __asm__("a3") = arg3;
	register long a4 __asm__("a4") = arg4;
	register long a5 __asm__("a5") = arg5;
	register long a7 __asm__("a7") = number;

	__asm__ volatile ("ecall"
			  : "+r" (a0), "+r" (a1), "+r" (a2), "+r" (a3),
			    "+r" (a4), "+r" (a5)
			  : "r" (a7)
			  : "memory");
	return a0;
}

static inline long mi_syscall4(long number, long arg0, long arg1, long arg2,
			       long arg3)
{
	return mi_syscall6(number, arg0, arg1, arg2, arg3, 0, 0);
}

static inline long mi_syscall3(long number, long arg0, long arg1, long arg2)
{
	return mi_syscall6(number, arg0, arg1, arg2, 0, 0, 0);
}

static inline long mi_syscall1(long number, long arg0)
{
	return mi_syscall6(number, arg0, 0, 0, 0, 0, 0);
}

static mi_size_t mi_strlen(const char *text)
{
	mi_size_t length = 0;

	while (text[length])
		length++;
	return length;
}

static long mi_write(int fd, const void *buffer, mi_size_t length)
{
	return mi_syscall3(MI_NR_write, fd, (long)buffer, length);
}

static void mi_puts(const char *text)
{
	mi_write(MI_STDOUT, text, mi_strlen(text));
	mi_write(MI_STDOUT, "\n", 1);
}

static void mi_puts_part(const char *text)
{
	mi_write(MI_STDOUT, text, mi_strlen(text));
}

static void mi_put_ulong(unsigned long value)
{
	char buffer[3 * sizeof(value) + 1];
	mi_size_t position = sizeof(buffer);

	if (!value) {
		mi_write(MI_STDOUT, "0", 1);
		return;
	}
	while (value) {
		buffer[--position] = '0' + value % 10;
		value /= 10;
	}
	mi_write(MI_STDOUT, buffer + position, sizeof(buffer) - position);
}

static void mi_put_long(long value)
{
	if (value < 0) {
		mi_write(MI_STDOUT, "-", 1);
		mi_put_ulong((unsigned long)(-(value + 1)) + 1);
	} else {
		mi_put_ulong((unsigned long)value);
	}
}

static void mi_kv(const char *name, unsigned long value)
{
	mi_puts_part(name);
	mi_put_ulong(value);
}

static int mi_starts_with(const char *buffer, mi_size_t length,
			  const char *needle)
{
	mi_size_t needle_length = mi_strlen(needle);
	mi_size_t index;

	if (needle_length > length)
		return 0;
	for (index = 0; index < needle_length; index++)
		if (buffer[index] != needle[index])
			return 0;
	return 1;
}

static int mi_contains_n(const char *buffer, mi_size_t length,
			 const char *needle)
{
	mi_size_t needle_length = mi_strlen(needle);
	mi_size_t index;

	if (!needle_length)
		return 1;
	if (needle_length > length)
		return 0;
	for (index = 0; index <= length - needle_length; index++)
		if (mi_starts_with(buffer + index, length - index, needle))
			return 1;
	return 0;
}

static int mi_contains(const char *buffer, const char *needle)
{
	return mi_contains_n(buffer, mi_strlen(buffer), needle);
}

__attribute__((noreturn))
static void mi_stop(void)
{
	mi_syscall1(MI_NR_sync, 0);
	for (;;)
		mi_syscall1(MI_NR_sched_yield, 0);
}

__attribute__((noreturn))
static void mi_fail(const char *prefix, const char *what, long error)
{
	mi_puts_part(prefix);
	mi_puts_part(what);
	mi_puts_part(" rc=");
	mi_put_long(error);
	mi_write(MI_STDOUT, "\n", 1);
	mi_stop();
}

static void mi_make_dir(const char *prefix, const char *path)
{
	long result = mi_syscall3(MI_NR_mkdirat, MI_AT_FDCWD, (long)path, 0755);

	if (result < 0 && result != -MI_EEXIST)
		mi_fail(prefix, path, result);
}

static void mi_mount_one(const char *prefix, const char *source,
			 const char *target, const char *type)
{
	long result;

	mi_make_dir(prefix, target);
	result = mi_syscall6(MI_NR_mount, (long)source, (long)target,
			     (long)type, 0, 0, 0);
	if (result < 0 && result != -MI_EBUSY)
		mi_fail(prefix, target, result);
}

/*
 * The directory-form initramfs cannot carry a /dev/console node when it is
 * assembled by an unprivileged build.  Linux therefore starts /init without
 * file descriptors 0, 1 and 2.  Mount devtmpfs, create the traditional static
 * console device (major 5, minor 1), and establish those descriptors before
 * the first acceptance record is written.  devtmpfs does not create the
 * /dev/console compatibility node merely because a serial console exists.
 */
static void mi_setup_console(const char *prefix)
{
	static const char console[] = "/dev/console";
	long result;
	long fd;
	int target;

	mi_mount_one(prefix, "devtmpfs", "/dev", "devtmpfs");
	result = mi_syscall4(MI_NR_mknodat, MI_AT_FDCWD, (long)console,
			     MI_S_IFCHR | 0600, (5 << 8) | 1);
	if (result < 0 && result != -MI_EEXIST)
		mi_fail(prefix, "mknodat /dev/console", result);
	fd = mi_syscall4(MI_NR_openat, MI_AT_FDCWD, (long)console,
			 MI_O_RDWR | MI_O_CLOEXEC, 0);
	if (fd < 0)
		mi_fail(prefix, console, fd);
	for (target = 0; target <= 2; target++) {
		long result;

		if (fd == target)
			continue;
		result = mi_syscall3(MI_NR_dup3, fd, target, 0);
		if (result < 0)
			mi_fail(prefix, "dup3 /dev/console", result);
	}
	if (fd > 2)
		mi_syscall1(MI_NR_close, fd);
}

static void mi_load_module(const char *prefix, const char *path,
			   const char *parameters)
{
	long fd = mi_syscall4(MI_NR_openat, MI_AT_FDCWD, (long)path,
			      MI_O_RDONLY | MI_O_CLOEXEC, 0);
	long result;

	if (fd < 0)
		mi_fail(prefix, path, fd);
	result = mi_syscall3(MI_NR_finit_module, fd, (long)parameters, 0);
	mi_syscall1(MI_NR_close, fd);
	if (result < 0)
		mi_fail(prefix, path, result);
}

static unsigned long mi_parse_ulong(const char *prefix, const char *path,
				    const char *buffer, mi_size_t length)
{
	unsigned long value = 0;
	unsigned int base = 10;
	mi_size_t index = 0;
	int digits = 0;

	while (index < length &&
	       (buffer[index] == ' ' || buffer[index] == '\t' ||
		buffer[index] == '\n'))
		index++;
	if (index + 2 <= length && buffer[index] == '0' &&
	    (buffer[index + 1] == 'x' || buffer[index + 1] == 'X')) {
		base = 16;
		index += 2;
	}
	for (; index < length; index++) {
		unsigned int digit;
		char byte = buffer[index];

		if (byte >= '0' && byte <= '9')
			digit = byte - '0';
		else if (byte >= 'a' && byte <= 'f')
			digit = byte - 'a' + 10;
		else if (byte >= 'A' && byte <= 'F')
			digit = byte - 'A' + 10;
		else
			break;
		if (digit >= base)
			break;
		value = value * base + digit;
		digits++;
	}
	if (!digits)
		mi_fail(prefix, path, -1);
	return value;
}

static unsigned long mi_read_ulong(const char *prefix, const char *path)
{
	char buffer[64];
	long fd = mi_syscall4(MI_NR_openat, MI_AT_FDCWD, (long)path,
			      MI_O_RDONLY | MI_O_CLOEXEC, 0);
	long length;

	if (fd < 0)
		mi_fail(prefix, path, fd);
	length = mi_syscall3(MI_NR_read, fd, (long)buffer, sizeof(buffer));
	mi_syscall1(MI_NR_close, fd);
	if (length <= 0)
		mi_fail(prefix, path, length);
	return mi_parse_ulong(prefix, path, buffer, length);
}

#define MI_LOG_SIZE (64 * 1024)
static char mi_log_buffer[MI_LOG_SIZE];

static char *mi_kernel_log(const char *prefix)
{
	long length = mi_syscall3(MI_NR_syslog, 3, (long)mi_log_buffer,
				  MI_LOG_SIZE - 1);

	if (length < 0)
		mi_fail(prefix, "klogctl read", length);
	mi_log_buffer[length] = '\0';
	return mi_log_buffer;
}

static __attribute__((unused))
void mi_print_log_matches(const char *log, const char *needle)
{
	const char *line = log;

	while (*line) {
		const char *end = line;
		mi_size_t length;

		while (*end && *end != '\n')
			end++;
		length = end - line;
		if (mi_contains_n(line, length, needle)) {
			mi_write(MI_STDOUT, line, length);
			mi_write(MI_STDOUT, "\n", 1);
		}
		if (!*end)
			break;
		line = end + 1;
	}
}

__attribute__((noreturn))
static void mi_poweroff(void)
{
	mi_syscall1(MI_NR_sync, 0);
	mi_syscall4(MI_NR_reboot, 0xfee1deadUL, 672274793UL,
		    0x4321fedcUL, 0);
	mi_stop();
}

#endif
