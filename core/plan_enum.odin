package core

// What a writer needs of an enum op in a plan: the value at an address, and the member that has it.

// The enum at `data` as the integer its members are compared by.
plan_enum_value :: #force_inline proc(op: Plan_Op, data: rawptr) -> i64 {
	return shape_int_load(data, op.size) if op.kind == .Enum_Int else i64(shape_uint_load(data, op.size))
}

// The first member of the enum `op` declared with value `v`, or false when none has it.
plan_enum_member :: #force_inline proc(p: ^Type_Plan, op: Plan_Op, v: i64) -> (Plan_Member, bool) {
	members := p.members[op.elem:][:op.count]
	if op.flat {
		if u64(v) < u64(op.count) {
			return members[v], true
		}
		return {}, false
	}
	// A linear scan of a sparse enum's members.
	for m in members {
		if m.value == v {
			return m, true
		}
	}
	return {}, false
}
