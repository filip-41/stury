package bits

// Format-neutral bit operations on 64-byte blocks: loads, lane masks packed to u64, the prefix XOR that turns
// quote bits into quoted regions, and RFC 3629 checks of 16-byte windows. No code here depends on a format's
// byte meanings.

import "base:intrinsics"
import "core:simd"

V :: #simd[16]u8

load :: #force_inline proc(p: [^]u8) -> V {
	return intrinsics.unaligned_load((^V)(p))
}

// Returns the 64 bytes of `src` from `lo`. Near the end, the rest of `src` is copied into `tail` and zero-padded,
// so no load reads past `src`. `valid` has one bit per byte of `src` in the block. `lo` is at most `len(src)`.
block_at :: #force_inline proc(src: []byte, lo: int, tail: ^[64]u8) -> (p: [^]u8, valid: u64) #no_bounds_check {
	if rem := len(src) - lo; rem < 64 {
		tail^ = {}
		copy(tail[:], src[lo:])
		return raw_data(tail[:]), u64(1) << u64(rem) - 1
	}
	return raw_data(src[lo:]), ~u64(0)
}

// Returns the lane masks of the bytes of `v` equal to `c`.
eq4 :: #force_inline proc(v: [4]V, c: byte) -> [4]V {
	b := V(c)
	return {simd.lanes_eq(v[0], b), simd.lanes_eq(v[1], b), simd.lanes_eq(v[2], b), simd.lanes_eq(v[3], b)}
}

// Reports whether any of the 16 bytes of `v` is `c`.
any_eq :: #force_inline proc(v: V, c: byte) -> bool {
	return any_lane(simd.lanes_eq(v, V(c)))
}

// Reports whether any of the 64 bytes of `v` is `c`.
any_eq4 :: #force_inline proc(v: [4]V, c: byte) -> bool {
	b := V(c)
	return any_lane(simd.lanes_eq(v[0], b) | simd.lanes_eq(v[1], b) | simd.lanes_eq(v[2], b) | simd.lanes_eq(v[3], b))
}

// Packs 64 lane masks (0x00/0xFF) into one u64, using NEON's pairwise-add reduction.
pack4 :: #force_inline proc(a, b, c, d: V) -> u64 {
	// x86 has a single mask-to-bits instruction, pmovmskb, which takes each lane's top bit.
	when ODIN_ARCH == .amd64 {
		return movemask(a) | movemask(b) << 16 | movemask(c) << 32 | movemask(d) << 48
	}
	w := V{1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128}
	s0 := padd(simd.bit_and(a, w), simd.bit_and(b, w))
	s1 := padd(simd.bit_and(c, w), simd.bit_and(d, w))
	s0 = padd(s0, s1)
	s0 = padd(s0, s0)
	return (transmute([2]u64)s0)[0]
}

// Computes two `pack4`s at once. On NEON the last pairwise add combines both halves, one per mask, which saves
// one add over two calls.
pack4x2 :: #force_inline proc(a, b: [4]V) -> (u64, u64) {
	when ODIN_ARCH == .amd64 {
		return pack4(a[0], a[1], a[2], a[3]), pack4(b[0], b[1], b[2], b[3])
	}
	w := V{1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128}
	sa := padd(padd(simd.bit_and(a[0], w), simd.bit_and(a[1], w)), padd(simd.bit_and(a[2], w), simd.bit_and(a[3], w)))
	sb := padd(padd(simd.bit_and(b[0], w), simd.bit_and(b[1], w)), padd(simd.bit_and(b[2], w), simd.bit_and(b[3], w)))
	both := transmute([2]u64)padd(sa, sb)
	return both[0], both[1]
}

// Pairwise add. LLVM lowers the portable form to uzp1+uzp2+add rather than
// NEON's single `addp`, so arm64 names the instruction.
@(private = "file")
padd :: #force_inline proc(a, b: V) -> V {
	when ODIN_ARCH == .arm64 {
		return neon_addp(a, b)
	} else {
		ev := simd.shuffle(a, b, 0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30)
		od := simd.shuffle(a, b, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31)
		return ev + od
	}
}

when ODIN_ARCH == .arm64 {
	@(private, default_calling_convention = "none")
	foreign _ {
		@(link_name = "llvm.aarch64.neon.addp.v16i8")
		neon_addp :: proc(a, b: V) -> V ---
	}
}

when ODIN_ARCH == .amd64 {
	@(private, default_calling_convention = "none")
	foreign _ {
		@(link_name = "llvm.x86.sse2.pmovmskb.128")
		pmovmskb :: proc(a: V) -> i32 ---
	}

	@(private = "file")
	movemask :: #force_inline proc(a: V) -> u64 {
		return u64(u32(pmovmskb(a)))
	}
}

prefix_xor :: #force_inline proc(x: u64) -> u64 {
	x := x
	x ~= x << 1
	x ~= x << 2
	x ~= x << 4
	x ~= x << 8
	x ~= x << 16
	x ~= x << 32
	return x
}

// Reports whether any lane is non-zero. On NEON, `reduce_or` lowers to an OR tree through scalar registers (nine
// instructions on the branch's path), while `reduce_max` is one `umaxv`. On x86 the OR is one `ptest`, while the
// maximum takes seven instructions through `phminposuw`.
any_lane :: #force_inline proc "contextless" (v: V) -> bool {
	when ODIN_ARCH == .amd64 {
		return simd.reduce_or(v) != 0
	}
	return simd.reduce_max(v) != 0
}

// Reports whether any lane is 0x80 or above. NEON uses `umaxv`. x86 uses the lanes' top bits (`pmovmskb`),
// because its maximum is a shuffle tree.
any_high :: #force_inline proc "contextless" (v: V) -> bool {
	when ODIN_ARCH == .amd64 {
		return simd.extract_msbs(v) != {}
	}
	return simd.reduce_max(v) >= 0x80
}
