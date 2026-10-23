package json

// The document: a strictly validated source plus its decoded rows, and every procedure that reads one. The `get_*`
// readers' `ok` is false for a value of another kind or `NO_NODE`; `get_int` and `get_float` also answer false
// for a value that does not fit, and `get_string`/`get_key` when an escaped value's decode could not be
// allocated.

import "base:runtime"
import "core:slice"
import "core:strings"
import core_pkg "../core"
import "scan/walk"
import scan_pkg "scan"

// A handle to one value of a `Document`, valid while the document is.
Node :: walk.Node
// "No such value": what every lookup answers on a miss.
NO_NODE :: walk.NO_NODE
// The root value.
ROOT :: walk.ROOT

// A parsed JSON text: one row per value over your source bytes. Make one with `build` (or a `Request`'s
// `doc`) and read it through the procedures in this file; its fields are internal.
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

// Validate `src` at `.Strict` and decode every value onto a row, allocating with `allocator`. The result is
// exactly a `Request({.Dom})` scan's rows.
//
//	- Numbers are the exception: a number is checked and its digits counted here, and decoded when it is
//	  read (`get_number`).
//	- `duplicates == .Last`, the default, builds every member, as the rows hold them. `child` by key reads
//	  the last.
//	- `.Refuse` refuses a key that, decoded, repeats one of its own object's (`.Duplicate_Key` at the
//	  repeat). Keys past the first 64 open at once are remembered in `allocator`, and a refusal there is
//	  `.Out_Of_Memory`.
//
// `err` is a document fault or one of `build`'s own, with `Document` the zero value.
//
//	.Source_Too_Wide  `src` is longer than row offsets (u32) address. `offset` is that limit, the first
//	                  position a row could not address. Refused before any byte is read.
//	.Out_Of_Memory    the allocator refused a row or a decoded string. `offset` is 0, the scan goes on
//	                  past a refused append to reach the result, so no one byte is where it failed.
//	.Bad_Option       `duplicates` is `.First` or `.All`, which choose among a path's answers, and a
//	                  document has none, or `.Refuse` in a build with `-define:REFUSE_DUPLICATES=false`.
//	                  `offset` is 0, refused before any byte is read.
@(require_results)
build :: proc(
	src: []byte,
	allocator := context.allocator,
	limits := Limits{},
	dialect := Dialect.Json,
	duplicates := Duplicates.Last,
) -> (doc: Document, err: Maybe(Error)) {
	if duplicates == .First || duplicates == .All {
		return {}, Error{kind = .Bad_Option}
	}
	req: Request({.Dom})
	req.allocator = allocator
	req.limits = limits
	req.dialect = dialect
	req.duplicates = duplicates
	switch e in scan(src, &req) {
	case Error:
		err = e
	case Request_Error:
		// The request is fresh and holds no paths. A capacity it can hit is the source's width, and any other
		// refusal is of an option, `.Refuse` in a build without it.
		#partial switch e.kind {
		case .Over_Capacity: err = Error{kind = .Source_Too_Wide, offset = MAX_ROW_SOURCE}
		case .Out_Of_Memory: err = Error{kind = .Out_Of_Memory}
		case:                err = Error{kind = .Bad_Option}
		}
	}
	if err == nil {
		doc = req.doc
		req.doc = {}
	}
	request_destroy(&req)
	return
}

// Free everything an owner holds, and empty it. Strings read from a document dangle after it.
destroy :: proc {
	document_destroy,
	request_destroy,
	type_plan_destroy,
	reader_destroy,
}

@(private)
document_destroy :: proc(doc: ^Document) {
	delete(doc.rows)
	delete(doc.values)
	delete(doc.keys)
	delete(doc.strings)
	delete(doc.members)
	delete(doc.member_at)
	delete(doc.facts)
	walk.name_arena_destroy(&doc.arena)
	doc^ = {}
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
//	- `ok` is false only where `n` is no number, so one past binary64's range (`1e400`) is the zero `Number`
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
//	- Reads of escaped strings a scan left undecoded write that arena, so on such a document they must not
//	  run on several threads at once. Every other read writes nothing, so an `.Eager` `build`'s strings may
//	  be read from any number of threads.
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

// The decoded key of member `n`: an escape-free key is a slice of `doc.src`, an escaped key is unescaped
// into the arena once and kept, as `get_string` keeps a string, under the same caveat. Valid until
// `destroy`. `ok` is false when `n` is not an object's member, and when an escaped key's decode could not
// be allocated.
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

// A member of `n` by key or by 0-based index, or `NO_NODE`; a negative index counts from the end (`-1` is
// the last member), as a path's `.[-1]` does.
child :: proc {
	child_by_key,
	child_by_index,
}

// The last member of object `n` whose key decodes to `name`, or `NO_NODE`. An array answers none. The same
// reading as a path's default `.Last`.
@(private, require_results)
child_by_key :: proc(doc: ^Document, n: Node, name: string) -> Node {
	return walk.dom_find_key(doc.rows[:], doc.src, n, name, &scan_pkg.FORMAT_HOOKS)
}

// Member `i` of container `n`, 0-based (from the end when negative), or `NO_NODE`. O(1) over an array of
// scalars, and over any other container once a call has reached NTH_WALK members into it, which lists its
// members once.
@(private, require_results)
child_by_index :: proc(doc: ^Document, n: Node, index: int) -> Node {
	i := index
	if i < 0 {
		i += child_count(doc, n)
		if i < 0 {
			return NO_NODE
		}
	}
	if i == 0 {
		return first_child(doc, n)
	}
	if i < NTH_WALK || i >= child_count(doc, n) || walk.dom_flat_array(doc.rows[n]) {
		return walk.dom_nth_member(doc.rows[:], n, i)
	}
	at, listed := doc.member_at[n]
	if !listed {
		at, listed = list_members(doc, n)
		if !listed {
			return walk.dom_nth_member(doc.rows[:], n, i)
		}
	}
	return doc.members[at + i]
}

// How many members `child_by_index` steps over before it lists a container's members: past that, a walk
// per call made reading every member by index quadratic.
@(private = "file")
NTH_WALK :: 64

// List the members of container `n` in `members`, and where they start; false when the allocator refused,
// or a refused append left the container short of rows, and nothing is kept.
@(private = "file")
list_members :: proc(doc: ^Document, n: Node) -> (at: int, ok: bool) {
	if doc.members.allocator.procedure == nil {
		doc.members.allocator = doc.rows.allocator
		doc.member_at.allocator = doc.rows.allocator
	}
	at = len(doc.members)
	count := child_count(doc, n)
	if reserve(&doc.members, at + count) != nil {
		return
	}
	it := members_of(doc, n)
	for j in children_next(&it) {
		append(&doc.members, j)
	}
	if len(doc.members) - at != count {
		resize(&doc.members, at)
		return
	}
	if map_insert(&doc.member_at, n, at) == nil {
		resize(&doc.members, at)
		return
	}
	return at, true
}

// The member count of container `n`; zero on a scalar.
@(require_results)
child_count :: proc(doc: ^Document, n: Node) -> int {
	return walk.dom_child_count(doc.rows[:], n)
}

// The position of a walk over one container's members (`children`, `members`). A value, owning nothing; it
// borrows the document. A member's run of rows ends where the next begins, so a step is one add, bounded by
// the container's end (`end`).
Members :: struct {
	doc:  ^Document,
	node: Node,
	end:  Node,
}

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
	members_of,
	children_next,
}

// Every member of an object in order, as `children` but with each member's decoded key.
//
//	- `members(&doc, n)` starts the walk, and `members(&it)` gives the next key and value.
//	- A key is borrowed from the document.
//	- The walk stops at a key the document's arena could not decode (`it.node < it.end` after the loop),
//	  and over an array yields nothing: an element has no key.
members :: proc {
	members_of,
	members_next,
}

@(private, require_results)
members_of :: proc(doc: ^Document, n: Node) -> Members {
	first := first_child(doc, n)
	if first == NO_NODE {
		return {doc = doc}
	}
	return {doc = doc, node = first, end = n + Node(doc.rows[n].subtree_size)}
}

@(private, require_results)
children_next :: #force_inline proc(it: ^Members) -> (n: Node, ok: bool) {
	if it.node >= it.end {
		return NO_NODE, false
	}
	n = it.node
	it.node += Node(it.doc.rows[n].subtree_size)
	return n, true
}

// It stops at a member `get_key` refuses (an array's, or an escaped key the arena could not hold), so
// `it.node < it.end` after the loop means it stopped early.
@(private)
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

// The stack scratch `pointer` decodes an escaped token into, and `query` a text path's quoted names: longer
// text takes the document's allocator.
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

// Append to `out` every value `path` reaches from `n`, in document order: the values a `.Path` scan finds
// under the default `.Last`.
//
//	- At most `path.limit` values are appended (0 is every one).
//	- `Name` is `child` by key (the last duplicate), `Index` counts from the end when negative, `Any` takes
//	  every member, an object's repeated key once, at its first place with its last value, as jq reads it,
//	  and a step that does not land yields nothing.
//	- An empty path is `n` itself, and `NO_NODE` reaches nothing.
//	- Text that does not parse is its `Parse_Fault`; a path of more than `MAX_PATH_STEPS` steps, text or a
//	  built `Path`, is `.Out_Of_Room` with nothing appended, as the scan and the edits refuse it.
//	- `.Out_Of_Room` is also `out` refusing to grow; the values appended before that stay.
//	- Besides `out` it allocates only for a text longer than 256 bytes with an escaped quoted name, and for
//	  the keys of an object past QUERY_SMALL members that `Any` reads, both in the document's allocator and
//	  freed before return; a refusal there is `.Out_Of_Room` too.
@(require_results)
query :: proc(doc: ^Document, n: Node, path: Path_Spec, out: ^[dynamic]Node) -> (err: Maybe(Parse_Fault)) {
	steps: [core_pkg.MAX_PATH_STEPS]Step
	stack: [SCRATCH_BYTES]u8 = ---
	text, is_text := path.(string)
	heap := len(text) > len(stack) && strings.index_byte(text, '\\') >= 0
	names := make([]u8, len(text), doc.rows.allocator) if heap else stack[:]
	if names == nil {
		return Parse_Fault{error = .Out_Of_Room}
	}
	defer if heap {
		delete(names, doc.rows.allocator)
	}
	p, _ := path.(Path)
	if is_text {
		p = parse_path(text, steps[:], names) or_return
	} else if len(p.steps) > core_pkg.MAX_PATH_STEPS {
		return Parse_Fault{error = .Out_Of_Room}
	}
	if !has(doc, n) {
		return nil
	}
	w := Query_Walk{doc = doc, mode = .Last, out = out, left = p.limit if p.limit > 0 else max(int)}
	if !query_from(&w, n, NO_NODE, p.steps) {
		return Parse_Fault{error = .Out_Of_Room}
	}
	return nil
}

// A path's walk over a document: the values reached go to `out`, each beside the container it was met in (`NO_NODE`
// for the root) when `holders` is not nil, until `left` more are wanted. `mode` is the occurrence of a repeated
// key that answers. With `outcomes`, the walk answers as a `per_element` path does: a step that does not apply
// is an answer too, `NO_NODE` in `out` beside the container that lacks its member or holds the value it met,
// and `outcomes` holds each answer's `Path_Outcome`.
@(private)
Query_Walk :: struct {
	doc:      ^Document,
	mode:     Duplicates,
	out:      ^[dynamic]Node,
	holders:  ^[dynamic]Node,
	outcomes: ^[dynamic]Path_Outcome,
	left:     int,
}

@(private)
query_from :: proc(w: ^Query_Walk, n, holder: Node, steps: []Step) -> bool {
	if w.left <= 0 {
		return true
	}
	doc := w.doc
	if len(steps) == 0 {
		return query_out(w, n, holder, .Found)
	}
	kd, _ := kind(doc, n)
	switch s in steps[0] {
	case Name:
		if kd != .Object {
			return query_fail(w, n, holder, steps, false, kd)
		}
		if w.mode == .Last {
			next := child(doc, n, string(s))
			if next == NO_NODE {
				return query_fail(w, n, holder, steps, true, kd)
			}
			return query_from(w, next, n, steps[1:])
		}
		it := members_of(doc, n)
		hit := false
		for k, c in members(&it) {
			if k != string(s) {
				continue
			}
			hit = true
			query_from(w, c, n, steps[1:]) or_return
			if w.mode == .First {
				return true
			}
		}
		if it.node < it.end {
			return false
		}
		return hit || query_fail(w, n, holder, steps, true, kd)
	case Index:
		if kd != .Array {
			return query_fail(w, n, holder, steps, false, kd)
		}
		next := child(doc, n, int(s))
		if next == NO_NODE {
			return query_fail(w, n, holder, steps, true, kd)
		}
		return query_from(w, next, n, steps[1:])
	case Any:
		if kd != .Object && kd != .Array {
			return query_fail(w, n, holder, steps, false, kd)
		}
		if kd == .Object && w.mode != .All {
			return query_distinct(w, n, steps[1:])
		}
		it := children(doc, n)
		for c in children(&it) {
			query_from(w, c, n, steps[1:]) or_return
		}
	}
	return true
}

// One answer, `n` met in `holder` (`NO_NODE` for a step that does not apply, under `outcomes`).
@(private = "file")
query_out :: proc(w: ^Query_Walk, n, holder: Node, outcome: Path_Outcome) -> bool {
	if _, err := append(w.out, n); err != nil {
		return false
	}
	if w.holders != nil {
		if _, err := append(w.holders, holder); err != nil {
			return false
		}
	}
	if w.outcomes != nil {
		if _, err := append(w.outcomes, outcome); err != nil {
			return false
		}
	}
	w.left -= 1
	return true
}

// `steps[0]` does not apply at `n`, a `met` held in `holder`: it `missed` its member or element there, or `n` is
// another kind. Nothing, but for a `per_element` walk (`outcomes`), which answers it as the scan does.
@(private = "file")
query_fail :: proc(w: ^Query_Walk, n, holder: Node, steps: []Step, missed: bool, met: Kind) -> bool {
	if w.outcomes == nil {
		return true
	}
	return query_out(w, NO_NODE, n if missed else holder, walk.per_element_outcome(steps, missed, met))
}

// The members of object `n` that `Any` reads, `steps` next: a repeated key once, at its first place, with the
// first member's value under `.First` and the last's under `.Last`.
@(private = "file")
query_distinct :: proc(w: ^Query_Walk, n: Node, steps: []Step) -> bool {
	doc := w.doc
	count := child_count(doc, n)
	small: [QUERY_SMALL]Node
	names: [QUERY_SMALL]string
	picked := small[:]
	seen: map[string]int
	big := count > QUERY_SMALL
	defer if big {
		delete(picked, doc.rows.allocator)
		delete(seen)
	}
	if big {
		err: runtime.Allocator_Error
		if picked, err = make([]Node, count, doc.rows.allocator); err != nil {
			return false
		}
		if seen, err = make(map[string]int, count, doc.rows.allocator); err != nil {
			return false
		}
	}
	kept := 0
	it := members_of(doc, n)
	for k, c in members(&it) {
		at := -1
		if big {
			at = seen[k] - 1
		} else {
			for i in 0 ..< kept {
				if names[i] == k {
					at = i
					break
				}
			}
		}
		if at < 0 {
			picked[kept] = c
			if big {
				seen[k] = kept + 1
			} else {
				names[kept] = k
			}
			kept += 1
		} else if w.mode == .Last {
			picked[at] = c
		}
	}
	if it.node < it.end {
		return false
	}
	for c in picked[:kept] {
		query_from(w, c, n, steps) or_return
	}
	return true
}

// The members `query_distinct` tells apart on the stack; an object with more keeps them in a map.
@(private = "file")
QUERY_SMALL :: 16

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

@(private = "file")
has :: #force_inline proc(doc: ^Document, n: Node) -> bool {
	return walk.dom_has(doc.rows[:], n)
}

// The first member of container `n` in document order, or `NO_NODE`.
@(private)
first_child :: proc(doc: ^Document, n: Node) -> Node {
	return walk.dom_first_member(doc.rows[:], n)
}
