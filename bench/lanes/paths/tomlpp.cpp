// `paths-tomlpp path FILE PATH [BATCH]`: toml++'s parse of the whole text, then `at_path` of one field, BATCH calls to a sample,
// each releasing its table inside the clock. PATH is a stury path of keys and indexes (`.logs[0].id`), which toml++ reads
// without the leading dot. The check folds the answer's text and a newline.
#include <cstdlib>
#include <iostream>
#include <string>

#include "../doc/tomlpp.hpp"

// The text of a scalar answer: a string's bytes, an integer's digits, true or false.
static std::string answer_text(const toml::node_view<toml::node>& v) {
    if (auto s = v.as_string()) return s->get();
    if (auto i = v.as_integer()) return std::to_string(i->get());
    if (auto b = v.as_boolean()) return b->get() ? "true" : "false";
    return "";
}

int main(int argc, char* argv[]) {
    if (argc < 4 || argc > 5 || std::string(argv[1]) != "path") {
        std::cerr << "usage: paths-tomlpp path FILE PATH [BATCH]" << std::endl;
        return 2;
    }
    long n = 0;
    char* data = load(argv[2], &n);
    if (!data) return 1;
    std::string in(data, n);
    free(data);
    std::string path = argv[3];
    if (!path.empty() && path[0] == '.') path.erase(0, 1);
    int batch = argc == 5 ? atoi(argv[4]) : 1;
    std::string found;
    bool failed = false;
    int64_t ns = median_ns([&]() -> int64_t {
        long long t0 = now_ns();
        for (int k = 0; k < batch; k++) {
            try {
                toml::table t = toml::parse(std::string_view(in.data(), in.size()));
                found = answer_text(t.at_path(path));
                keep(found.data());
            } catch (const toml::parse_error& e) {
                failed = true;
            }
        }
        return now_ns() - t0;
    });
    if (failed) {
        std::cerr << "toml++ parse failed" << std::endl;
        return 1;
    }
    uint64_t chk = fnv_byte(fnv_bytes(CHECK_OFFSET, found.data(), found.size()), '\n');
    report(in.size(), ns / batch, chk, "");
    return 0;
}
