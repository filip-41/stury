package model

import "base:runtime"
import "core:reflect"
import "core:strings"
import core ".."
import rules "../rules"
import typed "../typed"

// The rules of the models compiled from it: how members are named, and the rules of types and of members beside their
// `model:` tags. It owns copies of what it is given. `destroy` frees it, which leaves the models compiled from it as
// they are.
Registry :: struct {
	naming: Naming,
	types:  [dynamic]Type_Rule,
	fields: [dynamic]Field_Rule_Of,
}

// How a model spells its members' names, where a tag names none, and its enums' values.
Naming :: struct {
	fields: typed.Rename,
	enums:  typed.Enum_Spelling,
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

register :: proc {
	register_naming,
	register_type,
	register_field,
}

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

// A type with its rules, compiled for one format: the plan its values are read, written, validated and described by.
Model :: struct($T: typeid) {
	plan: typed.Plan,
}

// Compiles `T`'s model from `reg`, nil for a plain type, for the format whose typed reads are `reads`, as
// `json.reads(.Json)` gives them. A rule that does not fit its member, and a registered rule of a member its struct does
// not have, refuse the model as `.Bad_Tag`, at the member's path, with the struct as `want.type` and the item as
// `want.text`.
compile :: proc(reg: ^Registry, $T: typeid, reads: ^typed.Format_Reads, allocator := context.allocator) -> (m: Model(T), err: core.Error) {
	m.plan, err = plan_of(reg, T, reads, allocator)
	return
}

// The plan of `T` with `reg`'s rules, read with `reads`.
@(private)
plan_of :: proc(reg: ^Registry, T: typeid, reads: ^typed.Format_Reads, allocator: runtime.Allocator) -> (typed.Plan, core.Error) {
	if reads == nil || reads.plan == nil {
		return {}, core.error_of(core.Typed_Error{kind = .Unsupported})
	}
	none: Registry
	c := Compiling{model = {member = member_rule, compile = rules.rules_leaf}, reg = reg if reg != nil else &none}
	for x in c.reg.fields {
		if len(x.field) == 0 || reflect.struct_field_by_name(x.type, x.field).name != x.field {
			unknown := core.Typed_Error{kind = .Bad_Tag, n_steps = 1}
			unknown.want = {x.type, x.tag}
			unknown.steps[0] = core.Name(x.field)
			typed.own_names(&unknown)
			return {}, core.error_of(unknown)
		}
	}
	plan, refused := reads.plan(T, {enums = c.reg.naming.enums, rename = c.reg.naming.fields, model = &c.model}, allocator)
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
	delete(reg.types)
	delete(reg.fields)
	reg^ = {}
}

model_destroy :: proc(m: ^Model($T)) {
	typed.plan_destroy(&m.plan)
}

@(private)
Compiling :: struct {
	model: typed.Model_Rules,
	reg:   ^Registry,
}

// The rules of a member, or with `owner` nil of a value no member holds: the rules of its type and of the types its
// `Maybe`s and pointers hold, then the registry's rules of the member, then its tag's.
@(private)
member_rule :: proc(h: ^typed.Model_Rules, owner: typeid, field: string, type: typeid, tag: string) -> (r: typed.Member_Rule) {
	c := (^Compiling)(h)
	subject := subject_of(type_info_of(type))
	for ti := type_info_of(type); ti != nil; ti = held(ti) {
		for x in c.reg.types {
			if x.type == ti.id && !read_tag(x.tag, subject, false, &r) {
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
	if value, found := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), "model"); found {
		read_tag(value, subject, true, &r)
	}
	return
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
