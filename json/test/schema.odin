package json_tests

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import core "../../core"
import rules "../../core/rules"
import schema "../../core/schema"
import json ".."

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

	// A reference is not judged by a plan yet, so a bind refuses it by name.
	_, bind_err := schema.bind(&c, json.as(.Json))
	testing.expect_value(t, bind_err.(core.Typed_Failure).want.text, "$ref")

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
