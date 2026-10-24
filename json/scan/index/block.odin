package index

// Lists the set bits of 64-byte blocks as offsets, using the bit kernels of `core` (bits.odin).

import "base:intrinsics"
import bits "../../../core"

V :: bits.V
load :: bits.load
pack4 :: bits.pack4
pack4x2 :: bits.pack4x2
prefix_xor :: bits.prefix_xor
utf8_block :: bits.utf8_block
block_at :: bits.block_at

// The 16 source bytes before `lo`, zeros before the source.
before16 :: #force_inline proc(src: []u8, lo: int) -> (tmp: [16]u8) {
	if lo >= 16 {
		return (^[16]u8)(raw_data(src[lo - 16:]))^
	}
	copy(tmp[16 - lo:], src[:lo])
	return
}

// Set bits of `m`, offset by `base`, appended at `out[n]`. Steps of
// FLATTEN_STEP writes, the first unconditional, keep the per-block branch
// predictable at both sparse and dense token rates. `out` carries
// FLATTEN_STEP slots of slack.
FLATTEN_STEP :: 12

flatten :: #force_inline proc(out: [^]u16, n: int, m: u64, base: u16) -> int {
	cnt := int(intrinsics.count_ones(m))
	// x86 has trailing-zero counts (bsf/tzcnt) and no bit reverse, so it
	// walks `m` upward instead. Slack slots past the last bit take junk.
	// The stores are volatile only to keep each count a scalar `tzcnt`: in
	// the AVX-512 index (block_wide.odin) LLVM otherwise packs the counts
	// into a vector popcount sequence, which is slower.
	w := out[n:]
	when ODIN_ARCH == .amd64 {
		m := m
		#unroll for k in 0 ..< 2 {
			if k == 0 || cnt > FLATTEN_STEP * k {
				#unroll for i in 0 ..< FLATTEN_STEP {
					intrinsics.volatile_store(&w[FLATTEN_STEP * k + i], base + u16(intrinsics.count_trailing_zeros(m)))
					m &= m - 1
				}
			}
		}
		for i := 2 * FLATTEN_STEP; i < cnt; i += 1 {
			intrinsics.volatile_store(&w[i], base + u16(intrinsics.count_trailing_zeros(m)))
			m &= m - 1
		}
		return n + cnt
	}
	// Reversed once, so each position is a leading zero count: arm64 has no
	// trailing-zero instruction, and counting trailing zeros reverses the
	// bits again for every slot. Once the bits run out the count is 64 and
	// the slot gets junk, which only slack slots take. `& 63` keeps the shift
	// defined without a select, and the tail loop counts slots instead of
	// testing `r`.
	r := intrinsics.reverse_bits(m)
	#unroll for k in 0 ..< 2 {
		if k == 0 || cnt > FLATTEN_STEP * k {
			#unroll for i in 0 ..< FLATTEN_STEP {
				lz := intrinsics.count_leading_zeros(r)
				w[FLATTEN_STEP * k + i] = base + u16(lz)
				r ~= (u64(1) << 63) >> (lz & 63)
			}
		}
	}
	for i := 2 * FLATTEN_STEP; i < cnt; i += 1 {
		lz := intrinsics.count_leading_zeros(r)
		w[i] = base + u16(lz)
		r ~= (u64(1) << 63) >> (lz & 63)
	}
	return n + cnt
}

