package json_tests

import "base:runtime"
import "core:fmt"
import enc "core:encoding/json"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:testing"
import core "../../core"
import host "../../host"
import rules "../../core/rules"
import typed "../../core/typed"
import write "../../core/write"
import records "../../core/records"
import schema "../../core/schema"
import json ".."
import model "../../core/model"

// A check on the threads of a pool against the check on one, and the reports of a check's entries.

@(private = "file")
OUTPUT_TESTS :: #directory + "conformance/JSON-Schema-Test-Suite/output-tests/"

@(private = "file")
Bound_Schema :: struct {
	c: ^schema.Compiled,
	b: schema.Bound,
}

// The schema in `text` compiled and bound to JSON, from the context allocator.
@(private = "file")
bind_text :: proc(t: ^testing.T, s: ^Bound_Schema, text: string, draft := schema.Draft.D2020_12) -> bool {
	err: core.Error
	s.c, err = schema.compile(transmute([]u8)text, json.as(.Json), {draft = draft})
	if !testing.expectf(t, err == nil, "%s: %v", text, err) {
		return false
	}
	s.b, err = schema.bind(s.c, json.checks(.Json))
	return testing.expectf(t, err == nil, "%s: %v", text, err)
}

// The basic output of `entries` as JSON text.
@(private = "file")
basic_text :: proc(entries: []core.Error_Entry, uri := "", r := write.Report{}, bases: []rules.Base = nil) -> string {
	tw: write.Tokens
	write.tokens_init(&tw, json.as(.Json), {}, context.temp_allocator)
	schema.write_basic(&tw, entries, uri, r, bases)
	text, _ := write.tokens_finish(&tw)
	return string(text)
}

// Whether `got` passes `spec`, the part of a schema the output tests are written in: `const`, `required`, `properties`,
// `contains` and `items`, where a `false` property must be absent.
@(private = "file")
holds :: proc(spec, got: enc.Value) -> bool {
	if allowed, boolean := spec.(enc.Boolean); boolean {
		return bool(allowed)
	}
	s, is_schema := spec.(enc.Object)
	if !is_schema {
		return true
	}
	if want, has := s["const"]; has {
		switch w in want {
		case enc.String:
			if text, ok := got.(enc.String); !ok || text != w {
				return false
			}
		case enc.Boolean:
			if flag, ok := got.(enc.Boolean); !ok || flag != w {
				return false
			}
		case enc.Null, enc.Integer, enc.Float, enc.Array, enc.Object:
			return false
		}
	}
	if names, has := s["required"]; has {
		o, is_object := got.(enc.Object)
		if !is_object {
			return false
		}
		for n in names.(enc.Array) {
			if string(n.(enc.String)) not_in o {
				return false
			}
		}
	}
	if props, has := s["properties"]; has {
		if o, is_object := got.(enc.Object); is_object {
			for name, sub in props.(enc.Object) {
				if v, present := o[name]; present && !holds(sub, v) {
					return false
				}
			}
		}
	}
	items, listed := got.(enc.Array)
	if sub, has := s["contains"]; has {
		found := false
		for x in items {
			found ||= holds(sub, x)
		}
		if !listed || !found {
			return false
		}
	}
	if sub, has := s["items"]; has {
		for x in items {
			if !holds(sub, x) {
				return false
			}
		}
	}
	return true
}

// The suite's output tests: the basic output of a failing instance holds the keyword and instance locations the suite
// names, with `~` and `/` escaped, and no annotations. A schema the check refuses at bind is counted, and the
// annotation tests are left out, since a check reports failures only.
@(test)
schema_output_tests :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	ran, refused := 0, 0
	for entry in ([]struct {
		dir:   string,
		draft: schema.Draft,
	}{{"draft2020-12", .D2020_12}, {"draft2019-09", .D2019_09}}) {
		for name in ([]string{"escape", "general", "type"}) {
			path := fmt.tprintf("%s%s/content/%s.json", OUTPUT_TESTS, entry.dir, name)
			bytes, rerr := os.read_entire_file_from_path(path, context.allocator)
			if !testing.expectf(t, rerr == nil, "%s: %v", path, rerr) {
				continue
			}
			doc, _ := core.build(bytes, json.as(.Json))
			parsed, perr := enc.parse(bytes, .JSON, true)
			testing.expectf(t, perr == .None, "%s: %v", path, perr)
			groups := core.children(&doc, core.ROOT)
			g := 0
			for group in core.child_next(&groups) {
				node, _ := core.member(&doc, group, "schema")
				c, cerr := schema.compile(core.span(&doc, node), json.as(.Json), {draft = entry.draft})
				b: schema.Bound
				berr := cerr
				if cerr == nil {
					b, berr = schema.bind(c, json.checks(.Json))
				}
				if berr != nil {
					refused += 1
					g += 1
					continue
				}
				tests, _ := core.member(&doc, group, "tests")
				all := core.children(&doc, tests)
				j := 0
				for test in core.child_next(&all) {
					data, _ := core.member(&doc, test, "data")
					sink: typed.Sink
					schema.check(&b, core.span(&doc, data), &sink)
					text := basic_text(sink.entries[:], c.description.uri, {truncated = sink.truncated})
					got, _ := enc.parse(transmute([]u8)text, .JSON, true)
					want := parsed.(enc.Array)[g].(enc.Object)["tests"].(enc.Array)[j].(enc.Object)["output"].(enc.Object)["basic"]
					testing.expectf(t, holds(want, got), "%s %s: %s", entry.dir, name, text)
					typed.sink_destroy(&sink)
					ran += 1
					j += 1
				}
				schema.unbind(&b)
				schema.destroy(c)
				g += 1
			}
		}
	}
	log.infof("output tests: %d ran, %d schemas refused at bind", ran, refused)
	testing.expect(t, ran >= 2)
}

// The locations of an entry through a `$ref`, a name with `~` and `/`, an index, and a record.
@(test)
schema_report_locations :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	s: Bound_Schema
	if !bind_text(t, &s, `{"$id": "https://example.com/s", "properties": {"a~/b": {"items": {"type": "integer"}}, "c": {"$ref": "#/$defs/n"}}, "$defs": {"n": {"maximum": 3}}}`) {
		return
	}
	sink: typed.Sink
	schema.check(&s.b, transmute([]u8)string(`{"a~/b": [1, "x"], "c": 9}`), &sink)
	want := `{"valid":false,"errors":[{"valid":false,"keywordLocation":"/properties/a~0~1b/items/type","absoluteKeywordLocation":"https://example.com/s#/properties/a~0~1b/items/type","instanceLocation":"/a~0~1b/1","error":"Value is not of the allowed type, expected integer"},{"valid":false,"keywordLocation":"/properties/c/$ref/maximum","instanceLocation":"/c","error":"Number is above the maximum, at most 3"}]}`
	testing.expect_value(t, basic_text(sink.entries[:], s.c.description.uri), want)
	for &e in sink.entries {
		e.record = 4
	}
	tw: write.Tokens
	write.tokens_init(&tw, json.as(.Json), {}, context.temp_allocator)
	model.write_problem(&tw, sink.entries[:], {title = "Invalid", status = 422}, {records = true, truncated = true})
	text, _ := write.tokens_finish(&tw)
	testing.expect_value(t, string(text), `{"title":"Invalid","status":422,"errors":[{"pointer":"/a~0~1b/1","record":4,"code":"wrong_kind","message":"Value is not of the allowed type, expected integer"},{"pointer":"/c","record":4,"code":"above_maximum","message":"Number is above the maximum, at most 3"}],"truncated":true}`)
	testing.expect_value(t, basic_text(nil), `{"valid":true}`)
	typed.sink_destroy(&sink)
}

// A keyword location names each keyword as the schema wrote it, whatever its draft, and an absolute one starts at the
// innermost resource that holds the keyword and is left out past a reference.
@(test)
schema_report_locations_as_written :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		draft:          schema.Draft,
		schema_, value: string,
		want:           string,
	} {
		{.D2020_12, `{"$defs": {"a": {"type": "string"}}, "$dynamicRef": "#/$defs/a"}`, `1`, `[{"valid":false,"keywordLocation":"/$dynamicRef/type","instanceLocation":"","error":"Value is not of the allowed type, expected string"}]`},
		{.D2019_09, `{"$recursiveAnchor": true, "type": "object", "properties": {"c": {"$recursiveRef": "#"}}}`, `{"c": 1}`, `[{"valid":false,"keywordLocation":"/properties/c/$recursiveRef/type","instanceLocation":"/c","error":"Value is not of the allowed type, expected object"}]`},
		{.D2019_09, `{"type": "object", "properties": {"c": {"$recursiveRef": "#"}}}`, `{"c": 1}`, `[{"valid":false,"keywordLocation":"/properties/c/$recursiveRef/type","instanceLocation":"/c","error":"Value is not of the allowed type, expected object"}]`},
		{.D07, `{"dependencies": {"a": ["b"], "c": {"required": ["d"]}}}`, `{"a": 1, "c": 1}`, `[{"valid":false,"keywordLocation":"/dependencies","instanceLocation":"","error":"Required member \"b\" is missing"},{"valid":false,"keywordLocation":"/dependencies/c/required","instanceLocation":"","error":"Required member \"d\" is missing"}]`},
		{.D04, `{"items": [{"type": "string"}], "additionalItems": false}`, `[1, 2]`, `[{"valid":false,"keywordLocation":"/items/0/type","instanceLocation":"/0","error":"Value is not of the allowed type, expected string"},{"valid":false,"keywordLocation":"/additionalItems","instanceLocation":"/1","error":"No value is allowed here"}]`},
		{.D2020_12, `{"$id": "https://ex.com/r", "$defs": {"t": {"$dynamicAnchor": "T", "type": "string"}}, "items": {"$dynamicRef": "#T"}}`, `[1]`, `[{"valid":false,"keywordLocation":"/items/$dynamicRef/type","instanceLocation":"/0","error":"Value is not of the allowed type, expected string"}]`},
		{.D07, `{"$id": "http://ex.com/r", "dependencies": {"a": ["b"]}, "items": [{"type": "string"}]}`, `[1]`, `[{"valid":false,"keywordLocation":"/items/0/type","absoluteKeywordLocation":"http://ex.com/r#/items/0/type","instanceLocation":"/0","error":"Value is not of the allowed type, expected string"}]`},
		{.D2020_12, `{"$id": "https://ex.com/r", "properties": {"n": {"$id": "inner", "properties": {"x": {"type": "string"}}}, "m": {"type": "string"}}}`, `{"n": {"x": 1}, "m": 1}`, `[{"valid":false,"keywordLocation":"/properties/n/properties/x/type","absoluteKeywordLocation":"https://ex.com/inner#/properties/x/type","instanceLocation":"/n/x","error":"Value is not of the allowed type, expected string"},{"valid":false,"keywordLocation":"/properties/m/type","absoluteKeywordLocation":"https://ex.com/r#/properties/m/type","instanceLocation":"/m","error":"Value is not of the allowed type, expected string"}]`},
	}
	for c in cases {
		s: Bound_Schema
		if !bind_text(t, &s, c.schema_, c.draft) {
			continue
		}
		sink: typed.Sink
		schema.check(&s.b, transmute([]u8)c.value, &sink)
		want := strings.concatenate({`{"valid":false,"errors":`, c.want, "}"})
		testing.expect_value(t, basic_text(sink.entries[:], s.c.description.uri, {}, s.c.description.bases[:]), want)
		typed.sink_destroy(&sink)
		schema.unbind(&s.b)
		schema.destroy(s.c)
	}
}

@(private = "file")
same_entries :: proc(a, b: []core.Error_Entry) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		y := b[i]
		if x.kind != y.kind || x.start != y.start || x.end != y.end || x.record != y.record || len(x.path) != len(y.path) || len(x.keyword_path) != len(y.keyword_path) {
			return false
		}
		for s, k in x.path {
			if s != y.path[k] {
				return false
			}
		}
		for s, k in x.keyword_path {
			if s != y.keyword_path[k] {
				return false
			}
		}
	}
	return true
}

@(private = "file")
WIDTHS :: [?]int{1, 2, 6}

// The text checked on each pool and on one thread: the same entries, and a verdict, with and without a sink.
@(private = "file")
expect_pieces_law :: proc(t: ^testing.T, pools: []host.Pool, b: ^schema.Bound, text: string) -> bool {
	src := transmute([]u8)text
	one: typed.Sink
	defer typed.sink_destroy(&one)
	first := schema.check(b, src, &one)
	for &pool in pools {
		many: typed.Sink
		defer typed.sink_destroy(&many)
		got := schema.check(b, src, &many, &pool.runner)
		if !testing.expectf(t, same_entries(one.entries[:], many.entries[:]) && one.truncated == many.truncated && (first == nil) == (got == nil), "%q at width %d: %v, want %v", text, pool.runner.threads + 1, many.entries, one.entries) {
			return false
		}
		if !testing.expectf(t, schema.valid(b, src, &pool.runner) == (first == nil), "%q at width %d: verdict", text, pool.runner.threads + 1) {
			return false
		}
		// With no sink the failure is the one pass's, with its path.
		if !testing.expectf(t, fmt.tprintf("%v", schema.check(b, src, nil, &pool.runner)) == fmt.tprintf("%v", schema.check(b, src)), "%q at width %d: first failure", text, pool.runner.threads + 1) {
			return false
		}
	}
	return true
}

@(private = "file", rodata)
ARRAY_SCHEMAS := [?]string {
	`{"type": "array", "items": {"type": "object", "properties": {"a": {"type": "integer", "minimum": 2}}, "required": ["a"]}, "minItems": 2, "maxItems": 6}`,
	`{"$ref": "#/$defs/list", "$defs": {"list": {"type": "array", "items": {"$ref": "#/$defs/item"}}, "item": {"type": "string", "maxLength": 2}}}`,
	`{"items": {"type": "integer"}}`,
	`{"items": {"anyOf": [{"type": "integer"}, {"type": "string", "maxLength": 2}]}, "maxItems": 5}`,
}

@(private = "file", rodata)
ENTRIES := [?]string{`1`, `"x"`, `{"a": 3}`, `{"a": 1}`, `{}`, `[]`, `"too long"`, ` 7 `, `{"a": [1, {"b": "}"}]}`, `-0.5`, `null`}

// A root array checked in pieces gives the entries of the one-pass check, with each entry's index in its path and the
// keywords of the whole array, at every width and at every cut of a text that stops short.
@(test)
schema_check_pieces_equal_one_pass :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	pools: [len(WIDTHS)]host.Pool
	for w, i in WIDTHS {
		host.pool_init(&pools[i], w)
	}
	defer for &p in pools {
		host.pool_destroy(&p)
	}
	engaged := 0
	defer testing.expect(t, engaged > 0)
	for text in ARRAY_SCHEMAS {
		s: Bound_Schema
		if !bind_text(t, &s, text) {
			return
		}
		testing.expect(t, s.b.elements != nil)
		state := rand.create(7)
		gen := rand.default_random_generator(&state)
		for n in 0 ..= 9 {
			b := strings.builder_make()
			strings.write_byte(&b, '[')
			for k in 0 ..< n {
				strings.write_string(&b, rand.choice(ENTRIES[:], gen))
				strings.write_string(&b, ",\n" if k < n - 1 else "")
			}
			strings.write_byte(&b, ']')
			// The same entries in an array that an object holds, which is no root array.
			for src in ([]string{strings.to_string(b), fmt.tprintf(`{{"a": %s}}`, strings.to_string(b))}) {
				for cut in 0 ..= len(src) {
					_, _, pooled := records.entries_of(transmute([]u8)src[:cut], s.b.plan.as, &s.b.plan)
					engaged += int(pooled)
					if !expect_pieces_law(t, pools[:], &s.b, src[:cut]) {
						return
					}
				}
			}
		}
	}
	// A root that reads more than its entries is checked in one pass.
	for text in ([]string{`{"type": "array", "prefixItems": [{"type": "string"}], "items": {}}`, `{"type": "array", "items": {}, "pattern": "x"}`, `{"type": "object"}`}) {
		s: Bound_Schema
		if bind_text(t, &s, text) {
			testing.expect(t, s.b.elements == nil)
		}
	}
}

// The records of a text checked in pieces give the entries of each record checked alone, counted from the first.
@(test)
schema_check_records_equal_each_record :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	pools: [len(WIDTHS)]host.Pool
	for w, i in WIDTHS {
		host.pool_init(&pools[i], w)
	}
	defer for &p in pools {
		host.pool_destroy(&p)
	}
	s: Bound_Schema
	if !bind_text(t, &s, `{"type": "object", "properties": {"a": {"type": "integer", "minimum": 2}, "b": {"maxLength": 2}}, "required": ["a"], "additionalProperties": false}`) {
		return
	}
	lines := []string{`{"a": 5}`, `{"a": 1, "b": "xyz"}`, `{"b": "x"}`, `{"a": 3, "z": 1}`, `7`, `{"a": 9}`, `{"a": 1, "b": "xyz",}`, `{"a": 1}`}
	for upto in 0 ..= len(lines) {
		b := strings.builder_make()
		for l in lines[:upto] {
			strings.write_string(&b, l)
			strings.write_byte(&b, '\n')
		}
		src := strings.to_string(b)
		want: typed.Sink
		at := 0
		for l, i in lines[:upto] {
			one: typed.Sink
			one.record = i64(i)
			err := schema.check(&s.b, transmute([]u8)l, &one)
			cut_record := len(one.entries) > 0 && one.entries[len(one.entries) - 1].kind == .Walk
			for e in one.entries {
				// A record the fault cut tells only the fault.
				if cut_record && e.kind != .Walk {
					continue
				}
				x := e
				x.start += u64(at)
				x.end += u64(at)
				x.record = i64(i)
				append(&want.entries, x)
			}
			if cut_record {
				break
			}
			_ = err
			at += len(l) + 1
		}
		for &pool in pools {
			got: typed.Sink
			_, err := schema.check_records(&s.b, transmute([]u8)src, .Lines, &got, &pool.runner)
			testing.expectf(t, same_entries(want.entries[:], got.entries[:]), "%d lines at width %d: %v, want %v", upto, pool.runner.threads + 1, got.entries, want.entries)
			testing.expectf(t, (err == nil) == (len(want.entries) == 0), "%d lines at width %d: %v", upto, pool.runner.threads + 1, err)
			_, is_fault := err.(core.Fault)
			testing.expectf(t, is_fault == (upto >= 7), "%d lines at width %d: the fault is the result: %v", upto, pool.runner.threads + 1, err)
			typed.sink_destroy(&got)
			// A limit that keeps one entry keeps no fault out of the result.
			limited := typed.Sink{max_errors = 1}
			_, err = schema.check_records(&s.b, transmute([]u8)src, .Lines, &limited, &pool.runner)
			_, is_fault = err.(core.Fault)
			testing.expectf(t, is_fault == (upto >= 7), "%d lines, one entry, at width %d: %v", upto, pool.runner.threads + 1, err)
			typed.sink_destroy(&limited)
		}
	}
}

// A check of records in the temp allocator gives back what each record took from it, while the runs and forks of the
// check serve every record. The temp allocator's block is filled before each check, so what a record takes is in a
// block of its own that the release frees, which the sanitizer then sees read.
@(test)
schema_check_records_forks_outlive_each_record :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	s: Bound_Schema
	if !bind_text(t, &s, `{"anyOf": [{"type": "object", "required": ["a"]}, {"type": "array", "items": {"anyOf": [{"type": "integer"}, {"type": "object"}]}}]}`) {
		return
	}
	for framing in ([]core.Framing{.Lines, .Concatenated}) {
		temp_block_fill()
		count, err := schema.check_records(&s.b, transmute([]u8)string("{\"a\": 1}\n[1, {}]\n{\"a\": [2]}\n[{\"b\": 3}]\n"), framing)
		testing.expectf(t, count == 4 && err == nil, "%v: %d records, %v", framing, count, err)
	}
}

// Takes what is left of the temp allocator's current block, so its next allocation starts a block.
@(private = "file")
temp_block_fill :: proc() {
	arena := &(^runtime.Default_Temp_Allocator)(context.temp_allocator.data).arena
	if arena.curr_block == nil {
		_, _ = runtime.mem_alloc_non_zeroed(1, 1, context.temp_allocator)
	}
	if left := arena.curr_block.capacity - arena.curr_block.used; left > 0 {
		_, _ = runtime.mem_alloc_non_zeroed(int(left), 1, context.temp_allocator)
	}
}

// A held plan's records are checked one by one on a thread, and values one after another are records.
@(test)
schema_check_records_held_and_concatenated :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	s: Bound_Schema
	if !bind_text(t, &s, `{"type": "object", "properties": {"a": {"type": "integer"}}}`) {
		return
	}
	// A schema failure and a fault in one record end the records with the fault.
	got: typed.Sink
	count, err := schema.check_records(&s.b, transmute([]u8)string("{\"a\":\"x\",}\n{\"a\":\"y\"}\n"), .Lines, &got)
	_, is_fault := err.(core.Fault)
	testing.expectf(t, is_fault && count == 1, "%v after %d records", err, count)
	for e in got.entries {
		testing.expectf(t, e.record == 0, "a record past the fault: %v", got.entries)
	}
	typed.sink_destroy(&got)
	got = {}
	// Values one after another.
	count, err = schema.check_records(&s.b, transmute([]u8)string(`{"a": 1} {"a": "x"} 7`), .Concatenated, &got)
	testing.expectf(t, count == 3 && err != nil && len(got.entries) == 2, "%d records, %v, %v", count, err, got.entries)
	typed.sink_destroy(&got)
	// A property named `$ref` is not a reference.
	own: Bound_Schema
	if bind_text(t, &own, `{"$id": "http://e.com/s", "type": "object", "properties": {"$ref": {"type": "integer"}}}`) {
		one: typed.Sink
		schema.check(&own.b, transmute([]u8)string(`{"$ref": "x"}`), &one)
		testing.expect(t, basic_text(one.entries[:], own.c.description.uri) != "" && strings.contains(basic_text(one.entries[:], own.c.description.uri), "absoluteKeywordLocation"))
		typed.sink_destroy(&one)
	}
}
