// `doc-gumbo build|read|key FILE`: gumbo's parse of the text (WHATWG tree construction), then nothing, a visit of every
// value or the root key looked up in every object. The shape each lane reads is html_shape.hpp's.
extern "C" {
#include <gumbo.h>
}

#include "html_shape.hpp"

struct Gumbo {
    using Node = const GumboNode*;

    struct Doc {
        GumboOutput* out = nullptr;
        Doc() = default;
        Doc(const Doc&) = delete;
        ~Doc() { if (out) gumbo_destroy_output(&kGumboDefaultOptions, out); }
    };

    static bool parse(Doc& d, const char* text, size_t len) {
        d.out = gumbo_parse_with_options(&kGumboDefaultOptions, text, len);
        return d.out != nullptr;
    }

    static Node root(Doc& d) { return d.out->root; }

    static bool is_element(Node n) { return n->type == GUMBO_NODE_ELEMENT || n->type == GUMBO_NODE_TEMPLATE; }

    static std::string_view text(Node n) { return {n->v.text.text, strlen(n->v.text.text)}; }

    static std::string_view name(Node n) {
        const GumboElement& e = n->v.element;
        if (e.tag != GUMBO_TAG_UNKNOWN) return {gumbo_normalized_tagname(e.tag)};
        GumboStringPiece p = e.original_tag;
        gumbo_tag_from_original_text(&p);
        return {p.data, p.length};
    }

    template <class F>
    static void children(Node n, F&& f) {
        const GumboVector& v = n->v.element.children;
        for (unsigned i = 0; i < v.length; i++) {
            const GumboNode* c = (const GumboNode*)v.data[i];
            if (is_element(c) || c->type == GUMBO_NODE_TEXT || c->type == GUMBO_NODE_WHITESPACE || c->type == GUMBO_NODE_CDATA) f(c);
        }
    }
};

int main(int argc, char** argv) { return html_shape::run_doc<Gumbo>(argc, argv, "doc-gumbo"); }
