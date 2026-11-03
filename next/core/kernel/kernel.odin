// `simd` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
package kernel

import "base:intrinsics"
import "core:simd"

// Format-neutral kernels that work on 64-byte blocks: load a block, load the last partial block padded with zeros,
// compare bytes, sort bytes into sets, pack per-byte masks to one bit per byte, find the bytes an escape escapes,
// find the first set lane of a 16-byte mask, gather the lanes a mask keeps (compress.odin), and validate UTF-8
// (utf8.odin). arm64.odin and lanes64.odin hold the per-architecture operations. Kernels whose instructions differ by
// CPU take a `Tier` as `$T` (amd64.odin,
// single_tier.odin).

// 64 input bytes, or the 64 lane masks (0x00 or 0xFF) made from them, as four 16-byte vectors. lanes64.odin
// reinterprets it as one 64-lane vector. It is an array so that a block crosses a call between procedures built for
// different x86 tiers in the same registers on both sides, since a 64-lane vector returns in one register from an
// AVX-512 procedure and in four from an SSE one.
Block :: [4]#simd[16]u8

// A block's vector registers on NEON and SSE, and the whole block as one vector.
@(private)
V :: #simd[16]u8
@(private)
W :: #simd[64]u8

// The mask a load at `16 - n` gives: `n` lanes of 0xFF, then zeros.
@(private, rodata)
LIVE_LANES := [32]u8{0 ..< 16 = 0xFF, 16 ..< 32 = 0}

// Loads the 16 bytes at `src` in one instruction, with the mask of the first `n` lanes, `n` below 16. It is not `ok` when
// the load could cross a 4096-byte page boundary from `src`'s first byte, for a nil `src`, and under the address
// sanitizer. The lanes past `n` hold whatever follows `src` in its page.
head16 :: #force_inline proc "contextless" (src: [^]u8, n: int) -> (v, live: V, ok: bool) #no_bounds_check {
	when .Address in ODIN_SANITIZER_FLAGS {
		return
	} else {
		if (uintptr(src) - 1) & 4095 >= 4080 {
			return
		}
		return intrinsics.unaligned_load((^V)(src)), intrinsics.unaligned_load((^V)(&LIVE_LANES[16 - n])), true
	}
}

// Returns the bytes of `src` from `lo` to `len(src)` copied into a zeroed 64-byte buffer and loaded as a `Block`.
// `load_padded` uses it where no masked load exists.
@(private)
copied_tail :: #force_inline proc "contextless" (src: []u8, lo: int) -> Block {
	buf: [64]u8
	intrinsics.mem_copy_non_overlapping(&buf, raw_data(src[lo:]), len(src) - lo)
	return load(raw_data(buf[:]))
}

// Two 16-byte tables that sort bytes into up to 8 sets. Byte `b` is in set k when `lo[b & 15] & hi[b >> 4]` shares a
// bit with `bits[k]`, as `nibble_table` returns them. Each pair of a set and a high nibble owns one bit, so
// membership is exact while the sets have at most 8 such pairs between them.
Nibble_Table :: struct {
	lo, hi: #simd[16]u8,
}

nibble_table :: proc(sets: []string) -> (t: Nibble_Table, bits: [8]u8) {
	assert(len(sets) <= 8, "more than eight sets")
	lo, hi: [16]u8
	next: uint
	for set, k in sets {
		pair: [16]u8
		for c in transmute([]u8)set {
			h := c >> 4
			if pair[h] == 0 {
				assert(next < 8, "more than eight pairs of a set and a high nibble")
				pair[h] = 1 << next
				next += 1
			}
			hi[h] |= pair[h]
			lo[c & 15] |= pair[h]
			bits[k] |= pair[h]
		}
	}
	return {transmute(#simd[16]u8)lo, transmute(#simd[16]u8)hi}, bits
}

// Returns, for each byte of `b`, the class bits its two nibbles give from `t`. Looks up both nibbles one vector
// register at a time.
classes :: #force_inline proc "contextless" ($T: Tier, b: Block, t: Nibble_Table) -> Block #no_bounds_check {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	w := transmute([64 / N]U)b
	c: [64 / N]U
	#unroll for i in 0 ..< 64 / N {
		c[i] = simd.bit_and(lookup(T, t.lo, simd.bit_and(w[i], U(0x0f))), lookup(T, t.hi, simd.shr(w[i], U(4))))
	}
	return transmute(Block)c
}

// Returns a mask of the bytes after an odd run of escape bytes. Adding a run's first bit to the escapes clears the
// run and sets the bit after it, an odd distance from the first bit when the run is odd: an odd bit after a run
// starting on an even bit, an even bit after a run starting on an odd bit. A run reaching the end of the block is odd
// only when it starts on an odd bit, so the carry out of that add becomes the next block's `odd`. When `*odd` is
// set, bit 0 continues the previous run, counts as an odd start and is treated as escaped if it is not an escape. On
// return `*odd` says whether this block ends in a run of odd length.
escaped :: #force_inline proc "contextless" (escape: u64, odd: ^u64) -> u64 {
	EVEN :: u64(0x5555_5555_5555_5555)
	starts := escape &~ (escape << 1)
	even_starts_mask := EVEN ~ odd^
	even_carries := escape + (starts & even_starts_mask)
	odd_carries, overflow := intrinsics.overflow_add(escape, starts &~ even_starts_mask)
	odd_carries |= odd^
	odd^ = u64(overflow)
	return (even_carries &~ escape & ~EVEN) | (odd_carries &~ escape & EVEN)
}

// Returns the index of the first byte `c` in `src`, or -1. Reads 64 bytes at a time with the CPU's tier.
index_byte :: #force_inline proc "contextless" (src: []u8, c: u8) -> int {
	return scan(src, c, nil, .Forward)
}

// Returns the index of the last byte `c` in `src`, or -1. Reads 64 bytes at a time back from the end.
last_index_byte :: #force_inline proc "contextless" (src: []u8, c: u8) -> int {
	return scan(src, c, nil, .Back)
}

// A scan of quoted runs and brackets, and where it stands at a byte. A quoted run goes from a `quote` byte to the next
// one no `escape` byte escapes, 0 for no escape. With `nest`, `[` and `{` outside quoted runs open a level and `]` and
// `}` close one. At a byte, `odd` says an odd run of escapes ends just before it, `quoted` that it is in a quoted run,
// and `depth[0]` is its level, far below `want` once the level fell below `want` before it.
//
// After `quote_run` over a stretch from `odd`, index 0 is for a start outside a quoted run and 1 for a start inside
// one: `depth` holds the change in level and `low` the lowest level from 0. `quoted` says the stretch ends in a quoted
// run from a start outside one, and so ends outside from a start inside one.
Quotes :: struct {
	quote, escape, sep: u8,
	nest, quoted:       bool,
	odd:                u64,
	want:               int,
	depth, low:         [2]int,
}

// Reads `src` as a stretch of text into `s`, which holds only `quote`, `escape`, `nest` and `odd`.
quote_run :: proc "contextless" (src: []u8, s: ^Quotes) {
	scan(src, 0, s, .Run)
}

// Returns the index of the first `sep` of `src` outside quoted runs at level `want`, from where `s` stands at
// `src[0]`, or -1 when there is none or the level falls below `want` first.
quote_cut :: proc "contextless" (src: []u8, s: Quotes) -> int {
	s := s
	if s.quote == 0 {
		return scan(src, s.sep, nil, .Forward)
	}
	return scan(src, s.sep, &s, .Cut)
}

@(private)
Scan_Op :: enum u8 {
	Forward,
	Back,
	Run,
	Cut,
}

// The loops `scan` builds once per tier: `index_byte` and `last_index_byte` for `c`, then `quote_run` and `quote_cut`.
// The zeros of a padded last block are no quote, escape, separator or bracket.
@(private)
scan_op :: #force_inline proc "contextless" ($T: Tier, src: []u8, c: u8, s: ^Quotes, $OP: Scan_Op) -> int #no_bounds_check {
	when OP <= .Back {
		return scan_loop(src, c, OP == .Back)
	} else {
		inq := ~u64(0) if s.quoted else 0
		for lo := 0; lo < len(src); lo += 64 {
			b := load(raw_data(src)[lo:]) if len(src) - lo >= 64 else load_padded(T, src, lo)
			q := pack(eq(b, s.quote))
			if s.escape != 0 {
				e := escaped(pack(eq(b, s.escape)), &s.odd)
				// A run that ends before a padded block's end escapes the first pad byte.
				if n := len(src) - lo; n < 64 {
					s.odd = e >> uint(n) & 1
				}
				q &~= e
			}
			inside := prefix_xor(T, q) ~ inq
			inq = u64(i64(inside) >> 63)
			m := pack_n([3]Block{eq(b, s.sep), either(eq(b, '['), eq(b, '{')), either(eq(b, ']'), eq(b, '}'))})
			when OP == .Run {
				if s.nest {
					#unroll for g in 0 ..< 2 {
						out := inside if g == 1 else ~inside
						s.low[g] = depth_low(s.low[g], s.depth[g], m[1] & out, m[2] & out)
						s.depth[g] += int(intrinsics.count_ones(m[1] & out)) - int(intrinsics.count_ones(m[2] & out))
					}
				}
			} else {
				sep, open, close := m[0] &~ inside, m[1] &~ inside, m[2] &~ inside
				if !s.nest {
					if sep != 0 {
						return lo + int(intrinsics.count_trailing_zeros(sep))
					}
					continue
				}
				for r := sep | close; r != 0; r &= r - 1 {
					before := (r & -r) - 1
					d := s.depth[0] + int(intrinsics.count_ones(open & before)) - int(intrinsics.count_ones(close & before))
					if close & r & -r != 0 && d <= s.want {
						return -1
					}
					if sep & r & -r != 0 && d == s.want {
						return lo + int(intrinsics.count_trailing_zeros(r))
					}
				}
				s.depth[0] += int(intrinsics.count_ones(open)) - int(intrinsics.count_ones(close))
			}
		}
		s.quoted = inq != 0
		return -1
	}
}

// Returns the lower of `low` and the lowest level the closes of a block bring `depth` to, counting the opens before
// each close.
@(private)
depth_low :: #force_inline proc "contextless" (low, depth: int, open, close: u64) -> int {
	low := low
	if depth - int(intrinsics.count_ones(close)) >= low {
		return low
	}
	for m := close; m != 0; m &= m - 1 {
		through := (m & -m) << 1 - 1
		low = min(low, depth + int(intrinsics.count_ones(open & through)) - int(intrinsics.count_ones(close & through)))
	}
	return low
}

// The loop of `index_byte` and `last_index_byte`.
@(private)
scan_loop :: #force_inline proc "contextless" (src: []u8, c: u8, $BACK: bool) -> int #no_bounds_check {
	p := raw_data(src)
	i := len(src)
	when BACK {
		for i >= 64 {
			i -= 64
			if m := pack(eq(load(p[i:]), c)); m != 0 {
				return i + 63 - int(intrinsics.count_leading_zeros(m))
			}
		}
		for i > 0 {
			i -= 1
			if p[i] == c {
				return i
			}
		}
	} else {
		n := i
		for i = 0; i + 64 <= n; i += 64 {
			if m := pack(eq(load(p[i:]), c)); m != 0 {
				return i + int(intrinsics.count_trailing_zeros(m))
			}
		}
		for ; i < n; i += 1 {
			if p[i] == c {
				return i
			}
		}
	}
	return -1
}
