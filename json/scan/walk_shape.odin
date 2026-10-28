package scan

import core_pkg "../../core"
import "walk"

// The shape walk: `walk_value_q` over `{.Shape}`, whose hooks call core's transitions (core/shape_walk.odin)
// with JSON's leaves. The hooks act only on values at the run's depth. Anything deeper is inside a container
// nothing reads, and the walk checks it (or, under `.Lazy`, skips it) without the hooks.
//
// `shape_key` and `shape_scalar` see a token only once the walk has checked it. `shape_tag_arm`, which reads an
// object before the walk does, keeps its bounds checks. `$unique` adds the key set, `$dialect` the JSONC walk,
// and `$vc` a scalar's class.

shape_at :: core_pkg.shape_at
shape_zero :: core_pkg.shape_zero
shape_alloc :: core_pkg.shape_alloc
shape_resize :: core_pkg.shape_resize
shape_fault :: core_pkg.shape_fault
shape_list_grow :: core_pkg.shape_list_grow
shape_first_has :: core_pkg.shape_first_has
TYPED_FAULT :: walk.TYPED_FAULT
SHAPE_WHOLE_LEAVES :: core_pkg.SHAPE_WHOLE_LEAVES
SHAPE_SEQUENCES :: core_pkg.SHAPE_SEQUENCES
SHAPE_CONTAINERS :: core_pkg.SHAPE_CONTAINERS
SHAPE_ZERO_INLINE :: core_pkg.SHAPE_ZERO_INLINE

// A value opens at walk depth `sp`: core's transition with JSON's `null` and union tag.
shape_value_open :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, sp: u64, vc: u8) -> Maybe(Error) {
	return core_pkg.shape_value_open(q.shape, s, sp, s.pos, q.max_depth, vc, shape_is_null, shape_union_tag_arm)
}

@(private = "file")
shape_is_null :: #force_inline proc(s: ^Scanner, at: u64) -> bool #no_bounds_check {
	return s.src[at] == 'n'
}

@(private = "file")
shape_union_tag_arm :: proc(s: ^Scanner, r: ^walk.Shape_Run, op: ^core_pkg.Shape_Op, at: u64) -> (u8, core_pkg.Shape_Fault) {
	return shape_tag_arm(r, op, at)
}

// A member key of the object open at walk depth `sp - 1`: core's transition with JSON's key compare. Under
// `unique` (`.Unique`) a key no seen bit covers goes to the walk's key set.
shape_key :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, key_lo, key_hi: u64, sp: u64, $unique: bool) -> Maybe(Error) {
	return core_pkg.shape_key(q.shape, q, key_lo, key_hi, q.key_saw_escape, sp, unique, shape_key_is, shape_key_scan, shape_key_text, shape_map_key, shape_key_unique)
}

@(private = "file")
shape_key_is :: #force_inline proc(q: ^Query_Ctx, r: ^walk.Shape_Run, key_lo, key_hi: u64, escaped: bool, name: string) -> bool {
	return walk.key_equals_hooked(q.hooks, r.src, key_lo, key_hi, escaped, name)
}

// An escaped key may be any field. A plain one is a field only if some name starts with its first byte.
@(private = "file")
shape_key_scan :: #force_inline proc(q: ^Query_Ctx, r: ^walk.Shape_Run, op: ^core_pkg.Shape_Op, key_lo: u64, escaped: bool) -> bool #no_bounds_check {
	return escaped || shape_first_has(op.first, r.src[key_lo + 1])
}

@(private = "file")
shape_key_text :: proc(q: ^Query_Ctx, r: ^walk.Shape_Run, key_lo, key_hi: u64, escaped: bool) -> (string, bool) {
	if escaped {
		return "", false
	}
	return string(r.src[key_lo + 1:key_hi - 1]), true
}

@(private = "file")
shape_map_key :: proc(q: ^Query_Ctx, r: ^walk.Shape_Run, kop: ^core_pkg.Shape_Op, key_lo, key_hi: u64, escaped: bool, dest: rawptr) -> core_pkg.Shape_Fault {
	return shape_leaf_map_key(r, escaped, key_lo, key_hi, kop, dest)
}

// `.Unique`'s check of a key no seen bit covers: one of a map, one the struct does not name, or one in a value
// the shape does not read (`sp > r.sp`). A refused spill is the shape's `.Out_Of_Memory`.
@(private = "file")
shape_key_unique :: proc(q: ^Query_Ctx, r: ^walk.Shape_Run, key_lo, key_hi: u64, sp: u64) -> Maybe(Error) {
	unique, oom := key_set_add(q.keys, r.src, key_lo, key_hi, q.key_saw_escape, u32(sp))
	if oom {
		return shape_fault(r, .Out_Of_Memory, key_lo, min(sp, r.sp))
	}
	if !unique {
		return Error{offset = key_lo, kind = .Duplicate_Key}
	}
	return nil
}

// The scalar token `src[lo:s.pos]` the walk just checked, a string (`vc` 3), a literal (4) or a number (5): decode
// it into the latched target.
shape_scalar :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, lo: u64, sp: u64, $vc: u8) -> Maybe(Error) #no_bounds_check {
	r := q.shape
	if !r.cur_live {
		return nil
	}
	r.cur_live = false
	if fault := shape_leaf_token(r, q, r.cur_op, r.cur_dest, lo, s.pos, vc); fault != .None {
		return shape_fault(r, fault, lo, sp)
	}
	return nil
}

// The scalar token `src[lo:hi]` of class `vc`, just checked by the walk, decoded into `dest` as op `op_i` reads
// it. The commonest leaf of the token's class is taken without the dispatch.
shape_leaf_token :: #force_inline proc(r: ^walk.Shape_Run, q: ^Query_Ctx, op_i: u32, dest: rawptr, lo, hi: u64, $vc: u8) -> core_pkg.Shape_Fault #no_bounds_check {
	when vc == VC_STRING {
		if r.ops[op_i].kind == .String && !q.str_escaped && r.borrow {
			if dest != nil {
				(^string)(dest)^ = string(r.src[lo + 1:hi - 1])
			}
			return .None
		}
	} else when vc == VC_NUMBER {
		op := &r.ops[op_i]
		#partial switch op.kind {
		case .Int:
			return shape_leaf_number_int(r, lo, hi, dest, op.width, true)
		case .Float:
			return shape_leaf_float(r, lo, hi, dest, op.width)
		}
	}
	return shape_decode_scalar(r, q, op_i, dest, lo, hi)
}

// One scalar leaf per op kind. Lowering refuses every kind without one.
shape_decode_scalar :: proc(r: ^walk.Shape_Run, q: ^Query_Ctx, op_i: u32, dest: rawptr, lo, hi: u64) -> core_pkg.Shape_Fault #no_bounds_check {
	op := &r.ops[op_i]
	// A token starting with `-` or a digit is a number the walk just checked, so `r.num` holds its digits.
	is_number := r.src[lo] == '-' || (r.src[lo] >= '0' && r.src[lo] <= '9')
	#partial switch op.kind {
	case .Bool:
		return shape_leaf_bool(r.src, lo, dest, op.width)
	case .Int, .Uint:
		if !is_number {
			return .Wrong_Kind
		}
		return shape_leaf_number_int(r, lo, hi, dest, op.width, op.kind == .Int)
	case .Float:
		return shape_leaf_float(r, lo, hi, dest, op.width)
	case .String:
		return shape_leaf_string(r, r.src, lo, hi, dest, q.str_escaped, u64(q.str_first_esc))
	case .Null:
		return .None if r.src[lo] == 'n' else .Wrong_Kind
	case .Enum_Int, .Enum_Uint:
		if !r.enum_ints {
			return shape_leaf_enum_name(r.src, lo, hi, dest, op)
		}
		return core_pkg.shape_leaf_enum(r.src, lo, hi, dest, op)
	case .Wide_Int, .Wide_Uint:
		return core_pkg.shape_leaf_wide(r.src, lo, hi, dest, op.kind == .Wide_Int)
	case .Cstring:
		return shape_leaf_cstring(r, r.src, lo, hi, dest, q.str_escaped, u64(q.str_first_esc))
	case .Rune:
		return shape_leaf_rune(r.src, lo, hi, dest, q.str_escaped)
	case .Raw:
		return shape_leaf_raw(r, r.src, lo, hi, dest)
	case .Hook:
		return shape_leaf_hook(r, r.src, lo, hi, dest, op)
	case .Decoded:
		return shape_leaf_decoded(r, r.src, lo, hi, dest, q.str_escaped, u64(q.str_first_esc), true)
	case .Number:
		return shape_leaf_number(r, lo, hi, dest)
	case .Digits:
		if !is_number {
			return .Wrong_Kind
		}
		return shape_leaf_raw(r, r.src, lo, hi, dest)
	case .Any:
		return shape_leaf_any(r, r.src, lo, hi, dest, q.str_escaped, u64(q.str_first_esc), true)
	case .Pointer, .Union:
		// Only `null` gets here, or a scalar no union arm takes: any other token was unwrapped at its open. A
		// `.Last` repeat may have filled the target before.
		if r.src[lo] != 'n' {
			return .Wrong_Kind
		}
		return core_pkg.shape_leaf_null(r, op, dest)
	}
	unreachable()
}

// The container open at walk frame `idx` closed: core's transition, a container read whole going to
// `shape_leaf_container`.
shape_close :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, idx: u64) -> Maybe(Error) {
	return core_pkg.shape_close(q.shape, idx, s.pos, shape_leaf_container)
}
