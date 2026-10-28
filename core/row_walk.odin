package core

// Walks over a row document: `child` by key or index, `children` and `members` over one container, and the JSON
// Pointer `pointer`.

// A member of `n` by key or by 0-based index, or `NO_NODE`; a negative index counts from the end (`-1` is
// the last member), as a path's `.[-1]` does.
child :: proc {
	child_by_key,
	child_by_index,
}

// The last member of object `n` whose key decodes to `name`, or `NO_NODE`. An array answers none. The same
// reading as a path's default `.Last`.
@(require_results)
child_by_key :: proc(doc: ^Document, n: Node, name: string) -> Node {
	if doc.distinct_keys {
		return find_key(doc, n, name, true)
	}
	return find_key(doc, n, name, false)
}

// The last member of object `i` whose key decodes to `name`, or `NO_NODE`; with `unique` no key repeats, so the
// first match is the last. A member with no row is not found.
@(private = "file")
find_key :: proc(doc: ^Document, i: Node, name: string, $unique: bool) -> Node {
	nodes := doc.rows[:]
	if !dom_has(nodes, i) || nodes[i].kind != .Object {
		return NO_NODE
	}
	found := NO_NODE
	end := i + Node(nodes[i].subtree_size)
	j := dom_first_member(nodes, i)
	for _ in 0 ..< nodes[i].cnt {
		if !dom_has(nodes, j) {
			return NO_NODE
		}
		r := &nodes[j]
		if r.key_lo != NO_KEY && row_key_equals(doc, r, name) {
			found = j
			when unique {
				break
			}
		}
		// `dom_next_member`, with the container's end loaded once.
		j += Node(r.subtree_size)
		if j >= end {
			j = NO_NODE
		}
	}
	return found
}

// Every child of a container in order, as values for `children` and as keys and values for `members`. Start
// a walk with either and loop over the same name:
//
//	it := children(&doc, arr)
//	for v in children(&it) {}
//	kv := members(&doc, obj)
//	for name, v in members(&kv) {}
//
// `children(&doc, n)` starts the walk (over a scalar or `NO_NODE`, an empty one), and `children(&it)` gives the
// next child, `ok` false past the last. It allocates nothing and borrows `doc`, which outlives it.
children :: proc {
	members_of,
	children_next,
}

// Every member of an object in order, as `children` but with each member's decoded key.
//
//	- `members(&doc, n)` starts the walk, and `members(&it)` gives the next key and value.
//	- A key is borrowed from the document.
//	- The walk stops at a key `get_key` refuses (an escaped key the cache could not hold), so `it.node < it.end`
//	  after the loop means it stopped early, and over an array yields nothing: an element has no key.
members :: proc {
	members_of,
	members_next,
}

// The next key and member of the walk, `ok` false past the last or at a key `get_key` refuses.
members_next :: proc(it: ^Members) -> (k: string, n: Node, ok: bool) {
	if it.node >= it.end {
		return "", NO_NODE, false
	}
	k = get_key(it.doc, it.node) or_return
	n, _ = children_next(it)
	return k, n, true
}

// The value JSON Pointer `ptr` (RFC 6901) names from `n`, or `NO_NODE`.
//
//	- `""` is `n` itself; any other pointer starts with `/`.
//	- Each `/`-separated token, its `~1` read as `/` and its `~0` as `~`, names an object's member by decoded
//	  key (the last duplicate, as `child` reads) or an array's element by index: `0` or a digit run without
//	  a leading zero, in range.
//	- `-` (past the last element), a token that is no index on an array, a scalar mid-pointer, a missing
//	  member and a malformed pointer (no leading `/`, any other `~`) answer `NO_NODE`.
//	- A URI fragment pointer is the caller's to strip of `#` and percent-decode.
//	- It allocates nothing but for a token with a `~` longer than SCRATCH_BYTES, decoded in the document's
//	  allocator and freed before return; a refusal there answers `NO_NODE`.
@(require_results)
pointer :: proc(doc: ^Document, n: Node, ptr: string) -> Node {
	if !dom_has(doc.rows[:], n) || (ptr != "" && ptr[0] != '/') {
		return NO_NODE
	}
	at, i := n, 0
	for i < len(ptr) && at != NO_NODE {
		i += 1
		start, escaped := i, false
		for i < len(ptr) && ptr[i] != '/' {
			escaped |= ptr[i] == '~'
			i += 1
		}
		token := ptr[start:i]
		switch kd, _ := kind(doc, at); kd {
		case .Object:
			at = child(doc, at, token) if !escaped else pointer_member(doc, at, token)
		case .Array:
			index, count := 0, child_count(doc, at)
			for c in transmute([]u8)token {
				index = index * 10 + int(c - '0')
				if c < '0' || c > '9' || index >= count { return NO_NODE }
			}
			at = child(doc, at, index) if token != "" && (token[0] != '0' || token == "0") else NO_NODE
		case .Null, .False, .True, .Number, .String:
			return NO_NODE
		}
	}
	return at
}

// The stack scratch `pointer` decodes a token into: a longer one takes the document's allocator.
@(private = "file")
SCRATCH_BYTES :: 256

// `child(doc, n, key)` for a pointer token holding a `~`, its `~1` read as `/` and its `~0` as `~`; any other
// `~` answers `NO_NODE`.
@(private = "file")
pointer_member :: proc(doc: ^Document, n: Node, token: string) -> Node {
	stack: [SCRATCH_BYTES]u8 = ---
	heap := len(token) > len(stack)
	key := make([]u8, len(token), doc.rows.allocator) if heap else stack[:]
	if key == nil {
		return NO_NODE
	}
	defer if heap {
		delete(key, doc.rows.allocator)
	}
	w := 0
	for i := 0; i < len(token); i += 1 {
		c := token[i]
		if c == '~' {
			i += 1
			switch token[i:min(i + 1, len(token))] {
			case "0": c = '~'
			case "1": c = '/'
			case: return NO_NODE
			}
		}
		key[w] = c
		w += 1
	}
	return child(doc, n, string(key[:w]))
}
