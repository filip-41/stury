// `build` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
package json

import "base:intrinsics"
import "base:runtime"
import core "../core"
import compose "../core/compose"
import build "../core/build"
import write "../core/write"

// JSON's document holds the walk's tokens over the caller's bytes, read through core's readers and JSON's `SPELLING`.
// `build` is the only entry, and it runs the walk and the builder together.

// `EDIT` holds JSON's edit services, cold. The same table serves every spec, since a spec differs only in the text it
// accepts as an edit. Each service dispatches on `doc.as.spec`.
@(private, rodata)
EDIT := core.Edit_Spelling {
	value      = edit_value_at,
	key_text   = edit_key_text,
	comment    = edit_comment,
	member_sep = proc(_: ^core.Document) -> string {return ","},
	key_sep    = ":",
	commit     = proc(list: ^core.Edit_List, spec: u8, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
		return compose.commit(list, spec, nil, allocator)
	},
}

// `SPELLING` holds JSON's spelling services, in rodata, the same table for every spec, for a caller that knows no
// format. `text` and `number` are the procedures a direct caller calls, and `key_equals` reaches core's key rule. The
// same reader serves every spec, since a JSON token holds no form that only JSON5 reads. The document holds the spec
// because an edit's text is judged by it. A comment or an identifier is a value or a key only in the spec that
// accepts it.
@(private)
SPELLING := core.Spelling {
	text = text, key_equals = key_equals_decode, number = number, build = build_as, validate = validate_as, scan = scan_as,
	resolve = spelling_resolve, close_end = close_end, query = build.query, edit = &EDIT, write = write_text, tokens = &TOKENS, records = &RECORDS,
	tag_key = "json", key_open = "\"", key_close = "\":",
}

// A number's spelling leaves bit 0 (`SPELLING_DECODE`) and bit 15 clear.
#assert(u16(Number_Spelling.Nan) & core.SPELLING_DECODE == 0)
#assert(u16(Number_Spelling.Nan) <= core.NUMBER_KIND_MASK)
#assert(core.NUMBER_INT_SHIFT + 5 <= 15)
#assert(core.NUMBER_FRAC_SHIFT + 5 <= 15)
#assert(core.NUMBER_EXP < 1 << 15)
#assert(u16(Number_Spelling.Nan) < 1 << 15)

// Reads `src` as spec `spec` into a document, as `core.build` does with `as(spec, opts)`.
build :: #force_inline proc(src: []u8, spec: Spec, opts := Options{}, refuse_duplicates := false, allocator := context.allocator) -> (core.Document, core.Document_Error) {
	return core.build(src, as(spec, opts), refuse_duplicates, allocator)
}

// The handle's build: the walk compiled for the handle's spec.
@(private)
build_as :: proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	switch Spec(as.spec) {
	case .Json:  return build_spec(src, .Json, options_of(as), refuse_duplicates, allocator)
	case .Jsonc: return build_spec(src, .Jsonc, options_of(as), refuse_duplicates, allocator)
	case .Json5: return build_spec(src, .Json5, options_of(as), refuse_duplicates, allocator)
	}
	return {}, {kind = .Bad_Spec}
}

// Reads `src` as spec `S` into a document, allocating nodes and facts with `allocator`.
@(private)
build_spec :: proc(src: []u8, $S: Spec, opts: Options, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	// `walk` passes over record separators before a document for streams. A built document is one text, so a 0x1E
	// crossed by the shared pre-document run is the bad byte `validate` refuses.
	p := raw_data(src)
	q, sep := document_start(src, 0, S)
	if sep != nil {
		at := u64(intrinsics.ptr_sub(sep, p))
		return {}, {kind = .Walk, at = at, inner = {at = at, rules = &RULES, kind = .Bad_Char}}
	}
	// Every node takes two bytes of the text but an open container that stays open, which takes one: a closed container
	// its brackets, a key its colon, and a scalar its comma or its parent's close. A walk faults at the first byte past
	// a token, so the last token may be missing its second byte. So a text makes at most `(len(src) + 1 + depth) / 2`
	// nodes, the hooks test no capacity, and `builder_end` returns the unused tail.
	depth := core.reserve_depth(opts.max_depth, len(src))
	doc, err := build_reserved(src, q, S, opts, refuse_duplicates, allocator, (len(src) + depth) / 2 + 16, depth, 0)
	if err.kind != .No_Memory {
		return doc, err
	}
	// The allocator refused the bound, or a fact growth. Reading the text again sizes every buffer exactly, so only a
	// document that does not fit the allocator fails.
	count: build.Count
	regs: core.Hook_Regs
	walk_from(src, q, S, opts, &count, &regs, build.builder_hook_count)
	return build_reserved(src, q, S, opts, refuse_duplicates, allocator, count.nodes, count.deepest, count.facts)
}

// Reads the document that starts at `q` into a builder with room for `nodes` nodes, `depth` open containers and `facts`
// facts, which must cover every node and open container the walk reaches.
@(private)
build_reserved :: proc(src: []u8, q: [^]u8, $S: Spec, opts: Options, refuse_duplicates: bool, allocator: runtime.Allocator, nodes, depth, facts: int) -> (core.Document, core.Document_Error) {
	// The edit services dispatch on the handle's spec and read at its depth. The open containers' stack is this frame's
	// when it holds `depth`, so a build allocates none and an arena that keeps the document keeps none.
	frames: [core.MAX_DEPTH]u64 = ---
	b := build.builder_start(src, as(S, opts), refuse_duplicates, allocator, nodes, depth, facts, frames[:])
	if len(b.doc.nodes) == 0 {
		// The reservation was refused, so no hook may run over a nil node array.
		return build.builder_end(&b, build.BUILDER_REGS, nil)
	}
	regs := build.BUILDER_REGS
	// A spec with no comments makes no fact token, so its build uses the hook without fact and pending work.
	hi: u64
	fault: Maybe(core.Fault)
	stopped: bool
	when .Comments in FEATURES[S] {
		hi, fault, stopped = walk_from(src, q, S, opts, &b, &regs, build.builder_hook)
	} else {
		// A build that refuses repeats selects a separate hook, so the hook a usual build runs has no duplicate-key
		// test.
		if refuse_duplicates {
			hi, fault, stopped = walk_from(src, q, S, opts, &b, &regs, build.builder_hook_plain_refuse)
		} else {
			hi, fault, stopped = walk_from(src, q, S, opts, &b, &regs, build.builder_hook_plain)
		}
	}
	// A spec with comments walks past a comment after the root, so its `hi` is no close and `close_end` scans for it.
	when .Comments not_in FEATURES[S] {
		b.root_close = hi
	}
	if fault == nil && !stopped {
		fault = tail_fault(src, hi, S)
	}
	// A text with no value is no document. A stream may hold one, a built document does not.
	if fault == nil && regs.a == 0 {
		fault = core.fault_of(core.fault_at(u64(len(src)), .Truncated), &RULES)
	}
	return build.builder_end(&b, regs, fault)
}

// Returns the byte just past container `i`'s closing bracket. The root uses `root_close`, otherwise the document keeps
// no close node, so it starts after the last descendant's own bytes (after the open when the container is empty), skips
// each descendant container's close on the rightmost spine, then the container's own. Cold: only a nested span read
// calls it.
@(private, cold)
close_end :: proc(doc: ^core.Document, i: core.Node_Index) -> u64 {
	if i == core.ROOT && doc.root_close != 0 {
		return doc.root_close
	}
	spec := Spec(doc.as.spec)
	n := doc.nodes[i]
	if doc.partial {
		return close_by_walk(doc, n.lo, spec)
	}
	end := int(i) + int(n.n)
	p := n.lo + 1
	if end > int(i) + 1 {
		last := end - 1
		m := doc.nodes[last]
		if m.kind == .Array || m.kind == .Map {
			// The last node of a subtree is a scalar or an empty container, whose close is its open plus one.
			p = m.lo + 1
		} else if m.kind == .String && m.spelling & core.SPELLING_QUOTED != 0 {
			p = m.lo + u64(m.n) + 1
		} else {
			p = m.lo + u64(m.n)
		}
	}
	// Every container whose subtree ends here is on the rightmost spine, and its close is the next one to skip.
	closes := 0
	for j := int(i) + 1; j < end; {
		m := doc.nodes[j]
		if m.kind != .Array && m.kind != .Map {
			j += 1
		} else if j + int(m.n) == end {
			closes += 1
			j += 1
		} else {
			j += int(m.n)
		}
	}
	for _ in 0 ..< closes {
		p = skip_to_close(doc.src, p, spec)
		p += 1
	}
	p = skip_to_close(doc.src, p, spec)
	if p < u64(len(doc.src)) {
		p += 1
	}
	return p
}

// Returns the byte past the container at `lo`, by walking it. The nodes of a partial document do not reach a container's
// last descendant. The walk tolerates every fault, since a tolerance changes no container's end and the read may have
// tolerated any. A stopped read may leave text no walk judged, where this returns the fault's byte.
@(private, cold)
close_by_walk :: proc(doc: ^core.Document, lo: u64, spec: Spec) -> u64 {
	regs: core.Hook_Regs
	none: core.No_Hooks
	hi: u64
	fault: Maybe(core.Fault)
	opts := Options{max_depth = doc.as.max_depth, tolerate = {.Invalid_Utf8, .Lone_Surrogate}}
	switch spec {
	case .Json:  hi, fault = walk(doc.src, lo, .Json, opts, &none, &regs, core.no_hook)
	case .Jsonc: hi, fault = walk(doc.src, lo, .Jsonc, opts, &none, &regs, core.no_hook)
	case .Json5: hi, fault = walk(doc.src, lo, .Json5, opts, &none, &regs, core.no_hook)
	}
	if f, bad := fault.?; bad {
		return f.at
	}
	return hi
}

// Returns the first byte at or past `p` that is no whitespace, comment or trailing comma, where a container's span
// ends. `comment_run` reads the bytes as spec `spec`, the spec the document was built as, since a JSON5 `//` comment
// ends at U+2028 and U+2029 and a JSONC one does not. The walk already judged these bytes, so the fault is ignored.
@(private)
skip_to_close :: proc(src: []u8, p: u64, spec: Spec) -> u64 {
	q: [^]u8
	switch spec {
	case .Json:  q, _, _ = comment_run(raw_data(src)[p:], raw_data(src)[len(src):], true, .Json)
	case .Jsonc: q, _, _ = comment_run(raw_data(src)[p:], raw_data(src)[len(src):], true, .Jsonc)
	case .Json5: q, _, _ = comment_run(raw_data(src)[p:], raw_data(src)[len(src):], true, .Json5)
	case:        return p
	}
	return u64(intrinsics.ptr_sub(q, raw_data(src)))
}

// Checks that `src` is one value of spec `S` for an edit at depth `depth`, the document's `max_depth`, where 0 means
// the default. No comment may follow the last token, since a splice would put the next bytes inside it. Only a text's
// first byte may be a byte-order mark, so a value that begins with one is refused here as it would be at any later
// byte.
@(private)
edit_value :: proc(src: []u8, _: runtime.Allocator, depth: u32, $S: Spec) -> core.Document_Error {
	if len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF {
		return {kind = .Bad_Value}
	}
	c: Value_Check
	regs: core.Hook_Regs
	hi, fault := walk(src, 0, S, {max_depth = depth}, &c, &regs, value_check_hook)
	if f, bad := fault.?; bad {
		return {kind = .Bad_Value, inner = f}
	}
	if f, bad := tail_fault(src, hi, S).?; bad {
		return {kind = .Bad_Value, inner = f}
	}
	// No value, or a fact after it, since a comment there would swallow what a splice puts after the value.
	if !c.done || c.after {
		return {kind = .Bad_Value}
	}
	return {}
}

// `Value_Check` holds what `value_check_hook` records. It has whether a value was found, whether a fact follows it, and
// the value's depth in a container.
@(private)
Value_Check :: struct {
	depth: int,
	done:  bool,
	after: bool,
}

@(private)
value_check_hook :: proc "contextless" (h: ^Value_Check, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if h.done && t.role > .Key {
		h.after = true
	}
	switch t.kind {
	case .Array, .Map:
		h.depth += 1
	case .End:
		h.depth -= 1
		if h.depth == 0 {
			h.done = true
		}
	case .Null, .False, .True, .Number, .String, .Plain:
		if h.depth == 0 {
			h.done = true
		}
	}
	return s, .Next
}

// Writes `name` as a JSON string in `text`, with the quotes and escapes every JSON spec reads. A control byte is
// written as `\u00xx`, so the key reads the same in JSON, JSONC and JSON5. False when the allocation fails or `name`
// is not UTF-8.
@(private)
edit_key_text :: proc(_: ^core.Document, name: []u8, text: ^[dynamic]u8) -> bool {
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, text.allocator)
	kind := put_string(&out, string(name))
	spelled, err := write.finish(&out)
	defer delete(spelled, text.allocator)
	if kind != .None || err.kind != .None {
		return false
	}
	_, appended := append(text, ..spelled)
	return appended == nil
}

// The value check dispatches on `doc.as.spec`, since a proc pointer carries no compile-time spec.
@(private)
edit_value_at :: proc(doc: ^core.Token_View, src: []u8, allocator: runtime.Allocator) -> core.Document_Error {
	switch Spec(doc.spec) {
	case .Json:  return edit_value(src, allocator, doc.max_depth, .Json)
	case .Jsonc: return edit_value(src, allocator, doc.max_depth, .Jsonc)
	case .Json5: return edit_value(src, allocator, doc.max_depth, .Json5)
	}
	return {kind = .Bad_Value}
}

// Returns JSON's comment spelling for `spec`. It is `//` for the specs whose grammar has comments, and none for
// strict JSON. A line body holding a line end is written as a block comment, so the spec's line ends are the only
// shape rule.
@(private)
edit_comment :: proc(doc: ^core.Document, spec: u8) -> (core.Comment_Spelling, u8) {
	return .Line if Spec(spec) == .Jsonc || Spec(spec) == .Json5 else .None, 0
}

// Writes `list`'s edits as spec `as`, returning the text the caller frees with `allocator`. A text of another spec
// must read strictly, since the source's reading under its own spec is no evidence. A delimited document is another
// format family and is refused before the splice.
commit :: proc(list: ^core.Edit_List, as: Spec, allocator := context.allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
	if list.doc != nil && list.doc.spelling != nil && core.is_flat(list.doc) {
		return nil, 0, {kind = .Bad_Spec}
	}
	return compose.commit(list, u8(as), nil, allocator)
}
