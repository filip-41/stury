package json

// The document: a strictly validated source plus its rows, and its reads. The row document and every read of it
// are core's (core/row_document.odin, row_read.odin, row_walk.odin, row_query.odin); the procedures here forward to
// them under JSON's names. The `get_*` readers' `ok` is false for a value of another kind or `NO_NODE`;
// `get_int` and `get_float` also answer false for a value that does not fit, and `get_string`/`get_key` when an
// escaped value's decode could not be allocated. `build` and `destroy` are in document_build.odin.

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
//	- A document from `build` (a `.Dom` scan) is decoded: no read writes it, so any number of threads may read it
//	  at once. A `.Nodes` scan's decodes an escaped string or key on its first read and keeps it, and lists the
//	  members of a container `child` is asked deep into: one reader thread (`core.Document`).
//	- A JSONC or JSON5 document also holds its comments, each attached to a value. `marshal` writes a JSON5 one
//	  in JSON's spelling, comments kept, and refuses `Infinity` and `NaN` (`.Non_Finite`).
Document :: core_pkg.Document

// The kind of value `n`. `ok` is false, and the kind `.Null`, when `n` is no value, such as `NO_NODE`.
kind :: core_pkg.kind

// `true` or `false` for a boolean `n`.
get_bool :: core_pkg.get_bool

// The integer number `n` writes, when it fits `i64` (`decode_span`'s `i64` arm). `-0` is 0, as `unmarshal`
// reads it into an integer. `ok` is also false for an integer past `max(i64)` and for a fraction or exponent
// notation (`get_number`).
get_int :: core_pkg.get_int

// The binary64 value of number `n`, correctly rounded. `ok` is also false for a number with no binary64
// value (`1e400`); `get_number` tells how the value relates to the authored one.
get_float :: core_pkg.get_float

// The binary64 projection of number `n` and its `exactness` against the authored value.
//
//	- `ok` is false only where `n` is no number, so one past binary64's range (`1e400`) is `Number{0, .None}`
//	  (`value` +0, `.None`) with `ok` true, where `get_float` answers false.
//	- Decoded from the number's text at each call: a document keeps no number's value, so a reader that
//	  wants one many times keeps it itself.
get_number :: core_pkg.get_number

// The decoded text of string `n`, valid until `destroy`: escape-free text is a slice of `doc.src`, escaped text
// what the `.Dom` scan decoded or, on a `.Nodes` scan's document, unescaped into the document on the first read
// and kept. `ok` is false for a value that is not a string, and when an escaped string's decode could not be
// allocated.
get_string :: core_pkg.get_string

// The decoded key of member `n`, valid until `destroy`: an escaped key is unescaped by the build of a `.Dom`
// document, and on a `.Nodes` scan's document on its first read, and kept. `ok` is false when `n` is not an
// object's member, and when an escaped key's decode could not be allocated.
get_key :: core_pkg.get_key

// The authored text of value `n`, a slice of `doc.src`: a string with its quotes, a container with its
// brackets and everything between. Nil for `NO_NODE`.
get_raw :: core_pkg.get_raw

// Number `n`'s text in JSON's spelling: its authored text, or a dialect's own spelling respelled into
// `allocator` (a JSON5 hex integer as its decimal, a decimal without `+`, with a `0` before a leading point and
// none after a trailing one). False, with "", for a value JSON cannot spell (`Infinity`, `NaN`) and for any
// other kind.
@(require_results)
number_text :: proc(doc: ^Document, n: Node, allocator := context.allocator) -> (text: string, ok: bool) {
	if k, _ := kind(doc, n); k != .Number {
		return "", false
	}
	lit := string(core_pkg.get_raw(doc, n))
	if doc.rows[n].first_esc != core_pkg.SPELLED_NUMBER {
		return lit, true
	}
	out := make([dynamic]byte, allocator)
	if !scan_pkg.json5_number_json(lit, &out) {
		delete(out)
		return "", false
	}
	return string(out[:]), true
}

// The facts attached to `n`, sorted by place (`Fact_Place`) then source order. Empty for a JSON document.
facts :: core_pkg.facts

// The text of fact `f`, a slice of `doc.src`: a comment without its `//`, or its `/*` and `*/`.
@(require_results)
fact_text :: proc(doc: ^Document, f: Fact) -> string {
	text := string(doc.src[f.lo:f.hi])
	if strings.has_prefix(text, "/*") {
		return text[2:len(text) - 2]
	}
	return text[2:]
}

// A member of `n` by key (the last member whose key decodes to `name`, the reading of a path's default `.Last`)
// or by 0-based index, or `NO_NODE`; a negative index counts from the end (`-1` is the last member), as a path's
// `.[-1]` does. An array answers no key.
child :: proc {
	core_pkg.child_by_key,
	core_pkg.child_by_index,
}

// The member count of container `n`; zero on a scalar.
child_count :: core_pkg.child_count

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
//	- The walk stops at a key the document could not decode (`it.node < it.end` after the loop),
//	  and over an array yields nothing: an element has no key.
members :: proc {
	core_pkg.members_of,
	core_pkg.members_next,
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
pointer :: core_pkg.pointer

// Append to `out` the answers `path` gives in `doc` from node `n` (`query` from the root), in document order: the
// answers a `.Path` scan gives under the default `.Last`, each `node` the value in `doc`.
//
//	- At most `path.limit` values are found (0 is every one).
//	- `Name` is `child` by key (the last duplicate), `Index` counts from the end when negative, `Any` takes
//	  every member, an object's repeated key once, at its first place with its last value, as jq reads it.
//	- A path with no `Any` step that does not land appends one `.Missing` or `.Type_Mismatch` answer, owned by
//	  the container it missed in; a `per_element` path answers each element a step does not apply to; any
//	  other path that does not land appends nothing.
//	- An empty path is `n` itself, owned by the container holding it, and `NO_NODE` or a document with no
//	  root gives nothing.
//	- Text that does not parse is `.Bad_Path` at the byte the parser stopped on; a path of more than
//	  `MAX_PATH_STEPS` steps, text or a built `Path`, is `.Over_Capacity` with nothing appended, as the scan and
//	  the edits refuse it.
//	- `.Out_Of_Memory` is `out` refusing to grow; the answers appended before that stay.
//	- Besides `out` it allocates only for a text longer than 256 bytes with an escaped quoted name, and for
//	  the keys of an object past 16 members that `Any` reads, both in the document's allocator and freed
//	  before return; a refusal there is `.Out_Of_Memory` too.
query_in :: core_pkg.query_in

// `query_in` from the root.
query :: core_pkg.query

@(private)
has :: #force_inline proc(doc: ^Document, n: Node) -> bool {
	return core_pkg.dom_has(doc.rows[:], n)
}
