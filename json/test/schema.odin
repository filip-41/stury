package json_tests

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import core "../../core"
import rules "../../core/rules"
import typed "../../core/typed"
import schema "../../core/schema"
import json ".."
import model "../../core/model"

@(private = "file")
SUITE :: #directory + "conformance/JSON-Schema-Test-Suite/tests/"

@(private = "file")
FIXTURES :: #directory + "schema"

@(private = "file", rodata)
SUITE_DRAFTS := [?]struct {
	dir:   string,
	draft: schema.Draft,
} {
	{"draft2020-12", .D2020_12},
	{"draft2019-09", .D2019_09},
	{"draft7", .D07},
	{"draft6", .D06},
	{"draft4", .D04},
}

// The error of a refused read when it is a refusal that names a keyword, and "" else.
@(private = "file")
refused_keyword :: proc(err: core.Error) -> string {
	if f, ok := err.(core.Typed_Failure); ok && f.kind == .Bad_Schema {
		text, _, _ := strings.partition(f.want.text, ":")
		return text
	}
	return ""
}

@(private = "file")
read_text :: proc(text: string, draft := schema.Draft.D2020_12, root := "") -> (d: rules.Description, res: schema.Resolver, doc: core.Document, err: core.Error) {
	res = {
		as    = json.as(.Json),
		draft = draft,
		root  = root,
	}
	doc = core.build(transmute([]u8)text, json.as(.Json)) or_return
	d, err = schema.read(&doc, core.ROOT, "", &res)
	return
}

// Every schema of the suite reads, or is refused naming a keyword.
@(test)
schema_suite_reads :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	read, failed := 0, 0
	refusals := make(map[string]int)
	for entry in SUITE_DRAFTS {
		w := os.walker_create_path(strings.concatenate({SUITE, entry.dir}))
		for info in os.walker_walk(&w) {
			if info.type != .Regular || !strings.has_suffix(info.name, ".json") {
				continue
			}
			bytes, rerr := os.read_entire_file_from_path(info.fullpath, context.allocator)
			testing.expectf(t, rerr == nil, "%s: %v", info.fullpath, rerr)
			doc, derr := core.build(bytes, json.as(.Json))
			testing.expectf(t, derr == nil, "%s: %v", info.fullpath, derr)
			groups := core.children(&doc, core.ROOT)
			for group in core.child_next(&groups) {
				node, _ := core.member(&doc, group, "schema")
				res := schema.Resolver {
					as    = json.as(.Json),
					draft = entry.draft,
				}
				d, err := schema.read(&doc, node, "", &res)
				switch {
				case err == nil:
					read += 1
				case refused_keyword(err) != "":
					refusals[refused_keyword(err)] += 1
				case:
					failed += 1
					testing.expectf(t, false, "%s: %v", info.fullpath, err)
				}
				_ = d
			}
		}
		os.walker_destroy(&w)
	}
	total := 0
	for keyword, n in refusals {
		log.infof("refused %s: %d", keyword, n)
		total += n
	}
	log.infof("suite schemas: %d read, %d refused, %d failed", read, total, failed)
	testing.expect_value(t, failed, 0)
}

// One schema per kind of refusal, each answered with the keyword that is wrong.
@(test)
schema_refusals :: proc(t: ^testing.T) {
	cases := [?]struct {
		text, keyword, step: string,
	} {
		{`{"minimum": "x"}`, "minimum", ""},
		{`{"type": "strin"}`, "type", ""},
		{`{"properties": {"a": {"required": "a"}}}`, "required", "properties"},
		{`{"properties": {"a": 5}}`, "schema", "properties"},
		{`{"minLength": -1}`, "minLength", ""},
		{`{"contains": {}, "minContains": 1.5}`, "minContains", ""},
		{`{"multipleOf": 0}`, "multipleOf", ""},
		{`{"allOf": []}`, "allOf", ""},
		{`{"pattern": "(a"}`, "pattern", ""},
		{`{"pattern": "(a)\\1"}`, "pattern", ""},
		{`{"$ref": "#/$defs/missing"}`, "$ref", ""},
		{`{"$ref": "https://example.com/other.json"}`, "$ref", ""},
		{`{"$schema": "https://example.com/unknown"}`, "$schema", ""},
		{`{"$defs": {"a": {"$anchor": "x"}, "b": {"$anchor": "x"}}}`, "$anchor", "$defs"},
		{`{"$dynamicRef": "#nowhere"}`, "$dynamicRef", ""},
		{`{"$vocabulary": {"https://example.com/vocab/geo": true}}`, "$vocabulary", ""},
		{`{"type": []}`, "type", ""},
		{`{"type": ["string", "string"]}`, "type", ""},
		{`{"$ref": "#"}`, "$ref", ""},
		{`{"$defs": {"a": {"$ref": "#/$defs/b"}, "b": {"$ref": "#/$defs/a"}}}`, "$ref", "$defs"},
		{`{"$defs": {"a": {"$id": "http://x/a"}, "b": {"$id": "http://x/a"}}}`, "$id", "$defs"},
	}
	for c in cases {
		d, res, doc, err := read_text(c.text)
		defer core.destroy(&doc)
		defer schema.resolver_destroy(&res)
		testing.expectf(t, refused_keyword(err) == c.keyword, "%s: %v", c.text, err)
		if f, ok := err.(core.Typed_Failure); ok && c.step != "" {
			name, _ := f.steps[0].(core.Name)
			testing.expectf(t, string(name) == c.step, "%s: path starts at %v", c.text, f.steps)
		}
		testing.expect_value(t, len(d.nodes), 0)
	}
}

// What only draft 4 refuses: an empty `required` and a boolean schema outside the additional keywords.
@(test)
schema_refuses_draft_4_forms :: proc(t: ^testing.T) {
	cases := [?]struct {
		text, keyword: string,
		refused:       bool,
	} {
		{`{"required": []}`, "required", true},
		{`{"items": true}`, "schema", true},
		{`{"additionalProperties": false, "properties": {"a": {}}}`, "", false},
		{`{"items": [{}], "additionalItems": false}`, "", false},
	}
	for c in cases {
		d, res, doc, err := read_text(c.text, .D04)
		defer rules.description_destroy(&d)
		defer core.destroy(&doc)
		defer schema.resolver_destroy(&res)
		testing.expectf(t, (err != nil) == c.refused && refused_keyword(err) == c.keyword, "%s: %v", c.text, err)
	}
}

// A reference reaches the schema that holds its anchor, and a pointer into a position that is no keyword takes the
// `$id` it passes as its base.
@(test)
schema_reaches_anchors_and_nested_ids :: proc(t: ^testing.T) {
	anchored := `{"$defs": {"x": {"$anchor": "m", "type": "null"}}, "properties": {"p": {"$ref": "#m"}}}`
	d, res, doc, err := read_text(anchored)
	defer rules.description_destroy(&d)
	defer schema.resolver_destroy(&res)
	defer core.destroy(&doc)
	testing.expect(t, err == nil)
	p := d.nodes[d.objects[d.nodes[d.root].object].members[0].node]
	testing.expect_value(t, d.nodes[p.ref.? or_else 0].kinds, rules.Kinds{.Null})

	nested := `{"$id": "http://x/root", "$defs": {"a": {"$id": "http://x/a/", "unk": {"$ref": "b.json"}},
		"b": {"$id": "http://x/a/b.json", "type": "null"}, "c": {"$id": "http://x/b.json", "type": "string"}},
		"$ref": "#/$defs/a/unk"}`
	d2, res2, doc2, err2 := read_text(nested)
	defer rules.description_destroy(&d2)
	defer schema.resolver_destroy(&res2)
	defer core.destroy(&doc2)
	testing.expect(t, err2 == nil)
	unk := d2.nodes[d2.nodes[d2.root].ref.? or_else 0]
	testing.expect_value(t, d2.nodes[unk.ref.? or_else 0].kinds, rules.Kinds{.Null})
	testing.expect(t, unk.resource != d2.root)

	// `$schema` below a resource root is not a dialect.
	d3, res3, doc3, err3 := read_text(`{"properties": {"a": {"$schema": "https://example.com/unknown"}}}`)
	defer rules.description_destroy(&d3)
	defer core.destroy(&doc3)
	defer schema.resolver_destroy(&res3)
	testing.expect(t, err3 == nil)
}

// A schema of an earlier draft reads as 2020-12 reads the same schema.
@(test)
schema_translates_drafts :: proc(t: ^testing.T) {
	text := `{"definitions": {"n": {"type": "integer", "minimum": 5, "exclusiveMinimum": true}},
		"items": [{"$ref": "#/definitions/n"}], "additionalItems": false,
		"dependencies": {"a": ["b"], "c": {"required": ["d"]}}}`
	d, res, doc, err := read_text(text, .D04)
	defer rules.description_destroy(&d)
	defer schema.resolver_destroy(&res)
	defer core.destroy(&doc)
	testing.expect(t, err == nil)
	root := d.nodes[d.root]
	array := d.arrays[root.array]
	testing.expect_value(t, len(array.prefix), 1)
	testing.expect(t, array.items != rules.NONE && d.nodes[array.items].kinds == {})
	n := d.nodes[d.nodes[array.prefix[0]].ref.? or_else -1]
	testing.expect_value(t, n.kinds, rules.Kinds{.Integer})
	testing.expect_value(t, n.rules.minimum, "5")
	testing.expect(t, n.rules.exclusive_minimum)
	object := d.objects[root.object]
	testing.expect_value(t, len(object.dependents), 2)
	testing.expect_value(t, object.dependents[0].required[0], "b")
	testing.expect(t, object.dependents[1].node != nil)
}

// Dynamic and recursive references reach the anchors they name, and a `$ref` beside keywords keeps them in 2019-09.
@(test)
schema_resolves_references :: proc(t: ^testing.T) {
	text := `{"$id": "https://example.com/tree", "$dynamicAnchor": "node", "type": "object",
		"properties": {"kids": {"items": {"$dynamicRef": "#node"}}, "up": {"$ref": "#", "minProperties": 1}}}`
	d, res, doc, err := read_text(text)
	defer rules.description_destroy(&d)
	defer schema.resolver_destroy(&res)
	defer core.destroy(&doc)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(d.anchors), 1)
	testing.expect_value(t, d.anchors[0].name, "node")
	members := d.objects[d.nodes[d.root].object].members
	kids := d.nodes[d.arrays[d.nodes[members[0].node].array].items]
	testing.expect_value(t, kids.dynamic_ref, rules.Node_Index(0))
	up := d.nodes[members[1].node]
	testing.expect_value(t, up.ref, rules.Node_Index(0))
	testing.expect_value(t, up.rules.min_members, 1)

	recursive := `{"$schema": "https://json-schema.org/draft/2019-09/schema", "$recursiveAnchor": true,
		"properties": {"next": {"$recursiveRef": "#"}}}`
	d2, res2, doc2, err2 := read_text(recursive)
	defer rules.description_destroy(&d2)
	defer schema.resolver_destroy(&res2)
	defer core.destroy(&doc2)
	testing.expect(t, err2 == nil)
	next := d2.nodes[d2.objects[d2.nodes[d2.root].object].members[0].node]
	testing.expect_value(t, next.dynamic_ref, rules.Node_Index(0))
	testing.expect_value(t, len(d2.anchors), 1)
}

// References to files read them under the root only, and a meta-schema sets the keywords a schema has.
@(test)
schema_reads_files_and_dialects :: proc(t: ^testing.T) {
	root, _ := os.read_entire_file_from_path(strings.concatenate({FIXTURES, "/root.json"}, context.temp_allocator), context.allocator)
	defer delete(root)
	defer free_all(context.temp_allocator)
	doc, _ := core.build(root, json.as(.Json))
	defer core.destroy(&doc)
	opts := schema.Options {
		resolver = {as = json.as(.Json), root = FIXTURES},
	}
	c, err := schema.compile(&doc, core.ROOT, opts)
	defer schema.destroy(&c)
	testing.expect(t, err == nil)
	d := c.description
	name := d.nodes[d.objects[d.nodes[d.root].object].members[0].node]
	testing.expect_value(t, d.nodes[name.ref.? or_else 0].rules.min_length, 1)

	// A reference with nothing beside it is judged as the node it reaches.
	b, bind_err := schema.bind(&c, json.as(.Json))
	defer schema.unbind(&b)
	testing.expect(t, bind_err == nil)

	// Under no root the same reference is refused.
	_, res, doc2, err2 := read_text(string(root))
	defer core.destroy(&doc2)
	defer schema.resolver_destroy(&res)
	testing.expect_value(t, refused_keyword(err2), "$ref")

	// A file outside the root is not read.
	_, res3, doc3, err3 := read_text(`{"$ref": "file:///etc/hosts"}`, root = FIXTURES)
	defer core.destroy(&doc3)
	defer schema.resolver_destroy(&res3)
	testing.expect_value(t, refused_keyword(err3), "$ref")

	// Dots written as escapes lead out of the root as plain ones do.
	_, res6, doc6, err6 := read_text(`{"$ref": "%2e%2e/conformance/JSON-Schema-Test-Suite/remotes/integer.json"}`, root = FIXTURES)
	defer core.destroy(&doc6)
	defer schema.resolver_destroy(&res6)
	testing.expect_value(t, refused_keyword(err6), "$ref")

	// A vocabulary counts by its standard URI, not by the name that ends it.
	_, res7, doc7, err7 := read_text(`{"$schema": "meta-evil.json"}`, root = FIXTURES)
	defer core.destroy(&doc7)
	defer schema.resolver_destroy(&res7)
	testing.expect_value(t, refused_keyword(err7), "$schema")

	// The narrow meta-schema has no applicator vocabulary, so `properties` is an annotation. One that requires an unknown vocabulary is refused.
	narrow := `{"$schema": "meta-narrow.json", "properties": {"a": 5}, "minimum": 1}`
	d4, res4, doc4, err4 := read_text(narrow, root = FIXTURES)
	defer rules.description_destroy(&d4)
	defer core.destroy(&doc4)
	defer schema.resolver_destroy(&res4)
	testing.expect(t, err4 == nil)
	testing.expect_value(t, d4.nodes[d4.root].object, -1)
	testing.expect_value(t, d4.nodes[d4.root].rules.minimum, "1")
	_, res5, doc5, err5 := read_text(`{"$schema": "meta-unknown.json"}`, root = FIXTURES)
	defer core.destroy(&doc5)
	defer schema.resolver_destroy(&res5)
	testing.expect_value(t, refused_keyword(err5), "$schema")
}

// A schema with nothing past a type, members and required names binds to a plan; a description binds as it is.
@(test)
schema_binds_shapes :: proc(t: ^testing.T) {
	text := `{"type": "object", "properties": {"n": {"type": "integer"}}, "required": ["n", "m"]}`
	d, res, doc, err := read_text(text)
	defer rules.description_destroy(&d)
	defer core.destroy(&doc)
	defer schema.resolver_destroy(&res)
	testing.expect(t, err == nil)
	c, cerr := schema.compile(&doc, core.ROOT, {resolver = {as = json.as(.Json)}})
	defer schema.destroy(&c)
	testing.expect(t, cerr == nil)
	b, berr := schema.bind(&c, json.as(.Json))
	defer schema.unbind(&b)
	testing.expect(t, berr == nil)
	c2 := schema.compile_description(&d)
	b2, berr2 := schema.bind(&c2, json.as(.Json))
	defer schema.unbind(&b2)
	testing.expect(t, berr2 == nil)
}

// Every case of a suite schema the check binds gets the suite's verdict, from its text and from its built document.
@(test)
schema_suite_checks :: proc(t: ^testing.T) {
	bound, cases, wrong, format_cases := 0, 0, 0, 0
	for entry in SUITE_DRAFTS {
		w := os.walker_create_path(strings.concatenate({SUITE, entry.dir}, context.temp_allocator))
		defer os.walker_destroy(&w)
		for info in os.walker_walk(&w) {
			// Draft 7's content assertions and the later drafts' `dependencies` are optional behaviour the check leaves out.
			if info.type != .Regular || !strings.has_suffix(info.name, ".json") || strings.has_suffix(info.fullpath, "optional/content.json") || strings.has_suffix(info.fullpath, "optional/dependencies-compatibility.json") {
				continue
			}
			arena: virtual.Arena
			_ = virtual.arena_init_growing(&arena)
			defer virtual.arena_destroy(&arena)
			context.allocator = virtual.arena_allocator(&arena)
			bytes, _ := os.read_entire_file_from_path(info.fullpath, context.allocator)
			doc, _ := core.build(bytes, json.as(.Json))
			groups := core.children(&doc, core.ROOT)
			// The format suites run with `format` asserting, since a format is an annotation unless asked to assert.
			in_formats := strings.contains(info.fullpath, "optional/format/")
			for group in core.child_next(&groups) {
				node, _ := core.member(&doc, group, "schema")
				c, err := schema.compile(&doc, node, {format_assert = in_formats, resolver = {as = json.as(.Json), draft = entry.draft}})
				if err != nil {
					continue
				}
				b, berr := schema.bind(&c, json.as(.Json))
				if berr != nil {
					continue
				}
				bound += 1
				tests, _ := core.member(&doc, group, "tests")
				all := core.children(&doc, tests)
				for test in core.child_next(&all) {
					data, _ := core.member(&doc, test, "data")
					want, _ := core.member(&doc, test, "valid")
					valid := core.kind(&doc, want) == .True
					from_node := schema.check_node(&b, &doc, data) == nil
					from_text := schema.valid(&b, core.span(&doc, data))
					cases += 1
					format_cases += int(in_formats)
					if from_node != valid || from_text != valid {
						wrong += 1
						about, _ := core.member(&doc, test, "description")
						text, _ := core.text_clone(&doc, about)
						log.warnf("%s: %s: want %v, node %v, text %v", info.fullpath[len(SUITE):], text, valid, from_node, from_text)
					}
				}
			}
		}
	}
	log.infof("suite checks: %d schemas bound, %d cases (%d of formats), %d wrong", bound, cases, format_cases, wrong)
	testing.expect_value(t, wrong, 0)
}

// `format` annotates unless the compile asks for it or the schema's meta-schema holds the format-assertion vocabulary,
// and a name no checker knows annotates under the option and is a schema error under the vocabulary.
@(test)
schema_format_asserts_on_request :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		schema:  string,
		assert_: bool,
		text:    string,
		valid:   bool,
	} {
		{`{"format": "ipv4"}`, false, `"nope"`, true},
		{`{"format": "ipv4"}`, true, `"nope"`, false},
		{`{"format": "ipv4"}`, true, `"10.0.0.1"`, true},
		{`{"format": "ipv4"}`, true, `7`, true},
		{`{"format": "no-such-format"}`, true, `"nope"`, true},
		{`{"$schema": "meta-format-assertion.json", "format": "ipv4"}`, false, `"nope"`, false},
		{`{"$schema": "meta-format-assertion.json", "format": "ipv4"}`, false, `"10.0.0.1"`, true},
		{`{"properties": {"a": {"format": "date-time"}}}`, true, `{"a": "1985-04-12T23:20:50.123456789012Z"}`, true},
		{`{"properties": {"a": {"format": "uuid"}}}`, true, `{"a": "2eb8aa08-aa98-11ea-b4aa-73b441d16380"}`, true},
		{`{"properties": {"a": {"format": "uuid"}}}`, true, `{"a": "2eb8aa08aa9811eab4aa73b441d16380"}`, false},
		{`{"format": "regex"}`, true, `"(a)\\1"`, true},
		{`{"format": "regex"}`, true, `"(?<=a)b("`, false},
		{`{"format": "regex"}`, true, `"\\1("`, false},
		{`{"format": "relative-json-pointer"}`, true, `"1-1#"`, true},
		{`{"format": "relative-json-pointer"}`, true, `"0+01/a"`, false},
		{`{"propertyNames": {"format": "hostname"}}`, true, `{"a_b": 1}`, false},
		{`{"format": "idn-hostname"}`, true, `"a\u0378b"`, false},
		{`{"format": "idn-hostname"}`, true, `"a\u30a0b"`, false},
		{`{"format": "idn-hostname"}`, true, `"a\ufdd0b"`, false},
		{`{"format": "idn-hostname"}`, true, `"a\u0e3fb"`, false},
		{`{"format": "idn-hostname"}`, true, `"a\u3164b"`, false},
		{`{"format": "idn-hostname"}`, true, `"a\u309bb"`, false},
		{`{"format": "idn-hostname"}`, true, `"\ufb00.com"`, true},
		{`{"format": "idn-hostname"}`, true, `"\uff71.com"`, true},
		{`{"format": "idn-hostname"}`, true, `"a\u0340b"`, true},
		{`{"format": "idn-hostname"}`, true, `"a\u02b0b"`, true},
		{`{"format": "idn-hostname"}`, true, `"\u0627\u200c\u0628"`, false},
		{`{"format": "idn-hostname"}`, true, `"\u0628\u200c\u0628"`, true},
		{`{"format": "idn-hostname"}`, true, `"\u0628\u064e\u200c\u0628"`, true},
		{`{"format": "idn-hostname"}`, true, `"\u0628\u200c\u0627"`, true},
		{`{"format": "idn-hostname"}`, true, `"\u0628\u200c"`, false},
		{`{"format": "idn-hostname"}`, true, `"\ud83a\udd22\ud83a\udd23"`, true},
		{`{"format": "idn-hostname"}`, true, `"a\ud83a\udd22"`, false},
		{`{"format": "idn-email"}`, true, `"a@ex\u30a0ample.com"`, false},
		{`{"format": "idn-email"}`, true, `"\u00e0@\ufb00.com"`, true},
	}
	for c in cases {
		doc, built := core.build(transmute([]u8)c.schema, json.as(.Json))
		testing.expect(t, built == nil)
		compiled, err := schema.compile(&doc, core.ROOT, {format_assert = c.assert_, resolver = {as = json.as(.Json), root = FIXTURES}})
		testing.expectf(t, err == nil, "%s: %v", c.schema, err)
		b, bound := schema.bind(&compiled, json.as(.Json))
		testing.expectf(t, bound == nil, "%s: %v", c.schema, bound)
		testing.expectf(t, schema.valid(&b, transmute([]u8)c.text) == c.valid, "%s asserting %v: %s", c.schema, c.assert_, c.text)
	}
}

@(test)
schema_unknown_format_refused_under_assertion_vocabulary :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	doc, built := core.build(transmute([]u8)string(`{"$schema": "meta-format-assertion.json", "format": "no-such-format"}`), json.as(.Json))
	testing.expect(t, built == nil)
	_, err := schema.compile(&doc, core.ROOT, {resolver = {as = json.as(.Json), root = FIXTURES}})
	testing.expect(t, err != nil)
}

// A failure's entry holds where it is, the path to its value, and the keywords that lead to its rule.
@(test)
schema_check_reports_each_failure :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := `{"properties": {"a": {"type": "integer", "minimum": 2}, "b": {"type": "array", "items": {"type": "string"}}}, "required": ["a", "c"], "additionalProperties": false}`
	doc, _ := core.build(transmute([]u8)text, json.as(.Json))
	defer core.destroy(&doc)
	c, err := schema.compile(&doc, core.ROOT, {resolver = {as = json.as(.Json)}})
	defer schema.destroy(&c)
	testing.expect(t, err == nil)
	b, berr := schema.bind(&c, json.as(.Json))
	defer schema.unbind(&b)
	testing.expect(t, berr == nil)
	src := transmute([]u8)string(`{"a": 1, "b": ["x", 3], "z": 0}`)
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	first := schema.check(&b, src, &sink)
	testing.expect_value(t, first.(core.Typed_Failure).kind, core.Typed_Error_Kind.Below_Minimum)
	out := strings.builder_make(context.temp_allocator)
	for e in sink.entries {
		core.render_entry(strings.to_stream(&out), src, e)
		strings.write_byte(&out, '\n')
	}
	testing.expect_value(t, strings.to_string(out), "1:7: Number is below the minimum at .a (.properties.a.minimum)\n1:21: Value is not of the allowed type at .b[1] (.properties.b.items.type)\n1:30: No value is allowed here at .z (.additionalProperties)\n1:1: Required member is missing at .c (.required)\n")
	testing.expect(t, !schema.valid(&b, src))
	// `c` is only required, so `additionalProperties` refuses it too.
	testing.expect(t, !schema.valid(&b, transmute([]u8)string(`{"a": 2, "c": null}`)))
}

@(private = "file")
Corpus_Tie :: struct {
	x: f64 `model:"<=0.1"`,
}

@(private = "file")
Corpus_Formats :: struct {
	at: string `model:"format=date-time"`,
	mail: string `model:"format=email"`,
}

@(private = "file")
Corpus_Whole :: struct {
	n: i64,
}

@(private = "file")
Corpus_Narrow :: struct {
	f: f32,
}

@(private = "file")
Corpus_Keys :: struct {
	m: map[i8]int,
}

@(private = "file")
Corpus_Enum_Keys :: struct {
	m: map[enum {
		A = 1,
		C = 3,
	}]int,
}

@(private = "file")
Corpus_Gap :: struct {
	e: enum {
		A = 1,
		C = 3,
	},
}

// The known disagreements between a model's load and the check of its schema agree: a type's plan read through the
// check hook with its rules, against the check of the schema `describe` gives.
@(test)
schema_check_agrees_with_model_load :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		type:  typeid,
		text:  string,
		valid: bool,
		enums: typed.Enum_Spelling,
	} {
		{Corpus_Tie, `{"x": 0.10000000000000000001}`, false, .Name},
		{Corpus_Tie, `{"x": 0.1}`, true, .Name},
		{Corpus_Formats, `{"at": "1998-12-31T23:59:60Z"}`, true, .Name},
		{Corpus_Formats, `{"at": "1998-12-31T23:59:61Z"}`, false, .Name},
		{Corpus_Formats, `{"at": "1998-12-31 23:59:59Z"}`, false, .Name},
		{Corpus_Formats, `{"at": "1998-12-31t23:59:59z"}`, true, .Name},
		{Corpus_Formats, `{"mail": "a@b"}`, true, .Name},
		{Corpus_Formats, `{"mail": "a b@c"}`, false, .Name},
		{Corpus_Formats, `{"mail": "a..b@c"}`, false, .Name},
		{Corpus_Formats, `{"mail": "\"a b\"@c"}`, true, .Name},
		{Corpus_Whole, `{"n": 1.0}`, true, .Name},
		{Corpus_Whole, `{"n": 1e2}`, true, .Name},
		{Corpus_Whole, `{"n": 1.5}`, false, .Name},
		{Corpus_Narrow, `{"f": 1e39}`, false, .Name},
		{Corpus_Narrow, `{"f": 3.4e38}`, true, .Name},
		{Corpus_Keys, `{"m": {"300": 1}}`, false, .Name},
		{Corpus_Keys, `{"m": {"-128": 1}}`, true, .Name},
		{Corpus_Keys, `{"m": {"127": 1, "-0": 1, "0": 1, "99": 1}}`, true, .Name},
		{Corpus_Keys, `{"m": {"128": 1}}`, false, .Name},
		{Corpus_Keys, `{"m": {"-129": 1}}`, false, .Name},
		{Corpus_Keys, `{"m": {"01": 1}}`, false, .Name},
		{Corpus_Keys, `{"m": {"1.0": 1}}`, false, .Name},
		{Corpus_Gap, `{"e": "C"}`, true, .Name},
		{Corpus_Gap, `{"e": "B"}`, false, .Name},
		{Corpus_Gap, `{"e": 3}`, true, .Int},
		{Corpus_Gap, `{"e": 2}`, false, .Int},
		{Corpus_Enum_Keys, `{"m": {"3": 1}}`, true, .Int},
		{Corpus_Enum_Keys, `{"m": {"2": 1}}`, false, .Int},
		{Corpus_Enum_Keys, `{"m": {"C": 1}}`, true, .Name},
	}
	for c in cases {
		plan, planned := json.plan_make(c.type, plan = {rule_tags = true, enums = c.enums}, reads = json.reads(.Json))
		testing.expect(t, planned == nil)
		target := make([]u8, size_of(Corpus_Keys))
		loaded := typed.check_text(transmute([]u8)c.text, raw_data(target), c.type, &plan, {}) == nil
		d, described := model.describe(&plan)
		testing.expect(t, described == nil)
		compiled := schema.compile_description(&d)
		b, bound := schema.bind(&compiled, json.as(.Json))
		testing.expect(t, bound == nil)
		checked := schema.valid(&b, transmute([]u8)c.text)
		testing.expectf(t, loaded == c.valid && checked == c.valid, "%v %s: load %v, check %v", c.type, c.text, loaded, checked)
	}
}

// A file reference is judged by the real path of the file: a link that stays under the root reads, one that leads out is refused.
@(test)
schema_resolves_file_links :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tmp, terr := os.make_directory_temp("", "stury-schema-links-*", context.temp_allocator)
	testing.expect(t, terr == nil)
	defer os.remove_all(tmp)
	root := strings.concatenate({tmp, "/root"}, context.temp_allocator)
	outside := strings.concatenate({tmp, "/outside.json"}, context.temp_allocator)
	inside := strings.concatenate({root, "/inside.json"}, context.temp_allocator)
	testing.expect(t, os.make_directory(root) == nil)
	testing.expect(t, os.write_entire_file(outside, `{"minLength": 2}`) == nil)
	testing.expect(t, os.write_entire_file(inside, `{"minLength": 3}`) == nil)
	testing.expect(t, os.symlink(inside, strings.concatenate({root, "/stays.json"}, context.temp_allocator)) == nil)
	testing.expect(t, os.symlink(outside, strings.concatenate({root, "/leaves.json"}, context.temp_allocator)) == nil)

	d, res, doc, err := read_text(`{"$ref": "stays.json"}`, root = root)
	defer rules.description_destroy(&d)
	defer core.destroy(&doc)
	defer schema.resolver_destroy(&res)
	testing.expect(t, err == nil)
	testing.expect_value(t, d.nodes[d.nodes[d.root].ref.? or_else 0].rules.min_length, 3)

	_, res2, doc2, err2 := read_text(`{"$ref": "leaves.json"}`, root = root)
	defer core.destroy(&doc2)
	defer schema.resolver_destroy(&res2)
	testing.expect_value(t, refused_keyword(err2), "$ref")
}

// A pointer takes the `$id` of an ancestor only where the ancestor is a schema, not inside `const` or an unknown keyword.
@(test)
schema_pointer_ignores_ids_outside_schemas :: proc(t: ^testing.T) {
	text := `{"definitions": {"z": {"type": "string"}},
		"const": {"$id": "http://other.example/c", "inner": {"$ref": "#/definitions/z"}},
		"x-extra": {"$id": "http://other.example/d", "inner": {"$ref": "#/definitions/z"}},
		"allOf": [{"$ref": "#/const/inner"}, {"$ref": "#/x-extra/inner"}]}`
	d, res, doc, err := read_text(text)
	defer rules.description_destroy(&d)
	defer core.destroy(&doc)
	defer schema.resolver_destroy(&res)
	testing.expect(t, err == nil)
}

// A count may be written as `-0` or with an exponent. It is read by value, and a value past 64 bits is the greatest count.
@(test)
schema_reads_counts_by_value :: proc(t: ^testing.T) {
	d, res, doc, err := read_text(`{"minLength": -0, "maxLength": 1e400, "maxItems": 2.0e1, "minItems": 1E1}`)
	defer rules.description_destroy(&d)
	defer core.destroy(&doc)
	defer schema.resolver_destroy(&res)
	testing.expect(t, err == nil)
	n := d.nodes[d.root].rules
	testing.expect_value(t, n.min_length, 0)
	testing.expect_value(t, n.max_length, Maybe(u64)(max(u64)))
	testing.expect_value(t, n.max_items, Maybe(u64)(20))
	testing.expect_value(t, n.min_items, 10)
	_, res2, doc2, err2 := read_text(`{"minLength": -1}`)
	defer core.destroy(&doc2)
	defer schema.resolver_destroy(&res2)
	testing.expect_value(t, refused_keyword(err2), "minLength")
}

// A schema read from `text` in the format `spec` and bound to it. `checked` frees what it holds.
@(private = "file")
Checked :: struct {
	doc:      core.Document,
	compiled: schema.Compiled,
	bound:    schema.Bound,
}

@(private = "file")
checked_make :: proc(text: string, spec := json.Spec.Json, allocator := context.allocator) -> (c: ^Checked, err: core.Error) {
	c = new(Checked)
	c.doc, _ = core.build(transmute([]u8)text, json.as(.Json))
	if c.compiled, err = schema.compile(&c.doc, core.ROOT, {resolver = {as = json.as(.Json)}}); err == nil {
		c.bound, err = schema.bind(&c.compiled, json.as(spec), allocator = allocator)
	}
	return
}

@(private = "file")
checked_destroy :: proc(c: ^Checked) {
	schema.unbind(&c.bound)
	schema.destroy(&c.compiled)
	core.destroy(&c.doc)
	free(c)
}

// Each verdict is JSON Schema's, from a text and from its document. A schema with no `$schema` reads as 2020-12.
@(test)
schema_check_verdicts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		schema, text: string,
		valid:        bool,
	} {
		{`{"type": "integer"}`, `1.0`, true},
		{`{"required": ["c"], "additionalProperties": false}`, `{"c": 1}`, false},
		{`{"required": ["c"], "properties": {"a": {}}, "additionalProperties": false}`, `{"c": 1}`, false},
		{`{"required": ["c"], "properties": {"c": {}}, "additionalProperties": false}`, `{"c": 1}`, true},
		{`{"required": ["c"], "additionalProperties": {"type": "string"}}`, `{"c": "x", "d": "y"}`, true},
		{`{"required": ["c"], "additionalProperties": {"type": "string"}}`, `{"c": 1}`, false},
		{`{"propertyNames": {"type": "integer"}}`, `{"1": 1}`, false},
		{`{"propertyNames": {"type": "number"}}`, `{"1": 1}`, false},
		{`{"propertyNames": {"const": 1}}`, `{"1": 1}`, false},
		{`{"propertyNames": {"const": "1"}}`, `{"1": 1}`, true},
		{`{"propertyNames": {"maxLength": 1}}`, `{"1": 1}`, true},
		{`{"multipleOf": 0.1}`, `0.3`, true},
		{`{"multipleOf": 1234567890123456789}`, `2469135780246913578`, true},
		{`{"multipleOf": 1234567890123456789}`, `2469135780246913579`, false},
		{`{"multipleOf": 3}`, `1e400`, false},
		{`{"multipleOf": 2}`, `1e400`, true},
		{`{"pattern": "^\\/[^\\*\\?\\&\\%]*(\\/\\*)?$"}`, `"/a/*"`, true},
		{`{"pattern": "^\\/[^\\*\\?\\&\\%]*(\\/\\*)?$"}`, `"/a&"`, false},
	}
	for c in cases {
		ch, err := checked_make(c.schema)
		defer checked_destroy(ch)
		testing.expectf(t, err == nil, "%s: %v", c.schema, err)
		doc, _ := core.build(transmute([]u8)c.text, json.as(.Json))
		defer core.destroy(&doc)
		from_text, from_node := schema.valid(&ch.bound, transmute([]u8)c.text), schema.check_node(&ch.bound, &doc, core.ROOT) == nil
		testing.expectf(t, from_text == c.valid && from_node == c.valid, "%s on %s: text %v, node %v", c.schema, c.text, from_text, from_node)
	}
}

// A schema the check cannot judge exactly is refused at bind, naming the keyword, and a bind of a compile that failed is
// refused without reading it.
@(test)
schema_bind_refusals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for text in ([?]string{`{"multipleOf": 3.0000000000000000001}`, `{"multipleOf": 0.123456789012345678901}`, `{"multipleOf": 1e-1000000000000000000000000000000000}`}) {
		ch, err := checked_make(text)
		defer checked_destroy(ch)
		f, _ := err.(core.Typed_Failure)
		testing.expectf(t, f.kind == .Unsupported && f.want.text == "multipleOf", "%s: %v", text, err)
	}
	doc, _ := core.build(transmute([]u8)string(`{"pattern": "["}`), json.as(.Json))
	defer core.destroy(&doc)
	c, cerr := schema.compile(&doc, core.ROOT, {resolver = {as = json.as(.Json)}})
	defer schema.destroy(&c)
	testing.expect(t, cerr != nil)
	_, berr := schema.bind(&c, json.as(.Json))
	testing.expect_value(t, berr.(core.Typed_Failure).kind, core.Typed_Error_Kind.Bad_Option)
}

// A bind frees what the stamp of an object operand sorts, whether it binds or is refused, and two numbers one double
// holds stamp two plans.
@(test)
schema_bind_stamps :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	for text in ([?]string{`{"enum": [1, {"a": 1}]}`, `{"properties": {"a": {}}}`}) {
		ch, _ := checked_make(text, allocator = mem.tracking_allocator(&track))
		checked_destroy(ch)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
	a, _ := checked_make(`{"const": 9007199254740993}`)
	defer checked_destroy(a)
	b, _ := checked_make(`{"const": 9007199254740992}`)
	defer checked_destroy(b)
	testing.expect(t, a.bound.plan.stamp != b.bound.plan.stamp)
}

// A container that fails its kind or enum spans the container, from a text and from its document.
@(test)
schema_check_spans_containers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		schema, text: string,
		end:          u64,
	} {
		{`{"type": "string"}`, `{"a": [1, 2]}`, 13},
		{`{"enum": [1, 2]}`, `{"x": 1}`, 8},
		{`{"properties": {"x": {"type": "string"}}}`, `{"x": [1]}`, 9},
	}
	for c in cases {
		ch, _ := checked_make(c.schema)
		defer checked_destroy(ch)
		doc, _ := core.build(transmute([]u8)c.text, json.as(.Json))
		defer core.destroy(&doc)
		from_text, from_node: typed.Sink
		defer typed.sink_destroy(&from_text)
		defer typed.sink_destroy(&from_node)
		schema.check(&ch.bound, transmute([]u8)c.text, &from_text)
		schema.check_node(&ch.bound, &doc, core.ROOT, &from_node)
		testing.expectf(t, len(from_text.entries) == 1 && len(from_node.entries) == 1, "%s on %s: %d and %d entries", c.schema, c.text, len(from_text.entries), len(from_node.entries))
		if len(from_text.entries) == 1 && len(from_node.entries) == 1 {
			x, y := from_text.entries[0], from_node.entries[0]
			testing.expectf(t, x.end == c.end && y.end == c.end && x.start == y.start, "%s on %s: [%d,%d) and [%d,%d)", c.schema, c.text, x.start, x.end, y.start, y.end)
		}
	}
}

@(private = "file")
Json5_Bound :: struct {
	x: f64 `model:"<=5"`,
}

@(private = "file")
Json5_Count :: struct {
	n: i64 `model:">=0"`,
}

// A number JSON5 spells otherwise than a decimal is judged by its value, in a model's load and in the check of its schema.
@(test)
schema_check_agrees_on_json5_numbers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		type:  typeid,
		text:  string,
		valid: bool,
	} {
		{Json5_Bound, `{x: 0x10}`, false},
		{Json5_Bound, `{x: +6}`, false},
		{Json5_Bound, `{x: Infinity}`, false},
		{Json5_Bound, `{x: NaN}`, false},
		{Json5_Bound, `{x: 0x5}`, true},
		{Json5_Count, `{n: -0x1}`, false},
		{Json5_Count, `{n: 0x1}`, true},
	}
	for c in cases {
		plan, planned := json.plan_make(c.type, .Json5, plan = {rule_tags = true}, reads = json.reads(.Json5))
		testing.expect(t, planned == nil)
		target := make([]u8, size_of(Json5_Bound))
		loaded := typed.check_text(transmute([]u8)c.text, raw_data(target), c.type, &plan, {}) == nil
		d, _ := model.describe(&plan)
		compiled := schema.compile_description(&d)
		b, bound := schema.bind(&compiled, json.as(.Json5))
		testing.expect(t, bound == nil)
		checked := schema.valid(&b, transmute([]u8)c.text)
		testing.expectf(t, loaded == c.valid && checked == c.valid, "%v %s: load %v, check %v", c.type, c.text, loaded, checked)
	}
}

// A use's `multipleOf` or `pattern` that differs from its node's is refused, since both would hold.
@(test)
schema_leaf_refuses_two_divisors :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n := rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, rules = {multiple_of = "2", pattern = "a"}}
	_, refused := rules.leaf_of(&n, {multiple_of = "3"}, context.temp_allocator)
	testing.expect_value(t, refused, "multipleOf")
	_, refused = rules.leaf_of(&n, {pattern = "b"}, context.temp_allocator)
	testing.expect_value(t, refused, "pattern")
	_, refused = rules.leaf_of(&n, {multiple_of = "2", pattern = "a"}, context.temp_allocator)
	testing.expect_value(t, refused, "")
}
