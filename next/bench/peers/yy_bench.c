#include <yyjson.h>
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

// The checksum every arm of a lane prints, so the runner can refuse a fixture whose arms disagree.
#define CHECK_OFFSET 14695981039346656037ULL
#define CHECK_PRIME 1099511628211ULL

static inline uint64_t fnv_byte(uint64_t h, uint8_t b) { return (h ^ b) * CHECK_PRIME; }

static uint64_t fnv_bytes(uint64_t h, const char *p, size_t n) {
	for (size_t i = 0; i < n; i++) h = fnv_byte(h, (uint8_t)p[i]);
	return h;
}

static uint64_t fnv_u64(uint64_t h, uint64_t v) {
	for (int i = 0; i < 8; i++) h = fnv_byte(h, (uint8_t)(v >> (8 * i)));
	return h;
}

static int cmp_ll(const void *a, const void *b) {
	long long x = *(const long long *)a, y = *(const long long *)b;
	return (x > y) - (x < y);
}

// Timing jobs for doc.py. Each job makes WARMUP + TIMED reads of one input and prints the median as key=value
// tokens. File I/O is outside the clock.
//   dom FILE       yyjson_read alone
//   dom_read FILE  yyjson_read, then a visit of every value (string lengths, numbers, bools, nulls)
//   key FILE       one yyjson_obj_get of the first key in every object
#define WARMUP 2
#define TIMED 10

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

// What one dom_read visit saw. `sum` keeps every string's length and every number's value in one accumulator so
// the visit cannot be optimized away, and `check` is the checksum the runner compares.
typedef struct {
	double sum;
	uint64_t check;
} visit_counts;

// Touches the first byte of a string of N bytes.
static void touch_first(const char *p, size_t n) {
	if (n) {
		unsigned char first = (unsigned char)p[0];
		keep(&first);
	}
}

// Reads every value of the document. A string adds its length to the sum and touches its first byte, a number is
// read as its own subtype and added, bools and nulls are noted, and containers are walked in document order.
// Keys are not values, so the visit skips them and the key lane looks them up.
static void visit_value(yyjson_val *v, visit_counts *c) {
	switch (yyjson_get_type(v)) {
	case YYJSON_TYPE_STR: {
		size_t n = yyjson_get_len(v);
		c->sum += (double)n;
		touch_first(yyjson_get_str(v), n);
		break;
	}
	case YYJSON_TYPE_NUM: {
		double d;
		if (yyjson_is_uint(v)) d = (double)yyjson_get_uint(v);
		else if (yyjson_is_sint(v)) d = (double)yyjson_get_sint(v);
		else d = yyjson_get_real(v);
		c->sum += d;
		break;
	}
	case YYJSON_TYPE_ARR: {
		size_t i, n;
		yyjson_val *e;
		yyjson_arr_foreach(v, i, n, e) visit_value(e, c);
		break;
	}
	case YYJSON_TYPE_OBJ: {
		size_t i, n;
		yyjson_val *k, *val;
		yyjson_obj_foreach(v, i, n, k, val) visit_value(val, c);
		break;
	}
	default: break;
	}
}

// The read lane's check, from one untimed visit after the timed calls: each value's tag, then its text length or its
// number bits.
static void visit_check(yyjson_val *v, visit_counts *c) {
	switch (yyjson_get_type(v)) {
	case YYJSON_TYPE_STR: {
		size_t n = yyjson_get_len(v);
		c->check = fnv_byte(c->check, 's');
		c->check = fnv_u64(c->check, (uint64_t)n);
		break;
	}
	case YYJSON_TYPE_NUM: {
		double d;
		uint64_t bits;
		c->check = fnv_byte(c->check, 'n');
		if (yyjson_is_uint(v)) d = (double)yyjson_get_uint(v);
		else if (yyjson_is_sint(v)) d = (double)yyjson_get_sint(v);
		else d = yyjson_get_real(v);
		if (d == 0) bits = 0;
		else memcpy(&bits, &d, sizeof bits);
		c->check = fnv_u64(c->check, bits);
		break;
	}
	case YYJSON_TYPE_ARR: {
		c->check = fnv_byte(c->check, 'a');
		size_t i, n;
		yyjson_val *e;
		yyjson_arr_foreach(v, i, n, e) visit_check(e, c);
		break;
	}
	case YYJSON_TYPE_OBJ: {
		c->check = fnv_byte(c->check, 'o');
		size_t i, n;
		yyjson_val *k, *val;
		yyjson_obj_foreach(v, i, n, k, val) visit_check(val, c);
		break;
	}
	case YYJSON_TYPE_BOOL: c->check = fnv_byte(c->check, yyjson_get_bool(v) ? 't' : 'f'); break;
	case YYJSON_TYPE_NULL: c->check = fnv_byte(c->check, 'z'); break;
	default: break;
	}
}

// The build lane's check: the node count, then each node's kind tag and role in document order. A key is a node of
// role `.Key`, as next's document has it.
static uint64_t summary_count(yyjson_val *v) {
	switch (yyjson_get_type(v)) {
	case YYJSON_TYPE_OBJ: {
		uint64_t n = 1;
		size_t i, m;
		yyjson_val *k, *val;
		yyjson_obj_foreach(v, i, m, k, val) n += 1 + summary_count(val);
		return n;
	}
	case YYJSON_TYPE_ARR: {
		uint64_t n = 1;
		size_t i, m;
		yyjson_val *e;
		yyjson_arr_foreach(v, i, m, e) n += summary_count(e);
		return n;
	}
	default: return 1;
	}
}

static void summary_hash(yyjson_val *v, uint64_t *h) {
	switch (yyjson_get_type(v)) {
	case YYJSON_TYPE_OBJ: {
		*h = fnv_byte(*h, 'o');
		*h = fnv_byte(*h, 0);
		size_t i, m;
		yyjson_val *k, *val;
		yyjson_obj_foreach(v, i, m, k, val) {
			*h = fnv_byte(*h, 's');
			*h = fnv_byte(*h, 1);
			summary_hash(val, h);
		}
		break;
	}
	case YYJSON_TYPE_ARR: {
		*h = fnv_byte(*h, 'a');
		*h = fnv_byte(*h, 0);
		size_t i, m;
		yyjson_val *e;
		yyjson_arr_foreach(v, i, m, e) summary_hash(e, h);
		break;
	}
	case YYJSON_TYPE_STR: *h = fnv_byte(*h, 's'); *h = fnv_byte(*h, 0); break;
	case YYJSON_TYPE_NUM: *h = fnv_byte(*h, 'n'); *h = fnv_byte(*h, 0); break;
	case YYJSON_TYPE_BOOL: *h = fnv_byte(*h, yyjson_get_bool(v) ? 't' : 'f'); *h = fnv_byte(*h, 0); break;
	case YYJSON_TYPE_NULL: *h = fnv_byte(*h, 'z'); *h = fnv_byte(*h, 0); break;
	default: break;
	}
}

static uint64_t summary(yyjson_val *root) {
	uint64_t h = fnv_u64(CHECK_OFFSET, summary_count(root));
	summary_hash(root, &h);
	return h;
}

// Times yyjson_read alone.
static int dom_job(const char *path) {
	long n;
	char *buf = load(path, &n);
	if (!buf) return 1;
	yyjson_alc *alc = yyjson_alc_dyn_new();
	int timed = TIMED;
	long long *ns = malloc(timed * sizeof *ns);
	if (!alc || !ns) {
		fprintf(stderr, "yy_bench: out of memory\n");
		return 1;
	}
	yyjson_doc *d = NULL;
	for (int i = 0; i < WARMUP + timed; i++) {
		if (d) yyjson_doc_free(d);
		yyjson_read_err err;
		long long t = now_ns();
		d = yyjson_read_opts(buf, n, 0, alc, &err);
		keep(d);
		long long el = now_ns() - t;
		if (!d) {
			fprintf(stderr, "yyjson read failed: code %u at byte %zu: %s\n", (unsigned)err.code, err.pos, err.msg);
			return 1;
		}
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	qsort(ns, timed, sizeof *ns, cmp_ll);
	long long med = (ns[(timed - 1) / 2] + ns[timed / 2]) / 2;
	free(ns);
	uint64_t chk = d ? summary(yyjson_doc_get_root(d)) : 0;
	printf("gb_per_s=%.4f ns=%lld records=0 check=%llu\n", (double)n / (double)med, med,
		(unsigned long long)chk);
	yyjson_doc_free(d);
	yyjson_alc_dyn_free(alc);
	free(buf);
	return 0;
}

// Times yyjson_read plus a visit of every value of the resulting DOM.
static int dom_read_job(const char *path) {
	long n;
	char *buf = load(path, &n);
	if (!buf) return 1;
	yyjson_alc *alc = yyjson_alc_dyn_new();
	int timed = TIMED;
	long long *ns = malloc(timed * sizeof *ns);
	if (!alc || !ns) {
		fprintf(stderr, "yy_bench: out of memory\n");
		return 1;
	}
	visit_counts c = {0};
	yyjson_doc *d = NULL;
	for (int i = 0; i < WARMUP + timed; i++) {
		if (d) yyjson_doc_free(d);
		c = (visit_counts){0};
		yyjson_read_err err;
		long long t = now_ns();
		d = yyjson_read_opts(buf, n, 0, alc, &err);
		if (d) visit_value(yyjson_doc_get_root(d), &c);
		keep(&c);
		long long el = now_ns() - t;
		if (!d) {
			fprintf(stderr, "yyjson read failed: code %u at byte %zu: %s\n", (unsigned)err.code, err.pos, err.msg);
			return 1;
		}
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	qsort(ns, timed, sizeof *ns, cmp_ll);
	long long med = (ns[(timed - 1) / 2] + ns[timed / 2]) / 2;
	free(ns);
	visit_counts cc = {0};
	cc.check = CHECK_OFFSET;
	if (d) visit_check(yyjson_doc_get_root(d), &cc);
	printf("gb_per_s=%.4f ns=%lld check=%llu\n", (double)n / (double)med, med,
		(unsigned long long)cc.check);
	yyjson_doc_free(d);
	yyjson_alc_dyn_free(alc);
	free(buf);
	return 0;
}

// The first object in document order, as docprobe's `key` lane finds the document's first Map node.
static yyjson_val *first_object(yyjson_val *v) {
	if (!v) return NULL;
	switch (yyjson_get_type(v)) {
	case YYJSON_TYPE_OBJ: return v;
	case YYJSON_TYPE_ARR: {
		size_t i, n;
		yyjson_val *e;
		yyjson_arr_foreach(v, i, n, e) {
			yyjson_val *o = first_object(e);
			if (o) return o;
		}
		return NULL;
	}
	default: return NULL;
	}
}

// The `key` lane's work: one yyjson_obj_get of `key` in every object, then every member's value.
static void key_walk(yyjson_val *v, const char *key, size_t *answers, size_t *objects) {
	switch (yyjson_get_type(v)) {
	case YYJSON_TYPE_ARR: {
		size_t i, n;
		yyjson_val *e;
		yyjson_arr_foreach(v, i, n, e) key_walk(e, key, answers, objects);
		break;
	}
	case YYJSON_TYPE_OBJ: {
		(*objects)++;
		if (yyjson_obj_get(v, key)) (*answers)++;
		size_t i, n;
		yyjson_val *k, *val;
		yyjson_obj_foreach(v, i, n, k, val) key_walk(val, key, answers, objects);
		break;
	}
	default: break;
	}
}

// Times yyjson_read plus the key lane: the first object's first key, then one yyjson_obj_get of it per
// object. The key name is read from the root's own DOM, so the same key is looked up as in docprobe's lane.
static int key_job(const char *path) {
	long n;
	char *buf = load(path, &n);
	if (!buf) return 1;
	yyjson_alc *alc = yyjson_alc_dyn_new();
	int timed = TIMED;
	long long *ns = malloc(timed * sizeof *ns);
	if (!alc || !ns) {
		fprintf(stderr, "yy_bench: out of memory\n");
		return 1;
	}
	size_t answers = 0;
	size_t objects = 0;
	char shown[256] = "";
	yyjson_doc *d = NULL;
	for (int i = 0; i < WARMUP + timed; i++) {
		if (d) yyjson_doc_free(d);
		yyjson_read_err err;
		long long t = now_ns();
		d = yyjson_read_opts(buf, n, 0, alc, &err);
		size_t a = 0;
		size_t o = 0;
		if (d) {
			yyjson_val *root = yyjson_doc_get_root(d);
			yyjson_val *obj = first_object(root);
			yyjson_val *k = NULL;
			if (obj) {
				size_t j, m;
				yyjson_val *v;
				yyjson_obj_foreach(obj, j, m, k, v) { break; }
			}
			if (!k) {
				// No object, or an object with no members: the lane has no key to look up.
				shown[0] = 0;
			} else {
				size_t kl = yyjson_get_len(k);
				char *key = malloc(kl + 1);
				if (!key) {
					fprintf(stderr, "yy_bench: out of memory\n");
					return 1;
				}
				memcpy(key, yyjson_get_str(k), kl);
				key[kl] = 0;
				key_walk(root, key, &a, &o);
				if (!shown[0]) snprintf(shown, sizeof shown, "%s", key);
				free(key);
			}
		}
		keep(&a);
		long long el = now_ns() - t;
		if (!d) {
			fprintf(stderr, "yyjson read failed: code %u at byte %zu: %s\n", (unsigned)err.code, err.pos, err.msg);
			return 1;
		}
		answers = a;
		objects = o;
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	qsort(ns, timed, sizeof *ns, cmp_ll);
	long long med = (ns[(timed - 1) / 2] + ns[timed / 2]) / 2;
	free(ns);
	uint64_t chk = fnv_bytes(CHECK_OFFSET, shown, strlen(shown));
	chk = fnv_u64(fnv_u64(chk, (uint64_t)answers), (uint64_t)objects);
	printf("gb_per_s=%.4f ns=%lld check=%llu answers=%zu objects=%zu key=%s\n", (double)n / (double)med,
		med, (unsigned long long)chk, answers, objects, shown);
	yyjson_doc_free(d);
	yyjson_alc_dyn_free(alc);
	free(buf);
	return 0;
}

int main(int argc, char **argv) {
	if (argc == 3 && !strcmp(argv[1], "dom")) return dom_job(argv[2]);
	if (argc == 3 && !strcmp(argv[1], "dom_read")) return dom_read_job(argv[2]);
	if (argc == 3 && !strcmp(argv[1], "key")) return key_job(argv[2]);
	fprintf(stderr, "usage: yy_bench dom FILE | dom_read FILE | key FILE\n");
	return 2;
}
