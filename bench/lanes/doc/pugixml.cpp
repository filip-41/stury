// `doc-pugixml build|read|key FILE`: pugixml's tree of the text, then nothing, a visit of every value, or one `child` lookup
// of the root's name in every object. pugixml checks the nesting of tags and no more, so this arm is not validating.
#include <pugixml.hpp>

#include "../../xmlview/pugixml.h"

using namespace xmlview;

static const unsigned FLAGS = pugi::parse_default | pugi::parse_ws_pcdata_single;

int main(int argc, char **argv) {
	if (argc != 3 || (strcmp(argv[1], "build") && strcmp(argv[1], "read") && strcmp(argv[1], "key"))) {
		fprintf(stderr, "usage: doc-pugixml build|read|key FILE\n");
		return 2;
	}
	bool read = !strcmp(argv[1], "read"), key = !strcmp(argv[1], "key");
	long n;
	char *buf = load(argv[2], &n);
	if (!buf) return 1;
	long long ns[TIMED];
	size_t answers = 0, objects = 0;
	pugi::xml_document *doc = nullptr;
	for (int i = 0; i < WARMUP + TIMED; i++) {
		delete doc;
		doc = new pugi::xml_document;
		size_t a = 0, o = 0;
		Sum sum;
		long long t = now_ns();
		pugi::xml_parse_result r = doc->load_buffer(buf, n, FLAGS);
		if (!r) {
			fprintf(stderr, "pugixml: %s at offset %lld\n", r.description(), (long long)r.offset);
			return 1;
		}
		keep(doc);
		if (read) walk_document(*doc, sum);
		if (key) {
			pugi::xml_node root = doc->document_element();
			o = 1;
			a = 1;
			key_walk(root, root.name(), a, o);
		}
		keep(&sum);
		keep(&a);
		long long el = now_ns() - t;
		answers = a;
		objects = o;
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	long long med = median(ns);
	if (key) {
		const char *name = doc->document_element().name();
		uint64_t check = fnv_u64(fnv_u64(fnv_bytes(CHECK_OFFSET, name, strlen(name)), answers), objects);
		report(n, med, check, "answers=%zu objects=%zu key=%s", answers, objects, name);
	} else if (read) {
		ReadCheck c;
		walk_document(*doc, c);
		report(n, med, c.h, "");
	} else {
		BuildCheck c;
		walk_document(*doc, c);
		report(n, med, c.hash(), "");
	}
	return 0;
}
