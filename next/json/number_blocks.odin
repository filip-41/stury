package json

import "base:intrinsics"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"

// The levels below an array's depth `st_number_blocks` looks at for arrays it may close.
@(private)
FLOOR_LEVELS :: 8

// The state for arrays of arrays of numbers, at the close bracket after a number where `,[` follows. It judges 64-byte
// blocks with masks while each holds only digits, `-`, `.`, `,`, `[` and `]` and a comma, and gives the tokens of each
// judged block up to its last comma. At the first block it cannot judge, the walk goes on in `st_after` from the last
// comma given, or from `p`, so the states read every byte the masks did not judge. Only a hook that answers every token
// with `Next` enters it.
@(private, enable_target_feature = STATE_FEATURES)
st_number_blocks :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result #no_bounds_check {
	hs := tape.Hook_Regs{s0, s1, s2}
	dep := d >> 1
	// The depth a close may bring the walk down to, with every container from it to `dep` an array. Depth 0 is the
	// root's end.
	floor := dep
	for floor > 1 && dep - floor < FLOOR_LEVELS && u8(w.stack[floor - 1]) == ']' {
		floor -= 1
	}
	// The stack's levels from `floor` up to `zeroed` hold arrays. An array passes on the gap slot it opened with, so each
	// level holds the slot of the one below, and `m` is read back from the level the walk goes on in.
	zeroed := dep
	at, at_dep := p, dep
	q := p
	// The previous block's masks, whose top bits carry into this block's first byte. The byte before `p` is a digit,
	// whose number the hook was given.
	pn, pd, pm, pp, pl, po, pc, pk: u64 = 1 << 63, 1 << 63, 0, 0, 0, 0, 0, 0
	// The carry of the fraction runs' sum out of the previous block.
	frac_carry: u64
	when H != tape.No_Hooks {
		// The previous block's tokens past its last comma, which the hook has not been given, and where the number
		// after its last `[` or `,` starts and has its `.`.
		tail: Block_Tokens
		start, dot_at: [^]u8
	}
	for intrinsics.ptr_sub(end, q) >= 64 {
		b := kernel.load(q)
		ms := kernel.pack_n([4]kernel.Block{digits(b), kernel.eq(b, '-'), kernel.eq(b, '.'), kernel.eq(b, ',')})
		n := kernel.pack_n([3]kernel.Block{kernel.eq(b, '['), kernel.eq(b, ']'), kernel.eq(b, '0')})
		dg, mi, dot, comma := ms[0], ms[1], ms[2], ms[3]
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
			w.stack[zeroed] = w.stack[zeroed - 1] &~ 0xFF | ']'
			zeroed += 1
		}
		dep = dep + opens - closes
		last := 63 - u64(intrinsics.count_leading_zeros(comma))
		past := ~u64(0) << last << 1
		when H != tape.No_Hooks {
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
	return #must_tail st_after(at, end, at_dep << 1, ind, w, hs.a, hs.b, hs.c, u64(w.stack[at_dep - 1] >> 8), G, on)
}

// The token masks of a block. Only the tokens in `keep` are given.
@(private)
Block_Tokens :: struct {
	base:   [^]u8,
	ends:   u64, // the byte after each number
	dots:   u64, // each number's `.`
	seps:   u64, // the `[` or `,` before each number
	opens:  u64,
	closes: u64,
	keep:   u64,
}

// Gives the hook the tokens of `t` in text order. A number's end and a close at one byte give the number first. A
// number with no `[` or `,` before it in `t` starts at `start` and has its `.` at `dot_at`, from the block before.
@(private = "file")
block_tokens :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action), hs: ^tape.Hook_Regs, t: Block_Tokens, start, dot_at: [^]u8) #no_bounds_check {
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
			spelling := tape.number_spelling(0, u64(intrinsics.ptr_sub(int_end, digits_at)), frac)
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
