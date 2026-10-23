package scan

import core_pkg "../../core"
import "walk"
import "base:runtime"

// What the JSON walk reads a lowered shape by, set once on the shape when the plan lowers it
// (`Plan_Format.lowered`): the key words and first-byte filters its member matching compares, which structs and
// lists its fused loops read (`shape_take_members`, `shape_take_elements`), and whether the typed descent reads
// the whole shape (`Read_Shape.descends`). A reader of another format leaves all of it unset.

// `r` annotated for the walk, and a struct with more fields than the walk's seen words cover set back to
// `.Unsupported`.
shape_lowered :: proc(r: ^core_pkg.Read_Shape) -> runtime.Allocator_Error {
	for &op in r.ops {
		#partial switch op.kind {
		case .Struct:
			if op.count > 64 * (1 + walk.SHAPE_WIDE_WORDS) {
				op.kind = .Unsupported
				continue
			}
			for &f in r.fields[op.elem:][:op.count] {
				colon_key_words(&op, &f)
			}
			op.members_fused = struct_fuses(r, &op)
		case .Slice, .Dynamic:
			op.elements_fused = r.ops[op.elem].kind in SHAPE_WHOLE_LEAVES
		}
	}
	// The arm a union's tag picked reads every unknown key in `shape_key`, which tells the tag apart.
	for op in r.ops {
		if op.kind == .Union && op.tagged {
			for arm in r.fields[op.elem:][:op.count] {
				r.ops[arm.op].members_fused = false
			}
		}
	}
	seen := make([]bool, len(r.ops), r.ops.allocator) or_return
	r.descends = shape_descends(r, r.root, seen)
	delete(seen, r.ops.allocator)
	return nil
}

// `f.colon_key` and `f.colon_mask`: `"name":` in two little-endian words, or the zero word no key matches
// when it takes more than sixteen bytes. And the bit in `op.first` of the byte after the key's opening quote.
@(private = "file")
colon_key_words :: proc(op: ^core_pkg.Shape_Op, f: ^core_pkg.Shape_Field) {
	// An empty key's byte after the opening quote is the closing one.
	first := f.name[0] if len(f.name) > 0 else '"'
	op.first[first >> 6] |= u64(1) << (first & 63)
	spelled := len(f.name) + 3
	if spelled > 16 {
		f.colon_mask[0] = max(u64)
		return
	}
	for k in 0 ..< spelled {
		b := u64('"')
		if k == spelled - 1 {
			b = ':'
		} else if k > 0 && k <= len(f.name) {
			b = u64(f.name[k - 1])
		}
		f.colon_key[k / 8] |= b << (uint(k % 8) * 8)
		f.colon_mask[k / 8] |= u64(0xff) << (uint(k % 8) * 8)
	}
}

// Whether a struct op's members can be read by the fused loop: at most 64 fields, so `Shape_Frame.seen` marks
// each, and every name plain, so a key whose bytes equal a name is that name's whole token.
@(private = "file")
struct_fuses :: proc(r: ^core_pkg.Read_Shape, op: ^core_pkg.Shape_Op) -> bool {
	if op.count > 64 {
		return false
	}
	for f in r.fields[op.elem:][:op.count] {
		if !plain_key_name(f.name) {
			return false
		}
	}
	return true
}

// Whether `name` is written in printable ASCII with no quote or backslash, so a key whose bytes equal it is its
// whole unescaped token.
@(private = "file")
plain_key_name :: proc(name: string) -> bool {
	for b in transmute([]u8)name {
		if b < ' ' || b >= 0x7f || b == '"' || b == '\\' {
			return false
		}
	}
	return true
}

// Whether every op reachable from op `i` is one `shape_descend` reads: a fused struct, a sequence, or a scalar
// leaf that takes no container. `visited` stops a recursive type.
@(private = "file")
shape_descends :: proc(r: ^core_pkg.Read_Shape, i: u32, visited: []bool) -> bool {
	if visited[i] {
		return true
	}
	visited[i] = true
	op := r.ops[i]
	#partial switch op.kind {
	case .Null, .Bool, .Int, .Uint, .Enum_Int, .Enum_Uint, .Wide_Int, .Wide_Uint, .Float, .String, .Cstring, .Rune, .Decoded, .Number, .Digits:
		return true
	case .Struct:
		if !op.members_fused {
			return false
		}
		for f in r.fields[op.elem:][:op.count] {
			if !shape_descends(r, f.op, visited) {
				return false
			}
		}
		return true
	case .Slice, .Dynamic, .Array, .Fixed_List:
		// A list of flat records the walk reads in one loop (`shape_next_record`), which beats a call per
		// record.
		elem := r.ops[op.elem]
		if op.kind != .Array && op.kind != .Fixed_List && elem.kind == .Struct && shape_flat(r, elem) {
			return false
		}
		return shape_descends(r, op.elem, visited)
	}
	return false
}

// Whether every field of struct op `op` is a scalar.
@(private = "file")
shape_flat :: proc(r: ^core_pkg.Read_Shape, op: core_pkg.Shape_Op) -> bool {
	nested :: bit_set[core_pkg.Shape_Kind]{.Struct, .Slice, .Dynamic, .Array, .Fixed_List, .Map, .Bit_Set}
	for f in r.fields[op.elem:][:op.count] {
		if r.ops[f.op].kind in nested {
			return false
		}
	}
	return true
}

// The ops whose leaf writes every byte of its target, so a slot holding one needs no zeros first.
SHAPE_WHOLE_LEAVES :: bit_set[core_pkg.Shape_Kind]{.Bool, .Int, .Uint, .Float, .String}
