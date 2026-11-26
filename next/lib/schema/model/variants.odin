// Enum spelling rules, union dispatch rules, and identifier renaming.
package model

import "base:runtime"
import "core:reflect"
import "core:slice"
import "core:strings"

// How a model spells enum values: by member name or by underlying integer.
Enum_Spelling :: enum u8 { Name, Int }
// How a struct or enum member with no explicit alias is renamed from its Odin identifier.
Rename :: enum u8 { None, Camel, Pascal, Kebab, Screaming, Snake }
// How a model spells the members of enum `type`.
Enum_Rule :: struct { type: typeid, by_number: bool, renames: []Enum_Rename }
Enum_Rename :: struct { member, name: string }

// Registers how `rule.type`'s members are spelled, replacing any earlier rule for `rule.type`.
register_enum :: proc(reg: ^Registry, rule: Enum_Rule) -> runtime.Allocator_Error {
	arena := reg_arena(reg)
	owned := Enum_Rule{type = rule.type, by_number = rule.by_number, renames = slice.clone(rule.renames, arena) or_return}
	for &x in owned.renames { x = {kept(reg, x.member) or_return, kept(reg, x.name) or_return} }
	for &x in reg.enums { if x.type == rule.type { x = owned; return nil } }
	_, err := append(&reg.enums, owned); return err
}

// Computes the spelled names for enum `type` into `names` (initialized with its Odin names),
// allocating any renamed strings in `allocator`. Returns `by_name == false` for integer spelling.
@(private)
enum_names :: proc(reg: ^Registry, type: typeid, names: []string, allocator: runtime.Allocator) -> (by_name: bool, err: runtime.Allocator_Error) {
	by_name = reg.naming.enums == .Name
	rule: Maybe(Enum_Rule)
	for x in reg.enums { if x.type == type { rule, by_name = x, !x.by_number } }
	if !by_name { return false, nil }
	if reg.naming.enum_members != .None {
		for &name in names {
			lowered := rename_text(name, .Snake, allocator) or_return
			name = rename_text(lowered, reg.naming.enum_members, allocator) or_return
		}
	}
	if r, ruled := rule.?; ruled {
		own := reflect.enum_field_names(type)
		for x in r.renames { for member, i in own { if member == x.member { names[i] = strings.clone(x.name, allocator) or_return } } }
	}
	return true, nil
}

// Checks every registered enum rule for member names the enum lacks.
@(private)
enum_rules_refused :: proc(reg: ^Registry) -> Model_Error {
	if reg == nil { return {} }
	for x in reg.enums {
		own := reflect.enum_field_names(x.type)
		for r in x.renames { if !slice.contains(own, r.member) { return {kind = .Bad_Tag, want = {x.type, r.member}} } }
	}
	return {}
}

// How a model dispatches a union value.
Union_Mode :: enum u8 { Tag, First_Match, One_Match }
Union_Rule :: struct { type: typeid, mode: Union_Mode, tag: string }

// Registers how union `rule.type` is read and described, replacing any earlier rule for `rule.type`.
register_union :: proc(reg: ^Registry, rule: Union_Rule) -> runtime.Allocator_Error {
	owned := Union_Rule{rule.type, rule.mode, kept(reg, rule.tag) or_return}
	for &x in reg.unions { if x.type == rule.type { x = owned; return nil } }
	_, err := append(&reg.unions, owned); return err
}

@(private)
union_rule_of :: proc(reg: ^Registry, type: typeid) -> (mode: Union_Mode, tag: string) {
	mode = .Tag; if reg == nil { return }; tag = reg.naming.union_tag
	for x in reg.unions {
		if x.type == type { mode = x.mode; if x.mode == .Tag && x.tag != "" { tag = x.tag } else if x.mode != .Tag { tag = "" } }
	}
	return
}

// Spells `name` according to `style`, allocating with `allocator`.
@(private)
rename_text :: proc(name: string, style: Rename, allocator: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	if style == .None || len(name) == 0 { return strings.clone(name, allocator) }
	b, err := strings.builder_make(0, len(name) + 8, allocator); if err != nil { return "", err }
	first, upper_next := true, false
	for i := 0; i < len(name); i += 1 {
		c := name[i]
		if c == '_' {
			upper_next = !first
			if style == .Kebab || style == .Snake || style == .Screaming { if !first { strings.write_byte(&b, '-' if style == .Kebab else '_') }; upper_next = false }
			continue
		}
		word_start := i > 0 && (c >= 'A' && c <= 'Z') && (name[i - 1] >= 'a' && name[i - 1] <= 'z')
		if word_start {
			switch style {
			case .Kebab:            strings.write_byte(&b, '-')
			case .Snake, .Screaming: strings.write_byte(&b, '_')
			case .Camel, .Pascal:   upper_next = true
			case .None:
			}
		}
		up, lo := (c - 32 if c >= 'a' && c <= 'z' else c), (c + 32 if c >= 'A' && c <= 'Z' else c)
		switch style {
		case .Camel:     c = up if upper_next else (lo if first || (!word_start && !upper_next) else c)
		case .Pascal:    c = up if upper_next || first else lo
		case .Kebab, .Snake: c = lo
		case .Screaming: c = up
		case .None:
		}
		strings.write_byte(&b, c); first, upper_next = false, false
	}
	return strings.to_string(b), nil
}