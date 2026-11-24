package build

import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// A scan of a text in pieces copies the bytes it keeps out of each window when the window ends. The caller may drop a
// window once the walk is past it, and the document reads the copied bytes as `.Held`. Tokens arrive in text order, so
// the nodes, facts and coming key a window added are those from offset `Scanner.hold_from` on.

// Copies out of window `text` (indexed by the text's offsets) the authored span of each key and scalar node, each fact
// and the coming key that the walk produced since the last hold. `regs` are the hook's registers at the window's end.
scanner_hold :: proc(h: ^Scanner, regs: hook.Regs, text: []u8) -> runtime.Allocator_Error {
	h.holds = true
	if h.scattered {
		return hold_whole(h, text)
	}
	nodes := h.b.doc.nodes[:builder_cursor(&h.b, regs)]
	facts := h.b.doc.facts
	k, j := len(nodes), len(facts)
	for k > 0 && (nodes[k - 1].lo >= h.hold_from || hold_named(h, nodes[k - 1])) {
		k -= 1
	}
	for j > 0 && facts[j - 1].lo >= h.hold_from {
		j -= 1
	}
	for {
		t, ok := hold_next(h, nodes, facts, &k, &j)
		if !ok {
			break
		}
		if t.lo >= h.hold_from {
			// The head's bytes are where the keys are read from, which may lie before the window.
			from := h.key_text if t.kind == .End && t.lo == h.head[0] && u64(t.n) == h.head[1] - h.head[0] else text
			head, tail := hold_bounds(h, from, t)
			// A span of no bytes past its offset, as an empty string's of a binary format, shares its offset with the
			// token after it, and is held once.
			empty := u64(t.n) + u64(tail) == 0
			if empty && len(h.held) > 0 && h.held[len(h.held) - 1].lo == t.lo - u64(head) {
				continue
			}
			append(&h.held, tape.Held_Span{t.lo - head, u64(len(h.bytes))}) or_return
			append(&h.bytes, ..from[t.lo - head:t.lo + u64(t.n) + tail]) or_return
			h.hold_from = t.lo if empty else t.lo + 1
		}
	}
	if len(h.bytes) > 2 * h.held_live + HOLD_SLACK {
		return hold_drop(h, nodes, facts)
	}
	return nil
}

// Holds the text of a scan whose tokens are out of text order: its bytes from `h.hold_from`, where its first token is,
// up to the end of `text`, which one span names, each window adding the bytes past those held.
@(private)
hold_whole :: proc(h: ^Scanner, text: []u8) -> runtime.Allocator_Error {
	if len(h.held) == 0 {
		append(&h.held, tape.Held_Span{h.hold_from, 0}) or_return
	}
	if held := h.held[0].lo + u64(len(h.bytes)); u64(len(text)) > held {
		append(&h.bytes, ..text[held:]) or_return
	}
	return nil
}

// `scanner_hold` drops the bytes of tokens the scan no longer keeps when `h.bytes` exceeds twice `h.held_live` (the
// bytes live after the last drop) plus this many bytes.
@(private)
HOLD_SLACK :: 4096

// Returns the next token in text order among the nodes from index `k^`, the facts from index `j^`, the coming key and
// `h.head`, and advances the index it came from. On equal offsets the order is node, fact, coming key, head. A fact and
// the head come back as a token of kind `.End`. Container nodes hold no bytes and are skipped, and so are the keys
// `hold_named` names. False when none is left.
@(private)
hold_next :: proc "contextless" (h: ^Scanner, nodes: []tape.Node, facts: []tape.Fact, k, j: ^int) -> (tape.Token, bool) #no_bounds_check {
	for k^ < len(nodes) && (nodes[k^].kind > .Plain || hold_named(h, nodes[k^])) {
		k^ += 1
	}
	key := h.key.lo if h.has_key && h.key.lo >= h.hold_from && !hold_named(h, h.key) else max(u64)
	node := nodes[k^].lo if k^ < len(nodes) else max(u64)
	fact := facts[j^].lo if j^ < len(facts) else max(u64)
	head := h.head[0] if h.head[1] > h.head[0] && h.head[0] >= h.hold_from else max(u64)
	switch {
	case node == max(u64) && fact == max(u64) && key == max(u64) && head == max(u64):
		return {}, false
	case node <= fact && node <= key && node <= head:
		k^ += 1
		return nodes[k^ - 1], true
	case fact <= key && fact <= head:
		j^ += 1
		return {lo = fact, n = facts[j^ - 1].n, kind = .End}, true
	case key <= head:
		return h.key, true
	}
	return {lo = head, n = u32(h.head[1] - head), kind = .End}, true
}

// Whether `t` is a key with no bytes of its own to hold: one inside `h.head`, up to its last byte, held with it, or one
// named by its place.
@(private)
hold_named :: #force_inline proc "contextless" (h: ^Scanner, t: tape.Token) -> bool {
	return t.role == .Key && (t.spelling & tape.SPELLING_PLACED != 0 && t.kind == .String || h.head[1] > h.head[0] && t.lo - h.head[0] <= h.head[1] - h.head[0])
}

// The authored bytes before (`head`) and after (`tail`) token `t`'s own span, as the format's `bounds` gives them. A
// fact (kind `.End`) has none, its span is all of it.
@(private)
hold_bounds :: #force_inline proc "contextless" (h: ^Scanner, src: []u8, t: tape.Token) -> (head, tail: u64) {
	if t.kind == .End {
		return 0, 0
	}
	a, b := h.b.doc.format.bounds(src, t)
	return u64(a), u64(b)
}

// Rebuilds `h.held` and `h.bytes` with only the spans of the nodes, facts and coming key the scan still keeps. A scan
// that takes elements back drops their nodes, which leaves held bytes no node reads.
@(private, cold)
hold_drop :: proc(h: ^Scanner, nodes: []tape.Node, facts: []tape.Fact) -> runtime.Allocator_Error {
	held := make([dynamic]tape.Held_Span, 0, len(h.held), h.held.allocator) or_return
	bytes, err := make([dynamic]u8, 0, h.held_live + HOLD_SLACK, h.bytes.allocator)
	if err != nil {
		delete(held)
		return err
	}
	kept := false
	defer if !kept {
		delete(held)
		delete(bytes)
	}
	from := h.hold_from
	h.hold_from = 0
	defer h.hold_from = from
	span := -1
	k, j := 0, 0
	for {
		t, ok := hold_next(h, nodes, facts, &k, &j)
		if !ok || t.lo >= from {
			break
		}
		// With `hold_from` past `t`, `hold_next` returns the coming key once only, as in `scanner_hold`.
		h.hold_from = t.lo + 1
		for span + 1 < len(h.held) && h.held[span + 1].lo <= t.lo {
			span += 1
		}
		if span < 0 || len(held) > 0 && held[len(held) - 1].lo == h.held[span].lo {
			continue
		}
		hi := h.held[span + 1].at if span + 1 < len(h.held) else u64(len(h.bytes))
		append(&held, tape.Held_Span{h.held[span].lo, u64(len(bytes))}) or_return
		append(&bytes, ..h.bytes[h.held[span].at:hi]) or_return
	}
	delete(h.held)
	delete(h.bytes)
	h.held, h.bytes, h.held_live, kept = held, bytes, len(bytes), true
	return nil
}

// Returns the document of the answers a scan of a text in pieces has so far, as `builder_so_far` does for a build.
// Containers read only in part are marked `CONTAINER_PARTIAL` and every byte read is held. `regs` are the hook's
// registers at the cut and `cut` is the offset where more bytes are needed. The scan is unchanged and goes on.
@(require_results)
scanner_so_far :: proc(h: ^Scanner, regs: hook.Regs, cut: u64, allocator: runtime.Allocator) -> (doc: tape.Document, err: tape.Error) {
	read, rerr := make([]u64, regs.c, allocator)
	if e := took(rerr, raw_data(read), int(regs.c)); e != nil {
		return {}, e
	}
	defer delete(read, allocator)
	b := regs.b
	for c := regs.c; c > 0; c -= 1 {
		// A level past `h.frames` is inside a container the scan keeps whole, and its count is the builder's.
		read[c - 1] = h.frames[c - 1].count if int(c) <= len(h.frames) else u64(u32(b))
		b = h.b.stack[c - 1]
	}
	doc = builder_so_far(&h.b, regs, cut, allocator, read) or_return
	defer if err != nil {
		tape.destroy(&doc)
	}
	answers := slice.clone(h.answers[:], allocator) or_return
	defer delete(answers, allocator)
	missing := slice.clone(h.missing[:], allocator) or_return
	defer delete(missing, allocator)
	made := slice.clone(h.made, allocator) or_return
	defer delete(made, allocator)
	scan_lists(h, &doc, answers, missing, made) or_return
	hold_spans(h, &doc) or_return
	doc.src = slice.clone(h.bytes[:], allocator) or_return
	doc.flags += {.Owns_Src}
	return doc, nil
}

// Gives `doc` the spans the scan held, in a block of its own with the format data the walk gave it, and flags it
// `.Held`.
@(private)
hold_spans :: proc(h: ^Scanner, doc: ^tape.Document) -> runtime.Allocator_Error {
	format := doc.ext.format if doc.ext != nil else nil
	ext := tape.ext_make(h.held[:], format, doc.allocator) or_return
	free(doc.ext, doc.allocator)
	doc.ext = ext
	doc.flags += {.Held}
	return nil
}
