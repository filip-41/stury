package write_tests

import "core:bytes"
import "core:fmt"
import "core:io"
import "core:math/rand"
import "core:slice"
import "core:testing"
import "core:unicode/utf8"
import "stury:json"
import "stury:testkit"

// JSON's string writer against a model that goes one byte at a time: a string of any bytes is read back from a source
// that spells it, written, and compared with the text the fewest escapes give. The escapes are the quote, the
// backslash and the control bytes, each with its shortest spelling, a control byte with no short one as `\u00xx` in
// lowercase. Every other byte is written as itself. Ill-formed UTF-8 is read under `.Invalid_Utf8`, each maximal
// subpart as U+FFFD.

@(private = "file")
REPLACEMENT :: "\xEF\xBF\xBD"

// The text `s` reads as: its bytes, with each maximal subpart of an ill-formed sequence replaced by U+FFFD. Also whether
// `s` was well formed.
@(private = "file")
model_text :: proc(s: []u8) -> (text: [dynamic]u8, whole: bool) {
	whole = true
	for i := 0; i < len(s); {
		size := model_sequence(s[i:])
		if size < 0 {
			whole = false
			append(&text, REPLACEMENT)
			i += -size
			continue
		}
		append(&text, ..s[i:i + size])
		i += size
	}
	return
}

@(private = "file")
well_formed :: proc(s: []u8) -> bool {
	for i := 0; i < len(s); {
		size := model_sequence(s[i:])
		if size < 0 {
			return false
		}
		i += size
	}
	return true
}

// The length of the well-formed sequence at the start of `s`, or minus the length of its maximal ill-formed subpart.
@(private = "file")
model_sequence :: proc(s: []u8) -> int {
	lead := s[0]
	need, lo, hi := 0, u8(0x80), u8(0xBF)
	switch {
	case lead < 0x80:
		return 1
	case lead >= 0xC2 && lead <= 0xDF:
		need = 1
	case lead == 0xE0:
		need, lo = 2, 0xA0
	case lead >= 0xE1 && lead <= 0xEF:
		need = 2
		if lead == 0xED {
			hi = 0x9F
		}
	case lead == 0xF0:
		need, lo = 3, 0x90
	case lead >= 0xF1 && lead <= 0xF3:
		need = 3
	case lead == 0xF4:
		need, hi = 3, 0x8F
	case:
		return -1
	}
	for k in 1 ..= need {
		if k >= len(s) || s[k] < lo || s[k] > hi {
			return -k
		}
		lo, hi = 0x80, 0xBF
	}
	return need + 1
}

@(private = "file")
append_unit :: proc(text: ^[dynamic]u8, unit: u32, upper: bool) {
	digits := "0123456789ABCDEF" if upper else "0123456789abcdef"
	append(text, '\\', 'u', digits[unit >> 12 & 15], digits[unit >> 8 & 15], digits[unit >> 4 & 15], digits[unit & 15])
}

// The JSON string `s` reads as, written with the fewest escapes. `s` must be well formed.
@(private = "file")
model_string :: proc(s: []u8) -> [dynamic]u8 {
	text: [dynamic]u8
	append(&text, '"')
	for b in s {
		switch b {
		case '"':
			append(&text, '\\', '"')
		case '\\':
			append(&text, '\\', '\\')
		case '\b':
			append(&text, '\\', 'b')
		case '\t':
			append(&text, '\\', 't')
		case '\n':
			append(&text, '\\', 'n')
		case '\f':
			append(&text, '\\', 'f')
		case '\r':
			append(&text, '\\', 'r')
		case 0 ..< 0x20:
			append_unit(&text, u32(b), false)
		case:
			append(&text, b)
		}
	}
	append(&text, '"')
	return text
}

Spelling :: enum {
	// Multibyte text as it is, with only the escapes a string must have.
	Raw,
	// A `A` first, so the string is an escaped one, and every byte past ASCII as an uppercase `\u` escape.
	Escaped,
}

// A JSON string that reads as `s`, which is well formed under `.Escaped`. Returns the text the string reads as, with
// `.Escaped`'s `A` in front.
@(private = "file")
spell_string :: proc(s: []u8, spelling: Spelling) -> (source: [dynamic]u8) {
	append(&source, '"')
	if spelling == .Escaped {
		append(&source, `A`)
	}
	for i := 0; i < len(s); {
		size := model_sequence(s[i:])
		if size < 0 {
			append(&source, ..s[i:i - size])
			i += -size
			continue
		}
		switch b := s[i]; {
		case b == '"':
			append(&source, '\\', '"')
		case b == '\\':
			append(&source, '\\', '\\')
		case b < 0x20:
			append_unit(&source, u32(b), true)
		case b < 0x80 || spelling == .Raw:
			append(&source, ..s[i:i + size])
		case:
			cp := u32(b & (0x7F >> u32(size)))
			for c in s[i + 1:i + size] {
				cp = cp << 6 | u32(c & 0x3F)
			}
			if cp >= 0x10000 {
				append_unit(&source, 0xD800 + (cp - 0x10000) >> 10, true)
				append_unit(&source, 0xDC00 + (cp - 0x10000) & 0x3FF, true)
			} else {
				append_unit(&source, cp, true)
			}
		}
		i += size
	}
	append(&source, '"')
	return
}

// The texts a string of `s` is written in, whole and indented, as the model gives them.
@(private = "file")
Expected :: struct {
	array_source, object_source: [dynamic]u8,
	one, compact, indented:     [dynamic]u8,
}

@(private = "file")
expected_of :: proc(s: []u8, spelling: Spelling) -> (e: Expected) {
	text, _ := model_text(s)
	defer delete(text)
	if spelling == .Escaped {
		inject_at(&text, 0, 'A')
	}
	spelled := spell_string(s, spelling)
	defer delete(spelled)
	written := model_string(text[:])
	defer delete(written)
	for x in ([]string{"[", string(spelled[:]), ",", string(spelled[:]), "]"}) {
		append(&e.array_source, x)
	}
	for x in ([]string{"{", string(spelled[:]), ":", string(spelled[:]), "}"}) {
		append(&e.object_source, x)
	}
	append(&e.one, ..written[:])
	w := string(written[:])
	for x in ([]string{"[", w, ",", w, "]"}) {
		append(&e.compact, x)
	}
	for x in ([]string{"[\n  ", w, ",\n  ", w, "\n]"}) {
		append(&e.indented, x)
	}
	return
}

@(private = "file")
expected_destroy :: proc(e: ^Expected) {
	delete(e.array_source)
	delete(e.object_source)
	delete(e.one)
	delete(e.compact)
	delete(e.indented)
}

// Checks the writer against the model on `s`: as the first of two strings of an array, so the text before it stays,
// and as a key and a value, in both spellings that read as `s`.
@(private = "file")
check :: proc(t: ^testing.T, s: []u8, keys := false, loc := #caller_location) -> bool {
	whole := well_formed(s)
	for spelling in Spelling {
		if spelling == .Escaped && !whole {
			continue
		}
		e := expected_of(s, spelling)
		defer expected_destroy(&e)
		doc, err := json.build(e.array_source[:], .Json, {tolerate = {.Invalid_Utf8}})
		defer json.destroy(&doc)
		if !testing.expectf(t, err == nil, "% x read as %q: %v", s, e.array_source[:], err, loc = loc) {
			return false
		}
		compact, _, cerr := json.write(&doc)
		defer delete(compact)
		indented, _, ierr := json.write(&doc, .Json, {indent = 2})
		defer delete(indented)
		if !testing.expectf(t, cerr == nil && ierr == nil && string(compact) == string(e.compact[:]) && string(indented) == string(e.indented[:]), "% x as %v: %q %v, %q %v, want %q", s, spelling, compact, cerr, indented, ierr, e.compact[:], loc = loc) {
			return false
		}
		if !keys {
			continue
		}
		pair, perr := json.build(e.object_source[:], .Json, {tolerate = {.Invalid_Utf8}})
		defer json.destroy(&pair)
		keyed, _, kerr := json.write(&pair)
		defer delete(keyed)
		want := fmt.tprintf("{{%s:%s}}", e.one[:], e.one[:])
		if !testing.expectf(t, perr == nil && kerr == nil && string(keyed) == want, "% x as a key, %v: %q %v %v, want %q", s, spelling, keyed, perr, kerr, want, loc = loc) {
			return false
		}
	}
	return true
}

// Whether a position within two bytes of a 16-byte block edge or of an end, so the sweeps cover each edge without every
// offset.
@(private = "file")
near_block_edge :: proc(n: int) -> bool {
	return n <= 2 || n % 16 <= 2 || n % 16 >= 14
}

// Every byte value at every offset near a block edge of a string of ASCII and of two-byte characters.
@(test)
strings_every_byte_at_every_offset :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for fill in ([]string{"a", "\xc3\xa9"}) {
		for length in 0 ..= 80 {
			if !near_block_edge(length) {
				continue
			}
			s := make([]u8, length)
			defer delete(s)
			for &b, i in s {
				b = fill[i % len(fill)]
			}
			for at in 0 ..< length {
				if !near_block_edge(at) && !near_block_edge(length - 1 - at) {
					continue
				}
				saved := s[at]
				for v in 0 ..< 256 {
					s[at] = u8(v)
					if !check(t, s) {
						return
					}
				}
				s[at] = saved
			}
		}
	}
}

// A string of every length up to 200 and a byte that ends a plain run put at the offsets the blocks of 16, 32 and 64
// bytes end at.
@(test)
strings_lengths_around_the_block_sizes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for length in 0 ..= 200 {
		s := make([]u8, length)
		defer delete(s)
		slice.fill(s, 'x')
		if !check(t, s, keys = length % 16 < 2) {
			return
		}
		for stop in ([]u8{'"', '\\', '\n', 0x00, 0x1f, 0x7f}) {
			for at in ([]int{0, 1, 14, 15, 16, 17, 31, 32, 62, 63, 64, 65, 79, 80, 81, 127, 128, 129, 191}) {
				if at < length {
					s[at] = stop
					if !check(t, s) {
						return
					}
					s[at] = 'x'
				}
			}
		}
	}
}

// A character that crosses a block edge, an escape that does, and a run of escapes that fills blocks, at every offset.
@(test)
strings_characters_and_escapes_across_blocks :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pieces := [?]string{"\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80", "\xe2\x80\xa8", "<&>", "\"\\\n", "\x01\x02\x03\x04\x05\x06\x07\x08", "\x7f"}
	for piece in pieces {
		for before in 0 ..< 70 {
			for after in ([]int{0, 1, 15, 16, 17, 63, 64, 65, 100}) {
				s := make([]u8, before + len(piece) + after)
				defer delete(s)
				slice.fill(s, 'a')
				copy(s[before:], piece)
				if !check(t, s) {
					return
				}
			}
		}
	}
}

// Ill-formed UTF-8 at every offset reads as U+FFFD for each maximal subpart and is written as that, with the bytes
// around it as they were.
@(test)
strings_ill_formed_text_at_every_offset :: proc(t: ^testing.T) {
	testkit.deadline(t)
	bad := [?]string{
		"\x80", "\xbf", "\xc0\x80", "\xc1\xbf", "\xc2", "\xc2\x7f", "\xe0\x80\x80", "\xe0\x9f\xbf", "\xe0\xa0", "\xed\xa0\x80",
		"\xed\xbf\xbf", "\xef\xbf", "\xf0\x80\x80\x80", "\xf0\x8f\xbf\xbf", "\xf0\x90\x80", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80",
		"\xf8\x88\x80\x80\x80", "\xff", "\xfe",
	}
	for piece in bad {
		for before in 0 ..< 70 {
			for after in ([]int{0, 1, 14, 15, 16, 17, 40, 70}) {
				s := make([]u8, before + len(piece) + after)
				defer delete(s)
				slice.fill(s, 'a')
				copy(s[before:], piece)
				if !check(t, s) {
					return
				}
			}
		}
	}
}

// A lead byte at the end of a block with ASCII after it is an ill-formed sequence that the next block of a wide loop
// must still find.
@(test)
strings_sequence_cut_at_a_block_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for lead in ([?]u8{0xC3, 0xE2, 0xF0}) {
		for blocks in 1 ..= 5 {
			for shift in -2 ..= 1 {
				s := make([]u8, 64 * blocks + 300)
				defer delete(s)
				slice.fill(s, 'a')
				s[64 * blocks - 1 + shift] = lead
				if !check(t, s) {
					return
				}
			}
		}
	}
}

// Pieces of every kind in random order and length: short strings, and strings past the sizes a buffer is reserved in.
@(test)
strings_random_match_the_model :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x57121)
	pieces := [?]string{
		"a", "z", " ", "0", "~", "\x7f", "\"", "\\", "\n", "\x00", "\x1f", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80", "\xe2\x80\xa9",
		"<", "&", "\x80", "\xc0", "\xf5",
	}
	lengths := [?]int{0, 1, 7, 15, 16, 17, 40, 64, 100, 300, 511, 512, 513, 700, 1500, 4078, 4079, 5000, 70000}
	for length in lengths {
		cases := testkit.rounds(400 if length < 700 else 6)
		for _ in 0 ..< cases {
			noisy := rand.int_max(3) == 0
			s := make([dynamic]u8, 0, length + 4)
			defer delete(s)
			for len(s) < length {
				pick := rand.int_max(len(pieces)) if noisy || rand.int_max(40) == 0 else rand.int_max(4)
				if pick >= 16 && !noisy && rand.int_max(8) != 0 {
					pick = 0
				}
				append(&s, pieces[pick])
			}
			if !check(t, s[:], keys = length < 100) {
				return
			}
		}
	}
}

// A long string of every kind of escape is written through the buffer of a sink, which it fills many times.
@(test)
strings_written_through_a_sink :: proc(t: ^testing.T) {
	testkit.deadline(t)
	s := make([]u8, 300_000)
	defer delete(s)
	pattern := "ab\n\"\\\x01\xc3\xa9<qq"
	for &b, i in s {
		b = pattern[i % len(pattern)]
	}
	text, _ := model_text(s)
	defer delete(text)
	inject_at(&text, 0, 'A')
	want := model_string(text[:])
	defer delete(want)
	source := spell_string(s, .Escaped)
	defer delete(source)
	doc, err := json.build(source[:], .Json, {tolerate = {.Invalid_Utf8}})
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	sink: bytes.Buffer
	defer bytes.buffer_destroy(&sink)
	_, werr := json.write_to(bytes.buffer_to_stream(&sink), &doc)
	testing.expect_value(t, werr, nil)
	testing.expect(t, string(bytes.buffer_to_bytes(&sink)) == string(want[:]))
	buffered, _, berr := json.write(&doc)
	defer delete(buffered)
	testing.expect_value(t, berr, nil)
	testing.expect(t, string(buffered) == string(want[:]))
}

// Strings one after another keep every byte of each, whatever the buffer holds at the start of the next.
@(test)
strings_after_strings_keep_every_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	words := [?]string{"", "key", "a longer key with spaces", "line\nbreak and more than sixteen bytes", "caf\xc3\xa9"}
	source: [dynamic]u8
	defer delete(source)
	want: [dynamic]u8
	defer delete(want)
	append(&source, '[')
	append(&want, '[')
	for i in 0 ..< 5000 {
		w := words[i % len(words)]
		if i > 0 {
			append(&source, ',')
			append(&want, ',')
		}
		spelled := spell_string(transmute([]u8)w, .Escaped)
		append(&source, ..spelled[:])
		delete(spelled)
		text := make([dynamic]u8)
		append(&text, 'A')
		append(&text, w)
		written := model_string(text[:])
		append(&want, ..written[:])
		delete(written)
		delete(text)
	}
	append(&source, ']')
	append(&want, ']')
	doc, err := json.build(source[:])
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	got, _, werr := json.write(&doc)
	defer delete(got)
	testing.expect_value(t, werr, nil)
	testing.expect(t, string(got) == string(want[:]))
}

// A sink that refuses the bytes of a long string ends the write with the sink's error.
@(test)
strings_a_refusing_sink_fails_the_write :: proc(t: ^testing.T) {
	testkit.deadline(t)
	s := make([]u8, 200_000)
	defer delete(s)
	slice.fill(s, 'a')
	source := spell_string(s, .Escaped)
	defer delete(source)
	doc, _ := json.build(source[:])
	defer json.destroy(&doc)
	closed := io.Stream {
		procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
			return 0, .Permission_Denied if mode == .Write else .Unknown
		},
	}
	_, err := json.write_to(closed, &doc)
	testing.expect_value(t, err, json.Write_Error(io.Error.Permission_Denied))
}

// A string that ends at an unmapped page is written whole at every length: no read passes its last byte.
@(test)
strings_at_the_end_of_a_page :: proc(t: ^testing.T) {
	testkit.deadline(t)
	fence: testkit.Fence
	defer testkit.fence_release(&fence)
	body := make([]u8, 400)
	defer delete(body)
	for &b, i in body {
		b = 'a' if i % 50 != 49 else '"'
	}
	for n in 0 ..< len(body) {
		for spelling in Spelling {
			spelled := spell_string(body[:n], spelling)
			defer delete(spelled)
			text, _ := model_text(body[:n])
			defer delete(text)
			if spelling == .Escaped {
				inject_at(&text, 0, 'A')
			}
			want := model_string(text[:])
			defer delete(want)
			doc, err := json.build(testkit.fence_copy(&fence, spelled[:]))
			if !testing.expectf(t, err == nil, "length %d: %v", n, err) {
				return
			}
			got, _, werr := json.write(&doc)
			testing.expectf(t, werr == nil && string(got) == string(want[:]), "length %d as %v: %q %v", n, spelling, got, werr)
			delete(got)
			json.destroy(&doc)
		}
	}
}

// The model agrees with the standard library about which texts are well formed, so a sweep is not testing an invented
// rule.
@(test)
strings_model_agrees_with_the_decoder :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x4d0d)
	for _ in 0 ..< testkit.rounds(20_000) {
		s: [6]u8
		for &b in s {
			b = u8(rand.int_max(256))
		}
		n := 1 + rand.int_max(len(s))
		whole := well_formed(s[:n])
		testing.expectf(t, whole == utf8.valid_string(string(s[:n])), "% x", s[:n])
	}
}
