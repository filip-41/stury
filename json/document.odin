package json

// The document: a strictly validated source plus its decoded rows, and the reads that need no walk. The `get_*`
// readers' `ok` is false for a value of another kind or `NO_NODE`; `get_int` and `get_float` also answer false
// for a value that does not fit, and `get_string`/`get_key` when an escaped value's decode could not be
// allocated.
//
// `build` and `destroy` are in document_build.odin, the walks in document_walk.odin, and `query` in
// document_query.odin.

import "core:slice"
import "core:strings"
import "scan/walk"
import scan_pkg "scan"

// A handle to one value of a `Document`, valid while the document is.
Node :: walk.Node
// "No such value": what every lookup answers on a miss.
NO_NODE :: walk.NO_NODE
// The root value.
ROOT :: walk.ROOT

// A parsed JSON text: one row per value over your source bytes. Make one with `build` (or a `Request`'s
// `doc`) and read it through the procedures of this package; its fields are internal.
//
//	- `src` is borrowed and must outlive every read: a number is decoded from its text there at each read,
//	  and an escape-free string is a slice of it.
//	- Everything else is owned by whoever built it, and `destroy` is the only teardown.
//	- A JSONC document (`dialect == .Jsonc`) also holds its comments, each attached to a value.
Document :: struct {
	src:       []byte,
	// One row per value, in the order the values appear in `src`.
	rows:      [dynamic]walk.Row,
	// Escaped strings the `.Dom` scan decoded, addressed by the rows.
	values:    [dynamic]u8,
	// Escaped strings and keys decoded on demand; `keys` and `strings` cache them by node.
	arena:     scan_pkg.Name_Arena,
	keys:      map[Node]string,
	strings:   map[Node]string,
	// The member nodes of containers that `child` reached deep into by index; `member_at` has each run's start.
	members:   [dynamic]Node,
	member_at: map[Node]int,
	// The comments of a JSONC document.
	facts:     [dynamic]Fact,
	dialect:   Dialect,
	// Read under a `max_depth` past MAX_DEPTH, so it may nest deeper than `marshal` writes.
	deep:      bool,
}

// The kind of value `n`. `ok` is false, and the kind `.Null`, when `n` is no value, such as `NO_NODE`.
@(require_results)
kind :: #force_inline proc(doc: ^Document, n: Node) -> (k: Kind, ok: bool) {
	if !has(doc, n) {
		return .Null, false
	}
	return doc.rows[n].kind, true
}

// The integer number `n` writes, when it fits `i64` (`decode_span`'s `i64` arm). `-0` is 0, as `unmarshal`
// reads it into an integer. `ok` is also false for an integer past `max(i64)` and for a fraction or exponent
// notation (`get_number`).
@(require_results)
get_int :: #force_inline proc(doc: ^Document, n: Node) -> (v: i64, ok: bool) {
	if !has(doc, n) {
		return 0, false
	}
	return scan_pkg.dom_int(doc.rows[:], doc.src, n)
}

// The binary64 value of number `n`, correctly rounded. `ok` is also false for a number with no binary64
// value (`1e400`); `get_number` tells how the value relates to the authored one.
@(require_results)
get_float :: proc(doc: ^Document, n: Node) -> (v: f64, ok: bool) {
	num, is_number := get_number(doc, n)
	return num.value, is_number && num.exactness != .None
}

// The binary64 projection of number `n` and its `exactness` against the authored value.
//
//	- `ok` is false only where `n` is no number, so one past binary64's range (`1e400`) is `Number{0, .None}`
//	  (`value` +0, `.None`) with `ok` true, where `get_float` answers false.
//	- Decoded from the number's text at each call: a document keeps no number's value, so a reader that
//	  wants one many times keeps it itself.
//	- Inlined, so the decoding the caller does not read is dropped (`get_float` asks only whether there is a
//	  value).
@(require_results)
get_number :: #force_inline proc(doc: ^Document, n: Node) -> (v: Number, ok: bool) {
	if !has(doc, n) || doc.rows[n].kind != .Number {
		return {}, false
	}
	return scan_pkg.dom_number(doc.rows[:], doc.src, n), true
}

// The decoded text of string `n`, valid until `destroy`.
//
//	- Escape-free text is a slice of `doc.src`, escaped text is what the `.Dom` scan decoded, or, where it
//	  decoded nothing (a `.Nodes` scan), unescaped into the document's arena on the first read and kept.
//	- Reads of escaped strings a scan left undecoded write that arena, so on such a document they must not run
//	  on several threads at once. A `.Dom` build decoded every escaped string up front, so `get_string` writes
//	  nothing there and may run on any number of threads.
//	- The document is not otherwise read-only: `get_key` unescapes an escaped key into the arena and keeps it in
//	  `keys`, and `child_by_index` lists the members of a container it is asked past NTH_WALK of into `members`
//	  with `member_at` (document_walk.odin). Both write the document and allocate from its allocator, so neither
//	  belongs on several threads, nor do `query` and `pointer` (which allocate that allocator for a name or token
//	  longer than their stack scratch) nor the `children`/`members` walks, which read keys.
//	- `ok` is false for a value that is not a string, and when an escaped string's decode could not be
//	  allocated. A `.Dom` build decodes every escaped string up front, so its reads do not allocate.
@(require_results)
get_string :: #force_inline proc(doc: ^Document, n: Node) -> (s: string, ok: bool) #no_bounds_check {
	if has(doc, n) {
		r := &doc.rows[n]
		lo, hi := u64(r.lo), u64(r.hi)
		// The text is borrowed from `src`. The slice below is in range once `hi` is, and the quotes are checked
		// when no walk decoded the row.
		if r.kind == .String && .Str_Escaped not_in r.flags && hi >= lo + 2 && hi <= u64(len(doc.src)) &&
		   (.Decoded in r.flags || (doc.src[lo] == '"' && doc.src[hi - 1] == '"')) {
			return string(doc.src[lo + 1:hi - 1]), true
		}
	}
	return get_string_decoded(doc, n)
}

// Runs `get_string` for every value except an escape-free string.
@(private)
get_string_decoded :: #force_no_inline proc(doc: ^Document, n: Node) -> (s: string, ok: bool) {
	lazy := has(doc, n) && doc.rows[n].kind == .String &&
		doc.rows[n].flags & {.Str_Escaped, .Decoded} == {.Str_Escaped}
	if lazy {
		if s, ok = doc.strings[n]; ok {
			return
		}
	}
	b: []u8
	b, ok = scan_pkg.dom_get_string(doc.rows[:], doc.src, doc.values[:], &doc.arena, doc.rows.allocator, n)
	if ok && lazy {
		if doc.strings == nil {
			doc.strings.allocator = doc.rows.allocator
		}
		// A string the map cannot hold is decoded again on the next call.
		doc.strings[n] = string(b)
	}
	return string(b), ok
}

// The decoded key of member `n`: an escape-free key is a slice of `doc.src`, an escaped key is unescaped into the
// arena on the first read and kept in `keys`, a write and an allocation on any document, a `.Dom` build's
// included. Valid until `destroy`. `ok` is false when `n` is not an object's member, and when an escaped key's
// decode could not be allocated.
@(require_results)
get_key :: proc(doc: ^Document, n: Node) -> (s: string, ok: bool) {
	if s, ok = doc.keys[n]; ok {
		return
	}
	b: []u8
	b, ok = scan_pkg.dom_key(doc.rows[:], doc.src, &doc.arena, doc.rows.allocator, n)
	if ok && .Key_Escaped in doc.rows[n].flags {
		if doc.keys == nil {
			doc.keys.allocator = doc.rows.allocator
		}
		// A key the map cannot hold is decoded again on the next call.
		doc.keys[n] = string(b)
	}
	return string(b), ok
}

// The authored text of value `n`, a slice of `doc.src`: a string with its quotes, a container with its
// brackets and everything between. Nil for `NO_NODE`.
@(require_results)
get_raw :: proc(doc: ^Document, n: Node) -> []byte {
	if !has(doc, n) {
		return nil
	}
	return doc.src[doc.rows[n].lo:doc.rows[n].hi]
}

// The facts attached to `n`, sorted by place (`Fact_Place`) then source order. Empty for a JSON document.
@(require_results)
facts :: proc(doc: ^Document, n: Node) -> []Fact {
	all := doc.facts[:]
	lo, _ := slice.binary_search_by(all, n, proc(f: Fact, n: Node) -> slice.Ordering {
		return slice.cmp(f.node, n) if f.node != n else .Greater
	})
	hi := lo
	for hi < len(all) && all[hi].node == n {
		hi += 1
	}
	return all[lo:hi]
}

// The text of fact `f`, a slice of `doc.src`: a comment without its `//`, or its `/*` and `*/`.
@(require_results)
fact_text :: proc(doc: ^Document, f: Fact) -> string {
	text := string(doc.src[f.lo:f.hi])
	if strings.has_prefix(text, "/*") {
		return text[2:len(text) - 2]
	}
	return text[2:]
}

@(private)
has :: #force_inline proc(doc: ^Document, n: Node) -> bool {
	return walk.dom_has(doc.rows[:], n)
}

// The first member of container `n` in document order, or `NO_NODE`.
@(private)
first_child :: proc(doc: ^Document, n: Node) -> Node {
	return walk.dom_first_member(doc.rows[:], n)
}

// The stack scratch `pointer` decodes an escaped token into, and `query` a text path's quoted names: longer
// text takes the document's allocator.
@(private)
SCRATCH_BYTES :: 256
