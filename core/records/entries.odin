package records

import "base:runtime"
import "core:slice"
import core ".."
import engine "../build"

// `.Entries` over a format's walk, for a format with `Framing_Services.entry_step`: the walk finds the container
// `Reader.entries` names, gives each of its members as a record when the member's last token is read, and stops there
// for the next call to resume it. A fault ends the records at its byte, after every member before it.

// What `entry_hook` keeps across the walk, in `Reader.format`: the path, the depth, the member being read and the
// format's cursor.
Entry_Walk :: struct {
	view:   core.Token_View,
	names:  []string,
	// The format's cursor, which `Framing_Services.entry_step` allocates and frees.
	cursor: rawptr,
	// The open containers, and the depth inside the container once it is found, 0 before.
	depth:  int,
	inner:  int,
	// The names followed so far.
	named:  int,
	armed:  bool,
	// The member being read: its first and last byte, and its key's.
	lo, hi: u64,
	key:    core.Token,
	open:   bool,
	given:  bool,
	ended:  bool,
	// Set by a format whose members lie end to end, as CBOR's items do, so a member starts at `mark`, the end of the
	// token before it in the container, and not at its first token, which may leave out its head.
	abutting: bool,
	mark:   u64,
	// A member whose `End` closed it is given at the next token, which a walk stops on and `entries_walked` passes to
	// the hook before it resumes, as a walk need not stop on an `End`.
	closed: bool,
	ahead:  Maybe(core.Token),
	// On a stream: the window's `Reader.base` and `Reader.moves` the offsets above count from, and the state saved
	// reading from `saved` on, before a step at most `SAVE_SPAN` bytes of members back, which comes back
	// when the window could not tell a step's record. `given` counts the members given since the save and `redo` those
	// given before the last step, which the walk takes again from the saved state. `whole` is set for a format whose
	// walk cannot follow a moving window, whose records wait for the input's end.
	base:   u64,
	moves:  u64,
	back:   ^Entry_Walk,
	saved:  u64,
	since:  int,
	redo:   int,
	whole:  bool,
	// The records ended.
	done:   bool,
	// The shift `Entry_Op.Rebase` takes off every offset the cursor holds.
	delta:  u64,
	// Set by a format whose member's bytes alone may read otherwise than in their place: the tokens the walk read of
	// the member given last, from its key or first token through its last, which `entry_document` builds, and whether
	// memory ran out for them.
	logging: bool,
	short:   bool,
	log:     [dynamic]core.Token,
	// What the format reads once before the container for its members' documents, as XML's DTD, in `Reader.allocator`.
	prolog:  []u8,
	// The input offset of the reader's position at the first step, where a walk that finds an earlier member again
	// starts while the window holds it, and a copy of the walk at the first step of a later window, which such a walk
	// starts from once the window moved past `start`, nil while there is none. The window keeps the bytes from `start`,
	// or from `kept`, the lowest window offset `origin` reads, for members up to `ORIGIN_SPAN` bytes on. Past them
	// `moving` is set, the window keeps only what the walk reads again from `reads` on, and its next move makes the walk
	// the origin. `unpinned` is set once it could not, as for a format that makes no copy, and the window then keeps
	// none.
	start:    u64,
	origin:   ^Entry_Walk,
	kept:     u64,
	reads:    u64,
	moving:   bool,
	unpinned: bool,
}

// How many bytes of members past the origin an earlier member may be found again across.
@(private)
ORIGIN_SPAN :: CHUNK / 8

// How many bytes of members a stream's walk may take again past the state it saved.
@(private)
SAVE_SPAN :: 1024

// What `Framing_Services.entry_step` does: walk on, free the cursor, save the cursor's state, bring the saved state
// back, take `Entry_Walk.delta` off every offset the cursor holds and point it at the reader's window, return the
// lowest offset of the window the cursor reads again, `max(u64)` for none, which stays past the window's first byte,
// or a fault that ends the records after the one given, or
// point `Entry_Walk.cursor` at a copy of the cursor, which the caller keeps. A format whose walk cannot follow a moving
// window refuses the last five with `.Bad_Option`, and one that makes no copy refuses the last.
Entry_Op :: enum u8 {
	Step,
	Free,
	Save,
	Restore,
	Rebase,
	Keep,
	Clone,
}

// The hook of a walk under `.Entries`. Before the container it follows the names through object members, skipping
// every value off the path. In the container it marks each member's span, from its first token through the end of
// its last, comments left out, and stops the walk once a member is whole.
entry_hook :: proc "contextless" (h: ^Entry_Walk, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if h.inner == 0 {
		regs, a := locate_step(h, s, t)
		h.mark = t.lo + u64(t.n)
		return regs, a
	}
	if h.closed {
		h.closed, h.given, h.ahead = false, true, t
		return s, .Stop
	}
	if h.ended || t.role >= .Comment && t.role <= .Comment_Foot || t.role >= .Instruction && t.role <= .Attribute {
		if h.logging && !h.ended && (h.open || h.key.role == .Key) {
			log_token(h, t)
		}
		return s, .Next
	}
	at := h.depth
	switch {
	case t.kind == .End:
		h.depth -= 1
	case t.role == .Key && t.kind != .Array && t.kind != .Object:
		if at == h.inner {
			h.key, h.mark = t, t.lo + u64(t.n)
			if h.logging {
				clear(&h.log)
				log_token(h, t)
			}
			return s, .Next
		}
	case t.kind == .Array || t.kind == .Object:
		h.depth += 1
	}
	if at < h.inner {
		return s, .Next
	}
	if t.kind == .End && at == h.inner {
		h.ended = true
		return s, .Next
	}
	if !h.open {
		h.open, h.lo, h.hi = true, h.mark if h.abutting else t.lo, t.lo
		if h.logging && h.key.role != .Key {
			clear(&h.log)
		}
	}
	if h.logging {
		log_token(h, t)
	}
	h.hi = max(h.hi, t.lo + u64(t.n))
	if h.depth == h.inner && t.role != .Tag && t.role != .Anchor && t.role != .Alias {
		h.open, h.mark = false, h.hi
		if t.kind == .End {
			h.closed = true
			return s, .Next
		}
		h.given = true
		return s, .Stop
	}
	return s, .Next
}

@(private)
log_token :: proc "contextless" (h: ^Entry_Walk, t: core.Token) {
	context = runtime.default_context()
	if _, err := append(&h.log, t); err != nil {
		h.short = true
	}
}

// The hook of a walk that finds the container: it stops the walk at the container's open token, at `lo`.
locate_hook :: proc "contextless" (h: ^Entry_Walk, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	regs, a := locate_step(h, s, t)
	if h.inner != 0 {
		h.lo = t.lo
		return regs, .Stop
	}
	return regs, a
}

// `entry_hook` before the container: at the container's open token the members start.
@(private)
locate_step :: proc "contextless" (h: ^Entry_Walk, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if t.role > .Key {
		return s, .Next
	}
	if t.role == .Key {
		if h.named < len(h.names) && h.view.readers.key_equals(&h.view, t, h.names[h.named]) {
			h.armed = true
			return s, .Next
		}
		return s, .Skip
	}
	armed := h.armed
	h.armed = false
	#partial switch t.kind {
	case .Array, .Object:
		h.depth += 1
		switch {
		case !armed && h.named == 0 && len(h.names) == 0:
			h.inner = h.depth
		case !armed:
			// The root.
			return s, .Next if t.kind == .Object && h.depth == 1 else .Skip
		case h.named + 1 == len(h.names):
			h.inner = h.depth
		case t.kind == .Object:
			h.named += 1
		case:
			return s, .Skip
		}
	case .End:
		h.depth -= 1
		h.named = max(h.depth - 1, 0)
	}
	return s, .Next
}

// Frames the next member of the container under `.Entries` by the format's walk, which the first call starts and
// each later one resumes. On a stream the window keeps the bytes from the reader's position, or from the lowest byte the
// cursor reads again, and the cursor follows the window as it moves.
entries_walked :: proc(it: ^Reader) -> (rec: Record, ok: bool) {
	stream := it.input.procedure != nil
	w := (^Entry_Walk)(it.format)
	if w == nil {
		failed: runtime.Allocator_Error
		if w, failed = new(Entry_Walk, it.allocator); failed != nil {
			it.fault = core.Fault{kind = .No_Memory}
			return
		}
		w.view, w.names = {src = it.src, as = it.as}, it.entries
		w.base, w.moves, w.start, w.reads = it.base, it.moves, it.base + it.pos, it.pos
		w.log = make([dynamic]core.Token, it.allocator)
		it.format = w
		if stream {
			_, refused := it.services.entry_step(it, w, .Save)
			w.whole = refused != nil
		}
	} else if w.done {
		return
	}
	if stream && !entries_follow(it, w) {
		return
	}
	w.given = false
	fault: Maybe(core.Fault)
	if ahead, held := w.ahead.?; held {
		w.ahead = nil
		entry_hook(w, {}, ahead)
	}
	if !w.given {
		_, fault = it.services.entry_step(it, w, .Step)
	}
	if !w.given {
		it.fault = fault
		if !stream || it.last {
			it.services.entry_step(it, w, .Free)
			w.done = true
		}
		return
	}
	rec = {text = it.src[w.lo:w.hi], at = w.lo}
	if w.key.role == .Key {
		rec.key = it.src[w.key.lo:w.key.lo + u64(w.key.n)]
		w.key = {}
	}
	it.pos = w.hi
	if stream && !w.whole {
		w.since += 1
		// The window keeps the byte before `it.pos`, so a kept offset stays past 0, which a cursor reads as none.
		keep, failed := it.services.entry_step(it, w, .Keep)
		if failed != nil {
			// The record stands, and the records end after it.
			it.fault, w.done = failed, true
		} else if keep = min(keep, entries_pinned(it, w, keep), w.saved); keep < it.pos {
			it.pos = max(keep, 1)
		}
	}
	return rec, true
}

// Readies a stream's walk for a step: brings back the state before the last step when the window could not tell its
// record, follows the window's move, and saves the state the step starts from. False when the records end on the
// reader's fault, which a format whose walk reads the whole input sets until the window holds it.
@(private)
entries_follow :: proc(it: ^Reader, w: ^Entry_Walk) -> bool {
	if w.whole {
		if !it.last {
			it.fault = core.Fault{at = u64(len(it.src)), kind = .Truncated}
			return false
		}
		w.view.src, w.base = it.src, it.base
		return true
	}
	redo := -1
	if it.moves != w.moves && w.back != nil {
		// What the steps changed past the saved state stays: the prolog, and the log cut back to the tokens it held at
		// the save, which a step past the save only appended to unless it began another member, whose tokens a member
		// taken again logs anew.
		cursor, back, origin, log, prolog := w.cursor, w.back, w.origin, w.log, w.prolog
		kept, reads, moving, unpinned, saved := w.kept, w.reads, w.moving, w.unpinned, w.saved
		redo = w.redo
		w^ = back^
		w.cursor, w.back, w.origin, w.log, w.prolog = cursor, back, origin, log, prolog
		w.kept, w.reads, w.moving, w.unpinned, w.saved = kept, reads, moving, unpinned, saved
		resize(&w.log, len(back.log))
		if back.cursor == nil {
			it.services.entry_step(it, w, .Free)
		} else {
			it.services.entry_step(it, w, .Restore)
		}
	}
	moved := it.base != w.base || raw_data(it.src) != raw_data(w.view.src) || len(it.src) != len(w.view.src)
	if moved {
		w.delta = it.base - w.base
		w.lo, w.hi, w.mark = shifted(w.lo, w.delta, it.pin), shifted(w.hi, w.delta, it.pin), shifted(w.mark, w.delta, it.pin)
		if ahead, held := w.ahead.?; held {
			ahead.lo = shifted(ahead.lo, w.delta, it.pin)
			w.ahead = ahead
		}
		for &t in w.log {
			if t.lo >= it.pin && t.lo < it.pin + w.delta {
				clear(&w.log)
				break
			}
			t.lo = shifted(t.lo, w.delta, it.pin)
		}
		w.view.src, w.base = it.src, it.base
		if w.cursor != nil {
			it.services.entry_step(it, w, .Rebase)
		}
		w.kept, w.reads = shifted(w.kept, w.delta, it.pin), shifted(w.reads, w.delta, it.pin)
		if o := w.origin; o != nil && !w.moving {
			o.delta = w.delta
			o.lo, o.hi, o.mark = shifted(o.lo, o.delta, it.pin), shifted(o.hi, o.delta, it.pin), shifted(o.mark, o.delta, it.pin)
			if ahead, held := o.ahead.?; held {
				ahead.lo = shifted(ahead.lo, o.delta, it.pin)
				o.ahead = ahead
			}
			o.view.src, o.base, o.moves = it.src, it.base, it.moves
			it.services.entry_step(it, o, .Rebase)
		}
		w.saved = shifted(w.saved, w.delta, it.pin)
	}
	w.moves = it.moves
	if redo > 0 && !entries_redo(it, w, redo) {
		return false
	}
	if w.moving && moved {
		w.moving = false
		entries_origin(it, w)
		w.unpinned, w.kept = w.origin == nil, w.reads
	}
	w.redo = w.since
	if it.last || w.back != nil && redo < 0 && w.hi < w.saved + SAVE_SPAN {
		return true
	}
	if w.back == nil {
		failed: runtime.Allocator_Error
		if w.back, failed = new(Entry_Walk, it.allocator); failed != nil {
			it.fault = core.Fault{kind = .No_Memory}
			return false
		}
	}
	w.saved, w.since, w.redo = w.reads, 0, 0
	back := w.back
	back^ = w^
	back.back = nil
	if w.cursor != nil {
		it.services.entry_step(it, w, .Save)
	}
	return true
}

// Takes the `n` members given after the saved state again, from it, as `entries_walked` gave them, to the state the
// last step started from. False when the records end on the reader's fault.
@(private)
entries_redo :: proc(it: ^Reader, w: ^Entry_Walk, n: int) -> bool {
	pos := it.pos
	it.pos = w.saved
	for _ in 0 ..< n {
		w.given = false
		fault: Maybe(core.Fault)
		if ahead, held := w.ahead.?; held {
			w.ahead = nil
			entry_hook(w, {}, ahead)
		}
		if !w.given {
			_, fault = it.services.entry_step(it, w, .Step)
		}
		if !w.given {
			it.fault, w.done = fault if fault != nil else core.Fault{kind = .Bad_Option}, true
			return false
		}
		w.key = {}
		it.pos = w.hi
		keep, failed := it.services.entry_step(it, w, .Keep)
		if failed != nil {
			it.fault, w.done = failed, true
			return false
		}
		w.reads = min(keep, it.pos)
	}
	w.since, it.pos = n, pos
	return true
}

// The lowest window offset the window keeps for a walk that finds an earlier member again, after a member the walk
// gave, whose cursor reads from `keep` on: `start`'s, or `origin`'s, which the walk replaces past `ORIGIN_SPAN` bytes.
@(private)
entries_pinned :: proc(it: ^Reader, w: ^Entry_Walk, keep: u64) -> u64 {
	w.reads = min(keep, it.pos)
	if !w.logging || w.unpinned || w.moving {
		return max(u64)
	}
	if w.origin == nil && w.start < it.base {
		w.unpinned = true
		return max(u64)
	}
	low := w.start - it.base if w.origin == nil else w.kept
	if it.pos - low <= ORIGIN_SPAN {
		return low
	}
	w.moving = true
	return max(u64)
}

// Replaces `w.origin` with a copy of the walk as it stands, which a walk that finds an earlier member starts from.
@(private)
entries_origin :: proc(it: ^Reader, w: ^Entry_Walk) {
	if w.origin != nil {
		it.services.entry_step(it, w.origin, .Free)
		free(w.origin, it.allocator)
		w.origin = nil
	}
	if w.cursor == nil {
		return
	}
	o, failed := new(Entry_Walk, it.allocator)
	if failed != nil {
		return
	}
	o^ = w^
	o.back, o.log, o.prolog = nil, {}, nil
	if _, refused := it.services.entry_step(it, o, .Clone); refused != nil {
		free(o, it.allocator)
		return
	}
	w.origin = o
}

// The window offset `x` after the window's bytes past the `pin` kept at its start moved `delta` bytes on. An offset
// the window dropped is no place the walk reads again.
shifted :: #force_inline proc "contextless" (x, delta, pin: u64) -> u64 {
	switch {
	case x < pin:
		return x
	case x < pin + delta:
		return 0
	}
	return x - delta
}

// Frees what `.Entries` over a walk keeps.
entries_walked_close :: proc(it: ^Reader) {
	if w := (^Entry_Walk)(it.format); w != nil && it.framing == .Entries {
		it.services.entry_step(it, w, .Free)
		if w.origin != nil {
			it.services.entry_step(it, w.origin, .Free)
			free(w.origin, it.allocator)
		}
		delete(w.log)
		delete(w.prolog, it.allocator)
		free(w.back, it.allocator)
		free(w, it.allocator)
		it.format = nil
	}
}

// The document of an `.Entries` member from `doc`, the build of a text that holds that member alone in its container:
// the first value of `doc`'s root, which `doc` gives up.
member_document :: proc(doc: ^core.Document, allocator: runtime.Allocator) -> (sub: core.Document, err: core.Document_Error) {
	defer core.destroy(doc)
	members := core.children(doc, core.ROOT)
	v, found := core.child_next(&members)
	if !found {
		return {}, {kind = .Bad_Index}
	}
	failed: runtime.Allocator_Error
	if sub, failed = subtree(nil, doc, v, allocator); failed != nil {
		return {}, {kind = .No_Memory}
	}
	return
}

// The document of `rec`, a member `entries_walked` gave, from the tokens its walk read in its place, over the
// reader's text and with the format's `state`, marked `in_order` when no token goes back to bytes before the one sent
// before it. `feed` passes them to the builder as the format's build of a whole text
// passes its walk's, inside a container that holds the member alone, which `member_document` takes off. A member given
// before the last is found again by a walk from `Entry_Walk.start` or `Entry_Walk.origin`, and one the window no longer
// holds is `.Bad_Index`.
entry_document :: proc(it: ^Reader, rec: Record, state: []u8, in_order: bool, allocator: runtime.Allocator, feed: proc(b: ^engine.Builder, regs: core.Hook_Regs, tokens: []core.Token) -> core.Hook_Regs) -> (doc: core.Document, err: core.Document_Error) {
	w := (^Entry_Walk)(it.format)
	if w == nil || !w.logging || rec.at < it.base {
		return {}, {kind = .Bad_Index}
	}
	found := w
	again: Entry_Walk
	defer if found == &again {
		it.services.entry_step(it, &again, .Free)
		delete(again.log)
	}
	if len(w.log) == 0 || rec.at != it.base + w.lo {
		found = &again
		if err = entry_again(it, w, rec.at - it.base, &again); err.kind != .None {
			return
		}
	}
	if found.short {
		return {}, {kind = .No_Memory}
	}
	keyed := found.log[0].role == .Key
	open := core.Token{lo = found.log[0].lo, kind = .Object if keyed else .Array}
	end := core.Token{lo = found.hi, kind = .End}
	count: engine.Count
	counted: core.Hook_Regs
	counted, _ = engine.builder_hook_count(&count, counted, open)
	for t in found.log {
		counted, _ = engine.builder_hook_count(&count, counted, t)
	}
	counted, _ = engine.builder_hook_count(&count, counted, end)
	b := engine.builder_start(it.src, it.as, false, allocator, count.nodes, count.deepest, count.facts)
	regs := engine.BUILDER_REGS
	regs, _ = engine.builder_hook(&b, regs, open)
	// The feed reads the format's state in the builder's document, which holds none of its own.
	b.doc.state, b.doc.in_order = state, in_order
	regs = feed(&b, regs, found.log[:])
	b.doc.state = nil
	regs, _ = engine.builder_hook(&b, regs, end)
	doc, err = engine.builder_end(&b, regs, nil)
	if err.kind != .None {
		return
	}
	if len(state) > 0 {
		// A format's tables hold words of up to 8 bytes.
		kept, failed := runtime.mem_alloc_bytes(len(state), 16, allocator)
		if failed != nil {
			core.destroy(&doc)
			return {}, {kind = .No_Memory}
		}
		copy(kept, state)
		doc.state = kept
	}
	return member_document(&doc, allocator)
}

// Walks to the member that starts at window offset `at` again, into `again`, which the caller frees: from the reader's
// first position while the window holds it, else from `w.origin`, so the member's tokens are logged in their place.
@(private)
entry_again :: proc(it: ^Reader, w: ^Entry_Walk, at: u64, again: ^Entry_Walk) -> core.Document_Error {
	pos := it.pos
	defer it.pos = pos
	switch {
	case w.start >= it.base:
		again^ = {view = w.view, names = w.names, base = w.base, moves = w.moves, logging = true}
		it.pos = w.start - it.base
	case w.origin != nil:
		again^ = w.origin^
		if _, refused := it.services.entry_step(it, again, .Clone); refused != nil {
			again.cursor = nil
			return {kind = .Bad_Index}
		}
	case:
		return {kind = .Bad_Index}
	}
	again.log = make([dynamic]core.Token, it.allocator)
	for {
		again.given = false
		if ahead, held := again.ahead.?; held {
			again.ahead = nil
			entry_hook(again, {}, ahead)
		}
		if !again.given {
			it.services.entry_step(it, again, .Step)
		}
		if !again.given || again.lo > at {
			return {kind = .Bad_Index}
		}
		if again.lo == at {
			return {}
		}
		again.key = {}
	}
}

// What an `.Entries` reader over a tree keeps in `Reader.format`: the tree, built from byte `start` of the reader's
// text, the members still to give, and the last member given.
@(private)
Entries :: struct {
	doc:     core.Document,
	start:   u64,
	members: core.Child_Iter,
	keyed:   bool,
	last:    core.Node_Index,
}

// Frames the next member of the container as a record: its authored bytes, and in an object its key as written. A
// stream's records wait for the input's end, which the whole tree needs.
entries_next :: proc(it: ^Reader) -> (rec: Record, ok: bool) {
	e := (^Entries)(it.format)
	if e == nil {
		if it.input.procedure != nil && !it.last {
			it.fault = core.Fault{at = u64(len(it.src)), kind = .Truncated}
			return
		}
		e = entries_open(it) or_return
	}
	v := core.child_next(&e.members) or_return
	e.last = v
	text := core.span(&e.doc, v)
	rec = {text = text, at = u64(uintptr(raw_data(text)) - uintptr(raw_data(it.src)))}
	if e.keyed {
		rec.key = core.span(&e.doc, v - 1)
	}
	it.pos = rec.at + u64(len(text))
	return rec, true
}

// Builds the tree and finds the container: the root, or the value each name of `it.entries` names in the object before
// it, the first member of that name whose value is a container. A text with no such container has no records.
@(private)
entries_open :: proc(it: ^Reader) -> (e: ^Entries, ok: bool) {
	failed: runtime.Allocator_Error
	if e, failed = new(Entries, it.allocator); failed != nil {
		it.fault = core.Fault{kind = .No_Memory}
		return
	}
	it.format = e
	e.start = it.pos
	err: core.Document_Error
	if e.doc, err = it.services.tree(it.src[e.start:], it.as, false, it.allocator); err.kind != .None {
		core.move_document_error(&err, e.start)
		it.fault = err.inner if err.kind == .Walk else core.Fault{kind = .No_Memory if err.kind == .No_Memory else .Bad_Option}
		return
	}
	container := core.ROOT
	for name, depth in it.entries {
		found := core.NO_NODE
		named := core.members_named(&e.doc, container, name)
		for v in core.member_next(&named) {
			kind := e.doc.nodes[v].kind
			if kind == .Object || kind == .Array && depth == len(it.entries) - 1 {
				found = v
				break
			}
		}
		if found == core.NO_NODE {
			e.members.done = true
			return e, true
		}
		container = found
	}
	e.members = core.children(&e.doc, container)
	e.keyed = e.doc.nodes[container].kind == .Object
	return e, true
}

// Frees what an `.Entries` reader over a tree keeps.
entries_close :: proc(it: ^Reader) {
	if e := (^Entries)(it.format); e != nil {
		core.destroy(&e.doc)
		free(e, it.allocator)
		it.format = nil
	}
}

// The document of `rec`, a member `entries_next` gave: its subtree of the tree, with every offset from the input's
// first byte.
@(private)
entries_build :: proc(it: ^Reader, rec: Record, allocator: runtime.Allocator) -> (sub: core.Document, err: core.Document_Error) {
	e := (^Entries)(it.format)
	v := e.last
	at := rec.at - it.base - e.start
	if member_at(e, v) != at {
		// A record given before the last: its member is found among the container's.
		all := core.children(&e.doc, e.members.parent)
		for w in core.child_next(&all) {
			if member_at(e, w) == at {
				v = w
				break
			}
		}
	}
	failed: runtime.Allocator_Error
	if sub, failed = subtree(it, &e.doc, v, allocator); failed != nil {
		return {}, {kind = .No_Memory}
	}
	return
}

@(private)
member_at :: proc(e: ^Entries, v: core.Node_Index) -> u64 {
	if v == core.NO_NODE {
		return max(u64)
	}
	return u64(uintptr(raw_data(core.span(&e.doc, v))) - uintptr(raw_data(e.doc.src)))
}

// A document of node `v`'s subtree of `doc`: its nodes, facts and child counts, numbered from `v`, over `doc`'s text.
@(private)
subtree :: proc(it: ^Reader, doc: ^core.Document, v: core.Node_Index, allocator: runtime.Allocator) -> (sub: core.Document, err: runtime.Allocator_Error) {
	count := core.Node_Index(core.subtree_size(doc, v))
	sub.view = doc.view
	sub.state = nil
	sub.allocator = allocator
	sub.kinds_stored, sub.in_order = doc.kinds_stored, doc.in_order
	defer if err != nil {
		core.destroy(&sub)
	}
	sub.nodes_alloc = slice.clone(doc.nodes[v:v + count], allocator) or_return
	sub.facts_alloc = slice.clone(node_range(doc.facts, v, count), allocator) or_return
	sub.counts_alloc = slice.clone(node_range(doc.counts, v, count), allocator) or_return
	sub.nodes, sub.facts, sub.counts = sub.nodes_alloc, sub.facts_alloc, sub.counts_alloc
	for &f in sub.facts {
		f.node -= v
	}
	for &c in sub.counts {
		c.node -= v
	}
	if kind := doc.nodes[v].kind; kind == .Array || kind == .Object {
		span := core.span(doc, v)
		sub.root_close = u64(uintptr(raw_data(span)) - uintptr(raw_data(doc.src))) + u64(len(span))
	}
	if it != nil && it.services.tree_state != nil {
		sub.state = it.services.tree_state(doc, v, count, allocator) or_return
	} else if len(doc.state) > 0 {
		// A format's tables hold words of up to 8 bytes.
		sub.state = runtime.mem_alloc_bytes(len(doc.state), 16, allocator) or_return
		copy(sub.state, doc.state)
	}
	return
}

// The entries of `list`, sorted by node, whose node is in the `count` nodes from `v`.
@(private)
node_range :: proc(list: []$E, v, count: core.Node_Index) -> []E {
	return list[core.lower_node(list, v):core.lower_node(list, v + count)]
}

// Whether `framing` reads its records as members of a tree or by a walk that resumes, either on one thread.
@(private)
by_tree :: #force_inline proc(services: ^Framing_Services, framing: core.Framing) -> bool {
	return framing == .Entries && (services.tree != nil || services.entry_step != nil)
}

// Whether `it` reads its records as members of a tree it built.
@(private)
over_tree :: #force_inline proc(it: ^Reader) -> bool {
	return it.format != nil && it.framing == .Entries && it.services.tree != nil
}
