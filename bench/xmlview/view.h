// The tree stury reads an XML text as, produced from a DOM library's tree by the `walk_document` of each library's header,
// and the visitors that fold it. An element is a member named for it: a plain value of its text when it has no child
// element (empty text reads as null), otherwise an object holding a `#text` member for each run of text between its
// children that has a character other than white space, and each child. Attributes, comments and processing instructions
// are no nodes. The visitors take calls in the order of stury's document nodes: key, then its value (`object` to
// `end_object`, or `plain`).
#pragma once
#include <string>

#include "timing.h"

namespace xmlview {

inline bool has_text(const char *p, size_t n) {
	for (size_t i = 0; i < n; i++) {
		char c = p[i];
		if (c != ' ' && c != '\t' && c != '\n' && c != '\r') return true;
	}
	return false;
}

// The text between two children of an element, built of the text nodes the library gives for it.
struct Run {
	size_t len = 0;
	bool text = false;
	void add(const char *p, size_t n) {
		len += n;
		if (!text) text = has_text(p, n);
	}
	void clear() {
		len = 0;
		text = false;
	}
};

// Gives the run to `v` as a `#text` member when it has text, then clears it.
template <class V>
inline void flush(Run &r, V &v) {
	if (r.text) {
		v.key("#text", 5);
		v.plain(r.len, nullptr);
	}
	r.clear();
}

// The build lane's check: the node count, then each node's kind tag and role, role 1 being a key. An empty text is null.
struct BuildCheck {
	std::string seq;
	void key(const char *, size_t) { seq.push_back('s'), seq.push_back(1); }
	void object() { seq.push_back('o'), seq.push_back(0); }
	void end_object() {}
	void plain(size_t n, const char *) { seq.push_back(n ? 's' : 'z'), seq.push_back(0); }
	uint64_t hash() const {
		uint64_t h = fnv_u64(CHECK_OFFSET, seq.size() / 2);
		for (char c : seq) h = fnv_byte(h, (uint8_t)c);
		return h;
	}
};

// The read lane's check: each value's tag, then a string's length. An empty text is null.
struct ReadCheck {
	uint64_t h = CHECK_OFFSET;
	void key(const char *, size_t) {}
	void object() { h = fnv_byte(h, 'o'); }
	void end_object() {}
	void plain(size_t n, const char *) {
		if (n == 0) {
			h = fnv_byte(h, 'z');
		} else {
			h = fnv_u64(fnv_byte(h, 's'), n);
		}
	}
};

// The timed read: every string adds its length to the sum and touches its first byte.
struct Sum {
	double sum = 0;
	void key(const char *, size_t) {}
	void object() {}
	void end_object() {}
	void plain(size_t n, const char *first) {
		sum += (double)n;
		if (first && n) {
			unsigned char c = (unsigned char)*first;
			keep(&c);
		}
	}
};

}  // namespace xmlview
