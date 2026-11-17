// `paths-simdjson get FILE KEY [BATCH]`: On-Demand find_field of one root key and the value's raw text, BATCH calls to a
// sample. It reads to the key and skips values without judging their numbers and escapes.
#include <cstdlib>
#include <iostream>
#include <string>
#include <simdjson.h>

#include "timing.h"

// Times one On-Demand `find_field` of `key` in the root object, `batch` calls per sample. A value's raw text ends at its
// last byte, so the check folds the bytes every arm's span holds.
static int get_job(const simdjson::padded_string& in, const std::string& key, int batch) {
    simdjson::ondemand::parser parser;
    std::string_view found;
    int64_t ns = median_ns([&] {
        long long t0 = now_ns();
        for (int k = 0; k < batch; k++) {
            std::string_view raw;
            simdjson::ondemand::document doc;
            if (!parser.iterate(in).get(doc)) {
                simdjson::ondemand::value v;
                if (!doc.find_field(key).get(v) && v.raw_json().get(raw)) raw = {};
            }
            keep(&raw);
            found = raw;
        }
        return now_ns() - t0;
    });
    while (!found.empty() && (found.back() == ' ' || found.back() == '\n' || found.back() == '\t' || found.back() == '\r'))
        found.remove_suffix(1);
    report(in.size(), ns / batch, fnv_bytes(CHECK_OFFSET, found.data(), found.size()), "");
    return 0;
}


int main(int argc, char* argv[]) {
    simdjson::padded_string in;
    if (argc < 4 || argc > 5 || std::string(argv[1]) != "get" || simdjson::padded_string::load(argv[2]).get(in)) {
        std::cerr << "usage: paths-simdjson get FILE KEY [BATCH]" << std::endl;
        return 2;
    }
    return get_job(in, argv[3], argc == 5 ? atoi(argv[4]) : 1);
}
