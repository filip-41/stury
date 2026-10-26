package json_tests

import json "../.."
import "core:math"
import "core:testing"

// The JSON5 dialect: its grammar on the walk, its tokens decoded by the document's readers and found by paths.

@(private = "file")
JSON5_SAMPLE :: `// the JSON5 spec's example
{
  // comments
  unquoted: 'and you can quote me on that',
  singleQuotes: 'I can use "double quotes" here',
  lineBreaks: "Look, Mom! \
No \\n's!",
  hexadecimal: 0xdecaf,
  leadingDecimalPoint: .8675309, andTrailing: 8675309.,
  positiveSign: +1,
  trailingComma: 'in objects', andIn: ['arrays',],
  "backwardsCompatible": "with JSON",
}
`

@(test)
test_json5_validates_the_spec_example :: proc(t: ^testing.T) {
	testing.expect_value(t, json.validate(raw(JSON5_SAMPLE), {dialect = .Json5}), nil)
	// Neither JSON nor JSONC reads it.
	testing.expect(t, json.validate(raw(JSON5_SAMPLE), {dialect = .Jsonc}) != nil)
	testing.expect(t, json.validate(raw(JSON5_SAMPLE)) != nil)
}

@(test)
test_json5_accepts_its_grammar :: proc(t: ^testing.T) {
	for src in ([]string{
		`'a'`, `"\x41\v\0\'"`, `'\u00e9\uD83D\uDE00'`, "'a\\\nb'", "'a\\\r\nb'", "'\\ '", "'tab\there'",
		`0x1F`, `-0X1f`, `+0x0`, `.5`, `5.`, `+.5e-3`, `5.e2`, `-Infinity`, `+Infinity`, `NaN`, `-NaN`,
		`{a: 1, $b: 2, _c: 3, d0: 4, \u0065: 5, 'f': 6, "g": 7, é: 8, null: 9, true: 10}`,
		"\v\f\xc2\xa0\xef\xbb\xbf\xe2\x80\xa8\xe2\x80\xa9\xe3\x80\x80[1]", `[1,]`, `{a:1,}`, "/* c */ [1, // d\n 2]",
		`1e5`, `-0`, `0`,
	}) {
		testing.expectf(t, json.validate(raw(src), {dialect = .Json5}) == nil, "%q", src)
	}
}

@(test)
test_json5_refuses_with_offsets :: proc(t: ^testing.T) {
	Case :: struct {
		src:  string,
		kind: json.Error_Kind,
		at:   u64,
	}
	for c in ([]Case{
		{`01`, .Bad_Number, 1},
		{`'\1'`, .Bad_Escape, 1},
		{`'\x4'`, .Bad_Escape, 1},
		{`'\uD800'`, .Bad_Escape, 1},
		{"'a\nb'", .Bad_Char, 2},
		{`'abc`, .Truncated, 4},
		{`0x`, .Truncated, 2},
		{`0xg`, .Bad_Number, 2},
		{`.`, .Truncated, 1},
		{`+`, .Truncated, 1},
		{`Infinit`, .Truncated, 7},
		{`Infinitx`, .Bad_Literal, 0},
		{`{1a: 1}`, .Bad_Char, 1},
		{`{a-b: 1}`, .Bad_Char, 2},
		{`{\u0031: 1}`, .Bad_Escape, 1},
		{`[1,,]`, .Bad_Char, 3},
		{`1 2`, .Trailing, 2},
	}) {
		e, bad := json.validate(raw(c.src), {dialect = .Json5}).?
		testing.expectf(t, bad && e.kind == c.kind && e.offset == c.at, "%q: %v, want %v at %d", c.src, e, c.kind, c.at)
	}
}

// Every reader gives a JSON5 token's value: strings in either quote with JSON5's escapes, unquoted keys, and
// numbers in every spelling.
@(test)
test_json5_document_reads_decoded_values :: proc(t: ^testing.T) {
	doc, err := json.build(raw(JSON5_SAMPLE), {dialect = .Json5})
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	str :: proc(t: ^testing.T, doc: ^json.Document, name, want: string, loc := #caller_location) {
		s, ok := json.get_string(doc, json.child(doc, json.ROOT, name))
		testing.expectf(t, ok && s == want, "%s: %q, want %q", name, s, want, loc = loc)
	}
	str(t, &doc, "unquoted", "and you can quote me on that")
	str(t, &doc, "singleQuotes", `I can use "double quotes" here`)
	str(t, &doc, "lineBreaks", `Look, Mom! No \n's!`)
	str(t, &doc, "backwardsCompatible", "with JSON")
	tags := json.child(&doc, json.ROOT, "andIn")
	s, ok := json.get_string(&doc, json.child(&doc, tags, 0))
	testing.expect(t, ok && s == "arrays")

	hex, hok := json.get_int(&doc, json.child(&doc, json.ROOT, "hexadecimal"))
	testing.expect(t, hok && hex == 0xdecaf)
	plus, pok := json.get_int(&doc, json.child(&doc, json.ROOT, "positiveSign"))
	testing.expect(t, pok && plus == 1)
	lead, lok := json.get_number(&doc, json.child(&doc, json.ROOT, "leadingDecimalPoint"))
	testing.expect(t, lok && lead.value == 0.8675309 && lead.exactness == .Inexact)
	trail, tok := json.get_number(&doc, json.child(&doc, json.ROOT, "andTrailing"))
	testing.expect(t, tok && trail.value == 8675309 && trail.exactness == .Exact)
	_, frac := json.get_int(&doc, json.child(&doc, json.ROOT, "andTrailing"))
	testing.expect(t, !frac)

	keys: [dynamic]string
	defer delete(keys)
	it := json.members(&doc, json.ROOT)
	for k in json.members(&it) {
		append(&keys, k)
	}
	testing.expect_value(t, len(keys), 10)
	if len(keys) == 10 {
		testing.expect_value(t, keys[0], "unquoted")
		testing.expect_value(t, keys[9], "backwardsCompatible")
	}
}

@(test)
test_json5_numbers_and_escaped_keys :: proc(t: ^testing.T) {
	doc, err := json.build(raw(`{inf: -Infinity, nan: NaN, big: 0x10000000000000001, neg: -0x10, e: +5.e2, \u0061b: 'x', 'c\'d': 1}`), {dialect = .Json5})
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	num :: proc(doc: ^json.Document, name: string) -> json.Number {
		v, _ := json.get_number(doc, json.child(doc, json.ROOT, name))
		return v
	}
	testing.expect(t, math.is_inf(num(&doc, "inf").value, -1))
	testing.expect(t, math.is_nan(num(&doc, "nan").value))
	testing.expect_value(t, num(&doc, "big"), json.Number{18446744073709551616.0, .Inexact})
	testing.expect_value(t, num(&doc, "e"), json.Number{500, .Exact})
	neg, nok := json.get_int(&doc, json.child(&doc, json.ROOT, "neg"))
	testing.expect(t, nok && neg == -16)
	testing.expect(t, json.child(&doc, json.ROOT, "ab") != json.NO_NODE)
	testing.expect(t, json.child(&doc, json.ROOT, "c'd") != json.NO_NODE)
}

// A path finds a member by its decoded key, quoted in either quote or not quoted at all.
@(test)
test_json5_find_by_decoded_key :: proc(t: ^testing.T) {
	src := raw(`{a: {'b c': [10, 0x14,]}, \u0064: 'four', "e": 5}`)
	a, err := json.find(src, `.a["b c"][1]`, {dialect = .Json5})
	testing.expect_value(t, err, nil)
	testing.expectf(t, a.outcome == .Found && string(src[a.lo:a.hi]) == "0x14", "%v", a)
	d, derr := json.find(src, ".d", {dialect = .Json5})
	testing.expect_value(t, derr, nil)
	testing.expectf(t, d.outcome == .Found && string(src[d.lo:d.hi]) == "'four'" && d.kind == .String, "%v", d)
	e, eerr := json.find(src, ".e", {dialect = .Json5})
	testing.expect_value(t, eerr, nil)
	testing.expect(t, e.outcome == .Found && string(src[e.lo:e.hi]) == "5")
}

// A JSON5 document keeps its comments as a JSONC one does.
@(test)
test_json5_comments_attach_to_rows :: proc(t: ^testing.T) {
	doc, err := json.build(raw("// head\n{a: 1, // after a\n}"), {dialect = .Json5})
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(doc.facts), 2)
	testing.expect_value(t, len(json.facts(&doc, json.ROOT)), 1)
	testing.expect_value(t, len(json.facts(&doc, json.child(&doc, json.ROOT, "a"))), 1)
}

// `unmarshal` reads JSON5 into typed values, and a refusal points into the JSON5 text.
@(test)
test_json5_unmarshal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	T :: struct {
		name:  string,
		count: int,
		ratio: f64,
		tags:  []string,
	}
	v: T
	src := raw("// config\n{name: 'st\\x75ry', count: 0x10, ratio: .5, tags: ['a', \"b\",],}")
	testing.expect_value(t, json.unmarshal(src, &v, {dialect = .Json5}, nil, context.temp_allocator), nil)
	testing.expect_value(t, v.name, "stury")
	testing.expect_value(t, v.count, 16)
	testing.expect_value(t, v.ratio, 0.5)
	testing.expect(t, len(v.tags) == 2 && v.tags[0] == "a" && v.tags[1] == "b")

	bad := raw("{name: 'x', count: 'many'}")
	err := json.unmarshal(bad, &v, {dialect = .Json5}, nil, context.temp_allocator)
	e, refused := err.?
	testing.expectf(t, refused && e.kind == .Wrong_Kind && e.offset == 19, "%v", err)
	testing.expect(t, e.n_steps == 1 && e.steps[0] == json.Name("count"))

	U :: struct {
		a: int,
	}
	u: U
	err = json.unmarshal(raw("{a: 1, 'b\\u0063': 2}"), &u, {dialect = .Json5, unknown_fields = .Refuse}, nil, context.temp_allocator)
	e, refused = err.?
	testing.expectf(t, refused && e.kind == .Unknown_Field && e.offset == 7, "%v", err)
	testing.expect(t, e.n_steps == 1 && e.steps[0] == json.Name(`b\u0063`))

	syn := json.unmarshal(raw("{a: 01}"), &u, {dialect = .Json5}, nil, context.temp_allocator)
	testing.expectf(t, syn != nil && syn.?.kind == .Syntax && syn.?.syntax == .Bad_Number && syn.?.offset == 5, "%v", syn)
	inf := json.unmarshal(raw("{a: Infinity}"), &u, {dialect = .Json5}, nil, context.temp_allocator)
	testing.expectf(t, inf != nil && inf.?.kind == .Out_Of_Range && inf.?.offset == 4, "%v", inf)
}

// `marshal` writes a JSON5 document in JSON's spelling, comments kept; the edits refuse the dialect.
@(test)
test_json5_marshal_respells_and_edits_refuse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc, err := json.build(raw("{a: 'it\\'s', \"b\": [0x1F, .5, 5., +1, -0x2,], // c\n}"), {dialect = .Json5})
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	out, merr := json.marshal(&doc, {}, context.temp_allocator)
	testing.expect_value(t, merr, json.Marshal_Error.None)
	testing.expect_value(t, string(out), `{"a":"it's","b":[31,0.5,5,1,-2]// c
}`)
	testing.expect_value(t, json.validate(out, {dialect = .Jsonc}), nil)

	nan, _ := json.build(raw("[NaN]"), {dialect = .Json5})
	defer json.destroy(&nan)
	_, nerr := json.marshal(&nan, {}, context.temp_allocator)
	testing.expect_value(t, nerr, json.Marshal_Error.Non_Finite)
	_, ferr := json.format(raw("[1, -Infinity]"), {}, .Json5, context.temp_allocator)
	testing.expect_value(t, ferr, json.Error{kind = .Bad_Number, offset = 4})
	fout, _ := json.format(raw("{a: 0x10}"), {}, .Json5, context.temp_allocator)
	testing.expect_value(t, string(fout), `{"a":16}`)

	_, serr := json.set(raw("{a: 1}"), ".a", 2, dialect = .Json5, allocator = context.temp_allocator)
	testing.expect(t, serr != nil && serr.?.kind == .Bad_Option)
	_, rerr := json.remove(raw("{a: 1}"), ".a", .Json5, context.temp_allocator)
	testing.expect(t, rerr != nil && rerr.?.kind == .Bad_Option)
}
