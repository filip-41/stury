package json_tests

import "base:runtime"
import "base:sanitizer"
import "core:math/rand"
import "core:mem"
import "core:path/filepath"
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
	{"[01]", .Bad_Number, 2},
	{"[1.]", .Bad_Number, 3},
	{"\v[1]", .Bad_Char, 0},
	{"[1]\x00garbage", .Trailing, 3},
	// Number elements and number-valued members after a number, which runs of their own read.
	{"[1, -2, 3.5e1, 0]", nil, 0},
	{"{\"a\": 1, \"b\" : -2, \"c\":3, \"d\": [4, 5]}", nil, 0},
	{"[1, 2, 01, 3]", .Bad_Number, 8},
	{"[1, 2,  x]", .Bad_Char, 8},
	{"[1, 2, ]", .Bad_Char, 7},
	{"{\"a\": 1, \"b\": x}", .Bad_Char, 14},
}

// The faults with `Detail.Literal`.
@(rodata)
LITERAL_CASES := []Case{{"trUe", .Bad_Char, 2}, {"nulx", .Bad_Char, 3}, {"falsy", .Bad_Char, 4}}

// JSONC's comments and trailing commas, under JSONC, and as the bad bytes they are in JSON.
@(rodata)
JSONC_CASES := []Case {
	{"// a\n[1, /* b */ 2 // c\r] /* d */", nil, 0},
	{"/**/[/* a\n*/]//", nil, 0},
	{"{ /* a */ \"k\" /* b */ : /* c */ 1 /* d */ , /* e */ }", nil, 0},
	{"[1, 2, ]", nil, 0},
	{"{\"a\": 1, \"b\" : 2, \"c\":3,}", nil, 0},
	{"{\"a\": [1,], \"b\": {\"c\": {},},}", nil, 0},
	{"// é 😀\n1", nil, 0},
	{"/* \"*/ \"x\"", nil, 0},
	{"[1, /*", .Truncated, 6},
	{"[1 /", .Bad_Char, 3},
	{"/", .Bad_Char, 0},
	{"1 /", .Bad_Char, 2},
	{"1 /* a", .Truncated, 6},
	{"/* a */", .Truncated, 7},
	{"// a", .Truncated, 4},
	{"{\"a\" /* b */", .Truncated, 12},
	{"[1 /x]", .Bad_Char, 3},
	{"[/ 1]", .Bad_Char, 1},
	{"1 /x", .Bad_Char, 2},
	{"{\"a\" /x : 1}", .Bad_Char, 5},
	{"[// \xff\n1]", .Bad_Char, 4},
	{"[/* \xc3\x28 */1]", .Bad_Char, 4},
	{"[// a\x00\n1]", .Bad_Char, 5},
	{"[/* a\x1f */1]", .Bad_Char, 5},
	{"[/*\t\r\n*/ //\t\r1]", nil, 0},
	{"[,]", .Bad_Char, 1},
	{"[1,,]", .Bad_Char, 3},
	{"[1, /* a */ ,]", .Bad_Char, 12},
	{"1 // a\n2", .Trailing, 7},
	{"1 /* a */ 2", .Trailing, 10},
}

// The refusals JSONC_CASES has under `.Json`.
@(rodata)
JSONC_IN_JSON := []Case {
	{"// a\n[1]", .Bad_Char, 0},
	{"[1 /* a */]", .Bad_Char, 3},
	{"[1, 2, ]", .Bad_Char, 7},
	{"1 // a", .Trailing, 2},
}

@(rodata)
JSON5_CASES := []Case {
	{"{a: 1, $b_: 'x', _c: \"y\",}", nil, 0},
	{"[0x1F, -0XaB, +1, .5, 5., +.5e3, Infinity, -Infinity, +NaN, NaN, 1e5,]", nil, 0},
	{"'a\\'b\"c'", nil, 0},
	{"\"\\x41\\0\\v\\q\\/\"", nil, 0},
	{"'a\\\nb\\\r\nc\\\rd\\\xe2\x80\xa8e'", nil, 0},
	{"\"a\xe2\x80\xa8b\xe2\x80\xa9c\t\x01\"", nil, 0},
	{"\v\f\xc2\xa0\xef\xbb\xbf[1]\xe2\x80\xa9\xe3\x80\x80", nil, 0},
	{"{\xc7\x85: 1, \xe2\x85\xab: 2, a\xcc\x81: 3, a\xd9\xa3: 4, a\xe2\x80\xbfb: 5, a\xe2\x80\x8cb: 6, \\u0061b: 7, a\\u0062: 8}", nil, 0},
	{"[// a\x00\n1]", nil, 0},
	{"// a\xe2\x80\xa81", nil, 0},
	{"/* a */ {/* b */ k /* c */ : /* d */ 'v' /* e */, /* f */}", nil, 0},
	{"0x", .Truncated, 2},
	{"0xg", .Bad_Number, 2},
	{"[0x]", .Bad_Number, 3},
	{"01", .Bad_Number, 1},
	{"+01", .Bad_Number, 2},
	{".", .Truncated, 1},
	{".e1", .Bad_Number, 1},
	{"+", .Truncated, 1},
	{"+-1", .Bad_Number, 1},
	{"Infinit", .Truncated, 7},
	{"Inf]", .Bad_Number, 3},
	{"-NaN1", .Trailing, 4},
	{"[1, Infinityx]", .Bad_Char, 12},
	{"5.e", .Truncated, 3},
	{"'abc", .Truncated, 4},
	{"'a\nb'", .Bad_Char, 2},
	{"\"a\\x1\"", .Bad_Escape, 5},
	{"'\\1'", .Bad_Escape, 2},
	{"'\\01'", .Bad_Escape, 3},
	{"'\\x", .Truncated, 3},
	{"\"\\ud800\"", .Bad_Escape, 1},
	{"{a\\x: 1}", .Bad_Escape, 3},
	{"{a\\u0020b: 1}", .Bad_Escape, 2},
	{"{\\u0031: 1}", .Bad_Escape, 1},
	{"{a\\u00: 1}", .Bad_Escape, 6},
	{"{a\xff: 1}", .Bad_Char, 2},
	{"[1 \xc2]", .Bad_Char, 3},
	{"\xa0", .Bad_Char, 0},
	{"[1,,]", .Bad_Char, 3},
	{"/* a", .Truncated, 4},
}

// JSON5's refusals of a key, quoted or not.
@(rodata)
JSON5_KEY_CASES := []Case {
	{"{1: 2}", .Bad_Char, 1},
	{"{-a: 1}", .Bad_Char, 1},
	{"{a: 1, @: 2}", .Bad_Char, 7},
	{"{\xcc\x81a: 1}", .Bad_Char, 1},
	{"{a: 1,,}", .Bad_Char, 6},
}

// The refusals JSON5_CASES has under `.Jsonc`.
@(rodata)
JSON5_IN_JSONC := []Case {
	{"[0x1]", .Bad_Char, 2},
	{"'a'", .Bad_Char, 0},
	{"[\v1]", .Bad_Char, 1},
	{"NaN", .Bad_Char, 0},
}

// A byte where an object's key must start.
@(rodata)
KEY_CASES := []Case {
	{"{1:2}", .Bad_Char, 1},
	{"{\"a\": 1, b: 2}", .Bad_Char, 9},
	{"{\"a\": 1, \"b\" : 2, \"c\":3,}", .Bad_Char, 24},
	{"{\"a\":1,}", .Bad_Char, 7},
}

@(rodata)
KEY_CASES_JSONC := []Case {
	{"{,}", .Bad_Char, 1},
	{"{\"a\": 1, /* b */ 2}", .Bad_Char, 17},
	{"{a: 1}", .Bad_Char, 1},
}

// A byte where a member's colon must stand.
@(rodata)
COLON_CASES := []Case {
	{"{\"a\" 1}", .Bad_Char, 5},
	{"{\"a\" ,1}", .Bad_Char, 5},
	{"{\"a\" [1]}", .Bad_Char, 5},
}

@(rodata)
COLON_CASES_JSONC := []Case {
	{"{\"a\" 1}", .Bad_Char, 5},
	{"{\"a\" /* c */ 1}", .Bad_Char, 13},
}

@(rodata)
COLON_CASES_JSON5 := []Case {
	{"{a b: 1}", .Bad_Char, 3},
	{"{a /* c */ 1}", .Bad_Char, 11},
}

@(test)
faults_at_their_byte :: proc(t: ^testing.T) {
	for c in CASES {
		expect_fault(t, c, .Json, .None)
	}
	for c in LITERAL_CASES {
		expect_fault(t, c, .Json, .Literal)
	}
	for c in JSONC_CASES {
		expect_fault(t, c, .Jsonc, .None)
	}
	for c in JSONC_IN_JSON {
		expect_fault(t, c, .Json, .None)
	}
	for c in JSON5_CASES {
		expect_fault(t, c, .Json5, .None)
	}
	for c in JSON5_KEY_CASES {
		expect_fault(t, c, .Json5, .Identifier)
	}
	for c in JSON5_IN_JSONC {
		expect_fault(t, c, .Jsonc, .None)
	}
	for c in KEY_CASES {
		expect_fault(t, c, .Json, .Identifier)
	}
	for c in KEY_CASES_JSONC {
		expect_fault(t, c, .Jsonc, .Identifier)
	}
	for c in COLON_CASES {
		expect_fault(t, c, .Json, .Colon)
	}
	for c in COLON_CASES_JSONC {
		expect_fault(t, c, .Jsonc, .Colon)
	}
	for c in COLON_CASES_JSON5 {
		expect_fault(t, c, .Json5, .Colon)
	}
}

// A member skipped after its key still faults at the byte where its colon must stand, with `Colon` from the state
// that passes the comments around the colon as well.
@(test)
colon_detail_after_skip :: proc(t: ^testing.T) {
	Skipped :: struct {
		spec: json.Spec,
		text: string,
		at:   u64,
	}
	for want in ([]Skipped {
		{.Json, "{\"a\" 1}", 5},
		{.Jsonc, "{\"a\" 1}", 5},
		{.Jsonc, "{\"a\" /* c */ 1}", 13},
		{.Json5, "{a b: 1}", 3},
	}) {
		skip := 1
		fault: Maybe(core.Fault)
		switch want.spec {
		case .Json:
			_, fault = json.walk(transmute([]u8)want.text, 0, .Json, {}, &skip, &core.Hook_Regs{}, skip_hook)
		case .Jsonc:
			_, fault = json.walk(transmute([]u8)want.text, 0, .Jsonc, {}, &skip, &core.Hook_Regs{}, skip_hook)
		case .Json5:
			_, fault = json.walk(transmute([]u8)want.text, 0, .Json5, {}, &skip, &core.Hook_Regs{}, skip_hook)
		}
		f := core.Fault{want.at, &json.RULES, .Bad_Char, u8(json.Detail.Colon)}
		testing.expectf(t, fault == f, "%v %q: %v, want %v", want.spec, want.text, fault, f)
	}
}

// `validate`'s verdict, and the same fault from a walk with hooks, which takes the comment states that emit, where
// the walk finds a document: `Trailing` is `validate`'s alone.
expect_fault :: proc(t: ^testing.T, c: Case, $S: json.Spec, detail: json.Detail) {
	src := transmute([]u8)c.text
	verdict := json.validate(src, S)
	f, bad := verdict.?
	if c.kind == nil {
		testing.expectf(t, !bad, "%v %q: %v", S, c.text, f)
	} else {
		testing.expectf(t, bad && f.kind == c.kind && f.at == c.offset && f.detail == u8(detail), "%v %q: %v, want %v at %d", S, c.text, f, c.kind, c.offset)
	}
	if c.kind != .Trailing {
		log := new(Log)
		defer free(log)
		_, fault := json.walk(src, 0, S, {}, log, &core.Hook_Regs{}, log_hook)
		empty := fault == nil && log.n == 0
		testing.expectf(t, empty || fault == verdict, "%v %q: hooked walk %v, validate %v", S, c.text, fault, verdict)
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
				f, bad := validate_fenced(text[:], .Json).?
				if piece.kind == nil {
					if !testing.expectf(t, !bad, "%q: %v", text[:], f) {
						return
					}
				} else if !testing.expectf(t, bad && f.kind == piece.kind && f.at == 1 + u64(k) + piece.offset, "%q: %v, want %v at %d", text[:], f, piece.kind, 1 + u64(k) + piece.offset) {
					return
				}
				// Cut before the closing quote.
				resize(&text, 1 + k + len(piece.bytes))
				f, bad = validate_fenced(text[:], .Json).?
				if piece.kind == nil && !testing.expectf(t, bad && f.kind == .Truncated && f.at == u64(len(text)), "%q: %v", text[:], f) {
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
		f, bad := validate_fenced(text[:], .Json).?
		if want.kind == nil {
			return testing.expectf(t, !bad, "%q: %v", text[:], f)
		}
		at := u64(1 + shift + 2 * run + want.offset)
		return testing.expectf(t, bad && f.kind == want.kind && f.at == at, "%q: %v, want %v at %d", text[:], f, want.kind, at)
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
				want := json.validate(plain[:], .Json)
				got := validate_fenced(text[:], .Json)
				if !testing.expectf(t, got == want, "%q: %v, want %v", text[:], got, want) {
					return
				}
			}
		}
		resize(&text, 2 + k + 3 + k)
		f, bad := validate_fenced(text[:], .Json).?
		if !testing.expectf(t, bad && f.kind == .Truncated && f.at == u64(len(text)), "%q: %v", text[:], f) {
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
			return core.Fault{at = f.at + u64(by), rules = f.rules, kind = f.kind, detail = f.detail}
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
				want := json.validate(ref[:], .Json)
				got_short := shifted(json.validate(short[:], .Json), PAST + 1)
				got_long := shifted(json.validate(long[:], .Json), 1)
				if !testing.expectf(t, got_short == want && got_long == want, "%q: %v %v, want %v", short[:], got_short, got_long, want) {
					return
				}
				// Cut after the colon, after x, and after y when x is the space of a pretty printer's `": "`.
				if y > 0 && x != ' ' {
					continue
				}
				for n in 4 + key_len ..= 6 + key_len {
					want = json.validate(ref[:n + PAST + 1], .Json)
					got_short = shifted(validate_fenced(short[:n], .Json), PAST + 1)
					got_long = shifted(validate_fenced(long[:n + PAST], .Json), 1)
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
validate_fenced :: proc(src: []u8, $S: json.Spec, opts := json.Options{}) -> Maybe(core.Fault) {
	FENCE :: 64
	buf := make([]u8, len(src) + FENCE)
	defer delete(buf)
	copy(buf, src)
	sanitizer.address_poison(buf[len(src):])
	defer sanitizer.address_unpoison(buf[len(src):])
	return json.validate(buf[:len(src)], S, opts)
}

// Every prefix of seeded texts, compact and pretty, read with its next bytes poisoned: a state's look past the
// token it stands on must stop at the end wherever the text is cut.
@(test)
prefixes_fenced :: proc(t: ^testing.T) {
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)
	text: [dynamic]u8
	defer delete(text)
	for round in 0 ..< 900 {
		clear(&text)
		spec := json.Spec(round / 2 % len(json.Spec))
		if round % 2 == 1 {
			gen.pretty(&text, 1 + round % 4, spec)
		} else {
			gen.text(&text, 1 + round % 4, spec)
		}
		for n in 0 ..= len(text) {
			same: bool
			switch spec {
			case .Json:
				same = validate_fenced(text[:n], .Json) == json.validate(text[:n], .Json)
			case .Jsonc:
				same = validate_fenced(text[:n], .Jsonc) == json.validate(text[:n], .Jsonc)
			case .Json5:
				same = validate_fenced(text[:n], .Json5) == json.validate(text[:n], .Json5)
			}
			if !testing.expectf(t, same, "%v %q", spec, text[:n]) {
				return
			}
		}
	}
}

@(test)
depth_limit :: proc(t: ^testing.T) {
	deep := strings.concatenate({strings.repeat("[", json.MAX_DEPTH, context.temp_allocator), strings.repeat("]", json.MAX_DEPTH, context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(t, json.validate(transmute([]u8)deep, .Json), nil)
	run := strings.repeat("[", json.MAX_DEPTH + 1, context.temp_allocator)
	f, bad := json.validate(transmute([]u8)run, .Json).?
	testing.expectf(t, bad && f.kind == .Too_Deep && f.at == json.MAX_DEPTH, "%v", f)
	over :=strings.repeat("[{\"a\":", json.MAX_DEPTH, context.temp_allocator)
	f, bad = json.validate(transmute([]u8)over, .Json).?
	testing.expectf(t, bad && f.kind == .Too_Deep && f.at == 6 * (json.MAX_DEPTH / 2), "%v", f)
}

// Skips the token numbered `h^`, from 0, and reads every other.
skip_hook :: proc "contextless" (h: ^int, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	h^ -= 1
	return s, .Skip if h^ == -1 else .Next
}

// `max_depth` below the default, at it, and past it, where the depth stack comes from the heap: `max_depth` levels
// pass and the bracket past them is `Too_Deep`, an array or an object, through `validate`, a walk with a hook, and a
// walk that skips the root or its first key. The heap stack is the default heap's, whatever the caller's allocator.
@(test)
max_depth_option :: proc(t: ^testing.T) {
	heap := context.allocator
	log := new(Log)
	defer free(log, heap)
	context.allocator = mem.panic_allocator()
	for depth in ([]u32{1, 3, json.MAX_DEPTH, json.MAX_DEPTH + 1, 5000}) {
		n := int(depth)
		fits := strings.concatenate({strings.repeat("[", n, context.temp_allocator), strings.repeat("]", n, context.temp_allocator)}, context.temp_allocator)
		testing.expectf(t, json.validate(transmute([]u8)fits, .Json, {max_depth = depth}) == nil, "%d levels", n)
		over := strings.concatenate({strings.repeat("[{\"a\":", n / 2, context.temp_allocator), strings.repeat("[", n % 2 + 1, context.temp_allocator)}, context.temp_allocator)
		f, bad := json.validate(transmute([]u8)over, .Json, {max_depth = depth}).?
		testing.expectf(t, bad && f.kind == .Too_Deep && f.at == u64(len(over) - 1), "%d levels: %v", n, f)
		log^ = {}
		_, fault := json.walk(transmute([]u8)over, 0, .Json, {max_depth = depth}, log, &core.Hook_Regs{}, log_hook)
		testing.expectf(t, fault == f && log.n == n + n / 2, "%d levels, walked: %v, %d tokens", n, fault, log.n)
		maps := strings.concatenate({strings.repeat("{\"a\":", n, context.temp_allocator), "{"}, context.temp_allocator)
		f, bad = json.validate(transmute([]u8)maps, .Json, {max_depth = depth}).?
		testing.expectf(t, bad && f.kind == .Too_Deep && f.at == u64(len(maps) - 1), "%d objects: %v", n, f)
		for skip in ([]int{0, 1}) {
			k := skip
			_, fault = json.walk(transmute([]u8)maps, 0, .Json, {max_depth = depth}, &k, &core.Hook_Regs{}, skip_hook)
			testing.expectf(t, fault == f, "%d objects, token %d skipped: %v", n, skip, fault)
		}
	}
}

Tolerated :: struct {
	spec:   json.Spec,
	text:   string,
	tol:    bit_set[json.Tolerance; u8],
	kind:   core.Fault_Kind, // 0 where `tol` takes every fault
	offset: u64,
}

// Texts a tolerance takes, and faults no tolerance in the set takes, which stand as they do without it.
@(rodata)
TOLERATED := []Tolerated {
	{.Json, "\"a\xffb\"", {.Invalid_Utf8}, nil, 0},
	{.Json, "[\"\xe2\x82\",1]", {.Invalid_Utf8}, nil, 0},
	{.Json, "\"\xc0\xaf\"", {.Invalid_Utf8}, nil, 0},
	{.Json, "\"\xed\xa0\x80\"", {.Invalid_Utf8}, nil, 0},
	{.Json, "\"\xf0\x9f\x98x\"", {.Invalid_Utf8}, nil, 0},
	{.Json, "\"\xf4\x90\x80\x80\"", {.Invalid_Utf8}, nil, 0},
	{.Json, "{\"\xff\":1}", {.Invalid_Utf8}, nil, 0},
	{.Json, "\"\xe2\x82", {.Invalid_Utf8}, .Truncated, 3},
	{.Json, "\"\\ud800\"", {.Invalid_Utf8}, .Bad_Escape, 1},
	{.Json, "[\xff]", {.Invalid_Utf8, .Lone_Surrogate}, .Bad_Char, 1},
	{.Json, "\"\\ud800\"", {.Lone_Surrogate}, nil, 0},
	{.Json, "\"\\udc00x\"", {.Lone_Surrogate}, nil, 0},
	{.Json, "\"\\ud800\\u0041\"", {.Lone_Surrogate}, nil, 0},
	{.Json, "\"\\ud800\\ud800\"", {.Lone_Surrogate}, nil, 0},
	{.Json, "\"\\ud800\\ud83d\\ude00\"", {.Lone_Surrogate}, nil, 0},
	{.Json, "\"\\ud800\\u00g1\"", {.Lone_Surrogate}, .Bad_Escape, 11},
	{.Json, "\"\\ud800\\u", {.Lone_Surrogate}, .Truncated, 9},
	{.Json, "\"\xff\"", {.Lone_Surrogate}, .Bad_Char, 1},
	{.Jsonc, "\"\xff\" // \\ud800", {.Invalid_Utf8}, nil, 0},
	{.Jsonc, "// \xff\n1", {.Invalid_Utf8, .Lone_Surrogate}, .Bad_Char, 3},
	{.Jsonc, "/* \xff */1", {.Invalid_Utf8, .Lone_Surrogate}, .Bad_Char, 3},
	{.Json5, "'\xff'", {.Invalid_Utf8}, nil, 0},
	{.Json5, "'\\\xff'", {.Invalid_Utf8}, nil, 0},
	{.Json5, "'\\ud800'", {.Lone_Surrogate}, nil, 0},
	{.Json5, "{\xff:1}", {.Invalid_Utf8, .Lone_Surrogate}, .Bad_Char, 1},
	{.Json5, "{a\\ud800:1}", {.Invalid_Utf8, .Lone_Surrogate}, .Bad_Escape, 2},
}

// Each tolerance, through `validate` and a walk with hooks: what it takes was a fault without it, and what it does not
// take faults alike. A tolerated string's token keeps its bytes.
@(test)
tolerances :: proc(t: ^testing.T) {
	for c in TOLERATED {
		switch c.spec {
		case .Json:
			expect_tolerated(t, c, .Json)
		case .Jsonc:
			expect_tolerated(t, c, .Jsonc)
		case .Json5:
			expect_tolerated(t, c, .Json5)
		}
	}
	// Every offset the string readers branch on, as `strings_at_every_offset` sweeps them.
	text: [dynamic]u8
	defer delete(text)
	for piece in ([]string{"\xff", "\xe2\x82", "\xf0\x9f\x98x", "\\ud800", "\\udc00\\u0041"}) {
		for k in 0 ..< 140 {
			clear(&text)
			append(&text, '"')
			for _ in 0 ..< k {
				append(&text, 'a')
			}
			append(&text, piece)
			append(&text, '"')
			f, bad := validate_fenced(text[:], .Json, {tolerate = {.Invalid_Utf8, .Lone_Surrogate}}).?
			if !testing.expectf(t, !bad, "%q: %v", text[:], f) {
				return
			}
		}
	}
}

expect_tolerated :: proc(t: ^testing.T, c: Tolerated, $S: json.Spec) {
	src := transmute([]u8)c.text
	strict := json.validate(src, S)
	f, bad := json.validate(src, S, {tolerate = c.tol}).?
	if c.kind == nil {
		testing.expectf(t, !bad && strict != nil, "%v %q: %v, strict %v", S, c.text, f, strict)
	} else {
		testing.expectf(t, bad && f.kind == c.kind && f.at == c.offset, "%v %q: %v, want %v at %d", S, c.text, f, c.kind, c.offset)
	}
	log := new(Log)
	defer free(log)
	_, fault := json.walk(src, 0, S, {tolerate = c.tol}, log, &core.Hook_Regs{}, log_hook)
	testing.expectf(t, fault == (f if bad else nil), "%v %q: hooked walk %v, validate %v", S, c.text, fault, f)
	for tok in log.tokens[:log.n] {
		testing.expectf(t, spans(src, tok), "%v %q: %v", S, c.text, tok)
	}
}

// Every value of `Detail` has a rule, and a fault renders as `line:col: message` with its rule's code beside it.
// Faults met in offset order share one count of the lines, and one before the count's byte counts again.
@(test)
rendered_faults :: proc(t: ^testing.T) {
	testing.expect_value(t, len(json.RULES.details), len(json.Detail))
	src := transmute([]u8)string("{\n  \"a\": tru\n}")
	f, bad := json.validate(src, .Json).?
	testing.expect(t, bad)
	b := strings.builder_make(context.temp_allocator)
	core.render(strings.to_writer(&b), src, f)
	testing.expect_value(t, strings.to_string(b), "2:11: Invalid literal")
	strings.builder_reset(&b)
	core.write_code(strings.to_writer(&b), f)
	testing.expect_value(t, strings.to_string(b), "json.literal")
	lines: core.Lines
	Want :: struct {
		at:   u64,
		kind: core.Fault_Kind,
		text: string,
	}
	for want in ([]Want{{0, .Bad_Char, "1:1: Unexpected character"}, {6, .Bad_Number, "2:5: Invalid number"}, {14, .Truncated, "3:2: Unfinished input"}, {2, .Trailing, "2:1: Unexpected text after the value"}, {0, .No_Memory, "Out of memory"}, {0, .None, "No fault"}}) {
		strings.builder_reset(&b)
		core.render(strings.to_writer(&b), src, core.Fault{want.at, &json.RULES, want.kind, 0}, &lines)
		testing.expect_value(t, strings.to_string(b), want.text)
	}
	strings.builder_reset(&b)
	core.write_code(strings.to_writer(&b), core.Fault{0, &json.RULES, .No_Memory, 0})
	testing.expect_value(t, strings.to_string(b), "json.no_memory")
	strings.builder_reset(&b)
	core.write_code(strings.to_writer(&b), core.Fault{5, &json.RULES, .Bad_Char, u8(json.Detail.Colon)})
	testing.expect_value(t, strings.to_string(b), "json.colon")
	strings.builder_reset(&b)
	core.render(strings.to_writer(&b), transmute([]u8)string("{\"a\" 1}"), core.Fault{5, &json.RULES, .Bad_Char, u8(json.Detail.Colon)})
	testing.expect_value(t, strings.to_string(b), "1:6: Missing colon after key")
	line, col := core.locate(transmute([]u8)string("a\nb"), 2, nil)
	testing.expect_value(t, line, u64(2))
	testing.expect_value(t, col, u64(1))
	line, col = core.locate(transmute([]u8)string("a\nb"), 1, nil)
	testing.expect_value(t, line, u64(1))
	testing.expect_value(t, col, u64(2))
	// A line ends at its LF, a CR is a byte of its line, and a column counts bytes.
	Located :: struct {
		src:  string,
		at:   u64,
		text: string,
	}
	for want in ([]Located{{"a\r\nb", 3, "2:1"}, {"a\r\nb", 2, "1:3"}, {"a\rb", 2, "1:3"}, {"éx", 3, "1:4"}}) {
		strings.builder_reset(&b)
		core.render(strings.to_writer(&b), transmute([]u8)want.src, core.Fault{want.at, &json.RULES, .Bad_Char, 0})
		testing.expectf(t, strings.to_string(b) == strings.concatenate({want.text, ": Unexpected character"}, context.temp_allocator), "%q at %d: %s", want.src, want.at, strings.to_string(b))
	}
}

// JSONTestSuite: every `y_` text passes and every `n_` text fails. The `i_` texts are the oracle's.
@(test)
json_test_suite :: proc(t: ^testing.T) {
	suite := #load_directory("conformance/JSONTestSuite/test_parsing")
	n: int
	for file in suite {
		_, bad := json.validate(file.data, .Json).?
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

// json5-tests: every `.json` and `.json5` text passes, and every `.js` and `.txt` text fails.
@(test)
json5_tests :: proc(t: ^testing.T) {
	dirs := [?][]runtime.Load_Directory_File {
		#load_directory("conformance/json5-tests/arrays"),
		#load_directory("conformance/json5-tests/comments"),
		#load_directory("conformance/json5-tests/misc"),
		#load_directory("conformance/json5-tests/new-lines"),
		#load_directory("conformance/json5-tests/numbers"),
		#load_directory("conformance/json5-tests/objects"),
		#load_directory("conformance/json5-tests/strings"),
		#load_directory("conformance/json5-tests/todo"),
	}
	n: int
	for dir in dirs {
		for file in dir {
			f, bad := json.validate(file.data, .Json5).?
			switch filepath.ext(file.name) {
			case ".json", ".json5":
				testing.expectf(t, !bad, "%s: %v", file.name, f)
			case ".js", ".txt":
				testing.expectf(t, bad, "%s", file.name)
			case:
				continue
			}
			n += 1
		}
	}
	testing.expect_value(t, n, 114)
}
