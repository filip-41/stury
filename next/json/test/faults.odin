package json_tests

import "base:sanitizer"
import "core:math/rand"
import "core:strings"
import "core:testing"
import core "../../core"
import json ".."
import gen "gen"

Case :: struct {
	text:   string,
	kind:   core.Fault_Kind, // 0 for a valid text
	offset: u64,
}

// Every fault the walk and its one-document framing raise, at the byte the fault's rule names.
@(rodata)
CASES := []Case {
	{"0", nil, 0},
	{"-0.5e+10", nil, 0},
	{"\"\\ud83d\\ude00\\u00e9\\/\"", nil, 0},
	{" [[], {}, {\"a\": [true, false, null]}] \n", nil, 0},
	{"\xef\xbb\xbf[]", nil, 0},
	{"", .Truncated, 0},
	{"   ", .Truncated, 3},
	{"[", .Truncated, 1},
	{"[1,", .Truncated, 3},
	{"[1 ", .Truncated, 3},
	{"{\"a\"", .Truncated, 4},
	{"{\"a\":", .Truncated, 5},
	{"\"abc", .Truncated, 4},
	{"\"\\", .Truncated, 2},
	{"\"\\u12", .Truncated, 5},
	{"\"\\ud800\\u", .Truncated, 9},
	{"\"\xc3", .Truncated, 2},
	{"\"\xf0\x9f\x98", .Truncated, 4},
	{"tru", .Truncated, 3},
	{"-", .Truncated, 1},
	{"1.", .Truncated, 2},
	{"1e", .Truncated, 2},
	{"1e+", .Truncated, 3},
	{"x", .Bad_Char, 0},
	{"[1 2]", .Bad_Char, 3},
	{"[1}", .Bad_Char, 2},
	{"[}", .Bad_Char, 1},
	{"{1:2}", .Bad_Char, 1},
	{"{\"a\" 1}", .Bad_Char, 5},
	{"\"a\x01\"", .Bad_Char, 2},
	{"\"\xff\"", .Bad_Char, 1},
	{"\"\xc3\x28\"", .Bad_Char, 1},
	{"\"\xc0\x80\"", .Bad_Char, 1},
	{"\"\xed\xa0\x80\"", .Bad_Char, 1},
	{"\"\xf4\x90\x80\x80\"", .Bad_Char, 1},
	{"\"\xf0\x9f\x98x\"", .Bad_Char, 1},
	{"\xef\xbb\xbf\xef\xbb\xbf[]", .Bad_Char, 3},
	{"\"\\x\"", .Bad_Escape, 2},
	{"\"\\u12g4\"", .Bad_Escape, 5},
	{"\"\\udc00\"", .Bad_Escape, 1},
	{"\"\\ud800\"", .Bad_Escape, 1},
	{"\"\\ud800\\u0041\"", .Bad_Escape, 1},
	{"\"\\ud800\\x\"", .Bad_Escape, 1},
	{"01", .Bad_Number, 1},
	{"-01", .Bad_Number, 2},
	{"-a", .Bad_Number, 1},
	{"1.x", .Bad_Number, 2},
	{"[1e+]", .Bad_Number, 4},
	{"1 2", .Trailing, 2},
	{"{}x", .Trailing, 2},
	// The texts `core:encoding/json` takes in `.JSON` mode (odin-lang/Odin#8061).
	{"[\"a\x01b\"]", .Bad_Char, 3},
	{"[\"\\q\"]", .Bad_Escape, 3},
	{"[1e]", .Bad_Number, 3},
	{"[\"\xff\"]", .Bad_Char, 2},
	{"[\"\\ud800\"]", .Bad_Escape, 2},
	{"[1,]", .Bad_Char, 3},
	{"{\"a\":1,}", .Bad_Char, 7},
	{"[01]", .Bad_Number, 2},
	{"[1.]", .Bad_Number, 3},
	{"\v[1]", .Bad_Char, 0},
	{"[1]\x00garbage", .Trailing, 3},
}

// The faults with `Detail.Literal`.
@(rodata)
LITERAL_CASES := []Case{{"trUe", .Bad_Char, 2}, {"nulx", .Bad_Char, 3}, {"falsy", .Bad_Char, 4}}

@(test)
faults_at_their_byte :: proc(t: ^testing.T) {
	for c in CASES {
		expect_fault(t, c, .None)
	}
	for c in LITERAL_CASES {
		expect_fault(t, c, .Literal)
	}
}

expect_fault :: proc(t: ^testing.T, c: Case, detail: json.Detail) {
	f, bad := json.validate(transmute([]u8)c.text, .Strict).?
	if c.kind == nil {
		testing.expectf(t, !bad, "%q: %v", c.text, f)
	} else {
		testing.expectf(t, bad && f.kind == c.kind && f.offset == c.offset && f.detail == u8(detail), "%q: %v, want %v at %d", c.text, f, c.kind, c.offset)
	}
}

// A string's every byte at every offset its readers branch on: the 16-byte halves, the 64-byte blocks, the text's
// last 64 bytes, and past them, after plain bytes or escapes. `pad` plain bytes follow the closing quote or the cut.
@(test)
strings_at_every_offset :: proc(t: ^testing.T) {
	Piece :: struct {
		bytes:  string,
		kind:   core.Fault_Kind,
		offset: u64, // past the opening quote and the run before the piece
	}
	@(static, rodata)
	PIECES := []Piece {
		{"", nil, 0},
		{"\\n", nil, 0},
		{"\\u00e9", nil, 0},
		{"é", nil, 0},
		{"😀", nil, 0},
		{"\x7f", nil, 0},
		{"\x80", .Bad_Char, 0},
		{"\x01", .Bad_Char, 0},
		{"\x1f", .Bad_Char, 0},
		{"\\q", .Bad_Escape, 1},
		{"\\\\", nil, 0},
		{"\\\"", nil, 0},
		{"\\ud83d\\ude00", nil, 0},
		{"\\ud800", .Bad_Escape, 0},
		{"\\udc00", .Bad_Escape, 0},
		{"\\ud800\\u0041", .Bad_Escape, 0},
		{"\\u12g4", .Bad_Escape, 4},
		{"\\u", .Bad_Escape, 2},
		{"\xff", .Bad_Char, 0},
		{"\xc3\x28", .Bad_Char, 0},
		{"\xed\xa0\x80", .Bad_Char, 0},
	}
	text: [dynamic]u8
	defer delete(text)
	// The run before the piece, plain or escaped.
	for fill in ([]string{"a", "\\n"}) do for piece in PIECES {
		for k := 0; k < 140; k += len(fill) {
			for pad in ([]int{0, 1, 70}) {
				clear(&text)
				append(&text, '"')
				for j in 0 ..< k {
					append(&text, fill[j % len(fill)])
				}
				append(&text, piece.bytes)
				append(&text, '"')
				for _ in 0 ..< pad {
					append(&text, ' ')
				}
				f, bad := validate_fenced(text[:]).?
				if piece.kind == nil {
					if !testing.expectf(t, !bad, "%q: %v", text[:], f) {
						return
					}
				} else if !testing.expectf(t, bad && f.kind == piece.kind && f.offset == 1 + u64(k) + piece.offset, "%q: %v, want %v at %d", text[:], f, piece.kind, 1 + u64(k) + piece.offset) {
					return
				}
				// Cut before the closing quote.
				resize(&text, 1 + k + len(piece.bytes))
				f, bad = validate_fenced(text[:]).?
				if piece.kind == nil && !testing.expectf(t, bad && f.kind == .Truncated && f.offset == u64(len(text)), "%q: %v", text[:], f) {
					return
				}
			}
		}
	}
}

// Every byte as an escape's letter, as each digit of a `\u` escape, and as the second digit of a surrogate half, in
// blocks with other escapes, the escape in the first block, the second block, and across their edge at every lane.
@(test)
escapes_by_byte :: proc(t: ^testing.T) {
	Want :: struct {
		kind:   core.Fault_Kind,
		offset: int, // from the escape's backslash
	}
	text: [dynamic]u8
	defer delete(text)
	check :: proc(t: ^testing.T, text: ^[dynamic]u8, shift, run: int, escape: []u8, want: Want) -> bool {
		clear(text)
		append(text, '"')
		for _ in 0 ..< shift {
			append(text, 'a')
		}
		for _ in 0 ..< run {
			append(text, "\\n")
		}
		append(text, ..escape)
		append(text, '"')
		for _ in 0 ..< 80 {
			append(text, ' ')
		}
		f, bad := validate_fenced(text[:]).?
		if want.kind == nil {
			return testing.expectf(t, !bad, "%q: %v", text[:], f)
		}
		at := u64(1 + shift + 2 * run + want.offset)
		return testing.expectf(t, bad && f.kind == want.kind && f.offset == at, "%q: %v, want %v at %d", text[:], f, want.kind, at)
	}
	is_hex :: proc(c: u8) -> bool {
		return c - '0' < 10 || (c | 0x20) - 'a' < 6
	}
	for shift in 0 ..< 2 do for run in ([]int{8, 24, 26, 27, 28, 29, 30, 31}) {
		for c in 0 ..< 256 {
			c := u8(c)
			want := Want{.Bad_Escape, 1}
			switch c {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
				want = {}
			case 'u':
				want = {.Bad_Escape, 2}
			}
			if !check(t, &text, shift, run, {'\\', c}, want) {
				return
			}
			for i in 0 ..< 4 {
				escape := []u8{'\\', 'u', '0', '0', '4', '1'}
				escape[2 + i] = c
				want = {} if is_hex(c) else {.Bad_Escape, 2 + i}
				if !check(t, &text, shift, run, escape, want) {
					return
				}
			}
			// `\udX00`: a code point below the surrogates, a lone high half, or a lone low half.
			want = {}
			switch {
			case !is_hex(c):
				want = {.Bad_Escape, 3}
			case c - '8' < 2 || (c | 0x20) - 'a' < 6:
				want = {.Bad_Escape, 0}
			}
			if !check(t, &text, shift, run, {'\\', 'u', 'd', c, '0', '0'}, want) {
				return
			}
			// A high half, then `\udX00`: valid only with a low half.
			if is_hex(c) {
				want = {} if (c | 0x20) - 'c' < 4 else {.Bad_Escape, 0}
				if !check(t, &text, shift, run, {'\\', 'u', 'd', '8', '0', '0', '\\', 'u', 'd', c, '0', '0'}, want) {
					return
				}
			}
		}
	}
}

// Every byte at every place of a predicted indent, and in the token after it, judged as the same text with each
// newline a CR, which the indent prediction never takes. Then texts that end in a predicted indent.
@(test)
indents_by_byte :: proc(t: ^testing.T) {
	text, plain: [dynamic]u8
	defer delete(text)
	defer delete(plain)
	for k in 0 ..< 40 {
		for i in 0 ..= k {
			for c in 0 ..< 256 {
				clear(&text)
				append(&text, "[\n")
				for _ in 0 ..< k {
					append(&text, ' ')
				}
				append(&text, "1,\n")
				for _ in 0 ..< k {
					append(&text, ' ')
				}
				append(&text, '2')
				text[len(text) - 1 - k + i] = u8(c)
				append(&text, "\n]")
				for _ in 0 ..< 40 {
					append(&text, ' ')
				}
				clear(&plain)
				for b in text {
					append(&plain, '\r' if b == '\n' else b)
				}
				want := json.validate(plain[:], .Strict)
				got := validate_fenced(text[:])
				if !testing.expectf(t, got == want, "%q: %v, want %v", text[:], got, want) {
					return
				}
			}
		}
		resize(&text, 2 + k + 3 + k)
		f, bad := validate_fenced(text[:]).?
		if !testing.expectf(t, bad && f.kind == .Truncated && f.offset == u64(len(text)), "%q: %v", text[:], f) {
			return
		}
	}
}

// Every pair of bytes after a key's colon, after keys the probe reads and keys too long for it, judged as the same
// member with a space before its colon, which no state takes on a fast path. Then the members cut after the colon
// and after each of the two bytes, at the lengths where the probe still reads the key.
@(test)
colons_by_byte :: proc(t: ^testing.T) {
	member :: proc(out: ^[dynamic]u8, key_len: int, spaced: bool, x, y: u8) {
		clear(out)
		append(out, "{\"")
		for _ in 0 ..< key_len {
			append(out, 'k')
		}
		append(out, "\" :" if spaced else "\":")
		append(out, x, y)
		append(out, "1,\"pad\":\"........................................\"}")
	}
	// The fault of a text that holds `by` bytes fewer before its colon than the reference.
	shifted :: proc(f: Maybe(core.Fault), by: int) -> Maybe(core.Fault) {
		if f, bad := f.?; bad {
			return core.Fault{f.offset + u64(by), f.kind, f.detail}
		}
		return nil
	}
	ref, short, long: [dynamic]u8
	defer delete(ref)
	defer delete(short)
	defer delete(long)
	PAST :: 40
	for key_len in ([]int{1, 29, 30, 31}) {
		for x in 0 ..< 256 {
			for y in 0 ..< 256 {
				member(&ref, key_len + PAST, true, u8(x), u8(y))
				member(&short, key_len, false, u8(x), u8(y))
				member(&long, key_len + PAST, false, u8(x), u8(y))
				want := json.validate(ref[:], .Strict)
				got_short := shifted(json.validate(short[:], .Strict), PAST + 1)
				got_long := shifted(json.validate(long[:], .Strict), 1)
				if !testing.expectf(t, got_short == want && got_long == want, "%q: %v %v, want %v", short[:], got_short, got_long, want) {
					return
				}
				// Cut after the colon, after x, and after y when x is the space of a pretty printer's `": "`.
				if y > 0 && x != ' ' {
					continue
				}
				for n in 4 + key_len ..= 6 + key_len {
					want = json.validate(ref[:n + PAST + 1], .Strict)
					got_short = shifted(validate_fenced(short[:n]), PAST + 1)
					got_long = shifted(validate_fenced(long[:n + PAST]), 1)
					if !testing.expectf(t, got_short == want && got_long == want, "%q: %v %v, want %v", short[:n], got_short, got_long, want) {
						return
					}
				}
			}
		}
	}
}

// `src` validated from a copy whose next bytes are poisoned, so that under `-sanitize:address` a read past its end
// fails the run.
validate_fenced :: proc(src: []u8) -> Maybe(core.Fault) {
	FENCE :: 64
	buf := make([]u8, len(src) + FENCE)
	defer delete(buf)
	copy(buf, src)
	sanitizer.address_poison(buf[len(src):])
	defer sanitizer.address_unpoison(buf[len(src):])
	return json.validate(buf[:len(src)], .Strict)
}

// Every prefix of seeded texts, compact and pretty, read with its next bytes poisoned: a state's look past the
// token it stands on must stop at the end wherever the text is cut.
@(test)
prefixes_fenced :: proc(t: ^testing.T) {
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)
	text: [dynamic]u8
	defer delete(text)
	for round in 0 ..< 300 {
		clear(&text)
		if round % 2 == 1 {
			gen.pretty(&text, 1 + round % 4)
		} else {
			gen.text(&text, 1 + round % 4)
		}
		for n in 0 ..= len(text) {
			if !testing.expectf(t, validate_fenced(text[:n]) == json.validate(text[:n], .Strict), "%q", text[:n]) {
				return
			}
		}
	}
}

@(test)
depth_limit :: proc(t: ^testing.T) {
	deep := strings.concatenate({strings.repeat("[", json.MAX_DEPTH, context.temp_allocator), strings.repeat("]", json.MAX_DEPTH, context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(t, json.validate(transmute([]u8)deep, .Strict), nil)
	run := strings.repeat("[", json.MAX_DEPTH + 1, context.temp_allocator)
	f, bad := json.validate(transmute([]u8)run, .Strict).?
	testing.expectf(t, bad && f.kind == .Too_Deep && f.offset == json.MAX_DEPTH, "%v", f)
	over :=strings.repeat("[{\"a\":", json.MAX_DEPTH, context.temp_allocator)
	f, bad = json.validate(transmute([]u8)over, .Strict).?
	testing.expectf(t, bad && f.kind == .Too_Deep && f.offset == 6 * (json.MAX_DEPTH / 2), "%v", f)
}

// JSONTestSuite: every `y_` text passes and every `n_` text fails. The `i_` texts are the oracle's.
@(test)
json_test_suite :: proc(t: ^testing.T) {
	suite := #load_directory("conformance/JSONTestSuite/test_parsing")
	n: int
	for file in suite {
		_, bad := json.validate(file.data, .Strict).?
		switch file.name[0] {
		case 'y':
			testing.expectf(t, !bad, "%s", file.name)
		case 'n':
			testing.expectf(t, bad, "%s", file.name)
		case:
			continue
		}
		n += 1
	}
	testing.expect(t, n > 250)
}
