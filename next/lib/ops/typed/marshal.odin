package typed

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:time"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// A typed write gives a value of the plan's type to a writer as tokens (or direct JSON/CBOR bytes), by the same plan a
// read fills it by: the members' names, renames, enum spellings, `-` and `omitempty` come from it, so a write then a
// read returns the value. Open containers live on an explicit stack (inline up to `INLINE_FRAMES`, spilled past that).

@(private)
Write_Frame_Kind :: enum u8 {
	Struct,
	List,
	Map,
	Bits,
}

@(private)
Write_Frame :: struct {
	kind: Write_Frame_Kind,
	rec:  ^Record,
	data: uintptr,
	i, n: int,
}

@(private)
Scalar :: struct {
	kind: tape.Token_Kind,
	text: string,
}

@(private)
SCALAR_ROOM :: 64

// Open containers kept in the stack frame of `marshal*`; deeper values spill to the allocator.
@(private)
INLINE_FRAMES :: 64

// Why `marshal_json` or `marshal_cbor` refused a value (matches `write.Refusal` without importing `lib/ops/write`).
Marshal_Refusal :: enum u8 {
	None,
	No_Spelling,
	Malformed,
}

// Bytes reserved ahead of the cursor for inline leaf values (integers, floats, short strings, booleans, null, RFC 3339).
JSON_LEAF_ROOM :: 64

// Maximum indent bytes written in-line before falling back to the cold long-line emitter.
JSON_LINE_MAX :: 1024

// Room reserved per struct member (fast key + optional pretty indent + leaf value).
JSON_MEMBER_ROOM :: 1 + 256 + 16 + JSON_LEAF_ROOM
JSON_PRETTY_MEMBER_ROOM :: 1 + 1 + JSON_LINE_MAX + 16 + 256 + 16 + 1 + JSON_LEAF_ROOM
JSON_PRETTY_CLOSE_ROOM :: 2 * (1 + JSON_LINE_MAX) + 32

// Guaranteed free bytes ahead of `p` when `uintptr(p) <= uintptr(limit)`.
JSON_COMPACT_SLOP :: JSON_MEMBER_ROOM
JSON_PRETTY_SLOP :: JSON_PRETTY_CLOSE_ROOM

// CBOR headroom guaranteed ahead of `p` when `uintptr(p) <= uintptr(limit)`.
CBOR_SLOP :: 512

// How sorted CBOR map and struct entries order keys (`Text` for `.Cbor`/`.Preferred` `sort_keys`, `Written` for
// `.Deterministic`, `Length_First` for `.Length_First`).
Cbor_Key_Order :: enum u8 {
	None,
	Text,
	Written,
	Length_First,
}

@(private)
Decoded_Key_Kind :: enum u8 {
	Text,
	Int,
	Uint,
}

@(private)
Decoded_Key :: struct {
	kind: Decoded_Key_Kind,
	text: string,
	iv:   i64,
	uv:   u64,
}

// Validates `value`/`plan` and builds a one-shot plan in `made` when `plan` is nil.
@(private)
resolve_marshal_plan :: proc(value: rawptr, T: typeid, tag_key: string, plan: ^Plan, made: ^Plan, allocator: runtime.Allocator) -> (^Plan, tape.Error) {
	if value == nil {
		return nil, tape.Bad_Option{"value"}
	}
	if plan == nil {
		p, err := plan_make(T, tag_key, {}, allocator)
		if err != nil {
			return nil, err
		}
		made^ = p
		return made, nil
	}
	if !plan_matches(plan, T, tag_key) || plan.root == nil {
		return nil, tape.Bad_Option{"plan"}
	}
	return plan, nil
}

@(private)
push_frame :: #force_inline proc(frames: ^[^]$F, top, cap_frames: ^int, frame: F, allocator: runtime.Allocator, err: ^tape.Error) -> bool #no_bounds_check {
	if top^ == cap_frames^ && !grow_frames(frames, cap_frames, allocator, err) {
		return false
	}
	frames^[top^] = frame
	top^ += 1
	return true
}

@(private, cold)
grow_frames :: #force_no_inline proc(frames: ^[^]$F, cap_frames: ^int, allocator: runtime.Allocator, err: ^tape.Error) -> bool {
	next_cap := cap_frames^ * 2
	raw, aerr := runtime.mem_alloc_non_zeroed(next_cap * size_of(F), align_of(F), allocator)
	if aerr != nil || raw_data(raw) == nil {
		err^ = aerr if aerr != nil else runtime.Allocator_Error.Out_Of_Memory
		return false
	}
	grown := ([^]F)(raw_data(raw))
	intrinsics.mem_copy_non_overlapping(grown, frames^, cap_frames^ * size_of(F))
	if cap_frames^ > INLINE_FRAMES {
		runtime.mem_free_with_size(frames^, cap_frames^ * size_of(F), allocator)
	}
	frames^, cap_frames^ = grown, next_cap
	return true
}

// Copies pre-encoded key bytes `src[:size]` to `p` (caller guarantees >= 16 bytes of pad on `src` and >= `max(size, 16)` on `p`).
@(private)
put_fast_bytes :: #force_inline proc "contextless" (p, src: [^]u8, size: int) -> int #no_bounds_check {
	if size <= 16 {
		intrinsics.unaligned_store((^u128)(p), intrinsics.unaligned_load((^u128)(src)))
	} else if size <= 32 {
		intrinsics.unaligned_store((^u128)(p), intrinsics.unaligned_load((^u128)(src)))
		intrinsics.unaligned_store((^u128)(p[size - 16:]), intrinsics.unaligned_load((^u128)(src[size - 16:])))
	} else {
		intrinsics.mem_copy_non_overlapping(p, src, size)
	}
	return size
}

// Writes the value `value` points at, of type `T`, by `plan` (or a plan made for `T` under `tag_key` and freed on
// return when `plan` is nil), to `w` by `token`, one call each. Returns `werr` for the first error `token` or `tag`
// returns (leaving the writer at a prefix), or `err` for a bad plan/value, a `Raw` member, an out-of-range `time.Time`,
// or an allocator failure. A target that tags a date-time gives `tag`, called with "datetime" before a `time.Time`.
marshal :: proc(value: rawptr, T: typeid, tag_key: string, plan: ^Plan, w: ^$W, $token: proc(w: ^W, kind: tape.Token_Kind, text: string) -> $E, allocator := context.allocator, tag: proc(w: ^W, name: string) -> E = nil) -> (werr: E, err: tape.Error) {
	made: Plan
	plan := plan
	if plan, err = resolve_marshal_plan(value, T, tag_key, plan, &made, allocator); err != nil {
		return {}, err
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
		null: bool
		rec, at, null = unwrap_wrapper(plan, rec, at)
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
			data, n := list_data_len(plan, rec, at)
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
			if tag != nil && rec.kind == .Time {
				if werr = tag(w, "datetime"); werr != nil {
					return
				}
			}
			if werr = token(w, s.kind, s.text); werr != nil {
				return
			}
		}
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
					at = f.data + uintptr(member.offset)
					if member_omitted(plan, member, at) {
						continue
					}
					if werr = token(w, .Key, plan.meta[member.meta].name); werr != nil {
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
					if werr = token(w, .Key, key_text(plan, f.rec, key, &buf)); werr != nil {
						return
					}
					rec, at = element_of(f.rec), runtime.map_cell_index_dynamic(vs, info.vs, uintptr(i))
					break next
				}
			case .Bits:
				mm := &plan.meta[f.rec.meta]
				bit_limit := min(f.n, int(mm.size) * 8)
				for f.i < bit_limit {
					i := f.i
					f.i += 1
					if ((^u8)(f.data + uintptr(i >> 3))^ >> uint(i & 7)) & 1 == 0 {
						continue
					}
					elem := element_of(f.rec)
					text, named := spell_enum_value(plan, &plan.meta[elem.meta], mm.lower + i64(i), &buf)
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

// The record a list's, map's, pointer's or `Maybe`'s `first` reads its element by, which lies before it.
@(private)
element_of :: #force_inline proc "contextless" (rec: ^Record) -> ^Record {
	return (^Record)(uintptr(rec.first) - size_of(Record))
}

@(private)
list_data_len :: #force_inline proc "contextless" (plan: ^Plan, rec: ^Record, at: uintptr) -> (data: uintptr, n: int) #no_bounds_check {
	if rec.kind == .Array {
		return at, int(plan.meta[rec.meta].count)
	}
	raw := (^runtime.Raw_Slice)(at)
	return uintptr(raw.data), raw.len
}

@(private)
maybe_is_nil :: #force_inline proc "contextless" (m: ^Meta, at: uintptr) -> bool {
	return (^uintptr)(at)^ == 0 if m.tag_size == 0 else read_size(at + uintptr(m.tag), int(m.tag_size)) == 0
}

@(private)
union_active_arm :: #force_inline proc "contextless" (plan: ^Plan, m: ^Meta, at: uintptr) -> ^Arm #no_bounds_check {
	tag_v := u32(read_size(at + uintptr(m.tag), int(m.tag_size)))
	for &a in plan.arms[m.arms:][:m.count] {
		if a.tag == tag_v {
			return &a
		}
	}
	return nil
}

// Follows any chain of `.Maybe`, `.Ptr`, or `.Union` wrappers to the inner record/address, or signals null.
@(private)
unwrap_wrapper :: #force_inline proc "contextless" (plan: ^Plan, rec: ^Record, at: uintptr) -> (^Record, uintptr, bool) #no_bounds_check {
	rec, at := rec, at
	for {
		#partial switch rec.kind {
		case .Maybe:
			if maybe_is_nil(&plan.meta[rec.meta], at) {
				return rec, at, true
			}
			rec = element_of(rec)
		case .Ptr:
			to := (^uintptr)(at)^
			if to == 0 {
				return rec, at, true
			}
			rec, at = element_of(rec), to
		case .Union:
			arm := union_active_arm(plan, &plan.meta[rec.meta], at)
			if arm == nil {
				return rec, at, true
			}
			rec = &plan.records[arm.first - 1]
		case:
			return rec, at, false
		}
	}
}

@(private)
member_omitted :: #force_inline proc "contextless" (plan: ^Plan, rec: ^Record, at: uintptr) -> bool #no_bounds_check {
	mm := &plan.meta[rec.meta]
	return mm.omit_empty && is_empty(plan, rec, at) || mm.omit_unset && is_unset(plan, rec, at)
}

// Whether the value of `rec` at `at` is the zero of its type, or an empty string, list or map.
@(private)
is_empty :: proc "contextless" (plan: ^Plan, rec: ^Record, at: uintptr) -> bool #no_bounds_check {
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
is_unset :: proc "contextless" (plan: ^Plan, rec: ^Record, at: uintptr) -> bool #no_bounds_check {
	m := &plan.meta[rec.meta]
	#partial switch rec.kind {
	case .Ptr:
		return (^uintptr)(at)^ == 0
	case .Maybe:
		return maybe_is_nil(m, at)
	case .Union:
		return union_active_arm(plan, m, at) == nil
	}
	return false
}

@(private)
enum_lookup_name :: proc "contextless" (plan: ^Plan, ei: ^runtime.Type_Info_Enum, value: i64) -> (string, bool) #no_bounds_check {
	if plan.options.enums == .Name && ei != nil {
		for ev, idx in ei.values {
			if i64(ev) == value {
				return ei.names[idx], true
			}
		}
	}
	return "", false
}

@(private)
decode_map_key :: proc "contextless" (plan: ^Plan, m: ^Meta, key: uintptr) -> Decoded_Key #no_bounds_check {
	size := int(m.map_info.ks.size_of_type)
	#partial switch m.key_kind {
	case .String:
		return {.Text, (^string)(key)^, 0, 0}
	case .Enum:
		raw := read_size(key, size)
		signed := m.enum_info != nil && is_signed(m.enum_info.base)
		sv := sign_extend(raw, size) if signed else i64(raw)
		if name, ok := enum_lookup_name(plan, m.enum_info, sv); ok {
			return {.Text, name, 0, 0}
		}
		return {.Int, "", sv, 0} if signed else {.Uint, "", 0, raw}
	case .I8, .I16, .I32, .I64:
		return {.Int, "", sign_extend(read_size(key, size), size), 0}
	}
	return {.Uint, "", 0, read_size(key, size)}
}

// The text an enum's or bit set's `value` is written as, its member's name under `.Name` with `named` set, else its integer.
@(private)
spell_enum_value :: proc(plan: ^Plan, m: ^Meta, value: i64, buf: ^[SCALAR_ROOM]u8) -> (text: string, named: bool) #no_bounds_check {
	if name, ok := enum_lookup_name(plan, m.enum_info, value); ok {
		return name, true
	}
	n := spell.put_i64(&buf[0], value) if m.signed else spell.put_u64(&buf[0], u64(value))
	return string(buf[:n]), false
}

// The text of the map key at `key`, of a map record `rec`: a string, an integer or an enum's name.
@(private)
key_text :: proc(plan: ^Plan, rec: ^Record, key: uintptr, buf: ^[SCALAR_ROOM]u8) -> string #no_bounds_check {
	dk := decode_map_key(plan, &plan.meta[rec.meta], key)
	switch dk.kind {
	case .Text:
		return dk.text
	case .Int:
		return string(buf[:spell.put_i64(&buf[0], dk.iv)])
	case .Uint:
		return string(buf[:spell.put_u64(&buf[0], dk.uv)])
	}
	return ""
}

@(private)
is_signed :: proc "contextless" (ti: ^runtime.Type_Info) -> bool {
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
scalar_of :: proc(plan: ^Plan, rec: ^Record, at: uintptr, buf: ^[SCALAR_ROOM]u8) -> (s: Scalar, err: tape.Error) #no_bounds_check {
	m := &plan.meta[rec.meta]
	#partial switch rec.kind {
	case .String:
		return {.String, (^string)(at)^}, nil
	case .Bool:
		return {.True if (^bool)(at)^ else .False, ""}, nil
	case .Bool_Wide:
		return {.True if read_size(at, int(m.size)) != 0 else .False, ""}, nil
	case .I8, .I16, .I32, .I64:
		sz := int(m.size)
		return {.Number, string(buf[:spell.put_i64(&buf[0], sign_extend(read_size(at, sz), sz))])}, nil
	case .U8, .U16, .U32, .U64:
		return {.Number, string(buf[:spell.put_u64(&buf[0], read_size(at, int(m.size)))])}, nil
	case .F32:
		return {.Number, float_text(buf, f64((^f32)(at)^), 32)}, nil
	case .F64:
		return {.Number, float_text(buf, (^f64)(at)^, 64)}, nil
	case .Enum:
		signed := m.enum_info != nil && is_signed(m.enum_info.base)
		raw := read_size(at, int(m.size))
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

// Formats the `time.Time` at `va` in UTC RFC 3339 into `buf` with no allocation.
@(private)
rfc3339_at :: proc(va: uintptr, buf: ^[SCALAR_ROOM]u8) -> (string, bool) {
	return rfc3339_text((^time.Time)(va)^, buf)
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
	return string(buf[:o + 1]), true
}

// The shortest text of `f` that reads back as it, with no plus sign and `.0` appended to a finite whole float so
// `-0.0` keeps its sign bit and formats that tell floats from integers preserve the float kind.
@(private)
float_text :: proc(buf: ^[SCALAR_ROOM]u8, f: f64, bits: int) -> string #no_bounds_check {
	if math.is_nan(f) {
		return "NaN"
	}
	if math.is_inf(f, 0) {
		return "-Inf" if f < 0 else "Inf"
	}
	n := spell.put_f32_finite(&buf[0], f32(f)) if bits == 32 else spell.put_f64_finite(&buf[0], f)
	return string(buf[:n])
}
