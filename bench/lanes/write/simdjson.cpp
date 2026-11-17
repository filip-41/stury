// `write-simdjson doc|minify FILE`: `doc` writes a parsed DOM element with simdjson's string_builder, compact, into its
// reused buffer, and `minify` is simdjson::minify of the source text, which reads no values. It has no pretty writer, and
// its typed writer needs C++26 reflection.
#include <iostream>
#include <string>
#include <vector>
#include <simdjson.h>

#include "timing.h"

using simdjson::error_code;

static int minify_job(const simdjson::padded_string& in) {
    std::vector<char> out(in.size());
    size_t out_len = 0;
    int64_t ns = median_ns([&]() -> int64_t {
        long long t0 = now_ns();
        error_code e = simdjson::minify(in.data(), in.size(), out.data(), out_len);
        keep(&out);
        int64_t d = now_ns() - t0;
        if (e) {
            std::cerr << "simdjson minify failed: " << e << std::endl;
            return -1;
        }
        return d;
    });
    if (ns < 0) return 1;
    report(in.size(), ns, fnv_bytes(CHECK_OFFSET, out.data(), out_len), "out=%zu", out_len);
    return 0;
}

static int doc_job(const simdjson::padded_string& in) {
    simdjson::dom::parser parser;
    // As the document lane reads, so a number too big for 64 bits stays as text instead of failing the parse.
    parser.number_as_string(true);
    simdjson::dom::element root;
    if (error_code e = parser.parse(in).get(root)) {
        std::cerr << "simdjson dom parse failed: " << e << std::endl;
        return 1;
    }
    // The builder keeps its buffer across clear(), so every call writes into the same bytes.
    simdjson::internal::string_builder<> sb;
    int64_t ns = median_ns([&]() -> int64_t {
        long long t0 = now_ns();
        sb.clear();
        sb.append(root);
        std::string_view text = sb.str();
        keep(&text);
        return now_ns() - t0;
    });
    std::string_view out = sb.str();
    report(in.size(), ns, fnv_bytes(CHECK_OFFSET, out.data(), out.size()), "out=%zu", out.size());
    return 0;
}

int main(int argc, char* argv[]) {
    simdjson::padded_string in;
    if (argc != 3 || simdjson::padded_string::load(argv[2]).get(in)) {
        std::cerr << "usage: write-simdjson doc|minify FILE" << std::endl;
        return 2;
    }
    std::string lane = argv[1];
    if (lane == "doc") return doc_job(in);
    if (lane == "minify") return minify_job(in);
    std::cerr << "no sublane " << lane << std::endl;
    return 2;
}
