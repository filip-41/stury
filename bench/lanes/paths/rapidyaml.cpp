// `paths-rapidyaml build_query|query FILE PATH [BATCH]`: rapidyaml's lookup of a path such as `.logs[0].id` in a YAML text,
// BATCH calls to a sample. rapidyaml reads every byte to build its tree, so `build_query` parses the text, looks the path
// up and drops the tree, and `query` looks the path up in a tree built outside the clock. A name is `find_child` and an
// index `child`, which walk the siblings. The check folds the answer's text and a newline, as the stury probe does.
#define RYML_SINGLE_HDR_DEFINE_NOW
#include <ryml_all.hpp>

#include <string>
#include <vector>

#include "timing.h"

struct Step {
	bool by_index;
	std::string name;
	size_t index;
};

// The steps of a path of `.name` and `[n]` segments.
static bool parse_path(const std::string &path, std::vector<Step> &steps) {
	size_t i = 0;
	while (i < path.size()) {
		if (path[i] == '.') {
			size_t j = ++i;
			while (j < path.size() && path[j] != '.' && path[j] != '[') j++;
			steps.push_back({false, path.substr(i, j - i), 0});
			i = j;
		} else if (path[i] == '[') {
			size_t j = path.find(']', i);
			if (j == std::string::npos) return false;
			steps.push_back({true, "", (size_t)strtoull(path.substr(i + 1, j - i - 1).c_str(), nullptr, 10)});
			i = j + 1;
		} else {
			return false;
		}
	}
	return !steps.empty();
}

// The node the path reaches, or NONE.
static ryml::id_type lookup(const ryml::Tree &t, const std::vector<Step> &steps) {
	ryml::id_type id = t.root_id();
	if (t.is_stream(id) && t.num_children(id) == 1) id = t.first_child(id);
	for (const Step &s : steps) {
		if (id == ryml::NONE) break;
		id = s.by_index ? t.child(id, (ryml::id_type)s.index) : t.find_child(id, ryml::csubstr(s.name.data(), s.name.size()));
	}
	return id;
}

int main(int argc, char **argv) {
	if (argc < 4 || (strcmp(argv[1], "build_query") && strcmp(argv[1], "query"))) {
		fprintf(stderr, "usage: paths-rapidyaml build_query|query FILE PATH [BATCH]\n");
		return 2;
	}
	bool prebuilt = !strcmp(argv[1], "query");
	int batch = argc > 4 ? atoi(argv[4]) : 1;
	long n;
	char *buf = load(argv[2], &n);
	std::vector<Step> steps;
	if (!buf || !parse_path(argv[3], steps)) {
		fprintf(stderr, "paths-rapidyaml: bad file or path\n");
		return 1;
	}
	ryml::Tree built;
	if (prebuilt) built = ryml::parse_in_arena(ryml::csubstr(buf, (size_t)n));
	// One call's answer, as the length of its text, read where the check needs it.
	auto call = [&](const ryml::Tree &t) {
		ryml::id_type id = lookup(t, steps);
		keep(&id);
		return id;
	};
	uint64_t check = CHECK_OFFSET;
	{
		ryml::Tree t = prebuilt ? ryml::Tree() : ryml::parse_in_arena(ryml::csubstr(buf, (size_t)n));
		const ryml::Tree &use = prebuilt ? built : t;
		ryml::id_type id = call(use);
		if (id != ryml::NONE && use.has_val(id)) {
			ryml::csubstr v = use.val(id);
			check = fnv_byte(fnv_bytes(check, v.str, v.len), '\n');
		}
	}
	long long ns[TIMED];
	for (int i = 0; i < WARMUP + TIMED; i++) {
		long long t0 = now_ns();
		for (int b = 0; b < batch; b++) {
			if (prebuilt) {
				call(built);
			} else {
				ryml::Tree t = ryml::parse_in_arena(ryml::csubstr(buf, (size_t)n));
				call(t);
			}
		}
		long long el = now_ns() - t0;
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	long long med = median(ns) / batch;
	report(n, med, check, "");
	return 0;
}
