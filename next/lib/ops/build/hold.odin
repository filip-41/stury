package build

import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// A scan of a text in pieces copies the bytes of what it keeps out of each window as the window ends, so the caller may
// drop a window once the walk is past it, and its document reads those bytes as `.Held`. The walk's tokens come in text
// order and the nodes, facts and coming key a scan keeps follow it, so the tokens a window added are those from
// `Scanner.hold_from` on.

// Copies out of window `text`, which the text's offsets index, the authored span of each key and scalar node, each fact
// and the coming key that the walk gave since the last hold. `regs` are the hook's registers at the window's end.
scanner_hold :: proc(h: ^Scanner, regs: hook.Regs, text: []u8) -> runtime.Allocator_Error {
	h.holds = true
	nodes := h.b.doc.nodes[:builder_cursor(&h.b, regs)]
	facts := h.b.doc.facts
	k, j := len(nodes), len(facts)
	for k > 0 && nodes[k - 1].lo >= h.hold_from {
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
			head, tail := hold_bounds(h, text, t)
			append(&h.held, tape.Held_Span{t.lo - head, u64(len(h.bytes))}) or_return
			append(&h.bytes, ..text[t.lo - head:t.lo + u64(t.n) + tail]) or_return
			h.hold_from = t.lo + 1
		}
	}
	if len(h.bytes) > 2 * h.held_live + HOLD_SLACK {
		return hold_drop(h, nodes, facts)
	}
	return nil
}

// The bytes a scan holds past twice those it held when it last dropped the bytes of tokens it no longer keeps.
@(private)
HOLD_SLACK :: 4096

// The next of the tokens from node `k^` and fact `j^` on, and then the coming key, in text order, as a token whose
// span is the bytes it holds. A container node holds none, and is passed.
@(private)
hold_next :: proc "contextless" (h: ^Scanner, nodes: []tape.Node, facts: []tape.Fact, k, j: ^int) -> (tape.Token, bool) #no_bounds_check {
	for k^ < len(nodes) && nodes[k^].kind > .Plain {
		k^ += 1
	}
	key := h.key.lo if h.has_key && h.key.lo >= h.hold_from else max(u64)
	node := nodes[k^].lo if k^ < len(nodes) else max(u64)
	fact := facts[j^].lo if j^ < len(facts) else max(u64)
	switch {
	case node == max(u64) && fact == max(u64) && key == max(u64):
		return {}, false
	case node <= fact && node <= key:
		k^ += 1
		return nodes[k^ - 1], true
	case fact <= key:
		j^ += 1
		return {lo = fact, n = facts[j^ - 1].n, kind = .End}, true
	}
	return h.key, true
}

// The bytes of token `t`'s authored span before and after its own, none for a fact's, whose span is all of it.
@(private)
hold_bounds :: #force_inline proc "contextless" (h: ^Scanner, src: []u8, t: tape.Token) -> (head, tail: u64) {
	if t.kind == .End {
		return 0, 0
	}
	a, b := h.b.doc.format.bounds(src, t)
	return u64(a), u64(b)
}

// Keeps only the held bytes of the nodes, facts and coming key the scan still keeps, as a scan that takes elements
// back drops their nodes.
@(private, cold)
hold_drop :: proc(h: ^Scanner, nodes: []tape.Node, facts: []tape.Fact) -> runtime.Allocator_Error {
	held := make([dynamic]tape.Held_Span, 0, len(h.held), h.held.allocator) or_return
	bytes := make([dynamic]u8, 0, h.held_live + HOLD_SLACK, h.bytes.allocator) or_return
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
		// The coming key is next only once, as in `scanner_hold`.
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
	h.held, h.bytes, h.held_live = held, bytes, len(bytes)
	return nil
}

// The document of the answers a scan of a text in pieces has so far, as `builder_so_far` gives a build's, with the
// containers it read only part of marked `CONTAINER_PARTIAL` and every byte it reads held. `regs` are the hook's
// registers at the cut and `cut` where more bytes are needed. The scan goes on as it was.
@(require_results)
scanner_so_far :: proc(h: ^Scanner, regs: hook.Regs, cut: u64, allocator: runtime.Allocator) -> (doc: tape.Document, err: tape.Error) {
	read := make([]u64, regs.c, allocator) or_return
	defer delete(read, allocator)
	b := regs.b
	for c := regs.c; c > 0; c -= 1 {
		// A level past the frames is inside a container the scan keeps whole.
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
	doc.src = slice.clone(h.bytes[:], allocator) or_return
	doc.flags += {.Held, .Owns_Src}
	return doc, nil
}
