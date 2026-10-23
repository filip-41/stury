#include <yyjson.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef CLOCK_MONOTONIC_RAW
#define BENCH_CLOCK CLOCK_MONOTONIC_RAW
#else
#define BENCH_CLOCK CLOCK_MONOTONIC
#endif

static long long now_ns(void) {
	struct timespec t;
	clock_gettime(BENCH_CLOCK, &t);
	return t.tv_sec * 1000000000LL + t.tv_nsec;
}

// Keeps *p and what it points to from being optimized away.
static inline void keep(const void *p) { __asm__ volatile("" : : "r"(p) : "memory"); }

static int cmp_ll(const void *a, const void *b) {
	long long x = *(const long long *)a, y = *(const long long *)b;
	return (x > y) - (x < y);
}

// Timing jobs for bench/compare.py that match stury's bench lanes. Each job makes WARMUP + RUNS reads of one
// input and prints the median as key=value tokens. The allocator persists across reads. A typed read builds
// new records, as a generic decoder does; the previous read's records are freed outside the clock, as is file
// I/O.
//   dom FILE           yyjson_read alone
//   typed SHAPE FILE   yyjson_read, then a read of the DOM into the shapes of stury's bench_unmarshal.odin
//                      (logs, logs_subset, nested, config). Every member is visited, the last duplicate wins,
//                      and every field is required. STURY_DUMP names a file to receive the decoded value as
//                      JSON.
#define WARMUP 2

typedef struct {
	const char *p;
	size_t n;
} str_t;

typedef struct {
	str_t ts, level, service, msg;
	int64_t status, bytes;
	double duration_ms;
	str_t id;
} log_record;

typedef struct {
	int64_t status;
	str_t id;
} log_subset;

typedef struct {
	int64_t id;
	str_t name;
	int64_t *tags;
	size_t n_tags, cap_tags;
	double *a;
	size_t n_a, cap_a;
	int64_t c;
	bool ok;
} nested_rec;

typedef struct {
	str_t name;
	int64_t port;
} config_head;

typedef enum { LOGS, LOGS_SUBSET, NESTED, CONFIG } shape_t;

// One typed read's output: the records (log_record, log_subset or nested_rec) or the config head. The read
// that fills the records allocates them.
typedef struct {
	void *recs;
	size_t n, cap;
	config_head config;
} typed_out;

// Grows *buf to hold `need` elements of `size` bytes when it holds fewer; the new tail is zeroed.
static bool reserve(void **buf, size_t *cap, size_t need, size_t size) {
	if (need <= *cap) return true;
	void *p = realloc(*buf, need * size);
	if (!p) return false;
	memset((char *)p + *cap * size, 0, (need - *cap) * size);
	*buf = p;
	*cap = need;
	return true;
}

static bool get_str(yyjson_val *v, str_t *out) {
	if (!yyjson_is_str(v)) return false;
	out->p = yyjson_get_str(v);
	out->n = yyjson_get_len(v);
	return true;
}

// Reads an integer in int64 range. A number with a fraction or exponent is a real and is refused.
static bool get_i64(yyjson_val *v, int64_t *out) {
	if (yyjson_is_sint(v)) return *out = yyjson_get_sint(v), true;
	if (yyjson_is_uint(v) && yyjson_get_uint(v) <= INT64_MAX) return *out = (int64_t)yyjson_get_uint(v), true;
	return false;
}

static bool get_f64(yyjson_val *v, double *out) {
	if (!yyjson_is_num(v)) return false;
	*out = yyjson_get_num(v);
	return true;
}

static bool read_log(yyjson_val *o, log_record *r) {
	if (!yyjson_is_obj(o)) return false;
	unsigned seen = 0;
	size_t i, n;
	yyjson_val *k, *v;
	yyjson_obj_foreach(o, i, n, k, v) {
		bool ok = true;
		if (yyjson_equals_str(k, "ts")) ok = get_str(v, &r->ts), seen |= 1;
		else if (yyjson_equals_str(k, "level")) ok = get_str(v, &r->level), seen |= 2;
		else if (yyjson_equals_str(k, "service")) ok = get_str(v, &r->service), seen |= 4;
		else if (yyjson_equals_str(k, "msg")) ok = get_str(v, &r->msg), seen |= 8;
		else if (yyjson_equals_str(k, "status")) ok = get_i64(v, &r->status), seen |= 16;
		else if (yyjson_equals_str(k, "bytes")) ok = get_i64(v, &r->bytes), seen |= 32;
		else if (yyjson_equals_str(k, "duration_ms")) ok = get_f64(v, &r->duration_ms), seen |= 64;
		else if (yyjson_equals_str(k, "id")) ok = get_str(v, &r->id), seen |= 128;
		if (!ok) return false;
	}
	return seen == 0xFF;
}

static bool read_subset(yyjson_val *o, log_subset *r) {
	if (!yyjson_is_obj(o)) return false;
	unsigned seen = 0;
	size_t i, n;
	yyjson_val *k, *v;
	yyjson_obj_foreach(o, i, n, k, v) {
		bool ok = true;
		if (yyjson_equals_str(k, "status")) ok = get_i64(v, &r->status), seen |= 1;
		else if (yyjson_equals_str(k, "id")) ok = get_str(v, &r->id), seen |= 2;
		if (!ok) return false;
	}
	return seen == 3;
}

static bool read_inner(yyjson_val *o, nested_rec *r) {
	if (!yyjson_is_obj(o)) return false;
	unsigned seen = 0;
	size_t i, n;
	yyjson_val *k, *v;
	yyjson_obj_foreach(o, i, n, k, v) {
		if (yyjson_equals_str(k, "a")) {
			if (!yyjson_is_arr(v)) return false;
			r->n_a = yyjson_arr_size(v);
			if (!reserve((void **)&r->a, &r->cap_a, r->n_a, sizeof *r->a)) return false;
			size_t j, m;
			yyjson_val *e;
			yyjson_arr_foreach(v, j, m, e) if (!get_f64(e, &r->a[j])) return false;
			seen |= 1;
		} else if (yyjson_equals_str(k, "b")) {
			if (!yyjson_is_obj(v)) return false;
			bool c_seen = false;
			size_t j, m;
			yyjson_val *bk, *bv;
			yyjson_obj_foreach(v, j, m, bk, bv) if (yyjson_equals_str(bk, "c")) {
				if (!get_i64(bv, &r->c)) return false;
				c_seen = true;
			}
			if (!c_seen) return false;
			seen |= 2;
		}
	}
	return seen == 3;
}

static bool read_nested(yyjson_val *o, nested_rec *r) {
	if (!yyjson_is_obj(o)) return false;
	unsigned seen = 0;
	size_t i, n;
	yyjson_val *k, *v;
	yyjson_obj_foreach(o, i, n, k, v) {
		bool ok = true;
		if (yyjson_equals_str(k, "id")) ok = get_i64(v, &r->id), seen |= 1;
		else if (yyjson_equals_str(k, "name")) ok = get_str(v, &r->name), seen |= 2;
		else if (yyjson_equals_str(k, "tags")) {
			ok = yyjson_is_arr(v);
			if (ok) {
				r->n_tags = yyjson_arr_size(v);
				if (!reserve((void **)&r->tags, &r->cap_tags, r->n_tags, sizeof *r->tags)) return false;
				size_t j, m;
				yyjson_val *e;
				yyjson_arr_foreach(v, j, m, e) ok = ok && get_i64(e, &r->tags[j]);
			}
			seen |= 4;
		} else if (yyjson_equals_str(k, "nested")) ok = read_inner(v, r), seen |= 8;
		else if (yyjson_equals_str(k, "ok")) {
			ok = yyjson_is_bool(v);
			r->ok = yyjson_get_bool(v);
			seen |= 16;
		}
		if (!ok) return false;
	}
	return seen == 31;
}

static size_t rec_size(shape_t shape) {
	return shape == LOGS ? sizeof(log_record) : shape == LOGS_SUBSET ? sizeof(log_subset) : sizeof(nested_rec);
}

static bool read_record(shape_t shape, yyjson_val *o, char *rec) {
	switch (shape) {
	case LOGS: return read_log(o, (log_record *)rec);
	case LOGS_SUBSET: return read_subset(o, (log_subset *)rec);
	default: return read_nested(o, (nested_rec *)rec);
	}
}

static bool read_records(shape_t shape, yyjson_val *arr, typed_out *out) {
	if (!yyjson_is_arr(arr)) return false;
	out->n = yyjson_arr_size(arr);
	if (!reserve(&out->recs, &out->cap, out->n, rec_size(shape))) return false;
	size_t i, n;
	yyjson_val *e;
	yyjson_arr_foreach(arr, i, n, e) if (!read_record(shape, e, (char *)out->recs + i * rec_size(shape))) return false;
	return true;
}

static bool read_typed(shape_t shape, yyjson_val *root, typed_out *out) {
	if (shape == NESTED) return read_records(shape, root, out);
	if (!yyjson_is_obj(root)) return false;
	unsigned seen = 0;
	size_t i, n;
	yyjson_val *k, *v;
	yyjson_obj_foreach(root, i, n, k, v) {
		bool ok = true;
		if (shape == CONFIG) {
			if (yyjson_equals_str(k, "name")) ok = get_str(v, &out->config.name), seen |= 1;
			else if (yyjson_equals_str(k, "port")) ok = get_i64(v, &out->config.port), seen |= 2;
		} else if (yyjson_equals_str(k, "logs")) {
			ok = read_records(shape, v, out), seen = 3;
		}
		if (!ok) return false;
	}
	return seen == 3;
}

static void free_typed(shape_t shape, typed_out *out) {
	if (shape == NESTED)
		for (size_t i = 0; i < out->cap; i++) {
			nested_rec *r = (nested_rec *)out->recs + i;
			free(r->tags);
			free(r->a);
		}
	free(out->recs);
	memset(out, 0, sizeof *out);
}

static void dump_str(FILE *f, str_t s) {
	fputc('"', f);
	for (size_t i = 0; i < s.n; i++) {
		unsigned char ch = (unsigned char)s.p[i];
		if (ch == '"' || ch == '\\') fprintf(f, "\\%c", ch);
		else if (ch < 0x20) fprintf(f, "\\u%04x", ch);
		else fputc(ch, f);
	}
	fputc('"', f);
}

static void dump_typed(FILE *f, shape_t shape, const typed_out *out) {
	if (shape == CONFIG) {
		fputs("{\"name\":", f), dump_str(f, out->config.name), fprintf(f, ",\"port\":%lld}", (long long)out->config.port);
		return;
	}
	fputs(shape == NESTED ? "[" : "{\"logs\":[", f);
	for (size_t i = 0; i < out->n; i++) {
		if (i) fputc(',', f);
		if (shape == LOGS) {
			const log_record *r = (const log_record *)out->recs + i;
			fputs("{\"ts\":", f), dump_str(f, r->ts), fputs(",\"level\":", f), dump_str(f, r->level);
			fputs(",\"service\":", f), dump_str(f, r->service), fputs(",\"msg\":", f), dump_str(f, r->msg);
			fprintf(f, ",\"status\":%lld,\"bytes\":%lld,\"duration_ms\":%.17g,\"id\":", (long long)r->status,
				(long long)r->bytes, r->duration_ms);
			dump_str(f, r->id), fputc('}', f);
		} else if (shape == LOGS_SUBSET) {
			const log_subset *r = (const log_subset *)out->recs + i;
			fprintf(f, "{\"status\":%lld,\"id\":", (long long)r->status), dump_str(f, r->id), fputc('}', f);
		} else {
			const nested_rec *r = (const nested_rec *)out->recs + i;
			fprintf(f, "{\"id\":%lld,\"name\":", (long long)r->id), dump_str(f, r->name), fputs(",\"tags\":[", f);
			for (size_t j = 0; j < r->n_tags; j++) fprintf(f, j ? ",%lld" : "%lld", (long long)r->tags[j]);
			fputs("],\"nested\":{\"a\":[", f);
			for (size_t j = 0; j < r->n_a; j++) fprintf(f, j ? ",%.17g" : "%.17g", r->a[j]);
			fprintf(f, "],\"b\":{\"c\":%lld}},\"ok\":%s}", (long long)r->c, r->ok ? "true" : "false");
		}
	}
	fputs(shape == NESTED ? "]" : "]}", f);
}

static char *load(const char *path, long *n) {
	FILE *f = fopen(path, "rb");
	if (!f) {
		perror(path);
		return NULL;
	}
	char *buf = NULL;
	if (fseek(f, 0, SEEK_END) == 0 && (*n = ftell(f)) >= 0 && fseek(f, 0, SEEK_SET) == 0) {
		buf = malloc(*n ? *n : 1);
		if (buf && fread(buf, 1, *n, f) != (size_t)*n) {
			free(buf);
			buf = NULL;
		}
	}
	if (!buf) fprintf(stderr, "yy_bench: cannot read %s\n", path);
	fclose(f);
	return buf;
}

// Returns BENCH_RUNS if set, else 10. Exits 2 unless BENCH_RUNS is an integer >= 1.
static int timed_runs(void) {
	const char *s = getenv("BENCH_RUNS");
	if (!s) return 10;
	char *end;
	long v = strtol(s, &end, 10);
	if (end == s || *end || v < 1 || v > INT_MAX) {
		fprintf(stderr, "BENCH_RUNS must be an integer >= 1, got \"%s\"\n", s);
		exit(2);
	}
	return (int)v;
}

// Times yyjson_read, followed by the typed read of `shape` when `typed` is true.
static int read_job(const char *path, bool typed, shape_t shape) {
	long n;
	char *buf = load(path, &n);
	if (!buf) return 1;
	yyjson_alc *alc = yyjson_alc_dyn_new();
	int timed = timed_runs();
	long long *ns = malloc(timed * sizeof *ns);
	if (!alc || !ns) {
		fprintf(stderr, "yy_bench: out of memory\n");
		return 1;
	}
	typed_out out = {0};
	yyjson_doc *d = NULL;
	for (int i = 0; i < WARMUP + timed; i++) {
		if (d) yyjson_doc_free(d);
		free_typed(shape, &out);
		yyjson_read_err err;
		long long t = now_ns();
		d = yyjson_read_opts(buf, n, 0, alc, &err);
		bool ok = d && (!typed || read_typed(shape, yyjson_doc_get_root(d), &out));
		keep(d);
		keep(&out);
		long long el = now_ns() - t;
		if (!d) {
			fprintf(stderr, "yyjson read failed: code %u at byte %zu: %s\n", (unsigned)err.code, err.pos, err.msg);
			return 1;
		}
		if (!ok) {
			fprintf(stderr, "yyjson typed read failed\n");
			return 1;
		}
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	qsort(ns, timed, sizeof *ns, cmp_ll);
	// The mean of the two middle samples.
	long long med = (ns[(timed - 1) / 2] + ns[timed / 2]) / 2;
	free(ns);
	const char *dump = getenv("STURY_DUMP");
	if (typed && dump) {
		FILE *f = fopen(dump, "wb");
		if (!f) return 1;
		dump_typed(f, shape, &out);
		fclose(f);
	}
	printf("gb_per_s=%.4f ns=%lld records=%zu\n", (double)n / (double)med, med, typed ? (shape == CONFIG ? 1 : out.n) : 0);
	free_typed(shape, &out);
	yyjson_doc_free(d);
	yyjson_alc_dyn_free(alc);
	free(buf);
	return 0;
}

int main(int argc, char **argv) {
	if (argc == 3 && !strcmp(argv[1], "dom")) return read_job(argv[2], false, LOGS);
	if (argc == 4 && !strcmp(argv[1], "typed")) {
		const char *names[] = {"logs", "logs_subset", "nested", "config"};
		for (int s = LOGS; s <= CONFIG; s++)
			if (!strcmp(argv[2], names[s])) return read_job(argv[3], true, (shape_t)s);
	}
	fprintf(stderr, "usage: yy_bench dom FILE | typed SHAPE FILE\n");
	return 2;
}
