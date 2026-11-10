package model

import "base:intrinsics"
import "base:runtime"
import "core:mem/virtual"
import "core:reflect"
import "core:strings"
import core ".."
import rules "../rules"
import typed "../typed"
import write "../write"

// The rules of the models compiled from it: how members are named, the rules of types and of members beside their
// `model:` tags, members' defaults, and the structs that forbid members they do not name. It owns copies of what it is
// given. `destroy` frees it, which leaves the models compiled from it as they are, except that a model's loads take
// the registry's default constants: destroy the registry after its models.
Registry :: struct {
	naming: Naming,
	types:  [dynamic]Type_Rule,
	fields: [dynamic]Field_Rule_Of,
	loads:  Loads,
	validators: [dynamic]Validator_Of,
	befores:    [dynamic]Before_Of,
	customs: [dynamic]Custom_Of,
	enums:   [dynamic]Enum_Rule,
	unions:  [dynamic]Union_Rule,
	close:      typed.Close_Validators, // `typed.validate_closed` once a validator is registered
}

// How a model spells its members' names, where a tag names none, its enums' values, and the member an object names
// its union arm by, "" for none, as `typed.Plan_Options.union_tag` says.
Naming :: struct {
	fields:       typed.Rename,
	enums:        typed.Enum_Spelling,
	// How an enum's members are spelled by name: `.None` as declared, any other lowercased and then renamed.
	enum_members: typed.Rename,
	union_tag:    string,
}

@(private)
Loads :: struct {
	defaults: [dynamic]Default_Of,
	forbids:  [dynamic]typeid,
	// The memory of the constants `defaults` holds.
	constants: virtual.Arena,
}

@(private)
Default_Of :: struct {
	type:  typeid,
	field: string,
	make:  typed.Make_Default,
	data:  rawptr,
}

// Rules on every value of `type`, wherever it is held, spelled as a `model:` tag spells a member's value rules.
Type_Rule :: struct {
	type: typeid,
	tag:  string,
}

// Rules on member `field` of struct `type`, spelled as its `model:` tag, which they add to.
Field_Rule_Of :: struct {
	type:  typeid,
	field: string,
	tag:   string,
}

// How a model loads a member its struct does not name: `Ignore` skips it and `Forbid` refuses it. A member tagged
// `model:"extra"` takes such members, and a struct that has one cannot forbid them.
Extra :: enum u8 {
	Ignore,
	Forbid,
}

// Which members of a struct a load read, in a member of this type, which `was_set` asks. A struct that holds one loads at
// most 128 members.
Fields_Set :: typed.Fields_Set

// The problem document (RFC 9457) of a load's or a check's entries, for any format to write.
Problem :: write.Problem
Problem_Error :: write.Problem_Error
problem :: write.problem
problem_destroy :: write.problem_destroy

register :: proc {
	register_naming,
	register_type,
	register_field,
	register_default,
	register_factory,
	register_extra,
	register_after,
	register_validator,
	register_before,
	register_custom,
	register_enum,
	register_union,
}

// Sets how models compiled from `reg` spell names. `union_tag` must outlive the registry.
register_naming :: proc(reg: ^Registry, naming: Naming) {
	reg.naming = naming
}

register_type :: proc(reg: ^Registry, rule: Type_Rule) -> runtime.Allocator_Error {
	tag := strings.clone(rule.tag) or_return
	if _, err := append(&reg.types, Type_Rule{rule.type, tag}); err != nil {
		delete(tag)
		return err
	}
	return nil
}

// Adds the rules of a member. A struct with no such member is refused by `compile`, not here.
register_field :: proc(reg: ^Registry, rule: Field_Rule_Of) -> runtime.Allocator_Error {
	field := strings.clone(rule.field) or_return
	tag, err := strings.clone(rule.tag)
	if err == nil {
		_, err = append(&reg.fields, Field_Rule_Of{rule.type, field, tag})
	}
	if err != nil {
		delete(field)
		delete(tag)
	}
	return err
}

// Makes `value` the default of member `field` of `T`, which must have the type of `value`. The load of a text that
// leaves the member out gives it a copy of `value`. A member with a default is not required. Refuses as
// `.Invalid_Argument` a member `T` lacks or one of another type. A proc value is a factory's, so a proc member has none.
register_default :: proc(reg: ^Registry, $T: typeid, field: string, value: $V) -> runtime.Allocator_Error where !intrinsics.type_is_proc(V) {
	if !has_member(T, field, V) {
		return .Invalid_Argument
	}
	memory := virtual.arena_allocator(&reg.loads.constants)
	held := new(V, memory) or_return
	value := value
	clone(held, &value, type_info_of(V), memory) or_return
	copied :: proc(dest, data: rawptr, allocator: runtime.Allocator) -> runtime.Allocator_Error {
		return clone(dest, data, type_info_of(V), allocator)
	}
	return add_default(reg, {T, field, copied, held})
}

// Makes what `make` returns the default of member `field` of `T`, for a default that is not a constant: a fresh map,
// the time, an id. `make` allocates with the load's allocator. Refuses as `.Invalid_Argument` a member `T` lacks or one
// of another type.
register_factory :: proc(reg: ^Registry, $T: typeid, field: string, make: proc(allocator: runtime.Allocator) -> $V) -> runtime.Allocator_Error {
	if !has_member(T, field, V) {
		return .Invalid_Argument
	}
	made :: proc(dest, data: rawptr, allocator: runtime.Allocator) -> runtime.Allocator_Error {
		(^V)(dest)^ = (proc(allocator: runtime.Allocator) -> V)(data)(allocator)
		return nil
	}
	return add_default(reg, {T, field, made, rawptr(make)})
}

// Whether struct `T` has a member `field` of type `V`, of any type for a nil `V`.
@(private)
has_member :: proc(T: typeid, field: string, V: typeid) -> bool {
	member := reflect.struct_field_by_name(T, field)
	return len(field) > 0 && member.name == field && member.type != nil && (V == nil || member.type.id == V)
}

@(private)
add_default :: proc(reg: ^Registry, d: Default_Of) -> runtime.Allocator_Error {
	d := d
	d.field = strings.clone(d.field) or_return
	if _, err := append(&reg.loads.defaults, d); err != nil {
		delete(d.field)
		return err
	}
	return nil
}

// Sets what loads of `T` do with members it does not name, in place of what an earlier call set.
register_extra :: proc(reg: ^Registry, $T: typeid, extra: Extra) -> runtime.Allocator_Error {
	for x, i in reg.loads.forbids {
		if x == T {
			unordered_remove(&reg.loads.forbids, i)
			break
		}
	}
	if extra == .Forbid {
		_, err := append(&reg.loads.forbids, T)
		return err
	}
	return nil
}

// A type with its rules, compiled for one format. `plan` holds every member and serves `validate`, `schema` and
// writes, which leave out the write_only members, and refuses every read. `load_plan` leaves out the read_only members
// and reads only as a check, into a zeroed target, as `load` reads by it. Both plans are the model's, and
// `model_destroy` frees them.
Model :: struct($T: typeid) {
	plan:      typed.Plan,
	load_plan: typed.Plan,
	// The registry's customs with their carriers' plans, which the plans' hooks point at.
	customs:   []Custom_Of,
}

// Compiles `T`'s model from `reg`, nil for a plain type, for the format whose typed reads are `reads`, as
// `json.reads(.Json)` gives them. A rule that does not fit its member, and a registered rule of a member its struct does
// not have, refuse the model as `.Bad_Tag`, at the member's path, with the struct as `want.type` and the item as
// `want.text`, and so does an `extra` member of a struct that forbids the members it does not name, and a `Fields_Set`
// in a struct that loads more than 128 members. `layout` is the layout a format's options make, such as
// `dsv.layout(.Csv, {no_header = true})`, which both plans read and write by.
compile :: proc(reg: ^Registry, $T: typeid, reads: ^typed.Format_Reads, allocator := context.allocator, layout: Maybe(core.As) = nil) -> (m: Model(T), err: core.Error) {
	hooks: []typed.Type_Hook
	m.customs, hooks, err = carriers_of(reg, reads, allocator)
	defer delete(hooks, allocator)
	if err == nil {
		m.plan, err = plan_of(reg, T, reads, allocator, nil, nil, layout, hooks)
	}
	if err == nil {
		m.load_plan, err = plan_of(reg, T, reads, allocator, .Read_Only, &m.plan, layout, hooks)
	}
	if err == nil {
		err = carrier_plans(&m, reads, hooks[:len(hooks) - len(m.customs)], allocator)
	}
	if err != nil {
		destroy(&m)
		return
	}
	m.plan.model_plan, m.load_plan.model_plan = .Whole, .Load
	return
}

// The plan of `T` with `reg`'s rules, read with `reads`.
@(private)
plan_of :: proc(reg: ^Registry, T: typeid, reads: ^typed.Format_Reads, allocator: runtime.Allocator, without: Maybe(typed.Access), whole: ^typed.Plan, layout: Maybe(core.As), hooks: []typed.Type_Hook) -> (typed.Plan, core.Error) {
	if reads == nil || reads.plan == nil {
		return {}, core.error_of(core.Typed_Refusal{kind = .Unsupported})
	}
	none: Registry
	c := Compiling{model = {member = member_rule, forbids = forbids, compile = rules.rules_leaf, structs = typed.load_struct, validators = validators_of, enum_names = enum_names, unions = unions}, reg = reg if reg != nil else &none, without = without}
	c.model.close = c.reg.close
	if whole != nil {
		// A load's plan settles its structs, and takes the leaves of the plan of every member.
		c.model.loading, c.model.rule_sets, c.model.leaves = true, whole.rule_sets, whole.leaves
	}
	for x in c.reg.fields {
		if len(x.field) == 0 || reflect.struct_field_by_name(x.type, x.field).name != x.field {
			unknown := core.Typed_Refusal{kind = .Bad_Tag, n_steps = 1}
			unknown.want = {x.type, x.tag}
			unknown.steps[0] = core.Name(x.field)
			typed.own_names(&unknown)
			return {}, core.error_of(unknown)
		}
	}
	if refused := enum_rules_refused(c.reg); refused.kind != .None {
		return {}, core.error_of(refused)
	}
	plan, refused := reads.plan(T, {rename = c.reg.naming.fields, union_tag = c.reg.naming.union_tag, model = &c.model, hooks = hooks}, allocator)
	if as, set := layout.?; set && refused.kind == .None {
		plan.as = as
	}
	if whole != nil && refused.kind == .None {
		refused = replacement_plans(&c, reads, &plan, allocator)
		if refused.kind != .None {
			replacement_destroy(&plan)
			typed.plan_destroy(&plan)
		}
	}
	return plan, core.error_of(refused)
}

destroy :: proc {
	registry_destroy,
	model_destroy,
}

registry_destroy :: proc(reg: ^Registry) {
	for x in reg.types {
		delete(x.tag)
	}
	for x in reg.fields {
		delete(x.field)
		delete(x.tag)
	}
	for x in reg.loads.defaults {
		delete(x.field)
	}
	for x in reg.validators {
		delete(x.field)
	}
	for x in reg.befores {
		delete(x.field)
	}
	delete(reg.validators)
	delete(reg.befores)
	delete(reg.types)
	delete(reg.fields)
	delete(reg.loads.defaults)
	delete(reg.loads.forbids)
	delete(reg.customs)
	for x in reg.enums {
		enum_rule_destroy(x)
	}
	delete(reg.enums)
	for x in reg.unions {
		delete(x.tag)
	}
	delete(reg.unions)
	virtual.arena_destroy(&reg.loads.constants)
	reg^ = {}
}

model_destroy :: proc(m: ^Model($T)) {
	// The load plan's leaves are the other plan's.
	if raw_data(m.load_plan.leaves) == raw_data(m.plan.leaves) {
		m.load_plan.leaves = nil
	}
	replacement_destroy(&m.load_plan)
	typed.plan_destroy(&m.load_plan)
	typed.plan_destroy(&m.plan)
	for &x in m.customs {
		typed.plan_destroy(&x.plan)
	}
	delete(m.customs)
}

@(private)
Compiling :: struct {
	model:   typed.Model_Rules,
	reg:     ^Registry,
	without: Maybe(typed.Access), // the access whose members this plan leaves out
}

// The rules of a member, or with `owner` nil of a value no member holds: the rules of its type and of the types its
// `Maybe`s and pointers hold, then the registry's rules of the member, then its tag's.
@(private)
member_rule :: proc(h: ^typed.Model_Rules, owner: typeid, field: string, type: typeid, tag: string) -> (r: typed.Member_Rule) {
	c := (^Compiling)(h)
	subject := subject_of(type_info_of(type), c.reg)
	for ti := type_info_of(type); ti != nil; ti = held(ti) {
		carrier := carried(c.reg, ti.id)
		if x, is_carrier := carrier_of(carrier); is_carrier && !read_tag(x.tag, subject, false, &r) {
			return
		}
		for x in c.reg.types {
			if (x.type == ti.id || x.type == carrier) && !read_tag(x.tag, subject, false, &r) {
				return
			}
		}
	}
	if owner == nil {
		return
	}
	for x in c.reg.fields {
		if x.type == owner && x.field == field && !read_tag(x.tag, subject, true, &r) {
			return
		}
	}
	for x in c.reg.loads.defaults {
		if x.type == owner && x.field == field {
			r.make, r.data = x.make, x.data
		}
	}
	for x in c.reg.validators {
		if x.type == owner && x.field == field {
			r.after = x.v
		}
	}
	if value, found := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), "model"); found {
		read_tag(value, subject, true, &r)
	}
	if r.before = before_of(c, owner, field); r.before != nil {
		r.before.rules = r.rules
	}
	r.skip ||= r.access != .Read_Write && c.without == r.access
	return
}

@(private)
forbids :: proc(h: ^typed.Model_Rules, owner: typeid) -> bool {
	for x in (^Compiling)(h).reg.loads.forbids {
		if x == owner {
			return true
		}
	}
	return false
}

// The type a `Maybe` or pointer of type `ti` holds, nil for any other type.
@(private)
held :: proc(ti: ^runtime.Type_Info) -> ^runtime.Type_Info {
	#partial switch v in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Pointer:
		return v.elem
	case runtime.Type_Info_Union:
		if len(v.variants) == 1 && !v.no_nil {
			return v.variants[0]
		}
	}
	return nil
}
