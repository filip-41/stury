package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The levels below an array's depth `st_number_blocks` looks at for arrays it may close.
@(private)
FLOOR_LEVELS :: 8

// The state for arrays of arrays of numbers, at the close bracket after a number where `,[` follows. It judges 64-byte
// blocks with masks while each holds only digits, `-`, `.`, `,`, `[` and `]`, and gives the tokens of each
// judged block. At the first block it cannot judge, the walk goes on past the last `,`, `[` or `]` judged, in the state
// that byte leaves it in, or from `p`, so the states read every byte the masks did not judge. Only a hook with
// `.Number_Blocks` enters it, and a `Stop` ends the walk at its token. It answers no `Grow`, as a block is given only
// while the room has place for it, nor `Skip`, `Rest` or `Keep`, which such a hook never gives.
@(private, enable_target_feature = STATE_FEATURES)
st_number_blocks :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d: u64, ind: Indent_Arg, w: ^Walk($S, $H, $LAX, $C), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result #no_bounds_check {
	hs := hook.Regs{s0, s1, s2}
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
	q := p
	// The last `,`, `[` or `]` of the blocks judged, nil before one is judged.
	last: [^]u8
	// The previous block's masks, whose top bits carry into this block's first byte. The byte before `p` is a digit,
	// whose number the hook was given.
	pd, pm, pp, pl, po, pc, pk: u64 = 1 << 63, 0, 0, 0, 0, 0, 0
	// The carry of the fraction runs' sum out of the previous block.
	frac_carry: u64
	when H != hook.No_Hooks {
		// Where the number after the last `[` or `,` judged starts and has its `.`.
		start, dot_at: [^]u8
	}
	for intrinsics.ptr_sub(end, q) >= 64 {
		// A block gives at most a node per byte with no room check, so the room must have place for that many first.
		when .Rooms in C {
			if w.rooms - uintptr(hs.a) < 64 * size_of(tape.Node) {
				break
			}
		}
		b := kernel.load(q)
		ms := kernel.pack_n([4]kernel.Block{digits(b), kernel.eq(b, '-'), kernel.eq(b, '.'), kernel.eq(b, ',')})
		n := kernel.pack_n([3]kernel.Block{kernel.eq(b, '['), kernel.eq(b, ']'), kernel.eq(b, '0')})
		dg, mi, dot, comma := ms[0], ms[1], ms[2], ms[3]
		open, close, zero := n[0], n[1], n[2]
		num := dg | mi | dot
		after_dg := after(dg, pd)
		after_minus := after(mi, pm)
		after_dot := after(dot, pp)
		after_num := after_dg | after_minus | after_dot
		// The first digit of each integer part that is a 0.
		lead_zero := (dg & ~after_num | after_minus) & zero
		// One past each fraction's digits. `after_dot` marks the fraction's first digit, so the sum carries
		// through the fraction's run of digits.
		part, c1 := intrinsics.overflow_add(dg, after_dot)
		sum, c2 := intrinsics.overflow_add(part, frac_carry)
		bad := ~(num | comma | open | close)
		bad |= mi & after_num                           // a `-` inside a number
		bad |= after_minus & ~dg                        // a `-` with no digit after it
		bad |= dot & ~after_dg                          // a `.` with no digit before it
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
		top := 63 - u64(intrinsics.count_leading_zeros(open | comma | close))
		next_carry := u64(c1 | c2)
		next_pd, next_pm, next_pl := dg, mi, lead_zero
		when H != hook.No_Hooks {
			// If the previous block ended with `]` (`pk >> 63 == 1`), `top` was 63 so `start` points at `q[0:]` and
			// `dot_at` is nil. When this block starts with `,`, advance `start` past it (`q[1:]`) branchlessly.
			start = start[(pk >> 63) & comma & 1:]
			// A number's end is the byte after its last, a comma or a close. The end at `p` is the number the hook was
			// given before this state.
			t := Block_Tokens{q, after_num & ~num & ~u64(q == p), dot, open | comma, open, close}
			when !LAX && H == build.Builder {
				if on == build.builder_hook {
					block_tokens_builder(w.hooks, w.base, &hs, t, start, dot_at, false)
				} else if on == build.builder_hook_facts {
					block_tokens_builder(w.hooks, w.base, &hs, t, start, dot_at, true)
				} else if stop := block_tokens(w, on, &hs, t, start, dot_at); stop != nil {
					return stopped(w, hs, stop)
				}
			} else {
				if stop := block_tokens(w, on, &hs, t, start, dot_at); stop != nil {
					return stopped(w, hs, stop)
				}
			}
			start, dot_at = q[top + 1:], nil
			if dots := dot & (~u64(0) << top << 1); dots != 0 {
				dot_at = q[63 - intrinsics.count_leading_zeros(dots):]
			}
			pp, po, pc, pk = t.dots, t.opens, t.seps &~ t.opens, close
		} else {
			pp, po, pc, pk = dot, open, comma, close
		}
		last = q[top:]
		frac_carry = next_carry
		pd, pm, pl = next_pd, next_pm, next_pl
		q = q[64:]
	}
	// No `,`, `[` or `]` follows the last one judged before the block's end, so the walk is at depth `dep` in an array.
	slot := u64(w.stack[dep - 1] >> 8)
	if last == nil {
		return #must_tail st_after(p, end, dep << 1, ind, w, hs.a, hs.b, hs.c, slot, on)
	}
	if last[0] == '[' {
		return #must_tail st_open(last[1:], end, dep << 1, ind, w, hs.a, hs.b, hs.c, slot, on)
	}
	return #must_tail st_after(last[1:] if last[0] == ']' else last, end, dep << 1, ind, w, hs.a, hs.b, hs.c, slot, on)
}

// The token masks of a block.
@(private)
Block_Tokens :: struct {
	base:   [^]u8,
	ends:   u64, // the byte after each number
	dots:   u64, // each number's `.`
	seps:   u64, // the `[` or `,` before each number
	opens:  u64,
	closes: u64,
}

// Gives the hook the tokens of `t` in text order, and returns nil or one past the token the hook stopped at. A number's
// end and a close at one byte give the number first. A number with no `[` or `,` before it in `t` starts at `start` and
// has its `.` at `dot_at`, from the block before.
//
// The number an end closes starts at `num`, one past the `[` or `,` before it, which the tokens pass as they give it, and
// holds its `.` among `dots`, the block's `.`s at or after the numbers given, so no number reads either back from a mask.
// `dot_at` is the `.` no token of this block passes, that of a number whose `[` or `,` is in the block before.
@(private = "file")
block_tokens :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, t: Block_Tokens, start, dot_at: [^]u8) -> [^]u8 #no_bounds_check {
	num, dot, dots := start, dot_at, t.dots
	for ev := t.ends | t.opens | t.closes; ev != 0; ev &= ev - 1 {
		bit := ev & -ev
		x := t.base[intrinsics.count_trailing_zeros(ev):]
		if t.ends & bit != 0 {
			// A number holds one `.` at most, after its start and before its end, so the next one is its own.
			if dots != 0 {
				if d := t.base[intrinsics.count_trailing_zeros(dots):]; uintptr(d) < uintptr(x) {
					dot = d
				}
			}
			digits_at := num[u64(num[0] == '-'):]
			int_end, frac := x, u64(0)
			if dot != nil {
				int_end, frac = dot, u64(intrinsics.ptr_sub(x, dot)) - 1
			}
			spelling := tape.number_spelling(0, u64(intrinsics.ptr_sub(int_end, digits_at)), frac)
			if give(w, on, hs, tape.Token{at(w, num), u32(intrinsics.ptr_sub(x, num)), .Number, .Value, spelling}) == .Stop {
				return x
			}
			// The dots up to this number's end belong to numbers given.
			dots &= ~(bit | (bit - 1))
			dot = nil
			if t.seps & bit != 0 { // a `,` ends the number: the one after it starts here
				num = x[1:]
			}
		}
		if t.opens & bit != 0 {
			num, dot = x[1:], nil
			if give(w, on, hs, tape.Token{at(w, x), 1, .Array, .Value, 0}) == .Stop {
				return x[1:]
			}
		} else if t.closes & bit != 0 {
			if t.seps & (bit << 1) != 0 { // a `,` after the close: the one after it starts here
				num, dot = x[2:], nil
			}
			if give(w, on, hs, tape.Token{at(w, x), 1, .End, .Value, 0}) == .Stop {
				return x[1:]
			}
		}
	}
	return nil
}

// `block_tokens` specialized for `build.Builder` with loop-invariant pointers kept in SSA registers so node stores
// never force LLVM to reload `w.base`, `w.hooks`, `h.doc.nodes`, or `h.stack` per token. The caller checked room for
// 64 nodes and depth for `dep + opens`, so every store is in bounds and no token can stop or grow.
//
// Mask invariants from `st_number_blocks`'s `bad` check:
// - Every bit in `t.ends` is either a `,` (`t.seps & bit != 0`) or a `]` (`t.seps & bit == 0`), never `[`.
// - Every bit in `ev` with `t.ends & bit == 0` is either `[` (`t.opens & bit != 0`) or `]`, so `t.closes` need not stay live.
// - Each number has at most one `.`, so the lowest bit of `dots` before `x` is its own and `dots &= dots - 1` consumes it.
@(private = "file")
block_tokens_builder :: #force_inline proc "contextless" (h: ^build.Builder, base: [^]u8, hs: ^hook.Regs, t: Block_Tokens, start, dot_at: [^]u8, $FACTS: bool) #no_bounds_check {
	nodes := raw_data(h.doc.nodes)
	opens := raw_data(h.stack)
	num, dot, dots := start, dot_at, t.dots
	a, b, c := hs.a, hs.b, hs.c
	for ev := t.ends | t.opens | t.closes; ev != 0; ev &= ev - 1 {
		bit := ev & -ev
		x := t.base[intrinsics.count_trailing_zeros(ev):]
		if t.ends & bit != 0 {
			if dots != 0 {
				if d := t.base[intrinsics.count_trailing_zeros(dots):]; uintptr(d) < uintptr(x) {
					dot = d
					dots &= dots - 1
				}
			}
			digits_at := num[u64(num[0] == '-'):]
			int_end, frac := x, u64(0)
			if dot != nil {
				int_end, frac = dot, u64(intrinsics.ptr_sub(x, dot)) - 1
			}
			spelling := tape.number_spelling(0, u64(intrinsics.ptr_sub(int_end, digits_at)), frac)
			tok := tape.Token{u64(intrinsics.ptr_sub(num, base)), u32(intrinsics.ptr_sub(x, num)), .Number, .Value, spelling}
			((^[2]u64)(uintptr(a)))^ = transmute([2]u64)tok
			a += size_of(tape.Node)
			b += 1
			dot = nil
			if t.seps & bit != 0 {
				num = x[1:]
				continue
			}
		} else if t.opens & bit != 0 {
			num, dot = x[1:], nil
			tok := tape.Token{u64(intrinsics.ptr_sub(x, base)), 1, .Array, .Value, 0}
			((^[2]u64)(uintptr(a)))^ = transmute([2]u64)tok
			idx := u64((uintptr(a) - uintptr(nodes)) / size_of(tape.Node))
			opens[c] = b + 1
			c += 1
			a += size_of(tape.Node)
			b = idx << 32
			continue
		}
		if t.seps & (bit << 1) != 0 {
			num, dot = x[2:], nil
		}
		cur := u32((uintptr(a) - uintptr(nodes)) / size_of(tape.Node))
		open := u32(b >> 32)
		count := u32(b)
		when FACTS {
			h.closed = tape.Node_Index(open)
		}
		n := &nodes[open]
		n.n = cur - open
		n.spelling = u16(min(count, u32(tape.MAX_CHILDREN)))
		if intrinsics.expect(count >= u32(tape.MAX_CHILDREN), false) {
			counts := (^runtime.Raw_Dynamic_Array)(&h.counts)
			cn := counts.len
			([^]tape.Child_Count)(counts.data)[cn] = {tape.Node_Index(open), count}
			counts.len = cn + 1
		}
		c -= 1
		b = opens[c]
	}
	hs.a, hs.b, hs.c = a, b, c
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
