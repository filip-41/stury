package json

// Walks over a built document: `child` by key or index, `children` and `members` over one container, and the JSON
// Pointer `pointer`.

import core_pkg "../core"
import scan_pkg "scan"
import "scan/walk"

// A member of `n` by key or by 0-based index, or `NO_NODE`; a negative index counts from the end (`-1` is
// the last member), as a path's `.[-1]` does.
child :: proc {
	child_by_key,
	core_pkg.child_by_index,
}

// The last member of object `n` whose key decodes to `name`, or `NO_NODE`. An array answers none. The same
// reading as a path's default `.Last`.
@(private, require_results)
child_by_key :: proc(doc: ^Document, n: Node, name: string) -> Node {
	if doc.distinct_keys {
		return walk.dom_find_key(doc.rows[:], doc.src, n, name, scan_pkg.hooks_of(doc.dialect), true)
	}
	return walk.dom_find_key(doc.rows[:], doc.src, n, name, scan_pkg.hooks_of(doc.dialect), false)
}

// The member count of container `n`; zero on a scalar.
@(require_results)
child_count :: proc(doc: ^Document, n: Node) -> int {
	return core_pkg.child_count(doc, n)
}

// The position of a walk over one container's members (`children`, `members`). A value, owning nothing; it
// borrows the document. A member's run of rows ends where the next begins, so a step is one add, bounded by
// the container's end (`end`).
Members :: core_pkg.Members

// Every child of a container in order, as values for `children` and as keys and values for `members`. Start
// a walk with either and loop over the same name:
//
//	it := json.children(&doc, arr)
//	for v in json.children(&it) {}
//	kv := json.members(&doc, obj)
//	for name, v in json.members(&kv) {}
//
// `children(&doc, n)` starts the walk (over a scalar or `NO_NODE`, an
// empty one), and `children(&it)` gives the next child, `ok` false past the last. It allocates nothing and
// borrows `doc`, which outlives it.
children :: proc {
	core_pkg.members_of,
	core_pkg.children_next,
}

// Every member of an object in order, as `children` but with each member's decoded key.
//
//	- `members(&doc, n)` starts the walk, and `members(&it)` gives the next key and value.
//	- A key is borrowed from the document.
//	- The walk stops at a key the document's arena could not decode (`it.node < it.end` after the loop),
//	  and over an array yields nothing: an element has no key.
members :: proc {
	core_pkg.members_of,
	members_next,
}

// It stops at a member `get_key` refuses (an array's, or an escaped key the arena could not hold), so
// `it.node < it.end` after the loop means it stopped early.
@(private)
members_next :: proc(it: ^Members) -> (k: string, n: Node, ok: bool) {
	if it.node >= it.end {
		return "", NO_NODE, false
	}
	k = get_key(it.doc, it.node) or_return
	n, _ = core_pkg.children_next(it)
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
//	- It allocates nothing but for a token with a `~` longer than 256 bytes, decoded in the document's
//	  allocator and freed before return; a refusal there answers `NO_NODE`.
@(require_results)
pointer :: proc(doc: ^Document, n: Node, ptr: string) -> Node {
	if !has(doc, n) || (ptr != "" && ptr[0] != '/') {
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
		#partial switch kd, _ := kind(doc, at); kd {
		case .Object:
			at = child(doc, at, token) if !escaped else pointer_member(doc, at, token)
		case .Array:
			index, count := 0, child_count(doc, at)
			for c in transmute([]u8)token {
				index = index * 10 + int(c - '0')
				if c < '0' || c > '9' || index >= count { return NO_NODE }
			}
			at = child(doc, at, index) if token != "" && (token[0] != '0' || token == "0") else NO_NODE
		case:
			return NO_NODE
		}
	}
	return at
}

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
