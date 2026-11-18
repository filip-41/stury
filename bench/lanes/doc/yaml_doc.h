// What the YAML document drivers (`rapidyaml.cpp`, `libfyaml.cpp`, `libyaml.cpp`) share: the core schema's reading of a
// plain scalar, the sinks that fold what a walk of each library's tree passes, and `main`. A driver defines
//   struct Driver { using Doc = ...; static bool parse(const char *buf, long n, Doc &doc);
//                   template <class S> static void walk(Doc &doc, S &sink);
//                   static bool first_key(Doc &doc, std::string &key);
//                   static void key_walk(Doc &doc, const std::string &key, size_t &answers, size_t &objects); };
// and a walk calls `sink.object()`, `sink.array()`, `sink.key(text, n)` and `sink.scalar(text, n, plain)` in document
// order, a key before its value. `plain` is a scalar the text did not quote, which is the only one the schema resolves.
#pragma once
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>

#include "timing.h"

enum Kind : char { K_STRING = 's', K_NUMBER = 'n', K_TRUE = 't', K_FALSE = 'f', K_NULL = 'z' };

static inline bool is_digit(char c) { return c >= '0' && c <= '9'; }

// Whether a text is one of the core schema's decimal forms: an integer, or a float with a fraction, an exponent or both.
static inline bool decimal_form(const char *p, size_t n) {
	size_t i = 0;
	if (i < n && (p[i] == '+' || p[i] == '-')) i++;
	size_t digits = 0;
	while (i < n && is_digit(p[i])) i++, digits++;
	if (i < n && p[i] == '.') {
		i++;
		while (i < n && is_digit(p[i])) i++, digits++;
	}
	if (!digits) return false;
	if (i < n && (p[i] == 'e' || p[i] == 'E')) {
		i++;
		if (i < n && (p[i] == '+' || p[i] == '-')) i++;
		size_t exp = 0;
		while (i < n && is_digit(p[i])) i++, exp++;
		if (!exp) return false;
	}
	return i == n;
}

static inline bool all_digits(const char *p, size_t n, int base) {
	for (size_t i = 0; i < n; i++) {
		char c = p[i];
		int d = is_digit(c) ? c - '0' : (c >= 'a' && c <= 'f') ? c - 'a' + 10 : (c >= 'A' && c <= 'F') ? c - 'A' + 10 : 99;
		if (d >= base) return false;
	}
	return n > 0;
}

// The kind a plain scalar has under the YAML 1.2 core schema and, for a number, its binary64 value.
static inline Kind resolve(const char *p, size_t n, double *value) {
	if (n == 0) return K_NULL;
	char c = p[0];
	if (c == '~') return n == 1 ? K_NULL : K_STRING;
	if (is_digit(c) || c == '+' || c == '-' || c == '.') {
		if (n > 2 && c == '0' && (p[1] == 'x' || p[1] == 'o')) {
			int base = p[1] == 'x' ? 16 : 8;
			if (!all_digits(p + 2, n - 2, base)) return K_STRING;
			*value = (double)strtoull(std::string(p + 2, n - 2).c_str(), nullptr, base);
			return K_NUMBER;
		}
		std::string s(p, n);
		const char *w = s.c_str() + (c == '+' || c == '-');
		if (!strcmp(w, ".inf") || !strcmp(w, ".Inf") || !strcmp(w, ".INF")) {
			*value = c == '-' ? -INFINITY : INFINITY;
			return K_NUMBER;
		}
		if (c == '.' && (!strcmp(w, ".nan") || !strcmp(w, ".NaN") || !strcmp(w, ".NAN"))) {
			*value = NAN;
			return K_NUMBER;
		}
		if (!decimal_form(p, n)) return K_STRING;
		*value = strtod(s.c_str(), nullptr);
		// A decimal past binary64's range has no value there, and the check folds it as 0.
		if (std::isinf(*value)) *value = 0;
		return K_NUMBER;
	}
	if (n == 4 && (!memcmp(p, "null", 4) || !memcmp(p, "Null", 4) || !memcmp(p, "NULL", 4))) return K_NULL;
	if (n == 4 && (!memcmp(p, "true", 4) || !memcmp(p, "True", 4) || !memcmp(p, "TRUE", 4))) return K_TRUE;
	if (n == 5 && (!memcmp(p, "false", 5) || !memcmp(p, "False", 5) || !memcmp(p, "FALSE", 5))) return K_FALSE;
	return K_STRING;
}

static inline uint64_t number_bits(double d) {
	uint64_t bits = 0;
	if (d != 0) memcpy(&bits, &d, sizeof bits);
	return bits;
}

// The build lane's node count: one per value and one per key.
struct CountSink {
	uint64_t n = 0;
	void object() { n++; }
	void array() { n++; }
	void key(const char *, size_t) { n++; }
	void scalar(const char *, size_t, bool) { n++; }
};

// The build lane's hash after the count: each node's kind tag and its role.
struct BuildHashSink {
	uint64_t h;
	void object() { h = fnv_byte(fnv_byte(h, 'o'), 0); }
	void array() { h = fnv_byte(fnv_byte(h, 'a'), 0); }
	void key(const char *, size_t) { h = fnv_byte(fnv_byte(h, 's'), 1); }
	void scalar(const char *p, size_t n, bool plain) {
		double d;
		Kind k = plain ? resolve(p, n, &d) : K_STRING;
		h = fnv_byte(fnv_byte(h, k), 0);
	}
};

// The read lane's check: each value's tag, then a string's decoded byte count or a number's binary64 bits.
struct ReadHashSink {
	uint64_t h = CHECK_OFFSET;
	void object() { h = fnv_byte(h, 'o'); }
	void array() { h = fnv_byte(h, 'a'); }
	void key(const char *, size_t) {}
	void scalar(const char *p, size_t n, bool plain) {
		double d = 0;
		Kind k = plain ? resolve(p, n, &d) : K_STRING;
		h = fnv_byte(h, k);
		if (k == K_STRING) h = fnv_u64(h, n);
		if (k == K_NUMBER) h = fnv_u64(h, number_bits(d));
	}
};

// The timed read: what the check folds, as a sum the compiler cannot drop.
struct ReadSink {
	double sum = 0;
	void object() {}
	void array() {}
	void key(const char *, size_t) {}
	void scalar(const char *p, size_t n, bool plain) {
		double d = 0;
		Kind k = plain ? resolve(p, n, &d) : K_STRING;
		if (k == K_STRING) {
			sum += (double)n;
			if (n) {
				unsigned char first = (unsigned char)p[0];
				keep(&first);
			}
		} else if (k == K_NUMBER) {
			sum += d;
		}
	}
};

template <class D>
static int doc_main(int argc, char **argv, const char *name) {
	if (argc != 3 || (strcmp(argv[1], "build") && strcmp(argv[1], "read") && strcmp(argv[1], "key"))) {
		fprintf(stderr, "usage: %s build|read|key FILE\n", name);
		return 2;
	}
	bool read = !strcmp(argv[1], "read"), key = !strcmp(argv[1], "key");
	long n;
	char *buf = load(argv[2], &n);
	if (!buf) return 1;
	long long ns[TIMED];
	size_t answers = 0, objects = 0;
	std::string shown;
	typename D::Doc doc;
	for (int i = 0; i < WARMUP + TIMED; i++) {
		doc = typename D::Doc();
		ReadSink c;
		size_t a = 0, o = 0;
		long long t = now_ns();
		if (!D::parse(buf, n, doc)) {
			fprintf(stderr, "%s: parse failed\n", name);
			return 1;
		}
		keep(&doc);
		if (read) D::walk(doc, c);
		if (key) {
			std::string k;
			if (D::first_key(doc, k)) {
				D::key_walk(doc, k, a, o);
				shown = k;
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
		check = fnv_u64(fnv_u64(fnv_bytes(CHECK_OFFSET, shown.data(), shown.size()), answers), objects);
		report(n, med, check, "answers=%zu objects=%zu key=%s", answers, objects, shown.c_str());
	} else if (read) {
		ReadHashSink h;
		D::walk(doc, h);
		report(n, med, h.h, "");
	} else {
		CountSink count;
		D::walk(doc, count);
		BuildHashSink h{fnv_u64(CHECK_OFFSET, count.n)};
		D::walk(doc, h);
		report(n, med, h.h, "");
	}
	return 0;
}
