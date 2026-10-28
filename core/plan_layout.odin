package core

// A struct's fields and a union's arms as runs of the plan, and the spelling of a field's tag: the part of a
// compile that fills `Type_Plan.fields`, `sources` and `keys`.

import "base:runtime"
import "core:reflect"
import "core:strings"

// Lay the fields that take part (all but those tagged `-`) out as one run in `p.fields` from `first`, `base`
// bytes into the struct the run is for, keys pre-written as `Key_Role.Member`, each type in `p.sources` for
// `compile_field_types`. `refused` is the index in `p.fields` of the field that makes the struct unsupported:
// the second of two writing one key, which no object can hold twice, or one asking for `,string`. The run is
// laid out before any field type compiles, so a nested struct's run lands after it. A `using` field of a
// struct type its tag gives no name, and no hook handles, is flattened, as Go flattens an embedded struct:
// its fields join the run in its place.
@(private)
lay_out_run :: proc(p: ^Type_Plan, v: runtime.Type_Info_Struct, base: uintptr, first: u32) -> (refused: Maybe(u32), err: Plan_Error) {
	for i in 0 ..< int(v.field_count) {
		tag, terr := field_spelling(v.names[i], v.tags[i], p.format.tag_key, p.ops.allocator)
		if terr != .None {
			return nil, terr
		}
		if tag.owned {
			if _, aerr := append(&p.unescaped, tag.key); aerr != nil {
				delete(tag.key, p.ops.allocator)
				return nil, .Out_Of_Memory
			}
		}
		if tag.omitempty && p.format.refuse_omitempty {
			return nil, .Bad_Tag
		}
		if !tag.keep {
			continue
		}
		if inner, ok := runtime.type_info_base(v.types[i]).variant.(runtime.Type_Info_Struct); ok && v.usings[i] && !tag.named {
			if _, hooked := hook_of(p, v.types[i].id); !hooked && .raw_union not_in inner.flags && inner.soa_kind == .None {
				inner_refused := lay_out_run(p, inner, base + v.offsets[i], first) or_return
				if refused == nil {
					refused = inner_refused
				}
				continue
			}
		}
		at := u32(len(p.fields))
		if tag.quoted && refused == nil {
			refused = at
		}
		key_lo := u32(len(p.keys))
		p.format.spell(&p.keys, tag.key, .Member) or_return
		f := Plan_Field{offset = base + v.offsets[i], key_lo = key_lo, key_hi = u32(len(p.keys)), omitempty = tag.omitempty, required = tag.required}
		// Keys are spelled canonically, so two fields name one key exactly when their spelled forms are equal.
		for g in p.fields[first:] {
			if refused == nil && string(p.keys[g.key_lo:g.key_hi]) == string(p.keys[f.key_lo:f.key_hi]) {
				refused = at
			}
		}
		if _, aerr := append(&p.fields, f); aerr != nil {
			return nil, .Out_Of_Memory
		}
		if _, aerr := append(&p.sources, Field_Source{tag.key, v.types[i]}); aerr != nil {
			return nil, .Out_Of_Memory
		}
	}
	return
}

// Compile the types of the laid-out run `p.fields[first:][:count]`.
@(private)
compile_field_types :: proc(p: ^Type_Plan, first, count: u32) -> Plan_Error {
	for k in first ..< first + count {
		field_op := plan_op(p, p.sources[k].info) or_return
		// A type still being compiled further up (a recursive type, through a pointer, a list or a union) is
		// not final here: a struct's kind is, and any other's caches as `.Unsupported`, read only by the
		// scalar fast paths, which no type in progress is.
		op := p.ops[field_op]
		p.fields[k].op = field_op
		p.fields[k].kind = op.kind
		p.fields[k].size = op.size
	}
	return .None
}

// A union's arms as one run in `p.fields`, in declaration order: each its op and tag value, and a named
// struct arm its `arm_tag_name` spelled as `Key_Role.Value`.
@(private)
compile_arms :: proc(p: ^Type_Plan, u: runtime.Type_Info_Union) -> (first, count: u32, err: Plan_Error) {
	first = u32(len(p.fields))
	count = u32(len(u.variants))
	if resize(&p.fields, int(first + count)) != nil || resize(&p.sources, int(first + count)) != nil {
		return 0, 0, .Out_Of_Memory
	}
	for variant, k in u.variants {
		arm_op := plan_op(p, variant) or_return
		// Tag 0 is nil, unless the union has no nil.
		arm := Plan_Field{offset = uintptr(k if u.no_nil else k + 1), op = arm_op, kind = p.ops[arm_op].kind, size = p.ops[arm_op].size}
		if named, ok := variant.variant.(runtime.Type_Info_Named); ok && arm.kind == .Struct {
			arm.key_lo = u32(len(p.keys))
			p.format.spell(&p.keys, arm_tag_name(p, variant.id, named.name), .Value) or_return
			arm.key_hi = u32(len(p.keys))
		}
		p.fields[first + u32(k)] = arm
	}
	return
}

// The value `union_tag` names a struct arm of type `T` by: its `tag_names` entry, else its type name.
arm_tag_name :: proc(p: ^Type_Plan, T: typeid, type_name: string) -> string {
	for t in p.opts.tag_names {
		if t.type == T {
			return t.name
		}
	}
	return type_name
}

// Whether a named struct arm of the tagged union `op` has a field the `union_tag` member would repeat. The
// first call spells the tag's key.
@(private)
tag_clashes :: proc(p: ^Type_Plan, op: Plan_Op) -> (clash: bool, err: Plan_Error) {
	if p.tag_hi == 0 {
		p.tag_lo = u32(len(p.keys))
		p.format.spell(&p.keys, p.opts.union_tag, .Tag) or_return
		p.tag_hi = u32(len(p.keys))
	}
	for arm in p.fields[op.elem:][:op.count] {
		if arm.key_hi == arm.key_lo {
			continue
		}
		aop := p.ops[arm.op]
		for f in p.sources[aop.elem:][:aop.count] {
			if f.name == p.opts.union_tag {
				return true, .None
			}
		}
	}
	return false, .None
}

// A field's tag, read by `field_spelling`.
@(private = "file")
Field_Tag :: struct {
	key:       string, // the field's name in the format
	omitempty: bool,
	required:  bool,
	quoted:    bool, // Go's `,string`
	named:     bool, // the tag gave a name
	keep:      bool, // false for a tag of `-`
	owned:     bool, // `key` is an allocation in the plan's allocator, which `destroy` and a rollback free
}

// A field's name and flags from its tag under `tag_key`, or, when it has none, under SHARED_TAG_KEY:
// `name,omitempty,required`, `-` to omit, an empty
// name keeps the field's own and is not `named`. `quoted` is Go's `,string`, a number or bool written inside a
// string, which the plan refuses. A hook on a distinct type writes it. In the name a backslash makes the byte
// after it literal, so a name holding a comma or a backslash is written `\,` or `\\` (`csv:"Last\, First"`
// names the column `Last, First`); a flag that is not one of those three is `.Bad_Tag`, never dropped. A name
// that escapes a byte is allocated in `allocator` (`owned`); any other is the tag's or the field's own.
@(private = "file")
field_spelling :: proc(name, tag, tag_key: string, allocator: runtime.Allocator) -> (t: Field_Tag, err: Plan_Error) {
	value, ok := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), tag_key)
	if !ok {
		value, ok = reflect.struct_tag_lookup(reflect.Struct_Tag(tag), SHARED_TAG_KEY)
	}
	if !ok {
		return {key = name, keep = true}, .None
	}
	if value == "-" {
		return {}, .None
	}
	raw := transmute([]u8)value
	end, flags_at := len(raw), len(raw)
	i := 0
	for i < len(raw) {
		if raw[i] == '\\' && i + 1 < len(raw) {
			i += 2
		} else if raw[i] == ',' {
			end, flags_at = i, i + 1
			break
		} else {
			i += 1
		}
	}
	length, escaped := 0, false
	j := 0
	for j < end {
		if raw[j] == '\\' && j + 1 < end {
			j += 1
			escaped = true
		}
		j += 1
		length += 1
	}
	switch {
	case length == 0:
		t.key = name
	case !escaped:
		t.key = string(raw[:end])
	case:
		buf, aerr := make([]u8, length, allocator)
		if aerr != nil {
			return {}, .Out_Of_Memory
		}
		k := 0
		j = 0
		for j < end {
			if raw[j] == '\\' && j + 1 < end {
				j += 1
			}
			buf[k] = raw[j]
			k += 1
			j += 1
		}
		t.key, t.owned = string(buf), true
	}
	t.named = length > 0
	if flags_at < len(raw) {
		flags := string(raw[flags_at:])
		for flag in strings.split_iterator(&flags, ",") {
			switch flag {
			case "":
			case "omitempty":
				t.omitempty = true
			case "required":
				t.required = true
			case "string":
				t.quoted = true
			case:
				if t.owned {
					delete(t.key, allocator)
				}
				return {}, .Bad_Tag
			}
		}
	}
	t.keep = true
	return
}
