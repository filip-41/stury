// `walk_document` over a pugixml tree, for the visitors of view.h. The tree must be parsed with parse_ws_pcdata_single, so
// that a text of white space alone is kept when it is an element's only content.
#pragma once
#include <cstring>
#include <pugixml.hpp>

#include "view.h"

namespace xmlview {

inline bool is_text(pugi::xml_node c) { return c.type() == pugi::node_pcdata || c.type() == pugi::node_cdata; }

template <class V>
void walk_element(pugi::xml_node e, V &v) {
	const char *name = e.name();
	v.key(name, strlen(name));
	bool object = false;
	for (pugi::xml_node c = e.first_child(); c; c = c.next_sibling()) {
		if (c.type() == pugi::node_element) {
			object = true;
			break;
		}
	}
	if (!object) {
		size_t n = 0;
		const char *first = nullptr;
		for (pugi::xml_node c = e.first_child(); c; c = c.next_sibling()) {
			if (!is_text(c)) continue;
			const char *s = c.value();
			if (!first) first = s;
			n += strlen(s);
		}
		v.plain(n, first);
		return;
	}
	v.object();
	Run run;
	for (pugi::xml_node c = e.first_child(); c; c = c.next_sibling()) {
		if (c.type() == pugi::node_element) {
			flush(run, v);
			walk_element(c, v);
		} else if (is_text(c)) {
			const char *s = c.value();
			run.add(s, strlen(s));
		}
	}
	flush(run, v);
	v.end_object();
}

template <class V>
bool walk_document(const pugi::xml_document &d, V &v) {
	pugi::xml_node root = d.document_element();
	if (!root) return false;
	v.object();
	walk_element(root, v);
	v.end_object();
	return true;
}

// The key lane's lookups: the objects of the tree and those with a child element named `key`.
inline void key_walk(pugi::xml_node e, const char *key, size_t &answers, size_t &objects) {
	bool object = false;
	for (pugi::xml_node c = e.first_child(); c; c = c.next_sibling()) {
		if (c.type() != pugi::node_element) continue;
		object = true;
		key_walk(c, key, answers, objects);
	}
	if (!object) return;
	objects++;
	if (e.child(key)) answers++;
}

}  // namespace xmlview
