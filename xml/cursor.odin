package xml

import "base:runtime"
import core "../core"

// `Cursor` holds where a walk a hook stopped stands, for `walk_resume` to continue it: the text's address and length,
// and on the default heap the tokens past the stop. At its first stop the walk reads on to the text's end without the
// hook and holds every token it would give, with the result of the whole text, which the resumes give as the walk
// would. A cursor so resumes after any token, a `Skip` given on a held token hides what it hides in a walk, and a
// fault past the stop comes after the held tokens. A stop's `hi` is one past the span of the token it stopped on. A
// walk that ends frees what its cursor holds, and `cursor_destroy` frees a cursor no resume ended.
Cursor :: struct {
	src:  [^]u8,
	n:    u64,
	held: ^Held,
}

// What a cursor holds past a stop: the tokens from the one after the stop, the next one to give, the hook's registers,
// the open count a `Skip` hides up to, and the whole text's result.
@(private)
Held :: struct {
	queue: [dynamic]Held_Token,
	next:  int,
	regs:  core.Hook_Regs,
	mute:  u64,
	hi:    u64,
	fault: Maybe(core.Fault),
}

// A held token and the open count a `Skip` on it hides, as `emit` takes it, or with `close` the place the element of
// open count `at` ends.
@(private)
Held_Token :: struct {
	token: core.Token,
	at:    u64,
	close: bool,
}

// The hook a walk with a cursor runs: the caller's until it stops, then one that holds each token. `emit` sets
// `skip_at` before each token, and `st_closed` adds the close marks once `held` is set.
@(private)
Holding :: struct($H: typeid) {
	hooks:     ^H,
	held:      ^Held,
	skip_at:   u64,
	stop_hi:   u64,
	no_memory: bool,
}

// Whether `cursor` holds a stop that `walk_resume` continues, false once the walk it fills ended.
can_resume :: #force_inline proc "contextless" (cursor: ^Cursor) -> bool {
	return cursor.held != nil
}

// Continues the walk `cursor` holds a stop of, over the same `src`, from the token after the one it stopped on.
// `regs` is passed to the first token in place of the registers the stop saved, unless it is nil. The results are
// `walk`'s. A cursor that holds no stop, or that a walk of another text filled, is refused with `.Bad_Option`.
walk_resume :: proc "contextless" (src: []u8, cursor: ^Cursor, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	held := cursor.held
	if held == nil || cursor.src != raw_data(src) || cursor.n != u64(len(src)) {
		return 0, core.Fault{rules = &RULES, kind = .Bad_Option}
	}
	if regs != nil {
		held.regs = regs^
	}
	for held.next < len(held.queue) {
		e := held.queue[held.next]
		held.next += 1
		if e.close {
			if held.mute == e.at {
				held.mute = 0
			}
			continue
		}
		if held.mute != 0 {
			continue
		}
		a: core.Action
		held.regs, a = on(h, held.regs, e.token)
		if a == .Skip && e.at != 0 {
			held.mute = e.at
		}
		if a == .Stop {
			if regs != nil {
				regs^ = held.regs
			}
			return e.token.lo + u64(e.token.n), nil
		}
	}
	if regs != nil {
		regs^ = held.regs
	}
	hi, fault = held.hi, held.fault
	cursor_destroy(cursor)
	return
}

// Frees what `cursor` holds, a stop no resume ended. It is a member of `destroy`.
@(private)
cursor_destroy :: proc "contextless" (cursor: ^Cursor) {
	if cursor.held != nil {
		held_free(cursor.held)
		cursor.held = nil
	}
}

@(private)
held_free :: proc "contextless" (held: ^Held) {
	context = runtime.default_context()
	delete(held.queue)
	free(held)
}

// `walk` with a cursor: the walk of the whole text through `Holding`, which hands its held tokens to `cursor` when the
// hook stopped.
@(private)
walk_holding :: proc "contextless" (src: []u8, lo: u64, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor) -> (hi: u64, fault: Maybe(core.Fault)) {
	holding :: proc "contextless" (s: ^Holding(H), regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
		if s.held == nil {
			r, a := on(s.hooks, regs, t)
			if a != .Stop {
				return r, a
			}
			context = runtime.default_context()
			if s.held = new(Held); s.held == nil {
				s.no_memory = true
				return r, .Stop
			}
			s.held.regs, s.stop_hi = r, t.lo + u64(t.n)
			return r, .Next
		}
		if !hold(s, Held_Token{token = t, at = s.skip_at}) {
			return regs, .Stop
		}
		return regs, .Next
	}
	cursor_destroy(cursor)
	cursor.src, cursor.n = raw_data(src), u64(len(src))
	zero: core.Hook_Regs
	r := regs if regs != nil else &zero
	s := Holding(H) {
		hooks = h,
	}
	hi, fault, _ = core.result_of(walk_document(src, lo, opts, &s, r, holding, nil), &RULES)
	if s.no_memory {
		if s.held != nil {
			held_free(s.held)
		}
		return 0, core.Fault{rules = &RULES, kind = .No_Memory}
	}
	if s.held == nil {
		return
	}
	s.held.hi, s.held.fault = hi, fault
	cursor.held = s.held
	r^ = s.held.regs
	return s.stop_hi, nil
}

// Adds `e` to the held tokens. False when the memory ran out, which ends the walk.
@(private)
hold :: proc "contextless" (s: ^Holding($H), e: Held_Token) -> bool {
	context = runtime.default_context()
	if _, err := append(&s.held.queue, e); err != nil {
		s.no_memory = true
		return false
	}
	return true
}
