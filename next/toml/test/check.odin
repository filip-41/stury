// Streaming `toml.check` vs `check.check_document(toml.build)` parity across TOML 1.0 and 1.1.
package toml_tests

import "core:testing"
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
		sink_s: check.Sink
		check.sink_init(&sink_s)
		r_ss := toml.check(src, &plan, c.spec, {}, &sink_s)
		testkit.check_parity(t, &plan, toml.reads(c.spec), toml.as(c.spec), src, c.valid, r_s, r_ss, &sink_s)
	}
}

@(test)
test_toml_check_held_applicators_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)

	expect_parity :: proc(t: ^testing.T, plan: ^check.Plan, spec: toml.Spec, input: string, want_valid: bool, loc := #caller_location) {
		src := transmute([]u8)input
		r_s := toml.check(src, plan, spec)
		sink_s: check.Sink
		check.sink_init(&sink_s)
		r_ss := toml.check(src, plan, spec, {}, &sink_s)
		testkit.check_parity(t, plan, toml.reads(spec), toml.as(spec), src, want_valid, r_s, r_ss, &sink_s, check_err = true, loc = loc)
	}

	// 1. `contains` + `uniqueItems`
	{
		d: rules.Description
		d.allocator = context.allocator
		defer rules.description_destroy(&d)

		int_n := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {.Integer}, array = -1, object = -1})
		gt10_n := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {.Integer}, rules = {minimum = "10"}, array = -1, object = -1})
		arr_idx := i32(len(d.arrays))
		append(&d.arrays, rules.Array{items = int_n, contains = gt10_n})
		arr_n := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {.Array}, rules = {unique = true}, array = arr_idx, object = -1})
		members := make([]rules.Member, 1)
		members[0] = {name = "nums", node = arr_n, required = true}
		append(&d.objects, rules.Object{members = members, additional = rules.NONE, keys = rules.NONE})
		root := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})
		d.root = root

		plan, cerr := check.compile(&d)
		testing.expect_value(t, cerr.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		expect_parity(t, &plan, .Toml_1_0, "nums = [1, 12, 3]\n", true)
		expect_parity(t, &plan, .Toml_1_0, "nums = [1, 2, 3]\n", false)       // fails `contains`
		expect_parity(t, &plan, .Toml_1_0, "nums = [1, 12, 12]\n", false)     // fails `uniqueItems`
		expect_parity(t, &plan, .Toml_1_1, "nums = [10, 20, 30]\n", true)
	}

	// 2. `oneOf` + `anyOf` + `unevaluatedProperties: false`
	{
		d: rules.Description
		d.allocator = context.allocator
		defer rules.description_destroy(&d)

		str_n := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {.String}, array = -1, object = -1})
		int_n := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {.Integer}, array = -1, object = -1})
		bool_n := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {.Bool}, array = -1, object = -1})
		false_n := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {}, array = -1, object = -1})

		// `anyOf`: string or integer for `val`
		any_arms := make([]rules.Node_Index, 2)
		any_arms[0], any_arms[1] = str_n, int_n
		val_n := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = rules.EVERY_KIND, any_of = any_arms, array = -1, object = -1})

		// `oneOf`: {kind = "a", val = ...} vs {kind = "b", flag = bool}
		ka_n := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {.String}, const_of = "a", array = -1, object = -1})
		kb_n := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {.String}, const_of = "b", array = -1, object = -1})

		m_a := make([]rules.Member, 2)
		m_a[0] = {name = "kind", node = ka_n, required = true}
		m_a[1] = {name = "val", node = val_n, required = true}
		obj_a := i32(len(d.objects))
		append(&d.objects, rules.Object{members = m_a, additional = rules.NONE, keys = rules.NONE})
		arm_a := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = obj_a})

		m_b := make([]rules.Member, 2)
		m_b[0] = {name = "kind", node = kb_n, required = true}
		m_b[1] = {name = "flag", node = bool_n, required = true}
		obj_b := i32(len(d.objects))
		append(&d.objects, rules.Object{members = m_b, additional = rules.NONE, keys = rules.NONE})
		arm_b := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = obj_b})

		one_arms := make([]rules.Node_Index, 2)
		one_arms[0], one_arms[1] = arm_a, arm_b
		root := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{
			kinds = {.Object},
			one_of = one_arms,
			unevaluated_properties = false_n,
			array = -1,
			object = -1,
		})
		d.root = root

		plan, cerr := check.compile(&d)
		testing.expect_value(t, cerr.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		expect_parity(t, &plan, .Toml_1_0, "kind = \"a\"\nval = 42\n", true)
		expect_parity(t, &plan, .Toml_1_0, "kind = \"a\"\nval = \"hi\"\n", true)
		expect_parity(t, &plan, .Toml_1_0, "kind = \"b\"\nflag = true\n", true)
		expect_parity(t, &plan, .Toml_1_0, "kind = \"a\"\nval = true\n", false)               // fails `anyOf`
		expect_parity(t, &plan, .Toml_1_0, "kind = \"a\"\nval = 42\nextra = 1\n", false)       // fails `unevaluatedProperties: false`
		expect_parity(t, &plan, .Toml_1_1, "kind = \"b\"\nflag = false\nextra = 1\n", false)   // fails `unevaluatedProperties: false`
	}
}
