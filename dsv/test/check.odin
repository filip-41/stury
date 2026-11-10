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

// Whether `text` passes `schema_text` read by `handle`, judged as the text and as the document built from it.
@(private = "file")
verdicts :: proc(schema_text, text: string, handle: core.As) -> (by_text, by_doc: bool) {
	schema_doc, _ := core.build(transmute([]u8)schema_text, json.as(.Json), allocator = context.temp_allocator)
	c, _ := schema.compile(&schema_doc, core.ROOT, {resolver = {as = json.as(.Json)}}, context.temp_allocator)
	b, berr := schema.bind(&c, handle)
	defer schema.unbind(&b)
	if berr != nil {
		return false, false
	}
	built, _ := core.build(transmute([]u8)text, handle, allocator = context.temp_allocator)
	return schema.check(&b, transmute([]u8)text, nil) == nil, schema.check_node(&b, &built, core.ROOT, nil) == nil
}

// Whether the four ways to judge `csv` agree on `valid`: as CSV and as TSV, by text and by document.
@(private = "file")
expect_verdict :: proc(t: ^testing.T, schema_text, csv: string, valid: bool, loc := #caller_location) {
	tabs, _ := strings.replace_all(csv, ",", "\t", context.temp_allocator)
	for handle, i in ([2]core.As{dsv.as(.Csv), dsv.as(.Tsv)}) {
		by_text, by_doc := verdicts(schema_text, csv if i == 0 else tabs, handle)
		testing.expectf(t, by_text == valid && by_doc == valid, "%s over %q: text %v, document %v, want %v", schema_text, csv, by_text, by_doc, valid, loc = loc)
	}
}

// Every applicator judges a row's cells in step, over a text and over a document, in CSV and in TSV.
@(test)
check_applicators :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		items, csv: string,
		valid:      bool,
	} {
		{`{"allOf": [{"required": ["a"]}, {"properties": {"a": {"type": "integer"}}}]}`, "a\n1\n", true},
		{`{"allOf": [{"required": ["a"]}, {"properties": {"a": {"type": "integer"}}}]}`, "a\nx\n", false},
		{`{"allOf": [{"required": ["a"]}, {"properties": {"a": {"type": "integer"}}}]}`, "b\n1\n", false},
		{`{"properties": {"a": {"allOf": [{"minimum": 3}, {"maximum": 9}]}}}`, "a\n+5\n", true},
		{`{"properties": {"a": {"allOf": [{"minimum": 3}, {"maximum": 9}]}}}`, "a\n10\n", false},
		{`{"anyOf": [{"required": ["a"]}, {"required": ["b"]}]}`, "a,b\n,2\n", true},
		{`{"anyOf": [{"required": ["a"]}, {"required": ["b"]}]}`, "c\n1\n", false},
		{`{"properties": {"a": {"anyOf": [{"type": "integer"}, {"type": "boolean"}]}}}`, "a\ntrue\n", true},
		{`{"properties": {"a": {"anyOf": [{"type": "integer"}, {"type": "boolean"}]}}}`, "a\nx\n", false},
		{`{"oneOf": [{"required": ["a"]}, {"required": ["b"]}]}`, "a,b\n1,\n", true},
		{`{"oneOf": [{"required": ["a"]}, {"required": ["b"]}]}`, "a,b\n1,2\n", false},
		{`{"properties": {"a": {"oneOf": [{"type": "integer"}, {"minimum": 3}]}}}`, "a\n5\n", false},
		{`{"properties": {"a": {"oneOf": [{"type": "integer"}, {"minimum": 3}]}}}`, "a\n3.5\n", true},
		{`{"not": {"required": ["b"]}}`, "a\n1\n", true},
		{`{"not": {"required": ["b"]}}`, "a,b\n1,2\n", false},
		{`{"properties": {"a": {"not": {"type": "boolean"}}}}`, "a\ntrue\n", false},
		{`{"if": {"required": ["a"]}, "then": {"required": ["b"]}, "else": {"required": ["c"]}}`, "a,b\n1,2\n", true},
		{`{"if": {"required": ["a"]}, "then": {"required": ["b"]}, "else": {"required": ["c"]}}`, "a,b\n1,\n", false},
		{`{"if": {"required": ["a"]}, "then": {"required": ["b"]}, "else": {"required": ["c"]}}`, "a,c\n,3\n", true},
		{`{"if": {"required": ["a"]}, "then": {"required": ["b"]}, "else": {"required": ["c"]}}`, "a\n,\n", false},
		{`{"properties": {"a": {"$ref": "#/$defs/n", "minimum": 3}}, "$defs": {"n": {"type": "integer"}}}`, "a\n+5\n", true},
		{`{"properties": {"a": {"$ref": "#/$defs/n", "minimum": 3}}, "$defs": {"n": {"type": "integer"}}}`, "a\n1\n", false},
		{`{"properties": {"a": {"$ref": "#/$defs/n", "minimum": 3}}, "$defs": {"n": {"type": "integer"}}}`, "a\nx\n", false},
		{`{"enum": [{"a": 1}, {"a": 2}]}`, "a\n+1\n", true},
		{`{"enum": [{"a": 1}, {"a": 2}]}`, "a\n3\n", false},
		{`{"properties": {"a": {"const": 1}}, "unevaluatedProperties": false}`, "a\n1\n", true},
		{`{"properties": {"a": {"const": 1}}, "unevaluatedProperties": false}`, "a,b\n1,2\n", false},
	}
	for c in cases {
		schema_text := strings.concatenate({`{"type": "array", "items": `, c.items, `}`}, context.temp_allocator)
		if strings.contains(c.items, "$defs") {
			schema_text = strings.concatenate({`{"type": "array", "$defs": {"n": {"type": "integer"}}, "items": {"properties": {"a": {"$ref": "#/$defs/n", "minimum": 3}}}}`}, context.temp_allocator)
		}
		expect_verdict(t, schema_text, c.csv, c.valid)
	}
	// An applicator on the whole table sees its records.
	expect_verdict(t, `{"allOf": [{"type": "array", "minItems": 2}, {"type": "array", "items": {"required": ["a"]}}]}`, "a\n1\n2\n", true)
	expect_verdict(t, `{"allOf": [{"type": "array", "minItems": 2}]}`, "a\n1\n", false)
	expect_verdict(t, `{"const": [{"a": 1}, {"a": 2}]}`, "a\n1\n+2\n", true)
	expect_verdict(t, `{"const": [{"a": 1}, {"a": 2}]}`, "a\n1\n3\n", false)
}

// `patternProperties` judges the columns whose name it matches, and `additionalProperties` the others.
@(test)
check_pattern_properties :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	open := `{"type": "array", "items": {"patternProperties": {"^x": {"type": "integer"}}}}`
	closed := `{"type": "array", "items": {"patternProperties": {"^x": {"type": "integer"}}, "additionalProperties": false}}`
	typed_rest := `{"type": "array", "items": {"properties": {"y": {"type": "boolean"}}, "patternProperties": {"^x": {"type": "integer"}}, "additionalProperties": {"type": "string", "maxLength": 1}}}`
	expect_verdict(t, open, "x1,y\n5,z\n", true)
	expect_verdict(t, open, "x1,x2\n5,q\n", false)
	expect_verdict(t, closed, "x1,x2\n5,6\n", true)
	expect_verdict(t, closed, "x1,y\n5,z\n", false)
	expect_verdict(t, closed, "x1,x2\n5,q\n", false)
	expect_verdict(t, typed_rest, "x1,y,z\n5,true,k\n", true)
	expect_verdict(t, typed_rest, "x1,y,z\n5,true,kk\n", false)
	expect_verdict(t, typed_rest, "x1,y,z\n5,maybe,k\n", false)
}

// A scalar `const` and the same value in a container agree on a cell: the operand's kind decides how the cell reads.
@(test)
check_scalar_and_wrapped_const_agree :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		cell:  string,
		valid: bool,
	}{{"5", true}, {"+5", true}, {"5.0", true}, {"007", false}, {"x", false}, {"6", false}}
	for c in cases {
		csv := strings.concatenate({"a\n", c.cell, "\n"}, context.temp_allocator)
		expect_verdict(t, `{"type": "array", "items": {"properties": {"a": {"const": 5}}}}`, csv, c.valid)
		expect_verdict(t, `{"type": "array", "items": {"const": {"a": 5}}}`, csv, c.valid)
		expect_verdict(t, `{"type": "array", "items": {"enum": [{"a": 5}, {"a": 6.5}]}}`, csv, c.valid)
		expect_verdict(t, `{"const": [{"a": 5}]}`, csv, c.valid)
	}
	for c in ([?]struct {
		cell:  string,
		valid: bool,
	}{{"true", true}, {"false", false}, {"x", false}}) {
		csv := strings.concatenate({"a\n", c.cell, "\n"}, context.temp_allocator)
		expect_verdict(t, `{"type": "array", "items": {"properties": {"a": {"const": true}}}}`, csv, c.valid)
		expect_verdict(t, `{"type": "array", "items": {"const": {"a": true}}}`, csv, c.valid)
	}
	// A quoted cell has no TSV spelling, and reads as the number its operand's kind asks for.
	for schema_text in ([?]string{`{"type": "array", "items": {"properties": {"a": {"const": 5}}}}`, `{"type": "array", "items": {"const": {"a": 5}}}`}) {
		by_text, by_doc := verdicts(schema_text, "a\n\"5\"\n", dsv.as(.Csv))
		testing.expectf(t, by_text && by_doc, "%s: text %v document %v", schema_text, by_text, by_doc)
	}
	// A string operand keeps the cell a string, a null one reads an unquoted `null`.
	expect_verdict(t, `{"type": "array", "items": {"const": {"a": "5"}}}`, "a\n5\n", true)
	expect_verdict(t, `{"type": "array", "items": {"const": {"a": "5"}}}`, "a\n+5\n", false)
	expect_verdict(t, `{"type": "array", "items": {"const": {"a": null}}}`, "a\nnull\n", true)
	expect_verdict(t, `{"type": "array", "items": {"const": {"a": null}}}`, "a\n\"null\"\n", false)
}

// A document a path left partial is judged by the records it kept, as the text of those records is.
@(test)
check_partial_document :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	judge :: proc(schema_text, text, path: string, opts := dsv.Options{}) -> bool {
		schema_doc, _ := core.build(transmute([]u8)schema_text, json.as(.Json), allocator = context.temp_allocator)
		c, _ := schema.compile(&schema_doc, core.ROOT, {resolver = {as = json.as(.Json)}}, context.temp_allocator)
		b, berr := schema.bind(&c, dsv.as(.Csv, opts))
		defer schema.unbind(&b)
		parsed, _ := core.parse_path(path)
		defer core.path_destroy(&parsed)
		doc, _ := dsv.scan(transmute([]u8)text, .Csv, parsed, opts = opts, allocator = context.temp_allocator)
		return berr == nil && schema.check_node(&b, &doc, core.ROOT, nil) == nil
	}
	table := "a,b\n1,2\n5,\n"
	// A cell kept by name is a record of that one column.
	each_a := `{"type": "array", "items": {"properties": {"a": {"const": 5}}, "required": ["a"]}}`
	testing.expect(t, judge(each_a, table, ".[1].a"))
	testing.expect(t, !judge(each_a, table, ".[0].a"))
	// A record kept whole keeps its empty cell absent.
	any_of := `{"type": "array", "items": {"anyOf": [{"required": ["a"]}, {"required": ["b"]}], "oneOf": [{"required": ["b"]}, {"not": {"required": ["b"]}}]}}`
	testing.expect(t, judge(any_of, table, ".[1]"))
	only_b := `{"type": "array", "items": {"required": ["b"]}}`
	testing.expect(t, !judge(only_b, table, ".[1]"))
	testing.expect(t, judge(only_b, table, ".[0]"))
	testing.expect(t, !judge(only_b, table, ".[]"))
	// A record kept by position reads the cells before it as empty ones.
	rows := `{"type": "array", "items": {"type": "array", "prefixItems": [{"type": "null"}, {"const": "bob"}]}}`
	testing.expect(t, judge(rows, "1,ann\n2,bob\n", ".[1][1]", {no_header = true}))
	testing.expect(t, !judge(rows, "1,ann\n2,bob\n", ".[0][1]", {no_header = true}))
}

// `core.equal` with `read_plain` and `core.hash` with `like` read a cell as the kind of the value it is set against, so equal
// values share a hash. `core.equal` alone leaves a cell a string.
@(test)
check_equal_and_hash_retype_cells :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	operand_doc, _ := core.build(transmute([]u8)string(`{"a": 5, "b": true, "c": null, "d": "x"}`), json.as(.Json), allocator = context.temp_allocator)
	operand := core.Node_Ref{&operand_doc, core.ROOT}
	cases := [?]struct {
		cells: string,
		equal: bool,
	}{{"a,b,c,d\n+5,true,null,x\n", true}, {"a,b,c,d\n5.0,true,null,x\n", true}, {"a,b,c,d\n007,true,null,x\n", false}, {"a,b,c,d\n5,TRUE,null,x\n", false}, {"a,b,c,d\n5,true,nul,x\n", false}, {"a,b,c,d\n5,true,\"null\",x\n", false}, {"a,b,c,d\n5,true,null,y\n", false}}
	for c in cases {
		doc, _ := core.build(transmute([]u8)c.cells, dsv.as(.Csv), allocator = context.temp_allocator)
		it := core.children(&doc, core.ROOT)
		record, _ := core.child_next(&it)
		cell := core.Node_Ref{&doc, record}
		testing.expectf(t, core.equal(cell, operand, read_plain = true) == c.equal, "%q", c.cells)
		testing.expectf(t, core.equal(operand, cell, read_plain = true) == c.equal, "%q", c.cells)
		// Without the switch a cell is the string it is, so it is no number, boolean or null.
		testing.expectf(t, !core.equal(cell, operand), "%q", c.cells)
		if c.equal {
			testing.expectf(t, core.hash(cell, like = operand) == core.hash(operand), "%q", c.cells)
		}
	}
}
