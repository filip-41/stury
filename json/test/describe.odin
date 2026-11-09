package json_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import core "../../core"
import rules "../../core/rules"
import typed "../../core/typed"
import json ".."
import model "../../core/model"
import walktest "../../walktest"

// A type's description, `describe(plan)`, and the plan built from it, `plan_of`, agree on the plan's shape.

@(private = "file")
Zoo_Inner :: struct {
	n: i32,
	s: string,
}

@(private = "file")
Zoo_Tree :: struct {
	name: string,
	kids: []Zoo_Tree,
	up:   ^Zoo_Tree,
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
	i_8:       i8,
	i_16:      i16,
	i_32:      i32,
	i_64:      i64,
	u_8:       u8,
	u_16:      u16,
	u_32:      u32,
	u_64:      u64,
	f_32:      f32,
	f_64:      f64,
	yes:       bool,
	wide:      b32,
	s:         string,
	c:         cstring,
	req:       i32 `json:"req,required"`,
	inner:     Zoo_Inner,
	again:     Zoo_Inner,
	may_inner: Maybe(Zoo_Inner),
	ptr:       ^Zoo_Inner,
	may_ptr:   Maybe(^Zoo_Inner),
	tree:      Zoo_Tree,
	list:      []i32,
	may_list:  Maybe([]i32),
	dyn:       [dynamic]string,
	fixed:     [3]i32,
	capped:    [dynamic; 4]i32,
	maybes:    []Maybe(string),
	by_name:   map[string]Zoo_Inner,
	by_int:    map[i32]bool,
	classed:   union {
		i64,
		string,
		[]i32,
	},
	no_nil:    union #no_nil {
		bool,
		f64,
	},
	anything:  any,
	raw:       typed.Raw,
	color:     Zoo_Color,
	bits:      bit_set[0 ..< 8],
	colors:    bit_set[Zoo_Color],
	num:       core.Number,
	num_text:  typed.Number_Text,
	scalar:    typed.Scalar,
	hooked:    Zoo_Hooked,
	captured:  struct {
		a:    i32,
		rest: map[string]typed.Raw `json:",unknown"`,
	},
}

@(private = "file")
read_zoo_hooked :: proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
	return nil
}

// A plan's shape: its root record, then each struct and union block in the order a walk from the root meets it. A
// record is its class of value, `?` when it also takes null, and its block: `#k` names a struct or union block, a list
// or map shows its element in line. A `Maybe` or pointer folds into its element. A type plan's blocks of one type are
// one block, which folds those that differ only in rule set.
@(private = "file")
Projection :: struct {
	plan:     ^typed.Plan,
	ordinals: map[Projected]int,
	blocks:   [dynamic]string,
}

@(private = "file")
Projected :: struct {
	type:  typeid,
	block: i32,
}

@(private = "file")
project :: proc(plan: ^typed.Plan) -> string {
	p := Projection{plan = plan}
	p.ordinals.allocator = context.temp_allocator
	p.blocks.allocator = context.temp_allocator
	root := project_record(&p, 0)
	return fmt.tprint(root, p.blocks[:])
}

// The class of value a record's kind reads, and whether the kind reads null itself.
@(private = "file")
class :: proc(plan: ^typed.Plan, f: typed.Field, m: typed.Meta) -> (string, bool) {
	#partial switch f.kind {
	case .String, .Cstring:
		return "str", false
	case .Bool, .Bool_Wide:
		return "bool", false
	case .I8 ..= .U64:
		return "int", false
	case .F32, .F64, .Number:
		return "num", false
	case .Number_Text:
		return "num", true
	case .Scalar:
		return "scalar", true
	case .Enum, .Bit_Elem:
		return "str" if m.enum_info != nil && plan.enums == .Name else "int", false
	case .Struct, .Required, .Map:
		return "obj", false
	case .Slice, .Dynamic, .Array, .Fixed_List, .Bit_Set:
		return "arr", false
	case .Union:
		return "", !m.no_nil
	case .Any, .Raw, .Hook:
		return "any", true
	}
	return fmt.tprint(f.kind), false
}

@(private = "file")
project_record :: proc(p: ^Projection, at: i32) -> string {
	at, nullable := at, false
	for p.plan.fields[at].kind == .Maybe || p.plan.fields[at].kind == .Ptr {
		at, nullable = p.plan.meta[at].block, true
	}
	f, m := p.plan.fields[at], p.plan.meta[at]
	text, null := class(p.plan, f, m)
	shape := ""
	#partial switch f.kind {
	case .Struct, .Required:
		shape = project_block(p, m, false)
	case .Union:
		shape = project_block(p, m, true)
	case .Slice, .Dynamic, .Array, .Fixed_List, .Bit_Set, .Map:
		shape = fmt.tprintf("<%s>", project_record(p, m.block))
	}
	return fmt.tprintf("%s%s%s", text, "?" if nullable || null else "", shape)
}

@(private = "file")
project_block :: proc(p: ^Projection, m: typed.Meta, union_block: bool) -> string {
	key := Projected{m.type, -1} if p.plan.type != nil else Projected{nil, m.block}
	if k, ok := p.ordinals[key]; ok {
		return fmt.tprintf("#%d", k)
	}
	k := len(p.blocks)
	p.ordinals[key] = k
	append(&p.blocks, "")
	b := strings.builder_make(context.temp_allocator)
	if union_block {
		for arm in m.arms {
			fmt.sbprintf(&b, "| %s ", project_record(p, arm.fields))
		}
	} else {
		for j in 0 ..< m.members {
			at := m.block + j
			fmt.sbprintf(&b, "%s: %s, ", p.plan.meta[at].name, project_record(p, at))
		}
		fmt.sbprintf(&b, "required %v", p.plan.meta[m.block + m.members].required)
	}
	p.blocks[k] = fmt.tprintf("#%d %s", k, strings.to_string(b))
	return fmt.tprintf("#%d", k)
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

@(private = "file")
Ruled_Union :: struct {
	a: union {
		i64,
		string,
	} `model:">=1"`,
	b: union {
		i64,
		string,
	},
}

@(test)
a_plan_of_a_types_description_has_the_types_plan_shape :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	hooks := []typed.Type_Hook{{type = Zoo_Hooked, read = read_zoo_hooked}}
	cases := [?]struct {
		type: typeid,
		opts: typed.Plan_Options,
	} {
		{Zoo, {hooks = hooks}},
		{Zoo, {enums = .Int, hooks = hooks}},
		{Zoo_Tree, {}},
		{[]Maybe(Zoo_Inner), {}},
		{map[string]any, {}},
		{Ruled, {rule_tags = true}},
		{Ruled_Union, {rule_tags = true}},
	}
	for c in cases {
		plan, planned := json.plan_make(c.type, plan = c.opts, allocator = context.temp_allocator)
		walktest.expect_nil(t, planned)
		d, described := model.describe(&plan, context.temp_allocator)
		walktest.expect_nil(t, described)
		again, built := typed.plan_of(&d, json.as(.Json), c.opts, context.temp_allocator)
		walktest.expect_nil(t, built)
		want, got := project(&plan), project(&again)
		testing.expectf(t, want == got, "%v:\nplan        %s\ndescription %s", c.type, want, got)
	}
}

@(private = "file")
Shown :: struct {
	n: Maybe(i32),
	t: typed.Number_Text,
	e: Zoo_Color,
	u: union {
		bool,
		string,
	},
	l: []Shown,
}

@(test)
a_type_and_its_description_read_the_classes_the_type_reads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plan, _ := json.plan_make(Shown, allocator = context.temp_allocator)
	d, _ := model.describe(&plan, context.temp_allocator)
	again, _ := typed.plan_of(&d, json.as(.Json), allocator = context.temp_allocator)
	want := "obj#0 [\"#0 n: ?#1, t: num?, e: str, u: ?#2, l: arr<obj#0>, required []\", \"#1 | int \", \"#2 | bool | str \"]"
	testing.expect_value(t, project(&plan), want)
	testing.expect_value(t, project(&again), want)
}

@(test)
two_members_of_one_type_with_different_rules_get_two_blocks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plain, _ := json.plan_make(Ruled, allocator = context.temp_allocator)
	plan, planned := json.plan_make(Ruled, plan = {rule_tags = true}, allocator = context.temp_allocator)
	walktest.expect_nil(t, planned)
	block :: proc(p: ^typed.Plan, member: i32) -> i32 {
		return p.meta[p.meta[0].block + member].block
	}
	testing.expect_value(t, block(&plain, 0), block(&plain, 1))
	testing.expect(t, block(&plan, 0) != block(&plan, 1))
	testing.expect_value(t, block(&plan, 0), block(&plan, 2))
	d, _ := model.describe(&plan, context.temp_allocator)
	members := d.objects[d.nodes[d.root].object].members
	testing.expect_value(t, members[0].rules.min_length, 3)
	testing.expect_value(t, members[1].rules.min_length, 0)
	testing.expect_value(t, members[0].node, members[1].node)
	small := d.nodes[members[3].node].rules
	testing.expect_value(t, small.minimum, "-128")
	testing.expect_value(t, small.maximum, "127")
	bit := d.nodes[d.arrays[d.nodes[members[4].node].array].items].rules
	testing.expect_value(t, bit.maximum, "7")
	key := d.nodes[d.objects[d.nodes[members[5].node].object].keys].rules
	testing.expect_value(t, key.maximum, "127")
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
	for T in ([?]typeid{Past_Max, Signed, Leading_Zero, Flattened, Capture}) {
		_, err := json.plan_make(T, plan = {rule_tags = true}, allocator = context.temp_allocator)
		testing.expectf(t, walktest.typed_kind(err) == .Bad_Tag, "%v: %v", T, err)
	}
}

@(test)
describe_and_plan_of_free_what_they_allocate :: proc(t: ^testing.T) {
	plan, _ := json.plan_make(Zoo, plan = {hooks = {{type = Zoo_Hooked, read = read_zoo_hooked}}})
	defer typed.plan_destroy(&plan)
	d, _ := model.describe(&plan)
	defer rules.description_destroy(&d)
	again, built := typed.plan_of(&d, json.as(.Json))
	walktest.expect_nil(t, built)
	typed.plan_destroy(&again)
	_, empty := typed.plan_of(&rules.Description{}, json.as(.Json))
	walktest.expect_kind(t, empty, core.Typed_Error_Kind.Bad_Option)
	arms := [2]rules.Node_Index{1, 2}
	objects := rules.Description{}
	defer delete(objects.nodes)
	append(&objects.nodes, rules.Node{kinds = rules.EVERY_KIND, any_of = arms[:], array = -1, object = -1})
	append(&objects.nodes, rules.Node{kinds = {.Object}, array = -1, object = -1}, rules.Node{kinds = {.Object}, array = -1, object = -1})
	_, ambiguous := typed.plan_of(&objects, json.as(.Json))
	walktest.expect_kind(t, ambiguous, core.Typed_Error_Kind.Ambiguous_Union)
}
