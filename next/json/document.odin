package json

import "base:intrinsics"
import "base:runtime"
import core "../core"

// JSON's document holds the walk's tokens over the caller's bytes, read through core's readers and JSON's `SPELLING`.
// `build` is the only entry, and it runs the walk and the builder together.

// `EDIT` holds JSON's edit services, cold. The same table serves every spec, since a spec differs only in the text it
// accepts as an edit. Each service dispatches on `doc.spec`.
@(private, rodata)
EDIT := core.Edit_Spelling {
	value      = edit_value_at,
	key        = edit_key_at,
	reads      = edit_reads_at,
	comment    = edit_comment,
	member_sep = ",",
	key_sep    = ":",
}

// `SPELLING` holds JSON's spelling services, in rodata, the same table for every spec, for a caller that knows no
// format. `text` and `number` are the procedures a direct caller calls, and `key_equals` reaches core's key rule, so a
// caller that knows this format calls `key_equals` directly and inlines that rule. The same reader serves every spec,
// since a JSON token holds no form that only JSON5 reads. The document holds the spec because an edit's text is judged
// by it. A comment or an identifier is a value or a key only in the spec that accepts it.
@(private)
SPELLING := core.Spelling {
	text = text, key_equals = key_equals_decode, number = number,
	resolve = spelling_resolve, close_end = close_end, edit = &EDIT,
}

// No field of a number's spelling reaches bit 0 or bit 15. Every kind value is even, so bit 0 (`SPELLING_DECODE`) is
// clear, and the counts and `NUMBER_EXP` stay below bit 15.
#assert(u16(Number_Spelling.Nan) & core.SPELLING_DECODE == 0)
#assert(u16(Number_Spelling.Nan) <= NUMBER_KIND_MASK)
#assert(NUMBER_INT_SHIFT + 5 <= 15)
#assert(NUMBER_FRAC_SHIFT + 5 <= 15)
#assert(NUMBER_EXP < 1 << 15)
#assert(u16(Number_Spelling.Nan) < 1 << 15)

// Reads `src` as spec `S` into a document, allocating nodes and facts with `allocator`. `dups` is a build option.
// `.Refuse` fails at a key that repeats one of its object's, and every other value builds every member. The document
// borrows `src`, which must outlive it, and `core.destroy` frees it. On an error the document is the zero value.
build :: proc(src: []u8, $S: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Document_Error) {
	// `walk` passes over record separators before a document for streams. A built document is one text, so a 0x1E
	// crossed by the shared pre-document run is the bad byte `validate` refuses.
	p := raw_data(src)
	q, sep := document_start(src, 0, S)
	if sep != nil {
		at := u64(intrinsics.ptr_sub(sep, p))
		return {}, {kind = .Walk, at = at, inner = {at = at, rules = &RULES, kind = .Bad_Char}}
	}
	// A JSON text makes at most one token per byte, so `len(src)` is the reservation bound, and the depth stack is
	// `max(MAX_DEPTH, opts.max_depth)`. Neither buffer grows during the build.
	b := core.builder_start(src, &SPELLING, dups, allocator, 1, max(MAX_DEPTH, int(opts.max_depth)))
	// A reservation of one node per text byte is 16 bytes per byte, and an allocator with less room refuses a text
	// whose few nodes would fit many times over. Only that refusal reaches here, and the retry reserves one node per
	// 8 bytes.
	retry := len(b.doc.nodes) == 0 && b.err.kind == .No_Memory
	if retry {
		b = core.builder_start(src, &SPELLING, dups, allocator, 8, max(MAX_DEPTH, int(opts.max_depth)))
	}
	if len(b.doc.nodes) == 0 {
		// The reservation was refused, so no hook may run over a nil node array.
		doc, err := core.builder_end(&b, core.BUILDER_REGS, nil)
		return doc, err
	}
	// The edit dispatcher reads `doc.spec`.
	b.doc.spec = u8(S)
	regs := core.BUILDER_REGS
	// A spec with no comments makes no fact token, so its build uses the hook without fact and pending work.
	hi: u64
	fault: Maybe(core.Fault)
	stopped: bool
	when .Comments in FEATURES[S] {
		if retry {
			hi, fault, stopped = walk_from(src, q, S, opts, &b, &regs, core.builder_hook_checked)
		} else {
			hi, fault, stopped = walk_from(src, q, S, opts, &b, &regs, core.builder_hook)
		}
	} else {
		// The plain hook keeps the open container's index and child count in `s.b`, and the depth in `s.c`.
		regs.b = u64(core.NO_NODE) << 32
		regs.c = 0
		// `.Refuse` selects a separate hook, so the hook a usual build runs has no duplicate-key test.
		switch {
		case retry:
			hi, fault, stopped = walk_from(src, q, S, opts, &b, &regs, core.builder_hook_plain_checked)
		case dups == .Refuse:
			hi, fault, stopped = walk_from(src, q, S, opts, &b, &regs, core.builder_hook_plain_refuse)
		case:
			hi, fault, stopped = walk_from(src, q, S, opts, &b, &regs, core.builder_hook_plain)
		}
	}
	if fault == nil && !stopped {
		fault = tail_fault(src, hi, S)
	}
	// A text with no value is no document. A stream may hold one, a built document does not.
	if fault == nil && regs.a == 0 {
		fault = core.fault_of(core.fault_at(u64(len(src)), .Truncated), &RULES)
	}
	return core.builder_end(&b, regs, fault)
}

// Returns the byte just past container `i`'s closing bracket. The document keeps no close node, so it starts after
// the last descendant's own bytes (after the open when the container is empty), skips each descendant container's
// close on the rightmost spine, then the container's own. Cold: only a span read or the writer's splice calls it.
@(private, cold)
close_end :: proc(doc: ^core.Document, i: u32) -> u64 {
	n := doc.nodes[i]
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
	for j := int(i) + 1; j < end; j += 1 {
		m := doc.nodes[j]
		if (m.kind == .Array || m.kind == .Map) && j + int(m.n) == end {
			closes += 1
		}
	}
	for _ in 0 ..< closes {
		p = skip_to_close(doc.src, p)
		p += 1
	}
	p = skip_to_close(doc.src, p)
	if p < u64(len(doc.src)) {
		p += 1
	}
	return p
}

// Returns the first byte at or past `p` that is no whitespace, comment or trailing comma, where a container's span
// ends. The walk already judged these bytes, so the fault from `comment_run` is ignored.
@(private)
skip_to_close :: proc(src: []u8, p: u64) -> u64 {
	q, _, _ := comment_run(raw_data(src)[p:], raw_data(src)[len(src):], true, .Json5)
	return u64(intrinsics.ptr_sub(q, raw_data(src)))
}

// Checks that `src` is one value of spec `S` for an edit. No comment may follow the last token, since a splice would
// put the next bytes inside it. Only a text's first byte may be a byte-order mark, so a value that begins with one is
// refused here as it would be at any later byte.
@(private)
edit_value :: proc(src: []u8, _: runtime.Allocator, $S: Spec) -> core.Document_Error {
	if len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF {
		return {kind = .Bad_Value}
	}
	c: Value_Check
	regs: core.Hook_Regs
	hi, fault := walk(src, 0, S, {}, &c, &regs, value_check_hook)
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

// Checks that `src` is one key of spec `S` for an edit. The text is read as the only member of an object around it,
// and its token must cover the whole text, so a text with its own trivia is no key.
@(private)
edit_key :: proc(src: []u8, allocator: runtime.Allocator, $S: Spec) -> core.Document_Error {
	buf, err := make([]u8, len(src) + 4, allocator)
	if err != nil {
		return {kind = .No_Memory}
	}
	defer delete(buf, allocator)
	buf[0] = '{'
	copy(buf[1:], src)
	buf[len(src) + 1] = ':'
	buf[len(src) + 2] = '0'
	buf[len(src) + 3] = '}'
	k: Key_Check
	regs: core.Hook_Regs
	_, fault := walk(buf, 0, S, {}, &k, &regs, key_check_hook)
	if f, bad := fault.?; bad {
		return {kind = .Bad_Key, inner = f}
	}
	if k.n != 4 || k.tokens[0].kind != .Map || k.tokens[1].role != .Key || k.tokens[3].kind != .End {
		return {kind = .Bad_Key}
	}
	t := k.tokens[1]
	lo, hi := t.lo, t.lo + u64(t.n)
	if t.spelling & core.SPELLING_QUOTED != 0 {
		lo -= 1
		hi += 1
	}
	if lo != 1 || hi != u64(len(src)) + 1 {
		return {kind = .Bad_Key}
	}
	return {}
}

@(private)
Key_Check :: struct {
	tokens: [4]core.Token,
	n:      int,
}

@(private)
key_check_hook :: proc "contextless" (h: ^Key_Check, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if h.n < len(h.tokens) { h.tokens[h.n] = t }
	h.n += 1
	return s, .Next
}

// Reads `src` as spec `S` with or without the tolerance set a build may hold. The commit's check policy reads the
// output strictly, then tolerantly, then the source.
@(private)
edit_reads :: proc(doc: ^core.Document, src: []u8, tolerate: bool, $S: Spec) -> (core.Fault, bool) {
	t: bit_set[Tolerance; u8]
	if tolerate { t = {.Invalid_Utf8, .Lone_Surrogate} }
	return validate(src, S, {tolerate = t}).?
}

// The three services dispatch on `doc.spec`, since a proc pointer carries no compile-time spec.
@(private)
edit_value_at :: proc(doc: ^core.Document, src: []u8, allocator: runtime.Allocator) -> core.Document_Error {
	switch Spec(doc.spec) {
	case .Json:  return edit_value(src, allocator, .Json)
	case .Jsonc: return edit_value(src, allocator, .Jsonc)
	case .Json5: return edit_value(src, allocator, .Json5)
	}
	return {kind = .Bad_Value}
}

@(private)
edit_key_at :: proc(doc: ^core.Document, src: []u8, allocator: runtime.Allocator) -> core.Document_Error {
	switch Spec(doc.spec) {
	case .Json:  return edit_key(src, allocator, .Json)
	case .Jsonc: return edit_key(src, allocator, .Jsonc)
	case .Json5: return edit_key(src, allocator, .Json5)
	}
	return {kind = .Bad_Key}
}

@(private)
edit_reads_at :: proc(doc: ^core.Document, src: []u8, tolerate: bool, spec: u8) -> (core.Fault, bool) {
	switch Spec(spec) {
	case .Json:  return edit_reads(doc, src, tolerate, .Json)
	case .Jsonc: return edit_reads(doc, src, tolerate, .Jsonc)
	case .Json5: return edit_reads(doc, src, tolerate, .Json5)
	}
	return {}, true
}

// Returns JSON's comment spelling for `spec`. It is `//` for the specs whose grammar has comments, and none for
// strict JSON. A line body holding a line end is written as a block comment, so the spec's line ends are the only
// shape rule.
@(private)
edit_comment :: proc(doc: ^core.Document, spec: u8) -> (core.Comment_Spelling, u8) {
	switch Spec(spec) {
	case .Json:
		return .None, 0
	case .Jsonc, .Json5:
		return .Line, 0
	}
	return .None, 0
}
