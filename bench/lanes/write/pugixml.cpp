// `write-pugixml doc FILE`: pugixml's `save` of the tree of the text, parsed outside the clock, into a string reused across
// calls, without indentation. GB/s counts the source's bytes. The check is the read check of the text written, taken
// outside the clock by reading it back with pugixml, so a writer that keeps every value prints the check of its source.
#include <pugixml.hpp>
#include <string>

#include "../../xmlview/pugixml.h"

using namespace xmlview;

static const unsigned FLAGS = pugi::parse_default | pugi::parse_ws_pcdata_single;

struct StringWriter : pugi::xml_writer {
	std::string &out;
	explicit StringWriter(std::string &s) : out(s) {}
	void write(const void *data, size_t size) override { out.append(static_cast<const char *>(data), size); }
};

int main(int argc, char **argv) {
	if (argc != 3 || strcmp(argv[1], "doc")) {
		fprintf(stderr, "usage: write-pugixml doc FILE\n");
		return 2;
	}
	long n;
	char *buf = load(argv[2], &n);
	if (!buf) return 1;
	pugi::xml_document doc;
	if (!doc.load_buffer(buf, n, FLAGS)) {
		fprintf(stderr, "pugixml: parse failed\n");
		return 1;
	}
	std::string out;
	out.reserve(n * 2);
	StringWriter writer(out);
	long long ns[TIMED];
	for (int i = 0; i < WARMUP + TIMED; i++) {
		out.clear();
		long long t = now_ns();
		doc.save(writer, "", pugi::format_raw);
		keep(out.data());
		long long el = now_ns() - t;
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	pugi::xml_document back;
	if (!back.load_buffer(out.data(), out.size(), FLAGS)) {
		fprintf(stderr, "pugixml: the text written does not read back\n");
		return 1;
	}
	ReadCheck check;
	walk_document(back, check);
	report(n, median(ns), check.h, "out=%zu", out.size());
	return 0;
}
