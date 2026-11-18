// The shape of an HTML document under the doc lane's checks, over the tree a WHATWG tree construction builds. It is the
// document stury reads an HTML text as: an element with no child element is a value of its text (null when empty), an
// element with child elements is an object whose members are each child element under its name and a `#text` member for
// each run of text between the children that holds a character other than HTML white space. Attributes, comments, the
// document type and processing instructions are no nodes. The root is an object whose one member is the document element.
// A library's adapter gives the tree: `Node`, `children(node, f)` over the element and text nodes of a node, `element`,
// `text` (a text node's decoded bytes) and `name` (an element's local name).
#pragma once
#include <string>
#include <string_view>
#include <vector>

#include "timing.h"

namespace html_shape {

inline bool blank(std::string_view s) {
    for (unsigned char c : s)
        if (c != ' ' && c != '\t' && c != '\n' && c != '\f' && c != '\r') return false;
    return true;
}

// One element's events to `sink`, which has `object()`, `close()`, `member(name)`, `run(bytes)` and `leaf(bytes)`: `object` opens an
// element with child elements and `close` ends it, `member` precedes each child element's value, `run` is a `#text` member's value of that
// many decoded bytes (its key is a node `sink` counts too) and `leaf` an element with no child element, its text's bytes.
template <class A, class Sink>
void element(typename A::Node el, Sink& sink) {
    bool has_child = false;
    size_t leaf_bytes = 0;
    A::children(el, [&](typename A::Node c) {
        if (A::is_element(c)) has_child = true;
        else leaf_bytes += A::text(c).size();
    });
    if (!has_child) {
        sink.leaf(leaf_bytes);
        return;
    }
    sink.object();
    size_t run_bytes = 0;
    bool run_text = false;
    auto flush = [&] {
        if (run_text) sink.run(run_bytes);
        run_bytes = 0;
        run_text = false;
    };
    A::children(el, [&](typename A::Node c) {
        if (!A::is_element(c)) {
            std::string_view t = A::text(c);
            run_bytes += t.size();
            run_text = run_text || !blank(t);
            return;
        }
        flush();
        sink.member(A::name(c));
        element<A>(c, sink);
    });
    flush();
    sink.close();
}

// The document: an object with one member, the document element.
template <class A, class Sink>
void document(typename A::Node root, Sink& sink) {
    sink.object();
    sink.member(A::name(root));
    element<A>(root, sink);
    sink.close();
}

// The build lane's check: the node count, then each node's kind tag and role.
struct Count {
    uint64_t nodes = 0;
    void object() { nodes++; }
    void close() {}
    void member(std::string_view) { nodes++; }
    void run(size_t) { nodes += 2; }
    void leaf(size_t) { nodes++; }
};

struct Hash {
    uint64_t h;
    void put(char tag, uint8_t role) { h = fnv_byte(fnv_byte(h, (uint8_t)tag), role); }
    void object() { put('o', 0); }
    void close() {}
    void member(std::string_view) { put('s', 1); }
    void run(size_t) { put('s', 1); put('s', 0); }
    void leaf(size_t bytes) { put(bytes ? 's' : 'z', 0); }
};

// The read lane: each value's tag, then its decoded byte count. With HASH false only the sum, which is kept so the read
// is not optimized away.
template <bool HASH>
struct Read {
    uint64_t h = CHECK_OFFSET;
    double sum = 0;
    void object() { if constexpr (HASH) h = fnv_byte(h, 'o'); }
    void close() {}
    void member(std::string_view) {}
    void text(size_t bytes) {
        if constexpr (HASH) h = fnv_u64(fnv_byte(h, 's'), bytes);
        sum += (double)bytes;
    }
    void run(size_t bytes) { text(bytes); }
    void leaf(size_t bytes) {
        if (bytes) text(bytes);
        else if constexpr (HASH) h = fnv_byte(h, 'z');
    }
};

// The key lane: objects, and how many hold a member named `key`. An object answers once however many members are named so.
struct Key {
    std::string_view key;
    uint64_t objects = 0, answers = 0;
    std::vector<bool> counted;
    void object() { objects++; counted.push_back(false); }
    void close() { counted.pop_back(); }
    void member(std::string_view name) {
        if (name == key && !counted.back()) {
            counted.back() = true;
            answers++;
        }
    }
    void run(size_t) {}
    void leaf(size_t) {}
};

// The read check of a text parsed by `A`, which is how a write lane checks what a library wrote.
template <class A>
uint64_t read_check(const char* text, size_t len) {
    typename A::Doc doc;
    if (!A::parse(doc, text, len)) return 0;
    Read<true> r;
    document<A>(A::root(doc), r);
    return r.h;
}

// `doc-<library> build|read|key FILE`: the library's parse of the text, then nothing, a visit of every value, or the
// first member's key looked up in every object. `A::Doc` is the parsed tree, freed outside the clock, `A::parse` fills it
// from the text and `A::root` gives the document element.
template <class A>
int run_doc(int argc, char** argv, const char* program) {
    long n = 0;
    char* text = argc == 3 ? load(argv[2], &n) : nullptr;
    if (!text) {
        fprintf(stderr, "usage: %s build|read|key FILE\n", program);
        return 2;
    }
    std::string lane = argv[1];
    size_t len = (size_t)n;
    uint64_t answers = 0, objects = 0;
    std::string key_name;
    if (lane != "build" && lane != "read" && lane != "key") {
        fprintf(stderr, "no sublane %s\n", lane.c_str());
        return 2;
    }
    auto once = [&]() -> int64_t {
        typename A::Doc doc;
        long long t0 = now_ns();
        if (!A::parse(doc, text, len)) return -1;
        if (lane == "read") {
            Read<false> r;
            document<A>(A::root(doc), r);
            keep(&r);
        } else if (lane == "key") {
            Key k;
            k.key = A::name(A::root(doc));
            document<A>(A::root(doc), k);
            objects = k.objects;
            answers = k.answers;
            keep(&k);
        } else {
            keep(&doc);
        }
        return now_ns() - t0;
    };
    int64_t ns = median_ns(once);
    if (ns < 0) {
        fprintf(stderr, "%s: parse failed\n", program);
        return 1;
    }
    typename A::Doc doc;
    A::parse(doc, text, len);
    uint64_t check = 0;
    if (lane == "build") {
        Count c;
        document<A>(A::root(doc), c);
        Hash h{fnv_u64(CHECK_OFFSET, c.nodes)};
        document<A>(A::root(doc), h);
        check = h.h;
    } else if (lane == "read") {
        Read<true> r;
        document<A>(A::root(doc), r);
        check = r.h;
    } else {
        key_name = std::string(A::name(A::root(doc)));
        check = fnv_bytes(CHECK_OFFSET, key_name.data(), key_name.size());
        check = fnv_u64(fnv_u64(check, answers), objects);
    }
    if (lane == "key")
        report(len, ns, check, "answers=%llu objects=%llu key=%s", (unsigned long long)answers, (unsigned long long)objects, key_name.c_str());
    else
        report(len, ns, check, "");
    free(text);
    return 0;
}

}  // namespace html_shape
