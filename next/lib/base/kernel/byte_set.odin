package kernel

import "base:intrinsics"
import "core:simd"

// A set of bytes, tested a register at a time. A byte is in the set when its low nibble's bit is set in the row of its
// high nibble: `low[h]` holds the bits of low nibbles 0 to 7 of the members whose high nibble is `h`, and `high[h]`
// those of 8 to 15. Any set of bytes has that form, at three table lookups a register. A set whose 16 rows hold at most
// 8 distinct sets of low nibbles has the bucket form too, at two lookups: each distinct row is a bucket, `hi_tbl[h]`
// holds the bit of the bucket of the rows of high nibble `h`, and `lo_tbl[l]` the bits of the buckets that hold low
// nibble `l`. It is the `Nibble_Table` of the classes, exact only within that limit, so any other set keeps the
// general form.
Byte_Set :: struct {
	low, high:      V,
	lo_tbl, hi_tbl: V, // the bucket form, when `buckets`
	buckets:        bool,
}

// The set of the bytes whose bit is set in `members`: bit `b % 64` of word `b / 64` stands for byte `b`.
byte_set :: proc "contextless" (members: [4]u64) -> (t: Byte_Set) {
	low, high: [16]u8
	for h in 0 ..< 16 {
		row := members[h / 4] >> uint(h % 4 * 16)
		low[h], high[h] = u8(row), u8(row >> 8)
	}
	t = {low = transmute(V)low, high = transmute(V)high}
	rows: [8]u16
	n := 0
	lo, hi: [16]u8
	for h in 0 ..< 16 {
		row := u16(low[h]) | u16(high[h]) << 8
		if row == 0 {
			continue
		}
		k := 0
		for k < n && rows[k] != row {
			k += 1
		}
		if k == n {
			if n == 8 {
				return
			}
			rows[n] = row
			n += 1
		}
		hi[h] = 1 << uint(k)
	}
	for k in 0 ..< n {
		for l in 0 ..< 16 {
			if rows[k] >> uint(l) & 1 != 0 {
				lo[l] |= 1 << uint(k)
			}
		}
	}
	t.lo_tbl, t.hi_tbl, t.buckets = transmute(V)lo, transmute(V)hi, true
	return
}

// The index of the first byte of `src` that is in `t`, or -1.
index_set :: #force_inline proc "contextless" (src: []u8, t: Byte_Set) -> int {
	return find_set(src, t)
}

// Bit k of lane j is set for k = j mod 8: the bit a low nibble stands for within its half row.
@(private, rodata)
NIBBLE_BITS := [16]u8{1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128}

// Nonzero in each lane of `w` that is in `t`.
@(private)
in_set_reg :: #force_inline proc "contextless" (
	$T: Tier,
	w: #simd[VECTOR_BYTES[T]]u8,
	t: Byte_Set,
	$BUCKETS: bool,
) -> #simd[VECTOR_BYTES[T]]u8 {
	U :: #simd[VECTOR_BYTES[T]]u8
	when BUCKETS {
		return simd.bit_and(lookup(T, t.lo_tbl, simd.bit_and(w, U(0x0f))), lookup(T, t.hi_tbl, simd.shr(w, U(4))))
	} else {
		low := simd.bit_and(w, U(0x0f))
		high := simd.shr(w, U(4))
		first_half := simd.lanes_lt(low, U(8))
		from_low := simd.bit_and(lookup(T, t.low, high), first_half)
		row := simd.bit_or(from_low, simd.bit_and_not(lookup(T, t.high, high), first_half))
		return simd.bit_and(row, lookup(T, load16(raw_data(NIBBLE_BITS[:])), low))
	}
}

// Nonzero in each lane of `b` that is in `t`, looked up one register of the tier at a time.
@(private)
in_set :: #force_inline proc "contextless" (
	$T: Tier,
	b: Block,
	t: Byte_Set,
	$BUCKETS: bool,
) -> [64 / VECTOR_BYTES[T]]#simd[VECTOR_BYTES[T]]u8 {
	N :: VECTOR_BYTES[T]
	w := transmute([64 / N]#simd[N]u8)b
	m: [64 / N]#simd[N]u8
	#unroll for i in 0 ..< 64 / N {
		m[i] = in_set_reg(T, w[i], t, BUCKETS)
	}
	return m
}

// The first index of `src` whose byte is in `t`, or -1. The bucket form is chosen once, outside the loop.
@(private)
set_loop :: #force_inline proc "contextless" ($T: Tier, src: []u8, t: Byte_Set) -> int {
	if t.buckets {
		return set_blocks(T, src, t, true)
	}
	return set_blocks(T, src, t, false)
}

// Whole blocks of 64 bytes, then a short tail in one register or a padded block whose zero bytes are not counted.
@(private)
set_blocks :: #force_inline proc "contextless" ($T: Tier, src: []u8, t: Byte_Set, $BUCKETS: bool) -> int {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	full := len(src) - len(src) % 64
	for lo := 0; lo < full; lo += 64 {
		m := in_set(T, transmute(Block)load(raw_data(src)[lo:]), t, BUCKETS)
		acc: U
		#unroll for i in 0 ..< 64 / N {
			acc = simd.bit_or(acc, m[i])
		}
		if !all_zero(acc) {
			return lo + first_member(T, m)
		}
	}
	if left := len(src) - full; 0 < left && left < 16 {
		// A short tail is one register, not a block of four.
		if v, live, ok := head16(raw_data(src)[full:], left); ok {
			hit := simd.bit_and(simd.lanes_ne(in_set_reg(Tier(0), v, t, BUCKETS), V(0)), live)
			if any_lane16(hit) {
				return full + int(first_lane16(hit))
			}
			return -1
		}
	}
	if full < len(src) {
		m := in_set(T, load_block(T, src, full), t, BUCKETS)
		bits := member_bits(T, m) & (u64(1) << uint(len(src) % 64) - 1) // a padded block's zero bytes may be members
		if bits != 0 {
			return full + int(intrinsics.count_trailing_zeros(bits))
		}
	}
	return -1
}

// A bit for each byte of a block that `in_set` found in the set.
@(private)
member_bits :: #force_inline proc "contextless" (
	$T: Tier,
	m: [64 / VECTOR_BYTES[T]]#simd[VECTOR_BYTES[T]]u8,
) -> u64 {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	r: [64 / N]U
	#unroll for i in 0 ..< 64 / N {
		r[i] = simd.lanes_ne(m[i], U(0))
	}
	return pack(transmute(Block)r)
}

@(private)
first_member :: #force_inline proc "contextless" (
	$T: Tier,
	m: [64 / VECTOR_BYTES[T]]#simd[VECTOR_BYTES[T]]u8,
) -> int {
	return int(intrinsics.count_trailing_zeros(member_bits(T, m)))
}
