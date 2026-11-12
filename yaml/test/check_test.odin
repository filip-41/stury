// The checks of a YAML text: a JSON Schema bound to the format, a model's load and dump, and a plan's check, each judging
// a scalar as the kind the core schema reads it as.
package yaml_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import core "../../core"
import rules "../../core/rules"
import typed "../../core/typed"
import schema "../../core/schema"
import json_pkg "../../json"
import yaml ".."
import model "../../core/model"
import walktest "../../walktest"

// The kinds and paths of a sink's entries, one after another.
@(private = "file")
spelled :: proc(s: ^typed.Sink) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for e in s.entries {
		fmt.sbprintf(&b, "%v", e.kind)
		for st in e.path {
			#partial switch x in st {
			case core.Name:
				fmt.sbprintf(&b, "/%s", string(x))
			case core.Index:
				fmt.sbprintf(&b, "/%d", int(x))
			}
		}
		fmt.sbprint(&b, ";")
	}
	return strings.to_string(b)
}

@(private = "file")
SCHEMA :: `{"type":"object","required":["name","port"],"properties":{"name":{"type":"string"},"port":{"type":"integer","minimum":1},"ratio":{"type":"number"},"tags":{"type":"array","items":{"type":"string"},"uniqueItems":true},"home":{"type":["string","null"]}},"additionalProperties":false}`

@(test)
a_schema_judges_a_text_by_the_core_schema :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	s, err := json_pkg.load_schema(transmute([]u8)string(SCHEMA))
	walktest.expect_nil(t, err)
	bound, berr := yaml.bind_schema(s, .Yaml_1_2)
	walktest.expect_nil(t, berr)
	good := [?]string {
		"name: web\nport: 0x1F\nratio: .5\ntags: [a, 'b']\nhome: ~\n",
		"{name: 'yes', port: !!int \"7\", tags: &t [x], home: /srv}\n",
		"# head\nport: 8080 # inline\nname: |\n  block\n",
	}
	for text in good {
		sink: typed.Sink
		refused := yaml.check_schema(&bound, transmute([]u8)text, &sink)
		testing.expectf(t, refused == nil && len(sink.entries) == 0, "%q: %v %s", text, refused, spelled(&sink))
	}
	bad := [?][2]string {
		{"name: 12\nport: 0\ntags: [a, 3]\nextra: ~\n", "Wrong_Kind/name;Below_Minimum/port;Wrong_Kind/tags/1;Not_Allowed/extra;"},
		{"name: yes\nport: 1.5\n", "Wrong_Kind/port;"},
		{"port: 1\ntags: [a, a]\n", "Missing_Field;Not_Unique/tags;"},
		{"- name\n- port\n", "Wrong_Kind;"},
	}
	for c in bad {
		sink: typed.Sink
		refused := yaml.check_schema(&bound, transmute([]u8)c[0], &sink)
		testing.expectf(t, refused != nil && spelled(&sink) == c[1], "%q: %v\n got %s\nwant %s", c[0], refused, spelled(&sink), c[1])
		// The built document is judged as its text is.
		doc, derr := yaml.build(transmute([]u8)c[0], .Yaml_1_2)
		walktest.expect_nil(t, derr)
		nodes: typed.Sink
		testing.expect(t, schema.check_node(&bound, &doc, core.ROOT, &nodes) != nil)
		testing.expectf(t, spelled(&nodes) == c[1], "%q built:\n got %s\nwant %s", c[0], spelled(&nodes), c[1])
	}
	for text in good {
		doc, derr := yaml.build(transmute([]u8)text, .Yaml_1_2)
		walktest.expect_nil(t, derr)
		walktest.expect_nil(t, schema.check_node(&bound, &doc, core.ROOT))
	}
	// A text that does not read is its fault, and an alias is judged as the value it repeats.
	fault := yaml.check_schema(&bound, transmute([]u8)string("name: [x\n"))
	_, faulted := fault.(core.Fault)
	testing.expectf(t, faulted, "%v", fault)
	sink: typed.Sink
	refused := yaml.check_schema(&bound, transmute([]u8)string("name: &n 5\nport: *n\nhome: *n\n"), &sink)
	testing.expectf(t, refused != nil && spelled(&sink) == "Wrong_Kind/name;Wrong_Kind/home;", "%v %s", refused, spelled(&sink))
}

@(private = "file")
Server :: struct {
	name: string `model:"len>=2"`,
	port: int `model:">=1"`,
	tags: []string `model:"optional"`,
	home: Maybe(string) `model:"optional"`,
}

@(test)
a_model_loads_and_dumps_a_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	m, err := model.compile(&reg, Server, yaml.checks(.Yaml_1_2))
	walktest.expect_nil(t, err)
	v: Server
	sink: typed.Sink
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string("name: web\nport: 0o17\ntags:\n  - a\n  - b c\nhome: ~\n"), &v, &sink))
	testing.expect_value(t, len(sink.entries), 0)
	testing.expect(t, v.name == "web" && v.port == 15 && len(v.tags) == 2 && v.tags[1] == "b c" && v.home == nil)
	text, derr := model.dump(&m, &v, write = yaml.PRETTY)
	walktest.expect_nil(t, derr)
	testing.expect_value(t, string(text), "name: web\nport: 15\ntags:\n  - a\n  - b c\nhome: null\n")

	bad: Server
	refused := model.load(&m, transmute([]u8)string("name: w\nport: 0\n"), &bad, &sink)
	testing.expect(t, refused != nil)
	testing.expect_value(t, spelled(&sink), "Too_Short/name;Below_Minimum/port;")
	// A load refuses a repeated key under its own default and under `.Refuse`, and any other policy is no YAML read.
	repeated := transmute([]u8)string("name: web\nname: web\nport: 1\n")
	fault, faulted := model.load(&m, repeated, &bad).(core.Fault)
	testing.expect(t, faulted && fault.detail == u8(yaml.Detail.Duplicate_Key))
	walktest.expect_kind(t, model.load(&m, repeated, &bad, opts = {dups = .Last}), core.Typed_Error_Kind.Bad_Option)
}

@(test)
a_plan_checks_a_text_and_a_document :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	Pair :: struct {
		a: int,
		b: []int,
	}
	plan, perr := yaml.plan_make(Pair, .Yaml_1_2)
	walktest.expect_nil(t, perr)
	src := transmute([]u8)string("a: x\nb: [1, y]\n")
	v: Pair
	sink: typed.Sink
	refused := yaml.check(src, .Yaml_1_2, &v, &plan, {sink = &sink})
	testing.expect(t, refused != nil)
	testing.expect_value(t, spelled(&sink), "Wrong_Kind/a;Wrong_Kind/b/1;")
	spec := yaml.Spec.Yaml_1_2
	again: Pair
	other: typed.Sink
	testing.expect(t, yaml.check(src, spec, &again, &plan, {sink = &other}) != nil)
	testing.expect_value(t, spelled(&other), "Wrong_Kind/a;Wrong_Kind/b/1;")
	good: Pair
	walktest.expect_nil(t, yaml.check(transmute([]u8)string("a: 1\nb: [2]\n"), .Yaml_1_2, &good, &plan))
	testing.expect(t, good.a == 1 && len(good.b) == 1)

	// A plan made with the reads `checks` gives checks a text and a built document through `core/typed`.
	bound, berr := yaml.plan_make(Pair, .Yaml_1_2, reads = yaml.checks(.Yaml_1_2).reads)
	walktest.expect_nil(t, berr)
	held: Pair
	texts: typed.Sink
	testing.expect(t, typed.check_text(src, &held, Pair, &bound, {sink = &texts}) != nil)
	testing.expect_value(t, spelled(&texts), "Wrong_Kind/a;Wrong_Kind/b/1;")
	doc, derr := yaml.build(src, .Yaml_1_2)
	walktest.expect_nil(t, derr)
	b, _ := core.member(&doc, core.ROOT, "b")
	ints, ierr := yaml.plan_make([]int, .Yaml_1_2, reads = yaml.checks(.Yaml_1_2).reads)
	walktest.expect_nil(t, ierr)
	list: []int
	nodes: typed.Sink
	testing.expect(t, typed.check_document(&doc, b, &list, []int, &ints, {sink = &nodes}) != nil)
	testing.expect_value(t, spelled(&nodes), "Wrong_Kind/1;")

	// A node of a built document reads as its text does: a plain scalar is the kind the core schema reads it as.
	held_doc, herr := yaml.build(transmute([]u8)string("a: 1\nb: [2, 0x10, !!int '7']\nc: {on: True, off: ~, s: yes}\n"), .Yaml_1_2)
	walktest.expect_nil(t, herr)
	whole: Pair
	walktest.expect_nil(t, typed.unmarshal(&held_doc, core.ROOT, &whole, &plan))
	testing.expect(t, whole.a == 1 && len(whole.b) == 3 && whole.b[1] == 16 && whole.b[2] == 7)
	second, _ := core.member(&held_doc, core.ROOT, "b")
	part: []int
	walktest.expect_nil(t, typed.unmarshal(&held_doc, second, &part, &ints))
	testing.expect(t, len(part) == 3 && part[0] == 2 && part[1] == 16 && part[2] == 7)
	Flags :: struct {
		on:  bool,
		off: Maybe(int),
		s:   string,
	}
	flags_plan, fperr := yaml.plan_make(Flags, .Yaml_1_2)
	walktest.expect_nil(t, fperr)
	third, _ := core.member(&held_doc, core.ROOT, "c")
	flags: Flags
	walktest.expect_nil(t, typed.unmarshal(&held_doc, third, &flags, &flags_plan))
	testing.expect(t, flags.on && flags.off == nil && flags.s == "yes")
	// The document keeps its scalars as it was built.
	testing.expect_value(t, held_doc.nodes[second + 1].kind, core.Kind.Plain)
}

// A handle chosen at run time holds the checks of its spec, so a schema bound to it with no reads judges a text and a
// built document as one bound to `yaml.checks` does.
@(test)
a_schema_binds_to_a_handle_chosen_at_run_time :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	s, err := json_pkg.load_schema(transmute([]u8)string(SCHEMA))
	walktest.expect_nil(t, err)
	spec := yaml.Spec.Yaml_1_2
	bound, berr := schema.bind(s, {nil, yaml.as(spec)})
	walktest.expect_nil(t, berr)
	walktest.expect_nil(t, schema.check(&bound, transmute([]u8)string("name: web\nport: 0x1F\n")))
	text := "name: 12\nport: 0\n"
	sink: typed.Sink
	testing.expect(t, schema.check(&bound, transmute([]u8)text, &sink) != nil)
	testing.expectf(t, spelled(&sink) == "Wrong_Kind/name;Below_Minimum/port;", "got %s", spelled(&sink))
	doc, derr := core.build(transmute([]u8)text, yaml.as(spec))
	walktest.expect_nil(t, derr)
	nodes: typed.Sink
	testing.expect(t, schema.check_node(&bound, &doc, core.ROOT, &nodes) != nil)
	testing.expectf(t, spelled(&nodes) == "Wrong_Kind/name;Below_Minimum/port;", "built: got %s", spelled(&nodes))
}

@(test)
a_plan_of_a_description_reads_yaml :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Server :: struct {
		name: string,
		port: int,
	}
	plan, _ := yaml.plan_make(Server, allocator = context.temp_allocator)
	m := model.Model(struct{}){plan = plan}
	m.plan.model_plan = .None
	d, derr := model.schema(&m, .Load, context.temp_allocator)
	walktest.expect_nil(t, derr)
	again, built := yaml.plan_of(&d, allocator = context.temp_allocator)
	walktest.expect_nil(t, built)
	testing.expect(t, again.read != nil || again.marshal != nil)
	_, empty := yaml.plan_of(&rules.Description{})
	walktest.expect_kind(t, empty, core.Typed_Error_Kind.Bad_Option)
}
