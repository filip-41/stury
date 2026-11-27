package typed

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// Unified direct marshaler specialized at compile time (`$CBOR`, `$PRETTY`, `$INDEFINITE`, `$KEY_ORDER`) for both
// JSON (`marshal_json`) and CBOR (`marshal_cbor`). Keeps `buf, p, limit` in SSA registers, bypasses token sequence
// checks and per-field cursor traffic, and shares container traversal, primitive list loops, flat string map loops,
// and cold scalar/enum/map-key dispatch across both formats with zero runtime branching on format.

@(private = "file")
Direct_Frame_Mode :: enum u8 {
	Root,
	Struct,
	List,
	Map,
	Bits,
	Sorted,
}

@(private = "file")
Direct_Frame :: struct {
	r:        ^Record,
	at:       uintptr,
	left:     int,
	step:     int,
	total:    int,
	aux:      u32, // JSON: lead char/flag; CBOR: end_meta index
	has_omit: bool,
	mode:     Direct_Frame_Mode,
}
when size_of(uintptr) == 8 {
	#assert(size_of(Direct_Frame) == 48)
}

@(private = "file")
JSON_NULL_U32 :: u32le('n') | u32le('u') << 8 | u32le('l') << 16 | u32le('l') << 24
@(private = "file")
JSON_TRUE_U32 :: u32le('t') | u32le('r') << 8 | u32le('u') << 16 | u32le('e') << 24
@(private = "file")
JSON_FALSE_U64 :: u64le('f') | u64le('a') << 8 | u64le('l') << 16 | u64le('s') << 24 | u64le('e') << 32

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
) -> (refusal: Marshal_Refusal, err: tape.Error) {
	ORDER :: Cbor_Key_Order.Text when SORT_KEYS else Cbor_Key_Order.None
	return marshal_direct(
		value, T, tag_key, plan, w,
		false, PRETTY, false, ORDER,
		buf_state, sync_cursor, grow, has_err,
		put_string_inline, put_string_sync, put_line,
		allocator,
	)
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
) -> (refusal: Marshal_Refusal, err: tape.Error) {
	noop_line :: #force_inline proc(w: ^W, buf, p, limit: [^]u8, depth, after, slop: int) -> ([^]u8, [^]u8, [^]u8) {
		return buf, p, limit
	}
	return marshal_direct(
		value, T, tag_key, plan, w,
		true, false, INDEFINITE, KEY_ORDER,
		buf_state, sync_cursor, grow, has_err,
		cbor_put_text_inline, put_string_sync, noop_line,
		allocator,
	)
}

@(private = "file")
direct_put_bool :: #force_inline proc "contextless" (p: [^]u8, b: bool, $CBOR: bool) -> [^]u8 #no_bounds_check {
	when CBOR {
		p[0] = 0xF5 if b else 0xF4
		return p[1:]
	} else {
		if b {
			intrinsics.unaligned_store((^u32le)(p), JSON_TRUE_U32)
			return p[4:]
		}
		intrinsics.unaligned_store((^u64le)(p), JSON_FALSE_U64)
		return p[5:]
	}
}

@(private = "file")
direct_close_obj :: #force_inline proc(
	w: ^$W, buf, p, limit: [^]u8, lead: u32, depth, slop: int, $CBOR, $PRETTY, $INDEFINITE: bool,
	$grow: proc(w: ^W, buf, p: [^]u8, need, slop: int) -> ([^]u8, [^]u8, [^]u8),
	$put_line: proc(w: ^W, buf, p, limit: [^]u8, depth, after, slop: int) -> ([^]u8, [^]u8, [^]u8),
) -> ([^]u8, [^]u8, [^]u8) #no_bounds_check {
	buf, p, limit := buf, p, limit
	when CBOR {
		when INDEFINITE {
			if uintptr(p) > uintptr(limit) {
				buf, p, limit = grow(w, buf, p, slop, slop)
			}
			p[0] = 0xFF
			p = p[1:]
		}
		return buf, p, limit
	} else {
		if uintptr(p) > uintptr(limit) {
			buf, p, limit = grow(w, buf, p, slop, slop)
		}
		if lead == '{' {
			p[0], p[1] = '{', '}'
			return buf, p[2:], limit
		}
		when PRETTY {
			buf, p, limit = put_line(w, buf, p, limit, depth, 2, slop)
		}
		p[0] = '}'
		return buf, p[1:], limit
	}
}

@(private = "file")
direct_close_seq :: #force_inline proc(
	w: ^$W, buf, p, limit: [^]u8, indent: bool, depth, slop: int, $CBOR, $PRETTY, $INDEFINITE: bool,
	$grow: proc(w: ^W, buf, p: [^]u8, need, slop: int) -> ([^]u8, [^]u8, [^]u8),
	$put_line: proc(w: ^W, buf, p, limit: [^]u8, depth, after, slop: int) -> ([^]u8, [^]u8, [^]u8),
) -> ([^]u8, [^]u8, [^]u8) #no_bounds_check {
	buf, p, limit := buf, p, limit
	when !CBOR || INDEFINITE {
		if uintptr(p) > uintptr(limit) {
			buf, p, limit = grow(w, buf, p, slop, slop)
		}
		when CBOR {
			p[0] = 0xFF
		} else {
			when PRETTY {
				if indent {
					buf, p, limit = put_line(w, buf, p, limit, depth, 2, slop)
				}
			}
			p[0] = ']'
		}
		p = p[1:]
	}
	return buf, p, limit
}

@(private = "file")
direct_put_str :: #force_inline proc(
	w: ^$W, buf, p, limit: [^]u8, s: string, slop: int, $ENSURE_ROOM: bool,
	$put_string_inline: proc "contextless" (p: [^]u8, s: string) -> int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> ([^]u8, [^]u8, [^]u8, bool),
	$grow: proc(w: ^W, buf, p: [^]u8, need, slop: int) -> ([^]u8, [^]u8, [^]u8),
) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	if wrote := put_string_inline(p, s); wrote > 0 {
		return buf, p[wrote:], limit, true
	}
	nbuf, np, nlimit, ok := put_string_sync(w, buf, p, s, slop)
	if !ok {
		return nbuf, np, nlimit, false
	}
	when ENSURE_ROOM {
		if uintptr(np) > uintptr(nlimit) {
			nbuf, np, nlimit = grow(w, nbuf, np, slop, slop)
		}
	}
	return nbuf, np, nlimit, true
}

@(private = "file")
json_put_lead :: #force_inline proc(
	w: ^$W, buf, p, limit: [^]u8, lead: ^u32, depth, after, slop: int, $PRETTY: bool,
	$put_line: proc(w: ^W, buf, p, limit: [^]u8, depth, after, slop: int) -> ([^]u8, [^]u8, [^]u8),
) -> ([^]u8, [^]u8, [^]u8) #no_bounds_check {
	p[0] = u8(lead^)
	lead^ = ','
	when PRETTY {
		return put_line(w, buf, p[1:], limit, depth, after, slop)
	} else {
		return buf, p[1:], limit
	}
}

@(private = "file")
json_put_colon :: #force_inline proc "contextless" (p: [^]u8, $PRETTY: bool) -> [^]u8 #no_bounds_check {
	when PRETTY {
		p[0], p[1] = ':', ' '
		return p[2:]
	} else {
		p[0] = ':'
		return p[1:]
	}
}

@(private = "file")
direct_put_prim_list :: #force_inline proc(
	$T: typeid, data: uintptr, n: int, stride: uintptr, depth: int,
	w: ^$W, buf, p, limit: [^]u8, slop: int, $CBOR, $PRETTY, $INDEFINITE: bool,
	$grow: proc(w: ^W, buf, p: [^]u8, need, slop: int) -> ([^]u8, [^]u8, [^]u8),
	$has_err: proc "contextless" (w: ^W) -> bool,
	$put_line: proc(w: ^W, buf, p, limit: [^]u8, depth, after, slop: int) -> ([^]u8, [^]u8, [^]u8),
) -> ([^]u8, [^]u8, [^]u8, Marshal_Refusal) #no_bounds_check {
	buf, p, limit := buf, p, limit
	when CBOR {
		p = cbor_put_open(p, 4, u64(n), INDEFINITE)
	} else {
		p[0] = '['
		p = p[1:]
	}
	ea := data
	for _ in 0 ..< n {
		if uintptr(p) > uintptr(limit) {
			buf, p, limit = grow(w, buf, p, slop, slop)
			if has_err(w) {
				return buf, p, limit, .None
			}
		}
		when !CBOR {
			if ea != data {
				p[0] = ','
				p = p[1:]
			}
			when PRETTY {
				buf, p, limit = put_line(w, buf, p, limit, depth + 1, JSON_LEAF_ROOM, slop)
			}
		}
		when T == f64 {
			when CBOR {
				p = p[cbor_put_f64(p, (^f64)(ea)^):]
			} else {
				fn, fok := spell.put_f64(p, (^f64)(ea)^)
				if !fok {
					return buf, p, limit, .No_Spelling
				}
				p = p[fn:]
			}
		} else {
			when CBOR {
				p = p[cbor_put_i64(p, (^i64)(ea)^):]
			} else {
				p = p[spell.put_i64(p, (^i64)(ea)^):]
			}
		}
		ea += stride
	}
	buf, p, limit = direct_close_seq(w, buf, p, limit, true, depth, slop, CBOR, PRETTY, INDEFINITE, grow, put_line)
	return buf, p, limit, .None
}

@(private = "file")
marshal_direct :: proc(
	value: rawptr,
	T: typeid,
	tag_key: string,
	plan: ^Plan,
	w: ^$W,
	$CBOR: bool,
	$PRETTY: bool,
	$INDEFINITE: bool,
	$KEY_ORDER: Cbor_Key_Order,
	$buf_state: proc "contextless" (w: ^W, slop: int) -> (buf, p, limit: [^]u8),
	$sync_cursor: proc "contextless" (w: ^W, buf, p: [^]u8),
	$grow: proc(w: ^W, buf, p: [^]u8, need, slop: int) -> (new_buf, new_p, new_limit: [^]u8),
	$has_err: proc "contextless" (w: ^W) -> bool,
	$put_string_inline: proc "contextless" (p: [^]u8, s: string) -> int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> (new_buf, new_p, new_limit: [^]u8, ok: bool),
	$put_line: proc(w: ^W, buf, p, limit: [^]u8, depth, after, slop: int) -> (new_buf, new_p, new_limit: [^]u8),
	allocator: runtime.Allocator,
) -> (refusal: Marshal_Refusal, err: tape.Error) #no_bounds_check {
	SORT_KEYS :: KEY_ORDER != .None
	SLOP :: CBOR_SLOP when CBOR else (JSON_PRETTY_SLOP when PRETTY else JSON_COMPACT_SLOP)
	made: Plan
	plan := plan
	if plan, err = resolve_marshal_plan(value, T, tag_key, plan, &made, allocator); err != nil {
		return .None, err
	}
	defer if plan == &made {
		plan_destroy(&made)
	}
	when CBOR {
		prep: Cbor_Prep
		if perr := cbor_prep_init(&prep, plan, KEY_ORDER, allocator); perr != nil {
			cbor_prep_destroy(&prep)
			return .None, perr
		}
		defer cbor_prep_destroy(&prep)
	} else {
		keys := raw_data(plan.strings)
	}
	inline_frames: [INLINE_FRAMES]Direct_Frame = ---
	frames := raw_data(inline_frames[:])
	top, cap_frames := 0, INLINE_FRAMES
	defer if cap_frames > INLINE_FRAMES {
		runtime.mem_free_with_size(frames, cap_frames * size_of(Direct_Frame), allocator)
	}
	when SORT_KEYS {
		sorted_entries: [dynamic]Cbor_Map_Entry
		sorted_entries.allocator = allocator
		defer delete(sorted_entries)
	}
	buf, p, limit := buf_state(w, SLOP)
	cur := Direct_Frame{
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
			member: ^Record
			when CBOR && SORT_KEYS {
				for cur.left > 0 {
					idx := prep.sidx[cur.step]
					cur.step += 1
					cur.left -= 1
					cand := intrinsics.ptr_offset(cur.r, int(idx))
					if cur.has_omit && member_omitted(plan, cand, cur.at + uintptr(cand.offset)) {
						continue
					}
					member = cand
					break
				}
			} else {
				r := cur.r
				when CBOR {
					if cur.has_omit {
						for r.kind != .End && member_omitted(plan, r, cur.at + uintptr(r.offset)) {
							r = intrinsics.ptr_offset(r, 1)
						}
					}
				} else {
					if r.key_size == 0 {
						for r.kind != .End && r.key_size == 0 && member_omitted(plan, r, cur.at + uintptr(r.offset)) {
							r = intrinsics.ptr_offset(r, 1)
						}
					}
				}
				if r.kind != .End {
					member = r
					cur.r = intrinsics.ptr_offset(r, 1)
				}
			}
			if member == nil {
				buf, p, limit = direct_close_obj(w, buf, p, limit, cur.aux, top - 1, SLOP, CBOR, PRETTY, INDEFINITE, grow, put_line)
				// Reuse this struct frame for the next element of a list of structs without pop/push.
				up := &frames[top - 1]
				if up.mode == .List && up.left > 0 && (up.r.kind == .Struct || up.r.kind == .Required) && !has_err(w) {
					up.left -= 1
					when CBOR {
						if uintptr(p) > uintptr(limit) {
							buf, p, limit = grow(w, buf, p, SLOP, SLOP)
						}
						when SORT_KEYS {
							mi := prep.meta[cur.aux]
							cnt := cbor_count_struct_members(plan, up.r.first, up.at) if cur.has_omit else u64(mi.span_n)
							p = p[cbor_put_head(p, 5, cnt):]
							cur.at, cur.step, cur.left = up.at, int(mi.span_lo), int(mi.span_n) if cnt > 0 else 0
						} else when INDEFINITE {
							p = cbor_put_open(p, 5, 0, true)
							cur.r, cur.at = up.r.first, up.at
						} else {
							cnt := cbor_count_struct_members(plan, up.r.first, up.at) if cur.has_omit else u64(plan.meta[up.r.meta].count)
							p = p[cbor_put_head(p, 5, cnt):]
							if cnt > 0 {
								cur.r, cur.at = up.r.first, up.at
							}
						}
					} else {
						p[0] = ','
						p = p[1:]
						when PRETTY {
							buf, p, limit = put_line(w, buf, p, limit, top - 1, SLOP, SLOP)
						}
						cur.r, cur.at, cur.aux = up.r.first, up.at, '{'
					}
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
				buf, p, limit = grow(w, buf, p, SLOP, SLOP)
			}
			when CBOR {
				ref := prep.meta[member.meta]
				if ref.bad_utf8 {
					sync_cursor(w, buf, p)
					return .No_Spelling, nil
				}
				if ref.size > 0 {
					p = p[put_fast_bytes(p, prep.kbuf[ref.off:], int(ref.size)):]
				} else {
					ok: bool
					buf, p, limit, ok = put_string_sync(w, buf, p, plan.meta[member.meta].name, SLOP)
					if !ok {
						return .No_Spelling, nil
					}
					if uintptr(p) > uintptr(limit) {
						buf, p, limit = grow(w, buf, p, SLOP, SLOP)
					}
				}
			} else {
				ks := int(member.key_size)
				if ks != 0 {
					buf, p, limit = json_put_lead(w, buf, p, limit, &cur.aux, top, 256 + 16 + 1 + JSON_LEAF_ROOM, SLOP, PRETTY, put_line)
					p = p[put_fast_bytes(p, keys[uint(member.key_off):], ks):]
					when PRETTY {
						p[0] = ' '
						p = p[1:]
					}
				} else {
					buf, p, limit = json_put_lead(w, buf, p, limit, &cur.aux, top, 64, SLOP, PRETTY, put_line)
					ok: bool
					buf, p, limit, ok = direct_put_str(w, buf, p, limit, plan.meta[member.meta].name, SLOP, true, put_string_inline, put_string_sync, grow)
					if !ok {
						return .No_Spelling, nil
					}
					p = json_put_colon(p, PRETTY)
				}
			}
			vf, va = member, cur.at + uintptr(member.offset)
		case .Sorted:
			when SORT_KEYS {
				if cur.step >= cur.left {
					when !CBOR {
						buf, p, limit = direct_close_obj(w, buf, p, limit, cur.aux, top - 1, SLOP, false, PRETTY, false, grow, put_line)
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
				e := &sorted_entries[cur.step]
				cur.step += 1
				when CBOR {
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
								buf, p, limit = grow(w, buf, p, chunk, SLOP)
								intrinsics.mem_copy_non_overlapping(p, raw_data(e.text)[at:], chunk)
								p = p[chunk:]
							}
							if uintptr(p) > uintptr(limit) {
								buf, p, limit = grow(w, buf, p, SLOP, SLOP)
							}
						}
					}
				} else {
					buf, p, limit = json_put_lead(w, buf, p, limit, &cur.aux, top, 64, SLOP, PRETTY, put_line)
					kstr := e.text if e.is_text else string(e.dec_buf[:e.dec_len])
					ok: bool
					buf, p, limit, ok = direct_put_str(w, buf, p, limit, kstr, SLOP, true, put_string_inline, put_string_sync, grow)
					if !ok {
						return .No_Spelling, nil
					}
					p = json_put_colon(p, PRETTY)
				}
				vf, va = e.rec, e.val
			}
		case .List:
			if cur.left == 0 {
				buf, p, limit = direct_close_seq(w, buf, p, limit, true, top - 1, SLOP, CBOR, PRETTY, INDEFINITE, grow, put_line)
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
			when !CBOR {
				p[0] = ','
				p = p[cur.aux:]
				cur.aux = 1
				when PRETTY {
					buf, p, limit = put_line(w, buf, p, limit, top, JSON_LEAF_ROOM, SLOP)
				}
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
				buf, p, limit = direct_close_obj(w, buf, p, limit, cur.aux, top - 1, SLOP, CBOR, PRETTY, INDEFINITE, grow, put_line)
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
			when !CBOR {
				buf, p, limit = json_put_lead(w, buf, p, limit, &cur.aux, top, 32, SLOP, PRETTY, put_line)
			}
			ok: bool
			if m.key_kind == .String {
				buf, p, limit, ok = direct_put_str(w, buf, p, limit, (^string)(key)^, SLOP, true, put_string_inline, put_string_sync, grow)
			} else {
				buf, p, limit, ok = direct_put_non_string_key(plan, m, key, w, buf, p, limit, SLOP, CBOR, put_string_inline, put_string_sync)
			}
			if !ok {
				return .No_Spelling, nil
			}
			when !CBOR {
				p = json_put_colon(p, PRETTY)
			}
			vf, va = element_of(cur.r), runtime.map_cell_index_dynamic(vs, info.vs, uintptr(i))
		case .Bits:
			i := cur.step
			for i < cur.left && ((^u8)(cur.at + uintptr(i >> 3))^ >> uint(i & 7)) & 1 == 0 {
				i += 1
			}
			if i >= cur.left {
				buf, p, limit = direct_close_seq(w, buf, p, limit, cur.aux != 0, top - 1, SLOP, CBOR, PRETTY, INDEFINITE, grow, put_line)
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
			when !CBOR {
				p[0] = ','
				p = p[cur.aux:]
				cur.aux = 1
				when PRETTY {
					buf, p, limit = put_line(w, buf, p, limit, top, JSON_LEAF_ROOM, SLOP)
				}
			}
			mm := &plan.meta[cur.r.meta]
			elem := element_of(cur.r)
			ok: bool
			buf, p, limit, ok = direct_put_enum_scalar(plan, &plan.meta[elem.meta], mm.lower + i64(i), w, buf, p, limit, SLOP, CBOR, put_string_inline, put_string_sync)
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
				buf, p, limit = grow(w, buf, p, SLOP, SLOP)
			}
			vf, va = cur.r, cur.at
		}

		value: for {
			if vf.kind == .String {
				ok: bool
				buf, p, limit, ok = direct_put_str(w, buf, p, limit, (^string)(va)^, SLOP, false, put_string_inline, put_string_sync, grow)
				if !ok {
					return .No_Spelling, nil
				}
				continue next
			}
			#partial switch vf.kind {
			case .I64:
				when CBOR {
					p = p[cbor_put_i64(p, (^i64)(va)^):]
				} else {
					p = p[spell.put_i64(p, (^i64)(va)^):]
				}
			case .F64:
				when CBOR {
					p = p[cbor_put_f64(p, (^f64)(va)^):]
				} else {
					n, ok := spell.put_f64(p, (^f64)(va)^)
					if !ok {
						sync_cursor(w, buf, p)
						return .No_Spelling, nil
					}
					p = p[n:]
				}
			case .Bool:
				p = direct_put_bool(p, (^bool)(va)^, CBOR)
			case .Struct, .Required:
				if top >= tape.DEFAULT_DEPTH {
					sync_cursor(w, buf, p)
					return .Malformed, nil
				}
				when CBOR {
					scount := int(plan.meta[vf.meta].count)
					end_meta := intrinsics.ptr_offset(vf.first, scount).meta
					mi := prep.meta[end_meta]
					next_frame := Direct_Frame{r = vf.first, at = va, aux = end_meta, has_omit = mi.has_omit, mode = .Struct}
					when INDEFINITE && !SORT_KEYS {
						p = cbor_put_open(p, 5, 0, true)
					} else {
						cnt := cbor_count_struct_members(plan, vf.first, va) if mi.has_omit else u64(mi.span_n if SORT_KEYS else u32(scount))
						p = p[cbor_put_head(p, 5, cnt):]
						if cnt == 0 {
							continue next
						}
						when SORT_KEYS {
							next_frame.step, next_frame.left = int(mi.span_lo), int(mi.span_n)
						}
					}
					if !push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
						sync_cursor(w, buf, p)
						return .None, err
					}
					cur = next_frame
				} else when SORT_KEYS {
					old_len := len(sorted_entries)
					block := ([^]Record)(vf.first)
					for j in 0 ..< int(plan.meta[vf.meta].count) {
						member := &block[j]
						m_at := va + uintptr(member.offset)
						if member_omitted(plan, member, m_at) {
							continue
						}
						if _, aerr := append(&sorted_entries, Cbor_Map_Entry{is_text = true, text = plan.meta[member.meta].name, rec = member, val = m_at}); aerr != nil {
							sync_cursor(w, buf, p)
							return .None, aerr
						}
					}
					if len(sorted_entries) == old_len {
						p[0], p[1] = '{', '}'
						p = p[2:]
					} else {
						if !push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
							sync_cursor(w, buf, p)
							return .None, err
						}
						sort_cbor_entries(sorted_entries[old_len:], .Text)
						cur = Direct_Frame{left = len(sorted_entries), step = old_len, total = old_len, aux = '{', mode = .Sorted}
					}
				} else {
					if !push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
						sync_cursor(w, buf, p)
						return .None, err
					}
					cur = Direct_Frame{r = vf.first, at = va, aux = '{', mode = .Struct}
				}
			case .Slice, .Dynamic, .Array:
				if top >= tape.DEFAULT_DEPTH {
					sync_cursor(w, buf, p)
					return .Malformed, nil
				}
				data, n := list_data_len(plan, vf, va)
				if n == 0 {
					when CBOR {
						p = cbor_put_empty(p, 4, INDEFINITE)
					} else {
						p[0], p[1] = '[', ']'
						p = p[2:]
					}
				} else {
					elem := element_of(vf)
					if elem.kind == .F64 || elem.kind == .I64 {
						lref: Marshal_Refusal
						if elem.kind == .F64 {
							buf, p, limit, lref = direct_put_prim_list(f64, data, n, uintptr(elem.stride), top, w, buf, p, limit, SLOP, CBOR, PRETTY, INDEFINITE, grow, has_err, put_line)
						} else {
							buf, p, limit, lref = direct_put_prim_list(i64, data, n, uintptr(elem.stride), top, w, buf, p, limit, SLOP, CBOR, PRETTY, INDEFINITE, grow, has_err, put_line)
						}
						if lref != .None || has_err(w) {
							sync_cursor(w, buf, p)
							return lref, nil
						}
					} else {
						if !push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
							sync_cursor(w, buf, p)
							return .None, err
						}
						when CBOR {
							p = cbor_put_open(p, 4, u64(n), INDEFINITE)
						} else {
							p[0] = '['
							p = p[1:]
						}
						cur = Direct_Frame{r = elem, at = data, left = n, step = int(elem.stride), total = n, aux = 0, mode = .List}
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
					when CBOR {
						p = cbor_put_empty(p, 5, INDEFINITE)
					} else {
						p[0], p[1] = '{', '}'
						p = p[2:]
					}
				} else {
					mm := &plan.meta[vf.meta]
					when SORT_KEYS {
						info := mm.map_info
						ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw, info)
						val_rec := element_of(vf)
						old_len := len(sorted_entries)
						for slot in 0 ..< runtime.map_cap(raw) {
							if !runtime.map_hash_is_valid(hs[slot]) {
								continue
							}
							kptr := runtime.map_cell_index_dynamic(ks, info.ks, uintptr(slot))
							vptr := runtime.map_cell_index_dynamic(vs, info.vs, uintptr(slot))
							me := Cbor_Map_Entry{rec = val_rec, val = vptr}
							if !fill_sorted_map_key(plan, mm, kptr, &me, KEY_ORDER, CBOR) {
								sync_cursor(w, buf, p)
								return .No_Spelling, nil
							}
							if _, aerr := append(&sorted_entries, me); aerr != nil {
								sync_cursor(w, buf, p)
								return .None, aerr
							}
						}
						entries := sorted_entries[old_len:]
						sort_cbor_entries(entries, KEY_ORDER)
						when CBOR && KEY_ORDER >= .Written {
							for j in 1 ..< len(entries) {
								if cbor_key_equal(entries[j - 1], entries[j]) {
									sync_cursor(w, buf, p)
									return .No_Spelling, nil
								}
							}
						}
						if !push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
							sync_cursor(w, buf, p)
							return .None, err
						}
						when CBOR {
							p = p[cbor_put_head(p, 5, u64(len(entries))):]
						}
						cur = Direct_Frame{left = len(sorted_entries), step = old_len, total = old_len, aux = '{', mode = .Sorted}
					} else {
						elem := element_of(vf)
						if mm.key_kind == .String && (elem.kind == .I64 || elem.kind == .String) {
							ok: bool
							buf, p, limit, ok = direct_put_flat_string_map(mm.map_info, raw, mlen, elem.kind == .I64, top + 1, w, buf, p, limit, SLOP, CBOR, PRETTY, INDEFINITE, grow, has_err, put_string_inline, put_string_sync, put_line)
							if !ok {
								return .No_Spelling, nil
							}
							if has_err(w) {
								sync_cursor(w, buf, p)
								return .None, nil
							}
						} else {
							if !push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
								sync_cursor(w, buf, p)
								return .None, err
							}
							when CBOR {
								p = cbor_put_open(p, 5, u64(mlen), INDEFINITE)
							}
							cur = Direct_Frame{r = vf, at = va, left = runtime.map_cap(raw), step = 0, aux = '{', mode = .Map}
						}
					}
				}
			case .Maybe, .Ptr, .Union:
				nrec, nat, is_null := unwrap_wrapper(plan, vf, va)
				if is_null {
					when CBOR {
						p[0] = 0xF6
						p = p[1:]
					} else {
						intrinsics.unaligned_store((^u32le)(p), JSON_NULL_U32)
						p = p[4:]
					}
				} else {
					vf, va = nrec, nat
					continue value
				}
			case .Bit_Set:
				if top >= tape.DEFAULT_DEPTH {
					sync_cursor(w, buf, p)
					return .Malformed, nil
				}
				mm := &plan.meta[vf.meta]
				bit_limit := min(int(mm.count), int(mm.size) * 8)
				when CBOR && !INDEFINITE {
					cnt := u64(0)
					for b in 0 ..< bit_limit {
						if ((^u8)(va + uintptr(b >> 3))^ >> uint(b & 7)) & 1 != 0 {
							cnt += 1
						}
					}
					p = p[cbor_put_head(p, 4, cnt):]
					if cnt == 0 {
						continue next
					}
				}
				if !push_frame(&frames, &top, &cap_frames, cur, allocator, &err) {
					sync_cursor(w, buf, p)
					return .None, err
				}
				when CBOR {
					when INDEFINITE {
						p = cbor_put_open(p, 4, 0, true)
					}
				} else {
					p[0] = '['
					p = p[1:]
				}
				cur = Direct_Frame{r = vf, at = va, left = bit_limit, step = 0, aux = 0, mode = .Bits}
			case:
				rref: Marshal_Refusal
				rerr: tape.Error
				buf, p, limit, rref, rerr = direct_put_rare_scalar(plan, vf, va, w, buf, p, limit, SLOP, CBOR, put_string_inline, put_string_sync)
				if rerr != nil || rref != .None {
					sync_cursor(w, buf, p)
					return rref, rerr
				}
			}
			continue next
		}
	}
}

@(private = "file", cold)
fill_sorted_map_key :: proc(plan: ^Plan, m: ^Meta, key: uintptr, me: ^Cbor_Map_Entry, order: Cbor_Key_Order, cbor: bool) -> bool #no_bounds_check {
	dk := decode_map_key(plan, m, key)
	switch dk.kind {
	case .Text:
		if cbor {
			if !kernel.utf8_valid(transmute([]u8)dk.text) {
				return false
			}
			me.head_len = u8(cbor_put_head(&me.head[0], 3, u64(len(dk.text))))
		}
		me.is_text = true
		me.text = dk.text
	case .Int:
		if cbor {
			me.head_len = u8(cbor_put_i64(&me.head[0], dk.iv))
		}
		if !cbor || order == .Text {
			me.dec_len = u8(spell.put_i64(&me.dec_buf[0], dk.iv))
		}
	case .Uint:
		if cbor {
			me.head_len = u8(cbor_put_head(&me.head[0], 0, dk.uv))
		}
		if !cbor || order == .Text {
			me.dec_len = u8(spell.put_u64(&me.dec_buf[0], dk.uv))
		}
	}
	return true
}

@(private = "file", cold)
direct_put_non_string_key :: proc(
	plan: ^Plan, m: ^Meta, key: uintptr, w: ^$W, buf, p, limit: [^]u8, slop: int, $CBOR: bool,
	$put_string_inline: proc "contextless" (p: [^]u8, s: string) -> int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> ([^]u8, [^]u8, [^]u8, bool),
) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	dk := decode_map_key(plan, m, key)
	if dk.kind == .Text {
		if wrote := put_string_inline(p, dk.text); wrote > 0 {
			return buf, p[wrote:], limit, true
		}
		return put_string_sync(w, buf, p, dk.text, slop)
	}
	when CBOR {
		n := cbor_put_i64(p, dk.iv) if dk.kind == .Int else cbor_put_head(p, 0, dk.uv)
		return buf, p[n:], limit, true
	} else {
		p[0] = '"'
		n := spell.put_i64(p[1:], dk.iv) if dk.kind == .Int else spell.put_u64(p[1:], dk.uv)
		p[1 + n] = '"'
		return buf, p[n + 2:], limit, true
	}
}

@(private = "file", cold)
direct_put_enum_scalar :: proc(
	plan: ^Plan, m: ^Meta, value: i64, w: ^$W, buf, p, limit: [^]u8, slop: int, $CBOR: bool,
	$put_string_inline: proc "contextless" (p: [^]u8, s: string) -> int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> ([^]u8, [^]u8, [^]u8, bool),
) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	if name, ok := enum_lookup_name(plan, m.enum_info, value); ok {
		if wrote := put_string_inline(p, name); wrote > 0 {
			return buf, p[wrote:], limit, true
		}
		return put_string_sync(w, buf, p, name, slop)
	}
	when CBOR {
		n := cbor_put_i64(p, value) if m.signed else cbor_put_head(p, 0, u64(value))
	} else {
		n := spell.put_i64(p, value) if m.signed else spell.put_u64(p, u64(value))
	}
	return buf, p[n:], limit, true
}

// Tight loop for `map[string]i64` and `map[string]string` (computes `ks, vs, hs` once and keeps `buf, p, limit` in registers).
@(private = "file")
direct_put_flat_string_map :: #force_no_inline proc(
	info: ^runtime.Map_Info, raw: runtime.Raw_Map, mlen: int, is_i64: bool, depth: int,
	w: ^$W, buf0, p0, limit0: [^]u8, slop: int, $CBOR, $PRETTY, $INDEFINITE: bool,
	$grow: proc(w: ^W, buf, p: [^]u8, need, slop: int) -> ([^]u8, [^]u8, [^]u8),
	$has_err: proc "contextless" (w: ^W) -> bool,
	$put_string_inline: proc "contextless" (p: [^]u8, s: string) -> int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> ([^]u8, [^]u8, [^]u8, bool),
	$put_line: proc(w: ^W, buf, p, limit: [^]u8, depth, after, slop: int) -> ([^]u8, [^]u8, [^]u8),
) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw, info)
	keys_arr := ([^]string)(ks)
	vals_i64 := ([^]i64)(vs)
	vals_str := ([^]string)(vs)
	buf, p, limit := buf0, p0, limit0
	lead := u32('{')
	when CBOR {
		p = cbor_put_open(p, 5, u64(mlen), INDEFINITE)
	}
	for i in 0 ..< runtime.map_cap(raw) {
		if !runtime.map_hash_is_valid(hs[i]) {
			continue
		}
		if uintptr(p) > uintptr(limit) {
			buf, p, limit = grow(w, buf, p, slop, slop)
			if has_err(w) {
				return buf, p, limit, true
			}
		}
		when !CBOR {
			buf, p, limit = json_put_lead(w, buf, p, limit, &lead, depth, 64, slop, PRETTY, put_line)
		}
		ok: bool
		buf, p, limit, ok = direct_put_str(w, buf, p, limit, keys_arr[i], slop, true, put_string_inline, put_string_sync, grow)
		if !ok {
			return buf, p, limit, false
		}
		when !CBOR {
			p = json_put_colon(p, PRETTY)
		}
		if is_i64 {
			when CBOR {
				p = p[cbor_put_i64(p, vals_i64[i]):]
			} else {
				p = p[spell.put_i64(p, vals_i64[i]):]
			}
		} else {
			buf, p, limit, ok = direct_put_str(w, buf, p, limit, vals_str[i], slop, false, put_string_inline, put_string_sync, grow)
			if !ok {
				return buf, p, limit, false
			}
		}
	}
	buf, p, limit = direct_close_obj(w, buf, p, limit, lead, depth - 1, slop, CBOR, PRETTY, INDEFINITE, grow, put_line)
	return buf, p, limit, true
}

@(private = "file", cold)
direct_put_rare_scalar :: #force_no_inline proc(
	plan: ^Plan, vf: ^Record, va: uintptr, w: ^$W, buf, p, limit: [^]u8, slop: int, $CBOR: bool,
	$put_string_inline: proc "contextless" (p: [^]u8, s: string) -> int,
	$put_string_sync: proc(w: ^W, buf, p: [^]u8, s: string, slop: int) -> ([^]u8, [^]u8, [^]u8, bool),
) -> ([^]u8, [^]u8, [^]u8, Marshal_Refusal, tape.Error) #no_bounds_check {
	p := p
	m := &plan.meta[vf.meta]
	#partial switch vf.kind {
	case .I8, .I16, .I32:
		sz := int(m.size)
		sv := sign_extend(read_size(va, sz), sz)
		when CBOR {
			p = p[cbor_put_i64(p, sv):]
		} else {
			p = p[spell.put_i64(p, sv):]
		}
	case .U8, .U16, .U32, .U64:
		uv := read_size(va, int(m.size))
		when CBOR {
			p = p[cbor_put_head(p, 0, uv):]
		} else {
			p = p[spell.put_u64(p, uv):]
		}
	case .F32:
		when CBOR {
			p = p[cbor_put_f32(p, (^f32)(va)^):]
		} else {
			n, ok := spell.put_f32(p, (^f32)(va)^)
			if !ok {
				return buf, p, limit, .No_Spelling, nil
			}
			p = p[n:]
		}
	case .Bool_Wide:
		p = direct_put_bool(p, read_size(va, int(m.size)) != 0, CBOR)
	case .Enum:
		signed := m.enum_info != nil && is_signed(m.enum_info.base)
		raw := read_size(va, int(m.size))
		v := sign_extend(raw, int(m.size)) if signed else i64(raw)
		em := Meta{enum_info = m.enum_info, signed = signed}
		nbuf, np, nlimit, ok := direct_put_enum_scalar(plan, &em, v, w, buf, p, limit, slop, CBOR, put_string_inline, put_string_sync)
		return nbuf, np, nlimit, .None if ok else .No_Spelling, nil
	case .Time:
		tbuf: [SCALAR_ROOM]u8 = ---
		text, ok := rfc3339_at(va, &tbuf)
		if !ok {
			return buf, p, limit, .None, tape.Bad_Option{"time"}
		}
		when CBOR {
			p[0] = 0xC0 // CBOR tag 0 for RFC 3339 date-time string.
			hl := cbor_put_head(p[1:], 3, u64(len(text)))
			intrinsics.mem_copy_non_overlapping(p[1 + hl:], raw_data(text), len(text))
			p = p[1 + hl + len(text):]
		} else {
			p[0] = '"'
			intrinsics.mem_copy_non_overlapping(p[1:], raw_data(text), len(text))
			p[1 + len(text)] = '"'
			p = p[len(text) + 2:]
		}
	case:
		return buf, p, limit, .None, tape.Bad_Option{"raw"}
	}
	return buf, p, limit, .None, nil
}
