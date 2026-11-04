package json_tests

import "core:bytes"
import "core:io"
import "core:math/rand"
import "core:testing"
import core "../../core"
import write "../../core/write"
import json ".."
import walktest "../../walktest"

// The JSON string writer against a model that goes one byte at a time.

// Returns the length of the valid UTF-8 sequence at the start of `s` and its code point, or 0 for a fault. Written from the
// table of well-formed byte sequences in RFC 3629, not from the writer's tables.
@(private = "file")
model_decode :: proc(s: []u8) -> (size: int, cp: u32) {
	at :: proc(s: []u8, i: int, lo, hi: u8) -> bool {
		return i < len(s) && lo <= s[i] && s[i] <= hi
	}
	b := s[0]
	switch {
	case b <= 0x7F:
		return 1, u32(b)
	case 0xC2 <= b && b <= 0xDF:
		if at(s, 1, 0x80, 0xBF) {
			return 2, u32(b & 0x1F) << 6 | u32(s[1] & 0x3F)
		}
	case b == 0xE0 || 0xE1 <= b && b <= 0xEF:
		lo, hi := u8(0x80), u8(0xBF)
		if b == 0xE0 {
			lo = 0xA0
		} else if b == 0xED {
			hi = 0x9F
		}
		if at(s, 1, lo, hi) && at(s, 2, 0x80, 0xBF) {
			return 3, u32(b & 0x0F) << 12 | u32(s[1] & 0x3F) << 6 | u32(s[2] & 0x3F)
		}
	case 0xF0 <= b && b <= 0xF4:
		lo, hi := u8(0x80), u8(0xBF)
		if b == 0xF0 {
			lo = 0x90
		} else if b == 0xF4 {
			hi = 0x8F
		}
		if at(s, 1, lo, hi) && at(s, 2, 0x80, 0xBF) && at(s, 3, 0x80, 0xBF) {
			return 4, u32(b & 0x07) << 18 | u32(s[1] & 0x3F) << 12 | u32(s[2] & 0x3F) << 6 | u32(s[3] & 0x3F)
		}
	}
	return 0, 0
}

@(private = "file")
model_unit :: proc(text: ^[dynamic]u8, unit: u32) {
	hex := "0123456789abcdef"
	append(text, '\\', 'u', hex[unit >> 12 & 15], hex[unit >> 8 & 15], hex[unit >> 4 & 15], hex[unit & 15])
}

// Returns the text the JSON string of `s` is, or false when `s` is not UTF-8.
@(private = "file")
model_string :: proc(s: []u8, opts: core.Write_Options) -> (text: [dynamic]u8, ok: bool) {
	append(&text, '"')
	for i := 0; i < len(s); {
		size, cp := model_decode(s[i:])
		if size == 0 {
			return text, false
		}
		switch {
		case cp == '"':
			append(&text, '\\', '"')
		case cp == '\\':
			append(&text, '\\', '\\')
		case cp == '\b':
			append(&text, '\\', 'b')
		case cp == '\t':
			append(&text, '\\', 't')
		case cp == '\n':
			append(&text, '\\', 'n')
		case cp == '\f':
			append(&text, '\\', 'f')
		case cp == '\r':
			append(&text, '\\', 'r')
		case cp < 0x20:
			model_unit(&text, cp)
		case opts.escape_html && (cp == '<' || cp == '>' || cp == '&' || cp == 0x2028 || cp == 0x2029):
			model_unit(&text, cp)
		case opts.ascii && cp >= 0x7f || opts.escape_del && cp == 0x7f:
			if cp >= 0x10000 {
				model_unit(&text, 0xD800 + (cp - 0x10000) >> 10)
				model_unit(&text, 0xDC00 + (cp - 0x10000) & 0x3FF)
			} else {
				model_unit(&text, cp)
			}
		case:
			append(&text, ..s[i:i + size])
		}
		i += size
	}
	append(&text, '"')
	return text, true
}

@(private = "file")
OPTION_SETS := [?]core.Write_Options{{}, {ascii = true}, {escape_html = true}, {ascii = true, escape_html = true}, {escape_del = true}, {escape_del = true, escape_html = true}}

// Writes `s` after `lead` bytes of an earlier text and returns the whole output, which the caller frees.
@(private = "file")
written :: proc(s: []u8, opts: core.Write_Options, lead := 0) -> (text: []u8, kind: core.Typed_Error_Kind) {
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill)
	for _ in 0 ..< lead {
		write.room(&out, 1)[0] = ','
		out.cursor += 1
	}
	kind = json.put_string(&out, string(s), opts)
	bytes, err := write.finish(&out)
	if kind == .None {
		kind = err.kind
	}
	return ([^]u8)(rawptr(raw_data(bytes)))[:len(bytes)], kind
}

// Checks the writer against the model on `s`, with exact-size copies so a read past the string is a fault under the
// address sanitizer. The text before the cursor must stay.
@(private = "file")
check :: proc(t: ^testing.T, s: []u8, loc := #caller_location) {
	for opts in OPTION_SETS {
		want, ok := model_string(s, opts)
		defer delete(want)
		for lead in ([]int{0, 3}) {
			all, kind := written(s, opts, lead)
			defer delete(all)
			got := all[lead:] if len(all) >= lead else nil
			if !ok {
				testing.expectf(t, kind == .Bad_Utf8, "% x: %v, want Bad_Utf8", s, kind, loc = loc)
			} else if !testing.expectf(t, kind == .None && string(got) == string(want[:]), "% x %v: %q (%v), want %q", s, opts, got, kind, want[:], loc = loc) {
				return
			}
		}
	}
}

@(test)
every_byte_at_every_offset :: proc(t: ^testing.T) {
	for fill in ([]string{"a", "\xc3\xa9"}) {
		for length in 0 ..= 80 {
			s := make([]u8, length)
			defer delete(s)
			for &b, i in s {
				b = fill[i % len(fill)]
			}
			for at in 0 ..< length {
				saved := s[at]
				for v in 0 ..< 256 {
					s[at] = u8(v)
					check(t, s)
				}
				s[at] = saved
			}
		}
	}
}

@(test)
lengths_around_the_block_sizes :: proc(t: ^testing.T) {
	for length in 0 ..= 200 {
		s := make([]u8, length)
		defer delete(s)
		for &b in s {
			b = 'x'
		}
		check(t, s)
		for stop in ([]u8{'"', '\\', '\n', 0x00, 0x1f, 0x7f}) {
			for at in ([]int{0, 1, 14, 15, 16, 17, 31, 32, 62, 63, 64, 65, 79, 80, 81, 127, 128, 129, 191}) {
				if at < length {
					s[at] = stop
					check(t, s)
					s[at] = 'x'
				}
			}
		}
	}
}

// A character that crosses a block edge, an escape that does, and a run of escapes that fills blocks, at every offset.
@(test)
characters_and_escapes_across_blocks :: proc(t: ^testing.T) {
	pieces := [?]string{"\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80", "\xe2\x80\xa8", "<&>", "\"\\\n", "\x01\x02\x03\x04\x05\x06\x07\x08"}
	for piece in pieces {
		for before in 0 ..< 70 {
			for after in ([]int{0, 1, 15, 16, 17, 63, 64, 65, 100}) {
				s := make([]u8, before + len(piece) + after)
				defer delete(s)
				for &b in s {
					b = 'a'
				}
				copy(s[before:], piece)
				check(t, s)
			}
		}
	}
}

@(test)
invalid_utf8_is_refused_at_every_offset :: proc(t: ^testing.T) {
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
				for &b in s {
					b = 'a'
				}
				copy(s[before:], piece)
				for opts in OPTION_SETS {
					text, kind := written(s, opts)
					delete(text)
					testing.expectf(t, kind == .Bad_Utf8, "% x at %d: %v", piece, before, kind)
				}
			}
		}
	}
}

// Pieces of every kind in random order and length, short strings and strings past the reservation sizes.
@(test)
random_strings_match_the_model :: proc(t: ^testing.T) {
	state := rand.create(11)
	context.random_generator = rand.default_random_generator(&state)
	pieces := [?]string{
		"a", "z", " ", "0", "~", "\x7f", "\"", "\\", "\n", "\x00", "\x1f", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80", "\xe2\x80\xa9",
		"<", "&", "\x80", "\xc0", "\xf5",
	}
	lengths := [?]int{0, 1, 7, 15, 16, 17, 40, 64, 100, 300, 511, 512, 513, 700, 1500, 4078, 4079, 5000, 70000}
	for length in lengths {
		cases := 400 if length < 700 else 6
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
			check(t, s[:])
		}
	}
}

@(test)
valid_text_with_every_escape_writes_through_a_stream :: proc(t: ^testing.T) {
	s := make([]u8, 300_000)
	defer delete(s)
	pattern := "ab\n\"\\\x01\xc3\xa9<qq"
	for &b, i in s {
		b = pattern[i % len(pattern)]
	}
	// The cuts the pattern makes may split a character, so the model decides what the stream must hold.
	want, ok := model_string(s, {})
	defer delete(want)
	sink: bytes.Buffer
	defer bytes.buffer_destroy(&sink)
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, stream = bytes.buffer_to_stream(&sink))
	kind := json.put_string(&out, string(s))
	_, err := write.finish(&out)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	if ok {
		testing.expect_value(t, kind, core.Typed_Error_Kind.None)
		testing.expect(t, string(bytes.buffer_to_bytes(&sink)) == string(want[:]))
	} else {
		testing.expect_value(t, kind, core.Typed_Error_Kind.Bad_Utf8)
	}
}

@(test)
strings_after_strings_keep_every_byte :: proc(t: ^testing.T) {
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill)
	want: [dynamic]u8
	defer delete(want)
	words := [?]string{"", "key", "a longer key with spaces", "line\nbreak and more than sixteen bytes", "caf\xc3\xa9"}
	for i in 0 ..< 5000 {
		w := words[i % len(words)]
		testing.expect_value(t, json.put_string(&out, w), core.Typed_Error_Kind.None)
		text, _ := model_string(transmute([]u8)w, {})
		append(&want, ..text[:])
		delete(text)
	}
	data, err := write.finish(&out)
	defer delete(data)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect(t, string(data) == string(want[:]))
}

// A stream that refuses bytes ends the write with the stream's error, not a crash.
@(test)
a_refusing_stream_fails_the_write :: proc(t: ^testing.T) {
	refuse :: proc(_: rawptr, _: io.Stream_Mode, _: []byte, _: i64, _: io.Seek_From) -> (i64, io.Error) {
		return 0, .Unexpected_EOF
	}
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, stream = io.Stream{procedure = refuse})
	s := make([]u8, 200_000)
	defer delete(s)
	for &b in s {
		b = 'a'
	}
	json.put_string(&out, string(s))
	_, err := write.finish(&out)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Write_Failed)
}

// A string that ends at an unmapped page is written whole at every length: no read passes its last byte.
@(test)
strings_at_the_end_of_a_page :: proc(t: ^testing.T) {
	fence := walktest.fence_init()
	defer walktest.unfence(&fence)
	body := make([]u8, 400, context.temp_allocator)
	for &b, i in body {
		b = 'a' if i % 50 != 49 else '"'
	}
	for n in 0 ..< len(body) {
		s := string(walktest.fence_copy(&fence, body[:n]))
		for opts in ([?]core.Write_Options{{}, {ascii = true}, {escape_html = true}, {escape_del = true}}) {
			text, err := json.marshal(s, opts, context.temp_allocator)
			testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
			doc, derr := json.build(text, .Json)
			testing.expect_value(t, derr.kind, core.Document_Error_Kind.None)
			back, ok := core.text_clone(&doc, core.ROOT, context.temp_allocator)
			core.destroy(&doc)
			testing.expect(t, ok && back == s)
		}
		free_all(context.temp_allocator)
	}
}

// A lead byte at the end of a block with ASCII after it is found by the next block of the wide loop.
@(test)
a_sequence_cut_at_a_block_end :: proc(t: ^testing.T) {
	for lead in ([?]u8{0xC3, 0xE2, 0xF0}) {
		for blocks in 1 ..= 5 {
			for shift in -2 ..= 1 {
				text := make([]u8, 64 * blocks + 300, context.temp_allocator)
				for &b in text {
					b = 'a'
				}
				text[64 * blocks - 1 + shift] = lead
				_, err := json.marshal(string(text), {}, context.temp_allocator)
				testing.expect_value(t, err.kind, core.Typed_Error_Kind.Bad_Utf8)
			}
		}
	}
}
