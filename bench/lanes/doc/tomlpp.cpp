// `doc-tomlpp build|read|key FILE`: toml++'s parse of the text into a `toml::table`, then nothing, a visit of every value, or
// one `get` of the first key in every table. The first key is chosen outside the clock, since toml++ keeps its members
// in key order. The table is freed outside the clock.
#include <iostream>
#include <string>

#include "tomlpp.hpp"

int main(int argc, char* argv[]) {
    if (argc != 3) {
        std::cerr << "usage: doc-tomlpp build|read|key FILE" << std::endl;
        return 2;
    }
    long n = 0;
    char* data = load(argv[2], &n);
    if (!data) return 1;
    std::string in(data, n);
    free(data);
    std::string lane = argv[1];
    if (lane != "build" && lane != "read" && lane != "key") {
        std::cerr << "no sublane " << lane << std::endl;
        return 2;
    }
    toml::table fresh;
    try {
        fresh = toml::parse(std::string_view(in.data(), in.size()));
    } catch (const toml::parse_error& e) {
        std::cerr << "toml++ parse failed: " << e << std::endl;
        return 1;
    }
    uint64_t answers = 0, objects = 0;
    std::string key = tp::first_key(fresh);
    int64_t ns = median_ns([&]() -> int64_t {
        toml::table t;
        long long t0 = now_ns();
        t = toml::parse(std::string_view(in.data(), in.size()));
        if (lane == "read") {
            tp::Visit v;
            tp::visit(t, v);
            keep(&v);
        } else if (lane == "key") {
            uint64_t a = 0, o = 0;
            tp::key_walk(t, key, a, o);
            keep(&a);
            keep(&o);
            answers = a;
            objects = o;
        }
        keep(&t);
        return now_ns() - t0;
    });
    if (lane == "build") {
        report(in.size(), ns, tp::build_check(fresh), "");
    } else if (lane == "read") {
        bool ok;
        uint64_t chk = tp::read_check(fresh, fresh, ok);
        report(in.size(), ns, chk, "");
    } else {
        uint64_t chk = fnv_u64(fnv_u64(fnv_bytes(CHECK_OFFSET, key.data(), key.size()), answers), objects);
        report(in.size(), ns, chk, "answers=%llu objects=%llu key=%s", (unsigned long long)answers,
               (unsigned long long)objects, key.c_str());
    }
    return 0;
}
