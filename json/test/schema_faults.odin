package json_tests

import "core:fmt"
import "core:strings"
import "core:time"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import schema "../../core/schema"
import json ".."

// What a check of `instance` by the schema `text` finds first: the kind of its first entry, or `.None` when it passes.
@(private = "file")
first_kind :: proc(t: ^testing.T, text, instance: string) -> core.Typed_Error_Kind {
	return first_entry(t, text, instance).kind
}

// The first entry of a check of `instance` by the schema `text`, zero when it passes.
@(private = "file")
first_entry :: proc(t: ^testing.T, text, instance: string) -> core.Error_Entry {
	c, err := schema.compile(transmute([]u8)text, json.as(.Json))
	if !testing.expectf(t, err == nil, "%v", err) {
		return {}
	}
	defer schema.destroy(c)
	b: schema.Bound
	b, err = schema.bind(c, json.checks(.Json))
	if !testing.expectf(t, err == nil, "%v", err) {
		return {}
	}
	defer schema.unbind(&b)
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	schema.check(&b, transmute([]u8)instance, &sink)
	return sink.entries[0] if len(sink.entries) > 0 else {}
}

// A string of `n` letters a and b that a search for `(a|b)*a(a|b){20}$` cannot decide within its memory.
@(private = "file")
long_ab :: proc(n: int) -> string {
	b := strings.builder_make_len_cap(0, n + 2)
	strings.write_byte(&b, '"')
	x := u64(0x9E3779B97F4A7C15)
	for _ in 0 ..< n {
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		strings.write_byte(&b, 'a' if x & 1 == 0 else 'b')
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// A search that gives up is a fault on the value and no verdict: `pattern` does not fail the string, `not` does not pass
// it and a `patternProperties` name is not taken as unmatched.
@(test)
a_pattern_search_that_gives_up_is_a_fault :: proc(t: ^testing.T) {
	long := long_ab(1_000_000)
	defer delete(long)
	pattern :: `(a|b)*a(a|b){20}$`
	// Each failed search holds its memory until the temp allocator is freed, so the searches are freed one by one.
	testing.expect_value(t, first_kind(t, `{"pattern": "` + pattern + `"}`, long), core.Typed_Error_Kind.Pattern_Undecided)
	free_all(context.temp_allocator)
	testing.expect_value(t, first_kind(t, `{"not": {"pattern": "` + pattern + `"}}`, long), core.Typed_Error_Kind.Pattern_Undecided)
	free_all(context.temp_allocator)
	named := strings.concatenate({`{"`, long[1:len(long) - 1], `": 1}`})
	defer delete(named)
	testing.expect_value(t, first_kind(t, `{"patternProperties": {"` + pattern + `": {"type": "integer"}}, "additionalProperties": false}`, named), core.Typed_Error_Kind.Pattern_Undecided)
	free_all(context.temp_allocator)
	testing.expect_value(t, first_kind(t, `{"pattern": "` + pattern + `"}`, `"abbbbbbbbbbbbbbbbbbbb"`), core.Typed_Error_Kind.None)
	testing.expect_value(t, first_kind(t, `{"pattern": "` + pattern + `"}`, `"b"`), core.Typed_Error_Kind.No_Match)
}

@(private = "file")
binds :: proc(text: string) -> core.Error {
	c, err := schema.compile(transmute([]u8)text, json.as(.Json))
	if err != nil {
		return err
	}
	defer schema.destroy(c)
	b: schema.Bound
	b, err = schema.bind(c, json.checks(.Json))
	if err == nil {
		schema.unbind(&b)
	}
	return err
}

// A schema whose `$defs` d1 to dn each name the one before twice under `allOf` binds without a copy of the chain for
// every path through it.
@(test)
a_shared_allof_chain_binds_in_bounded_memory :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	text := strings.builder_make()
	strings.write_string(&text, `{"$ref": "#/$defs/d30", "$defs": {"d0": {"type": "integer"}`)
	for i in 1 ..= 30 {
		fmt.sbprintf(&text, `, "d%d": {{"allOf": [{{"$ref": "#/$defs/d%d"}}, {{"$ref": "#/$defs/d%d"}}]}}`, i, i - 1, i - 1)
	}
	strings.write_string(&text, "}}")
	e := binds(strings.to_string(text)); testing.expectf(t, e == nil, "%v", e)
}

// A chain of references loads and binds in time linear in its length: a chain eight times as long takes less than 32
// times as long, where a search along the chain from each link would take 64 times as long. Each length takes its
// fastest of three runs, and a ratio of two times holds on a machine that runs slow throughout. The runs bind on the
// heap, so a run after the first reuses the pages the one before released rather than faulting in new ones.
@(test)
a_long_ref_chain_loads_and_binds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	chain :: proc(links: int) -> string {
		text := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&text, `{{"$ref": "#/$defs/r%d", "$defs": {{"r0": {{"type": "integer"}}`, links)
		for i in 1 ..= links {
			fmt.sbprintf(&text, `, "r%d": {{"$ref": "#/$defs/r%d"}}`, i, i - 1)
		}
		strings.write_string(&text, "}}")
		return strings.to_string(text)
	}
	short, long := chain(6250), chain(50000)
	fastest: [2]time.Duration = max(time.Duration)
	for _ in 0 ..< 3 {
		for text, i in ([2]string{short, long}) {
			start := time.tick_now()
			e := binds(text)
			fastest[i] = min(fastest[i], time.tick_since(start))
			if !testing.expectf(t, e == nil, "%v", e) {
				return
			}
		}
	}
	testing.expectf(t, fastest[1] < 32 * fastest[0], "%v for 50000 links, %v for 6250", fastest[1], fastest[0])
}

// A schema whose references lead 2100 levels down is refused and no recursion runs out of stack.
@(test)
a_schema_nested_past_the_depth_bound_is_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	text := strings.builder_make()
	strings.write_string(&text, `{"$ref": "#/$defs/n0", "$defs": {"n2100": {}`)
	for i in 0 ..< 2100 {
		fmt.sbprintf(&text, `, "n%d": {{"properties": {{"a": {{"$ref": "#/$defs/n%d"}}}}}}`, i, i + 1)
	}
	strings.write_string(&text, "}}")
	err := binds(strings.to_string(text))
	fault, is_typed := err.(core.Typed_Error)
	testing.expectf(t, is_typed && fault.kind == .Too_Deep, "%v", err)
}

// Under draft 2019-09 a matching `contains` does not mark an item evaluated.
@(test)
contains_does_not_evaluate_items_under_2019_09 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	older :: `{"$schema": "https://json-schema.org/draft/2019-09/schema", "contains": {"type": "integer"}, "unevaluatedItems": false}`
	newer :: `{"$schema": "https://json-schema.org/draft/2020-12/schema", "contains": {"type": "integer"}, "unevaluatedItems": false}`
	testing.expect(t, first_kind(t, older, `[1]`) != .None)
	testing.expect_value(t, first_kind(t, newer, `[1]`), core.Typed_Error_Kind.None)
}

// A check's wrong-kind error names the kind of the value it found.
@(test)
a_wrong_kind_error_names_the_found_kind :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	text :: `{"type": "string"}`
	c, cerr := schema.compile(transmute([]u8)string(text), json.as(.Json))
	if !testing.expectf(t, cerr == nil, "%v", cerr) {
		return
	}
	defer schema.destroy(c)
	b, berr := schema.bind(c, json.checks(.Json))
	if !testing.expectf(t, berr == nil, "%v", berr) {
		return
	}
	defer schema.unbind(&b)
	first, is_typed := schema.check(&b, transmute([]u8)string("[1]")).(core.Typed_Error)
	testing.expect(t, is_typed)
	testing.expect_value(t, first.kind, core.Typed_Error_Kind.Wrong_Kind)
	testing.expect_value(t, first.found, core.Kind.Array)
}
