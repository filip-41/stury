package json

import "base:intrinsics"
import core "../core"
import kernel "../core/kernel"

// The levels below an array's depth `st_number_blocks` looks at for arrays it may close.
@(private)
FLOOR_LEVELS :: 8

// `p` is at the close bracket right after a number, where `,[` follows. Arrays of arrays of numbers are judged here
// 64 bytes at a time with masks, while every byte of a block is a digit, `-`, `.`, `,`, `[` or `]`, the block holds a
// comma, and its numbers, separators and brackets are valid, in arrays it may open and arrays it may close. Each judged
// block passes its tokens to the hook up to its last comma. At the first block that is not judged, the walk goes on in
// `st_after` from the last comma passed, or from `p`, so the states read every byte the masks did not vouch for, give
// every token not given yet, and fault where they would. Only a hook that takes every token with `Next` enters it.
@(private, enable_target_feature = STATE_FEATURES)
st_number_blocks :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 #no_bounds_check {
	hs := core.Hook_Regs{s0, s1, s2}
	dep := d >> 1
	// A close may bring the walk down to `floor`: every container from it to `dep` is an array, and depth 0 is the
	// root's end.
	floor := dep
	for floor > 1 && dep - floor < FLOOR_LEVELS && w.stack[floor - 1] == 0 {
		floor -= 1
	}
	// The stack's slots from `floor` up to `zeroed` hold an array's kind, 0.
	zeroed := dep
	at, at_dep := p, dep
	q := p
	// The previous block's masks, whose top bits carry into this block's first byte. The byte before `p` is a digit,
	// whose number the hook was given.
	pn, pd, pm, pp, pl, po, pc, pk: u64 = 1 << 63, 1 << 63, 0, 0, 0, 0, 0, 0
	// The carry of the fraction runs' sum out of the previous block.
	frac_carry: u64
	when H != core.No_Hooks {
		// The previous block's tokens past its last comma, which the hook has not been given, and where the number
		// after its last `[` or `,` starts and has its `.`.
		tail: Block_Tokens
		start, dot_at: [^]u8
	}
	for intrinsics.ptr_sub(end, q) >= 64 {
		b := kernel.load(q)
		m := kernel.pack_n([4]kernel.Block{digits(b), kernel.eq(b, '-'), kernel.eq(b, '.'), kernel.eq(b, ',')})
		n := kernel.pack_n([3]kernel.Block{kernel.eq(b, '['), kernel.eq(b, ']'), kernel.eq(b, '0')})
		dg, mi, dot, comma := m[0], m[1], m[2], m[3]
		open, close, zero := n[0], n[1], n[2]
		num := dg | mi | dot
		after_num := after(num, pn)
		after_minus := after(mi, pm)
		after_dot := after(dot, pp)
		// The first digit of each integer part that is a 0.
		lead_zero := (dg & ~after_num | after_minus) & zero
		// One past each fraction's digits. `after_dot` lands on the fraction's first digit, so the sum carries
		// through the fraction's run of digits.
		part, c1 := intrinsics.overflow_add(dg, after_dot)
		sum, c2 := intrinsics.overflow_add(part, frac_carry)
		bad := ~(num | comma | open | close)
		bad |= mi & after_num                           // a `-` inside a number
		bad |= after_minus & ~dg                        // a `-` with no digit after it
		bad |= dot & ~after(dg, pd)                     // a `.` with no digit before it
		bad |= after_dot & ~dg                          // a `.` with no digit after it
		bad |= after(lead_zero, pl) & dg                // a leading 0 with a digit after it
		bad |= sum & ~dg & dot                          // a second `.` in a number
		bad |= after(open, po) & ~(num | open | close)  // no value or close after `[`
		bad |= after(comma, pc) & ~(num | open)         // no value after `,`
		bad |= after(close, pk) & ~(comma | close)      // no `,` or close after `]`
		bad |= after_num & open                         // `[` right after a number
		if bad != 0 || comma == 0 {
			break
		}
		opens, closes := u64(intrinsics.count_ones(open)), u64(intrinsics.count_ones(close))
		if dep + opens > w.depth || kernel.depth_low(int(floor), int(dep), open, close) < int(floor) {
			break
		}
		for zeroed < dep + opens {
			w.stack[zeroed] = 0
			zeroed += 1
		}
		dep = dep + opens - closes
		last := 63 - u64(intrinsics.count_leading_zeros(comma))
		past := ~u64(0) << last << 1
		when H != core.No_Hooks {
			// A number's end is the byte after its last, a comma or a close. The end at `p` is the number the hook was
			// given before this state.
			t := Block_Tokens{q, after_num & ~num & ~u64(q == p), dot, open | comma, open, close, ~past}
			block_tokens(w, on, &hs, tail, start, dot_at)
			block_tokens(w, on, &hs, t, start, dot_at)
			tail = t
			tail.keep = past
			top := 63 - u64(intrinsics.count_leading_zeros(t.seps))
			start, dot_at = q[top + 1:], nil
			if dots := dot & (~u64(0) << top << 1); dots != 0 {
				dot_at = q[63 - intrinsics.count_leading_zeros(dots):]
			}
		}
		at = q[last:]
		at_dep = dep - u64(intrinsics.count_ones(open & past)) + u64(intrinsics.count_ones(close & past))
		frac_carry = u64(c1 | c2)
		pn, pd, pm, pp, pl, po, pc, pk = num, dg, mi, dot, lead_zero, open, comma, close
		q = q[64:]
	}
	return #must_tail st_after(at, end, at_dep << 1, ind, w, hs.a, hs.b, hs.c, on)
}

// A block's token masks: where each number ends and has its `.`, the `[` and `,` before each number, and its
// brackets. Only the tokens in `keep` are given.
@(private)
Block_Tokens :: struct {
	base:                                   [^]u8,
	ends, dots, seps, opens, closes, keep: u64,
}

// Gives the hook the tokens of `t` in text order. A number's end and a close at one byte give the number first. A
// number with no `[` or `,` before it in `t` starts at `start` and has its `.` at `dot_at`, from the block before.
@(private = "file")
block_tokens :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, t: Block_Tokens, start, dot_at: [^]u8) #no_bounds_check {
	for ev := (t.ends | t.opens | t.closes) & t.keep; ev != 0; ev &= ev - 1 {
		bit := ev & -ev
		x := t.base[intrinsics.count_trailing_zeros(ev):]
		if t.ends & bit != 0 {
			s, dot, from := start, dot_at, ~u64(0)
			if seps := t.seps & (bit - 1); seps != 0 {
				top := 63 - u64(intrinsics.count_leading_zeros(seps))
				s, dot, from = t.base[top + 1:], nil, ~u64(0) << top
			}
			if dots := t.dots & (bit - 1) & from; dots != 0 {
				dot = t.base[63 - intrinsics.count_leading_zeros(dots):]
			}
			digits_at := s[u64(s[0] == '-'):]
			int_end, frac := x, u64(0)
			if dot != nil {
				int_end, frac = dot, u64(intrinsics.ptr_sub(x, dot)) - 1
			}
			spelling := core.number_spelling(u16(Number_Spelling.Json), u64(intrinsics.ptr_sub(int_end, digits_at)), frac)
			emit(w, on, hs, .Number, .Value, s, x, spelling)
		}
		if t.opens & bit != 0 {
			emit(w, on, hs, .Array, .Value, x, x[1:], 0)
		} else if t.closes & bit != 0 {
			emit(w, on, hs, .End, .Value, x, x[1:], 0)
		}
	}
}

// The mask `x` moved one byte later, with the previous block's last byte from `prev` in its first.
@(private = "file")
after :: #force_inline proc "contextless" (x, prev: u64) -> u64 {
	return x << 1 | prev >> 63
}

@(private = "file")
digits :: #force_inline proc "contextless" (b: kernel.Block) -> kernel.Block {
	W :: #simd[64]u8
	return kernel.below(transmute(kernel.Block)(transmute(W)b - W('0')), 10)
}
