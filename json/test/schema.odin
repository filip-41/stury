package json_tests

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import compose "../../core/compose"
import rules "../../core/rules"
import typed "../../core/typed"
import write "../../core/write"
import schema "../../core/schema"
import json ".."

@(private = "file")
SUITE :: #directory + "conformance/JSON-Schema-Test-Suite/tests/"

@(private = "file")
FIXTURES :: #directory + "schema"

// The remote documents the suite's runners serve at `REMOTE_URL`, which a read takes as files under its root.
@(private = "file")
REMOTES :: #directory + "conformance/JSON-Schema-Test-Suite/remotes"

@(private = "file")
REMOTE_URL :: "http://localhost:1234/"

// The suite file at `path` with its remote documents named by `file:` URIs.
@(private = "file")
served_suite :: proc(path: string) -> []u8 {
	bytes, _ := os.read_entire_file_from_path(path, context.allocator)
	full, _ := os.get_absolute_path(REMOTES, context.allocator)
	text, _ := strings.replace_all(string(bytes), REMOTE_URL, strings.concatenate({"file://", full, "/"}))
	return transmute([]u8)text
}

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

// A `$vocabulary` outside a meta-schema is ignored, whatever vocabularies it names.
@(test)
schema_vocabulary_outside_a_meta_schema_is_ignored :: proc(t: ^testing.T) {
	d, res, doc, err := read_text(`{"$vocabulary": {"https://example.com/vocab/geo": true}, "type": "string"}`)
	defer core.destroy(&doc)
	defer schema.resolver_destroy(&res)
	defer rules.description_destroy(&d)
	testing.expect_value(t, refused_keyword(err), "")
	testing.expect(t, len(d.nodes) > 0)
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

// Every case of a suite schema the check binds gets the suite's verdict, from its text, from its built document and with
// a sink.
@(test)
schema_suite_checks :: proc(t: ^testing.T) {
	bound, cases, wrong, format_cases, read_total, left_out := 0, 0, 0, 0, 0, 0
	unread := make(map[string]int, context.temp_allocator)
	refused := make(map[string]int, context.temp_allocator)
	for entry in SUITE_DRAFTS {
		w := os.walker_create_path(strings.concatenate({SUITE, entry.dir}, context.temp_allocator))
		defer os.walker_destroy(&w)
		for info in os.walker_walk(&w) {
			if info.type != .Regular || !strings.has_suffix(info.name, ".json") {
				continue
			}
			arena: virtual.Arena
			_ = virtual.arena_init_growing(&arena)
			defer virtual.arena_destroy(&arena)
			context.allocator = virtual.arena_allocator(&arena)
			bytes := served_suite(info.fullpath)
			doc, _ := core.build(bytes, json.as(.Json))
			groups := core.children(&doc, core.ROOT)
			// The format suites run with `format` asserting, since a format is an annotation unless asked to assert.
			in_formats := strings.contains(info.fullpath, "optional/format/")
			// Draft 7's content assertions and the later drafts' `dependencies` are optional behaviour the check leaves out.
			optional_out := strings.has_suffix(info.fullpath, "optional/content.json") || strings.has_suffix(info.fullpath, "optional/dependencies-compatibility.json")
			for group in core.child_next(&groups) {
				node, _ := core.member(&doc, group, "schema")
				read_total += 1
				c, err := schema.compile(&doc, node, {format_assert = in_formats, resolver = {as = json.as(.Json), draft = entry.draft, root = REMOTES}})
				if err != nil {
					unread[strings.clone(refused_keyword(err), context.temp_allocator)] += 1
					continue
				}
				b, berr := schema.bind(&c, json.as(.Json))
				if berr != nil {
					f, _ := berr.(core.Typed_Failure)
					refused[strings.clone(f.want.text, context.temp_allocator)] += 1
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
					sink: typed.Sink
					first := schema.check(&b, core.span(&doc, data), &sink)
					from_sink := first == nil && len(sink.entries) == 0
					typed.sink_destroy(&sink)
					cases += 1
					format_cases += int(in_formats)
					if from_node != valid || from_text != valid || from_sink != valid {
						if optional_out {
							left_out += 1
							continue
						}
						wrong += 1
						about, _ := core.member(&doc, test, "description")
						text, _ := core.text_clone(&doc, about)
						log.warnf("%s: %s: want %v, node %v, text %v, sink %v", info.fullpath[len(SUITE):], text, valid, from_node, from_text, from_sink)
					}
				}
			}
		}
	}
	for keyword, n in unread {
		log.infof("read refused %s: %d", keyword, n)
	}
	for keyword, n in refused {
		log.infof("check refused %s: %d", keyword, n)
	}
	log.infof("suite checks: %d schemas, %d bound, %d cases (%d of formats, %d of left-out optional behaviour judged as annotations), %d wrong", read_total, bound, cases, format_cases, left_out, wrong)
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
	testing.expect_value(t, strings.to_string(out), "1:7: Number is below the minimum at .a (.properties.a.minimum)\n1:21: Value is not of the allowed type at .b[1] (.properties.b.items.type)\n1:30: No value is allowed here at .z (.additionalProperties)\n1:1: Required member \"c\" is missing (.required)\n")
	testing.expect(t, !schema.valid(&b, src))
	// `c` is only required, so `additionalProperties` refuses it too.
	testing.expect(t, !schema.valid(&b, transmute([]u8)string(`{"a": 2, "c": null}`)))
}

// A failure under an applicator reports the value's path and the keywords through the applicator to the rule.
@(test)
schema_check_reports_arms :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := `{"properties": {"a": {"allOf": [{"minimum": 2}], "anyOf": [{"type": "string"}, {"type": "boolean"}]}, "l": {"contains": {"const": 0}, "uniqueItems": true}}, "patternProperties": {"^x": {"type": "integer"}}, "dependentRequired": {"a": ["q"]}, "not": {"required": ["n"]}}`
	ch, err := checked_make(text)
	defer checked_destroy(ch)
	testing.expect(t, err == nil)
	src := transmute([]u8)string(`{"a": 1, "xy": "s", "l": [1, 1], "n": 0}`)
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	first := schema.check(&ch.bound, src, &sink)
	testing.expect_value(t, first.(core.Typed_Failure).kind, core.Typed_Error_Kind.Below_Minimum)
	out := strings.builder_make(context.temp_allocator)
	for e in sink.entries {
		core.render_entry(strings.to_stream(&out), src, e)
		strings.write_byte(&out, '\n')
	}
	testing.expect_value(t, strings.to_string(out), "1:7: Number is below the minimum at .a (.properties.a.allOf[0].minimum)\n1:7: Value passes none of the subschemas at .a (.properties.a.anyOf)\n1:16: Value is not of the allowed type at .xy (.patternProperties.\"^x\".type)\n1:26: Elements are not unique at .l (.properties.l.uniqueItems)\n1:26: Too few elements or members at .l (.properties.l.contains)\n1:1: Required member \"q\" is missing (.dependentRequired)\n1:1: No value is allowed here (.not)\n")
}

// A check with no sink reads `allOf` and `$ref` arms conjoined into one, and the parts beside a lone `anyOf` or `oneOf`
// spread into each of its arms, and its verdicts are those of a check with a sink, which reads each arm.
@(test)
schema_conjoined_verdicts_agree :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	schemas := [?]string{
		`{"$defs": {"r": {"type": "object", "properties": {"a": {"type": "integer"}, "b": {"type": "string"}}, "additionalProperties": false}, "q": {"required": ["a", "b"]}}, "allOf": [{"$ref": "#/$defs/r"}, {"$ref": "#/$defs/q"}]}`,
		`{"properties": {"a": {"minimum": 1}}, "allOf": [{"properties": {"a": {"maximum": 3}, "c": {"items": {"type": "integer"}}}}, {"properties": {"c": {"prefixItems": [{"const": 1}]}}}]}`,
		`{"type": "object", "required": ["v"], "oneOf": [{"properties": {"v": {"const": 1}, "x": {"type": "string"}}, "additionalProperties": false}, {"properties": {"v": {"const": 2}}}]}`,
		`{"properties": {"a": {"type": "string"}}, "anyOf": [{"required": ["a"]}, {"properties": {"a": {"maxLength": 1}}}], "allOf": [{"if": {"required": ["b"]}, "then": {"required": ["a"]}}]}`,
	}
	texts := [?]string{`{"a": 1, "b": "s"}`, `{"a": 1}`, `{"a": 4, "c": [1, 2]}`, `{"a": 2, "c": [2]}`, `{"v": 1, "x": "s"}`, `{"v": 2, "x": 1}`, `{"v": 1, "y": 0}`, `{"v": 3}`, `{"b": 0}`, `{"a": "ss", "b": 0}`, `{}`, `[]`, `1`}
	for schema_text in schemas {
		ch, err := checked_make(schema_text)
		testing.expect(t, err == nil, schema_text)
		for text in texts {
			src := transmute([]u8)string(text)
			sink: typed.Sink
			reported := schema.check(&ch.bound, src, &sink) == nil
			typed.sink_destroy(&sink)
			testing.expectf(t, schema.valid(&ch.bound, src) == reported, "%s against %s", schema_text, text)
		}
		checked_destroy(ch)
	}
}

// An `enum` of many object operands checks many items in memory that grows with neither: an item is compared with the
// operands of its hash, and a comparison takes back what it took.
@(test)
schema_object_enum_memory :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	COUNT :: 10000
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, `{"items": {"enum": [`)
	for i in 0 ..< COUNT {
		strings.write_string(&b, `, {"a": ` if i > 0 else `{"a": `)
		strings.write_int(&b, i)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, `]}}`)
	ch, err := checked_make(strings.to_string(b))
	testing.expect(t, err == nil)
	defer checked_destroy(ch)
	items := strings.to_string(b)[len(`{"items": {"enum": `):len(b.buf) - 2]
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.temp_allocator = mem.tracking_allocator(&track)
	testing.expect(t, schema.valid(&ch.bound, transmute([]u8)items))
	testing.expectf(t, track.peak_memory_allocated < 16 << 20, "%d bytes", track.peak_memory_allocated)
}

// A failing property name reports its keyword under `propertyNames` at the object, a `false` there allows no name, and a
// missing member of a nested object is reported at the object.
@(test)
schema_check_reports_names_and_required :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		schema, text, want: string,
	} {
		{`{"propertyNames": {"maxLength": 1}}`, `{"ab": 1}`, "1:2: String is too long (.propertyNames.maxLength)\n"},
		{`{"propertyNames": false}`, `{"a": 1}`, "1:2: No value is allowed here (.propertyNames)\n"},
		{`{"properties": {"o": {"required": ["k"]}}}`, `{"o": {}}`, "1:7: Required member \"k\" is missing at .o (.properties.o.required)\n"},
	}
	for c in cases {
		ch, err := checked_make(c.schema)
		defer checked_destroy(ch)
		testing.expectf(t, err == nil, "%s: %v", c.schema, err)
		sink: typed.Sink
		defer typed.sink_destroy(&sink)
		src := transmute([]u8)c.text
		schema.check(&ch.bound, src, &sink)
		out := strings.builder_make(context.temp_allocator)
		for e in sink.entries {
			core.render_entry(strings.to_stream(&out), src, e)
			strings.write_byte(&out, '\n')
		}
		testing.expectf(t, strings.to_string(out) == c.want, "%s on %s: %q", c.schema, c.text, strings.to_string(out))
	}
}

@(private = "file")
Corpus_Tie :: struct {
	x: f64 `model:"<=0.1"`,
}

@(private = "file")
Corpus_Formats :: struct {
	at: string `model:"format=date-time,optional"`,
	mail: string `model:"format=email,optional"`,
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

@(private = "file")
Typed_Spelling :: struct {
	type:  typeid,
	enums: typed.Enum_Spelling,
}

// The plans of the corpus types' models, in each spelling of enums.
@(private = "file")
corpus_plans :: proc() -> map[Typed_Spelling]typed.Plan {
	plans := make(map[Typed_Spelling]typed.Plan, context.temp_allocator)
	for enums in typed.Enum_Spelling {
		plans[{Corpus_Tie, enums}] = ruled_plan(Corpus_Tie, enums)
		plans[{Corpus_Formats, enums}] = ruled_plan(Corpus_Formats, enums)
		plans[{Corpus_Whole, enums}] = ruled_plan(Corpus_Whole, enums)
		plans[{Corpus_Narrow, enums}] = ruled_plan(Corpus_Narrow, enums)
		plans[{Corpus_Keys, enums}] = ruled_plan(Corpus_Keys, enums)
		plans[{Corpus_Gap, enums}] = ruled_plan(Corpus_Gap, enums)
		plans[{Corpus_Enum_Keys, enums}] = ruled_plan(Corpus_Enum_Keys, enums)
	}
	return plans
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
	plans := corpus_plans()
	for c in cases {
		plan := plans[{c.type, c.enums}]
		target := make([]u8, size_of(Corpus_Keys))
		loaded := typed.check_text(transmute([]u8)c.text, raw_data(target), c.type, &plan, {}) == nil
		d, described := description_of(&plan)
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
		{`{"multipleOf": 3.0000000000000000001}`, `6.0000000000000000002`, true},
		{`{"multipleOf": 3.0000000000000000001}`, `6.0000000000000000003`, false},
		{`{"multipleOf": 3.0000000000000000001}`, `6`, false},
		{`{"multipleOf": 0.123456789012345678901}`, `0.246913578024691357802`, true},
		{`{"multipleOf": 0.123456789012345678901}`, `123456789012345678901e-21`, true},
		{`{"multipleOf": 0.123456789012345678901}`, `0.246913578024691357803`, false},
		{`{"multipleOf": 3}`, `1e400`, false},
		{`{"multipleOf": 2}`, `1e400`, true},
		{`{"pattern": "^\\/[^\\*\\?\\&\\%]*(\\/\\*)?$"}`, `"/a/*"`, true},
		{`{"pattern": "^\\/[^\\*\\?\\&\\%]*(\\/\\*)?$"}`, `"/a&"`, false},
		{`{"propertyNames": {"maxLength": 3}, "required": ["a"]}`, `{"b": 1}`, false},
		{`{"propertyNames": {"maxLength": 3}, "required": ["a"]}`, `{"a": 1}`, true},
		{`{"propertyNames": {"maxLength": 3}, "properties": {"a": {}}, "required": ["a"]}`, `{"b": 1}`, false},
		{`{"propertyNames": {"maxLength": 3}, "properties": {"a": {}}, "required": ["a"]}`, `{"a": 1, "b": 2}`, true},
		{`{"const": "x", "enum": ["y"]}`, `"x"`, false},
		{`{"const": "x", "enum": ["y"]}`, `"y"`, false},
		{`{"const": "x", "enum": ["x", "y"]}`, `"x"`, true},
		{`{"const": "x", "enum": ["x", "y"]}`, `"y"`, false},
		{`{"patternProperties": {"^a": {"type": "string"}}, "properties": {"ab": {"maxLength": 1}}, "additionalProperties": false}`, `{"ab": "x"}`, true},
		{`{"patternProperties": {"^a": {"type": "string"}}, "properties": {"ab": {"maxLength": 1}}, "additionalProperties": false}`, `{"ab": 1}`, false},
		{`{"patternProperties": {"^a": {"type": "string"}}, "properties": {"ab": {"maxLength": 1}}, "additionalProperties": false}`, `{"ac": "xy", "b": 1}`, false},
		{`{"patternProperties": {"^a": {"type": "string"}}, "required": ["b"], "additionalProperties": {"type": "integer"}}`, `{"b": 1}`, true},
		{`{"patternProperties": {"^a": {"type": "string"}}, "required": ["b"], "additionalProperties": {"type": "integer"}}`, `{"b": "x"}`, false},
		{`{"items": {"anyOf": [{"type": "integer"}, {"enum": [[1]]}]}}`, `[1, [1], [1.0]]`, true},
		{`{"items": {"anyOf": [{"type": "integer"}, {"enum": [[1]]}]}}`, `[[2]]`, false},
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
	for text in ([?]string{`{"multipleOf": 1e-1000000000000000000000000000000000}`}) {
		ch, err := checked_make(text)
		defer checked_destroy(ch)
		f, _ := err.(core.Typed_Failure)
		testing.expectf(t, f.kind == .Unsupported && f.want.text == "multipleOf", "%s: %v", text, err)
	}
	names, nerr := checked_make(`{"propertyNames": {"anyOf": [{"maxLength": 1}]}}`)
	defer checked_destroy(names)
	nf, _ := nerr.(core.Typed_Failure)
	testing.expect(t, nf.kind == .Unsupported && nf.want.text == "propertyNames")
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
	plans := [?]typed.Plan{ruled_plan(Json5_Bound, reads = json.reads(.Json5)), ruled_plan(Json5_Count, reads = json.reads(.Json5))}
	for c in cases {
		plan := plans[0 if c.type == Json5_Bound else 1]
		target := make([]u8, size_of(Json5_Bound))
		loaded := typed.check_text(transmute([]u8)c.text, raw_data(target), c.type, &plan, {}) == nil
		d, _ := description_of(&plan)
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

@(private = "file")
Pairs :: map[[2]rules.Node_Index]bool

// Whether node `i` of `a` and node `j` of `b` take the same values by structure: the kinds, the arms, the members and
// their requirement, the array and object shapes and the operands of `enum` and `const`. A node and its copy are one,
// so a shared node written once equals a repeated one, and a `$ref` with rules beside it equals the node it reaches with
// those rules. A block of the defaults equals no block. `with_rules` adds the rules a node has with the rules `ea` and
// `eb` of its use, where `assert_format` counts only beside a `format`.
@(private = "file")
same_schema :: proc(a, b: ^rules.Description, from_a, from_b: rules.Node_Index, seen: ^Pairs, with_rules: bool, ea := rules.Rules{}, eb := rules.Rules{}) -> bool {
	if from_a == rules.NONE || from_b == rules.NONE {
		return from_a == from_b
	}
	ea, eb := ea, eb
	i, j := followed(a, from_a, &ea), followed(b, from_b, &eb)
	if seen[{i, j}] {
		return true
	}
	seen[{i, j}] = true
	x, y := a.nodes[i], b.nodes[j]
	rx, _ := rules.merged(&x, ea)
	ry, _ := rules.merged(&y, eb)
	for r in ([?]^rules.Rules{&rx, &ry}) {
		r.assert_format &&= r.format != ""
	}
	if x.kinds != y.kinds || (with_rules && rx != ry) || len(x.enum_of) != len(y.enum_of) || (x.enum_of == nil) != (y.enum_of == nil) {
		return false
	}
	for v, k in x.enum_of {
		if !core.equal(v, y.enum_of[k]) {
			return false
		}
	}
	cx, hx := x.const_of.?
	cy, hy := y.const_of.?
	if hx != hy || (hx && !core.equal(cx, cy)) {
		return false
	}
	same_list :: proc(a, b: ^rules.Description, xs, ys: []rules.Node_Index, seen: ^Pairs, with_rules: bool) -> bool {
		if len(xs) != len(ys) {
			return false
		}
		for _, k in xs {
			if !same_schema(a, b, xs[k], ys[k], seen, with_rules) {
				return false
			}
		}
		return true
	}
	opt :: proc(m: Maybe(rules.Node_Index)) -> rules.Node_Index {
		return m.? or_else rules.NONE
	}
	if !same_list(a, b, x.any_of, y.any_of, seen, with_rules) || !same_list(a, b, x.all_of, y.all_of, seen, with_rules) || !same_list(a, b, x.one_of, y.one_of, seen, with_rules) {
		return false
	}
	pairs := [?][2]rules.Node_Index {
		{opt(x.not), opt(y.not)},
		{opt(x.cond.test), opt(y.cond.test)},
		{opt(x.cond.then), opt(y.cond.then)},
		{opt(x.cond.other), opt(y.cond.other)},
		{opt(x.unevaluated_items), opt(y.unevaluated_items)},
		{opt(x.unevaluated_properties), opt(y.unevaluated_properties)},
		{opt(x.ref), opt(y.ref)},
		{opt(x.dynamic_ref), opt(y.dynamic_ref)},
	}
	if anchor_names(a, i) != anchor_names(b, j) {
		return false
	}
	for p in pairs {
		if !same_schema(a, b, p[0], p[1], seen, with_rules) {
			return false
		}
	}
	ax, ay := rules.Array{items = rules.NONE}, rules.Array{items = rules.NONE}
	if x.array >= 0 {
		ax = a.arrays[x.array]
	}
	if y.array >= 0 {
		ay = b.arrays[y.array]
	}
	if !same_list(a, b, ax.prefix, ay.prefix, seen, with_rules) || !same_schema(a, b, ax.items, ay.items, seen, with_rules) || !same_schema(a, b, opt(ax.contains), opt(ay.contains), seen, with_rules) || ax.min_contains != ay.min_contains || ax.max_contains != ay.max_contains {
		return false
	}
	ox, oy := rules.Object{additional = rules.NONE, keys = rules.NONE}, rules.Object{additional = rules.NONE, keys = rules.NONE}
	if x.object >= 0 {
		ox = a.objects[x.object]
	}
	if y.object >= 0 {
		oy = b.objects[y.object]
	}
	if len(ox.members) != len(oy.members) || len(ox.patterns) != len(oy.patterns) || len(ox.dependents) != len(oy.dependents) {
		return false
	}
	for m, k in ox.members {
		n := oy.members[k]
		if m.name != n.name || m.required != n.required || m.only_required != n.only_required || !same_schema(a, b, m.node, n.node, seen, with_rules, m.rules, n.rules) {
			return false
		}
	}
	for p, k in ox.patterns {
		if p.expression != oy.patterns[k].expression || !same_schema(a, b, p.node, oy.patterns[k].node, seen, with_rules) {
			return false
		}
	}
	for p in ox.dependents {
		q: rules.Dependent
		for candidate in oy.dependents {
			if candidate.name == p.name {
				q = candidate
			}
		}
		if q.name != p.name || len(p.required) != len(q.required) || !same_schema(a, b, opt(p.node), opt(q.node), seen, with_rules) {
			return false
		}
		for name, e in p.required {
			if name != q.required[e] {
				return false
			}
		}
	}
	return same_schema(a, b, ox.additional, oy.additional, seen, with_rules) && same_schema(a, b, ox.keys, oy.keys, seen, with_rules)
}

// The dynamic anchor names of node `i`, joined, where the written `_recursive` is the read `$recursive`.
@(private = "file")
anchor_names :: proc(d: ^rules.Description, i: rules.Node_Index) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for x in d.anchors {
		if x.node == i {
			append(&names, strings.trim_left(x.name, "$_"))
		}
	}
	slice.sort(names[:])
	return strings.join(names[:], " ", context.temp_allocator)
}

// The node a `$ref` with at most rules beside it reaches, which judges as the reference does, with those rules added to
// `extra`.
@(private = "file")
followed :: proc(d: ^rules.Description, i: rules.Node_Index, extra: ^rules.Rules) -> rules.Node_Index {
	i := i
	for {
		bare := d.nodes[i]
		bare.rules = {}
		if !rules.ref_only(&bare) {
			return i
		}
		extra^, _ = rules.merged(&d.nodes[i], extra^)
		i = d.nodes[i].ref.?
	}
}

// Writes `d` and compiles the text back as 2020-12, asserting formats when `d` does. A description the write refuses
// comes back with the keyword it names.
@(private = "file")
written_back :: proc(t: ^testing.T, d: ^rules.Description, doc: ^core.Document) -> (back: schema.Compiled, text: []u8, refused: string) {
	werr: core.Error
	text, werr = schema.write(d, json.as(.Json))
	if f, is_typed := werr.(core.Typed_Failure); is_typed && f.kind == .Unsupported {
		return {}, nil, f.want.text
	}
	testing.expectf(t, werr == nil, "write: %v", werr)
	built, berr := core.build(text, json.as(.Json))
	testing.expectf(t, berr == nil, "built %s: %v", text, berr)
	doc^ = built
	asserts := false
	for n in d.nodes {
		asserts ||= n.rules.assert_format && n.rules.format != ""
	}
	for o in d.objects {
		for m in o.members {
			asserts ||= m.rules.assert_format && m.rules.format != ""
		}
	}
	cerr: core.Error
	back, cerr = schema.compile(doc, core.ROOT, {format_assert = asserts, resolver = {as = json.as(.Json)}})
	testing.expectf(t, cerr == nil, "read %s: %v", text, cerr)
	if cerr != nil {
		return {}, text, "compile"
	}
	return back, text, ""
}

// Every schema of the suite that reads and has no draft 4 integer writes and reads back as itself,
// and the written schema judges every instance as the schema did, text and document alike, with formats asserted on both
// sides where the suite asserts them. Verdicts under applicators wait for 5b, which the check does not judge yet, so a
// schema that does not bind is counted and compared by shape only.
@(test)
schema_write_reads_back_to_the_suite_schemas :: proc(t: ^testing.T) {
	written, differ, cases, wrong := 0, 0, 0, 0
	skips := make(map[string]int, context.temp_allocator)
	for entry in SUITE_DRAFTS {
		w := os.walker_create_path(strings.concatenate({SUITE, entry.dir}, context.temp_allocator))
		defer os.walker_destroy(&w)
		for info in os.walker_walk(&w) {
			if info.type != .Regular || !strings.has_suffix(info.name, ".json") {
				continue
			}
			arena: virtual.Arena
			_ = virtual.arena_init_growing(&arena)
			defer virtual.arena_destroy(&arena)
			context.allocator = virtual.arena_allocator(&arena)
			bytes := served_suite(info.fullpath)
			doc, _ := core.build(bytes, json.as(.Json))
			groups := core.children(&doc, core.ROOT)
			in_formats := strings.contains(info.fullpath, "optional/format/")
			for group in core.child_next(&groups) {
				node, _ := core.member(&doc, group, "schema")
				c, err := schema.compile(&doc, node, {format_assert = in_formats, resolver = {as = json.as(.Json), draft = entry.draft, root = REMOTES}})
				if err != nil {
					skips["read"] += 1
					continue
				}
				back_doc: core.Document
				back, text, refused := written_back(t, c.description, &back_doc)
				if refused != "" {
					skips[refused] += 1
					testing.expectf(t, refused == "integer", "%s: refused %s", info.fullpath[len(SUITE):], refused)
					continue
				}
				written += 1
				seen: Pairs
				if !same_schema(c.description, back.description, c.description.root, back.description.root, &seen, true) {
					differ += 1
					log.warnf("%s: written back differs: %s", info.fullpath[len(SUITE):], text)
				}
				b, berr := schema.bind(&c, json.as(.Json))
				b2, b2err := schema.bind(&back, json.as(.Json))
				if berr != nil || b2err != nil {
					skips["bind"] += 1
					continue
				}
				tests, _ := core.member(&doc, group, "tests")
				all := core.children(&doc, tests)
				for test in core.child_next(&all) {
					data, _ := core.member(&doc, test, "data")
					want := schema.check_node(&b, &doc, data) == nil
					from_text := schema.valid(&b2, core.span(&doc, data))
					cases += 1
					if from_text != want {
						wrong += 1
						log.warnf("%s: verdict %v, written %v: %s", info.fullpath[len(SUITE):], want, from_text, text)
					}
				}
			}
		}
	}
	log.infof("suite writes: %d written, %d differ, %d cases, %d wrong, skipped %v", written, differ, cases, wrong, skips)
	testing.expect_value(t, differ, 0)
	testing.expect_value(t, wrong, 0)
}

@(private = "file")
Written_Tree :: struct {
	name:  string,
	kids:  []Written_Tree,
	up:    ^Written_Tree,
	may:   Maybe(Written_Leaf),
	other: Written_Leaf,
	pick:  union {
		i64,
		string,
		[]Written_Leaf,
	},
	named: map[string]Written_Leaf,
	fixed: [3]i16,
	color: enum {
		Red,
		Green,
	},
	free:  any,
}

@(private = "file")
Written_Leaf :: struct {
	n: i32 `json:"n,required"`,
	s: string `model:"len>=2"`,
}

// A type's description writes and reads back as a description of the same rules, a member's `model:` rules beside a
// shared node's `$ref` or merged into an unshared one, and the written schema judges the instances of the merged types
// as the type does. The check does not judge a `$ref` with siblings yet, so the shared members compare by shape.
@(test)
schema_write_reads_back_to_described_types :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	plans := corpus_plans()
	for enums in typed.Enum_Spelling {
		plans[{Written_Tree, enums}] = ruled_plan(Written_Tree, enums)
		plans[{Written_Member, enums}] = ruled_plan(Written_Member, enums)
		plans[{Written_Merge, enums}] = ruled_plan(Written_Merge, enums)
	}
	for key, &plan in plans {
		d, described := description_of(&plan)
		testing.expect(t, described == nil)
		doc: core.Document
		back, text, refused := written_back(t, &d, &doc)
		testing.expectf(t, refused == "", "%v: %s", key.type, refused)
		seen: Pairs
		testing.expectf(t, same_schema(&d, back.description, d.root, back.description.root, &seen, true), "%v %v: %s", key.type, key.enums, text)
	}
	plan := ruled_plan(Written_Merge)
	d, _ := description_of(&plan)
	doc: core.Document
	back, text, _ := written_back(t, &d, &doc)
	b, bound := schema.bind(&back, json.as(.Json))
	testing.expect(t, bound == nil)
	cases := [?]struct {
		text:  string,
		valid: bool,
	} {
		{`{"at": "1998-12-31T23:59:60Z"}`, true},
		{`{"at": "1998-12-31 23:59:59Z"}`, false},
		{`{"at": "1998-13-31T23:59:59Z"}`, false},
		{`{"at": "2021-02-30T00:00:00Z"}`, false},
		{`{"a": 100, "b": 1}`, true},
		{`{"a": 200}`, false},
		{`{"b": 0}`, false},
		{`{"b": 70000}`, false},
	}
	for c in cases {
		testing.expectf(t, schema.valid(&b, transmute([]u8)c.text) == c.valid, "%s against %s", c.text, text)
	}
}

// Members of one type, whose node is shared and so written as a `$ref` with the member's rules beside it.
@(private = "file")
Written_Member :: struct {
	a: i8 `model:"<=1000"`,
	b: i8,
	c: i8 `model:">=1"`,
}

// Members of types of their own, whose rules merge into their nodes: a bound looser than the type's keeps the type's.
@(private = "file")
Written_Merge :: struct {
	a:  i8 `model:"<=1000,optional"`,
	b:  i16 `model:">=1,optional"`,
	at: string `model:"format=date-time,optional"`,
}

@(test)
schema_write_refuses_what_it_cannot_spell :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		text, keyword: string,
		draft:         schema.Draft,
	} {
		{`{"type": "integer"}`, "integer", .D04},
	}
	for c in cases {
		d, _, _, err := read_text(c.text, c.draft)
		testing.expectf(t, err == nil, "%s: %v", c.text, err)
		_, werr := schema.write(&d, json.as(.Json))
		f, _ := werr.(core.Typed_Failure)
		testing.expectf(t, f.kind == .Unsupported && f.want.text == c.keyword, "%s: %v", c.text, werr)
	}
}

// A dynamic reference is written with the `$id` of its resource and the anchors that make it dynamic, and the text reads
// back as the schema that reached the extension's anchor.
@(test)
schema_write_spells_dynamic_references :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	text := `{"$id": "https://x/ext", "$dynamicAnchor": "n", "$ref": "base", "maxProperties": 1, "$defs": {"base": {"$id": "base", "$dynamicAnchor": "n", "properties": {"kid": {"$dynamicRef": "#n"}}}}}`
	d, _, doc, err := read_text(text)
	defer core.destroy(&doc)
	testing.expect(t, err == nil)
	back_doc: core.Document
	back, written, refused := written_back(t, &d, &back_doc)
	defer core.destroy(&back_doc)
	testing.expect_value(t, refused, "")
	testing.expect(t, strings.contains(string(written), "\"$dynamicRef\":\"https://schema.invalid/r"))
	seen: Pairs
	testing.expect(t, same_schema(&d, back.description, d.root, back.description.root, &seen, true))
}

// A JSON5 schema's numbers are written as JSON numbers, and one that is not finite is refused naming its keyword.
@(test)
schema_write_spells_json5_numbers_as_json :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		text, written, keyword: string,
	} {
		{`{minimum: 0x10, maximum: .5, multipleOf: +2.}`, `"minimum":16,"maximum":5e-1,"multipleOf":2e0`, ""},
		{`{minimum: Infinity}`, "", "minimum"},
	}
	for c in cases {
		doc, derr := core.build(transmute([]u8)c.text, json.as(.Json5))
		testing.expect(t, derr == nil)
		res := schema.Resolver {
			as = json.as(.Json5),
		}
		d, rerr := schema.read(&doc, core.ROOT, "", &res)
		testing.expectf(t, rerr == nil, "%s: %v", c.text, rerr)
		text, werr := schema.write(&d, json.as(.Json))
		f, _ := werr.(core.Typed_Failure)
		testing.expectf(t, f.want.text == c.keyword && strings.contains(string(text), c.written), "%s: %s, %v", c.text, text, werr)
	}
}

// An attribute fact `name="value"` read as a format with attributes reads one, its value a string with nothing to decode.
@(private)
markup_attribute :: proc "contextless" (doc: ^core.Document, f: core.Fact) -> (name, value: core.Token) {
	lead := u32(core.comment_lead(f.spelling))
	return {lo = f.lo, n = lead - 2, kind = .String, role = .Key}, {lo = f.lo + u64(lead), n = f.n - lead - 1, kind = .String}
}

// A markup document made by hand: `model` is the JSON text of its data model, where an element is a member whose value
// is its text, empty when it is, or an object of its children and `#text` runs, and each attribute `name="value"` is a
// fact of its node, written past the model.
@(private)
markup_doc :: proc(model: string, attributes: []Markup_Attribute, readers: ^core.Readers) -> core.Document {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, model)
	facts := make([]core.Fact, len(attributes), context.temp_allocator)
	for a, i in attributes {
		strings.write_byte(&b, ' ')
		name, _, _ := strings.partition(a.text, "=")
		facts[i] = {lo = u64(len(b.buf)), node = a.node, n = u32(len(a.text)), role = .Attribute, spelling = core.comment_spelling(u8(len(name) + 2), 1)}
		strings.write_string(&b, a.text)
	}
	doc, _ := core.build(b.buf[:len(model)], json.as(.Json))
	doc.src, doc.facts, doc.readers = b.buf[:], facts, readers
	return doc
}

@(private)
Markup_Attribute :: struct {
	node: core.Node_Index,
	text: string,
}

// The entries of a check, each without its position.
@(private = "file")
rendered :: proc(src: []u8, sink: ^typed.Sink) -> string {
	out := strings.builder_make(context.temp_allocator)
	line := strings.builder_make(context.temp_allocator)
	for e in sink.entries {
		strings.builder_reset(&line)
		core.render_entry(strings.to_stream(&line), src, e)
		_, _, rest := strings.partition(strings.to_string(line), ": ")
		strings.write_string(&out, rest)
		strings.write_byte(&out, '\n')
	}
	return strings.to_string(out)
}

// The check of a markup document gives the errors of the check of its JSON form: attributes and the element's text
// as members, the siblings a member collects as an array at the first one's place, and a sequence bound by
// `prefixItems` as the array of the element's children.
@(test)
schema_check_reads_markup :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	readers := json.as(.Json).readers^
	readers.attribute = markup_attribute
	markup := json.as(.Json)
	markup.readers = &readers
	cases := [?]struct {
		schema, model, form: string,
		attributes:          []Markup_Attribute,
		errors:              int,
		bind:                string, // a member whose record binds `node`, as `xml.nodeType` would
		node:                typed.Markup_Node,
	} {
		// <price currency="EUR">5</price>
		{`{"properties": {"price": {"type": "object", "properties": {"currency": {"enum": ["USD"]}, "#text": {"maxLength": 0}}, "required": ["currency", "amount"], "additionalProperties": false}}}`, `{"price": "5"}`, `{"price": {"currency": "EUR", "#text": "5"}}`, {{2, `currency="EUR"`}}, 3, "", .Any},
		{`{"properties": {"price": {"type": "object", "properties": {"currency": {"enum": ["USD"]}, "amount": {"maxLength": 0}}, "required": ["currency", "amount"], "additionalProperties": false}}}`, `{"price": "5"}`, `{"price": {"currency": "EUR", "amount": "5"}}`, {{2, `currency="EUR"`}}, 2, "amount", .Text},
		// <a id="x7" n="1"/>
		{`{"properties": {"a": {"type": "object", "required": ["id", "name"], "properties": {"id": {"pattern": "^[a-z]+$"}}, "additionalProperties": false}}}`, `{"a": ""}`, `{"a": {"id": "x7", "n": "1"}}`, {{2, `id="x7"`}, {2, `n="1"`}}, 3, "", .Any},
		{`{"properties": {"a": {"required": ["id"], "properties": {"id": {}}, "additionalProperties": false}}}`, `{"a": ""}`, `{"a": {"id": "x7"}}`, {{2, `id="x7"`}}, 0, "", .Any},
		// <a/>, an empty element at a string record
		{`{"properties": {"a": {"type": "string", "minLength": 1}}}`, `{"a": ""}`, `{"a": ""}`, nil, 1, "", .Any},
		// <a id="1"><id>2</id></a>, an attribute and a child of one name, each bound to its node
		{`{"properties": {"a": {"properties": {"id": {"const": "2"}}}}}`, `{"a": {"id": "2"}}`, `{"a": {"id": "2"}}`, {{2, `id="1"`}}, 0, "id", .Element},
		// <a>5</a>, an element whose record takes objects
		{`{"properties": {"a": {"type": "object", "required": ["#text"], "maxProperties": 0}}}`, `{"a": "5"}`, `{"a": {"#text": "5"}}`, nil, 1, "", .Any},
		// <a k="1"><b>2</b>tail</a>
		{`{"properties": {"a": {"properties": {"k": {"type": "integer"}, "b": {"maxLength": 0}, "#text": {"minLength": 5}}, "maxProperties": 2}}}`, `{"a": {"b": "2", "#text": "tail"}}`, `{"a": {"k": "1", "b": "2", "#text": "tail"}}`, {{2, `k="1"`}}, 4, "", .Any},
		// <r><item>a</item><x/><item n="1">bb</item></r>
		{`{"properties": {"r": {"properties": {"item": {"type": "array", "maxItems": 1, "items": {"type": "string"}}, "x": {"type": "string"}}, "maxProperties": 1}}}`, `{"r": {"item": "a", "x": null, "item": "bb"}}`, `{"r": {"item": ["a", {"n": "1", "#text": "bb"}], "x": null}}`, {{8, `n="1"`}}, 4, "", .Any},
		{`{"properties": {"r": {"properties": {"item": {"type": "array", "minItems": 1}}, "maxProperties": 1}}}`, `{"r": {"item": "a", "x": null, "item": "bb"}}`, `{"r": {"item": ["a", "bb"], "x": null}}`, nil, 1, "", .Any},
		// <p>Hi <b>you</b>!</p>
		{`{"properties": {"p": {"type": "array", "prefixItems": [{"const": "Hi "}, {"maxLength": 2}, {"const": "?"}], "maxItems": 2}}}`, `{"p": {"#text": "Hi ", "b": "you", "#text": "!"}}`, `{"p": ["Hi ", "you", "!"]}`, nil, 3, "", .Any},
		{`{"properties": {"p": {"type": "array", "prefixItems": [{"const": "Hi"}], "maxItems": 1}}}`, `{"p": "Hi"}`, `{"p": ["Hi"]}`, nil, 0, "", .Any},
		// <p>Hi<b>x</b></p> under one prefixItems
		{`{"properties": {"p": {"type": "array", "prefixItems": [{"const": "Hi"}]}}}`, `{"p": {"#text": "Hi", "b": "x"}}`, `{"p": ["Hi", "x"]}`, nil, 0, "", .Any},
		{`{"properties": {"p": {"type": "array", "prefixItems": [{}], "maxItems": 1}}}`, `{"p": {"#text": "Hi", "b": "x"}}`, `{"p": ["Hi", "x"]}`, nil, 1, "", .Any},
		// <r><item>a</item><item>b</item></r>, repeated under prefixItems
		{`{"properties": {"r": {"properties": {"item": {"type": "array", "prefixItems": [{"const": "a"}, {"const": "c"}]}}}}}`, `{"r": {"item": "a", "item": "b"}}`, `{"r": {"item": ["a", "b"]}}`, nil, 1, "", .Any},
		// repeated under a nullable array and under an array with no type
		{`{"properties": {"r": {"properties": {"item": {"type": ["array", "null"], "maxItems": 1}}}}}`, `{"r": {"item": "a", "item": "b"}}`, `{"r": {"item": ["a", "b"]}}`, nil, 1, "", .Any},
		{`{"properties": {"r": {"properties": {"item": {"items": {"type": "string"}, "maxItems": 1}}}}}`, `{"r": {"item": "a", "item": "b"}}`, `{"r": {"item": ["a", "b"]}}`, nil, 1, "", .Any},
	}
	for c in cases {
		ch, err := checked_make(c.schema)
		defer checked_destroy(ch)
		testing.expectf(t, err == nil, "%s: %v", c.schema, err)
		bound, _ := schema.bind(&ch.compiled, markup)
		defer schema.unbind(&bound)
		for m, i in bound.plan.meta {
			if c.bind != "" && m.name == c.bind {
				bound.plan.uses[i].node = c.node
			}
		}
		doc := markup_doc(c.model, c.attributes, &readers)
		defer core.destroy(&doc)
		from_doc, from_form: typed.Sink
		defer typed.sink_destroy(&from_doc)
		defer typed.sink_destroy(&from_form)
		schema.check_node(&bound, &doc, core.ROOT, &from_doc)
		schema.check(&ch.bound, transmute([]u8)c.form, &from_form)
		got, want := rendered(doc.src, &from_doc), rendered(transmute([]u8)c.form, &from_form)
		testing.expectf(t, got == want && len(from_form.entries) == c.errors, "%s on %s:\n%s\nagainst %s:\n%s", c.schema, c.model, got, c.form, want)
		testing.expectf(t, (schema.check_node(&bound, &doc, core.ROOT) == nil) == (c.errors == 0), "%s on %s: the first failure", c.schema, c.model)
	}
}

// An edit and a write of a document with attributes keep them: no attribute is cut as a comment with no slot, and a
// JSON write drops them. The stand-in's attributes stand past the JSON text, so its edit accepts any output.
@(test)
markup_attributes_survive_an_edit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	readers := json.as(.Json).readers^
	readers.attribute = markup_attribute
	services := readers.services^
	edit := services.edit^
	edit.validate = proc "contextless" (_: []u8, _: core.As) -> Maybe(core.Fault) { return nil }
	services.edit, readers.services = &edit, &services
	doc := markup_doc(`{"price": "5", "n": 1}`, {{2, `currency="EUR"`}}, &readers)
	defer core.destroy(&doc)
	it := core.facts_of(&doc, 2, .Attribute)
	body, _ := core.fact_next(&it)
	testing.expect_value(t, body, "EUR")
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect(t, write.set(&list, 4, typed.Raw("2")) == nil)
	edited, _, err := compose.commit(&list)
	defer delete(edited)
	testing.expectf(t, err == nil, "%v", err)
	testing.expect_value(t, string(edited), `{"price": "5", "n": 2} currency="EUR"`)
	written, _, werr := json.write(&doc, .Json)
	defer delete(written)
	testing.expect(t, werr == nil)
	testing.expect_value(t, string(written), `{"price":"5","n":1}`)
}

// A held value is judged in step with the read at any depth the walk takes, an arm that nests without end is a schema
// error, and a run's own limit stops the check rather than reading as the arm's failure.
@(test)
schema_check_holds_deep_values :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	nested :: proc(depth: int, inner: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< depth {
			strings.write_byte(&b, '[')
		}
		strings.write_string(&b, inner)
		for _ in 0 ..< depth {
			strings.write_byte(&b, ']')
		}
		return strings.to_string(b)
	}
	arrays :: `{"allOf": [{"$ref": "#/$defs/i"}], "$defs": {"i": {"type": "array", "items": {"$ref": "#/$defs/i"}}}}`
	recursive :: `{"allOf": [{}], "items": {"$ref": "#"}}`
	any_tree :: `{"$defs": {"s": {"anyOf": [{"type": "integer"}, {"type": "array", "items": {"$ref": "#/$defs/s"}}]}}, "not": {"$ref": "#/$defs/s"}}`
	// The members reach an object eight and more deep under a `patternProperties` or a `oneOf` arm.
	gateway :: `{"properties": {"e": {"items": {"$ref": "#/$defs/end"}}}, "$defs": {"end": {"properties": {"b": {"items": {"properties": {"x": {"properties": {"m": {"$ref": "#/$defs/m"}}}}}}}, "patternProperties": {"^@": {}}}, "m": {"properties": {"g": {"properties": {"l": {"items": {"$ref": "#/$defs/m"}}}}}}}}`
	pages :: `{"properties": {"app": {"properties": {"pages": {"oneOf": [{"items": {"$ref": "#/$defs/p"}}]}}}}, "$defs": {"p": {"properties": {"pages": {"items": {"$ref": "#/$defs/p"}}}}}}`
	// Each level's `unevaluatedProperties` reads the in-place `allOf` once, whatever the depth below it.
	children :: `{"$defs": {"n": {"allOf": [{"$ref": "#/$defs/t"}], "unevaluatedProperties": false}, "t": {"type": "object", "properties": {"data": true, "children": {"type": "array", "items": {"$ref": "#/$defs/n"}}}}}, "$ref": "#/$defs/n"}`
	tree :: proc(depth: int, leaf: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< depth {
			strings.write_string(&b, `{"children": [`)
		}
		strings.write_string(&b, leaf)
		for _ in 0 ..< depth {
			strings.write_string(&b, "]}")
		}
		return strings.to_string(b)
	}
	cases := [?]struct {
		schema, text: string,
		valid:        bool,
		keyword:      string,
	} {
		{arrays, nested(8, ""), true, ""},
		{arrays, nested(64, ""), true, ""},
		{arrays, nested(1000, ""), true, ""},
		{recursive, nested(8, ""), true, ""},
		{recursive, nested(64, ""), true, ""},
		{recursive, nested(1000, ""), true, ""},
		{any_tree, nested(256, "1"), false, "not"},
		{any_tree, nested(600, "1"), false, "not"},
		{any_tree, nested(600, `"a"`), true, ""},
		{gateway, `{"e": [{"b": [{"x": {"m": {"g": {"l": [{"r": {"q": {"h": {}}}}]}}}}]}]}`, true, ""},
		{pages, `{"app": {"pages": [{"pages": [{"pages": [{"pages": [{}]}]}]}]}}`, true, ""},
		{`{"allOf": [{"minimum": 3}], "properties": {"a": {"$ref": "#/allOf/0", "type": "integer"}}}`, `1`, false, "minimum"},
		{`{"enum": [[1]], "const": [2]}`, `[1]`, false, "enum"},
		{`{"enum": [[1]], "const": [2]}`, `[2]`, false, "enum"},
		{`{"uniqueItems": true}`, `[{"a": 1, "b": [2]}, {"b": [2.0], "a": 1}]`, false, "uniqueItems"},
		{`{"uniqueItems": true}`, `[{"a": 1}, {"a": 2}, [1], 1, "1", true]`, true, ""},
		{children, tree(8, `{"data": 1}`), true, ""},
		{children, tree(64, `{"data": 1}`), true, ""},
		{children, tree(64, `{"data": 1, "x": 2}`), false, "unevaluatedProperties"},
	}
	for c in cases {
		ch, err := checked_make(c.schema)
		testing.expect(t, err == nil, c.schema)
		if err == nil {
			doc, _ := core.build(transmute([]u8)c.text, json.as(.Json))
			for from_node in ([?]bool{false, true}) {
				sink: typed.Sink
				first := schema.check_node(&ch.bound, &doc, core.ROOT, &sink) if from_node else schema.check(&ch.bound, transmute([]u8)c.text, &sink)
				testing.expectf(t, (first == nil) == c.valid && (len(sink.entries) == 0) == c.valid, "%s: %v %v", c.schema, first, len(sink.entries))
				if !c.valid && len(sink.entries) > 0 {
					words := sink.entries[0].keyword_path
					testing.expect_value(t, words[len(words) - 1], core.Step(core.Name(c.keyword)))
				}
				typed.sink_destroy(&sink)
			}
			core.destroy(&doc)
		}
		checked_destroy(ch)
	}
	// The `$ref` path of the case above is the arm's own, not the first site that reached the node.
	ch, _ := checked_make(cases[11].schema)
	sink: typed.Sink
	schema.check(&ch.bound, transmute([]u8)string(`1`), &sink)
	testing.expect_value(t, len(sink.entries[0].keyword_path), 3)
	testing.expect_value(t, sink.entries[0].keyword_path[0], core.Step(core.Name("allOf")))
	typed.sink_destroy(&sink)
	checked_destroy(ch)
	// Many distinct elements are told apart by their hashes.
	many := strings.builder_make(context.temp_allocator)
	strings.write_byte(&many, '[')
	for i in 0 ..< 5000 {
		if i > 0 {
			strings.write_byte(&many, ',')
		}
		strings.write_int(&many, i)
	}
	strings.write_byte(&many, ']')
	ch, _ = checked_make(`{"uniqueItems": true}`)
	testing.expect(t, schema.valid(&ch.bound, transmute([]u8)strings.to_string(many)))
	checked_destroy(ch)
	// An applicator that reaches its own node with no member or element between is refused when it compiles.
	doc, _ := core.build(transmute([]u8)string(`{"$defs": {"a": {"allOf": [{"$ref": "#/$defs/a"}]}}, "$ref": "#/$defs/a"}`), json.as(.Json))
	defer core.destroy(&doc)
	c, cerr := schema.compile(&doc, core.ROOT, {resolver = {as = json.as(.Json)}})
	testing.expect(t, cerr != nil)
	if cerr == nil {
		schema.destroy(&c)
	}
	// So is one that reaches it through a `$dynamicRef`.
	for text in ([?]string{`{"$dynamicAnchor": "a", "allOf": [{"$dynamicRef": "#a"}]}`, `{"$dynamicAnchor": "a", "if": true, "else": {"$dynamicRef": "#a"}}`}) {
		dyn, _ := core.build(transmute([]u8)text, json.as(.Json))
		dc, derr := schema.compile(&dyn, core.ROOT, {resolver = {as = json.as(.Json)}})
		testing.expect(t, derr != nil, text)
		if derr == nil {
			schema.destroy(&dc)
		}
		core.destroy(&dyn)
	}
}

// A fault in the text under a held value names the place in the text, as it does with no arm.
@(test)
schema_check_faults_inside_held_values :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ch, err := checked_make(`{"items": {"type": "integer"}, "allOf": [{}]}`)
	testing.expect(t, err == nil)
	defer checked_destroy(ch)
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	first := schema.check(&ch.bound, transmute([]u8)string(`[1, 01]`), &sink)
	testing.expect(t, first != nil)
	testing.expect_value(t, len(sink.entries), 1)
	if len(sink.entries) == 1 {
		testing.expect_value(t, len(sink.entries[0].path), 1)
		if len(sink.entries[0].path) == 1 {
			testing.expect_value(t, sink.entries[0].path[0], core.Step(core.Index(1)))
		}
	}
}

// The annotations beside the rules are read, kept as written and spelled again, and judge nothing.
@(test)
schema_keeps_annotations :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	text := `{"type": "string", "title": "T", "description": "D", "default": "x", "examples": ["a", "b"], "deprecated": true, "contentEncoding": "base64", "contentMediaType": "text/plain"}`
	d, _, doc, err := read_text(text)
	defer core.destroy(&doc)
	testing.expect(t, err == nil)
	n := d.nodes[d.root]
	testing.expect_value(t, n.title, "T")
	testing.expect_value(t, n.content_encoding, "base64")
	testing.expect_value(t, n.content_media_type, "text/plain")
	testing.expect(t, n.deprecated && n.default_of != nil && len(n.examples) == 2)
	back_doc: core.Document
	back, written, refused := written_back(t, &d, &back_doc)
	defer core.destroy(&back_doc)
	testing.expect_value(t, refused, "")
	for part in ([?]string{`"title":"T"`, `"default":"x"`, `"examples":["a","b"]`, `"deprecated":true`, `"contentEncoding":"base64"`, `"contentMediaType":"text/plain"`}) {
		testing.expectf(t, strings.contains(string(written), part), "%s in %s", part, written)
	}
	m := back.description.nodes[back.description.root]
	testing.expect(t, m.title == "T" && m.deprecated && len(m.examples) == 2 && m.default_of != nil)
	bad, _, bdoc, berr := read_text(`{"title": 1}`)
	defer core.destroy(&bdoc)
	_ = bad
	testing.expect(t, berr != nil)
}
