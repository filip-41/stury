// `build` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
#+private
package json

import "base:intrinsics"
import "base:runtime"
import core "../core"
import compose "../core/compose"
import build "../core/build"
import typed "../core/typed"
import write "../core/write"

// JSON's document holds the walk's tokens over the caller's bytes, read through core's readers and JSON's handles.
// `build` is the only entry, and it runs the walk and the builder together.

// JSON's handles, one per spec, which only `as` names. A handle's readers are the readers a constant build of its spec
// holds, and its services the walks of that spec, so a call through a handle never switches on the spec. The tables
// hold pointers to the bound tables, so they are set at startup and never written after.
HANDLES := [Spec]core.Readers {
	.Json  = core.with_services(readers_of(.Json)^, &SERVICES[.Json]),
	.Jsonc = core.with_services(readers_of(.Jsonc)^, &SERVICES[.Jsonc]),
	.Json5 = core.with_services(readers_of(.Json5)^, &SERVICES[.Json5]),
}

SERVICES := [Spec]core.Services {
	.Json  = handle_services(.Json),
	.Jsonc = handle_services(.Jsonc),
	.Json5 = handle_services(.Json5),
}

handle_services :: proc "contextless" ($S: Spec) -> core.Services {
	return {
		build    = proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
			return build_spec(src, S, as, refuse_duplicates, allocator)
		},
		validate = edit_of(S).validate,
		scan     = proc(src: []u8, as: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (core.Document, core.Path_Error) {
			return scan_spec(src, S, as, paths, read, state, on, allocator)
		},
		write    = write_text,
		edit     = edit_of(S),
		plans    = rawptr(plan_as),
		reads    = checks_of(S),
		tokens   = &TOKENS,
		records  = framing_of(S),
		docs     = record_docs(S),
	}
}

// JSON's fault table, which names the format whatever the spec.
rules_of :: proc "contextless" () -> ^core.Rules {
	return &RULES
}

// A number's kind fits core's kind bits and leaves bit 0 (`SPELLING_DECODE`) clear.
#assert(u16(Number_Spelling.Nan) & core.SPELLING_DECODE == 0)
#assert(u16(Number_Spelling.Nan) <= core.NUMBER_KIND_MASK)
#assert(u16(Number_Spelling.Decimal) == core.NUMBER_DECIMAL)

// Reads `src` as spec `S` into a document that holds the handle `handle`, allocating nodes and facts with `allocator`.
build_spec :: proc(src: []u8, $S: Spec, handle: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	opts := options_of(handle)
	// `walk` passes over record separators before a document for streams. A built document is one text, so a 0x1E
	// crossed by the shared pre-document run is the bad byte `validate` refuses.
	q, sep := document_start(src, 0, S)
	if sep != nil {
		return {}, sep_error(src, sep)
	}
	// Every node takes two bytes of the text but an open container that stays open, which takes one: a closed container
	// its brackets, a key its colon, and a scalar its comma or its parent's close. A walk faults at the first byte past
	// a token, so the last token may be missing its second byte. So a text makes at most `(len(src) + 1 + depth) / 2`
	// nodes, the hooks test no capacity, and `builder_end` returns the unused tail.
	depth := core.reserve_depth(opts.max_depth, len(src))
	doc, err := build_reserved(src, q, S, handle, refuse_duplicates, allocator, (len(src) + depth) / 2 + 16, min(depth, core.MAX_DEPTH), 0)
	if err.kind != .No_Memory {
		return doc, err
	}
	// The allocator refused the bound, or a fact growth. Reading the text again sizes every buffer exactly, so only a
	// document that does not fit the allocator fails.
	count: build.Count
	regs: core.Hook_Regs
	walk_from(src, q, S, opts, &count, &regs, build.builder_hook_count)
	return build_reserved(src, q, S, handle, refuse_duplicates, allocator, count.nodes, count.deepest, count.facts)
}

// The fault of the record separator at `sep`, which a text that is one document may not hold before its value.
sep_error :: proc(src: []u8, sep: [^]u8) -> core.Document_Error {
	at := u64(intrinsics.ptr_sub(sep, raw_data(src)))
	return {kind = .Walk, at = at, inner = {at = at, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Control_Char)}}
}

// Reads the document that starts at `q` into a builder with room for `nodes` nodes and `facts` facts, which must cover
// every node the walk reaches, and a stack of `depth` open containers, which grows as the text nests past it.
build_reserved :: proc(src: []u8, q: [^]u8, $S: Spec, handle: core.As, refuse_duplicates: bool, allocator: runtime.Allocator, nodes, depth, facts: int) -> (core.Document, core.Document_Error) {
	opts := options_of(handle)
	// The edit services dispatch on the handle's spec and read at its depth. The open containers' stack is this frame's
	// when it holds `depth`, so a build allocates none and an arena that keeps the document keeps none.
	frames: [core.MAX_DEPTH]u64 = ---
	b := build.builder_start(src, handle, refuse_duplicates, allocator, nodes, depth, facts, frames[:])
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
		fault = core.Fault{at = u64(len(src)), rules = &RULES, kind = .Truncated}
	}
	return build.builder_end(&b, regs, fault)
}

// Returns the byte just past container `i`'s closing bracket. The root uses `root_close`, otherwise the document keeps
// no close node, so it starts after the last descendant's own bytes (after the open when the container is empty), skips
// each descendant container's close on the rightmost spine, then the container's own. Cold: only a nested span read
// calls it.
@(cold)
close_end_spec :: proc(doc: ^core.Document, i: core.Node_Index, $S: Spec) -> u64 {
	if i == core.ROOT && doc.root_close != 0 {
		return doc.root_close
	}
	n := doc.nodes[i]
	if doc.partial {
		return close_by_walk(doc, n.lo, S)
	}
	end := int(i) + int(n.n)
	p := n.lo + 1
	if end > int(i) + 1 {
		last := end - 1
		m := doc.nodes[last]
		if m.kind == .Array || m.kind == .Object {
			// The last node of a subtree is a scalar or an empty container, whose close is its open plus one.
			p = m.lo + 1
		} else {
			_, p = core.scalar_ends(m)
		}
	}
	// Every container whose subtree ends here is on the rightmost spine, and its close is the next one to skip.
	closes := 0
	for j := int(i) + 1; j < end; {
		m := doc.nodes[j]
		if m.kind != .Array && m.kind != .Object {
			j += 1
		} else if j + int(m.n) == end {
			closes += 1
			j += 1
		} else {
			j += int(m.n)
		}
	}
	for _ in 0 ..< closes {
		p = skip_to_close(doc.src, p, S)
		p += 1
	}
	p = skip_to_close(doc.src, p, S)
	if p < u64(len(doc.src)) {
		p += 1
	}
	return p
}

// Returns the byte past the container at `lo`, by walking it. The nodes of a partial document do not reach a container's
// last descendant. The walk tolerates every fault, since a tolerance changes no container's end and the read may have
// tolerated any. A stopped read may leave text no walk judged, where this returns the fault's byte.
@(cold)
close_by_walk :: proc(doc: ^core.Document, lo: u64, $S: Spec) -> u64 {
	regs: core.Hook_Regs
	none: core.No_Hooks
	hi: u64
	fault: Maybe(core.Fault)
	opts := Options{max_depth = doc.as.max_depth, tolerate = {.Invalid_Utf8, .Lone_Surrogate}}
	hi, fault = walk(doc.src, lo, S, opts, &none, &regs, core.no_hook)
	if f, bad := fault.?; bad {
		return f.at
	}
	return hi
}

// Returns the first byte at or past `p` that is no whitespace, comment or trailing comma, where a container's span
// ends. JSON has neither a comment nor a trailing comma. `comment_run` reads the bytes as spec `spec`, the spec the
// document was built as, since a JSON5 `//` comment ends at U+2028 and U+2029 and a JSONC one does not. The walk
// already judged these bytes, so the fault is ignored.
skip_to_close :: proc(src: []u8, p: u64, $S: Spec) -> u64 {
	q: [^]u8
	when S == .Json {
		q = skip_ws(raw_data(src)[p:], raw_data(src)[len(src):])
	} else {
		q, _, _ = comment_run(raw_data(src)[p:], raw_data(src)[len(src):], true, S)
	}
	return u64(intrinsics.ptr_sub(q, raw_data(src)))
}

// Checks that `src` is one value of spec `S` for an edit at depth `depth`, the document's `max_depth`, where 0 means
// the default. No comment may follow the last token, since a splice would put the next bytes inside it. Only a text's
// first byte may be a byte-order mark, so a value that begins with one is refused here as it would be at any later
// byte.
edit_value :: proc(src: []u8, _: runtime.Allocator, depth: u32, $S: Spec) -> core.Document_Error {
	if len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF {
		return {kind = .Bad_Value}
	}
	// Strict JSON has no fact, so a value that validates is the whole text and the check needs no hook.
	when S == .Json {
		h: core.No_Hooks
		regs: core.Hook_Regs
		if f, bad := walk_text(src, 0, S, {max_depth = depth}, &h, &regs, core.no_hook).?; bad {
			return {kind = .Bad_Value, inner = f}
		}
		return {}
	} else {
		c: Value_Check
		regs: core.Hook_Regs
		// A record separator before the value is no part of it.
		q, sep := document_start(src, 0, S)
		if sep != nil {
			return {kind = .Bad_Value}
		}
		hi, fault, _ := walk_from(src, q, S, {max_depth = depth}, &c, &regs, value_check_hook)
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
}

// `Value_Check` holds what `value_check_hook` records. It has whether a value was found, whether a fact follows it, and
// the value's depth in a container.
Value_Check :: struct {
	depth: int,
	done:  bool,
	after: bool,
}

value_check_hook :: proc "contextless" (h: ^Value_Check, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if h.done && t.role > .Key {
		h.after = true
	}
	switch t.kind {
	case .Array, .Object:
		h.depth += 1
	case .End:
		h.depth -= 1
		if h.depth == 0 {
			h.done = true
		}
	case .Null, .False, .True, .Number, .String, .Bytes, .Plain:
		if h.depth == 0 {
			h.done = true
		}
	}
	return s, .Next
}

// Writes `name` as a JSON string in `text`, with the quotes and escapes every JSON spec reads. A control byte is
// written as `\u00xx`, so the key reads the same in JSON, JSONC and JSON5. False when the allocation fails or `name`
// is not UTF-8.
edit_key_text :: proc(_: ^core.Document, name: []u8, text: ^[dynamic]u8) -> bool {
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, text.allocator)
	spelled, err := write.finish(&out, {kind = put_string(&out, string(name))})
	defer delete(spelled, text.allocator)
	if err.kind != .None {
		return false
	}
	_, appended := append(text, ..spelled)
	return appended == nil
}

// Returns JSON's comment spelling for `spec`. It is `//` for the specs whose grammar has comments, and none for
// strict JSON. A line body holding a line end is written as a block comment, so the spec's line ends are the only
// shape rule.
edit_separators :: proc(doc: ^core.Document, spec: u8) -> bool {
	return Spec(spec) == .Json5 && Spec(doc.as.spec) != .Json5
}

edit_comment :: proc(doc: ^core.Document, spec: u8) -> (core.Comment_Spelling, u8) {
	return .Line if Spec(spec) == .Jsonc || Spec(spec) == .Json5 else .None, 0
}
