#+build amd64
package index

// `classify` in 64-byte registers, for amd64 processors with AVX-512BW (lex_span_wide.odin has the target and
// the runtime check). A block is one register, so each lane mask is one compare into a mask register where
// four 16-byte windows take a compare and a movemask each, and the string region's prefix XOR is one
// carry-less multiply where the shift chain takes twelve operations in a row. It lists the same positions and
// leaves the same carries and region flags as `classify_narrow`.

import "base:intrinsics"
import "core:simd"
import "core:sys/info"
import lex "../lex"

@(private = "file")
Block64 :: lex.Block64

// `lex.WIDE_FEATURES` and the carry-less multiply.
WIDE_FEATURES :: lex.WIDE_FEATURES + ",pclmul"

// `-define:SCAN_WIDE_512=false` sends an AVX-512 processor to the AVX2 index (block_avx2.odin), to time that
// route on one.
SCAN_WIDE_512 :: #config(SCAN_WIDE_512, true)

// Every processor with AVX-512BW has PCLMULQDQ, but a hypervisor can mask either.
wide_ok :: #force_inline proc "contextless" () -> bool {
	return SCAN_WIDE_512 && lex.wide_ok() && .pclmulqdq in info.cpu_features()
}

@(private = "file", default_calling_convention = "none")
foreign _ {
	@(link_name = "llvm.x86.pclmulqdq")
	pclmulqdq :: proc(a, b: #simd[2]i64, #const imm8: u8) -> #simd[2]i64 ---
}

// What a region's blocks found besides token starts, as `Chunk_Acc`, plus the block before for the UTF-8 check.
@(private = "file")
Wide_Acc :: struct {
	bs, ctrl, scalar_bad: u64,
	utf8_err:             Block64,
	// The block before, of which the UTF-8 check reads the last three lanes, and those lanes' top bits: a
	// character unfinished there makes the next block check even without a byte >= 0x80 of its own.
	prev:                 Block64,
	open:                 u64,
	pend:                 u64,
	pend_base:            u16,
}

@(enable_target_feature = WIDE_FEATURES)
classify_wide :: proc(ix: ^Index($F), lo, hi: int) {
	cy := ix.carry
	acc: Wide_Acc
	acc.prev = transmute(Block64)[4]V{{}, {}, {}, transmute(V)cy.prev}
	acc.open = lex.bits_wide(acc.prev) >> 61
	out := raw_data(ix.buf[:])
	at := raw_data(ix.src)
	n := 0
	p := lo
	for p + 64 <= hi {
		n = block_wide(intrinsics.unaligned_load((^Block64)(at[p:])), u16(p - lo), &cy, &acc, out, n, F)
		p += 64
	}
	if p < hi {
		pad: [64]u8 = ' '
		copy(pad[:], ix.src[p:hi])
		n = block_wide(transmute(Block64)pad, u16(p - lo), &cy, &acc, out, n, F)
	}
	cy.prev = transmute([16]u8)(transmute([4]V)acc.prev)[3]
	ix.carry = cy
	ix.n = flatten(out, n, acc.pend, acc.pend_base)
	ix.chunk_lo = lo
	ix.next_lo = hi
	ix.chunk_bs = acc.bs != 0
	ix.chunk_wire_ok = simd.reduce_or(acc.utf8_err) == 0 && acc.ctrl == 0
	ix.chunk_scalar_ok = .Scalar_Shape in F && acc.scalar_bad == 0
}

// `block` (json.odin) over one register.
@(private = "file", enable_target_feature = WIDE_FEATURES)
block_wide :: #force_inline proc(v: Block64, base: u16, cy: ^Carry, acc: ^Wide_Acc, out: [^]u16, n: int, $F: Facts) -> int {
	quote := lex.bits_wide(simd.lanes_eq(v, Block64('"')))
	bs := lex.bits_wide(simd.lanes_eq(v, Block64('\\')))
	high := lex.bits_wide(v)
	if high | acc.open != 0 {
		acc.utf8_err |= lex.utf8_err_wide(acc.prev, v)
	}
	acc.prev = v
	acc.open = high >> 61
	when .Ctrl_In_String in F {
		ctrl := lex.bits_wide(simd.lanes_lt(v, Block64(0x20)))
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
	lo := simd.bit_and(v, Block64(0x0f))
	hi := simd.shr(v, 4)
	c := lex.pshufb_wide(lex.table_wide(LO_TBL), lo) & lex.pshufb_wide(lex.table_wide(HI_TBL), hi)
	op := lex.bits_wide(simd.lanes_gt(c, Block64(7)))
	sep := lex.bits_wide(simd.lanes_ne(c, Block64(0)))

	acc.bs |= bs
	escaped: u64
	if bs != 0 || cy.prev_odd != 0 {
		escaped = escaped_bits(bs, &cy.prev_odd)
	}
	real_q := quote & ~escaped
	instr := clmul_prefix_xor(real_q) ~ cy.in_string
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
			sc := lex.pshufb_wide(lex.table_wide(LO_SCALAR), lo) & lex.pshufb_wide(lex.table_wide(HI_SCALAR), hi)
			num := lex.bits_wide(simd.lanes_ne(simd.bit_and(sc, Block64(7)), Block64(0)))
			alpha := lex.bits_wide(simd.lanes_gt(sc, Block64(7)))
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

// `prefix_xor` as a carry-less multiply by all ones.
@(enable_target_feature = WIDE_FEATURES)
clmul_prefix_xor :: #force_inline proc "contextless" (x: u64) -> u64 {
	return u64(simd.extract(pclmulqdq(#simd[2]i64{i64(x), 0}, #simd[2]i64{-1, -1}, 0), 0))
}
