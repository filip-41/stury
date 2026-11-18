// html_shape.hpp's adapter for lexbor's tree: `Lexbor::Doc` owns a parsed document and frees it.
#pragma once
#include <lexbor/html/html.h>
#include <lexbor/dom/interfaces/character_data.h>
#include <lexbor/html/interfaces/template_element.h>

#include "html_shape.hpp"

struct Lexbor {
    using Node = lxb_dom_node_t*;

    struct Doc {
        lxb_html_document_t* doc = nullptr;
        Doc() = default;
        Doc(const Doc&) = delete;
        ~Doc() { if (doc) lxb_html_document_destroy(doc); }
    };

    static bool parse(Doc& d, const char* text, size_t len) {
        d.doc = lxb_html_document_create();
        return d.doc && lxb_html_document_parse(d.doc, (const lxb_char_t*)text, len) == LXB_STATUS_OK;
    }

    static Node root(Doc& d) { return lxb_dom_interface_node(lxb_dom_document_element(lxb_dom_interface_document(d.doc))); }

    static bool is_element(Node n) { return n->type == LXB_DOM_NODE_TYPE_ELEMENT; }

    static std::string_view text(Node n) {
        lexbor_str_t& s = lxb_dom_interface_character_data(n)->data;
        return {(const char*)s.data, s.length};
    }

    static std::string_view name(Node n) {
        size_t len = 0;
        const lxb_char_t* s = lxb_dom_element_local_name(lxb_dom_interface_element(n), &len);
        return {(const char*)s, len};
    }

    // A template's contents are its children, as the tree of the standard keeps them apart from the element.
    template <class F>
    static void children(Node n, F&& f) {
        if (n->local_name == LXB_TAG_TEMPLATE && n->ns == LXB_NS_HTML) n = &lxb_html_interface_template(n)->content->node;
        for (Node c = n->first_child; c; c = c->next) {
            if (c->type == LXB_DOM_NODE_TYPE_ELEMENT || c->type == LXB_DOM_NODE_TYPE_TEXT) f(c);
        }
    }
};
