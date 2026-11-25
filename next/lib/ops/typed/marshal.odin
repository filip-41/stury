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

// Why `marshal_json` refused a value (matches `write.Refusal` without importing `lib/ops/write`).
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
JSON_PRETTY_MEMBER_ROOM :: 1 + 1 + JSON_LINE_MAX + 256 + 16 + 1 + JSON_LEAF_ROOM
JSON_PRETTY_CLOSE_ROOM :: 2 * (1 + JSON_LINE_MAX) + 16

@(private)
Fast_Frame_Mode :: enum u32 {
	Root,
	Struct,
	List,
	Map,
	Bits,
}

@(private)
Fast_Frame :: struct {
	r:     ^Record,
	at:    uintptr,
	left:  int,
	step:  int,
	total: int,
	lead:  u32,
	mode:  Fast_Frame_Mode,
}
when size_of(uintptr) == 8 {
	#assert(size_of(Fast_Frame) == 48)
}

@(private)
JSON_NULL_U32 :: u32le('n') | u32le('u') << 8 | u32le('l') << 16 | u32le('l') << 24
@(private)
JSON_TRUE_U32 :: u32le('t') | u32le('r') << 8 | u32le('u') << 16 | u32le('e') << 24
@(private)
JSON_FALSE_U64 :: u64le('f') | u64le('a') << 8 | u64le('l') << 16 | u64le('s') << 24 | u64le('e') << 32

// Direct JSON marshaler: walks `value` by `plan` and writes JSON directly into `w`'s output buffer without per-token
// callbacks, structural sequence validation, or re-encoding clean struct field names. `PRETTY` and `ASCII` are
// compile-time specialized so the hot loop carries zero option branches.
marshal_json :: proc(
	value: rawptr,
	T: typeid,
	tag_key: string,
	plan: ^Plan,
	w: ^$W,
	$PRETTY: bool,
	$room: proc(w: ^W, n: int) -> [^]u8,
	$cursor_of: proc "contextless" (w: ^W) -> ^int,
	$has_err: proc "contextless" (w: ^W) -> bool,
	$put_string: proc(w: ^W, p: [^]u8, s: string) -> bool,
	$put_line: proc(w: ^W, p: [^]u8, depth: int, after: int) -> [^]u8,
	allocator := context.allocator,
) -> (refusal: Marshal_Refusal, err: tape.Error) #no_bounds_check {
	if value == nil {
		return .None, tape.Bad_Option{"value"}
	}
	plan := plan
	made: Plan
	if plan == nil {
		if made, err = plan_make(T, tag_key, {}, allocator); err != nil {
			return .None, err
		}
		plan = &made
	} else if plan.type != T || plan.tag != tag_key || plan.root == nil {
		return .None, tape.Bad_Option{"plan"}
	}
	defer if plan == &made {
		plan_destroy(&made)
	}
	inline_frames: [INLINE_FRAMES]Fast_Frame = ---
	frames := raw_data(inline_frames[:])
	top, cap_frames := 0, INLINE_FRAMES
	defer if cap_frames > INLINE_FRAMES {
		runtime.mem_free_with_size(frames, cap_frames * size_of(Fast_Frame), allocator)
	}
	keys := raw_data(plan.strings)
	cursor := cursor_of(w)
	cur := Fast_Frame{
		r    = (^Record)(uintptr(plan.root) - size_of(Record)),
		at   = uintptr(value),
		left = 1,
		mode = .Root,
	}
	next: for {
		vf: ^Record
		va: uintptr
		p: [^]u8
		if cur.mode == .Struct {
			r := cur.r
			if r.key_size == 0 {
				for r.kind != .End && r.key_size == 0 {
					mm := &plan.meta[r.meta]
					member_at := cur.at + uintptr(r.offset)
					if mm.omit_empty && is_empty(plan, r, member_at) || mm.omit_unset && is_unset(plan, r, member_at) {
						r = intrinsics.ptr_offset(r, 1)
						continue
					}
					break
				}
				if r.kind == .End {
					when PRETTY {
						p = room(w, JSON_PRETTY_CLOSE_ROOM)
						if cur.lead == '{' {
							p[0], p[1] = '{', '}'
							cursor^ += 2
							p = p[2:]
						} else {
							p = put_line(w, p, top - 1, 2)
							p[0] = '}'
							cursor^ += 1
							p = p[1:]
						}
					} else {
						p = room(w, 3)
						if cur.lead == '{' {
							p[0], p[1] = '{', '}'
							cursor^ += 2
							p = p[2:]
						} else {
							p[0] = '}'
							cursor^ += 1
							p = p[1:]
						}
					}
					// Reuse this struct frame for the next element of a list of structs without pop/push.
					up := &frames[top - 1]
					if up.mode == .List && up.left > 0 && (up.r.kind == .Struct || up.r.kind == .Required) && !has_err(w) {
						up.left -= 1
						p[0] = ','
						cursor^ += 1
						when PRETTY {
							_ = put_line(w, p[1:], top - 1, 1)
						}
						cur.r, cur.at, cur.lead = up.r.first, up.at, '{'
						up.at += uintptr(up.step)
						continue next
					}
					top -= 1
					cur = frames[top]
					if has_err(w) {
						return .None, nil
					}
					continue next
				}
			}
			ks := int(r.key_size)
			if ks != 0 {
				when PRETTY {
					p = room(w, JSON_PRETTY_MEMBER_ROOM)
					p[0] = u8(cur.lead)
					cur.lead = ','
					cursor^ += 1
					p = put_line(w, p[1:], top, 256 + 16 + 1 + JSON_LEAF_ROOM)
					key_src := keys[uint(r.key_off):]
					if ks <= 16 {
						intrinsics.unaligned_store((^u128)(p), intrinsics.unaligned_load((^u128)(key_src)))
					} else {
						intrinsics.mem_copy_non_overlapping(p, key_src, ks)
					}
					p = p[ks:]
					p[0] = ' '
					p = p[1:]
					cursor^ += ks + 1
				} else {
					p = room(w, JSON_MEMBER_ROOM)
					p[0] = u8(cur.lead)
					cur.lead = ','
					key_src := keys[uint(r.key_off):]
					if ks <= 16 {
						intrinsics.unaligned_store((^u128)(p[1:]), intrinsics.unaligned_load((^u128)(key_src)))
					} else {
						intrinsics.mem_copy_non_overlapping(p[1:], key_src, ks)
					}
					cursor^ += 1 + ks
					p = p[1 + ks:]
				}
			} else {
				when PRETTY {
					p = room(w, 1 + 1 + JSON_LINE_MAX + 18)
					p[0] = u8(cur.lead)
					cur.lead = ','
					cursor^ += 1
					p = put_line(w, p[1:], top, 18)
				} else {
					p = room(w, 1 + 18)
					p[0] = u8(cur.lead)
					cur.lead = ','
					p = p[1:]
					cursor^ += 1
				}
				if !put_string(w, p, plan.meta[r.meta].name) {
					return .No_Spelling, nil
				}
				p = room(w, 2 + JSON_LEAF_ROOM)
				when PRETTY {
					p[0], p[1] = ':', ' '
					p = p[2:]
					cursor^ += 2
				} else {
					p[0] = ':'
					p = p[1:]
					cursor^ += 1
				}
			}
			cur.r = intrinsics.ptr_offset(r, 1)
			vf, va = r, cur.at + uintptr(r.offset)
		} else if cur.mode == .List {
			if cur.left == 0 {
				when PRETTY {
					p = room(w, 1 + JSON_LINE_MAX + 8)
					p = put_line(w, p, top - 1, 1)
					p[0] = ']'
					cursor^ += 1
				} else {
					p = room(w, 1)
					p[0] = ']'
					cursor^ += 1
				}
				top -= 1
				cur = frames[top]
				if has_err(w) {
					return .None, nil
				}
				continue next
			}
			cur.left -= 1
			when PRETTY {
				p = room(w, 1 + 1 + JSON_LINE_MAX + JSON_LEAF_ROOM)
				p[0] = ','
				p = p[cur.lead:]
				cursor^ += int(cur.lead)
				cur.lead = 1
				p = put_line(w, p, top, JSON_LEAF_ROOM)
			} else {
				p = room(w, 1 + JSON_LEAF_ROOM)
				p[0] = ','
				p = p[cur.lead:]
				cursor^ += int(cur.lead)
				cur.lead = 1
			}
			vf, va = cur.r, cur.at
			cur.at += uintptr(cur.step)
		} else if cur.mode == .Map {
			m := &plan.meta[cur.r.meta]
			info := m.map_info
			raw := (^runtime.Raw_Map)(cur.at)^
			ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw, info)
			i := cur.step
			for i < cur.left && !runtime.map_hash_is_valid(hs[i]) {
				i += 1
			}
			if i >= cur.left {
				when PRETTY {
					p = room(w, 1 + JSON_LINE_MAX + 8)
					if cur.lead == '{' {
						p[0], p[1] = '{', '}'
						cursor^ += 2
					} else {
						p = put_line(w, p, top - 1, 1)
						p[0] = '}'
						cursor^ += 1
					}
				} else {
					p = room(w, 2)
					if cur.lead == '{' {
						p[0], p[1] = '{', '}'
						cursor^ += 2
					} else {
						p[0] = '}'
						cursor^ += 1
					}
				}
				top -= 1
				cur = frames[top]
				if has_err(w) {
					return .None, nil
				}
				continue next
			}
			cur.step = i + 1
			key := runtime.map_cell_index_dynamic(ks, info.ks, uintptr(i))
			when PRETTY {
				p = room(w, 1 + 1 + JSON_LINE_MAX + 32)
				p[0] = u8(cur.lead)
				cur.lead = ','
				cursor^ += 1
				p = put_line(w, p[1:], top, 32)
			} else {
				p = room(w, 1 + 32)
				p[0] = u8(cur.lead)
				cur.lead = ','
				p = p[1:]
				cursor^ += 1
			}
			if m.key_kind == .String {
				if !put_string(w, p, (^string)(key)^) {
					return .No_Spelling, nil
				}
			} else if !put_non_string_key(plan, m, key, w, p, cursor, put_string) {
				return .No_Spelling, nil
			}
			p = room(w, 2 + JSON_LEAF_ROOM)
			when PRETTY {
				p[0], p[1] = ':', ' '
				p = p[2:]
				cursor^ += 2
			} else {
				p[0] = ':'
				p = p[1:]
				cursor^ += 1
			}
			vf, va = element_of(cur.r), runtime.map_cell_index_dynamic(vs, info.vs, uintptr(i))
		} else if cur.mode == .Bits {
			i := cur.step
			for i < cur.left && ((^u8)(cur.at + uintptr(i >> 3))^ >> uint(i & 7)) & 1 == 0 {
				i += 1
			}
			if i >= cur.left {
				when PRETTY {
					p = room(w, 1 + JSON_LINE_MAX + 8)
					if cur.lead != 0 {
						p = put_line(w, p, top - 1, 1)
					}
					p[0] = ']'
					cursor^ += 1
				} else {
					p = room(w, 1)
					p[0] = ']'
					cursor^ += 1
				}
				top -= 1
				cur = frames[top]
				if has_err(w) {
					return .None, nil
				}
				continue next
			}
			cur.step = i + 1
			when PRETTY {
				p = room(w, 1 + 1 + JSON_LINE_MAX + JSON_LEAF_ROOM)
				p[0] = ','
				p = p[cur.lead:]
				cursor^ += int(cur.lead)
				cur.lead = 1
				p = put_line(w, p, top, JSON_LEAF_ROOM)
			} else {
				p = room(w, 1 + JSON_LEAF_ROOM)
				p[0] = ','
				p = p[cur.lead:]
				cursor^ += int(cur.lead)
				cur.lead = 1
			}
			mm := &plan.meta[cur.r.meta]
			elem := element_of(cur.r)
			if !put_enum_scalar(plan, &plan.meta[elem.meta], mm.lower + i64(i), w, p, cursor, put_string) {
				return .No_Spelling, nil
			}
			continue next
		} else {
			if cur.left == 0 {
				return .None, nil
			}
			cur.left = 0
			p = room(w, JSON_LEAF_ROOM)
			vf, va = cur.r, cur.at
		}

		value: for {
			if vf.kind == .String {
				if !put_string(w, p, (^string)(va)^) {
					return .No_Spelling, nil
				}
				continue next
			}
			#partial switch vf.kind {
			case .I64:
				cursor^ += put_i64(p, (^i64)(va)^)
			case .F64:
				n, ok := put_f64(p, (^f64)(va)^)
				if !ok {
					return .No_Spelling, nil
				}
				cursor^ += n
			case .Bool:
				if (^bool)(va)^ {
					intrinsics.unaligned_store((^u32le)(p), JSON_TRUE_U32)
					cursor^ += 4
				} else {
					intrinsics.unaligned_store((^u64le)(p), JSON_FALSE_U64)
					cursor^ += 5
				}
			case .Struct, .Required:
				if top >= tape.DEFAULT_DEPTH {
					return .Malformed, nil
				}
				if !push_fast_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
					return .None, err
				}
				cur = Fast_Frame{r = vf.first, at = va, lead = '{', mode = .Struct}
			case .Slice, .Dynamic, .Array:
				if top >= tape.DEFAULT_DEPTH {
					return .Malformed, nil
				}
				data, n := va, 0
				if vf.kind == .Array {
					n = int(plan.meta[vf.meta].count)
				} else {
					raw := (^runtime.Raw_Slice)(va)
					data, n = uintptr(raw.data), raw.len
				}
				if n == 0 {
					p[0], p[1] = '[', ']'
					cursor^ += 2
				} else {
					if !push_fast_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
						return .None, err
					}
					elem := element_of(vf)
					p[0] = '['
					cursor^ += 1
					cur = Fast_Frame{r = elem, at = data, left = n, step = int(elem.stride), total = n, lead = 0, mode = .List}
				}
			case .Map:
				if top >= tape.DEFAULT_DEPTH {
					return .Malformed, nil
				}
				raw := (^runtime.Raw_Map)(va)^
				if runtime.map_len(raw) == 0 {
					p[0], p[1] = '{', '}'
					cursor^ += 2
				} else {
					mm := &plan.meta[vf.meta]
					elem := element_of(vf)
					if mm.key_kind == .String && (elem.kind == .I64 || elem.kind == .String) {
						if !put_flat_string_map(mm.map_info, raw, elem.kind == .I64, top + 1, w, cursor, PRETTY, room, has_err, put_string, put_line) {
							return .No_Spelling, nil
						}
						if has_err(w) {
							return .None, nil
						}
					} else {
						if !push_fast_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
							return .None, err
						}
						cur = Fast_Frame{r = vf, at = va, left = runtime.map_cap(raw), step = 0, lead = '{', mode = .Map}
					}
				}
			case .Maybe:
				m := &plan.meta[vf.meta]
				if m.tag_size == 0 && (^uintptr)(va)^ == 0 || m.tag_size != 0 && load_size(va + uintptr(m.tag), int(m.tag_size)) == 0 {
					intrinsics.unaligned_store((^u32le)(p), JSON_NULL_U32)
					cursor^ += 4
				} else {
					vf = element_of(vf)
					continue value
				}
			case .Ptr:
				to := (^uintptr)(va)^
				if to == 0 {
					intrinsics.unaligned_store((^u32le)(p), JSON_NULL_U32)
					cursor^ += 4
				} else {
					vf, va = element_of(vf), to
					continue value
				}
			case .Union:
				m := &plan.meta[vf.meta]
				tag_v := u32(load_size(va + uintptr(m.tag), int(m.tag_size)))
				arm: ^Arm
				for &a in plan.arms[m.arms:][:m.count] {
					if a.tag == tag_v {
						arm = &a
						break
					}
				}
				if arm == nil {
					intrinsics.unaligned_store((^u32le)(p), JSON_NULL_U32)
					cursor^ += 4
				} else {
					vf = &plan.records[arm.first - 1]
					continue value
				}
			case .Bit_Set:
				if top >= tape.DEFAULT_DEPTH {
					return .Malformed, nil
				}
				if !push_fast_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
					return .None, err
				}
				mm := &plan.meta[vf.meta]
				p[0] = '['
				cursor^ += 1
				cur = Fast_Frame{r = vf, at = va, left = min(int(mm.count), int(mm.size) * 8), step = 0, lead = 0, mode = .Bits}
			case:
				rref, rerr := put_rare_scalar(plan, vf, va, w, p, cursor, put_string)
				if rerr != nil || rref != .None {
					return rref, rerr
				}
			}
			continue next
		}
	}
}

@(private)
push_fast_frame :: #force_inline proc(frames: ^[^]Fast_Frame, top, cap_frames: ^int, frame: Fast_Frame, allocator: runtime.Allocator, err: ^tape.Error) -> bool #no_bounds_check {
	if top^ == cap_frames^ && !grow_fast_frames(frames, cap_frames, allocator, err) {
		return false
	}
	frames^[top^] = frame
	top^ += 1
	return true
}

@(private, cold)
grow_fast_frames :: #force_no_inline proc(frames: ^[^]Fast_Frame, cap_frames: ^int, allocator: runtime.Allocator, err: ^tape.Error) -> bool {
	next_cap := cap_frames^ * 2
	raw, aerr := runtime.mem_alloc_non_zeroed(next_cap * size_of(Fast_Frame), align_of(Fast_Frame), allocator)
	if aerr != nil || raw_data(raw) == nil {
		err^ = aerr if aerr != nil else runtime.Allocator_Error.Out_Of_Memory
		return false
	}
	grown := ([^]Fast_Frame)(raw_data(raw))
	intrinsics.mem_copy_non_overlapping(grown, frames^, cap_frames^ * size_of(Fast_Frame))
	if cap_frames^ > INLINE_FRAMES {
		runtime.mem_free_with_size(frames^, cap_frames^ * size_of(Fast_Frame), allocator)
	}
	frames^, cap_frames^ = grown, next_cap
	return true
}

@(private, cold)
put_non_string_key :: proc(
	plan: ^Plan,
	m: ^Meta,
	key: uintptr,
	w: ^$W,
	p: [^]u8,
	cursor: ^int,
	$put_string: proc(w: ^W, p: [^]u8, s: string) -> bool,
) -> bool #no_bounds_check {
	size := int(m.map_info.ks.size_of_type)
	#partial switch m.key_kind {
	case .Enum:
		v := load_size(key, size)
		signed := is_signed(m.enum_info.base)
		sv := sign_extend(v, size) if signed else i64(v)
		if plan.options.enums == .Name && m.enum_info != nil {
			for ev, idx in m.enum_info.values {
				if i64(ev) == sv {
					return put_string(w, p, m.enum_info.names[idx])
				}
			}
		}
		p[0] = '"'
		n := put_i64(p[1:], sv) if signed else put_u64(p[1:], v)
		p[1 + n] = '"'
		cursor^ += n + 2
		return true
	case .I8, .I16, .I32, .I64:
		p[0] = '"'
		n := put_i64(p[1:], sign_extend(load_size(key, size), size))
		p[1 + n] = '"'
		cursor^ += n + 2
		return true
	}
	p[0] = '"'
	n := put_u64(p[1:], load_size(key, size))
	p[1 + n] = '"'
	cursor^ += n + 2
	return true
}

@(private, cold)
put_enum_scalar :: proc(
	plan: ^Plan,
	m: ^Meta,
	value: i64,
	w: ^$W,
	p: [^]u8,
	cursor: ^int,
	$put_string: proc(w: ^W, p: [^]u8, s: string) -> bool,
) -> bool #no_bounds_check {
	if plan.options.enums == .Name && m.enum_info != nil {
		for ev, idx in m.enum_info.values {
			if i64(ev) == value {
				return put_string(w, p, m.enum_info.names[idx])
			}
		}
	}
	cursor^ += put_i64(p, value) if m.signed else put_u64(p, u64(value))
	return true
}

@(private)
ZEROS8 :: u64(0x3030_3030_3030_3030)

// `x` < 10^8 as eight digit values 0..9, the most significant in the low byte.
@(private)
bcd8 :: #force_inline proc "contextless" (x: u64) -> u64 {
	abcd_efgh := x + (1 << 32 - 10000) * ((x * ((1 << 40) / 10000 + 1)) >> 40)
	ab_cd_ef_gh := abcd_efgh + (1 << 16 - 100) * ((abcd_efgh * ((1 << 19) / 100 + 1)) >> 19 & 0x7f_0000_007f)
	a_b_c_d_e_f_g_h := ab_cd_ef_gh + (1 << 8 - 10) * ((ab_cd_ef_gh * ((1 << 10) / 10 + 1)) >> 10 & 0xf_000f_000f_000f)
	return intrinsics.byte_swap(a_b_c_d_e_f_g_h)
}

@(private)
lead8_text :: #force_inline proc "contextless" (dst: [^]u8, x: u64) -> int #no_bounds_check {
	digits := bcd8(x)
	skip := int(intrinsics.count_trailing_zeros(digits | 1 << 56)) >> 3
	intrinsics.unaligned_store((^u64le)(dst), u64le((digits + ZEROS8) >> (8 * uint(skip))))
	return 8 - skip
}

// Writes `u` in decimal at `dst` (caller guarantees >= 24 bytes of room). Returns the digit count.
@(private)
put_u64 :: #force_inline proc "contextless" (dst: [^]u8, u: u64) -> int #no_bounds_check {
	if u < 100_000_000 {
		return lead8_text(dst, u)
	}
	if u < 10_000_000_000_000_000 {
		high := u / 100_000_000
		n := lead8_text(dst, high)
		intrinsics.unaligned_store((^u64le)(dst[n:]), u64le(bcd8(u - high * 100_000_000) | ZEROS8))
		return n + 8
	}
	top := u / 10_000_000_000_000_000
	low16 := u - top * 10_000_000_000_000_000
	mid := low16 / 100_000_000
	n := lead8_text(dst, top)
	intrinsics.unaligned_store((^u64le)(dst[n:]), u64le(bcd8(mid) | ZEROS8))
	intrinsics.unaligned_store((^u64le)(dst[n + 8:]), u64le(bcd8(low16 - mid * 100_000_000) | ZEROS8))
	return n + 16
}

// Writes `v` in decimal at `dst` (caller guarantees >= 24 bytes of room). Returns the byte count.
@(private)
put_i64 :: #force_inline proc "contextless" (dst: [^]u8, v: i64) -> int #no_bounds_check {
	neg := int(v < 0)
	dst[0] = '-'
	u := u64(v)
	return neg + put_u64(dst[neg:], 0 - u if neg != 0 else u)
}

// Tight loop for `map[string]i64` and `map[string]string` (computes `ks, vs, hs` once for the entire map).
@(private)
put_flat_string_map :: #force_no_inline proc(
	info: ^runtime.Map_Info,
	raw: runtime.Raw_Map,
	is_i64: bool,
	depth: int,
	w: ^$W,
	cursor: ^int,
	$PRETTY: bool,
	$room: proc(w: ^W, n: int) -> [^]u8,
	$has_err: proc "contextless" (w: ^W) -> bool,
	$put_string: proc(w: ^W, p: [^]u8, s: string) -> bool,
	$put_line: proc(w: ^W, p: [^]u8, depth: int, after: int) -> [^]u8,
) -> bool #no_bounds_check {
	cap_map := runtime.map_cap(raw)
	ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw, info)
	keys_arr := ([^]string)(ks)
	vals_i64 := ([^]i64)(vs)
	vals_str := ([^]string)(vs)
	lead := u8('{')
	for i in 0 ..< cap_map {
		if !runtime.map_hash_is_valid(hs[i]) {
			continue
		}
		key := keys_arr[i]
		when PRETTY {
			p := room(w, 1 + 1 + JSON_LINE_MAX + 18 + 2 + JSON_LEAF_ROOM)
			p[0] = lead
			lead = ','
			cursor^ += 1
			p = put_line(w, p[1:], depth, 18 + 2 + JSON_LEAF_ROOM)
		} else {
			p := room(w, 1 + 18 + 1 + JSON_LEAF_ROOM)
			p[0] = lead
			lead = ','
			p = p[1:]
			cursor^ += 1
		}
		before := cursor^
		if !put_string(w, p, key) {
			return false
		}
		wrote := cursor^ - before
		if len(key) < 16 && wrote == len(key) + 2 {
			p = p[wrote:]
		} else {
			p = room(w, 2 + JSON_LEAF_ROOM)
		}
		when PRETTY {
			p[0], p[1] = ':', ' '
			p = p[2:]
			cursor^ += 2
		} else {
			p[0] = ':'
			p = p[1:]
			cursor^ += 1
		}
		if is_i64 {
			cursor^ += put_i64(p, vals_i64[i])
		} else {
			if !put_string(w, p, vals_str[i]) {
				return false
			}
		}
		if i & 63 == 63 && has_err(w) {
			return true
		}
	}
	when PRETTY {
		p := room(w, 1 + JSON_LINE_MAX + 8)
		if lead == '{' {
			p[0], p[1] = '{', '}'
			cursor^ += 2
		} else {
			p = put_line(w, p, depth - 1, 1)
			p[0] = '}'
			cursor^ += 1
		}
	} else {
		p := room(w, 2)
		if lead == '{' {
			p[0], p[1] = '{', '}'
			cursor^ += 2
		} else {
			p[0] = '}'
			cursor^ += 1
		}
	}
	return true
}

@(private, cold)
put_rare_scalar :: #force_no_inline proc(
	plan: ^Plan,
	vf: ^Record,
	va: uintptr,
	w: ^$W,
	p: [^]u8,
	cursor: ^int,
	$put_string: proc(w: ^W, p: [^]u8, s: string) -> bool,
) -> (Marshal_Refusal, tape.Error) #no_bounds_check {
	#partial switch vf.kind {
	case .I32:
		cursor^ += put_i64(p, i64((^i32)(va)^))
	case .I16:
		cursor^ += put_i64(p, i64((^i16)(va)^))
	case .I8:
		cursor^ += put_i64(p, i64((^i8)(va)^))
	case .U64:
		cursor^ += put_u64(p, (^u64)(va)^)
	case .U32:
		cursor^ += put_u64(p, u64((^u32)(va)^))
	case .U16:
		cursor^ += put_u64(p, u64((^u16)(va)^))
	case .U8:
		cursor^ += put_u64(p, u64((^u8)(va)^))
	case .F32:
		n, ok := put_f32(p, (^f32)(va)^)
		if !ok {
			return .No_Spelling, nil
		}
		cursor^ += n
	case .Bool_Wide:
		if load_size(va, int(plan.meta[vf.meta].size)) != 0 {
			intrinsics.unaligned_store((^u32le)(p), JSON_TRUE_U32)
			cursor^ += 4
		} else {
			intrinsics.unaligned_store((^u64le)(p), JSON_FALSE_U64)
			cursor^ += 5
		}
	case .Enum:
		m := &plan.meta[vf.meta]
		signed := is_signed(m.enum_info.base)
		raw := load_size(va, int(m.size))
		v := sign_extend(raw, int(m.size)) if signed else i64(raw)
		em := Meta{enum_info = m.enum_info, signed = signed}
		if !put_enum_scalar(plan, &em, v, w, p, cursor, put_string) {
			return .No_Spelling, nil
		}
	case .Time:
		tbuf: [SCALAR_ROOM]u8 = ---
		text, ok := rfc3339_text((^time.Time)(va)^, &tbuf)
		if !ok {
			return .None, tape.Bad_Option{"time"}
		}
		p[0] = '"'
		intrinsics.mem_copy_non_overlapping(p[1:], raw_data(text), len(text))
		p[1 + len(text)] = '"'
		cursor^ += len(text) + 2
	case:
		return .None, tape.Bad_Option{"raw"}
	}
	return .None, nil
}

// Writes finite `f` directly at `dst` (caller guarantees `JSON_LEAF_ROOM` = 64 bytes), appending `.0` to whole floats
// so `-0.0` keeps its sign bit and floats remain distinct from integers. False for NaN or Inf.
// Fast path handles exact decimals with up to 3 fractional digits in `[0, 1e6)` (matching shortest `'g'` output bit-for-bit).
@(private)
put_f64 :: #force_inline proc(dst: [^]u8, f: f64) -> (int, bool) #no_bounds_check {
	if f - f != 0 {
		return 0, false
	}
	bits := transmute(u64)f
	neg := int(bits >> 63)
	abs_f := transmute(f64)(bits & 0x7FFF_FFFF_FFFF_FFFF)
	if abs_f < 1_000_000.0 && (abs_f >= 0.001 || abs_f == 0) {
		scaled := abs_f * 1000.0
		k := u64(scaled + 0.5)
		diff := scaled - f64(k)
		if diff > -1e-7 && diff < 1e-7 && k < 1_000_000_000 && f64(k) / 1000.0 == abs_f {
			dst[0] = '-'
			whole := k / 1000
			frac := k - whole * 1000
			n := neg + lead8_text(dst[neg:], whole)
			dst[n] = '.'
			if frac == 0 {
				dst[n + 1] = '0'
				return n + 2, true
			}
			d1 := frac / 100
			rem := frac - d1 * 100
			d2 := rem / 10
			d3 := rem - d2 * 10
			dst[n + 1] = '0' + u8(d1)
			if d3 != 0 {
				dst[n + 2] = '0' + u8(d2)
				dst[n + 3] = '0' + u8(d3)
				return n + 4, true
			}
			if d2 != 0 {
				dst[n + 2] = '0' + u8(d2)
				return n + 3, true
			}
			return n + 2, true
		}
	}
	return put_f64_slow(dst, f), true
}

@(private)
put_f64_slow :: #force_no_inline proc(dst: [^]u8, f: f64) -> int #no_bounds_check {
	res := strconv.write_float(dst[:JSON_LEAF_ROOM - 2], f, 'g', -1, 64, {})
	n := len(res)
	for i in 0 ..< n {
		c := dst[i]
		if c == '.' || c == 'e' || c == 'E' {
			return n
		}
	}
	dst[n], dst[n + 1] = '.', '0'
	return n + 2
}

@(private)
put_f32 :: #force_no_inline proc(dst: [^]u8, f: f32) -> (int, bool) #no_bounds_check {
	if f - f != 0 {
		return 0, false
	}
	res := strconv.write_float(dst[:JSON_LEAF_ROOM - 2], f64(f), 'g', -1, 32, {})
	n := len(res)
	for i in 0 ..< n {
		c := dst[i]
		if c == '.' || c == 'e' || c == 'E' {
			return n, true
		}
	}
	dst[n], dst[n + 1] = '.', '0'
	return n + 2, true
}

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
