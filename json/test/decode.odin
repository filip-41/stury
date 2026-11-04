package json_tests

import "base:runtime"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:testing"
import spell "../../core/spell"
import core "../../core"
import json ".."

// Decoding a document's text and numbers: JSON5 forms, tolerances, the decoder's block edges, and number spellings.

// Checks `bytes_equal` on lengths 0 to 40, with the last byte differing and with the second slice a byte shorter.
@(test)
bytes_equal_table :: proc(t: ^testing.T) {
	a, b: [64]u8
	for i in 0 ..< len(a) {
		a[i] = u8(i * 31 + 7)
		b[i] = a[i]
	}
	for n in 0 ..= 40 {
		testing.expectf(t, spell.bytes_equal(a[:n], b[:n]), "length %d: equal", n)
		if n > 0 {
			b[n - 1] = a[n - 1] ~ 0x80
			testing.expectf(t, !spell.bytes_equal(a[:n], b[:n]), "length %d: last byte differs", n)
			b[n - 1] = a[n - 1]
			testing.expectf(t, !spell.bytes_equal(a[:n], b[:n - 1]), "length %d against %d", n, n - 1)
		}
	}
}

// For numbers of 3 to 19 digits with a point after `total / 2` of them, `number` returns `.Float` with the bits
// `strconv.parse_f64` returns.
@(test)
number_digit_count :: proc(t: ^testing.T) {
	state := u64(7)
	text: [32]u8
	for total in 3 ..= 19 {
		for _ in 0 ..< 100 {
			k := 0
			for i in 0 ..< total {
				// A point after half the digits keeps both runs non-empty and the significand at `total` digits.
				if i == total / 2 {
					text[k] = '.'
					k += 1
				}
				state = state * 6364136223846793005 + 1442695040888963407
				d := u8('0' + (state >> 33) % 10)
				if i == 0 && d == '0' {
					d = '1'
				}
				text[k] = d
				k += 1
			}
			src := string(text[:k])
			doc, err := build(src, .Json)
			testing.expectf(t, err.kind == .None, "%q: %v", src, err)
			if err.kind == .None {
				got := core.number(&doc, 0)
				want, ok := strconv.parse_f64(src)
				testing.expectf(t, ok && got.kind == .Float && got.bits == transmute(u64)want, "%q: %v, want %x", src, got, transmute(u64)want)
				core.destroy(&doc)
			}
		}
	}
}


// Checks JSON5's identifier and `\u`-escaped keys, single-quoted strings, `\x` and `\0` escapes, and number forms.
@(test)
json5 :: proc(t: ^testing.T) {
	src := `{'a': 'x', b: 'y', \u0063: 0x10}`
	doc, err := build(src, .Json5)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	for w in ([]struct {
		name: string,
		text: string,
	}{{"a", "x"}, {"b", "y"}, {"c", ""}}) {
		v, ok := core.member(&doc, 0, w.name)
		testing.expectf(t, ok, "key %q", w.name)
		if !ok {
			continue
		}
		if w.text != "" {
			s, _ := core.text_clone(&doc, v, context.temp_allocator)
			testing.expect_value(t, s, w.text)
		}
	}
	v, _ := core.member(&doc, 0, "c")
	num := core.number(&doc, v)
	testing.expect_value(t, num.kind, core.Number_Kind.Int)
	testing.expect_value(t, num.bits, u64(16))
	core.destroy(&doc)

	doc, err = build(`['\x41\0\n\'\\', "\uD83D\uDE00"]`, .Json5)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	buf: [256]u8
	s, ok := core.text(&doc, 1, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "A\x00\n'\\")
	s, ok = core.text(&doc, 2, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "\U0001F600")
	core.destroy(&doc)

	doc, err = build(`[+1, .5, 5., Infinity, -Infinity, NaN, -NaN, 0x10, -0x10]`, .Json5)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	want := []struct {
		kind: core.Number_Kind,
		bits: u64,
	}{
		{.Int, 1},
		{.Float, 0x3fe0000000000000},
		{.Float, 0x4014000000000000},
		{.Float, 0x7ff0000000000000},
		{.Float, 0xfff0000000000000},
		{.Float, 0x7ff8000000000000},
		{.Float, 0x7ff8000000000000},
		{.Int, 16},
		{.Int, ~u64(15)},
	}
	it := core.children(&doc, 0)
	first, _ := core.child_next(&it)
	for w, i in want {
		n := core.number(&doc, first + core.Node_Index(i))
		testing.expectf(t, n.kind == w.kind && n.bits == w.bits, "number %d: %v, want %v", i, n, w)
	}
	core.destroy(&doc)
}

// Under `Invalid_Utf8` and `Lone_Surrogate`, an ill-formed sequence or a lone surrogate half decodes to U+FFFD, one
// per maximal subpart.
@(test)
tolerated :: proc(t: ^testing.T) {
	doc, err := build("\"a\xffb\"", .Json, {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	buf: [64]u8
	s, ok := core.text(&doc, 0, buf[:])
	testing.expect(t, ok)
	testing.expectf(t, s == "a\uFFFDb", "got %x want %x", transmute([]u8)s, transmute([]u8)string("a\uFFFDb"))
	core.destroy(&doc)

	doc, err = build("\"\\uD800\"", .Json, {tolerate = {.Lone_Surrogate}})
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	s, ok = core.text(&doc, 0, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "\uFFFD")
	core.destroy(&doc)

	// `E1 80 41` is U+FFFD for the maximal subpart `E1 80`, then `A`.
	doc, err = build("'\xe1\x80A'", .Json5, {tolerate = {.Invalid_Utf8}})
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	s, ok = core.text(&doc, 0, buf[:])
	testing.expect(t, ok)
	testing.expectf(t, s == "\uFFFDA", "got %x want %x", transmute([]u8)s, transmute([]u8)string("\uFFFDA"))
	core.destroy(&doc)
}

// Checks a number's kind and bits at the i64 and u64 edges, at the binary64 edges, and against `strconv.parse_f64` on
// random digits.
@(test)
numbers :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		kind: core.Number_Kind,
		bits: u64,
	}
	cases := []Case{
		{"0", .Int, 0},
		{"-0", .Int, 0},
		{"9223372036854775807", .Int, u64(max(i64))},
		{"9223372036854775808", .Uint, u64(1) << 63},
		{"18446744073709551615", .Uint, max(u64)},
		{"18446744073709551616", .Float, 0x43f0000000000000},
		{"-9223372036854775808", .Int, u64(1) << 63},
		{"-9223372036854775809", .Float, 0xc3e0000000000000},
		{"0.1", .Float, 0x3fb999999999999a},
		{"1e308", .Float, 0x7fe1ccf385ebc8a0},
		{"1e309", .Wide, 0},
		{"-1e309", .Wide, 0},
		{"1e-400", .Float, 0},
		{"-1e-400", .Float, 0x8000000000000000},
		{"5e-324", .Float, 1},
		{"2.2250738585072014e-308", .Float, 0x0010000000000000},
		// A fraction of 78 digits saturates the token's recorded count, and `number` reads the whole span.
		{"-0.000000000000000000000000000000000000000000000000000000000000000000000000000001", .Float, 0xafbda48ce468e7c7},
		{"1.0000000000000000001e2", .Float, 0x4059000000000000},
		{"1e5000", .Wide, 0},
	}
	for c in cases {
		doc, err := build(c.text, .Json)
		testing.expectf(t, err.kind == .None, "%q: %v", c.text, err)
		if err.kind != .None {
			continue
		}
		n := core.number(&doc, 0)
		testing.expectf(t, n.kind == c.kind && n.bits == c.bits, "%q: %v, want %v", c.text, n, c)
		core.destroy(&doc)
	}

	long: [301]u8
	long[0] = '1'
	for i in 1 ..< len(long) {
		long[i] = '0'
	}
	long_doc, long_err := build(string(long[:]), .Json)
	testing.expect_value(t, long_err.kind, core.Document_Error_Kind.None)
	if long_err.kind == .None {
		testing.expect_value(t, core.number(&long_doc, 0).kind, core.Number_Kind.Wide)
		core.destroy(&long_doc)
	}

	// 20 to 40 random digits with an optional fraction and exponent: a `.Float` has `strconv.parse_f64`'s bits, and
	// `.Wide` is what `strconv.parse_f64` refuses.
	state := u64(1)
	digits: [40]u8
	for round in 0 ..< 2000 {
		length := 20 + int(round % 21)
		for i in 0 ..< length {
			state = state * 6364136223846793005 + 1442695040888963407
			digits[i] = u8('0' + (state >> 33) % 10)
		}
		if digits[0] == '0' {
			digits[0] = '1'
		}
		text: [64]u8
		k := copy(text[:], digits[:length])
		if round % 3 == 0 {
			text[k] = '.'
			k += 1
			for i := 0; i < 5; i += 1 {
				state = state * 6364136223846793005 + 1442695040888963407
				text[k] = u8('0' + (state >> 33) % 10)
				k += 1
			}
		}
		if round % 4 == 0 {
			text[k] = 'e'
			k += 1
			text[k] = '-' if round % 8 == 0 else '+'
			k += 1
			text[k] = '3'
			k += 1
			text[k] = '0'
			k += 1
			text[k] = '0'
			k += 1
		}
		src := string(text[:k])
		doc, err := build(src, .Json)
		testing.expectf(t, err.kind == .None, "%q: %v", src, err)
		if err.kind != .None {
			return
		}
		got := core.number(&doc, 0)
		want, ok := strconv.parse_f64(src)
		if !ok {
			testing.expectf(t, got.kind == .Wide, "%q: %v, strconv refused", src, got)
		} else {
			testing.expectf(t, got.kind == .Float && got.bits == transmute(u64)want, "%q: %v, want %x", src, got, transmute(u64)want)
		}
		core.destroy(&doc)
	}
}


// A number token's spelling has no `SPELLING_DECODE` bit, stays below bit 15, and `number_spelling_of` returns the
// spelling of each form.
@(test)
number_spelling_bits :: proc(t: ^testing.T) {
	doc, err := build(`[0, 1.5, 1e2, 0x10, Infinity, NaN, +1, .5, 5.]`, .Json5)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	want := []json.Number_Spelling{.Json, .Json, .Json, .Hex, .Infinity, .Nan, .Decimal, .Decimal, .Decimal}
	it := core.children(&doc, 0)
	i := 0
	for {
		v, more := core.child_next(&it)
		if !more {
			break
		}
		n := doc.nodes[v]
		testing.expect_value(t, n.kind, core.Kind.Number)
		testing.expect_value(t, n.spelling & core.SPELLING_DECODE, 0)
		testing.expect(t, n.spelling < 1 << 15)
		testing.expect_value(t, json.number_spelling_of(n.spelling), want[i])
		i += 1
	}
	testing.expect_value(t, i, len(want))
}

// `text` writes a decode into the caller's buffer and never allocates, and returns false when the buffer is too short.
// `text_clone` always allocates, and the allocation is exactly the string the caller frees with `delete`, for a decoded
// text and for one that is its source.
@(test)
text_owned :: proc(t: ^testing.T) {
	doc, err := build(`"\u0041"`, .Json)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	buf: [8]u8
	s, ok := core.text(&doc, 0, buf[:])
	testing.expect(t, ok && s == "A")
	_, ok = core.text(&doc, 0, nil)
	testing.expect(t, !ok)
	_, ok = core.text(&doc, 0, buf[:0])
	testing.expect(t, !ok)

	p: Track_Alloc = {inner = context.temp_allocator}
	alloc := track_allocator(&p)
	s, ok = core.text_clone(&doc, 0, alloc)
	testing.expectf(t, ok && s == "A", "clone: %q %v", s, ok)
	testing.expect_value(t, p.alloc_size, len(s))
	delete(s, alloc)
	testing.expect_value(t, p.free_size, len(s))

	plain, perr := build(`"abc"`, .Json)
	defer core.destroy(&plain)
	if !testing.expectf(t, perr.kind == .None, "build: %v", perr) {
		return
	}
	s, ok = core.text(&plain, 0, nil)
	testing.expect(t, ok && s == "abc")
	p.alloc_size, p.free_size = 0, 0
	s, ok = core.text_clone(&plain, 0, alloc)
	testing.expect(t, ok && s == "abc")
	testing.expect_value(t, p.alloc_size, len(s))
	delete(s, alloc)
	testing.expect_value(t, p.free_size, len(s))
}

// A `Track_Alloc` records the size of the last allocation and of the last free.
Track_Alloc :: struct {
	inner:      runtime.Allocator,
	alloc_size: int,
	free_size:  int,
}

track_allocator_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	p := (^Track_Alloc)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		p.alloc_size = size
	case .Free:
		p.free_size = old_size
	case .Resize, .Resize_Non_Zeroed:
		p.alloc_size = size
	case .Free_All, .Query_Features, .Query_Info:
	}
	return p.inner.procedure(p.inner.data, mode, size, alignment, old_memory, old_size, loc)
}

track_allocator :: proc(p: ^Track_Alloc) -> runtime.Allocator {
	return {procedure = track_allocator_proc, data = p}
}

// Checks strings that cross the decoder's 64-byte block edge: an escape at the edge, a surrogate pair across it,
// `\u0000`, a string of escapes only, and plain strings of 63, 64 and 65 bytes.
@(test)
decode_edges :: proc(t: ^testing.T) {
	buf: [256]u8
	expect_decode :: proc(t: ^testing.T, src: string, want: []u8, buf: []u8) {
		doc, err := build(src, .Json)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "%q: %v", src, err) {
			return
		}
		s, ok := core.text(&doc, 0, buf)
		testing.expectf(t, ok && string(want) == s, "%q: %q, want %q", src, s, want)
	}

	// 63 `a` bytes then `\n`: the escape starts at byte 64, the second block's first byte.
	esc: [128]u8
	esc[0] = '"'
	for i in 1 ..= 63 {
		esc[i] = 'a'
	}
	esc[64] = '\\'
	esc[65] = 'n'
	esc[66] = '"'
	want: [64]u8
	for i in 0 ..< 63 {
		want[i] = 'a'
	}
	want[63] = '\n'
	expect_decode(t, string(esc[:67]), want[:64], buf[:])

	// A surrogate pair whose second escape starts past byte 64.
	for i in 1 ..= 58 {
		esc[i] = 'a'
	}
	copy(esc[59:], `\ud83d\ude00`)
	esc[71] = '"'
	for i in 0 ..< 58 {
		want[i] = 'a'
	}
	copy(want[58:], "\xf0\x9f\x98\x80")
	expect_decode(t, string(esc[:72]), want[:62], buf[:])

	expect_decode(t, `"\u0000"`, []u8{0}, buf[:])
	expect_decode(t, `"\n\t\r\"\\\/\b\f"`, []u8{'\n', '\t', '\r', '"', '\\', '/', '\b', '\f'}, buf[:])

	// Plain strings of 63, 64 and 65 bytes, and each with `\t` as its last byte.
	for n in 63 ..= 65 {
		plain: [80]u8
		plain[0] = '"'
		for i in 1 ..= n {
			plain[i] = 'b'
		}
		plain[n + 1] = '"'
		got: [80]u8
		for i in 0 ..< n {
			got[i] = 'b'
		}
		expect_decode(t, string(plain[:n + 2]), got[:n], buf[:])

		escaped: [80]u8
		escaped[0] = '"'
		for i in 1 ..< n {
			escaped[i] = 'b'
		}
		copy(escaped[n:], `\t"`)
		got[n - 1] = '\t'
		expect_decode(t, string(escaped[:n + 3]), got[:n], buf[:])
	}
}

// `key_equals` decodes a key whose `\n` escape starts 64 bytes into the key's span, and compares 65 decoded bytes.
@(test)
key_equals_escaped :: proc(t: ^testing.T) {
	src: [256]u8
	src[0] = '{'
	src[1] = '"'
	for i in 2 ..= 65 {
		src[i] = 'k'
	}
	copy(src[66:], `\n":1}`)
	doc, err := build(string(src[:72]), .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	name: [65]u8
	for i in 0 ..< 64 {
		name[i] = 'k'
	}
	name[64] = '\n'
	testing.expect(t, core.key_equals(&doc, 1, string(name[:65])))
	testing.expect(t, !core.key_equals(&doc, 1, "kk"))
}

// Under `Invalid_Utf8`, a key holding `\xff` decodes to `a\uFFFDb`, and `key_equals` and `member` find it by that text.
@(test)
tolerated_key :: proc(t: ^testing.T) {
	src := "{\"a\xffb\":0}"
	doc, err := build(src, .Json, {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	buf: [16]u8
	k, ok := core.text(&doc, 1, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, k, "a\uFFFDb")
	testing.expect(t, core.key_equals(&doc, 1, k))
	v, found := core.member(&doc, 0, k)
	testing.expect(t, found)
	testing.expect_value(t, v, 2)
}

// Reads `text` into a buffer as long as the token's span and checks that it allocates nothing, for the scalar decoder
// and the block decoder. The decoded text is no longer than the span.
@(test)
decode_into_token_sized_buffer :: proc(t: ^testing.T) {
	arena: mem.Arena
	backing := make([]u8, 1 << 16, context.allocator)
	defer delete(backing)
	mem.arena_init(&arena, backing)
	alloc := mem.arena_allocator(&arena)
	texts := []string{`"\u0041"`, `"\uD800"`}
	for src in texts {
		doc, err := json.build(transmute([]u8)src, .Json, {tolerate = {.Lone_Surrogate}}, false, alloc)
		if !testing.expectf(t, err.kind == .None, "%q: %v", src, err) {
			continue
		}
		before := arena.offset
		buf: [16]u8
		s, ok := core.text(&doc, 0, buf[:len(src) - 2])
		testing.expectf(t, ok, "%q: no text", src)
		testing.expectf(t, arena.offset == before, "%q: allocated %d bytes", src, arena.offset - before)
		if src == texts[0] {
			testing.expect_value(t, s, "A")
		}
		core.destroy(&doc)
	}

	// The block decoder on a string of 300 `x` bytes and `\u0041`, past its 256-byte split.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_byte(&b, '"')
	for _ in 0 ..< 300 {
		strings.write_byte(&b, 'x')
	}
	strings.write_string(&b, `\u0041"`)
	src := strings.to_string(b)
	doc, err := json.build(transmute([]u8)src, .Json, {}, false, alloc)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "long: %v", err) {
		return
	}
	before := arena.offset
	buf: [400]u8
	s, ok := core.text(&doc, 0, buf[:len(src) - 2])
	testing.expect(t, ok)
	testing.expectf(t, arena.offset == before, "long: allocated %d bytes", arena.offset - before)
	testing.expect_value(t, len(s), 301)
	testing.expect_value(t, s[300], 'A')
}


// A leading zero in a multi-digit integer run is a digit, not the zero of a `0.<fraction>` significand.
@(test)
number_decimal_leading_zero :: proc(t: ^testing.T) {
	for src in ([]string{"012345678901234567890123456789", "0012345678901234567890123456789"}) {
		got := spell.number_decimal(transmute([]u8)src, 0, u64(len(src)))
		want, ok := strconv.parse_f64(src)
		testing.expectf(t, ok && got.kind == .Float && got.bits == transmute(u64)want, "%q: %v, want %x", src, got, transmute(u64)want)
	}
}

