// `records-rapidyaml build FILE`: rapidyaml's parse_in_arena of a YAML stream of `---` documents into one Tree whose root
// holds a document node per record, then the tree dropped. The check is the number of records.
#define RYML_SINGLE_HDR_DEFINE_NOW
#include <ryml_all.hpp>

#include "timing.h"

// The documents of a parsed stream: the children of its root, or the text's one document.
static uint64_t records_of(const ryml::Tree &t) {
	ryml::id_type root = t.root_id();
	return t.is_stream(root) ? (uint64_t)t.num_children(root) : 1;
}

int main(int argc, char **argv) {
	if (argc != 3 || strcmp(argv[1], "build")) {
		fprintf(stderr, "usage: records-rapidyaml build FILE\n");
		return 2;
	}
	long n;
	char *buf = load(argv[2], &n);
	if (!buf) return 1;
	long long ns[TIMED];
	uint64_t records = 0;
	for (int i = 0; i < WARMUP + TIMED; i++) {
		long long t0 = now_ns();
		ryml::Tree t = ryml::parse_in_arena(ryml::csubstr(buf, (size_t)n));
		records = records_of(t);
		keep(&t);
		long long el = now_ns() - t0;
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	report(n, median(ns), records, "");
	return 0;
}
