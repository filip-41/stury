package core

import "base:runtime"

// `Token_Cursor` holds where a walk a hook stopped stands, for a format's `walk_resume` to continue it: the text's
// address and length, and on the default heap the tokens past the stop. At its first stop the walk reads on to the
// text's end without the hook and holds every token it would give, with the result of the whole text, which the resumes
// give as the walk would. A cursor so resumes after any token, a `Skip` given on a held token hides what it hides in a
// walk, and a fault past the stop comes after the held tokens. A stop's `hi` is one past the span of the token it
// stopped on. A walk that ends frees what its cursor holds, and `cursor_free` frees a cursor no resume ended.
Token_Cursor :: struct {
	src:  [^]u8,
	n:    u64,
	held: ^Held_Tokens,
}

// What a cursor holds past a stop: the tokens from the one after the stop, the next one to give, the hook's registers,
// the mark a `Skip` hides up to, and the whole text's result.
Held_Tokens :: struct {
	queue: [dynamic]Held_Token,
	next:  int,
	regs:  Hook_Regs,
	mute:  u64,
	hi:    u64,
	fault: Maybe(Fault),
}

// A held token and the mark a `Skip` on it hides up to, 0 for none, or with `close` the place the tokens of mark `at`
// end.
Held_Token :: struct {
	token: Token,
	at:    u64,
	close: bool,
}

// The hook a walk with a cursor runs, `holding_hook`: the caller's until it stops, then one that holds each token. The
// format's walk sets `skip_at` before each token, and holds a close mark with `hold` once `held` is set.
Holding :: struct($H: typeid) {
	hooks:     ^H,
	held:      ^Held_Tokens,
	skip_at:   u64,
	stop_hi:   u64,
	no_memory: bool,
}

// The step of `Holding`, which a format's walk with a cursor binds to the caller's `on`.
holding_hook :: #force_inline proc "contextless" (s: ^Holding($H), regs: Hook_Regs, t: Token, $on: proc "contextless" (h: ^H, s: Hook_Regs, t: Token) -> (Hook_Regs, Action)) -> (Hook_Regs, Action) {
	if s.held == nil {
		r, a := on(s.hooks, regs, t)
		if a != .Stop {
			return r, a
		}
		context = runtime.default_context()
		if s.held = new(Held_Tokens); s.held == nil {
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

// Adds `e` to the held tokens. False when the memory ran out, which ends the walk.
hold :: proc "contextless" (s: ^Holding($H), e: Held_Token) -> bool {
	context = runtime.default_context()
	if _, err := append(&s.held.queue, e); err != nil {
		s.no_memory = true
		return false
	}
	return true
}

// Ends a walk of `src` that ran through `s` and had `hi` and `fault` for the whole text: with no stop the walk's result,
// and with one the stop's, its tokens handed to `cursor` and the registers it saved in `regs`.
holding_end :: proc "contextless" (src: []u8, cursor: ^Token_Cursor, s: ^Holding($H), regs: ^Hook_Regs, hi: u64, fault: Maybe(Fault), rules: ^Rules) -> (u64, Maybe(Fault)) {
	cursor_free(cursor)
	cursor.src, cursor.n = raw_data(src), u64(len(src))
	if s.no_memory {
		cursor.held = s.held
		cursor_free(cursor)
		return 0, Fault{rules = rules, kind = .No_Memory}
	}
	if s.held == nil {
		return hi, fault
	}
	s.held.hi, s.held.fault = hi, fault
	cursor.held = s.held
	regs^ = s.held.regs
	return s.stop_hi, nil
}

// Continues the walk `cursor` holds a stop of, over the same `src`, from the token after the one it stopped on, as a
// format's `walk_resume` does. A cursor that holds no stop, or that a walk of another text filled, is refused with
// `.Bad_Option` under `rules`.
cursor_resume :: proc "contextless" (src: []u8, cursor: ^Token_Cursor, h: ^$H, regs: ^Hook_Regs, $on: proc "contextless" (h: ^H, s: Hook_Regs, t: Token) -> (Hook_Regs, Action), rules: ^Rules) -> (hi: u64, fault: Maybe(Fault)) {
	held := cursor.held
	if held == nil || cursor.src != raw_data(src) || cursor.n != u64(len(src)) {
		return 0, Fault{rules = rules, kind = .Bad_Option}
	}
	if regs != nil {
		held.regs = regs^
	}
	a: Action
	for a != .Stop && held.next < len(held.queue) {
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
		held.regs, a = on(h, held.regs, e.token)
		if a == .Skip && e.at != 0 {
			held.mute = e.at
		}
		hi = e.token.lo + u64(e.token.n)
	}
	if regs != nil {
		regs^ = held.regs
	}
	if a == .Stop {
		return
	}
	hi, fault = held.hi, held.fault
	cursor_free(cursor)
	return
}

// Frees what `cursor` holds, a stop no resume ended.
cursor_free :: proc "contextless" (cursor: ^Token_Cursor) {
	if cursor.held != nil {
		context = runtime.default_context()
		delete(cursor.held.queue)
		free(cursor.held)
		cursor.held = nil
	}
}
