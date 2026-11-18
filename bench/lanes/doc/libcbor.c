// `doc-libcbor build|read|key FILE`: `cbor_load` of the text into libcbor's item tree, then nothing, a visit of every value,
// or one lookup of the first key in every object. libcbor does not judge the UTF-8 of a text string, so this arm is in
// the tables of arms that do not validate text. The tree is freed outside the clock, at the start of the next call.
#include <cbor.h>

#include "cbor_events.h"

enum { LC_MAX_DEPTH = 512 };

static int lc_walk(const cbor_item_t *v, sink *s, int role, int depth) {
	if (depth > LC_MAX_DEPTH) return 1;
	while (cbor_isa_tag(v)) v = cbor_tag_item(v);
	switch (cbor_typeof(v)) {
	case CBOR_TYPE_UINT: sink_number(s, (double)cbor_get_int(v), role); break;
	case CBOR_TYPE_NEGINT: {
		uint64_t raw = cbor_get_int(v);
		sink_number(s, raw <= INT64_MAX ? (double)(-1 - (int64_t)raw) : -1.0 - (double)raw, role);
		break;
	}
	case CBOR_TYPE_BYTESTRING: {
		size_t len = 0;
		if (cbor_bytestring_is_indefinite(v)) {
			cbor_item_t **c = cbor_bytestring_chunks_handle(v);
			for (size_t i = 0; i < cbor_bytestring_chunk_count(v); i++) len += cbor_bytestring_length(c[i]);
		} else {
			len = cbor_bytestring_length(v);
		}
		sink_text(s, NULL, len, role, 0);
		break;
	}
	case CBOR_TYPE_STRING: {
		if (cbor_string_is_indefinite(v)) {
			size_t len = 0;
			cbor_item_t **c = cbor_string_chunks_handle(v);
			for (size_t i = 0; i < cbor_string_chunk_count(v); i++) len += cbor_string_length(c[i]);
			sink_text(s, NULL, len, role, 1);
		} else {
			sink_text(s, (const char *)cbor_string_handle(v), cbor_string_length(v), role, 1);
		}
		break;
	}
	case CBOR_TYPE_ARRAY: {
		cbor_item_t **e = cbor_array_handle(v);
		sink_open(s, 0, role);
		for (size_t i = 0; i < cbor_array_size(v); i++)
			if (lc_walk(e[i], s, 0, depth + 1)) return 1;
		sink_close(s, 0);
		break;
	}
	case CBOR_TYPE_MAP: {
		struct cbor_pair *m = cbor_map_handle(v);
		sink_open(s, 1, role);
		for (size_t i = 0; i < cbor_map_size(v); i++)
			if (lc_walk(m[i].key, s, 1, depth + 1) || lc_walk(m[i].value, s, 0, depth + 1)) return 1;
		sink_close(s, 1);
		break;
	}
	case CBOR_TYPE_FLOAT_CTRL:
		if (cbor_float_ctrl_is_ctrl(v)) {
			if (cbor_is_bool(v)) sink_simple(s, cbor_get_bool(v) ? 't' : 'f', role);
			else sink_simple(s, 'z', role);
		} else {
			sink_number(s, cbor_float_get_float(v), role);
		}
		break;
	default: return 1;
	}
	return 0;
}

int main(int argc, char **argv) {
	if (argc != 3 || (strcmp(argv[1], "build") && strcmp(argv[1], "read") && strcmp(argv[1], "key"))) {
		fprintf(stderr, "usage: doc-libcbor build|read|key FILE\n");
		return 2;
	}
	int read = !strcmp(argv[1], "read"), key = !strcmp(argv[1], "key");
	long n;
	char *buf = load(argv[2], &n);
	if (!buf) return 1;
	long long ns[TIMED];
	cbor_item_t *d = NULL;
	sink timed;
	for (int i = 0; i < WARMUP + TIMED; i++) {
		if (d) cbor_decref(&d);
		sink_init(&timed, key ? SINK_KEY : SINK_SUM);
		struct cbor_load_result result;
		long long t = now_ns();
		d = cbor_load((cbor_data)buf, (size_t)n, &result);
		if (!d || result.read != (size_t)n) {
			fprintf(stderr, "libcbor load failed: error %d at byte %zu\n", (int)result.error.code, result.error.position);
			return 1;
		}
		keep(d);
		if ((read || key) && lc_walk(d, &timed, 0, 0)) return 1;
		keep(&timed);
		long long el = now_ns() - t;
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	long long med = median(ns);
	if (key) {
		report(n, med, sink_key_check(&timed), "answers=%llu objects=%llu key=%.*s", (unsigned long long)timed.answers,
		       (unsigned long long)timed.objects, (int)timed.name_len, timed.name);
		return 0;
	}
	sink s;
	if (read) {
		sink_init(&s, SINK_READ);
		if (lc_walk(d, &s, 0, 0)) return 1;
		report(n, med, s.check, "");
		return 0;
	}
	sink_init(&s, SINK_COUNT);
	if (lc_walk(d, &s, 0, 0)) return 1;
	uint64_t count = s.count;
	sink_init(&s, SINK_BUILD);
	s.check = fnv_u64(CHECK_OFFSET, count);
	if (lc_walk(d, &s, 0, 0)) return 1;
	report(n, med, s.check, "");
	return 0;
}
