package json_tests

import "core:strings"
import "core:testing"
import core "../../core"
import json ".."

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
// last 64 bytes, and past them. `pad` plain bytes follow the closing quote or the cut.
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
		{"\xff", .Bad_Char, 0},
		{"\xc3\x28", .Bad_Char, 0},
		{"\xed\xa0\x80", .Bad_Char, 0},
	}
	text: [dynamic]u8
	defer delete(text)
	for piece in PIECES {
		for k in 0 ..< 140 {
			for pad in ([]int{0, 1, 70}) {
				clear(&text)
				append(&text, '"')
				for _ in 0 ..< k {
					append(&text, 'a')
				}
				append(&text, piece.bytes)
				append(&text, '"')
				for _ in 0 ..< pad {
					append(&text, ' ')
				}
				f, bad := json.validate(text[:], .Strict).?
				if piece.kind == nil {
					if !testing.expectf(t, !bad, "%q: %v", text[:], f) {
						return
					}
				} else if !testing.expectf(t, bad && f.kind == piece.kind && f.offset == 1 + u64(k) + piece.offset, "%q: %v, want %v at %d", text[:], f, piece.kind, 1 + u64(k) + piece.offset) {
					return
				}
				// Cut before the closing quote.
				resize(&text, 1 + k + len(piece.bytes))
				f, bad = json.validate(text[:], .Strict).?
				if piece.kind == nil && !testing.expectf(t, bad && f.kind == .Truncated && f.offset == u64(len(text)), "%q: %v", text[:], f) {
					return
				}
			}
		}
	}
}

@(test)
depth_limit :: proc(t: ^testing.T) {
	deep := strings.concatenate({strings.repeat("[", json.MAX_DEPTH, context.temp_allocator), strings.repeat("]", json.MAX_DEPTH, context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(t, json.validate(transmute([]u8)deep, .Strict), nil)
	over := strings.repeat("[{\"a\":", json.MAX_DEPTH, context.temp_allocator)
	f, bad := json.validate(transmute([]u8)over, .Strict).?
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
