package typed

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:strconv"
import "core:time"
import "stury:lib/core/tape"

// A typed write gives a value of the plan's type to a writer as tokens, by the same plan a read fills it by: the
// members' names, renames, enum spellings, `-` and `omitempty` come from it, so a write then a read returns the value.
// A struct's members go in the plan's order and a map's entries in the order its table holds them. The walk keeps its
// open containers on a stack of its own, inline up to `INLINE_FRAMES` and spilled to the allocator past that, so a
// value nested as deep as its memory holds takes no native recursion.

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

// What a scalar is written as: its kind and text, which lives in the caller's buffer or in the value itself.
@(private)
Scalar :: struct {
	kind: tape.Token_Kind,
	text: string,
}

@(private)
SCALAR_ROOM :: 64

// Open containers kept in the stack frame of `marshal`; deeper values spill to the allocator.
@(private)
INLINE_FRAMES :: 64

// Writes the value `value` points at, of type `T`, by `plan` (or a plan made for `T` under `tag_key` and freed on
// return when `plan` is nil), to `w` by `token`, one call each. Returns `werr` for the first error `token` or `tag`
// returns (leaving the writer at a prefix), or `err` for a bad plan/value, a `Raw` member, an out-of-range `time.Time`,
// or an allocator failure. A target that tags a date-time gives `tag`, called with "datetime" before a `time.Time`.
marshal :: proc(value: rawptr, T: typeid, tag_key: string, plan: ^Plan, w: ^$W, $token: proc(w: ^W, kind: tape.Token_Kind, text: string) -> $E, allocator := context.allocator, tag: proc(w: ^W, name: string) -> E = nil) -> (werr: E, err: tape.Error) {
	if value == nil {
		return {}, tape.Bad_Option{"value"}
	}
	plan := plan
	made: Plan
	if plan == nil {
		if made, err = plan_make(T, tag_key, {}, allocator); err != nil {
			return {}, err
		}
		plan = &made
	} else if plan.type != T || plan.tag != tag_key || plan.root == nil {
		return {}, tape.Bad_Option{"plan"}
	}
	defer if plan == &made {
		plan_destroy(&made)
	}
	inline_frames: [INLINE_FRAMES]Write_Frame = ---
	frames := raw_data(inline_frames[:])
	sp, cap_frames := 0, INLINE_FRAMES
	defer if cap_frames > INLINE_FRAMES {
		runtime.mem_free_with_size(frames, cap_frames * size_of(Write_Frame), allocator)
	}
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
				tag_v := u32(load_size(at + uintptr(m.tag), int(m.tag_size)))
				arm: ^Arm
				for &a in plan.arms[m.arms:][:m.count] {
					if a.tag == tag_v {
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
			if werr = token(w, .Null, ""); werr != nil {
				return
			}
		case rec.kind == .Struct || rec.kind == .Required:
			if !push_frame(&frames, &sp, &cap_frames, Write_Frame{.Struct, rec, at, 0, int(m.count)}, allocator, &err) {
				return
			}
			if werr = token(w, .Object, ""); werr != nil {
				return
			}
		case rec.kind == .Slice || rec.kind == .Dynamic || rec.kind == .Array:
			data, n := at, int(m.count)
			if rec.kind != .Array {
				raw := (^runtime.Raw_Slice)(at)
				data, n = uintptr(raw.data), raw.len
			}
			if !push_frame(&frames, &sp, &cap_frames, Write_Frame{.List, rec, data, 0, n}, allocator, &err) {
				return
			}
			if werr = token(w, .Array, ""); werr != nil {
				return
			}
		case rec.kind == .Map:
			if !push_frame(&frames, &sp, &cap_frames, Write_Frame{.Map, rec, at, 0, runtime.map_cap((^runtime.Raw_Map)(at)^)}, allocator, &err) {
				return
			}
			if werr = token(w, .Object, ""); werr != nil {
				return
			}
		case rec.kind == .Bit_Set:
			if !push_frame(&frames, &sp, &cap_frames, Write_Frame{.Bits, rec, at, 0, int(m.count)}, allocator, &err) {
				return
			}
			if werr = token(w, .Array, ""); werr != nil {
				return
			}
		case:
			s, serr := scalar_of(plan, rec, at, &buf)
			if serr != nil {
				return {}, serr
			}
			// A `time.Time` is a date-time, which a target that tags them does.
			if tag != nil && rec.kind == .Time {
				if werr = tag(w, "datetime"); werr != nil {
					return
				}
			}
			if werr = token(w, s.kind, s.text); werr != nil {
				return
			}
		}
		// The next value: a member, an element, an entry or a bit, or the close of the container that has no more.
		next: for {
			if sp == 0 {
				return
			}
			f := &frames[sp - 1]
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
					if werr = token(w, .Key, mm.name); werr != nil {
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
					text := key_text(plan, f.rec, key, &buf)
					if werr = token(w, .Key, text); werr != nil {
						return
					}
					rec, at = element_of(f.rec), runtime.map_cell_index_dynamic(vs, info.vs, uintptr(i))
					break next
				}
			case .Bits:
				mm := &plan.meta[f.rec.meta]
				limit := min(f.n, int(mm.size) * 8)
				for f.i < limit {
					i := f.i
					f.i += 1
					if ((^u8)(f.data + uintptr(i >> 3))^ >> uint(i & 7)) & 1 == 0 {
						continue
					}
					elem := element_of(f.rec)
					v := mm.lower + i64(i)
					text, named := spell_enum_value(plan, &plan.meta[elem.meta], v, &buf)
					if werr = token(w, .String if named else .Number, text); werr != nil {
						return
					}
					continue next
				}
			}
			if werr = token(w, .Close, ""); werr != nil {
				return
			}
			sp -= 1
		}
	}
}

@(private)
push_frame :: #force_inline proc(frames: ^[^]Write_Frame, sp, cap_frames: ^int, frame: Write_Frame, allocator: runtime.Allocator, err: ^tape.Error) -> bool #no_bounds_check {
	if sp^ == cap_frames^ && !grow_frames(frames, cap_frames, allocator, err) {
		return false
	}
	frames^[sp^] = frame
	sp^ += 1
	return true
}

@(private, cold)
grow_frames :: #force_no_inline proc(frames: ^[^]Write_Frame, cap_frames: ^int, allocator: runtime.Allocator, err: ^tape.Error) -> bool {
	next_cap := cap_frames^ * 2
	raw, aerr := runtime.mem_alloc_non_zeroed(next_cap * size_of(Write_Frame), align_of(Write_Frame), allocator)
	if aerr != nil || raw_data(raw) == nil {
		err^ = aerr if aerr != nil else runtime.Allocator_Error.Out_Of_Memory
		return false
	}
	grown := ([^]Write_Frame)(raw_data(raw))
	intrinsics.mem_copy_non_overlapping(grown, frames^, cap_frames^ * size_of(Write_Frame))
	if cap_frames^ > INLINE_FRAMES {
		runtime.mem_free_with_size(frames^, cap_frames^ * size_of(Write_Frame), allocator)
	}
	frames^, cap_frames^ = grown, next_cap
	return true
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
	bytes := uintptr(m.size)
	#partial switch rec.kind {
	case .String, .Slice, .Dynamic:
		return (^runtime.Raw_Slice)(at).len == 0
	case .Map:
		return runtime.map_len((^runtime.Raw_Map)(at)^) == 0
	case .Maybe, .Ptr, .Union:
		return is_unset(plan, rec, at)
	case .Array:
		bytes = uintptr(m.size) * uintptr(m.count)
	}
	for i in 0 ..< bytes {
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
	if m.signed {
		return strconv.write_int(buf[:], value, 10), false
	}
	return strconv.write_uint(buf[:], u64(value), 10), false
}

// The text of the map key at `key`, of a map record `rec`: a string, an integer or an enum's name.
@(private)
key_text :: proc(plan: ^Plan, rec: ^Record, key: uintptr, buf: ^[SCALAR_ROOM]u8) -> string {
	m := &plan.meta[rec.meta]
	#partial switch m.key_kind {
	case .String:
		return (^string)(key)^
	case .Enum:
		size := int(m.map_info.ks.size_of_type)
		v := load_size(key, size)
		signed := is_signed(m.enum_info.base)
		text, _ := spell_enum_value(plan, &Meta{enum_info = m.enum_info, signed = signed}, sign_extend(v, size) if signed else i64(v), buf)
		return text
	case .I8, .I16, .I32, .I64:
		return strconv.write_int(buf[:], sign_extend(load_size(key, int(m.map_info.ks.size_of_type)), int(m.map_info.ks.size_of_type)), 10)
	}
	return strconv.write_uint(buf[:], load_size(key, int(m.map_info.ks.size_of_type)), 10)
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

// The token of the scalar of `rec` at `at`, spelled into `buf` without allocating.
@(private)
scalar_of :: proc(plan: ^Plan, rec: ^Record, at: uintptr, buf: ^[SCALAR_ROOM]u8) -> (s: Scalar, err: tape.Error) {
	m := &plan.meta[rec.meta]
	#partial switch rec.kind {
	case .String:
		return {.String, (^string)(at)^}, nil
	case .Bool:
		return {.True if (^bool)(at)^ else .False, ""}, nil
	case .Bool_Wide:
		return {.True if load_size(at, int(m.size)) != 0 else .False, ""}, nil
	case .I8, .I16, .I32, .I64:
		return {.Number, strconv.write_int(buf[:], sign_extend(load_size(at, int(m.size)), int(m.size)), 10)}, nil
	case .U8, .U16, .U32, .U64:
		return {.Number, strconv.write_uint(buf[:], load_size(at, int(m.size)), 10)}, nil
	case .F32:
		return {.Number, float_text(buf, f64((^f32)(at)^), 32)}, nil
	case .F64:
		return {.Number, float_text(buf, (^f64)(at)^, 64)}, nil
	case .Enum:
		signed := is_signed(m.enum_info.base)
		raw := load_size(at, int(m.size))
		text, named := spell_enum_value(plan, &Meta{enum_info = m.enum_info, signed = signed}, sign_extend(raw, int(m.size)) if signed else i64(raw), buf)
		return {.String if named else .Number, text}, nil
	case .Time:
		text, ok := rfc3339_text((^time.Time)(at)^, buf)
		if !ok {
			return {}, tape.Bad_Option{"time"}
		}
		return {.String, text}, nil
	}
	return {}, tape.Bad_Option{"raw"}
}

// Formats `t` in UTC RFC 3339 into `buf` with no allocation. False outside years 0..9999.
@(private)
rfc3339_text :: proc(t: time.Time, buf: ^[SCALAR_ROOM]u8) -> (string, bool) #no_bounds_check {
	dt, ok := time.time_to_datetime(t)
	if !ok || dt.year < 0 || dt.year >= 10_000 {
		return "", false
	}
	put_digits :: #force_inline proc "contextless" (dst: []u8, at: int, width: int, val: i64) #no_bounds_check {
		v := val
		for k := width - 1; k >= 0; k -= 1 {
			dst[at + k] = '0' + u8(v % 10)
			v /= 10
		}
	}
	put_digits(buf[:], 0, 4, dt.year)
	buf[4] = '-'
	put_digits(buf[:], 5, 2, i64(dt.month))
	buf[7] = '-'
	put_digits(buf[:], 8, 2, i64(dt.day))
	buf[10] = 'T'
	put_digits(buf[:], 11, 2, i64(dt.hour))
	buf[13] = ':'
	put_digits(buf[:], 14, 2, i64(dt.minute))
	buf[16] = ':'
	put_digits(buf[:], 17, 2, i64(dt.second))
	o := 19
	nanos := t._nsec % 1_000_000_000
	if nanos < 0 {
		nanos += 1_000_000_000
	}
	if nanos != 0 {
		buf[o] = '.'
		o += 1
		digits := 9
		for nanos % 10 == 0 {
			nanos /= 10
			digits -= 1
		}
		put_digits(buf[:], o, digits, nanos)
		o += digits
	}
	buf[o] = 'Z'
	o += 1
	return string(buf[:o]), true
}

// The shortest text of `f` that reads back as it, with no plus sign and `.0` appended to a finite whole float so
// `-0.0` keeps its sign bit and formats that tell floats from integers preserve the float kind.
@(private)
float_text :: proc(buf: ^[SCALAR_ROOM]u8, f: f64, bits: int) -> string #no_bounds_check {
	raw := strconv.write_float(buf[:len(buf) - 2], f, 'g', -1, bits)
	start := 1 if len(raw) > 0 && raw[0] == '+' else 0
	text := raw[start:]
	if !math.is_nan(f) && !math.is_inf(f) {
		for c in transmute([]u8)text {
			if c == '.' || c == 'e' || c == 'E' {
				return text
			}
		}
		end := start + len(text)
		buf[end], buf[end + 1] = '.', '0'
		return string(buf[start:end + 2])
	}
	return text
}
