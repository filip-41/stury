#+feature dynamic-literals
package model_tests

import "base:runtime"
import "core:mem"
import "core:testing"
import core "../.."
import rules "../../rules"
import typed "../../typed"
import json "../../../json"
import model ".."
import testkit "../../../testkit"

// A type's description, bound as a check, judges the texts the type writes and reads.

@(private = "file")
Zoo_Inner :: struct {
	n: i32,
	s: string,
}

@(private = "file")
Zoo_Hooked :: distinct i32

@(private = "file")
Zoo_Color :: enum u8 {
	Red,
	Green,
}

@(private = "file")
Zoo :: struct {
	i_8:      i8,
	u_64:     u64,
	f_32:     f32,
	yes:      bool,
	s:        string,
	c:        cstring,
	req:      i32 `json:"req,required"`,
	inner:    Zoo_Inner,
	may:      Maybe(Zoo_Inner),
	ptr:      ^Zoo_Inner,
	list:     []i32,
	dyn:      [dynamic]string,
	fixed:    [3]i32,
	maybes:   []Maybe(string),
	by_name:  map[string]Zoo_Inner,
	by_int:   map[i32]bool,
	classed:  union {
		i64,
		string,
		[]i32,
	},
	no_nil:   union #no_nil {
		bool,
		f64,
	},
	raw:      typed.Raw,
	color:    Zoo_Color,
	colors:   bit_set[Zoo_Color],
	num_text: core.Number_Text,
	scalar:   typed.Scalar,
	hooked:   Zoo_Hooked,
	captured: struct {
		a:    i32,
		rest: map[string]typed.Raw `json:",unknown"`,
	},
}

@(private = "file")
read_zoo_hooked :: proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
	return nil
}

// Whether `src` passes the check `plan` of a description.
@(private = "file")
passes :: proc(plan: ^typed.Plan, src: string) -> bool {
	target: u8
	return typed.check_text(transmute([]u8)src, &target, nil, plan, {}) == nil
}

@(test)
a_types_description_checks_what_the_type_writes_and_reads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	hooks := []typed.Type_Hook{{type = Zoo_Hooked, read = read_zoo_hooked}}
	read_plan, planned := json.plan_make(Zoo, plan = {hooks = hooks}, allocator = context.temp_allocator)
	testkit.expect_nil(t, planned)
	d, described := testkit.description_of(&read_plan, context.temp_allocator)
	testkit.expect_nil(t, described)
	as := json.checks(.Json)
	check, built := typed.plan_of(&d, as.layout, as.reads, context.temp_allocator)
	testkit.expect_nil(t, built)

	inner := Zoo_Inner{1, "in"}
	filled := Zoo {
		i_8      = -3,
		u_64     = 1 << 40,
		f_32     = 1.5,
		yes      = true,
		s        = "text",
		c        = "cs",
		req      = 7,
		inner    = inner,
		may      = inner,
		ptr      = &inner,
		list     = []i32{1, 2},
		dyn      = {"a", "b"},
		fixed    = {1, 2, 3},
		maybes   = []Maybe(string){"x", nil},
		by_name  = {"k" = inner},
		by_int   = {4 = true},
		classed  = []i32{5},
		no_nil   = 2.5,
		raw      = typed.Raw("[1,{\"a\":null}]"),
		color    = .Green,
		colors   = {.Red},
		num_text = {"12", 12},
		scalar   = typed.Scalar(true),
		hooked   = 9,
		captured = {a = 1, rest = {"z" = typed.Raw("2")}},
	}
	named := filled
	named.classed = "named"
	for value, i in ([]Zoo{{}, filled, named}) {
		value := value
		out, wrote := json.marshal(value, allocator = context.temp_allocator)
		testkit.expect_nil(t, wrote)
		testing.expectf(t, passes(&check, string(out)), "value %d: %s", i, out)
	}

	wrong := [?]string {
		`[]`,
		`{"i_8":"x"}`,
		`{"list":{}}`,
		`{"classed":true}`,
		`{"color":"Blue"}`,
		`{"req":null}`,
		`{"by_int":{"1":"x"}}`,
		`{"inner":{"n":"x"}}`,
		`{"no_nil":null}`,
	}
	for text in wrong {
		zoo: Zoo
		refused := json.unmarshal(transmute([]u8)text, .Json, &zoo, allocator = context.temp_allocator) != nil
		testing.expectf(t, refused, "the type reads %s", text)
		testing.expectf(t, !passes(&check, text), "the description passes %s", text)
	}
}

@(test)
describe_and_plan_of_free_what_they_allocate :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	a := mem.tracking_allocator(&track)
	plan, _ := json.plan_make(Zoo, plan = {hooks = {{type = Zoo_Hooked, read = read_zoo_hooked}}}, allocator = a)
	d, described := testkit.description_of(&plan, a)
	testkit.expect_nil(t, described)
	as := json.checks(.Json)
	check, built := typed.plan_of(&d, as.layout, as.reads, a)
	testkit.expect_nil(t, built)
	typed.plan_destroy(&check)
	rules.description_destroy(&d)
	typed.plan_destroy(&plan)
	testing.expectf(t, len(track.allocation_map) == 0, "%d allocations live", len(track.allocation_map))
}

// Why `T`'s model does not compile.
refusal :: proc($T: typeid) -> core.Error {
	reg: model.Registry
	_, err := model.compile(&reg, T, json.checks(.Json), context.temp_allocator)
	return err
}

@(private = "file")
Ruled :: struct {
	a:     Maybe(string) `model:"len>=3"`,
	b:     Maybe(string),
	c:     Maybe(string) `model:"len>=3"`,
	small: i8,
	bits:  bit_set[0 ..< 8],
	keyed: map[i8]bool,
}

@(test)
two_members_of_one_type_with_different_rules_get_two_blocks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plain, _ := json.plan_make(Ruled, allocator = context.temp_allocator)
	plan := testkit.ruled_plan(Ruled)
	block :: proc(p: ^typed.Plan, member: i32) -> i32 {
		return p.meta[p.meta[0].block + member].block
	}
	testing.expect_value(t, block(&plain, 0), block(&plain, 1))
	testing.expect(t, block(&plan, 0) != block(&plan, 1))
	testing.expect_value(t, block(&plan, 0), block(&plan, 2))
	d, _ := testkit.description_of(&plan, context.temp_allocator)
	members := d.objects[d.nodes[d.root].object].members
	testing.expect_value(t, members[0].rules.min_length, 3)
	testing.expect_value(t, members[1].rules.min_length, 0)
	testing.expect_value(t, members[0].node, members[1].node)
	small := d.nodes[members[3].node].rules
	testing.expect_value(t, small.minimum, "-128")
	testing.expect_value(t, small.maximum, "127")
	bit := d.nodes[d.arrays[d.nodes[members[4].node].array].items].rules
	testing.expect_value(t, bit.maximum, "7")
	key := d.nodes[d.objects[d.nodes[members[5].node].object].keys]
	testing.expect_value(t, key.kinds, rules.Kinds{.String})
	testing.expect_value(t, key.rules.pattern, `^(?:-(?:(?:[0-9])|(?:[1-9][0-9])|1(?:[0-1][0-9]|2(?:[0-8])))|(?:[0-9])|(?:[1-9][0-9])|1(?:[0-1][0-9]|2(?:[0-7])))$`)
}

@(private = "file")
Rule_Inner :: struct {
	x: i32,
}

@(test)
a_model_tag_it_cannot_hold_refuses_the_plan :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Past_Max :: struct {
		s: string `model:"len>18446744073709551615"`,
	}
	Signed :: struct {
		s: string `model:"len>=+1_0"`,
	}
	Leading_Zero :: struct {
		s: string `model:"len>=01"`,
	}
	Flattened :: struct {
		using inner: Rule_Inner `model:">=1"`,
	}
	Capture :: struct {
		rest: map[string]typed.Raw `json:",unknown" model:">=1"`,
	}
	refusals := [?]core.Error{refusal(Past_Max), refusal(Signed), refusal(Leading_Zero), refusal(Flattened), refusal(Capture)}
	for err, i in refusals {
		testing.expectf(t, testkit.typed_kind(err) == .Bad_Tag, "%d: %v", i, err)
	}
}

@(private = "file")
Null_After :: struct {
	email: Maybe(string),
	name:  Maybe(string) `model:"optional,not_null"`,
}

@(private = "file")
Null_Before :: struct {
	name:  Maybe(string) `model:"optional,not_null"`,
	email: Maybe(string),
}

// Whether node `n` of `d` takes null, itself or through an arm.
@(private = "file")
takes_null :: proc(d: ^rules.Description, n: rules.Node_Index) -> bool {
	node := d.nodes[n]
	if ref, has := node.ref.?; .Null not_in node.kinds || has && !takes_null(d, ref) {
		return false
	}
	if node.any_of == nil && node.one_of == nil {
		return true
	}
	for arm in node.any_of {
		if takes_null(d, arm) {
			return true
		}
	}
	for arm in node.one_of {
		if takes_null(d, arm) {
			return true
		}
	}
	return false
}

@(test)
two_maybes_of_one_type_that_differ_on_null_get_two_nodes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	check :: proc(t: ^testing.T, plan: typed.Plan, name, email: int) {
		plan := plan
		d, err := testkit.description_of(&plan, context.temp_allocator)
		testkit.expect_nil(t, err)
		members := d.objects[d.nodes[d.root].object].members
		testing.expect(t, !takes_null(&d, members[name].node))
		testing.expect(t, takes_null(&d, members[email].node))
	}
	check(t, testkit.ruled_plan(Null_After), 1, 0)
	check(t, testkit.ruled_plan(Null_Before), 0, 1)
}
