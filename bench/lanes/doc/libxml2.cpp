// `doc-libxml2 build|read|key|validate FILE`: libxml2's tree of the text, then nothing, a visit of every value, or one name lookup of
// the root's name in every object. A text with a namespace error is refused, since libxml2 reads it as a recoverable one.
#include <libxml/parser.h>

#include "../../xmlview/libxml2.h"

using namespace xmlview;

static void ignore_error(void *, const xmlError *) {}

// The text parsed by the SAX2 reader with no handler, which judges well-formedness and builds nothing. Its check is 1.
static int validate(const char *path) {
	long n;
	char *buf = load(path, &n);
	if (!buf) return 1;
	xmlSAXHandler handler = {};
	handler.initialized = XML_SAX2_MAGIC;
	long long ns[TIMED];
	for (int i = 0; i < WARMUP + TIMED; i++) {
		long long t = now_ns();
		int status = xmlSAXUserParseMemory(&handler, nullptr, buf, (int)n);
		long long el = now_ns() - t;
		if (status != 0) {
			fprintf(stderr, "libxml2: parse failed\n");
			return 1;
		}
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	report(n, median(ns), 1, "");
	return 0;
}

int main(int argc, char **argv) {
	if (argc == 3 && !strcmp(argv[1], "validate")) return validate(argv[2]);
	if (argc != 3 || (strcmp(argv[1], "build") && strcmp(argv[1], "read") && strcmp(argv[1], "key"))) {
		fprintf(stderr, "usage: doc-libxml2 build|read|key FILE\n");
		return 2;
	}
	bool read = !strcmp(argv[1], "read"), key = !strcmp(argv[1], "key");
	long n;
	char *buf = load(argv[2], &n);
	xmlParserCtxt *ctxt = xmlNewParserCtxt();
	if (!buf || !ctxt) return 1;
	xmlCtxtSetErrorHandler(ctxt, ignore_error, nullptr);
	long long ns[TIMED];
	size_t answers = 0, objects = 0;
	xmlDoc *doc = nullptr;
	for (int i = 0; i < WARMUP + TIMED; i++) {
		if (doc) xmlFreeDoc(doc);
		size_t a = 0, o = 0;
		Sum sum;
		long long t = now_ns();
		doc = xmlCtxtReadMemory(ctxt, buf, (int)n, nullptr, nullptr, XML_PARSE_NONET | XML_PARSE_HUGE);
		if (!doc || !ctxt->wellFormed || !ctxt->nsWellFormed) {
			fprintf(stderr, "libxml2: read failed\n");
			return 1;
		}
		keep(doc);
		if (read) walk_document(doc, sum);
		if (key) {
			const xmlNode *root = xmlDocGetRootElement(doc);
			o = 1;
			a = 1;
			key_walk(root, root->name, a, o);
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
		const char *name = (const char *)xmlDocGetRootElement(doc)->name;
		uint64_t check = fnv_u64(fnv_u64(fnv_bytes(CHECK_OFFSET, name, strlen(name)), answers), objects);
		report(n, med, check, "answers=%zu objects=%zu key=%s", answers, objects, name);
	} else if (read) {
		ReadCheck c;
		walk_document(doc, c);
		report(n, med, c.h, "");
	} else {
		BuildCheck c;
		walk_document(doc, c);
		report(n, med, c.hash(), "");
	}
	return 0;
}
