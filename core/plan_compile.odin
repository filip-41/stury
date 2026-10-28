package core

// Compiling a type into plan ops: `plan_op` and the per-kind compilers. A compile that fails is rolled back, so a plan
// is never left half built. Struct fields and union arms are laid out in plan_layout.odin.

import "base:runtime"

@(private = "file")
Plan_Mark :: struct {
	ops, fields, sources, keys, members, unescaped: int,
}

@(private = "file")
plan_mark :: proc(p: ^Type_Plan) -> Plan_Mark {
	return {
		ops = len(p.ops),
		fields = len(p.fields),
		sources = len(p.sources),
		keys = len(p.keys),
		members = len(p.members),
		unescaped = len(p.unescaped),
	}
}

@(private = "file")
NO_OP :: max(u32)

// `delete_key` on a `map[typeid]` hangs the Odin checker at `-o:speed` (dev-2026-10); overwrite with `NO_OP`.
@(private = "file")
plan_rollback :: proc(p: ^Type_Plan, m: Plan_Mark) {
	for _, &idx in p.index {
		if idx >= u32(m.ops) {
			idx = NO_OP
		}
	}
	resize(&p.ops, m.ops)
	resize(&p.fields, m.fields)
	resize(&p.sources, m.sources)
	resize(&p.keys, m.keys)
	resize(&p.members, m.members)
	for s in p.unescaped[m.unescaped:] {
		delete(s, p.ops.allocator)
	}
	resize(&p.unescaped, m.unescaped)
	if p.tag_hi > u32(m.keys) {
		p.tag_lo, p.tag_hi = 0, 0
	}
}

// The op for `ti`. A type already in the plan, including one still being compiled further up this call (a
// recursive type), answers its existing index. A compile that fails is rolled back before the error returns, so
// no half-built op, field, index entry or name stays: the plan is as it was before, the next call compiles the
// same type again, and every call answers the same error. The plan cache evicts only a plan that reported
// `.Out_Of_Memory`, and a rolled-back plan is sound whether or not it is evicted.
plan_op :: proc(p: ^Type_Plan, ti: ^runtime.Type_Info) -> (idx: u32, err: Plan_Error) {
	if found, ok := p.index[ti.id]; ok && found != NO_OP {
		return found, .None
	}
	mark := plan_mark(p)
	idx = u32(len(p.ops))
	if _, aerr := append(&p.ops, Plan_Op{info = ti}); aerr != nil {
		return 0, .Out_Of_Memory
	}
	if map_insert(&p.index, ti.id, idx) == nil {
		plan_rollback(p, mark)
		return 0, .Out_Of_Memory
	}
	op, cerr := compile_op(p, ti, idx)
	if cerr != .None {
		plan_rollback(p, mark)
		return 0, cerr
	}
	// Indexed after the call: compiling element types may have moved `p.ops`.
	p.ops[idx] = op
	return idx, .None
}

// `plan_op` on a format's plan, its refusal as the `Marshal_Error_Kind` of the same value.
plan_op_m :: #force_inline proc(p: ^Hooked_Plan, ti: ^runtime.Type_Info) -> (u32, Marshal_Error_Kind) {
	idx, err := plan_op(&p.base, ti)
	return idx, Marshal_Error_Kind(err)
}

// The op for `ti`, whose slot is `p.ops[idx]`.
@(private = "file")
compile_op :: proc(p: ^Type_Plan, ti: ^runtime.Type_Info, idx: u32) -> (op: Plan_Op, err: Plan_Error) {
	op.info = ti
	if k, hooked := hook_of(p, ti.id); hooked {
		op.kind = .Hook
		op.elem = u32(k)
		return
	}
	for t in p.format.types {
		if t.type == ti.id {
			op.kind = t.kind
			return
		}
	}
	base := runtime.type_info_base(ti)
	op.size = u8(min(base.size, 255))
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		op.kind = .Bool
	case runtime.Type_Info_Integer:
		switch {
		case v.endianness != .Platform:
			op.kind = .Unsupported
		case base.size == 16:
			op.kind = .Wide_Int if v.signed else .Wide_Uint
		case:
			op.kind = .Int if v.signed else .Uint
		}
	case runtime.Type_Info_Rune:
		op.kind = .Rune
	case runtime.Type_Info_Float:
		op.kind = .Float if v.endianness == .Platform else .Unsupported
	case runtime.Type_Info_String:
		switch {
		case v.encoding != .UTF_8:
			op.kind = .Unsupported
		case v.is_cstring:
			op.kind = .Cstring
		case:
			op.kind = .String
		}
	case runtime.Type_Info_Enum:
		compile_enum_op(p, ti, v, &op) or_return
	case runtime.Type_Info_Pointer:
		if v.elem == nil {
			op.kind = .Unsupported
		} else {
			op.kind = .Pointer
			op.elem = plan_op(p, v.elem) or_return
		}
	case runtime.Type_Info_Array:
		op.kind = .Array
		op.count = u32(v.count)
		op.stride = u32(v.elem_size)
		op.elem = plan_op(p, v.elem) or_return
	case runtime.Type_Info_Enumerated_Array:
		op.kind = .Array
		op.count = u32(v.count)
		op.stride = u32(v.elem_size)
		op.elem = plan_op(p, v.elem) or_return
	case runtime.Type_Info_Slice:
		op.kind = .Slice
		op.stride = u32(v.elem_size)
		op.elem = plan_op(p, v.elem) or_return
	case runtime.Type_Info_Dynamic_Array:
		op.kind = .Dynamic
		op.stride = u32(v.elem_size)
		op.elem = plan_op(p, v.elem) or_return
	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		op.kind = .Fixed_List
		op.count = u32(v.capacity)
		op.stride = u32(v.elem_size)
		op.len_offset = u32(v.len_offset)
		op.elem = plan_op(p, v.elem) or_return
	case runtime.Type_Info_Map:
		compile_map_op(p, v, &op) or_return
	case runtime.Type_Info_Struct:
		compile_struct_op(p, v, &op, idx) or_return
	case runtime.Type_Info_Bit_Set:
		compile_bit_set_op(p, v, &op) or_return
	case runtime.Type_Info_Union:
		compile_union_op(p, v, &op) or_return
	case runtime.Type_Info_Any:
		op.kind = .Any
	case:
		op.kind = .Unsupported
	}
	return
}

// An enum's op in `op`: its integer kind with the member table, or its backing op for a 128-bit backing.
@(private = "file")
compile_enum_op :: proc(p: ^Type_Plan, ti: ^runtime.Type_Info, v: runtime.Type_Info_Enum, op: ^Plan_Op) -> (err: Plan_Error) {
	backing := plan_op(p, v.base) or_return
	if k := p.ops[backing].kind; k != .Int && k != .Uint {
		// A 128-bit backing writes its integer.
		op^ = p.ops[backing]
		op.info = ti
		return
	}
	op.kind = .Enum_Int if p.ops[backing].kind == .Int else .Enum_Uint
	op.elem = u32(len(p.members))
	op.count = u32(len(v.names))
	op.flat = true
	for name, k in v.names {
		lo := u32(len(p.keys))
		p.format.spell(&p.keys, name, .Value) or_return
		if _, aerr := append(&p.members, Plan_Member{i64(v.values[k]), lo, u32(len(p.keys))}); aerr != nil {
			return .Out_Of_Memory
		}
		op.flat &&= i64(v.values[k]) == i64(k)
	}
	return .None
}

// A map's op in `op`: supported for string and integer keys.
@(private = "file")
compile_map_op :: proc(p: ^Type_Plan, v: runtime.Type_Info_Map, op: ^Plan_Op) -> (err: Plan_Error) {
	op.key = plan_op(p, v.key) or_return
	#partial switch p.ops[op.key].kind {
	case .String, .Cstring, .Int, .Uint, .Wide_Int, .Wide_Uint, .Enum_Int, .Enum_Uint:
		op.kind = .Map
		op.elem = plan_op(p, v.value) or_return
	case:
		op.kind = .Unsupported
	}
	return .None
}

// A struct's op in `op`, whose slot is `p.ops[idx]`.
@(private = "file")
compile_struct_op :: proc(p: ^Type_Plan, v: runtime.Type_Info_Struct, op: ^Plan_Op, idx: u32) -> (err: Plan_Error) {
	if .raw_union in v.flags || v.soa_kind != .None {
		op.kind = .Unsupported
	} else {
		op.elem = u32(len(p.fields))
		refused := lay_out_run(p, v, 0, op.elem) or_return
		op.count = u32(len(p.fields)) - op.elem
		if at, bad := refused.?; bad {
			op.kind = .Unsupported
			op.refused = true
			op.key = at
			return
		}
		op.kind = .Struct
		// Published before the field types compile: a recursive type meets this op again (through a
		// pointer, a list or a union) while it is compiled, and a union reads its arms' kinds.
		p.ops[idx] = op^
		compile_field_types(p, op.elem, op.count) or_return
		op.flat = true
		for f in p.fields[op.elem:][:op.count] {
			#partial switch f.kind {
			case .Bool, .Int, .Uint, .Float, .String, .Enum_Int, .Enum_Uint:
				op.flat &&= !f.omitempty
			case:
				op.flat = false
			}
		}
	}
	return .None
}

@(private = "file")
compile_bit_set_op :: proc(p: ^Type_Plan, v: runtime.Type_Info_Bit_Set, op: ^Plan_Op) -> (err: Plan_Error) {
	// An enum's names or a range's integers. A 128-bit enum lowers to its integer kind, refused here, and
	// so is a backing integer of another byte order, as an integer of one is.
	if v.underlying != nil && runtime.type_info_base(v.underlying).variant.(runtime.Type_Info_Integer).endianness != .Platform {
		op.kind = .Unsupported
		return
	}
	op.elem = plan_op(p, v.elem) or_return
	#partial switch p.ops[op.elem].kind {
	case .Enum_Int, .Enum_Uint, .Int, .Uint:
		op.kind = .Bit_Set
	case:
		op.kind = .Unsupported
	}
	return .None
}

@(private = "file")
compile_union_op :: proc(p: ^Type_Plan, v: runtime.Type_Info_Union, op: ^Plan_Op) -> (err: Plan_Error) {
	op.kind = .Union
	op.elem, op.count = compile_arms(p, v) or_return
	named := 0
	for arm in p.fields[op.elem:][:op.count] {
		named += int(arm.key_hi > arm.key_lo)
	}
	op.tagged = named >= 2
	if op.tagged && len(p.opts.union_tag) > 0 && (tag_clashes(p, op^) or_return) {
		op.kind = .Unsupported
	}
	return .None
}

// The hook `opts.hooks[k]` that handles type `T`.
@(private)
hook_of :: proc(p: ^Type_Plan, T: typeid) -> (k: int, hooked: bool) {
	for h, j in p.opts.hooks {
		if h.type == T {
			return j, true
		}
	}
	return -1, false
}
