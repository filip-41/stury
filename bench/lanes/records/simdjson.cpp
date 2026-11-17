// `records-simdjson stream|stream_nothread|skip|skip_nothread FILE`: simdjson over an NDJSON text read in 1 MB batches
// (its default), each document counted. `stream` is parse_many, every document judged and a tape built, and `skip` is
// On-Demand iterate_many with each document skipped: the structure is judged, string escapes and number syntax are
// not. Stage 1 of the next batch runs in a thread of its own unless the sublane ends in `_nothread`. `check` is the
// document count.
#include <iostream>
#include <string>
#include <type_traits>
#include <simdjson.h>

#include "timing.h"

using simdjson::error_code;
using simdjson::SUCCESS;

// Times a document_stream over `in` and counts its documents, which the runner compares across arms. `Parser` is
// simdjson::dom::parser (parse_many, a tape per document) or simdjson::ondemand::parser (iterate_many, each document
// skipped). A document that fails to parse or skip ends the job.
template <class Parser>
static int stream_job(const simdjson::padded_string& in, bool threaded) {
    constexpr bool DOM = std::is_same_v<Parser, simdjson::dom::parser>;
    Parser parser;
    parser.threaded = threaded && parser.threaded;
    uint64_t docs = 0;
    bool failed = false;
    int64_t ns = median_ns([&]() -> int64_t {
        long long t0 = now_ns();
        uint64_t n = 0;
        std::conditional_t<DOM, simdjson::dom::document_stream, simdjson::ondemand::document_stream> stream;
        error_code opened = SUCCESS;
        if constexpr (DOM) opened = parser.parse_many(in).get(stream);
        else opened = parser.iterate_many(in).get(stream);
        if (opened) failed = true;
        else
            for (auto doc : stream) {
                if constexpr (DOM) {
                    if (doc.error()) { failed = true; break; }
                } else {
                    simdjson::ondemand::document_reference d;
                    std::string_view raw;
                    if (doc.get(d) || d.raw_json().get(raw)) { failed = true; break; }
                    keep(&raw);
                }
                n++;
            }
        keep(&n);
        int64_t d = now_ns() - t0;
        docs = n;
        return failed ? -1 : d;
    });
    if (failed) {
        std::cerr << "simdjson stream failed" << std::endl;
        return 1;
    }
    report(in.size(), ns, docs, "threads=%d", int(parser.threaded));
    return 0;
}


int main(int argc, char* argv[]) {
    simdjson::padded_string in;
    if (argc != 3 || simdjson::padded_string::load(argv[2]).get(in)) {
        std::cerr << "usage: records-simdjson stream|stream_nothread|skip|skip_nothread FILE" << std::endl;
        return 2;
    }
    std::string lane = argv[1];
    if (lane == "stream") return stream_job<simdjson::dom::parser>(in, true);
    if (lane == "stream_nothread") return stream_job<simdjson::dom::parser>(in, false);
    if (lane == "skip") return stream_job<simdjson::ondemand::parser>(in, true);
    if (lane == "skip_nothread") return stream_job<simdjson::ondemand::parser>(in, false);
    std::cerr << "no sublane " << lane << std::endl;
    return 2;
}
