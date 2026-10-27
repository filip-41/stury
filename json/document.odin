package json

// The document: a strictly validated source plus its decoded rows, and the reads that need no walk. The `get_*`
// readers' `ok` is false for a value of another kind or `NO_NODE`; `get_int` and `get_float` also answer false
// for a value that does not fit, and `get_string`/`get_key` when an escaped value's decode could not be
// allocated.
//
// `build` and `destroy` are in document_build.odin, the walks in document_walk.odin, and `query` in
// document_query.odin. The row tree and its format-free readers are core's (core/row_document.odin); this
// package decodes the rows' strings, keys and numbers.

import "core:strings"
import core_pkg "../core"
import scan_pkg "scan"

// A handle to one value of a `Document`, valid while the document is.
Node :: core_pkg.Node
// "No such value": what every lookup answers on a miss.
NO_NODE :: core_pkg.NO_NODE
// The root value.
ROOT :: core_pkg.ROOT

// A parsed JSON text: one row per value over your source bytes. Make one with `build` (or a `Request`'s
// `doc`) and read it through the procedures of this package; its fields are internal.
//
//	- `src` is borrowed and must outlive every read: a number is decoded from its text there at each read,
//	  and an escape-free string is a slice of it.
//	- Everything else is owned by whoever built it, and `destroy` is the only teardown.
//	- A JSONC or JSON5 document (`dialect != .Json`) also holds its comments, each attached to a value.
//	  `marshal` writes a JSON5 one in JSON's spelling, comments kept, and refuses `Infinity` and `NaN`
//	  (`.Non_Finite`).
Document :: core_pkg.Row_Document

// The kind of value `n`. `ok` is false, and the kind `.Null`, when `n` is no value, such as `NO_NODE`.
@(require_results)
kind :: #force_inline proc(doc: ^Document, n: Node) -> (k: Kind, ok: bool) {
	return core_pkg.kind(doc, n)
}

// The integer number `n` writes, when it fits `i64` (`decode_span`'s `i64` arm). `-0` is 0, as `unmarshal`
// reads it into an integer. `ok` is also false for an integer past `max(i64)` and for a fraction or exponent
// notation (`get_number`).
@(require_results)
get_int :: #force_inline proc(doc: ^Document, n: Node) -> (v: i64, ok: bool) {
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
//	  on several threads at once. A `.Dom` build decodes every escaped string up front, so its `get_string`
//	  writes nothing and may run on any number of threads.
//	- The document is not otherwise read-only: `get_key` unescapes an escaped key into the arena and keeps it in
//	  `keys`, and `child_by_index` lists the members of a container it is asked past NTH_WALK of into `members`
//	  with `member_at` (core/row_document.odin). Both write the document and allocate from its allocator, so neither
//	  belongs on several threads, nor do `query` and `pointer` (which allocate from it for a name or token
//	  longer than their stack scratch) nor the `children`/`members` walks, which read keys.
//	- `ok` is false for a value that is not a string, and when an escaped string's decode could not be
//	  allocated.
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
	if !has(doc, n) || doc.rows[n].kind != .String {
		return "", false
	}
	r := doc.rows[n]
	escaped := .Str_Escaped in r.flags
	if .Decoded in r.flags {
		return string(doc.values[r.payload.str.off:][:r.payload.str.len] if escaped else doc.src[r.lo + 1:r.hi - 1]), true
	}
	if doc.cache != nil {
		if s, ok = doc.cache.strings[n]; ok {
			return
		}
	}
	b: []u8
	b, ok = scan_pkg.dom_span_text(doc, u64(r.lo), u64(r.hi), escaped, u64(r.first_esc))
	if ok && escaped {
		// A string the map cannot hold is decoded again on the next call.
		doc.cache.strings[n] = string(b)
	}
	return string(b), ok
}

// The decoded key of member `n`, valid until `destroy`. An escaped key is unescaped into the arena on the first
// read and kept in the cache (`Row_Cache`): a write and an allocation on any document, a `.Dom` build's included. `ok` is false
// when `n` is not an object's member, and when an escaped key's decode could not be allocated.
@(require_results)
get_key :: #force_inline proc(doc: ^Document, n: Node) -> (s: string, ok: bool) {
	if !has(doc, n) || doc.rows[n].key_lo == core_pkg.NO_KEY {
		return "", false
	}
	r := &doc.rows[n]
	if .Key_Escaped not_in r.flags {
		b: []u8
		b, ok = scan_pkg.dom_span_text(doc, u64(r.key_lo), u64(r.key_hi), false, 0)
		return string(b), ok
	}
	return get_key_escaped(doc, n)
}

// Runs `get_key` for an escaped key, which is kept.
@(private = "file")
get_key_escaped :: #force_no_inline proc(doc: ^Document, n: Node) -> (s: string, ok: bool) {
	if doc.cache != nil {
		if s, ok = doc.cache.keys[n]; ok {
			return
		}
	}
	r := doc.rows[n]
	b: []u8
	b, ok = scan_pkg.dom_span_text(doc, u64(r.key_lo), u64(r.key_hi), true, 0)
	if ok {
		// A key the map cannot hold is decoded again on the next call.
		doc.cache.keys[n] = string(b)
	}
	return string(b), ok
}

// The authored text of value `n`, a slice of `doc.src`: a string with its quotes, a container with its
// brackets and everything between. Nil for `NO_NODE`.
@(require_results)
get_raw :: proc(doc: ^Document, n: Node) -> []byte {
	return core_pkg.get_raw(doc, n)
}

// The facts attached to `n`, sorted by place (`Fact_Place`) then source order. Empty for a JSON document.
@(require_results)
facts :: proc(doc: ^Document, n: Node) -> []Fact {
	return core_pkg.facts(doc, n)
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
	return core_pkg.dom_has(doc.rows[:], n)
}

// The stack scratch `pointer` decodes an escaped token into: a longer one takes the document's allocator.
@(private)
SCRATCH_BYTES :: 256
