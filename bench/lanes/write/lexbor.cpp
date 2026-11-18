// `write-lexbor doc FILE`: lexbor's serialization of the document parsed from FILE, into a buffer reused across calls. The
// parse is outside the clock and the GB/s counts the source's bytes. The check is the read check of the output parsed
// again by lexbor (html_shape.hpp's), taken outside the clock.
#include <lexbor/html/serialize.h>

#include "../doc/lexbor_shape.hpp"

namespace {

lxb_status_t append(const lxb_char_t* data, size_t len, void* ctx) {
    static_cast<std::string*>(ctx)->append((const char*)data, len);
    return LXB_STATUS_OK;
}

}  // namespace

int main(int argc, char** argv) {
    long n = 0;
    char* text = argc >= 3 && std::string(argv[1]) == "doc" ? load(argv[2], &n) : nullptr;
    if (!text) {
        fprintf(stderr, "usage: write-lexbor doc FILE\n");
        return 2;
    }
    Lexbor::Doc doc;
    if (!Lexbor::parse(doc, text, (size_t)n)) {
        fprintf(stderr, "write-lexbor: parse failed\n");
        return 1;
    }
    std::string out;
    out.reserve((size_t)n * 3);
    lxb_dom_node_t* top = lxb_dom_interface_node(lxb_dom_interface_document(doc.doc));
    int64_t ns = median_ns([&]() -> int64_t {
        out.clear();
        long long t0 = now_ns();
        lxb_status_t status = lxb_html_serialize_tree_cb(top, append, &out);
        keep(out.data());
        long long d = now_ns() - t0;
        return status == LXB_STATUS_OK ? d : -1;
    });
    if (ns < 0) {
        fprintf(stderr, "write-lexbor: serialize failed\n");
        return 1;
    }
    report((size_t)n, ns, html_shape::read_check<Lexbor>(out.data(), out.size()), "out=%zu", out.size());
    return 0;
}
