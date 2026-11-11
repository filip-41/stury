package json_tests

import "core:math/rand"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import core "../../core"
import json ".."
import gen "gen"
import walktest "../../walktest"

Case :: struct {
	text:   string,
	kind:   core.Fault_Kind, // nil for a valid text
	offset: u64,
	detail: json.Detail,
}

// The kind a case names for `Bad_Char` with `Detail.Trailing`, which only `validate` reports.
TRAILING :: core.Fault_Kind(0xff)

// Holds each fault of a JSON text at the byte its rule names. A `nil` kind is a valid text.
@(rodata)
CASES := []Case {
	{"0", nil, 0, .None},
	{"-0.5e+10", nil, 0, .None},
	{"\"\\ud83d\\ude00\\u00e9\\/\"", nil, 0, .None},
	{" [[], {}, {\"a\": [true, false, null]}] \n", nil, 0, .None},
	{"\xef\xbb\xbf[]", nil, 0, .None},
	{"", .Truncated, 0, .None},
	{"   ", .Truncated, 3, .None},
	{"[", .Truncated, 1, .None},
	{"[1,", .Truncated, 3, .None},
	{"[1 ", .Truncated, 3, .None},
	{"{\"a\"", .Truncated, 4, .None},
	{"{\"a\":", .Truncated, 5, .None},
	{"\"abc", .Truncated, 4, .None},
	{"\"\\", .Truncated, 2, .None},
	{"\"\\u12", .Truncated, 5, .None},
	{"\"\\ud800\\u", .Truncated, 9, .None},
	{"\"\xc3", .Truncated, 2, .None},
	{"\"\xf0\x9f\x98", .Truncated, 4, .None},
	{"tru", .Truncated, 3, .None},
	{"-", .Truncated, 1, .None},
	{"1.", .Truncated, 2, .None},
	{"1e", .Truncated, 2, .None},
	{"1e+", .Truncated, 3, .None},
	{"x", .Bad_Char, 0, .Literal},
	{"[1 2]", .Bad_Char, 3, .Array_Separator},
	{"[1}", .Bad_Char, 2, .Unmatched_Brace},
	{"[}", .Bad_Char, 1, .Unmatched_Brace},
	{"\"a\x01\"", .Bad_Char, 2, .Control_Char},
	{"\"\xff\"", .Bad_Char, 1, .Invalid_Utf8},
	{"\"\xc3\x28\"", .Bad_Char, 1, .Invalid_Utf8},
	{"\"\xc0\x80\"", .Bad_Char, 1, .Invalid_Utf8},
	{"\"\xed\xa0\x80\"", .Bad_Char, 1, .Invalid_Utf8},
	{"\"\xf4\x90\x80\x80\"", .Bad_Char, 1, .Invalid_Utf8},
	{"\"\xf0\x9f\x98x\"", .Bad_Char, 1, .Invalid_Utf8},
	{"\xef\xbb\xbf\xef\xbb\xbf[]", .Bad_Char, 3, .Expected_Value},
	{"\"\\x\"", .Bad_Escape, 2, .None},
	{"\"\\u12g4\"", .Bad_Escape, 5, .None},
	{"\"\\udc00\"", .Bad_Escape, 1, .None},
	{"\"\\ud800\"", .Bad_Escape, 1, .None},
	{"\"\\ud800\\u0041\"", .Bad_Escape, 1, .None},
	{"\"\\ud800\\x\"", .Bad_Escape, 1, .None},
	{"\"\\ud83d\\ude0\"", .Bad_Escape, 1, .None},
	{"01", .Bad_Number, 1, .Leading_Zero},
	{"-01", .Bad_Number, 2, .Leading_Zero},
	{"-a", .Bad_Number, 1, .None},
	{"1.x", .Bad_Number, 2, .None},
	{"[1e+]", .Bad_Number, 4, .None},
	{"1 2", TRAILING, 2, .None},
	{"{}x", TRAILING, 2, .None},
	// Texts `core:encoding/json` accepts in `.JSON` mode that the walk refuses (odin-lang/Odin#8061).
	{"[\"a\x01b\"]", .Bad_Char, 3, .Control_Char},
	{"[\"\\q\"]", .Bad_Escape, 3, .None},
	{"[1e]", .Bad_Number, 3, .None},
	{"[\"\xff\"]", .Bad_Char, 2, .Invalid_Utf8},
	{"[\"\\ud800\"]", .Bad_Escape, 2, .None},
	{"[1,]", .Bad_Char, 3, .Trailing_Comma},
	{"[01]", .Bad_Number, 2, .Leading_Zero},
	{"[1.]", .Bad_Number, 3, .None},
	{"\v[1]", .Bad_Char, 0, .Control_Char},
	{"[1]\x00garbage", TRAILING, 3, .None},
	// Number elements and number-valued members after a number, each read as its own number run.
	{"[1, -2, 3.5e1, 0]", nil, 0, .None},
	{"{\"a\": 1, \"b\" : -2, \"c\":3, \"d\": [4, 5]}", nil, 0, .None},
	{"[1, 2, 01, 3]", .Bad_Number, 8, .Leading_Zero},
	{"[1, 2,  x]", .Bad_Char, 8, .Literal},
	{"[1, 2, ]", .Bad_Char, 7, .Trailing_Comma},
	{"{\"a\": 1, \"b\": x}", .Bad_Char, 14, .Literal},
}

// Holds texts faulted at a literal's first wrong letter, with `Detail.Literal`.
@(rodata)
LITERAL_CASES := []Case{{"trUe", .Bad_Char, 2, .Literal}, {"nulx", .Bad_Char, 3, .Literal}, {"falsy", .Bad_Char, 4, .Literal}}

// Holds JSONC texts with comments and trailing commas, and the faults they raise under `.Jsonc`.
@(rodata)
JSONC_CASES := []Case {
	{"// a\n[1, /* b */ 2 // c\r] /* d */", nil, 0, .None},
	{"/**/[/* a\n*/]//", nil, 0, .None},
	{"{ /* a */ \"k\" /* b */ : /* c */ 1 /* d */ , /* e */ }", nil, 0, .None},
	{"[1, 2, ]", nil, 0, .None},
	{"{\"a\": 1, \"b\" : 2, \"c\":3,}", nil, 0, .None},
	{"{\"a\": [1,], \"b\": {\"c\": {},},}", nil, 0, .None},
	{"// é 😀\n1", nil, 0, .None},
	{"/* \"*/ \"x\"", nil, 0, .None},
	{"[1, /*", .Truncated, 6, .None},
	{"[1 /", .Bad_Char, 3, .None},
	{"/", .Bad_Char, 0, .None},
	{"1 /", TRAILING, 2, .None},
	{"1 /* a */ /", TRAILING, 10, .None},
	{"1 /* a", .Truncated, 6, .None},
	{"/* a */", .Truncated, 7, .None},
	{"// a", .Truncated, 4, .None},
	{"{\"a\" /* b */", .Truncated, 12, .None},
	{"[1 /x]", .Bad_Char, 3, .None},
	{"[/ 1]", .Bad_Char, 1, .None},
	{"1 /x", TRAILING, 2, .None},
	{"[// \xff\n1]", .Bad_Char, 4, .Invalid_Utf8},
	{"[/* \xc3\x28 */1]", .Bad_Char, 4, .Invalid_Utf8},
	{"[// a\x00\n1]", .Bad_Char, 5, .Control_Char},
	{"[/* a\x1f */1]", .Bad_Char, 5, .Control_Char},
	{"[/*\t\r\n*/ //\t\r1]", nil, 0, .None},
	{"[,]", .Bad_Char, 1, .Lone_Comma},
	{"[1,,]", .Bad_Char, 3, .Lone_Comma},
	{"[1, /* a */ ,]", .Bad_Char, 12, .Lone_Comma},
	{"1 // a\n2", TRAILING, 7, .None},
	{"1 /* a */ 2", TRAILING, 10, .None},
}

// Holds JSONC texts that raise a fault under `.Json`.
@(rodata)
JSONC_IN_JSON := []Case {
	{"// a\n[1]", .Bad_Char, 0, .Expected_Value},
	{"[1 /* a */]", .Bad_Char, 3, .Array_Separator},
	{"[1, 2, ]", .Bad_Char, 7, .Trailing_Comma},
	{"1 // a", TRAILING, 2, .None},
}

@(rodata)
JSON5_CASES := []Case {
	{"{a: 1, $b_: 'x', _c: \"y\",}", nil, 0, .None},
	{"[0x1F, -0XaB, +1, .5, 5., +.5e3, Infinity, -Infinity, +NaN, NaN, 1e5,]", nil, 0, .None},
	{"'a\\'b\"c'", nil, 0, .None},
	{"\"\\x41\\0\\v\\q\\/\"", nil, 0, .None},
	{"'a\\\nb\\\r\nc\\\rd\\\xe2\x80\xa8e'", nil, 0, .None},
	{"\"a\xe2\x80\xa8b\xe2\x80\xa9c\t\x01\"", nil, 0, .None},
	{"\v\f\xc2\xa0\xef\xbb\xbf[1]\xe2\x80\xa9\xe3\x80\x80", nil, 0, .None},
	{"{\xc7\x85: 1, \xe2\x85\xab: 2, a\xcc\x81: 3, a\xd9\xa3: 4, a\xe2\x80\xbfb: 5, a\xe2\x80\x8cb: 6, \\u0061b: 7, a\\u0062: 8}", nil, 0, .None},
	{"[// a\x00\n1]", .Bad_Char, 5, .Control_Char},
	{"[/* a\x1f */1]", .Bad_Char, 5, .Control_Char},
	{"[// a\x0b\n1]", .Bad_Char, 5, .Control_Char},
	{"[/*\t\r\n*/ //\t\r1]", nil, 0, .None},
	{"// a\xe2\x80\xa81", nil, 0, .None},
	{"/* a */ {/* b */ k /* c */ : /* d */ 'v' /* e */, /* f */}", nil, 0, .None},
	{"0x", .Truncated, 2, .None},
	{"0xg", .Bad_Number, 2, .None},
	{"[0x]", .Bad_Number, 3, .None},
	{"01", .Bad_Number, 1, .None},
	{"+01", .Bad_Number, 2, .None},
	{".", .Truncated, 1, .None},
	{".e1", .Bad_Number, 1, .None},
	{"+", .Truncated, 1, .None},
	{"+-1", .Bad_Number, 1, .None},
	{"Infinit", .Truncated, 7, .None},
	{"Inf]", .Bad_Number, 3, .None},
	{"-NaN1", TRAILING, 4, .None},
	{"[1, Infinityx]", .Bad_Char, 12, .Array_Separator},
	{"5.e", .Truncated, 3, .None},
	{"'abc", .Truncated, 4, .None},
	{"'a\nb'", .Bad_Char, 2, .Control_Char},
	{"\"a\\x1\"", .Bad_Escape, 5, .None},
	{"'\\1'", .Bad_Escape, 2, .None},
	{"'\\01'", .Bad_Escape, 3, .None},
	{"'\\x", .Truncated, 3, .None},
	{"\"\\ud800\"", .Bad_Escape, 1, .None},
	{"{a\\x: 1}", .Bad_Escape, 3, .None},
	{"{a\\u0020b: 1}", .Bad_Escape, 2, .None},
	{"{\\u0031: 1}", .Bad_Escape, 1, .None},
	{"{a\\u00: 1}", .Bad_Escape, 6, .None},
	{"{a\xff: 1}", .Bad_Char, 2, .Invalid_Utf8},
	{"[1 \xc2]", .Bad_Char, 3, .Array_Separator},
	{"\xa0", .Bad_Char, 0, .Invalid_Utf8},
	{"[1,,]", .Bad_Char, 3, .Lone_Comma},
	{"/* a", .Truncated, 4, .None},
}

// Holds JSON5 keys that start with no identifier character, faulted with `Detail.Identifier`.
@(rodata)
JSON5_KEY_CASES := []Case {
	{"{1: 2}", .Bad_Char, 1, .Identifier},
	{"{-a: 1}", .Bad_Char, 1, .Identifier},
	{"{a: 1, @: 2}", .Bad_Char, 7, .Identifier},
	{"{\xcc\x81a: 1}", .Bad_Char, 1, .Identifier},
	{"{a: 1,,}", .Bad_Char, 6, .Identifier},
	{"{/}", .Bad_Char, 1, .Identifier},
}

// Holds JSON5 texts that raise a fault under `.Jsonc`.
@(rodata)
JSON5_IN_JSONC := []Case {
	{"[0x1]", .Bad_Char, 2, .Array_Separator},
	{"'a'", .Bad_Char, 0, .Single_Quote},
	{"[\v1]", .Bad_Char, 1, .Control_Char},
	{"NaN", .Bad_Char, 0, .Non_Finite},
}

// Holds bytes where an object's key must start, which JSON and JSONC fault with no string.
@(rodata)
KEY_CASES := []Case {
	{"{1:2}", .Bad_Char, 1, .Key_Not_String},
	{"{\"a\": 1, b: 2}", .Bad_Char, 9, .Key_Not_String},
	{"{\"a\": 1, \"b\" : 2, \"c\":3,}", .Bad_Char, 24, .Trailing_Comma},
	{"{\"a\":1,}", .Bad_Char, 7, .Trailing_Comma},
}

@(rodata)
KEY_CASES_JSONC := []Case {
	{"{,}", .Bad_Char, 1, .Lone_Comma},
	{"{\"a\": 1, /* b */ 2}", .Bad_Char, 17, .Key_Not_String},
	{"{a: 1}", .Bad_Char, 1, .Key_Not_String},
}

// Holds bytes where a member's colon must stand, with `Detail.Colon`.
@(rodata)
COLON_CASES := []Case {
	{"{\"a\" 1}", .Bad_Char, 5, .Colon},
	{"{\"a\" ,1}", .Bad_Char, 5, .Colon},
	{"{\"a\" [1]}", .Bad_Char, 5, .Colon},
}

@(rodata)
COLON_CASES_JSONC := []Case {
	{"{\"a\" 1}", .Bad_Char, 5, .Colon},
	{"{\"a\" /* c */ 1}", .Bad_Char, 13, .Colon},
	{"{\"a\" /x : 1}", .Bad_Char, 5, .Colon},
	{"{\"a\" /* c */ / : 1}", .Bad_Char, 13, .Colon},
}

@(rodata)
COLON_CASES_JSON5 := []Case {
	{"{a b: 1}", .Bad_Char, 3, .Colon},
	{"{a /* c */ 1}", .Bad_Char, 11, .Colon},
	{"{a é: 1}", .Bad_Char, 3, .Colon},
	{"{\"a\" é: 1}", .Bad_Char, 6, .Colon},
	{"{a /* c */é: 1}", .Bad_Char, 10, .Colon},
	{"{a / 1}", .Bad_Char, 3, .Colon},
}

@(test)
faults_at_their_byte :: proc(t: ^testing.T) {
	for c in CASES {
		expect_fault(t, c, .Json)
	}
	for c in LITERAL_CASES {
		expect_fault(t, c, .Json)
	}
	for c in JSONC_CASES {
		expect_fault(t, c, .Jsonc)
	}
	for c in JSONC_IN_JSON {
		expect_fault(t, c, .Json)
	}
	for c in JSON5_CASES {
		expect_fault(t, c, .Json5)
	}
	for c in JSON5_KEY_CASES {
		expect_fault(t, c, .Json5)
	}
	for c in JSON5_IN_JSONC {
		expect_fault(t, c, .Jsonc)
	}
	for c in KEY_CASES {
		expect_fault(t, c, .Json)
	}
	for c in KEY_CASES_JSONC {
		expect_fault(t, c, .Jsonc)
	}
	for c in COLON_CASES {
		expect_fault(t, c, .Json)
	}
	for c in COLON_CASES_JSONC {
		expect_fault(t, c, .Jsonc)
	}
	for c in COLON_CASES_JSON5 {
		expect_fault(t, c, .Json5)
	}
}

// `refuse_non_finite` faults at the first byte of a JSON5 `Infinity` or `NaN`, sign included, with
// `Detail.Non_Finite`, and leaves hex and JSON5's decimals read.
@(test)
non_finite_refused :: proc(t: ^testing.T) {
	refuse := json.Options{refuse_non_finite = true}
	for c in ([]Case{{"[1, NaN]", .Bad_Char, 4, .Non_Finite}, {"{a: -Infinity}", .Bad_Char, 4, .Non_Finite}, {"+NaN", .Bad_Char, 0, .Non_Finite}, {"[0x10, +1, .5, 5.]", nil, 0, .None}}) {
		src := transmute([]u8)c.text
		want: Maybe(core.Fault)
		if c.kind != nil {
			want = core.Fault{c.offset, &json.RULES, .Bad_Char, u8(c.detail)}
		}
		verdict := walktest.fault_of(core.validate(src, json.as(.Json5, refuse)))
		testing.expectf(t, verdict == want, "%q: validate %v, want %v", c.text, verdict, want)
		log := new(walktest.Log)
		defer free(log)
		_, fault := json.walk(src, 0, .Json5, refuse, log, &core.Hook_Regs{}, walktest.log_hook)
		testing.expectf(t, fault == want, "%q: hooked walk %v, want %v", c.text, fault, want)
	}
}

// Returns the fault of a walk of `text` whose hook skips the token numbered `token`.
walk_skipping :: proc(text: string, spec: json.Spec, token: int) -> (fault: Maybe(core.Fault)) {
	skip := token
	src := transmute([]u8)text
	switch spec {
	case .Json:  _, fault = json.walk(src, 0, .Json, {}, &skip, &core.Hook_Regs{}, skip_hook)
	case .Jsonc: _, fault = json.walk(src, 0, .Jsonc, {}, &skip, &core.Hook_Regs{}, skip_hook)
	case .Json5: _, fault = json.walk(src, 0, .Json5, {}, &skip, &core.Hook_Regs{}, skip_hook)
	}
	return
}

// A walk whose hook skips a key still faults at the byte where its colon must stand, with `Detail.Colon`, the
// comments around the colon passed over.
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
		fault := walk_skipping(want.text, want.spec, 1)
		f := core.Fault{want.at, &json.RULES, .Bad_Char, u8(json.Detail.Colon)}
		testing.expectf(t, fault == f, "%v %q: %v, want %v", want.spec, want.text, fault, f)
	}
}

// A walk whose hook skips a container or a key faults at the first byte after the skipped container's close where
// that byte is no close, whatever its value, so `0xDD` and `0xFD`, `]` and `}` with bit 7 set, are `Bad_Char`.
@(test)
byte_after_skipped_close :: proc(t: ^testing.T) {
	Skipped :: struct {
		text:  string,
		token:  int,
		at:     u64,
		detail: json.Detail,
	}
	for want in ([]Skipped {
		{"[[1]\xdd,2]", 1, 4, .Array_Separator},
		{"[{}\xdd]", 1, 3, .Array_Separator},
		{"{\"x\":[1]\xfd,\"a\":1}", 1, 8, .Member_Separator},
		{"{\"x\":[1]\xfd,\"a\":1}", 2, 8, .Member_Separator},
		{"{\"x\":{\"y\":1}\xfd}", 1, 12, .Member_Separator},
		{"{\"x\":{\"y\":1}\xfd}", 2, 12, .Member_Separator},
	}) {
		f := core.Fault{want.at, &json.RULES, .Bad_Char, u8(want.detail)}
		testing.expectf(t, walktest.fault_of(json.validate(transmute([]u8)want.text, .Json)) == f, "%q: validate", want.text)
		for spec in json.Spec {
			fault := walk_skipping(want.text, spec, want.token)
			testing.expectf(t, fault == f, "%v %q, token %d skipped: %v, want %v", spec, want.text, want.token, fault, f)
		}
	}
}

// Checks `validate`'s fault against `c`, then checks that a hooked walk returns the same fault, except `TRAILING`,
// which only `validate` reports, and a text with no value, where the walk returns no fault.
expect_fault :: proc(t: ^testing.T, c: Case, $S: json.Spec) {
	src := transmute([]u8)c.text
	verdict := walktest.fault_of(json.validate(src, S))
	f, bad := verdict.?
	if c.kind == nil {
		testing.expectf(t, !bad, "%v %q: %v", S, c.text, f)
	} else if c.kind == TRAILING {
		testing.expectf(t, bad && f == {c.offset, &json.RULES, .Bad_Char, u8(json.Detail.Trailing)}, "%v %q: %v, want trailing at %d", S, c.text, f, c.offset)
	} else {
		testing.expectf(t, bad && f.kind == c.kind && f.at == c.offset && f.detail == u8(c.detail), "%v %q: %v, want %v at %d", S, c.text, f, c.kind, c.offset)
	}
	if c.kind != TRAILING {
		log := new(walktest.Log)
		defer free(log)
		_, fault := json.walk(src, 0, S, {}, log, &core.Hook_Regs{}, walktest.log_hook)
		empty := fault == nil && log.n == 0
		testing.expectf(t, empty || fault == verdict, "%v %q: hooked walk %v, validate %v", S, c.text, fault, verdict)
	}
}

// Validates `src` from a copy at the end of `fence`'s readable page, with the page after it unreadable, so a read past
// the end faults in every build.
validate_fenced :: proc(fence: ^walktest.Fence, src: []u8, $S: json.Spec, opts := json.Options{}) -> Maybe(core.Fault) {
	return walktest.fault_of(json.validate(walktest.fence_copy(fence, src), S, opts))
}

// Validates every prefix of 900 seeded texts, compact and pretty, from a copy that ends at a guard page: each prefix
// gives the same fault as the same text validated without the fence.
@(test)
prefixes_fenced :: proc(t: ^testing.T) {
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)
	text: [dynamic]u8
	defer delete(text)
	fence := walktest.fence_init()
	defer walktest.unfence(&fence)
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
				same = validate_fenced(&fence, text[:n], .Json) == walktest.fault_of(json.validate(text[:n], .Json))
			case .Jsonc:
				same = validate_fenced(&fence, text[:n], .Jsonc) == walktest.fault_of(json.validate(text[:n], .Jsonc))
			case .Json5:
				same = validate_fenced(&fence, text[:n], .Json5) == walktest.fault_of(json.validate(text[:n], .Json5))
			}
			if !testing.expectf(t, same, "%v %q", spec, text[:n]) {
				return
			}
		}
	}
}

// Returns `.Skip` on the token numbered `h^`, counted from 0, and `.Next` on every other token.
skip_hook :: proc "contextless" (h: ^int, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	h^ -= 1
	return s, .Skip if h^ == -1 else .Next
}

// Tests `max_depth` 1, 3, the default and 5000. That many levels pass and the next bracket is `Too_Deep`, for an
// array and an object, through `validate`, a hooked walk, and a walk that skips the root or its first key. The depth
// stack comes from the default heap even when `context.allocator` is the panic allocator.
@(test)
max_depth_option :: proc(t: ^testing.T) {
	heap := context.allocator
	log := new(walktest.Log)
	defer free(log, heap)
	context.allocator = mem.panic_allocator()
	for depth in ([]u32{1, 3, core.MAX_DEPTH, core.MAX_DEPTH + 1, 5000}) {
		n := int(depth)
		fits := strings.concatenate({strings.repeat("[", n, context.temp_allocator), strings.repeat("]", n, context.temp_allocator)}, context.temp_allocator)
		testing.expectf(t, walktest.fault_of(json.validate(transmute([]u8)fits, .Json, {max_depth = depth})) == nil, "%d levels", n)
		over := strings.concatenate({strings.repeat("[{\"a\":", n / 2, context.temp_allocator), strings.repeat("[", n % 2 + 1, context.temp_allocator)}, context.temp_allocator)
		f, bad := walktest.fault_of(json.validate(transmute([]u8)over, .Json, {max_depth = depth})).?
		testing.expectf(t, bad && f.kind == .Too_Deep && f.at == u64(len(over) - 1), "%d levels: %v", n, f)
		log^ = {}
		_, fault := json.walk(transmute([]u8)over, 0, .Json, {max_depth = depth}, log, &core.Hook_Regs{}, walktest.log_hook)
		testing.expectf(t, fault == f && log.n == n + n / 2, "%d levels, walked: %v, %d tokens", n, fault, log.n)
		maps := strings.concatenate({strings.repeat("{\"a\":", n, context.temp_allocator), "{"}, context.temp_allocator)
		f, bad = walktest.fault_of(json.validate(transmute([]u8)maps, .Json, {max_depth = depth})).?
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
	tol:    bit_set[core.Tolerance; u8],
	kind:   core.Fault_Kind, // nil where `tol` tolerates every fault
	offset: u64,
}

// Holds texts a tolerance set accepts, and faults the set does not accept, which are the same as without it.
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
	{.Json, "\"\\ud83d\\ude0\"", {.Lone_Surrogate}, .Bad_Escape, 12},
	{.Json, "\"\\ud800\\u00g1\"", {.Lone_Surrogate}, .Bad_Escape, 11},
	{.Json, "\"\\ud800\\u", {.Lone_Surrogate}, .Truncated, 9},
	{.Json, "\"\xff\"", {.Lone_Surrogate}, .Bad_Char, 1},
	{.Json, "\"\xff\\ud800\"", {.Invalid_Utf8, .Lone_Surrogate, .Ragged, .Bare_Quote}, nil, 0},
	{.Json, "[\"\xff\",\"\\ud800\"]", {.Ragged, .Bare_Quote}, .Bad_Char, 2},
	{.Jsonc, "\"\xff\" // \\ud800", {.Invalid_Utf8}, nil, 0},
	{.Jsonc, "// \xff\n1", {.Invalid_Utf8, .Lone_Surrogate}, .Bad_Char, 3},
	{.Jsonc, "/* \xff */1", {.Invalid_Utf8, .Lone_Surrogate}, .Bad_Char, 3},
	{.Jsonc, "1 // \xe2\x82", {.Invalid_Utf8}, .Truncated, 7},
	{.Json5, "'\xff'", {.Invalid_Utf8}, nil, 0},
	{.Json5, "'\\\xff'", {.Invalid_Utf8}, nil, 0},
	{.Json5, "'\\ud800'", {.Lone_Surrogate}, nil, 0},
	{.Json5, "{\xff:1}", {.Invalid_Utf8, .Lone_Surrogate}, .Bad_Char, 1},
	{.Json5, "// \xff\n1", {.Invalid_Utf8}, .Bad_Char, 3},
	{.Json5, "1 /* \xc3( */", {.Invalid_Utf8}, .Bad_Char, 5},
	{.Json5, "{a\\ud800:1}", {.Invalid_Utf8, .Lone_Surrogate}, .Bad_Escape, 2},
}

// Tests each tolerance through `validate` and a hooked walk: a text the set accepts is clean with it and faulty
// without it, a text the set does not accept keeps its kind and offset, the hooked walk returns `validate`'s fault, and
// every token keeps its span's bytes.
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
}

// Tests the tolerated pieces at every offset from 0 to 139 in each spec, in both of JSON5's quote kinds: each is clean
// with the tolerance set and a fault without it.
@(test)
tolerance_offsets :: proc(t: ^testing.T) {
	tolerance_offsets_in(t, .Json)
	tolerance_offsets_in(t, .Jsonc)
	tolerance_offsets_in(t, .Json5)
}

tolerance_offsets_in :: proc(t: ^testing.T, $S: json.Spec) {
	text: [dynamic]u8
	defer delete(text)
	fence := walktest.fence_init()
	defer walktest.unfence(&fence)
	for quote in ([]u8{'"', '\''}) {
		if S != .Json5 && quote == '\'' {
			continue
		}
		for piece in ([]string{"\xff", "\xe2\x82", "\xf0\x9f\x98x", "\\ud800", "\\udc00\\u0041"}) {
			for k in 0 ..< 140 {
				clear(&text)
				append(&text, quote)
				for _ in 0 ..< k {
					append(&text, 'a')
				}
				append(&text, piece)
				append(&text, quote)
				f, bad := validate_fenced(&fence, text[:], S, {tolerate = {.Invalid_Utf8, .Lone_Surrogate}}).?
				if !testing.expectf(t, !bad, "%v %q: %v", S, text[:], f) {
					return
				}
				strict, strict_bad := walktest.fault_of(json.validate(text[:], S)).?
				if !testing.expectf(t, strict_bad, "%v %q: strict %v", S, text[:], strict) {
					return
				}
			}
		}
	}
}

expect_tolerated :: proc(t: ^testing.T, c: Tolerated, $S: json.Spec) {
	src := transmute([]u8)c.text
	strict := walktest.fault_of(json.validate(src, S))
	f, bad := walktest.fault_of(json.validate(src, S, {tolerate = c.tol})).?
	if c.kind == nil {
		testing.expectf(t, !bad && strict != nil, "%v %q: %v, strict %v", S, c.text, f, strict)
	} else {
		testing.expectf(t, bad && f.kind == c.kind && f.at == c.offset, "%v %q: %v, want %v at %d", S, c.text, f, c.kind, c.offset)
	}
	log := new(walktest.Log)
	defer free(log)
	_, fault := json.walk(src, 0, S, {tolerate = c.tol}, log, &core.Hook_Regs{}, walktest.log_hook)
	testing.expectf(t, fault == (f if bad else nil), "%v %q: hooked walk %v, validate %v", S, c.text, fault, f)
	for tok in log.tokens[:log.n] {
		testing.expectf(t, spans(src, tok), "%v %q: %v", S, c.text, tok)
	}
}

// `RULES.details` has one entry per `Detail`. A fault renders as `line:col: message`, and `write_code` gives its rule's
// code. A `Lines` keeps the line count between faults in offset order, and a fault before its byte counts from 0
// again.
@(test)
rendered_faults :: proc(t: ^testing.T) {
	testing.expect_value(t, len(json.RULES.details), len(json.Detail))
	src := transmute([]u8)string("{\n  \"a\": tru\n}")
	f, bad := walktest.fault_of(json.validate(src, .Json)).?
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
	for want in ([]Want{{0, .Bad_Char, "1:1: Unexpected character"}, {6, .Bad_Number, "2:5: Invalid number"}, {14, .Truncated, "3:2: Unfinished input"}, {2, .Bad_Char, "2:1: Unexpected text after the value"}, {0, .No_Memory, "Out of memory"}, {0, .None, "No fault"}}) {
		strings.builder_reset(&b)
		detail := u8(json.Detail.Trailing) if want.text == "2:1: Unexpected text after the value" else 0
		core.render(strings.to_writer(&b), src, core.Fault{want.at, &json.RULES, want.kind, detail}, &lines)
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
	// A line ends at its `\n`, a `\r` belongs to its line, and a column counts bytes.
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

// JSONTestSuite: every `y_` text passes, every `n_` text fails, and the `i_` texts are left to the oracle.
@(test)
json_test_suite :: proc(t: ^testing.T) {
	suite := #load_directory("conformance/JSONTestSuite/test_parsing")
	n: int
	for file in suite {
		_, bad := walktest.fault_of(json.validate(file.data, .Json)).?
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

// json5-tests: every `.json` and `.json5` text passes and every `.js` and `.txt` text fails, 114 files in all.
@(test)
json5_tests :: proc(t: ^testing.T) {
	n: int
	for dir in walktest.JSON5_TESTS {
		for file in dir {
			f, bad := walktest.fault_of(json.validate(file.data, .Json5)).?
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
