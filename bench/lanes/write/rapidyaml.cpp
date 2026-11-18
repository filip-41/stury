// `write-rapidyaml typed|doc FILE`: rapidyaml's emit_yaml into one buffer sized once and reused. `doc` emits the Tree the
// fixture parses to, and its GB/s counts the source's bytes. `typed` builds a Tree from C++ structs of the fixture's logs
// records and emits it, since rapidyaml writes no struct without a tree. The build is inside the clock, with each string
// borrowed and each number written into the tree's arena, and the freeing of each call's tree is outside it. Its GB/s
// counts the output's bytes. Reading the fixture is outside the clock. The check is the read check of the text written,
// read back as YAML outside the clock, since a writer spells a value its own way.
#define RYML_SINGLE_HDR_DEFINE_NOW
#include "rapidyaml_doc.h"

#include <vector>

struct Rec {
	std::string ts, level, service, msg, id;
	long long status, bytes;
	double duration_ms;
};

static std::string text_of(const ryml::Tree &t, ryml::id_type rec, const char *key) {
	ryml::csubstr v = t.val(t.find_child(rec, ryml::to_csubstr(key)));
	return std::string(v.str, v.len);
}

// The logs records of the fixture.
static std::vector<Rec> records(const ryml::Tree &t) {
	std::vector<Rec> out;
	ryml::id_type logs = t.find_child(t.root_id(), "logs");
	for (ryml::id_type r = t.first_child(logs); r != ryml::NONE; r = t.next_sibling(r))
		out.push_back({text_of(t, r, "ts"), text_of(t, r, "level"), text_of(t, r, "service"), text_of(t, r, "msg"),
		               text_of(t, r, "id"), atoll(text_of(t, r, "status").c_str()), atoll(text_of(t, r, "bytes").c_str()),
		               strtod(text_of(t, r, "duration_ms").c_str(), nullptr)});
	return out;
}

static ryml::Tree build_tree(const std::vector<Rec> &recs) {
	ryml::Tree t((ryml::id_type)(recs.size() * 9 + 3), 64 * recs.size());
	ryml::NodeRef root = t.rootref();
	root |= ryml::MAP;
	ryml::NodeRef logs = root["logs"];
	logs |= ryml::SEQ;
	for (const Rec &r : recs) {
		ryml::NodeRef n = logs.append_child();
		n |= ryml::MAP;
		n["ts"] = ryml::csubstr(r.ts.data(), r.ts.size());
		n["level"] = ryml::csubstr(r.level.data(), r.level.size());
		n["service"] = ryml::csubstr(r.service.data(), r.service.size());
		n["msg"] = ryml::csubstr(r.msg.data(), r.msg.size());
		n["status"] << r.status;
		n["bytes"] << r.bytes;
		n["duration_ms"] << r.duration_ms;
		n["id"] = ryml::csubstr(r.id.data(), r.id.size());
	}
	return t;
}

static uint64_t read_check(const char *text, size_t n) {
	Rapidyaml::Doc t;
	Rapidyaml::parse(text, (long)n, t);
	ReadHashSink h;
	Rapidyaml::walk(t, h);
	return h.h;
}

int main(int argc, char **argv) {
	if (argc != 3 || (strcmp(argv[1], "typed") && strcmp(argv[1], "doc"))) {
		fprintf(stderr, "usage: write-rapidyaml typed|doc FILE\n");
		return 2;
	}
	bool typed = !strcmp(argv[1], "typed");
	long n;
	char *buf = load(argv[2], &n);
	if (!buf) return 1;
	ryml::Tree parsed = ryml::parse_in_arena(ryml::csubstr(buf, (size_t)n));
	std::vector<Rec> recs = records(parsed);
	std::vector<char> out((size_t)n * 3);
	size_t written = 0;
	long long ns[TIMED];
	for (int i = 0; i < WARMUP + TIMED; i++) {
		long long t0 = now_ns();
		if (typed) {
			ryml::Tree t = build_tree(recs);
			written = ryml::emit_yaml(t, ryml::substr(out.data(), out.size())).len;
			keep(out.data());
			long long el = now_ns() - t0;
			if (i >= WARMUP) ns[i - WARMUP] = el;
		} else {
			written = ryml::emit_yaml(parsed, ryml::substr(out.data(), out.size())).len;
			keep(out.data());
			long long el = now_ns() - t0;
			if (i >= WARMUP) ns[i - WARMUP] = el;
		}
	}
	long long med = median(ns);
	report(typed ? written : (size_t)n, med, read_check(out.data(), written), "out=%zu", written);
	return 0;
}
