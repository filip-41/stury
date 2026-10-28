package core

import "base:runtime"
import "core:reflect"

// Returns the enum at `data` as the integer its members are compared by.
plan_enum_value :: #force_inline proc(op: Plan_Op, data: rawptr) -> i64 {
	return shape_int_load(data, op.size) if op.kind == .Enum_Int else i64(shape_uint_load(data, op.size))
}

// Returns the first declared member of the enum `op` with value `v`, or false when none has it.
plan_enum_member :: #force_inline proc(p: ^Type_Plan, op: Plan_Op, v: i64) -> (Plan_Member, bool) {
	members := p.members[op.elem:][:op.count]
	if op.flat {
		if u64(v) < u64(op.count) {
			return members[v], true
		}
		return {}, false
	}
	for m in members {
		if m.value == v {
			return m, true
		}
	}
	return {}, false
}

// The enum at `data` as a writer spells it: the first declared member with its value, and the value for a
// writer that spells enums as integers. A value no member has is refused under either spelling.
plan_enum_written :: #force_inline proc(p: ^Type_Plan, op: Plan_Op, data: rawptr) -> (m: Plan_Member, v: i64, err: Marshal_Error_Kind) {
	v = plan_enum_value(op, data)
	member: bool
	if m, member = plan_enum_member(p, op, v); !member {
		return m, v, .Not_A_Member
	}
	return m, v, .None
}

// The arm the union `op` at `data` holds, as an index into its arm run, or -1 for nil.
plan_union_arm :: #force_inline proc(op: Plan_Op, data: rawptr) -> int {
	u := runtime.type_info_base(op.info).variant.(runtime.Type_Info_Union)
	if len(u.variants) == 0 {
		return -1
	}
	// A pure maybe holds its pointer arm with no tag, and nil is the pointer.
	if reflect.type_info_union_is_pure_maybe(u) {
		return 0 if (^rawptr)(data)^ != nil else -1
	}
	tag := int(shape_uint_load(rawptr(uintptr(data) + u.tag_offset), u8(u.tag_type.size)))
	return tag if u.no_nil else tag - 1
}
