// `doc-yyjson build|read|key FILE`: yyjson_read of the text, then nothing, a visit of every value, or one yyjson_obj_get of
// the first key in every object.
#include <yyjson.h>

#include "timing.h"

// What one read visit saw. `sum` keeps every string's length and every number's value in one accumulator so the visit
// cannot be optimized away, and `check` is the checksum the runner compares.
typedef struct {
	double sum;
	uint64_t check;
} visit_counts;

// The binary64 value of a number.
static double number_of(yyjson_val *v) {
	if (yyjson_is_uint(v)) return (double)yyjson_get_uint(v);
	if (yyjson_is_sint(v)) return (double)yyjson_get_sint(v);
	return yyjson_get_real(v);
}

// Reads every value of the document. A string adds its length to the sum and touches its first byte, a number is read as
// its own subtype and added, bools and nulls are noted, and containers are walked in document order. Keys are not
// values, so the visit skips them and the key lane looks them up.
static void visit_value(yyjson_val *v, visit_counts *c) {
	switch (yyjson_get_type(v)) {
	case YYJSON_TYPE_STR: {
		size_t n = yyjson_get_len(v);
		c->sum += (double)n;
		if (n) {
			unsigned char first = (unsigned char)yyjson_get_str(v)[0];
			keep(&first);
		}
		break;
	}
	case YYJSON_TYPE_NUM: c->sum += number_of(v); break;
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
	case YYJSON_TYPE_STR:
		c->check = fnv_byte(c->check, 's');
		c->check = fnv_u64(c->check, (uint64_t)yyjson_get_len(v));
		break;
	case YYJSON_TYPE_NUM: {
		double d = number_of(v);
		uint64_t bits = 0;
		c->check = fnv_byte(c->check, 'n');
		if (d != 0) memcpy(&bits, &d, sizeof bits);
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

// The build lane's check: the node count, then each node's kind tag and role in document order. A key is a node of role
// `.Key`, as the document of stury has it.
static uint64_t summary_count(yyjson_val *v) {
	uint64_t n = 1;
	size_t i, m;
	if (yyjson_is_obj(v)) {
		yyjson_val *k, *val;
		yyjson_obj_foreach(v, i, m, k, val) n += 1 + summary_count(val);
	} else if (yyjson_is_arr(v)) {
		yyjson_val *e;
		yyjson_arr_foreach(v, i, m, e) n += summary_count(e);
	}
	return n;
}

static void summary_hash(yyjson_val *v, uint64_t *h) {
	switch (yyjson_get_type(v)) {
	case YYJSON_TYPE_OBJ: {
		*h = fnv_byte(fnv_byte(*h, 'o'), 0);
		size_t i, m;
		yyjson_val *k, *val;
		yyjson_obj_foreach(v, i, m, k, val) {
			*h = fnv_byte(fnv_byte(*h, 's'), 1);
			summary_hash(val, h);
		}
		break;
	}
	case YYJSON_TYPE_ARR: {
		*h = fnv_byte(fnv_byte(*h, 'a'), 0);
		size_t i, m;
		yyjson_val *e;
		yyjson_arr_foreach(v, i, m, e) summary_hash(e, h);
		break;
	}
	case YYJSON_TYPE_STR: *h = fnv_byte(fnv_byte(*h, 's'), 0); break;
	case YYJSON_TYPE_NUM: *h = fnv_byte(fnv_byte(*h, 'n'), 0); break;
	case YYJSON_TYPE_BOOL: *h = fnv_byte(fnv_byte(*h, yyjson_get_bool(v) ? 't' : 'f'), 0); break;
	case YYJSON_TYPE_NULL: *h = fnv_byte(fnv_byte(*h, 'z'), 0); break;
	default: break;
	}
}

// The first object in document order, as stury's `key` lane finds the document's first Map node.
static yyjson_val *first_object(yyjson_val *v) {
	if (yyjson_is_obj(v)) return v;
	if (yyjson_is_arr(v)) {
		size_t i, n;
		yyjson_val *e;
		yyjson_arr_foreach(v, i, n, e) {
			yyjson_val *o = first_object(e);
			if (o) return o;
		}
	}
	return NULL;
}

// The `key` lane's work: one yyjson_obj_get of `key` in every object, then every member's value.
static void key_walk(yyjson_val *v, const char *key, size_t *answers, size_t *objects) {
	size_t i, n;
	if (yyjson_is_arr(v)) {
		yyjson_val *e;
		yyjson_arr_foreach(v, i, n, e) key_walk(e, key, answers, objects);
	} else if (yyjson_is_obj(v)) {
		(*objects)++;
		if (yyjson_obj_get(v, key)) (*answers)++;
		yyjson_val *k, *val;
		yyjson_obj_foreach(v, i, n, k, val) key_walk(val, key, answers, objects);
	}
}

int main(int argc, char **argv) {
	if (argc != 3 || (strcmp(argv[1], "build") && strcmp(argv[1], "read") && strcmp(argv[1], "key"))) {
		fprintf(stderr, "usage: doc-yyjson build|read|key FILE\n");
		return 2;
	}
	int read = !strcmp(argv[1], "read"), key = !strcmp(argv[1], "key");
	long n;
	char *buf = load(argv[2], &n);
	yyjson_alc *alc = yyjson_alc_dyn_new();
	if (!buf || !alc) return 1;
	long long ns[TIMED];
	size_t answers = 0, objects = 0;
	char shown[256] = "";
	yyjson_doc *d = NULL;
	for (int i = 0; i < WARMUP + TIMED; i++) {
		if (d) yyjson_doc_free(d);
		yyjson_read_err err;
		visit_counts c = {0};
		size_t a = 0, o = 0;
		long long t = now_ns();
		d = yyjson_read_opts(buf, n, 0, alc, &err);
		if (!d) {
			fprintf(stderr, "yyjson read failed: code %u at byte %zu: %s\n", (unsigned)err.code, err.pos, err.msg);
			return 1;
		}
		keep(d);
		if (read) visit_value(yyjson_doc_get_root(d), &c);
		if (key) {
			// No object, or an object with no members: the lane has no key to look up.
			yyjson_val *root = yyjson_doc_get_root(d), *obj = first_object(root), *k = NULL, *v;
			size_t j, m;
			if (obj) yyjson_obj_foreach(obj, j, m, k, v) break;
			if (k) {
				char *name = strndup(yyjson_get_str(k), yyjson_get_len(k));
				key_walk(root, name, &a, &o);
				if (!shown[0]) snprintf(shown, sizeof shown, "%s", name);
				free(name);
			}
		}
		keep(&c);
		keep(&a);
		long long el = now_ns() - t;
		answers = a;
		objects = o;
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	long long med = median(ns);
	uint64_t check;
	if (key) {
		check = fnv_u64(fnv_u64(fnv_bytes(CHECK_OFFSET, shown, strlen(shown)), answers), objects);
		report(n, med, check, "answers=%zu objects=%zu key=%s", answers, objects, shown);
	} else if (read) {
		visit_counts c = {0, CHECK_OFFSET};
		visit_check(yyjson_doc_get_root(d), &c);
		report(n, med, c.check, "");
	} else {
		uint64_t h = fnv_u64(CHECK_OFFSET, summary_count(yyjson_doc_get_root(d)));
		summary_hash(yyjson_doc_get_root(d), &h);
		report(n, med, h, "");
	}
	return 0;
}
