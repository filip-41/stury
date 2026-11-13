package json_tests

import "core:testing"
import core "../../core"
import "../../core/typed"
import schema "../../core/schema"
import dsv "../../dsv"
import json ".."

// Conversion through a schema: the output passes it, a member it leaves open survives, a value the output format
// cannot spell is refused with its path, and a cell is the kind its format reads, which no schema changes.

@(private = "file")
Converted :: struct {
	text:  string,
	stage: schema.Stage,
	err:   core.Error,
}

@(private = "file")
converted :: proc(t: ^testing.T, rules_text, src: string, from, to: core.As, sink: ^typed.Sink = nil) -> Converted {
	schema_doc, serr := core.build(transmute([]u8)rules_text, json.as(.Json))
	testing.expectf(t, serr == nil, "%s: %v", rules_text, serr)
	defer core.destroy(&schema_doc)
	c, cerr := schema.compile(core.span(&schema_doc, core.ROOT), json.as(.Json), {})
	testing.expectf(t, cerr == nil, "%s: %v", rules_text, cerr)
	defer schema.destroy(c)
	doc, derr := core.build(transmute([]u8)src, from)
	testing.expectf(t, derr == nil, "%s: %v", src, derr)
	defer core.destroy(&doc)
	return convert_document(t, c, &doc, to, sink)
}

@(private = "file")
convert_document :: proc(t: ^testing.T, c: ^schema.Compiled, doc: ^core.Document, to: core.As, sink: ^typed.Sink = nil) -> Converted {
	cv: schema.Converter
	err := schema.converter_init(&cv, c, doc.as, to, dsv.checks_for(doc.as), dsv.checks_for(to))
	testing.expectf(t, err == nil, "%v", err)
	defer schema.converter_destroy(&cv)
	text, stage, err2 := schema.convert(&cv, doc, sink = sink, allocator = context.temp_allocator)
	return {string(text), stage, err2}
}

@(private = "file")
expect_refused :: proc(t: ^testing.T, got: Converted, stage: schema.Stage, path: ..core.Step) {
	failure, _ := got.err.(core.Typed_Error)
	testing.expectf(t, got.stage == stage && got.err != nil, "stage %v, %v", got.stage, got.err)
	testing.expectf(t, len(failure.steps) == len(path), "path %v, want %v", failure.steps, path)
	for step, i in path {
		testing.expectf(t, i < len(failure.steps) && failure.steps[i] == step, "step %d of %v, want %v", i, failure.steps, path)
	}
}

@(test)
convert_keeps_the_members_a_schema_leaves_open :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s := `{"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}`
	for spec in ([?]json.Spec{.Json, .Jsonc, .Json5}) {
		got := converted(t, s, `{"id": 7, "extra": [1, {"deep": null}], "note": "x"}`, json.as(.Json), json.as(spec))
		testing.expectf(t, got.err == nil, "%v: %v", spec, got.err)
		testing.expect_value(t, got.text, `{"id":7,"extra":[1,{"deep":null}],"note":"x"}`)
	}
}

// The output is written as core.write writes it: comments and the spelling of strings and numbers stay, and the layout
// is the one asked for.
@(test)
convert_writes_as_core_writes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	got := converted(t, `{"type": "object"}`, "// note\n{\"a\": 5.0e0 /* five */, \"b\": \"\\u00e9\"}\n", json.as(.Jsonc), json.as(.Jsonc))
	testing.expectf(t, got.err == nil, "%v", got.err)
	testing.expect_value(t, got.text, "// note\n{\"a\":5.0e0,/* five */\"b\":\"\\u00e9\"}")
}

@(test)
convert_refuses_an_input_that_fails_the_schema :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s := `{"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}`
	got := converted(t, s, `{"id": "7"}`, json.as(.Json), json.as(.Json5))
	testing.expect_value(t, got.stage, schema.Stage.Input)
	_, is_failure := got.err.(core.Typed_Error)
	testing.expect(t, is_failure)
}

@(test)
convert_refuses_what_the_output_cannot_spell_with_its_path :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	got := converted(t, `{"type": "object"}`, `{"a": [1, {"b": Infinity}]}`, json.as(.Json5), json.as(.Json))
	expect_refused(t, got, .Write, core.Name("a"), core.Index(1), core.Name("b"))
	rows := `{"type": "array"}`
	got = converted(t, rows, `[{"a": 1}, {"a": [1]}]`, json.as(.Json), dsv.as(.Csv))
	expect_refused(t, got, .Write, core.Index(1), core.Name("a"))
	got = converted(t, rows, `[1]`, json.as(.Json), dsv.as(.Csv))
	expect_refused(t, got, .Write, core.Index(0))
}

@(test)
convert_to_a_table_joins_the_columns_of_every_row :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s := `{"type": "array", "items": {"type": "object", "properties": {"n": {"type": "integer"}}, "required": ["n"]}}`
	infer := dsv.as(.Csv, {infer = true})
	got := converted(t, s, `[{"n": 1, "a": "x"}, {"n": 2, "b": true}, {"n": 3}]`, json.as(.Json), infer)
	testing.expectf(t, got.err == nil, "%v", got.err)
	testing.expect_value(t, got.text, "n,a,b\n1,x,\n2,,true\n3,,\n")
}

// The output is checked as its format reads it: a null the table writes as an empty cell reads back as a null.
@(test)
convert_checks_the_output_as_its_format_reads_it :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s := `{"type": "array", "items": {"type": "object", "required": ["b"], "properties": {"b": {"type": "null"}}}}`
	got := converted(t, s, `[{"a": 1, "b": null}]`, json.as(.Json), dsv.as(.Csv))
	testing.expectf(t, got.err == nil, "%v", got.err)
}

@(test)
convert_judges_an_inferred_cell_by_its_arms :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s := `{"type": "array", "items": {"type": "object", "properties": {"v": {"oneOf": [{"type": "integer"}, {"type": "string", "pattern": "^[a-z]+$"}]}}, "required": ["v"]}}`
	got := converted(t, s, "v\n5\nx\n", dsv.as(.Csv, {infer = true}), json.as(.Json))
	testing.expectf(t, got.err == nil, "%v", got.err)
	testing.expect_value(t, got.text, `[{"v":5},{"v":"x"}]`)
	got = converted(t, s, `[{"v": "x"}, {"v": 5}]`, json.as(.Json), dsv.as(.Csv, {infer = true}))
	testing.expectf(t, got.err == nil, "%v", got.err)
	testing.expect_value(t, got.text, "v\nx\n5\n")
}

// A cell is judged as the format reads it, and the schema picks no reading: without `infer` every cell is a string, so
// one a schema asks to be an integer fails, and with it a cell that spells a number is one, so one a schema asks to be
// a string fails.
@(test)
convert_reads_a_cell_as_the_format_reads_it :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	integer := `{"type": "array", "items": {"type": "object", "properties": {"v": {"type": "integer"}}}}`
	got := converted(t, integer, "v\n5\n", dsv.as(.Csv), json.as(.Json))
	testing.expectf(t, got.stage == .Input && got.err != nil, "%v %v", got.stage, got.err)
	text := `{"type": "array", "items": {"type": "object", "properties": {"v": {"type": "string"}}}}`
	got = converted(t, text, "v\n5\ntrue\n", dsv.as(.Csv), json.as(.Json))
	testing.expectf(t, got.err == nil, "%v", got.err)
	testing.expect_value(t, got.text, `[{"v":"5"},{"v":"true"}]`)
	got = converted(t, text, "v\n5\n", dsv.as(.Csv, {infer = true}), json.as(.Json))
	testing.expectf(t, got.stage == .Input && got.err != nil, "%v %v", got.stage, got.err)
	either := `{"type": "array", "items": {"type": "object", "properties": {"v": {"type": ["integer", "string"], "minimum": 6}}}}`
	got = converted(t, either, "v\n5\n7\n", dsv.as(.Csv), json.as(.Json))
	testing.expectf(t, got.err == nil, "%v", got.err)
	testing.expect_value(t, got.text, `[{"v":"5"},{"v":"7"}]`)
	got = converted(t, either, "v\n5\n7\n", dsv.as(.Csv, {infer = true}), json.as(.Json))
	testing.expectf(t, got.stage == .Input && got.err != nil, "%v %v", got.stage, got.err)
	// `infer` reads a number by the strict grammar, so a loose spelling stays a string.
	number := `{"type": "array", "items": {"properties": {"v": {"type": "number"}}}}`
	got = converted(t, number, "v\n+5\n", dsv.as(.Csv, {infer = true}), json.as(.Json))
	testing.expectf(t, got.stage == .Input && got.err != nil, "%v %v", got.stage, got.err)
}


// An element's text and an attribute's value that the format gives no kind are written as the check read them.
@(test)
convert_writes_markup_text_as_the_check_reads_it :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	readers := json.as(.Json).readers^
	readers.attribute = proc "contextless" (doc: ^core.Document, f: core.Fact) -> (name, value: core.Token) {
		name, value = markup_attribute(doc, f)
		value.kind = .Plain
		return
	}
	s := `{"type": "object", "properties": {"price": {"type": "object", "properties": {"n": {"type": "integer"}, "id": {"type": "string"}, "#text": {"type": "number"}}}}}`
	schema_doc, _ := core.build(transmute([]u8)s, json.as(.Json))
	defer core.destroy(&schema_doc)
	c, cerr := schema.compile(core.span(&schema_doc, core.ROOT), json.as(.Json), {})
	testing.expect(t, cerr == nil)
	defer schema.destroy(c)
	doc := markup_doc(`{"price": "5"}`, {{2, `n="3"`}, {2, `id="7"`}}, &readers)
	defer core.destroy(&doc)
	doc.as.readers = &readers
	doc.nodes[2].kind = .Plain
	got := convert_document(t, c, &doc, json.as(.Json))
	testing.expectf(t, got.err == nil, "%v", got.err)
	testing.expect_value(t, got.text, `{"price":{"n":3,"id":"7","#text":5}}`)
}

// An empty unquoted cell is a null member, which a `required` member may be.
@(test)
convert_writes_an_empty_cell_as_null :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	got := converted(t, `{"type": "array", "items": {"required": ["a", "b"]}}`, "a,b\n1,\n,2\n", dsv.as(.Csv), json.as(.Json))
	testing.expectf(t, got.err == nil, "%v", got.err)
	testing.expect_value(t, got.text, `[{"a":"1","b":null},{"a":null,"b":"2"}]`)
}

@(test)
convert_refuses_a_table_with_no_member :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	got := converted(t, `{"type": "array"}`, `[{}, {}]`, json.as(.Json), dsv.as(.Csv))
	expect_refused(t, got, .Write, core.Index(0))
	got = converted(t, `{"type": "integer"}`, `5`, json.as(.Json), dsv.as(.Csv))
	expect_refused(t, got, .Write)
}

@(test)
convert_writes_attributes_as_members :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	readers := json.as(.Json).readers^
	readers.attribute = markup_attribute
	s := `{"type": "object", "properties": {"price": {"type": "object", "properties": {"currency": {"enum": ["EUR", "USD"]}, "#text": {"maxLength": 3}}, "required": ["currency"], "additionalProperties": false}}}`
	schema_doc, _ := core.build(transmute([]u8)s, json.as(.Json))
	defer core.destroy(&schema_doc)
	c, cerr := schema.compile(core.span(&schema_doc, core.ROOT), json.as(.Json), {})
	testing.expect(t, cerr == nil)
	defer schema.destroy(c)
	doc := markup_doc(`{"price": "5"}`, {{2, `currency="EUR"`}}, &readers)
	doc.as.readers = &readers
	got := convert_document(t, c, &doc, json.as(.Json))
	testing.expectf(t, got.err == nil, "%v", got.err)
	testing.expect_value(t, got.text, `{"price":{"currency":"EUR","#text":"5"}}`)
	core.destroy(&doc)
	doc = markup_doc(`{"price": "5"}`, {{2, `currency="GBP"`}}, &readers)
	doc.as.readers = &readers
	got = convert_document(t, c, &doc, json.as(.Json))
	testing.expect_value(t, got.stage, schema.Stage.Input)
	core.destroy(&doc)
}

@(private = "file")
markup_converted :: proc(t: ^testing.T, model: string, attributes: []Markup_Attribute) -> Converted {
	readers := json.as(.Json).readers^
	readers.attribute = markup_attribute
	schema_doc, _ := core.build(transmute([]u8)string(`{"type": "object"}`), json.as(.Json))
	defer core.destroy(&schema_doc)
	c, cerr := schema.compile(core.span(&schema_doc, core.ROOT), json.as(.Json), {})
	testing.expect(t, cerr == nil)
	defer schema.destroy(c)
	doc := markup_doc(model, attributes, &readers, .All)
	doc.as.readers = &readers
	defer core.destroy(&doc)
	return convert_document(t, c, &doc, json.as(.Json))
}

// A markup document loses nothing to the JSON model: a name its children repeat is an array, and the runs of text of a
// mixed element keep their order.
@(test)
convert_keeps_repeated_children_and_runs_of_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	got := markup_converted(t, `{"list": {"item": "1", "item": "2", "other": "x", "item": "3"}}`, nil)
	testing.expectf(t, got.err == nil, "%v", got.err)
	testing.expect_value(t, got.text, `{"list":{"item":["1","2","3"],"other":"x"}}`)
	got = markup_converted(t, `{"p": {"#text": "a", "b": "x", "#text": "c"}}`, nil)
	testing.expectf(t, got.err == nil, "%v", got.err)
	testing.expect_value(t, got.text, `{"p":{"#text":["a","c"],"b":"x"}}`)
}

// An attribute and a child of one name, and an array with an attribute, are not written.
@(test)
convert_refuses_what_markup_cannot_hold :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	got := markup_converted(t, `{"a": {"id": "x"}}`, {{2, `id="1"`}})
	expect_refused(t, got, .Write, core.Name("a"), core.Name("id"))
	got = markup_converted(t, `{"a": [1, 2]}`, {{2, `id="1"`}})
	expect_refused(t, got, .Write, core.Name("a"))
}
