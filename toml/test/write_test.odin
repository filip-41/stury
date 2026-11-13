// The TOML writer: every valid toml-test case written and read back as the same value, the writer's own texts as a fixed
// point, the layout of sections, comments and datetimes, the token write, and the typed write and read.
package toml_tests

import "core:encoding/json"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import write "../../core/write"
import json_pkg "../../json"
import toml ".."
import walktest "../../walktest"
import yaml "../../yaml"

@(private)
written :: proc(doc: ^core.Document, opts := core.Write_Options{}) -> (string, core.Error) {
	text, _, err := core.write(doc, opts, toml.as(.Toml_1_0), allocator = context.temp_allocator)
	return string(text), err
}

// Every case read, written, read again and compared with its expected value, then written again for the same text.
@(private)
check_written :: proc(t: ^testing.T, list: string, spec: toml.Spec) -> (cases: int) {
	rest := list
	for name in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(name, "valid/") || !strings.has_suffix(name, ".toml") {
			continue
		}
		data, found := case_data(name)
		expected, has_json := case_data(strings.concatenate({name[:len(name) - 5], ".json"}, context.temp_allocator))
		if !testing.expectf(t, found && has_json, "%s is not vendored", name) {
			continue
		}
		want, _ := json.parse(expected, .JSON, true, context.temp_allocator)
		doc, err := toml.build(data, spec)
		if !testing.expectf(t, err == nil, "%s: %v", name, err) {
			continue
		}
		text, werr := written(&doc)
		if testing.expectf(t, werr == nil, "%s: the write is %v", name, werr) {
			again, aerr := toml.build(transmute([]u8)text, .Toml_1_0)
			if testing.expectf(t, aerr == nil, "%s: the written text does not read: %v\n%s", name, aerr, text) {
				why: strings.Builder
				strings.builder_init(&why, context.temp_allocator)
				testing.expectf(t, matches(&again, core.ROOT, want, &why), "%s: %s\n%s", name, strings.to_string(why), text)
				second, _ := written(&again)
				testing.expectf(t, second == text, "%s: a second write differs\n%s\n---\n%s", name, text, second)
				core.destroy(&again)
			}
		}
		core.destroy(&doc)
		cases += 1
		free_all(context.temp_allocator)
	}
	return
}

@(test)
written_toml_1_0 :: proc(t: ^testing.T) {
	testing.expect_value(t, check_written(t, LIST_1_0, .Toml_1_0), 208)
}

@(test)
written_toml_1_1 :: proc(t: ^testing.T) {
	testing.expect_value(t, check_written(t, LIST_1_1, .Toml_1_1), 218)
}

@(private)
text_of :: proc(src: string, opts := core.Write_Options{}) -> string {
	doc, err := toml.build(transmute([]u8)src, .Toml_1_1)
	if err != nil {
		return "build failed"
	}
	defer core.destroy(&doc)
	text, werr := written(&doc, opts)
	return text if werr == nil else "write failed"
}

@(test)
layout_puts_lines_before_sections :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	got := text_of("[a]\nx = 1\n[b]\ny = 2\n[a.c]\nz = 3\n")
	testing.expect_value(t, got, "[a]\nx = 1\n\n[a.c]\nz = 3\n\n[b]\ny = 2\n")
}

@(test)
layout_omits_the_header_of_a_table_that_holds_only_sections :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, text_of("[a.b.c]\nx = 1\n"), "[a.b.c]\nx = 1\n")
	testing.expect_value(t, text_of("a = {}\n"), "[a]\n")
}

@(test)
layout_writes_arrays_of_tables_as_sections :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, text_of("a = [{x = 1}, {x = 2, y = [{z = 3}]}]\nb = [[1], 2]\nc = []\n"), "b = [[1], 2]\nc = []\n\n[[a]]\nx = 1\n\n[[a]]\nx = 2\n\n[[a.y]]\nz = 3\n")
}

@(test)
layout_keeps_comments :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "# head\na = 1 # inline\n\n# section\n[t]\n# above b\nb = 2\n# foot\n"
	testing.expect_value(t, text_of(src), "# head\na = 1 # inline\n\n# section\n[t]\n# above b\nb = 2\n\n# foot\n")
}

@(test)
layout_keeps_literal_strings_unless_respelled :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, text_of("a = 'x\\y'\nb = \"\"\"m\nl\"\"\"\n"), "a = 'x\\y'\nb = \"m\\nl\"\n")
	testing.expect_value(t, text_of("a = 'x\\y'\n", {respell_strings = true}), "a = \"x\\\\y\"\n")
}

@(test)
strings_escape_what_toml_requires :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, text_of("a = \"q\\\"\\t\\u0001\\u007f\\u00e9\"\n", {respell_strings = true}), "a = \"q\\\"\\t\\u0001\\u007fé\"\n")
	testing.expect_value(t, text_of("a = \"\\u00e9\\U0001F600\"\n", {ascii = true, respell_strings = true}), "a = \"\\u00e9\\U0001f600\"\n")
}

@(test)
datetimes_are_written_bare_in_1_0_forms :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, text_of("a = 07:32\nb = 1979-05-27 07:32Z\nc = 1979-05-27\n"), "a = 07:32:00\nb = 1979-05-27 07:32:00Z\nc = 1979-05-27\n")
}

@(test)
sort_keys_orders_members :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, text_of("z = 1\na = 2\n[m]\nb = 1\na = 2\n", {sort_keys = true}), "a = 2\nz = 1\n\n[m]\na = 2\nb = 1\n")
}

@(test)
other_formats_are_written_as_toml :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := `{"b":[1,2.5,"x"],"a":{"k":true,"e":[{"i":1}]},"s":"é\n"}`
	doc, err := json_pkg.build(transmute([]u8)src, .Json)
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	got, werr := written(&doc)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, got, "b = [1, 2.5, \"x\"]\ns = \"é\\n\"\n\n[a]\nk = true\n\n[[a.e]]\ni = 1\n")
}

@(test)
infinities_and_nans_of_other_formats_are_written_as_toml :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "a: .inf\nb: -.inf\nc: .nan\n"
	doc, err := yaml.build(transmute([]u8)src, .Yaml_1_2)
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	got, werr := written(&doc)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, got, "a = inf\nb = -inf\nc = nan\n")
}

@(test)
the_head_comment_of_another_format_is_written_as_toml :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "# head\n\n# before a\na: 1 # tail a\n"
	doc, err := yaml.build(transmute([]u8)src, .Yaml_1_2)
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	got, werr := written(&doc)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, got, "# head\n# before a\na = 1 # tail a\n")
}

@(test)
the_write_refuses_what_toml_cannot_spell :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for src in ([]string{`{"a":null}`, `[1]`, `1`, `{"a":1,"a":2}`, `{"a":[null]}`}) {
		doc, err := json_pkg.build(transmute([]u8)src, .Json)
		walktest.expect_nil(t, err)
		_, werr := written(&doc)
		kind := walktest.typed_kind(werr)
		testing.expectf(t, kind == .Unsupported || kind == .Unwritable, "%s is written", src)
		core.destroy(&doc)
	}
}

@(test)
token_write_lays_out_the_calls :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: write.Tokens
	testing.expect_value(t, write.tokens_init(&w, toml.as(.Toml_1_0), allocator = context.temp_allocator), core.Typed_Error_Kind.None)
	write.open_object(&w)
	write.key(&w, "t")
	write.open_object(&w)
	write.key(&w, "x")
	write.value_int(&w, 1)
	write.close(&w)
	write.key(&w, "when")
	write.value_tagged(&w, "1979-05-27T07:32:00Z", "datetime")
	write.key(&w, "list")
	write.open_array(&w)
	write.value_string(&w, "a\"b")
	write.value_float(&w, 1.5)
	write.close(&w)
	write.close(&w)
	bytes, err := write.tokens_finish(&w)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(bytes), "when = 1979-05-27T07:32:00Z\nlist = [\"a\\\"b\", 1.5]\n\n[t]\nx = 1\n")
}

@(test)
token_write_under_a_pretty_layout_lays_out_the_same_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: write.Tokens
	testing.expect_value(t, write.tokens_init(&w, toml.as(.Toml_1_0), core.PRETTY, context.temp_allocator), core.Typed_Error_Kind.None)
	write.open_object(&w)
	write.key(&w, "t")
	write.open_object(&w)
	write.key(&w, "x")
	write.value_int(&w, 1)
	write.close(&w)
	write.key(&w, "list")
	write.open_array(&w)
	write.value_int(&w, 2)
	write.close(&w)
	write.close(&w)
	bytes, err := write.tokens_finish(&w)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(bytes), "list = [2]\n\n[t]\nx = 1\n")
}

@(test)
token_write_refuses_a_datetime_of_another_type :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: write.Tokens
	write.tokens_init(&w, toml.as(.Toml_1_0), allocator = context.temp_allocator)
	write.open_object(&w)
	write.key(&w, "when")
	write.value_tagged(&w, "1979-05-27", "datetime")
	write.close(&w)
	_, err := write.tokens_finish(&w)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Bad_Raw)
}

@(test)
token_write_refuses_null_and_a_value_that_is_no_table :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: write.Tokens
	write.tokens_init(&w, toml.as(.Toml_1_0), allocator = context.temp_allocator)
	write.open_object(&w)
	write.key(&w, "a")
	write.value_null(&w)
	write.close(&w)
	_, err := write.tokens_finish(&w)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Unwritable)
	v: write.Tokens
	write.tokens_init(&v, toml.as(.Toml_1_0), allocator = context.temp_allocator)
	write.value_int(&v, 3)
	_, err = write.tokens_finish(&v)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Unsupported)
}

Server :: struct {
	host: string,
	port: int,
	tags: []string,
}

Config :: struct {
	title:   string,
	debug:   bool,
	ratio:   f64,
	servers: []Server,
	limits:  map[string]int,
	inner:   struct {
		name: string `toml:"label"`,
	},
}

@(test)
marshal_writes_a_struct_as_a_document :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cfg := Config {
		title   = "t",
		debug   = true,
		ratio   = 0.5,
		servers = {{"a", 1, {"x", "y"}}, {"b", 2, nil}},
		inner   = {name = "n"},
	}
	cfg.limits = make(map[string]int, allocator = context.temp_allocator)
	cfg.limits["m"] = 1
	text, err := toml.marshal(cfg, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(text), "title = \"t\"\ndebug = true\nratio = 0.5\n\n[[servers]]\nhost = \"a\"\nport = 1\ntags = [\"x\", \"y\"]\n\n[[servers]]\nhost = \"b\"\nport = 2\ntags = []\n\n[limits]\nm = 1\n\n[inner]\nlabel = \"n\"\n")
}

@(test)
unmarshal_reads_what_marshal_writes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "title = \"t\" # c\ndebug = true\nratio = 0.5\n[limits]\nm = 1\n[inner]\nlabel = \"n\"\n[[servers]]\nhost = \"a\"\nport = 0x10\ntags = [\"x\"]\n[[servers]]\nhost = \"b\"\n"
	cfg: Config
	err := toml.unmarshal(transmute([]u8)src, .Toml_1_1, &cfg, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, cfg.title, "t")
	testing.expect_value(t, cfg.debug, true)
	testing.expect_value(t, cfg.inner.name, "n")
	testing.expect_value(t, cfg.limits["m"], 1)
	testing.expect_value(t, len(cfg.servers), 2)
	testing.expect_value(t, cfg.servers[0].port, 16)
	testing.expect_value(t, cfg.servers[0].tags[0], "x")
	testing.expect_value(t, cfg.servers[1].host, "b")
	text, werr := toml.marshal(cfg, allocator = context.temp_allocator)
	walktest.expect_nil(t, werr)
	back: Config
	err = toml.unmarshal(text, .Toml_1_0, &back, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, back.servers[0].port, 16)
	testing.expect_value(t, back.inner.name, "n")
}

@(test)
unmarshal_reports_a_fault_of_the_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cfg: Config
	err := toml.unmarshal(transmute([]u8)string("a = \na = 1\n"), .Toml_1_0, &cfg, allocator = context.temp_allocator)
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Walk)
}

@(test)
marshal_refuses_a_value_that_is_no_table :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, err := toml.marshal(3, allocator = context.temp_allocator)
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Unsupported)
}

@(test)
a_plan_made_for_toml_writes_and_reads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plan, perr := toml.plan_make(Server, .Toml_1_0, reads = toml.reads(.Toml_1_0))
	defer typed.plan_destroy(&plan)
	walktest.expect_nil(t, perr)
	s := Server{"h", 2, {"a"}}
	text, err := plan.marshal(&plan, &s, {}, {}, context.temp_allocator, nil)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), "host = \"h\"\nport = 2\ntags = [\"a\"]\n")
	back: Server
	rerr := typed.unmarshal_text(text, &back, Server, &plan, {}, context.temp_allocator)
	walktest.expect_nil(t, rerr)
	testing.expect_value(t, back.host, "h")
}

// An array nested as deep as a text may nest it is written back on a thread with a quarter of the 1 MB a Windows thread
// has: the writer's stack of open arrays and inline tables does not grow the native one.
@(test)
a_deep_inline_value_is_written_on_a_small_stack :: proc(t: ^testing.T) {
	walktest.on_small_stack(t, proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)
		levels := core.MAX_DEPTH - 2
		value := strings.concatenate({strings.repeat("[", levels, context.temp_allocator), "1", strings.repeat("]", levels, context.temp_allocator)}, context.temp_allocator)
		text := strings.concatenate({"a = ", value, "\n"}, context.temp_allocator)
		doc, err := core.build(transmute([]u8)text, toml.as(.Toml_1_0))
		defer core.destroy(&doc)
		if !walktest.expect_nil(t, err) {
			return
		}
		out, werr := written(&doc)
		walktest.expect_nil(t, werr)
		testing.expect_value(t, out, text)
	})
}
