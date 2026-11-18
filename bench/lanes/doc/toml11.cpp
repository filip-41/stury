// `doc-toml11 build|read|key FILE`: toml11's parse of the text into a `toml::basic_value`, then nothing, a visit of every value,
// or one lookup of the first key in every table. The type config keeps a table's members in text order, as the other
// arms' documents do, and drops comments. The parse takes its text as a byte vector, so each call copies the file's bytes
// inside the clock. Dates and times count as strings.
#include <cmath>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>
#include <toml.hpp>

#include "timing.h"

struct bench_config {
    using comment_type = toml::discard_comments;
    using boolean_type = bool;
    using integer_type = std::int64_t;
    using floating_type = double;
    using string_type = std::string;
    template <typename T>
    using array_type = std::vector<T>;
    template <typename K, typename T>
    using table_type = toml::ordered_map<K, T>;
    static toml::result<integer_type, toml::error_info> parse_int(const std::string& str, const toml::source_location src,
                                                                  const std::uint8_t base) {
        return toml::read_int<integer_type>(str, src, base);
    }
    static toml::result<floating_type, toml::error_info> parse_float(const std::string& str,
                                                                     const toml::source_location src, const bool is_hex) {
        return toml::read_float<floating_type>(str, src, is_hex);
    }
};

using Value = toml::basic_value<bench_config>;

static uint64_t bits_of(double x) {
    uint64_t b = 0;
    if (x != 0) std::memcpy(&b, &x, sizeof b);
    return b;
}

static Value parse(const char* data, long n) {
    std::vector<unsigned char> bytes(reinterpret_cast<const unsigned char*>(data),
                                     reinterpret_cast<const unsigned char*>(data) + n);
    return toml::parse<bench_config>(std::move(bytes), "doc");
}

static uint64_t count(const Value& v) {
    uint64_t c = 1;
    if (v.is_table()) {
        for (auto& kv : v.as_table()) c += 1 + count(kv.second);
    } else if (v.is_array()) {
        for (auto& e : v.as_array()) c += count(e);
    }
    return c;
}

static void hash_kinds(const Value& v, uint64_t& h) {
    if (v.is_table()) {
        h = fnv_byte(fnv_byte(h, 'o'), 0);
        for (auto& kv : v.as_table()) {
            h = fnv_byte(fnv_byte(h, 's'), 1);
            hash_kinds(kv.second, h);
        }
    } else if (v.is_array()) {
        h = fnv_byte(fnv_byte(h, 'a'), 0);
        for (auto& e : v.as_array()) hash_kinds(e, h);
    } else if (v.is_boolean()) {
        h = fnv_byte(fnv_byte(h, v.as_boolean() ? 't' : 'f'), 0);
    } else if (v.is_integer() || v.is_floating()) {
        h = fnv_byte(fnv_byte(h, 'n'), 0);
    } else {
        h = fnv_byte(fnv_byte(h, 's'), 0);
    }
}

static void hash_values(const Value& v, uint64_t& h) {
    if (v.is_table()) {
        h = fnv_byte(h, 'o');
        for (auto& kv : v.as_table()) hash_values(kv.second, h);
    } else if (v.is_array()) {
        h = fnv_byte(h, 'a');
        for (auto& e : v.as_array()) hash_values(e, h);
    } else if (v.is_boolean()) {
        h = fnv_byte(h, v.as_boolean() ? 't' : 'f');
    } else if (v.is_integer()) {
        h = fnv_u64(fnv_byte(h, 'n'), bits_of(static_cast<double>(v.as_integer())));
    } else if (v.is_floating()) {
        h = fnv_u64(fnv_byte(h, 'n'), bits_of(v.as_floating()));
    } else {
        h = fnv_u64(fnv_byte(h, 's'), v.is_string() ? v.as_string().size() : 0);
    }
}

static void visit(const Value& v, double& sum) {
    if (v.is_table()) {
        for (auto& kv : v.as_table()) visit(kv.second, sum);
    } else if (v.is_array()) {
        for (auto& e : v.as_array()) visit(e, sum);
    } else if (v.is_string()) {
        const std::string& s = v.as_string();
        sum += static_cast<double>(s.size());
        if (!s.empty()) keep(s.data());
    } else if (v.is_integer()) {
        sum += static_cast<double>(v.as_integer());
    } else if (v.is_floating()) {
        sum += v.as_floating();
    }
}

static void key_walk(const Value& v, const std::string& key, uint64_t& answers, uint64_t& objects) {
    if (v.is_table()) {
        objects++;
        const auto& t = v.as_table();
        if (t.find(key) != t.end()) answers++;
        for (auto& kv : t) key_walk(kv.second, key, answers, objects);
    } else if (v.is_array()) {
        for (auto& e : v.as_array()) key_walk(e, key, answers, objects);
    }
}

int main(int argc, char* argv[]) {
    if (argc != 3) {
        std::cerr << "usage: doc-toml11 build|read|key FILE" << std::endl;
        return 2;
    }
    long n = 0;
    char* data = load(argv[2], &n);
    if (!data) return 1;
    std::string lane = argv[1];
    if (lane != "build" && lane != "read" && lane != "key") {
        std::cerr << "no sublane " << lane << std::endl;
        return 2;
    }
    Value fresh;
    try {
        fresh = parse(data, n);
    } catch (const toml::syntax_error& e) {
        std::cerr << "toml11 parse failed: " << e.what() << std::endl;
        return 1;
    }
    uint64_t answers = 0, objects = 0;
    std::string key;
    if (fresh.is_table() && !fresh.as_table().empty()) key = fresh.as_table().begin()->first;
    int64_t ns = median_ns([&]() -> int64_t {
        long long t0 = now_ns();
        Value v = parse(data, n);
        if (lane == "read") {
            double sum = 0;
            visit(v, sum);
            keep(&sum);
        } else if (lane == "key") {
            uint64_t a = 0, o = 0;
            key_walk(v, key, a, o);
            keep(&a);
            keep(&o);
            answers = a;
            objects = o;
        }
        keep(&v);
        return now_ns() - t0;
    });
    if (lane == "build") {
        uint64_t h = fnv_u64(CHECK_OFFSET, count(fresh));
        hash_kinds(fresh, h);
        report(n, ns, h, "");
    } else if (lane == "read") {
        uint64_t h = CHECK_OFFSET;
        hash_values(fresh, h);
        report(n, ns, h, "");
    } else {
        uint64_t chk = fnv_u64(fnv_u64(fnv_bytes(CHECK_OFFSET, key.data(), key.size()), answers), objects);
        report(n, ns, chk, "answers=%llu objects=%llu key=%s", (unsigned long long)answers, (unsigned long long)objects,
               key.c_str());
    }
    return 0;
}
