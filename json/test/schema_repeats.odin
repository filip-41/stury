package json_tests

import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import schema "../../core/schema"
import json ".."

// A key that repeats in an object is judged as the read's `Duplicates` sees the object: the member counts once, and its
// rules judge the value `dups` keeps.

// What a check of `instance` by the schema `text` under `dups` finds: the entries with a sink, and whether a check with no
// sink passes.
@(private = "file")
Repeat_Verdict :: struct {
	entries:    int,
	passes:     bool,
	with_sink:  core.Error,
	no_sink_ok: bool,
}

@(private = "file")
judge :: proc(t: ^testing.T, text, instance: string, dups: core.Duplicates) -> (v: Repeat_Verdict) {
	doc, err := core.build(transmute([]u8)text, json.as(.Json))
	if !testing.expectf(t, err == nil, "%s: %v", text, err) {
		return
	}
	defer core.destroy(&doc)
	c: schema.Compiled
	c, err = schema.compile(&doc, core.ROOT, {dups = dups})
	if !testing.expectf(t, err == nil, "%s: %v", text, err) {
		return
	}
	defer schema.destroy(&c)
	b: schema.Bound
	b, err = schema.bind(&c, json.checks(.Json))
	if !testing.expectf(t, err == nil, "%s: %v", text, err) {
		return
	}
	defer schema.unbind(&b)
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	v.with_sink = schema.check(&b, transmute([]u8)instance, &sink)
	v.entries = len(sink.entries)
	v.passes = schema.check(&b, transmute([]u8)instance) == nil
	v.no_sink_ok = schema.valid(&b, transmute([]u8)instance)
	return
}

@(private = "file")
expect_verdict :: proc(t: ^testing.T, text, instance: string, dups: core.Duplicates, entries: int) {
	v := judge(t, text, instance, dups)
	testing.expectf(t, v.entries == entries, "%s on %s under %v: %d entries, want %d", text, instance, dups, v.entries, entries)
	testing.expectf(t, v.passes == (entries == 0) && v.no_sink_ok == (entries == 0), "%s on %s under %v: no sink passes %v, valid %v", text, instance, dups, v.passes, v.no_sink_ok)
}

// The review's table: counts and member rules under `.Last`.
@(test)
repeats_last :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	expect_verdict(t, `{"minProperties": 2}`, `{"a":1,"a":2}`, .Last, 1)
	expect_verdict(t, `{"maxProperties": 1}`, `{"a":1,"a":2}`, .Last, 0)
	expect_verdict(t, `{"properties": {"a": {"type": "string"}}}`, `{"a":1,"a":"x"}`, .Last, 0)
	expect_verdict(t, `{"properties": {"a": {"type": "string"}}}`, `{"a":"x","a":1}`, .Last, 1)
	expect_verdict(t, `{"const": {"a": 2}}`, `{"a":1,"a":2}`, .Last, 0)
	expect_verdict(t, `{"required": ["a"], "minProperties": 1}`, `{"a":1,"a":2}`, .Last, 0)
}

@(test)
repeats_first :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	expect_verdict(t, `{"minProperties": 2}`, `{"a":1,"a":2}`, .First, 1)
	expect_verdict(t, `{"maxProperties": 1}`, `{"a":1,"a":2}`, .First, 0)
	expect_verdict(t, `{"properties": {"a": {"type": "string"}}}`, `{"a":"x","a":1}`, .First, 0)
	expect_verdict(t, `{"properties": {"a": {"type": "string"}}}`, `{"a":1,"a":"x"}`, .First, 1)
}

@(test)
repeats_refuse_and_all :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for text in ([]string{`{"maxProperties": 5}`, `{"properties": {"a": {}}}`, `{}`}) {
		v := judge(t, text, `{"a":1,"b":{"c":1,"c":2}}`, .Refuse)
		testing.expectf(t, v.with_sink != nil && !v.no_sink_ok, "%s under .Refuse: %v", text, v.with_sink)
		v = judge(t, text, `{"a":1,"b":{"c":1}}`, .Refuse)
		testing.expectf(t, v.with_sink == nil && v.no_sink_ok, "%s under .Refuse with no repeat: %v", text, v.with_sink)
	}
	v := judge(t, `{}`, `{"a":1}`, .All)
	testing.expect(t, v.with_sink != nil)
}

// A key no record names, a key of an inner object, and a repeat whose earlier errors sit among other members' errors.
@(test)
repeats_unnamed_and_nested :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	expect_verdict(t, `{"additionalProperties": {"type": "string"}}`, `{"x":1,"x":"s"}`, .Last, 0)
	expect_verdict(t, `{"additionalProperties": {"type": "string"}}`, `{"x":1,"x":"s"}`, .First, 1)
	expect_verdict(t, `{"maxProperties": 2}`, `{"x":1,"x":2,"y":3}`, .Last, 0)
	expect_verdict(t, `{"maxProperties": 2}`, `{"x":1,"y":2,"x":3,"z":4}`, .Last, 1)
	expect_verdict(t, `{"propertyNames": {"maxLength": 1}}`, `{"ab":1,"ab":2}`, .Last, 1)
	expect_verdict(t, `{"properties": {"a": {"type": "string"}, "b": {"type": "string"}}}`, `{"a":1,"b":1,"a":"x"}`, .Last, 1)
	expect_verdict(t, `{"properties": {"o": {"maxProperties": 1}}}`, `{"o":{"p":1,"p":2}}`, .Last, 0)
	expect_verdict(t, `{"properties": {"o": {"maxProperties": 1}}}`, `{"o":{"p":1,"q":2}, "o":{"p":1}}`, .Last, 0)
	expect_verdict(t, `{"items": {"properties": {"a": {"type": "string"}}}}`, `[{"a":1,"a":"x"},{"a":2}]`, .Last, 1)
}

// Records: each is judged by its own repeats, and a record's retried check leaves the next record's alone.
@(test)
repeats_records :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	doc, err := core.build(transmute([]u8)string(`{"properties": {"a": {"type": "string"}}}`), json.as(.Json))
	testing.expect(t, err == nil)
	c, compiled := schema.compile(&doc, core.ROOT)
	testing.expect(t, compiled == nil)
	b, bound := schema.bind(&c, json.checks(.Json))
	testing.expect(t, bound == nil)
	src := transmute([]u8)string("{\"a\":1,\"a\":\"x\"}\n{\"a\":2}\n{\"a\":\"y\",\"a\":3}\n")
	for framing in ([]core.Framing{.Lines, .Concatenated}) {
		sink: typed.Sink
		count, failure := schema.check_records(&b, src, framing, &sink)
		testing.expectf(t, count == 3 && failure != nil && len(sink.entries) == 2 && sink.entries[0].record == 1 && sink.entries[1].record == 2, "%v: %d records, %d entries", framing, count, len(sink.entries))
		_, no_sink := schema.check_records(&b, src, framing)
		testing.expectf(t, no_sink != nil, "%v: no sink", framing)
		typed.sink_destroy(&sink)
	}
	valid := transmute([]u8)string("{\"a\":1,\"a\":\"x\"}\n{\"a\":\"z\"}\n")
	for framing in ([]core.Framing{.Lines, .Concatenated}) {
		_, passes := schema.check_records(&b, valid, framing)
		testing.expectf(t, passes == nil, "%v: valid records: %v", framing, passes)
	}
}

// A recursive `oneOf` whose arms reach one child alike, read again for its repeats: the arms that read one child share
// one judging of it, so the work stays linear in the depth.
@(test)
repeats_recursive_arms :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	node := `{"$defs": {"node": {"oneOf": [` +
		`{"properties": {"kind": {"const": "t0"}, "child": {"$ref": "#/$defs/node"}}, "required": ["kind"]},` +
		`{"properties": {"kind": {"const": "t1"}, "child": {"$ref": "#/$defs/node"}}, "required": ["kind"]},` +
		`{"properties": {"kind": {"const": "t2"}, "child": {"$ref": "#/$defs/node", "type": "object"}}, "required": ["kind"]},` +
		`{"properties": {"kind": {"const": "leaf"}, "value": {"type": "integer"}}, "required": ["kind", "value"]},` +
		`{"type": "integer"}]}}, "$ref": "#/$defs/node"}`
	kinds := [3]string{"t0", "t1", "t2"}
	for every in ([]bool{false, true}) {
		for last in ([]string{"t1", "zz"}) {
			text := `{"kind": "leaf", "value": 1}`
			for i in 0 ..< 40 {
				lead := `{"kind": "zz", ` if every || i == 39 else `{`
				text = strings.concatenate({lead, `"child": `, text, `, "kind": "`, last if i == 39 else kinds[i % 3], `"}`})
			}
			expect_verdict(t, node, text, .Last, 0 if last == "t1" else 1)
			expect_verdict(t, node, text, .First, 1)
		}
	}
}
