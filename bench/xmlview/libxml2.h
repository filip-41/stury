// `walk_document` over a libxml2 tree, for the visitors of view.h. An element's name is its local name, which is its
// qualified name for a name with no prefix.
#pragma once
#include <cstring>
#include <libxml/parser.h>
#include <libxml/tree.h>

#include "view.h"

namespace xmlview {

inline bool is_text(const xmlNode *c) { return c->type == XML_TEXT_NODE || c->type == XML_CDATA_SECTION_NODE; }

inline const char *content(const xmlNode *c) { return c->content ? (const char *)c->content : ""; }

template <class V>
void walk_element(const xmlNode *e, V &v) {
	const char *name = (const char *)e->name;
	v.key(name, strlen(name));
	bool object = false;
	for (const xmlNode *c = e->children; c; c = c->next) {
		if (c->type == XML_ELEMENT_NODE) {
			object = true;
			break;
		}
	}
	if (!object) {
		size_t n = 0;
		const char *first = nullptr;
		for (const xmlNode *c = e->children; c; c = c->next) {
			if (!is_text(c)) continue;
			const char *s = content(c);
			if (!first) first = s;
			n += strlen(s);
		}
		v.plain(n, first);
		return;
	}
	v.object();
	Run run;
	for (const xmlNode *c = e->children; c; c = c->next) {
		if (c->type == XML_ELEMENT_NODE) {
			flush(run, v);
			walk_element(c, v);
		} else if (is_text(c)) {
			const char *s = content(c);
			run.add(s, strlen(s));
		}
	}
	flush(run, v);
	v.end_object();
}

template <class V>
bool walk_document(xmlDoc *d, V &v) {
	const xmlNode *root = xmlDocGetRootElement(d);
	if (!root) return false;
	v.object();
	walk_element(root, v);
	v.end_object();
	return true;
}

// The key lane's lookups: the objects of the tree and those with a child element named `key`.
inline void key_walk(const xmlNode *e, const xmlChar *key, size_t &answers, size_t &objects) {
	bool object = false, found = false;
	for (const xmlNode *c = e->children; c; c = c->next) {
		if (c->type != XML_ELEMENT_NODE) continue;
		object = true;
		found = found || xmlStrEqual(c->name, key);
		key_walk(c, key, answers, objects);
	}
	if (!object) return;
	objects++;
	if (found) answers++;
}

}  // namespace xmlview
