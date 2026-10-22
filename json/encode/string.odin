package encode

// The string writer: validates UTF-8 and escapes in one pass, 16 bytes at a time. A block with nothing to
// escape is stored whole and never touches the byte table. UTF-8 is checked only around blocks with a high
// bit set, chained through the previous block, and the result is read once at the end. `$wide`, which
// `spell_mixed` sets when 64 bytes remain, adds a 64-byte step.
//
// Stores are unchecked and whole, a block as 16 bytes and an escape as one 8-byte ESC_SEQ word, so every
// reservation covers BLOCK_SLACK past the closing quote (a short plain string reserves a whole block), and
// `escape_room` adds BLOCK_WORST before each escaped block. Loads stay inside `s`: 16 bytes only while 16
// remain, and `tail_block` builds the last, shorter block from loads inside `s`, padded with `a`, whose
// escaped form is one byte a lane and is taken back.

import "base:intrinsics"
import "core:simd"
import c "../../core"
import lex "../scan/lex"

// What each byte is written as inside a string, low byte first: itself, `\` and a letter, or `\u00XX`. One
// 8-byte store writes any of them; the top byte says how many of the low bytes count, so the length comes
// with the load and the store's own junk byte lands in the slack.
@(rodata)
ESC_SEQ: [256]u64 = {
	0x060030303030755c, 0x060031303030755c, 0x060032303030755c, 0x060033303030755c,
	0x060034303030755c, 0x060035303030755c, 0x060036303030755c, 0x060037303030755c,
	0x020000000000625c, 0x020000000000745c, 0x0200000000006e5c, 0x060062303030755c,
	0x020000000000665c, 0x020000000000725c, 0x060065303030755c, 0x060066303030755c,
	0x060030313030755c, 0x060031313030755c, 0x060032313030755c, 0x060033313030755c,
	0x060034313030755c, 0x060035313030755c, 0x060036313030755c, 0x060037313030755c,
	0x060038313030755c, 0x060039313030755c, 0x060061313030755c, 0x060062313030755c,
	0x060063313030755c, 0x060064313030755c, 0x060065313030755c, 0x060066313030755c,
	0x0100000000000020, 0x0100000000000021, 0x020000000000225c, 0x0100000000000023,
	0x0100000000000024, 0x0100000000000025, 0x0100000000000026, 0x0100000000000027,
	0x0100000000000028, 0x0100000000000029, 0x010000000000002a, 0x010000000000002b,
	0x010000000000002c, 0x010000000000002d, 0x010000000000002e, 0x010000000000002f,
	0x0100000000000030, 0x0100000000000031, 0x0100000000000032, 0x0100000000000033,
	0x0100000000000034, 0x0100000000000035, 0x0100000000000036, 0x0100000000000037,
	0x0100000000000038, 0x0100000000000039, 0x010000000000003a, 0x010000000000003b,
	0x010000000000003c, 0x010000000000003d, 0x010000000000003e, 0x010000000000003f,
	0x0100000000000040, 0x0100000000000041, 0x0100000000000042, 0x0100000000000043,
	0x0100000000000044, 0x0100000000000045, 0x0100000000000046, 0x0100000000000047,
	0x0100000000000048, 0x0100000000000049, 0x010000000000004a, 0x010000000000004b,
	0x010000000000004c, 0x010000000000004d, 0x010000000000004e, 0x010000000000004f,
	0x0100000000000050, 0x0100000000000051, 0x0100000000000052, 0x0100000000000053,
	0x0100000000000054, 0x0100000000000055, 0x0100000000000056, 0x0100000000000057,
	0x0100000000000058, 0x0100000000000059, 0x010000000000005a, 0x010000000000005b,
	0x0200000000005c5c, 0x010000000000005d, 0x010000000000005e, 0x010000000000005f,
	0x0100000000000060, 0x0100000000000061, 0x0100000000000062, 0x0100000000000063,
	0x0100000000000064, 0x0100000000000065, 0x0100000000000066, 0x0100000000000067,
	0x0100000000000068, 0x0100000000000069, 0x010000000000006a, 0x010000000000006b,
	0x010000000000006c, 0x010000000000006d, 0x010000000000006e, 0x010000000000006f,
	0x0100000000000070, 0x0100000000000071, 0x0100000000000072, 0x0100000000000073,
	0x0100000000000074, 0x0100000000000075, 0x0100000000000076, 0x0100000000000077,
	0x0100000000000078, 0x0100000000000079, 0x010000000000007a, 0x010000000000007b,
	0x010000000000007c, 0x010000000000007d, 0x010000000000007e, 0x010000000000007f,
	0x0100000000000080, 0x0100000000000081, 0x0100000000000082, 0x0100000000000083,
	0x0100000000000084, 0x0100000000000085, 0x0100000000000086, 0x0100000000000087,
	0x0100000000000088, 0x0100000000000089, 0x010000000000008a, 0x010000000000008b,
	0x010000000000008c, 0x010000000000008d, 0x010000000000008e, 0x010000000000008f,
	0x0100000000000090, 0x0100000000000091, 0x0100000000000092, 0x0100000000000093,
	0x0100000000000094, 0x0100000000000095, 0x0100000000000096, 0x0100000000000097,
	0x0100000000000098, 0x0100000000000099, 0x010000000000009a, 0x010000000000009b,
	0x010000000000009c, 0x010000000000009d, 0x010000000000009e, 0x010000000000009f,
	0x01000000000000a0, 0x01000000000000a1, 0x01000000000000a2, 0x01000000000000a3,
	0x01000000000000a4, 0x01000000000000a5, 0x01000000000000a6, 0x01000000000000a7,
	0x01000000000000a8, 0x01000000000000a9, 0x01000000000000aa, 0x01000000000000ab,
	0x01000000000000ac, 0x01000000000000ad, 0x01000000000000ae, 0x01000000000000af,
	0x01000000000000b0, 0x01000000000000b1, 0x01000000000000b2, 0x01000000000000b3,
	0x01000000000000b4, 0x01000000000000b5, 0x01000000000000b6, 0x01000000000000b7,
	0x01000000000000b8, 0x01000000000000b9, 0x01000000000000ba, 0x01000000000000bb,
	0x01000000000000bc, 0x01000000000000bd, 0x01000000000000be, 0x01000000000000bf,
	0x01000000000000c0, 0x01000000000000c1, 0x01000000000000c2, 0x01000000000000c3,
	0x01000000000000c4, 0x01000000000000c5, 0x01000000000000c6, 0x01000000000000c7,
	0x01000000000000c8, 0x01000000000000c9, 0x01000000000000ca, 0x01000000000000cb,
	0x01000000000000cc, 0x01000000000000cd, 0x01000000000000ce, 0x01000000000000cf,
	0x01000000000000d0, 0x01000000000000d1, 0x01000000000000d2, 0x01000000000000d3,
	0x01000000000000d4, 0x01000000000000d5, 0x01000000000000d6, 0x01000000000000d7,
	0x01000000000000d8, 0x01000000000000d9, 0x01000000000000da, 0x01000000000000db,
	0x01000000000000dc, 0x01000000000000dd, 0x01000000000000de, 0x01000000000000df,
	0x01000000000000e0, 0x01000000000000e1, 0x01000000000000e2, 0x01000000000000e3,
	0x01000000000000e4, 0x01000000000000e5, 0x01000000000000e6, 0x01000000000000e7,
	0x01000000000000e8, 0x01000000000000e9, 0x01000000000000ea, 0x01000000000000eb,
	0x01000000000000ec, 0x01000000000000ed, 0x01000000000000ee, 0x01000000000000ef,
	0x01000000000000f0, 0x01000000000000f1, 0x01000000000000f2, 0x01000000000000f3,
	0x01000000000000f4, 0x01000000000000f5, 0x01000000000000f6, 0x01000000000000f7,
	0x01000000000000f8, 0x01000000000000f9, 0x01000000000000fa, 0x01000000000000fb,
	0x01000000000000fc, 0x01000000000000fd, 0x01000000000000fe, 0x01000000000000ff,
}

@(private, rodata)
LANE_SPACE: #simd[16]u8 = {0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20}
@(private, rodata)
LANE_SPACE_I8: #simd[16]i8 = {0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20}
@(private, rodata)
LANE_QUOTE: #simd[16]u8 = {0x22,0x22,0x22,0x22,0x22,0x22,0x22,0x22,0x22,0x22,0x22,0x22,0x22,0x22,0x22,0x22}
@(private, rodata)
LANE_BSLASH: #simd[16]u8 = {0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c}
// Tail padding: `a` needs no escape and continues no UTF-8 sequence.
@(private, rodata)
LANE_PAD: #simd[16]u8 = {0x61,0x61,0x61,0x61,0x61,0x61,0x61,0x61,0x61,0x61,0x61,0x61,0x61,0x61,0x61,0x61}

// The most one block writes: sixteen `\u00XX`.
@(private = "file")
BLOCK_WORST :: 16 * 6
// Room past the written end that a whole-block or ESC_SEQ store may write into.
@(private = "file")
BLOCK_SLACK :: 16

// Append `s` as a JSON string, quotes included. `.Bad_Utf8` when `s` is not valid UTF-8. Nothing is then
// committed.
put_string :: proc(dst: ^[dynamic]u8, s: string) -> Encode_Error {
	return put_string_as(dst, s, false)
}

// `put_string` that also escapes DEL, as `\u007f`: the form jq 1.8 prints.
put_string_escaping_del :: proc(dst: ^[dynamic]u8, s: string) -> Encode_Error {
	return put_string_as(dst, s, true)
}

@(private)
put_string_as :: #force_inline proc(dst: ^[dynamic]u8, s: string, $del: bool) -> Encode_Error {
	mark := len(dst^)
	end, err := spell_led_string(dst, mark, nil, 0, s, del)
	c.edge_publish(dst, end if err == .None else mark)
	return err
}

// `lead[:lead_n]` verbatim, then `s` as `put_string` writes it, under one reservation at the write cursor
// `mark` (see `put_room`). Returns the cursor past the closing quote. `lead_n` is 0 or at least 4 (see
// `copy_lead`). The length of `dst` is committed only to grow, so on a refusal the caller truncates to
// `mark`. A short ASCII string with nothing to escape is written in line. `$del` escapes DEL as well, in this
// and each proc below that takes it.
spell_led_string :: #force_inline proc(dst: ^[dynamic]u8, mark: int, lead: [^]u8, lead_n: int, s: string, $del: bool) -> (int, Encode_Error) #no_bounds_check {
	if len(s) < 16 {
		v := tail_block(raw_data(s), 0, len(s))
		if block_is_plain(v, del) {
			out := put_room(dst, mark, lead_n + 16 + 2)
			if out == nil {
				return mark, .Out_Of_Memory
			}
			if lead_n > 0 {
				copy_lead(out, lead, lead_n)
			}
			out[lead_n] = '"'
			intrinsics.unaligned_store((^#simd[16]u8)(&out[lead_n + 1]), v)
			out[lead_n + 1 + len(s)] = '"'
			return mark + lead_n + 2 + len(s), .None
		}
	}
	return spell_any_string(dst, mark, lead, lead_n, s, del)
}

@(private)
spell_any_string :: proc(dst: ^[dynamic]u8, mark: int, lead: [^]u8, lead_n: int, s: string, $del: bool) -> (int, Encode_Error) #no_bounds_check {
	n := len(s)
	// Clean text is written as itself plus two quotes. This path makes no call, so it keeps no frame. A buffer
	// that must grow, a string under 16 bytes (`spell_led_string` has taken the plain ones) and any block
	// that is not plain ASCII go to `spell_mixed`.
	src := raw_data(s)
	if mark + lead_n + n + 2 + BLOCK_SLACK > cap(dst^) || n < 16 || !block_is_plain(intrinsics.unaligned_load((^#simd[16]u8)(src)), del) {
		return spell_mixed(dst, mark, lead, lead_n, s, 0, del)
	}
	out := raw_data(dst^)
	w := mark
	if lead_n > 0 {
		copy_lead(out[w:], lead, lead_n)
		w += lead_n
	}
	out[w] = '"'
	w += 1
	i := 0
	for ; i + 16 <= n; i += 16 {
		v := intrinsics.unaligned_load((^#simd[16]u8)(&src[i]))
		if !block_is_plain(v, del) {
			return spell_mixed(dst, mark, lead, lead_n, s, i, del)
		}
		intrinsics.unaligned_store((^#simd[16]u8)(&out[w]), v)
		w += 16
	}
	v := tail_block(src, i, n)
	if !block_is_plain(v, del) {
		return spell_mixed(dst, mark, lead, lead_n, s, i, del)
	}
	intrinsics.unaligned_store((^#simd[16]u8)(&out[w]), v)
	w += n - i
	out[w] = '"'
	return w + 1, .None
}

// `spell_any_string` from byte `i` of `s`: every block before `i` is plain ASCII, so no UTF-8 sequence is
// open, and the plain prefix may already be written. The lead and the opening quote are written here too.
@(private)
spell_mixed :: #force_no_inline proc(dst: ^[dynamic]u8, mark: int, lead: [^]u8, lead_n: int, s: string, i_in: int, $del: bool) -> (int, Encode_Error) #no_bounds_check {
	// A string with less than a 64-byte step left has no use for the step's bookkeeping. The DEL-escaping
	// speller (the CLI's) takes no step.
	if !del && len(s) - i_in >= 64 {
		return spell_blocks(dst, mark, lead, lead_n, s, i_in, true, del)
	}
	return spell_blocks(dst, mark, lead, lead_n, s, i_in, false, del)
}

// The body of `spell_mixed`; `wide` adds the 64-byte step, for a string with room for one.
@(private)
spell_blocks :: #force_inline proc(dst: ^[dynamic]u8, mark: int, lead: [^]u8, lead_n: int, s: string, i_in: int, $wide, $del: bool) -> (int, Encode_Error) #no_bounds_check {
	n := len(s)
	if put_room(dst, mark, lead_n + n + 2 + BLOCK_SLACK) == nil {
		return mark, .Out_Of_Memory
	}
	out := raw_data(dst^)
	src := raw_data(s)
	w := mark
	if lead_n > 0 {
		copy_lead(out[w:], lead, lead_n)
		w += lead_n
	}
	out[w] = '"'
	w += 1 + i_in
	i := i_in
	prev, bad: #simd[16]u8
	prev_high := false
	when wide {
		// The first offset a 64-byte step may start at: a block that needs an escape, or a step that meets
		// one, holds it off for several blocks.
		try_from := 0
		// Where the last 64-byte step ended, and whether it held a byte of 0xE0 or more. A step that starts
		// elsewhere has blocks taken the single way before it, which are not accounted for.
		step_end, long_prev := 0, false
	}
	for ; i + 16 <= n; i += 16 {
		v := intrinsics.unaligned_load((^#simd[16]u8)(&src[i]))
		when wide {
			if i >= try_from && i + 64 <= n {
				// Four blocks with nothing to escape are stored whole. UTF-8 is checked over them only when one
				// has a high bit or the block before did.
				v0 := v
				v1 := intrinsics.unaligned_load((^#simd[16]u8)(&src[i + 16]))
				v2 := intrinsics.unaligned_load((^#simd[16]u8)(&src[i + 32]))
				v3 := intrinsics.unaligned_load((^#simd[16]u8)(&src[i + 48]))
				if simd.reduce_or(escape_lanes(v0, del) | escape_lanes(v1, del) | escape_lanes(v2, del) | escape_lanes(v3, del)) == 0 {
					top := simd.reduce_max(simd.max(simd.max(v0, v1), simd.max(v2, v3)))
					high := top >= 0x80
					if high || prev_high {
						// Below 0xE0 nothing opens a sequence longer than two bytes, so each byte need only be
						// read against the one before it.
						if top < 0xE0 && i == step_end && !long_prev {
							bad |= lex.utf8_pairs_err(prev, v0) | lex.utf8_pairs_err(v0, v1) | lex.utf8_pairs_err(v1, v2) | lex.utf8_pairs_err(v2, v3)
						} else {
							bad |= lex.utf8_err(prev, v0) | lex.utf8_err(v0, v1) | lex.utf8_err(v1, v2) | lex.utf8_err(v2, v3)
						}
					}
					long_prev = top >= 0xE0
					step_end = i + 64
					intrinsics.unaligned_store((^#simd[16]u8)(&out[w]), v0)
					intrinsics.unaligned_store((^#simd[16]u8)(&out[w + 16]), v1)
					intrinsics.unaligned_store((^#simd[16]u8)(&out[w + 32]), v2)
					intrinsics.unaligned_store((^#simd[16]u8)(&out[w + 48]), v3)
					w += 64
					prev, prev_high = v3, high
					i += 48
					continue
				}
				try_from = i + 64
			}
		}
		// An ASCII block after an ASCII one ends no sequence and needs no escape.
		if !prev_high && block_is_plain(v, del) {
			intrinsics.unaligned_store((^#simd[16]u8)(&out[w]), v)
			w += 16
			prev = v
			continue
		}
		// arm64 keeps its OR reduction. On x86 that is a shuffle tree, and `lex.any_high` one `pmovmskb`.
		when ODIN_ARCH == .amd64 {
			high := lex.any_high(v)
		} else {
			high := simd.reduce_or(v) >= 0x80
		}
		if high || prev_high {
			bad |= lex.utf8_err(prev, v)
		}
		prev, prev_high = v, high
		if !block_needs_escape(v, del) {
			intrinsics.unaligned_store((^#simd[16]u8)(&out[w]), v)
			w += 16
			continue
		}
		when wide {
			try_from = i + 80
		}
		out = escape_room(dst, out, w, n - i)
		if out == nil {
			return mark, .Out_Of_Memory
		}
		w = escape_block(out, w, v, del)
	}
	// The tail runs even when empty: a sequence cut off by the end of `s` then reads as one cut off by the
	// padding, which `utf8_err` refuses.
	live := n - i
	v := tail_block(src, i, n)
	if !prev_high && block_is_plain(v, del) && !lex.any_lane(bad) {
		intrinsics.unaligned_store((^#simd[16]u8)(&out[w]), v)
		w += live
		out[w] = '"'
		return w + 1, .None
	}
	if prev_high || lex.any_high(v) {
		bad |= lex.utf8_err(prev, v)
	}
	if lex.any_lane(bad) {
		return mark, .Bad_Utf8
	}
	if !block_needs_escape(v, del) {
		intrinsics.unaligned_store((^#simd[16]u8)(&out[w]), v)
		w += live
	} else {
		out = escape_room(dst, out, w, live)
		if out == nil {
			return mark, .Out_Of_Memory
		}
		w = escape_block(out, w, v, del) - (16 - live)
	}
	out[w] = '"'
	return w + 1, .None
}

// `src[i:n]`, fewer than 16 bytes, in the low lanes and LANE_PAD above them, loaded without reading
// outside `src[:n]`: a string of 16 bytes or more has its last 16 shifted down, a shorter one is assembled
// in two words from overlapping loads.
@(private)
tail_block :: #force_inline proc "contextless" (src: [^]u8, i, n: int) -> #simd[16]u8 #no_bounds_check {
	live := n - i
	if n >= 16 {
		last := intrinsics.unaligned_load((^#simd[16]u8)(&src[n - 16]))
		lane := simd.iota(#simd[16]u8)
		shifted := simd.runtime_swizzle(last, lane + (#simd[16]u8)(u8(16 - live)))
		return simd.select(simd.lanes_lt(lane, (#simd[16]u8)(u8(live))), shifted, LANE_PAD)
	}
	low, high := PAD_WORD, PAD_WORD
	switch {
	case live > 8:
		low = intrinsics.unaligned_load((^u64)(&src[i]))
		last := intrinsics.unaligned_load((^u64)(&src[n - 8]))
		high = last >> (8 * u64(16 - live)) | PAD_WORD << (8 * u64(live - 8))
	case live == 8:
		low = intrinsics.unaligned_load((^u64)(&src[i]))
	case live >= 4:
		first := u64(intrinsics.unaligned_load((^u32)(&src[i])))
		last := u64(intrinsics.unaligned_load((^u32)(&src[n - 4])))
		low = first | last << (8 * u64(live - 4)) | PAD_WORD << (8 * u64(live))
	case live > 0:
		mid := live / 2
		low = u64(src[i]) | u64(src[i + mid]) << (8 * u64(mid)) | u64(src[n - 1]) << (8 * u64(live - 1)) | PAD_WORD << (8 * u64(live))
	}
	return transmute(#simd[16]u8)[2]u64{low, high}
}

// LANE_PAD as one word.
@(private)
PAD_WORD :: u64(0x6161_6161_6161_6161)

// No lane at or above 0x80, below 0x20, `"` or `\` (or DEL): one signed compare takes both ends.
@(private)
block_is_plain :: #force_inline proc "contextless" (v: #simd[16]u8, $del: bool) -> bool {
	special := simd.lanes_lt(transmute(#simd[16]i8)v, LANE_SPACE_I8) | simd.lanes_eq(v, LANE_QUOTE) | simd.lanes_eq(v, LANE_BSLASH)
	when del {
		special |= simd.lanes_eq(v, (#simd[16]u8)(0x7f))
	}
	return simd.reduce_or(special) == 0
}

// Lanes below 0x20, `"` or `\` (or DEL).
@(private)
block_needs_escape :: #force_inline proc "contextless" (v: #simd[16]u8, $del: bool) -> bool {
	return simd.reduce_or(escape_lanes(v, del)) != 0
}

// The lanes of `v` below 0x20, `"` or `\` (or DEL), each all-ones.
@(private)
escape_lanes :: #force_inline proc "contextless" (v: #simd[16]u8, $del: bool) -> #simd[16]u8 {
	lanes := simd.lanes_lt(v, LANE_SPACE) | simd.lanes_eq(v, LANE_QUOTE) | simd.lanes_eq(v, LANE_BSLASH)
	when del {
		lanes |= simd.lanes_eq(v, (#simd[16]u8)(0x7f))
	}
	return lanes
}

// The buffer's data, with room from `w` for one worst-case block plus `rest` clean bytes, the closing quote
// and the store slack, or nil when the allocator refused. The length is moved to `w` first, so a
// reallocation keeps every byte written so far.
@(private)
escape_room :: proc(dst: ^[dynamic]u8, out: [^]u8, w, rest: int) -> [^]u8 {
	need := BLOCK_WORST + rest + 1 + BLOCK_SLACK
	if w + need <= cap(dst^) {
		return out
	}
	c.edge_publish(dst, w)
	if put_reserve(dst, need) == nil {
		return nil
	}
	return raw_data(dst^)
}

// Write all 16 bytes of `v` at `out[w:]`, one ESC_SEQ store each. Returns the new write offset. Escapes come
// dense when they come at all, so a fixed count of branch-free stores beats skipping a clean prefix.
@(private)
escape_block :: #force_inline proc "contextless" (out: [^]u8, w: int, v: #simd[16]u8, $del: bool) -> int #no_bounds_check {
	blk := transmute([16]u8)v
	at := w
	for k in 0 ..< 16 {
		ch := blk[k]
		seq := ESC_SEQ[ch]
		when del {
			if ch == 0x7f {
				seq = 0x0600_6637_3030_755c // `\u007f`
			}
		}
		intrinsics.unaligned_store((^u64)(&out[at]), seq)
		at += int(seq >> 56)
	}
	return at
}
