#+build amd64
package scan

import "base:intrinsics"
import "core:simd"
import index "index"
import lex "lex"

// A run of members nothing reads, checked 64 bytes at a time on a processor with AVX-512BW: `descend_struct`'s
// unread-member loop spends its cycles on one key, colon and number per member, each found by the last one's
// end. Here a block's masks find every member in it at once. It takes only the compact member the walk's
// lexers would take whole, `"key":digits,`, with a key of printable ASCII and no escape, a number of one to
// fifteen digits that starts with one to nine, and no byte between tokens, and no member whose key begins with
// a byte a field name does (`Shape_Op.first`), which the caller's loop matches. Anything else, a byte >= 0x80
// or a backslash anywhere in a block included, ends the run before the member it spoils, so a result is the
// loop's own on the same bytes: the position after the comma of the last member passed, the start of the next.
//
// Loads stay inside `src`: a block is read only with 64 bytes left.

// The digits a number passed whole may have, which is as many as `plain_int_end` takes, and the bytes of unread
// members the loop takes before it tries a run, and before it tries again after a run that passed none.
UNREAD_RUN_DIGITS :: 15
UNREAD_RUN_AFTER :: 512
UNREAD_RUN_RETRY :: 4096

// Whether the running processor has what `unread_run_wide` needs: the index's AVX-512 route.
unread_run_ok :: #force_inline proc "contextless" () -> bool {
	return index.wide_ok()
}

// The members from the key at `pos` that `unread_run_wide` passes whole, and the position after the last one's
// comma. It is `pos` itself when the first is not one. `first` is `Shape_Op.first`.
//
// The bytes of `first` become the nibble tables of a bucket match, looked up by `pshufb`: the k-th of them goes in
// bucket k mod 8, whose bit its low nibble's entry of `lo` and its high nibble's entry of `hi` both carry. A byte
// can start a field name only when `lo[b & 15] & hi[b >> 4] != 0`. Up to eight first bytes keep a bucket each,
// so the match is exact. More share buckets, and it can pass a byte no field starts with, never refuse one that
// does. A run is tried seldom, so the tables are built here, not kept.
@(enable_target_feature = index.WIDE_FEATURES)
unread_run_wide :: proc "contextless" (src: []u8, pos: u64, first: [4]u64) -> u64 {
	Block64 :: lex.Block64
	lo, hi: [16]u8
	k := uint(0)
	for word, w in first {
		for bs := word; bs != 0; bs &= bs - 1 {
			b := u64(w) * 64 + u64(intrinsics.count_trailing_zeros(bs))
			lo[b & 15] |= u8(1) << (k & 7)
			hi[b >> 4] |= u8(1) << (k & 7)
			k += 1
		}
	}
	lo_table := lex.table_wide(transmute(#simd[16]u8)lo)
	hi_table := lex.table_wide(transmute(#simd[16]u8)hi)
	bits :: lex.bits_wide
	n := u64(len(src))
	p := pos
	end := pos
	// What the block before leaves for the shifted tests of the next: a bit's neighbour in the byte before it.
	// The run starts as a key's opening quote follows a comma.
	closing_before, colon_before, comma_before, opening_before: u64 = 0, 0, 1, 0
	in_key: u64
	digits_1, digits_2, digits_4, digits_8, digits_16: u64
	#no_bounds_check for p + 64 <= n {
		v := intrinsics.unaligned_load((^Block64)(&src[p]))
		quote := bits(simd.lanes_eq(v, Block64('"')))
		// Not a member's key: a backslash, a control byte (whitespace included) or a byte >= 0x80.
		spoiled := bits(simd.lanes_eq(v, Block64('\\'))) | bits(simd.lanes_lt(v, Block64(0x20))) | bits(v)
		// A key's bytes, from its opening quote to the byte before its closing one.
		key := index.clmul_prefix_xor(quote) ~ in_key
		in_key = u64(i64(key) >> 63)
		opening, closing := quote & key, quote & ~key
		colon := bits(simd.lanes_eq(v, Block64(':'))) & ~key
		comma := bits(simd.lanes_eq(v, Block64(','))) & ~key
		digit := bits(simd.lanes_le(v - Block64('0'), Block64(9))) & ~key
		zero := bits(simd.lanes_eq(v, Block64('0')))
		// The byte before each, a block's first byte's from the block before.
		digit_before := digit << 1 | digits_1 >> 63
		starts, after := digit & ~digit_before, digit_before & ~digit
		// Sixteen digits in a row, doubled from one: a run's length is held to the fifteen `plain_int_end` takes.
		d2 := digit & digit_before
		d4 := d2 & (d2 << 2 | digits_2 >> 62)
		d8 := d4 & (d4 << 4 | digits_4 >> 60)
		d16 := d8 & (d8 << 8 | digits_8 >> 56)
		long := d16 << 1 | digits_16 >> 63
		digits_1, digits_2, digits_4, digits_8, digits_16 = digit, d2, d4, d8, d16
		// A byte that might begin a field's name, after an opening quote.
		maybe_field := bits(simd.lanes_ne(
			lex.pshufb_wide(lo_table, simd.bit_and(v, Block64(0x0f))) & lex.pshufb_wide(hi_table, simd.shr(v, 4)),
			Block64(0),
		))
		// Where the bytes stop being members: an outside byte that is no colon, comma or digit, a colon not after a
		// closing quote or a closing quote without one, a number not after a colon or not starting 1-9, a comma not
		// after a number or a number not before a comma, an opening quote not after a comma, a field's name.
		bad := spoiled | (~key & ~(colon | comma | digit | closing)) | starts & zero | maybe_field & (opening << 1 | opening_before) | long
		bad |= colon ~ (closing << 1 | closing_before)
		bad |= starts ~ (colon << 1 | colon_before)
		bad |= comma ~ after
		bad |= opening ~ (comma << 1 | comma_before)
		closing_before, colon_before, comma_before, opening_before = closing >> 63, colon >> 63, comma >> 63, opening >> 63
		// The commas before the first such byte end whole members.
		ended := comma
		if bad != 0 {
			ended &= (bad ~ (bad - 1)) >> 1
		}
		if ended != 0 {
			end = p + 64 - u64(intrinsics.count_leading_zeros(ended))
		}
		if bad != 0 {
			break
		}
		p += 64
	}
	return end
}
