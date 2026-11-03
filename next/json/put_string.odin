package json

import "base:intrinsics"
import "core:simd"
import core "../core"
import kernel "../core/kernel"
import write "../core/write"

// The JSON string writer. A string is checked as UTF-8 and written with `"`, `\` and the control bytes escaped as
// RFC 8259 asks, in the shortest spelling, and DEL and every other byte of a valid sequence written raw. It takes one of
// three paths by length. Under 16 bytes `put_short` builds one block from loads that stay inside the string. From 16
// bytes `put_string_mid` copies 16-byte blocks and ends with an overlapping store, while the text holds only plain ASCII.
// Anything else goes to `put_mixed`, which steps 16 bytes at a time with an escape table, and 64 bytes at a time over
// the stretches with no escape. A string with `ascii` or `escape_html` set goes to `put_escaped` instead, which copies
// 16-byte blocks of plain ASCII and steps one byte at a time through the rest.

@(private)
V :: #simd[16]u8

// The source bytes one reservation of `put_mixed` covers. Every byte is written as at most 6, so a reservation of
// `6 * (SEGMENT + 16) + 18` fits `write.ROOM_MAX`.
@(private)
SEGMENT :: 512
#assert(6 * (SEGMENT + 16) + 18 <= write.ROOM_MAX)

// The longest string `put_string_mid` copies under one reservation.
@(private)
MID_MAX :: write.ROOM_MAX - 18

// How the escaped bytes are spelled, as the text and its length in bits 56 to 63. A store of the 8 bytes followed by a
// step of the length writes one byte's spelling.
@(private, rodata)
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

@(private)
SPACE: V = 0x20
@(private)
QUOTE: V = '"'
@(private)
BACKSLASH: V = '\\'
@(private)
HIGH: V = 0x80
@(private)
PAD: V = 0x61
@(private)
PAD_WORD :: u64(0x6161616161616161)

// Returns the lanes of `v` that hold `"`, `\` or a control byte.
@(private)
esc_lanes :: #force_inline proc "contextless" (v: V) -> V {
	return simd.lanes_lt(v, SPACE) | simd.lanes_eq(v, QUOTE) | simd.lanes_eq(v, BACKSLASH)
}

// Whether `v` holds a byte that needs a closer look: an escape or a byte past 0x7F, which as a signed byte is below 0x20.
@(private)
dirty :: #force_inline proc "contextless" (v: V) -> bool {
	return kernel.any_lane16(simd.lanes_lt(transmute(#simd[16]i8)v, (#simd[16]i8)(0x20)) | simd.lanes_eq(v, QUOTE) | simd.lanes_eq(v, BACKSLASH))
}

// Writes `s` as a JSON string at the output's cursor and returns `.Bad_Utf8` when it is not UTF-8. With `ascii` every
// rune past U+007F is written as `\uXXXX`, and with `escape_html` `<`, `>`, `&`, U+2028 and U+2029 are.
put_string :: proc(out: ^write.Out, s: string, opts := core.Write_Options{}) -> core.Typed_Error_Kind {
	switch {
	case opts.ascii && opts.escape_html:
		return put_escaped(out, s, true, true)
	case opts.ascii:
		return put_escaped(out, s, true, false)
	case opts.escape_html:
		return put_escaped(out, s, false, true)
	}
	return put_short(out, write.room(out, 18), s)
}

// Writes `s` as a JSON string. `p` is `write.room(out, 18)`, the 18 free bytes at the cursor, with every byte before
// the cursor written already. The caller moves nothing, `out.cursor` is moved past the string.
@(private)
put_short :: #force_inline proc(out: ^write.Out, p: [^]u8, s: string) -> core.Typed_Error_Kind #no_bounds_check {
	if len(s) < 16 {
		v, live, ok := kernel.head16(raw_data(s), len(s))
		if ok {
			v = simd.select(simd.lanes_ne(live, V(0)), v, PAD)
		} else {
			v = short_block(raw_data(s), len(s))
		}
		if !dirty(v) {
			p[0] = '"'
			intrinsics.unaligned_store((^V)(p[1:]), v)
			p[1 + len(s)] = '"'
			out.cursor += len(s) + 2
			return .None
		}
	}
	return put_string_mid(out, s)
}

// Writes a string of 16 bytes or more while it holds only plain ASCII, 16 bytes at a time under one reservation, then
// leaves the rest to `put_mixed`. A string past `MID_MAX` bytes cannot be reserved at once, so it goes there whole.
@(private)
put_string_mid :: proc(out: ^write.Out, s: string) -> core.Typed_Error_Kind #no_bounds_check {
	n := len(s)
	if n < 16 || n > MID_MAX {
		return put_mixed(out, s, 0)
	}
	src := raw_data(s)
	p := write.room(out, n + 18)
	i := 0
	for ; i + 16 < n; i += 16 {
		v := intrinsics.unaligned_load((^V)(src[i:]))
		if dirty(v) {
			return put_mixed(out, s, i)
		}
		intrinsics.unaligned_store((^V)(p[1 + i:]), v)
	}
	v := intrinsics.unaligned_load((^V)(src[n - 16:]))
	if dirty(v) {
		return put_mixed(out, s, i)
	}
	intrinsics.unaligned_store((^V)(p[1 + n - 16:]), v)
	p[0], p[1 + n] = '"', '"'
	out.cursor += n + 2
	return .None
}

// Returns the string's bytes from `src` for `n` below 16, padded with `a` to a block, from loads that stay inside it.
@(private)
short_block :: #force_inline proc "contextless" (src: [^]u8, n: int) -> V #no_bounds_check {
	low, high := PAD_WORD, PAD_WORD
	switch {
	case n > 8:
		low = intrinsics.unaligned_load((^u64)(src))
		last := intrinsics.unaligned_load((^u64)(src[n - 8:]))
		high = last >> (8 * u64(16 - n)) | PAD_WORD << (8 * u64(n - 8))
	case n == 8:
		low = intrinsics.unaligned_load((^u64)(src))
	case n >= 4:
		first := u64(intrinsics.unaligned_load((^u32)(src)))
		last := u64(intrinsics.unaligned_load((^u32)(src[n - 4:])))
		low = first | last << (8 * u64(n - 4)) | PAD_WORD << (8 * u64(n))
	case n > 0:
		mid := n / 2
		low = u64(src[0]) | u64(src[mid]) << (8 * u64(mid)) | u64(src[n - 1]) << (8 * u64(n - 1)) | PAD_WORD << (8 * u64(n))
	}
	return transmute(V)[2]u64{low, high}
}

// Returns the block of `s` at `i`, from `n - i` live bytes, the rest padded with `a`. The last block of a string of 16
// bytes or more is its last 16 bytes shifted down.
@(private)
tail_block :: #force_inline proc "contextless" (src: [^]u8, i, n: int) -> V #no_bounds_check {
	live := n - i
	if n >= 16 {
		last := intrinsics.unaligned_load((^V)(src[n - 16:]))
		lane := simd.indices(V)
		shifted := simd.runtime_swizzle(last, lane + V(u8(16 - live)))
		return simd.select(simd.lanes_lt(lane, V(u8(live))), shifted, PAD)
	}
	return short_block(src[i:], live)
}

// Writes the 16 bytes of `v` through the escape table at `o` in `base` and returns the offset after them.
@(private)
escape_block :: #force_inline proc "contextless" (base: [^]u8, o: int, v: V) -> int #no_bounds_check {
	blk := transmute([16]u8)v
	o := o
	for b in blk {
		seq := ESC_SEQ[b]
		intrinsics.unaligned_store((^u64)(&base[o]), seq)
		o += int(seq >> 56)
	}
	return o
}

// Copies the 64-byte blocks of `src` from `i` while they hold no stop, checking the UTF-8 of those with a byte past 0x7F.
// Out of line so the four registers of a block stay out of `put_mixed`'s loop, which spills them. `prev` is the last
// block read, `bad` the faults so far and `high` whether `prev` ended after a byte past 0x7F. It stops before `end`, at
// the first block with a stop, and returns the source offset and the offset in `base`.
@(private)
wide_run :: #force_inline proc "contextless" (base, src: [^]u8, i, o, end: int, prev, bad: ^V, high: ^bool) -> (int, int) #no_bounds_check {
	i, o := i, o
	for ; i + 64 <= end; i += 64 {
		b := kernel.load(src[i:])
		if kernel.any_lane(kernel.either(kernel.either(kernel.eq(b, '"'), kernel.eq(b, '\\')), kernel.below(b, 0x20))) {
			break
		}
		if !kernel.is_ascii(b) {
			bad^ |= kernel.utf8_window(prev^, b[0]) | kernel.utf8_window(b[0], b[1]) | kernel.utf8_window(b[1], b[2]) | kernel.utf8_window(b[2], b[3])
			high^ = true
		} else if high^ {
			bad^ |= kernel.utf8_window(prev^, b[0])
			high^ = false
		}
		prev^ = b[3]
		intrinsics.unaligned_store((^kernel.Block)(base[o:]), b)
		o += 64
	}
	return i, o
}

// `wide_run` has a copy per x86 tier, each out of line with the tier's target features, so its 64-lane operations
// use the tier's registers.
when ODIN_ARCH == .amd64 {
	@(private, enable_target_feature = kernel.FEATURES[.V2])
	wide_run_v2 :: #force_no_inline proc "contextless" (base, src: [^]u8, i, o, end: int, prev, bad: ^V, high: ^bool) -> (int, int) {
		return wide_run(base, src, i, o, end, prev, bad, high)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V3])
	wide_run_v3 :: #force_no_inline proc "contextless" (base, src: [^]u8, i, o, end: int, prev, bad: ^V, high: ^bool) -> (int, int) {
		return wide_run(base, src, i, o, end, prev, bad, high)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V4])
	wide_run_v4 :: #force_no_inline proc "contextless" (base, src: [^]u8, i, o, end: int, prev, bad: ^V, high: ^bool) -> (int, int) {
		return wide_run(base, src, i, o, end, prev, bad, high)
	}
} else {
	@(private)
	wide_run_base :: #force_no_inline proc "contextless" (base, src: [^]u8, i, o, end: int, prev, bad: ^V, high: ^bool) -> (int, int) {
		return wide_run(base, src, i, o, end, prev, bad, high)
	}
}

@(private)
wide_run_tier :: #force_inline proc "contextless" (tier: kernel.Tier, base, src: [^]u8, i, o, end: int, prev, bad: ^V, high: ^bool) -> (int, int) {
	when ODIN_ARCH == .amd64 {
		switch tier {
		case .V4:
			return wide_run_v4(base, src, i, o, end, prev, bad, high)
		case .V3:
			return wide_run_v3(base, src, i, o, end, prev, bad, high)
		case .V2:
		}
		return wide_run_v2(base, src, i, o, end, prev, bad, high)
	} else {
		return wide_run_base(base, src, i, o, end, prev, bad, high)
	}
}

// Writes `s` as a JSON string, its first `i0` bytes already copied past the cursor as the plain ASCII `put_string_mid`
// found. It reserves `SEGMENT` source bytes at a time, so it takes any length, and carries the UTF-8 state between them.
// Steps by 16 bytes, through the escape table when the block holds a stop. After a stop it does not try 64-byte blocks
// for 80 bytes, since a string with one escape has more.
@(private)
put_mixed :: #force_no_inline proc(out: ^write.Out, s: string, i0: int) -> core.Typed_Error_Kind #no_bounds_check {
	n := len(s)
	src := raw_data(s)
	if i0 > 0 {
		write.room(out, 1)[0] = '"'
		out.cursor += 1 + i0
	}
	tier := kernel.tier() if n >= 64 else kernel.Tier(0)
	prev, bad: V
	high := false
	try_from := 0
	for i := i0; i < n; {
		end := min(i + SEGMENT, n)
		base := write.room(out, 6 * (end - i + 16) + 18)
		o := 0
		if i == 0 {
			base[0] = '"'
			o = 1
		}
		for i < end {
			left := n - i
			if i >= try_from && left >= 64 && i + 64 <= end {
				// Copies, so that the address the call takes keeps `prev`, `bad` and `high` out of memory in this loop.
				run_prev, run_bad, run_high := prev, bad, high
				i, o = wide_run_tier(tier, base, src, i, o, end, &run_prev, &run_bad, &run_high)
				prev, bad, high = run_prev, run_bad, run_high
				try_from = i + 64
				if i >= end {
					break
				}
				left = n - i
			}
			v := intrinsics.unaligned_load((^V)(src[i:])) if left >= 16 else tail_block(src, i, n)
			take := min(left, 16)
			h := kernel.any_lane16(simd.lanes_ge(v, HIGH))
			if h || high {
				bad |= kernel.utf8_window(prev, v)
			}
			prev, high = v, h
			if kernel.any_lane16(esc_lanes(v)) {
				try_from = i + 80
				o = escape_block(base, o, v) - (16 - take)
			} else {
				intrinsics.unaligned_store((^V)(base[o:]), v)
				o += take
			}
			i += take
		}
		if end == n {
			if high {
				bad |= kernel.utf8_window(prev, PAD)
			}
			if simd.reduce_or(bad) != 0 {
				return .Bad_Utf8
			}
			base[o] = '"'
			o += 1
		}
		out.cursor += o
	}
	return .None
}

// Writes `s` one byte at a time with the stops `ascii` and `escape_html` add: a rune past U+007F as `\uXXXX`, a surrogate
// pair past U+FFFF, and `<`, `>`, `&`, U+2028 and U+2029 as `\u00xx` and `\u202x`. Any other rune is copied as it is.
@(private)
put_escaped :: proc(out: ^write.Out, s: string, $ASCII, $HTML: bool) -> core.Typed_Error_Kind #no_bounds_check {
	n := len(s)
	src := raw_data(s)
	write.room(out, 1)[0] = '"'
	out.cursor += 1
	for i := 0; i < n; {
		end := min(i + SEGMENT, n)
		base := write.room(out, 6 * (end - i) + 32)
		o := 0
		next_block := i
		for i < end {
			// A block of plain ASCII is copied whole. After a stop the next 80 bytes are not tried, since a text with one
			// stop has more.
			if i >= next_block {
				if i + 16 <= end {
					v := intrinsics.unaligned_load((^V)(src[i:]))
					stop := dirty(v)
					when HTML {
						stop ||= kernel.any_lane16(simd.lanes_eq(v, V('<')) | simd.lanes_eq(v, V('>')) | simd.lanes_eq(v, V('&')))
					}
					if !stop {
						intrinsics.unaligned_store((^V)(base[o:]), v)
						o += 16
						i += 16
						next_block = i
						continue
					}
				}
				next_block = i + 80
			}
			b := src[i]
			if b < 0x80 {
				if HTML && (b == '<' || b == '>' || b == '&') {
					o += u_escape(base[o:], u16(b))
				} else {
					seq := ESC_SEQ[b]
					intrinsics.unaligned_store((^u64)(&base[o]), seq)
					o += int(seq >> 56)
				}
				i += 1
				continue
			}
			q, kind := kernel.utf8_char(src[i:], src[n:])
			if kind != .None {
				return .Bad_Utf8
			}
			size := intrinsics.ptr_sub(q, src[i:])
			cp := decode_rune(src[i:], size)
			if ASCII || HTML && (cp == 0x2028 || cp == 0x2029) {
				o += unit_text(base[o:], cp)
			} else {
				for j in 0 ..< size {
					base[o + j] = src[i + j]
				}
				o += size
			}
			i += size
		}
		out.cursor += o
	}
	write.room(out, 1)[0] = '"'
	out.cursor += 1
	return .None
}

// Writes `cp` as `\uXXXX`, as a surrogate pair past the plane, under 12 bytes, and returns its length.
@(private)
unit_text :: proc "contextless" (p: [^]u8, cp: u32) -> int {
	if cp < 0x10000 {
		return u_escape(p, u16(cp))
	}
	c := cp - 0x10000
	return u_escape(p, u16(0xD800 + c >> 10)) + u_escape(p[6:], u16(0xDC00 + c & 0x3FF))
}

// Returns the code point of the valid sequence of `size` bytes at `p`.
@(private)
decode_rune :: #force_inline proc "contextless" (p: [^]u8, size: int) -> u32 {
	switch size {
	case 2:
		return u32(p[0] & 0x1F) << 6 | u32(p[1] & 0x3F)
	case 3:
		return u32(p[0] & 0x0F) << 12 | u32(p[1] & 0x3F) << 6 | u32(p[2] & 0x3F)
	}
	return u32(p[0] & 0x07) << 18 | u32(p[1] & 0x3F) << 12 | u32(p[2] & 0x3F) << 6 | u32(p[3] & 0x3F)
}

// Writes `\u` and the four lowercase hex digits of `unit` at `p` and returns 6.
@(private)
u_escape :: #force_inline proc "contextless" (p: [^]u8, unit: u16) -> int #no_bounds_check {
	hex := "0123456789abcdef"
	p[0], p[1] = '\\', 'u'
	p[2], p[3], p[4], p[5] = hex[unit >> 12], hex[unit >> 8 & 15], hex[unit >> 4 & 15], hex[unit & 15]
	return 6
}
