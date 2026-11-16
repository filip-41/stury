package yaml

import "base:runtime"
import "core:bytes"
import kernel "../core/kernel"
import core "../core"
import engine "../core/build"
import "../core/records"

// The cursor of `.Entries`, with the walk's state at the save. `back` holds the anchors before `stable` and the log
// before `logged` as the live walk holds them, since the walk only completes anchors past `stable` and appends to the
// log. `back_lows`, `back_hidden` and `back_low` hold what `lows`, `hidden` and `low` held at the save.
// `lows` holds the lowest byte a replay of each anchor before `len(lows)` reads, `max(u64)` for an anchor a later one
// of its name hides. `hidden` counts the hidden anchors, `names` maps each name to its last anchor, and `low` is the
// lowest of their lows. `open_low` is the lowest byte the first unfinished anchor, `open`, reads, and `scan` how far
// through the log it has looked. `directives` holds the `%TAG` directives once their bytes may leave the window, the
// text `declared_prefix` reads. `copies` holds the nodes of anchors copied out of the window, at `regions`, which the
// walk's offsets from `FAR` name, and `compacted` its length when it last let go of the regions no offset names.
// `short` is set when memory ran out for any of it.
@(private)
Entry_Cursor :: struct {
	cursor:     Cursor,
	back:       Held,
	saved:      bool,
	short:      bool,
	stable:     int,
	logged:     int,
	hidden:     int,
	lows:       [dynamic]u64,
	back_lows:  [dynamic]u64,
	back_hidden: int,
	back_low:   u64,
	names:      map[string]int,
	low:        u64,
	dirty:      bool,
	open:       int,
	scan:       int,
	open_low:   u64,
	directives: []u8,
	declared:   int,
	copies:     [dynamic]u8,
	regions:    [dynamic]Region,
	compacted:  int,
}

// Bytes `lo ..< hi` of `Entry_Cursor.copies`, a copy of one anchor's node. A byte apart from the next, so an empty
// token at its end names it alone.
@(private)
Region :: struct {
	lo, hi: u64,
}

// The offsets `lo ..< hi` taken to `to` on.
@(private)
Move :: struct {
	lo, hi, to: u64,
}

@(private)
FAR :: records.FAR

// How far before the lowest byte the rest of the walk reads again an anchor's node lies when it is copied out of the
// window, so that a name taken again soon after is not copied.
@(private)
COPY_SPAN :: 4096

// The walk of `.Entries` from the reader's position, or its resume, and the cursor's part in following a stream's
// window. A stream's record stands once the window holds the bytes the walk judged it by: the walk ends a node at the
// next line that is no blank line, so a window that ends near that line waits for the bytes past it. The cursor reads
// again its last tokens, its comments and properties held for a node, its open blocks' properties and the nodes of
// the anchors an alias may still name. Under `merge_keys` the tokens a `<<` holds stay in the window until their
// mapping closes, and the text of the open mappings' keys is copied out of it.
@(private)
step_entries :: proc(it: ^records.Reader, w: ^records.Entry_Walk, op: records.Entry_Op) -> (hi: u64, fault: Maybe(core.Fault)) {
	e := (^Entry_Cursor)(w.cursor)
	opts := options_of(it.as)
	switch op {
	case .Step:
		if e == nil {
			failed: runtime.Allocator_Error
			if e, failed = new(Entry_Cursor, it.allocator); failed != nil {
				return 0, core.Fault{kind = .No_Memory}
			}
			e.cursor.allocator, e.names.allocator, e.lows.allocator = it.allocator, it.allocator, it.allocator
			anchors_forget(e)
			w.cursor, w.logging = e, true
			hi, fault = walk(it.src, it.pos, .Yaml_1_2, opts, w, nil, records.entry_hook, &e.cursor)
		} else if e.short {
			return 0, core.Fault{kind = .No_Memory}
		} else {
			if held := e.cursor.held; held != nil {
				held.parser.far = e.copies[:]
			}
			hi, fault = walk_resume(it.src, &e.cursor, .Yaml_1_2, opts, w, nil, records.entry_hook)
		}
		if w.given && it.input.procedure != nil && !it.last && !told(it.src, e.cursor.held) {
			w.given = false
			return 0, core.Fault{at = u64(len(it.src)), kind = .Truncated}
		}
		// A fault at an offset the window's start has passed comes back wrapped below the window.
		if f, bad := fault.?; bad && f.at >= 1 << 47 {
			f.at -= 1 << 48
			fault = f
		}
	case .Free:
		if e != nil {
			entry_cursor_free(e, it.allocator)
			w.cursor, w.far = nil, nil
		}
	case .Save:
		if e == nil || e.short {
			return
		}
		held := e.cursor.held
		if e.saved = held != nil; e.saved {
			p := &held.parser
			e.back_hidden, e.back_low = e.hidden, e.low
			if e.short || !directives_keep(e, p) || !held_copy(&e.back, held, e.stable, e.logged, e.cursor.allocator) ||
			   !mirror(&e.back_lows, e.lows, 0, e.cursor.allocator) {
				e.short = true
				return
			}
			for e.stable < len(p.anchors) && !p.anchors[e.stable].open {
				e.stable += 1
			}
			e.logged = len(p.log)
		}
	case .Restore:
		if !e.saved {
			cursor_destroy(&e.cursor)
			anchors_forget(e)
			break
		}
		stable, logged := e.stable, e.logged
		if e.cursor.held == nil {
			context = core.cursor_context(e.cursor.allocator)
			if e.cursor.held = new(Held); e.cursor.held == nil {
				e.short = true
				break
			}
			stable, logged = 0, 0
		}
		e.short ||= !held_copy(e.cursor.held, &e.back, stable, logged, e.cursor.allocator) ||
			!mirror(&e.lows, e.back_lows, 0, e.cursor.allocator)
		e.hidden, e.low = e.back_hidden, e.back_low
		e.cursor.held.parser.far = e.copies[:]
		anchors_name(e, &e.cursor.held.parser)
	case .Rebase:
		e.cursor.src, e.cursor.n = raw_data(it.src), u64(len(it.src))
		if held := e.cursor.held; held != nil {
			// A hidden anchor's bytes may have left the window, and an alias reads every anchor's name.
			anchors_compact(e, &held.parser)
			held_shift(held, it.src, w.delta)
			for &low in e.lows {
				if low < FAR {
					low -= w.delta
				}
			}
			if len(e.copies) > 2 * e.compacted + COPY_SPAN && !copies_compact(e, w, held) {
				e.short = true
			}
			held.parser.far = e.copies[:]
			anchors_name(e, &held.parser)
			if opts.alias_limit == 0 {
				held.parser.limit = max(held.parser.limit, ALIAS_RATIO * (it.base + u64(len(it.src))))
			}
		}
		e.stable, e.logged = 0, 0
	case .Keep:
		hi = max(u64)
		if held := e.cursor.held; held != nil {
			p := &held.parser
			if e.hidden >= 32 + len(p.anchors) / 2 {
				anchors_compact(e, p)
				anchors_name(e, p)
			}
			hi = held_keep(held)
			low := anchors_low(e, p)
			// No anchor lies `COPY_SPAN` bytes back unless the lowest does.
			if !opts.merge_keys && low < FAR && low + COPY_SPAN <= hi {
				e.short ||= !anchors_copy(e, w, held, hi)
				low = anchors_low(e, p)
			}
			hi = min(hi, low)
			// The keys of the open mappings are read again under `merge_keys` by each later key, so those the window
			// lets go are copied out, in the saved walk too.
			if !keys_hold(&held.parser.keys, it.src, hi) || e.saved && !keys_hold(&e.back.parser.keys, it.src, hi) {
				e.short = true
			}
		}
	case .Clone:
		if e != nil {
			c, ok := entry_cursor_clone(e, it.allocator)
			if !ok {
				return 0, core.Fault{kind = .No_Memory}
			}
			w.cursor, w.far = c, c.copies[:]
		}
	}
	if e != nil && w.cursor == e {
		w.far = e.copies[:]
	}
	return
}

// Whether the bytes of `src` past the place `held` paused at, or ended or faulted at, could not change what the walk
// read: the next byte that is no white space or line break lies `FAULT_REACH` bytes before the end. A `Truncated`
// fault may name a byte far back, such as an opening quote, and the next bytes may close it.
@(private)
told :: proc "contextless" (src: []u8, held: ^Held) -> bool {
	if held == nil {
		return false
	}
	p := &held.parser
	if held.ended && core.Fault_Kind(p.fail & 0xff) == .Truncated {
		return false
	}
	n := u64(len(src))
	at := max(p.pos, p.fail >> 16)
	for at < n && kernel.is_ws(src[at]) {
		at += 1
	}
	return at + core.FAULT_REACH < n
}

// The lowest byte the walk `held` holds reads again but for the anchors' nodes. The start of the line and the next line
// found are compared with the place the walk reads at, and only read there.
@(private)
held_keep :: proc(held: ^Held) -> u64 {
	p := &held.parser
	lo := min(p.pos, p.last_end)
	if p.tag.n != 0 {
		lo = min(lo, p.tag.lo)
	}
	if p.staging {
		for t in p.stage {
			lo = min(lo, t.lo)
		}
	}
	for c in p.pending {
		lo = min(lo, c.lo)
	}
	for b in p.blocks {
		if b.lead.tag.n != 0 {
			lo = min(lo, b.lead.tag.lo)
		}
		if b.lead.anchor.n != 0 {
			lo = min(lo, b.lead.anchor.lo)
		}
	}
	for t in held.queue {
		lo = min(lo, t.lo)
	}
	// Under `merge_keys` the tokens a `<<` holds are read again at its mapping's close.
	for t in p.merges {
		lo = min(lo, t.lo)
	}
	return lo
}

// The lowest byte an alias may read again: the anchors of a name no later anchor took, and the anchors not yet
// complete with every anchor after them.
@(private)
anchors_low :: proc(e: ^Entry_Cursor, p: ^Parser) -> u64 {
	anchors_seen(e, p)
	lo := e.low
	if u := len(e.lows); u < len(p.anchors) {
		if e.open != u {
			e.open, e.scan, e.open_low = u, p.anchors[u].log_lo, p.anchors[u].name_lo - 1
		}
		for ; e.scan < len(p.log); e.scan += 1 {
			e.open_low = min(e.open_low, p.log[e.scan].lo)
		}
		lo = min(lo, e.open_low)
	}
	return lo
}

// Takes the anchors up to the first that is not complete into `lows` and `names`.
@(private)
anchors_seen :: proc(e: ^Entry_Cursor, p: ^Parser) {
	for len(e.lows) < len(p.anchors) && !p.anchors[len(e.lows)].open {
		k := len(e.lows)
		a := p.anchors[k]
		low := anchor_low(p, a)
		if _, failed := append(&e.lows, low); failed != nil {
			e.short = true
			return
		}
		name := anchor_name(p, a)
		if j, seen := e.names[name]; seen {
			e.dirty ||= e.lows[j] == e.low
			e.lows[j] = max(u64)
			e.hidden += 1
		}
		e.names[name] = k
		e.low = min(e.low, low)
	}
	if e.dirty {
		e.low, e.dirty = max(u64), false
		for _, k in e.names {
			e.low = min(e.low, e.lows[k])
		}
	}
}

// The lowest window byte a replay of anchor `a` reads, its name's `&` among them, past the window when it reads none.
@(private)
anchor_low :: proc "contextless" (p: ^Parser, a: Anchor) -> u64 {
	low := a.name_lo - 1
	for t in p.log[a.log_lo:a.log_hi] {
		low = min(low, t.lo)
	}
	return low
}

// Copies the nodes of the anchors an alias may still name whose bytes lie `COPY_SPAN` bytes before `rest` or more out of
// the window, oldest first, and moves every offset the walk and the member hold into them, the saved walk's too, so
// the window may let them go. An anchor the saved walk does not hold complete waits. False when memory ran out.
@(private)
anchors_copy :: proc(e: ^Entry_Cursor, w: ^records.Entry_Walk, held: ^Held, rest: u64) -> bool {
	p := &held.parser
	anchors_seen(e, p)
	limit := min(len(e.lows), e.stable) if e.saved else len(e.lows)
	copied := false
	for k in 0 ..< limit {
		if e.lows[k] >= FAR || rest < COPY_SPAN || e.lows[k] + COPY_SPAN > rest {
			continue
		}
		a := p.anchors[k]
		lo, hi := anchor_low(p, a), a.lo
		for t in p.log[a.log_lo:a.log_hi] {
			if t.lo < FAR {
				hi = max(hi, t.lo + u64(t.n))
			}
		}
		e.lows[k] = lo
		if lo + COPY_SPAN > rest {
			continue
		}
		at := u64(len(e.copies))
		if _, failed := append(&e.copies, ..p.src[lo:hi]); failed != nil {
			return false
		}
		if _, failed := append(&e.copies, '\n'); failed != nil {
			return false
		}
		if _, failed := append(&e.regions, Region{at, at + hi - lo}); failed != nil {
			return false
		}
		move := []Move{{lo, hi, FAR + at}}
		far_move(p, held.queue[:], move)
		member_far_move(w, move)
		if e.saved {
			far_move(&e.back.parser, e.back.queue[:], move)
		}
		copied = true
	}
	if copied {
		e.low = lows_again(&e.lows, p)
		if e.saved {
			e.back_low = lows_again(&e.back_lows, &e.back.parser)
		}
		// The names may be views of the copies, which grew.
		p.far = e.copies[:]
		anchors_name(e, p)
	}
	return true
}

// Takes again each anchor's lowest window byte in `lows` but for those a later anchor of their name hides, and returns
// the lowest.
@(private)
lows_again :: proc(lows: ^[dynamic]u64, p: ^Parser) -> u64 {
	lowest := max(u64)
	for &low, k in lows {
		if low != max(u64) {
			low = anchor_low(p, p.anchors[k])
			lowest = min(lowest, low)
		}
	}
	return lowest
}

// Moves each offset the walk holds whose bytes, from the offset for its length, lie in one of `moves`, sorted by `lo`:
// its anchors' names, the tokens of its log, its held and staged tokens, its tag and its last token's end.
@(private)
far_move :: proc(p: ^Parser, queue: []core.Token, moves: []Move) {
	for &a in p.anchors {
		a.name_lo = moved(moves, a.name_lo, a.name_n)
		a.lo = a.name_lo + u64(a.name_n)
	}
	far_move_tokens(p.log[:], moves)
	far_move_tokens(queue, moves)
	far_move_tokens(p.stage[:], moves)
	p.tag.lo = moved(moves, p.tag.lo, p.tag.n)
	p.last_end = moved(moves, p.last_end, 0)
}

// Moves the offsets of the member's tokens and the token held ahead of it as `far_move` does.
@(private)
member_far_move :: proc(w: ^records.Entry_Walk, moves: []Move) {
	far_move_tokens(w.log[:], moves)
	if ahead, ok := w.ahead.?; ok {
		ahead.lo = moved(moves, ahead.lo, ahead.n)
		w.ahead = ahead
	}
}

@(private)
far_move_tokens :: proc(tokens: []core.Token, moves: []Move) {
	for &t in tokens {
		t.lo = moved(moves, t.lo, t.n)
	}
}

// Offset `x` of `n` bytes taken by the move of `moves` that holds them, or `x` when none does.
@(private)
moved :: #force_inline proc "contextless" (moves: []Move, x: u64, n: u32) -> u64 {
	lo, hi := 0, len(moves)
	for lo < hi {
		mid := (lo + hi) / 2
		if moves[mid].lo <= x {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo > 0 {
		if m := moves[lo - 1]; x <= m.hi && u64(n) <= m.hi - x {
			return x - m.lo + m.to
		}
	}
	return x
}

// Lets go of the copies no offset the walk holds names, the member's log and the token held ahead of it included, and
// moves the offsets into those it keeps. Run where the cursor holds no saved walk, which a save writes again whole.
// False when memory ran out.
@(private)
copies_compact :: proc(e: ^Entry_Cursor, w: ^records.Entry_Walk, held: ^Held) -> bool {
	p := &held.parser
	live := make([]bool, len(e.regions), context.temp_allocator)
	mark :: proc(e: ^Entry_Cursor, live: []bool, x: u64) {
		if x < FAR || x - FAR > u64(len(e.copies)) {
			return
		}
		lo, hi := 0, len(e.regions)
		for lo < hi {
			mid := (lo + hi) / 2
			if e.regions[mid].lo <= x - FAR {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if lo > 0 {
			live[lo - 1] = true
		}
	}
	for a in p.anchors {
		mark(e, live, a.name_lo)
	}
	for list in ([?][]core.Token{p.log[:], held.queue[:], p.stage[:], w.log[:]}) {
		for t in list {
			mark(e, live, t.lo)
		}
	}
	mark(e, live, p.tag.lo)
	mark(e, live, p.last_end)
	if ahead, ok := w.ahead.?; ok {
		mark(e, live, ahead.lo)
	}
	moves := make([dynamic]Move, context.temp_allocator)
	kept, at := 0, u64(0)
	for r, i in e.regions {
		if !live[i] {
			continue
		}
		if _, failed := append(&moves, Move{FAR + r.lo, FAR + r.hi, FAR + at}); failed != nil {
			return false
		}
		copy(e.copies[at:], e.copies[r.lo:r.hi + 1])
		e.regions[kept] = {at, at + r.hi - r.lo}
		kept, at = kept + 1, at + r.hi - r.lo + 1
	}
	resize(&e.copies, int(at))
	resize(&e.regions, kept)
	e.compacted = int(at)
	far_move(p, held.queue[:], moves[:])
	member_far_move(w, moves[:])
	for &low in e.lows {
		if low >= FAR && low != max(u64) {
			low = moved(moves[:], low, 0)
		}
	}
	return true
}

// Forgets what `anchors_seen` took.
@(private)
anchors_forget :: proc(e: ^Entry_Cursor) {
	clear(&e.lows)
	clear(&e.names)
	e.low, e.dirty, e.open, e.hidden = max(u64), false, -1, 0
}

// Takes `names` again from the anchors `lows` holds and no later anchor hides, as their names now read in `p.src` or
// the copies.
@(private)
anchors_name :: proc(e: ^Entry_Cursor, p: ^Parser) {
	clear(&e.names)
	for low, k in e.lows {
		if low != max(u64) {
			e.names[anchor_name(p, p.anchors[k])] = k
		}
	}
	e.dirty, e.open = true, -1
}

// Drops the anchors a later anchor of their name hides, which no alias can name, with the log tokens no other anchor
// holds. It reads no anchor's bytes, which may have left the window, and leaves `names` to `anchors_name`.
@(private)
anchors_compact :: proc(e: ^Entry_Cursor, p: ^Parser) {
	if e.hidden == 0 {
		return
	}
	seen := len(e.lows)
	kept, logged := 0, 0
	run_lo, run_hi, run_at := 0, -1, 0
	for k in 0 ..< len(p.anchors) {
		a := p.anchors[k]
		if k < seen && e.lows[k] == max(u64) {
			continue
		}
		hi := len(p.log) if a.open else a.log_hi
		if a.log_lo > run_hi {
			if run_hi > run_lo {
				copy(p.log[logged:], p.log[run_lo:run_hi])
				logged += run_hi - run_lo
			}
			run_lo, run_hi, run_at = a.log_lo, hi, logged
		} else {
			run_hi = max(run_hi, hi)
		}
		a.log_lo = run_at + a.log_lo - run_lo
		if !a.open {
			a.log_hi = run_at + a.log_hi - run_lo
		}
		for &o in p.open {
			if o.anchor == k {
				o.anchor = kept
			}
		}
		if p.pend_anch == k {
			p.pend_anch = kept
		}
		if k < seen {
			e.lows[kept] = e.lows[k]
		}
		p.anchors[kept] = a
		kept += 1
	}
	if run_hi > run_lo {
		copy(p.log[logged:], p.log[run_lo:run_hi])
		logged += run_hi - run_lo
	}
	resize(&e.lows, seen - e.hidden)
	resize(&p.anchors, kept)
	resize(&p.log, logged)
	e.hidden, e.stable, e.logged = 0, 0, 0
}

// Moves the `%TAG` directives' handles and prefixes into `e.directives`, once, written as directive lines.
@(private)
directives_keep :: proc(e: ^Entry_Cursor, p: ^Parser) -> bool {
	if len(p.handles) == e.declared {
		return true
	}
	size := 0
	for h in p.handles {
		size += len("%TAG  \n") + len(h.handle) + len(h.prefix)
	}
	text, failed := make([]u8, size, e.cursor.allocator)
	if failed != nil {
		return false
	}
	at := 0
	for &h in p.handles {
		at += copy(text[at:], "%TAG ")
		handle := at
		at += copy(text[at:], h.handle)
		at += copy(text[at:], " ")
		prefix := at
		at += copy(text[at:], h.prefix)
		at += copy(text[at:], "\n")
		h.handle, h.prefix = string(text[handle:prefix - 1]), string(text[prefix:at - 1])
	}
	delete(e.directives, e.cursor.allocator)
	e.directives, e.declared = text, len(p.handles)
	return true
}

// Copies the walk `from` holds to `to`, which keeps its own arrays. Their anchors before `stable` and log tokens before
// `logged` are equal already.
@(private)
held_copy :: proc(to, from: ^Held, stable, logged: int, allocator: runtime.Allocator) -> bool {
	t, f := &to.parser, &from.parser
	t.state = f.state
	to.regs, to.stop_at, to.stopped, to.ended = from.regs, from.stop_at, from.stopped, from.ended
	return mirror(&to.queue, from.queue, 0, allocator) && mirror(&t.stage, f.stage, 0, allocator) &&
		mirror(&t.pending, f.pending, 0, allocator) && mirror(&t.anchors, f.anchors, stable, allocator) &&
		mirror(&t.log, f.log, logged, allocator) && mirror(&t.open, f.open, 0, allocator) &&
		mirror(&t.handles, f.handles, 0, allocator) && mirror(&t.merges, f.merges, 0, allocator) &&
		mirror(&t.blocks, f.blocks, 0, allocator) && mirror(&t.flows, f.flows, 0, allocator) &&
		mirror(&t.keys.frames, f.keys.frames, 0, allocator) && mirror(&t.keys.keys, f.keys.keys, 0, allocator) &&
		mirror(&t.keys.heads, f.keys.heads, 0, allocator) && mirror(&t.keys.kept, f.keys.kept, 0, allocator)
}

// Makes `to` hold what `from` holds, whose items before `from_i` it holds already. `to` keeps its memory and grows
// it to the capacity of `from`, in `allocator` when it has none of its own.
@(private)
mirror :: #force_inline proc(to: ^[dynamic]$T, from: [dynamic]T, from_i: int, allocator: runtime.Allocator) -> bool {
	if cap(from) > cap(to) {
		context = core.cursor_context(allocator)
		if reserve(to, cap(from)) != nil {
			return false
		}
	}
	(^runtime.Raw_Dynamic_Array)(to).len = len(from)
	if at := min(from_i, len(from)); at < len(from) {
		copy(to[at:], from[at:])
	}
	return true
}

// Takes `delta` off every offset the walk `held` holds and points it at `src`. An offset `held_keep` did not keep is
// one the walk does not read again: a flow collection's start, which only a fault names, wraps below the window, and an
// open block's inline comment is dropped.
@(private)
held_shift :: proc(held: ^Held, src: []u8, delta: u64) {
	p := &held.parser
	p.src, p.masks.at = src, NO_BLOCK
	p.pos -= delta
	p.ls -= delta
	p.last_end = window_shift(p.last_end, delta)
	p.nl.pos -= delta
	p.tag.lo = window_shift(p.tag.lo, delta)
	if p.fail != 0 {
		p.fail = ((p.fail >> 16) - delta) << 16 | p.fail & 0xffff
	}
	held.stop_at = window_shift(held.stop_at, delta)
	for &t in held.queue {
		t.lo = window_shift(t.lo, delta)
	}
	for &t in p.stage {
		t.lo = window_shift(t.lo, delta)
	}
	for &c in p.pending {
		c.lo -= delta
	}
	for &a in p.anchors {
		a.name_lo = window_shift(a.name_lo, delta)
		a.lo = window_shift(a.lo, delta)
	}
	for &t in p.log {
		t.lo = window_shift(t.lo, delta)
	}
	for &b in p.blocks {
		b.lead.tag.lo -= delta
		b.lead.anchor.lo -= delta
		if b.inline.lo < delta {
			b.inline = {}
		} else {
			b.inline.lo -= delta
		}
	}
	for &f in p.flows {
		f.lo -= delta
	}
	for &k in p.keys.keys {
		if !k.kept {
			k.lo = window_shift(k.lo, delta)
		}
	}
	for &t in p.merges {
		t.lo -= delta
	}
}

// `x` past a window move of `delta` bytes, an offset into the copies left as it is.
@(private)
window_shift :: #force_inline proc "contextless" (x, delta: u64) -> u64 {
	return x if x >= FAR else x - delta
}

// A copy of `e` that holds its own walk, anchors and directives, with no saved state, nil and false when memory ran
// out.
@(private)
entry_cursor_clone :: proc(e: ^Entry_Cursor, allocator: runtime.Allocator) -> (c: ^Entry_Cursor, ok: bool) {
	failed: runtime.Allocator_Error
	if c, failed = new(Entry_Cursor, allocator); failed != nil {
		return
	}
	c.cursor.src, c.cursor.n, c.cursor.allocator, c.cursor.replayed = e.cursor.src, e.cursor.n, e.cursor.allocator, e.cursor.replayed
	c.names.allocator, c.lows.allocator = allocator, allocator
	c.short, c.hidden, c.low, c.dirty, c.open, c.scan, c.open_low = e.short, e.hidden, e.low, e.dirty, e.open, e.scan, e.open_low
	ok = true
	if held := e.cursor.held; held != nil {
		context = core.cursor_context(e.cursor.allocator)
		if c.cursor.held = new(Held); c.cursor.held == nil {
			ok = false
		} else {
			ok = held_copy(c.cursor.held, held, 0, 0, e.cursor.allocator) && mirror(&c.lows, e.lows, 0, allocator)
			c.copies.allocator, c.regions.allocator = allocator, allocator
			c.compacted = e.compacted
			ok = ok && mirror(&c.copies, e.copies, 0, allocator) && mirror(&c.regions, e.regions, 0, allocator)
			if ok {
				c.cursor.held.parser.far = c.copies[:]
				anchors_name(c, &c.cursor.held.parser)
				ok = directives_keep(c, &c.cursor.held.parser)
			}
		}
	}
	if !ok {
		entry_cursor_free(c, allocator)
		c = nil
	}
	return
}

// Frees what `e` holds and `e`.
@(private)
entry_cursor_free :: proc(e: ^Entry_Cursor, allocator: runtime.Allocator) {
	cursor_destroy(&e.cursor)
	context = core.cursor_context(e.cursor.allocator)
	parser_destroy(&e.back.parser)
	delete(e.back.queue)
	delete(e.lows)
	delete(e.back_lows)
	delete(e.names)
	delete(e.copies)
	delete(e.regions)
	delete(e.directives, e.cursor.allocator)
	free(e, allocator)
}

// The document of an `.Entries` member, built from the tokens the walk read of it in its place, an alias's node
// among them and a tag typed by the directives, with its keys judged as a whole text's are.
@(private)
build_entry :: proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (doc: core.Document, err: core.Document_Error) {
	e := (^Entry_Cursor)((^records.Entry_Walk)(it.format).cursor) if it.format != nil else nil
	directives := e.directives if e != nil else nil
	in_order := e != nil && !e.cursor.replayed && !options_of(it.as).merge_keys
	doc, err = records.entry_document(it, rec, directives, in_order, allocator, proc(b: ^engine.Builder, regs: core.Hook_Regs, tokens: []core.Token) -> core.Hook_Regs {
		f := Filter{build = b, src = b.doc.src, directives = b.doc.state}
		regs := regs
		for t in tokens {
			regs, _ = filter_hook(&f, regs, t)
		}
		return regs
	})
	if err.kind == .None {
		err = judge_keys(&doc, false)
	}
	return
}

// Frames the document at the reader's position: the bytes from there through the document's end, judged by the walk
// that frames it. A stream's last comments and blank lines hold no document, so they end the records.
@(private)
next_document :: proc(it: ^records.Reader) -> (rec: records.Record, ok: bool) {
	lo := it.pos
	if lo >= u64(len(it.src)) || it.to != 0 && lo >= it.to {
		return
	}
	p: Parser
	parser_init(&p, it.src, options_of(it.as), nil, nil)
	defer parser_destroy(&p)
	p.pos = core.text_start(it.src, lo)
	p.ls = p.pos
	found, read := read_document(&p)
	if read {
		p.fail = core.fault_at(p.pos, .None)
	}
	hi, fault, _ := core.result_of(p.fail, &RULES)
	if fault != nil {
		it.fault = fault
		return
	}
	it.pos = max(hi, lo)
	if !found || hi <= lo {
		it.pos = u64(len(it.src))
		return
	}
	return {text = it.src[lo:hi], at = lo}, true
}

// Moves a piece's reader to the first document start at or past `it.pos` and before `to`.
@(private)
guess_document :: proc(it: ^records.Reader, to: u64) -> bool {
	if it.pos == 0 || to <= it.pos {
		return false
	}
	at := cut_document(it, it.pos - 1, to - 1) or_return
	it.pos = at
	return true
}

// A document starts past the LF before a `---` line, and past the LF that ends a `...` line, unless the last line
// before that line that is no comment or blank line is a directive or a `...` line. Every other start follows a
// `---` or `...` line too, and no line of a document is one.
@(private)
cut_document :: proc(it: ^records.Reader, lo, to: u64) -> (u64, bool) {
	src := it.src
	hi := min(to, u64(len(src)))
	if lo >= hi {
		return 0, false
	}
	p: Parser
	p.src = src
	ls := u64(bytes.last_index_byte(src[:lo], '\n') + 1)
	for i := lo; i < hi; {
		k := bytes.index_byte(src[i:hi], '\n')
		if k < 0 {
			break
		}
		lf := i + u64(k)
		if marker_at(&p, ls) == '.' && !lone_cr(src[ls:lf]) && ls > 0 && opens_past(&p, ls - 1) {
			return lf + 1, true
		}
		if marker_at(&p, lf + 1) == '-' && opens_past(&p, lf) {
			return lf + 1, true
		}
		ls, i = lf + 1, lf + 1
	}
	return 0, false
}

// Whether a document may start past the line that ends at the LF `lf`: the last line at or before it that is no
// comment or blank line is no directive, no `...` line and no line a byte order mark starts, and the text starts
// before none. A CR may end a line alone, so a line that holds one before its end is taken for any of them.
@(private)
opens_past :: proc(p: ^Parser, lf: u64) -> bool {
	end := lf
	for {
		ls := u64(bytes.last_index_byte(p.src[:end], '\n') + 1)
		line := p.src[ls:end]
		if lone_cr(line) {
			return false
		}
		j := 0
		for j < len(line) && (line[j] == ' ' || line[j] == '\t') {
			j += 1
		}
		if j < len(line) && line[j] != '#' && line[j] != '\r' {
			return line[0] != '%' && line[0] != 0xef && marker_at(p, ls) != '.'
		}
		if ls == 0 {
			return false
		}
		end = ls - 1
	}
}

// Whether `line` holds a CR other than one right before its LF.
@(private)
lone_cr :: #force_inline proc(line: []u8) -> bool {
	k := bytes.index_byte(line, '\r')
	return k >= 0 && k < len(line) - 1
}

// A piece reads the documents from the cut `lo`, and none that starts at or past the cut `hi`. Its text runs on past
// `hi`, so a document that is not well-formed meets the fault the serial read meets, though the cut lies inside it.
@(private)
piece_documents :: proc(it: ^records.Reader, lo, hi: u64) -> bool {
	if lo > 0 {
		it.pos = lo
	}
	if hi < u64(len(it.src)) {
		it.to = hi
	}
	return true
}

// A whole text is the documents of its stream.
@(private)
whole_stream :: proc(src: []u8, as: core.As) -> (core.As, core.Framing, u64) {
	return as, .Concatenated, 0
}

@(private)
build_document :: proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	doc, err := build_as(rec.text, it.as, false, allocator)
	core.move_document_error(&err, rec.at)
	return doc, err
}
