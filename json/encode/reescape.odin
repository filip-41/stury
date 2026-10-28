package encode

// Re-escaping: finished JSON text with some characters rewritten as `\u` escapes (`ascii_only`,
// `escape_html`). Strict JSON has a byte past 0x7F, `<`, `>` or `&` only inside a string, and never right
// after an escaping backslash, so the rewrite reads each character alone and keeps no string state. The text
// is valid UTF-8: every writer here has checked it.
//
// `$FLAGS` compiles the counting and rewriting loops once per flag set. The loops load 16 bytes only while
// 16 remain, and read a lead byte's continuation bytes unchecked: every caller hands over whole values or,
// in `sink_write`, pieces cut between characters. Stores write only output bytes (16 for a clean block, 6
// per `\u` escape), so `dst` needs exactly the rewrite's length.

import "base:intrinsics"
import "core:simd"
import core_pkg "../../core"

@(private = "file")
Reescape_Flag :: enum u8 {
	Non_Ascii, // every character past U+007F
	Html,      // `<`, `>`, `&`, U+2028 and U+2029
}
@(private)
Reescape :: bit_set[Reescape_Flag; u8]

reescape_of :: proc(opts: Marshal_Opts) -> (r: Reescape) {
	if opts.ascii_only {
		r += {.Non_Ascii}
	}
	if opts.escape_html {
		r += {.Html}
	}
	return
}

// The bytes rewriting `text` adds.
@(private)
reescape_extra :: proc(text: []u8, flags: Reescape) -> int {
	switch flags {
	case {.Non_Ascii}:
		return reescape_count(text, Reescape{.Non_Ascii})
	case {.Html}:
		return reescape_count(text, Reescape{.Html})
	case {.Non_Ascii, .Html}:
		return reescape_count(text, Reescape{.Non_Ascii, .Html})
	}
	return 0
}

// `reescape_extra` for constant flags, as `reescape_run` is, so the block loop does not re-derive their
// masks every 16 bytes.
@(private)
reescape_count :: proc(text: []u8, $FLAGS: Reescape) -> int #no_bounds_check {
	flags :: FLAGS
	extra := 0
	n := len(text)
	scalar_to := 0
	for i := 0; i < n; {
		if i >= scalar_to && i + 16 <= n {
			v := intrinsics.unaligned_load((^#simd[16]u8)(&text[i]))
			if !reescape_block(v, flags) {
				i += 16
				continue
			}
			// What a character adds is a weight on its bytes, so a block sums them whatever characters it
			// cuts. Only U+2028 and U+2029 without `.Non_Ascii` are not one byte's weight.
			if .Non_Ascii in flags || simd.reduce_or(simd.lanes_eq(v, (#simd[16]u8)(0xE2))) == 0 {
				extra += int(simd.reduce_add_ordered(reescape_weights(v, flags)))
				i += 16
				continue
			}
			scalar_to = i + 16
		}
		k, cp := reescape_char(text, i, flags)
		if cp >= 0 {
			extra += escape_width(cp) - k
		}
		i += k
	}
	return extra
}

// `text` rewritten at `dst`. Returns the count written. `dst` may start at or before `text` in the same buffer, as
// long as it is no more than the rewrite's extra bytes before it: the write then never passes the read.
@(private)
reescape_into :: proc(dst: [^]u8, text: []u8, flags: Reescape) -> int {
	switch flags {
	case {.Non_Ascii}:
		return reescape_run(dst, text, Reescape{.Non_Ascii})
	case {.Html}:
		return reescape_run(dst, text, Reescape{.Html})
	case {.Non_Ascii, .Html}:
		return reescape_run(dst, text, Reescape{.Non_Ascii, .Html})
	}
	intrinsics.mem_copy(dst, raw_data(text), len(text))
	return len(text)
}

@(private)
reescape_run :: proc(dst: [^]u8, text: []u8, $FLAGS: Reescape) -> int #no_bounds_check {
	w := 0
	n := len(text)
	// A dirty block is read character by character to its end before the next block is tried.
	scalar_to := 0
	for i := 0; i < n; {
		if i >= scalar_to && i + 16 <= n {
			v := intrinsics.unaligned_load((^#simd[16]u8)(&text[i]))
			if !reescape_block(v, FLAGS) {
				intrinsics.unaligned_store((^#simd[16]u8)(&dst[w]), v)
				w += 16
				i += 16
				continue
			}
			scalar_to = i + 16
		}
		if b := text[i]; b < 0x80 && (.Html not_in FLAGS || !is_html_byte(b)) {
			dst[w] = b
			w += 1
			i += 1
			continue
		}
		k, cp := reescape_char(text, i, FLAGS)
		if cp < 0 {
			for j in 0 ..< k {
				dst[w + j] = text[i + j]
			}
			w += k
		} else if cp < 0x10000 {
			w += spell_u_escape(dst[w:], u16(cp))
		} else {
			c := cp - 0x10000
			w += spell_u_escape(dst[w:], u16(0xD800 + (c >> 10)))
			w += spell_u_escape(dst[w:], u16(0xDC00 + (c & 0x3FF)))
		}
		i += k
	}
	return w
}

// Rewrite `dst[lo:]` in place, growing `dst` by exactly the bytes the rewrite adds when they do not fit.
reescape_tail :: proc(dst: ^[dynamic]u8, lo: int, flags: Reescape) -> Marshal_Error_Kind {
	extra := reescape_extra(dst[lo:], flags)
	if extra == 0 {
		return .None
	}
	n := len(dst) - lo
	if len(dst) + extra > cap(dst) && non_zero_reserve(dst, len(dst) + extra) != nil {
		return .Out_Of_Memory
	}
	base := raw_data(dst^)
	intrinsics.mem_copy(&base[lo + extra], &base[lo], n)
	reescape_into(&base[lo], base[lo + extra:][:n], flags)
	put_commit(dst, extra)
	return .None
}

// The length of `text` without a UTF-8 sequence cut off at its end.
@(private)
utf8_whole_len :: proc(text: []u8) -> int {
	n := len(text)
	for back := 1; back <= min(3, n); back += 1 {
		b := text[n - back]
		if b & 0xC0 == 0x80 {
			continue
		}
		if b >= 0xC0 && utf8_seq_len(b) > back {
			return n - back
		}
		break
	}
	return n
}

@(private)
utf8_seq_len :: #force_inline proc "contextless" (lead: u8) -> int {
	return 2 if lead < 0xE0 else 3 if lead < 0xF0 else 4
}

// A block that holds nothing the rewrite might change.
@(private)
reescape_block :: #force_inline proc "contextless" (v: #simd[16]u8, flags: Reescape) -> bool {
	when ODIN_ARCH != .amd64 {
		if flags == {.Non_Ascii} {
			return core_pkg.any_high(v)
		}
	}
	hit: #simd[16]u8
	if .Non_Ascii in flags {
		hit = simd.lanes_ge(v, (#simd[16]u8)(0x80))
	} else {
		// U+2028 and U+2029 begin with 0xE2.
		hit = simd.lanes_eq(v, (#simd[16]u8)(0xE2))
	}
	if .Html in flags {
		hit |= html_lanes(v)
	}
	return core_pkg.any_lane(hit)
}

// The lanes of `v` holding `<`, `>` or `&`, the bytes `.Html` writes as escapes.
@(private = "file")
html_lanes :: #force_inline proc "contextless" (v: #simd[16]u8) -> #simd[16]u8 {
	return simd.lanes_eq(v, (#simd[16]u8)('<')) | simd.lanes_eq(v, (#simd[16]u8)('>')) | simd.lanes_eq(v, (#simd[16]u8)('&'))
}

// Whether `b` is `<`, `>` or `&`.
@(private = "file")
is_html_byte :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == '<' || b == '>' || b == '&'
}

// What each byte of `v` adds: a lead byte past U+007F the rest of its `\u` text (4, 3 or 8 for a lead
// of 2, 3 or 4 bytes), and `<`, `>` or `&` five. At most 8 a byte, so a block's sum fits a byte.
@(private)
reescape_weights :: #force_inline proc "contextless" (v: #simd[16]u8, flags: Reescape) -> (w: #simd[16]u8) {
	if .Non_Ascii in flags {
		// 4 from 0xC0, 4 - 1 from 0xE0, 3 + 5 from 0xF0, in wrapping byte arithmetic.
		w = simd.lanes_ge(v, (#simd[16]u8)(0xC0)) & 4
		w += simd.lanes_ge(v, (#simd[16]u8)(0xE0))
		w += simd.lanes_ge(v, (#simd[16]u8)(0xF0)) & 5
	}
	if .Html in flags {
		w += html_lanes(v) & 5
	}
	return
}

// The character at `text[i]`: its length, and the code point to write as escapes, or -1 to copy it.
@(private)
reescape_char :: #force_inline proc "contextless" (text: []u8, i: int, flags: Reescape) -> (n: int, cp: rune) #no_bounds_check {
	b := text[i]
	switch {
	case b < 0x80:
		if .Html in flags && is_html_byte(b) {
			return 1, rune(b)
		}
		return 1, -1
	case b < 0xC0:
		// A sequence a clean block's skip cut in two: its lead was in the block, so it is no character
		// the rewrite changes.
		return 1, -1
	case b < 0xE0:
		n, cp = 2, rune(b & 0x1F) << 6 | rune(text[i + 1] & 0x3F)
	case b < 0xF0:
		n, cp = 3, rune(b & 0x0F) << 12 | rune(text[i + 1] & 0x3F) << 6 | rune(text[i + 2] & 0x3F)
	case:
		n, cp = 4, rune(b & 0x07) << 18 | rune(text[i + 1] & 0x3F) << 12 | rune(text[i + 2] & 0x3F) << 6 | rune(text[i + 3] & 0x3F)
	}
	if .Non_Ascii in flags || cp == 0x2028 || cp == 0x2029 {
		return n, cp
	}
	return n, -1
}

// What `cp` is written as: one `\uXXXX`, or a surrogate pair past U+FFFF.
@(private)
escape_width :: #force_inline proc "contextless" (cp: rune) -> int {
	return 6 if cp < 0x10000 else 12
}

// The two lowercase hex digits of a byte, first digit in the low byte, so a 16-bit store writes them in order.
@(private = "file", rodata)
HEX_PAIR: [256]u16 = {
	0x3030, 0x3130, 0x3230, 0x3330, 0x3430, 0x3530, 0x3630, 0x3730,
	0x3830, 0x3930, 0x6130, 0x6230, 0x6330, 0x6430, 0x6530, 0x6630,
	0x3031, 0x3131, 0x3231, 0x3331, 0x3431, 0x3531, 0x3631, 0x3731,
	0x3831, 0x3931, 0x6131, 0x6231, 0x6331, 0x6431, 0x6531, 0x6631,
	0x3032, 0x3132, 0x3232, 0x3332, 0x3432, 0x3532, 0x3632, 0x3732,
	0x3832, 0x3932, 0x6132, 0x6232, 0x6332, 0x6432, 0x6532, 0x6632,
	0x3033, 0x3133, 0x3233, 0x3333, 0x3433, 0x3533, 0x3633, 0x3733,
	0x3833, 0x3933, 0x6133, 0x6233, 0x6333, 0x6433, 0x6533, 0x6633,
	0x3034, 0x3134, 0x3234, 0x3334, 0x3434, 0x3534, 0x3634, 0x3734,
	0x3834, 0x3934, 0x6134, 0x6234, 0x6334, 0x6434, 0x6534, 0x6634,
	0x3035, 0x3135, 0x3235, 0x3335, 0x3435, 0x3535, 0x3635, 0x3735,
	0x3835, 0x3935, 0x6135, 0x6235, 0x6335, 0x6435, 0x6535, 0x6635,
	0x3036, 0x3136, 0x3236, 0x3336, 0x3436, 0x3536, 0x3636, 0x3736,
	0x3836, 0x3936, 0x6136, 0x6236, 0x6336, 0x6436, 0x6536, 0x6636,
	0x3037, 0x3137, 0x3237, 0x3337, 0x3437, 0x3537, 0x3637, 0x3737,
	0x3837, 0x3937, 0x6137, 0x6237, 0x6337, 0x6437, 0x6537, 0x6637,
	0x3038, 0x3138, 0x3238, 0x3338, 0x3438, 0x3538, 0x3638, 0x3738,
	0x3838, 0x3938, 0x6138, 0x6238, 0x6338, 0x6438, 0x6538, 0x6638,
	0x3039, 0x3139, 0x3239, 0x3339, 0x3439, 0x3539, 0x3639, 0x3739,
	0x3839, 0x3939, 0x6139, 0x6239, 0x6339, 0x6439, 0x6539, 0x6639,
	0x3061, 0x3161, 0x3261, 0x3361, 0x3461, 0x3561, 0x3661, 0x3761,
	0x3861, 0x3961, 0x6161, 0x6261, 0x6361, 0x6461, 0x6561, 0x6661,
	0x3062, 0x3162, 0x3262, 0x3362, 0x3462, 0x3562, 0x3662, 0x3762,
	0x3862, 0x3962, 0x6162, 0x6262, 0x6362, 0x6462, 0x6562, 0x6662,
	0x3063, 0x3163, 0x3263, 0x3363, 0x3463, 0x3563, 0x3663, 0x3763,
	0x3863, 0x3963, 0x6163, 0x6263, 0x6363, 0x6463, 0x6563, 0x6663,
	0x3064, 0x3164, 0x3264, 0x3364, 0x3464, 0x3564, 0x3664, 0x3764,
	0x3864, 0x3964, 0x6164, 0x6264, 0x6364, 0x6464, 0x6564, 0x6664,
	0x3065, 0x3165, 0x3265, 0x3365, 0x3465, 0x3565, 0x3665, 0x3765,
	0x3865, 0x3965, 0x6165, 0x6265, 0x6365, 0x6465, 0x6565, 0x6665,
	0x3066, 0x3166, 0x3266, 0x3366, 0x3466, 0x3566, 0x3666, 0x3766,
	0x3866, 0x3966, 0x6166, 0x6266, 0x6366, 0x6466, 0x6566, 0x6666,
}

@(private)
spell_u_escape :: #force_inline proc "contextless" (dst: [^]u8, unit: u16) -> int {
	intrinsics.unaligned_store((^u32)(dst), u32('\\') | u32('u') << 8 | u32(HEX_PAIR[unit >> 8]) << 16)
	intrinsics.unaligned_store((^u16)(&dst[4]), HEX_PAIR[unit & 0xFF])
	return 6
}
