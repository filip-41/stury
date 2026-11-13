// The check of a TOML text against a JSON Schema: one schema judges the same value alike in JSON and in TOML.
package toml_tests

import "core:strings"
import "core:testing"
import core "../../core"
import rules "../../core/rules"
import typed "../../core/typed"
import schema "../../core/schema"
import json_pkg "../../json"
import toml ".."
import model "../../core/model"
import walktest "../../walktest"

// The rendered failures of `text` against `schema_text`, each as the message, its path and its keyword path, one a line.
@(private = "file")
failures :: proc(schema_text: string, text: string, checks: typed.Format_Checks) -> (out: string, err: core.Error) {
	c, cerr := json_pkg.load_schema(transmute([]u8)schema_text)
	defer schema.destroy(c)
	if cerr != nil {
		return "", cerr
	}
	b, berr := schema.bind(c, checks)
	defer schema.unbind(&b)
	if berr != nil {
		return "", berr
	}
	src := transmute([]u8)text
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	err = schema.check(&b, src, &sink)
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

@(private = "file")
SERVER :: `{"type": "object", "required": ["id", "host"], "properties": {
	"id": {"type": "integer", "minimum": 1}, "host": {"type": "string", "maxLength": 3}, "ok": {"type": "boolean"},
	"load": {"type": "number", "maximum": 10}, "tags": {"type": "array", "items": {"type": "string"}, "maxItems": 2},
	"limits": {"type": "object", "additionalProperties": false, "properties": {"n": {"type": "integer"}}},
	"peers": {"type": "array", "items": {"type": "object", "required": ["name"]}}}}`

@(test)
check_one_schema_over_json_and_toml :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		json, toml: string,
		failures:   int,
	} {
		{`{"id": 1, "host": "abc", "ok": true, "load": 2.5, "tags": ["a", "b"], "limits": {"n": 1}, "peers": [{"name": "x"}]}`, "id = 1\nhost = \"abc\"\nok = true\nload = 2.5\ntags = [\"a\", \"b\"]\n\n[limits]\nn = 1\n\n[[peers]]\nname = \"x\"\n", 0},
		{`{"id": 0, "host": "abcd", "ok": "maybe", "load": 11, "tags": ["a", 1, "c"], "limits": {"n": 1.5, "x": 2}, "peers": [{"name": "x"}, {}]}`, "id = 0x0\nhost = 'abcd'\nok = \"maybe\"\nload = 1_1\ntags = [\"a\", 1, \"c\"]\n\n[limits]\nn = 1.5\nx = 2\n\n[[peers]]\nname = \"x\"\n\n[[peers]]\n", 9},
		{`{"host": "a"}`, "host = \"a\"\n", 1},
		{`{"id": 3, "host": "a", "limits": {"n": 2}, "tags": []}`, "limits.n = 2\nid = 3\nhost = \"a\"\ntags = []\n", 0},
	}
	for c in cases {
		want, werr := failures(SERVER, c.json, json_pkg.checks(.Json))
		got, gerr := failures(SERVER, c.toml, toml.checks(.Toml_1_0))
		testing.expectf(t, (werr == nil) == (gerr == nil), "%s: %v against %v", c.toml, gerr, werr)
		testing.expect_value(t, got, want)
		testing.expect_value(t, strings.count(want, "\n"), c.failures)
		later, _ := failures(SERVER, c.toml, toml.checks(.Toml_1_1))
		testing.expect_value(t, later, want)
	}
}

// A text the walk refuses is the one entry of its check.
@(test)
check_reports_a_fault_of_the_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	got, err := failures(SERVER, "id = 1\nid = 2\n", toml.checks(.Toml_1_0))
	_, faulted := err.(core.Fault)
	testing.expectf(t, faulted, "%v", err)
	testing.expect_value(t, strings.count(got, "\n"), 1)
}

// `bind_schema` binds a schema to the handle of a spec chosen at run time, and `check_schema` judges a text by it.
@(test)
bind_schema_checks_a_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	c, cerr := json_pkg.load_schema(transmute([]u8)string(SERVER))
	defer toml.destroy(c)
	testing.expect(t, cerr == nil)
	for spec in toml.Spec {
		b, berr := toml.bind_schema(c, spec)
		defer toml.destroy(&b)
		testing.expect(t, berr == nil)
		testing.expect(t, toml.check_schema(&b, transmute([]u8)string("id = 1\nhost = \"a\"\n")) == nil)
		testing.expect(t, toml.check_schema(&b, transmute([]u8)string("id = 1\nhost = \"abcd\"\n")) != nil)
	}
}

@(private = "file")
Peer :: struct {
	name: string `model:"len=1..=8"`,
	port: u16 `model:">=1024"`,
}

@(private = "file")
Service :: struct {
	title: string `model:"len>=1"`,
	ratio: f64 `model:"0..=1,optional"`,
	peers: []Peer `toml:"peer" model:"optional"`,
}

// A model compiled for TOML loads a text by its rules, with each failure at its path, and dumps what it loaded.
@(test)
a_model_loads_and_dumps_toml :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	m, compiled := model.compile(&reg, Service, toml.checks(.Toml_1_1))
	walktest.expect_nil(t, compiled)
	v: Service
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string("title = \"t\"\nratio = 0.5\n\n[[peer]]\nname = \"a\"\nport = 0x2000\n"), &v))
	testing.expect(t, v.title == "t" && v.ratio == 0.5 && len(v.peers) == 1 && v.peers[0].port == 0x2000)
	text, dumped := model.dump(&m, &v)
	walktest.expect_nil(t, dumped)
	testing.expect_value(t, string(text), "title = \"t\"\nratio = 0.5\n\n[[peer]]\nname = \"a\"\nport = 8192\n")
	bad: Service
	sink: typed.Sink
	refused := model.load(&m, transmute([]u8)string("title = \"\"\nratio = 2.0\n\n[[peer]]\nname = \"a\"\nport = 80\n"), &bad, &sink)
	testing.expect(t, refused != nil)
	testing.expect_value(t, len(sink.entries), 3)
}

// `check` gives every refusal of a text read by a plan, for either spec, and a plan made with the reads `checks` gives
// reads a text through `core/typed`.
@(test)
a_plan_checks_a_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	Pair :: struct {
		a: int,
		b: []int,
	}
	plan, perr := toml.plan_make(Pair, .Toml_1_1)
	walktest.expect_nil(t, perr)
	src := transmute([]u8)string("a = 'x'\nb = [1, 'y']\n")
	v: Pair
	sink: typed.Sink
	testing.expect(t, toml.check(src, .Toml_1_1, &v, &plan, {sink = &sink}) != nil)
	testing.expect_value(t, len(sink.entries), 2)
	spec := toml.Spec.Toml_1_0
	again: Pair
	other: typed.Sink
	testing.expect(t, toml.check(src, spec, &again, &plan, {sink = &other}) != nil)
	testing.expect_value(t, len(other.entries), 2)
	good: Pair
	walktest.expect_nil(t, toml.unmarshal(transmute([]u8)string("a = 1\nb = [2]\n"), spec, &good))
	testing.expect(t, good.a == 1 && len(good.b) == 1)
	read, rerr := toml.plan_make(Pair, .Toml_1_1, reads = toml.reads(.Toml_1_1))
	walktest.expect_nil(t, rerr)
	walktest.expect_nil(t, typed.unmarshal_text(transmute([]u8)string("a = 3\n"), &good, Pair, &read, {}))
	testing.expect_value(t, good.a, 3)
}

// A plan of a description reads TOML, and an empty description is refused.
@(test)
a_plan_of_a_description_reads_toml :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	m, compiled := model.compile(&reg, Service, toml.checks(.Toml_1_1))
	walktest.expect_nil(t, compiled)
	d, derr := model.schema(&m, .Load, context.temp_allocator)
	walktest.expect_nil(t, derr)
	plan, built := toml.plan_of(&d, .Toml_1_1, reads = toml.reads(.Toml_1_1))
	walktest.expect_nil(t, built)
	testing.expect(t, plan.read != nil && plan.marshal != nil)
	_, empty := toml.plan_of(&rules.Description{})
	walktest.expect_kind(t, empty, core.Typed_Error_Kind.Bad_Option)
}
