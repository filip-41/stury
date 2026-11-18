// `doc-libyaml build|read|key FILE`: yaml_parser_load of the text into a yaml_document_t, then nothing, a visit of every
// value, or a scan of the first key in every mapping (libyaml has no lookup, so a mapping's pairs are compared in order).
// libyaml reads YAML 1.1, whose events hold a scalar's text and style, and a plain scalar is typed by the core schema in
// yaml_doc.h.
#include <yaml.h>

#include "yaml_doc.h"

struct Libyaml {
	struct Doc {
		yaml_document_t d{};
		bool live = false;
		Doc() = default;
		Doc(Doc &&o) noexcept : d(o.d), live(o.live) { o.live = false; }
		Doc &operator=(Doc &&o) noexcept {
			if (live) yaml_document_delete(&d);
			d = o.d;
			live = o.live;
			o.live = false;
			return *this;
		}
		~Doc() {
			if (live) yaml_document_delete(&d);
		}
	};

	static bool parse(const char *buf, long n, Doc &doc) {
		yaml_parser_t p;
		if (!yaml_parser_initialize(&p)) return false;
		yaml_parser_set_input_string(&p, (const unsigned char *)buf, (size_t)n);
		doc.live = yaml_parser_load(&p, &doc.d);
		yaml_parser_delete(&p);
		return doc.live;
	}

	template <class S>
	static void walk_node(yaml_document_t *d, yaml_node_t *node, S &s) {
		switch (node->type) {
		case YAML_MAPPING_NODE:
			s.object();
			for (yaml_node_pair_t *p = node->data.mapping.pairs.start; p < node->data.mapping.pairs.top; p++) {
				yaml_node_t *k = yaml_document_get_node(d, p->key);
				s.key((const char *)k->data.scalar.value, k->data.scalar.length);
				walk_node(d, yaml_document_get_node(d, p->value), s);
			}
			break;
		case YAML_SEQUENCE_NODE:
			s.array();
			for (yaml_node_item_t *i = node->data.sequence.items.start; i < node->data.sequence.items.top; i++)
				walk_node(d, yaml_document_get_node(d, *i), s);
			break;
		default:
			s.scalar((const char *)node->data.scalar.value, node->data.scalar.length, node->data.scalar.style == YAML_PLAIN_SCALAR_STYLE);
		}
	}

	template <class S>
	static void walk(Doc &doc, S &s) {
		walk_node(&doc.d, yaml_document_get_root_node(&doc.d), s);
	}

	static yaml_node_t *first_object(yaml_document_t *d, yaml_node_t *node) {
		if (node->type == YAML_MAPPING_NODE) return node;
		if (node->type == YAML_SEQUENCE_NODE)
			for (yaml_node_item_t *i = node->data.sequence.items.start; i < node->data.sequence.items.top; i++)
				if (yaml_node_t *o = first_object(d, yaml_document_get_node(d, *i))) return o;
		return nullptr;
	}

	static bool first_key(Doc &doc, std::string &key) {
		yaml_node_t *o = first_object(&doc.d, yaml_document_get_root_node(&doc.d));
		if (!o || o->data.mapping.pairs.start == o->data.mapping.pairs.top) return false;
		yaml_node_t *k = yaml_document_get_node(&doc.d, o->data.mapping.pairs.start->key);
		key.assign((const char *)k->data.scalar.value, k->data.scalar.length);
		return true;
	}

	static void key_walk_node(yaml_document_t *d, yaml_node_t *node, const std::string &key, size_t &answers, size_t &objects) {
		if (node->type == YAML_SEQUENCE_NODE) {
			for (yaml_node_item_t *i = node->data.sequence.items.start; i < node->data.sequence.items.top; i++)
				key_walk_node(d, yaml_document_get_node(d, *i), key, answers, objects);
		} else if (node->type == YAML_MAPPING_NODE) {
			objects++;
			for (yaml_node_pair_t *p = node->data.mapping.pairs.start; p < node->data.mapping.pairs.top; p++) {
				yaml_node_t *k = yaml_document_get_node(d, p->key);
				if (k->type == YAML_SCALAR_NODE && k->data.scalar.length == key.size() && !memcmp(k->data.scalar.value, key.data(), key.size())) {
					answers++;
					break;
				}
			}
			for (yaml_node_pair_t *p = node->data.mapping.pairs.start; p < node->data.mapping.pairs.top; p++)
				key_walk_node(d, yaml_document_get_node(d, p->value), key, answers, objects);
		}
	}

	static void key_walk(Doc &doc, const std::string &key, size_t &answers, size_t &objects) {
		key_walk_node(&doc.d, yaml_document_get_root_node(&doc.d), key, answers, objects);
	}
};

int main(int argc, char **argv) { return doc_main<Libyaml>(argc, argv, "doc-libyaml"); }
