// `doc-libfyaml build|read|key FILE`: fy_document_build_from_string of the text, then nothing, a visit of every value, or
// one fy_node_mapping_lookup_value_by_simple_key of the first key in every mapping. A plain scalar is typed by the core
// schema in yaml_doc.h.
// yaml_doc.h comes first: libfyaml.h includes <stdatomic.h>, whose macros break libc++'s <atomic> when it is read later.
#include <atomic>

#include "yaml_doc.h"

#include <libfyaml.h>

struct Libfyaml {
	struct Doc {
		fy_document *d = nullptr;
		Doc() = default;
		Doc(Doc &&o) noexcept : d(o.d) { o.d = nullptr; }
		Doc &operator=(Doc &&o) noexcept {
			if (d) fy_document_destroy(d);
			d = o.d;
			o.d = nullptr;
			return *this;
		}
		~Doc() {
			if (d) fy_document_destroy(d);
		}
	};

	static bool parse(const char *buf, long n, Doc &doc) {
		doc.d = fy_document_build_from_string(nullptr, buf, (size_t)n);
		return doc.d != nullptr;
	}

	template <class S>
	static void walk_node(fy_node *node, S &s) {
		switch (fy_node_get_type(node)) {
		case FYNT_MAPPING: {
			s.object();
			void *it = nullptr;
			while (fy_node_pair *p = fy_node_mapping_iterate(node, &it)) {
				size_t kn = 0;
				const char *k = fy_node_get_scalar(fy_node_pair_key(p), &kn);
				s.key(k, kn);
				walk_node(fy_node_pair_value(p), s);
			}
			break;
		}
		case FYNT_SEQUENCE: {
			s.array();
			void *it = nullptr;
			while (fy_node *c = fy_node_sequence_iterate(node, &it)) walk_node(c, s);
			break;
		}
		default: {
			size_t n = 0;
			const char *v = fy_node_get_scalar(node, &n);
			s.scalar(v, n, fy_node_get_style(node) == FYNS_PLAIN);
		}
		}
	}

	template <class S>
	static void walk(Doc &doc, S &s) {
		walk_node(fy_document_root(doc.d), s);
	}

	static fy_node *first_object(fy_node *node) {
		switch (fy_node_get_type(node)) {
		case FYNT_MAPPING: return node;
		case FYNT_SEQUENCE: {
			void *it = nullptr;
			while (fy_node *c = fy_node_sequence_iterate(node, &it))
				if (fy_node *o = first_object(c)) return o;
			return nullptr;
		}
		default: return nullptr;
		}
	}

	static bool first_key(Doc &doc, std::string &key) {
		fy_node *o = first_object(fy_document_root(doc.d));
		void *it = nullptr;
		fy_node_pair *p = o ? fy_node_mapping_iterate(o, &it) : nullptr;
		if (!p) return false;
		size_t n = 0;
		const char *k = fy_node_get_scalar(fy_node_pair_key(p), &n);
		key.assign(k, n);
		return true;
	}

	static void key_walk_node(fy_node *node, const std::string &key, size_t &answers, size_t &objects) {
		switch (fy_node_get_type(node)) {
		case FYNT_SEQUENCE: {
			void *it = nullptr;
			while (fy_node *c = fy_node_sequence_iterate(node, &it)) key_walk_node(c, key, answers, objects);
			break;
		}
		case FYNT_MAPPING: {
			objects++;
			if (fy_node_mapping_lookup_value_by_simple_key(node, key.data(), key.size())) answers++;
			void *it = nullptr;
			while (fy_node_pair *p = fy_node_mapping_iterate(node, &it)) key_walk_node(fy_node_pair_value(p), key, answers, objects);
			break;
		}
		default: break;
		}
	}

	static void key_walk(Doc &doc, const std::string &key, size_t &answers, size_t &objects) {
		key_walk_node(fy_document_root(doc.d), key, answers, objects);
	}
};

int main(int argc, char **argv) { return doc_main<Libfyaml>(argc, argv, "doc-libfyaml"); }
