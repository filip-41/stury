// `doc-simdjson build|read|key FILE`: simdjson's DOM parse of the text, then nothing, a visit of every value, or one at_key
// of the first key in every object. Numbers stay text so that an integer past 64 bits parses.
#include <iostream>
#include <string>
#include <simdjson.h>

#include "timing.h"

using simdjson::error_code;
using simdjson::SUCCESS;

#define TRY(x)                                             \
    do {                                                   \
        if (error_code e_ = (x); e_ != SUCCESS) return e_; \
    } while (0)

// What one read visit saw. `sum` keeps every string's length and every number's value in one
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
        keep(&first);
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

// The key lane: the first object's first key, then one at_key of it per object, taken from the DOM the lane itself parsed.
static int key_job(const simdjson::padded_string& in) {
    simdjson::dom::parser parser;
    parser.number_as_string(true);
    size_t answers = 0;
    size_t objects = 0;
    std::string key_copy;
    error_code err = SUCCESS;
    int64_t ns = median_ns([&]() -> int64_t {
        long long t0 = now_ns();
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
        keep(&a);
        keep(&o);
        int64_t d = now_ns() - t0;
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
    report(in.size(), ns, chk, "answers=%zu objects=%zu key=%s", answers, objects, key_copy.c_str());
    return 0;
}


static int build_job(const simdjson::padded_string& in) {
    simdjson::dom::parser parser;
    parser.number_as_string(true);
    int64_t ns = median_ns([&]() -> int64_t {
        long long t0 = now_ns();
        simdjson::dom::element root;
        error_code e = parser.parse(in).get(root);
        keep(&root);
        int64_t d = now_ns() - t0;
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
    report(in.size(), ns, chk, "");
    return 0;
}

static int read_job(const simdjson::padded_string& in) {
    simdjson::dom::parser parser;
    parser.number_as_string(true);
    error_code err = SUCCESS;
    int64_t ns = median_ns([&]() -> int64_t {
        long long t0 = now_ns();
        simdjson::dom::element root;
        error_code e = parser.parse(in).get(root);
        VisitCounts c;
        if (!e) e = dom_visit<false>(root, c);
        keep(&c);
        int64_t d = now_ns() - t0;
        if (e) {
            err = e;
            return -1;
        }
        return d;
    });
    if (ns < 0) {
        std::cerr << "simdjson read failed: " << err << std::endl;
        return 1;
    }
    // The check is work outside the clock, on a fresh parse.
    simdjson::dom::element root;
    VisitCounts counts;
    counts.check = CHECK_OFFSET;
    error_code e = parser.parse(in).get(root);
    if (!e) e = dom_visit<true>(root, counts);
    if (e) {
        std::cerr << "simdjson read check failed: " << e << std::endl;
        return 1;
    }
    report(in.size(), ns, counts.check, "");
    return 0;
}

int main(int argc, char* argv[]) {
    simdjson::padded_string in;
    if (argc != 3 || simdjson::padded_string::load(argv[2]).get(in)) {
        std::cerr << "usage: doc-simdjson build|read|key FILE" << std::endl;
        return 2;
    }
    std::string lane = argv[1];
    if (lane == "build") return build_job(in);
    if (lane == "read") return read_job(in);
    if (lane == "key") return key_job(in);
    std::cerr << "no sublane " << lane << std::endl;
    return 2;
}
