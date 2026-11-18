// `write-tinycbor typed FILE`: tinycbor's encoder writes the logs records of a CBOR fixture, held as C structs whose strings
// point into the fixture's bytes, into a buffer sized once. Reading the fixture into the structs is outside the clock.
// tinycbor has no document type, so it has no `doc` job. GB/s counts the output's bytes. `check` is the read check of the
// text written, read back with tinycbor's parser outside the clock: in document order each value's kind tag, then a
// string's byte count or a number's binary64 bits, zero as +0.
#include "../doc/tinycbor_walk.h"

typedef struct {
	const char *ts, *level, *service, *msg, *id;
	size_t ts_n, level_n, service_n, msg_n, id_n;
	int64_t status, bytes;
	double duration_ms;
} record;

static int fail(const char *what, CborError err) {
	fprintf(stderr, "tinycbor %s failed: %s\n", what, cbor_error_string(err));
	return 1;
}

// The definite text string `it` points to as a pointer into the input and a length, then moves `it` past it.
static CborError take_text(CborValue *it, const char **p, size_t *len) {
	CborError err;
	if (!cbor_value_is_text_string(it)) return CborErrorIllegalType;
	if ((err = cbor_value_begin_string_iteration(it))) return err;
	if ((err = cbor_value_get_text_string_chunk(it, p, len, it))) return err;
	const char *more;
	size_t more_len;
	err = cbor_value_get_text_string_chunk(it, &more, &more_len, it);
	if (err != CborErrorNoMoreStringChunks) return err ? err : CborErrorIllegalType;
	return cbor_value_finish_string_iteration(it);
}

static CborError take_record(CborValue *it, record *r) {
	CborValue m;
	CborError err = cbor_value_enter_container(it, &m);
	for (int i = 0; !err && !cbor_value_at_end(&m); i++) {
		const char *k;
		size_t kn;
		if ((err = take_text(&m, &k, &kn))) return err;
		if (kn == 2 && !memcmp(k, "ts", 2)) err = take_text(&m, &r->ts, &r->ts_n);
		else if (kn == 5 && !memcmp(k, "level", 5)) err = take_text(&m, &r->level, &r->level_n);
		else if (kn == 7 && !memcmp(k, "service", 7)) err = take_text(&m, &r->service, &r->service_n);
		else if (kn == 3 && !memcmp(k, "msg", 3)) err = take_text(&m, &r->msg, &r->msg_n);
		else if (kn == 2 && !memcmp(k, "id", 2)) err = take_text(&m, &r->id, &r->id_n);
		else if (kn == 6 && !memcmp(k, "status", 6)) {
			if (!(err = cbor_value_get_int64(&m, &r->status))) err = cbor_value_advance_fixed(&m);
		} else if (kn == 5 && !memcmp(k, "bytes", 5)) {
			if (!(err = cbor_value_get_int64(&m, &r->bytes))) err = cbor_value_advance_fixed(&m);
		} else if (kn == 11 && !memcmp(k, "duration_ms", 11)) {
			if (!(err = cbor_value_get_double(&m, &r->duration_ms))) err = cbor_value_advance_fixed(&m);
		} else {
			err = cbor_value_advance(&m);
		}
	}
	return err ? err : cbor_value_leave_container(it, &m);
}

// The fixture's one map, `logs`, whose array holds the records.
static CborError take_records(const uint8_t *buf, size_t n, record **out, size_t *count) {
	CborParser parser;
	CborValue it, root, list;
	CborError err = cbor_parser_init(buf, n, 0, &parser, &it);
	if (err) return err;
	if ((err = cbor_value_enter_container(&it, &root))) return err;
	const char *k;
	size_t kn;
	if ((err = take_text(&root, &k, &kn))) return err;
	if (kn != 4 || memcmp(k, "logs", 4)) return CborErrorIllegalType;
	if ((err = cbor_value_get_array_length(&root, count))) return err;
	*out = calloc(*count ? *count : 1, sizeof **out);
	if (!*out) return CborErrorOutOfMemory;
	if ((err = cbor_value_enter_container(&root, &list))) return err;
	for (size_t i = 0; i < *count && !err; i++) err = take_record(&list, &(*out)[i]);
	return err;
}

static CborError put_text(CborEncoder *e, const char *name, const char *p, size_t n) {
	CborError err = cbor_encode_text_stringz(e, name);
	return err ? err : cbor_encode_text_string(e, p, n);
}

static CborError put_records(const record *r, size_t count, uint8_t *buf, size_t cap, size_t *out) {
	CborEncoder enc, root, list, m;
	cbor_encoder_init(&enc, buf, cap, 0);
	CborError err = cbor_encoder_create_map(&enc, &root, 1);
	if (!err) err = cbor_encode_text_stringz(&root, "logs");
	if (!err) err = cbor_encoder_create_array(&root, &list, count);
	for (size_t i = 0; i < count && !err; i++) {
		err = cbor_encoder_create_map(&list, &m, 8);
		if (!err) err = put_text(&m, "ts", r[i].ts, r[i].ts_n);
		if (!err) err = put_text(&m, "level", r[i].level, r[i].level_n);
		if (!err) err = put_text(&m, "service", r[i].service, r[i].service_n);
		if (!err) err = put_text(&m, "msg", r[i].msg, r[i].msg_n);
		if (!err) err = cbor_encode_text_stringz(&m, "status");
		if (!err) err = cbor_encode_int(&m, r[i].status);
		if (!err) err = cbor_encode_text_stringz(&m, "bytes");
		if (!err) err = cbor_encode_int(&m, r[i].bytes);
		if (!err) err = cbor_encode_text_stringz(&m, "duration_ms");
		if (!err) err = cbor_encode_double(&m, r[i].duration_ms);
		if (!err) err = put_text(&m, "id", r[i].id, r[i].id_n);
		if (!err) err = cbor_encoder_close_container(&list, &m);
	}
	if (!err) err = cbor_encoder_close_container(&root, &list);
	if (!err) err = cbor_encoder_close_container(&enc, &root);
	*out = cbor_encoder_get_buffer_size(&enc, buf);
	return err;
}

int main(int argc, char **argv) {
	if (argc != 3 || strcmp(argv[1], "typed")) {
		fprintf(stderr, "usage: write-tinycbor typed FILE\n");
		return 2;
	}
	long n;
	char *src = load(argv[2], &n);
	if (!src) return 1;
	record *recs;
	size_t count, out = 0;
	CborError err = take_records((const uint8_t *)src, n, &recs, &count);
	if (err) return fail("read", err);
	size_t cap = (size_t)n * 3;
	uint8_t *buf = malloc(cap);
	if (!buf) return 1;
	long long ns[TIMED];
	for (int i = 0; i < WARMUP + TIMED; i++) {
		long long t = now_ns();
		err = put_records(recs, count, buf, cap, &out);
		if (err) return fail("write", err);
		keep(buf);
		long long el = now_ns() - t;
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	long long med = median(ns);
	sink s;
	sink_init(&s, SINK_READ);
	if ((err = tc_validate(buf, out))) return fail("validate", err);
	if ((err = tc_read(buf, out, &s))) return fail("read back", err);
	report(out, med, s.check, "out=%zu", out);
	return 0;
}
