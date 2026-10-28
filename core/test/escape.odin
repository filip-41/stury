package core_tests

import "core:testing"
import p ".."

// Each escape's decoded bytes and length, and each refusal's fault, at the backslash of `text`.
@(test)
test_decode_escape :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		want:  string,
		fault: p.Escape_Fault,
	}
	cases := [?]Case {
		{"\\n", "\n", .None},
		{"\\/", "/", .None},
		{"\\u0041", "A", .None},
		{"\\u00e9", "é", .None},
		{"\\ud83d\\ude00", "😀", .None},
		{"\\", "", .Truncated},
		{"\\q", "", .Bad_Char},
		{"\\u12", "", .Short_Hex},
		{"\\u12g4", "", .Bad_Hex},
		{"\\ud83d", "", .Bad_Pair},
		{"\\ud83d\\u0041", "", .Bad_Pair},
		{"\\ude00", "", .Lone_Low},
	}
	for c in cases {
		unit: [4]u8
		src := transmute([]byte)c.text
		n, next, fault := p.decode_escape(src, 0, u64(len(src)), unit[:])
		testing.expectf(t, fault == c.fault, "%q: fault %v, want %v", c.text, fault, c.fault)
		if c.fault == .None {
			testing.expectf(t, string(unit[:n]) == c.want && next == u64(len(src)), "%q: %q next %d", c.text, string(unit[:n]), next)
		}
	}
}
