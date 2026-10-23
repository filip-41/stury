#include <iostream>
#include <fstream>
#include <vector>
#include <algorithm>
#include <string>
#include <chrono>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <rapidjson/document.h>
#include <rapidjson/error/en.h>
#include <simdjson.h>

// Warm in-process timing jobs for bench/compare.py, mirroring stury's lanes: WARMUP + RUNS calls
// on one input, the median printed as key=value tokens. Parsers, allocators and output buffers are kept
// across calls; file I/O is outside the clock.
//   typed SHAPE [strict] [reuse]
//                          simdjson ondemand into the shapes of stury's bench_unmarshal.odin (logs,
//                          logs_subset, nested, config): every member visited, last duplicate kept, keys
//                          matched unescaped, every field required. `strict` also judges the members the
//                          shape skips; `reuse` keeps the output containers' capacity across reads.
//                          STURY_DUMP names a file for the decoded value as JSON.
//   validate               ondemand, every value read
//   simd_dom | rapid_dom_warm   simdjson DOM, RapidJSON DOM (UTF-8 validated, full-precision floats)
//   get KEY                ondemand find_field on one root member, its raw text taken; one sample is
//                          GET_BATCH calls and the time printed is per call
namespace od = simdjson::ondemand;
using clk = std::chrono::steady_clock;
using simdjson::error_code;
using simdjson::SUCCESS;

#define TRY(x)                                                   \
    do {                                                         \
        if (error_code e_ = (x); e_ != SUCCESS) return e_;       \
    } while (0)

static const int WARMUP = 2;
// Calls per get-one sample: an early key answers in a few timer ticks. The same count as the other get-one arms.
static const int GET_BATCH = 256;
// BENCH_RUNS overrides the timed iteration count.
static int RUNS = 10;
static bool g_judge_skipped = false;

// Exit 2 unless BENCH_RUNS, when set, is an integer >= 1.
static void read_runs() {
    const char* s = getenv("BENCH_RUNS");
    if (!s) return;
    char* end;
    long v = strtol(s, &end, 10);
    if (end == s || *end || v < 1 || v > INT_MAX) {
        std::cerr << "BENCH_RUNS must be an integer >= 1, got \"" << s << "\"" << std::endl;
        exit(2);
    }
    RUNS = int(v);
}

// Keeps `x` and what it points to from being optimized away.
template <class T>
static inline void keep(T& x) { asm volatile("" : : "r"(&x) : "memory"); }

static int64_t since(clk::time_point t0) {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(clk::now() - t0).count();
}

// The member's key, unescaped only when it holds a backslash, so an escaped spelling of a field name matches.
static error_code field_key(od::field& f, std::string_view& k) {
    k = f.escaped_key();
    if (k.find('\\') != std::string_view::npos) TRY(f.unescaped_key().get(k));
    return SUCCESS;
}

// Reads every value under `v`, which judges it in full.
static error_code judge(od::value v) {
    od::json_type t;
    TRY(v.type().get(t));
    switch (t) {
    case od::json_type::array: {
        od::array a;
        TRY(v.get_array().get(a));
        for (auto er : a) {
            od::value c;
            TRY(std::move(er).get(c));
            TRY(judge(c));
        }
        return SUCCESS;
    }
    case od::json_type::object: {
        od::object o;
        TRY(v.get_object().get(o));
        for (auto fr : o) {
            od::field f;
            std::string_view k;
            TRY(std::move(fr).get(f));
            TRY(f.unescaped_key().get(k));
            TRY(judge(f.value()));
        }
        return SUCCESS;
    }
    case od::json_type::number: {
        od::number n;
        return v.get_number().get(n);
    }
    case od::json_type::string: {
        std::string_view s;
        return v.get_string().get(s);
    }
    case od::json_type::boolean: {
        bool b;
        return v.get_bool().get(b);
    }
    case od::json_type::null: {
        bool n;
        TRY(v.is_null().get(n));
        return n ? SUCCESS : simdjson::N_ATOM_ERROR;
    }
    default:
        return simdjson::INCORRECT_TYPE;
    }
}

static error_code skip(od::value& v) { return g_judge_skipped ? judge(v) : SUCCESS; }

struct LogRecord {
    std::string_view ts, level, service, msg;
    int64_t status, bytes;
    double duration_ms;
    std::string_view id;
};
struct LogSubset {
    int64_t status;
    std::string_view id;
};
struct NestedB {
    int64_t c;
};
struct NestedInner {
    std::vector<double> a;
    NestedB b;
};
struct NestedRec {
    int64_t id;
    std::string_view name;
    std::vector<int64_t> tags;
    NestedInner nested;
    bool ok;
};
struct ConfigHead {
    std::string_view name;
    int64_t port;
};

static error_code read_record(od::object o, LogRecord& r) {
    unsigned seen = 0;
    for (auto mr : o) {
        od::field m;
        std::string_view k;
        TRY(std::move(mr).get(m));
        TRY(field_key(m, k));
        od::value& v = m.value();
        if (k == "ts") { TRY(v.get_string().get(r.ts)); seen |= 1; }
        else if (k == "level") { TRY(v.get_string().get(r.level)); seen |= 2; }
        else if (k == "service") { TRY(v.get_string().get(r.service)); seen |= 4; }
        else if (k == "msg") { TRY(v.get_string().get(r.msg)); seen |= 8; }
        else if (k == "status") { TRY(v.get_int64().get(r.status)); seen |= 16; }
        else if (k == "bytes") { TRY(v.get_int64().get(r.bytes)); seen |= 32; }
        else if (k == "duration_ms") { TRY(v.get_double().get(r.duration_ms)); seen |= 64; }
        else if (k == "id") { TRY(v.get_string().get(r.id)); seen |= 128; }
        else TRY(skip(v));
    }
    return seen == 0xFF ? SUCCESS : simdjson::NO_SUCH_FIELD;
}

static error_code read_record(od::object o, LogSubset& r) {
    unsigned seen = 0;
    for (auto mr : o) {
        od::field m;
        std::string_view k;
        TRY(std::move(mr).get(m));
        TRY(field_key(m, k));
        od::value& v = m.value();
        if (k == "status") { TRY(v.get_int64().get(r.status)); seen |= 1; }
        else if (k == "id") { TRY(v.get_string().get(r.id)); seen |= 2; }
        else TRY(skip(v));
    }
    return seen == 3 ? SUCCESS : simdjson::NO_SUCH_FIELD;
}

// The records of the root object's last `logs` member.
template <class Rec>
static error_code read_logs(od::document& doc, std::vector<Rec>& out) {
    od::object root;
    TRY(doc.get_object().get(root));
    bool found = false;
    for (auto fr : root) {
        od::field f;
        std::string_view k;
        TRY(std::move(fr).get(f));
        TRY(field_key(f, k));
        if (k != "logs") {
            TRY(skip(f.value()));
            continue;
        }
        found = true;
        out.clear();
        od::array arr;
        TRY(f.value().get_array().get(arr));
        for (auto er : arr) {
            od::object o;
            Rec r{};
            TRY(er.get_object().get(o));
            TRY(read_record(o, r));
            out.push_back(r);
        }
    }
    return found ? SUCCESS : simdjson::NO_SUCH_FIELD;
}

// No sizing pass: On-Demand learns an array's length only by reading it, so `out` grows as push_back grows it.
template <class T>
static error_code read_array(od::value v, std::vector<T>& out) {
    od::array a;
    TRY(v.get_array().get(a));
    for (auto er : a) {
        T x;
        TRY(std::move(er).get(x));
        out.push_back(x);
    }
    return SUCCESS;
}

static error_code read_inner(od::value v, NestedInner& n) {
    od::object o;
    TRY(v.get_object().get(o));
    unsigned seen = 0;
    for (auto mr : o) {
        od::field m;
        std::string_view k;
        TRY(std::move(mr).get(m));
        TRY(field_key(m, k));
        if (k == "a") {
            n.a.clear();
            TRY(read_array(m.value(), n.a));
            seen |= 1;
        } else if (k == "b") {
            od::object b;
            unsigned b_seen = 0;
            TRY(m.value().get_object().get(b));
            for (auto br : b) {
                od::field bf;
                std::string_view bk;
                TRY(std::move(br).get(bf));
                TRY(field_key(bf, bk));
                if (bk == "c") { TRY(bf.value().get_int64().get(n.b.c)); b_seen = 1; }
                else TRY(skip(bf.value()));
            }
            if (!b_seen) return simdjson::NO_SUCH_FIELD;
            seen |= 2;
        } else TRY(skip(m.value()));
    }
    return seen == 3 ? SUCCESS : simdjson::NO_SUCH_FIELD;
}

static error_code read_nested(od::document& doc, std::vector<NestedRec>& out) {
    od::array arr;
    TRY(doc.get_array().get(arr));
    size_t i = 0;
    for (auto er : arr) {
        od::object o;
        if (i == out.size()) out.emplace_back();
        NestedRec& r = out[i++];
        unsigned seen = 0;
        TRY(er.get_object().get(o));
        for (auto mr : o) {
            od::field m;
            std::string_view k;
            TRY(std::move(mr).get(m));
            TRY(field_key(m, k));
            od::value& v = m.value();
            if (k == "id") { TRY(v.get_int64().get(r.id)); seen |= 1; }
            else if (k == "name") { TRY(v.get_string().get(r.name)); seen |= 2; }
            else if (k == "tags") {
                r.tags.clear();
                TRY(read_array(v, r.tags));
                seen |= 4;
            } else if (k == "nested") { TRY(read_inner(v, r.nested)); seen |= 8; }
            else if (k == "ok") { TRY(v.get_bool().get(r.ok)); seen |= 16; }
            else TRY(skip(v));
        }
        if (seen != 31) return simdjson::NO_SUCH_FIELD;
    }
    out.resize(i);
    return SUCCESS;
}

static error_code read_config(od::document& doc, ConfigHead& c) {
    od::object root;
    TRY(doc.get_object().get(root));
    unsigned seen = 0;
    for (auto fr : root) {
        od::field f;
        std::string_view k;
        TRY(std::move(fr).get(f));
        TRY(field_key(f, k));
        if (k == "name") { TRY(f.value().get_string().get(c.name)); seen |= 1; }
        else if (k == "port") { TRY(f.value().get_int64().get(c.port)); seen |= 2; }
        else TRY(skip(f.value()));
    }
    return seen == 3 ? SUCCESS : simdjson::NO_SUCH_FIELD;
}

static error_code read_doc(od::document& doc, std::vector<LogRecord>& out) { return read_logs(doc, out); }
static error_code read_doc(od::document& doc, std::vector<LogSubset>& out) { return read_logs(doc, out); }
static error_code read_doc(od::document& doc, std::vector<NestedRec>& out) { return read_nested(doc, out); }
static error_code read_doc(od::document& doc, ConfigHead& out) { return read_config(doc, out); }

// The value as JSON, for the driver to compare with stury's: strings are escape-free in these fixtures but
// are escaped anyway, and floats print in enough digits to read back to the same binary64.
static void dump_str(std::string& o, std::string_view s) {
    o += '"';
    for (unsigned char ch : s) {
        if (ch == '"' || ch == '\\') {
            o += '\\';
            o += ch;
        } else if (ch < 0x20) {
            char b[8];
            snprintf(b, sizeof b, "\\u%04x", ch);
            o += b;
        } else o += ch;
    }
    o += '"';
}
static void dump_num(std::string& o, int64_t v) { o += std::to_string(v); }
static void dump_num(std::string& o, double v) {
    char b[32];
    snprintf(b, sizeof b, "%.17g", v);
    o += b;
}
static void dump(std::string& o, int64_t v);
static void dump(std::string& o, double v);
static void dump(std::string& o, const LogRecord& r);
static void dump(std::string& o, const LogSubset& r);
static void dump(std::string& o, const NestedRec& r);
template <class T>
static void dump_list(std::string& o, const std::vector<T>& xs) {
    o += '[';
    for (size_t i = 0; i < xs.size(); i++) {
        if (i) o += ',';
        dump(o, xs[i]);
    }
    o += ']';
}
static void dump(std::string& o, int64_t v) { dump_num(o, v); }
static void dump(std::string& o, double v) { dump_num(o, v); }
static void dump(std::string& o, const LogRecord& r) {
    o += "{\"ts\":";
    dump_str(o, r.ts);
    o += ",\"level\":";
    dump_str(o, r.level);
    o += ",\"service\":";
    dump_str(o, r.service);
    o += ",\"msg\":";
    dump_str(o, r.msg);
    o += ",\"status\":";
    dump_num(o, r.status);
    o += ",\"bytes\":";
    dump_num(o, r.bytes);
    o += ",\"duration_ms\":";
    dump_num(o, r.duration_ms);
    o += ",\"id\":";
    dump_str(o, r.id);
    o += '}';
}
static void dump(std::string& o, const LogSubset& r) {
    o += "{\"status\":";
    dump_num(o, r.status);
    o += ",\"id\":";
    dump_str(o, r.id);
    o += '}';
}
static void dump(std::string& o, const NestedRec& r) {
    o += "{\"id\":";
    dump_num(o, r.id);
    o += ",\"name\":";
    dump_str(o, r.name);
    o += ",\"tags\":";
    dump_list(o, r.tags);
    o += ",\"nested\":{\"a\":";
    dump_list(o, r.nested.a);
    o += ",\"b\":{\"c\":";
    dump_num(o, r.nested.b.c);
    o += "}},\"ok\":";
    o += r.ok ? "true" : "false";
    o += '}';
}
template <class Rec>
static void dump_logs_root(std::string& o, const std::vector<Rec>& v) {
    o += "{\"logs\":";
    dump_list(o, v);
    o += '}';
}
static void dump_root(std::string& o, const std::vector<LogRecord>& v) { dump_logs_root(o, v); }
static void dump_root(std::string& o, const std::vector<LogSubset>& v) { dump_logs_root(o, v); }
static void dump_root(std::string& o, const std::vector<NestedRec>& v) { dump_list(o, v); }
static void dump_root(std::string& o, const ConfigHead& c) {
    o += "{\"name\":";
    dump_str(o, c.name);
    o += ",\"port\":";
    dump_num(o, c.port);
    o += '}';
}
static size_t records(const ConfigHead&) { return 1; }
template <class T>
static size_t records(const std::vector<T>& v) { return v.size(); }

// Median nanoseconds of RUNS timed calls after WARMUP; `once` returns one call's nanoseconds, or -1.
template <class F>
static int64_t median_ns(F&& once) {
    std::vector<int64_t> times;
    for (int i = 0; i < WARMUP + RUNS; i++) {
        int64_t ns = once();
        if (ns < 0) return -1;
        if (i >= WARMUP) times.push_back(ns);
    }
    std::sort(times.begin(), times.end());
    // The mean of the two middle samples.
    return (times[(RUNS - 1) / 2] + times[RUNS / 2]) / 2;
}

static int report(size_t len, int64_t ns, const std::string& extra) {
    if (ns < 0) return 1;
    printf("gb_per_s=%.4f ns=%lld %s\n", double(len) / double(ns), (long long)ns, extra.c_str());
    return 0;
}

// With `reuse` the output containers keep their capacity across reads (the readers clear them), as a C++ user
// who keeps one result object would; stury's arena arm is the counterpart.
template <class Out>
static int typed_job(const simdjson::padded_string& in, bool reuse) {
    od::parser parser;
    Out out{};
    error_code err = SUCCESS;
    int64_t ns = median_ns([&]() -> int64_t {
        // Each read builds its records afresh, as a generic decoder's value is; the previous read's are freed
        // here, outside the clock. The parser keeps its buffers.
        if (!reuse) out = Out{};
        auto t0 = clk::now();
        od::document doc;
        err = parser.iterate(in).get(doc);
        if (!err) err = read_doc(doc, out);
        if (!err && !doc.at_end()) err = simdjson::TRAILING_CONTENT;
        keep(out);
        int64_t d = since(t0);
        return err ? -1 : d;
    });
    if (err) {
        std::cerr << "simdjson typed read failed: " << err << std::endl;
        return 1;
    }
    if (const char* path = getenv("STURY_DUMP")) {
        std::string o;
        dump_root(o, out);
        std::ofstream(path, std::ios::binary) << o;
    }
    return report(in.size(), ns, "records=" + std::to_string(records(out)));
}

// RapidJSON's DOM with one pool allocator and one Document kept across iterations. Clear() frees every chunk
// but a user-supplied buffer, so the pool is one buffer sized from an untimed first parse and the timed
// parses never call malloc; the parse stack stays with the Document.
static int rapid_dom_job(const std::string& text) {
    // The flags that give RapidJSON the guarantee the other arms have: UTF-8 validated (without it invalid
    // bytes pass) and numbers parsed to the correctly rounded double (without it the default is faster and
    // may be off by a few ulps).
    constexpr unsigned flags = rapidjson::kParseValidateEncodingFlag | rapidjson::kParseFullPrecisionFlag;
    size_t need;
    {
        rapidjson::Document sizing;
        sizing.Parse<flags>(text.data(), text.size());
        if (sizing.HasParseError()) {
            std::cerr << "rapidjson parse failed: " << rapidjson::GetParseError_En(sizing.GetParseError())
                      << " at offset " << sizing.GetErrorOffset() << std::endl;
            return 1;
        }
        need = sizing.GetAllocator().Capacity();
    }
    std::vector<char> pool(need + 4096);
    rapidjson::MemoryPoolAllocator<> alloc(pool.data(), pool.size());
    const size_t pool_capacity = alloc.Capacity();
    rapidjson::Document doc(&alloc);
    int64_t ns = median_ns([&]() -> int64_t {
        auto t0 = clk::now();
        doc.Parse<flags>(text.data(), text.size());
        keep(doc);
        int64_t d = since(t0);
        if (doc.HasParseError()) {
            std::cerr << "rapidjson parse failed: " << rapidjson::GetParseError_En(doc.GetParseError())
                      << " at offset " << doc.GetErrorOffset() << std::endl;
            return -1;
        }
        if (alloc.Capacity() != pool_capacity) {
            std::cerr << "rapidjson pool outgrew its buffer: a timed parse called malloc" << std::endl;
            return -1;
        }
        doc.SetNull();
        alloc.Clear();
        return d;
    });
    return report(text.size(), ns, "");
}

static int warm_job(const std::string& buffer, const std::string& job, int argc, char* argv[]) {
    simdjson::padded_string in(buffer);
    if (job == "typed") {
        if (argc < 4) return 2;
        std::string shape = argv[3];
        bool reuse = false;
        for (int i = 4; i < argc; i++) {
            std::string flag = argv[i];
            if (flag == "strict") g_judge_skipped = true;
            else if (flag == "reuse") reuse = true;
            else return 2;
        }
        if (shape == "logs") return typed_job<std::vector<LogRecord>>(in, reuse);
        if (shape == "logs_subset") return typed_job<std::vector<LogSubset>>(in, reuse);
        if (shape == "nested") return typed_job<std::vector<NestedRec>>(in, reuse);
        if (shape == "config") return typed_job<ConfigHead>(in, reuse);
        return 2;
    }
    if (job == "validate") {
        od::parser parser;
        return report(in.size(), median_ns([&]() -> int64_t {
            auto t0 = clk::now();
            od::document doc;
            od::value root;
            error_code e = parser.iterate(in).get(doc);
            if (!e) e = doc.get_value().get(root);
            if (!e) e = judge(root);
            if (!e && !doc.at_end()) e = simdjson::TRAILING_CONTENT;
            keep(doc);
            int64_t d = since(t0);
            if (e) {
                std::cerr << "simdjson validate failed: " << e << std::endl;
                return -1;
            }
            return d;
        }), "");
    }
    if (job == "simd_dom") {
        simdjson::dom::parser parser;
        return report(in.size(), median_ns([&]() -> int64_t {
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
        }), "");
    }
    if (job == "rapid_dom_warm") return rapid_dom_job(buffer);
    if (job == "get") {
        if (argc < 4) return 2;
        std::string_view key = argv[3];
        od::parser parser;
        size_t answer = 0;
        int64_t ns = median_ns([&]() -> int64_t {
            error_code e = SUCCESS;
            std::string_view raw;
            auto t0 = clk::now();
            for (int i = 0; i < GET_BATCH && !e; i++) {
                od::document doc;
                od::value v;
                e = parser.iterate(in).get(doc);
                if (!e) e = doc.find_field(key).get(v);
                if (e == simdjson::NO_SUCH_FIELD) {
                    raw = {};
                    e = SUCCESS;
                } else if (!e) {
                    e = v.raw_json().get(raw);
                }
                keep(raw);
            }
            int64_t d = since(t0);
            // raw_json() of a container runs to the next structural character, trailing whitespace included.
            while (!raw.empty() && strchr(" \t\r\n", raw.back())) raw.remove_suffix(1);
            answer = raw.size();
            if (e) {
                std::cerr << "simdjson get failed: " << e << std::endl;
                return -1;
            }
            return d;
        });
        if (ns < 0) return 1;
        double per_call = double(ns) / GET_BATCH;
        printf("gb_per_s=%.4f ns=%.1f answer_bytes=%zu\n", double(in.size()) / per_call, per_call, answer);
        return 0;
    }
    return 2;
}

int main(int argc, char* argv[]) {
    if (argc < 3) {
        std::cerr << "Usage: cpp_bench <fixture_path> <mode>" << std::endl;
        return 1;
    }

    read_runs();
    std::string fixture_path = argv[1];
    std::string mode = argv[2];

    std::ifstream file(fixture_path, std::ios::binary | std::ios::ate);
    if (!file) {
        std::cerr << "Could not open file: " << fixture_path << std::endl;
        return 1;
    }
    std::streamsize size = file.tellg();
    file.seekg(0, std::ios::beg);

    std::string buffer(size, '\0');
    if (!file.read(&buffer[0], size)) {
        std::cerr << "Could not read file: " << fixture_path << std::endl;
        return 1;
    }

    if (mode == "typed" || mode == "validate" || mode == "simd_dom" || mode == "rapid_dom_warm" || mode == "get") {
        int rc = warm_job(buffer, mode, argc, argv);
        if (rc == 2) std::cerr << "bad arguments for " << mode << std::endl;
        return rc;
    }
    std::cerr << "Unknown mode: " << mode << std::endl;
    return 1;
}
