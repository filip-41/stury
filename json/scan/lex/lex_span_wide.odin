#+build amd64
package lex

// The string span and the UTF-8 check in one 64-byte register, for amd64 processors with AVX-512BW. The
// released amd64 builds target x86-64-v2, so the procs that use them carry the wider target themselves
// (`WIDE_FEATURES`) and are called only when `wide_ok` finds it on the running processor. A compare lands
// in a mask register, so a block's lane mask is one instruction where four 16-byte windows take seven.

import "base:intrinsics"
import "core:simd"
import "core:sys/info"

Block64 :: #simd[64]u8

// The target a wide proc is compiled for: AVX-512BW, and BMI1 for the mask arithmetic (`tzcnt`, `blsmsk`).
// LLVM before 22 keeps 512-bit registers behind `evex512` (later ones ignore it). Without it a
// 64-lane intrinsic fails to compile.
WIDE_FEATURES :: "avx,avx2,avx512f,avx512bw,avx512vl,evex512,bmi"

// `-define:SCAN_WIDE=false` keeps the wide procs unused, so a machine that has the features can time and
// test the x86-64-v2 routes the released build takes elsewhere.
SCAN_WIDE :: #config(SCAN_WIDE, true)

// What `WIDE_FEATURES` code needs of the running processor and its OS. A hypervisor can mask any feature
// bit, so each one is asked. `core:sys/info` reads them once, before `main`. The OS check (XGETBV) is part
// of it.
@(private = "file")
WIDE_CPU :: info.CPU_Features{.avx, .avx2, .avx512f, .avx512bw, .avx512vl, .bmi1}

wide_ok :: #force_inline proc "contextless" () -> bool {
	when !SCAN_WIDE {
		return false
	}
	return info.cpu_features() >= WIDE_CPU
}

@(default_calling_convention = "none")
foreign _ {
	// `simd.runtime_swizzle` picks the 64-lane form only when the whole build targets AVX-512.
	@(link_name = "llvm.x86.avx512.pshuf.b.512")
	pshufb_wide :: proc(t, idx: Block64) -> Block64 ---
}

// One bit per lane, the lane's top bit.
@(enable_target_feature = WIDE_FEATURES)
bits_wide :: #force_inline proc "contextless" (m: Block64) -> u64 {
	return transmute(u64)simd.extract_msbs(m)
}

// A 16-entry nibble table in each 16-byte quarter, for `pshufb_wide`, which looks up within its quarter.
@(enable_target_feature = WIDE_FEATURES)
table_wide :: #force_inline proc "contextless" (t: #simd[16]u8) -> Block64 {
	return transmute(Block64)[4]#simd[16]u8{t, t, t, t}
}

// `utf8_err` over 64 lanes. Of `prev`, the 64 bytes before `v`, only the last three are read.
@(enable_target_feature = WIDE_FEATURES)
utf8_err_wide :: #force_inline proc "contextless" (prev, v: Block64) -> Block64 {
	p1 := simd.shuffle(prev, v,
		63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94,
		95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126)
	p2 := simd.shuffle(prev, v,
		62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93,
		94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125)
	p3 := simd.shuffle(prev, v,
		61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92,
		93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124)
	pairs := pshufb_wide(table_wide(UTF8_TBL_A), simd.shr(p1, 4)) &
		pshufb_wide(table_wide(UTF8_TBL_B), simd.bit_and(p1, Block64(0x0f))) &
		pshufb_wide(table_wide(UTF8_TBL_C), simd.shr(v, 4))
	must23 := simd.saturating_sub(p2, Block64(0x60)) | simd.saturating_sub(p3, Block64(0x70))
	return simd.bit_and(must23, Block64(0x80)) ~ pairs
}

// The stop lanes of a block, as bits.
@(private = "file", enable_target_feature = WIDE_FEATURES)
stops_wide :: #force_inline proc "contextless" (v: Block64, $check: Check_Level) -> u64 {
	st := simd.lanes_eq(v, Block64('"')) | simd.lanes_eq(v, Block64('\\'))
	when check == .Values {
		st |= simd.lanes_lt(v, Block64(0x20))
	}
	return bits_wide(st)
}

// `span_advance`'s vector body, 64 bytes per step from `pos`, a character boundary with 64 bytes of `src`
// left. It lands on the first stop byte once every lane up to and including it is valid UTF-8 (the stop lane
// for the reason `prefix_keep` gives), and answers its offset. Otherwise it leaves the span unfinished and
// answers the complement (`~`, so negative) of a character boundary for `span_advance`'s narrow loops to go
// on from: `pos` again on a fault, which they re-derive, or the boundary at or just short of the last 64
// bytes. One signed offset comes back in a register, where a pair would go through the caller's stack.
//
// This loop crosses ASCII and loads only the stop constants. The first block with a byte >= 0x80 before its
// stop goes to `span_wide_utf8`, which loads the UTF-8 tables: most spans end in their first block, and
// loading the tables there is the bulk of a short span's cost.
//
// It takes the cursor by value: the walks keep their `Scanner` in registers only while its address stays
// inside them, and a walk whose scanner escapes stores `pos` at every byte.
@(enable_target_feature = WIDE_FEATURES)
span_wide :: proc "contextless" (src: []u8, pos: u64, $check: Check_Level) -> int {
	n := u64(len(src))
	p := pos
	#no_bounds_check for p + 64 <= n {
		v := intrinsics.unaligned_load((^Block64)(&src[p]))
		stop := stops_wide(v, check)
		high := bits_wide(v)
		if stop | high != 0 {
			// `stop ~ (stop - 1)`: the lanes up to and including the first stop, or all of them without one.
			if high & (stop ~ (stop - 1)) == 0 {
				return int(p + intrinsics.count_trailing_zeros(stop))
			}
			return span_wide_utf8(src, p, pos, check)
		}
		p += 64
	}
	return ~int(p)
}

// `span_wide` on from `p`, a character boundary after ASCII blocks, checking UTF-8 on each block that has a
// byte >= 0x80 or follows an unfinished character. A fault answers `~entry`, the span's start.
@(private = "file", enable_target_feature = WIDE_FEATURES)
span_wide_utf8 :: #force_no_inline proc "contextless" (src: []u8, p, entry: u64, $check: Check_Level) -> int {
	n := u64(len(src))
	p := p
	prev: Block64
	// The last lane of the block before, as a bit. A character unfinished there has its last byte there (a lead
	// or a continuation, >= 0x80 either way), and the block after must check it even without a high byte.
	open: u64
	#no_bounds_check for p + 64 <= n {
		v := intrinsics.unaligned_load((^Block64)(&src[p]))
		stop := stops_wide(v, check)
		high := bits_wide(v)
		fault: u64
		if high | open != 0 {
			fault = bits_wide(simd.lanes_ne(utf8_err_wide(prev, v), Block64(0)))
		}
		if stop | fault != 0 {
			if fault & (stop ~ (stop - 1)) == 0 {
				return int(p + intrinsics.count_trailing_zeros(stop))
			}
			return ~int(entry)
		}
		open = high >> 63
		prev = v
		p += 64
	}
	return ~int(char_boundary_at((transmute([4]#simd[16]u8)prev)[3], p))
}
