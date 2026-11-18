// tinycbor's pull parser walked in document order into a `sink` (cbor_events.h). Shared by the doc and write drivers,
// which read a CBOR text back to check it. tinycbor builds no document: a string is read in place by its chunk and a
// container entered and left. `tc_validate` is `cbor_value_validate` with UTF-8 and the end of the data judged.
#pragma once
#include <stdbool.h>

#include <cbor.h>

#include "cbor_events.h"

enum { TC_MAX_DEPTH = 512 };

static CborError tc_walk(CborValue *it, sink *s, int role, int depth) {
	if (depth > TC_MAX_DEPTH) return CborErrorNestingTooDeep;
	CborError err;
	while (cbor_value_get_type(it) == CborTagType)
		if ((err = cbor_value_skip_tag(it))) return err;
	switch (cbor_value_get_type(it)) {
	case CborIntegerType: {
		uint64_t raw;
		if ((err = cbor_value_get_raw_integer(it, &raw))) return err;
		double x = (double)raw;
		if (cbor_value_is_negative_integer(it)) x = raw <= INT64_MAX ? (double)(-1 - (int64_t)raw) : -1.0 - (double)raw;
		sink_number(s, x, role);
		return cbor_value_advance_fixed(it);
	}
	case CborTextStringType:
	case CborByteStringType: {
		int is_text = cbor_value_is_text_string(it);
		const char *first = NULL;
		size_t len = 0, chunks = 0;
		if ((err = cbor_value_begin_string_iteration(it))) return err;
		for (;;) {
			const char *p;
			size_t l;
			err = is_text ? cbor_value_get_text_string_chunk(it, &p, &l, it)
			              : cbor_value_get_byte_string_chunk(it, (const uint8_t **)&p, &l, it);
			if (err == CborErrorNoMoreStringChunks) break;
			if (err) return err;
			if (!chunks++) first = p;
			len += l;
		}
		sink_text(s, chunks == 1 ? first : NULL, len, role, is_text);
		return cbor_value_finish_string_iteration(it);
	}
	case CborArrayType:
	case CborMapType: {
		int is_map = cbor_value_is_map(it);
		CborValue inner;
		sink_open(s, is_map, role);
		if ((err = cbor_value_enter_container(it, &inner))) return err;
		while (!cbor_value_at_end(&inner)) {
			if (is_map && (err = tc_walk(&inner, s, 1, depth + 1))) return err;
			if ((err = tc_walk(&inner, s, 0, depth + 1))) return err;
		}
		sink_close(s, is_map);
		return cbor_value_leave_container(it, &inner);
	}
	case CborHalfFloatType: {
		float f;
		if ((err = cbor_value_get_half_float_as_float(it, &f))) return err;
		sink_number(s, (double)f, role);
		return cbor_value_advance_fixed(it);
	}
	case CborFloatType: {
		float f;
		if ((err = cbor_value_get_float(it, &f))) return err;
		sink_number(s, (double)f, role);
		return cbor_value_advance_fixed(it);
	}
	case CborDoubleType: {
		double d;
		if ((err = cbor_value_get_double(it, &d))) return err;
		sink_number(s, d, role);
		return cbor_value_advance_fixed(it);
	}
	case CborBooleanType: {
		bool b;
		if ((err = cbor_value_get_boolean(it, &b))) return err;
		sink_simple(s, b ? 't' : 'f', role);
		return cbor_value_advance_fixed(it);
	}
	case CborNullType:
	case CborUndefinedType:
	case CborSimpleType:
		sink_simple(s, 'z', role);
		return cbor_value_advance_fixed(it);
	default: return CborErrorUnknownType;
	}
}

// Parses `buf` and walks it into `s`. Returns the first error. Data after the item is `tc_validate`'s to refuse.
static CborError tc_read(const uint8_t *buf, size_t n, sink *s) {
	CborParser parser;
	CborValue it;
	CborError err = cbor_parser_init(buf, n, 0, &parser, &it);
	if (err) return err;
	return tc_walk(&it, s, 0, 0);
}

// Judges the whole text: structure, UTF-8 of every text string, and no data after the item.
static CborError tc_validate(const uint8_t *buf, size_t n) {
	CborParser parser;
	CborValue it;
	CborError err = cbor_parser_init(buf, n, 0, &parser, &it);
	if (err) return err;
	return cbor_value_validate(&it, CborValidateCompleteData | CborValidateUtf8);
}
