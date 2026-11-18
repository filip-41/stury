// `paths-lexbor build_select|select FILE SELECTOR [BATCH]`: lexbor's CSS selector engine over an HTML text, taking the first
// element SELECTOR matches. `build_select` parses the text, selects and releases the document in each call, the job
// stury's build_query does. `select` selects on a document parsed outside the clock. A sample is BATCH calls, and the
// ns is the median sample over BATCH. The check is the FNV-1a of the answer's decoded text then a newline.
#include <lexbor/css/css.h>
#include <lexbor/html/html.h>
#include <lexbor/selectors/selectors.h>
#include <string>

#include "timing.h"

namespace {

lxb_status_t first_match(lxb_dom_node_t* node, lxb_css_selector_specificity_t, void* ctx) {
    *static_cast<lxb_dom_node_t**>(ctx) = node;
    return LXB_STATUS_STOP;
}

struct Selection {
    lxb_selectors_t* selectors = lxb_selectors_create();
    lxb_css_parser_t* parser = lxb_css_parser_create();
    lxb_css_selector_list_t* list = nullptr;

    bool init(const std::string& selector) {
        if (lxb_selectors_init(selectors) != LXB_STATUS_OK || lxb_css_parser_init(parser, nullptr) != LXB_STATUS_OK) return false;
        list = lxb_css_selectors_parse(parser, (const lxb_char_t*)selector.data(), selector.size());
        return parser->status == LXB_STATUS_OK && list;
    }

    lxb_dom_node_t* first(lxb_html_document_t* doc) const {
        lxb_dom_node_t* found = nullptr;
        lxb_selectors_find(selectors, lxb_dom_interface_node(lxb_dom_document_element(lxb_dom_interface_document(doc))), list, first_match, &found);
        return found;
    }
};

uint64_t answer_check(lxb_dom_node_t* node) {
    uint64_t h = CHECK_OFFSET;
    if (node) {
        size_t len = 0;
        lxb_char_t* text = lxb_dom_node_text_content(node, &len);
        h = fnv_bytes(h, (const char*)text, len);
        lxb_dom_document_destroy_text(node->owner_document, text);
    }
    return fnv_byte(h, '\n');
}

}  // namespace

int main(int argc, char** argv) {
    long n = 0;
    char* text = argc >= 4 ? load(argv[2], &n) : nullptr;
    std::string mode = argc >= 4 ? argv[1] : "";
    if (!text || (mode != "build_select" && mode != "select")) {
        fprintf(stderr, "usage: paths-lexbor build_select|select FILE SELECTOR [BATCH]\n");
        return 2;
    }
    int batch = argc >= 5 ? atoi(argv[4]) : 1;
    Selection sel;
    if (!sel.init(argv[3])) {
        fprintf(stderr, "paths-lexbor: bad selector %s\n", argv[3]);
        return 1;
    }
    auto parse = [&]() {
        lxb_html_document_t* doc = lxb_html_document_create();
        if (lxb_html_document_parse(doc, (const lxb_char_t*)text, (size_t)n) != LXB_STATUS_OK) {
            fprintf(stderr, "paths-lexbor: parse failed\n");
            exit(1);
        }
        return doc;
    };
    lxb_html_document_t* built = mode == "select" ? parse() : nullptr;
    int64_t ns = median_ns([&]() -> int64_t {
        long long t0 = now_ns();
        for (int k = 0; k < batch; k++) {
            if (built) {
                lxb_dom_node_t* node = sel.first(built);
                keep(&node);
            } else {
                lxb_html_document_t* doc = parse();
                lxb_dom_node_t* node = sel.first(doc);
                keep(&node);
                lxb_html_document_destroy(doc);
            }
        }
        return now_ns() - t0;
    });
    lxb_html_document_t* doc = built ? built : parse();
    uint64_t check = answer_check(sel.first(doc));
    report((size_t)n, ns / batch, check, "");
    return 0;
}
