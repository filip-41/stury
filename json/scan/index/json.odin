package index

// JSON's rules for one 64-byte block: which bytes are operators and whitespace, how a backslash escapes, and
// where a scalar run starts. `classify` (index.odin) runs `block` over a region; the quote and escape masks are
// core's (bits.odin).
//
// A backslash escapes the next byte everywhere, inside a string or not. Outside a string that input is
// invalid anyway, and stage 2 rejects it.
//
// `block` loads 64 bytes at `p` unchecked: `classify` passes a pointer into `src` only while 64 bytes remain
// before the region's end, and the last, shorter block as a copy in a 64-byte buffer of spaces, which open no
// string and start no token. `$F` adds per-block work: `.Ctrl_In_String` folds control bytes inside strings
// into `acc.ctrl`, `.Scalar_Shape` checks scalar runs.

import "base:intrinsics"
import "core:simd"
import lex "../lex"

// Nibble classification. lo & hi != 0 marks the byte, and no other bit is
// ever set, so a nonzero class is an operator or whitespace, and the
// operator bits sit above the whitespace bits so that a class above 7 is an
// operator, one compare per lane:
//   bit0 \t \n \r   bit1 space   bit3 [ ] { }   bit4 ,   bit5 :
@(rodata) LO_TBL := V{2, 0, 0, 0, 0, 0, 0, 0, 0, 1, 33, 8, 16, 9, 0, 0}
@(rodata) HI_TBL := V{1, 0, 18, 32, 0, 8, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0}

// Scalar classes, the same way: bits 0-2 are the number characters
// (0-9, + - ., e E), bits 3-4 the letters (A-Z a-z), so a class above 7 is a
// letter.
//   bit0 0-9   bit1 + - .   bit2 e E   bit3 A-O a-o   bit4 P-Z p-z
@(rodata) LO_SCALAR := V{17, 25, 25, 25, 25, 29, 25, 25, 25, 25, 24, 10, 8, 10, 10, 8}
@(rodata) HI_SCALAR := V{0, 0, 2, 1, 12, 16, 12, 16, 0, 0, 0, 0, 0, 0, 0, 0}

// Everything a block needs from the bytes before it. A forward walk carries it
// from block to block and region to region. The document start is the zero value
// plus the bytes before it.
Carry :: struct {
	in_string:   u64, // all ones inside a string
	prev_odd:    u64, // 1 when an odd backslash run ends right before
	prev_scalar: u64, // 1 when a scalar run continues into the block
	num_run:     u64, // 1 when that run started with a number character
	alpha_run:   u64, // 1 when it started with a letter
	// The 16 bytes before the block, zeros before the source. Bytes rather
	// than a vector, whose alignment would pad the struct (see `Index`).
	prev:        [16]u8,
}

// What one region's blocks found besides token starts.
Chunk_Acc :: struct {
	bs:        u64, // any backslash
	ctrl:      u64, // any control byte inside a string
	utf8_err:  V,
	// Any scalar byte its run does not allow (`scalar_shape`).
	scalar_bad: u64,
	// The previous block's token starts, written while this block classifies.
	pend:      u64,
	pend_base: u16,
}

// The block's quotes that no backslash escapes, and the bytes inside a string,
// carried in from `cy`. Folds the block's wire faults into `acc`.
string_bits :: #force_inline proc(v: [4]V, quote, bs: u64, cy: ^Carry, acc: ^Chunk_Acc, $F: Facts) -> (real_q, instr: u64) {
	prev := transmute(V)cy.prev
	cy.prev = transmute([16]u8)v[3]
	// `prev` joins the gate: a sequence cut by the block edge is refused by
	// the first window of an all-ASCII block.
	if lex.any_high(prev | v[0] | v[1] | v[2] | v[3]) {
		acc.utf8_err |= utf8_block(prev, v)
	}

	acc.bs |= bs
	real_q, instr = string_region(quote, bs, &cy.prev_odd, &cy.in_string)
	when .Ctrl_In_String in F {
		// Most blocks hold no byte below 0x20 at all, and one reduction says
		// so for fewer vector operations than the lane mask costs.
		if simd.reduce_min(simd.min(simd.min(v[0], v[1]), simd.min(v[2], v[3]))) < 0x20 {
			ctrl := pack4(simd.lanes_lt(v[0], V(0x20)), simd.lanes_lt(v[1], V(0x20)), simd.lanes_lt(v[2], V(0x20)), simd.lanes_lt(v[3], V(0x20)))
			acc.ctrl |= ctrl & instr
		}
	}
	return
}

// A block that opens inside a string and holds no quote or backslash is
// string to its end: it lists nothing and leaves every carry as it was, so
// only its wire checks remain. A backslash pending from the block before only
// matters to a quote or a backslash, so it lapses.
@(private = "file")
inside_string :: #force_inline proc(v: [4]V, cy: ^Carry, acc: ^Chunk_Acc, $F: Facts) {
	prev := transmute(V)cy.prev
	cy.prev = transmute([16]u8)v[3]
	cy.prev_odd = 0
	if lex.any_high(prev | v[0] | v[1] | v[2] | v[3]) {
		acc.utf8_err |= utf8_block(prev, v)
	}
	when .Ctrl_In_String in F {
		if simd.reduce_min(simd.min(simd.min(v[0], v[1]), simd.min(v[2], v[3]))) < 0x20 {
			acc.ctrl |= 1
		}
	}
}

// One 64-byte block at `p`, whose first byte is `base` bytes into its region:
// token starts are each bracket, comma and colon outside a string, each opening
// quote, and the first byte of each scalar run. The block's starts are appended
// one block late (`acc.pend`), so the caller flushes the last ones.
block :: #force_inline proc(p: [^]u8, base: u16, cy: ^Carry, acc: ^Chunk_Acc, out: [^]u16, n: int, $F: Facts) -> int {
	v := [4]V{load(p), load(p[16:]), load(p[32:]), load(p[48:])}
	quote, bs := quote_and_escape_bits(v, '"', '\\')
	// Tested quote-free first: few blocks are outside a long string, so the
	// test predicts where the carry alone would not.
	if quote | bs == 0 && cy.in_string != 0 {
		inside_string(v, cy, acc, F)
		flushed := flatten(out, n, acc.pend, acc.pend_base)
		acc.pend, acc.pend_base = 0, base
		return flushed
	}
	lo, hi, c: [4]V
	#unroll for k in 0 ..< 4 {
		lo[k] = simd.bit_and(v[k], V(0x0f))
		hi[k] = simd.shr(v[k], 4)
		c[k] = simd.runtime_swizzle(LO_TBL, lo[k]) & simd.runtime_swizzle(HI_TBL, hi[k])
	}
	op := pack4(simd.lanes_gt(c[0], V(7)), simd.lanes_gt(c[1], V(7)), simd.lanes_gt(c[2], V(7)), simd.lanes_gt(c[3], V(7)))
	sep := pack4(simd.lanes_ne(c[0], V(0)), simd.lanes_ne(c[1], V(0)), simd.lanes_ne(c[2], V(0)), simd.lanes_ne(c[3], V(0)))
	real_q, instr := string_bits(v, quote, bs, cy, acc, F)

	scalar := ~(sep | real_q) & ~instr
	follows := (scalar << 1) | cy.prev_scalar
	cy.prev_scalar = scalar >> 63
	starts := scalar & ~follows
	m := (op & ~instr) | (real_q & instr) | starts
	when .Scalar_Shape in F {
		// A block inside a string, as most of a long one is, has no run to check.
		if scalar != 0 {
			acc.scalar_bad |= scalar_shape(lo, hi, scalar, starts, cy)
		} else {
			cy.num_run, cy.alpha_run = 0, 0
		}
	}

	flushed := flatten(out, n, acc.pend, acc.pend_base)
	acc.pend, acc.pend_base = m, base
	return flushed
}

// The scalar bytes their run does not allow. A run that starts with a number
// character may hold only number characters, and one that starts with a letter
// only letters: what Locate asks of a number or a literal. A run that starts
// with anything else is refused at its first byte by stage 2.
@(private = "file")
scalar_shape :: #force_inline proc(lo, hi: [4]V, scalar, starts: u64, cy: ^Carry) -> u64 {
	c: [4]V
	#unroll for k in 0 ..< 4 {
		c[k] = simd.runtime_swizzle(LO_SCALAR, lo[k]) & simd.runtime_swizzle(HI_SCALAR, hi[k])
	}
	num := pack4(
		simd.lanes_ne(simd.bit_and(c[0], V(7)), V(0)), simd.lanes_ne(simd.bit_and(c[1], V(7)), V(0)),
		simd.lanes_ne(simd.bit_and(c[2], V(7)), V(0)), simd.lanes_ne(simd.bit_and(c[3], V(7)), V(0)))
	alpha := pack4(simd.lanes_gt(c[0], V(7)), simd.lanes_gt(c[1], V(7)), simd.lanes_gt(c[2], V(7)), simd.lanes_gt(c[3], V(7)))
	in_num := run_bytes(scalar, starts & num, &cy.num_run)
	in_alpha := run_bytes(scalar, starts & alpha, &cy.alpha_run)
	return (in_num & ~num) | (in_alpha & ~alpha)
}

// Every byte of the runs in `scalar` that begin at a bit of `starts`, and of
// the run `carry` says continues into the block. Adding a start bit carries
// through its run, so the bits the sum clears are the run.
run_bytes :: #force_inline proc(scalar, starts: u64, carry: ^u64) -> u64 {
	sum, out := intrinsics.overflow_add(scalar, starts | carry^)
	carry^ = 1 if out else 0
	return (sum ~ scalar) & scalar
}
