package core

// Lowering a `Type_Plan` into the read shape a typed reader walks (`Read_Shape`): one shape op per plan op and
// one shape field per plan field, at the same indices, so tags, field order and omitempty are the ones the
// writer uses. A type the reader cannot read lowers to `.Unsupported`, and a shape that reaches one is refused
// before any byte is read. A format annotates the shape for its own walk with `Plan_Format.lowered`.

import "base:runtime"
import "core:reflect"

// The plan's read shape, lowered on first use and kept on the plan, as is a refusal. A plan that cannot compile
// its root type refuses with `.Unsupported` (`.Bad_Tag` for a tag flag the format does not know), and every
// later call answers the same. `.Out_Of_Memory` alone leaves `read_refused` unset, so a later call lowers
// again: it is the one failure an allocator may stop reporting.
read_shape_of :: proc(p: ^Type_Plan) -> (shape: ^Read_Shape, err: Maybe(Unmarshal_Error)) {
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
	switch perr {
	case .None:
		// The plan compiled every type the read reaches: lower it below.
	case .Out_Of_Memory:
		return nil, Unmarshal_Error{kind = .Out_Of_Memory}
	case .Bad_Name:
		p.read_refused = Unmarshal_Error{kind = .Unsupported}
		return nil, p.read_refused
	case .Bad_Tag:
		p.read_refused = Unmarshal_Error{kind = .Bad_Tag}
		return nil, p.read_refused
	}
	r := &p.read
	defer if err != nil {
		read_shape_destroy(r)
	}
	alloc := p.ops.allocator
	oerr, ferr, herr: runtime.Allocator_Error
	r.ops, oerr = make([dynamic]Shape_Op, len(p.ops), alloc)
	r.fields, ferr = make([dynamic]Shape_Field, len(p.fields), alloc)
	r.wide = make([dynamic]u64, alloc)
	r.hooks, herr = make([]Shape_Hook, len(p.opts.hooks), alloc)
	if oerr != nil || ferr != nil || herr != nil {
		return nil, Unmarshal_Error{kind = .Out_Of_Memory}
	}
	r.root = root
	for h, k in p.opts.hooks {
		r.hooks[k] = h.read
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
	if widest >= 0 {
		zero, zerr := make([]u8, widest, alloc)
		if zerr != nil {
			return nil, Unmarshal_Error{kind = .Out_Of_Memory}
		}
		r.zero = zero
	}
	if lowered := p.format.lowered; lowered != nil && lowered(r) != nil {
		return nil, Unmarshal_Error{kind = .Out_Of_Memory}
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
		out.arm_of[0] = UNION_NO_NIL
	}
	taken: bit_set[Value_Class]
	tagged := op.tagged && len(p.opts.union_tag) > 0
	// Objects taken by an arm the tag does not name.
	untagged_objects := 0
	for arm, k in p.fields[op.elem:][:op.count] {
		classes := value_classes(p, arm.op, 0)
		if u.no_nil && arm.kind == .Null {
			classes = {.Null}
		}
		into := &p.read.fields[op.elem + u32(k)]
		into^ = {offset = u32(arm.offset), op = arm.op}
		if tagged && arm.key_hi > arm.key_lo {
			into.name = arm_tag_name(p, u.variants[k].id, u.variants[k].variant.(runtime.Type_Info_Named).name)
		} else if .Object in classes {
			untagged_objects += 1
		}
		if classes & taken - {.Object} != {} {
			return
		}
		taken |= classes
		for class in classes {
			out.arm_of[u8(class)] = u8(k + 1)
		}
	}
	if tagged {
		if untagged_objects > 0 {
			return
		}
		out.arm_of[u8(Value_Class.Object)] = 0
		out.tagged = true
	} else if untagged_objects > 1 {
		return
	}
	out.kind = .Union
	out.tag_offset = u32(u.tag_offset)
	out.tag_size = 0 if reflect.type_info_union_is_pure_maybe(u) else u8(u.tag_type.size)
	out.size = size
}

// Returns the non-null value classes that plan op `i` reads. `null` reads as a pointer's or a union's nil, never
// as an arm. `depth` bounds a union that holds a pointer to itself: past 16 nested pointers or unions, an arm
// accepts no further class.
@(private = "file")
value_classes :: proc(p: ^Type_Plan, i: u32, depth: int) -> (classes: bit_set[Value_Class]) {
	if depth > 16 {
		return
	}
	op := p.ops[i]
	switch op.kind {
	case .Unsupported, .Null:
	case .Bool:
		classes = {.Bool}
	case .Int, .Uint, .Wide_Int, .Wide_Uint, .Float, .Number, .Digits:
		classes = {.Number}
	case .String, .Cstring, .Rune:
		classes = {.String}
	case .Struct, .Map:
		classes = {.Object}
	case .Slice, .Dynamic, .Array, .Fixed_List, .Bit_Set:
		classes = {.Array}
	case .Enum_Int, .Enum_Uint:
		// A name or, under `enums = .Int`, a number: the plan serves both, so the arm takes both.
		classes = {.String, .Number}
	case .Decoded:
		classes = {.String, .Bool, .Number}
	case .Raw, .Any, .Hook:
		classes = {.Object, .Array, .String, .Bool, .Number}
	case .Pointer:
		classes = value_classes(p, op.elem, depth + 1)
	case .Union:
		for arm in p.fields[op.elem:][:op.count] {
			classes |= value_classes(p, arm.op, depth + 1)
		}
	}
	return
}

// Lowers a struct op: its field names and required-field masks. Two fields with the same name have already made
// the plan op `.Unsupported`.
@(private = "file")
lower_struct :: proc(p: ^Type_Plan, i: u32, size: u32) -> runtime.Allocator_Error {
	op := p.ops[i]
	out := &p.read.ops[i]
	if wide := (op.count - 1) / 64 if op.count > 64 else 0; wide > 0 {
		out.key = u32(len(p.read.wide))
		resize(&p.read.wide, len(p.read.wide) + int(wide)) or_return
	}
	fields := p.read.fields[op.elem:][:op.count]
	for pf, k in p.fields[op.elem:][:op.count] {
		name := p.sources[int(op.elem) + k].name
		fields[k] = Shape_Field{name = name, offset = u32(pf.offset), op = pf.op}
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

// Whether the shape reachable from op `i` holds an `.Unsupported` op, which an ambiguous union is too.
// `visited` stops a recursive type. On the way back out, each container puts its step in `err`'s path: a
// field's name, `Any` for an element or a map value, and nothing for a pointer or a union, which take no
// step.
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
		} else if p.ops[i].refused {
			unmarshal_path_prepend(err, Name(p.sources[p.ops[i].key].name))
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
		// The kinds a map key's text can be read as.
		keys :: bit_set[Shape_Kind]{.String, .Cstring, .Int, .Uint, .Enum_Int, .Enum_Uint, .Wide_Int, .Wide_Uint}
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
