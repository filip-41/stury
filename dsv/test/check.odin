package dsv_tests

import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import schema "../../core/schema"
import dsv ".."
import json "../../json"

// The check of a delimited text and document against a schema: each cell reads as the kind its leaf allows, an empty cell
// is an absent member, and one schema judges the same records alike in JSON, JSON5, CSV and TSV.

// The rendered failures of `text` against `schema_text`, each as the message, its path and its keyword path, one a line.
@(private = "file")
failures :: proc(schema_text: string, text: string, handle: core.As, read := typed.Read_Options{}) -> (out: string, err: core.Error) {
	doc, _ := core.build(transmute([]u8)schema_text, json.as(.Json))
	defer core.destroy(&doc)
	c, _ := schema.compile(&doc, core.ROOT, {resolver = {as = json.as(.Json)}})
	defer schema.destroy(&c)
	b, berr := schema.bind(&c, handle)
	defer schema.unbind(&b)
	if berr != nil {
		return "", berr
	}
	src := transmute([]u8)text
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	target: u8
	read := read
	read.sink = &sink
	err = typed.check_text(src, &target, nil, &b.plan, read)
	w := strings.builder_make(context.temp_allocator)
	for e in sink.entries {
		line := strings.builder_make(context.temp_allocator)
		core.render_entry(strings.to_stream(&line), src, e)
		_, _, message := strings.partition(strings.to_string(line), ": ")
		strings.write_string(&w, message)
		strings.write_byte(&w, '\n')
	}
	return strings.to_string(w), err
}

ROWS :: `{"type": "array", "items": {"type": "object", "required": ["id"], "additionalProperties": false, "properties": {
	"id": {"type": "integer", "minimum": 1}, "name": {"type": "string", "maxLength": 3}, "ok": {"type": "boolean"}, "score": {"type": "number", "maximum": 10}}}}`

// One schema judges the same records in JSON, JSON5, CSV and TSV alike: the same failures at the same paths and keywords.
@(test)
check_one_schema_over_every_format :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		json, json5, csv: string,
	} {
		{`[{"id": 1, "name": "abc", "ok": true, "score": 2.5}, {"id": 2, "name": "x", "ok": false, "score": 10}]`, `[{id: 1, name: 'abc', ok: true, score: 2.5}, {id: 2, name: 'x', ok: false, score: 10}]`, "id,name,ok,score\n1,abc,true,2.5\n2,x,false,10\n"},
		{`[{"id": 0, "name": "abcd", "ok": "maybe", "score": 11}, {"id": 3, "ok": true}]`, `[{id: 0, name: 'abcd', ok: 'maybe', score: 11}, {id: 3, ok: true}]`, "id,name,ok,score\n0,abcd,maybe,11\n3,,true,\n"},
		{`[{"name": "abc"}]`, `[{name: 'abc'}]`, "name\nabc\n"},
		{`[{"id": 1, "extra": 5}]`, `[{id: 1, extra: 5}]`, "id,extra\n1,5\n"},
		{`[{"id": 1.5}]`, `[{id: 1.5}]`, "id\n1.5\n"},
		{`[{"id": 1, "name": ""}]`, `[{id: 1, name: ''}]`, "id,name\n1,\"\"\n"},
	}
	for c in cases {
		want, werr := failures(ROWS, c.json, json.as(.Json))
		testing.expect(t, werr == nil || len(want) > 0)
		json5, _ := failures(ROWS, c.json5, json.as(.Json5))
		csv, _ := failures(ROWS, c.csv, dsv.as(.Csv))
		tabs, _ := strings.replace_all(c.csv, ",", "\t", context.temp_allocator)
		tsv, _ := failures(ROWS, tabs, dsv.as(.Tsv))
		testing.expect_value(t, json5, want)
		testing.expect_value(t, csv, want)
		// A quoted cell has no TSV spelling.
		if !strings.contains(c.csv, "\"") {
			testing.expect_value(t, tsv, want)
		}
	}
}

// A leaf reads a cell as the kinds it allows: numbers alone by the loose grammar, booleans alone by their words, and any
// other leaf an unquoted cell by the strict grammar.
@(test)
check_cell_rule :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		property, cell: string,
		valid:          bool,
	} {
		{`{"type": "integer"}`, "+5", true},
		{`{"type": "integer"}`, "007", true},
		{`{"type": "integer"}`, "5.", true},
		{`{"type": "integer"}`, "5.5", false},
		{`{"type": "integer"}`, `"7"`, true},
		{`{"type": "number"}`, ".5", true},
		{`{"type": "number"}`, "x", false},
		{`{"type": "string"}`, "5", true},
		{`{"type": "string", "maxLength": 1}`, "55", false},
		{`{"type": ["integer", "string"]}`, "+5", true},
		{`{"type": ["integer", "string"], "maxLength": 1}`, "+5", false},
		{`{"type": ["integer", "string"], "maxLength": 1}`, "5", true},
		{`{"type": ["integer", "string"], "minimum": 6}`, "5", true},
		{`{"type": ["integer", "null"]}`, "007", true},
		{`{"type": ["integer", "null"]}`, "+5", true},
		{`{"type": ["integer", "null"]}`, "null", true},
		{`{"type": ["integer", "null"]}`, "x", false},
		{`{"type": ["boolean", "null"]}`, `"true"`, true},
		{`{"enum": [null, 7]}`, "007", true},
		{`{"enum": [null, true]}`, `"true"`, true},
		{`{"enum": ["1", 2]}`, "1", true},
		{`{"enum": ["1", 2]}`, "2", true},
		{`{"enum": ["1", 2]}`, "3", false},
		{`{"const": "1"}`, "1", true},
		{`{"type": ["integer", "string"], "minimum": 6, "maxLength": 0}`, "5", false},
		{`{"type": ["integer", "string"], "minimum": 6}`, "+5", true},
		{`{"type": ["integer", "string"], "minimum": 6}`, `"5"`, true},
		{`{"type": "boolean"}`, "true", true},
		{`{"type": "boolean"}`, "TRUE", false},
		{`{"type": "boolean"}`, `"false"`, true},
		{`{"type": ["boolean", "string"], "maxLength": 3}`, "true", true},
		{`{"type": "null"}`, "null", true},
		{`{"type": "string"}`, "null", true},
		{`{"enum": ["1", "2"]}`, "1", true},
		{`{"enum": [1, 2]}`, "1", true},
		{`{"enum": [1, 2]}`, "1.0", true},
		{`{"enum": [1, 2]}`, "3", false},
		{`{"enum": [true, "x"]}`, "true", true},
		{`{"const": 5}`, "+5", true},
		{`{"const": 5}`, "5.0", true},
		{`{"const": "5"}`, "5", true},
		{`{"minimum": 3}`, "2", false},
		{`{"minimum": 3}`, "x", true},
		{`{"minLength": 3}`, "55", true},
	}
	for c in cases {
		schema_text := strings.concatenate({`{"type": "array", "items": {"type": "object", "properties": {"a": `, c.property, `}}}`}, context.temp_allocator)
		text := strings.concatenate({"a\n", c.cell, "\n"}, context.temp_allocator)
		out, err := failures(schema_text, text, dsv.as(.Csv))
		testing.expect(t, err == nil == c.valid && (out == "") == c.valid, strings.concatenate({c.property, " ", c.cell, " ", out}, context.temp_allocator))
	}
}

// An empty unquoted cell is an absent member, and a quoted one a string. Rows, `required` and counts see the difference.
@(test)
check_empty_cells :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		property, text: string,
		valid:          bool,
	} {
		{`{"required": ["a"]}`, "a,b\n,1\n", false},
		{`{"required": ["a"]}`, "a,b\n\"\",1\n", true},
		{`{"minProperties": 2}`, "a,b\n,1\n", false},
		{`{"minProperties": 2}`, "a,b\n\"\",1\n", true},
		{`{"properties": {"a": {"type": "integer"}}}`, "a,b\n,1\n", true},
		{`{"properties": {"a": {"type": "integer"}}}`, "a,b\n\"\",1\n", false},
		{`{"additionalProperties": false}`, "a\n\n", true},
	}
	for c in cases {
		schema_text := strings.concatenate({`{"type": "array", "items": `, c.property, `}`}, context.temp_allocator)
		_, err := failures(schema_text, c.text, dsv.as(.Csv))
		testing.expect_value(t, err == nil, c.valid)
	}
}

// A repeated header column is the read's `Duplicates`: the earlier cell drops under `.Last`, the later under `.First`, and
// a repeat is refused under `.Refuse`.
@(test)
check_repeated_columns :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	schema_text := `{"type": "array", "items": {"properties": {"a": {"type": "integer"}}, "maxProperties": 1}}`
	_, last := failures(schema_text, "a,a\nx,1\n", dsv.as(.Csv), {dups = .Last})
	_, first := failures(schema_text, "a,a\nx,1\n", dsv.as(.Csv), {dups = .First})
	_, refuse := failures(schema_text, "a,a\n1,1\n", dsv.as(.Csv), {dups = .Refuse})
	_, alone := failures(schema_text, "a,a\n", dsv.as(.Csv), {dups = .Refuse})
	_, alone_last := failures(schema_text, "a,a\n", dsv.as(.Csv), {dups = .Last})
	_, all := failures(schema_text, "a,a\n1,1\n", dsv.as(.Csv), {dups = .All})
	testing.expect(t, last == nil)
	testing.expect(t, first != nil)
	testing.expect_value(t, refuse.(core.Fault).kind, core.Fault_Kind.Duplicate_Key)
	testing.expect_value(t, alone.(core.Fault).kind, core.Fault_Kind.Duplicate_Key)
	testing.expect(t, alone_last == nil)
	testing.expectf(t, all.(core.Typed_Failure).kind == .Bad_Option, "%v", all)
}

// A ragged row keeps its cells, a short one lacks the rest and a long one names the extra by position.
@(test)
check_ragged_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	schema_text := `{"type": "array", "items": {"required": ["b"], "properties": {"3": {"type": "string"}}, "additionalProperties": false}}`
	_, strict := failures(schema_text, "a,b\n1\n", dsv.as(.Csv))
	testing.expect(t, strict != nil)
	out, ragged := failures(schema_text, "a,b\n1\n1,2,3\n", dsv.as(.Csv, {tolerate = {.Ragged}}))
	testing.expect(t, ragged != nil)
	testing.expect_value(t, out, "No value is allowed here at .[0].a (.items.additionalProperties)\nRequired member \"b\" is missing at .[0] (.items.required)\nNo value is allowed here at .[1].a (.items.additionalProperties)\nNo value is allowed here at .[1].b (.items.additionalProperties)\n")
}

// A document built from the text is judged as the text is, with the cell kinds `infer` stored put back to text.
@(test)
check_document_agrees_with_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]string{"id,name,ok,score\n1,abc,true,2.5\n2,x,false,10\n", "id,name,ok,score\n0,abcd,maybe,11\n3,,true,\n", "id\n+5\n007\n", "name\nabc\n", "id,extra\n1,5\n"}
	doc, _ := core.build(transmute([]u8)string(ROWS), json.as(.Json))
	defer core.destroy(&doc)
	c, _ := schema.compile(&doc, core.ROOT, {resolver = {as = json.as(.Json)}})
	defer schema.destroy(&c)
	for infer in ([?]bool{false, true}) {
		handle := dsv.as(.Csv, {infer = infer})
		b, berr := schema.bind(&c, handle)
		defer schema.unbind(&b)
		testing.expect(t, berr == nil)
		for text in cases {
			built, _ := core.build(transmute([]u8)text, handle)
			defer core.destroy(&built)
			from_text, from_doc: typed.Sink
			defer typed.sink_destroy(&from_text)
			defer typed.sink_destroy(&from_doc)
			schema.check(&b, transmute([]u8)text, &from_text)
			schema.check_node(&b, &built, core.ROOT, &from_doc)
			testing.expect_value(t, len(from_doc.entries), len(from_text.entries))
			for e, i in from_text.entries {
				if i < len(from_doc.entries) {
					testing.expect_value(t, from_doc.entries[i].kind, e.kind)
					testing.expect_value(t, len(from_doc.entries[i].path), len(e.path))
				}
			}
		}
	}
}
