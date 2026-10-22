#+build amd64
package index

// `classify` in two 32-byte registers per block, for amd64 processors with AVX2 and no AVX-512BW. Each lane
// mask is two compares and two movemasks where the 16-byte windows take four of each, and the prefix XOR is
// a carry-less multiply. The UTF-8 check stays `utf8_block`'s, out of line. It lists the same positions and
// leaves the same carries and region flags as `classify_narrow`, which the scan tests check.

import "base:intrinsics"
import "core:simd"
import "core:sys/info"
import lex "../lex"

@(private = "file")
H :: #simd[32]u8

@(private = "file")
AVX2_FEATURES :: "avx,avx2,bmi,pclmul,popcnt"

avx2_ok :: #force_inline proc "contextless" () -> bool {
	when !lex.SCAN_WIDE {
		return false
	}
	return info.cpu_features() >= {.avx2, .bmi1, .pclmulqdq}
}

@(private = "file", default_calling_convention = "none")
foreign _ {
	@(link_name = "llvm.x86.avx2.pshuf.b")
	pshufb256 :: proc(t, idx: H) -> H ---
	@(link_name = "llvm.x86.pclmulqdq")
	pclmulqdq :: proc(a, b: #simd[2]i64, #const imm8: u8) -> #simd[2]i64 ---
}

@(private = "file")
Avx2_Acc :: struct {
	bs, ctrl, scalar_bad: u64,
	utf8_err:             V,
	prev:                 V, // the 16 bytes before the block
	pend:                 u64,
	pend_base:            u16,
}

@(enable_target_feature = AVX2_FEATURES)
classify_avx2 :: proc(ix: ^Index($F), lo, hi: int) {
	cy := ix.carry
	acc: Avx2_Acc
	acc.prev = transmute(V)cy.prev
	out := raw_data(ix.buf[:])
	at := raw_data(ix.src)
	n := 0
	p := lo
	for p + 64 <= hi {
		n = block_avx2(at[p:], u16(p - lo), &cy, &acc, out, n, F)
		p += 64
	}
	if p < hi {
		pad: [64]u8 = ' '
		copy(pad[:], ix.src[p:hi])
		n = block_avx2(raw_data(pad[:]), u16(p - lo), &cy, &acc, out, n, F)
	}
	cy.prev = transmute([16]u8)acc.prev
	ix.carry = cy
	ix.n = flatten(out, n, acc.pend, acc.pend_base)
	ix.chunk_lo = lo
	ix.next_lo = hi
	ix.chunk_bs = acc.bs != 0
	ix.chunk_wire_ok = simd.reduce_or(acc.utf8_err) == 0 && acc.ctrl == 0
	ix.chunk_scalar_ok = .Scalar_Shape in F && acc.scalar_bad == 0
}

// The lanes of a block pair's lane masks, as bits.
@(private = "file", enable_target_feature = AVX2_FEATURES)
bits2 :: #force_inline proc "contextless" (a, b: H) -> u64 {
	return u64(transmute(u32)simd.extract_msbs(a)) | u64(transmute(u32)simd.extract_msbs(b)) << 32
}

@(private = "file", enable_target_feature = AVX2_FEATURES)
table2 :: #force_inline proc "contextless" (t: V) -> H {
	return transmute(H)[2]V{t, t}
}

// `block` (json.odin) over two registers.
@(private = "file", enable_target_feature = AVX2_FEATURES)
block_avx2 :: #force_inline proc(p: [^]u8, base: u16, cy: ^Carry, acc: ^Avx2_Acc, out: [^]u16, n: int, $F: Facts) -> int {
	v0 := intrinsics.unaligned_load((^H)(p))
	v1 := intrinsics.unaligned_load((^H)(p[32:]))
	quote := bits2(simd.lanes_eq(v0, H('"')), simd.lanes_eq(v1, H('"')))
	bs := bits2(simd.lanes_eq(v0, H('\\')), simd.lanes_eq(v1, H('\\')))
	prev := acc.prev
	acc.prev = (transmute([2]V)v1)[1]
	if simd.extract_msbs(v0 | v1) != {} || lex.any_high(prev) {
		acc.utf8_err |= utf8_block(prev, transmute([4]V)[2]H{v0, v1})
	}
	when .Ctrl_In_String in F {
		ctrl := bits2(simd.lanes_lt(v0, H(0x20)), simd.lanes_lt(v1, H(0x20)))
	}

	if quote | bs == 0 && cy.in_string != 0 {
		cy.prev_odd = 0
		when .Ctrl_In_String in F {
			acc.ctrl |= ctrl
		}
		flushed := flatten(out, n, acc.pend, acc.pend_base)
		acc.pend, acc.pend_base = 0, base
		return flushed
	}
	lo0, lo1 := simd.bit_and(v0, H(0x0f)), simd.bit_and(v1, H(0x0f))
	hi0, hi1 := simd.shr(v0, 4), simd.shr(v1, 4)
	lo_t, hi_t := table2(LO_TBL), table2(HI_TBL)
	c0 := pshufb256(lo_t, lo0) & pshufb256(hi_t, hi0)
	c1 := pshufb256(lo_t, lo1) & pshufb256(hi_t, hi1)
	op := bits2(simd.lanes_gt(c0, H(7)), simd.lanes_gt(c1, H(7)))
	sep := ~bits2(simd.lanes_eq(c0, H(0)), simd.lanes_eq(c1, H(0)))

	acc.bs |= bs
	escaped: u64
	if bs != 0 || cy.prev_odd != 0 {
		escaped = escaped_bits(bs, &cy.prev_odd)
	}
	real_q := quote & ~escaped
	instr := u64(simd.extract(pclmulqdq(#simd[2]i64{i64(real_q), 0}, #simd[2]i64{-1, -1}, 0), 0)) ~ cy.in_string
	cy.in_string = u64(i64(instr) >> 63)
	when .Ctrl_In_String in F {
		acc.ctrl |= ctrl & instr
	}

	scalar := ~(sep | real_q) & ~instr
	follows := (scalar << 1) | cy.prev_scalar
	cy.prev_scalar = scalar >> 63
	starts := scalar & ~follows
	m := (op & ~instr) | (real_q & instr) | starts
	when .Scalar_Shape in F {
		if scalar != 0 {
			ls, hs := table2(LO_SCALAR), table2(HI_SCALAR)
			s0 := pshufb256(ls, lo0) & pshufb256(hs, hi0)
			s1 := pshufb256(ls, lo1) & pshufb256(hs, hi1)
			num := ~bits2(simd.lanes_eq(simd.bit_and(s0, H(7)), H(0)), simd.lanes_eq(simd.bit_and(s1, H(7)), H(0)))
			alpha := bits2(simd.lanes_gt(s0, H(7)), simd.lanes_gt(s1, H(7)))
			in_num := run_bytes(scalar, starts & num, &cy.num_run)
			in_alpha := run_bytes(scalar, starts & alpha, &cy.alpha_run)
			acc.scalar_bad |= (in_num & ~num) | (in_alpha & ~alpha)
		} else {
			cy.num_run, cy.alpha_run = 0, 0
		}
	}

	flushed := flatten(out, n, acc.pend, acc.pend_base)
	acc.pend, acc.pend_base = m, base
	return flushed
}
