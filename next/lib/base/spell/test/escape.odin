package spell_tests

import "core:testing"
import "stury:lib/base/spell"
import "stury:testkit"

// `ESCAPED` maps only RFC 8259's eight one-letter escapes and zeroes every other byte, and `HEX_NIBBLE` maps only
// ASCII hex digits.
@(test)
escape_tables_cover_all_bytes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for b in 0 ..< 256 {
		want_escaped: u8
		switch b {
		case '"':
			want_escaped = '"'
		case '\\':
			want_escaped = '\\'
		case '/':
			want_escaped = '/'
		case 'b':
			want_escaped = '\b'
		case 'f':
			want_escaped = '\f'
		case 'n':
			want_escaped = '\n'
		case 'r':
			want_escaped = '\r'
		case 't':
			want_escaped = '\t'
		}
		if spell.ESCAPED[b] != want_escaped {
			testing.expectf(t, false, "ESCAPED[0x%02x] = 0x%02x, want 0x%02x", b, spell.ESCAPED[b], want_escaped)
			return
		}

		want_nibble: u8 = 0xFF
		switch {
		case b >= '0' && b <= '9':
			want_nibble = u8(b - '0')
		case b >= 'A' && b <= 'F':
			want_nibble = u8(b - 'A' + 10)
		case b >= 'a' && b <= 'f':
			want_nibble = u8(b - 'a' + 10)
		}
		if spell.HEX_NIBBLE[b] != want_nibble {
			testing.expectf(t, false, "HEX_NIBBLE[0x%02x] = 0x%02x, want 0x%02x", b, spell.HEX_NIBBLE[b], want_nibble)
			return
		}
	}
}

// `hex4` and `hex4_value` agree on every 16-bit hex spelling in lowercase, uppercase, and mixed case, and `hex4`
// rejects any non-hex byte in any of the four positions.
@(test)
hex4_decoders_match_and_reject_bad_digits :: proc(t: ^testing.T) {
	testkit.deadline(t)
	LOWER :: "0123456789abcdef"
	UPPER :: "0123456789ABCDEF"

	buf: [4]u8
	for v in u32(0) ..< 0x10000 {
		for digits in ([2]string{LOWER, UPPER}) {
			buf = {
				digits[(v >> 12) & 0xF],
				digits[(v >> 8) & 0xF],
				digits[(v >> 4) & 0xF],
				digits[v & 0xF],
			}
			unit, ok := spell.hex4(&buf[0])
			val := spell.hex4_value(&buf[0])
			if !ok || unit != v || val != v {
				testing.expectf(t, false, "%q: hex4=(0x%04x, %v) hex4_value=0x%04x, want 0x%04x", string(buf[:]), unit, ok, val, v)
				return
			}
		}
	}

	mixed := []struct {
		text: string,
		want: u32,
	}{
		{"aB3f", 0xAB3F},
		{"DeAd", 0xDEAD},
		{"bEeF", 0xBEEF},
		{"0aF9", 0x0AF9},
		{"F0e1", 0xF0E1},
		{"d800", 0xD800},
		{"DcFf", 0xDCFF},
	}
	for c in mixed {
		unit, ok := spell.hex4(raw_data(c.text))
		val := spell.hex4_value(raw_data(c.text))
		testing.expectf(t, ok && unit == c.want && val == c.want, "%q: hex4=(0x%04x, %v) hex4_value=0x%04x, want 0x%04x", c.text, unit, ok, val, c.want)
	}

	bad_bytes := []u8{0x00, ' ', '/', ':', '@', 'G', '`', 'g', 0x7F, 0x80, 0xFF}
	for pos in 0 ..< 4 {
		for bad in bad_bytes {
			buf = {'d', 'c', '0', '1'}
			buf[pos] = bad
			_, ok := spell.hex4(&buf[0])
			testing.expectf(t, !ok, "pos=%d bad=0x%02x accepted", pos, bad)
		}
	}
}

// `rune_len` returns the UTF-8 byte length across every code-point width boundary in `0..0x10FFFF`.
@(test)
rune_len_boundaries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := []struct {
		r:    rune,
		want: u32,
	}{
		{0x0000, 1},
		{0x0041, 1},
		{0x007F, 1},
		{0x0080, 2},
		{0x00E9, 2},
		{0x07FF, 2},
		{0x0800, 3},
		{0x20AC, 3},
		{0xD7FF, 3},
		{0xE000, 3},
		{0xFFFF, 3},
		{0x10000, 4},
		{0x1F600, 4},
		{0x10FFFF, 4},
	}
	for c in cases {
		testing.expectf(t, spell.rune_len(c.r) == c.want, "U+%04X: got %d, want %d", u32(c.r), spell.rune_len(c.r), c.want)
	}
}

// `high_surrogate`, `low_surrogate`, and `surrogate_pair` enforce exact UTF-16 surrogate bounds and combine halves to
// `U+10000..U+10FFFF`.
@(test)
surrogate_helpers_boundaries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for unit in u32(0) ..< 0x10000 {
		want_high := unit >= 0xD800 && unit <= 0xDBFF
		want_low := unit >= 0xDC00 && unit <= 0xDFFF
		if spell.high_surrogate(unit) != want_high || spell.low_surrogate(unit) != want_low {
			testing.expectf(t, false, "0x%04x: high=%v/%v low=%v/%v", unit, spell.high_surrogate(unit), want_high, spell.low_surrogate(unit), want_low)
			return
		}
	}
	for extra in ([]u32{0x10000, 0x10FFFF, 0xFFFF_D800, 0xFFFF_DC00, max(u32)}) {
		testing.expectf(t, !spell.high_surrogate(extra), "0x%x high", extra)
		testing.expectf(t, !spell.low_surrogate(extra), "0x%x low", extra)
	}

	pairs := []struct {
		high, low: u32,
		want:      rune,
	}{
		{0xD800, 0xDC00, 0x10000},
		{0xD800, 0xDC01, 0x10001},
		{0xD800, 0xDFFF, 0x103FF},
		{0xD801, 0xDC00, 0x10400},
		{0xD834, 0xDD1E, 0x1D11E},
		{0xD83D, 0xDE00, 0x1F600},
		{0xDBFF, 0xDFFE, 0x10FFFE},
		{0xDBFF, 0xDFFF, 0x10FFFF},
	}
	for p in pairs {
		got := spell.surrogate_pair(p.high, p.low)
		testing.expectf(t, got == p.want, "(0x%04x, 0x%04x): got U+%X, want U+%X", p.high, p.low, u32(got), u32(p.want))
	}
}

// `string_escape` decodes JSON one-letter, BMP `\uXXXX`, and surrogate-pair escapes, and returns `(0, 0)` for short or
// negative `room`, non-JSON escapes, bad hex digits, and lone or reversed surrogates.
@(test)
string_escape_valid_and_invalid_cases :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Good :: struct {
		text: string,
		r:    rune,
		n:    int,
	}
	good := []Good{
		{`\"`, '"', 2},
		{`\\`, '\\', 2},
		{`\/`, '/', 2},
		{`\b`, '\b', 2},
		{`\f`, '\f', 2},
		{`\n`, '\n', 2},
		{`\r`, '\r', 2},
		{`\t`, '\t', 2},
		{`\ntrailing`, '\n', 2},
		{`\u0000`, 0, 6},
		{`\u001f`, 0x1F, 6},
		{`\u0041`, 'A', 6},
		{`\u007F`, 0x7F, 6},
		{`\u00e9`, 0xE9, 6},
		{`\u20Ac`, 0x20AC, 6},
		{`\uD7FF`, 0xD7FF, 6},
		{`\uE000`, 0xE000, 6},
		{`\uFFFF`, 0xFFFF, 6},
		{`\u0041rest`, 'A', 6},
		{`\uD800\uDC00`, 0x10000, 12},
		{`\ud800\udc00`, 0x10000, 12},
		{`\uD83D\uDE00`, 0x1F600, 12},
		{`\ud83D\uDe00tail`, 0x1F600, 12},
		{`\uDBFF\uDFFF`, 0x10FFFF, 12},
	}
	for c in good {
		r, n := spell.string_escape(raw_data(c.text), len(c.text))
		testing.expectf(t, r == c.r && n == c.n, "%q: got (U+%X, %d), want (U+%X, %d)", c.text, u32(r), n, u32(c.r), c.n)
	}

	// Non-JSON one-letter escapes (every non-`u`, non-RFC-8259 byte after `\`) are rejected.
	pair: [2]u8 = {'\\', 0}
	for b in 0 ..< 256 {
		if spell.ESCAPED[b] != 0 || b == 'u' {
			continue
		}
		pair[1] = u8(b)
		r, n := spell.string_escape(&pair[0], len(pair))
		if r != 0 || n != 0 {
			testing.expectf(t, false, "non-JSON escape 0x%02x: got (U+%X, %d)", b, u32(r), n)
			return
		}
	}

	// Truncated and negative `room` values never read past `room` and return `(0, 0)`.
	sample := `\uD83D\uDE00`
	for room in ([]int{-100, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}) {
		r, n := spell.string_escape(raw_data(sample), room)
		testing.expectf(t, r == 0 && n == 0, "sample room=%d: got (U+%X, %d)", room, u32(r), n)
	}
	bmp := `\u0041`
	for room in ([]int{-1, 0, 1, 2, 3, 4, 5}) {
		r, n := spell.string_escape(raw_data(bmp), room)
		testing.expectf(t, r == 0 && n == 0, "bmp room=%d: got (U+%X, %d)", room, u32(r), n)
	}
	short := `\n`
	for room in ([]int{-1, 0, 1}) {
		r, n := spell.string_escape(raw_data(short), room)
		testing.expectf(t, r == 0 && n == 0, "short room=%d: got (U+%X, %d)", room, u32(r), n)
	}

	bad := []string{
		// Non-JSON escapes (TOML / JSON5 / uppercase \U).
		`\'`,
		`\v`,
		`\0`,
		`\e`,
		`\x41`,
		`\U00000041`,
		// Bad hex in each digit of \uXXXX.
		`\ug000`,
		`\u0g00`,
		`\u00g0`,
		`\u000g`,
		`\u00/0`,
		`\u00:0`,
		// Lone high surrogates and malformed followers.
		`\uD800`,
		`\uDBFF`,
		`\uD800abc`,
		`\uD800\n`,
		`\uD800\\`,
		`\uD800\Udc00`,
		`\uD800\uDC0`,
		// Bad hex in low surrogate (including `dc0g`, whose raw `hex4` unit `0xDCFF` is in the low-surrogate range).
		`\uD800\udc0g`,
		`\uD800\ugC00`,
		`\uD800\uDg00`,
		`\uD800\uDCg0`,
		// High surrogate followed by non-low code unit.
		`\uD800\u0041`,
		`\uD800\uD7FF`,
		`\uD800\uE000`,
		`\uD800\uD800`,
		`\uD800\uDBFF`,
		// Lone low surrogates and reversed surrogate pairs.
		`\uDC00`,
		`\uDFFF`,
		`\uDC00\uD800`,
		`\uDFFF\uDBFF`,
	}
	for s in bad {
		r, n := spell.string_escape(raw_data(s), len(s))
		testing.expectf(t, r == 0 && n == 0, "%q: got (U+%X, %d), want (0, 0)", s, u32(r), n)
	}
}
