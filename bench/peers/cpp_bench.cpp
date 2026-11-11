#include <iostream>
#include <fstream>
#include <vector>
#include <algorithm>
#include <string>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <type_traits>

#include <simdjson.h>

#include "bench_common.h"

// Timing jobs for doc.py. Each job makes WARMUP + TIMED calls on one input and prints the median as key=value
// tokens. Parsers and output buffers persist across calls; file I/O is outside the clock.
//   simd_dom               simdjson DOM
//   simd_dom_read          simdjson DOM, then a visit of every value (string lengths, numbers, bools, nulls)
//   simd_key               the first object's first key, then one at_key of it per object
//   simd_get KEY [BATCH]   On-Demand find_field of one root key, and the value's raw text. A sample is BATCH calls.
//   simd_minify            simdjson::minify of the text, which does not read the text's values
//   simd_doc_write         a parsed DOM element written by simdjson's string_builder, compact, into its reused buffer
//   simd_stream[_nothread] parse_many over an NDJSON text: every document judged and its tape built. The text is
//                          read in 1 MB batches (simdjson's default), and stage 1 of the next batch runs in a
//                          thread of its own unless `_nothread`
//   simd_stream_skip[_nothread]  iterate_many (On-Demand) over the same text, each document skipped: the structure
//                          is judged, string escapes and number syntax are not
// The stream jobs print the document count as `check` and whether stage 1 ran threaded as `threads`.
// The write lanes count the source's bytes. simdjson has no pretty writer, and its typed writer needs C++26 reflection.
using clk = std::chrono::steady_clock;
using simdjson::error_code;
using simdjson::SUCCESS;

#define TRY(x)                                                   \
    do {                                                         \
        if (error_code e_ = (x); e_ != SUCCESS) return e_;       \
    } while (0)

// The checksum every arm of a lane prints, so the runner can refuse a fixture whose arms disagree.
static const uint64_t CHECK_OFFSET = 14695981039346656037ULL;
static const uint64_t CHECK_PRIME = 1099511628211ULL;

static inline uint64_t fnv_byte(uint64_t h, uint8_t b) { return (h ^ b) * CHECK_PRIME; }

static uint64_t fnv_bytes(uint64_t h, const char* p, size_t n) {
    for (size_t i = 0; i < n; i++) h = fnv_byte(h, static_cast<uint8_t>(p[i]));
    return h;
}

static uint64_t fnv_u64(uint64_t h, uint64_t v) {
    for (int i = 0; i < 8; i++) h = fnv_byte(h, static_cast<uint8_t>(v >> (8 * i)));
    return h;
}

// Keeps `x` and what it points to from being optimized away.
template <class T>
static inline void keep(T& x) { asm volatile("" : : "r"(&x) : "memory"); }

static int64_t since(clk::time_point t0) {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(clk::now() - t0).count();
}

// What one simd_dom_read visit saw. `sum` keeps every string's length and every number's value in one
// accumulator so the visit cannot be optimized away, and `check` is the checksum the runner compares.
struct VisitCounts {
    double sum = 0;
    uint64_t check = 0;
};

// The binary64 bits of `x`, the value next's `core.Number` keeps for a float. Zero folds as +0, since sonic's reader
// keeps no sign on it.
static uint64_t double_bits(double x) {
    uint64_t b = 0;
    if (x != 0) std::memcpy(&b, &x, sizeof b);
    return b;
}

// Touches the first byte of a string of `n` bytes.
static void touch_first(std::string_view s) {
    if (!s.empty()) {
        unsigned char first = static_cast<unsigned char>(s[0]);
        keep(first);
    }
}

// Visits every value of a simdjson DOM. A string adds its length to the sum and touches its first byte, a number
// is read as its own type and added, bools and nulls are noted, and containers are walked in document order.
// Keys are not values, so the visit skips them and the key lane looks them up. `HASH` true is the untimed check,
// which also folds each value's tag, then its text length or its number bits.
template <bool HASH>
static error_code dom_visit(simdjson::dom::element v, VisitCounts& c) {
    switch (v.type()) {
    case simdjson::dom::element_type::STRING: {
        std::string_view s;
        TRY(v.get_string().get(s));
        if constexpr (HASH) {
            c.check = fnv_byte(c.check, 's');
            c.check = fnv_u64(c.check, static_cast<uint64_t>(s.size()));
        }
        c.sum += static_cast<double>(s.size());
        touch_first(s);
        break;
    }
    case simdjson::dom::element_type::INT64: {
        int64_t x;
        TRY(v.get_int64().get(x));
        if constexpr (HASH) {
            c.check = fnv_byte(c.check, 'n');
            c.check = fnv_u64(c.check, double_bits(static_cast<double>(x)));
        }
        c.sum += static_cast<double>(x);
        break;
    }
    case simdjson::dom::element_type::UINT64: {
        uint64_t x;
        TRY(v.get_uint64().get(x));
        if constexpr (HASH) {
            c.check = fnv_byte(c.check, 'n');
            c.check = fnv_u64(c.check, double_bits(static_cast<double>(x)));
        }
        c.sum += static_cast<double>(x);
        break;
    }
    case simdjson::dom::element_type::DOUBLE: {
        double x;
        TRY(v.get_double().get(x));
        if constexpr (HASH) {
            c.check = fnv_byte(c.check, 'n');
            c.check = fnv_u64(c.check, double_bits(x));
        }
        c.sum += x;
        break;
    }
    case simdjson::dom::element_type::ARRAY: {
        simdjson::dom::array a;
        if constexpr (HASH) c.check = fnv_byte(c.check, 'a');
        TRY(v.get_array().get(a));
        for (simdjson::dom::element e : a) TRY(dom_visit<HASH>(e, c));
        break;
    }
    case simdjson::dom::element_type::OBJECT: {
        simdjson::dom::object o;
        if constexpr (HASH) c.check = fnv_byte(c.check, 'o');
        TRY(v.get_object().get(o));
        for (auto kv : o) TRY(dom_visit<HASH>(kv.value, c));
        break;
    }
    case simdjson::dom::element_type::BOOL: {
        bool b;
        TRY(v.get_bool().get(b));
        if constexpr (HASH) c.check = fnv_byte(c.check, b ? 't' : 'f');
        break;
    }
    case simdjson::dom::element_type::NULL_VALUE:
        if constexpr (HASH) c.check = fnv_byte(c.check, 'z');
        break;
    case simdjson::dom::element_type::BIGINT: {
        // The document parsers keep an integer past 64 bits as text. It is one number value, and next reads it as
        // the binary64 it rounds to.
        std::string_view raw;
        TRY(v.get_bigint().get(raw));
        std::string text(raw);
        double x = std::strtod(text.c_str(), nullptr);
        if constexpr (HASH) {
            c.check = fnv_byte(c.check, 'n');
            c.check = fnv_u64(c.check, double_bits(x));
        }
        c.sum += x;
        break;
    }
    default:
        break;
    }
    return SUCCESS;
}

static int report(size_t len, int64_t ns, const std::string& extra) {
    if (ns < 0) return 1;
    printf("gb_per_s=%.4f ns=%lld %s\n", double(len) / double(ns), (long long)ns, extra.c_str());
    return 0;
}

// The build lane's check: the node count, then each node's kind tag and role in document order. A key is a node of
// role `.Key`, as next's document has it.
static error_code summary_count(simdjson::dom::element v, uint64_t& n) {
    n = 1;
    switch (v.type()) {
    case simdjson::dom::element_type::ARRAY: {
        simdjson::dom::array a;
        TRY(v.get_array().get(a));
        for (auto e : a) {
            uint64_t c;
            TRY(summary_count(e, c));
            n += c;
        }
        break;
    }
    case simdjson::dom::element_type::OBJECT: {
        simdjson::dom::object o;
        TRY(v.get_object().get(o));
        for (auto kv : o) {
            uint64_t c;
            TRY(summary_count(kv.value, c));
            n += 1 + c;
        }
        break;
    }
    default: break;
    }
    return SUCCESS;
}

static error_code summary_hash(simdjson::dom::element v, uint64_t& h) {
    switch (v.type()) {
    case simdjson::dom::element_type::ARRAY: {
        h = fnv_byte(h, 'a');
        h = fnv_byte(h, 0);
        simdjson::dom::array a;
        TRY(v.get_array().get(a));
        for (auto e : a) TRY(summary_hash(e, h));
        break;
    }
    case simdjson::dom::element_type::OBJECT: {
        h = fnv_byte(h, 'o');
        h = fnv_byte(h, 0);
        simdjson::dom::object o;
        TRY(v.get_object().get(o));
        for (auto kv : o) {
            h = fnv_byte(h, 's');
            h = fnv_byte(h, 1);
            TRY(summary_hash(kv.value, h));
        }
        break;
    }
    case simdjson::dom::element_type::STRING: h = fnv_byte(h, 's'); h = fnv_byte(h, 0); break;
    case simdjson::dom::element_type::INT64:
    case simdjson::dom::element_type::UINT64:
    case simdjson::dom::element_type::DOUBLE:
    case simdjson::dom::element_type::BIGINT: h = fnv_byte(h, 'n'); h = fnv_byte(h, 0); break;
    case simdjson::dom::element_type::BOOL: {
        bool b;
        TRY(v.get_bool().get(b));
        h = fnv_byte(h, b ? 't' : 'f');
        h = fnv_byte(h, 0);
        break;
    }
    case simdjson::dom::element_type::NULL_VALUE: h = fnv_byte(h, 'z'); h = fnv_byte(h, 0); break;
    default: break;
    }
    return SUCCESS;
}

static error_code build_summary(simdjson::dom::element root, uint64_t& chk) {
    uint64_t count;
    TRY(summary_count(root, count));
    chk = fnv_u64(CHECK_OFFSET, count);
    return summary_hash(root, chk);
}

// The first object in document order, as docprobe's `key` lane finds the document's first Map node. Its first
// member's key is the lane's key.
static error_code first_object(simdjson::dom::element v, std::string_view& key, bool& found) {
    if (found) return SUCCESS;
    switch (v.type()) {
    case simdjson::dom::element_type::ARRAY: {
        simdjson::dom::array a;
        TRY(v.get_array().get(a));
        for (auto e : a) {
            TRY(first_object(e, key, found));
            if (found) return SUCCESS;
        }
        break;
    }
    case simdjson::dom::element_type::OBJECT: {
        simdjson::dom::object o;
        TRY(v.get_object().get(o));
        auto it = o.begin();
        if (it != o.end()) {
            key = (*it).key;
            found = true;
        }
        break;
    }
    default: break;
    }
    return SUCCESS;
}

// The `key` lane's work: one at_key of `key` in every object, then every member's value.
static error_code key_walk(simdjson::dom::element v, std::string_view key, size_t& answers, size_t& objects) {
    switch (v.type()) {
    case simdjson::dom::element_type::ARRAY: {
        simdjson::dom::array a;
        TRY(v.get_array().get(a));
        for (auto e : a) TRY(key_walk(e, key, answers, objects));
        break;
    }
    case simdjson::dom::element_type::OBJECT: {
        simdjson::dom::object o;
        TRY(v.get_object().get(o));
        objects++;
        if (o.at_key(key).error() == SUCCESS) answers++;
        for (auto kv : o) TRY(key_walk(kv.value, key, answers, objects));
        break;
    }
    default: break;
    }
    return SUCCESS;
}

// Times a simdjson DOM parse plus the key lane: the first object's first key, then one at_key of it per
// object. The key is taken from the DOM the lane itself parsed.
static int simd_key_job(const simdjson::padded_string& in) {
    simdjson::dom::parser parser;
    parser.number_as_string(true);
    size_t answers = 0;
    size_t objects = 0;
    std::string key_copy;
    error_code err = SUCCESS;
    int64_t ns = median_ns([&]() -> int64_t {
        auto t0 = clk::now();
        simdjson::dom::element root;
        error_code e = parser.parse(in).get(root);
        size_t a = 0;
        size_t o = 0;
        if (!e) {
            std::string_view key;
            bool found = false;
            e = first_object(root, key, found);
            // No object, or an object with no members: the lane has no key to look up.
            if (!e && found) e = key_walk(root, key, a, o);
            if (!e && found && key_copy.empty()) key_copy.assign(key);
        }
        keep(a);
        keep(o);
        int64_t d = since(t0);
        if (e) {
            err = e;
            return -1;
        }
        answers = a;
        objects = o;
        return d;
    });
    if (ns < 0) {
        std::cerr << "simdjson key failed: " << err << std::endl;
        return 1;
    }
    uint64_t chk = fnv_bytes(CHECK_OFFSET, key_copy.data(), key_copy.size());
    chk = fnv_u64(fnv_u64(chk, answers), objects);
    return report(in.size(), ns, "check=" + std::to_string(chk) + " answers=" + std::to_string(answers) +
                                      " objects=" + std::to_string(objects) + " key=" + key_copy);
}

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
        auto t0 = clk::now();
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
                    keep(raw);
                }
                n++;
            }
        keep(n);
        int64_t d = since(t0);
        docs = n;
        return failed ? -1 : d;
    });
    if (failed) {
        std::cerr << "simdjson stream failed" << std::endl;
        return 1;
    }
    return report(in.size(), ns, "check=" + std::to_string(docs) + " threads=" + std::to_string(int(parser.threaded)));
}

static uint64_t fnv_all(const char* p, size_t n) { return fnv_bytes(CHECK_OFFSET, p, n); }

static int run_job(const std::string& buffer, const std::string& job) {
    simdjson::padded_string in(buffer);
    if (job == "simd_minify") {
        std::vector<char> out(in.size());
        size_t out_len = 0;
        int64_t ns = median_ns([&]() -> int64_t {
            auto t0 = clk::now();
            error_code e = simdjson::minify(in.data(), in.size(), out.data(), out_len);
            keep(out);
            int64_t d = since(t0);
            if (e) {
                std::cerr << "simdjson minify failed: " << e << std::endl;
                return -1;
            }
            return d;
        });
        return report(in.size(), ns, "out=" + std::to_string(out_len) + " check=" + std::to_string(fnv_all(out.data(), out_len)));
    }
    if (job == "simd_doc_write") {
        simdjson::dom::parser parser;
        // As simd_dom reads, so a number too big for 64 bits stays as text instead of failing the parse.
        parser.number_as_string(true);
        simdjson::dom::element root;
        if (error_code e = parser.parse(in).get(root)) {
            std::cerr << "simdjson dom parse failed: " << e << std::endl;
            return 1;
        }
        // The builder keeps its buffer across clear(), so every call writes into the same bytes.
        simdjson::internal::string_builder<> sb;
        int64_t ns = median_ns([&]() -> int64_t {
            auto t0 = clk::now();
            sb.clear();
            sb.append(root);
            std::string_view text = sb.str();
            keep(text);
            return since(t0);
        });
        std::string_view out = sb.str();
        return report(in.size(), ns, "out=" + std::to_string(out.size()) + " check=" + std::to_string(fnv_all(out.data(), out.size())));
    }
    if (job == "simd_dom") {
        simdjson::dom::parser parser;
        parser.number_as_string(true);
        int64_t ns = median_ns([&]() -> int64_t {
            auto t0 = clk::now();
            simdjson::dom::element root;
            error_code e = parser.parse(in).get(root);
            keep(root);
            int64_t d = since(t0);
            if (e) {
                std::cerr << "simdjson dom parse failed: " << e << std::endl;
                return -1;
            }
            return d;
        });
        if (ns < 0) return 1;
        // The check is work outside the clock, on a fresh parse.
        simdjson::dom::element root;
        uint64_t chk = 0;
        error_code e = parser.parse(in).get(root);
        if (!e) e = build_summary(root, chk);
        if (e) {
            std::cerr << "simdjson dom summary failed: " << e << std::endl;
            return 1;
        }
        return report(in.size(), ns, "check=" + std::to_string(chk));
    }
    if (job == "simd_dom_read") {
        simdjson::dom::parser parser;
        parser.number_as_string(true);
        VisitCounts counts;
        error_code err = SUCCESS;
        int64_t ns = median_ns([&]() -> int64_t {
            auto t0 = clk::now();
            simdjson::dom::element root;
            error_code e = parser.parse(in).get(root);
            VisitCounts c;
            if (!e) e = dom_visit<false>(root, c);
            keep(c);
            int64_t d = since(t0);
            if (e) {
                err = e;
                return -1;
            }
            return d;
        });
        if (ns < 0) {
            std::cerr << "simdjson dom_read failed: " << err << std::endl;
            return 1;
        }
        // The check is work outside the clock, on a fresh parse.
        simdjson::dom::element root;
        counts.check = CHECK_OFFSET;
        error_code e = parser.parse(in).get(root);
        if (!e) e = dom_visit<true>(root, counts);
        if (e) {
            std::cerr << "simdjson dom_read check failed: " << e << std::endl;
            return 1;
        }
        return report(in.size(), ns, "check=" + std::to_string(counts.check));
    }
    if (job == "simd_key") return simd_key_job(in);
    if (job == "simd_stream") return stream_job<simdjson::dom::parser>(in, true);
    if (job == "simd_stream_nothread") return stream_job<simdjson::dom::parser>(in, false);
    if (job == "simd_stream_skip") return stream_job<simdjson::ondemand::parser>(in, true);
    if (job == "simd_stream_skip_nothread") return stream_job<simdjson::ondemand::parser>(in, false);
    return 2;
}

// Times one On-Demand `find_field` of `key` in the root object, `batch` calls per sample. A value's raw text ends at its
// last byte, so the check folds the bytes every arm's span holds.
static int simd_get_job(const simdjson::padded_string& in, const std::string& key, int batch) {
    simdjson::ondemand::parser parser;
    std::string_view found;
    int64_t ns = median_ns([&] {
        auto t0 = clk::now();
        for (int k = 0; k < batch; k++) {
            std::string_view raw;
            simdjson::ondemand::document doc;
            if (!parser.iterate(in).get(doc)) {
                simdjson::ondemand::value v;
                if (!doc.find_field(key).get(v) && v.raw_json().get(raw)) raw = {};
            }
            keep(raw);
            found = raw;
        }
        return since(t0);
    });
    while (!found.empty() && (found.back() == ' ' || found.back() == '\n' || found.back() == '\t' || found.back() == '\r'))
        found.remove_suffix(1);
    return report(in.size(), ns / batch, "check=" + std::to_string(fnv_bytes(CHECK_OFFSET, found.data(), found.size())));
}

int main(int argc, char* argv[]) {
    if ((argc == 4 || argc == 5) && std::string(argv[2]) == "simd_get") {
        simdjson::padded_string in;
        if (simdjson::padded_string::load(argv[1]).get(in)) return 1;
        return simd_get_job(in, argv[3], argc == 5 ? atoi(argv[4]) : 1);
    }
    if (argc != 3) {
        std::cerr << "Usage: cpp_bench <fixture_path> <mode>" << std::endl;
        return 1;
    }

    std::string fixture_path = argv[1];
    std::string mode = argv[2];

    std::string buffer;
    try {
        buffer = slurp(fixture_path.c_str());
    } catch (const std::exception& e) {
        std::cerr << e.what() << std::endl;
        return 1;
    }

    int rc = run_job(buffer, mode);
    if (rc == 2) std::cerr << "bad arguments for " << mode << std::endl;
    return rc;
}
