// What the TOML writer refuses or leaves out where TOML cannot spell a value: an integer past 64 bits, a negative zero
// integer, and a null.
package toml_tests

import "core:testing"
import core "../../core"
import write "../../core/write"
import json_pkg "../../json"
import toml ".."
import testkit "../../testkit"
import yaml "../../yaml"

@(private)
expect_steps :: proc(t: ^testing.T, err: core.Error, want: ..core.Step, loc := #caller_location) {
	e, is_typed := err.(core.Typed_Error)
	testing.expect(t, is_typed, loc = loc)
	testing.expect_value(t, len(e.steps), len(want), loc)
	for step, i in want {
		if i < len(e.steps) {
			testing.expect_value(t, e.steps[i], step, loc)
		}
	}
}

@(test)
marshal_leaves_out_a_nil_optional_member :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Inner :: struct {
		n:   Maybe(int),
		tag: string,
	}
	Config :: struct {
		title: string,
		opt:   Maybe(int),
		ptr:   ^int,
		set:   Maybe(int),
		in_:   Inner,
	}
	text, err := toml.marshal(Config{title = "x", set = 3, in_ = {tag = "y"}}, allocator = context.temp_allocator)
	testkit.expect_nil(t, err)
	testing.expect_value(t, string(text), "title = \"x\"\nset = 3\n\n[in_]\ntag = \"y\"\n")
}

@(test)
marshal_names_the_field_of_a_nil_that_cannot_be_left_out :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, err := toml.marshal(struct {
			list: []Maybe(int),
		}{[]Maybe(int){1, nil}}, allocator = context.temp_allocator)
	testkit.expect_kind(t, err, core.Typed_Error_Kind.Unwritable)
	expect_steps(t, err, core.Name("list"), core.Index(1))
}

@(test)
written_integer_past_64_bits_is_refused_and_named :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for src in ([]string{`{"a":18446744073709551616}`, `{"a":9223372036854775808}`, `{"a":-9223372036854775809}`}) {
		doc, berr := json_pkg.build(transmute([]u8)src, .Json)
		defer core.destroy(&doc)
		testkit.expect_nil(t, berr)
		_, _, err := core.write(&doc, {}, toml.as(.Toml_1_0), allocator = context.temp_allocator)
		testkit.expect_kind(t, err, core.Typed_Error_Kind.Unwritable)
		e, _ := err.(core.Typed_Error)
		testing.expect(t, len(e.want.text) > 0, "the refusal names the value")
	}
	for c in ([][2]string{{`{"a":9223372036854775807}`, "a = 9223372036854775807\n"}, {`{"a":-9223372036854775808}`, "a = -9223372036854775808\n"}}) {
		src, want := c[0], c[1]
		doc, _ := json_pkg.build(transmute([]u8)src, .Json)
		defer core.destroy(&doc)
		text, werr := written(&doc)
		testkit.expect_nil(t, werr)
		testing.expect_value(t, text, want)
	}
}

@(test)
token_write_refuses_an_unsigned_integer_past_64_bits :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: write.Tokens
	write.tokens_init(&w, toml.as(.Toml_1_0), allocator = context.temp_allocator)
	write.open_object(&w)
	write.key(&w, "a")
	write.value_uint(&w, 1 << 63)
	write.close(&w)
	_, err := write.tokens_finish(&w)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Unwritable)
	testing.expect_value(t, err.want.text, "9223372036854775808 is an integer past 64 bits")
}

// An integer `-0` reads back as 0, so it is written as the float that keeps the sign.
@(test)
negative_zero_integer_is_written_as_a_float :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc, berr := json_pkg.build(transmute([]u8)string(`{"a":-0,"b":[0,-0],"c":-0.0}`), .Json)
	defer core.destroy(&doc)
	testkit.expect_nil(t, berr)
	text, werr := written(&doc)
	testkit.expect_nil(t, werr)
	testing.expect_value(t, text, "a = -0.0\nb = [0, -0.0]\nc = -0.0\n")
}

// A document write that refuses names the node: an infinity of a YAML document written as JSON has no spelling there.
@(test)
document_write_names_the_node_it_refuses :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc, berr := yaml.build(transmute([]u8)string("a:\n  - 1\n  - .inf\n"), .Yaml_1_2)
	defer core.destroy(&doc)
	testkit.expect_nil(t, berr)
	_, _, err := core.write(&doc, {}, json_pkg.as(.Json), allocator = context.temp_allocator)
	testkit.expect_kind(t, err, core.Typed_Error_Kind.Non_Finite)
	expect_steps(t, err, core.Name("a"), core.Index(1))
}

@(test)
marshal_names_an_unsigned_member_past_64_bits :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, err := toml.marshal(struct {
			big: u64,
		}{1 << 63}, allocator = context.temp_allocator)
	testkit.expect_kind(t, err, core.Typed_Error_Kind.Unwritable)
	expect_steps(t, err, core.Name("big"))
	e, _ := err.(core.Typed_Error)
	testing.expect_value(t, e.want.text, "9223372036854775808 is an integer past 64 bits")
}

@(test)
toml_write_names_the_node_of_a_null :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc, berr := json_pkg.build(transmute([]u8)string(`{"a":{"b":[1,null]}}`), .Json)
	defer core.destroy(&doc)
	testkit.expect_nil(t, berr)
	_, _, err := core.write(&doc, {}, toml.as(.Toml_1_0), allocator = context.temp_allocator)
	testkit.expect_kind(t, err, core.Typed_Error_Kind.Unwritable)
	expect_steps(t, err, core.Name("a"), core.Name("b"), core.Index(1))
}
