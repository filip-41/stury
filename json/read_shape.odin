package json

// Lowering a `Type_Plan` into the read shape `unmarshal` walks (`core_pkg.Read_Shape`): one shape op per plan
// op and one shape field per plan field, at the same indices, so tags, field order and omitempty are the
// ones `marshal` writes by. A type unmarshal cannot read lowers to `.Unsupported`, and a shape that reaches
// one is refused before any byte is read.

import "base:runtime"
import "core:reflect"
import core_pkg "../core"

// The plan's read shape, lowered on first use and kept on the plan, as is an `.Unsupported` refusal. Only an
// `.Out_Of_Memory` refusal leaves the plan as it was, so the next call lowers again.
@(private)
read_shape_of :: proc(p: ^Type_Plan) -> (shape: ^core_pkg.Read_Shape, err: Maybe(Unmarshal_Error)) {
	if len(p.read.ops) > 0 {
		return &p.read, nil
	}
	if p.read_refused != nil {
		return nil, p.read_refused
	}
	if p.opts_lost {
		return nil, Unmarshal_Error{kind = .Out_Of_Memory}
	}
	root, perr := plan_op(p, type_info_of(p.root))
	if perr != .None {
		return nil, Unmarshal_Error{kind = .Out_Of_Memory}
	}
	r := &p.read
	defer if err != nil {
		core_pkg.read_shape_destroy(r)
	}
	alloc := p.ops.allocator
	oerr, ferr, herr: runtime.Allocator_Error
	r.ops, oerr = make([dynamic]core_pkg.Shape_Op, len(p.ops), alloc)
	r.fields, ferr = make([dynamic]core_pkg.Shape_Field, len(p.fields), alloc)
	r.wide = make([dynamic]u64, alloc)
	r.hooks, herr = make([]core_pkg.Shape_Hook, len(p.opts.hooks), alloc)
	if oerr != nil || ferr != nil || herr != nil {
		return nil, Unmarshal_Error{kind = .Out_Of_Memory}
	}
	r.root = root
	for h, k in p.opts.hooks {
		// One proc type: both answers are a `Maybe` of a u8 enum, and `Shape_Fault` numbers its kinds as
		// `Unmarshal_Error_Kind` does.
		r.hooks[k] = cast(core_pkg.Shape_Hook)h.read
	}
	widest := -1
	for i in 0 ..< len(p.ops) {
		if lower_op(p, u32(i)) != nil {
			return nil, Unmarshal_Error{kind = .Out_Of_Memory}
		}
		if r.ops[i].kind == .Map {
			widest = max(widest, int(r.ops[i].stride))
		}
	}
	for &op in r.ops {
		#partial switch op.kind {
		case .Struct:
			op.members_fused = struct_fuses(r, &op)
		case .Slice, .Dynamic:
			op.elements_fused = r.ops[op.elem].kind in core_pkg.SHAPE_WHOLE_LEAVES
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
	descent_seen, derr := make([]bool, len(r.ops), alloc)
	if derr != nil {
		return nil, Unmarshal_Error{kind = .Out_Of_Memory}
	}
	r.descends = shape_descends(r, root, descent_seen)
	delete(descent_seen, alloc)
	if widest >= 0 {
		zero, zerr := make([]u8, widest, alloc)
		if zerr != nil {
			return nil, Unmarshal_Error{kind = .Out_Of_Memory}
		}
		r.zero = zero
	}
	visited, verr := make([]bool, len(r.ops), alloc)
	if verr != nil {
		return nil, Unmarshal_Error{kind = .Out_Of_Memory}
	}
	uerr := Unmarshal_Error{kind = .Unsupported}
	refused := shape_refused(p, root, visited, &uerr)
	delete(visited, alloc)
	if refused {
		p.read_refused = uerr
		return nil, uerr
	}
	return r, nil
}

// Lower plan op `i` into `p.read.ops[i]`, and a struct's fields or a union's arms into `p.read.fields`.
@(private = "file")
lower_op :: proc(p: ^Type_Plan, i: u32) -> (err: runtime.Allocator_Error) {
	op := p.ops[i]
	out := &p.read.ops[i]
	base := runtime.type_info_base(op.info)
	#partial switch op.kind {
	case .Null, .Bool, .Int, .Uint, .Wide_Int, .Wide_Uint, .Float, .String, .Cstring, .Rune, .Raw, .Decoded, .Number, .Digits:
		out.kind = op.kind
	case .Enum_Int, .Enum_Uint:
		out.kind = op.kind
		out.enum_info = &base.variant.(runtime.Type_Info_Enum)
	case .Struct:
		return lower_struct(p, i, u32(base.size))
	case .Slice, .Dynamic, .Array, .Fixed_List:
		out.kind = op.kind
		out.elem = op.elem
		out.count = op.count
		out.stride = op.stride
		out.len_offset = op.len_offset
		out.size = u32(base.size)
		out.align = u32(p.ops[op.elem].info.align)
		return
	case .Pointer:
		pointee := base.variant.(runtime.Type_Info_Pointer).elem
		out.kind = .Pointer
		out.elem = op.elem
		out.stride = u32(pointee.size)
		out.align = u32(pointee.align)
		out.size = u32(base.size)
		return
	case .Union:
		lower_union(p, i, base.variant.(runtime.Type_Info_Union), u32(base.size))
		return
	case .Any:
		out.kind = .Any
		return
	case .Hook:
		if p.opts.hooks[op.elem].read != nil {
			out.kind = .Hook
			out.elem = op.elem
		}
		return
	case .Bit_Set:
		bs := base.variant.(runtime.Type_Info_Bit_Set)
		elem := p.ops[op.elem]
		out.kind = .Bit_Set
		out.required = u64(bs.lower)
		out.count = u32(bs.upper - bs.lower + 1)
		out.size = u32(op.size)
		out.width = 8
		if elem.kind == .Enum_Int || elem.kind == .Enum_Uint {
			out.enum_info = &runtime.type_info_base(elem.info).variant.(runtime.Type_Info_Enum)
		}
		return
	case .Map:
		m := base.variant.(runtime.Type_Info_Map)
		out.kind = .Map
		out.key = op.key
		out.elem = op.elem
		out.map_info = m.map_info
		out.stride = u32(m.value.size)
		out.size = u32(base.size)
		return
	case:
		return
	}
	out.width = op.size
	return
}

// A union op: its arms, and the arm each value class picks. Two arms that take one class leave it
// `.Unsupported`, which `shape_refused` reports as `.Ambiguous_Union`: the walk reads a value as it passes,
// so it cannot try one arm and fall back to another. Under a `union_tag`, a tagged union's named struct arms
// are the exception: they carry their tag name, which an object's tag member picks by, so they leave objects
// to the tag.
@(private = "file")
lower_union :: proc(p: ^Type_Plan, i: u32, u: runtime.Type_Info_Union, size: u32) {
	op := p.ops[i]
	out := &p.read.ops[i]
	out.elem = op.elem
	out.count = op.count
	if u.no_nil {
		out.arm_of[0] = core_pkg.UNION_NO_NIL
	}
	taken: bit_set[0 ..< core_pkg.SHAPE_CLASSES]
	tagged := op.tagged && len(p.opts.union_tag) > 0
	// Objects taken by an arm the tag does not name.
	untagged_objects := 0
	for arm, k in p.fields[op.elem:][:op.count] {
		classes := value_classes(p, arm.op, 0)
		if u.no_nil && arm.kind == .Null {
			classes = {0}
		}
		into := &p.read.fields[op.elem + u32(k)]
		into^ = {offset = u32(arm.offset), op = arm.op}
		if tagged && arm.key_hi > arm.key_lo {
			into.name = arm_tag_name(p, u.variants[k].id, u.variants[k].variant.(runtime.Type_Info_Named).name)
		} else if 1 in classes {
			untagged_objects += 1
		}
		if classes & taken - {1} != {} {
			return
		}
		taken |= classes
		for class in classes {
			out.arm_of[class] = u8(k + 1)
		}
	}
	if tagged {
		if untagged_objects > 0 {
			return
		}
		out.arm_of[1] = 0
		out.tagged = true
	} else if untagged_objects > 1 {
		return
	}
	out.kind = .Union
	out.tag_offset = u32(u.tag_offset)
	out.tag_size = 0 if reflect.type_info_union_is_pure_maybe(u) else u8(u.tag_type.size)
	out.size = size
}

// The non-null value classes (`core.Shape_Op.arm_of`) plan op `i` reads. `null` reads as a pointer's or a
// union's nil, never as an arm. `depth` stops a union that holds a pointer to itself: past 16 pointers or
// unions in a row an arm takes nothing more.
@(private = "file")
value_classes :: proc(p: ^Type_Plan, i: u32, depth: int) -> (classes: bit_set[0 ..< core_pkg.SHAPE_CLASSES]) {
	if depth > 16 {
		return
	}
	op := p.ops[i]
	switch op.kind {
	case .Unsupported, .Null:
	case .Bool:
		classes = {4}
	case .Int, .Uint, .Wide_Int, .Wide_Uint, .Float, .Number, .Digits:
		classes = {5}
	case .String, .Cstring, .Rune:
		classes = {3}
	case .Struct, .Map:
		classes = {1}
	case .Slice, .Dynamic, .Array, .Fixed_List, .Bit_Set:
		classes = {2}
	case .Enum_Int, .Enum_Uint:
		// A name or, under `enums = .Int`, a number: the plan serves both, so the arm takes both.
		classes = {3, 5}
	case .Decoded:
		classes = {3, 4, 5}
	case .Raw, .Any, .Hook:
		classes = {1, 2, 3, 4, 5}
	case .Pointer:
		classes = value_classes(p, op.elem, depth + 1)
	case .Union:
		for arm in p.fields[op.elem:][:op.count] {
			classes |= value_classes(p, arm.op, depth + 1)
		}
	}
	return
}

// A struct op: its field names, the first-byte filter and the required masks. More fields than the walk's
// seen words cover leave it `.Unsupported`. Two fields writing one JSON name left the plan op so already.
@(private = "file")
lower_struct :: proc(p: ^Type_Plan, i: u32, size: u32) -> runtime.Allocator_Error {
	op := p.ops[i]
	out := &p.read.ops[i]
	wide := (op.count - 1) / 64 if op.count > 64 else 0
	if wide > core_pkg.SHAPE_WIDE_WORDS {
		return nil
	}
	if wide > 0 {
		out.key = u32(len(p.read.wide))
		resize(&p.read.wide, len(p.read.wide) + int(wide)) or_return
	}
	fields := p.read.fields[op.elem:][:op.count]
	for pf, k in p.fields[op.elem:][:op.count] {
		name := p.sources[int(op.elem) + k].name
		fields[k] = core_pkg.Shape_Field{name = name, offset = u32(pf.offset), op = pf.op}
		colon_key_words(&fields[k])
		// An empty key's byte after the opening quote is the closing one.
		first := name[0] if len(name) > 0 else '"'
		out.first[first >> 6] |= u64(1) << (first & 63)
		if pf.required && k < 64 {
			out.required |= u64(1) << uint(k)
		} else if pf.required {
			p.read.wide[int(out.key) + (k - 64) / 64] |= u64(1) << uint((k - 64) % 64)
		}
	}
	out.kind = .Struct
	out.elem = op.elem
	out.count = op.count
	out.size = size
	return nil
}

// `f.colon_key` and `f.colon_mask`: `"name":` in two little-endian words, or the zero word no key matches
// when it takes more than sixteen bytes.
@(private = "file")
colon_key_words :: proc(f: ^core_pkg.Shape_Field) {
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

// Whether a struct op's members can be read by the walk's fused loop: at most 64 fields, so `Shape_Frame.seen`
// marks each, and every name written in printable ASCII with no quote or backslash, so a key whose bytes equal
// a name is that name's whole unescaped token.
@(private = "file")
struct_fuses :: proc(r: ^core_pkg.Read_Shape, op: ^core_pkg.Shape_Op) -> bool {
	if op.count > 64 {
		return false
	}
	for f in r.fields[op.elem:][:op.count] {
		for b in transmute([]u8)f.name {
			if b < ' ' || b >= 0x7f || b == '"' || b == '\\' {
				return false
			}
		}
	}
	return true
}

// Whether every op reachable from op `i` is one `shape_descend` reads: a fused struct, a sequence, or a
// scalar leaf that takes no container. `visited` stops a recursive type.
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
		// A list of flat records the walk reads in one loop (`shape_next_record`), which beats a call per record.
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

// Whether the shape reachable from op `i` holds an `.Unsupported` op, which an ambiguous union is too.
// `visited` stops a recursive type. On the way back out, each container puts its step in `err`'s path: a
// field's name, `Any` for an element or a map value, and nothing for a pointer or a union, which JSON does
// not write.
@(private = "file")
shape_refused :: proc(p: ^Type_Plan, i: u32, visited: []bool, err: ^Unmarshal_Error) -> bool {
	if visited[i] {
		return false
	}
	visited[i] = true
	r := &p.read
	op := r.ops[i]
	#partial switch op.kind {
	case .Unsupported:
		if p.ops[i].kind == .Union {
			err.kind = .Ambiguous_Union
		}
		return true
	case .Union:
		for arm in r.fields[op.elem:][:op.count] {
			if shape_refused(p, arm.op, visited, err) {
				return true
			}
		}
	case .Struct:
		for f in r.fields[op.elem:][:op.count] {
			if shape_refused(p, f.op, visited, err) {
				unmarshal_path_prepend(err, Name(f.name))
				return true
			}
		}
	case .Slice, .Dynamic, .Array, .Fixed_List:
		if shape_refused(p, op.elem, visited, err) {
			unmarshal_path_prepend(err, Any{})
			return true
		}
	case .Pointer:
		return shape_refused(p, op.elem, visited, err)
	case .Map:
		// The keys `shape_leaf_map_key` parses.
		keys :: bit_set[core_pkg.Shape_Kind]{.String, .Cstring, .Int, .Uint, .Enum_Int, .Enum_Uint, .Wide_Int, .Wide_Uint}
		if r.ops[op.key].kind not_in keys {
			return true
		}
		if shape_refused(p, op.elem, visited, err) {
			unmarshal_path_prepend(err, Any{})
			return true
		}
	}
	return false
}
