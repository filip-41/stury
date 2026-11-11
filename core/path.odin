package core

import "base:intrinsics"
import "base:runtime"
import "core:strings"

// A path is a chain of steps from a value, spelled as jq text, as an RFC 6901 JSON Pointer, or as an Odin `Path` of step
// literals. Each spelling gives the same `Path`.

// The most steps a path holds, since `Path.optional` holds one bit per step.
MAX_STEPS :: 64
// The most paths one read holds, since the engine keeps a bit per path.
MAX_PATHS :: 64

// A member by its decoded key.
Name :: distinct string
// An element, negative from the end.
Index :: distinct int
// Every member or element.
All :: struct {}
// The elements from `lo` up to `hi`, each negative from the end, and `hi` nil for all the rest.
Slice :: struct {
	lo: int,
	hi: Maybe(int),
}
// The value and everything under it.
Descend :: struct {}
// A JSON Pointer token of digits, which names a member of an object and an element of an array.
Index_Or_Name :: struct {
	name:  string,
	index: int,
}

// A zero `Step` is a `Name` with no data pointer, which a read refuses as `Bad_Path`, so a path built with an unset step
// fails instead of reading an empty key. A name that is empty needs a data pointer, as every parsed one has.
Step :: union #no_nil {
	Name,
	Index,
	All,
	Slice,
	Descend,
	Index_Or_Name,
}

// `optional` holds a bit per step a `?` follows, and `limit` is the most answers the path gives, nil for no limit. `block`
// is the allocation behind a parsed path's steps and its decoded names, nil for a path of step literals. A parsed path
// borrows its text for every name that holds no escape.
Path :: struct {
	steps:     []Step,
	optional:  bit_set[0 ..< MAX_STEPS; u64],
	limit:     Maybe(int),
	block:     []u8,
	allocator: runtime.Allocator,
}

// A read's options. `dups` picks among a repeated key, and `.Refuse` builds the whole text. `stop_early` ends the walk
// once every answer is known, and what lies past that point is not judged. Under `.Last` an answer through a key is
// known at the close of the object holding it, so a read that should stop at the first matching key asks for `.First`.
Path_Options :: struct {
	dups:       Duplicates,
	stop_early: bool,
}

// What a query over a built document can honour of `Path_Options`. A built document holds no repeat that `.Refuse`
// would fail at, so a query reads it as `.Last`.
Query_Options :: struct {
	dups: Duplicates,
}

// What a read gives for a value it looks for: a path's answer, a member's or an element's. `Wrong_Kind` is a value a
// step cannot enter: a name of a value that is no map, a position of a value that is no array or positional record. A
// `null` takes both reads and holds nothing. `Not_Loaded` is the answer of a `Partial` container for what a read did
// not ask for: it may or may not be in the text, and no path answers it.
Presence :: enum u8 {
	Found,
	Missing,
	Wrong_Kind,
	Not_Loaded,
}

// What a path gives for one value it reaches. `node` is the value of a `.Found`, `NO_NODE` for the others. `owner` is the
// container holding a `.Found` value, `NO_NODE` for the root, the deepest container reached for a `.Missing`, and for
// a `.Wrong_Kind` the value a step could not enter. A null reads as `.Missing` where jq reads `.a` of it as null, and
// its owner is the container holding it, or the null at the root. A missing member with a `[]` still to come is a
// `.Wrong_Kind` naming the container that lacks it. `path` is the path's number in the read.
Answer :: struct {
	node:    Node_Index,
	owner:   Node_Index,
	path:    u32,
	outcome: Presence,
}

// What `each_answer` gives for one value a path reaches, with no document. `token` is the value's for a `.Found` and a
// `.Wrong_Kind`, and the closing token of the container that lacks it, or the null, for a `.Missing`. For a `.Found`,
// `lo` and `hi` are the value's authored span, `src[lo:hi]`, the bytes `span` gives for its node in every format, so a
// string's quotes and a quoted cell's quotes are inside it. For the other outcomes both are 0.
Token_Answer :: struct {
	token:   Token,
	lo, hi:  u64,
	path:    u32,
	outcome: Presence,
}

// The true position of a child a `Partial` container kept, for a container read by position. `Document.kept` holds these,
// sorted by node.
Kept_Child :: struct {
	node:  Node_Index,
	index: u32,
}

// A name a path asked `node` for and did not find. `Document.missing` holds these, sorted by node, and the names are
// copies in the document's reads block.
Missing_Name :: struct {
	node: Node_Index,
	name: string,
}


// Reads a member as `member` does, and on a `Partial` container tells a name a path looked for from one nobody asked for.
// A member kept by position was not looked for by name: past `.First` a repeat of its key may lie among what the read
// did not keep, so it is `Not_Loaded`.
member_of :: proc(doc: ^Document, obj: Node_Index, name: string, dups := Duplicates.Last) -> (Node_Index, Presence) {
	if int(obj) < len(doc.nodes) && doc.nodes[obj].kind != .Object && doc.nodes[obj].kind != .Null {
		return NO_NODE, .Wrong_Kind
	}
	v, ok := member(doc, obj, name, dups)
	partial := int(obj) < len(doc.nodes) && doc.nodes[obj].role == .Partial
	if ok {
		if partial && dups != .First && kept_index(doc, v) >= 0 {
			return NO_NODE, .Not_Loaded
		}
		return v, .Found
	}
	if !partial {
		return NO_NODE, .Missing
	}
	lo := lower_node(doc.missing, obj)
	for ; lo < len(doc.missing) && doc.missing[lo].node == obj; lo += 1 {
		if doc.missing[lo].name == name {
			return NO_NODE, .Missing
		}
	}
	return NO_NODE, .Not_Loaded
}

// Reads a member by position as `child_at` does, and on a `Partial` container tells a position past the end from a child
// that was not kept. A container a stopped read left open does not know its end. An `Object` answers by position only when
// the format's records are positional, as a dsv record is.
element_of :: proc(doc: ^Document, c: Node_Index, k: int) -> (Node_Index, Presence) {
	if int(c) < len(doc.nodes) {
		kind := doc.nodes[c].kind
		if kind != .Array && kind != .Null && !(kind == .Object && positional(doc)) {
			return NO_NODE, .Wrong_Kind
		}
	}
	if v, ok := child_at(doc, c, k); ok {
		return v, .Found
	}
	if int(c) < len(doc.nodes) && doc.nodes[c].role == .Partial && k >= 0 && (k < length(doc, c) || doc.stopped) {
		return NO_NODE, .Not_Loaded
	}
	return NO_NODE, .Missing
}

// Returns `length`, and whether it is the container's true count. A `Partial` container of a stopped read holds the
// count read so far.
length_exact :: proc(doc: ^Document, i: Node_Index) -> (n: int, exact: bool) {
	return length(doc, i), !(doc.stopped && int(i) < len(doc.nodes) && doc.nodes[i].role == .Partial)
}

// Returns the child of `Partial` container `i` at true position `k`, when it was kept.
@(private, cold)
kept_child :: #force_no_inline proc(doc: ^Document, i: Node_Index, k: int) -> (Node_Index, bool) {
	it := children(doc, i)
	for v in child_next(&it) {
		if kept_index(doc, v) == k {
			return v, true
		}
	}
	return NO_NODE, false
}

// Returns the true position `Document.kept` gives child `v`, -1 for a child kept by name.
@(private)
kept_index :: proc(doc: ^Document, v: Node_Index) -> int {
	at := lower_node(doc.kept, v)
	return int(doc.kept[at].index) if at < len(doc.kept) && doc.kept[at].node == v else -1
}

// Frees a parsed path's block and sets `p` to the zero value.
path_destroy :: proc(p: ^Path) {
	if p.block != nil {
		delete(p.block, p.allocator)
	}
	p^ = {}
}

// Reads jq path text: `.`, `.a`, `."a-b"`, `.["a-b"]`, `.[0]`, `.[-1]`, `.[]`, `.[2:5]`, `..` first in a path, `?` after
// any step, and the wrappers `first(P)` and `limit(N; P)`. A quoted name's escapes are a JSON string's, a lone surrogate
// escape and an ill-formed UTF-8 sequence are refused as in one, and its other bytes stand as written. Spaces may stand around the text and inside a
// wrapper, not inside a path. Text past this subset is refused, so a path means here what it means in jq. A bare name is
// a jq identifier. `.Bad_Path`'s `at` is a byte of `text`.
parse_path :: proc(text: string, allocator := context.allocator) -> (path: Path, err: Error) {
	parsed, refusal := parse(text, allocator, false)
	return parsed, error_of(refusal)
}

// Reads an RFC 6901 JSON Pointer: the empty text is the root, and each `/` starts a reference token, in which `~0` is `~`
// and `~1` is `/`, and an ill-formed UTF-8 sequence is refused. A token that is an array index by the RFC's rule, with no
// leading zero, is an `Index_Or_Name`.
parse_pointer :: proc(text: string, allocator := context.allocator) -> (path: Path, err: Error) {
	parsed, refusal := parse(text, allocator, true)
	return parsed, error_of(refusal)
}

// A copy of `steps` in `allocator`, with each name's text copied too.
steps_clone :: proc(steps: []Step, allocator := context.allocator) -> []Step {
	out := make([]Step, len(steps), allocator)
	for s, i in steps {
		if name, named := s.(Name); named {
			out[i] = Name(strings.clone(string(name), allocator))
		} else {
			out[i] = s
		}
	}
	return out
}
