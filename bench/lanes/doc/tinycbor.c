// `doc-tinycbor build|read|key FILE`: tinycbor builds no document, so every lane judges the whole text with
// `cbor_value_validate` (structure, UTF-8 of every text string, no data after the item) and then reads in place. `build` is
// the validation alone, `read` adds a visit of every value and `key` one lookup of the first key in every object. The
// checks come from an untimed walk of the same parser, which counts and folds the nodes a document would hold.
#include "tinycbor_walk.h"

static int fail(const char *what, CborError err) {
	fprintf(stderr, "tinycbor %s failed: %s\n", what, cbor_error_string(err));
	return 1;
}

int main(int argc, char **argv) {
	if (argc != 3 || (strcmp(argv[1], "build") && strcmp(argv[1], "read") && strcmp(argv[1], "key"))) {
		fprintf(stderr, "usage: doc-tinycbor build|read|key FILE\n");
		return 2;
	}
	int read = !strcmp(argv[1], "read"), key = !strcmp(argv[1], "key");
	long n;
	char *buf = load(argv[2], &n);
	if (!buf) return 1;
	long long ns[TIMED];
	sink timed;
	for (int i = 0; i < WARMUP + TIMED; i++) {
		sink_init(&timed, key ? SINK_KEY : SINK_SUM);
		long long t = now_ns();
		CborError err = tc_validate((const uint8_t *)buf, n);
		if (err) return fail("validate", err);
		if (read || key) {
			if ((err = tc_read((const uint8_t *)buf, n, &timed))) return fail("read", err);
		}
		keep(&timed);
		long long el = now_ns() - t;
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	long long med = median(ns);
	CborError err;
	if (key) {
		report(n, med, sink_key_check(&timed), "answers=%llu objects=%llu key=%.*s", (unsigned long long)timed.answers,
		       (unsigned long long)timed.objects, (int)timed.name_len, timed.name);
		return 0;
	}
	sink s;
	if (read) {
		sink_init(&s, SINK_READ);
		if ((err = tc_read((const uint8_t *)buf, n, &s))) return fail("read", err);
		report(n, med, s.check, "");
		return 0;
	}
	sink_init(&s, SINK_COUNT);
	if ((err = tc_read((const uint8_t *)buf, n, &s))) return fail("read", err);
	uint64_t count = s.count;
	sink_init(&s, SINK_BUILD);
	s.check = fnv_u64(CHECK_OFFSET, count);
	if ((err = tc_read((const uint8_t *)buf, n, &s))) return fail("read", err);
	report(n, med, s.check, "");
	return 0;
}
