// What every C and C++ probe shares: the clock, the sampling rule, the check hash and the output line. WARMUP untimed
// calls, then TIMED timed ones, and the mean of the two middle samples as the median. The Odin and Rust probes follow
// the same rule and hash (timing.odin, rust/src/lib.rs).
#pragma once
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { WARMUP = 2, TIMED = 10 };

#ifdef CLOCK_MONOTONIC_RAW
#define BENCH_CLOCK CLOCK_MONOTONIC_RAW
#else
#define BENCH_CLOCK CLOCK_MONOTONIC
#endif

static inline long long now_ns(void) {
	struct timespec t;
	clock_gettime(BENCH_CLOCK, &t);
	return t.tv_sec * 1000000000LL + t.tv_nsec;
}

// Keeps *p and what it points to from being optimized away.
static inline void keep(const void *p) { __asm__ volatile("" : : "r"(p) : "memory"); }

#define CHECK_OFFSET 14695981039346656037ULL
#define CHECK_PRIME 1099511628211ULL

static inline uint64_t fnv_byte(uint64_t h, uint8_t b) { return (h ^ b) * CHECK_PRIME; }

static inline uint64_t fnv_bytes(uint64_t h, const char *p, size_t n) {
	for (size_t i = 0; i < n; i++) h = fnv_byte(h, (uint8_t)p[i]);
	return h;
}

static inline uint64_t fnv_u64(uint64_t h, uint64_t v) {
	for (int i = 0; i < 8; i++) h = fnv_byte(h, (uint8_t)(v >> (8 * i)));
	return h;
}

static inline int cmp_ll(const void *a, const void *b) {
	long long x = *(const long long *)a, y = *(const long long *)b;
	return (x > y) - (x < y);
}

// The median of the TIMED samples in ns[], which it sorts.
static inline long long median(long long *ns) {
	qsort(ns, TIMED, sizeof *ns, cmp_ll);
	return (ns[(TIMED - 1) / 2] + ns[TIMED / 2]) / 2;
}

// The bytes of the file at PATH, malloc'd, with their count in *n. NULL after a message when it cannot be read.
static inline char *load(const char *path, long *n) {
	FILE *f = fopen(path, "rb");
	char *buf = NULL;
	if (f && fseek(f, 0, SEEK_END) == 0 && (*n = ftell(f)) >= 0 && fseek(f, 0, SEEK_SET) == 0) {
		buf = (char *)malloc(*n ? *n : 1);
		if (buf && fread(buf, 1, *n, f) != (size_t)*n) {
			free(buf);
			buf = NULL;
		}
	}
	if (f) fclose(f);
	if (!buf) fprintf(stderr, "cannot read %s\n", path);
	return buf;
}

// Prints the line the runner reads, then EXTRA, a printf format of more key=value tokens.
static inline void report(size_t len, long long ns, uint64_t check, const char *extra, ...) {
	printf("gb_per_s=%.4f ns=%lld check=%llu ", (double)len / (double)ns, ns, (unsigned long long)check);
	va_list args;
	va_start(args, extra);
	vprintf(extra, args);
	va_end(args);
	putchar('\n');
}

#ifdef __cplusplus
// The median ns of TIMED calls of `once` after WARMUP calls, or -1 when a call fails. `once` returns one call's ns, or -1.
template <class F>
static inline int64_t median_ns(F&& once) {
	long long times[TIMED];
	for (int i = 0; i < WARMUP + TIMED; i++) {
		long long ns = once();
		if (ns < 0) return -1;
		if (i >= WARMUP) times[i - WARMUP] = ns;
	}
	return median(times);
}
#endif
