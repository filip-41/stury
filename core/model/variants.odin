package model

import "base:runtime"
import "core:reflect"
import "core:mem/virtual"
import "core:slice"
import core ".."
import typed "../typed"

// How a model spells the members of enum `type`: as their integers when `by_number`, else each member a rename names by
// the rename's name, and the rest as `Naming.enum_members` spells them.
Enum_Rule :: struct {
	type:      typeid,
	by_number: bool,
	renames:   []Enum_Rename,
}

Enum_Rename :: struct {
	member, name: string,
}

// Adds how `rule.type`'s members are spelled, in place of what an earlier rule of the type said. A rename of a member
// the enum lacks, and two members spelled alike, are refused by `compile`.
register_enum :: proc(reg: ^Registry, rule: Enum_Rule) -> runtime.Allocator_Error {
	owned := Enum_Rule{rule.type, rule.by_number, slice.clone(rule.renames, virtual.arena_allocator(&reg.loads.memory)) or_return}
	for &x in owned.renames {
		x = {kept(reg, x.member) or_return, kept(reg, x.name) or_return}
	}
	for &x in reg.enums {
		if x.type == rule.type {
			x = owned
			return nil
		}
	}
	_, err := append(&reg.enums, owned)
	return err
}

// The names a model spells enum `type`'s members with, into `names`, which holds their own, or false for their integers.
// The names live in the temp allocator.
@(private)
enum_names :: proc(h: ^typed.Model_Rules, type: typeid, names: []string) -> (by_name: bool, err: runtime.Allocator_Error) {
	reg := (^Compiling)(h).reg
	by_name = reg.naming.enums == .Name
	rule: Maybe(Enum_Rule)
	for x in reg.enums {
		if x.type == type {
			rule, by_name = x, !x.by_number
		}
	}
	if !by_name {
		return
	}
	for &name in names {
		if reg.naming.enum_members != .None {
			lowered := typed.rename_text(name, .Snake, context.temp_allocator) or_return
			name = typed.rename_text(lowered, reg.naming.enum_members, context.temp_allocator) or_return
		}
	}
	if r, ruled := rule.?; ruled {
		own := reflect.enum_field_names(type)
		for x in r.renames {
			for member, i in own {
				names[i] = x.name if member == x.member else names[i]
			}
		}
	}
	return
}

// A refusal of an enum rule of `reg` that renames a member its enum lacks, as `.Bad_Tag` with the enum as `want.type`
// and the member as `want.text`.
@(private)
enum_rules_refused :: proc(reg: ^Registry) -> core.Typed_Refusal {
	for x in reg.enums {
		for r in x.renames {
			if !slice.contains(reflect.enum_field_names(x.type), r.member) {
				return {kind = .Bad_Tag, want = {x.type, r.member}}
			}
		}
	}
	return {}
}

// How a model reads union `type`: under `.Tag` an object by its member `tag`, which names the struct arm, in place of
// `Naming.union_tag` unless it is "", and the rest by their kind. Under `.First_Match` a load reads a value of the type
// wherever it is by the first arm that reads its text with no refusal, in the arms' order, a null as nil where the union
// has one, and refuses it as `.No_Arm` with each arm's refusals after it where none does. A format that holds no value
// alone, a table's, refuses the rule at compile as `.Unsupported`. `.One_Match` reads as `.First_Match` does and then
// refuses a value that more than one arm reads with no refusal, as JSON Schema's `oneOf`.
Union_Rule :: struct {
	type: typeid,
	mode: Union_Mode,
	tag:  string,
}

Union_Mode :: enum u8 {
	Tag,
	First_Match,
	One_Match,
}

// Adds how `rule.type` is read, in place of what an earlier rule of the type said.
register_union :: proc(reg: ^Registry, rule: Union_Rule) -> runtime.Allocator_Error {
	_, err := append(&reg.unions, Union_Rule{rule.type, rule.mode, kept(reg, rule.tag) or_return})
	return err
}

@(private)
unions :: proc(h: ^typed.Model_Rules, type: typeid) -> (tag: string, set: bool, first_match: bool) {
	for x in (^Compiling)(h).reg.unions {
		if x.type == type {
			tag, set, first_match = x.tag, x.mode == .Tag && x.tag != "", x.mode != .Tag
		}
	}
	return
}
