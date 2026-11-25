// Streaming `toml.check` vs `check.check_document(toml.build)` parity across TOML 1.0 and 1.1.
package toml_tests

import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"
import "stury:testkit"
import "stury:toml"

@(test)
test_toml_check_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)
	d: rules.Description
	d.allocator = context.allocator
	defer rules.description_destroy(&d)

	host_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.String}, rules = {min_length = 1}, array = -1, object = -1})
	port_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Integer}, rules = {minimum = "1", maximum = "65535"}, array = -1, object = -1})
	false_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {}, array = -1, object = -1})

	srv_members := make([]rules.Member, 2)
	srv_members[0] = {name = "host", node = host_n, required = true}
	srv_members[1] = {name = "port", node = port_n, required = true}
	append(&d.objects, rules.Object{members = srv_members, additional = false_n, keys = rules.NONE})

	srv_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})

	root_members := make([]rules.Member, 1)
	root_members[0] = {name = "server", node = srv_n, required = true}
	append(&d.objects, rules.Object{members = root_members, additional = false_n, keys = rules.NONE})

	root := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 1})
	d.root = root

	plan, cerr := check.compile(&d)
	testing.expect_value(t, cerr.kind, check.Error_Kind.None)
	defer check.plan_destroy(&plan)

	Case :: struct {
		spec:  toml.Spec,
		input: string,
		valid: bool,
	}
	cases := [?]Case{
		{.Toml_1_0, "[server]\nhost = \"localhost\"\nport = 8080\n", true},
		{.Toml_1_1, "server = {\n  host = \"127.0.0.1\",\n  port = 443,\n}\n", true},
		{.Toml_1_0, "[server]\nhost = \"localhost\"\nport = 70000\n", false},
		{.Toml_1_0, "[server]\nhost = \"localhost\"\n", false},
	}

	for c in cases {
		src := transmute([]u8)c.input
		r_s := toml.check(src, &plan, c.spec)
		defer check.result_destroy(&r_s)
		testing.expectf(t, r_s.valid == c.valid, "toml stream %v: got %v want %v", c.spec, r_s.valid, c.valid)

		sink_s: check.Sink
		check.sink_init(&sink_s)
		defer check.sink_destroy(&sink_s)
		r_ss := toml.check(src, &plan, c.spec, {}, &sink_s)
		defer check.result_destroy(&r_ss)
		testing.expect_value(t, r_ss.valid, c.valid)

		doc, berr := toml.build(src, c.spec)
		testing.expect_value(t, berr, nil)
		defer tape.destroy(&doc)

		r_d := check.check_document(&doc, &plan)
		defer check.result_destroy(&r_d)
		testing.expect_value(t, r_d.valid, c.valid)

		sink_d: check.Sink
		check.sink_init(&sink_d)
		defer check.sink_destroy(&sink_d)
		r_ds := check.check_document(&doc, &plan, {}, &sink_d)
		defer check.result_destroy(&r_ds)
		testing.expect_value(t, r_ds.valid, c.valid)
		testing.expect_value(t, len(sink_s.entries), len(sink_d.entries))
	}
}
