package xml

import "base:intrinsics"
import "base:runtime"
import core "../core"
import records "../core/records"

// A walk's cursor, `core.Token_Cursor`: at its first stop the walk reads on and holds the tokens past the stop up to the
// next element's end, where it pauses, and `walk_resume` gives them and continues the walk.
Cursor :: core.Token_Cursor

// Whether `cursor` holds a stop that `walk_resume` continues, false once the walk it fills ended.
can_resume :: #force_inline proc "contextless" (cursor: ^Cursor) -> bool {
	return cursor.held != nil
}

// Continues the walk `cursor` holds a stop of, over the same `src`, from the token after the one it stopped on.
// `regs` is passed to the first token in place of the registers the stop saved, unless it is nil. The results are
// `walk`'s. A cursor that holds no stop, or that a walk of another text filled, is refused with `.Bad_Option`.
walk_resume :: proc "contextless" (src: []u8, cursor: ^Cursor, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	held := cursor.held
	if held == nil || held.walk == nil || cursor.src != raw_data(src) || cursor.n != u64(len(src)) {
		return core.cursor_resume(src, cursor, h, regs, on, &RULES)
	}
	if regs != nil {
		held.regs = regs^
	}
	stopped: bool
	if hi, stopped = core.cursor_give(held, h, on); stopped {
		if regs != nil {
			regs^ = held.regs
		}
		return
	}
	paused := (^Paused(core.Holding(H)))(held.walk)
	r := held.regs
	held.walk = nil
	mute := held.mute
	core.cursor_free(cursor)
	if regs != nil {
		regs^ = r
		return walk_continue(src, paused, mute, h, regs, on, cursor)
	}
	return walk_continue(src, paused, mute, h, &r, on, cursor)
}

// Where a walk through `core.Holding` paused: at the end of an element with `e` open elements, its last byte just
// before `at`, with the walk's state, which lives under `allocator`. `names` holds `names_n` bytes on the default heap,
// the start tags' `<` and names of the open elements a stream's window moved past, which their frames point to.
@(private)
Paused :: struct($H: typeid) {
	walk:      Walk(H),
	at:        u64,
	e:         u64,
	allocator: runtime.Allocator,
	names:     [^]u8,
	names_n:   int,
}

// Frees the walk `paused` holds and `paused`.
@(private)
paused_free :: proc "contextless" (paused: ^Paused($H)) {
	walk_end(&paused.walk, 0, nil)
	if paused.names != nil {
		runtime.heap_free(paused.names)
	}
	context = core.cursor_context(paused.allocator)
	free(paused)
}

// Pauses the walk at the end of an element with `e` open elements whose last byte is just before `p`, once the hook's
// stop is held: copies the walk to its `Paused`, the frames on the default heap, and returns the result word of the
// pause.
@(private, cold)
pause :: #force_no_inline proc "contextless" (p: [^]u8, e: u64, w: ^Walk($H), hs: core.Hook_Regs) -> u64 {
	release :: proc "contextless" (walk: rawptr) {
		paused_free((^Paused(H))(walk))
	}
	paused := (^Paused(H))(w.parked)
	if paused == nil {
		if !w.owned {
			frames := runtime.heap_alloc(int(e) * size_of(Frame), false)
			if frames == nil {
				return fault(w, hs, p, .No_Memory)
			}
			intrinsics.mem_copy_non_overlapping(frames, w.frames, int(e) * size_of(Frame))
			w.frames, w.owned, w.depth = ([^]Frame)(frames), true, e
		}
		context = core.cursor_context(w.hooks.allocator)
		if paused = new(Paused(H)); paused == nil {
			return fault(w, hs, p, .No_Memory)
		}
		paused.allocator = context.allocator
		w.parked = paused
	}
	paused.walk, paused.at, paused.e = w^, at(w, p), e
	w.hooks.held.walk, w.hooks.held.release = paused, release
	w.regs^ = hs
	return core.fault_at(at(w, p), .None, PAUSED)
}

// Continues the walk `paused` holds with hook `on`, a `Skip` on a held token hiding the elements up to `mute`, and
// ends it as `walk_holding` does.
@(private)
walk_continue :: proc "contextless" (src: []u8, paused: ^Paused(core.Holding($H)), mute: u64, h: ^H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor) -> (hi: u64, fault: Maybe(core.Fault)) {
	holding :: proc "contextless" (s: ^core.Holding(H), regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
		return core.holding_hook(s, regs, t, on)
	}
	s := core.Holding(H) {
		hooks     = h,
		allocator = cursor.allocator,
	}
	w := paused.walk
	w.hooks, w.regs, w.mute = &s, regs, mute
	p := raw_data(src)
	word := st_closed(p[paused.at:], p[len(src):], paused.e, &w, regs.a, regs.b, regs.c, holding)
	if word & 0xffff != PAUSED << 8 {
		word = walk_end(&w, word, nil)
		paused.walk = {}
		paused_free(paused)
	}
	hi, fault, _ = core.result_of(word, &RULES)
	return core.holding_end(src, cursor, &s, regs, hi, fault, &RULES)
}

// `walk` with a cursor: the walk of the whole text through `core.Holding`, which hands its held tokens to `cursor` when
// the hook stopped.
@(private)
walk_holding :: proc "contextless" (src: []u8, lo: u64, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor) -> (hi: u64, fault: Maybe(core.Fault)) {
	holding :: proc "contextless" (s: ^core.Holding(H), regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
		return core.holding_hook(s, regs, t, on)
	}
	zero: core.Hook_Regs
	r := regs if regs != nil else &zero
	s := core.Holding(H) {
		hooks     = h,
		allocator = cursor.allocator,
	}
	hi, fault, _ = core.result_of(walk_document(src, lo, opts, &s, r, holding, nil), &RULES)
	return core.holding_end(src, cursor, &s, r, hi, fault, &RULES)
}

// Makes `to` a copy of the walk `from` holds, which shares none of its memory, in the memory `to` holds where it is
// large enough. False when memory runs out, with `to` a walk `paused_free` frees.
@(private)
paused_copy :: proc "contextless" (to, from: ^Paused($H)) -> bool {
	old, names, names_n := to.walk, to.names, to.names_n
	to^ = from^
	to.names, to.names_n = names, names_n
	w := &to.walk
	w.parked, w.table, w.dtd = to, nil, old.dtd
	w.frames, w.owned, w.depth = old.frames, old.owned, old.depth if old.owned else 0
	w.ns, w.ns_len, w.ns_cap = old.ns, old.ns_len, old.ns_cap
	if from.names_n != names_n {
		if names != nil {
			runtime.heap_free(names)
		}
		to.names, to.names_n = nil, 0
		if from.names != nil {
			if to.names = ([^]u8)(runtime.heap_alloc(from.names_n, false)); to.names == nil {
				return false
			}
			to.names_n = from.names_n
		}
	}
	if from.names != nil {
		intrinsics.mem_copy_non_overlapping(to.names, from.names, from.names_n)
	}
	if !w.owned || w.depth < from.e {
		if w.owned {
			runtime.heap_free(w.frames)
		}
		w.frames, w.owned, w.depth = nil, false, 0
		if w.frames = ([^]Frame)(runtime.heap_alloc(int(max(from.e, 1)) * size_of(Frame), false)); w.frames == nil {
			return false
		}
		w.owned, w.depth = true, max(from.e, 1)
	}
	intrinsics.mem_copy_non_overlapping(w.frames, from.walk.frames, int(from.e) * size_of(Frame))
	for &f in w.frames[:from.e] {
		if off, kept := inside(f.tag, from.names, u64(from.names_n)); kept {
			f.tag = to.names[off:]
		}
	}
	if from.walk.ns != nil && (old.ns == nil || old.ns_cap < from.walk.ns_cap) {
		if w.ns = ([^]Ns_Entry)(runtime.heap_alloc(int(from.walk.ns_cap) * size_of(Ns_Entry), false)); w.ns == nil {
			w.ns = old.ns
			return false
		}
		w.ns_cap = from.walk.ns_cap
	}
	w.ns_len = 0
	// An entry of `to` whose block has the size of the one at its place in `from` takes the copy in that block.
	for i in 0 ..< from.walk.ns_len {
		entry := from.walk.ns[i]
		mine := old.ns[i] if i < old.ns_len else Ns_Entry{}
		if entry.owned {
			n := ns_bytes(entry)
			block: [^]u8
			if mine.owned && ns_bytes(mine) == n {
				block, mine.owned = mine.uri.p, false
			} else if block = ([^]u8)(runtime.heap_alloc(max(n, 1), false)); block == nil {
				ns_release(old.ns[i:old.ns_len])
				if w.ns != old.ns && old.ns != nil {
					runtime.heap_free(old.ns)
				}
				return false
			}
			intrinsics.mem_copy_non_overlapping(block, entry.uri.p, n)
			entry.uri.p = block
			if entry.moved {
				entry.prefix.p = block[entry.uri.n:]
			}
		}
		if mine.owned {
			runtime.heap_free(mine.uri.p)
		}
		w.ns[i] = entry
		w.ns_len += 1
	}
	if from.walk.ns_len < old.ns_len {
		ns_release(old.ns[from.walk.ns_len:old.ns_len])
	}
	if w.ns != old.ns && old.ns != nil {
		runtime.heap_free(old.ns)
	}
	if from.walk.dtd == nil {
		dtd_free(w.dtd)
		w.dtd = nil
	} else if w.dtd == nil || !dtd_copy(w.dtd, from.walk.dtd) {
		dtd_free(w.dtd)
		if w.dtd = dtd_clone(from.walk.dtd); w.dtd == nil {
			return false
		}
	}
	return true
}

// Copies out of the window `src` of `n` bytes what the walk `paused` reads again from the `pin` the window keeps to
// offset `keep`: the names of its open elements and its namespace declarations, so the window may drop those bytes.
// False when memory runs out, with nothing copied that the walk does not point to.
@(private)
paused_keep :: proc "contextless" (paused: ^Paused($H), src: [^]u8, n, pin, keep: u64) -> bool {
	w := &paused.walk
	open := w.frames[:max(paused.e, 1) - 1]
	below :: #force_inline proc "contextless" (p, src: [^]u8, n, pin, keep: u64) -> bool {
		off, held := inside(p, src, n)
		return held && off >= pin && off < keep
	}
	// The names copied before stay where they are unless a name the window drops joins them.
	size, dropped := 0, false
	for f in open {
		if below(f.tag, src, n, pin, keep) {
			size, dropped = size + int(f.name_n) + 1, true
		} else if paused.names != nil && inside_any(f.tag, paused.names, u64(paused.names_n)) {
			size += int(f.name_n) + 1
		}
	}
	if dropped || size == 0 && paused.names != nil {
		names: [^]u8
		if size > 0 {
			if names = ([^]u8)(runtime.heap_alloc(size, false)); names == nil {
				return false
			}
		}
		at := 0
		for &f in open {
			if below(f.tag, src, n, pin, keep) || paused.names != nil && inside_any(f.tag, paused.names, u64(paused.names_n)) {
				intrinsics.mem_copy_non_overlapping(names[at:], f.tag, int(f.name_n) + 1)
				f.tag = names[at:]
				at += int(f.name_n) + 1
			}
		}
		if paused.names != nil {
			runtime.heap_free(paused.names)
		}
		paused.names, paused.names_n = names, size
	}
	for &entry in w.ns[:w.ns_len] {
		if entry.moved || !(entry.prefix.n > 0 && below(entry.prefix.p, src, n, pin, keep) || !entry.owned && entry.uri.n > 0 && below(entry.uri.p, src, n, pin, keep)) {
			continue
		}
		block := ([^]u8)(runtime.heap_alloc(int(entry.uri.n + entry.prefix.n), false))
		if block == nil {
			return false
		}
		intrinsics.mem_copy_non_overlapping(block, entry.uri.p, int(entry.uri.n))
		intrinsics.mem_copy_non_overlapping(block[entry.uri.n:], entry.prefix.p, int(entry.prefix.n))
		if entry.owned {
			runtime.heap_free(entry.uri.p)
		}
		entry.uri.p, entry.prefix.p = block, block[entry.uri.n:]
		entry.owned, entry.moved = true, true
	}
	return true
}

// Points the walk `paused` at the window `src` of `n` bytes, whose bytes past the `pin` it kept from the window `old`
// of `old_n` bytes moved `delta` bytes on: each offset past the pin loses `delta`, and every pointer into `old` moves
// to its byte in `src`.
@(private)
paused_rebase :: proc "contextless" (paused: ^Paused($H), old: [^]u8, old_n: u64, src: [^]u8, n, delta, pin: u64) {
	moved :: #force_inline proc "contextless" (p, old: [^]u8, old_n: u64, src: [^]u8, delta, pin: u64) -> [^]u8 {
		if off, held := inside(p, old, old_n); held && (off < pin || off >= pin + delta) {
			return src[records.shifted(off, delta, pin):]
		}
		return p
	}
	w := &paused.walk
	w.base = src
	paused.at = records.shifted(paused.at, delta, pin)
	for &f in w.frames[:paused.e] {
		f.tag = moved(f.tag, old, old_n, src, delta, pin)
		f.text_lo = records.shifted(f.text_lo, delta, pin)
	}
	for &entry in w.ns[:w.ns_len] {
		if !entry.moved {
			entry.prefix.p = moved(entry.prefix.p, old, old_n, src, delta, pin)
		}
		if !entry.owned {
			entry.uri.p = moved(entry.uri.p, old, old_n, src, delta, pin)
		}
	}
	if d := w.dtd; d != nil {
		d.src = src[:n]
		// A pinned window keeps the DTD's offsets.
		if pin == 0 {
			dtd_shift(d.view, delta)
		}
	}
}

// The offset of `p` in the `n` bytes at `src`, and whether it lies there or at their end.
@(private)
inside :: #force_inline proc "contextless" (p, src: [^]u8, n: u64) -> (u64, bool) {
	off := u64(uintptr(p)) - u64(uintptr(src))
	return off, uintptr(p) >= uintptr(src) && off <= n
}

@(private)
inside_any :: #force_inline proc "contextless" (p, src: [^]u8, n: u64) -> bool {
	_, held := inside(p, src, n)
	return held
}
