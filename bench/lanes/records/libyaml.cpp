// `records-libyaml check|build FILE`: libyaml over a YAML stream of `---` documents. `check` parses it as events and
// counts the document starts, which judges every byte and builds nothing. `build` loads each document into a
// yaml_document_t with yaml_parser_load, until the stream ends, and deletes it. The check is the number of records.
#include <yaml.h>

#include "timing.h"

static bool count_events(const char *buf, long n, uint64_t *records) {
	yaml_parser_t p;
	if (!yaml_parser_initialize(&p)) return false;
	yaml_parser_set_input_string(&p, (const unsigned char *)buf, (size_t)n);
	yaml_event_t e;
	bool ok = true;
	for (bool done = false; !done;) {
		if (!yaml_parser_parse(&p, &e)) {
			ok = false;
			break;
		}
		if (e.type == YAML_DOCUMENT_START_EVENT) (*records)++;
		done = e.type == YAML_STREAM_END_EVENT;
		yaml_event_delete(&e);
	}
	yaml_parser_delete(&p);
	return ok;
}

static bool load_documents(const char *buf, long n, uint64_t *records) {
	yaml_parser_t p;
	if (!yaml_parser_initialize(&p)) return false;
	yaml_parser_set_input_string(&p, (const unsigned char *)buf, (size_t)n);
	bool ok = true;
	for (;;) {
		yaml_document_t d;
		if (!yaml_parser_load(&p, &d)) {
			ok = false;
			break;
		}
		bool end = yaml_document_get_root_node(&d) == nullptr;
		yaml_document_delete(&d);
		if (end) break;
		(*records)++;
	}
	yaml_parser_delete(&p);
	return ok;
}

int main(int argc, char **argv) {
	if (argc != 3 || (strcmp(argv[1], "check") && strcmp(argv[1], "build"))) {
		fprintf(stderr, "usage: records-libyaml check|build FILE\n");
		return 2;
	}
	bool build = !strcmp(argv[1], "build");
	long n;
	char *buf = load(argv[2], &n);
	if (!buf) return 1;
	long long ns[TIMED];
	uint64_t records = 0;
	for (int i = 0; i < WARMUP + TIMED; i++) {
		records = 0;
		long long t0 = now_ns();
		bool ok = build ? load_documents(buf, n, &records) : count_events(buf, n, &records);
		long long el = now_ns() - t0;
		if (!ok) {
			fprintf(stderr, "records-libyaml: parse failed\n");
			return 1;
		}
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	report(n, median(ns), records, "");
	return 0;
}
