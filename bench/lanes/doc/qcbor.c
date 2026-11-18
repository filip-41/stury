// `doc-qcbor build|read|key FILE`: QCBOR's decoder, `QCBORDecode_GetNext` over every item of the text and
// `QCBORDecode_Finish` after it. QCBOR builds no document and does not judge the UTF-8 of a text string, so this arm is in
// the tables of arms that do not validate text. `build` decodes every item, `read` also visits every value and `key`
// looks up the first key in every object, from the labels of the items. The checks come from an untimed decode.
#include <qcbor/qcbor_decode.h>

#include "cbor_events.h"

enum { QC_LEVELS = QCBOR_MAX_ARRAY_NESTING + 2 };

// Decodes `buf` into `s`, a container opened when its item comes and closed when the item after its last member has a lower
// nesting level. Returns the first error.
static QCBORError qc_read(const uint8_t *buf, size_t n, sink *s) {
	QCBORDecodeContext ctx;
	QCBORItem it;
	unsigned char is_map[QC_LEVELS] = {0};
	QCBORDecode_Init(&ctx, (UsefulBufC){buf, n}, QCBOR_DECODE_MODE_NORMAL);
	do {
		QCBORDecode_GetNext(&ctx, &it);
		QCBORError err = QCBORDecode_GetError(&ctx);
		if (err) return err;
		int level = it.uNestingLevel, next = it.uNextNestLevel;
		if (it.uLabelType == QCBOR_TYPE_TEXT_STRING) {
			sink_text(s, (const char *)it.label.string.ptr, it.label.string.len, 1, 1);
		} else if (it.uLabelType == QCBOR_TYPE_INT64) {
			sink_number(s, (double)it.label.int64, 1);
		} else if (it.uLabelType == QCBOR_TYPE_UINT64) {
			sink_number(s, (double)it.label.uint64, 1);
		} else if (it.uLabelType != QCBOR_TYPE_NONE) {
			return QCBOR_ERR_MAP_LABEL_TYPE;
		}
		int container = 0;
		switch (it.uDataType) {
		case QCBOR_TYPE_ARRAY:
		case QCBOR_TYPE_MAP:
			container = 1;
			sink_open(s, it.uDataType == QCBOR_TYPE_MAP, 0);
			is_map[level + 1] = it.uDataType == QCBOR_TYPE_MAP;
			break;
		case QCBOR_TYPE_INT64: sink_number(s, (double)it.val.int64, 0); break;
		case QCBOR_TYPE_UINT64: sink_number(s, (double)it.val.uint64, 0); break;
		case QCBOR_TYPE_DOUBLE: sink_number(s, it.val.dfnum, 0); break;
		case QCBOR_TYPE_FLOAT: sink_number(s, (double)it.val.fnum, 0); break;
		case QCBOR_TYPE_TEXT_STRING:
			sink_text(s, (const char *)it.val.string.ptr, it.val.string.len, 0, 1);
			break;
		case QCBOR_TYPE_BYTE_STRING:
			sink_text(s, (const char *)it.val.string.ptr, it.val.string.len, 0, 0);
			break;
		case QCBOR_TYPE_TRUE: sink_simple(s, 't', 0); break;
		case QCBOR_TYPE_FALSE: sink_simple(s, 'f', 0); break;
		case QCBOR_TYPE_NULL:
		case QCBOR_TYPE_UNDEF: sink_simple(s, 'z', 0); break;
		default: return QCBOR_ERR_UNSUPPORTED;
		}
		if (container && next == level) sink_close(s, is_map[level + 1]);
		for (int l = level; l > next; l--) sink_close(s, is_map[l]);
	} while (it.uNextNestLevel > 0);
	return QCBORDecode_Finish(&ctx);
}

static int fail(QCBORError err) {
	fprintf(stderr, "qcbor decode failed: %s\n", qcbor_err_to_str(err));
	return 1;
}

int main(int argc, char **argv) {
	if (argc != 3 || (strcmp(argv[1], "build") && strcmp(argv[1], "read") && strcmp(argv[1], "key"))) {
		fprintf(stderr, "usage: doc-qcbor build|read|key FILE\n");
		return 2;
	}
	int read = !strcmp(argv[1], "read"), key = !strcmp(argv[1], "key");
	long n;
	char *buf = load(argv[2], &n);
	if (!buf) return 1;
	long long ns[TIMED];
	sink timed;
	for (int i = 0; i < WARMUP + TIMED; i++) {
		sink_init(&timed, key ? SINK_KEY : read ? SINK_SUM : SINK_COUNT);
		long long t = now_ns();
		QCBORError err = qc_read((const uint8_t *)buf, n, &timed);
		if (err) return fail(err);
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
	QCBORError err;
	if (read) {
		sink_init(&s, SINK_READ);
		if ((err = qc_read((const uint8_t *)buf, n, &s))) return fail(err);
		report(n, med, s.check, "");
		return 0;
	}
	sink_init(&s, SINK_COUNT);
	if ((err = qc_read((const uint8_t *)buf, n, &s))) return fail(err);
	uint64_t count = s.count;
	sink_init(&s, SINK_BUILD);
	s.check = fnv_u64(CHECK_OFFSET, count);
	if ((err = qc_read((const uint8_t *)buf, n, &s))) return fail(err);
	report(n, med, s.check, "");
	return 0;
}
