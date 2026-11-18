// The rapidyaml side of the YAML document lane, shared by `rapidyaml.cpp` and the other lanes' rapidyaml drivers: a
// parsed Tree walked into the sinks of yaml_doc.h. The including file defines RYML_SINGLE_HDR_DEFINE_NOW once.
#pragma once
#include <ryml_all.hpp>

#include "yaml_doc.h"

struct Rapidyaml {
	using Doc = ryml::Tree;

	static bool parse(const char *buf, long n, Doc &doc) {
		doc = ryml::parse_in_arena(ryml::csubstr(buf, (size_t)n));
		return true;
	}

	// The node a document's content starts at: the root, or the one document of a stream.
	static ryml::id_type content(const Doc &t) {
		ryml::id_type id = t.root_id();
		if (t.is_stream(id) && t.num_children(id) == 1) id = t.first_child(id);
		return id;
	}

	template <class S>
	static void walk_node(const Doc &t, ryml::id_type id, S &s) {
		if (t.is_map(id)) {
			s.object();
			for (ryml::id_type c = t.first_child(id); c != ryml::NONE; c = t.next_sibling(c)) {
				ryml::csubstr k = t.key(c);
				s.key(k.str, k.len);
				walk_node(t, c, s);
			}
		} else if (t.is_seq(id)) {
			s.array();
			for (ryml::id_type c = t.first_child(id); c != ryml::NONE; c = t.next_sibling(c)) walk_node(t, c, s);
		} else {
			ryml::csubstr v = t.has_val(id) ? t.val(id) : ryml::csubstr();
			s.scalar(v.str, v.len, !t.is_val_quoted(id));
		}
	}

	template <class S>
	static void walk(Doc &t, S &s) {
		walk_node(t, content(t), s);
	}

	static ryml::id_type first_object(const Doc &t, ryml::id_type id) {
		if (t.is_map(id)) return id;
		if (t.is_seq(id))
			for (ryml::id_type c = t.first_child(id); c != ryml::NONE; c = t.next_sibling(c)) {
				ryml::id_type o = first_object(t, c);
				if (o != ryml::NONE) return o;
			}
		return ryml::NONE;
	}

	static bool first_key(Doc &t, std::string &key) {
		ryml::id_type o = first_object(t, content(t));
		if (o == ryml::NONE || t.first_child(o) == ryml::NONE) return false;
		ryml::csubstr k = t.key(t.first_child(o));
		key.assign(k.str, k.len);
		return true;
	}

	static void key_walk_node(const Doc &t, ryml::id_type id, ryml::csubstr key, size_t &answers, size_t &objects) {
		if (t.is_seq(id)) {
			for (ryml::id_type c = t.first_child(id); c != ryml::NONE; c = t.next_sibling(c)) key_walk_node(t, c, key, answers, objects);
		} else if (t.is_map(id)) {
			objects++;
			if (t.find_child(id, key) != ryml::NONE) answers++;
			for (ryml::id_type c = t.first_child(id); c != ryml::NONE; c = t.next_sibling(c)) key_walk_node(t, c, key, answers, objects);
		}
	}

	static void key_walk(Doc &t, const std::string &key, size_t &answers, size_t &objects) {
		key_walk_node(t, content(t), ryml::csubstr(key.data(), key.size()), answers, objects);
	}
};
