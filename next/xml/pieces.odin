package xml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Reads a text in windows. The walk of the whole text goes on from window to window in the state it paused in, its
// frames, namespaces and DTD kept in the read's state, and reads a unit of markup only once the window holds it whole
// (`Units`), so every token, fault and answer is the whole read's. The prolog is read once the window holds it with the
// root's start tag, and the epilog in the last window. A window keeps from the text run of the innermost open element,
// from its start tag while it has given no `Object`, and from the internal subset while there is one, as the DTD's
// entities and attribute defaults are read in place there. The names of the other open elements and the namespaces in
// scope are copied out of the window.

// The walk a read of a text in pieces keeps, laid out as the walk of every hook.
@(private)
Held_Walk :: Walk(hook.No_Hooks, true)

// What a read of a text in pieces keeps from one window to the next, besides the state `hook.Piece_State` holds.
@(private)
Piece :: struct {
	using state: hook.Piece_State,
	walk:        Held_Walk,
	frames:      [WALK_LEVELS]Frame,
	pause:       Pause,
	// The names of the open elements, each with its `<`, which their frames read once the window no longer holds them.
	tags:        [dynamic]u8,
	inner:       u64, // the start tag of the innermost open element, which the window holds while it has no `Object`
	begun:       bool, // the walk holds memory, from its first window until it ends
}

// Frees the state of a read of a text in pieces, whose lists the read's own allocator holds.
@(private)
piece_free :: proc(p: ^tape.Pieces) {
	s := (^Piece)(p.state)
	if s.begun {
		ctx := context
		w := &s.walk
		w.ctx = &ctx
		if w.dtd != nil {
			// A grab with no context frees in the default one, with its own allocator.
			w.dtd.grab.ctx = nil
		}
		walk_end(w, 0)
		w.ctx = nil
	}
	delete(s.tags)
	hook.piece_release(p)
}

// Walks the window `src` of the text in pieces `opts.pieces` for hook `h` from its registers `regs`, and updates
// `opts.pieces` (`more`, `at`, `keep`, `open`) for the next window. A window must start at or before `keep` and end at
// or after `at`, and the first window must start the text.
@(private)
piece_read :: proc(src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	hook.check(H)
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	p := opts.pieces
	s, text, to, e := hook.piece_begin(p, Piece, piece_free, src)
	if e != nil {
		return 0, e, false
	}
	lists := hook.piece_lists(p)
	// The walk reads in this call's frame, and the state keeps it without what the call lends it.
	kept := (^Walk(H, true))(&s.walk)
	walk := kept^
	w := &walk
	defer {
		w.hooks, w.regs, w.ctx = nil, nil, nil
		if w.dtd != nil {
			w.dtd.grab.ctx = nil
		}
		kept^ = walk
	}
	base := raw_data(text)
	if !s.started {
		walk_init(w, opts, build.read_depth(opts), build.read_steps(opts), raw_data(s.frames[:]))
		walk_bind(w, base, h, regs, ctx)
		w.opened = regs.c
		// The hook holds the document's level before the walk opens an element.
		if !hook.levels_need(w, int(regs.c) + 1, regs, 0) {
			return 0, runtime.Allocator_Error.Out_Of_Memory, false
		}
		w.depth = hook.held_depth(h, regs, min(w.limit, WALK_LEVELS))
		s.tags.allocator, s.steps_buf.allocator = lists, lists
		s.started, s.begun = true, true
	} else if d := s.pause.depth; d > 0 && .Object not_in w.stack[d - 1].flags {
		w.stack[d - 1].tag = base[s.inner:]
	}
	walk_bind(w, base, h, regs, ctx)
	w.allocator, w.pause = lists, &s.pause
	if w.dtd != nil {
		w.dtd.src, w.dtd.grab.ctx = text, ctx
	}
	s.pause.end, s.pause.more = base[to:], !p.last
	if s.pause.place == .Prolog && !p.last {
		units_frame(&s.pause.units, base, to, true)
		if !s.pause.units.rooted {
			p.more, p.at, p.keep, p.open = true, to, 0, nil
			return 0, nil, false
		}
	}
	when .Walk in C {
		h.walk = w
	}
	r := resume(w, text, base[to:], regs^, on)
	when .Walk in C {
		h.walk = nil
	}
	s.regs = regs^
	if u8(r) == hook.WALK_MORE {
		if herr := piece_hold(p, s, w, to); herr != nil {
			return 0, herr, false
		}
		return 0, nil, false
	}
	r = u64(hook.steps_result(hook.Walk_Result(walk_end(w, r)), w.steps))
	s.begun = false
	p.more, p.open = false, nil
	root_close, err, _ = hook.walk_error(hook.Walk_Result(r), &RULES)
	return root_close, err, w.tolerated
}

// Sets the pieces `p` for the window after one that ended at `to` with walk `w` paused, with the path of the open
// elements, as `window_hold` keeps what the walk reads past the window.
@(private)
piece_hold :: proc(p: ^tape.Pieces, s: ^Piece, w: ^Walk($H, $LAX), to: u64) -> tape.Error {
	keep := window_hold(w, s.pause.at, s.pause.depth, &s.tags, &s.inner) or_return
	clear(&s.steps_buf)
	at_ := 0
	for f in w.stack[:s.pause.depth] {
		append(&s.steps_buf, tape.Step(tape.Name(string(s.tags[at_ + 1:][:f.name_n])))) or_return
		at_ += 1 + int(f.name_n)
	}
	p.more, p.at, p.keep, p.open = true, to, keep, s.steps_buf[:]
	return nil
}

// Copies out of the window what walk `w`, paused at `paused_at` with `d` open elements, reads past the bytes the next
// window keeps, and gives the first byte it keeps. The names of the open elements go to `tags`, each with its `<`, but
// the innermost's while it has given no `Object`, whose start tag the window keeps, at `inner^`, `max(u64)` for none.
// The namespaces in scope are copied out too. The window keeps the text run of the innermost open element, and the
// internal subset while there is one, as the DTD's entities and attribute defaults are read in place there.
@(private)
window_hold :: proc(w: ^Walk($H, $LAX), paused_at, d: u64, tags: ^[dynamic]u8, inner: ^u64) -> (keep: u64, err: tape.Error) {
	keep, inner^ = paused_at, max(u64)
	size := 0
	for f in w.stack[:d] {
		size += 1 + int(f.name_n)
	}
	// The copy has room for every name, so appending moves none.
	held := make([dynamic]u8, 0, size, tags.allocator) or_return
	for f in w.stack[:d] {
		append(&held, ..f.tag[:1 + int(f.name_n)])
	}
	at_ := 0
	for &f, i in w.stack[:d] {
		if i == int(d) - 1 && .Object not_in f.flags {
			inner^ = at(w, f.tag)
			keep = min(keep, inner^)
		} else {
			f.tag = raw_data(held[at_:])
		}
		at_ += 1 + int(f.name_n)
	}
	delete(tags^)
	tags^ = held
	if d > 0 {
		keep = min(keep, w.stack[d - 1].text_lo)
	}
	if t := w.dtd; t != nil && t.subset_hi != 0 {
		keep = min(keep, t.subset_lo)
	}
	if !ns_own(w) {
		return keep, runtime.Allocator_Error.Out_Of_Memory
	}
	return keep, nil
}

// Copies the prefix and the URI of each namespace declaration in scope that points into the window into a block of
// the walk's allocator, the prefix right after the URI. A decoded URI is in a block already, without its prefix. False
// when memory is refused.
@(private)
ns_own :: proc "contextless" (w: ^Walk($H, $LAX)) -> bool {
	for &entry in w.ns[:w.ns_len] {
		if entry.owned != 0 && (entry.prefix.n == 0 || entry.prefix.p == entry.uri.p[entry.uri.n:]) {
			continue
		}
		size := max(int(entry.uri.n + entry.prefix.n), 1)
		b := ([^]u8)(grab(walk_grab(w), size))
		if b == nil {
			return false
		}
		intrinsics.mem_copy_non_overlapping(b, entry.uri.p, int(entry.uri.n))
		intrinsics.mem_copy_non_overlapping(b[entry.uri.n:], entry.prefix.p, int(entry.prefix.n))
		ungrab(walk_grab(w), entry.uri.p, entry.owned)
		entry.uri.p, entry.prefix.p, entry.owned = b, b[entry.uri.n:], size
	}
	return true
}

@(private)
validate_pieces :: proc(src: []u8, $S: Spec, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	walk :: proc(src: []u8, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, a, ctx, hook.no_hook)
	}
	return build.read_validate_pieces(src, &FORMATS[S], opts, allocator, Piece, walk)
}

@(private)
build_pieces :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Builder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, a, ctx, build.builder_hook_facts)
	}
	return build.read_build_pieces(src, &FORMATS[S], &RULES, opts, caller, Piece, walk, build_finish)
}

@(private)
find_pieces :: proc(src: []u8, path: []tape.Step, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, a, ctx, build.finder_key_skip_hook)
	}
	return build.read_find_pieces(src, path, &FORMATS[S], read, opts, caller, respell, Piece, walk)
}

@(private)
scan_pieces :: proc(src: []u8, demand: ^tape.Demand, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	// A text's token spans the comments and instructions in its run, which the walk gives before it, so the scan holds
	// the bytes it reads whole rather than token by token. A window may end between a key and its value, so it skips no
	// member at its key.
	walk :: proc(src: []u8, opts: Options, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		h.scattered = true
		return piece_read(src, S, opts, h, regs, a, ctx, build.scanner_hook)
	}
	doc, err := build.read_scan_pieces(src, demand, &FORMATS[S], read, opts, caller, Piece, walk)
	if err == nil {
		err = keep_scopes(&doc, demand.facts)
	}
	return doc, err
}
