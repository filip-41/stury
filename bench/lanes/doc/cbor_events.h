// What the C CBOR drivers (tinycbor, QCBOR, libcbor) share: each walks its parse of the text in document order and reports
// every node as an event to a `sink`, which folds it under one of the lanes' checks. A key is a node of role 1. Containers
// are told apart from scalars, and a tag counts as its content. The sink does the timed work of the `read` and `key`
// lanes (`SINK_SUM`, `SINK_KEY`) and the untimed checks (`SINK_COUNT` then `SINK_BUILD` for the build check, `SINK_READ`
// for the read check).
#pragma once
#include <math.h>

#include "timing.h"

enum sink_mode { SINK_COUNT, SINK_BUILD, SINK_READ, SINK_SUM, SINK_KEY };

enum { KEY_MAX_DEPTH = 1024 };

typedef struct {
	enum sink_mode mode;
	uint64_t count, check;
	double sum;
	// The key lane: the first key met names the lookup, `found` is per open object, and `answers` counts the objects
	// that held a member of that name.
	char name[256];
	size_t name_len;
	int named, depth;
	unsigned char found[KEY_MAX_DEPTH];
	uint64_t answers, objects;
} sink;

static inline void sink_init(sink *s, enum sink_mode mode) {
	memset(s, 0, sizeof *s);
	s->mode = mode;
	s->check = CHECK_OFFSET;
}

static inline void sink_node(sink *s, char tag, int role) {
	switch (s->mode) {
	case SINK_COUNT: s->count++; break;
	case SINK_BUILD: s->check = fnv_byte(fnv_byte(s->check, (uint8_t)tag), (uint8_t)role); break;
	case SINK_READ:
		if (!role) s->check = fnv_byte(s->check, (uint8_t)tag);
		break;
	default: break;
	}
}

static inline void sink_open(sink *s, int is_map, int role) {
	sink_node(s, is_map ? 'o' : 'a', role);
	if (s->mode == SINK_KEY && is_map) {
		s->objects++;
		if (s->depth < KEY_MAX_DEPTH) s->found[s->depth] = 0;
		s->depth++;
	}
}

static inline void sink_close(sink *s, int is_map) {
	if (s->mode == SINK_KEY && is_map) {
		s->depth--;
		if (s->depth >= 0 && s->depth < KEY_MAX_DEPTH && s->found[s->depth]) s->answers++;
	}
}

// A string or byte string of `len` bytes, `first` pointing at its first byte or NULL. A text key in the key lane names
// the lookup when it is the first key met, and marks its object when it equals the name.
static inline void sink_text(sink *s, const char *p, size_t len, int role, int is_text) {
	sink_node(s, 's', role);
	switch (s->mode) {
	case SINK_READ:
		if (!role) s->check = fnv_u64(s->check, (uint64_t)len);
		break;
	case SINK_SUM:
		if (!role) {
			s->sum += (double)len;
			if (p && len) keep(p);
		}
		break;
	case SINK_KEY:
		if (role && is_text && s->depth > 0) {
			if (!s->named) {
				s->named = 1;
				if (len < sizeof s->name) {
					memcpy(s->name, p, len);
					s->name_len = len;
				}
			}
			if (len == s->name_len && s->name_len && !memcmp(p, s->name, len) && s->depth <= KEY_MAX_DEPTH)
				s->found[s->depth - 1] = 1;
		}
		break;
	default: break;
	}
}

static inline void sink_number(sink *s, double x, int role) {
	sink_node(s, 'n', role);
	switch (s->mode) {
	case SINK_READ:
		if (!role) {
			uint64_t bits = 0;
			if (x != 0) memcpy(&bits, &x, sizeof bits);
			s->check = fnv_u64(s->check, bits);
		}
		break;
	case SINK_SUM:
		if (!role) s->sum += x;
		break;
	default: break;
	}
}

// true, false and null.
static inline void sink_simple(sink *s, char tag, int role) { sink_node(s, tag, role); }

// The key lane's check. A first object with no key leaves the name empty, so no object answers.
static inline uint64_t sink_key_check(const sink *s) {
	return fnv_u64(fnv_u64(fnv_bytes(CHECK_OFFSET, s->name, s->name_len), s->answers), s->objects);
}
