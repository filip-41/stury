// `paths-pugixml get|query FILE PATH first|last`: pugixml's tree of the text and one XPath query over it (`get`), or the
// query alone on a tree built outside the clock (`query`). PATH names elements from the root, as `.logs.log.id`. The answer
// is the first or the last element it matches in document order, and the check is the FNV-1a of its text then a newline.
// pugixml checks the nesting of tags and no more, so this arm is not validating.
#include <pugixml.hpp>
#include <string>

#include "timing.h"

static const unsigned FLAGS = pugi::parse_default | pugi::parse_ws_pcdata_single;

// `.a.b.c` as the XPath `/a/b/c`, wrapped in `(...)[last()]` for the last answer.
static std::string xpath_of(const char *path, bool last) {
	std::string x;
	for (const char *p = path; *p; p++) x += *p == '.' ? '/' : *p;
	return last ? "(" + x + ")[last()]" : x;
}

static bool answer(const pugi::xpath_query &q, const pugi::xml_document &doc, std::string &text) {
	pugi::xpath_node hit = q.evaluate_node(doc);
	if (!hit) return false;
	text = hit.node().child_value();
	return true;
}

int main(int argc, char **argv) {
	if (argc != 5 || (strcmp(argv[1], "get") && strcmp(argv[1], "query"))) {
		fprintf(stderr, "usage: paths-pugixml get|query FILE PATH first|last\n");
		return 2;
	}
	bool get = !strcmp(argv[1], "get");
	long n;
	char *buf = load(argv[2], &n);
	if (!buf) return 1;
	pugi::xpath_query q(xpath_of(argv[3], !strcmp(argv[4], "last")).c_str());
	if (!q) {
		fprintf(stderr, "pugixml: bad xpath\n");
		return 1;
	}
	pugi::xml_document built;
	if (!get && !built.load_buffer(buf, n, FLAGS)) return 1;
	long long ns[TIMED];
	std::string text;
	pugi::xml_document *doc = nullptr;
	for (int i = 0; i < WARMUP + TIMED; i++) {
		long long t;
		bool found;
		if (get) {
			delete doc;
			doc = new pugi::xml_document;
			t = now_ns();
			if (!doc->load_buffer(buf, n, FLAGS)) {
				fprintf(stderr, "pugixml: parse failed\n");
				return 1;
			}
			found = answer(q, *doc, text);
		} else {
			t = now_ns();
			found = answer(q, built, text);
		}
		keep(text.data());
		long long el = now_ns() - t;
		if (!found) {
			fprintf(stderr, "pugixml: no answer\n");
			return 1;
		}
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	uint64_t check = fnv_byte(fnv_bytes(CHECK_OFFSET, text.data(), text.size()), '\n');
	report(n, median(ns), check, "");
	return 0;
}
