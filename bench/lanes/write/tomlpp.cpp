// `write-tomlpp doc FILE`: toml++'s `toml_formatter` writing a parsed `toml::table` as text into a string that keeps its
// capacity across calls. Parsing the file is outside the clock, and GB/s counts the source's bytes. toml++ writes a table's
// members in key order, so the check reads the output back and folds it in the text order of the table it was made from,
// as the other arms' checks fold the text they wrote read back as TOML.
#include <iostream>
#include <streambuf>
#include <string>

#include "../doc/tomlpp.hpp"

// A stream buffer that appends to a string.
struct StringSink : std::streambuf {
    std::string& out;
    explicit StringSink(std::string& s) : out(s) {}
    int_type overflow(int_type c) override {
        if (c != traits_type::eof()) out.push_back(static_cast<char>(c));
        return c;
    }
    std::streamsize xsputn(const char* p, std::streamsize n) override {
        out.append(p, static_cast<size_t>(n));
        return n;
    }
};

int main(int argc, char* argv[]) {
    if (argc != 3 || std::string(argv[1]) != "doc") {
        std::cerr << "usage: write-tomlpp doc FILE" << std::endl;
        return 2;
    }
    long n = 0;
    char* data = load(argv[2], &n);
    if (!data) return 1;
    toml::table table;
    try {
        table = toml::parse(std::string_view(data, n));
    } catch (const toml::parse_error& e) {
        std::cerr << "toml++ parse failed: " << e << std::endl;
        return 1;
    }
    std::string out;
    out.reserve(static_cast<size_t>(n) * 3);
    int64_t ns = median_ns([&]() -> int64_t {
        out.clear();
        long long t0 = now_ns();
        StringSink sink(out);
        std::ostream os(&sink);
        os << toml::toml_formatter{table};
        keep(out.data());
        return now_ns() - t0;
    });
    toml::table back;
    try {
        back = toml::parse(std::string_view(out.data(), out.size()));
    } catch (const toml::parse_error& e) {
        std::cerr << "toml++ output does not parse: " << e << std::endl;
        return 1;
    }
    bool ok;
    uint64_t chk = tp::read_check(table, back, ok);
    if (!ok) {
        std::cerr << "toml++ output reads back as other values" << std::endl;
        return 1;
    }
    report(static_cast<size_t>(n), ns, chk, "out=%zu", out.size());
    return 0;
}
