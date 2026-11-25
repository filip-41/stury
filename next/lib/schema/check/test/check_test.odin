// Comprehensive tests for `stury:lib/schema/check`: all JSON Schema 2020-12 keywords,
// 4-stage factored held objects (verdict + sink), duplicate keys, deep nesting, budgets, and concurrent shared Plan.
package check_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:thread"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

// Helper to build `rules.Description` concisely for unit tests.
@(private = "file")
Desc_Builder :: struct {
	d: rules.Description,
}

@(private = "file")
db_init :: proc(allocator := context.allocator) -> Desc_Builder {
	b: Desc_Builder
	b.d.allocator = allocator
	b.d.nodes.allocator = allocator
	b.d.arrays.allocator = allocator
	b.d.objects.allocator = allocator
	b.d.texts.allocator = allocator
	b.d.anchors.allocator = allocator
	b.d.names.allocator = allocator
	b.d.bases.allocator = allocator
	return b
}

@(private = "file")
db_node :: proc(b: ^Desc_Builder, n: rules.Node) -> rules.Node_Index {
	cp := n
	if cp.array == 0 && len(b.d.arrays) == 0 {
		cp.array = -1
	}
	if cp.object == 0 && len(b.d.objects) == 0 {
		cp.object = -1
	}
	idx := rules.Node_Index(len(b.d.nodes))
	append(&b.d.nodes, cp)
	return idx
}

@(private = "file")
make_node :: proc(kinds := rules.EVERY_KIND, r := rules.Rules{}) -> rules.Node {
	return rules.Node{kinds = kinds, rules = r, array = -1, object = -1}
}

@(private = "file")
db_obj :: proc(b: ^Desc_Builder, o: rules.Object) -> i32 {
	cp := o
	if len(o.members) > 0 {
		cp.members = make([]rules.Member, len(o.members), b.d.allocator)
		copy(cp.members, o.members)
	}
	if len(o.patterns) > 0 {
		cp.patterns = make([]rules.Pattern, len(o.patterns), b.d.allocator)
		copy(cp.patterns, o.patterns)
	}
	if len(o.dependents) > 0 {
		cp.dependents = make([]rules.Dependent, len(o.dependents), b.d.allocator)
		for dep, i in o.dependents {
			req_cp: []string
			if len(dep.required) > 0 {
				req_cp = make([]string, len(dep.required), b.d.allocator)
				copy(req_cp, dep.required)
			}
			cp.dependents[i] = {name = dep.name, required = req_cp, node = dep.node}
		}
	}
	idx := i32(len(b.d.objects))
	append(&b.d.objects, cp)
	return idx
}

@(private = "file")
db_arr :: proc(b: ^Desc_Builder, a: rules.Array) -> i32 {
	cp := a
	if len(a.prefix) > 0 {
		cp.prefix = make([]rules.Node_Index, len(a.prefix), b.d.allocator)
		copy(cp.prefix, a.prefix)
	}
	idx := i32(len(b.d.arrays))
	append(&b.d.arrays, cp)
	return idx
}

@(private = "file")
db_ids :: proc(b: ^Desc_Builder, ids: ..rules.Node_Index) -> []rules.Node_Index {
	out := make([]rules.Node_Index, len(ids), b.d.allocator)
	copy(out, ids)
	return out
}

@(private = "file")
db_vals :: proc(b: ^Desc_Builder, vals: ..rules.Value) -> []rules.Value {
	out := make([]rules.Value, len(vals), b.d.allocator)
	copy(out, vals)
	return out
}

// Verifies BOTH streaming `json.check` AND `check.check_document(json.build)` agree on verdict,
// both without sink and with sink!
@(private = "file")
expect_json :: proc(t: ^testing.T, plan: ^check.Plan, input: string, want_valid: bool, opts := check.Options{}, loc := #caller_location) {
	src := transmute([]u8)input

	// 1. Streaming verdict-only
	r1 := json.check(src, plan, .Json, opts)
	defer check.result_destroy(&r1)
	testing.expectf(t, r1.valid == want_valid, "stream verdict mismatch on %q: got valid=%v (err=%v), want %v", input, r1.valid, r1.err.kind, want_valid, loc = loc)

	// 2. Streaming with sink
	sink1: check.Sink
	check.sink_init(&sink1)
	defer check.sink_destroy(&sink1)
	r2 := json.check(src, plan, .Json, opts, &sink1)
	defer check.result_destroy(&r2)
	testing.expectf(t, r2.valid == want_valid, "stream sink mismatch on %q: got valid=%v (entries=%d), want %v", input, r2.valid, len(sink1.entries), want_valid, loc = loc)
	if !want_valid && r2.walk_err == nil && r2.err.kind != .Exceeded {
		testing.expectf(t, len(sink1.entries) > 0, "expected sink entries on invalid %q", input, loc = loc)
	}

	// 3. Document check parity (when build succeeds under same dups/budget)
	if opts.dups != .Refuse && opts.budget == {} {
		bopts := tape.Options{dups = opts.dups}
		doc, berr := json.build(src, .Json, bopts)
		if berr == nil {
			defer tape.destroy(&doc)
			r3 := check.check_document(&doc, plan, opts)
			defer check.result_destroy(&r3)
			testing.expectf(t, r3.valid == want_valid, "doc verdict mismatch on %q: got valid=%v, want %v", input, r3.valid, want_valid, loc = loc)

			sink2: check.Sink
			check.sink_init(&sink2)
			defer check.sink_destroy(&sink2)
			r4 := check.check_document(&doc, plan, opts, &sink2)
			defer check.result_destroy(&r4)
			testing.expectf(t, r4.valid == want_valid, "doc sink mismatch on %q: got valid=%v, want %v", input, r4.valid, want_valid, loc = loc)
			testing.expectf(t, len(sink1.entries) == len(sink2.entries), "sink count parity mismatch on %q: stream=%d doc=%d", input, len(sink1.entries), len(sink2.entries), loc = loc)
		}
	}
}

@(test)
test_scalar_and_bounds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Number with exclusiveMinimum: 0, maximum: 10, multipleOf: 0.5
	b := db_init()
	n := make_node({.Number}, {minimum = "0", exclusive_minimum = true, maximum = "10", multiple_of = "0.5"})
	b.d.root = db_node(&b, n)
	plan, cerr := check.compile(&b.d)
	testing.expect_value(t, cerr.kind, check.Error_Kind.None)
	// Destroy Description right after compile to prove Plan is 100% self-contained!
	rules.description_destroy(&b.d)
	defer check.plan_destroy(&plan)

	expect_json(t, &plan, `0.5`, true)
	expect_json(t, &plan, `10`, true)
	expect_json(t, &plan, `2.50`, true)
	expect_json(t, &plan, `0`, false)
	expect_json(t, &plan, `-1`, false)
	expect_json(t, &plan, `10.5`, false)
	expect_json(t, &plan, `1.25`, false)
	expect_json(t, &plan, `"5"`, false)

	// Integer vs Draft 4 integer_spelled
	b2 := db_init()
	ni := make_node({.Integer})
	b2.d.root = db_node(&b2, ni)
	p2, e2 := check.compile(&b2.d)
	testing.expect_value(t, e2.kind, check.Error_Kind.None)
	rules.description_destroy(&b2.d)
	defer check.plan_destroy(&p2)
	expect_json(t, &p2, `42`, true)
	expect_json(t, &p2, `42.0`, true)
	expect_json(t, &p2, `4.2e1`, true)
	expect_json(t, &p2, `42.5`, false)

	b3 := db_init()
	ni4 := make_node({.Integer})
	ni4.integer_spelled = true
	b3.d.root = db_node(&b3, ni4)
	p3, e3 := check.compile(&b3.d)
	testing.expect_value(t, e3.kind, check.Error_Kind.None)
	rules.description_destroy(&b3.d)
	defer check.plan_destroy(&p3)
	expect_json(t, &p3, `42`, true)
	expect_json(t, &p3, `42.0`, false)

	// String length (UTF-8 codepoints), pattern, format assertion
	b4 := db_init()
	ns := make_node({.String}, {min_length = 2, max_length = u64(5), pattern = "^[a-z]+$"})
	b4.d.root = db_node(&b4, ns)
	p4, e4 := check.compile(&b4.d)
	testing.expect_value(t, e4.kind, check.Error_Kind.None)
	rules.description_destroy(&b4.d)
	defer check.plan_destroy(&p4)
	expect_json(t, &p4, `"ab"`, true)
	expect_json(t, &p4, `"abcde"`, true)
	expect_json(t, &p4, `"a"`, false)
	expect_json(t, &p4, `"abcdef"`, false)
	expect_json(t, &p4, `"AB"`, false)

	// Format assertion vs annotation-only
	b5 := db_init()
	nf := make_node({.String}, {format = "email", assert_format = true})
	b5.d.root = db_node(&b5, nf)
	p5, e5 := check.compile(&b5.d)
	testing.expect_value(t, e5.kind, check.Error_Kind.None)
	rules.description_destroy(&b5.d)
	defer check.plan_destroy(&p5)
	expect_json(t, &p5, `"alice@example.com"`, true)
	expect_json(t, &p5, `"not-an-email"`, false)
}

@(test)
test_objects_arrays_and_keywords :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Object: properties {id: integer >= 1, name: string minLength 1}, required ["id"],
	// dependentRequired {"email": ["name"]}, additionalProperties: false, propertyNames: pattern "^[a-z]+$"
	b := db_init()
	id_n := db_node(&b, make_node({.Integer}, {minimum = "1"}))
	name_n := db_node(&b, make_node({.String}, {min_length = 1}))
	email_n := db_node(&b, make_node({.String}, {format = "email", assert_format = true}))
	false_n := db_node(&b, make_node({}))
	key_n := db_node(&b, make_node({.String}, {pattern = "^[a-z]+$"}))
	obj := db_obj(&b, rules.Object{
		members = {
			{name = "id", node = id_n, required = true},
			{name = "name", node = name_n},
			{name = "email", node = email_n},
		},
		additional = false_n,
		keys = key_n,
		dependents = {{name = "email", required = {"name"}}},
	})
	root := make_node({.Object})
	root.object = obj
	b.d.root = db_node(&b, root)

	plan, err := check.compile(&b.d)
	testing.expect_value(t, err.kind, check.Error_Kind.None)
	rules.description_destroy(&b.d)
	defer check.plan_destroy(&plan)

	expect_json(t, &plan, `{"id": 1}`, true)
	expect_json(t, &plan, `{"id": 2, "name": "Ada", "email": "ada@example.com"}`, true)
	// Out-of-order keys
	expect_json(t, &plan, `{"email": "ada@example.com", "name": "Ada", "id": 3}`, true)
	// Missing required "id"
	expect_json(t, &plan, `{"name": "Ada"}`, false)
	// dependentRequired violation ("email" without "name")
	expect_json(t, &plan, `{"id": 1, "email": "ada@example.com"}`, false)
	// additionalProperties: false violation
	expect_json(t, &plan, `{"id": 1, "extra": 9}`, false)
	// propertyNames violation
	expect_json(t, &plan, `{"id": 1, "BAD": 9}`, false)

	// Array: prefixItems [string, integer], items boolean, contains integer >= 10 (minContains 1, maxContains 2), uniqueItems
	ba := db_init()
	s_n := db_node(&ba, make_node({.String}))
	i_n := db_node(&ba, make_node({.Integer}))
	bool_n := db_node(&ba, make_node({.Bool}))
	big_n := db_node(&ba, make_node({.Integer}, {minimum = "10"}))
	arr := db_arr(&ba, rules.Array{
		prefix = {s_n, i_n},
		items = bool_n,
		contains = big_n,
		evaluates_contains = true,
		min_contains = u64(1),
		max_contains = u64(2),
	})
	aroot := make_node({.Array}, {unique = true, min_items = 2, max_items = u64(4)})
	aroot.array = arr
	ba.d.root = db_node(&ba, aroot)
	pa, ea := check.compile(&ba.d)
	testing.expect_value(t, ea.kind, check.Error_Kind.None)
	rules.description_destroy(&ba.d)
	defer check.plan_destroy(&pa)

	expect_json(t, &pa, `["ok", 10, true]`, true)
	expect_json(t, &pa, `["ok", 10, true, false]`, true)
	expect_json(t, &pa, `["ok", 10, true, true]`, false) // uniqueItems
	expect_json(t, &pa, `["ok", 5, true]`, false)        // contains >= 10 missing
	expect_json(t, &pa, `["ok", 10, "nope"]`, false)     // items must be boolean
	expect_json(t, &pa, `["ok"]`, false)                 // minItems 2
}

@(test)
test_applicators_refs_and_container_const_enum :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Container const & enum (numeric equivalence 1 == 1.0, key order independence)
	b := db_init()
	m1 := make([]rules.Member_Value, 2)
	m1[0] = {key = "a", value = i64(1)}
	m1[1] = {key = "b", value = "x"}
	defer delete(m1)
	cn := make_node()
	cn.const_of = rules.Value(m1)
	b.d.root = db_node(&b, cn)
	pc, ec := check.compile(&b.d)
	testing.expect_value(t, ec.kind, check.Error_Kind.None)
	rules.description_destroy(&b.d)
	defer check.plan_destroy(&pc)
	expect_json(t, &pc, `{"b": "x", "a": 1.0}`, true)
	expect_json(t, &pc, `{"a": 2, "b": "x"}`, false)

	// `if` / `then` / `else` + `not` on numbers
	b2 := db_init()
	test_n := db_node(&b2, make_node({.Number}, {minimum = "10"}))
	then_n := db_node(&b2, make_node({.Number}, {multiple_of = "5"}))
	else_n := db_node(&b2, make_node({.Number}, {multiple_of = "2"}))
	not_n := db_node(&b2, make_node({.Number}, {minimum = "20", maximum = "20"}))
	r2 := make_node({.Number})
	r2.cond = {test = test_n, then = then_n, other = else_n}
	r2.not = not_n
	b2.d.root = db_node(&b2, r2)
	p2, e2 := check.compile(&b2.d)
	testing.expect_value(t, e2.kind, check.Error_Kind.None)
	rules.description_destroy(&b2.d)
	defer check.plan_destroy(&p2)
	expect_json(t, &p2, `15`, true)
	expect_json(t, &p2, `14`, false) // >= 10 but not multiple of 5
	expect_json(t, &p2, `20`, false) // forbidden by `not`
	expect_json(t, &p2, `4`, true)
	expect_json(t, &p2, `3`, false)  // < 10 and not multiple of 2

	// Recursive `$ref` linked list: {val: integer, next?: $ref #}
	b3 := db_init()
	val_n := db_node(&b3, make_node({.Integer}))
	// Reserve root index 0 first, fill after.
	root_id := db_node(&b3, make_node({.Object}))
	ref_n := db_node(&b3, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, ref = root_id})
	o3 := db_obj(&b3, rules.Object{
		members = {
			{name = "val", node = val_n, required = true},
			{name = "next", node = ref_n},
		},
		additional = db_node(&b3, make_node({})),
		keys = rules.NONE,
	})
	b3.d.nodes[root_id].object = o3
	b3.d.root = root_id
	p3, e3 := check.compile(&b3.d)
	testing.expect_value(t, e3.kind, check.Error_Kind.None)
	rules.description_destroy(&b3.d)
	defer check.plan_destroy(&p3)
	expect_json(t, &p3, `{"val": 1, "next": {"val": 2, "next": {"val": 3}}}`, true)
	expect_json(t, &p3, `{"val": 1, "next": {"val": "bad"}}`, false)

	// `$dynamicRef` + `$dynamicAnchor` override across resources!
	b4 := db_init()
	// Outer resource (0) defines dynamic anchor "node" = string; inner resource (1) defines default "node" = integer,
	// and uses `$dynamicRef` pointing to inner's "node". Because outer resource is in scope, `$dynamicRef` resolves to string!
	outer_root := db_node(&b4, make_node())
	outer_anchor := db_node(&b4, make_node({.String}))
	inner_root := db_node(&b4, make_node())
	inner_anchor := db_node(&b4, make_node({.Integer}))
	b4.d.nodes[outer_root].resource = outer_root
	b4.d.nodes[outer_anchor].resource = outer_root
	b4.d.nodes[inner_root].resource = inner_root
	b4.d.nodes[inner_anchor].resource = inner_root
	b4.d.nodes[outer_root].ref = inner_root
	b4.d.nodes[inner_root].dynamic_ref = inner_anchor
	append(&b4.d.anchors,
		rules.Anchor{name = "node", resource = outer_root, node = outer_anchor},
		rules.Anchor{name = "node", resource = inner_root, node = inner_anchor},
	)
	b4.d.root = outer_root
	p4, e4 := check.compile(&b4.d)
	testing.expect_value(t, e4.kind, check.Error_Kind.None)
	rules.description_destroy(&b4.d)
	defer check.plan_destroy(&p4)
	expect_json(t, &p4, `"hello"`, true)
	expect_json(t, &p4, `123`, false)
}

@(test)
test_factored_stages_1_to_4 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Stage 1 + 2 + 3 + 4 combined factored object:
	// `oneOf`:
	//   arm 0: kind="user", name: string (required), patternProperties "^x-": integer, nested meta: {role: "admin"|"guest"}
	//   arm 1: kind="bot", token: string minLength 4 (required), additionalProperties: false
	// Plus `dependentSchemas`: when "audit" present -> requires "actor": string
	// Plus outer `unevaluatedProperties: false` and spine `maxProperties: 6`!
	b := db_init()
	false_n := db_node(&b, make_node({}))

	k_user := make_node({.String})
	k_user.const_of = "user"
	k_user_id := db_node(&b, k_user)

	k_bot := make_node({.String})
	k_bot.const_of = "bot"
	k_bot_id := db_node(&b, k_bot)

	str_n := db_node(&b, make_node({.String}, {min_length = 1}))
	tok_n := db_node(&b, make_node({.String}, {min_length = 4}))
	int_n := db_node(&b, make_node({.Integer}))

	// Nested factored object on `meta`: `oneOf: [{role: "admin", level: int}, {role: "guest"}]`
	r_admin := make_node({.String}); r_admin.const_of = "admin"
	r_guest := make_node({.String}); r_guest.const_of = "guest"
	m_arm0 := make_node({.Object})
	m_arm0.object = db_obj(&b, rules.Object{
		members = {
			{name = "role", node = db_node(&b, r_admin), required = true},
			{name = "level", node = int_n, required = true},
		},
		additional = false_n,
		keys = rules.NONE,
	})
	m_arm1 := make_node({.Object})
	m_arm1.object = db_obj(&b, rules.Object{
		members = {{name = "role", node = db_node(&b, r_guest), required = true}},
		additional = false_n,
		keys = rules.NONE,
	})
	meta_n := make_node({.Object})
	meta_n.one_of = db_ids(&b, db_node(&b, m_arm0), db_node(&b, m_arm1))
	meta_id := db_node(&b, meta_n)

	arm0 := make_node({.Object})
	arm0.object = db_obj(&b, rules.Object{
		members = {
			{name = "kind", node = k_user_id, required = true},
			{name = "name", node = str_n, required = true},
			{name = "meta", node = meta_id},
		},
		patterns = {{expression = "^x-", node = int_n}},
		additional = rules.NONE,
		keys = rules.NONE,
	})
	arm0_id := db_node(&b, arm0)

	arm1 := make_node({.Object})
	arm1.object = db_obj(&b, rules.Object{
		members = {
			{name = "kind", node = k_bot_id, required = true},
			{name = "token", node = tok_n, required = true},
		},
		additional = false_n,
		keys = rules.NONE,
	})
	arm1_id := db_node(&b, arm1)

	dep_audit := make_node({.Object})
	dep_audit.object = db_obj(&b, rules.Object{
		members = {
			{name = "audit", node = db_node(&b, make_node({.Bool}))},
			{name = "actor", node = str_n, required = true},
		},
		additional = rules.NONE,
		keys = rules.NONE,
	})
	dep_audit_id := db_node(&b, dep_audit)

	root := make_node({.Object}, {max_members = u64(6)})
	root.object = db_obj(&b, rules.Object{
		additional = rules.NONE,
		keys = rules.NONE,
		dependents = {{name = "audit", node = dep_audit_id}},
	})
	root.one_of = db_ids(&b, arm0_id, arm1_id)
	root.unevaluated_properties = false_n
	b.d.root = db_node(&b, root)

	plan, err := check.compile(&b.d)
	testing.expect_value(t, err.kind, check.Error_Kind.None)
	// Assert that BOTH root AND nested `meta` compiled into a 4-stage `Factor`!
	testing.expect(t, plan.uses[0].factor != nil, "expected root held object to compile into a Factor")
	rules.description_destroy(&b.d)
	defer check.plan_destroy(&plan)

	// Valid Stage 1/2/3/4 cases
	expect_json(t, &plan, `{"kind": "user", "name": "Filip", "x-age": 30, "meta": {"role": "admin", "level": 9}}`, true)
	expect_json(t, &plan, `{"kind": "user", "name": "Guest", "meta": {"role": "guest"}}`, true)
	expect_json(t, &plan, `{"kind": "bot", "token": "abcd1234"}`, true)
	expect_json(t, &plan, `{"kind": "user", "name": "Ada", "audit": true, "actor": "sys"}`, true)

	// Invalid cases (both verdict-only AND sink reread-by-runs!)
	expect_json(t, &plan, `{"kind": "user", "name": "Filip", "x-age": "bad"}`, false)                     // patternProperties value fail
	expect_json(t, &plan, `{"kind": "user", "name": "Filip", "stray": 1}`, false)                         // unevaluatedProperties: false fail
	expect_json(t, &plan, `{"kind": "bot", "token": "abcd", "extra": 1}`, false)                          // arm1 additionalProperties: false fail
	expect_json(t, &plan, `{"kind": "bot", "token": "ab"}`, false)                                        // token minLength 4 fail
	expect_json(t, &plan, `{"kind": "user", "name": "Filip", "meta": {"role": "admin"}}`, false)          // nested factored missing level
	expect_json(t, &plan, `{"kind": "user", "name": "Ada", "audit": true}`, false)                        // dependentSchemas missing actor
	expect_json(t, &plan, `{"kind": "user", "name": "A", "x-1": 1, "x-2": 2, "x-3": 3, "x-4": 4, "x-5": 5}`, false) // spine maxProperties: 6
	expect_json(t, &plan, `{"kind": "unknown"}`, false)                                                   // discriminator fail (factor_doomed)
}

@(test)
test_unevaluated_items_and_properties :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// `unevaluatedItems: false` with `prefixItems: [string]` and `anyOf: [{contains: {type: integer}}]` (evaluates_contains = true)
	b := db_init()
	str_n := db_node(&b, make_node({.String}))
	int_n := db_node(&b, make_node({.Integer}))
	false_n := db_node(&b, make_node({}))

	contains_arm := make_node({.Array})
	contains_arm.array = db_arr(&b, rules.Array{items = rules.NONE, contains = int_n, evaluates_contains = true})
	root := make_node({.Array})
	root.array = db_arr(&b, rules.Array{prefix = {str_n}, items = rules.NONE})
	root.all_of = db_ids(&b, db_node(&b, contains_arm))
	root.unevaluated_items = false_n
	b.d.root = db_node(&b, root)

	plan, err := check.compile(&b.d)
	testing.expect_value(t, err.kind, check.Error_Kind.None)
	rules.description_destroy(&b.d)
	defer check.plan_destroy(&plan)

	expect_json(t, &plan, `["head", 1, 2]`, true)
	expect_json(t, &plan, `["head", 1, "extra"]`, false) // index 2 not evaluated by prefixItems or contains
}

@(test)
test_duplicate_keys_and_budgets :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := db_init()
	int_n := db_node(&b, make_node({.Integer}))
	root := make_node({.Object})
	root.object = db_obj(&b, rules.Object{
		members = {{name = "a", node = int_n, required = true}},
		additional = rules.NONE,
		keys = rules.NONE,
	})
	b.d.root = db_node(&b, root)
	plan, err := check.compile(&b.d)
	testing.expect_value(t, err.kind, check.Error_Kind.None)
	rules.description_destroy(&b.d)
	defer check.plan_destroy(&plan)

	// `.Last` (default): last "a" is 42 -> valid!
	expect_json(t, &plan, `{"a": "bad", "a": 42}`, true, {dups = .Last})
	// `.First`: first "a" is "bad" -> invalid!
	expect_json(t, &plan, `{"a": "bad", "a": 42}`, false, {dups = .First})
	// `.First`: first "a" is 42 -> valid!
	expect_json(t, &plan, `{"a": 42, "a": "bad"}`, true, {dups = .First})
	// `.Refuse`: duplicate key anywhere (even in skipped extra member!) -> Duplicate_Key!
	ref_src := `{"a": 1, "skip": {"x": 1, "x": 2}}`
	r_ref := json.check(transmute([]u8)ref_src, &plan, .Json, {dups = .Refuse})
	defer check.result_destroy(&r_ref)
	testing.expect(t, !r_ref.valid, "expected .Refuse to reject duplicate key inside skipped subtree")
	testing.expect_value(t, r_ref.err.kind, check.Error_Kind.Duplicate_Key)

	// Depth budget exhaustion
	deep_b := strings.builder_make()
	defer strings.builder_destroy(&deep_b)
	for _ in 0 ..< 150 {
		strings.write_byte(&deep_b, '[')
	}
	strings.write_byte(&deep_b, '1')
	for _ in 0 ..< 150 {
		strings.write_byte(&deep_b, ']')
	}
	deep_src := transmute([]u8)strings.to_string(deep_b)

	// Schema accepting nested arrays recursively
	bd := db_init()
	any_arr := db_node(&bd, make_node({.Array, .Integer}))
	arr_d := db_arr(&bd, rules.Array{items = any_arr})
	bd.d.nodes[any_arr].array = arr_d
	bd.d.root = any_arr
	pd, ed := check.compile(&bd.d)
	testing.expect_value(t, ed.kind, check.Error_Kind.None)
	rules.description_destroy(&bd.d)
	defer check.plan_destroy(&pd)

	// 150 levels passes with default depth!
	r_deep_ok := json.check(deep_src, &pd)
	defer check.result_destroy(&r_deep_ok)
	testing.expect(t, r_deep_ok.valid, "expected 150-level nested array to pass")

	// 150 levels fails with `budget.depth = 32`!
	r_deep_lim := json.check(deep_src, &pd, .Json, {budget = {depth = 32}})
	defer check.result_destroy(&r_deep_lim)
	testing.expect(t, !r_deep_lim.valid && r_deep_lim.err.kind == .Exceeded, "expected depth budget exceeded")

	// Node budget exhaustion
	r_nodes := json.check(deep_src, &pd, .Json, {budget = {nodes = 10}})
	defer check.result_destroy(&r_nodes)
	testing.expect(t, !r_nodes.valid && r_nodes.err.kind == .Exceeded, "expected node budget exceeded")

	// Steps budget exhaustion
	r_steps := json.check(deep_src, &pd, .Json, {budget = {steps = 5}})
	defer check.result_destroy(&r_steps)
	testing.expect(t, !r_steps.valid && r_steps.err.kind == .Exceeded, "expected steps budget exceeded")
}

@(test)
test_concurrent_shared_plan :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Build a factored discriminated union plan and share it read-only across 4 concurrent worker threads!
	b := db_init()
	false_n := db_node(&b, make_node({}))
	ka := make_node({.String}); ka.const_of = "a"
	kb := make_node({.String}); kb.const_of = "b"
	arm_a := make_node({.Object})
	arm_a.object = db_obj(&b, rules.Object{
		members = {
			{name = "t", node = db_node(&b, ka), required = true},
			{name = "x", node = db_node(&b, make_node({.Integer}, {minimum = "0"})), required = true},
		},
		additional = false_n,
		keys = rules.NONE,
	})
	arm_b := make_node({.Object})
	arm_b.object = db_obj(&b, rules.Object{
		members = {
			{name = "t", node = db_node(&b, kb), required = true},
			{name = "y", node = db_node(&b, make_node({.String}, {pattern = "^[a-z]+$"})), required = true},
		},
		additional = false_n,
		keys = rules.NONE,
	})
	root := make_node({.Object})
	root.one_of = db_ids(&b, db_node(&b, arm_a), db_node(&b, arm_b))
	b.d.root = db_node(&b, root)

	plan, err := check.compile(&b.d)
	testing.expect_value(t, err.kind, check.Error_Kind.None)
	rules.description_destroy(&b.d)
	defer check.plan_destroy(&plan)

	Worker_Data :: struct {
		plan: ^check.Plan,
		ok:   bool,
	}
	worker :: proc(th: ^thread.Thread) {
		d := (^Worker_Data)(th.data)
		ok := true
		for i in 0 ..< 200 {
			s1 := fmt.tprintf(`{{"t":"a","x":%d}}`, i)
			r1 := json.check(transmute([]u8)s1, d.plan)
			if !r1.valid {
				ok = false
			}
			check.result_destroy(&r1)

			s2 := `{"t":"b","y":"hello"}`
			r2 := json.check(transmute([]u8)s2, d.plan)
			if !r2.valid {
				ok = false
			}
			check.result_destroy(&r2)

			sink: check.Sink
			check.sink_init(&sink)
			s3 := `{"t":"b","y":"BAD123"}`
			r3 := json.check(transmute([]u8)s3, d.plan, .Json, {}, &sink)
			if r3.valid || len(sink.entries) == 0 {
				ok = false
			}
			check.result_destroy(&r3)
			check.sink_destroy(&sink)
			free_all(context.temp_allocator)
		}
		d.ok = ok
	}

	N :: 4
	data: [N]Worker_Data
	threads: [N]^thread.Thread
	for i in 0 ..< N {
		data[i] = {plan = &plan}
		threads[i] = thread.create(worker)
		threads[i].data = &data[i]
		thread.start(threads[i])
	}
	for i in 0 ..< N {
		thread.join(threads[i])
		thread.destroy(threads[i])
		testing.expect(t, data[i].ok, "concurrent shared Plan worker failed")
	}
}

@(test)
test_review_regressions_part_a :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// A-C1: Heap-allocated Decimal bounds freed immediately after `compile` (caught under ASan if dangling!)
	{
		b := db_init()
		min_s := strings.clone("0.5")
		max_s := strings.clone("5.5")
		mul_s := strings.clone("0.25")
		b.d.root = db_node(&b, make_node({.Number}, {minimum = min_s, maximum = max_s, multiple_of = mul_s}))
		plan, err := check.compile(&b.d)
		delete(min_s)
		delete(max_s)
		delete(mul_s)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)
		expect_json(t, &plan, `0.75`, true)
		expect_json(t, &plan, `0.25`, false)
		expect_json(t, &plan, `1.1`, false)
	}

	// A-C2: Cyclic `$ref` through held `contains` and mutually recursive `anyOf`/`allOf`
	{
		b := db_init()
		root := db_node(&b, make_node({.Array}))
		ref_n := db_node(&b, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, ref = root})
		b.d.nodes[root].array = db_arr(&b, rules.Array{items = rules.NONE, contains = ref_n})
		b.d.root = root
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)
		expect_json(t, &plan, `[1]`, false)
		expect_json(t, &plan, `[[1]]`, false)
	}
	{
		// Recursive `anyOf`: `string` OR `{next: $ref #}`
		b := db_init()
		root := db_node(&b, make_node())
		str_n := db_node(&b, make_node({.String}))
		ref_n := db_node(&b, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, ref = root})
		obj_arm := make_node({.Object})
		obj_arm.object = db_obj(&b, rules.Object{
			members = {{name = "next", node = ref_n, required = true}},
			additional = rules.NONE,
			keys = rules.NONE,
		})
		b.d.nodes[root].any_of = db_ids(&b, str_n, db_node(&b, obj_arm))
		b.d.root = root
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)
		expect_json(t, &plan, `"leaf"`, true)
		expect_json(t, &plan, `{"next": {"next": "ok"}}`, true)
		expect_json(t, &plan, `{"next": 42}`, false)
	}

	// A-C3: Cyclic `$ref` + `unevaluatedProperties: false` must NOT drop evaluated properties
	{
		b := db_init()
		false_n := db_node(&b, make_node({}))
		int_n := db_node(&b, make_node({.Integer}))
		root := db_node(&b, make_node({.Object}))
		ref_n := db_node(&b, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, ref = root})
		base := make_node({.Object})
		base.object = db_obj(&b, rules.Object{
			members = {
				{name = "val", node = int_n, required = true},
				{name = "child", node = ref_n},
			},
			additional = rules.NONE,
			keys = rules.NONE,
		})
		b.d.nodes[root].all_of = db_ids(&b, db_node(&b, base))
		b.d.nodes[root].unevaluated_properties = false_n
		b.d.root = root
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)
		expect_json(t, &plan, `{"val": 1, "child": {"val": 2}}`, true)
		expect_json(t, &plan, `{"val": 1, "extra": 9}`, false)
	}

	// A-C4: `allOf` with conflicting asserted formats must enforce BOTH (never silently drop one!)
	{
		b := db_init()
		f1 := db_node(&b, make_node({.String}, {format = "email", assert_format = true}))
		f2 := db_node(&b, make_node({.String}, {format = "ipv4", assert_format = true}))
		root := make_node({.String})
		root.all_of = db_ids(&b, f1, f2)
		b.d.root = db_node(&b, root)
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)
		expect_json(t, &plan, `"alice@example.com"`, false)
		expect_json(t, &plan, `"192.168.0.1"`, false)
	}

	// A-C5: XML `.Group` repeated sibling elements in `uniqueItems`
	{
		b := db_init()
		root := make_node({.Object})
		item_arr := make_node({.Array}, {unique = true})
		root.object = db_obj(&b, rules.Object{
			members = {{name = "list", node = db_node(&b, item_arr)}},
			additional = rules.NONE,
			keys = rules.NONE,
		})
		b.d.root = db_node(&b, root)
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		// Compare two XML documents directly via `rules.value_equal` / `check_document`
		xdoc, xerr := xml.build(transmute([]u8)string(`<root><x>1</x><x>2</x></root>`))
		testing.expect(t, xerr == nil)
		defer tape.destroy(&xdoc)
		bc := db_init()
		cn := make_node()
		cn.const_of = rules.Node_Ref{&xdoc, tape.ROOT}
		bc.d.root = db_node(&bc, cn)
		pc, ec := check.compile(&bc.d)
		rules.description_destroy(&bc.d)
		testing.expect_value(t, ec.kind, check.Error_Kind.None)
		defer check.plan_destroy(&pc)

		r_same := xml.check(transmute([]u8)string(`<root><x>1</x><x>2</x></root>`), &pc)
		defer check.result_destroy(&r_same)
		testing.expect(t, r_same.valid, "expected matching XML repeated elements to pass const")

		r_diff := xml.check(transmute([]u8)string(`<root><x>1</x><x>9</x></root>`), &pc)
		defer check.result_destroy(&r_diff)
		testing.expect(t, !r_diff.valid, "expected differing second XML repeated element to fail const")
	}

	// A-H1: Non-finite `NaN`/`Infinity` (JSON5 & TOML) and TOML underscored floats
	{
		b := db_init()
		b.d.root = db_node(&b, make_node({.Number}, {minimum = "0", maximum = "2000"}))
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		r_nan := json.check(transmute([]u8)string(`NaN`), &plan, .Json5)
		defer check.result_destroy(&r_nan)
		testing.expect(t, !r_nan.valid)

		r_inf := json.check(transmute([]u8)string(`Infinity`), &plan, .Json5)
		defer check.result_destroy(&r_inf)
		testing.expect(t, !r_inf.valid)

		r_dot := json.check(transmute([]u8)string(`.5`), &plan, .Json5)
		defer check.result_destroy(&r_dot)
		testing.expect(t, r_dot.valid)

		r_plus := json.check(transmute([]u8)string(`+1.5`), &plan, .Json5)
		defer check.result_destroy(&r_plus)
		testing.expect(t, r_plus.valid)
	}
	{
		// TOML `.All` refused as `.Bad_Option` (A-H5), and TOML underscored float precision
		b := db_init()
		num_n := db_node(&b, make_node({.Number}, {minimum = "1000.25", maximum = "1000.25"}))
		root := make_node({.Object})
		root.object = db_obj(&b, rules.Object{
			members = {{name = "v", node = num_n, required = true}},
			additional = rules.NONE,
			keys = rules.NONE,
		})
		b.d.root = db_node(&b, root)
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		r_all := toml.check(transmute([]u8)string("v = 1_000.25\n"), &plan, .Toml_1_0, {dups = .All})
		defer check.result_destroy(&r_all)
		testing.expect_value(t, r_all.err.kind, check.Error_Kind.Bad_Option)

		r_ok := toml.check(transmute([]u8)string("v = 1_000.25\n"), &plan)
		defer check.result_destroy(&r_ok)
		testing.expect(t, r_ok.valid)

		r_tnan := toml.check(transmute([]u8)string("v = nan\n"), &plan)
		defer check.result_destroy(&r_tnan)
		testing.expect(t, !r_tnan.valid)
	}

	// A-H4: DSV `.Refuse` with tight `Budget.memory` maps to `.Exceeded` (NOT `.Duplicate_Key`)
	{
		b := db_init()
		b.d.root = db_node(&b, make_node({.Array}))
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		for i in 0 ..< 80 {
			if i > 0 {
				strings.write_byte(&sb, ',')
			}
			fmt.sbprintf(&sb, "col_%d", i)
		}
		strings.write_byte(&sb, '\n')
		for i in 0 ..< 80 {
			if i > 0 {
				strings.write_byte(&sb, ',')
			}
			strings.write_byte(&sb, '1')
		}
		r_mem := dsv.check(transmute([]u8)strings.to_string(sb), &plan, .Csv, {dups = .Refuse, budget = {memory = 64}})
		defer check.result_destroy(&r_mem)
		testing.expect(t, !r_mem.valid)
		testing.expect_value(t, r_mem.err.kind, check.Error_Kind.Exceeded)
	}
}

@(test)
test_review_regressions_part_b :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// B-C1 & B-C2: Factored object under `dups = .Refuse` with `sink != nil`, plus early-doomed `err.kind == .No_Arm`!
	{
		b := db_init()
		false_n := db_node(&b, make_node({}))
		ka := make_node({.String}); ka.const_of = "a"
		kb := make_node({.String}); kb.const_of = "b"
		arm_a := make_node({.Object})
		arm_a.object = db_obj(&b, rules.Object{
			members = {
				{name = "k", node = db_node(&b, ka), required = true},
				{name = "x", node = db_node(&b, make_node({.Integer})), required = true},
			},
			additional = false_n,
			keys = rules.NONE,
		})
		arm_b := make_node({.Object})
		arm_b.object = db_obj(&b, rules.Object{
			members = {
				{name = "k", node = db_node(&b, kb), required = true},
				{name = "y", node = db_node(&b, make_node({.String})), required = true},
			},
			additional = false_n,
			keys = rules.NONE,
		})
		root := make_node({.Object})
		root.one_of = db_ids(&b, db_node(&b, arm_a), db_node(&b, arm_b))
		b.d.root = db_node(&b, root)
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		testing.expect(t, plan.uses[0].factor != nil)
		defer check.plan_destroy(&plan)

		// B-C2: early-doomed factored failure records `.No_Arm` (NOT `.None`!)
		r_doom := json.check(transmute([]u8)string(`{"k": "unknown", "x": 1}`), &plan)
		defer check.result_destroy(&r_doom)
		testing.expect(t, !r_doom.valid)
		testing.expect_value(t, r_doom.err.kind, check.Error_Kind.No_Arm)

		// B-C1: Refusing_Checker + sink != nil on factored failure rereads cleanly without UAF/crash
		sink: check.Sink
		check.sink_init(&sink)
		defer check.sink_destroy(&sink)
		r_ref := json.check(transmute([]u8)string(`{"k": "a", "x": "bad"}`), &plan, .Json, {dups = .Refuse}, &sink)
		defer check.result_destroy(&r_ref)
		testing.expect(t, !r_ref.valid)
		testing.expect(t, len(sink.entries) > 0)

		// B-C1: Refusing_Checker + sink != nil with duplicate key inside factored object reports `.Duplicate_Key`
		check.sink_clear(&sink)
		r_dup := json.check(transmute([]u8)string(`{"k": "a", "x": 1, "x": 2}`), &plan, .Json, {dups = .Refuse}, &sink)
		defer check.result_destroy(&r_dup)
		testing.expect(t, !r_dup.valid)
		testing.expect_value(t, r_dup.err.kind, check.Error_Kind.Duplicate_Key)
	}

	// B-C3: Inner `unevaluatedProperties: false` must NOT leak sibling arm's `additionalProperties` `eval_all`!
	{
		b := db_init()
		false_n := db_node(&b, make_node({}))
		int_n := db_node(&b, make_node({.Integer}))
		str_n := db_node(&b, make_node({.String}))

		// arm0: {properties: {a: int}, unevaluatedProperties: false}
		arm0 := make_node({.Object})
		arm0.object = db_obj(&b, rules.Object{
			members = {{name = "a", node = int_n, required = true}},
			additional = rules.NONE,
			keys = rules.NONE,
		})
		arm0.unevaluated_properties = false_n

		// arm1: {properties: {b: int}, additionalProperties: {type: string}}
		arm1 := make_node({.Object})
		arm1.object = db_obj(&b, rules.Object{
			members = {{name = "b", node = int_n, required = true}},
			additional = str_n,
			keys = rules.NONE,
		})

		root := make_node({.Object})
		root.any_of = db_ids(&b, db_node(&b, arm0), db_node(&b, arm1))
		b.d.root = db_node(&b, root)
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		expect_json(t, &plan, `{"a": 1}`, true)
		expect_json(t, &plan, `{"b": 2, "extra": "ok"}`, true)
		// MUST FAIL: arm1 fails (missing b), arm0 fails (extra is unevaluated by arm0)!
		expect_json(t, &plan, `{"a": 1, "extra": "ok"}`, false)
	}

	// B-C5: Sequential `.Expects` nested `instance_location` must preserve ancestor keys (`/user/age`, NOT `/age`)!
	{
		b := db_init()
		age_n := db_node(&b, make_node({.Integer}))
		user_n := make_node({.Object})
		user_n.object = db_obj(&b, rules.Object{
			members = {{name = "age", node = age_n, required = true}},
			additional = rules.NONE,
			keys = rules.NONE,
		})
		root := make_node({.Object})
		root.object = db_obj(&b, rules.Object{
			members = {{name = "user", node = db_node(&b, user_n), required = true}},
			additional = rules.NONE,
			keys = rules.NONE,
		})
		b.d.root = db_node(&b, root)
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		r := json.check(transmute([]u8)string(`{"user": {"age": "not-an-int"}}`), &plan)
		defer check.result_destroy(&r)
		testing.expect(t, !r.valid)
		testing.expect_value(t, r.err.instance_location, "/user/age")
	}

	// B-C7: Sibling `unevaluatedProperties: false` and `unevaluatedItems: false` do not alias in `Evaluates` cache
	{
		b := db_init()
		false_n := db_node(&b, make_node({}))
		int_n := db_node(&b, make_node({.Integer}))
		root := make_node({.Object, .Array})
		root.object = db_obj(&b, rules.Object{
			members = {{name = "a", node = int_n}},
			additional = rules.NONE,
			keys = rules.NONE,
		})
		root.array = db_arr(&b, rules.Array{prefix = {int_n}, items = rules.NONE})
		root.unevaluated_properties = false_n
		root.unevaluated_items = false_n
		b.d.root = db_node(&b, root)
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		expect_json(t, &plan, `{"a": 1}`, true)
		expect_json(t, &plan, `{"a": 1, "b": 2}`, false)
		expect_json(t, &plan, `[1]`, true)
		expect_json(t, &plan, `[1, 2]`, false)
	}

	// B-C6: `$ref` + `$dynamicRef` inside a factored arm preserves dynamic scope!
	{
		b := db_init()
		false_n := db_node(&b, make_node({}))
		outer_res := db_node(&b, make_node({.Object}))
		outer_anchor := db_node(&b, make_node({.String}))
		inner_res := db_node(&b, make_node({.Object}))
		inner_anchor := db_node(&b, make_node({.Integer}))
		dyn_ref_n := db_node(&b, make_node())
		b.d.nodes[dyn_ref_n].dynamic_ref = inner_anchor
		b.d.nodes[outer_res].resource = outer_res
		b.d.nodes[outer_anchor].resource = outer_res
		b.d.nodes[inner_res].resource = inner_res
		b.d.nodes[inner_anchor].resource = inner_res
		b.d.nodes[dyn_ref_n].resource = inner_res
		ka := make_node({.String}); ka.const_of = "a"
		kb := make_node({.String}); kb.const_of = "b"
		b.d.nodes[inner_res].object = db_obj(&b, rules.Object{
			members = {
				{name = "k", node = db_node(&b, ka), required = true},
				{name = "v", node = dyn_ref_n, required = true},
			},
			additional = false_n,
			keys = rules.NONE,
		})
		arm_b := make_node({.Object})
		arm_b.object = db_obj(&b, rules.Object{
			members = {
				{name = "k", node = db_node(&b, kb), required = true},
				{name = "v", node = db_node(&b, make_node({.Bool})), required = true},
			},
			additional = false_n,
			keys = rules.NONE,
		})
		ref_to_inner := db_node(&b, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, ref = inner_res, resource = outer_res})
		b.d.nodes[outer_res].any_of = db_ids(&b, ref_to_inner, db_node(&b, arm_b))
		append(&b.d.anchors,
			rules.Anchor{name = "val", resource = outer_res, node = outer_anchor},
			rules.Anchor{name = "val", resource = inner_res, node = inner_anchor},
		)
		b.d.root = outer_res
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		// Outer resource overrides dynamic anchor "val" to string -> `"hello"` passes, `123` fails!
		expect_json(t, &plan, `{"k": "a", "v": "hello"}`, true)
		expect_json(t, &plan, `{"k": "a", "v": 123}`, false)
		expect_json(t, &plan, `{"k": "b", "v": true}`, true)
	}

	// B-C8: Mixed-type `enum` inside factored object must accept all types in the enum!
	{
		b := db_init()
		false_n := db_node(&b, make_node({}))
		en := make_node()
		en.enum_of = db_vals(&b, "a", i64(1), true)
		en.has_enum = true
		arm0 := make_node({.Object})
		arm0.object = db_obj(&b, rules.Object{
			members = {{name = "v", node = db_node(&b, en), required = true}},
			additional = false_n,
			keys = rules.NONE,
		})
		arm1 := make_node({.Object})
		arm1.object = db_obj(&b, rules.Object{
			members = {{name = "w", node = db_node(&b, make_node({.String})), required = true}},
			additional = false_n,
			keys = rules.NONE,
		})
		root := make_node({.Object})
		root.any_of = db_ids(&b, db_node(&b, arm0), db_node(&b, arm1))
		b.d.root = db_node(&b, root)
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		expect_json(t, &plan, `{"v": "a"}`, true)
		expect_json(t, &plan, `{"v": 1}`, true)
		expect_json(t, &plan, `{"v": true}`, true)
		expect_json(t, &plan, `{"v": 2}`, false)
	}

	// B-C9: `Budget.memory` enforced on `Sink` and `first_arena`
	{
		b := db_init()
		b.d.root = db_node(&b, make_node({.Integer}))
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		r := json.check(transmute([]u8)string(`"bad"`), &plan, .Json, {budget = {memory = 16}})
		defer check.result_destroy(&r)
		testing.expect(t, !r.valid)
		testing.expect_value(t, r.err.kind, check.Error_Kind.Exceeded)
	}

	// B-C10: `check_document` refuses partial documents cleanly
	{
		b := db_init()
		b.d.root = db_node(&b, make_node({.Integer}))
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		doc, derr := json.build(transmute([]u8)string(`1`))
		testing.expect(t, derr == nil)
		defer tape.destroy(&doc)
		part := tape.Partial{}
		doc.partial = &part
		defer {
			doc.partial = nil
		}
		r := check.check_document(&doc, &plan)
		defer check.result_destroy(&r)
		testing.expect(t, !r.valid)
		testing.expect_value(t, r.err.kind, check.Error_Kind.Unsupported)
	}

	// B-H6: `oneOf` matching 2 arms & `contains` failing `minContains` must NOT export annotations!
	{
		b := db_init()
		false_n := db_node(&b, make_node({}))
		int_n := db_node(&b, make_node({.Integer}))
		// `contains` with `minContains: 2` + `unevaluatedItems: false`
		c_arm := make_node({.Array})
		c_arm.array = db_arr(&b, rules.Array{items = rules.NONE, contains = int_n, evaluates_contains = true, min_contains = u64(2)})
		root := make_node({.Array})
		root.any_of = db_ids(&b, db_node(&b, c_arm), db_node(&b, make_node({.Array})))
		root.unevaluated_items = false_n
		b.d.root = db_node(&b, root)
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		// `[1, 2]`: c_arm passes (>=2 ints), both items evaluated -> valid!
		expect_json(t, &plan, `[1, 2]`, true)
		// `[1]`: c_arm FAILS (only 1 int < minContains 2), second arm of anyOf passes without evaluating item 0 -> MUST FAIL unevaluatedItems!
		expect_json(t, &plan, `[1]`, false)
	}
	{
		// `oneOf` where 2 arms both pass: `oneOf` fails, so in `anyOf: [oneOf, {}]` + `unevaluatedProperties: false`,
		// `oneOf` must NOT export annotations!
		b := db_init()
		false_n := db_node(&b, make_node({}))
		int_n := db_node(&b, make_node({.Integer}))
		a1 := make_node({.Object})
		a1.object = db_obj(&b, rules.Object{members = {{name = "x", node = int_n}}, additional = rules.NONE, keys = rules.NONE})
		a2 := make_node({.Object})
		a2.object = db_obj(&b, rules.Object{members = {{name = "x", node = int_n}}, additional = rules.NONE, keys = rules.NONE})
		one_n := make_node({.Object})
		one_n.one_of = db_ids(&b, db_node(&b, a1), db_node(&b, a2))

		root := make_node({.Object})
		root.any_of = db_ids(&b, db_node(&b, one_n), db_node(&b, make_node({.Object})))
		root.unevaluated_properties = false_n
		b.d.root = db_node(&b, root)
		plan, err := check.compile(&b.d)
		rules.description_destroy(&b.d)
		testing.expect_value(t, err.kind, check.Error_Kind.None)
		defer check.plan_destroy(&plan)

		// `{"x": 1}` matches BOTH arms of `oneOf` -> `oneOf` FAILS -> `anyOf` passes via `{}` -> `"x"` is unevaluated -> MUST FAIL!
		expect_json(t, &plan, `{"x": 1}`, false)
	}
}
