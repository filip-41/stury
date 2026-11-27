// Streaming `json.check` vs `check.check_document(json.build)` parity across JSON, JSONC, and JSON5.
package json_tests

import "core:testing"
import "stury:json"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"
import "stury:testkit"

@(private = "file")
make_user_plan :: proc(t: ^testing.T) -> check.Plan {
	d: rules.Description
	d.allocator = context.allocator
	defer rules.description_destroy(&d)

	name_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.String}, rules = {min_length = 1}, array = -1, object = -1})
	age_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Integer}, rules = {minimum = "0", maximum = "150"}, array = -1, object = -1})
	false_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {}, array = -1, object = -1})

	members := make([]rules.Member, 2)
	members[0] = {name = "name", node = name_n, required = true}
	members[1] = {name = "age", node = age_n, required = true}
	append(&d.objects, rules.Object{members = members, additional = false_n, keys = rules.NONE})

	root := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})
	d.root = root

	plan, err := check.compile(&d)
	testing.expect_value(t, err.kind, check.Error_Kind.None)
	return plan
}

@(test)
test_json_check_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)
	plan := make_user_plan(t)
	defer check.plan_destroy(&plan)

	Case :: struct {
		spec:  json.Spec,
		input: string,
		valid: bool,
	}
	cases := [?]Case{
		{.Json, `{"name": "Alice", "age": 30}`, true},
		{.Json, `{"age": 30, "name": "Alice"}`, true},
		{.Json, `{"name": "", "age": 30}`, false},
		{.Json, `{"name": "Alice", "age": 200}`, false},
		{.Json, `{"name": "Alice", "age": 30, "extra": true}`, false},
		{.Jsonc, "// comment\n{\"name\": \"Bob\", /* block */ \"age\": 42,}", true},
		{.Jsonc, `{"name": "Bob", /* bad age */ "age": -5}`, false},
		{.Json5, `{name: 'Charlie', age: 0x10,}`, true},
		{.Json5, `{name: 'Charlie', age: 'nope'}`, false},
	}

	for c in cases {
		src := transmute([]u8)c.input
		r_s := json.check(src, &plan, c.spec)
		sink_s: check.Sink
		check.sink_init(&sink_s)
		r_ss := json.check(src, &plan, c.spec, {}, &sink_s)
		testkit.check_parity(t, &plan, json.reads(c.spec), json.as(c.spec), src, c.valid, r_s, r_ss, &sink_s)
	}
}
