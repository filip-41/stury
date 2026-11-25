package typed

import "base:runtime"
import "core:strconv"
import "core:time"
import "stury:lib/core/tape"

// A typed write gives a value of the plan's type to a writer as tokens, by the same plan a read fills it by: the
// members' names, renames, enum spellings, `-` and `omitempty` come from it, so a write then a read returns the value.
// A struct's members go in the plan's order and a map's entries in the order its table holds them. The walk keeps its
// open containers on a stack of its own, so a value nested as deep as its memory holds takes no native recursion.

// Why a plan or a value has no tokens.
Marshal_Refusal :: enum u8 {
	None,
	// The type holds a `Raw`, which is a text of one format and no token.
	Raw,
	// A `time.Time` outside the years 0 to 9999.
	Time,
}

@(private)
Write_Frame_Kind :: enum u8 {
	Struct,
	List,
	Map,
	Bits,
}

// An open container: `data` is a struct's base, a list's first element, a map or a bit set's own bytes, and `i` the
// next of its `n` members, elements, buckets or bits.
@(private)
Write_Frame :: struct {
	kind: Write_Frame_Kind,
	rec:  ^Record,
	data: uintptr,
	i, n: int,
}

// What a scalar is written as: its kind and text, which lives in the caller's buffer or in `held`.
@(private)
Scalar :: struct {
	kind: tape.Token_Kind,
	text: string,
	held: []u8,
}

@(private)
SCALAR_ROOM :: 64

// Writes the value `value` points at, of the type `plan` is of, to `w` by `token`, one call each, with `err` the first
// error `token` returns, whose writer then holds a prefix. A value the plan has no tokens for is `refusal`. The frames
// of open containers come from `allocator`, so a refused allocation stops the write with the writer at a prefix and
// `refusal` `.None`, as a `token` error would, but through `Allocator_Error`. A target that tags a date-time gives `tag`,
// which is called with "datetime" before the token of a `time.Time`.
marshal :: proc(plan: ^Plan, value: rawptr, w: ^$W, $token: proc(w: ^W, kind: tape.Token_Kind, text: string) -> $E, allocator := context.allocator, tag: proc(w: ^W, name: string) -> E = nil) -> (err: E, refusal: Marshal_Refusal, memory: runtime.Allocator_Error) {
	stack: [dynamic]Write_Frame
	stack.allocator = allocator
	defer delete(stack)
	buf: [SCALAR_ROOM]u8 = ---
	rec, at := (^Record)(uintptr(plan.root) - size_of(Record)), uintptr(value)
	for {
		null := false
		resolve: for {
			m := &plan.meta[rec.meta]
			#partial switch rec.kind {
			case .Maybe:
				if m.tag_size == 0 && (^uintptr)(at)^ == 0 || m.tag_size != 0 && load_size(at + uintptr(m.tag), int(m.tag_size)) == 0 {
					null = true
					break resolve
				}
				rec = element_of(rec)
			case .Ptr:
				to := (^uintptr)(at)^
				if to == 0 {
					null = true
					break resolve
				}
				rec, at = element_of(rec), to
			case .Union:
				tag := u32(load_size(at + uintptr(m.tag), int(m.tag_size)))
				arm: ^Arm
				for &a in plan.arms[m.arms:][:m.count] {
					if a.tag == tag {
						arm = &a
					}
				}
				if arm == nil {
					null = true
					break resolve
				}
				rec = &plan.records[arm.first - 1]
			case:
				break resolve
			}
		}
		m := &plan.meta[rec.meta]
		switch {
		case null:
			if err = token(w, .Null, ""); err != nil {
				return
			}
		case rec.kind == .Struct || rec.kind == .Required:
			if _, memory = append(&stack, Write_Frame{.Struct, rec, at, 0, int(m.count)}); memory != nil {
				return
			}
			if err = token(w, .Object, ""); err != nil {
				return
			}
		case rec.kind == .Slice || rec.kind == .Dynamic || rec.kind == .Array:
			data, n := at, int(m.count)
			if rec.kind != .Array {
				raw := (^runtime.Raw_Slice)(at)
				data, n = uintptr(raw.data), raw.len
			}
			if _, memory = append(&stack, Write_Frame{.List, rec, data, 0, n}); memory != nil {
				return
			}
			if err = token(w, .Array, ""); err != nil {
				return
			}
		case rec.kind == .Map:
			if _, memory = append(&stack, Write_Frame{.Map, rec, at, 0, runtime.map_cap((^runtime.Raw_Map)(at)^)}); memory != nil {
				return
			}
			if err = token(w, .Object, ""); err != nil {
				return
			}
		case rec.kind == .Bit_Set:
			if _, memory = append(&stack, Write_Frame{.Bits, rec, at, 0, int(m.count)}); memory != nil {
				return
			}
			if err = token(w, .Array, ""); err != nil {
				return
			}
		case:
			s, why := scalar_of(plan, rec, at, &buf, allocator)
			if why != .None {
				return {}, why, nil
			}
			// A `time.Time` is a date-time, which a target that tags them does.
			if tag != nil && rec.kind == .Time {
				if err = tag(w, "datetime"); err != nil {
					delete(s.held, allocator)
					return
				}
			}
			err = token(w, s.kind, s.text)
			delete(s.held, allocator)
			if err != nil {
				return
			}
		}
		// The next value: a member, an element, an entry or a bit, or the close of the container that has no more.
		next: for {
			if len(stack) == 0 {
				return
			}
			f := &stack[len(stack) - 1]
			switch f.kind {
			case .Struct:
				block := ([^]Record)(f.rec.first)
				for f.i < f.n {
					member := &block[f.i]
					f.i += 1
					mm := &plan.meta[member.meta]
					at = f.data + uintptr(member.offset)
					if mm.omit_empty && is_empty(plan, member, at) || mm.omit_unset && is_unset(plan, member, at) {
						continue
					}
					if err = token(w, .Key, mm.name); err != nil {
						return
					}
					rec = member
					break next
				}
			case .List:
				if f.i < f.n {
					size := uintptr(plan.meta[f.rec.meta].size)
					rec, at = element_of(f.rec), f.data + uintptr(f.i) * size
					f.i += 1
					break next
				}
			case .Map:
				info := plan.meta[f.rec.meta].map_info
				raw := (^runtime.Raw_Map)(f.data)^
				ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw, info)
				for f.i < f.n {
					i := f.i
					f.i += 1
					if !runtime.map_hash_is_valid(hs[i]) {
						continue
					}
					key := runtime.map_cell_index_dynamic(ks, info.ks, uintptr(i))
					text, held, why := key_text(plan, f.rec, key, &buf, allocator)
					if why != .None {
						return {}, why, nil
					}
					err = token(w, .Key, text)
					delete(held, allocator)
					if err != nil {
						return
					}
					rec, at = element_of(f.rec), runtime.map_cell_index_dynamic(vs, info.vs, uintptr(i))
					break next
				}
			case .Bits:
				mm := &plan.meta[f.rec.meta]
				bits := load_size(f.data, int(mm.size))
				for f.i < f.n {
					i := f.i
					f.i += 1
					if bits >> uint(i) & 1 == 0 {
						continue
					}
					elem := element_of(f.rec)
					value := mm.lower + i64(i)
					text, named := spell_enum_value(plan, &plan.meta[elem.meta], value, &buf)
					if err = token(w, .String if named else .Number, text); err != nil {
						return
					}
					continue next
				}
			}
			if err = token(w, .Close, ""); err != nil {
				return
			}
			pop(&stack)
		}
	}
}

// The record a list's, map's, pointer's or `Maybe`'s `first` reads its element by, which lies before it.
@(private)
element_of :: #force_inline proc "contextless" (rec: ^Record) -> ^Record {
	return (^Record)(uintptr(rec.first) - size_of(Record))
}

// The `size` bytes at `at` as an unsigned integer.
@(private)
load_size :: proc "contextless" (at: uintptr, size: int) -> u64 {
	switch size {
	case 1: return u64((^u8)(at)^)
	case 2: return u64((^u16)(at)^)
	case 4: return u64((^u32)(at)^)
	}
	return (^u64)(at)^
}

// Whether the value of `rec` at `at` is the zero of its type, or an empty string, list or map.
@(private)
is_empty :: proc(plan: ^Plan, rec: ^Record, at: uintptr) -> bool {
	m := &plan.meta[rec.meta]
	#partial switch rec.kind {
	case .String, .Slice, .Dynamic:
		return (^runtime.Raw_Slice)(at).len == 0
	case .Map:
		return runtime.map_len((^runtime.Raw_Map)(at)^) == 0
	case .Maybe, .Ptr, .Union:
		return is_unset(plan, rec, at)
	}
	for i in 0 ..< uintptr(m.size) {
		if (^u8)(at + i)^ != 0 {
			return false
		}
	}
	return true
}

// Whether the pointer, `Maybe` or union of `rec` at `at` holds no value.
@(private)
is_unset :: proc(plan: ^Plan, rec: ^Record, at: uintptr) -> bool {
	m := &plan.meta[rec.meta]
	#partial switch rec.kind {
	case .Ptr:
		return (^uintptr)(at)^ == 0
	case .Maybe:
		return m.tag_size == 0 && (^uintptr)(at)^ == 0 || m.tag_size != 0 && load_size(at + uintptr(m.tag), int(m.tag_size)) == 0
	case .Union:
		tag := u32(load_size(at + uintptr(m.tag), int(m.tag_size)))
		for a in plan.arms[m.arms:][:m.count] {
			if a.tag == tag {
				return false
			}
		}
		return true
	}
	return false
}

// The text an enum's or bit set's `value` is written as, its member's name under `.Name` with `named` set, else its
// integer.
@(private)
spell_enum_value :: proc(plan: ^Plan, m: ^Meta, value: i64, buf: ^[SCALAR_ROOM]u8) -> (text: string, named: bool) {
	if plan.options.enums == .Name && m.enum_info != nil {
		for v, i in m.enum_info.values {
			if i64(v) == value {
				return m.enum_info.names[i], true
			}
		}
	}
	if m.signed || m.enum_info != nil {
		return strconv.write_int(buf[:], value, 10), false
	}
	return strconv.write_uint(buf[:], u64(value), 10), false
}

// The text of the map key at `key`, of a map record `rec`: a string, an integer or an enum's name.
@(private)
key_text :: proc(plan: ^Plan, rec: ^Record, key: uintptr, buf: ^[SCALAR_ROOM]u8, allocator: runtime.Allocator) -> (text: string, held: []u8, why: Marshal_Refusal) {
	m := &plan.meta[rec.meta]
	#partial switch m.key_kind {
	case .String:
		return (^string)(key)^, nil, .None
	case .Enum:
		size := int(m.map_info.ks.size_of_type)
		v := load_size(key, size)
		signed := is_signed(m.enum_info.base)
		text, _ = spell_enum_value(plan, &Meta{enum_info = m.enum_info, signed = signed}, sign_extend(v, size) if signed else i64(v), buf)
		return text, nil, .None
	case .I8, .I16, .I32, .I64:
		return strconv.write_int(buf[:], sign_extend(load_size(key, int(m.map_info.ks.size_of_type)), int(m.map_info.ks.size_of_type)), 10), nil, .None
	}
	return strconv.write_uint(buf[:], load_size(key, int(m.map_info.ks.size_of_type)), 10), nil, .None
}

@(private)
is_signed :: proc(ti: ^runtime.Type_Info) -> bool {
	if v, ok := runtime.type_info_base(ti).variant.(^runtime.Type_Info_Integer); ok {
		return v.signed
	}
	return false
}

@(private)
sign_extend :: proc "contextless" (v: u64, size: int) -> i64 {
	switch size {
	case 1: return i64(i8(v))
	case 2: return i64(i16(v))
	case 4: return i64(i32(v))
	}
	return i64(v)
}

// The token of the scalar of `rec` at `at`: its text in `buf`, or in a block from `allocator` that `held` names.
@(private)
scalar_of :: proc(plan: ^Plan, rec: ^Record, at: uintptr, buf: ^[SCALAR_ROOM]u8, allocator: runtime.Allocator) -> (s: Scalar, why: Marshal_Refusal) {
	m := &plan.meta[rec.meta]
	#partial switch rec.kind {
	case .String:
		return {.String, (^string)(at)^, nil}, .None
	case .Bool:
		return {.True if (^bool)(at)^ else .False, "", nil}, .None
	case .Bool_Wide:
		return {.True if load_size(at, int(m.size)) != 0 else .False, "", nil}, .None
	case .I8, .I16, .I32, .I64:
		return {.Number, strconv.write_int(buf[:], sign_extend(load_size(at, int(m.size)), int(m.size)), 10), nil}, .None
	case .U8, .U16, .U32, .U64:
		return {.Number, strconv.write_uint(buf[:], load_size(at, int(m.size)), 10), nil}, .None
	case .F32:
		return {.Number, float_text(buf, f64((^f32)(at)^), 32), nil}, .None
	case .F64:
		return {.Number, float_text(buf, (^f64)(at)^, 64), nil}, .None
	case .Enum:
		signed := is_signed(m.enum_info.base)
		raw := load_size(at, int(m.size))
		text, named := spell_enum_value(plan, &Meta{enum_info = m.enum_info, signed = signed}, sign_extend(raw, int(m.size)) if signed else i64(raw), buf)
		return {.String if named else .Number, text, nil}, .None
	case .Time:
		text, ok := time.time_to_rfc3339((^time.Time)(at)^, 0, true, allocator)
		if !ok {
			return {}, .Time
		}
		return {.String, text, transmute([]u8)text}, .None
	}
	return {}, .Raw
}

// The shortest text of `f` that reads back as it, with no plus sign.
@(private)
float_text :: proc(buf: ^[SCALAR_ROOM]u8, f: f64, bits: int) -> string {
	text := strconv.write_float(buf[:], f, 'g', -1, bits)
	return text[1:] if len(text) > 0 && text[0] == '+' else text
}
