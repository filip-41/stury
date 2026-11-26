package typed

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:simd"
import "core:time"
import "stury:lib/base/kernel"
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
CBOR_LEAF_ROOM :: 64
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
Fast_Frame_Mode :: enum u32 {
	Root,
	Struct,
	List,
	Map,
	Bits,
	Sorted,
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

@(private)
Sorted_Json_Entry :: struct {
	text:       string,
	inline_buf: [24]u8,
	inline_len: u8,
	rec:        ^Record,
	val:        uintptr,
}

@(private)
sorted_json_key :: #force_inline proc "contextless" (e: ^Sorted_Json_Entry) -> string #no_bounds_check {
	return string(e.inline_buf[:e.inline_len]) if e.inline_len > 0 else e.text
}

@(private, cold)
sort_sorted_json :: proc(s: []Sorted_Json_Entry) #no_bounds_check {
	s := s
	for len(s) > 1 {
		if len(s) <= 16 {
			for i in 1 ..< len(s) {
				cur := s[i]
				ck := sorted_json_key(&cur)
				j := i - 1
				for j >= 0 {
					e := s[j]
					if !(ck < sorted_json_key(&e)) {
						break
					}
					s[j + 1] = e
					j -= 1
				}
				s[j + 1] = cur
			}
			return
		}
		mid := len(s) / 2
		e0, em, el := s[0], s[mid], s[len(s) - 1]
		k0, km, kl := sorted_json_key(&e0), sorted_json_key(&em), sorted_json_key(&el)
		p := mid
		if k0 < km {
			if km < kl { p = mid } else if k0 < kl { p = len(s) - 1 } else { p = 0 }
		} else {
			if k0 < kl { p = 0 } else if km < kl { p = len(s) - 1 } else { p = mid }
		}
		piv := s[p]
		s[p], s[len(s) - 1] = s[len(s) - 1], piv
		pk := sorted_json_key(&piv)
		store := 0
		for i in 0 ..< len(s) - 1 {
			cur := s[i]
			if sorted_json_key(&cur) < pk {
				s[store], s[i] = cur, s[store]
				store += 1
			}
		}
		s[store], s[len(s) - 1] = s[len(s) - 1], s[store]
		left, right := s[:store], s[store + 1:]
		if len(left) < len(right) {
			sort_sorted_json(left)
			s = right
		} else {
			sort_sorted_json(right)
			s = left
		}
	}
}

// Direct JSON marshaler: walks `value` by `plan` and writes JSON directly into `w`'s buffer with `buf, p, limit`
// kept in SSA registers, bypassing token sequence checks, re-escaping clean struct field names, and per-field cursor
// memory traffic. `PRETTY` and `SORT_KEYS` are compile-time specialized.
marshal_json :: proc(
	value: rawptr,
	T: typeid,
	tag_key: string,
	plan: ^Plan,
	w: ^$W,
	$PRETTY: bool,
	$SORT_KEYS: bool,
	$buf_state: proc "contextless" (w: ^W, slop: int) -> (buf, p, limit: [^]u8),
	$sync_cursor: proc "contextless" (w: ^W, buf, p: [^]u8),
	$grow: proc(w: ^W, buf, p: [^]u8, need, slop: int) -> (new_buf, new_p, new_limit: [^]u8),
	$has_err: proc "contextless" (w: ^W) -> bool,
	$put_string_inline: proc "contextless" (p: [^]u8, s: string) -> int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> (new_buf, new_p, new_limit: [^]u8, ok: bool),
	$put_line: proc(w: ^W, buf, p, limit: [^]u8, depth, after, slop: int) -> (new_buf, new_p, new_limit: [^]u8),
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
	SLOP :: JSON_PRETTY_SLOP when PRETTY else JSON_COMPACT_SLOP
	inline_frames: [INLINE_FRAMES]Fast_Frame = ---
	frames := raw_data(inline_frames[:])
	top, cap_frames := 0, INLINE_FRAMES
	defer if cap_frames > INLINE_FRAMES {
		runtime.mem_free_with_size(frames, cap_frames * size_of(Fast_Frame), allocator)
	}
	when SORT_KEYS {
		sorted_entries: [dynamic]Sorted_Json_Entry
		sorted_entries.allocator = allocator
		defer delete(sorted_entries)
	}
	keys := raw_data(plan.strings)
	buf, p, limit := buf_state(w, SLOP)
	cur := Fast_Frame{
		r    = (^Record)(uintptr(plan.root) - size_of(Record)),
		at   = uintptr(value),
		left = 1,
		mode = .Root,
	}
	next: for {
		vf: ^Record
		va: uintptr
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
					if uintptr(p) > uintptr(limit) {
						buf, p, limit = grow(w, buf, p, SLOP, SLOP)
					}
					when PRETTY {
						if cur.lead == '{' {
							p[0], p[1] = '{', '}'
							p = p[2:]
						} else {
							buf, p, limit = put_line(w, buf, p, limit, top - 1, 2, SLOP)
							p[0] = '}'
							p = p[1:]
						}
					} else {
						if cur.lead == '{' {
							p[0], p[1] = '{', '}'
							p = p[2:]
						} else {
							p[0] = '}'
							p = p[1:]
						}
					}
					// Reuse this struct frame for the next element of a list of structs without pop/push.
					up := &frames[top - 1]
					if up.mode == .List && up.left > 0 && (up.r.kind == .Struct || up.r.kind == .Required) && !has_err(w) {
						up.left -= 1
						p[0] = ','
						p = p[1:]
						when PRETTY {
							buf, p, limit = put_line(w, buf, p, limit, top - 1, SLOP, SLOP)
						}
						cur.r, cur.at, cur.lead = up.r.first, up.at, '{'
						up.at += uintptr(up.step)
						continue next
					}
					top -= 1
					cur = frames[top]
					if has_err(w) {
						sync_cursor(w, buf, p)
						return .None, nil
					}
					continue next
				}
			}
			ks := int(r.key_size)
			if ks != 0 {
				if uintptr(p) > uintptr(limit) {
					buf, p, limit = grow(w, buf, p, SLOP, SLOP)
				}
				p[0] = u8(cur.lead)
				cur.lead = ','
				when PRETTY {
					buf, p, limit = put_line(w, buf, p[1:], limit, top, 256 + 16 + 1 + JSON_LEAF_ROOM, SLOP)
				} else {
					p = p[1:]
				}
				key_src := keys[uint(r.key_off):]
				if ks <= 16 {
					intrinsics.unaligned_store((^u128)(p), intrinsics.unaligned_load((^u128)(key_src)))
				} else if ks <= 32 {
					intrinsics.unaligned_store((^u128)(p), intrinsics.unaligned_load((^u128)(key_src)))
					intrinsics.unaligned_store((^u128)(p[ks - 16:]), intrinsics.unaligned_load((^u128)(key_src[ks - 16:])))
				} else {
					intrinsics.mem_copy_non_overlapping(p, key_src, ks)
				}
				p = p[ks:]
				when PRETTY {
					p[0] = ' '
					p = p[1:]
				}
			} else {
				if uintptr(p) > uintptr(limit) {
					buf, p, limit = grow(w, buf, p, SLOP, SLOP)
				}
				p[0] = u8(cur.lead)
				cur.lead = ','
				when PRETTY {
					buf, p, limit = put_line(w, buf, p[1:], limit, top, 64, SLOP)
				} else {
					p = p[1:]
				}
				name := plan.meta[r.meta].name
				wrote := put_string_inline(p, name)
				if wrote > 0 {
					p = p[wrote:]
				} else {
					ok: bool
					buf, p, limit, ok = put_string_sync(w, buf, p, name, SLOP)
					if !ok {
						return .No_Spelling, nil
					}
					if uintptr(p) > uintptr(limit) {
						buf, p, limit = grow(w, buf, p, SLOP, SLOP)
					}
				}
				when PRETTY {
					p[0], p[1] = ':', ' '
					p = p[2:]
				} else {
					p[0] = ':'
					p = p[1:]
				}
			}
			cur.r = intrinsics.ptr_offset(r, 1)
			vf, va = r, cur.at + uintptr(r.offset)
		} else if cur.mode == .Sorted {
			when SORT_KEYS {
				if cur.step >= cur.left {
					if uintptr(p) > uintptr(limit) {
						buf, p, limit = grow(w, buf, p, SLOP, SLOP)
					}
					when PRETTY {
						if cur.lead == '{' {
							p[0], p[1] = '{', '}'
							p = p[2:]
						} else {
							buf, p, limit = put_line(w, buf, p, limit, top - 1, 2, SLOP)
							p[0] = '}'
							p = p[1:]
						}
					} else {
						if cur.lead == '{' {
							p[0], p[1] = '{', '}'
							p = p[2:]
						} else {
							p[0] = '}'
							p = p[1:]
						}
					}
					resize(&sorted_entries, cur.total)
					top -= 1
					cur = frames[top]
					if has_err(w) {
						sync_cursor(w, buf, p)
						return .None, nil
					}
					continue next
				}
				if uintptr(p) > uintptr(limit) {
					buf, p, limit = grow(w, buf, p, SLOP, SLOP)
				}
				entry := &sorted_entries[cur.step]
				cur.step += 1
				p[0] = u8(cur.lead)
				cur.lead = ','
				when PRETTY {
					buf, p, limit = put_line(w, buf, p[1:], limit, top, 64, SLOP)
				} else {
					p = p[1:]
				}
				kstr := sorted_json_key(entry)
				wrote := put_string_inline(p, kstr)
				if wrote > 0 {
					p = p[wrote:]
				} else {
					ok: bool
					buf, p, limit, ok = put_string_sync(w, buf, p, kstr, SLOP)
					if !ok {
						return .No_Spelling, nil
					}
					if uintptr(p) > uintptr(limit) {
						buf, p, limit = grow(w, buf, p, SLOP, SLOP)
					}
				}
				when PRETTY {
					p[0], p[1] = ':', ' '
					p = p[2:]
				} else {
					p[0] = ':'
					p = p[1:]
				}
				vf, va = entry.rec, entry.val
			}
		} else if cur.mode == .List {
			if cur.left == 0 {
				if uintptr(p) > uintptr(limit) {
					buf, p, limit = grow(w, buf, p, SLOP, SLOP)
				}
				when PRETTY {
					buf, p, limit = put_line(w, buf, p, limit, top - 1, 2, SLOP)
					p[0] = ']'
					p = p[1:]
				} else {
					p[0] = ']'
					p = p[1:]
				}
				top -= 1
				cur = frames[top]
				if has_err(w) {
					sync_cursor(w, buf, p)
					return .None, nil
				}
				continue next
			}
			cur.left -= 1
			if uintptr(p) > uintptr(limit) {
				buf, p, limit = grow(w, buf, p, SLOP, SLOP)
			}
			p[0] = ','
			p = p[cur.lead:]
			cur.lead = 1
			when PRETTY {
				buf, p, limit = put_line(w, buf, p, limit, top, JSON_LEAF_ROOM, SLOP)
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
				if uintptr(p) > uintptr(limit) {
					buf, p, limit = grow(w, buf, p, SLOP, SLOP)
				}
				when PRETTY {
					if cur.lead == '{' {
						p[0], p[1] = '{', '}'
						p = p[2:]
					} else {
						buf, p, limit = put_line(w, buf, p, limit, top - 1, 2, SLOP)
						p[0] = '}'
						p = p[1:]
					}
				} else {
					if cur.lead == '{' {
						p[0], p[1] = '{', '}'
						p = p[2:]
					} else {
						p[0] = '}'
						p = p[1:]
					}
				}
				top -= 1
				cur = frames[top]
				if has_err(w) {
					sync_cursor(w, buf, p)
					return .None, nil
				}
				continue next
			}
			cur.step = i + 1
			key := runtime.map_cell_index_dynamic(ks, info.ks, uintptr(i))
			if uintptr(p) > uintptr(limit) {
				buf, p, limit = grow(w, buf, p, SLOP, SLOP)
			}
			p[0] = u8(cur.lead)
			cur.lead = ','
			when PRETTY {
				buf, p, limit = put_line(w, buf, p[1:], limit, top, 32, SLOP)
			} else {
				p = p[1:]
			}
			if m.key_kind == .String {
				kstr := (^string)(key)^
				wrote := put_string_inline(p, kstr)
				if wrote > 0 {
					p = p[wrote:]
				} else {
					ok: bool
					buf, p, limit, ok = put_string_sync(w, buf, p, kstr, SLOP)
					if !ok {
						return .No_Spelling, nil
					}
					if uintptr(p) > uintptr(limit) {
						buf, p, limit = grow(w, buf, p, SLOP, SLOP)
					}
				}
			} else {
				ok: bool
				buf, p, limit, ok = put_non_string_key(plan, m, key, w, buf, p, limit, SLOP, put_string_inline, put_string_sync)
				if !ok {
					return .No_Spelling, nil
				}
			}
			when PRETTY {
				p[0], p[1] = ':', ' '
				p = p[2:]
			} else {
				p[0] = ':'
				p = p[1:]
			}
			vf, va = element_of(cur.r), runtime.map_cell_index_dynamic(vs, info.vs, uintptr(i))
		} else if cur.mode == .Bits {
			i := cur.step
			for i < cur.left && ((^u8)(cur.at + uintptr(i >> 3))^ >> uint(i & 7)) & 1 == 0 {
				i += 1
			}
			if i >= cur.left {
				if uintptr(p) > uintptr(limit) {
					buf, p, limit = grow(w, buf, p, SLOP, SLOP)
				}
				when PRETTY {
					if cur.lead != 0 {
						buf, p, limit = put_line(w, buf, p, limit, top - 1, 2, SLOP)
					}
					p[0] = ']'
					p = p[1:]
				} else {
					p[0] = ']'
					p = p[1:]
				}
				top -= 1
				cur = frames[top]
				if has_err(w) {
					sync_cursor(w, buf, p)
					return .None, nil
				}
				continue next
			}
			cur.step = i + 1
			if uintptr(p) > uintptr(limit) {
				buf, p, limit = grow(w, buf, p, SLOP, SLOP)
			}
			p[0] = ','
			p = p[cur.lead:]
			cur.lead = 1
			when PRETTY {
				buf, p, limit = put_line(w, buf, p, limit, top, JSON_LEAF_ROOM, SLOP)
			}
			mm := &plan.meta[cur.r.meta]
			elem := element_of(cur.r)
			ok: bool
			buf, p, limit, ok = put_enum_scalar(plan, &plan.meta[elem.meta], mm.lower + i64(i), w, buf, p, limit, SLOP, put_string_inline, put_string_sync)
			if !ok {
				return .No_Spelling, nil
			}
			continue next
		} else {
			if cur.left == 0 {
				sync_cursor(w, buf, p)
				return .None, nil
			}
			cur.left = 0
			if uintptr(p) > uintptr(limit) {
				buf, p, limit = grow(w, buf, p, SLOP, SLOP)
			}
			vf, va = cur.r, cur.at
		}

		value: for {
			if vf.kind == .String {
				s := (^string)(va)^
				wrote := put_string_inline(p, s)
				if wrote > 0 {
					p = p[wrote:]
				} else {
					ok: bool
					buf, p, limit, ok = put_string_sync(w, buf, p, s, SLOP)
					if !ok {
						return .No_Spelling, nil
					}
				}
				continue next
			}
			#partial switch vf.kind {
			case .I64:
				p = p[put_i64(p, (^i64)(va)^):]
			case .F64:
				n, ok := put_f64(p, (^f64)(va)^)
				if !ok {
					sync_cursor(w, buf, p)
					return .No_Spelling, nil
				}
				p = p[n:]
			case .Bool:
				if (^bool)(va)^ {
					intrinsics.unaligned_store((^u32le)(p), JSON_TRUE_U32)
					p = p[4:]
				} else {
					intrinsics.unaligned_store((^u64le)(p), JSON_FALSE_U64)
					p = p[5:]
				}
			case .Struct, .Required:
				if top >= tape.DEFAULT_DEPTH {
					sync_cursor(w, buf, p)
					return .Malformed, nil
				}
				when SORT_KEYS {
					old_len := len(sorted_entries)
					block := ([^]Record)(vf.first)
					count := int(plan.meta[vf.meta].count)
					for j in 0 ..< count {
						member := &block[j]
						mm := &plan.meta[member.meta]
						m_at := va + uintptr(member.offset)
						if mm.omit_empty && is_empty(plan, member, m_at) || mm.omit_unset && is_unset(plan, member, m_at) {
							continue
						}
						if _, aerr := append(&sorted_entries, Sorted_Json_Entry{text = mm.name, rec = member, val = m_at}); aerr != nil {
							sync_cursor(w, buf, p)
							return .None, aerr
						}
					}
					if len(sorted_entries) == old_len {
						p[0], p[1] = '{', '}'
						p = p[2:]
					} else {
						if !push_fast_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
							sync_cursor(w, buf, p)
							return .None, err
						}
						sort_sorted_json(sorted_entries[old_len:])
						cur = Fast_Frame{
							left  = len(sorted_entries),
							step  = old_len,
							total = old_len,
							lead  = '{',
							mode  = .Sorted,
						}
					}
				} else {
					if !push_fast_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
						sync_cursor(w, buf, p)
						return .None, err
					}
					cur = Fast_Frame{r = vf.first, at = va, lead = '{', mode = .Struct}
				}
			case .Slice, .Dynamic, .Array:
				if top >= tape.DEFAULT_DEPTH {
					sync_cursor(w, buf, p)
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
					p = p[2:]
				} else {
					elem := element_of(vf)
					if elem.kind == .F64 {
						p[0] = '['
						p = p[1:]
						ea := data
						stride := uintptr(elem.stride)
						for j in 0 ..< n {
							if uintptr(p) > uintptr(limit) {
								buf, p, limit = grow(w, buf, p, SLOP, SLOP)
								if has_err(w) {
									sync_cursor(w, buf, p)
									return .None, nil
								}
							}
							if j > 0 {
								p[0] = ','
								p = p[1:]
							}
							when PRETTY {
								buf, p, limit = put_line(w, buf, p, limit, top + 1, JSON_LEAF_ROOM, SLOP)
							}
							fn, fok := put_f64(p, (^f64)(ea)^)
							if !fok {
								sync_cursor(w, buf, p)
								return .No_Spelling, nil
							}
							p = p[fn:]
							ea += stride
						}
						if uintptr(p) > uintptr(limit) {
							buf, p, limit = grow(w, buf, p, SLOP, SLOP)
						}
						when PRETTY {
							buf, p, limit = put_line(w, buf, p, limit, top, 2, SLOP)
						}
						p[0] = ']'
						p = p[1:]
					} else if elem.kind == .I64 {
						p[0] = '['
						p = p[1:]
						ea := data
						stride := uintptr(elem.stride)
						for j in 0 ..< n {
							if uintptr(p) > uintptr(limit) {
								buf, p, limit = grow(w, buf, p, SLOP, SLOP)
								if has_err(w) {
									sync_cursor(w, buf, p)
									return .None, nil
								}
							}
							if j > 0 {
								p[0] = ','
								p = p[1:]
							}
							when PRETTY {
								buf, p, limit = put_line(w, buf, p, limit, top + 1, JSON_LEAF_ROOM, SLOP)
							}
							p = p[put_i64(p, (^i64)(ea)^):]
							ea += stride
						}
						if uintptr(p) > uintptr(limit) {
							buf, p, limit = grow(w, buf, p, SLOP, SLOP)
						}
						when PRETTY {
							buf, p, limit = put_line(w, buf, p, limit, top, 2, SLOP)
						}
						p[0] = ']'
						p = p[1:]
					} else {
						if !push_fast_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
							sync_cursor(w, buf, p)
							return .None, err
						}
						p[0] = '['
						p = p[1:]
						cur = Fast_Frame{r = elem, at = data, left = n, step = int(elem.stride), total = n, lead = 0, mode = .List}
					}
				}
			case .Map:
				if top >= tape.DEFAULT_DEPTH {
					sync_cursor(w, buf, p)
					return .Malformed, nil
				}
				raw := (^runtime.Raw_Map)(va)^
				if runtime.map_len(raw) == 0 {
					p[0], p[1] = '{', '}'
					p = p[2:]
				} else {
					mm := &plan.meta[vf.meta]
					when SORT_KEYS {
						old_len := len(sorted_entries)
						info := mm.map_info
						ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw, info)
						cap_map := runtime.map_cap(raw)
						val_rec := element_of(vf)
						for slot in 0 ..< cap_map {
							if !runtime.map_hash_is_valid(hs[slot]) {
								continue
							}
							kptr := runtime.map_cell_index_dynamic(ks, info.ks, uintptr(slot))
							vptr := runtime.map_cell_index_dynamic(vs, info.vs, uintptr(slot))
							se := Sorted_Json_Entry{rec = val_rec, val = vptr}
							if !fill_sorted_json_map_key(plan, mm, kptr, &se) {
								sync_cursor(w, buf, p)
								return .No_Spelling, nil
							}
							if _, aerr := append(&sorted_entries, se); aerr != nil {
								sync_cursor(w, buf, p)
								return .None, aerr
							}
						}
						if !push_fast_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
							sync_cursor(w, buf, p)
							return .None, err
						}
						sort_sorted_json(sorted_entries[old_len:])
						cur = Fast_Frame{
							left  = len(sorted_entries),
							step  = old_len,
							total = old_len,
							lead  = '{',
							mode  = .Sorted,
						}
					} else {
						elem := element_of(vf)
						if mm.key_kind == .String && (elem.kind == .I64 || elem.kind == .String) {
							ok: bool
							buf, p, limit, ok = put_flat_string_map(mm.map_info, raw, elem.kind == .I64, top + 1, w, buf, p, limit, SLOP, PRETTY, grow, has_err, put_string_inline, put_string_sync, put_line)
							if !ok {
								return .No_Spelling, nil
							}
							if has_err(w) {
								sync_cursor(w, buf, p)
								return .None, nil
							}
						} else {
							if !push_fast_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
								sync_cursor(w, buf, p)
								return .None, err
							}
							cur = Fast_Frame{r = vf, at = va, left = runtime.map_cap(raw), step = 0, lead = '{', mode = .Map}
						}
					}
				}
			case .Maybe:
				m := &plan.meta[vf.meta]
				if m.tag_size == 0 && (^uintptr)(va)^ == 0 || m.tag_size != 0 && load_size(va + uintptr(m.tag), int(m.tag_size)) == 0 {
					intrinsics.unaligned_store((^u32le)(p), JSON_NULL_U32)
					p = p[4:]
				} else {
					vf = element_of(vf)
					continue value
				}
			case .Ptr:
				to := (^uintptr)(va)^
				if to == 0 {
					intrinsics.unaligned_store((^u32le)(p), JSON_NULL_U32)
					p = p[4:]
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
					p = p[4:]
				} else {
					vf = &plan.records[arm.first - 1]
					continue value
				}
			case .Bit_Set:
				if top >= tape.DEFAULT_DEPTH {
					sync_cursor(w, buf, p)
					return .Malformed, nil
				}
				if !push_fast_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
					sync_cursor(w, buf, p)
					return .None, err
				}
				mm := &plan.meta[vf.meta]
				p[0] = '['
				p = p[1:]
				cur = Fast_Frame{r = vf, at = va, left = min(int(mm.count), int(mm.size) * 8), step = 0, lead = 0, mode = .Bits}
			case:
				rref: Marshal_Refusal
				rerr: tape.Error
				buf, p, limit, rref, rerr = put_rare_scalar(plan, vf, va, w, buf, p, limit, SLOP, put_string_inline, put_string_sync)
				if rerr != nil || rref != .None {
					sync_cursor(w, buf, p)
					return rref, rerr
				}
			}
			continue next
		}
	}
}

@(private, cold)
fill_sorted_json_map_key :: proc(plan: ^Plan, m: ^Meta, key: uintptr, se: ^Sorted_Json_Entry) -> bool #no_bounds_check {
	size := int(m.map_info.ks.size_of_type)
	#partial switch m.key_kind {
	case .String:
		se.text = (^string)(key)^
		return true
	case .Enum:
		ev_raw := load_size(key, size)
		signed := m.enum_info != nil && is_signed(m.enum_info.base)
		sv := sign_extend(ev_raw, size) if signed else i64(ev_raw)
		if plan.options.enums == .Name && m.enum_info != nil {
			for ev, idx in m.enum_info.values {
				if i64(ev) == sv {
					se.text = m.enum_info.names[idx]
					return true
				}
			}
		}
		se.inline_len = u8(put_i64(&se.inline_buf[0], sv) if signed else put_u64(&se.inline_buf[0], ev_raw))
		return true
	case .I8, .I16, .I32, .I64:
		se.inline_len = u8(put_i64(&se.inline_buf[0], sign_extend(load_size(key, size), size)))
		return true
	}
	se.inline_len = u8(put_u64(&se.inline_buf[0], load_size(key, size)))
	return true
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
	buf, p, limit: [^]u8,
	slop: int,
	$put_string_inline: proc "contextless" (p: [^]u8, s: string) -> int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> (new_buf, new_p, new_limit: [^]u8, ok: bool),
) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	size := int(m.map_info.ks.size_of_type)
	#partial switch m.key_kind {
	case .Enum:
		ev_raw := load_size(key, size)
		signed := m.enum_info != nil && is_signed(m.enum_info.base)
		sv := sign_extend(ev_raw, size) if signed else i64(ev_raw)
		if plan.options.enums == .Name && m.enum_info != nil {
			for ev, idx in m.enum_info.values {
				if i64(ev) == sv {
					name := m.enum_info.names[idx]
					wrote := put_string_inline(p, name)
					if wrote > 0 {
						return buf, p[wrote:], limit, true
					}
					return put_string_sync(w, buf, p, name, slop)
				}
			}
		}
		p[0] = '"'
		n := put_i64(p[1:], sv) if signed else put_u64(p[1:], ev_raw)
		p[1 + n] = '"'
		return buf, p[n + 2:], limit, true
	case .I8, .I16, .I32, .I64:
		p[0] = '"'
		n := put_i64(p[1:], sign_extend(load_size(key, size), size))
		p[1 + n] = '"'
		return buf, p[n + 2:], limit, true
	}
	p[0] = '"'
	n := put_u64(p[1:], load_size(key, size))
	p[1 + n] = '"'
	return buf, p[n + 2:], limit, true
}

@(private, cold)
put_enum_scalar :: proc(
	plan: ^Plan,
	m: ^Meta,
	value: i64,
	w: ^$W,
	buf, p, limit: [^]u8,
	slop: int,
	$put_string_inline: proc "contextless" (p: [^]u8, s: string) -> int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> (new_buf, new_p, new_limit: [^]u8, ok: bool),
) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	if plan.options.enums == .Name && m.enum_info != nil {
		for ev, idx in m.enum_info.values {
			if i64(ev) == value {
				name := m.enum_info.names[idx]
				wrote := put_string_inline(p, name)
				if wrote > 0 {
					return buf, p[wrote:], limit, true
				}
				return put_string_sync(w, buf, p, name, slop)
			}
		}
	}
	n := put_i64(p, value) if m.signed else put_u64(p, u64(value))
	return buf, p[n:], limit, true
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

// Tight loop for `map[string]i64` and `map[string]string` (computes `ks, vs, hs` once and keeps `buf, p, limit` in registers).
@(private)
put_flat_string_map :: #force_no_inline proc(
	info: ^runtime.Map_Info,
	raw: runtime.Raw_Map,
	is_i64: bool,
	depth: int,
	w: ^$W,
	buf0, p0, limit0: [^]u8,
	slop: int,
	$PRETTY: bool,
	$grow: proc(w: ^W, buf, p: [^]u8, need, slop: int) -> (new_buf, new_p, new_limit: [^]u8),
	$has_err: proc "contextless" (w: ^W) -> bool,
	$put_string_inline: proc "contextless" (p: [^]u8, s: string) -> int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> (new_buf, new_p, new_limit: [^]u8, ok: bool),
	$put_line: proc(w: ^W, buf, p, limit: [^]u8, depth, after, slop: int) -> (new_buf, new_p, new_limit: [^]u8),
) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	cap_map := runtime.map_cap(raw)
	ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw, info)
	keys_arr := ([^]string)(ks)
	vals_i64 := ([^]i64)(vs)
	vals_str := ([^]string)(vs)
	buf, p, limit := buf0, p0, limit0
	lead := u8('{')
	for i in 0 ..< cap_map {
		if !runtime.map_hash_is_valid(hs[i]) {
			continue
		}
		if uintptr(p) > uintptr(limit) {
			buf, p, limit = grow(w, buf, p, slop, slop)
			if has_err(w) {
				return buf, p, limit, true
			}
		}
		key := keys_arr[i]
		p[0] = lead
		lead = ','
		when PRETTY {
			buf, p, limit = put_line(w, buf, p[1:], limit, depth, 64, slop)
		} else {
			p = p[1:]
		}
		wrote := put_string_inline(p, key)
		if wrote > 0 {
			p = p[wrote:]
		} else {
			ok: bool
			buf, p, limit, ok = put_string_sync(w, buf, p, key, slop)
			if !ok {
				return buf, p, limit, false
			}
			if uintptr(p) > uintptr(limit) {
				buf, p, limit = grow(w, buf, p, slop, slop)
			}
		}
		when PRETTY {
			p[0], p[1] = ':', ' '
			p = p[2:]
		} else {
			p[0] = ':'
			p = p[1:]
		}
		if is_i64 {
			p = p[put_i64(p, vals_i64[i]):]
		} else {
			vstr := vals_str[i]
			vwrote := put_string_inline(p, vstr)
			if vwrote > 0 {
				p = p[vwrote:]
			} else {
				ok: bool
				buf, p, limit, ok = put_string_sync(w, buf, p, vstr, slop)
				if !ok {
					return buf, p, limit, false
				}
			}
		}
	}
	if uintptr(p) > uintptr(limit) {
		buf, p, limit = grow(w, buf, p, slop, slop)
	}
	if lead == '{' {
		p[0], p[1] = '{', '}'
		p = p[2:]
	} else {
		when PRETTY {
			buf, p, limit = put_line(w, buf, p, limit, depth - 1, 2, slop)
		}
		p[0] = '}'
		p = p[1:]
	}
	return buf, p, limit, true
}

@(private, cold)
put_rare_scalar :: #force_no_inline proc(
	plan: ^Plan,
	vf: ^Record,
	va: uintptr,
	w: ^$W,
	buf, p, limit: [^]u8,
	slop: int,
	$put_string_inline: proc "contextless" (p: [^]u8, s: string) -> int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> (new_buf, new_p, new_limit: [^]u8, ok: bool),
) -> ([^]u8, [^]u8, [^]u8, Marshal_Refusal, tape.Error) #no_bounds_check {
	p := p
	#partial switch vf.kind {
	case .I32:
		p = p[put_i64(p, i64((^i32)(va)^)):]
	case .I16:
		p = p[put_i64(p, i64((^i16)(va)^)):]
	case .I8:
		p = p[put_i64(p, i64((^i8)(va)^)):]
	case .U64:
		p = p[put_u64(p, (^u64)(va)^):]
	case .U32:
		p = p[put_u64(p, u64((^u32)(va)^)):]
	case .U16:
		p = p[put_u64(p, u64((^u16)(va)^)):]
	case .U8:
		p = p[put_u64(p, u64((^u8)(va)^)):]
	case .F32:
		n, ok := put_f32(p, (^f32)(va)^)
		if !ok {
			return buf, p, limit, .No_Spelling, nil
		}
		p = p[n:]
	case .Bool_Wide:
		if load_size(va, int(plan.meta[vf.meta].size)) != 0 {
			intrinsics.unaligned_store((^u32le)(p), JSON_TRUE_U32)
			p = p[4:]
		} else {
			intrinsics.unaligned_store((^u64le)(p), JSON_FALSE_U64)
			p = p[5:]
		}
	case .Enum:
		m := &plan.meta[vf.meta]
		signed := m.enum_info != nil && is_signed(m.enum_info.base)
		raw := load_size(va, int(m.size))
		v := sign_extend(raw, int(m.size)) if signed else i64(raw)
		em := Meta{enum_info = m.enum_info, signed = signed}
		nbuf, np, nlimit, ok := put_enum_scalar(plan, &em, v, w, buf, p, limit, slop, put_string_inline, put_string_sync)
		if !ok {
			return nbuf, np, nlimit, .No_Spelling, nil
		}
		return nbuf, np, nlimit, .None, nil
	case .Time:
		tbuf: [SCALAR_ROOM]u8 = ---
		text, ok := rfc3339_text((^time.Time)(va)^, &tbuf)
		if !ok {
			return buf, p, limit, .None, tape.Bad_Option{"time"}
		}
		p[0] = '"'
		intrinsics.mem_copy_non_overlapping(p[1:], raw_data(text), len(text))
		p[1 + len(text)] = '"'
		p = p[len(text) + 2:]
	case:
		return buf, p, limit, .None, tape.Bad_Option{"raw"}
	}
	return buf, p, limit, .None, nil
}

// ============================================================================
// Shortest round-trip float formatting (ported from `zmij`, MIT license)
// Matches `strconv.write_float(..., 'g', -1, 64/32, {})` with `.0` on whole
// floats so `-0.0` keeps its sign bit and floats remain distinct from integers.
// ============================================================================

@(private)
DOUBLE_MANTISSA_BITS :: 52
@(private)
EXP_OFFSET :: 1023 + DOUBLE_MANTISSA_BITS
@(private)
EXTRA_SHIFT :: 6
@(private)
SINGLE_MANTISSA_BITS :: 23
@(private)
SINGLE_EXP_OFFSET :: 127 + SINGLE_MANTISSA_BITS
@(private)
SINGLE_EXTRA_SHIFT :: 34
@(private)
ZERO_POINT8 :: u64(0x3030_3030_3030_2e30)

@(private)
zmij_compute_exp_shift :: #force_inline proc "contextless" (bin_exp, dec_exp: i32) -> i32 {
	return bin_exp + ((-dec_exp * 217707) >> 16) + 1
}

@(private)
zmij_umul192_hi128 :: #force_inline proc "contextless" (x_hi, x_lo, y: u64) -> (hi, lo: u64) {
	p := u128(x_hi) * u128(y)
	lo = u64(p) + u64((u128(x_lo) * u128(y)) >> 64)
	hi = u64(p >> 64) + u64(lo < u64(p))
	return
}

@(private)
zmij_umul128_add_hi64 :: #force_inline proc "contextless" (x, y, c: u64) -> u64 {
	return u64((u128(x) * u128(y) + u128(c)) >> 64)
}

@(private)
zmij_pow10_of :: #force_inline proc "contextless" (k: int) -> (u64, u64) #no_bounds_check {
	e := ZMIJ_POW10_SIG[k + 342]
	return e[0], e[1]
}

@(private)
zmij_to_decimal :: #force_inline proc "contextless" (bin_sig, raw_exp: u64, regular: bool) -> (sig: u64, exp: i32, last: u64, has_last: bool) #no_bounds_check {
	if !regular {
		return zmij_to_decimal_irregular(bin_sig, i32(raw_exp) - EXP_OFFSET)
	}
	dec_exp := i32(u64((u128(raw_exp - EXP_OFFSET) * u128(78913 << 46)) >> 64))
	shift := u64(ZMIJ_EXP_SHIFT[raw_exp]) & 63
	even := 1 - bin_sig & 1
	p_hi, p_lo := zmij_pow10_of(int(-dec_exp - 1))
	hi, lo := zmij_umul192_hi128(p_hi, p_lo, bin_sig << shift)
	integral := hi >> EXTRA_SHIFT
	fractional := hi << (64 - EXTRA_SHIFT) | lo >> EXTRA_SHIFT
	half_ulp := p_hi >> ((EXTRA_SHIFT + 1 - shift) & 63) + even
	round_up := fractional + half_ulp < fractional
	round_down := half_ulp > fractional
	digit := zmij_umul128_add_hi64(fractional, 10, 1 << 63 + 6)
	if fractional == 1 << 62 {
		digit = 2
	}
	return integral + u64(round_up), dec_exp, digit, !(round_up || round_down)
}

@(private, cold)
zmij_to_decimal_irregular :: proc "contextless" (bin_sig: u64, bin_exp: i32) -> (sig: u64, exp: i32, last: u64, has_last: bool) #no_bounds_check {
	dec_exp := (bin_exp * 315653 - 131072) >> 20
	shift := u64(zmij_compute_exp_shift(bin_exp, dec_exp + 1) + EXTRA_SHIFT) & 63
	p_hi, p_lo := zmij_pow10_of(int(-dec_exp - 1))
	hi, lo := zmij_umul192_hi128(p_hi, p_lo, bin_sig << shift)
	integral := hi >> EXTRA_SHIFT
	fractional := hi << (64 - EXTRA_SHIFT) | lo >> EXTRA_SHIFT
	half_ulp := p_hi >> ((EXTRA_SHIFT + 1 - shift) & 63)
	round_up := half_ulp > max(u64) - fractional
	round_down := half_ulp >> 1 >= fractional
	digit := max(
		zmij_umul128_add_hi64(fractional, 10, 1 << 63 - 1),
		zmij_umul128_add_hi64(fractional - half_ulp >> 1, 10, max(u64) - (1 << 32)),
	)
	return integral + u64(round_up), dec_exp, digit, !(round_up || round_down)
}

@(private)
zmij_to_decimal_f32 :: #force_inline proc "contextless" (bin_sig, raw_exp: u64, regular: bool) -> (sig: u64, exp: i32, last: u64, has_last: bool) #no_bounds_check {
	bin_exp := i32(raw_exp) - SINGLE_EXP_OFFSET
	if !regular {
		return zmij_to_decimal_irregular(bin_sig, bin_exp)
	}
	dec_exp := (bin_exp * 315653) >> 20
	shift := u64(zmij_compute_exp_shift(bin_exp, dec_exp + 1) + SINGLE_EXTRA_SHIFT) & 63
	even := 1 - bin_sig & 1
	p_hi, _ := zmij_pow10_of(int(-dec_exp - 1))
	p := u64((u128(p_hi + 1) * u128(bin_sig << shift)) >> 64)
	integral := p >> SINGLE_EXTRA_SHIFT
	fractional := p & (1 << SINGLE_EXTRA_SHIFT - 1)
	half_ulp := p_hi >> ((65 - shift) & 63) + even
	round_up := ((fractional + half_ulp) >> SINGLE_EXTRA_SHIFT) != 0
	round_down := half_ulp > fractional
	integral += u64(round_up)
	digit := (fractional * 10 + (1 << (SINGLE_EXTRA_SHIFT - 1))) >> SINGLE_EXTRA_SHIFT
	if fractional == 1 << (SINGLE_EXTRA_SHIFT - 2) {
		digit = 2
	}
	return integral, dec_exp, digit, !(round_up || round_down)
}

@(private, cold)
zmij_subnormal_decimal :: proc "contextless" (bin_sig: u64) -> (sig: u64, exp: i32, last: u64, has_last: bool) {
	short_sig, e, short_last, short_has_last := zmij_to_decimal(bin_sig, 1, true)
	dec_sig := short_sig * 10 + (short_last if short_has_last else 0)
	for dec_sig < 1_000_000_000_000_000 {
		dec_sig *= 10
		e -= 1
	}
	sig = dec_sig / 10
	last = dec_sig - sig * 10
	return sig, e, last, last != 0
}

@(private)
f64_digits :: #force_inline proc "contextless" (p: [^]u8, bits: u64) -> (k, n: int) #no_bounds_check {
	bin_sig := bits & (1 << DOUBLE_MANTISSA_BITS - 1)
	raw_exp := bits >> DOUBLE_MANTISSA_BITS & 0x7ff
	sig, last: u64
	dec_exp: i32
	has_last: bool
	if raw_exp != 0 {
		sig, dec_exp, last, has_last = zmij_to_decimal(bin_sig | 1 << DOUBLE_MANTISSA_BITS, raw_exp, bin_sig != 0)
	} else {
		if bin_sig == 0 {
			return 0, 0
		}
		sig, dec_exp, last, has_last = zmij_subnormal_decimal(bin_sig)
	}
	extra := int(sig >= 1_000_000_000_000_000)
	high := u64((u128(sig) * 0xabcc77118461cefd) >> 90)
	low := sig - high * 100_000_000
	bhi := bcd8(high)
	blo := bcd8(low)
	intrinsics.unaligned_store((^u64le)(p[extra:]), u64le(bhi | ZEROS8))
	intrinsics.unaligned_store((^u64le)(p[extra + 8:]), u64le(blo | ZEROS8))
	intrinsics.unaligned_store((^u16)(p[extra + 16:]), u16('0' + (last if has_last else 0)) | u16('0') << 8)
	btail := blo if blo != 0 else bhi
	tail_bytes := int(8 - intrinsics.count_leading_zeros(btail) / 8)
	k = extra - 1 + max(8 * int(low != 0) + tail_bytes, 17 * int(has_last))
	return k, int(dec_exp) + 16 + extra
}

@(private)
f32_digits :: #force_inline proc "contextless" (p: [^]u8, bits: u32) -> (k, n: int) #no_bounds_check {
	raw_exp := u64(bits >> 23) & 0xff
	bin_sig := u64(bits & (1 << SINGLE_MANTISSA_BITS - 1))
	if raw_exp == 0 {
		if bin_sig == 0 {
			return 0, 0
		}
		raw_exp = 1
	} else {
		bin_sig |= 1 << SINGLE_MANTISSA_BITS
	}
	sig, exp, last, has_last := zmij_to_decimal_f32(bin_sig, raw_exp, bin_sig != 1 << SINGLE_MANTISSA_BITS)
	digits := bcd8(sig)
	start := int(intrinsics.count_trailing_zeros(digits) >> 3)
	intrinsics.unaligned_store((^u64le)(p[1:]), u64le(digits >> (8 * uint(start)) | ZEROS8))
	intrinsics.unaligned_store((^u64le)(p[9:]), u64le(ZEROS8))
	p[17] = '0'
	k = 8 - int(intrinsics.count_leading_zeros(digits) >> 3) - start
	if has_last && last != 0 {
		k = 9 - start
		p[9 - start] = '0' + u8(last)
	}
	return k, 9 - start + int(exp)
}

@(private)
zmij_exponent_text :: #force_inline proc "contextless" (p: [^]u8, at: int, e: int) -> int #no_bounds_check {
	x := u32(e if e >= 0 else -e)
	hundreds := x / 100
	rest := x - hundreds * 100
	tens := rest / 10
	word := 'e' | u64('+' + u32(e < 0) * 2) << 8 | u64(hundreds + '0') << 16 | u64(tens + '0') << 24 | u64(rest - tens * 10 + '0') << 32
	drop := u64(x < 100)
	word = (word & 0xffff) | (word >> 16 >> (drop * 8)) << 16
	intrinsics.unaligned_store((^u64le)(p[at:]), u64le(word))
	return at + 5 - int(drop)
}

@(private)
zmij_layout_json :: #force_inline proc "contextless" (p: [^]u8, k, n: int) -> int #no_bounds_check {
	if k == 0 {
		p[0], p[1], p[2] = '0', '.', '0'
		return 3
	}
	if u64(n + 3) <= 9 {
		digits := intrinsics.unaligned_load((^u128)(p[1:]))
		d17 := p[17]
		if n <= 0 {
			intrinsics.unaligned_store((^u64le)(p), u64le(ZERO_POINT8))
			intrinsics.unaligned_store((^u128)(p[2 - n:]), digits)
			p[18 - n] = d17
			return 2 - n + k
		}
		intrinsics.unaligned_store((^u128)(p), digits)
		if k <= n {
			p[n], p[n + 1] = '.', '0'
			return n + 2
		}
		intrinsics.unaligned_store((^u128)(p[n + 1:]), digits >> (8 * uint(n)))
		p[n] = '.'
		p[17] = d17
		return k + 1
	}
	p[0] = p[1]
	p[1] = '.'
	return zmij_exponent_text(p, k + int(k > 1), n - 1)
}

// Writes finite `f` directly at `dst` (caller guarantees `JSON_LEAF_ROOM` = 64 bytes), appending `.0` to whole floats
// so `-0.0` keeps its sign bit and floats remain distinct from integers. False for NaN or Inf.
@(private)
put_f64 :: #force_inline proc "contextless" (dst: [^]u8, f: f64) -> (int, bool) #no_bounds_check {
	if f - f != 0 {
		return 0, false
	}
	return put_f64_finite(dst, f), true
}

@(private)
put_f64_finite :: proc "contextless" (dst: [^]u8, f: f64) -> int #no_bounds_check {
	bits := transmute(u64)f
	neg := int(bits >> 63)
	dst[0] = '-'
	p := dst[neg:]
	k, n := f64_digits(p, bits)
	return neg + zmij_layout_json(p, k, n)
}

@(private)
put_f32 :: #force_inline proc "contextless" (dst: [^]u8, f: f32) -> (int, bool) #no_bounds_check {
	if f - f != 0 {
		return 0, false
	}
	return put_f32_finite(dst, f), true
}

@(private)
put_f32_finite :: #force_no_inline proc "contextless" (dst: [^]u8, f: f32) -> int #no_bounds_check {
	bits := transmute(u32)f
	neg := int(bits >> 31)
	dst[0] = '-'
	p := dst[neg:]
	k, n := f32_digits(p, bits)
	return neg + zmij_layout_json(p, k, n)
}


// Generated by tools/generators/zmij_tables.py. Do not edit.
//
// `ZMIJ_POW10_SIG[k + 342]` is the 128-bit significand of 10^k, truncated toward zero with bit 127 set, for
// -342 <= k <= 341. Each row is (high, low), and both `to_decimal` functions scale by it.
@(private, rodata)
ZMIJ_POW10_SIG: [684][2]u64 = {
	{0xeef453d6923bd65a, 0x113faa2906a13b3f}, // 10^-342
	{0x9558b4661b6565f8, 0x4ac7ca59a424c507}, // 10^-341
	{0xbaaee17fa23ebf76, 0x5d79bcf00d2df649}, // 10^-340
	{0xe95a99df8ace6f53, 0xf4d82c2c107973dc}, // 10^-339
	{0x91d8a02bb6c10594, 0x79071b9b8a4be869}, // 10^-338
	{0xb64ec836a47146f9, 0x9748e2826cdee284}, // 10^-337
	{0xe3e27a444d8d98b7, 0xfd1b1b2308169b25}, // 10^-336
	{0x8e6d8c6ab0787f72, 0xfe30f0f5e50e20f7}, // 10^-335
	{0xb208ef855c969f4f, 0xbdbd2d335e51a935}, // 10^-334
	{0xde8b2b66b3bc4723, 0xad2c788035e61382}, // 10^-333
	{0x8b16fb203055ac76, 0x4c3bcb5021afcc31}, // 10^-332
	{0xaddcb9e83c6b1793, 0xdf4abe242a1bbf3d}, // 10^-331
	{0xd953e8624b85dd78, 0xd71d6dad34a2af0d}, // 10^-330
	{0x87d4713d6f33aa6b, 0x8672648c40e5ad68}, // 10^-329
	{0xa9c98d8ccb009506, 0x680efdaf511f18c2}, // 10^-328
	{0xd43bf0effdc0ba48, 0x0212bd1b2566def2}, // 10^-327
	{0x84a57695fe98746d, 0x014bb630f7604b57}, // 10^-326
	{0xa5ced43b7e3e9188, 0x419ea3bd35385e2d}, // 10^-325
	{0xcf42894a5dce35ea, 0x52064cac828675b9}, // 10^-324
	{0x818995ce7aa0e1b2, 0x7343efebd1940993}, // 10^-323
	{0xa1ebfb4219491a1f, 0x1014ebe6c5f90bf8}, // 10^-322
	{0xca66fa129f9b60a6, 0xd41a26e077774ef6}, // 10^-321
	{0xfd00b897478238d0, 0x8920b098955522b4}, // 10^-320
	{0x9e20735e8cb16382, 0x55b46e5f5d5535b0}, // 10^-319
	{0xc5a890362fddbc62, 0xeb2189f734aa831d}, // 10^-318
	{0xf712b443bbd52b7b, 0xa5e9ec7501d523e4}, // 10^-317
	{0x9a6bb0aa55653b2d, 0x47b233c92125366e}, // 10^-316
	{0xc1069cd4eabe89f8, 0x999ec0bb696e840a}, // 10^-315
	{0xf148440a256e2c76, 0xc00670ea43ca250d}, // 10^-314
	{0x96cd2a865764dbca, 0x380406926a5e5728}, // 10^-313
	{0xbc807527ed3e12bc, 0xc605083704f5ecf2}, // 10^-312
	{0xeba09271e88d976b, 0xf7864a44c633682e}, // 10^-311
	{0x93445b8731587ea3, 0x7ab3ee6afbe0211d}, // 10^-310
	{0xb8157268fdae9e4c, 0x5960ea05bad82964}, // 10^-309
	{0xe61acf033d1a45df, 0x6fb92487298e33bd}, // 10^-308
	{0x8fd0c16206306bab, 0xa5d3b6d479f8e056}, // 10^-307
	{0xb3c4f1ba87bc8696, 0x8f48a4899877186c}, // 10^-306
	{0xe0b62e2929aba83c, 0x331acdabfe94de87}, // 10^-305
	{0x8c71dcd9ba0b4925, 0x9ff0c08b7f1d0b14}, // 10^-304
	{0xaf8e5410288e1b6f, 0x07ecf0ae5ee44dd9}, // 10^-303
	{0xdb71e91432b1a24a, 0xc9e82cd9f69d6150}, // 10^-302
	{0x892731ac9faf056e, 0xbe311c083a225cd2}, // 10^-301
	{0xab70fe17c79ac6ca, 0x6dbd630a48aaf406}, // 10^-300
	{0xd64d3d9db981787d, 0x092cbbccdad5b108}, // 10^-299
	{0x85f0468293f0eb4e, 0x25bbf56008c58ea5}, // 10^-298
	{0xa76c582338ed2621, 0xaf2af2b80af6f24e}, // 10^-297
	{0xd1476e2c07286faa, 0x1af5af660db4aee1}, // 10^-296
	{0x82cca4db847945ca, 0x50d98d9fc890ed4d}, // 10^-295
	{0xa37fce126597973c, 0xe50ff107bab528a0}, // 10^-294
	{0xcc5fc196fefd7d0c, 0x1e53ed49a96272c8}, // 10^-293
	{0xff77b1fcbebcdc4f, 0x25e8e89c13bb0f7a}, // 10^-292
	{0x9faacf3df73609b1, 0x77b191618c54e9ac}, // 10^-291
	{0xc795830d75038c1d, 0xd59df5b9ef6a2417}, // 10^-290
	{0xf97ae3d0d2446f25, 0x4b0573286b44ad1d}, // 10^-289
	{0x9becce62836ac577, 0x4ee367f9430aec32}, // 10^-288
	{0xc2e801fb244576d5, 0x229c41f793cda73f}, // 10^-287
	{0xf3a20279ed56d48a, 0x6b43527578c1110f}, // 10^-286
	{0x9845418c345644d6, 0x830a13896b78aaa9}, // 10^-285
	{0xbe5691ef416bd60c, 0x23cc986bc656d553}, // 10^-284
	{0xedec366b11c6cb8f, 0x2cbfbe86b7ec8aa8}, // 10^-283
	{0x94b3a202eb1c3f39, 0x7bf7d71432f3d6a9}, // 10^-282
	{0xb9e08a83a5e34f07, 0xdaf5ccd93fb0cc53}, // 10^-281
	{0xe858ad248f5c22c9, 0xd1b3400f8f9cff68}, // 10^-280
	{0x91376c36d99995be, 0x23100809b9c21fa1}, // 10^-279
	{0xb58547448ffffb2d, 0xabd40a0c2832a78a}, // 10^-278
	{0xe2e69915b3fff9f9, 0x16c90c8f323f516c}, // 10^-277
	{0x8dd01fad907ffc3b, 0xae3da7d97f6792e3}, // 10^-276
	{0xb1442798f49ffb4a, 0x99cd11cfdf41779c}, // 10^-275
	{0xdd95317f31c7fa1d, 0x40405643d711d583}, // 10^-274
	{0x8a7d3eef7f1cfc52, 0x482835ea666b2572}, // 10^-273
	{0xad1c8eab5ee43b66, 0xda3243650005eecf}, // 10^-272
	{0xd863b256369d4a40, 0x90bed43e40076a82}, // 10^-271
	{0x873e4f75e2224e68, 0x5a7744a6e804a291}, // 10^-270
	{0xa90de3535aaae202, 0x711515d0a205cb36}, // 10^-269
	{0xd3515c2831559a83, 0x0d5a5b44ca873e03}, // 10^-268
	{0x8412d9991ed58091, 0xe858790afe9486c2}, // 10^-267
	{0xa5178fff668ae0b6, 0x626e974dbe39a872}, // 10^-266
	{0xce5d73ff402d98e3, 0xfb0a3d212dc8128f}, // 10^-265
	{0x80fa687f881c7f8e, 0x7ce66634bc9d0b99}, // 10^-264
	{0xa139029f6a239f72, 0x1c1fffc1ebc44e80}, // 10^-263
	{0xc987434744ac874e, 0xa327ffb266b56220}, // 10^-262
	{0xfbe9141915d7a922, 0x4bf1ff9f0062baa8}, // 10^-261
	{0x9d71ac8fada6c9b5, 0x6f773fc3603db4a9}, // 10^-260
	{0xc4ce17b399107c22, 0xcb550fb4384d21d3}, // 10^-259
	{0xf6019da07f549b2b, 0x7e2a53a146606a48}, // 10^-258
	{0x99c102844f94e0fb, 0x2eda7444cbfc426d}, // 10^-257
	{0xc0314325637a1939, 0xfa911155fefb5308}, // 10^-256
	{0xf03d93eebc589f88, 0x793555ab7eba27ca}, // 10^-255
	{0x96267c7535b763b5, 0x4bc1558b2f3458de}, // 10^-254
	{0xbbb01b9283253ca2, 0x9eb1aaedfb016f16}, // 10^-253
	{0xea9c227723ee8bcb, 0x465e15a979c1cadc}, // 10^-252
	{0x92a1958a7675175f, 0x0bfacd89ec191ec9}, // 10^-251
	{0xb749faed14125d36, 0xcef980ec671f667b}, // 10^-250
	{0xe51c79a85916f484, 0x82b7e12780e7401a}, // 10^-249
	{0x8f31cc0937ae58d2, 0xd1b2ecb8b0908810}, // 10^-248
	{0xb2fe3f0b8599ef07, 0x861fa7e6dcb4aa15}, // 10^-247
	{0xdfbdcece67006ac9, 0x67a791e093e1d49a}, // 10^-246
	{0x8bd6a141006042bd, 0xe0c8bb2c5c6d24e0}, // 10^-245
	{0xaecc49914078536d, 0x58fae9f773886e18}, // 10^-244
	{0xda7f5bf590966848, 0xaf39a475506a899e}, // 10^-243
	{0x888f99797a5e012d, 0x6d8406c952429603}, // 10^-242
	{0xaab37fd7d8f58178, 0xc8e5087ba6d33b83}, // 10^-241
	{0xd5605fcdcf32e1d6, 0xfb1e4a9a90880a64}, // 10^-240
	{0x855c3be0a17fcd26, 0x5cf2eea09a55067f}, // 10^-239
	{0xa6b34ad8c9dfc06f, 0xf42faa48c0ea481e}, // 10^-238
	{0xd0601d8efc57b08b, 0xf13b94daf124da26}, // 10^-237
	{0x823c12795db6ce57, 0x76c53d08d6b70858}, // 10^-236
	{0xa2cb1717b52481ed, 0x54768c4b0c64ca6e}, // 10^-235
	{0xcb7ddcdda26da268, 0xa9942f5dcf7dfd09}, // 10^-234
	{0xfe5d54150b090b02, 0xd3f93b35435d7c4c}, // 10^-233
	{0x9efa548d26e5a6e1, 0xc47bc5014a1a6daf}, // 10^-232
	{0xc6b8e9b0709f109a, 0x359ab6419ca1091b}, // 10^-231
	{0xf867241c8cc6d4c0, 0xc30163d203c94b62}, // 10^-230
	{0x9b407691d7fc44f8, 0x79e0de63425dcf1d}, // 10^-229
	{0xc21094364dfb5636, 0x985915fc12f542e4}, // 10^-228
	{0xf294b943e17a2bc4, 0x3e6f5b7b17b2939d}, // 10^-227
	{0x979cf3ca6cec5b5a, 0xa705992ceecf9c42}, // 10^-226
	{0xbd8430bd08277231, 0x50c6ff782a838353}, // 10^-225
	{0xece53cec4a314ebd, 0xa4f8bf5635246428}, // 10^-224
	{0x940f4613ae5ed136, 0x871b7795e136be99}, // 10^-223
	{0xb913179899f68584, 0x28e2557b59846e3f}, // 10^-222
	{0xe757dd7ec07426e5, 0x331aeada2fe589cf}, // 10^-221
	{0x9096ea6f3848984f, 0x3ff0d2c85def7621}, // 10^-220
	{0xb4bca50b065abe63, 0x0fed077a756b53a9}, // 10^-219
	{0xe1ebce4dc7f16dfb, 0xd3e8495912c62894}, // 10^-218
	{0x8d3360f09cf6e4bd, 0x64712dd7abbbd95c}, // 10^-217
	{0xb080392cc4349dec, 0xbd8d794d96aacfb3}, // 10^-216
	{0xdca04777f541c567, 0xecf0d7a0fc5583a0}, // 10^-215
	{0x89e42caaf9491b60, 0xf41686c49db57244}, // 10^-214
	{0xac5d37d5b79b6239, 0x311c2875c522ced5}, // 10^-213
	{0xd77485cb25823ac7, 0x7d633293366b828b}, // 10^-212
	{0x86a8d39ef77164bc, 0xae5dff9c02033197}, // 10^-211
	{0xa8530886b54dbdeb, 0xd9f57f830283fdfc}, // 10^-210
	{0xd267caa862a12d66, 0xd072df63c324fd7b}, // 10^-209
	{0x8380dea93da4bc60, 0x4247cb9e59f71e6d}, // 10^-208
	{0xa46116538d0deb78, 0x52d9be85f074e608}, // 10^-207
	{0xcd795be870516656, 0x67902e276c921f8b}, // 10^-206
	{0x806bd9714632dff6, 0x00ba1cd8a3db53b6}, // 10^-205
	{0xa086cfcd97bf97f3, 0x80e8a40eccd228a4}, // 10^-204
	{0xc8a883c0fdaf7df0, 0x6122cd128006b2cd}, // 10^-203
	{0xfad2a4b13d1b5d6c, 0x796b805720085f81}, // 10^-202
	{0x9cc3a6eec6311a63, 0xcbe3303674053bb0}, // 10^-201
	{0xc3f490aa77bd60fc, 0xbedbfc4411068a9c}, // 10^-200
	{0xf4f1b4d515acb93b, 0xee92fb5515482d44}, // 10^-199
	{0x991711052d8bf3c5, 0x751bdd152d4d1c4a}, // 10^-198
	{0xbf5cd54678eef0b6, 0xd262d45a78a0635d}, // 10^-197
	{0xef340a98172aace4, 0x86fb897116c87c34}, // 10^-196
	{0x9580869f0e7aac0e, 0xd45d35e6ae3d4da0}, // 10^-195
	{0xbae0a846d2195712, 0x8974836059cca109}, // 10^-194
	{0xe998d258869facd7, 0x2bd1a438703fc94b}, // 10^-193
	{0x91ff83775423cc06, 0x7b6306a34627ddcf}, // 10^-192
	{0xb67f6455292cbf08, 0x1a3bc84c17b1d542}, // 10^-191
	{0xe41f3d6a7377eeca, 0x20caba5f1d9e4a93}, // 10^-190
	{0x8e938662882af53e, 0x547eb47b7282ee9c}, // 10^-189
	{0xb23867fb2a35b28d, 0xe99e619a4f23aa43}, // 10^-188
	{0xdec681f9f4c31f31, 0x6405fa00e2ec94d4}, // 10^-187
	{0x8b3c113c38f9f37e, 0xde83bc408dd3dd04}, // 10^-186
	{0xae0b158b4738705e, 0x9624ab50b148d445}, // 10^-185
	{0xd98ddaee19068c76, 0x3badd624dd9b0957}, // 10^-184
	{0x87f8a8d4cfa417c9, 0xe54ca5d70a80e5d6}, // 10^-183
	{0xa9f6d30a038d1dbc, 0x5e9fcf4ccd211f4c}, // 10^-182
	{0xd47487cc8470652b, 0x7647c3200069671f}, // 10^-181
	{0x84c8d4dfd2c63f3b, 0x29ecd9f40041e073}, // 10^-180
	{0xa5fb0a17c777cf09, 0xf468107100525890}, // 10^-179
	{0xcf79cc9db955c2cc, 0x7182148d4066eeb4}, // 10^-178
	{0x81ac1fe293d599bf, 0xc6f14cd848405530}, // 10^-177
	{0xa21727db38cb002f, 0xb8ada00e5a506a7c}, // 10^-176
	{0xca9cf1d206fdc03b, 0xa6d90811f0e4851c}, // 10^-175
	{0xfd442e4688bd304a, 0x908f4a166d1da663}, // 10^-174
	{0x9e4a9cec15763e2e, 0x9a598e4e043287fe}, // 10^-173
	{0xc5dd44271ad3cdba, 0x40eff1e1853f29fd}, // 10^-172
	{0xf7549530e188c128, 0xd12bee59e68ef47c}, // 10^-171
	{0x9a94dd3e8cf578b9, 0x82bb74f8301958ce}, // 10^-170
	{0xc13a148e3032d6e7, 0xe36a52363c1faf01}, // 10^-169
	{0xf18899b1bc3f8ca1, 0xdc44e6c3cb279ac1}, // 10^-168
	{0x96f5600f15a7b7e5, 0x29ab103a5ef8c0b9}, // 10^-167
	{0xbcb2b812db11a5de, 0x7415d448f6b6f0e7}, // 10^-166
	{0xebdf661791d60f56, 0x111b495b3464ad21}, // 10^-165
	{0x936b9fcebb25c995, 0xcab10dd900beec34}, // 10^-164
	{0xb84687c269ef3bfb, 0x3d5d514f40eea742}, // 10^-163
	{0xe65829b3046b0afa, 0x0cb4a5a3112a5112}, // 10^-162
	{0x8ff71a0fe2c2e6dc, 0x47f0e785eaba72ab}, // 10^-161
	{0xb3f4e093db73a093, 0x59ed216765690f56}, // 10^-160
	{0xe0f218b8d25088b8, 0x306869c13ec3532c}, // 10^-159
	{0x8c974f7383725573, 0x1e414218c73a13fb}, // 10^-158
	{0xafbd2350644eeacf, 0xe5d1929ef90898fa}, // 10^-157
	{0xdbac6c247d62a583, 0xdf45f746b74abf39}, // 10^-156
	{0x894bc396ce5da772, 0x6b8bba8c328eb783}, // 10^-155
	{0xab9eb47c81f5114f, 0x066ea92f3f326564}, // 10^-154
	{0xd686619ba27255a2, 0xc80a537b0efefebd}, // 10^-153
	{0x8613fd0145877585, 0xbd06742ce95f5f36}, // 10^-152
	{0xa798fc4196e952e7, 0x2c48113823b73704}, // 10^-151
	{0xd17f3b51fca3a7a0, 0xf75a15862ca504c5}, // 10^-150
	{0x82ef85133de648c4, 0x9a984d73dbe722fb}, // 10^-149
	{0xa3ab66580d5fdaf5, 0xc13e60d0d2e0ebba}, // 10^-148
	{0xcc963fee10b7d1b3, 0x318df905079926a8}, // 10^-147
	{0xffbbcfe994e5c61f, 0xfdf17746497f7052}, // 10^-146
	{0x9fd561f1fd0f9bd3, 0xfeb6ea8bedefa633}, // 10^-145
	{0xc7caba6e7c5382c8, 0xfe64a52ee96b8fc0}, // 10^-144
	{0xf9bd690a1b68637b, 0x3dfdce7aa3c673b0}, // 10^-143
	{0x9c1661a651213e2d, 0x06bea10ca65c084e}, // 10^-142
	{0xc31bfa0fe5698db8, 0x486e494fcff30a62}, // 10^-141
	{0xf3e2f893dec3f126, 0x5a89dba3c3efccfa}, // 10^-140
	{0x986ddb5c6b3a76b7, 0xf89629465a75e01c}, // 10^-139
	{0xbe89523386091465, 0xf6bbb397f1135823}, // 10^-138
	{0xee2ba6c0678b597f, 0x746aa07ded582e2c}, // 10^-137
	{0x94db483840b717ef, 0xa8c2a44eb4571cdc}, // 10^-136
	{0xba121a4650e4ddeb, 0x92f34d62616ce413}, // 10^-135
	{0xe896a0d7e51e1566, 0x77b020baf9c81d17}, // 10^-134
	{0x915e2486ef32cd60, 0x0ace1474dc1d122e}, // 10^-133
	{0xb5b5ada8aaff80b8, 0x0d819992132456ba}, // 10^-132
	{0xe3231912d5bf60e6, 0x10e1fff697ed6c69}, // 10^-131
	{0x8df5efabc5979c8f, 0xca8d3ffa1ef463c1}, // 10^-130
	{0xb1736b96b6fd83b3, 0xbd308ff8a6b17cb2}, // 10^-129
	{0xddd0467c64bce4a0, 0xac7cb3f6d05ddbde}, // 10^-128
	{0x8aa22c0dbef60ee4, 0x6bcdf07a423aa96b}, // 10^-127
	{0xad4ab7112eb3929d, 0x86c16c98d2c953c6}, // 10^-126
	{0xd89d64d57a607744, 0xe871c7bf077ba8b7}, // 10^-125
	{0x87625f056c7c4a8b, 0x11471cd764ad4972}, // 10^-124
	{0xa93af6c6c79b5d2d, 0xd598e40d3dd89bcf}, // 10^-123
	{0xd389b47879823479, 0x4aff1d108d4ec2c3}, // 10^-122
	{0x843610cb4bf160cb, 0xcedf722a585139ba}, // 10^-121
	{0xa54394fe1eedb8fe, 0xc2974eb4ee658828}, // 10^-120
	{0xce947a3da6a9273e, 0x733d226229feea32}, // 10^-119
	{0x811ccc668829b887, 0x0806357d5a3f525f}, // 10^-118
	{0xa163ff802a3426a8, 0xca07c2dcb0cf26f7}, // 10^-117
	{0xc9bcff6034c13052, 0xfc89b393dd02f0b5}, // 10^-116
	{0xfc2c3f3841f17c67, 0xbbac2078d443ace2}, // 10^-115
	{0x9d9ba7832936edc0, 0xd54b944b84aa4c0d}, // 10^-114
	{0xc5029163f384a931, 0x0a9e795e65d4df11}, // 10^-113
	{0xf64335bcf065d37d, 0x4d4617b5ff4a16d5}, // 10^-112
	{0x99ea0196163fa42e, 0x504bced1bf8e4e45}, // 10^-111
	{0xc06481fb9bcf8d39, 0xe45ec2862f71e1d6}, // 10^-110
	{0xf07da27a82c37088, 0x5d767327bb4e5a4c}, // 10^-109
	{0x964e858c91ba2655, 0x3a6a07f8d510f86f}, // 10^-108
	{0xbbe226efb628afea, 0x890489f70a55368b}, // 10^-107
	{0xeadab0aba3b2dbe5, 0x2b45ac74ccea842e}, // 10^-106
	{0x92c8ae6b464fc96f, 0x3b0b8bc90012929d}, // 10^-105
	{0xb77ada0617e3bbcb, 0x09ce6ebb40173744}, // 10^-104
	{0xe55990879ddcaabd, 0xcc420a6a101d0515}, // 10^-103
	{0x8f57fa54c2a9eab6, 0x9fa946824a12232d}, // 10^-102
	{0xb32df8e9f3546564, 0x47939822dc96abf9}, // 10^-101
	{0xdff9772470297ebd, 0x59787e2b93bc56f7}, // 10^-100
	{0x8bfbea76c619ef36, 0x57eb4edb3c55b65a}, // 10^-99
	{0xaefae51477a06b03, 0xede622920b6b23f1}, // 10^-98
	{0xdab99e59958885c4, 0xe95fab368e45eced}, // 10^-97
	{0x88b402f7fd75539b, 0x11dbcb0218ebb414}, // 10^-96
	{0xaae103b5fcd2a881, 0xd652bdc29f26a119}, // 10^-95
	{0xd59944a37c0752a2, 0x4be76d3346f0495f}, // 10^-94
	{0x857fcae62d8493a5, 0x6f70a4400c562ddb}, // 10^-93
	{0xa6dfbd9fb8e5b88e, 0xcb4ccd500f6bb952}, // 10^-92
	{0xd097ad07a71f26b2, 0x7e2000a41346a7a7}, // 10^-91
	{0x825ecc24c873782f, 0x8ed400668c0c28c8}, // 10^-90
	{0xa2f67f2dfa90563b, 0x728900802f0f32fa}, // 10^-89
	{0xcbb41ef979346bca, 0x4f2b40a03ad2ffb9}, // 10^-88
	{0xfea126b7d78186bc, 0xe2f610c84987bfa8}, // 10^-87
	{0x9f24b832e6b0f436, 0x0dd9ca7d2df4d7c9}, // 10^-86
	{0xc6ede63fa05d3143, 0x91503d1c79720dbb}, // 10^-85
	{0xf8a95fcf88747d94, 0x75a44c6397ce912a}, // 10^-84
	{0x9b69dbe1b548ce7c, 0xc986afbe3ee11aba}, // 10^-83
	{0xc24452da229b021b, 0xfbe85badce996168}, // 10^-82
	{0xf2d56790ab41c2a2, 0xfae27299423fb9c3}, // 10^-81
	{0x97c560ba6b0919a5, 0xdccd879fc967d41a}, // 10^-80
	{0xbdb6b8e905cb600f, 0x5400e987bbc1c920}, // 10^-79
	{0xed246723473e3813, 0x290123e9aab23b68}, // 10^-78
	{0x9436c0760c86e30b, 0xf9a0b6720aaf6521}, // 10^-77
	{0xb94470938fa89bce, 0xf808e40e8d5b3e69}, // 10^-76
	{0xe7958cb87392c2c2, 0xb60b1d1230b20e04}, // 10^-75
	{0x90bd77f3483bb9b9, 0xb1c6f22b5e6f48c2}, // 10^-74
	{0xb4ecd5f01a4aa828, 0x1e38aeb6360b1af3}, // 10^-73
	{0xe2280b6c20dd5232, 0x25c6da63c38de1b0}, // 10^-72
	{0x8d590723948a535f, 0x579c487e5a38ad0e}, // 10^-71
	{0xb0af48ec79ace837, 0x2d835a9df0c6d851}, // 10^-70
	{0xdcdb1b2798182244, 0xf8e431456cf88e65}, // 10^-69
	{0x8a08f0f8bf0f156b, 0x1b8e9ecb641b58ff}, // 10^-68
	{0xac8b2d36eed2dac5, 0xe272467e3d222f3f}, // 10^-67
	{0xd7adf884aa879177, 0x5b0ed81dcc6abb0f}, // 10^-66
	{0x86ccbb52ea94baea, 0x98e947129fc2b4e9}, // 10^-65
	{0xa87fea27a539e9a5, 0x3f2398d747b36224}, // 10^-64
	{0xd29fe4b18e88640e, 0x8eec7f0d19a03aad}, // 10^-63
	{0x83a3eeeef9153e89, 0x1953cf68300424ac}, // 10^-62
	{0xa48ceaaab75a8e2b, 0x5fa8c3423c052dd7}, // 10^-61
	{0xcdb02555653131b6, 0x3792f412cb06794d}, // 10^-60
	{0x808e17555f3ebf11, 0xe2bbd88bbee40bd0}, // 10^-59
	{0xa0b19d2ab70e6ed6, 0x5b6aceaeae9d0ec4}, // 10^-58
	{0xc8de047564d20a8b, 0xf245825a5a445275}, // 10^-57
	{0xfb158592be068d2e, 0xeed6e2f0f0d56712}, // 10^-56
	{0x9ced737bb6c4183d, 0x55464dd69685606b}, // 10^-55
	{0xc428d05aa4751e4c, 0xaa97e14c3c26b886}, // 10^-54
	{0xf53304714d9265df, 0xd53dd99f4b3066a8}, // 10^-53
	{0x993fe2c6d07b7fab, 0xe546a8038efe4029}, // 10^-52
	{0xbf8fdb78849a5f96, 0xde98520472bdd033}, // 10^-51
	{0xef73d256a5c0f77c, 0x963e66858f6d4440}, // 10^-50
	{0x95a8637627989aad, 0xdde7001379a44aa8}, // 10^-49
	{0xbb127c53b17ec159, 0x5560c018580d5d52}, // 10^-48
	{0xe9d71b689dde71af, 0xaab8f01e6e10b4a6}, // 10^-47
	{0x9226712162ab070d, 0xcab3961304ca70e8}, // 10^-46
	{0xb6b00d69bb55c8d1, 0x3d607b97c5fd0d22}, // 10^-45
	{0xe45c10c42a2b3b05, 0x8cb89a7db77c506a}, // 10^-44
	{0x8eb98a7a9a5b04e3, 0x77f3608e92adb242}, // 10^-43
	{0xb267ed1940f1c61c, 0x55f038b237591ed3}, // 10^-42
	{0xdf01e85f912e37a3, 0x6b6c46dec52f6688}, // 10^-41
	{0x8b61313bbabce2c6, 0x2323ac4b3b3da015}, // 10^-40
	{0xae397d8aa96c1b77, 0xabec975e0a0d081a}, // 10^-39
	{0xd9c7dced53c72255, 0x96e7bd358c904a21}, // 10^-38
	{0x881cea14545c7575, 0x7e50d64177da2e54}, // 10^-37
	{0xaa242499697392d2, 0xdde50bd1d5d0b9e9}, // 10^-36
	{0xd4ad2dbfc3d07787, 0x955e4ec64b44e864}, // 10^-35
	{0x84ec3c97da624ab4, 0xbd5af13bef0b113e}, // 10^-34
	{0xa6274bbdd0fadd61, 0xecb1ad8aeacdd58e}, // 10^-33
	{0xcfb11ead453994ba, 0x67de18eda5814af2}, // 10^-32
	{0x81ceb32c4b43fcf4, 0x80eacf948770ced7}, // 10^-31
	{0xa2425ff75e14fc31, 0xa1258379a94d028d}, // 10^-30
	{0xcad2f7f5359a3b3e, 0x096ee45813a04330}, // 10^-29
	{0xfd87b5f28300ca0d, 0x8bca9d6e188853fc}, // 10^-28
	{0x9e74d1b791e07e48, 0x775ea264cf55347d}, // 10^-27
	{0xc612062576589dda, 0x95364afe032a819d}, // 10^-26
	{0xf79687aed3eec551, 0x3a83ddbd83f52204}, // 10^-25
	{0x9abe14cd44753b52, 0xc4926a9672793542}, // 10^-24
	{0xc16d9a0095928a27, 0x75b7053c0f178293}, // 10^-23
	{0xf1c90080baf72cb1, 0x5324c68b12dd6338}, // 10^-22
	{0x971da05074da7bee, 0xd3f6fc16ebca5e03}, // 10^-21
	{0xbce5086492111aea, 0x88f4bb1ca6bcf584}, // 10^-20
	{0xec1e4a7db69561a5, 0x2b31e9e3d06c32e5}, // 10^-19
	{0x9392ee8e921d5d07, 0x3aff322e62439fcf}, // 10^-18
	{0xb877aa3236a4b449, 0x09befeb9fad487c2}, // 10^-17
	{0xe69594bec44de15b, 0x4c2ebe687989a9b3}, // 10^-16
	{0x901d7cf73ab0acd9, 0x0f9d37014bf60a10}, // 10^-15
	{0xb424dc35095cd80f, 0x538484c19ef38c94}, // 10^-14
	{0xe12e13424bb40e13, 0x2865a5f206b06fb9}, // 10^-13
	{0x8cbccc096f5088cb, 0xf93f87b7442e45d3}, // 10^-12
	{0xafebff0bcb24aafe, 0xf78f69a51539d748}, // 10^-11
	{0xdbe6fecebdedd5be, 0xb573440e5a884d1b}, // 10^-10
	{0x89705f4136b4a597, 0x31680a88f8953030}, // 10^-9
	{0xabcc77118461cefc, 0xfdc20d2b36ba7c3d}, // 10^-8
	{0xd6bf94d5e57a42bc, 0x3d32907604691b4c}, // 10^-7
	{0x8637bd05af6c69b5, 0xa63f9a49c2c1b10f}, // 10^-6
	{0xa7c5ac471b478423, 0x0fcf80dc33721d53}, // 10^-5
	{0xd1b71758e219652b, 0xd3c36113404ea4a8}, // 10^-4
	{0x83126e978d4fdf3b, 0x645a1cac083126e9}, // 10^-3
	{0xa3d70a3d70a3d70a, 0x3d70a3d70a3d70a3}, // 10^-2
	{0xcccccccccccccccc, 0xcccccccccccccccc}, // 10^-1
	{0x8000000000000000, 0x0000000000000000}, // 10^0
	{0xa000000000000000, 0x0000000000000000}, // 10^1
	{0xc800000000000000, 0x0000000000000000}, // 10^2
	{0xfa00000000000000, 0x0000000000000000}, // 10^3
	{0x9c40000000000000, 0x0000000000000000}, // 10^4
	{0xc350000000000000, 0x0000000000000000}, // 10^5
	{0xf424000000000000, 0x0000000000000000}, // 10^6
	{0x9896800000000000, 0x0000000000000000}, // 10^7
	{0xbebc200000000000, 0x0000000000000000}, // 10^8
	{0xee6b280000000000, 0x0000000000000000}, // 10^9
	{0x9502f90000000000, 0x0000000000000000}, // 10^10
	{0xba43b74000000000, 0x0000000000000000}, // 10^11
	{0xe8d4a51000000000, 0x0000000000000000}, // 10^12
	{0x9184e72a00000000, 0x0000000000000000}, // 10^13
	{0xb5e620f480000000, 0x0000000000000000}, // 10^14
	{0xe35fa931a0000000, 0x0000000000000000}, // 10^15
	{0x8e1bc9bf04000000, 0x0000000000000000}, // 10^16
	{0xb1a2bc2ec5000000, 0x0000000000000000}, // 10^17
	{0xde0b6b3a76400000, 0x0000000000000000}, // 10^18
	{0x8ac7230489e80000, 0x0000000000000000}, // 10^19
	{0xad78ebc5ac620000, 0x0000000000000000}, // 10^20
	{0xd8d726b7177a8000, 0x0000000000000000}, // 10^21
	{0x878678326eac9000, 0x0000000000000000}, // 10^22
	{0xa968163f0a57b400, 0x0000000000000000}, // 10^23
	{0xd3c21bcecceda100, 0x0000000000000000}, // 10^24
	{0x84595161401484a0, 0x0000000000000000}, // 10^25
	{0xa56fa5b99019a5c8, 0x0000000000000000}, // 10^26
	{0xcecb8f27f4200f3a, 0x0000000000000000}, // 10^27
	{0x813f3978f8940984, 0x4000000000000000}, // 10^28
	{0xa18f07d736b90be5, 0x5000000000000000}, // 10^29
	{0xc9f2c9cd04674ede, 0xa400000000000000}, // 10^30
	{0xfc6f7c4045812296, 0x4d00000000000000}, // 10^31
	{0x9dc5ada82b70b59d, 0xf020000000000000}, // 10^32
	{0xc5371912364ce305, 0x6c28000000000000}, // 10^33
	{0xf684df56c3e01bc6, 0xc732000000000000}, // 10^34
	{0x9a130b963a6c115c, 0x3c7f400000000000}, // 10^35
	{0xc097ce7bc90715b3, 0x4b9f100000000000}, // 10^36
	{0xf0bdc21abb48db20, 0x1e86d40000000000}, // 10^37
	{0x96769950b50d88f4, 0x1314448000000000}, // 10^38
	{0xbc143fa4e250eb31, 0x17d955a000000000}, // 10^39
	{0xeb194f8e1ae525fd, 0x5dcfab0800000000}, // 10^40
	{0x92efd1b8d0cf37be, 0x5aa1cae500000000}, // 10^41
	{0xb7abc627050305ad, 0xf14a3d9e40000000}, // 10^42
	{0xe596b7b0c643c719, 0x6d9ccd05d0000000}, // 10^43
	{0x8f7e32ce7bea5c6f, 0xe4820023a2000000}, // 10^44
	{0xb35dbf821ae4f38b, 0xdda2802c8a800000}, // 10^45
	{0xe0352f62a19e306e, 0xd50b2037ad200000}, // 10^46
	{0x8c213d9da502de45, 0x4526f422cc340000}, // 10^47
	{0xaf298d050e4395d6, 0x9670b12b7f410000}, // 10^48
	{0xdaf3f04651d47b4c, 0x3c0cdd765f114000}, // 10^49
	{0x88d8762bf324cd0f, 0xa5880a69fb6ac800}, // 10^50
	{0xab0e93b6efee0053, 0x8eea0d047a457a00}, // 10^51
	{0xd5d238a4abe98068, 0x72a4904598d6d880}, // 10^52
	{0x85a36366eb71f041, 0x47a6da2b7f864750}, // 10^53
	{0xa70c3c40a64e6c51, 0x999090b65f67d924}, // 10^54
	{0xd0cf4b50cfe20765, 0xfff4b4e3f741cf6d}, // 10^55
	{0x82818f1281ed449f, 0xbff8f10e7a8921a4}, // 10^56
	{0xa321f2d7226895c7, 0xaff72d52192b6a0d}, // 10^57
	{0xcbea6f8ceb02bb39, 0x9bf4f8a69f764490}, // 10^58
	{0xfee50b7025c36a08, 0x02f236d04753d5b4}, // 10^59
	{0x9f4f2726179a2245, 0x01d762422c946590}, // 10^60
	{0xc722f0ef9d80aad6, 0x424d3ad2b7b97ef5}, // 10^61
	{0xf8ebad2b84e0d58b, 0xd2e0898765a7deb2}, // 10^62
	{0x9b934c3b330c8577, 0x63cc55f49f88eb2f}, // 10^63
	{0xc2781f49ffcfa6d5, 0x3cbf6b71c76b25fb}, // 10^64
	{0xf316271c7fc3908a, 0x8bef464e3945ef7a}, // 10^65
	{0x97edd871cfda3a56, 0x97758bf0e3cbb5ac}, // 10^66
	{0xbde94e8e43d0c8ec, 0x3d52eeed1cbea317}, // 10^67
	{0xed63a231d4c4fb27, 0x4ca7aaa863ee4bdd}, // 10^68
	{0x945e455f24fb1cf8, 0x8fe8caa93e74ef6a}, // 10^69
	{0xb975d6b6ee39e436, 0xb3e2fd538e122b44}, // 10^70
	{0xe7d34c64a9c85d44, 0x60dbbca87196b616}, // 10^71
	{0x90e40fbeea1d3a4a, 0xbc8955e946fe31cd}, // 10^72
	{0xb51d13aea4a488dd, 0x6babab6398bdbe41}, // 10^73
	{0xe264589a4dcdab14, 0xc696963c7eed2dd1}, // 10^74
	{0x8d7eb76070a08aec, 0xfc1e1de5cf543ca2}, // 10^75
	{0xb0de65388cc8ada8, 0x3b25a55f43294bcb}, // 10^76
	{0xdd15fe86affad912, 0x49ef0eb713f39ebe}, // 10^77
	{0x8a2dbf142dfcc7ab, 0x6e3569326c784337}, // 10^78
	{0xacb92ed9397bf996, 0x49c2c37f07965404}, // 10^79
	{0xd7e77a8f87daf7fb, 0xdc33745ec97be906}, // 10^80
	{0x86f0ac99b4e8dafd, 0x69a028bb3ded71a3}, // 10^81
	{0xa8acd7c0222311bc, 0xc40832ea0d68ce0c}, // 10^82
	{0xd2d80db02aabd62b, 0xf50a3fa490c30190}, // 10^83
	{0x83c7088e1aab65db, 0x792667c6da79e0fa}, // 10^84
	{0xa4b8cab1a1563f52, 0x577001b891185938}, // 10^85
	{0xcde6fd5e09abcf26, 0xed4c0226b55e6f86}, // 10^86
	{0x80b05e5ac60b6178, 0x544f8158315b05b4}, // 10^87
	{0xa0dc75f1778e39d6, 0x696361ae3db1c721}, // 10^88
	{0xc913936dd571c84c, 0x03bc3a19cd1e38e9}, // 10^89
	{0xfb5878494ace3a5f, 0x04ab48a04065c723}, // 10^90
	{0x9d174b2dcec0e47b, 0x62eb0d64283f9c76}, // 10^91
	{0xc45d1df942711d9a, 0x3ba5d0bd324f8394}, // 10^92
	{0xf5746577930d6500, 0xca8f44ec7ee36479}, // 10^93
	{0x9968bf6abbe85f20, 0x7e998b13cf4e1ecb}, // 10^94
	{0xbfc2ef456ae276e8, 0x9e3fedd8c321a67e}, // 10^95
	{0xefb3ab16c59b14a2, 0xc5cfe94ef3ea101e}, // 10^96
	{0x95d04aee3b80ece5, 0xbba1f1d158724a12}, // 10^97
	{0xbb445da9ca61281f, 0x2a8a6e45ae8edc97}, // 10^98
	{0xea1575143cf97226, 0xf52d09d71a3293bd}, // 10^99
	{0x924d692ca61be758, 0x593c2626705f9c56}, // 10^100
	{0xb6e0c377cfa2e12e, 0x6f8b2fb00c77836c}, // 10^101
	{0xe498f455c38b997a, 0x0b6dfb9c0f956447}, // 10^102
	{0x8edf98b59a373fec, 0x4724bd4189bd5eac}, // 10^103
	{0xb2977ee300c50fe7, 0x58edec91ec2cb657}, // 10^104
	{0xdf3d5e9bc0f653e1, 0x2f2967b66737e3ed}, // 10^105
	{0x8b865b215899f46c, 0xbd79e0d20082ee74}, // 10^106
	{0xae67f1e9aec07187, 0xecd8590680a3aa11}, // 10^107
	{0xda01ee641a708de9, 0xe80e6f4820cc9495}, // 10^108
	{0x884134fe908658b2, 0x3109058d147fdcdd}, // 10^109
	{0xaa51823e34a7eede, 0xbd4b46f0599fd415}, // 10^110
	{0xd4e5e2cdc1d1ea96, 0x6c9e18ac7007c91a}, // 10^111
	{0x850fadc09923329e, 0x03e2cf6bc604ddb0}, // 10^112
	{0xa6539930bf6bff45, 0x84db8346b786151c}, // 10^113
	{0xcfe87f7cef46ff16, 0xe612641865679a63}, // 10^114
	{0x81f14fae158c5f6e, 0x4fcb7e8f3f60c07e}, // 10^115
	{0xa26da3999aef7749, 0xe3be5e330f38f09d}, // 10^116
	{0xcb090c8001ab551c, 0x5cadf5bfd3072cc5}, // 10^117
	{0xfdcb4fa002162a63, 0x73d9732fc7c8f7f6}, // 10^118
	{0x9e9f11c4014dda7e, 0x2867e7fddcdd9afa}, // 10^119
	{0xc646d63501a1511d, 0xb281e1fd541501b8}, // 10^120
	{0xf7d88bc24209a565, 0x1f225a7ca91a4226}, // 10^121
	{0x9ae757596946075f, 0x3375788de9b06958}, // 10^122
	{0xc1a12d2fc3978937, 0x0052d6b1641c83ae}, // 10^123
	{0xf209787bb47d6b84, 0xc0678c5dbd23a49a}, // 10^124
	{0x9745eb4d50ce6332, 0xf840b7ba963646e0}, // 10^125
	{0xbd176620a501fbff, 0xb650e5a93bc3d898}, // 10^126
	{0xec5d3fa8ce427aff, 0xa3e51f138ab4cebe}, // 10^127
	{0x93ba47c980e98cdf, 0xc66f336c36b10137}, // 10^128
	{0xb8a8d9bbe123f017, 0xb80b0047445d4184}, // 10^129
	{0xe6d3102ad96cec1d, 0xa60dc059157491e5}, // 10^130
	{0x9043ea1ac7e41392, 0x87c89837ad68db2f}, // 10^131
	{0xb454e4a179dd1877, 0x29babe4598c311fb}, // 10^132
	{0xe16a1dc9d8545e94, 0xf4296dd6fef3d67a}, // 10^133
	{0x8ce2529e2734bb1d, 0x1899e4a65f58660c}, // 10^134
	{0xb01ae745b101e9e4, 0x5ec05dcff72e7f8f}, // 10^135
	{0xdc21a1171d42645d, 0x76707543f4fa1f73}, // 10^136
	{0x899504ae72497eba, 0x6a06494a791c53a8}, // 10^137
	{0xabfa45da0edbde69, 0x0487db9d17636892}, // 10^138
	{0xd6f8d7509292d603, 0x45a9d2845d3c42b6}, // 10^139
	{0x865b86925b9bc5c2, 0x0b8a2392ba45a9b2}, // 10^140
	{0xa7f26836f282b732, 0x8e6cac7768d7141e}, // 10^141
	{0xd1ef0244af2364ff, 0x3207d795430cd926}, // 10^142
	{0x8335616aed761f1f, 0x7f44e6bd49e807b8}, // 10^143
	{0xa402b9c5a8d3a6e7, 0x5f16206c9c6209a6}, // 10^144
	{0xcd036837130890a1, 0x36dba887c37a8c0f}, // 10^145
	{0x802221226be55a64, 0xc2494954da2c9789}, // 10^146
	{0xa02aa96b06deb0fd, 0xf2db9baa10b7bd6c}, // 10^147
	{0xc83553c5c8965d3d, 0x6f92829494e5acc7}, // 10^148
	{0xfa42a8b73abbf48c, 0xcb772339ba1f17f9}, // 10^149
	{0x9c69a97284b578d7, 0xff2a760414536efb}, // 10^150
	{0xc38413cf25e2d70d, 0xfef5138519684aba}, // 10^151
	{0xf46518c2ef5b8cd1, 0x7eb258665fc25d69}, // 10^152
	{0x98bf2f79d5993802, 0xef2f773ffbd97a61}, // 10^153
	{0xbeeefb584aff8603, 0xaafb550ffacfd8fa}, // 10^154
	{0xeeaaba2e5dbf6784, 0x95ba2a53f983cf38}, // 10^155
	{0x952ab45cfa97a0b2, 0xdd945a747bf26183}, // 10^156
	{0xba756174393d88df, 0x94f971119aeef9e4}, // 10^157
	{0xe912b9d1478ceb17, 0x7a37cd5601aab85d}, // 10^158
	{0x91abb422ccb812ee, 0xac62e055c10ab33a}, // 10^159
	{0xb616a12b7fe617aa, 0x577b986b314d6009}, // 10^160
	{0xe39c49765fdf9d94, 0xed5a7e85fda0b80b}, // 10^161
	{0x8e41ade9fbebc27d, 0x14588f13be847307}, // 10^162
	{0xb1d219647ae6b31c, 0x596eb2d8ae258fc8}, // 10^163
	{0xde469fbd99a05fe3, 0x6fca5f8ed9aef3bb}, // 10^164
	{0x8aec23d680043bee, 0x25de7bb9480d5854}, // 10^165
	{0xada72ccc20054ae9, 0xaf561aa79a10ae6a}, // 10^166
	{0xd910f7ff28069da4, 0x1b2ba1518094da04}, // 10^167
	{0x87aa9aff79042286, 0x90fb44d2f05d0842}, // 10^168
	{0xa99541bf57452b28, 0x353a1607ac744a53}, // 10^169
	{0xd3fa922f2d1675f2, 0x42889b8997915ce8}, // 10^170
	{0x847c9b5d7c2e09b7, 0x69956135febada11}, // 10^171
	{0xa59bc234db398c25, 0x43fab9837e699095}, // 10^172
	{0xcf02b2c21207ef2e, 0x94f967e45e03f4bb}, // 10^173
	{0x8161afb94b44f57d, 0x1d1be0eebac278f5}, // 10^174
	{0xa1ba1ba79e1632dc, 0x6462d92a69731732}, // 10^175
	{0xca28a291859bbf93, 0x7d7b8f7503cfdcfe}, // 10^176
	{0xfcb2cb35e702af78, 0x5cda735244c3d43e}, // 10^177
	{0x9defbf01b061adab, 0x3a0888136afa64a7}, // 10^178
	{0xc56baec21c7a1916, 0x088aaa1845b8fdd0}, // 10^179
	{0xf6c69a72a3989f5b, 0x8aad549e57273d45}, // 10^180
	{0x9a3c2087a63f6399, 0x36ac54e2f678864b}, // 10^181
	{0xc0cb28a98fcf3c7f, 0x84576a1bb416a7dd}, // 10^182
	{0xf0fdf2d3f3c30b9f, 0x656d44a2a11c51d5}, // 10^183
	{0x969eb7c47859e743, 0x9f644ae5a4b1b325}, // 10^184
	{0xbc4665b596706114, 0x873d5d9f0dde1fee}, // 10^185
	{0xeb57ff22fc0c7959, 0xa90cb506d155a7ea}, // 10^186
	{0x9316ff75dd87cbd8, 0x09a7f12442d588f2}, // 10^187
	{0xb7dcbf5354e9bece, 0x0c11ed6d538aeb2f}, // 10^188
	{0xe5d3ef282a242e81, 0x8f1668c8a86da5fa}, // 10^189
	{0x8fa475791a569d10, 0xf96e017d694487bc}, // 10^190
	{0xb38d92d760ec4455, 0x37c981dcc395a9ac}, // 10^191
	{0xe070f78d3927556a, 0x85bbe253f47b1417}, // 10^192
	{0x8c469ab843b89562, 0x93956d7478ccec8e}, // 10^193
	{0xaf58416654a6babb, 0x387ac8d1970027b2}, // 10^194
	{0xdb2e51bfe9d0696a, 0x06997b05fcc0319e}, // 10^195
	{0x88fcf317f22241e2, 0x441fece3bdf81f03}, // 10^196
	{0xab3c2fddeeaad25a, 0xd527e81cad7626c3}, // 10^197
	{0xd60b3bd56a5586f1, 0x8a71e223d8d3b074}, // 10^198
	{0x85c7056562757456, 0xf6872d5667844e49}, // 10^199
	{0xa738c6bebb12d16c, 0xb428f8ac016561db}, // 10^200
	{0xd106f86e69d785c7, 0xe13336d701beba52}, // 10^201
	{0x82a45b450226b39c, 0xecc0024661173473}, // 10^202
	{0xa34d721642b06084, 0x27f002d7f95d0190}, // 10^203
	{0xcc20ce9bd35c78a5, 0x31ec038df7b441f4}, // 10^204
	{0xff290242c83396ce, 0x7e67047175a15271}, // 10^205
	{0x9f79a169bd203e41, 0x0f0062c6e984d386}, // 10^206
	{0xc75809c42c684dd1, 0x52c07b78a3e60868}, // 10^207
	{0xf92e0c3537826145, 0xa7709a56ccdf8a82}, // 10^208
	{0x9bbcc7a142b17ccb, 0x88a66076400bb691}, // 10^209
	{0xc2abf989935ddbfe, 0x6acff893d00ea435}, // 10^210
	{0xf356f7ebf83552fe, 0x0583f6b8c4124d43}, // 10^211
	{0x98165af37b2153de, 0xc3727a337a8b704a}, // 10^212
	{0xbe1bf1b059e9a8d6, 0x744f18c0592e4c5c}, // 10^213
	{0xeda2ee1c7064130c, 0x1162def06f79df73}, // 10^214
	{0x9485d4d1c63e8be7, 0x8addcb5645ac2ba8}, // 10^215
	{0xb9a74a0637ce2ee1, 0x6d953e2bd7173692}, // 10^216
	{0xe8111c87c5c1ba99, 0xc8fa8db6ccdd0437}, // 10^217
	{0x910ab1d4db9914a0, 0x1d9c9892400a22a2}, // 10^218
	{0xb54d5e4a127f59c8, 0x2503beb6d00cab4b}, // 10^219
	{0xe2a0b5dc971f303a, 0x2e44ae64840fd61d}, // 10^220
	{0x8da471a9de737e24, 0x5ceaecfed289e5d2}, // 10^221
	{0xb10d8e1456105dad, 0x7425a83e872c5f47}, // 10^222
	{0xdd50f1996b947518, 0xd12f124e28f77719}, // 10^223
	{0x8a5296ffe33cc92f, 0x82bd6b70d99aaa6f}, // 10^224
	{0xace73cbfdc0bfb7b, 0x636cc64d1001550b}, // 10^225
	{0xd8210befd30efa5a, 0x3c47f7e05401aa4e}, // 10^226
	{0x8714a775e3e95c78, 0x65acfaec34810a71}, // 10^227
	{0xa8d9d1535ce3b396, 0x7f1839a741a14d0d}, // 10^228
	{0xd31045a8341ca07c, 0x1ede48111209a050}, // 10^229
	{0x83ea2b892091e44d, 0x934aed0aab460432}, // 10^230
	{0xa4e4b66b68b65d60, 0xf81da84d5617853f}, // 10^231
	{0xce1de40642e3f4b9, 0x36251260ab9d668e}, // 10^232
	{0x80d2ae83e9ce78f3, 0xc1d72b7c6b426019}, // 10^233
	{0xa1075a24e4421730, 0xb24cf65b8612f81f}, // 10^234
	{0xc94930ae1d529cfc, 0xdee033f26797b627}, // 10^235
	{0xfb9b7cd9a4a7443c, 0x169840ef017da3b1}, // 10^236
	{0x9d412e0806e88aa5, 0x8e1f289560ee864e}, // 10^237
	{0xc491798a08a2ad4e, 0xf1a6f2bab92a27e2}, // 10^238
	{0xf5b5d7ec8acb58a2, 0xae10af696774b1db}, // 10^239
	{0x9991a6f3d6bf1765, 0xacca6da1e0a8ef29}, // 10^240
	{0xbff610b0cc6edd3f, 0x17fd090a58d32af3}, // 10^241
	{0xeff394dcff8a948e, 0xddfc4b4cef07f5b0}, // 10^242
	{0x95f83d0a1fb69cd9, 0x4abdaf101564f98e}, // 10^243
	{0xbb764c4ca7a4440f, 0x9d6d1ad41abe37f1}, // 10^244
	{0xea53df5fd18d5513, 0x84c86189216dc5ed}, // 10^245
	{0x92746b9be2f8552c, 0x32fd3cf5b4e49bb4}, // 10^246
	{0xb7118682dbb66a77, 0x3fbc8c33221dc2a1}, // 10^247
	{0xe4d5e82392a40515, 0x0fabaf3feaa5334a}, // 10^248
	{0x8f05b1163ba6832d, 0x29cb4d87f2a7400e}, // 10^249
	{0xb2c71d5bca9023f8, 0x743e20e9ef511012}, // 10^250
	{0xdf78e4b2bd342cf6, 0x914da9246b255416}, // 10^251
	{0x8bab8eefb6409c1a, 0x1ad089b6c2f7548e}, // 10^252
	{0xae9672aba3d0c320, 0xa184ac2473b529b1}, // 10^253
	{0xda3c0f568cc4f3e8, 0xc9e5d72d90a2741e}, // 10^254
	{0x8865899617fb1871, 0x7e2fa67c7a658892}, // 10^255
	{0xaa7eebfb9df9de8d, 0xddbb901b98feeab7}, // 10^256
	{0xd51ea6fa85785631, 0x552a74227f3ea565}, // 10^257
	{0x8533285c936b35de, 0xd53a88958f87275f}, // 10^258
	{0xa67ff273b8460356, 0x8a892abaf368f137}, // 10^259
	{0xd01fef10a657842c, 0x2d2b7569b0432d85}, // 10^260
	{0x8213f56a67f6b29b, 0x9c3b29620e29fc73}, // 10^261
	{0xa298f2c501f45f42, 0x8349f3ba91b47b8f}, // 10^262
	{0xcb3f2f7642717713, 0x241c70a936219a73}, // 10^263
	{0xfe0efb53d30dd4d7, 0xed238cd383aa0110}, // 10^264
	{0x9ec95d1463e8a506, 0xf4363804324a40aa}, // 10^265
	{0xc67bb4597ce2ce48, 0xb143c6053edcd0d5}, // 10^266
	{0xf81aa16fdc1b81da, 0xdd94b7868e94050a}, // 10^267
	{0x9b10a4e5e9913128, 0xca7cf2b4191c8326}, // 10^268
	{0xc1d4ce1f63f57d72, 0xfd1c2f611f63a3f0}, // 10^269
	{0xf24a01a73cf2dccf, 0xbc633b39673c8cec}, // 10^270
	{0x976e41088617ca01, 0xd5be0503e085d813}, // 10^271
	{0xbd49d14aa79dbc82, 0x4b2d8644d8a74e18}, // 10^272
	{0xec9c459d51852ba2, 0xddf8e7d60ed1219e}, // 10^273
	{0x93e1ab8252f33b45, 0xcabb90e5c942b503}, // 10^274
	{0xb8da1662e7b00a17, 0x3d6a751f3b936243}, // 10^275
	{0xe7109bfba19c0c9d, 0x0cc512670a783ad4}, // 10^276
	{0x906a617d450187e2, 0x27fb2b80668b24c5}, // 10^277
	{0xb484f9dc9641e9da, 0xb1f9f660802dedf6}, // 10^278
	{0xe1a63853bbd26451, 0x5e7873f8a0396973}, // 10^279
	{0x8d07e33455637eb2, 0xdb0b487b6423e1e8}, // 10^280
	{0xb049dc016abc5e5f, 0x91ce1a9a3d2cda62}, // 10^281
	{0xdc5c5301c56b75f7, 0x7641a140cc7810fb}, // 10^282
	{0x89b9b3e11b6329ba, 0xa9e904c87fcb0a9d}, // 10^283
	{0xac2820d9623bf429, 0x546345fa9fbdcd44}, // 10^284
	{0xd732290fbacaf133, 0xa97c177947ad4095}, // 10^285
	{0x867f59a9d4bed6c0, 0x49ed8eabcccc485d}, // 10^286
	{0xa81f301449ee8c70, 0x5c68f256bfff5a74}, // 10^287
	{0xd226fc195c6a2f8c, 0x73832eec6fff3111}, // 10^288
	{0x83585d8fd9c25db7, 0xc831fd53c5ff7eab}, // 10^289
	{0xa42e74f3d032f525, 0xba3e7ca8b77f5e55}, // 10^290
	{0xcd3a1230c43fb26f, 0x28ce1bd2e55f35eb}, // 10^291
	{0x80444b5e7aa7cf85, 0x7980d163cf5b81b3}, // 10^292
	{0xa0555e361951c366, 0xd7e105bcc332621f}, // 10^293
	{0xc86ab5c39fa63440, 0x8dd9472bf3fefaa7}, // 10^294
	{0xfa856334878fc150, 0xb14f98f6f0feb951}, // 10^295
	{0x9c935e00d4b9d8d2, 0x6ed1bf9a569f33d3}, // 10^296
	{0xc3b8358109e84f07, 0x0a862f80ec4700c8}, // 10^297
	{0xf4a642e14c6262c8, 0xcd27bb612758c0fa}, // 10^298
	{0x98e7e9cccfbd7dbd, 0x8038d51cb897789c}, // 10^299
	{0xbf21e44003acdd2c, 0xe0470a63e6bd56c3}, // 10^300
	{0xeeea5d5004981478, 0x1858ccfce06cac74}, // 10^301
	{0x95527a5202df0ccb, 0x0f37801e0c43ebc8}, // 10^302
	{0xbaa718e68396cffd, 0xd30560258f54e6ba}, // 10^303
	{0xe950df20247c83fd, 0x47c6b82ef32a2069}, // 10^304
	{0x91d28b7416cdd27e, 0x4cdc331d57fa5441}, // 10^305
	{0xb6472e511c81471d, 0xe0133fe4adf8e952}, // 10^306
	{0xe3d8f9e563a198e5, 0x58180fddd97723a6}, // 10^307
	{0x8e679c2f5e44ff8f, 0x570f09eaa7ea7648}, // 10^308
	{0xb201833b35d63f73, 0x2cd2cc6551e513da}, // 10^309
	{0xde81e40a034bcf4f, 0xf8077f7ea65e58d1}, // 10^310
	{0x8b112e86420f6191, 0xfb04afaf27faf782}, // 10^311
	{0xadd57a27d29339f6, 0x79c5db9af1f9b563}, // 10^312
	{0xd94ad8b1c7380874, 0x18375281ae7822bc}, // 10^313
	{0x87cec76f1c830548, 0x8f2293910d0b15b5}, // 10^314
	{0xa9c2794ae3a3c69a, 0xb2eb3875504ddb22}, // 10^315
	{0xd433179d9c8cb841, 0x5fa60692a46151eb}, // 10^316
	{0x849feec281d7f328, 0xdbc7c41ba6bcd333}, // 10^317
	{0xa5c7ea73224deff3, 0x12b9b522906c0800}, // 10^318
	{0xcf39e50feae16bef, 0xd768226b34870a00}, // 10^319
	{0x81842f29f2cce375, 0xe6a1158300d46640}, // 10^320
	{0xa1e53af46f801c53, 0x60495ae3c1097fd0}, // 10^321
	{0xca5e89b18b602368, 0x385bb19cb14bdfc4}, // 10^322
	{0xfcf62c1dee382c42, 0x46729e03dd9ed7b5}, // 10^323
	{0x9e19db92b4e31ba9, 0x6c07a2c26a8346d1}, // 10^324
	{0xc5a05277621be293, 0xc7098b7305241885}, // 10^325
	{0xf70867153aa2db38, 0xb8cbee4fc66d1ea7}, // 10^326
	{0x9a65406d44a5c903, 0x737f74f1dc043328}, // 10^327
	{0xc0fe908895cf3b44, 0x505f522e53053ff2}, // 10^328
	{0xf13e34aabb430a15, 0x647726b9e7c68fef}, // 10^329
	{0x96c6e0eab509e64d, 0x5eca783430dc19f5}, // 10^330
	{0xbc789925624c5fe0, 0xb67d16413d132072}, // 10^331
	{0xeb96bf6ebadf77d8, 0xe41c5bd18c57e88f}, // 10^332
	{0x933e37a534cbaae7, 0x8e91b962f7b6f159}, // 10^333
	{0xb80dc58e81fe95a1, 0x723627bbb5a4adb0}, // 10^334
	{0xe61136f2227e3b09, 0xcec3b1aaa30dd91c}, // 10^335
	{0x8fcac257558ee4e6, 0x213a4f0aa5e8a7b1}, // 10^336
	{0xb3bd72ed2af29e1f, 0xa988e2cd4f62d19d}, // 10^337
	{0xe0accfa875af45a7, 0x93eb1b80a33b8605}, // 10^338
	{0x8c6c01c9498d8b88, 0xbc72f130660533c3}, // 10^339
	{0xaf87023b9bf0ee6a, 0xeb8fad7c7f8680b4}, // 10^340
	{0xdb68c2ca82ed2a05, 0xa67398db9f6820e1}, // 10^341
}

// `compute_exp_shift(bin_exp, dec_exp + 1) + EXTRA_SHIFT` for a regular double of biased exponent `raw_exp`. The table spares
// the multiply and shift on every regular double. Entries 0 and 2047 are never read.
@(private, rodata)
ZMIJ_EXP_SHIFT: [2048]u8 = {
	5, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6,
	3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4,
	5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6,
	4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5,
	6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4,
	5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6,
	4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5,
	6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4,
	5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6,
	3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5,
	6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3,
	4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5,
	6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4,
	5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6,
	4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5,
	6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4,
	5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6,
	4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5,
	6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4,
	5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6,
	3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4,
	5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3,
	4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5,
	6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4,
	5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6,
	4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5,
	6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4,
	5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6,
	4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5,
	6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3,
	4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6,
	3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4,
	5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6,
	4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5,
	6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4,
	5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6,
	4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5,
	6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4,
	5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6,
	3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5,
	6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3,
	4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5,
	6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4,
	5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6,
	4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5,
	6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4,
	5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6,
	4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5,
	6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4,
	5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6,
	3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4,
	5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3,
	4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5,
	6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4,
	5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6,
	4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5,
	6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4,
	5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6,
	4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5,
	6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3,
	4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 4, 5, 6,
	3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4,
	5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6,
	4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5, 6, 4, 5, 6, 3, 4, 5, 6, 4, 5,
}

// ============================================================================
// Direct CBOR marshaler
// ============================================================================

@(private)
CBOR_V :: #simd[16]u8
@(private)
CBOR_PAD :: CBOR_V(0)
@(private)
CBOR_INLINE_META :: 128
@(private)
CBOR_INLINE_KEY_BYTES :: 2048

@(private)
Cbor_Key_Ref :: struct {
	off:      u32,
	size:     u16,
	bad_utf8: bool,
}

@(private)
Cbor_Sort_Span :: struct {
	lo: u32,
	n:  u32,
}

@(private)
Cbor_Map_Entry :: struct {
	head:     [9]u8,
	head_len: u8,
	dec_buf:  [24]u8,
	dec_len:  u8,
	is_text:  bool,
	text:     string,
	rec:      ^Record,
	val:      uintptr,
}

@(private)
Cbor_Frame_Mode :: enum u8 {
	Root,
	Struct,
	Struct_Sorted,
	List,
	Map,
	Map_Sorted,
	Bits,
}

@(private)
Cbor_Frame :: struct {
	r:        ^Record,
	at:       uintptr,
	left:     int,
	step:     int,
	total:    int,
	end_meta: u32,
	has_omit: bool,
	mode:     Cbor_Frame_Mode,
}
when size_of(uintptr) == 8 {
	#assert(size_of(Cbor_Frame) == 48)
}

// Writes CBOR head of major type `major` and argument `arg` at `p` (caller guarantees >= 9 bytes).
@(private)
cbor_put_head :: #force_inline proc "contextless" (p: [^]u8, major: u8, arg: u64) -> int #no_bounds_check {
	m := major << 5
	switch {
	case arg < 24:
		p[0] = m | u8(arg)
		return 1
	case arg <= 0xFF:
		p[0], p[1] = m | 24, u8(arg)
		return 2
	case arg <= 0xFFFF:
		p[0] = m | 25
		intrinsics.unaligned_store((^u16be)(p[1:]), u16be(arg))
		return 3
	case arg <= 0xFFFF_FFFF:
		p[0] = m | 26
		intrinsics.unaligned_store((^u32be)(p[1:]), u32be(arg))
		return 5
	case:
		p[0] = m | 27
		intrinsics.unaligned_store((^u64be)(p[1:]), u64be(arg))
		return 9
	}
}

// Writes signed `v` in CBOR major 0/1 form at `p` (caller guarantees >= 9 bytes).
@(private)
cbor_put_i64 :: #force_inline proc "contextless" (p: [^]u8, v: i64) -> int #no_bounds_check {
	if v >= 0 {
		return cbor_put_head(p, 0, u64(v))
	}
	return cbor_put_head(p, 1, ~u64(v))
}

// Writes `f` in shortest CBOR float encoding (binary16, binary32, binary64; NaN as `f97e00`, `-0.0` preserved) at `p`.
@(private)
cbor_put_f64 :: #force_inline proc "contextless" (p: [^]u8, f: f64) -> int #no_bounds_check {
	if f != f {
		p[0], p[1], p[2] = 0xF9, 0x7E, 0x00
		return 3
	}
	s := f32(f)
	if f64(s) != f {
		p[0] = 0xFB
		intrinsics.unaligned_store((^u64be)(p[1:]), u64be(transmute(u64)f))
		return 9
	}
	h := f16(s)
	if f32(h) == s {
		p[0] = 0xF9
		intrinsics.unaligned_store((^u16be)(p[1:]), u16be(transmute(u16)h))
		return 3
	}
	p[0] = 0xFA
	intrinsics.unaligned_store((^u32be)(p[1:]), u32be(transmute(u32)s))
	return 5
}

@(private)
cbor_put_f32 :: #force_inline proc "contextless" (p: [^]u8, s: f32) -> int #no_bounds_check {
	if s != s {
		p[0], p[1], p[2] = 0xF9, 0x7E, 0x00
		return 3
	}
	h := f16(s)
	if f32(h) == s {
		p[0] = 0xF9
		intrinsics.unaligned_store((^u16be)(p[1:]), u16be(transmute(u16)h))
		return 3
	}
	p[0] = 0xFA
	intrinsics.unaligned_store((^u32be)(p[1:]), u32be(transmute(u32)s))
	return 5
}

@(private)
cbor_short_block :: #force_inline proc "contextless" (src: [^]u8, n: int) -> CBOR_V #no_bounds_check {
	low, high := u64(0), u64(0)
	switch {
	case n > 8:
		low = u64(intrinsics.unaligned_load((^u64le)(src)))
		last := u64(intrinsics.unaligned_load((^u64le)(src[n - 8:])))
		high = last >> (8 * u64(16 - n))
	case n == 8:
		low = u64(intrinsics.unaligned_load((^u64le)(src)))
	case n >= 4:
		first := u64(intrinsics.unaligned_load((^u32le)(src)))
		last := u64(intrinsics.unaligned_load((^u32le)(src[n - 4:])))
		low = first | last << (8 * u64(n - 4))
	case n > 0:
		mid := n / 2
		low = u64(src[0]) | u64(src[mid]) << (8 * u64(mid)) | u64(src[n - 1]) << (8 * u64(n - 1))
	}
	return transmute(CBOR_V)[2]u64{low, high}
}

@(private)
cbor_pad_live :: #force_inline proc "contextless" (live, v: CBOR_V) -> CBOR_V {
	return simd.select(simd.lanes_ne(live, CBOR_V(0)), v, CBOR_PAD)
}

@(private)
cbor_put_text_inline :: #force_inline proc "contextless" (p: [^]u8, s: string) -> int #no_bounds_check {
	when (ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32) && !intrinsics.has_target_feature("simd128") {
		if len(s) == 0 {
			p[0] = 0x60
			return 1
		}
		return 0
	} else {
		n := len(s)
		if n == 0 {
			p[0] = 0x60
			return 1
		}
		src := raw_data(s)
		if n < 16 {
			v, live, ok := kernel.head16(src, n)
			if ok {
				v = cbor_pad_live(live, v)
			} else {
				v = cbor_short_block(src, n)
			}
			if kernel.is_ascii16(v) {
				p[0] = 0x60 | u8(n)
				kernel.store16(p[1:], v)
				return 1 + n
			}
		} else if n <= 32 {
			v0 := kernel.load16(src)
			v1 := kernel.load16(src[n - 16:])
			if kernel.is_ascii16(v0 | v1) {
				if n < 24 {
					p[0] = 0x60 | u8(n)
					kernel.store16(p[1:], v0)
					kernel.store16(p[1 + n - 16:], v1)
					return 1 + n
				}
				p[0], p[1] = 0x78, u8(n)
				kernel.store16(p[2:], v0)
				kernel.store16(p[2 + n - 16:], v1)
				return 2 + n
			}
		}
		return 0
	}
}

@(private)
cbor_put_key_bytes :: #force_inline proc "contextless" (p: [^]u8, src: [^]u8, size: int) -> int #no_bounds_check {
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

@(private, cold)
cbor_count_struct_members :: proc(plan: ^Plan, first: ^Record, at: uintptr) -> u64 #no_bounds_check {
	n := u64(0)
	for r := first; r.kind != .End; r = intrinsics.ptr_offset(r, 1) {
		mm := &plan.meta[r.meta]
		m_at := at + uintptr(r.offset)
		if (mm.omit_empty && is_empty(plan, r, m_at)) || (mm.omit_unset && is_unset(plan, r, m_at)) {
			continue
		}
		n += 1
	}
	return n
}

@(private)
cbor_key_less_written :: proc(a, b: Cbor_Map_Entry) -> bool #no_bounds_check {
	la := int(a.head_len) + len(a.text)
	lb := int(b.head_len) + len(b.text)
	n := min(la, lb)
	ha, hb := int(a.head_len), int(b.head_len)
	for i in 0 ..< n {
		ba := a.head[i] if i < ha else a.text[i - ha]
		bb := b.head[i] if i < hb else b.text[i - hb]
		if ba != bb {
			return ba < bb
		}
	}
	return la < lb
}

@(private)
cbor_key_less_len_first :: proc(a, b: Cbor_Map_Entry) -> bool #no_bounds_check {
	la := int(a.head_len) + len(a.text)
	lb := int(b.head_len) + len(b.text)
	if la != lb {
		return la < lb
	}
	ha, hb := int(a.head_len), int(b.head_len)
	for i in 0 ..< la {
		ba := a.head[i] if i < ha else a.text[i - ha]
		bb := b.head[i] if i < hb else b.text[i - hb]
		if ba != bb {
			return ba < bb
		}
	}
	return false
}

@(private)
cbor_key_less_text :: proc(a, b: Cbor_Map_Entry) -> bool #no_bounds_check {
	a, b := a, b
	sa := a.text if a.is_text else string(a.dec_buf[:a.dec_len])
	sb := b.text if b.is_text else string(b.dec_buf[:b.dec_len])
	return sa < sb
}

@(private)
cbor_key_equal :: proc(a, b: Cbor_Map_Entry) -> bool #no_bounds_check {
	la := int(a.head_len) + len(a.text)
	lb := int(b.head_len) + len(b.text)
	if la != lb || a.head_len != b.head_len {
		return false
	}
	for i in 0 ..< int(a.head_len) {
		if a.head[i] != b.head[i] {
			return false
		}
	}
	return a.text == b.text
}

@(private, cold)
sort_cbor_entries :: proc(s: []Cbor_Map_Entry, order: Cbor_Key_Order) #no_bounds_check {
	less :: #force_inline proc(a, b: Cbor_Map_Entry, order: Cbor_Key_Order) -> bool {
		switch order {
		case .Text:
			return cbor_key_less_text(a, b)
		case .Written:
			return cbor_key_less_written(a, b)
		case .Length_First:
			return cbor_key_less_len_first(a, b)
		case .None:
			return false
		}
		return false
	}
	s := s
	for len(s) > 1 {
		if len(s) <= 16 {
			for i in 1 ..< len(s) {
				cur := s[i]
				j := i - 1
				for j >= 0 && less(cur, s[j], order) {
					s[j + 1] = s[j]
					j -= 1
				}
				s[j + 1] = cur
			}
			return
		}
		mid := len(s) / 2
		p := mid
		if less(s[0], s[mid], order) {
			if less(s[mid], s[len(s) - 1], order) { p = mid } else if less(s[0], s[len(s) - 1], order) { p = len(s) - 1 } else { p = 0 }
		} else {
			if less(s[0], s[len(s) - 1], order) { p = 0 } else if less(s[mid], s[len(s) - 1], order) { p = len(s) - 1 } else { p = mid }
		}
		piv := s[p]
		s[p], s[len(s) - 1] = s[len(s) - 1], piv
		store := 0
		for i in 0 ..< len(s) - 1 {
			if less(s[i], piv, order) {
				s[store], s[i] = s[i], s[store]
				store += 1
			}
		}
		s[store], s[len(s) - 1] = s[len(s) - 1], s[store]
		left, right := s[:store], s[store + 1:]
		if len(left) < len(right) {
			sort_cbor_entries(left, order)
			s = right
		} else {
			sort_cbor_entries(right, order)
			s = left
		}
	}
}

// Direct CBOR marshaler: emits CBOR items straight into `w`'s buffer with `buf, p, limit` in SSA registers,
// supporting indefinite containers (`.Cbor`), definite preferred heads (`.Preferred`), and deterministic sorted keys
// (`.Deterministic`, `.Length_First`, `opts.sort_keys`). Precomputes struct CBOR keys and sorted field orders once per call.
marshal_cbor :: proc(
	value: rawptr,
	T: typeid,
	tag_key: string,
	plan: ^Plan,
	w: ^$W,
	$INDEFINITE: bool,
	$KEY_ORDER: Cbor_Key_Order,
	$buf_state: proc "contextless" (w: ^W, slop: int) -> (buf, p, limit: [^]u8),
	$sync_cursor: proc "contextless" (w: ^W, buf, p: [^]u8),
	$grow: proc(w: ^W, buf, p: [^]u8, need, slop: int) -> (new_buf, new_p, new_limit: [^]u8),
	$has_err: proc "contextless" (w: ^W) -> bool,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> (new_buf, new_p, new_limit: [^]u8, ok: bool),
	allocator := context.allocator,
) -> (refusal: Marshal_Refusal, err: tape.Error) #no_bounds_check {
	SORT_KEYS :: KEY_ORDER != .None
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

	n_meta := len(plan.meta)
	inline_seen: [CBOR_INLINE_META]bool
	inline_omit: [CBOR_INLINE_META]bool
	inline_krefs: [CBOR_INLINE_META]Cbor_Key_Ref
	inline_kbuf: [CBOR_INLINE_KEY_BYTES]u8

	seen := inline_seen[:]
	has_omit := inline_omit[:]
	krefs := inline_krefs[:]
	when SORT_KEYS {
		inline_spans: [CBOR_INLINE_META]Cbor_Sort_Span
		inline_sidx: [CBOR_INLINE_META]u32
		spans := inline_spans[:]
		sidx := inline_sidx[:]
		sidx_dyn: [dynamic]u32
		sidx_using_dyn := false
		sidx_dyn.allocator = allocator
		defer if sidx_using_dyn {
			delete(sidx_dyn)
		}
	}
	kbuf_dyn: [dynamic]u8

	if n_meta > CBOR_INLINE_META {
		seen_mem, aerr := make([]bool, n_meta, allocator)
		if aerr != nil {
			return .None, aerr
		}
		seen = seen_mem
		omit_mem: []bool
		omit_mem, aerr = make([]bool, n_meta, allocator)
		if aerr != nil {
			delete(seen_mem, allocator)
			return .None, aerr
		}
		has_omit = omit_mem
		kref_mem: []Cbor_Key_Ref
		kref_mem, aerr = make([]Cbor_Key_Ref, n_meta, allocator)
		if aerr != nil {
			delete(seen_mem, allocator)
			delete(omit_mem, allocator)
			return .None, aerr
		}
		krefs = kref_mem
		when SORT_KEYS {
			span_mem, serr := make([]Cbor_Sort_Span, n_meta, allocator)
			if serr != nil {
				delete(seen_mem, allocator)
				delete(omit_mem, allocator)
				delete(kref_mem, allocator)
				return .None, serr
			}
			spans = span_mem
		}
	}
	defer if n_meta > CBOR_INLINE_META {
		delete(seen, allocator)
		delete(has_omit, allocator)
		delete(krefs, allocator)
		when SORT_KEYS {
			delete(spans, allocator)
		}
	}

	kbuf_len := 0
	kbuf_using_dyn := false
	kbuf_dyn.allocator = allocator
	defer if kbuf_using_dyn {
		delete(kbuf_dyn)
	}
	kbuf := raw_data(inline_kbuf[:])

	append_kbuf :: proc(b: []u8, inline_ptr: [^]u8, inline_cap: int, using_dyn: ^bool, dyn: ^[dynamic]u8, cur_len: ^int) -> ([^]u8, runtime.Allocator_Error) #no_bounds_check {
		need := cur_len^ + len(b) + 16
		if !using_dyn^ && need <= inline_cap {
			intrinsics.mem_copy_non_overlapping(inline_ptr[cur_len^:], raw_data(b), len(b))
			cur_len^ += len(b)
			return inline_ptr, nil
		}
		if !using_dyn^ {
			if err := resize(dyn, max(need * 2, inline_cap * 2)); err != nil {
				return nil, err
			}
			if cur_len^ > 0 {
				intrinsics.mem_copy_non_overlapping(raw_data(dyn^), inline_ptr, cur_len^)
			}
			using_dyn^ = true
		} else if len(dyn^) < need {
			if err := resize(dyn, max(need * 2, len(dyn^) * 2)); err != nil {
				return nil, err
			}
		}
		intrinsics.mem_copy_non_overlapping(raw_data(dyn^)[cur_len^:], raw_data(b), len(b))
		cur_len^ += len(b)
		return raw_data(dyn^), nil
	}

	// Precompute per-struct CBOR keys (and sorted order when `SORT_KEYS`) once per plan.
	when SORT_KEYS {
		sidx_len := 0
	}
	for &rec in plan.records {
		if rec.kind != .Struct && rec.kind != .Required {
			continue
		}
		scount := int(plan.meta[rec.meta].count)
		end_rec := intrinsics.ptr_offset(rec.first, scount)
		em := end_rec.meta
		if seen[em] {
			continue
		}
		seen[em] = true
		omit_any := false
		for fi in 0 ..< scount {
			member := intrinsics.ptr_offset(rec.first, fi)
			mm := &plan.meta[member.meta]
			if mm.omit_empty || mm.omit_unset {
				omit_any = true
			}
			name := mm.name
			bad := member.key_size == 0 && !kernel.utf8_valid(transmute([]u8)name)
			if len(name) <= 246 {
				tmp_key: [256]u8 = ---
				hl := cbor_put_head(&tmp_key[0], 3, u64(len(name)))
				if len(name) > 0 {
					intrinsics.mem_copy_non_overlapping(&tmp_key[hl], raw_data(name), len(name))
				}
				off := kbuf_len
				aerr: runtime.Allocator_Error
				kbuf, aerr = append_kbuf(tmp_key[:hl + len(name)], raw_data(inline_kbuf[:]), CBOR_INLINE_KEY_BYTES, &kbuf_using_dyn, &kbuf_dyn, &kbuf_len)
				if aerr != nil {
					return .None, aerr
				}
				krefs[member.meta] = {off = u32(off), size = u16(hl + len(name)), bad_utf8 = bad}
			} else {
				krefs[member.meta] = {bad_utf8 = bad}
			}
		}
		has_omit[em] = omit_any
		when SORT_KEYS {
			lo := sidx_len
			if !sidx_using_dyn && lo + scount <= CBOR_INLINE_META {
				for fi in 0 ..< scount {
					inline_sidx[lo + fi] = u32(fi)
				}
				sidx_len += scount
				sidx = inline_sidx[:]
			} else {
				if !sidx_using_dyn {
					if aerr := resize(&sidx_dyn, max((lo + scount) * 2, CBOR_INLINE_META * 2)); aerr != nil {
						return .None, aerr
					}
					if lo > 0 {
						intrinsics.mem_copy_non_overlapping(raw_data(sidx_dyn), raw_data(inline_sidx[:]), lo * size_of(u32))
					}
					sidx_using_dyn = true
				} else if len(sidx_dyn) < lo + scount {
					if aerr := resize(&sidx_dyn, max((lo + scount) * 2, len(sidx_dyn) * 2)); aerr != nil {
						return .None, aerr
					}
				}
				for fi in 0 ..< scount {
					sidx_dyn[lo + fi] = u32(fi)
				}
				sidx_len += scount
				sidx = sidx_dyn[:]
			}
			// Simple in-place insertion sort over `scount` fields using `rec.first`, `plan.meta`, `krefs`, `kbuf`.
			sub := sidx[lo:lo + scount]
			for a in 1 ..< scount {
				cur_idx := sub[a]
				m_a := intrinsics.ptr_offset(rec.first, int(cur_idx)).meta
				name_a := plan.meta[m_a].name
				j := a - 1
				for j >= 0 {
					m_b := intrinsics.ptr_offset(rec.first, int(sub[j])).meta
					name_b := plan.meta[m_b].name
					less := false
					when KEY_ORDER == .Text {
						less = name_a < name_b
					} else when KEY_ORDER == .Written {
						ref_a := krefs[m_a]
						ref_b := krefs[m_b]
						if ref_a.size > 0 && ref_b.size > 0 {
							less = string(kbuf[ref_a.off:][:ref_a.size]) < string(kbuf[ref_b.off:][:ref_b.size])
						} else {
							less = len(name_a) < len(name_b) || len(name_a) == len(name_b) && name_a < name_b
						}
					} else when KEY_ORDER == .Length_First {
						ref_a := krefs[m_a]
						ref_b := krefs[m_b]
						if ref_a.size > 0 && ref_b.size > 0 {
							if ref_a.size != ref_b.size {
								less = ref_a.size < ref_b.size
							} else {
								less = string(kbuf[ref_a.off:][:ref_a.size]) < string(kbuf[ref_b.off:][:ref_b.size])
							}
						} else {
							less = len(name_a) < len(name_b) || len(name_a) == len(name_b) && name_a < name_b
						}
					}
					if !less {
						break
					}
					sub[j + 1] = sub[j]
					j -= 1
				}
				sub[j + 1] = cur_idx
			}
			spans[em] = {lo = u32(lo), n = u32(scount)}
		}
	}

	inline_frames: [INLINE_FRAMES]Cbor_Frame = ---
	frames := raw_data(inline_frames[:])
	top, cap_frames := 0, INLINE_FRAMES
	defer if cap_frames > INLINE_FRAMES {
		runtime.mem_free_with_size(frames, cap_frames * size_of(Cbor_Frame), allocator)
	}
	when SORT_KEYS {
		map_entries: [dynamic]Cbor_Map_Entry
		map_entries.allocator = allocator
		defer delete(map_entries)
	}
	buf, p, limit := buf_state(w, CBOR_SLOP)
	cur := Cbor_Frame{
		r    = (^Record)(uintptr(plan.root) - size_of(Record)),
		at   = uintptr(value),
		left = 1,
		mode = .Root,
	}

	next: for {
		vf: ^Record
		va: uintptr
		switch cur.mode {
		case .Struct:
			r := cur.r
			if cur.has_omit {
				for r.kind != .End {
					mm := &plan.meta[r.meta]
					m_at := cur.at + uintptr(r.offset)
					if (mm.omit_empty && is_empty(plan, r, m_at)) || (mm.omit_unset && is_unset(plan, r, m_at)) {
						r = intrinsics.ptr_offset(r, 1)
						continue
					}
					break
				}
			}
			if r.kind == .End {
				if uintptr(p) > uintptr(limit) {
					buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
				}
				when INDEFINITE {
					p[0] = 0xFF
					p = p[1:]
				}
				up := &frames[top - 1]
				if up.mode == .List && up.left > 0 && (up.r.kind == .Struct || up.r.kind == .Required) && !has_err(w) {
					up.left -= 1
					when INDEFINITE {
						p[0] = 0xBF
						p = p[1:]
						cur.r, cur.at = up.r.first, up.at
						up.at += uintptr(up.step)
						continue next
					} else {
						em := cur.end_meta
						if cur.has_omit {
							cnt := cbor_count_struct_members(plan, up.r.first, up.at)
							p = p[cbor_put_head(p, 5, cnt):]
							if cnt == 0 {
								up.at += uintptr(up.step)
								continue next
							}
						} else {
							p = p[cbor_put_head(p, 5, u64(plan.meta[up.r.meta].count)):]
						}
						cur.r, cur.at, cur.end_meta = up.r.first, up.at, em
						up.at += uintptr(up.step)
						continue next
					}
				}
				top -= 1
				cur = frames[top]
				if has_err(w) {
					sync_cursor(w, buf, p)
					return .None, nil
				}
				continue next
			}
			if uintptr(p) > uintptr(limit) {
				buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
			}
			ref := krefs[r.meta]
			if ref.bad_utf8 {
				sync_cursor(w, buf, p)
				return .No_Spelling, nil
			}
			if ref.size > 0 {
				p = p[cbor_put_key_bytes(p, kbuf[ref.off:], int(ref.size)):]
			} else {
				ok: bool
				buf, p, limit, ok = put_string_sync(w, buf, p, plan.meta[r.meta].name, CBOR_SLOP)
				if !ok {
					return .No_Spelling, nil
				}
				if uintptr(p) > uintptr(limit) {
					buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
				}
			}
			cur.r = intrinsics.ptr_offset(r, 1)
			vf, va = r, cur.at + uintptr(r.offset)
		case .Struct_Sorted:
			when SORT_KEYS {
				found := false
				member: ^Record
				for cur.left > 0 {
					idx := sidx[cur.step]
					cur.step += 1
					cur.left -= 1
					member = intrinsics.ptr_offset(cur.r, int(idx))
					if cur.has_omit {
						mm := &plan.meta[member.meta]
						m_at := cur.at + uintptr(member.offset)
						if (mm.omit_empty && is_empty(plan, member, m_at)) || (mm.omit_unset && is_unset(plan, member, m_at)) {
							continue
						}
					}
					found = true
					break
				}
				if !found {
					up := &frames[top - 1]
					if up.mode == .List && up.left > 0 && (up.r.kind == .Struct || up.r.kind == .Required) && !has_err(w) {
						if uintptr(p) > uintptr(limit) {
							buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
						}
						up.left -= 1
						em := cur.end_meta
						sp := spans[em]
						cnt := u64(sp.n)
						if cur.has_omit {
							cnt = cbor_count_struct_members(plan, up.r.first, up.at)
						}
						p = p[cbor_put_head(p, 5, cnt):]
						cur.at = up.at
						cur.step = int(sp.lo)
						cur.left = int(sp.n) if cnt > 0 else 0
						up.at += uintptr(up.step)
						continue next
					}
					top -= 1
					cur = frames[top]
					if has_err(w) {
						sync_cursor(w, buf, p)
						return .None, nil
					}
					continue next
				}
				if uintptr(p) > uintptr(limit) {
					buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
				}
				ref := krefs[member.meta]
				if ref.bad_utf8 {
					sync_cursor(w, buf, p)
					return .No_Spelling, nil
				}
				if ref.size > 0 {
					p = p[cbor_put_key_bytes(p, kbuf[ref.off:], int(ref.size)):]
				} else {
					ok: bool
					buf, p, limit, ok = put_string_sync(w, buf, p, plan.meta[member.meta].name, CBOR_SLOP)
					if !ok {
						return .No_Spelling, nil
					}
					if uintptr(p) > uintptr(limit) {
						buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
					}
				}
				vf, va = member, cur.at + uintptr(member.offset)
			}
		case .List:
			if cur.left == 0 {
				when INDEFINITE {
					if uintptr(p) > uintptr(limit) {
						buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
					}
					p[0] = 0xFF
					p = p[1:]
				}
				top -= 1
				cur = frames[top]
				if has_err(w) {
					sync_cursor(w, buf, p)
					return .None, nil
				}
				continue next
			}
			cur.left -= 1
			if uintptr(p) > uintptr(limit) {
				buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
			}
			vf, va = cur.r, cur.at
			cur.at += uintptr(cur.step)
		case .Map:
			m := &plan.meta[cur.r.meta]
			info := m.map_info
			raw := (^runtime.Raw_Map)(cur.at)^
			ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw, info)
			i := cur.step
			for i < cur.left && !runtime.map_hash_is_valid(hs[i]) {
				i += 1
			}
			if i >= cur.left {
				when INDEFINITE {
					if uintptr(p) > uintptr(limit) {
						buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
					}
					p[0] = 0xFF
					p = p[1:]
				}
				top -= 1
				cur = frames[top]
				if has_err(w) {
					sync_cursor(w, buf, p)
					return .None, nil
				}
				continue next
			}
			cur.step = i + 1
			key := runtime.map_cell_index_dynamic(ks, info.ks, uintptr(i))
			if uintptr(p) > uintptr(limit) {
				buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
			}
			if m.key_kind == .String {
				kstr := (^string)(key)^
				wrote := cbor_put_text_inline(p, kstr)
				if wrote > 0 {
					p = p[wrote:]
				} else {
					ok: bool
					buf, p, limit, ok = put_string_sync(w, buf, p, kstr, CBOR_SLOP)
					if !ok {
						return .No_Spelling, nil
					}
					if uintptr(p) > uintptr(limit) {
						buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
					}
				}
			} else {
				ok: bool
				buf, p, limit, ok = cbor_put_non_string_key(plan, m, key, w, buf, p, limit, CBOR_SLOP, put_string_sync)
				if !ok {
					return .No_Spelling, nil
				}
			}
			vf, va = element_of(cur.r), runtime.map_cell_index_dynamic(vs, info.vs, uintptr(i))
		case .Map_Sorted:
			when SORT_KEYS {
				if cur.step >= cur.left {
					resize(&map_entries, cur.total)
					top -= 1
					cur = frames[top]
					if has_err(w) {
						sync_cursor(w, buf, p)
						return .None, nil
					}
					continue next
				}
				if uintptr(p) > uintptr(limit) {
					buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
				}
				e := &map_entries[cur.step]
				cur.step += 1
				if e.is_text && KEY_ORDER == .Text {
					wrote := cbor_put_text_inline(p, e.text)
					if wrote > 0 {
						p = p[wrote:]
					} else {
						ok: bool
						buf, p, limit, ok = put_string_sync(w, buf, p, e.text, CBOR_SLOP)
						if !ok {
							return .No_Spelling, nil
						}
						if uintptr(p) > uintptr(limit) {
							buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
						}
					}
				} else if KEY_ORDER == .Text {
					// Pre-formatted integer in `e.text` was decimal; re-emit integer/uint from `e.head` or store.
					hl := int(e.head_len)
					intrinsics.mem_copy_non_overlapping(p, &e.head[0], hl)
					p = p[hl:]
				} else {
					hl := int(e.head_len)
					intrinsics.mem_copy_non_overlapping(p, &e.head[0], hl)
					p = p[hl:]
					if len(e.text) > 0 {
						if len(e.text) <= 256 {
							intrinsics.mem_copy_non_overlapping(p, raw_data(e.text), len(e.text))
							p = p[len(e.text):]
						} else {
							for at := 0; at < len(e.text); at += 4096 {
								chunk := min(4096, len(e.text) - at)
								buf, p, limit = grow(w, buf, p, chunk, CBOR_SLOP)
								intrinsics.mem_copy_non_overlapping(p, raw_data(e.text)[at:], chunk)
								p = p[chunk:]
							}
							if uintptr(p) > uintptr(limit) {
								buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
							}
						}
					}
				}
				vf, va = e.rec, e.val
			}
		case .Bits:
			i := cur.step
			for i < cur.left && ((^u8)(cur.at + uintptr(i >> 3))^ >> uint(i & 7)) & 1 == 0 {
				i += 1
			}
			if i >= cur.left {
				when INDEFINITE {
					if uintptr(p) > uintptr(limit) {
						buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
					}
					p[0] = 0xFF
					p = p[1:]
				}
				top -= 1
				cur = frames[top]
				if has_err(w) {
					sync_cursor(w, buf, p)
					return .None, nil
				}
				continue next
			}
			cur.step = i + 1
			if uintptr(p) > uintptr(limit) {
				buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
			}
			mm := &plan.meta[cur.r.meta]
			elem := element_of(cur.r)
			ok: bool
			buf, p, limit, ok = cbor_put_enum_scalar(plan, &plan.meta[elem.meta], mm.lower + i64(i), w, buf, p, limit, CBOR_SLOP, put_string_sync)
			if !ok {
				return .No_Spelling, nil
			}
			continue next
		case .Root:
			if cur.left == 0 {
				sync_cursor(w, buf, p)
				return .None, nil
			}
			cur.left = 0
			if uintptr(p) > uintptr(limit) {
				buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
			}
			vf, va = cur.r, cur.at
		}

		value: for {
			if vf.kind == .String {
				s := (^string)(va)^
				wrote := cbor_put_text_inline(p, s)
				if wrote > 0 {
					p = p[wrote:]
				} else {
					ok: bool
					buf, p, limit, ok = put_string_sync(w, buf, p, s, CBOR_SLOP)
					if !ok {
						return .No_Spelling, nil
					}
				}
				continue next
			}
			#partial switch vf.kind {
			case .I64:
				p = p[cbor_put_i64(p, (^i64)(va)^):]
			case .F64:
				p = p[cbor_put_f64(p, (^f64)(va)^):]
			case .Bool:
				p[0] = 0xF5 if (^bool)(va)^ else 0xF4
				p = p[1:]
			case .Struct, .Required:
				if top >= tape.DEFAULT_DEPTH {
					sync_cursor(w, buf, p)
					return .Malformed, nil
				}
				scount := int(plan.meta[vf.meta].count)
				end_meta := intrinsics.ptr_offset(vf.first, scount).meta
				omit := has_omit[end_meta]
				when SORT_KEYS {
					sp := spans[end_meta]
					cnt := u64(sp.n)
					if omit {
						cnt = cbor_count_struct_members(plan, vf.first, va)
					}
					p = p[cbor_put_head(p, 5, cnt):]
					if cnt > 0 {
						if !cbor_push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
							sync_cursor(w, buf, p)
							return .None, err
						}
						cur = Cbor_Frame{r = vf.first, at = va, step = int(sp.lo), left = int(sp.n), end_meta = end_meta, has_omit = omit, mode = .Struct_Sorted}
					}
				} else {
					when INDEFINITE {
						if !cbor_push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
							sync_cursor(w, buf, p)
							return .None, err
						}
						p[0] = 0xBF
						p = p[1:]
						cur = Cbor_Frame{r = vf.first, at = va, end_meta = end_meta, has_omit = omit, mode = .Struct}
					} else {
						cnt := u64(scount)
						if omit {
							cnt = cbor_count_struct_members(plan, vf.first, va)
						}
						p = p[cbor_put_head(p, 5, cnt):]
						if cnt > 0 {
							if !cbor_push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
								sync_cursor(w, buf, p)
								return .None, err
							}
							cur = Cbor_Frame{r = vf.first, at = va, end_meta = end_meta, has_omit = omit, mode = .Struct}
						}
					}
				}
			case .Slice, .Dynamic, .Array:
				if top >= tape.DEFAULT_DEPTH {
					sync_cursor(w, buf, p)
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
					when INDEFINITE {
						p[0], p[1] = 0x9F, 0xFF
						p = p[2:]
					} else {
						p[0] = 0x80
						p = p[1:]
					}
				} else {
					elem := element_of(vf)
					if elem.kind == .F64 {
						when INDEFINITE {
							p[0] = 0x9F
							p = p[1:]
						} else {
							p = p[cbor_put_head(p, 4, u64(n)):]
						}
						ea := data
						stride := uintptr(elem.stride)
						for _ in 0 ..< n {
							if uintptr(p) > uintptr(limit) {
								buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
								if has_err(w) {
									sync_cursor(w, buf, p)
									return .None, nil
								}
							}
							p = p[cbor_put_f64(p, (^f64)(ea)^):]
							ea += stride
						}
						when INDEFINITE {
							if uintptr(p) > uintptr(limit) {
								buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
							}
							p[0] = 0xFF
							p = p[1:]
						}
					} else if elem.kind == .I64 {
						when INDEFINITE {
							p[0] = 0x9F
							p = p[1:]
						} else {
							p = p[cbor_put_head(p, 4, u64(n)):]
						}
						ea := data
						stride := uintptr(elem.stride)
						for _ in 0 ..< n {
							if uintptr(p) > uintptr(limit) {
								buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
								if has_err(w) {
									sync_cursor(w, buf, p)
									return .None, nil
								}
							}
							p = p[cbor_put_i64(p, (^i64)(ea)^):]
							ea += stride
						}
						when INDEFINITE {
							if uintptr(p) > uintptr(limit) {
								buf, p, limit = grow(w, buf, p, CBOR_SLOP, CBOR_SLOP)
							}
							p[0] = 0xFF
							p = p[1:]
						}
					} else {
						if !cbor_push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
							sync_cursor(w, buf, p)
							return .None, err
						}
						when INDEFINITE {
							p[0] = 0x9F
							p = p[1:]
						} else {
							p = p[cbor_put_head(p, 4, u64(n)):]
						}
						cur = Cbor_Frame{r = elem, at = data, left = n, step = int(elem.stride), mode = .List}
					}
				}
			case .Map:
				if top >= tape.DEFAULT_DEPTH {
					sync_cursor(w, buf, p)
					return .Malformed, nil
				}
				raw := (^runtime.Raw_Map)(va)^
				mlen := runtime.map_len(raw)
				if mlen == 0 {
					when INDEFINITE {
						p[0], p[1] = 0xBF, 0xFF
						p = p[2:]
					} else {
						p[0] = 0xA0
						p = p[1:]
					}
				} else {
					mm := &plan.meta[vf.meta]
					when SORT_KEYS {
						old_len := len(map_entries)
						info := mm.map_info
						ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw, info)
						cap_map := runtime.map_cap(raw)
						val_rec := element_of(vf)
						for slot in 0 ..< cap_map {
							if !runtime.map_hash_is_valid(hs[slot]) {
								continue
							}
							kptr := runtime.map_cell_index_dynamic(ks, info.ks, uintptr(slot))
							vptr := runtime.map_cell_index_dynamic(vs, info.vs, uintptr(slot))
							me := Cbor_Map_Entry{rec = val_rec, val = vptr}
							if !cbor_fill_sorted_map_key(plan, mm, kptr, &me, KEY_ORDER) {
								sync_cursor(w, buf, p)
								return .No_Spelling, nil
							}
							if _, aerr := append(&map_entries, me); aerr != nil {
								sync_cursor(w, buf, p)
								return .None, aerr
							}
						}
						entries := map_entries[old_len:]
						sort_cbor_entries(entries, KEY_ORDER)
						when KEY_ORDER >= .Written {
							for j in 1 ..< len(entries) {
								if cbor_key_equal(entries[j - 1], entries[j]) {
									sync_cursor(w, buf, p)
									return .No_Spelling, nil
								}
							}
						}
						if !cbor_push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
							sync_cursor(w, buf, p)
							return .None, err
						}
						p = p[cbor_put_head(p, 5, u64(len(entries))):]
						cur = Cbor_Frame{left = len(map_entries), step = old_len, total = old_len, mode = .Map_Sorted}
					} else {
						elem := element_of(vf)
						if mm.key_kind == .String && (elem.kind == .I64 || elem.kind == .String) {
							ok: bool
							buf, p, limit, ok = cbor_put_flat_string_map(mm.map_info, raw, mlen, elem.kind == .I64, w, buf, p, limit, CBOR_SLOP, INDEFINITE, grow, has_err, put_string_sync)
							if !ok {
								return .No_Spelling, nil
							}
							if has_err(w) {
								sync_cursor(w, buf, p)
								return .None, nil
							}
						} else {
							if !cbor_push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
								sync_cursor(w, buf, p)
								return .None, err
							}
							when INDEFINITE {
								p[0] = 0xBF
								p = p[1:]
							} else {
								p = p[cbor_put_head(p, 5, u64(mlen)):]
							}
							cur = Cbor_Frame{r = vf, at = va, left = runtime.map_cap(raw), step = 0, mode = .Map}
						}
					}
				}
			case .Maybe:
				m := &plan.meta[vf.meta]
				if m.tag_size == 0 && (^uintptr)(va)^ == 0 || m.tag_size != 0 && load_size(va + uintptr(m.tag), int(m.tag_size)) == 0 {
					p[0] = 0xF6
					p = p[1:]
				} else {
					vf = element_of(vf)
					continue value
				}
			case .Ptr:
				to := (^uintptr)(va)^
				if to == 0 {
					p[0] = 0xF6
					p = p[1:]
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
					p[0] = 0xF6
					p = p[1:]
				} else {
					vf = &plan.records[arm.first - 1]
					continue value
				}
			case .Bit_Set:
				if top >= tape.DEFAULT_DEPTH {
					sync_cursor(w, buf, p)
					return .Malformed, nil
				}
				mm := &plan.meta[vf.meta]
				bit_limit := min(int(mm.count), int(mm.size) * 8)
				when !INDEFINITE {
					cnt := u64(0)
					for b := 0; b < bit_limit; b += 1 {
						if ((^u8)(va + uintptr(b >> 3))^ >> uint(b & 7)) & 1 != 0 {
							cnt += 1
						}
					}
					p = p[cbor_put_head(p, 4, cnt):]
					if cnt == 0 {
						continue next
					}
				} else {
					p[0] = 0x9F
					p = p[1:]
				}
				if !cbor_push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
					sync_cursor(w, buf, p)
					return .None, err
				}
				cur = Cbor_Frame{r = vf, at = va, left = bit_limit, step = 0, mode = .Bits}
			case:
				rref: Marshal_Refusal
				rerr: tape.Error
				buf, p, limit, rref, rerr = cbor_put_rare_scalar(plan, vf, va, w, buf, p, limit, CBOR_SLOP, put_string_sync)
				if rerr != nil || rref != .None {
					sync_cursor(w, buf, p)
					return rref, rerr
				}
			}
			continue next
		}
	}
}

@(private)
cbor_push_frame :: #force_inline proc(frames: ^[^]Cbor_Frame, top, cap_frames: ^int, frame: Cbor_Frame, allocator: runtime.Allocator, err: ^tape.Error) -> bool #no_bounds_check {
	if top^ == cap_frames^ && !cbor_grow_frames(frames, cap_frames, allocator, err) {
		return false
	}
	frames^[top^] = frame
	top^ += 1
	return true
}

@(private, cold)
cbor_grow_frames :: #force_no_inline proc(frames: ^[^]Cbor_Frame, cap_frames: ^int, allocator: runtime.Allocator, err: ^tape.Error) -> bool {
	next_cap := cap_frames^ * 2
	raw, aerr := runtime.mem_alloc_non_zeroed(next_cap * size_of(Cbor_Frame), align_of(Cbor_Frame), allocator)
	if aerr != nil || raw_data(raw) == nil {
		err^ = aerr if aerr != nil else runtime.Allocator_Error.Out_Of_Memory
		return false
	}
	grown := ([^]Cbor_Frame)(raw_data(raw))
	intrinsics.mem_copy_non_overlapping(grown, frames^, cap_frames^ * size_of(Cbor_Frame))
	if cap_frames^ > INLINE_FRAMES {
		runtime.mem_free_with_size(frames^, cap_frames^ * size_of(Cbor_Frame), allocator)
	}
	frames^, cap_frames^ = grown, next_cap
	return true
}

@(private, cold)
cbor_fill_sorted_map_key :: proc(plan: ^Plan, m: ^Meta, key: uintptr, me: ^Cbor_Map_Entry, order: Cbor_Key_Order) -> bool #no_bounds_check {
	size := int(m.map_info.ks.size_of_type)
	set_text_key :: proc(me: ^Cbor_Map_Entry, s: string) -> bool #no_bounds_check {
		if !kernel.utf8_valid(transmute([]u8)s) {
			return false
		}
		me.is_text = true
		me.head_len = u8(cbor_put_head(&me.head[0], 3, u64(len(s))))
		me.text = s
		return true
	}
	#partial switch m.key_kind {
	case .String:
		return set_text_key(me, (^string)(key)^)
	case .Enum:
		ev_raw := load_size(key, size)
		signed := m.enum_info != nil && is_signed(m.enum_info.base)
		sv := sign_extend(ev_raw, size) if signed else i64(ev_raw)
		if plan.options.enums == .Name && m.enum_info != nil {
			for ev, idx in m.enum_info.values {
				if i64(ev) == sv {
					return set_text_key(me, m.enum_info.names[idx])
				}
			}
		}
		hl := cbor_put_i64(&me.head[0], sv) if signed else cbor_put_head(&me.head[0], 0, ev_raw)
		me.head_len = u8(hl)
		if order == .Text {
			me.dec_len = u8(put_i64(&me.dec_buf[0], sv) if signed else put_u64(&me.dec_buf[0], ev_raw))
		}
		return true
	case .I8, .I16, .I32, .I64:
		sv := sign_extend(load_size(key, size), size)
		me.head_len = u8(cbor_put_i64(&me.head[0], sv))
		if order == .Text {
			me.dec_len = u8(put_i64(&me.dec_buf[0], sv))
		}
		return true
	}
	uval := load_size(key, size)
	me.head_len = u8(cbor_put_head(&me.head[0], 0, uval))
	if order == .Text {
		me.dec_len = u8(put_u64(&me.dec_buf[0], uval))
	}
	return true
}

@(private, cold)
cbor_put_non_string_key :: proc(
	plan: ^Plan,
	m: ^Meta,
	key: uintptr,
	w: ^$W,
	buf, p, limit: [^]u8,
	slop: int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> (new_buf, new_p, new_limit: [^]u8, ok: bool),
) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	size := int(m.map_info.ks.size_of_type)
	#partial switch m.key_kind {
	case .Enum:
		ev_raw := load_size(key, size)
		signed := m.enum_info != nil && is_signed(m.enum_info.base)
		sv := sign_extend(ev_raw, size) if signed else i64(ev_raw)
		if plan.options.enums == .Name && m.enum_info != nil {
			for ev, idx in m.enum_info.values {
				if i64(ev) == sv {
					name := m.enum_info.names[idx]
					wrote := cbor_put_text_inline(p, name)
					if wrote > 0 {
						return buf, p[wrote:], limit, true
					}
					return put_string_sync(w, buf, p, name, slop)
				}
			}
		}
		n := cbor_put_i64(p, sv) if signed else cbor_put_head(p, 0, ev_raw)
		return buf, p[n:], limit, true
	case .I8, .I16, .I32, .I64:
		n := cbor_put_i64(p, sign_extend(load_size(key, size), size))
		return buf, p[n:], limit, true
	}
	n := cbor_put_head(p, 0, load_size(key, size))
	return buf, p[n:], limit, true
}

@(private, cold)
cbor_put_enum_scalar :: proc(
	plan: ^Plan,
	m: ^Meta,
	value: i64,
	w: ^$W,
	buf, p, limit: [^]u8,
	slop: int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> (new_buf, new_p, new_limit: [^]u8, ok: bool),
) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	if plan.options.enums == .Name && m.enum_info != nil {
		for ev, idx in m.enum_info.values {
			if i64(ev) == value {
				name := m.enum_info.names[idx]
				wrote := cbor_put_text_inline(p, name)
				if wrote > 0 {
					return buf, p[wrote:], limit, true
				}
				return put_string_sync(w, buf, p, name, slop)
			}
		}
	}
	n := cbor_put_i64(p, value) if m.signed else cbor_put_head(p, 0, u64(value))
	return buf, p[n:], limit, true
}

@(private)
cbor_put_flat_string_map :: #force_no_inline proc(
	info: ^runtime.Map_Info,
	raw: runtime.Raw_Map,
	mlen: int,
	is_i64: bool,
	w: ^$W,
	buf0, p0, limit0: [^]u8,
	slop: int,
	$INDEFINITE: bool,
	$grow: proc(w: ^W, buf, p: [^]u8, need, slop: int) -> (new_buf, new_p, new_limit: [^]u8),
	$has_err: proc "contextless" (w: ^W) -> bool,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> (new_buf, new_p, new_limit: [^]u8, ok: bool),
) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	cap_map := runtime.map_cap(raw)
	ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw, info)
	keys_arr := ([^]string)(ks)
	vals_i64 := ([^]i64)(vs)
	vals_str := ([^]string)(vs)
	buf, p, limit := buf0, p0, limit0
	when INDEFINITE {
		p[0] = 0xBF
		p = p[1:]
	} else {
		p = p[cbor_put_head(p, 5, u64(mlen)):]
	}
	for i in 0 ..< cap_map {
		if !runtime.map_hash_is_valid(hs[i]) {
			continue
		}
		if uintptr(p) > uintptr(limit) {
			buf, p, limit = grow(w, buf, p, slop, slop)
			if has_err(w) {
				return buf, p, limit, true
			}
		}
		key := keys_arr[i]
		wrote := cbor_put_text_inline(p, key)
		if wrote > 0 {
			p = p[wrote:]
		} else {
			ok: bool
			buf, p, limit, ok = put_string_sync(w, buf, p, key, slop)
			if !ok {
				return buf, p, limit, false
			}
			if uintptr(p) > uintptr(limit) {
				buf, p, limit = grow(w, buf, p, slop, slop)
			}
		}
		if is_i64 {
			p = p[cbor_put_i64(p, vals_i64[i]):]
		} else {
			vstr := vals_str[i]
			vwrote := cbor_put_text_inline(p, vstr)
			if vwrote > 0 {
				p = p[vwrote:]
			} else {
				ok: bool
				buf, p, limit, ok = put_string_sync(w, buf, p, vstr, slop)
				if !ok {
					return buf, p, limit, false
				}
			}
		}
	}
	when INDEFINITE {
		if uintptr(p) > uintptr(limit) {
			buf, p, limit = grow(w, buf, p, slop, slop)
		}
		p[0] = 0xFF
		p = p[1:]
	}
	return buf, p, limit, true
}

@(private, cold)
cbor_put_rare_scalar :: #force_no_inline proc(
	plan: ^Plan,
	vf: ^Record,
	va: uintptr,
	w: ^$W,
	buf, p, limit: [^]u8,
	slop: int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> (new_buf, new_p, new_limit: [^]u8, ok: bool),
) -> ([^]u8, [^]u8, [^]u8, Marshal_Refusal, tape.Error) #no_bounds_check {
	p := p
	#partial switch vf.kind {
	case .I32:
		p = p[cbor_put_i64(p, i64((^i32)(va)^)):]
	case .I16:
		p = p[cbor_put_i64(p, i64((^i16)(va)^)):]
	case .I8:
		p = p[cbor_put_i64(p, i64((^i8)(va)^)):]
	case .U64:
		p = p[cbor_put_head(p, 0, (^u64)(va)^):]
	case .U32:
		p = p[cbor_put_head(p, 0, u64((^u32)(va)^)):]
	case .U16:
		p = p[cbor_put_head(p, 0, u64((^u16)(va)^)):]
	case .U8:
		p = p[cbor_put_head(p, 0, u64((^u8)(va)^)):]
	case .F32:
		p = p[cbor_put_f32(p, (^f32)(va)^):]
	case .Bool_Wide:
		p[0] = 0xF5 if load_size(va, int(plan.meta[vf.meta].size)) != 0 else 0xF4
		p = p[1:]
	case .Enum:
		m := &plan.meta[vf.meta]
		signed := m.enum_info != nil && is_signed(m.enum_info.base)
		raw := load_size(va, int(m.size))
		v := sign_extend(raw, int(m.size)) if signed else i64(raw)
		em := Meta{enum_info = m.enum_info, signed = signed}
		nbuf, np, nlimit, ok := cbor_put_enum_scalar(plan, &em, v, w, buf, p, limit, slop, put_string_sync)
		if !ok {
			return nbuf, np, nlimit, .No_Spelling, nil
		}
		return nbuf, np, nlimit, .None, nil
	case .Time:
		tbuf: [SCALAR_ROOM]u8 = ---
		text, ok := rfc3339_text((^time.Time)(va)^, &tbuf)
		if !ok {
			return buf, p, limit, .None, tape.Bad_Option{"time"}
		}
		p[0] = 0xC0 // CBOR tag 0 for RFC 3339 date-time string.
		hl := cbor_put_head(p[1:], 3, u64(len(text)))
		intrinsics.mem_copy_non_overlapping(p[1 + hl:], raw_data(text), len(text))
		p = p[1 + hl + len(text):]
	case:
		return buf, p, limit, .None, tape.Bad_Option{"raw"}
	}
	return buf, p, limit, .None, nil
}

// ============================================================================
// Generic token-callback marshaler (`toml`, `xml`, `dsv`, etc.)
// ============================================================================

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
spell_enum_value :: proc(plan: ^Plan, m: ^Meta, value: i64, buf: ^[SCALAR_ROOM]u8) -> (text: string, named: bool) #no_bounds_check {
	if plan.options.enums == .Name && m.enum_info != nil {
		for v, i in m.enum_info.values {
			if i64(v) == value {
				return m.enum_info.names[i], true
			}
		}
	}
	if m.signed {
		return string(buf[:put_i64(&buf[0], value)]), false
	}
	return string(buf[:put_u64(&buf[0], u64(value))]), false
}

// The text of the map key at `key`, of a map record `rec`: a string, an integer or an enum's name.
@(private)
key_text :: proc(plan: ^Plan, rec: ^Record, key: uintptr, buf: ^[SCALAR_ROOM]u8) -> string #no_bounds_check {
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
		sz := int(m.map_info.ks.size_of_type)
		return string(buf[:put_i64(&buf[0], sign_extend(load_size(key, sz), sz))])
	}
	return string(buf[:put_u64(&buf[0], load_size(key, int(m.map_info.ks.size_of_type)))])
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
scalar_of :: proc(plan: ^Plan, rec: ^Record, at: uintptr, buf: ^[SCALAR_ROOM]u8) -> (s: Scalar, err: tape.Error) #no_bounds_check {
	m := &plan.meta[rec.meta]
	#partial switch rec.kind {
	case .String:
		return {.String, (^string)(at)^}, nil
	case .Bool:
		return {.True if (^bool)(at)^ else .False, ""}, nil
	case .Bool_Wide:
		return {.True if load_size(at, int(m.size)) != 0 else .False, ""}, nil
	case .I8, .I16, .I32, .I64:
		return {.Number, string(buf[:put_i64(&buf[0], sign_extend(load_size(at, int(m.size)), int(m.size)))])}, nil
	case .U8, .U16, .U32, .U64:
		return {.Number, string(buf[:put_u64(&buf[0], load_size(at, int(m.size)))])}, nil
	case .F32:
		return {.Number, float_text(buf, f64((^f32)(at)^), 32)}, nil
	case .F64:
		return {.Number, float_text(buf, (^f64)(at)^, 64)}, nil
	case .Enum:
		signed := m.enum_info != nil && is_signed(m.enum_info.base)
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
	if math.is_nan(f) {
		return "NaN"
	}
	if math.is_inf(f, 0) {
		return "-Inf" if f < 0 else "Inf"
	}
	n := put_f32_finite(&buf[0], f32(f)) if bits == 32 else put_f64_finite(&buf[0], f)
	return string(buf[:n])
}
