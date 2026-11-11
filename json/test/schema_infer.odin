package json_tests

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import host "../../host"
import rules "../../core/rules"
import write "../../core/write"
import schema "../../core/schema"
import json ".."

// Inference and sampling: every input passes the description inferred from it, a description round trips through JSON
// Schema, and every sample passes the check that the description makes.

// The description inferred from the JSON `texts`, taken as the documents of one set.
@(private = "file")
inferred_from :: proc(t: ^testing.T, inf: ^schema.Inferred, texts: []string, ranges := false) -> (d: rules.Description) {
	inf.ranges = ranges
	for text in texts {
		doc, err := core.build(transmute([]u8)text, json.as(.Json))
		testing.expectf(t, err == nil, "%s: %v", text, err)
		testing.expect(t, schema.infer(inf, core.Node_Ref{&doc, core.ROOT}) == .None)
		core.destroy(&doc)
	}
	derr: runtime.Allocator_Error
	d, derr = schema.inferred(inf)
	testing.expect(t, derr == .None)
	return
}

@(private = "file")
passes :: proc(t: ^testing.T, d: ^rules.Description, text: string) -> bool {
	c, _ := schema.compile_description(d)
	defer schema.destroy(c)
	b, err := schema.bind(c, json.checks(.Json))
	defer schema.unbind(&b)
	testing.expectf(t, err == nil, "%v", err)
	return schema.valid(&b, transmute([]u8)text)
}

@(test)
infer_inputs_pass_their_description :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sets := [?][]string {
		{`1`, `2.5`, `-3`},
		{`null`, `true`, `"x"`, `[]`, `{}`},
		{`{"a": 1, "b": "x"}`, `{"a": 2}`, `{"a": 3, "b": null, "c": [1, 2]}`},
		{`[[1, 2], [3], []]`, `[["a"]]`},
		{`{"a": {"b": {"c": [{"d": 1}, {"d": 2, "e": true}]}}}`},
		{`{"a\u0000b": 1, "a\nb": 2, "é": 3}`, `{"é": "x"}`},
		{`{"1": "a", "22": "b", "333": "c"}`, `{"4": "d"}`},
		{`{"123e4567-e89b-12d3-a456-426614174000": 1}`, `{"123e4567-e89b-12d3-a456-426614174001": 2}`},
	}
	for set in sets {
		for ranges in ([2]bool{false, true}) {
			inf: schema.Inferred
			d := inferred_from(t, &inf, set, ranges)
			defer schema.inferred_destroy(&inf)
			defer rules.description_destroy(&d)
			for text in set {
				testing.expectf(t, passes(t, &d, text), "ranges %v: %s", ranges, text)
			}
		}
	}
}

// Past 64 names, or with names that are all integers or all UUIDs, an object is a map of one value description.
@(test)
infer_maps :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	for i in 0 ..< 70 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, `"k`)
		strings.write_int(&b, i)
		strings.write_string(&b, `":`)
		strings.write_int(&b, i)
	}
	strings.write_byte(&b, '}')
	cases := [?]string{strings.to_string(b), `{"1": 1, "2": 2}`, `{"123e4567-e89b-12d3-a456-426614174000": 1}`}
	for text in cases {
		inf: schema.Inferred
		d := inferred_from(t, &inf, {text})
		defer schema.inferred_destroy(&inf)
		defer rules.description_destroy(&d)
		n := d.nodes[d.root]
		o := d.objects[n.object]
		testing.expectf(t, len(o.members) == 0 && o.additional != rules.NONE, "%.30s: members %d", text, len(o.members))
		testing.expect(t, passes(t, &d, text))
	}
	inf: schema.Inferred
	d := inferred_from(t, &inf, {`{"a": 1}`, `{"b": 1}`})
	defer schema.inferred_destroy(&inf)
	defer rules.description_destroy(&d)
	o := d.objects[d.nodes[d.root].object]
	testing.expect_value(t, len(o.members), 2)
	testing.expect(t, !o.members[0].required && !o.members[1].required)
}

// What an inference writes reads back as the same description, and the same text.
@(test)
infer_round_trips_through_json_schema :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	sets := [?][]string {
		{`{"a": 1, "b": "xy", "c": [1.5, 2]}`, `{"a": 2, "c": []}`},
		{`[null, true]`},
		{`{"1": {"x": 1}, "2": {"x": 2, "y": [{"z": null}]}}`},
	}
	for set in sets {
		for ranges in ([2]bool{false, true}) {
			inf: schema.Inferred
			d := inferred_from(t, &inf, set, ranges)
			text, werr := schema.write(&d, json.as(.Json))
			testing.expect(t, werr == nil)
			doc, _ := core.build(text, json.as(.Json))
			back, _, rerr := read_text(string(core.span(&doc, core.ROOT)))
			testing.expectf(t, rerr == nil, "%s: %v", text, rerr)
			again, _ := schema.write(&back, json.as(.Json))
			testing.expect_value(t, string(again), string(text))
			for s in set {
				testing.expectf(t, passes(t, &back, s), "%s against %s", s, text)
			}
		}
	}
	// A node's description and its markup node survive.
	text := `{"description": "a note", "type": "object", "properties": {"id": {"type": "string", "xml": {"nodeType": "attribute"}}}}`
	doc, _ := core.build(transmute([]u8)text, json.as(.Json))
	d, _, err := read_text(string(core.span(&doc, core.ROOT)))
	testing.expect(t, err == nil)
	testing.expect_value(t, d.nodes[d.root].description, "a note")
	out, _ := schema.write(&d, json.as(.Json))
	testing.expect(t, strings.contains(string(out), `"description":"a note"`) && strings.contains(string(out), `"nodeType":"attribute"`))
}

// The records of a text, read on the threads of a pool, give the description that one thread gives.
@(test)
infer_records_on_the_pool :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	b := strings.builder_make()
	for i in 0 ..< 400 {
		strings.write_string(&b, `{"id": `)
		strings.write_int(&b, i)
		if i % 3 == 0 {
			strings.write_string(&b, `, "tag": "t"`)
		}
		if i % 7 == 0 {
			strings.write_string(&b, `, "n": {"x": [1, 2.5]}`)
		}
		strings.write_string(&b, "}\n")
	}
	text := transmute([]u8)strings.to_string(b)
	serial: schema.Inferred
	defer schema.inferred_destroy(&serial)
	testing.expect(t, schema.infer_records(&serial, text, json.as(.Json), .Lines) == nil)
	want, _ := schema.inferred(&serial)
	want_text, _ := schema.write(&want, json.as(.Json))
	for width in ([?]int{1, 2, 6}) {
		pool: host.Pool
		host.pool_init(&pool, width)
		defer host.pool_destroy(&pool)
		inf: schema.Inferred
		defer schema.inferred_destroy(&inf)
		testing.expect(t, schema.infer_records(&inf, text, json.as(.Json), .Lines, &pool.runner) == nil)
		got, _ := schema.inferred(&inf)
		got_text, _ := schema.write(&got, json.as(.Json))
		testing.expect_value(t, string(got_text), string(want_text))
	}
	testing.expect(t, strings.contains(string(want_text), `"required":["id"]`))
}

// Records past a bad one are not taken, and the bad one is the result, in any framing and on the pool or not.
@(test)
infer_records_report_a_record_that_does_not_read :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		text:    string,
		framing: core.Framing,
	}{{"{\"a\":1}\n{\"a\":\n{\"b\":2}\n", .Lines}, {"{\"a\":1}\n{\"b\":01}\n{\"c\":2}\n", .Lines}, {"{\"a\":1} {\"b\":", .Entries}}
	for c in cases {
		inf: schema.Inferred
		defer schema.inferred_destroy(&inf)
		testing.expectf(t, schema.infer_records(&inf, transmute([]u8)c.text, json.as(.Json), c.framing) != nil, "%s", c.text)
		d, _ := schema.inferred(&inf)
		for o in d.objects {
			for m in o.members {
				testing.expectf(t, m.name == "a", "%s: member %s", c.text, m.name)
			}
		}
	}
}

// Members are in the order of their first appearance in the text, and so is every position a collapse made, whatever
// the pieces the text was read in.
@(test)
infer_records_order_is_independent_of_pieces :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	b := strings.builder_make()
	first: [dynamic]string
	for i in 0 ..< 12000 {
		name := fmt.tprintf("f%d", (i * 13) % 50)
		if !slice.contains(first[:], name) {
			append(&first, name)
		}
		fmt.sbprintf(&b, "{{\"m\": {{\"n%d\": {{\"%s\": 1}}}}}}\n", (i * 7) % 90, name)
	}
	text := transmute([]u8)strings.to_string(b)
	described :: proc(text: []u8, runner: ^core.Runner) -> string {
		inf := schema.Inferred {
			ranges = true,
		}
		defer schema.inferred_destroy(&inf)
		schema.infer_records(&inf, text, json.as(.Json), .Lines, runner)
		d, _ := schema.inferred(&inf)
		out, _ := schema.write(&d, json.as(.Json))
		return string(out)
	}
	want := described(text, nil)
	at := -1
	for name in first {
		next := strings.index(want, fmt.tprintf("\"%s\"", name))
		testing.expectf(t, next > at, "%s is not in order of appearance", name)
		at = next
	}
	for width in ([?]int{2, 3, 6}) {
		pool: host.Pool
		host.pool_init(&pool, width)
		defer host.pool_destroy(&pool)
		testing.expect_value(t, described(text, &pool.runner), want)
	}
}

// A markup document's attributes and text are members, and the children a name repeats are an array.
@(test)
infer_reads_markup :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	readers := json.as(.Json).readers^
	readers.attribute = markup_attribute
	markup := json.as(.Json)
	markup.readers = &readers
	cases := [?]struct {
		model:      string,
		attributes: []Markup_Attribute,
	} {
		// <price currency="EUR">5</price>
		{`{"price": "5"}`, {{2, `currency="EUR"`}}},
		// <r><item>a</item><x/><item n="1">bb</item></r>
		{`{"r": {"item": "a", "x": null, "item": "bb"}}`, {{8, `n="1"`}}},
		// <a id="x"/>
		{`{"a": ""}`, {{2, `id="x"`}}},
		{`{"p": {"#text": "Hi ", "b": "you", "#text": "!"}}`, nil},
		// <a id="1"><id>2</id></a>, an attribute and a child of one name
		{`{"a": {"id": "2"}}`, {{2, `id="1"`}}},
		// <a id="1"><id>2</id><id>3</id></a>
		{`{"a": {"id": "2", "id": "3"}}`, {{2, `id="1"`}}},
	}
	for c in cases {
		doc := markup_doc(c.model, c.attributes, &readers)
		defer core.destroy(&doc)
		inf: schema.Inferred
		defer schema.inferred_destroy(&inf)
		testing.expect(t, schema.infer(&inf, core.Node_Ref{&doc, core.ROOT}) == .None)
		d, _ := schema.inferred(&inf)
		defer rules.description_destroy(&d)
		cc, _ := schema.compile_description(&d)
		defer schema.destroy(cc)
		bound, err := schema.bind(cc, {layout = markup})
		defer schema.unbind(&bound)
		testing.expect(t, err == nil)
		testing.expectf(t, schema.check_node(&bound, &doc, core.ROOT) == nil, "%s", c.model)
	}
}

// A sample from a schema read from text passes, and an invalid one fails.
@(test)
sample_passes_its_check :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	schemas := [?]string {
		`{"type": "integer", "minimum": 3, "maximum": 9, "multipleOf": 2}`,
		`{"type": "number", "exclusiveMinimum": 0, "exclusiveMaximum": 1}`,
		`{"type": "number", "multipleOf": 0.01, "minimum": 1, "maximum": 2}`,
		`{"type": "string", "minLength": 3, "maxLength": 5}`,
		`{"type": "string", "pattern": "^[a-z]{2}-[0-9]+$"}`,
		`{"type": "string", "pattern": "^(foo|bar)+$", "minLength": 6}`,
		`{"type": "string", "format": "date-time"}`,
		`{"type": "string", "format": "uuid"}`,
		`{"enum": [1, "a", null]}`,
		`{"const": {"a": [1, 2]}}`,
		`{"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 4, "uniqueItems": true}`,
		`{"type": "array", "prefixItems": [{"type": "string"}, {"type": "boolean"}], "items": false, "minItems": 2}`,
		`{"type": "array", "contains": {"const": 7}, "minContains": 2}`,
		`{"type": "object", "required": ["a", "b"], "properties": {"a": {"type": "integer"}, "b": {"type": "string"}, "c": {"type": "null"}}, "additionalProperties": false}`,
		`{"type": "object", "additionalProperties": {"type": "integer"}, "minProperties": 2, "propertyNames": {"pattern": "^k[0-9]$"}}`,
		`{"type": "object", "patternProperties": {"^x-": {"type": "string"}}, "minProperties": 1}`,
		`{"type": "object", "properties": {"a": {}}, "required": ["a"], "dependentRequired": {"a": ["z"]}}`,
		`{"anyOf": [{"type": "integer"}, {"type": "string"}]}`,
		`{"oneOf": [{"type": "integer", "minimum": 10}, {"type": "string"}]}`,
		`{"allOf": [{"type": "integer"}, {"minimum": 5}, {"maximum": 5}]}`,
		`{"type": "integer", "multipleOf": 1e-1000, "minimum": 1, "maximum": 3}`,
		`{"type": "number", "multipleOf": 1e-100000000000000000000, "minimum": 1, "maximum": 3}`,
		`{"if": {"type": "integer"}, "then": {"minimum": 3}, "else": {"type": "string"}}`,
		`{"$defs": {"n": {"type": "object", "properties": {"next": {"$ref": "#/$defs/n"}}}}, "$ref": "#/$defs/n"}`,
		`{"description": "a thing", "type": "object", "properties": {"a": {"description": "the a", "type": "integer"}}, "required": ["a"]}`,
	}
	for text in schemas {
		doc, _ := core.build(transmute([]u8)text, json.as(.Json))
		d, _, rerr := read_text(string(core.span(&doc, core.ROOT)))
		testing.expectf(t, rerr == nil, "%s: %v", text, rerr)
		for spec in ([?]json.Spec{.Json, .Jsonc, .Json5}) {
			for invalid in ([2]bool{false, true}) {
				as := json.as(spec)
				got, err := schema.sample(&d, as, {count = 6, seed = 7, invalid = invalid, comments = true})
				if invalid && err != nil {
					continue
				}
				testing.expectf(t, err == nil, "%s: %v", text, err)
				c, _ := schema.compile_description(&d)
				defer schema.destroy(c)
				b, _ := schema.bind(c, {layout = as})
				defer schema.unbind(&b)
				for s in got {
					testing.expectf(t, schema.valid(&b, s) != invalid, "%s, invalid %v: %s", text, invalid, s)
				}
			}
		}
	}
}

// A description that no value passes gives no sample.
@(test)
sample_gives_no_sample :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for text in ([?]string {
			`{"not": {}}`,
			`false`,
			`{"type": "integer", "minimum": 5, "maximum": 4}`,
			`{"type": "string", "minLength": 4, "maxLength": 2}`,
			`{"type": "array", "minItems": 3, "maxItems": 1}`,
			`{"enum": []}`,
			`{"type": "integer", "type2": 1, "const": "x"}`,
			`{"exclusiveMinimum": 2, "exclusiveMaximum": 2, "type": "number"}`,
		}) {
		doc, _ := core.build(transmute([]u8)text, json.as(.Json))
		d, _, rerr := read_text(string(core.span(&doc, core.ROOT)))
		testing.expectf(t, rerr == nil, "%s: %v", text, rerr)
		_, err := schema.sample(&d, json.as(.Json), {tries = 16})
		f, _ := err.(core.Typed_Error)
		testing.expectf(t, f.kind == .No_Sample, "%s: %v", text, err)
	}
}

// A description that asks for more than the size bound gives no sample, and a conditional with no else can be avoided.
@(test)
sample_is_bounded_and_takes_the_other_branch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	refused := [?]string {
		`{"type": "array", "minItems": 100000000}`,
		`{"type": "string", "minLength": 100000000}`,
		`{"type": "object", "minProperties": 100000000}`,
		`{"$defs": {"n": {"type": "array", "minItems": 50, "items": {"$ref": "#/$defs/n"}}}, "$ref": "#/$defs/n"}`,
	}
	for text in refused {
		doc, _ := core.build(transmute([]u8)text, json.as(.Json))
		d, _, rerr := read_text(string(core.span(&doc, core.ROOT)))
		testing.expectf(t, rerr == nil, "%s: %v", text, rerr)
		_, err := schema.sample(&d, json.as(.Json), {size = 1000})
		f, _ := err.(core.Typed_Error)
		testing.expectf(t, f.kind == .No_Sample, "%s: %v", text, err)
	}
	others := [?]string {
		`{"if": {"const": 1}, "then": false}`,
		`{"type": "array", "items": {"type": "string", "pattern": "^a"}, "minItems": 2, "uniqueItems": true}`,
		`{"type": "string", "pattern": "^a", "minLength": 3}`,
		`{"type": "string", "format": "duration"}`,
	}
	for text in others {
		doc, _ := core.build(transmute([]u8)text, json.as(.Json))
		d, _, _ := read_text(string(core.span(&doc, core.ROOT)))
		got, err := schema.sample(&d, json.as(.Json), {count = 4, format_assert = true})
		testing.expectf(t, err == nil, "%s: %v", text, err)
		c, _ := schema.compile_description(&d)
		defer schema.destroy(c)
		bound, _ := schema.bind(c, json.checks(.Json))
		defer schema.unbind(&bound)
		for s in got {
			testing.expectf(t, schema.valid(&bound, s), "%s: %s", text, s)
		}
	}
}

// No_Sample names the node the search stopped at by its keyword path.
@(test)
sample_names_the_node :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	text := `{"type": "object", "properties": {"a": {"type": "string", "minLength": 3, "maxLength": 2}}, "required": ["a"]}`
	doc, _ := core.build(transmute([]u8)text, json.as(.Json))
	d, _, _ := read_text(string(core.span(&doc, core.ROOT)))
	_, err := schema.sample(&d, json.as(.Json))
	f, _ := err.(core.Typed_Error)
	testing.expectf(t, f.kind == .No_Sample, "%v", err)
	testing.expect_value(t, f.kind, core.Typed_Error_Kind.No_Sample)
	testing.expect_value(t, len(f.steps), 2)
}

// A sample is the same for the same seed, and an inferred description's samples pass it.
@(test)
sample_is_seeded_and_follows_inference :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	inf: schema.Inferred
	d := inferred_from(t, &inf, {`{"a": 1, "b": [1, 2], "c": {"d": "x"}}`, `{"a": 2.5, "c": {"d": "y"}}`})
	one, e1 := schema.sample(&d, json.as(.Json), {seed = 3, count = 4})
	two, e2 := schema.sample(&d, json.as(.Json), {seed = 3, count = 4})
	testing.expect(t, e1 == nil && e2 == nil)
	for _, i in one {
		testing.expect_value(t, string(one[i]), string(two[i]))
		testing.expect(t, passes(t, &d, string(one[i])))
	}
}

// A comment is written where the format has comments and dropped where it has none.
@(test)
tokens_comment :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		spec: json.Spec,
		want: string,
	} {
		{.Json, `{"a":1}`},
		{.Jsonc, `{/* note */"a":1}`},
		{.Json5, `{/* note */"a":1}`},
	}
	for c in cases {
		tk: write.Tokens
		testing.expect(t, write.tokens_init(&tk, json.as(c.spec), allocator = context.temp_allocator) == .None)
		write.open_object(&tk)
		write.comment(&tk, "note")
		write.key(&tk, "a")
		write.value_int(&tk, 1)
		write.close(&tk)
		out, err := write.tokens_finish(&tk)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, string(out), c.want)
	}
}
