package write

// The edits that take an Odin value: a scalar or a string as it is, a `typed.Raw` as the text of a value, and a struct, a
// slice or a map by the plan the caller gives. The format spells it, as `core.set_value` does for a built value.

import "base:intrinsics"
import "base:runtime"
import "core:strconv"
import "core:strings"
import core ".."
import "../typed"

// What the values a call converted hold, freed after the edit has taken their text.
Scratch :: runtime.Arena

scratch_destroy :: proc(s: ^Scratch) {
	runtime.arena_destroy(s)
}

// What an edit of `v` writes. A `typed.Raw` is the text of a value, a `core.Value` is spelled as it is, and an Odin
// scalar or string is the value it holds. Any other type is built by `plan`, which a format made for the type with its
// reads, and is `.Plan_Mismatch` without one. What the input holds lasts until `scratch` is destroyed.
edit_input :: proc(v: $T, plan: ^typed.Plan, scratch: ^Scratch) -> (in_: core.Edit_Input, err: core.Error) {
	when T == typed.Raw {
		return {text = string(v), raw = true}, nil
	} else {
		return edit_input_of(v, plan, scratch)
	}
}

@(private = "file")
edit_input_of :: proc(v: any, plan: ^typed.Plan, scratch: ^Scratch) -> (in_: core.Edit_Input, err: core.Error) {
	if raw, is_raw := v.(typed.Raw); is_raw {
		return {text = string(raw), raw = true}, nil
	}
	scratch.backing_allocator = context.allocator
	scratch.minimum_block_size = 4096
	allocator := runtime.arena_allocator(scratch)
	switch x in v {
	case core.Value:
		return {value = x}, nil
	case core.Node_Ref:
		return {value = x}, nil
	case ^core.Number_Text:
		return {value = x}, nil
	case ^core.Array:
		return {value = x}, nil
	case ^core.Object:
		return {value = x}, nil
	case ^core.Commented:
		return {value = x}, nil
	case core.Trail:
		return {value = x}, nil
	case bool:
		return {value = x}, nil
	case string:
		return {value = x}, nil
	case cstring:
		return {value = string(x)}, nil
	case f64:
		return {value = x}, nil
	case f32:
		return {value = f64(x)}, nil
	case i8:
		return {value = digits(i64(x), allocator)}, nil
	case i16:
		return {value = digits(i64(x), allocator)}, nil
	case i32:
		return {value = digits(i64(x), allocator)}, nil
	case i64:
		return {value = digits(x, allocator)}, nil
	case int:
		return {value = digits(i64(x), allocator)}, nil
	case u8:
		return {value = digits(u64(x), allocator)}, nil
	case u16:
		return {value = digits(u64(x), allocator)}, nil
	case u32:
		return {value = digits(u64(x), allocator)}, nil
	case u64:
		return {value = digits(x, allocator)}, nil
	case uint:
		return {value = digits(u64(x), allocator)}, nil
	}
	if plan == nil {
		return {}, core.error_of(core.Typed_Refusal{kind = .Plan_Mismatch})
	}
	built := marshal_value(v, plan, allocator) or_return
	// A flat format writes one struct or map as a table of one record.
	if plan.as.readers.flat {
		#partial switch _ in runtime.type_info_base(type_info_of(plan.type)).variant {
		case runtime.Type_Info_Struct, runtime.Type_Info_Map:
			if row, ok := core.child_at(built, 0); ok && core.length(built) == 1 {
				built = row
			}
		}
	}
	return {value = built}, nil
}

@(private = "file")
digits :: proc(n: $T, allocator: runtime.Allocator) -> core.Value {
	buf: [24]u8
	text: string
	when intrinsics.type_is_unsigned(T) {
		text = strconv.write_uint(buf[:], u64(n), 10)
	} else {
		text = strconv.write_int(buf[:], i64(n), 10)
	}
	return core.number_text(strings.clone(text, allocator), allocator)
}

// Makes `v` the value of node `node`, as `core.set_value` does for a built value.
set :: proc(list: ^core.Edit_List, node: core.Node_Index, v: $T, plan: ^typed.Plan = nil) -> core.Error {
	when T == typed.Raw {
		return core.set_text(list, node, string(v))
	} else {
		scratch: Scratch
		defer scratch_destroy(&scratch)
		in_ := edit_input(v, plan, &scratch) or_return
		return core.set_input(list, node, in_)
	}
}

// Makes `v` the value of the member of `obj` named `name`, as `core.set_member_value` does for a built value.
set_member :: proc(list: ^core.Edit_List, obj: core.Node_Index, name: string, v: $T, plan: ^typed.Plan = nil, dups := core.Duplicates.Last) -> core.Error {
	when T == typed.Raw {
		return core.set_member_input(list, obj, name, {text = string(v), raw = true}, dups)
	} else {
		scratch: Scratch
		defer scratch_destroy(&scratch)
		in_ := edit_input(v, plan, &scratch) or_return
		return core.set_member_input(list, obj, name, in_, dups)
	}
}

// Inserts `v` into the array `container` before its element `at`, or after its last when `at` is its length.
insert_element :: proc(list: ^core.Edit_List, container: core.Node_Index, at: int, v: $T, plan: ^typed.Plan = nil) -> core.Error {
	when T == typed.Raw {
		return core.insert_input(list, container, at, "", false, {text = string(v), raw = true})
	} else {
		scratch: Scratch
		defer scratch_destroy(&scratch)
		in_ := edit_input(v, plan, &scratch) or_return
		return core.insert_input(list, container, at, "", false, in_)
	}
}

// Inserts `key` and `v` as a member of the object `container` before its member `at`, or after its last when `at` is its
// length.
insert_member :: proc(list: ^core.Edit_List, container: core.Node_Index, at: int, key: string, v: $T, plan: ^typed.Plan = nil) -> core.Error {
	when T == typed.Raw {
		return core.insert_input(list, container, at, key, true, {text = string(v), raw = true})
	} else {
		scratch: Scratch
		defer scratch_destroy(&scratch)
		in_ := edit_input(v, plan, &scratch) or_return
		return core.insert_input(list, container, at, key, true, in_)
	}
}

insert :: proc {
	insert_element,
	insert_member,
}
