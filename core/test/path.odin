package core_tests

import "core:slice"
import "core:testing"
import core "../"
import p "../path"

N :: p.Name
I :: p.Index
A :: p.Any

// `parse_path` with its fault unwrapped, as these tables read it.
parse :: proc(text: string, steps: []p.Step, names: []u8 = nil) -> (got: p.Path, fault: p.Parse_Fault, ok: bool) {
	perr: Maybe(p.Parse_Fault)
	got, perr = p.parse_path(text, steps, names)
	fault, ok = perr.?
	return got, fault, !ok
}

// Every text path must lower to exactly the steps (and limit) a caller would write by hand, so nothing
// downstream can tell which form produced the path. The first block is one of each form of the jq subset
// the parser takes: bare and quoted names, an index, a negative index, `[]` and the root.
@(test)
test_parse_lowers_to_hand_built_steps :: proc(t: ^testing.T) {
	cases := []struct {
		text:  string,
		want:  []p.Step,
		limit: int,
	}{
		// One of each form.
		{".a.b", {N("a"), N("b")}, 0},
		{`."a-b"`, {N("a-b")}, 0},
		{`.["a-b"]`, {N("a-b")}, 0},
		{".[0]", {I(0)}, 0},
		{".[-1]", {I(-1)}, 0},
		{".[]", {A{}}, 0},
		{`.""`, {N("")}, 0}, // the empty key is a member like another
		{`.a[""]`, {N("a"), N("")}, 0},
		{".a[]", {N("a"), A{}}, 0},
		{".", {}, 0}, // the root
		// More of the subset.
		{".port", {N("port")}, 0},
		{".a.b.c.d.e", {N("a"), N("b"), N("c"), N("d"), N("e")}, 0},
		{"._x1.Y_2", {N("_x1"), N("Y_2")}, 0},
		{".a.[0]", {N("a"), I(0)}, 0}, // jq 1.7 allows a dot before a bracket
		{`."a".b`, {N("a"), N("b")}, 0},
		{`.a."b-c"`, {N("a"), N("b-c")}, 0},
		{`."po.rt"`, {N("po.rt")}, 0}, // quotes escape a literal dot
		{`.a["b[c"]`, {N("a"), N("b[c")}, 0},
		{".results[5]", {N("results"), I(5)}, 0},
		{".a.b[0].c", {N("a"), N("b"), I(0), N("c")}, 0},
		{".[10][-20]", {I(10), I(-20)}, 0},
		{".[][].id", {A{}, A{}, N("id")}, 0},
		{".logs[].id", {N("logs"), A{}, N("id")}, 0},
		{"limit(2; .logs[].id)", {N("logs"), A{}, N("id")}, 2},
		// Both ends of the i64 range stay exact. Leading zeros are digits, not magnitude.
		{".[9223372036854775807]", {I(9223372036854775807)}, 0},
		{".[-9223372036854775808]", {I(-9223372036854775808)}, 0},
		{".[00000000000000000005]", {I(5)}, 0},
		{".[-00000000000000000005]", {I(-5)}, 0},
		// The limit wrappers.
		{"first(.a)", {N("a")}, 1},
		{"first(.[].id)", {A{}, N("id")}, 1},
		{"first(.)", {}, 1},
		{"limit(3; .a[])", {N("a"), A{}}, 3},
		{"limit(10;.a)", {N("a")}, 10},
		{"limit(9223372036854775807; .a)", {N("a")}, 9223372036854775807},
		// Whitespace around the text and inside the wrappers, never inside a path.
		{"  .a.b \n", {N("a"), N("b")}, 0},
		{" first( .a ) ", {N("a")}, 1},
		{"\tlimit( 2 ;\t.a ) ", {N("a")}, 2},
	}
	for tc in cases {
		buf: [16]p.Step
		got, fault, ok := parse(tc.text, buf[:])
		if !ok {
			testing.expectf(t, false, "%q: parse failed at %d with %v", tc.text, fault.offset, fault.error)
			continue
		}
		testing.expectf(t, slice.equal(got.steps, tc.want), "%q: steps %v, want %v", tc.text, got.steps, tc.want)
		testing.expectf(t, got.limit == tc.limit, "%q: limit %d, want %d", tc.text, got.limit, tc.limit)
	}
}

// Each construct outside the subset is `Unsupported_Syntax`, at the byte that leaves it.
@(test)
test_parse_refuses_what_is_outside_the_subset :: proc(t: ^testing.T) {
	cases := []struct {
		text: string,
		at:   int,
	}{
		{"..", 1}, // recurse
		{".a..b", 3},
		{".a | .b", 3}, // pipe
		{".a|.b", 2},
		{".a, .b", 2}, // comma
		{".a?", 2}, // try
		{".[]?", 3},
		{".a-b", 2}, // a subtraction in jq
		{".a+1", 2},
		{".a b", 3}, // no whitespace inside a path
		{". a", 2},
		{".[1:2]", 3}, // slices
		{".[:2]", 2},
		{".[1:]", 3},
		{".[abc]", 2}, // an expression in brackets
		{".[.a]", 2},
		{`.a|select(.b)`, 2}, // filters and functions
		{"select(.a)", 0},
		{"map(.a)", 0},
		{"length", 0},
		{"first", 0}, // jq's `first` is `.[0]`, not the wrapper
		{"$x", 0},
		{"a.b", 0}, // no leading dot: not a jq path
		{"a", 0},
		{"", 0}, // an empty program has no path to lower
		{"   ", 3},
		{"first(first(.a))", 6}, // wrappers do not nest
		{"first(limit(2; .a))", 6},
		{"limit(2; first(.a))", 9},
		{"first (.a)", 0}, // the wrapper's name is followed directly by `(`
		{"first(.a", 8}, // unclosed paren
		{"first(.a))", 9},
		{"first(.a) .b", 10},
		{"limit(0; .a)", 6}, // a limit of 0 has no form here (0 asks for every answer)
		{"limit(-1; .a)", 6},
		{"limit(x; .a)", 6},
		{"limit(; .a)", 6},
		{"limit(1 .a)", 8},
		{"limit(1, .a)", 7},
		{"limit(1.5; .a)", 7},
		{`."a\(1)"`, 3}, // string interpolation
		{`."a""b"`, 4}, // two names with no dot
		{`.a"b"`, 2},
		{".a.-", 3},
	}
	for tc in cases {
		expect_parse_fault(t, tc.text, .Unsupported_Syntax, tc.at)
	}
}

// `text` parses to nothing: no steps, no limit, and the fault `want` at byte `at`.
@(private = "file")
expect_parse_fault :: proc(t: ^testing.T, text: string, want: p.Parse_Error, at: int, loc := #caller_location) {
	buf: [16]p.Step
	got, fault, ok := parse(text, buf[:])
	testing.expectf(t, !ok && len(got.steps) == 0 && got.limit == 0 && fault.error == want && int(fault.offset) == at,
		"%q: got ok=%v steps=%d limit=%d err=%v at %d, want %v at %d", text, ok, len(got.steps), got.limit, fault.error, fault.offset, want, at, loc = loc)
}

// A malformed construct inside the subset keeps its own fault, so a caller can tell "you wrote this
// wrong" from "this is not supported". A fault writes no steps, so a caller never holds a partial path.
//
// An index past `2^63 - 1` has no `i64` answer and refuses as `.Limit_Index`. A Limit fault reports
// the construct that exceeded the budget, so its offset is the index's first byte
// (the sign, when there is one), not the digit that overflowed.
@(test)
test_parse_faults_write_nothing :: proc(t: ^testing.T) {
	cases := []struct {
		text: string,
		want: p.Parse_Error,
		at:   int,
	}{
		{".a[", .Unclosed_Bracket, 2},
		{`.a["b`, .Unclosed_Quote, 3},
		{`.a["b"`, .Unclosed_Bracket, 2},
		{`.a.b["unclosed`, .Unclosed_Quote, 5},
		{`."unclosed`, .Unclosed_Quote, 1},
		{".a[-]", .Bad_Index, 3},
		{".a[1x]", .Bad_Index, 3},
		{".a[1", .Bad_Index, 3},
		{".a.", .Empty_Key, 3}, // a separator names no step
		{".a. ", .Empty_Key, 3},
		{`."a\x"`, .Bad_Escape, 3}, // not a JSON escape
		{`."\u12"`, .Bad_Escape, 2},
		{`."\ud83d"[0]`, .Bad_Escape, 2}, // a lone surrogate half
		{`."\ude00\ud83d"`, .Bad_Escape, 2},
		{`."\ud83d\u0041"`, .Bad_Escape, 2},
		{`."a\`, .Unclosed_Quote, 1},
		{`.["a\"]`, .Unclosed_Quote, 2}, // the quote is escaped
		{"first(.a.)", .Empty_Key, 9},
		{".[9223372036854775808]", .Limit_Index, 2}, // 2^63: positive has no i64
		{".[-9223372036854775809]", .Limit_Index, 2}, // 2^63+1: negative does not either
		{".[18446744073709551616]", .Limit_Index, 2}, // 2^64
		{".[99999999999999999999]", .Limit_Index, 2}, // 20 digits
		{".a.b[9223372036854775808]", .Limit_Index, 5}, // mid-path
		{"limit(9223372036854775808; .a)", .Limit_Index, 6}, // past what `Path.limit` holds
		{"limit(99999999999999999999; .a)", .Limit_Index, 6},
	}
	for tc in cases {
		expect_parse_fault(t, tc.text, tc.want, tc.at)
	}
}

@(test)
test_parse_out_of_room :: proc(t: ^testing.T) {
	buf: [1]p.Step
	got, fault, ok := parse(".a.b.c", buf[:])
	testing.expectf(t, !ok && len(got.steps) == 0 && fault.error == .Out_Of_Room && fault.offset == 3,
		"a short buffer must report Out_Of_Room at the step that did not fit, got ok=%v err=%v at %d", ok, fault.error, fault.offset)
}

// A quoted name is a JSON string: its escapes decode into `names`, which `len(text)` bytes always hold, and
// a name without one still borrows the text.
@(test)
test_parse_decodes_escaped_names :: proc(t: ^testing.T) {
	cases := []struct {
		text: string,
		want: []p.Step,
	}{
		{`."a\"b"`, {N(`a"b`)}},
		{`.["a\\b"]`, {N(`a\b`)}},
		{`."\/\b\f\n\r\t"`, {N("/\b\f\n\r\t")}},
		{`.x."\u00e9\u20AC".y`, {N("x"), N("é€"), N("y")}},
		{`."\ud83d\ude00"`, {N("😀")}},
		{`limit(2; ."a\"".["\"b"])`, {N(`a"`), N(`"b`)}},
	}
	for tc in cases {
		buf: [16]p.Step
		names := make([]u8, len(tc.text), context.temp_allocator)
		got, fault, ok := parse(tc.text, buf[:], names)
		testing.expectf(t, ok && slice.equal(got.steps, tc.want), "%q: steps %v (%v), want %v", tc.text, got.steps, fault, tc.want)
		_, fault, ok = parse(tc.text, buf[:])
		testing.expectf(t, !ok && fault.error == .Out_Of_Room, "%q: no names buffer is %v", tc.text, fault)
	}
	buf: [4]p.Step
	got, _, ok := parse(`."plain"`, buf[:])
	testing.expect(t, ok && len(got.steps) == 1 && string(got.steps[0].(p.Name)) == "plain")
}

// A `.Last` run settles early only when no step is a `Name`: an index-then-name path parks its answer until
// the root closes (`path_prefix_is_deterministic`), so a stop test for it would wait on a promise it cannot keep.
@(test)
test_last_settles_early_on_indices_only :: proc(t: ^testing.T) {
	Case :: struct {
		steps: []p.Step,
		want:  bool,
	}
	for c in ([]Case{{{I(0), I(1)}, true}, {{I(0), N("a")}, false}, {{N("a"), I(0)}, false}}) {
		run := core.Path_Run{steps = c.steps, mode = .Last}
		testing.expectf(t, core.path_run_may_settle_early(&run) == c.want, "%v: want %v", c.steps, c.want)
	}
}
