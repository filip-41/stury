package spell_tests

import "base:intrinsics"
import "core:testing"
import "stury:lib/base/spell"
import "stury:testkit"

// Reference Unicode Table 3-7 validation and maximal subpart length for a non-empty byte sequence.
@(private = "file")
ref_utf8_table_3_7 :: proc(src: []u8) -> (char_len: int, kind: spell.Fault_Kind, subpart: int) {
	b0 := src[0]
	if b0 < 0xC2 || b0 > 0xF4 {
		return 0, .Bad_Char, 1
	}
	need := 2 if b0 < 0xE0 else 3 if b0 < 0xF0 else 4
	for i in 1 ..< need {
		if i >= len(src) {
			return len(src), .Truncated, len(src)
		}
		b := src[i]
		bad := b & 0xC0 != 0x80
		if i == 1 {
			switch b0 {
			case 0xE0:
				bad ||= b < 0xA0
			case 0xED:
				bad ||= b > 0x9F
			case 0xF0:
				bad ||= b < 0x90
			case 0xF4:
				bad ||= b > 0x8F
			}
		}
		if bad {
			return 0, .Bad_Char, i
		}
	}
	return need, .None, need
}

// `utf8_char`, `utf8_subpart`, and `utf8_lax` match Unicode Table 3-7 across every 1- and 2-byte sequence,
// boundary 3- and 4-byte sequences, well-formed UTF-8, overlongs, surrogates, > U+10FFFF, and truncations.
@(test)
test_utf8_table_3_7_and_lax :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, spell.REPLACEMENT, [3]u8{0xEF, 0xBF, 0xBD})

	check_one :: proc(t: ^testing.T, src: []u8) -> bool {
		want_len, want_kind, want_sub := ref_utf8_table_3_7(src)
		p := raw_data(src)
		end := p[len(src):]

		q, kind := spell.utf8_char(p, end)
		got_len := int(intrinsics.ptr_sub(q, p))
		if kind != want_kind || got_len != want_len {
			testing.expectf(t, false, "utf8_char(%x) = (%d, %v), want (%d, %v)", src, got_len, kind, want_len, want_kind)
			return false
		}

		sub_q := spell.utf8_subpart(p, end)
		got_sub := int(intrinsics.ptr_sub(sub_q, p))
		if got_sub != want_sub {
			testing.expectf(t, false, "utf8_subpart(%x) = %d, want %d", src, got_sub, want_sub)
			return false
		}

		CANARY :: u8(0xA5)
		out := [5]u8{CANARY, CANARY, CANARY, CANARY, CANARY}
		wn, lq := spell.utf8_lax(p, end, raw_data(out[:]))
		got_read := int(intrinsics.ptr_sub(lq, p))
		if got_read != want_sub {
			testing.expectf(t, false, "utf8_lax(%x) read %d, want %d", src, got_read, want_sub)
			return false
		}
		if want_kind == .None {
			if wn != want_len {
				testing.expectf(t, false, "utf8_lax(%x) wrote %d, want %d", src, wn, want_len)
				return false
			}
			for i in 0 ..< wn {
				if out[i] != src[i] {
					testing.expectf(t, false, "utf8_lax(%x) out[%d] = 0x%02x, want 0x%02x", src, i, out[i], src[i])
					return false
				}
			}
		} else {
			if wn != 3 || out[0] != spell.REPLACEMENT[0] || out[1] != spell.REPLACEMENT[1] || out[2] != spell.REPLACEMENT[2] {
				testing.expectf(t, false, "utf8_lax(%x) wrote (%d, %x), want REPLACEMENT", src, wn, out[:3])
				return false
			}
		}
		for i in wn ..< len(out) {
			if out[i] != CANARY {
				testing.expectf(t, false, "utf8_lax(%x) overwrote canary out[%d] = 0x%02x", src, i, out[i])
				return false
			}
		}
		return true
	}

	// Exhaustive 1-byte and 2-byte sequences.
	buf: [4]u8
	for b0 in 0 ..< 256 {
		buf[0] = u8(b0)
		if !check_one(t, buf[:1]) {
			return
		}
		for b1 in 0 ..< 256 {
			buf[1] = u8(b1)
			if !check_one(t, buf[:2]) {
				return
			}
		}
	}

	// Boundary 3-byte and 4-byte leads x boundary continuations.
	LEADS :: [20]u8{
		0x00, 0x7F, 0x80, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF,
		0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xEF,
		0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xFF,
	}
	CONTS :: [13]u8{0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC2, 0xE0, 0xFF}
	LASTS :: [6]u8{0x41, 0x7F, 0x80, 0xBF, 0xC0, 0xFF}
	for b0 in LEADS {
		buf[0] = b0
		for b1 in CONTS {
			buf[1] = b1
			for b2 in CONTS {
				buf[2] = b2
				if !check_one(t, buf[:3]) {
					return
				}
				for b3 in LASTS {
					buf[3] = b3
					if !check_one(t, buf[:4]) {
						return
					}
				}
			}
		}
	}
}

// Canonical Unicode Standard substitution-of-maximal-subparts examples (Tables 3-8 to 3-11).
@(test)
test_utf8_lax_unicode_examples :: proc(t: ^testing.T) {
	testkit.deadline(t)
	FFFD :: "\xEF\xBF\xBD"
	Case :: struct {
		src:  string,
		want: string,
	}
	cases := [?]Case{
		// Table 3-8: C0 AF E0 80 BF F0 81 82 41 -> 8x U+FFFD + "A"
		{"\xC0\xAF\xE0\x80\xBF\xF0\x81\x82A", FFFD + FFFD + FFFD + FFFD + FFFD + FFFD + FFFD + FFFD + "A"},
		// Table 3-9: ED A0 80 ED BF BF ED AF 41 -> 8x U+FFFD + "A"
		{"\xED\xA0\x80\xED\xBF\xBF\xED\xAFA", FFFD + FFFD + FFFD + FFFD + FFFD + FFFD + FFFD + FFFD + "A"},
		// Table 3-10: F4 91 92 93 FF 41 80 BF -> 5x U+FFFD + "A" + 2x U+FFFD
		{"\xF4\x91\x92\x93\xFFA\x80\xBF", FFFD + FFFD + FFFD + FFFD + FFFD + "A" + FFFD + FFFD},
		// Table 3-11: E1 80 E2 F0 91 92 F1 BF 41 -> 4x U+FFFD + "A"
		{"\xE1\x80\xE2\xF0\x91\x92\xF1\xBFA", FFFD + FFFD + FFFD + FFFD + "A"},
		// Mixed valid 1..4 byte UTF-8 and truncated tail
		{"a\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80\xF0\x90\x80", "aé€😀" + FFFD},
	}

	out: [128]u8
	for c in cases {
		src := transmute([]u8)c.src
		p := raw_data(src)
		end := p[len(src):]
		w := 0
		for p < end {
			if p[0] < 0x80 {
				out[w] = p[0]
				w += 1
				p = p[1:]
			} else {
				n: int
				n, p = spell.utf8_lax(p, end, raw_data(out[w:]))
				w += n
			}
		}
		testing.expect_value(t, string(out[:w]), c.want)
	}
}

// `bom_length` recognizes only the exact 3-byte UTF-8 BOM at the start of `src`.
@(test)
test_bom_length :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		src:  string,
		want: int,
	}
	cases := [?]Case{
		{"", 0},
		{"\xEF", 0},
		{"\xEF\xBB", 0},
		{"\xEF\xBB\xBE", 0},
		{"\xEF\xBA\xBF", 0},
		{"\xEE\xBB\xBF", 0},
		{"abc", 0},
		{" \xEF\xBB\xBF", 0},
		{"\xEF\xBB\xBF", 3},
		{"\xEF\xBB\xBFhello", 3},
		{"\xEF\xBB\xBF\xEF\xBB\xBF", 3},
	}
	for c in cases {
		testing.expect_value(t, spell.bom_length(transmute([]u8)c.src), c.want)
	}
}

// `digit_end` finds the exact end of every decimal digit run across SWAR chunk boundaries and all 256 trailing bytes.
@(test)
test_digit_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	empty: [1]u8
	ep := raw_data(empty[:])
	testing.expect_value(t, spell.digit_end(ep, ep), ep)

	buf: [32]u8
	for run_len in 0 ..= 25 {
		for i in 0 ..< run_len {
			buf[i] = u8('0' + (i % 10))
		}
		p := raw_data(buf[:])
		// Run reaching `end` exactly.
		got_full := int(intrinsics.ptr_sub(spell.digit_end(p, p[run_len:]), p))
		if got_full != run_len {
			testing.expectf(t, false, "digit_end(len=%d exact) = %d", run_len, got_full)
			return
		}
		// Run followed by every possible byte (plus padding digits after it to verify we stop at the first non-digit).
		for trail in 0 ..< 256 {
			b := u8(trail)
			buf[run_len] = b
			for j in run_len + 1 ..< len(buf) {
				buf[j] = '9'
			}
			want := len(buf) if b >= '0' && b <= '9' else run_len
			got := int(intrinsics.ptr_sub(spell.digit_end(p, p[len(buf):]), p))
			if got != want {
				testing.expectf(t, false, "digit_end(run=%d, trail=0x%02x) = %d, want %d", run_len, trail, got, want)
				return
			}
		}
	}
}

// `hex_digit_end` scans ASCII hex digits and stops at the first non-hex byte or `end`.
@(test)
test_hex_digit_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	empty: [1]u8
	ep := raw_data(empty[:])
	testing.expect_value(t, spell.hex_digit_end(ep, ep), ep)

	all_hex := "0123456789abcdefABCDEF"
	hp := raw_data(all_hex)
	testing.expect_value(t, int(intrinsics.ptr_sub(spell.hex_digit_end(hp, hp[len(all_hex):]), hp)), len(all_hex))

	buf: [16]u8
	for prefix in 0 ..= 9 {
		for i in 0 ..< prefix {
			buf[i] = all_hex[i % len(all_hex)]
		}
		p := raw_data(buf[:])
		for trail in 0 ..< 256 {
			b := u8(trail)
			buf[prefix] = b
			for j in prefix + 1 ..< len(buf) {
				buf[j] = 'F'
			}
			is_hex := (b >= '0' && b <= '9') || (b >= 'A' && b <= 'F') || (b >= 'a' && b <= 'f')
			want := len(buf) if is_hex else prefix
			got := int(intrinsics.ptr_sub(spell.hex_digit_end(p, p[len(buf):]), p))
			if got != want {
				testing.expectf(t, false, "hex_digit_end(prefix=%d, trail=0x%02x) = %d, want %d", prefix, trail, got, want)
				return
			}
		}
	}
}
