package json

// Container and struct writers for `marshal`: compact/flat/eager structs, struct-array elements, sorted map
// keys, inline scalar text, and `omitempty`.

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import enc "encode"
import core_pkg "../core"

@(private)
write_elems :: proc(st: ^Marshal_Out, op: Plan_Op, data: rawptr, n: int) -> Encode_Error {
	elem := st.plan.ops[op.elem]
	if elem.kind == .Struct && !st.eager && n > 0 {
		return write_struct_elems(st, op, elem, data, n)
	}
	open_container(st, '[') or_return
	for k in 0 ..< n {
		element(st, k) or_return
		write_value(st, op.elem, rawptr(uintptr(data) + uintptr(k) * uintptr(op.stride))) or_return
	}
	return close_container(st, ']', n)
}

// The most bytes an integer is written in: `-9223372036854775808` and `18446744073709551615` are 20.
@(private)
MAX_INT_DIGITS :: 20

// Room past a field's key for its value when the value is written inline: an integer, a float, or the
// `true`/`false` word (one u64 store).
@(private)
FIELD_VALUE_ROOM :: max(MAX_INT_DIGITS, enc.F64_ROOM, size_of(u64))

// `true` and `false`, low byte first.
@(private)
TRUE_WORD :: u64(0x65_75_72_74)
@(private)
FALSE_WORD :: u64(0x65_73_6c_61_66)

// Write the `.Int`, `.Uint`, `.Float` or `.Bool` scalar of `size` bytes at `at` into `p`, which has
// FIELD_VALUE_ROOM bytes. Returns the count written.
@(private)
spell_scalar :: #force_inline proc(p: [^]u8, kind: core_pkg.Shape_Kind, at: rawptr, size: u8) -> (int, Encode_Error) #no_bounds_check {
	#partial switch kind {
	case .Int:
		return enc.spell_i64(p, read_int(at, size)), .None
	case .Uint:
		return enc.spell_u64(p, read_uint(at, size)), .None
	case .Float:
		x := read_float(at, size)
		if enc.is_non_finite(x) {
			return 0, .Non_Finite
		}
		return enc.spell_f64(p, x), .None
	}
	yes := read_uint(at, size) != 0
	intrinsics.unaligned_store((^u64)(p), TRUE_WORD if yes else FALSE_WORD)
	return 5 - int(yes), .None
}

// `spell_scalar` appended to `dst`.
@(private)
put_scalar :: proc(dst: ^[dynamic]u8, kind: core_pkg.Shape_Kind, at: rawptr, size: u8) -> Encode_Error {
	p := enc.put_room(dst, len(dst^), FIELD_VALUE_ROOM)
	if p == nil {
		return .Out_Of_Memory
	}
	enc.put_commit(dst, spell_scalar(p, kind, at, size) or_return)
	return .None
}

// `then_comma`: a `,` follows the closing brace, under the same reservation. Scalar fields and strings are
// written at a cursor kept out of `st.out`'s length, which is committed only around a nested value and at
// the end.
@(private)
write_struct :: proc(st: ^Marshal_Out, op: Plan_Op, data: rawptr, then_comma := false) -> Encode_Error #no_bounds_check {
	// A flat struct holds no element boundary, so a streaming write needs no `{` before its members.
	if st.eager && (st.pretty || !op.flat) {
		return write_struct_eager(st, op, data)
	}
	if st.depth == MAX_DEPTH {
		return .Too_Deep
	}
	if op.flat {
		return write_flat_struct(st, op, data, then_comma)
	}
	st.depth += 1
	st.nest += 1
	// Where the first written key's comma is, which becomes the `{`.
	first := -1
	w := len(st.out^)
	for k in op.elem ..< op.elem + op.count {
		// Re-read per field: a nested lazy compile may move `fields` and `keys`.
		f := st.plan.fields[k]
		at := rawptr(uintptr(data) + f.offset)
		if f.omitempty && is_empty(st.plan, f.op, at) {
			continue
		}
		n := int(f.key_hi - f.key_lo)
		key := raw_data(st.plan.keys[f.key_lo:])
		start := w
		if f.kind == .String {
			w = enc.spell_led_string(st.out, w, key, n, (^string)(at)^, false) or_return
		} else {
			p := enc.put_room(st.out, w, n + FIELD_VALUE_ROOM)
			if p == nil {
				return .Out_Of_Memory
			}
			enc.copy_lead(p, key, n)
			#partial switch f.kind {
			case .Int, .Uint, .Float, .Bool:
				w += n + (spell_scalar(p[n:], f.kind, at, f.size) or_return)
			case:
				enc.put_commit(st.out, w + n - len(st.out^))
				write_value(st, f.op, at) or_return
				w = len(st.out^)
			}
		}
		if first < 0 {
			first = start
		}
	}
	st.depth -= 1
	st.nest -= 1
	return close_object(st.out, first, w, first >= 0, then_comma)
}

// A flat struct (see `Plan_Op.flat`) in compact form: nothing nested is written, so no plan array moves
// and nothing is opened below it.
@(private)
write_flat_struct :: proc(st: ^Marshal_Out, op: Plan_Op, data: rawptr, then_comma: bool) -> Encode_Error #no_bounds_check {
	out := st.out
	keys := raw_data(st.plan.keys)
	start := len(out^)
	w := start
	for f in st.plan.fields[op.elem:][:op.count] {
		at := rawptr(uintptr(data) + f.offset)
		n := int(f.key_hi - f.key_lo)
		key := keys[f.key_lo:]
		if f.kind == .String {
			w = enc.spell_led_string(out, w, key, n, (^string)(at)^, false) or_return
			continue
		}
		p := enc.put_room(out, w, n + FIELD_VALUE_ROOM)
		if p == nil {
			return .Out_Of_Memory
		}
		enc.copy_lead(p, key, n)
		#partial switch f.kind {
		case .Int:
			w += n + (spell_scalar(p[n:], .Int, at, f.size) or_return)
		case .Uint:
			w += n + (spell_scalar(p[n:], .Uint, at, f.size) or_return)
		case .Float:
			w += n + (spell_scalar(p[n:], .Float, at, f.size) or_return)
		case .Bool:
			w += n + (spell_scalar(p[n:], .Bool, at, f.size) or_return)
		case .Enum_Int, .Enum_Uint:
			w = spell_flat_enum(st, f, key, p, n, w, at) or_return
		}
	}
	return close_object(out, start, w, op.count > 0, then_comma)
}

// An enum field of a flat struct after its key at `w`: the member's name, or its number under `enum_ints`.
// `p` is the room put for the key. A value no member has is refused, as `put_enum_int` refuses it. Returns the
// end of the field.
@(private = "file")
spell_flat_enum :: #force_inline proc(st: ^Marshal_Out, f: Plan_Field, key, p: [^]u8, n, w: int, at: rawptr) -> (end: int, err: Encode_Error) #no_bounds_check {
	m := enum_member(st.plan, st.plan.ops[f.op], at) or_return
	if st.enum_ints {
		if st.plan.ops[f.op].kind == .Enum_Int {
			return w + n + enc.spell_i64(p[n:], read_int(at, f.size)), .None
		}
		return w + n + enc.spell_u64(p[n:], read_uint(at, f.size)), .None
	}
	name := st.plan.keys[m.lo:m.hi]
	if len(name) > FIELD_VALUE_ROOM {
		return spell_flat_enum_long(st, key, n, w, name)
	}
	if len(name) >= 4 {
		enc.copy_lead(p[n:], raw_data(name), len(name))
	} else {
		// `"x"`, the one form shorter than a word.
		p[n], p[n + 1], p[n + 2] = name[0], name[1], name[2]
	}
	return w + n + len(name), .None
}

// A member name longer than the room put for the key. Growing keeps only the bytes before `w`, so the key is
// copied again.
@(private = "file")
spell_flat_enum_long :: #force_no_inline proc(st: ^Marshal_Out, key: [^]u8, n, w: int, name: []u8) -> (end: int, err: Encode_Error) {
	p := enc.put_room(st.out, w, n + len(name))
	if p == nil {
		return 0, .Out_Of_Memory
	}
	enc.copy_lead(p, key, n)
	enc.copy_lead(p[n:], raw_data(name), len(name))
	return w + n + len(name), .None
}

// After an object's last member at `w`: the `}` and, with `then_comma`, a `,`, committed. With `opened`
// the first key's comma at `start` becomes the `{`. Otherwise the object is `{}`.
@(private)
close_object :: #force_inline proc(out: ^[dynamic]u8, start, w: int, opened, then_comma: bool) -> Encode_Error #no_bounds_check {
	p := enc.put_room(out, w, 3)
	if p == nil {
		return .Out_Of_Memory
	}
	end := w
	if opened {
		raw_data(out^)[start] = '{'
	} else {
		p[0] = '{'
		p = p[1:]
		end += 1
	}
	p[0] = '}'
	p[1] = ','
	core_pkg.edge_publish(out, end + 1 + int(then_comma))
	return .None
}

// Compact elements that are all structs: each closes as `},`, and the last comma becomes the `]`.
@(private)
write_struct_elems :: proc(st: ^Marshal_Out, op, elem: Plan_Op, data: rawptr, n: int) -> Encode_Error {
	open_container(st, '[') or_return
	for k in 0 ..< n {
		write_struct(st, elem, rawptr(uintptr(data) + uintptr(k) * uintptr(op.stride)), true) or_return
	}
	st.depth -= 1
	st.nest -= 1
	raw_data(st.out^)[len(st.out^) - 1] = ']'
	return .None
}

// A struct opened before its members: pretty, streaming, or a tagged union's arm. A `tag` is that arm's
// tag name written as a JSON string, written first as the `union_tag` member.
@(private)
write_struct_eager :: proc(st: ^Marshal_Out, op: Plan_Op, data: rawptr, tag := "") -> Encode_Error {
	open_container(st, '{') or_return
	written := 0
	if len(tag) > 0 {
		element(st, 0) or_return
		enc.put_bytes(st.out, string(st.plan.keys[st.plan.tag_lo:st.plan.tag_hi])) or_return
		if st.pretty {
			enc.put_byte(st.out, ' ') or_return
		}
		enc.put_bytes(st.out, tag) or_return
		written = 1
	}
	for k in op.elem ..< op.elem + op.count {
		f := st.plan.fields[k]
		at := rawptr(uintptr(data) + f.offset)
		if f.omitempty && is_empty(st.plan, f.op, at) {
			continue
		}
		element(st, written) or_return
		enc.put_bytes(st.out, string(st.plan.keys[f.key_lo + 1:f.key_hi])) or_return
		if st.pretty {
			enc.put_byte(st.out, ' ') or_return
		}
		write_value(st, f.op, at) or_return
		written += 1
	}
	return close_container(st, '}', written)
}

@(private)
Map_Entry :: struct {
	key:    string, // the key as written between its quotes: the sort key
	lo, hi: u32, // the key as written, quotes included
	value:  rawptr,
}

// Keys sorted by their written bytes between the quotes, so the output depends only on the map's contents.
// The scratch lives in `st.out.allocator` and is freed before return.
@(private)
write_map :: proc(st: ^Marshal_Out, op: Plan_Op, data: rawptr) -> Encode_Error {
	m := (^runtime.Raw_Map)(data)^
	open_container(st, '{') or_return
	n := int(m.len)
	if n == 0 {
		return close_container(st, '}', 0)
	}
	info := runtime.type_info_base(op.info).variant.(runtime.Type_Info_Map)
	key_op := st.plan.ops[op.key]
	alloc := st.out.allocator
	keys, kerr := make([dynamic]u8, 0, 16 * n, alloc)
	defer delete(keys)
	entries, eerr := make([]Map_Entry, n, alloc)
	defer delete(entries, alloc)
	if kerr != nil || eerr != nil || keys == nil || entries == nil {
		return .Out_Of_Memory
	}
	ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(m, info.map_info)
	e := 0
	for bucket in 0 ..< uintptr(runtime.map_cap(m)) {
		runtime.map_hash_is_valid(hs[bucket]) or_continue
		lo := u32(len(keys))
		spell_map_key(&keys, st, key_op, rawptr(runtime.map_cell_index_dynamic(ks, info.map_info.ks, bucket))) or_return
		entries[e] = {lo = lo, hi = u32(len(keys)), value = rawptr(runtime.map_cell_index_dynamic(vs, info.map_info.vs, bucket))}
		e += 1
	}
	for &entry in entries[:e] {
		entry.key = string(keys[entry.lo + 1:entry.hi - 1])
	}
	slice.sort_by(entries[:e], proc(a, b: Map_Entry) -> bool {
		return a.key < b.key
	})
	for entry, k in entries[:e] {
		element(st, k) or_return
		enc.put_bytes(st.out, string(keys[entry.lo:entry.hi])) or_return
		enc.put_colon(st.out, st.pretty) or_return
		write_value(st, op.elem, entry.value) or_return
	}
	return close_container(st, '}', e)
}

// A map key as a JSON string: a string key as written (§5.1), an enum key's name, an integer key's digits in
// quotes.
@(private)
spell_map_key :: proc(dst: ^[dynamic]u8, st: ^Marshal_Out, key: Plan_Op, data: rawptr) -> Encode_Error {
	#partial switch key.kind {
	case .String:
		return enc.put_string(dst, (^string)(data)^)
	case .Cstring:
		return enc.put_string(dst, string((^cstring)(data)^))
	case .Enum_Int, .Enum_Uint:
		if !st.enum_ints {
			m := enum_member(st.plan, key, data) or_return
			return enc.put_bytes(dst, string(st.plan.keys[m.lo:m.hi]))
		}
	}
	enc.put_byte(dst, '"') or_return
	#partial switch key.kind {
	case .Int:
		enc.put_i64(dst, read_int(data, key.size)) or_return
	case .Uint:
		enc.put_u64(dst, read_uint(data, key.size)) or_return
	case .Wide_Int:
		put_wide(dst, (^u128)(data)^, true) or_return
	case .Wide_Uint:
		put_wide(dst, (^u128)(data)^, false) or_return
	case .Enum_Int, .Enum_Uint:
		put_enum_int(dst, st.plan, key, data) or_return
	}
	return enc.put_byte(dst, '"')
}

// omitempty: a nil pointer, a nil `any` or union, an empty string, `Raw` or `Digits`, an empty slice, dynamic
// array, fixed-capacity dynamic array, map or bit_set. `0`, `false` and `Null` are kept.
@(private)
is_empty :: proc(p: ^Type_Plan, idx: u32, data: rawptr) -> bool {
	op := p.ops[idx]
	#partial switch op.kind {
	case .Pointer:
		return (^rawptr)(data)^ == nil
	case .Any:
		a := (^any)(data)^
		return a.id == nil || a.data == nil
	case .Union:
		return union_arm_of(op, data) < 0
	case .Decoded:
		return (^Decoded)(data)^ == nil
	case .String, .Raw, .Digits:
		return len((^string)(data)^) == 0
	case .Cstring:
		cs := (^cstring)(data)^
		return cs == nil || len(cs) == 0
	case .Slice, .Dynamic:
		return (^runtime.Raw_Slice)(data).len == 0
	case .Fixed_List:
		return (^int)(uintptr(data) + uintptr(op.len_offset))^ == 0
	case .Map:
		return (^runtime.Raw_Map)(data).len == 0
	case .Bit_Set:
		bits: u128
		runtime.mem_copy_non_overlapping(&bits, data, int(op.size))
		return bits == 0
	case .Hook:
		// As its representation would be unhooked.
		#partial switch v in runtime.type_info_base(op.info).variant {
		case runtime.Type_Info_String:
			return len((^string)(data)^) == 0 if !v.is_cstring else len((^cstring)(data)^) == 0
		case runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array:
			return (^runtime.Raw_Slice)(data).len == 0
		case runtime.Type_Info_Map:
			return (^runtime.Raw_Map)(data).len == 0
		case runtime.Type_Info_Pointer:
			return (^rawptr)(data)^ == nil
		}
	}
	return false
}
