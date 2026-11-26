package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Walks a text in pieces. Runs the `LAX` walk over one window, tracks each token's place in the grammar and the open
// containers, and ends at the window's end as at a token. The walk of the next window continues from the place past
// the last token and reads again from there. A string, number or JSON5 unquoted key that the window cuts short is read
// on in the next window from where the last stopped, with the spelling its bytes so far gave. So is a run of white
// space and comments, whose comments wait for the token past it. Any other token is read again whole.
//
// Inside a container whose hook answered `Skip`, `Keep`, `Keep_Stubs` or `Rest`, and in the value of a member whose key
// it answered `Skip` for, the walk continues in the same states and gives each token to no hook, or to the inner hook
// of the hook's `Keeps`. A window can end inside such a container as anywhere else.

// The places a walk of a text in pieces continues from, past the last token it gave.
@(private)
PLACE_ROOT :: u8(0) // before the root value
@(private)
PLACE_OPEN :: u8(1) // past an open bracket
@(private)
PLACE_AFTER :: u8(2) // past a value
@(private)
PLACE_COLON :: u8(3) // past a key, before its colon
@(private)
PLACE_VALUE :: u8(4) // past a key's colon, which a comment followed
@(private)
PLACE_MEMBER :: u8(5) // past a comma, which a comment followed
@(private)
PLACE_TAIL :: u8(6) // past the root value, whose foot only the last window judges

// What JSON's walk keeps from one piece to the next.
@(private)
Piece :: struct {
	using state: hook.Piece_State,
	place:       u8, // the format's place in its grammar past the last token, 0 at the text's start
	last:        u64, // one past the last token the walk gave, or past the run of comments `run` held back before it
	nest_open:   u64, // with `nest`, the containers open inside the one the hook passed
	levels:      [dynamic]u32,
	// The comments of a run of white space and comments the window ended inside, which wait for the token past the run
	// to decide their roles, and are given to the hook in the window the run ends in, which may no longer hold their
	// bytes: a hook that reads a comment's bytes holds them itself.
	comments:    [dynamic]tape.Token,
	gaps:        ^Gaps, // with `GAPS`, the walk's learned gap table across pieces
	cut:         Cut_Token,
	run:         Cut_Run,
}

@(private)
piece_free :: proc(p: ^tape.Pieces) {
	s := (^Piece)(p.state)
	delete(s.levels)
	delete(s.comments)
	free(s.gaps, hook.piece_lists(p))
	hook.piece_release(p)
}

// A token the window ended inside, read up to `on`, which the next window reads on from rather than from its first
// byte. `on` is 0 for none.
@(private)
Cut_Token :: struct {
	lo, on:   u64,
	digits:   [2]u64, // a number's integer and fraction digits so far
	spelling: u16, // the spelling so far
	part:     u8, // the part of the token `on` is in
	quote:    u8, // a string's closing quote
}

// A run of white space and comments the window ended inside, read up to `on`, which the next window reads on from. Its
// comments wait in `Piece.comments`.
@(private)
Cut_Run :: struct {
	state:   u8, // the state the run is read in, 0 for none
	part:    u8, // the part of the run `on` is in
	place:   u8, // the place in the grammar before the run's first comment
	line:    bool, // a line ends in the run before `on`
	crossed: bool, // the run crossed the one comma it may hold
	held:    bool, // the comment `on` is in holds a line end
	comma:   u32, // with `crossed`, the comments before the comma
	lo:      u64, // the first byte of the comment `on` is in
	on:      u64,
}

// The window of a text in pieces that a walk reads.
@(private)
Piece_Walk :: struct {
	s:       ^Piece,
	from:    u64, // the window's first byte in the whole text
	end:     u64, // one past its last
	more:    bool, // bytes may follow the window
	cut:     bool, // set by the walk: a scalar reached the window's end, so the next window reads it again
	refused: bool, // set by the walk: memory for an open container was refused
	ended:   bool, // set by the walk: the window ended the read inside its root value, or before its foot
	foot:    bool, // set by the walk: it read the root's foot on from a run of comments the last window held back
	ctx:     ^runtime.Context,
}

// Gives token `t` of a text in pieces to the hook, or stops the walk at a scalar that the window's end cuts, which a
// later window may make longer. Counts `Budget.steps` as `give` does.
@(private)
give_piece :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, t: tape.Token) -> hook.Action {
	if t.kind <= .Plain && t.role <= .Key && (t.kind != .String || t.spelling & tape.SPELLING_QUOTED == 0) && t.lo + u64(t.n) >= pw.end && pw.more {
		pw.cut = true
		if t.kind == .Number {
			piece_cut_number(w, pw, t)
		}
		when S == .Json5 {
			if t.kind == .String {
				pw.s.cut = {lo = t.lo, on = t.lo + u64(t.n), spelling = t.spelling, part = CUT_IDENT}
			}
		}
		return .Stop
	}
	opens := t.kind > .Plain && t.kind != .End
	if opens {
		w.steps[0] -= 1
		if w.steps[0] == 0 {
			return .Stop
		}
	}
	if !piece_track(w, pw, t) {
		return .Stop
	}
	when .Skips in C {
		if pw.s.nest != .None {
			// The inner hook of a kept container takes no credit.
			t := t
			when .Credits in C {
				if t.role == .Key {
					t.spelling = tape.without_credit(t.spelling)
				}
			}
			return piece_nested(w, pw, on, hs, t)
		}
	}
	a: hook.Action
	hs^, a = on(w.hooks, hs^, t)
	when .Skips in C {
		if opens && a >= .Skip && a <= .Keep_Stubs {
			return piece_nest(w, pw, hs, t, a)
		}
		// The states read the member's value as they would any other, and it gives no token.
		if t.role == .Key && a == .Skip {
			pw.s.nest, pw.s.nest_open = .Pass, 0
			return .Next
		}
	}
	return a
}

// Records token `t` in the open containers and sets the place past it. False when memory for one more container is
// refused.
@(private)
piece_track :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk, t: tape.Token) -> bool #no_bounds_check {
	s := pw.s
	opened := (^runtime.Raw_Dynamic_Array)(&s.opened)
	levels := ([^]hook.Open_Level)(opened.data)
	n := opened.len
	if t.role > .Key {
		piece_fact(w, pw, t)
		return true
	}
	if t.kind == .End {
		opened.len = n - 1
		if n > 1 {
			levels[n - 2].key.kind = .End
		}
		s.place, s.last = PLACE_AFTER, t.lo + 1
		return true
	}
	if n > 0 && t.role == .Value {
		levels[n - 1].count += 1
	}
	if t.kind > .Plain {
		if n == opened.cap {
			if !piece_open_grow(pw) {
				pw.refused = true
				return false
			}
			levels = ([^]hook.Open_Level)(opened.data)
		}
		levels[n] = {key = {kind = .End}, object = t.kind == .Object, name = -1}
		opened.len = n + 1
		s.place, s.last = PLACE_OPEN, t.lo + 1
		return true
	}
	s.last = t.lo + u64(t.n) + u64(t.kind == .String && t.spelling & tape.SPELLING_QUOTED != 0)
	if t.role == .Key {
		levels[n - 1].key, levels[n - 1].name = t, -1
		s.place = PLACE_COLON
	} else {
		if n > 0 {
			levels[n - 1].key.kind = .End
		}
		s.place = PLACE_AFTER
	}
	return true
}

// Records comment `t`. A colon or comma between the last token and the comment sets the place past it.
@(private, cold)
piece_fact :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk, t: tape.Token) #no_bounds_check {
	s := pw.s
	for k := s.last; k < t.lo; k += 1 {
		switch w.base[k] {
		case ':':
			s.place = PLACE_VALUE
		case ',':
			s.place = PLACE_MEMBER
		}
	}
	s.last = t.lo + u64(t.n)
}

@(private, cold)
piece_open_grow :: #force_no_inline proc "contextless" (pw: ^Piece_Walk) -> bool {
	context = pw.ctx^
	return reserve(&pw.s.opened, max(2 * cap(pw.s.opened), 16)) == nil
}

// Applies the hook's action `a` for the container that token `t` opens. The walk reads the container in the same
// states. For `Keep` and `Keep_Stubs` it gives the container's tokens to the inner hook, starting with the open
// bracket, and for `Skip` and `Rest` to no hook.
@(private, cold)
piece_nest :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk, hs: ^hook.Regs, t: tape.Token, a: hook.Action) -> hook.Action {
	s := pw.s
	s.nest_open = 0
	#partial switch a {
	case .Skip:
		s.nest = .Skip
	case .Rest:
		s.nest = .Rest
		w.rested = true
	case .Keep, .Keep_Stubs:
		when .Keeps in C {
			s.nest = .Keep if a == .Keep else .Keep_Stubs
			return piece_keep(w, hs, t, s.nest, true)
		}
	}
	return .Next
}

// Gives token `t` of a container the hook passed over to the inner hook that keeps it, if any.
@(private)
piece_nested :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, t: tape.Token) -> hook.Action {
	s := pw.s
	nest := s.nest
	if nest == .Rest {
		return .Next
	}
	if nest == .Pass {
		// The facts before the value are the hook's, and the value ends at its scalar or at the `End` of its container.
		if t.role > .Key {
			if s.nest_open == 0 {
				a: hook.Action
				hs^, a = on(w.hooks, hs^, t)
				return a
			}
		} else if t.kind == .End {
			s.nest_open -= 1
		} else if t.kind > .Plain {
			s.nest_open += 1
		}
		if s.nest_open == 0 && t.role <= .Key {
			s.nest = .None
		}
		return .Next
	}
	if t.kind == .End {
		if s.nest_open == 0 {
			s.nest = .None
			when .Keeps in C {
				if nest != .Skip && piece_keep(w, hs, t, nest, false) == .Stop {
					return .Stop
				}
				when .Rooms in C {
					w.rooms = hook.rooms_end(w.hooks)
				}
			}
			a: hook.Action
			hs^, a = on(w.hooks, hs^, t)
			return a
		}
		s.nest_open -= 1
	} else if t.kind > .Plain {
		s.nest_open += 1
	}
	when .Keeps in C {
		if nest != .Skip {
			return piece_keep(w, hs, t, nest, false)
		}
	}
	return .Next
}

// Gives token `t` to the inner hook of the hook's `Keeps`, with stubs for `Keep_Stubs`, as `keep_through` does. Before
// that it checks the inner hook's room, which the walk does only for a hook with `.Rooms`. With `opens`, `t` is the
// open bracket of the kept container, and the walk's room check moves to the inner hook's room.
@(private)
piece_keep :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: ^hook.Regs, t: tape.Token, nest: hook.Nest, opens: bool) -> hook.Action {
	K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
	Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
	IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
	when .Rooms in IC {
		inner := (^Inner)(hook.keeps_inner(w.hooks))
		if t.kind != .End && t.role <= .Key && uintptr(hs.a) == hook.rooms_end(inner) && !hook.rooms_grow(inner, hs, t.lo) {
			w.piece[0].refused = true
			return .Stop
		}
		when .Rooms in C {
			if opens {
				w.rooms = hook.rooms_end(inner)
			}
		}
	}
	a: hook.Action
	if nest == .Keep_Stubs {
		hs^, a = hook.keeps_give(w.hooks, hs^, t, true)
	} else {
		hs^, a = hook.keeps_give(w.hooks, hs^, t, false)
	}
	return a
}

// Whether more bytes may follow the walk's window.
@(private)
piece_more :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C)) -> bool {
	when LAX {
		return w.piece[0] != nil && w.piece[0].more
	} else {
		return false
	}
}

// Returns `Truncated` for fault `kind` at `q` when bytes may follow the window and `q` may be the start of a longer
// token: a `/` that may open a comment, or in JSON5 a lead byte of non-ASCII white space whose next bytes the window
// does not hold. Returns `kind` otherwise.
@(private)
piece_short :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), q, end: [^]u8, kind: tape.Fault_Kind) -> tape.Fault_Kind {
	when LAX && S != .Json {
		if kind == .Bad_Char && piece_more(w) && q < end && (q[0] == '/' && q[1:] == end || S == .Json5 && q[0] >= 0xc2 && intrinsics.ptr_sub(end, q) < 3) {
			return .Truncated
		}
	}
	return kind
}

// Whether the walk is inside a container its hook passed over with `Skip` or `Rest`, or a member's value it passed,
// whose tokens no hook stores.
@(private)
piece_passes :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C)) -> bool {
	when LAX && .Skips in C {
		return w.piece[0] != nil && (w.piece[0].s.nest == .Skip || w.piece[0].s.nest == .Rest || w.piece[0].s.nest == .Pass)
	} else {
		return false
	}
}

// Whether the walk is inside a container whose tokens go to the inner hook of the hook's `Keeps`.
@(private)
piece_keeps :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C)) -> bool {
	when LAX {
		return w.piece[0] != nil && (w.piece[0].s.nest == .Keep || w.piece[0].s.nest == .Keep_Stubs)
	} else {
		return false
	}
}

// Grows the room of the inner hook that receives a kept container's tokens, after the hook answered `Grow`.
@(private, cold)
piece_grow_inner :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: ^hook.Regs) -> bool {
	K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
	Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
	IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
	when .Rooms in IC {
		inner := (^Inner)(hook.keeps_inner(w.hooks))
		if !hook.rooms_grow(inner, hs, w.grow) {
			return false
		}
		w.rooms = hook.rooms_end(inner)
	}
	return true
}

// Walks the window of a text in pieces from its place. For a window that starts the text, `p` is past the root's white
// space. The walk continues with the levels, gaps, budget and nest the last window left. The containers still open
// have no gaps, because their slots were in registers.
@(private)
piece_walk :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk, p, end: [^]u8, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result #no_bounds_check {
	s := pw.s
	if !s.started || s.place == PLACE_ROOT && s.last == 0 && s.cut.on == 0 && s.run.state == 0 {
		return enter(p, end, indent_start(w), w, w.regs^, GAP_START, on)
	}
	when ODIN_DEBUG || ODIN_SANITIZER_FLAGS != {} {
		if (piece_cut_keep(s.cut) if s.cut.on != 0 else piece_keep_from(s, S)) < pw.from {
			runtime.panic_contextless("json: a read of a text in pieces resumes before its window")
		}
	}
	when .Skips in C {
		w.rested = s.rested
	}
	w.tolerated, w.steps[0] = s.tolerated, s.steps
	if s.gaps != nil {
		w.gaps = s.gaps^
		gaps_drop(&w.gaps, pw.from)
	}
	open := u64(len(s.opened))
	if open > w.room && !hook.levels_room(w, open) {
		return too_deep(w, w.regs^, w.base[s.last:], hook.WALK_NO_MEMORY)
	}
	intrinsics.mem_copy_non_overlapping(w.stack, raw_data(s.levels), int(open) * size_of(u32))
	w.depth = min(w.room, w.limit)
	when .Levels in C {
		w.depth = min(w.depth, open + u64(hook.levels_held(w.hooks)) - w.regs.c)
	}
	when .Keeps in C {
		if s.nest == .Keep || s.nest == .Keep_Stubs {
			piece_keep_rooms(w)
		}
	}
	if s.cut.on != 0 {
		return piece_resume(w, pw, end, on)
	}
	if s.run.state != 0 {
		return piece_run(w, pw, w.regs^, end, on)
	}
	q := w.base[s.last:]
	if s.place == PLACE_TAIL || s.place == PLACE_AFTER && open == 0 {
		return done(w, w.regs^, q)
	}
	if s.place == PLACE_ROOT {
		// Past the comments before the root value, which the hook was given.
		return enter_place(PLACE_VALUE, kernel.skip_ws(q, end), end, 0, w, w.regs^, on)
	}
	d := open << 1 | u64(s.opened[open - 1].object)
	return enter_place(s.place, q, end, d, w, w.regs^, on)
}

// Drops the gaps recorded before offset `from`, the first byte of a window, as a gap is matched against the bytes it
// was recorded from.
@(private, cold)
gaps_drop :: proc "contextless" (gaps: ^Gaps, from: u64) {
	for bits := gaps.live; bits != 0; bits &= bits - 1 {
		row := u64(intrinsics.count_trailing_zeros(bits))
		for &g in gaps.slots[row * GAP_MEMBERS:(row + 1) * GAP_MEMBERS] {
			if g.n != GAP_DEAD && u64(g.lo) < from {
				g.n = 0
			}
		}
	}
}

// The parts of a token a window cut short, `Cut_Token.part`.
@(private)
CUT_STRING :: u8(0)
@(private)
CUT_INT :: u8(1) // a number's integer digits
@(private)
CUT_FRAC :: u8(2) // its fraction digits
@(private)
CUT_EXP :: u8(3) // its exponent digits
@(private)
CUT_HEX :: u8(4) // a JSON5 number's hex digits
@(private)
CUT_IDENT :: u8(5) // a JSON5 unquoted key

// Records where the string at `p`, which the window's end cut short, is read on from.
@(private, cold)
piece_cut_string :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p, end: [^]u8) {
	quote := p[0] if S == .Json5 else '"'
	q, spelling, _ := string_exact_on(S == .Json5, quote, p[1:], end, w.tolerate, tape.SPELLING_ASCII)
	w.piece[0].s.cut = {lo = at(w, p), on = at(w, q), spelling = spelling, part = CUT_STRING, quote = quote}
}

// Records where the number token `t`, which the window's end cut short in a run of digits, is read on from. A number
// cut after its first integer digit or after its point is read again whole, because the next byte decides whether a
// lone `0` is valid and changes the spelling of a JSON5 `5.`.
@(private, cold)
piece_cut_number :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk, t: tape.Token) #no_bounds_check {
	b, k, e := w.base, t.lo, t.lo + u64(t.n)
	c := Cut_Token{lo = t.lo, on = e}
	if b[k] == '-' || b[k] == '+' {
		c.spelling = u16(Number_Spelling.Decimal) if b[k] == '+' else 0
		k += 1
	}
	if b[k] - '0' >= 10 && b[k] != '.' {
		return
	}
	if t.spelling & tape.NUMBER_KIND == u16(Number_Spelling.Hex) {
		c.spelling, c.part = u16(Number_Spelling.Hex), CUT_HEX
	} else {
		run := k
		for k < e && b[k] - '0' < 10 {
			k += 1
		}
		c.digits[0], c.part = k - run, CUT_INT
		if k < e && b[k] == '.' {
			k += 1
			run = k
			for k < e && b[k] - '0' < 10 {
				k += 1
			}
			c.digits[1], c.part = k - run, CUT_FRAC
			if c.digits[0] == 0 || c.digits[1] == 0 {
				c.spelling = u16(Number_Spelling.Decimal)
			}
		}
		if k < e {
			c.part = CUT_EXP
		} else if c.digits[c.part - CUT_INT] < 1 + u64(c.part == CUT_INT) {
			return
		}
	}
	pw.s.cut = c
}

// Reads on the token the last window cut short, gives it to the hook once it ends, and continues past it.
@(private, cold)
piece_resume :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk, end: [^]u8, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	s := pw.s
	c := s.cut
	s.cut = {}
	hs := w.regs^
	open := u64(len(s.opened))
	object := open > 0 && s.opened[open - 1].object
	q: [^]u8
	t: tape.Token
	kind: tape.Fault_Kind
	if c.part == CUT_STRING {
		q, t.spelling, kind = string_exact_on(S == .Json5, c.quote, w.base[c.on:], end, w.tolerate, c.spelling)
		if kind == .Truncated && pw.more {
			s.cut, s.cut.on, s.cut.spelling = c, at(w, q), t.spelling
		}
		if kind != .None {
			return fault(w, hs, end if kind == .Truncated else q, kind)
		}
		w.tolerated ||= t.spelling & tape.SPELLING_LAX != 0
		key := object && s.place != PLACE_COLON && s.place != PLACE_VALUE
		t = {c.lo + 1, u32(at(w, q) - c.lo - 2), .String, .Key if key else .Value, t.spelling | tape.SPELLING_QUOTED}
	} else if c.part == CUT_IDENT {
		when S == .Json5 {
			esc: bool
			q, esc, kind = ident5_on(w.base[c.lo:], w.base[c.on:], end, c.spelling != 0)
			if q >= end && pw.more && (kind == .None || kind == .Truncated) {
				from := at(w, end) if kind == .None else piece_ident_cut(w, c.on, end)
				s.cut, s.cut.on, s.cut.spelling, kind = c, from, tape.SPELLING_DECODE if esc else 0, .Truncated
			}
			if kind != .None {
				return fault(w, hs, end if kind == .Truncated else q, kind)
			}
			t = {c.lo, u32(at(w, q) - c.lo), .String, .Key, tape.SPELLING_DECODE if esc else 0}
		}
	} else {
		if q, t.spelling, kind = piece_number_on(w, pw, c, end); kind != .None {
			return fault(w, hs, q, kind)
		}
		t = {c.lo, u32(at(w, q) - c.lo), .Number, .Value, t.spelling}
	}
	if too_wide(w.base[c.lo:], q) {
		return fault(w, hs, w.base[c.lo:], .Too_Wide)
	}
	for {
		a := emit_token(w, on, &hs, t)
		if a == .Stop {
			return stopped(w, hs, q)
		}
		if !grows(C, a) {
			break
		}
		if !grow_room(w, &hs) {
			return stopped(w, hs, w.base[c.lo:])
		}
	}
	if open == 0 {
		return done(w, hs, q)
	}
	return enter_place(PLACE_COLON if t.role == .Key else PLACE_AFTER, q, end, open << 1 | u64(object), w, hs, on)
}

// Returns the end of number `c` and its spelling, read on from its digits at `c.on`, or the fault. A number that the
// window's end cuts short again is kept for the next window and answers `Truncated`, so each window after one that cut
// a number reads on from bytes past the last window's. Past its run of digits, the grammar reads on from the run's last
// digit, which gives the same spelling as the whole run would.
@(private)
piece_number_on :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk, c: Cut_Token, end: [^]u8) -> (q: [^]u8, spelling: u16, kind: tape.Fault_Kind) #no_bounds_check {
	c := c
	p := w.base[c.on:]
	q = spell.hex_digit_end(p, end) if c.part == CUT_HEX else spell.digit_end(p, end)
	if c.part == CUT_INT || c.part == CUT_FRAC {
		c.digits[c.part - CUT_INT] += u64(intrinsics.ptr_sub(q, p))
	}
	if q >= end && pw.more {
		pw.s.cut, pw.s.cut.on = c, at(w, q)
		return end, 0, .Truncated
	}
	k := c.spelling & tape.NUMBER_KIND
	flags := tape.NUMBER_EXP if c.part == CUT_EXP else 0
	if q < end && (c.part == CUT_INT && (q[0] == '.' || q[0] | 0x20 == 'e') || c.part == CUT_FRAC && q[0] | 0x20 == 'e') {
		run := q
		tail: u16
		when S == .Json5 {
			q, tail, kind = number5(run[-1:], end)
		} else {
			wide: u64
			q, wide, kind = tape.number_scan(run[-1:], end, true, S == .Json5)
			tail = u16(wide)
		}
		if kind == .Truncated && pw.more {
			pw.s.cut, pw.s.cut.on = c, at(w, run)
		}
		if kind != .None {
			return
		}
		_, frac := tape.number_digits(tail)
		if c.part == CUT_INT {
			c.digits[1] = u64(frac)
		}
		k = max(k, tail & tape.NUMBER_KIND)
		if q >= end && pw.more {
			// A point with no digit after it reads on from the point, because a digit after it changes the spelling.
			at_run := tail & tape.NUMBER_EXP == 0 && frac == 0
			if !at_run {
				c.part, c.spelling = CUT_EXP if tail & tape.NUMBER_EXP != 0 else CUT_FRAC, k
			}
			pw.s.cut, pw.s.cut.on = c, at(w, run if at_run else q)
			return end, 0, .Truncated
		}
		flags |= tail & (tape.NUMBER_EXP | tape.NUMBER_POINT)
	}
	when H == hook.No_Hooks || .Unspelled in C {
		if k == u16(Number_Spelling.Json) {
			return q, 0, .None
		}
	}
	return q, tape.number_spelling(k, c.digits[0], c.digits[1]) | flags, .None
}

// Records where the unquoted key at `p`, whose escape or UTF-8 sequence the window's end cut short, is read on from.
// A key whose first character is cut is not recorded, because that character may be white space, which the walk of the
// next window reads from the last token.
@(private, cold)
piece_cut_ident :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p, end: [^]u8) {
	lo := at(w, p)
	on := piece_ident_cut(w, lo, end)
	if on == lo {
		return
	}
	_, esc, _ := ident5_on(p, p, end, false)
	w.piece[0].s.cut = {lo = lo, on = on, spelling = tape.SPELLING_DECODE if esc else 0, part = CUT_IDENT}
}

// The offset of the first byte of the `\u` escape or UTF-8 sequence that the window's `end` cuts in an identifier read
// on from `on`. It is the last `\` or lead byte, since a hex digit or continuation byte is neither.
@(private)
piece_ident_cut :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), on: u64, end: [^]u8) -> u64 #no_bounds_check {
	e := at(w, end)
	for k := e; k > on && k + 6 > e; k -= 1 {
		if w.base[k - 1] == '\\' || w.base[k - 1] >= 0xc0 {
			return k - 1
		}
	}
	return on
}

// The lowest offset that a read past a window ending inside token `c` needs of the token: the bytes from where it reads
// on, and for a number also the digit before, which the grammar reads on from. An unquoted key also needs the byte
// before, because the key may end where the next window starts, and that window's read then needs the byte before the
// key's end.
@(private)
piece_cut_keep :: proc "contextless" (c: Cut_Token) -> u64 {
	return c.on - u64(c.part != CUT_STRING)
}

// Moves the walk's room check to the room of the inner hook a kept container's tokens go to.
@(private)
piece_keep_rooms :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C)) {
	K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
	Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
	IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
	when .Rooms in IC && .Rooms in C {
		w.rooms = hook.rooms_end((^Inner)(hook.keeps_inner(w.hooks)))
	}
}

// Enters the walk at `place` of container `d` at `p`. A separate call whose frame has no base pointer, as `enter` has
// in a sanitizer build.
@(private)
enter_place :: #force_no_inline proc "contextless" (place: u8, p, end: [^]u8, d: u64, w: ^Walk($S, $H, $LAX, $C), hs: hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	switch place {
	case PLACE_OPEN:
		return st_open(p, end, d, indent_start(w), w, hs.a, hs.b, hs.c, GAP_OFF, on)
	case PLACE_COLON:
		return st_colon(p, end, d, indent_start(w), w, hs.a, hs.b, hs.c, GAP_OFF, on)
	case PLACE_VALUE:
		return st_value(piece_skip_white(p, end, S), end, d, indent_start(w), w, hs.a, hs.b, hs.c, GAP_OFF, on)
	case PLACE_MEMBER:
		return st_member_ws(p, end, d, indent_start(w), w, hs.a, hs.b, hs.c, GAP_OFF, on)
	}
	return st_after(p, end, d, indent_start(w), w, hs.a, hs.b, hs.c, GAP_OFF, on)
}

// Handles the bytes after the root value ending at `p`, in a window that more bytes may follow. A run of comments is
// held back, because only the last window ends the foot. Anything else is a fault.
@(private, cold)
piece_tail :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p, q, end: [^]u8, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := w.regs^
	when S != .Json {
		if opens_run(q, end, S) || piece_short(w, q, end, .Bad_Char) == .Truncated {
			return piece_hold_run(w, hs, p, RUN_FOOT, end, on)
		}
	}
	return fault(w, hs, q, .Bad_Char, .Trailing)
}

// The states a run of white space and comments is read in, `Cut_Run.state`: before a value, before a key, before
// a key's colon, past a value (a comma may lie in the run), and past the root value.
@(private)
RUN_VALUE :: u8(1)
@(private)
RUN_KEY :: u8(2)
@(private)
RUN_COLON :: u8(3)
@(private)
RUN_AFTER :: u8(4)
@(private)
RUN_FOOT :: u8(5)

// The parts of a run that `Cut_Run.on` can be in: between its comments, in a `//` comment or in a `/* */` comment.
@(private)
RUN_GAP :: u8(0)
@(private)
RUN_LINE :: u8(1)
@(private)
RUN_BLOCK :: u8(2)

// Holds back the run of white space and comments that the window's end cuts short, read in state `run` from `p`. In
// `RUN_AFTER` and `RUN_FOOT`, `p` is the end of the value, whose line a comment may share. Otherwise `p` is the run's
// first byte.
@(private, cold)
piece_hold_run :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: hook.Regs, p: [^]u8, run: u8, end: [^]u8, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	pw := w.piece[0]
	s := pw.s
	r := &s.run
	open := len(s.opened)
	object := open > 0 && s.opened[open - 1].object
	r.state, r.part, r.lo, r.on = run, RUN_GAP, 0, at(w, p)
	r.line, r.crossed, r.held, r.comma = run < RUN_AFTER, false, false, 0
	// The place past a key's colon, as a comment after the colon sets it.
	r.place = PLACE_VALUE if run == RUN_VALUE && object else s.place
	return piece_run(w, pw, hs, end, on)
}

// Reads on the run of white space and comments `s.run` from where it stopped, reading each byte once, as `comment_run`
// does. Keeps each comment for the hook with what its role needs: whether a line ended before it in the run, and
// whether the run's comma did. When the window ends and more bytes may follow, it holds the run back again. Past the
// run it gives the hook the comments, with their roles as `emit_comments` gives them, and continues from the token
// there.
@(private, cold)
piece_run :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk, hs: hook.Regs, end: [^]u8, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result #no_bounds_check {
	s := pw.s
	r := &s.run
	w.gap_lo = GAP_UNLEARNABLE
	q := w.base[r.on:]
	for {
		if r.part != RUN_GAP {
			body := q
			nl: bool
			kind: tape.Fault_Kind
			if r.part == RUN_BLOCK {
				q, nl, kind = comment_body(q, end, true, S)
			} else {
				q, nl, kind = comment_body(q, end, false, S)
			}
			r.held ||= nl
			// A `//` comment that the window's end ends may continue in the next window.
			if pw.more && (kind == .Truncated || kind == .None && q >= end && r.part == RUN_LINE) {
				r.on = piece_comment_on(w, body, end, r.part == RUN_BLOCK)
				return piece_run_held(w, pw, hs, end)
			}
			if kind != .None {
				return fault(w, hs, q, kind)
			}
			c := w.base[r.lo:]
			if too_wide(c, q) {
				return fault(w, hs, c, .Too_Wide)
			}
			when H != hook.No_Hooks {
				if !piece_passes(w) {
					role := tape.Role.Comment if r.line else .Comment_Inline
					spelling := BLOCK_COMMENT if r.part == RUN_BLOCK else LINE_COMMENT
					t := tape.Token{r.lo, u32(intrinsics.ptr_sub(q, c)), .Plain, role, spelling}
					context = pw.ctx^
					if _, err := append(&s.comments, t); err != nil {
						pw.refused = true
						return stopped(w, hs, q)
					}
				}
			}
			r.line ||= r.held
			r.part, r.held = RUN_GAP, false
		}
		g := q
		q = kernel.skip_ws(q, end)
		for x := g; !r.line && x < q; x = x[1:] {
			r.line = x[0] == '\n' || x[0] == '\r'
		}
		if q >= end {
			if pw.more {
				r.on = at(w, q)
				return piece_run_held(w, pw, hs, end)
			}
			break
		}
		when S == .Json5 {
			if n := ws5_len(q, end); n > 0 {
				r.line ||= line_end(q, end, S)
				q = q[n:]
				continue
			}
		}
		if piece_short(w, q, end, .Bad_Char) == .Truncated {
			r.on = at(w, q)
			return piece_run_held(w, pw, hs, end)
		}
		when S != .Json {
			if q[0] == '/' {
				if intrinsics.ptr_sub(end, q) < 2 || q[1] != '/' && q[1] != '*' {
					return fault(w, hs, q, .Bad_Char, run_stray(S, r.state))
				}
				r.part, r.lo = RUN_BLOCK if q[1] == '*' else RUN_LINE, at(w, q)
				q = q[2:]
				continue
			}
		}
		if r.state == RUN_AFTER && !r.crossed && q[0] == ',' {
			r.crossed, r.comma = true, u32(len(s.comments))
			q = q[1:]
			continue
		}
		break
	}
	return piece_run_end(w, pw, hs, q, end, on)
}

// The offset from which a comment body or run of white space read from `body` is read on after a window that ended at
// `end`. It is the final `*` of the window, which may close a `/* */` comment, or the first byte of the UTF-8 character
// the window may cut, or else `end`.
@(private)
piece_comment_on :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), body, end: [^]u8, star: bool) -> u64 #no_bounds_check {
	if star && end > body && end[-1] == '*' {
		return at(w, end) - 1
	}
	for k := end; k > body && intrinsics.ptr_sub(end, k) < 4; k = k[-1:] {
		if k[-1] >= 0xc0 {
			return at(w, k) - 1
		}
		if k[-1] < 0x80 {
			break
		}
	}
	return at(w, end)
}

// The result of a walk of a window that ends inside run `s.run`, which is held back for the next window. A run past
// the root value ends the walk past it, and any other run gives the fault `Truncated`.
@(private)
piece_run_held :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk, hs: hook.Regs, end: [^]u8) -> hook.Walk_Result {
	if pw.s.run.state == RUN_FOOT {
		pw.foot = true
		return done(w, hs, w.base[pw.s.last:])
	}
	return fault(w, hs, end, .Truncated)
}

// Gives the hook the comments of run `s.run`, which ends at `q`, and continues from the token there in the run's state.
// The place past each comment is set as `piece_fact` sets it, and the place past the run is the place before its token.
@(private)
piece_run_end :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk, hs: hook.Regs, q, end: [^]u8, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result #no_bounds_check {
	s := pw.s
	r := &s.run
	hs := hs
	state, crossed, root := r.state, r.crossed, s.last
	r.state = 0
	if state == RUN_FOOT && q < end {
		return fault(w, hs, q, .Bad_Char, .Trailing)
	}
	open := u64(len(s.opened))
	object := open > 0 && s.opened[open - 1].object
	d := open << 1 | u64(object)
	when H != hook.No_Hooks {
		rest := tape.Role.Comment
		switch state {
		case RUN_VALUE:
			rest = .Comment_Foot if !object && open > 0 && q < end && q[0] == ']' else .Comment
		case RUN_KEY:
			rest = .Comment_Foot if q < end && q[0] == '}' else .Comment
		case RUN_AFTER:
			rest = .Comment if crossed && q < end && q[0] != ']' | u8(object) << 5 else .Comment_Foot
		case RUN_FOOT:
			rest = .Comment_Foot
		}
		for t, i in s.comments {
			t := t
			if t.role != .Comment_Inline {
				t.role = rest
			}
			s.place, s.last = PLACE_MEMBER if crossed && u32(i) >= r.comma else r.place, t.lo
			if emit_token(w, on, &hs, t) == .Stop {
				clear(&s.comments)
				return stopped(w, hs, w.base[t.lo + u64(t.n):])
			}
		}
		clear(&s.comments)
	}
	if state == RUN_FOOT {
		pw.foot = true
		return done(w, hs, w.base[root:])
	}
	s.place, s.last = PLACE_MEMBER if crossed else r.place, at(w, q)
	return enter_run(state, crossed, q, end, d, w, hs, on)
}

// Enters the walk at the token `p` past a run of comments read in state `run`, in container `d`. `crossed` is whether
// the run held its comma. A separate call whose frame has no base pointer, as `enter` has in a sanitizer build.
@(private)
enter_run :: #force_no_inline proc "contextless" (run: u8, crossed: bool, p, end: [^]u8, d: u64, w: ^Walk($S, $H, $LAX, $C), hs: hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	switch run {
	case RUN_VALUE:
		return st_value(p, end, d, indent_start(w), w, hs.a, hs.b, hs.c, GAP_OFF, on)
	case RUN_KEY:
		return st_key(p, end, d, indent_start(w), w, hs.a, hs.b, hs.c, GAP_OFF, on)
	case RUN_COLON:
		return st_colon(p, end, d, indent_start(w), w, hs.a, hs.b, hs.c, GAP_OFF, on)
	}
	if crossed {
		return st_member_ws(p, end, d, indent_start(w), w, hs.a, hs.b, hs.c, GAP_OFF, on)
	}
	return st_after_ws(p, end, d, indent_start(w), w, hs.a, hs.b, hs.c, GAP_OFF, on)
}

// The offset of the first byte of the comments that run `s.run` holds back, which a hook that reads a comment's bytes
// needs in the window that gives it the comment. `max(u64)` when the run holds none.
@(private)
piece_run_facts :: proc "contextless" (s: ^Piece) -> u64 {
	r := &s.run
	switch {
	case r.state == 0:
		return max(u64)
	case len(s.comments) > 0:
		return s.comments[0].lo
	case r.part != RUN_GAP:
		return r.lo
	}
	return max(u64)
}

// The result of a walk of a window that ended as `r`. When more bytes may follow the window and the walk ended inside
// the root value, before its foot, at a `Truncated` fault, at a scalar it cut, or past the root value, the walk's state
// is kept for the next window.
@(private, cold)
piece_end :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk, r: hook.Walk_Result) -> hook.Walk_Result {
	s := pw.s
	s.started = true
	if pw.refused {
		return hook.walk_result(u64(r) >> 16, hook.WALK_NO_MEMORY)
	}
	outcome := u8(r)
	if !pw.more || !(outcome == u8(tape.Fault_Kind.Truncated) || outcome == hook.WALK_STOPPED && pw.cut || outcome == 0) {
		return r
	}
	if outcome == 0 && s.run.state == 0 {
		s.place, s.last = PLACE_TAIL, u64(r) >> 16
		piece_pass_white(w, pw)
	} else if outcome == u8(tape.Fault_Kind.Truncated) && !pw.cut && s.cut.on == 0 && s.run.state == 0 {
		piece_pass_white(w, pw)
	}
	context = pw.ctx^
	open := len(s.opened)
	if resize(&s.levels, open) != nil {
		return hook.walk_result(s.last, hook.WALK_NO_MEMORY)
	}
	intrinsics.mem_copy_non_overlapping(raw_data(s.levels), w.stack, open * size_of(u32))
	if GAPS {
		if s.gaps == nil {
			gaps, err := new(Gaps, s.opened.allocator)
			if err != nil || gaps == nil {
				return hook.walk_result(s.last, hook.WALK_NO_MEMORY)
			}
			s.gaps = gaps
		}
		s.gaps^ = w.gaps
	}
	s.regs, s.steps, s.tolerated = w.regs^, w.steps[0], w.tolerated
	when .Skips in C {
		s.rested = w.rested
	}
	pw.ended = true
	return hook.walk_result(s.last, hook.WALK_MORE)
}

// Moves the offset the next window reads on from past the white space that ends this window after the last token, so a
// run longer than a window is read once. Past the root value, past a value's comma and past a key's colon, the run is
// held as a run of comments is, and read on in the next window. Otherwise the place stays, and in a spec with comments
// the next read continues from the run's last line end, which tells a comment past the run whether a line ended before
// it.
@(private)
piece_pass_white :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), pw: ^Piece_Walk) #no_bounds_check {
	s := pw.s
	p, end := w.base[s.last:], w.base[pw.end:]
	// A character the window's end may cut is read in the next window.
	when S == .Json5 {
		if s.place != PLACE_TAIL {
			end = w.base[piece_comment_on(w, p, end, false):]
		}
	}
	run: u8
	// Past the root value, `walk_tail` checked that the rest of the window is white space.
	if s.place == PLACE_TAIL {
		run = RUN_FOOT
	} else if q := piece_skip_white(p, end, S); q < end {
		mark := u8(':') if s.place == PLACE_COLON else ','
		if s.place != PLACE_COLON && s.place != PLACE_AFTER || q[0] != mark || piece_skip_white(q[1:], end, S) != end {
			if s.place == PLACE_VALUE {
				s.last = at(w, q)
			}
			return
		}
		run = RUN_VALUE if s.place == PLACE_COLON else RUN_AFTER
	} else if s.place == PLACE_VALUE {
		run = RUN_VALUE
	} else {
		when S != .Json {
			for k := end; k > p; k = k[-1:] {
				if k[-1] == '\n' || k[-1] == '\r' {
					s.last = at(w, k) - 1
					return
				}
				if S == .Json5 && intrinsics.ptr_sub(k, p) >= 3 && line_sep5(k[-3:], k) {
					s.last = at(w, k) - 3
					return
				}
			}
		}
		s.last = at(w, end)
		return
	}
	r := &s.run
	r.state, r.part, r.lo, r.on, r.crossed, r.held, r.comma = run, RUN_GAP, 0, at(w, end), run == RUN_AFTER, false, 0
	r.place = PLACE_VALUE if run == RUN_VALUE else s.place
	r.line = run == RUN_VALUE
	for x := p; !r.line && x < end; x = x[1:] {
		r.line = line_end(x, end, S)
	}
}

// The first byte past the white space from `p`, including JSON5's white space when `S` is `.Json5`.
@(private = "file")
piece_skip_white :: proc "contextless" (p, end: [^]u8, $S: Spec) -> [^]u8 {
	q := kernel.skip_ws(p, end)
	when S == .Json5 {
		for q < end {
			n := ws5_len(q, end)
			if n == 0 {
				break
			}
			q = kernel.skip_ws(q[n:], end)
		}
	}
	return q
}

// The lowest offset that a window after one ending past `last` needs: the bytes from `last`, and in a
// spec with comments the byte before, which the states read back to for a comment after a comma. A run of comments
// that the window ended inside needs the bytes from where it reads on, and the byte before, because the run may end
// where the next window starts, and that window's read then needs the byte before the token past the run.
@(private)
piece_keep_from :: proc "contextless" (s: ^Piece, $S: Spec) -> u64 {
	if s.run.state != 0 {
		return max(s.run.on, 1) - 1
	}
	if s.last == 0 {
		return 0
	}
	when S != .Json {
		return s.last - 1
	} else {
		return s.last
	}
}

// Whether `src`, a window that starts a text with more bytes to follow, holds too few bytes to tell a byte order mark
// from none: fewer than 3 bytes that all match the start of the mark.
@(private)
piece_bom_open :: proc "contextless" (src: []u8) -> bool {
	BOM := [3]u8{0xEF, 0xBB, 0xBF}
	if len(src) >= 3 {
		return false
	}
	for b, k in src {
		if b != BOM[k] {
			return false
		}
	}
	return true
}
