// `doc-expat validate FILE`: expat's parse of the text with namespace processing and no handler, which judges well-formedness
// and builds nothing. Its check is 1 for a text it accepts.
#include <expat.h>

#include "timing.h"

int main(int argc, char **argv) {
	if (argc != 3 || strcmp(argv[1], "validate")) {
		fprintf(stderr, "usage: doc-expat validate FILE\n");
		return 2;
	}
	long n;
	char *buf = load(argv[2], &n);
	if (!buf) return 1;
	long long ns[TIMED];
	for (int i = 0; i < WARMUP + TIMED; i++) {
		XML_Parser p = XML_ParserCreateNS(nullptr, ' ');
		if (!p) return 1;
		long long t = now_ns();
		enum XML_Status st = XML_Parse(p, buf, (int)n, 1);
		long long el = now_ns() - t;
		if (st != XML_STATUS_OK) {
			fprintf(stderr, "expat: %s at line %lu\n", XML_ErrorString(XML_GetErrorCode(p)), (unsigned long)XML_GetCurrentLineNumber(p));
			return 1;
		}
		XML_ParserFree(p);
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	report(n, median(ns), 1, "");
	return 0;
}
