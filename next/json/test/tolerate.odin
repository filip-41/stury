package json_tests

import "core:slice"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:testkit"

@(private = "file")
LAX :: json.Options{tolerate = {.Invalid_Utf8, .Non_Finite}}

@(private = "file")
FFFD :: "�"

// A string with ill-formed UTF-8 and the text it reads as, each maximal subpart of an ill-formed sequence as U+FFFD.
@(private = "file")
Lax_String :: struct {
	bytes: string,
	text:  string,
}

@(private = "file")
LAX_STRINGS := []Lax_String {
	{"a\x80b", "a" + FFFD + "b"}, // a lone continuation byte
	{"\xBF\x80", FFFD + FFFD},
	{"\xC0\xAF", FFFD + FFFD}, // overlong, with a lead no sequence has
	{"\xC1\xBF", FFFD + FFFD},
	{"\xE0\x80\xAF", FFFD + FFFD + FFFD}, // overlong, with a second byte its lead refuses
	{"\xF0\x80\x80\xAF", FFFD + FFFD + FFFD + FFFD},
	{"\xED\xA0\x80", FFFD + FFFD + FFFD}, // a surrogate code point
	{"\xED\xBF\xBF", FFFD + FFFD + FFFD},
	{"\xF4\x90\x80\x80", FFFD + FFFD + FFFD + FFFD}, // past U+10FFFF
	{"\xE2\x82", FFFD}, // cut at the string's end
	{"\xF0\x9F\x98", FFFD},
	{"\xE2\x82x", FFFD + "x"},
	{"\xF0\x9F\x98\xE2\x82\xAC", FFFD + "€"},
	{"\xF5", FFFD}, // bytes no sequence has
	{"\xF8\x88\x80\x80\x80", FFFD + FFFD + FFFD + FFFD + FFFD},
	{"\xFE\xFF", FFFD + FFFD},
	{"é\xFF\\n", "é" + FFFD + "\n"}, // beside a character and an escape
}

// The texts a string is read in, as a value and as a key, each short and past the block readers' 64 bytes.
@(private = "file")
lax_texts :: proc(body: string) -> [4]string {
	long := strings.concatenate({strings.repeat("x", 80, context.temp_allocator), body}, context.temp_allocator)
	text :: proc(head, body, tail: string) -> string {
		return strings.concatenate({head, body, tail}, context.temp_allocator)
	}
	return {text(`["`, body, `"]`), text(`["`, long, `"]`), text(`{"`, body, `":1}`), text(`{"`, long, `":1}`)}
}

// Each class of ill-formed UTF-8 is refused by a strict read and taken under `.Invalid_Utf8`, in a value and in a key,
// as a string marked `SPELLING_LAX` that decodes to U+FFFD per maximal subpart.
@(test)
tolerate_invalid_utf8 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in LAX_STRINGS {
		for src, i in lax_texts(c.bytes) {
			want := c.text if i % 2 == 0 else strings.concatenate({strings.repeat("x", 80, context.temp_allocator), c.text}, context.temp_allocator)
			for spec in ([]json.Spec{.Json, .Jsonc, .Json5}) {
				testing.expectf(t, json.validate(transmute([]u8)src, spec) != nil, "%v accepted %q", spec, src)
				testing.expectf(t, json.validate(transmute([]u8)src, spec, LAX) == nil, "%v refused %q", spec, src)
				doc, err := json.build(transmute([]u8)src, spec, LAX)
				defer tape.destroy(&doc)
				if !testing.expectf(t, err == nil, "%v %q: %v", spec, src, err) {
					continue
				}
				testing.expectf(t, .Tolerated in doc.flags, "%q not flagged", src)
				n := doc.nodes[1]
				testing.expect(t, n.kind == .String && n.spelling & tape.SPELLING_LAX != 0 && n.spelling & tape.SPELLING_DECODE != 0)
				buf := make([]u8, tape.text_room(&doc, 1), context.temp_allocator)
				text, ok := tape.node_text(&doc, 1, buf)
				testing.expectf(t, ok && text == want, "%v %q reads %q", spec, src, text)
				_, short := tape.node_text(&doc, 1, buf[:len(buf) - 1])
				testing.expect(t, !short)
			}
		}
	}
}

// A JSON5 string in single quotes takes the tolerance as a double-quoted one does.
@(test)
tolerate_invalid_utf8_in_json5_quotes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "{'k\xFF': 'v\xC0\\x41'}"
	testing.expect(t, json.validate(transmute([]u8)src, .Json5) != nil)
	doc, err := json.build(transmute([]u8)src, .Json5, LAX)
	defer tape.destroy(&doc)
	testing.expect_value(t, err, nil)
	texts: [2]string
	for i in 0 ..< 2 {
		n := tape.Node_Index(i + 1)
		texts[i], _ = tape.node_text(&doc, n, make([]u8, tape.text_room(&doc, n), context.temp_allocator))
	}
	testing.expect_value(t, texts[0], "k" + FFFD)
	testing.expect_value(t, texts[1], "v" + FFFD + "A")
}

// A sequence the text's end cuts short leaves its string open, which no tolerance closes.
@(test)
tolerate_invalid_utf8_not_an_open_string :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for src in ([]string{"\"\xE2\x82", "[\"\xF0\x9F", "\"a\xFF"}) {
		err := json.validate(transmute([]u8)src, .Json, LAX)
		f, is_fault := err.(tape.Fault)
		testing.expectf(t, is_fault && f.kind == .Truncated, "%q: %v", src, err)
	}
}

// A key with a tolerated byte is found and scanned by its decoded name, and the answer says the read took a tolerance,
// unless the read stopped before the byte.
@(test)
tolerate_invalid_utf8_keys_by_name :: proc(t: ^testing.T) {
	testkit.deadline(t)
	long := strings.repeat("k", 70, context.temp_allocator)
	for prefix in ([]string{"", long}) {
		src := strings.concatenate({`{"a":0,"`, prefix, "\xFFz", `":[1,2],"b\u00e9":3}`}, context.temp_allocator)
		name := strings.concatenate({prefix, FFFD, "z"}, context.temp_allocator)
		path := []tape.Step{tape.Name(name), tape.Index(1)}
		_, serr := json.find(transmute([]u8)src, path)
		testing.expect(t, serr != nil)
		f, err := json.find(transmute([]u8)src, path, opts = LAX)
		testing.expectf(t, err == nil && f.outcome == .Found && src[f.lo:f.hi] == "2" && f.tolerated, "%q: %v %v", src, f, err)
		plain, _ := json.find(transmute([]u8)src, {tape.Name("a")}, opts = LAX, read = {dups = .First, stop_early = true})
		testing.expect(t, plain.outcome == .Found && !plain.tolerated)

		d, _ := tape.demand_of([][]tape.Step{path, {tape.Name("bé")}})
		defer tape.destroy(&d)
		r, rerr := json.scan(transmute([]u8)src, &d, opts = LAX)
		defer tape.destroy(&r)
		testing.expect_value(t, rerr, nil)
		testing.expect(t, .Tolerated in r.flags)
		testing.expect_value(t, render_answers(&r), `0=2 1=3`)
	}
}

@(private = "file")
LONE :: json.Options{tolerate = {.Lone_Surrogate}}

// A string spelling a surrogate half no partner pairs with, and the text it reads as.
@(private = "file")
LONE_STRINGS := []Lax_String {
	{`\uD800`, FFFD}, // a lone high half
	{`\uDC00`, FFFD}, // a lone low half
	{`\udbff`, FFFD},
	{`\uDFFF`, FFFD},
	{`\uD800\u0041`, FFFD + "A"}, // a high half before an escape that is no low half
	{`\uD800\n`, FFFD + "\n"},
	{`\uD800x`, FFFD + "x"},
	{`x\uD800`, "x" + FFFD}, // at the string's end
	{`\uD800\uD800`, FFFD + FFFD},
	{`\uD800\uD83D\uDE00`, FFFD + "😀"}, // a lone half before a pair
	{`\uD83D\uDE00\uDE00`, "😀" + FFFD}, // a lone half after a pair
	{`\uDC00\uD800`, FFFD + FFFD},
	{`\uDC00\uDC00`, FFFD + FFFD},
}

// A lone surrogate half is refused by a strict read at its backslash and taken under `.Lone_Surrogate`, in a value and
// in a key, as a string marked `SPELLING_LAX` that decodes to U+FFFD for each half.
@(test)
tolerate_lone_surrogate :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in LONE_STRINGS {
		for src, i in lax_texts(c.bytes) {
			want := c.text if i % 2 == 0 else strings.concatenate({strings.repeat("x", 80, context.temp_allocator), c.text}, context.temp_allocator)
			for spec in ([]json.Spec{.Json, .Jsonc, .Json5}) {
				strict := json.validate(transmute([]u8)src, spec)
				f, is_fault := strict.(tape.Fault)
				testing.expectf(t, is_fault && f.kind == .Bad_Escape, "%v strict %q: %v", spec, src, strict)
				testing.expectf(t, json.validate(transmute([]u8)src, spec, LONE) == nil, "%v refused %q", spec, src)
				doc, err := json.build(transmute([]u8)src, spec, LONE)
				defer tape.destroy(&doc)
				if !testing.expectf(t, err == nil, "%v %q: %v", spec, src, err) {
					continue
				}
				testing.expectf(t, .Tolerated in doc.flags, "%q not flagged", src)
				n := doc.nodes[1]
				testing.expect(t, n.kind == .String && n.spelling & tape.SPELLING_LAX != 0 && n.spelling & tape.SPELLING_DECODE != 0)
				buf := make([]u8, tape.text_room(&doc, 1), context.temp_allocator)
				text, ok := tape.node_text(&doc, 1, buf)
				testing.expectf(t, ok && text == want, "%v %q reads %q", spec, src, text)
				_, short := tape.node_text(&doc, 1, buf[:len(buf) - 1])
				testing.expect(t, !short)
			}
		}
	}
}

// Each tolerance takes only its own text, and a lone half's refusal is the fault of a strict read.
@(test)
tolerate_lone_surrogate_alone :: proc(t: ^testing.T) {
	testkit.deadline(t)
	lone := transmute([]u8)string(`["\ud800"]`)
	for spec in ([]json.Spec{.Json, .Jsonc, .Json5}) {
		other := json.Options{tolerate = {.Invalid_Utf8, .Non_Finite}}
		testing.expectf(t, json.validate(lone, spec, other) == json.validate(lone, spec), "%v", spec)
		testing.expect(t, json.validate(transmute([]u8)string("[\"\xFF\"]"), spec, LONE) != nil)
		testing.expect(t, json.validate(transmute([]u8)string("[NaN]"), .Json, LONE) != nil)
	}
	both := json.Options{tolerate = {.Invalid_Utf8, .Lone_Surrogate}}
	src := transmute([]u8)string("[\"\xFF\\ud800\"]")
	testing.expect(t, json.validate(src, .Json, both) == nil)
	testing.expect(t, json.validate(src, .Json, LONE) != nil)
}

// A half cut by the text's end or followed by a bad escape keeps the fault a strict read gives there.
@(test)
tolerate_lone_surrogate_faults :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := []struct {
		src:  string,
		kind: tape.Fault_Kind,
	}{{`"\ud800\u`, .Truncated}, {`"\ud800\u00g1"`, .Bad_Escape}, {`"\ud83d\ude0"`, .Bad_Escape}, {`"\ud800`, .Truncated}}
	for c in cases {
		for spec in ([]json.Spec{.Json, .Jsonc, .Json5}) {
			err := json.validate(transmute([]u8)c.src, spec, LONE)
			f, is_fault := err.(tape.Fault)
			testing.expectf(t, is_fault && f.kind == c.kind, "%v %q: %v", spec, c.src, err)
		}
	}
}

// A valid pair reads the same under the tolerance, with no flag.
@(test)
tolerate_lone_surrogate_pair_unaffected :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`["\uD83D\uDE00","\uD83D\uDE00x","\u00e9"]`)
	for spec in ([]json.Spec{.Json, .Jsonc, .Json5}) {
		strict, serr := json.build(src, spec)
		lone, lerr := json.build(src, spec, LONE)
		testing.expect(t, serr == nil && lerr == nil && slice.equal(strict.nodes, lone.nodes) && strict.flags == lone.flags)
		testing.expect(t, .Tolerated not_in lone.flags)
		tape.destroy(&strict)
		tape.destroy(&lone)
	}
}

// A key with a lone half is found and scanned by its decoded name, and the answer says the read took a tolerance.
@(test)
tolerate_lone_surrogate_keys_by_name :: proc(t: ^testing.T) {
	testkit.deadline(t)
	long := strings.repeat("k", 70, context.temp_allocator)
	for prefix in ([]string{"", long}) {
		for spec in ([]json.Spec{.Json, .Jsonc, .Json5}) {
			src := strings.concatenate({`{"a":0,"`, prefix, `\ud800z":[1,2],"b\u00e9":3}`}, context.temp_allocator)
			name := strings.concatenate({prefix, FFFD, "z"}, context.temp_allocator)
			path := []tape.Step{tape.Name(name), tape.Index(1)}
			_, serr := json.find(transmute([]u8)src, path, spec)
			testing.expect(t, serr != nil)
			f, err := json.find(transmute([]u8)src, path, spec, opts = LONE)
			testing.expectf(t, err == nil && f.outcome == .Found && src[f.lo:f.hi] == "2" && f.tolerated, "%q: %v %v", src, f, err)

			d, _ := tape.demand_of([][]tape.Step{path, {tape.Name("bé")}})
			defer tape.destroy(&d)
			r, rerr := json.scan(transmute([]u8)src, &d, spec, opts = LONE)
			defer tape.destroy(&r)
			testing.expect_value(t, rerr, nil)
			testing.expect(t, .Tolerated in r.flags)
			testing.expect_value(t, render_answers(&r), `0=2 1=3`)
		}
	}
}

// A non-finite number and its value, whose bits are binary64's.
@(private = "file")
Non_Finite_Case :: struct {
	src:  string,
	path: []tape.Step,
	bits: u64,
}

@(private = "file")
INF :: u64(0x7FF0_0000_0000_0000)
@(private = "file")
NEG_INF :: u64(0xFFF0_0000_0000_0000)
@(private = "file")
NAN :: u64(0x7FF8_0000_0000_0000)
@(private = "file")
NEG_NAN :: u64(0xFFF8_0000_0000_0000)

// `NaN` and `Infinity` with either sign are refused by a strict JSON or JSONC read and read under `.Non_Finite` as
// those binary64 values, a NaN with its sign, wherever a value starts.
@(test)
tolerate_non_finite :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := []Non_Finite_Case {
		{`NaN`, {}, NAN},
		{` Infinity `, {}, INF},
		{`-Infinity`, {}, NEG_INF},
		{`+Infinity`, {}, INF},
		{`-NaN`, {}, NEG_NAN},
		{`[1,NaN]`, {tape.Index(1)}, NAN},
		{`[1, 2, -Infinity, 3]`, {tape.Index(2)}, NEG_INF},
		{`[1,-Infinity]`, {tape.Index(1)}, NEG_INF},
		{`{"a":-Infinity}`, {tape.Name("a")}, NEG_INF},
		{`{"a": Infinity}`, {tape.Name("a")}, INF},
		{`{"a":1,"b":-NaN}`, {tape.Name("b")}, NEG_NAN},
		{`[{"a":1,"b":2},{"a":-Infinity,"b":NaN}]`, {tape.Index(1), tape.Name("a")}, NEG_INF},
		{`[{"a":1,"b":2},{"a":3,"b":NaN}]`, {tape.Index(1), tape.Name("b")}, NAN},
		{"[[1,2],[3,4],[5,6],[7,8],[9,10],[11,12],[13,14],[15,16],[17,18],[19,20],[21,22],[NaN]]", {tape.Index(-1), tape.Index(0)}, NAN},
	}
	for c in cases {
		for spec in ([]json.Spec{.Json, .Jsonc}) {
			src := transmute([]u8)c.src
			testing.expectf(t, json.validate(src, spec) != nil, "%v accepted %q", spec, c.src)
			testing.expectf(t, json.validate(src, spec, LAX) == nil, "%v refused %q", spec, c.src)
			f, err := json.find(src, c.path, spec, opts = LAX)
			if !testing.expectf(t, err == nil && f.outcome == .Found && f.tolerated, "%v %q: %v %v", spec, c.src, f, err) {
				continue
			}
			num, ok := tape.node_number(json.as(spec), src, tape.answer_node(f))
			testing.expectf(t, ok && num == spell.Number{c.bits, .Float}, "%q reads %x", c.src, num.bits)

			doc, berr := json.build(src, spec, LAX)
			defer tape.destroy(&doc)
			testing.expect_value(t, berr, nil)
			testing.expect(t, .Tolerated in doc.flags)
			d, _ := tape.demand_of([][]tape.Step{c.path})
			defer tape.destroy(&d)
			r, rerr := json.scan(src, &d, spec, opts = LAX)
			defer tape.destroy(&r)
			testing.expect(t, rerr == nil && .Tolerated in r.flags)
		}
	}
	jsonc := "[/* c */ NaN, // d\n -Infinity]"
	testing.expect(t, json.validate(transmute([]u8)jsonc, .Jsonc) != nil)
	testing.expect(t, json.validate(transmute([]u8)jsonc, .Jsonc, LAX) == nil)
}

// A tolerance changes no fault of a text it does not take, and JSON5's own non-finite numbers are no tolerance.
@(test)
tolerate_non_finite_only_the_words :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for src in ([]string{`-Inf`, `Nan`, `Infinit`, `+1`, `-`, `-x`, `+`, `[1,-I]`, `{"a":N}`, `.5`, `0x10`}) {
		for spec in ([]json.Spec{.Json, .Jsonc}) {
			strict := json.validate(transmute([]u8)src, spec)
			testing.expectf(t, strict != nil && json.validate(transmute([]u8)src, spec, LAX) == strict, "%v %q", spec, src)
		}
	}
	doc, err := json.build(transmute([]u8)string(`[NaN, -Infinity]`), .Json5, LAX)
	defer tape.destroy(&doc)
	testing.expect(t, err == nil && .Tolerated not_in doc.flags)
	refused := json.Options{tolerate = {.Invalid_Utf8}}
	testing.expect(t, json.validate(transmute([]u8)string(`NaN`), .Json, refused) != nil)
	testing.expect(t, json.validate(transmute([]u8)string("\"\xFF\""), .Json, {tolerate = {.Non_Finite}}) != nil)
}

// A valid text reads the same under every tolerance, with no flag.
@(test)
tolerate_changes_no_valid_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for f in #load_directory("conformance/JSONTestSuite/test_parsing") {
		if f.name[:2] != "y_" {
			continue
		}
		strict, serr := json.build(f.data, .Json)
		lax, lerr := json.build(f.data, .Json, LAX)
		testing.expectf(t, serr == nil && lerr == nil, "%s: %v %v", f.name, serr, lerr)
		testing.expectf(t, slice.equal(strict.nodes, lax.nodes) && strict.flags == lax.flags, "%s reads otherwise", f.name)
		tape.destroy(&strict)
		tape.destroy(&lax)
	}
}

// Each text the tolerances let a read take is taken with its tolerance and with no other, in every spec that does not
// take it itself, and a strict read refuses it.
@(test)
tolerances_take_one_rule_each :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		src:    string,
		rule:   tape.Tolerance,
		native: json.Spec, // a spec whose grammar takes the text with no tolerance, else `.Json`, which does not
	}
	cases := []Case {
		{"[\"\xFF\"]", .Invalid_Utf8, .Json},
		{"[\"a\xC3\"]", .Invalid_Utf8, .Json},
		{`[NaN]`, .Non_Finite, .Json5},
		{`[-Infinity]`, .Non_Finite, .Json5},
		{`{"a":Infinity}`, .Non_Finite, .Json5},
		{`["\ud800"]`, .Lone_Surrogate, .Json},
		{`["\udc00"]`, .Lone_Surrogate, .Json},
		{`["\ud800A"]`, .Lone_Surrogate, .Json},
		{`["\udc00\ud800"]`, .Lone_Surrogate, .Json},
		{`["\ud800\ud800"]`, .Lone_Surrogate, .Json},
		{`["a\udc00b"]`, .Lone_Surrogate, .Json},
	}
	for subset in 0 ..< 8 {
		tolerate := transmute(tape.Tolerances)u8(subset)
		for spec in json.Spec {
			for c in cases {
				doc, err := json.build(transmute([]u8)c.src, spec, {tolerate = tolerate})
				defer tape.destroy(&doc)
				native := c.native != .Json && spec == c.native
				want := native || c.rule in tolerate
				testing.expectf(t, (err == nil) == want, "%q %v tolerating %v: %v", c.src, spec, tolerate, err)
				if err != nil {
					fault, is_fault := err.(tape.Fault)
					testing.expectf(t, is_fault && (fault.kind == .Bad_Char || fault.kind == .Bad_Escape || fault.kind == .Bad_Number), "%q %v: %v", c.src, spec, err)
				}
				verr := json.validate(transmute([]u8)c.src, spec, {tolerate = tolerate})
				testing.expectf(t, (verr == nil) == want, "validate %q %v tolerating %v: %v", c.src, spec, tolerate, verr)
			}
		}
	}
}
