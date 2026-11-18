// What the toml++ drivers of the doc, paths and write lanes share: the checks over a parsed `toml::table`. toml++ keeps a
// table's members in key order, so every check walks them in the order the text first names them, taken from each node's
// source position, which is how the other arms' documents and stury's order them. Dates and times count as strings.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <string_view>
#include <utility>
#include <vector>
#include <toml++/toml.hpp>

#include "timing.h"

namespace tp {

using Pos = std::pair<uint32_t, uint32_t>;

// The first place the text names `n`: its own position or the first of its members and elements, whichever comes first.
static Pos first_pos(const toml::node& n) {
    Pos p{UINT32_MAX, UINT32_MAX};
    const auto& b = n.source().begin;
    if (b.line) p = {b.line, b.column};
    if (auto* t = n.as_table()) {
        for (auto&& kv : *t) p = std::min(p, first_pos(kv.second));
    } else if (auto* a = n.as_array()) {
        for (auto& e : *a) p = std::min(p, first_pos(e));
    }
    return p;
}

using Member = std::pair<std::string_view, const toml::node*>;

// The members of `t` in text order.
static std::vector<Member> members(const toml::table& t) {
    std::vector<std::pair<Pos, Member>> keyed;
    keyed.reserve(t.size());
    for (auto&& kv : t) keyed.push_back({first_pos(kv.second), {kv.first.str(), &kv.second}});
    std::stable_sort(keyed.begin(), keyed.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
    std::vector<Member> out;
    out.reserve(keyed.size());
    for (auto& k : keyed) out.push_back(k.second);
    return out;
}

static uint64_t bits_of(double x) {
    uint64_t b = 0;
    if (x != 0) std::memcpy(&b, &x, sizeof b);
    return b;
}

static bool is_container(const toml::node& n) { return n.is_table() || n.is_array(); }

static uint64_t count(const toml::node& n) {
    uint64_t c = 1;
    if (auto* t = n.as_table()) {
        for (auto&& kv : *t) c += 1 + count(kv.second);
    } else if (auto* a = n.as_array()) {
        for (auto& e : *a) c += count(e);
    }
    return c;
}

// The build check's kind tags of the tree in text order.
static void hash_kinds(const toml::node& n, uint64_t& h) {
    if (auto* t = n.as_table()) {
        h = fnv_byte(fnv_byte(h, 'o'), 0);
        for (auto& m : members(*t)) {
            h = fnv_byte(fnv_byte(h, 's'), 1);
            hash_kinds(*m.second, h);
        }
    } else if (auto* a = n.as_array()) {
        h = fnv_byte(fnv_byte(h, 'a'), 0);
        for (auto& e : *a) hash_kinds(e, h);
    } else if (auto* b = n.as_boolean()) {
        h = fnv_byte(fnv_byte(h, b->get() ? 't' : 'f'), 0);
    } else if (n.is_integer() || n.is_floating_point()) {
        h = fnv_byte(fnv_byte(h, 'n'), 0);
    } else {
        h = fnv_byte(fnv_byte(h, 's'), 0);
    }
}

static uint64_t build_check(const toml::table& root) {
    uint64_t h = fnv_u64(CHECK_OFFSET, count(root));
    hash_kinds(root, h);
    return h;
}

// The read check: in the text order of `order`, each value's tag, then a string's length or a number's binary64 bits, the
// values taken from `from`, which is `order` itself or a parse of what a writer made of it. False when `from` lacks a
// member, an element or the type of what `order` holds.
static bool hash_values(const toml::node& order, const toml::node& from, uint64_t& h) {
    if (auto* t = order.as_table()) {
        auto* ft = from.as_table();
        if (!ft || ft->size() != t->size()) return false;
        h = fnv_byte(h, 'o');
        for (auto& m : members(*t)) {
            auto* f = ft->get(m.first);
            if (!f || !hash_values(*m.second, *f, h)) return false;
        }
    } else if (auto* a = order.as_array()) {
        auto* fa = from.as_array();
        if (!fa || fa->size() != a->size()) return false;
        h = fnv_byte(h, 'a');
        for (size_t i = 0; i < a->size(); i++)
            if (!hash_values(*a->get(i), *fa->get(i), h)) return false;
    } else if (auto* b = order.as_boolean()) {
        auto* fb = from.as_boolean();
        if (!fb || fb->get() != b->get()) return false;
        h = fnv_byte(h, b->get() ? 't' : 'f');
    } else if (order.is_integer() || order.is_floating_point()) {
        double x;
        if (auto* fi = from.as_integer()) x = static_cast<double>(fi->get());
        else if (auto* ff = from.as_floating_point()) x = ff->get();
        else return false;
        h = fnv_u64(fnv_byte(h, 'n'), bits_of(x));
    } else {
        auto* fs = from.as_string();
        size_t len = fs ? fs->get().size() : 0;
        h = fnv_u64(fnv_byte(h, 's'), len);
    }
    return true;
}

static uint64_t read_check(const toml::table& order, const toml::table& from, bool& ok) {
    uint64_t h = CHECK_OFFSET;
    ok = hash_values(order, from, h);
    return h;
}

// What a timed visit of every value saw, kept so the visit is not optimized away.
struct Visit {
    double sum = 0;
};

static void visit(const toml::node& n, Visit& v) {
    if (auto* t = n.as_table()) {
        for (auto&& kv : *t) visit(kv.second, v);
    } else if (auto* a = n.as_array()) {
        for (auto& e : *a) visit(e, v);
    } else if (auto* s = n.as_string()) {
        const std::string& str = s->get();
        v.sum += static_cast<double>(str.size());
        if (!str.empty()) keep(str.data());
    } else if (auto* i = n.as_integer()) {
        v.sum += static_cast<double>(i->get());
    } else if (auto* f = n.as_floating_point()) {
        v.sum += f->get();
    }
}

// The first object in text order is the root table, and the lane's key is its first member's.
static std::string first_key(const toml::table& root) {
    auto m = members(root);
    return m.empty() ? std::string() : std::string(m.front().first);
}

static void key_walk(const toml::node& n, std::string_view key, uint64_t& answers, uint64_t& objects) {
    if (auto* t = n.as_table()) {
        objects++;
        if (t->get(key)) answers++;
        for (auto&& kv : *t) key_walk(kv.second, key, answers, objects);
    } else if (auto* a = n.as_array()) {
        for (auto& e : *a) key_walk(e, key, answers, objects);
    }
}

}  // namespace tp
