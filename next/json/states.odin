package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The walk's states, one procedure per place in the grammar. Each takes the cursor `p`, `end` one past the text, `d`
// the depth shifted left once with the open container's kind in bit 0 (1 for an object), `w` the rest of the walk
// `ind` the predicted indent (in `Walk.ind` on AMD64 via zero-sized `Indent_Arg`, live register elsewhere), `w` the rest of the walk, `s0`, `s1` and `s2` the hook's registers and `m` the open object's gap
// slot, dormant or past the table where it matches no gaps (members.odin).

// The state at the start of a value, past white space.
@(private, enable_target_feature = STATE_FEATURES)
st_value :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	if p >= end {
		return fault(w, hs, end, .Truncated)
	}
	// Branches on the first byte's class, so `true`, `false` and `null` share a branch.
	#partial switch VALUE_CLASS[p[0]] {
	case .String:
		q, stop, ok, escaped := string_short(p, end, '"')
		if !ok {
			if escaped {
				w.resume = stop
				return #must_tail st_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			// A byte past ASCII or a control byte, which `st_string` would only find again.
			if stop != nil {
				return #must_tail st_string_utf8(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			return #must_tail st_string(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		a := emit_string(w, on, &hs, .Value, p, q, tape.SPELLING_ASCII)
		if a == .Stop {
			return stopped(w, hs, q)
		}
		if grows(C, a) {
			return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	case .Number:
		q, spelling, kind := hook_number(p, end, H, C, S)
		if kind != .None {
			when S == .Json5 {
				return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			} else {
				if .Non_Finite in w.tolerate {
					return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
				}
			}
			return fault(w, hs, q, kind)
		}
		if too_wide(p, q) {
			return fault(w, hs, p, .Too_Wide)
		}
		a := emit(w, on, &hs, .Number, .Value, p, q, spelling)
		if a == .Stop {
			return stopped(w, hs, q)
		}
		if grows(C, a) {
			return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		if gaps_on(m) {
			if d & 1 != 0 {
				return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
		}
		return #must_tail st_after_number(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	case .Literal:
		q, k := literal(p, end)
		if q == nil {
			return #must_tail st_bad_literal(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		a := emit(w, on, &hs, k, .Value, p, q, 0)
		if a == .Stop {
			return stopped(w, hs, q)
		}
		if grows(C, a) {
			return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	case .Map:
		if d >> 1 >= w.depth {
			return #must_tail st_deepen(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		w.stack[d >> 1] = level(d, m)
		a := emit(w, on, &hs, .Object, .Value, p, p[1:], 0)
		if a == .Stop {
			return stopped(w, hs, p[1:])
		}
		if grows(C, a) {
			return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		when .Skips in C {
			if a == .Skip {
				return #must_tail st_skip_open(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			if a == .Rest {
				return #must_tail st_rest(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			when .Keeps in C {
				if a == .Keep {
					return #must_tail st_keep_open(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
				}
				if a == .Keep_Stubs {
					return #must_tail st_keep_stubs_open(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
				}
			}
		}
		if gaps_rows(m) {
			c := w.gaps.child[m & (GAP_DORMANT - 1)]
			if c == 0 {
				return #must_tail st_open_new_row(p[1:], end, (d | 1) + 2, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			if c < GAP_ROWS {
				return #must_tail st_open(p[1:], end, (d | 1) + 2, ind, w, hs.a, hs.b, hs.c, u64(c) * GAP_MEMBERS, on)
			}
			if c < GAP_SECOND_MARK + GAP_ROWS {
				return #must_tail st_open_row_live(p[1:], end, (d | 1) + 2, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			if c < GAP_DORMANT_MARK + GAP_ROWS {
				return #must_tail st_open_row_second(p[1:], end, (d | 1) + 2, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			return #must_tail st_open(p[1:], end, (d | 1) + 2, ind, w, hs.a, hs.b, hs.c, GAP_OFF, on)
		} else {
			return #must_tail st_open(p[1:], end, (d | 1) + 2, ind, w, hs.a, hs.b, hs.c, m, on)
		}
	case .Array:
		if d >> 1 >= w.depth {
			return #must_tail st_deepen(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		w.stack[d >> 1] = level(d, m)
		a := emit(w, on, &hs, .Array, .Value, p, p[1:], 0)
		if a == .Stop {
			return stopped(w, hs, p[1:])
		}
		if grows(C, a) {
			return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		when .Skips in C {
			if a == .Skip {
				return #must_tail st_skip_open(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			if a == .Rest {
				return #must_tail st_rest(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			when .Keeps in C {
				if a == .Keep {
					return #must_tail st_keep_open(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
				}
			}
		}
		return #must_tail st_open(p[1:], end, (d | 1) + 1, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	when S == .Json5 {
		switch p[0] {
		case '\'':
			return #must_tail st_string5(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		case '+', '.', 'I', 'N':
			return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
	}
	when S != .Json {
		return #must_tail st_spec_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	return #must_tail st_bad_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at an object's key, past white space, which reads on through the colon to the value.
@(private, enable_target_feature = STATE_FEATURES)
st_key :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	if p >= end {
		return fault(w, hs, end, .Truncated)
	}
	if p[0] != '"' {
		when S == .Json5 {
			return #must_tail st_key_ident(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		} else when S != .Json {
			return #must_tail st_spec_key(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		return #must_tail st_bad_key(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	// The key the hook expects is taken here as the hook would take it, with no token.
	q: [^]u8
	a := hook.Action.Next
	when .Expects in C {
		q = expected_at(hs.b, p, end)
	}
	if q != nil {
		hs.b += hook.EXPECTED_STRIDE
	} else {
		stop: [^]u8
		ok, escaped: bool
		q, stop, ok, escaped = string_probe(p, end)
		if !ok {
			if escaped {
				w.resume = stop
				return #must_tail st_key_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			// A byte past ASCII or a control byte, which `st_key_string` would only find again.
			if stop != nil {
				return #must_tail st_key_string_utf8(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			return #must_tail st_key_string(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		a = emit_string(w, on, &hs, .Key, p, q, tape.SPELLING_ASCII)
		if a == .Stop {
			return stopped(w, hs, q)
		}
		if grows(C, a) {
			return #must_tail st_grow_key(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
	}
	if r := colon_fast(q, end); r != nil {
		if gaps_on(m) {
			w.resume = p
			when .Skips in C {
				if a == .Skip {
					return #must_tail st_gap_learn_skip(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
				}
			}
			return #must_tail st_gap_learn(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		when .Skips in C {
			if a == .Skip {
				return #must_tail st_skip_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
			}
		}
		return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
	}
	// No gap is learned around a colon `colon_fast` refuses, so its member is a miss.
	if gaps_on(m) {
		if gap_miss(w, p) {
			when .Skips in C {
				if a == .Skip {
					return #must_tail st_stop_gaps_skip(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
				}
			}
			return #must_tail st_stop_gaps(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
	}
	when .Skips in C {
		if a == .Skip {
			return #must_tail st_skip_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
		}
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
}

// The start of a member's value when the colon after the key ending at `q` is flush against it or a pretty printer's
// `": "`, `" : "` or `" :"`, else nil, when `st_colon` must read the colon.
@(private, require_results)
colon_fast :: #force_inline proc "contextless" (q, end: [^]u8) -> [^]u8 {
	if intrinsics.ptr_sub(end, q) > 2 && q[0] == ':' {
		if q[1] > ' ' {
			return q[1:]
		}
		if q[1] == ' ' && q[2] > ' ' {
			return q[2:]
		}
	}
	if intrinsics.ptr_sub(end, q) > 3 && q[0] == ' ' && q[1] == ':' {
		if q[2] > ' ' {
			return q[2:]
		}
		if q[2] == ' ' && q[3] > ' ' {
			return q[3:]
		}
	}
	return nil
}

// The state at a value string that `string_short` refused, with no backslash in its first 32 bytes. `string_lean` is
// inlined, so a plain ASCII string makes no call. It reads on past those 32 bytes, which `string_short` judged, when the
// text holds them: that is the only way it is entered, a probe that is short of the text's end returns at once without
// judging a byte.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_string :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	q, escape, ok, escaped := string_lean(p[32:] if intrinsics.ptr_sub(end, p) > 32 else p, end, '"')
	if !ok {
		if escaped {
			w.resume = escape
			return #must_tail st_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		return #must_tail st_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	a := emit_string(w, on, &hs, .Value, p, q, tape.SPELLING_ASCII)
	if a == .Stop {
		return stopped(w, hs, q)
	}
	if grows(C, a) {
		return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at a value string whose first escape is at `w.resume`.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_string_escaped :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	q: [^]u8
	ok, utf8_tail: bool
	when S == .Json5 {
		if w.refused < BLOCK_RETIRE {
			q, ok, utf8_tail = string_escaped_scan(w.resume, end, '"', true)
		}
	} else {
		q, ok, utf8_tail = string_escaped_scan(w.resume, end, '"', true)
	}
	if !ok {
		when !SCALAR_WASM {
			if utf8_tail {
				return #must_tail st_string_escaped_utf8(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
		}
		return #must_tail st_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	a := emit_string(w, on, &hs, .Value, p, q, tape.SPELLING_DECODE)
	if a == .Stop {
		return stopped(w, hs, q)
	}
	if grows(C, a) {
		return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at a value string whose first 64-byte escaped block from `w.resume` had valid escapes and a closing quote
// but failed `ctl` on non-ASCII bytes. Kept as a separate tail-called state so `st_string_escaped` stays 0-frame.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_string_escaped_utf8 :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	when !SCALAR_WASM {
		q, ok := string_escaped_utf8(w.resume)
		if !ok {
			return #must_tail st_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		if too_wide(p, q) {
			return fault(w, hs, p, .Too_Wide)
		}
		a := emit_string(w, on, &hs, .Value, p, q, tape.SPELLING_DECODE)
		if a == .Stop {
			return stopped(w, hs, q)
		}
		if grows(C, a) {
			return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	} else {
		return #must_tail st_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
}

// The state at a value string whose first byte past printable ASCII is no backslash, within 32 bytes.
// Caller guarantees `ptr_sub(end, p) > 32` so `string_utf8` may load 32 bytes unchecked from `p[1:]`.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_string_utf8 :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	q, ok := string_utf8(p)
	if !ok {
		return #must_tail st_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	a := emit_string(w, on, &hs, .Value, p, q, 0)
	if a == .Stop {
		return stopped(w, hs, q)
	}
	if grows(C, a) {
		return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at a value string past ASCII, or one the faster readers refused.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_string_long :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	q, spelling, kind := string_long(w, p, end)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	a := emit_string(w, on, &hs, .Value, p, q, spelling)
	if a == .Stop {
		return stopped(w, hs, q)
	}
	if grows(C, a) {
		return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at a key `string_probe` refused, longer than `PROBE_MAX` or past printable ASCII. It reads on past the
// `PROBE_MAX` bytes the probe judged, as `st_string` does for `string_short`'s.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_key_string :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	q, escape, ok, escaped := string_lean(p[PROBE_MAX:] if intrinsics.ptr_sub(end, p) > PROBE_MAX else p, end, '"')
	if !ok {
		if escaped {
			w.resume = escape
			return #must_tail st_key_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		return #must_tail st_key_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	a := emit_string(w, on, &hs, .Key, p, q, tape.SPELLING_ASCII)
	if a == .Stop {
		return stopped(w, hs, q)
	}
	if grows(C, a) {
		return #must_tail st_grow_key(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	when .Skips in C {
		if a == .Skip {
			return #must_tail st_skip_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
		}
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
}

// The state at a key whose first escape is at `w.resume`.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_key_string_escaped :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	q, at, credit, ok := key_escaped_head(w.resume, end)
	spelling := tape.SPELLING_DECODE
	if !ok {
		q, ok = string_escaped(at, end, '"')
	} else {
		spelling = tape.credit_spelling(credit) if .Credits in C else tape.SPELLING_DECODE
	}
	if !ok {
		return #must_tail st_key_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	a := emit_string(w, on, &hs, .Key, p, q, spelling)
	if a == .Stop {
		return stopped(w, hs, q)
	}
	if grows(C, a) {
		return #must_tail st_grow_key(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	when .Skips in C {
		if a == .Skip {
			return #must_tail st_skip_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
		}
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
}

// The state at a key whose first byte past printable ASCII is no backslash, within `PROBE_MAX` bytes.
// Caller guarantees `ptr_sub(end, p) > 32` (enforced by `string_probe` since `PROBE_MAX >= 32`) so `string_utf8` may
// load 32 bytes unchecked from `p[1:]`.
#assert(PROBE_MAX >= 32)
@(private = "file", enable_target_feature = STATE_FEATURES)
st_key_string_utf8 :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	q, ok := string_utf8(p)
	if !ok {
		return #must_tail st_key_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	a := emit_string(w, on, &hs, .Key, p, q, 0)
	if a == .Stop {
		return stopped(w, hs, q)
	}
	if grows(C, a) {
		return #must_tail st_grow_key(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	when .Skips in C {
		if a == .Skip {
			return #must_tail st_skip_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
		}
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
}

// The state at a key past ASCII, or one the faster readers refused.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_key_string_long :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	q, spelling, kind := string_long(w, p, end)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	a := emit_string(w, on, &hs, .Key, p, q, spelling)
	if a == .Stop {
		return stopped(w, hs, q)
	}
	if grows(C, a) {
		return #must_tail st_grow_key(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	when .Skips in C {
		if a == .Skip {
			return #must_tail st_skip_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
		}
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
}

// The state right after a key.
@(private, enable_target_feature = STATE_FEATURES)
st_colon :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	if intrinsics.ptr_sub(end, p) > 2 && p[0] == ':' && p[1] == ' ' && p[2] > ' ' {
		return #must_tail st_value(p[2:], end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	q, kind := colon(p, end)
	if kind != .None {
		when S != .Json {
			if kind == .Bad_Char {
				return #must_tail st_spec_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
		}
		return fault(w, hs, q, kind, .Colon if kind == .Bad_Char else .None)
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// `st_colon` after a key the hook answered `Skip` on, whose value gives no token. Comments before the colon are given.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_skip_colon :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	q, kind := colon(p, end)
	when S != .Json {
		if kind == .Bad_Char && opens_run(q, end, S) {
			r, done, result := comments_before(w, on, &hs, q, end, 0, RUN_COLON)
			if done {
				return result
			}
			q, kind = colon(r, end)
		}
		if kind == .Bad_Char {
			kind = piece_short(w, q, end, .Bad_Char)
		}
	}
	if kind != .None {
		return fault(w, hs, q, kind, .Colon if kind == .Bad_Char else .None)
	}
	return #must_tail st_skip_value(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state right after an open bracket.
@(private, enable_target_feature = STATE_FEATURES)
st_open :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	ind := ind
	pind := indent_ptr(w, &ind)
	if gaps_on(m) {
		if d & 1 != 0 {
			if r, key, nl := gap_match(w, p, end, m); r != nil {
				a := gap_key(w, on, &hs, key, m)
				if a == .Stop {
					return stopped(w, hs, past_key(w, key))
				}
				if grows(C, a) {
					return #must_tail st_grow_open(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
				}
				if nl {
					// The members are a step deeper, as `indent_predicted` would have found at a line break.
					pind^ = pind^ &~ 0xffff_ff00 | ((pind^ >> 8 + pind^ >> 32) & 0xff_ffff) << 8
				}
				when .Skips in C {
					if a == .Skip {
						return #must_tail st_skip_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
					}
				}
				#partial switch VALUE_CLASS[r[0]] {
				case .String:
					return #must_tail st_hit_string(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
				case .Number:
					return #must_tail st_hit_number(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
				case .Literal:
					return #must_tail st_hit_literal(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
				}
				return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
			}
			w.gap_lo = at(w, p)
		}
	}
	q := indent_fast(p, end, pind, .Open)
	if q == nil {
		return #must_tail st_open_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if d & 1 != 0 {
		return #must_tail st_key(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if q[0] == '[' {
		return #must_tail st_open_run(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The stack entry of a container opened in container `d`, whose gap slot is `m`.
@(private = "file", require_results)
level :: #force_inline proc "contextless" (d, m: u64) -> u32 {
	#assert(']' | 1 << 5 == '}')
	return u32(']' | (d & 1) << 5 | m << 8)
}

// One past the closing quote of the key token `key` a gap matched, where a stop at it ends the walk as one in the
// key's states does.
@(private = "file", require_results)
past_key :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), key: tape.Token) -> [^]u8 {
	return w.base[key.lo + u64(key.n) + 1:]
}

// The state that retires the row of the object whose key ends at `p` once the walk's misses pass their limit. Its
// members and the objects at its place in the tree match no more gaps, and an array holding it reads on without
// them, as its other objects are of that row. Other rows match on, against the limit less `GAP_MISS_FLOOR`.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_stop_gaps :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	stop_gaps(w, p, d)
	return #must_tail st_colon(p, end, d, ind, w, s0, s1, s2, GAP_OFF, on)
}

// `st_stop_gaps` after a key the hook answered `Skip` on.
@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_stop_gaps_skip :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	stop_gaps(w, p, d)
	return #must_tail st_skip_colon(p, end, d, ind, w, s0, s1, s2, GAP_OFF, on)
}

// Learns slot `m`'s gap around the key starting at `w.resume` and ending at `p`, then continues to its value, or
// retires the object's row when misses pass their limit.
@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_gap_learn :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	r := colon_fast(p, end)
	if gap_learn(w, m, w.resume, p, r) {
		stop_gaps(w, p, d)
		return #must_tail st_colon(p, end, d, ind, w, s0, s1, s2, GAP_OFF, on)
	}
	return #must_tail st_value(r, end, d, ind, w, s0, s1, s2, gap_next(m), on)
}

// `st_gap_learn` after a key the hook answered `Skip` on.
@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_gap_learn_skip :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	r := colon_fast(p, end)
	if gap_learn(w, m, w.resume, p, r) {
		stop_gaps(w, p, d)
		return #must_tail st_skip_colon(p, end, d, ind, w, s0, s1, s2, GAP_OFF, on)
	}
	return #must_tail st_skip_value(r, end, d, ind, w, s0, s1, s2, gap_next(m), on)
}

// Retires the row of the object `d` names, whose key ends at `p`, as `st_stop_gaps` does.
@(private)
stop_gaps :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p: [^]u8, d: u64) {
	l := &w.stack[(d >> 1) - 1]
	if parent := u64(l^ >> 8); gaps_rows(parent) {
		w.gaps.child[parent & (GAP_DORMANT - 1)] = GAP_ROW_OFF
	}
	if u8(l^) == ']' {
		l^ = l^ & 0xFF | GAP_OFF << 8
	}
	w.gaps.misses = at(w, p) / GAP_MISS_BYTES
}

// The state at the open bracket `p` of a container a hook skips. Judges what it holds with no hooks, gives its `End`
// and goes on after it.
@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_skip_open :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	r := pass_over(w, p, end, d, ind, hs, m, true)
	if u8(r) != 0 {
		w.regs^ = hs
		return r
	}
	q := w.base[u64(r) >> 16:]
	if emit(w, on, &hs, .End, .Value, q[-1:], q, 0) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at the value of a member whose key the hook answered `Skip`, past white space. Judges it with no token: a
// short string, a number or a literal here, any other value as `pass_over` judges it. Comments before it are given,
// and a byte that starts no value faults as `st_value` faults it.
@(private, enable_target_feature = STATE_FEATURES)
st_skip_value :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	if p >= end {
		return fault(w, hs, end, .Truncated)
	}
	p := p
	when S != .Json {
		if opens_run(p, end, S) {
			q, done, result := comments_before(w, on, &hs, p, end, 0, RUN_VALUE)
			if done {
				return result
			}
			p = q
			if p >= end {
				return fault(w, hs, end, .Truncated)
			}
		}
	}
	#partial switch VALUE_CLASS[p[0]] {
	case .String:
		if q, _, ok, _ := string_short(p, end, '"'); ok {
			return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
	case .Number:
		if q, _, kind := tape.number_scan(p, end, false, S == .Json5); kind == .None && !too_wide(p, q) {
			if gaps_on(m) {
				return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			return #must_tail st_after_number(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
	case .Literal:
		if q, _ := literal(p, end); q != nil {
			return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
	case .Map, .Array:
	case:
		// The bytes past JSON's that open a value of JSON5 or of `.Non_Finite`.
		switch p[0] {
		case '\'', '+', '.', 'I', 'N':
		case:
			return #must_tail st_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
	}
	r := pass_over(w, p, end, d, ind, hs, m, false)
	if u8(r) != 0 {
		w.regs^ = hs
		return r
	}
	return #must_tail st_after(w.base[u64(r) >> 16:], end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at the open bracket `p` of a container a scan keeps whole. The scanner's builder stores the container,
// and the hook is given its `End`.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_keep_open :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	r := keep_over(w, p, end, d, ind, &hs, m, false)
	if u8(r) != 0 {
		return r
	}
	q := w.base[u64(r) >> 16:]
	if emit(w, on, &hs, .End, .Value, q[-1:], q, 0) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// `st_keep_open` for an object a scan keeps as its members, each container value as one node.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_keep_stubs_open :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	r := keep_over(w, p, end, d, ind, &hs, m, true)
	if u8(r) != 0 {
		return r
	}
	q := w.base[u64(r) >> 16:]
	if emit(w, on, &hs, .End, .Value, q[-1:], q, 0) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at the open bracket `p` of a container once a hook wants no more tokens. Judges the rest of the text in
// the same walk with no hooks.
@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_rest :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	// A walk's hooks are behind a pointer, so a walk with `No_Hooks` has the same layout, its stack and gaps included.
	#assert(size_of(Walk(S, H, LAX, C)) == size_of(Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS)))
	when LAX {
		w.steps[0] += 1 // the container's step, taken again as its bracket is read again
	}
	w.rested = true
	return st_value(p, end, d, ind, (^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS))(w), s0, s1, s2, m, hook.no_hook)
}

// The state at an object's open bracket whose parent slot has no row yet, the first object there, which reads its
// members on the row's dormant slots.
@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_open_new_row :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	row := gap_new_row(&w.gaps, m)
	return #must_tail st_open(p, end, d, ind, w, s0, s1, s2, GAP_DORMANT + row * GAP_MEMBERS, on)
}

// The state at an object's open bracket that is the second object at its parent slot's place, which reads its
// members on the row's dormant slots too, as a row learned from the second object pays only from the third.
@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_open_row_second :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	c := &w.gaps.child[m & (GAP_DORMANT - 1)]
	c^ -= GAP_DORMANT_MARK - GAP_SECOND_MARK
	return #must_tail st_open(p, end, d, ind, w, s0, s1, s2, GAP_DORMANT + u64(c^ - GAP_SECOND_MARK) * GAP_MEMBERS, on)
}

// The state at an object's open bracket that is the third object at its parent slot's place, whose row goes live:
// its slots are zeroed, the only write to them before a learn, and its members read on them.
@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_open_row_live :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	return #must_tail st_open(p, end, d, ind, w, s0, s1, s2, gap_row_live(&w.gaps, m), on)
}

// The states that grow the hook's room for nodes after `emit` answered `Grow` for a token, and walk again from that
// token's value, key, or the `st_open` or `st_after` whose gap match gave the key. A growth refused stops the walk at
// `p`.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_grow_value :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	if !grow_room(w, &hs) {
		return stopped(w, hs, p)
	}
	return #must_tail st_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

@(private, cold, enable_target_feature = STATE_FEATURES)
st_grow_key :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	if !grow_room(w, &hs) {
		return stopped(w, hs, p)
	}
	return #must_tail st_key(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_grow_open :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	if !grow_room(w, &hs) {
		return stopped(w, hs, p)
	}
	return #must_tail st_open(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_grow_after :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	if !grow_room(w, &hs) {
		return stopped(w, hs, p)
	}
	return #must_tail st_after(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at an open bracket past the levels the walk holds.
@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_deepen :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	if k := deepen(w, &hs, p, s2); k != 0 {
		return too_deep(w, hs, p, k)
	}
	return #must_tail st_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_deepen_run :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	if k := deepen(w, &hs, p, s2); k != 0 {
		return too_deep(w, hs, p, k)
	}
	return #must_tail st_open_run(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at an array's first element when it is an array, which reads the run of open brackets.
// Caller guarantees `d & 1 == 0` (enclosing container is an array), so `level(0, m)` records an array level.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_open_run :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	p, d := p, d
	stack, depth := w.stack, w.depth
	when !LAX && H == build.Builder {
		if on == build.builder_hook || on == build.builder_hook_facts {
			base := w.base
			rooms := w.rooms
			h := w.hooks
			opens := raw_data(h.stack)
			idx := u64((uintptr(hs.a) - uintptr(raw_data(h.doc.nodes))) / size_of(tape.Node))
			lvl := level(0, m)
			dep := d >> 1
			for {
				if dep >= depth {
					return #must_tail st_deepen_run(p, end, dep << 1, ind, w, hs.a, hs.b, hs.c, m, on)
				}
				stack[dep] = lvl
				lo := u64(intrinsics.ptr_sub(p, base))
				if uintptr(hs.a) == rooms {
					w.grow = lo
					return #must_tail st_grow_value(p, end, dep << 1, ind, w, hs.a, hs.b, hs.c, m, on)
				}
				tok := tape.Token{lo, 1, .Array, .Value, 0}
				((^[2]u64)(uintptr(hs.a)))^ = transmute([2]u64)tok
				opens[hs.c] = hs.b + 1
				hs.c += 1
				hs.a += size_of(tape.Node)
				hs.b = idx << 32
				idx += 1
				dep += 1
				p = p[1:]
				if p >= end || p[0] != '[' {
					break
				}
			}
			return #must_tail st_open(p, end, dep << 1, ind, w, hs.a, hs.b, hs.c, m, on)
		}
	}
	for {
		if d >> 1 >= depth {
			return #must_tail st_deepen_run(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		stack[d >> 1] = level(0, m)
		d += 2
		p = p[1:]
		a := emit(w, on, &hs, .Array, .Value, p[-1:], p, 0)
		if a == .Stop {
			return stopped(w, hs, p)
		}
		if grows(C, a) {
			return #must_tail st_grow_value(p[-1:], end, d - 2, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		when .Skips in C {
			if a == .Skip {
				return #must_tail st_skip_open(p[-1:], end, d - 2, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			if a == .Rest {
				return #must_tail st_rest(p[-1:], end, d - 2, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			when .Keeps in C {
				if a == .Keep {
					return #must_tail st_keep_open(p[-1:], end, d - 2, ind, w, hs.a, hs.b, hs.c, m, on)
				}
			}
		}
		if p >= end || p[0] != '[' {
			break
		}
	}
	return #must_tail st_open(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// `st_open` where white space follows the open bracket.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_open_ws :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	ind := ind
	pind := indent_ptr(w, &ind)
	q := skip_indent(p, end, pind, .Open)
	if q < end && q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if d & 1 != 0 {
		return #must_tail st_key(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state right after a value, which reads a comma and the next member, the container's close, or the root's end.
@(private, enable_target_feature = STATE_FEATURES)
st_after :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	ind := ind
	pind := indent_ptr(w, &ind)
	if d < 2 {
		return done(w, hs, p)
	}
	if gaps_on(m) {
		if d & 1 != 0 {
			if r, key, _ := gap_match(w, p, end, m); r != nil {
				a := gap_key(w, on, &hs, key, m)
				if a == .Stop {
					return stopped(w, hs, past_key(w, key))
				}
				if grows(C, a) {
					return #must_tail st_grow_after(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
				}
				when .Skips in C {
					if a == .Skip {
						return #must_tail st_skip_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
					}
				}
				#partial switch VALUE_CLASS[r[0]] {
				case .String:
					return #must_tail st_hit_string(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
				case .Number:
					return #must_tail st_hit_number(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
				case .Literal:
					return #must_tail st_hit_literal(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
				}
				return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
			}
			w.gap_lo = at(w, p)
		}
	}
	q := indent_fast(p, end, pind, .Close)
	if q == nil {
		return #must_tail st_after_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if q[0] == ',' {
		r := indent_fast(q[1:], end, pind, .Member)
		if r == nil {
			return #must_tail st_member_ws(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		if d & 1 != 0 {
			return #must_tail st_key(r, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	when S != .Json {
		return #must_tail st_spec_after(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	return #must_tail st_bad_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// `st_after` once no gap matches, which reads a comma and the next member or the container's close. Only the states of
// a member whose gap matched enter it, so it is never at the root and has no root's end to read.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_after_unmatched :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	ind := ind
	pind := indent_ptr(w, &ind)
	q := indent_fast(p, end, pind, .Close)
	if q == nil {
		return #must_tail st_after_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if q[0] == ',' {
		r := indent_fast(q[1:], end, pind, .Member)
		if r == nil {
			return #must_tail st_member_ws(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		if d & 1 != 0 {
			return #must_tail st_key(r, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	when S != .Json {
		return #must_tail st_spec_after(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	return #must_tail st_bad_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at a string value whose member's gap matched, which matches the gap after it too.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_hit_string :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	q, stop, ok, escaped := string_short(p, end, '"')
	if !ok {
		if escaped {
			w.resume = stop
			return #must_tail st_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		if stop != nil {
			return #must_tail st_string_utf8(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		return #must_tail st_string(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	a := emit_string(w, on, &hs, .Value, p, q, tape.SPELLING_ASCII)
	if a == .Stop {
		return stopped(w, hs, q)
	}
	if grows(C, a) {
		return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	r, key, _ := gap_match(w, q, end, m)
	if r == nil {
		w.gap_lo = at(w, q)
		return #must_tail st_after_unmatched(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	a = gap_key(w, on, &hs, key, m)
	if a == .Stop {
		return stopped(w, hs, past_key(w, key))
	}
	if grows(C, a) {
		return #must_tail st_grow_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	when .Skips in C {
		if a == .Skip {
			return #must_tail st_skip_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
		}
	}
	#partial switch VALUE_CLASS[r[0]] {
	case .String:
		return #must_tail st_hit_string(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
	case .Number:
		return #must_tail st_hit_number(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
	case .Literal:
		return #must_tail st_hit_literal(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
	}
	return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
}

// The state at a number value whose member's gap matched, which matches the gap after it too.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_hit_number :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	q, spelling, kind := hook_number(p, end, H, C, S)
	if kind != .None {
		when S == .Json5 {
			return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		} else {
			if .Non_Finite in w.tolerate {
				return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
		}
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	a := emit(w, on, &hs, .Number, .Value, p, q, spelling)
	if a == .Stop {
		return stopped(w, hs, q)
	}
	if grows(C, a) {
		return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	r, key, _ := gap_match(w, q, end, m)
	if r == nil {
		w.gap_lo = at(w, q)
		return #must_tail st_after_unmatched(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	a = gap_key(w, on, &hs, key, m)
	if a == .Stop {
		return stopped(w, hs, past_key(w, key))
	}
	if grows(C, a) {
		return #must_tail st_grow_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	when .Skips in C {
		if a == .Skip {
			return #must_tail st_skip_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
		}
	}
	#partial switch VALUE_CLASS[r[0]] {
	case .String:
		return #must_tail st_hit_string(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
	case .Number:
		return #must_tail st_hit_number(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
	case .Literal:
		return #must_tail st_hit_literal(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
	}
	return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
}

// The state at a literal value whose member's gap matched, which matches the gap after it too.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_hit_literal :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	q, k := literal(p, end)
	if q == nil {
		return #must_tail st_bad_literal(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	a := emit(w, on, &hs, k, .Value, p, q, 0)
	if a == .Stop {
		return stopped(w, hs, q)
	}
	if grows(C, a) {
		return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	r, key, _ := gap_match(w, q, end, m)
	if r == nil {
		w.gap_lo = at(w, q)
		return #must_tail st_after_unmatched(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	a = gap_key(w, on, &hs, key, m)
	if a == .Stop {
		return stopped(w, hs, past_key(w, key))
	}
	if grows(C, a) {
		return #must_tail st_grow_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	when .Skips in C {
		if a == .Skip {
			return #must_tail st_skip_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
		}
	}
	#partial switch VALUE_CLASS[r[0]] {
	case .String:
		return #must_tail st_hit_string(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
	case .Number:
		return #must_tail st_hit_number(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
	case .Literal:
		return #must_tail st_hit_literal(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
	}
	return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m), on)
}

// `st_after` where white space follows the value.
@(private, enable_target_feature = STATE_FEATURES)
st_after_ws :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	ind := ind
	pind := indent_ptr(w, &ind)
	q := skip_indent(p, end, pind, .Close)
	if q >= end {
		return fault(w, hs, end, .Truncated)
	}
	if q[0] == ',' {
		return #must_tail st_member_ws(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	when S != .Json {
		return #must_tail st_spec_after(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	return #must_tail st_bad_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state right after a comma, at white space or the text's end.
@(private, enable_target_feature = STATE_FEATURES)
st_member_ws :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	ind := ind
	pind := indent_ptr(w, &ind)
	q := skip_indent(p, end, pind, .Member)
	if d & 1 != 0 {
		return #must_tail st_key(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at the close bracket of container `d`, which reads the run of closes after it too.
@(private, enable_target_feature = STATE_FEATURES)
st_close :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	p := p
	// The depth is carried apart from the kind bit, so the next close does not wait on the stack's load.
	depth := d >> 1
	stack := w.stack
	when !LAX && H == build.Builder {
		if on == build.builder_hook || on == build.builder_hook_facts {
			h := w.hooks
			nodes := raw_data(h.doc.nodes)
			opens := raw_data(h.stack)
			cur := u32((uintptr(hs.a) - uintptr(nodes)) / size_of(tape.Node))
			last_open: tape.Node_Index
			for {
				open := u32(hs.b >> 32)
				count := u32(hs.b)
				last_open = tape.Node_Index(open)
				n := &nodes[open]
				n.n = cur - open
				n.spelling = u16(min(count, u32(tape.MAX_CHILDREN)))
				if intrinsics.expect(count >= u32(tape.MAX_CHILDREN), false) {
					counts := (^runtime.Raw_Dynamic_Array)(&h.counts)
					cn := counts.len
					([^]tape.Child_Count)(counts.data)[cn] = {tape.Node_Index(open), count}
					counts.len = cn + 1
				}
				hs.c -= 1
				hs.b = opens[hs.c]
				depth -= 1
				p = p[1:]
				if depth == 0 || p >= end || u32(p[0]) != stack[depth] & 0xFF {
					break
				}
			}
			if on == build.builder_hook_facts {
				h.closed = last_open
			}
			top := stack[depth]
			return #must_tail st_after(p, end, depth << 1 | u64(top >> 5 & 1), ind, w, hs.a, hs.b, hs.c, u64(top >> 8), on)
		}
	}
	for {
		if emit(w, on, &hs, .End, .Value, p, p[1:], 0) == .Stop {
			return stopped(w, hs, p[1:])
		}
		depth -= 1
		p = p[1:]
		if depth == 0 || p >= end || u32(p[0]) != stack[depth] & 0xFF {
			break
		}
	}
	top := stack[depth]
	return #must_tail st_after(p, end, depth << 1 | u64(top >> 5 & 1), ind, w, hs.a, hs.b, hs.c, u64(top >> 8), on)
}

// The state right after a number in an array, or without gap matching in an object. Runs of numbers in an array go on
// in `st_number_run`, and runs of flush members with number values in `st_member_run`.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_after_number :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	ind := ind
	pind := indent_ptr(w, &ind)
	if d < 2 {
		return done(w, hs, p)
	}
	q := indent_fast(p, end, pind, .Close)
	if q == nil {
		return #must_tail st_after_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if q[0] == ',' {
		r := indent_fast(q[1:], end, pind, .Member)
		if r == nil {
			return #must_tail st_member_ws(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		if d & 1 != 0 {
			if !gaps_on(m) {
				// The run is faster when a member follows its comma flush. An indented member is faster through
				// `st_key`.
				if r == q[1:] {
					return #must_tail st_member_run(r, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
				}
			}
			return #must_tail st_key(r, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		if r[0] == '-' || r[0] - '0' < 10 {
			return #must_tail st_number_run(r, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	when S != .Json {
		return #must_tail st_spec_after(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
	return #must_tail st_bad_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at a number after a comma in an array, which reads numbers while each is followed by a comma and, after at
// most one space, another number. Caller guarantees `d >= 2 && d & 1 == 0` (inside an array), relied on when entering
// `st_number_blocks` on `q[0] == ']'`.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_number_run :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	p := p
	q: [^]u8
	for {
		spelling: u16
		kind: tape.Fault_Kind
		q, spelling, kind = hook_number(p, end, H, C, S)
		if kind != .None {
			when S == .Json5 {
				return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			} else {
				if .Non_Finite in w.tolerate {
					return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
				}
			}
			return fault(w, hs, q, kind)
		}
		if too_wide(p, q) {
			return fault(w, hs, p, .Too_Wide)
		}
		a := emit(w, on, &hs, .Number, .Value, p, q, spelling)
		if a == .Stop {
			return stopped(w, hs, q)
		}
		if grows(C, a) {
			return #must_tail st_grow_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		if intrinsics.ptr_sub(end, q) <= 2 || q[0] != ',' {
			// A walk with no hook gives no tokens, so only a strict one, which tracks no pieces and counts no steps, reads blocks.
			when .Number_Blocks in C && (H != hook.No_Hooks || !LAX) {
				if intrinsics.ptr_sub(end, q) > 2 && q[2] == '[' && q[0] == ']' && q[1] == ',' {
					return #must_tail st_number_blocks(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
				}
			}
			break
		}
		r := q[1:]
		if r[0] == ' ' {
			r = r[1:]
		}
		if r[0] != '-' && r[0] - '0' >= 10 {
			break
		}
		p = r
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
}

// The state at a key flush after a comma, which reads flush members with number values. A walk with gaps matches them
// in `st_after` instead.
@(private = "file", enable_target_feature = STATE_FEATURES)
st_member_run :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := hook.Regs{s0, s1, s2}
	p, m := p, m
	// The slot advances by one a member up to its row's last slot, so it is the run's start plus the members read,
	// clamped where the run leaves.
	last := m | (GAP_MEMBERS - 1)
	run := m
	for {
		m = min(run, last)
		if p >= end || p[0] != '"' {
			return #must_tail st_key(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
		}
		q: [^]u8
		a := hook.Action.Next
		when .Expects in C {
			q = expected_at(hs.b, p, end)
		}
		if q != nil {
			hs.b += hook.EXPECTED_STRIDE
		} else {
			stop: [^]u8
			ok, escaped: bool
			q, stop, ok, escaped = string_probe(p, end)
			if !ok {
				if escaped {
					w.resume = stop
					return #must_tail st_key_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
				}
				if stop != nil {
					return #must_tail st_key_string_utf8(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
				}
				return #must_tail st_key_string(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
			a = emit_string(w, on, &hs, .Key, p, q, tape.SPELLING_ASCII)
			if a == .Stop {
				return stopped(w, hs, q)
			}
			if grows(C, a) {
				return #must_tail st_grow_key(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
			}
		}
		// The value's slot, the next, so a dormant row stays in step with the slots its later objects match.
		value := min(run + 1, last)
		r := colon_fast(q, end)
		if r == nil {
			when .Skips in C {
				if a == .Skip {
					return #must_tail st_skip_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, value, on)
				}
			}
			return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, value, on)
		}
		// A number the hook skips at its key is judged in the run with no token.
		skip := false
		when .Skips in C {
			skip = a == .Skip
		}
		if r[0] != '-' && r[0] - '0' >= 10 {
			if skip {
				return #must_tail st_skip_value(r, end, d, ind, w, hs.a, hs.b, hs.c, value, on)
			}
			return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, value, on)
		}
		n, spelling, kind := hook_number(r, end, H, C, S)
		if kind != .None {
			if skip {
				return #must_tail st_skip_value(r, end, d, ind, w, hs.a, hs.b, hs.c, value, on)
			}
			when S == .Json5 {
				return #must_tail st_number5(r, end, d, ind, w, hs.a, hs.b, hs.c, value, on)
			} else {
				if .Non_Finite in w.tolerate {
					return #must_tail st_number5(r, end, d, ind, w, hs.a, hs.b, hs.c, value, on)
				}
			}
			return fault(w, hs, n, kind)
		}
		if too_wide(r, n) {
			return fault(w, hs, r, .Too_Wide)
		}
		if !skip {
			a = emit(w, on, &hs, .Number, .Value, r, n, spelling)
			if a == .Stop {
				return stopped(w, hs, n)
			}
			if grows(C, a) {
				return #must_tail st_grow_value(r, end, d, ind, w, hs.a, hs.b, hs.c, value, on)
			}
		}
		if n >= end || n[0] != ',' {
			return #must_tail st_after_number(n, end, d, ind, w, hs.a, hs.b, hs.c, value, on)
		}
		next := n[1:]
		if next >= end || next[0] <= ' ' {
			return #must_tail st_member_ws(next, end, d, ind, w, hs.a, hs.b, hs.c, value, on)
		}
		p = next
		run += 1
	}
}

@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_bad_literal :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	q, kind := literal_fault(p, end)
	return fault(w, hook.Regs{s0, s1, s2}, q, kind, .Literal if kind == .Bad_Char else .None)
}

// `p` is where a value must start, at a byte that starts none. The fault's detail is chosen here, so the states that
// send a fault here compile none of that choice.

@(private, cold, enable_target_feature = STATE_FEATURES)
st_bad_value :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	when S != .Json5 {
		if .Non_Finite in w.tolerate && (p[0] == '+' || p[0] == 'I' || p[0] == 'N') {
			return #must_tail st_number5(p, end, d, ind, w, s0, s1, s2, m, on)
		}
	}
	kind := piece_short(w, p, end, .Bad_Char)
	return fault(w, hook.Regs{s0, s1, s2}, p, kind, value_detail(p, end, d) if kind == .Bad_Char else .None)
}

// `st_bad_value` where an object's key must start.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_bad_key :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	return fault(w, hook.Regs{s0, s1, s2}, p, .Bad_Char, key_detail(p, end))
}

// `st_bad_value` after a value, at a byte that is no comma and no close of its container.
@(private = "file", cold, enable_target_feature = STATE_FEATURES)
st_bad_after :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	return fault(w, hook.Regs{s0, s1, s2}, p, .Bad_Char, after_detail(p, d))
}

@(private = "file")
Byte_Class :: enum u8 {
	Bad,
	String,
	Number,
	Literal,
	Map,
	Array,
}

@(private = "file", rodata)
VALUE_CLASS := [256]Byte_Class {
	'"' = .String,
	'-' = .Number,
	'0' ..= '9' = .Number,
	't' = .Literal,
	'f' = .Literal,
	'n' = .Literal,
	'{' = .Map,
	'[' = .Array,
}
