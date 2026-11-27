package typed

import "base:intrinsics"
import "base:runtime"
import "core:simd"
import "core:slice"
import "stury:lib/base/kernel"

// CBOR low-level wire encoders, struct key precomputation, and deterministic map-key sorting helpers
// used by `marshal_direct` when `$CBOR == true`.

@(private = "file")
CBOR_V :: #simd[16]u8
@(private = "file")
CBOR_INLINE_META :: 128
@(private = "file")
CBOR_INLINE_KEY_BYTES :: 2048

@(private)
Cbor_Meta_Info :: struct {
	off:      u32,
	span_lo:  u32,
	span_n:   u32,
	size:     u16,
	seen:     bool,
	has_omit: bool,
	bad_utf8: bool,
}

@(private)
Cbor_Prep :: struct {
	inline_meta: [CBOR_INLINE_META]Cbor_Meta_Info,
	inline_kbuf: [CBOR_INLINE_KEY_BYTES]u8,
	inline_sidx: [CBOR_INLINE_META]u32,
	meta:        []Cbor_Meta_Info,
	kbuf:        [^]u8,
	sidx:        []u32,
	kbuf_dyn:    [dynamic]u8,
	sidx_dyn:    [dynamic]u32,
	allocator:   runtime.Allocator,
	meta_heap:   bool,
	kbuf_heap:   bool,
	sidx_heap:   bool,
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

@(private)
cbor_put_open :: #force_inline proc "contextless" (p: [^]u8, major: u8, n: u64, $INDEFINITE: bool) -> [^]u8 #no_bounds_check {
	when INDEFINITE {
		p[0] = (major << 5) | 31
		return p[1:]
	} else {
		return p[cbor_put_head(p, major, n):]
	}
}

@(private)
cbor_put_empty :: #force_inline proc "contextless" (p: [^]u8, major: u8, $INDEFINITE: bool) -> [^]u8 #no_bounds_check {
	when INDEFINITE {
		p[0], p[1] = (major << 5) | 31, 0xFF
		return p[2:]
	} else {
		p[0] = major << 5
		return p[1:]
	}
}

@(private)
cbor_put_i64 :: #force_inline proc "contextless" (p: [^]u8, v: i64) -> int #no_bounds_check {
	return cbor_put_head(p, 0, u64(v)) if v >= 0 else cbor_put_head(p, 1, ~u64(v))
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
	return cbor_put_f32(p, s)
}

@(private = "file")
cbor_short_block :: #force_inline proc "contextless" (src: [^]u8, n: int) -> CBOR_V #no_bounds_check {
	low, high := u64(0), u64(0)
	switch {
	case n > 8:
		low = u64(intrinsics.unaligned_load((^u64le)(src)))
		high = u64(intrinsics.unaligned_load((^u64le)(src[n - 8:]))) >> (8 * u64(16 - n))
	case n == 8:
		low = u64(intrinsics.unaligned_load((^u64le)(src)))
	case n >= 4:
		low = u64(intrinsics.unaligned_load((^u32le)(src))) | u64(intrinsics.unaligned_load((^u32le)(src[n - 4:]))) << (8 * u64(n - 4))
	case n > 0:
		mid := n / 2
		low = u64(src[0]) | u64(src[mid]) << (8 * u64(mid)) | u64(src[n - 1]) << (8 * u64(n - 1))
	}
	return transmute(CBOR_V)[2]u64{low, high}
}

@(private = "file")
cbor_pad_live :: #force_inline proc "contextless" (live, v: CBOR_V) -> CBOR_V {
	return simd.select(simd.lanes_ne(live, CBOR_V(0)), v, CBOR_V(0))
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
			v = cbor_pad_live(live, v) if ok else cbor_short_block(src, n)
			if kernel.is_ascii16(v) {
				p[0] = 0x60 | u8(n)
				kernel.store16(p[1:], v)
				return 1 + n
			}
		} else if n <= 32 {
			v0 := kernel.load16(src)
			v1 := kernel.load16(src[n - 16:])
			if kernel.is_ascii16(v0 | v1) {
				off := 1
				if n < 24 {
					p[0] = 0x60 | u8(n)
				} else {
					p[0], p[1] = 0x78, u8(n)
					off = 2
				}
				kernel.store16(p[off:], v0)
				kernel.store16(p[off + n - 16:], v1)
				return off + n
			}
		}
		return 0
	}
}

@(private, cold)
cbor_count_struct_members :: proc(plan: ^Plan, first: ^Record, at: uintptr) -> u64 #no_bounds_check {
	n := u64(0)
	for r := first; r.kind != .End; r = intrinsics.ptr_offset(r, 1) {
		if !member_omitted(plan, r, at + uintptr(r.offset)) {
			n += 1
		}
	}
	return n
}

@(private = "file")
cbor_key_less_bytes :: proc(a, b: Cbor_Map_Entry, len_first: bool) -> bool #no_bounds_check {
	la := int(a.head_len) + len(a.text)
	lb := int(b.head_len) + len(b.text)
	if len_first && la != lb {
		return la < lb
	}
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
cbor_key_equal :: proc(a, b: Cbor_Map_Entry) -> bool #no_bounds_check {
	if a.head_len != b.head_len || len(a.text) != len(b.text) {
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
sort_cbor_entries :: proc(s: []Cbor_Map_Entry, order: Cbor_Key_Order) {
	switch order {
	case .Text:
		slice.sort_by(s, proc(a, b: Cbor_Map_Entry) -> bool {
			a, b := a, b
			sa := a.text if a.is_text else string(a.dec_buf[:a.dec_len])
			sb := b.text if b.is_text else string(b.dec_buf[:b.dec_len])
			return sa < sb
		})
	case .Written:
		slice.sort_by(s, proc(a, b: Cbor_Map_Entry) -> bool {return cbor_key_less_bytes(a, b, false)})
	case .Length_First:
		slice.sort_by(s, proc(a, b: Cbor_Map_Entry) -> bool {return cbor_key_less_bytes(a, b, true)})
	case .None:
	}
}

@(private = "file")
inline_buf_grow :: proc(inline_buf: []$T, using_dyn: ^bool, dyn: ^[dynamic]T, cur_len, need: int) -> ([]T, runtime.Allocator_Error) #no_bounds_check {
	if !using_dyn^ && need <= len(inline_buf) {
		return inline_buf, nil
	}
	if !using_dyn^ {
		if err := resize(dyn, max(need * 2, len(inline_buf) * 2)); err != nil {
			return nil, err
		}
		if cur_len > 0 {
			intrinsics.mem_copy_non_overlapping(raw_data(dyn^), raw_data(inline_buf), cur_len * size_of(T))
		}
		using_dyn^ = true
	} else if len(dyn^) < need {
		if err := resize(dyn, max(need * 2, len(dyn^) * 2)); err != nil {
			return nil, err
		}
	}
	return dyn[:], nil
}

@(private)
cbor_prep_init :: proc(prep: ^Cbor_Prep, plan: ^Plan, order: Cbor_Key_Order, allocator: runtime.Allocator) -> runtime.Allocator_Error #no_bounds_check {
	prep.allocator = allocator
	prep.kbuf_dyn.allocator = allocator
	prep.sidx_dyn.allocator = allocator
	n_meta := len(plan.meta)
	if n_meta > CBOR_INLINE_META {
		mem, err := make([]Cbor_Meta_Info, n_meta, allocator)
		if err != nil {
			return err
		}
		prep.meta, prep.meta_heap = mem, true
	} else {
		prep.meta = prep.inline_meta[:n_meta]
	}
	kbuf_slice := prep.inline_kbuf[:]
	sidx_slice := prep.inline_sidx[:]
	kbuf_len, sidx_len := 0, 0
	for &rec in plan.records {
		if rec.kind != .Struct && rec.kind != .Required {
			continue
		}
		scount := int(plan.meta[rec.meta].count)
		em := intrinsics.ptr_offset(rec.first, scount).meta
		if prep.meta[em].seen {
			continue
		}
		prep.meta[em].seen = true
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
				klen := hl + len(name)
				err: runtime.Allocator_Error
				if kbuf_slice, err = inline_buf_grow(prep.inline_kbuf[:], &prep.kbuf_heap, &prep.kbuf_dyn, kbuf_len, kbuf_len + klen + 16); err != nil {
					return err
				}
				intrinsics.mem_copy_non_overlapping(raw_data(kbuf_slice)[kbuf_len:], &tmp_key[0], klen)
				prep.meta[member.meta].off = u32(kbuf_len)
				prep.meta[member.meta].size = u16(klen)
				prep.meta[member.meta].bad_utf8 = bad
				kbuf_len += klen
			} else {
				prep.meta[member.meta].bad_utf8 = bad
			}
		}
		prep.meta[em].has_omit = omit_any
		if order != .None {
			lo := sidx_len
			err: runtime.Allocator_Error
			if sidx_slice, err = inline_buf_grow(prep.inline_sidx[:], &prep.sidx_heap, &prep.sidx_dyn, lo, lo + scount); err != nil {
				return err
			}
			sub := sidx_slice[lo:lo + scount]
			for fi in 0 ..< scount {
				sub[fi] = u32(fi)
			}
			sidx_len += scount
			kb := raw_data(kbuf_slice)
			for a in 1 ..< scount {
				cur_idx := sub[a]
				m_a := intrinsics.ptr_offset(rec.first, int(cur_idx)).meta
				j := a - 1
				for j >= 0 {
					m_b := intrinsics.ptr_offset(rec.first, int(sub[j])).meta
					if !cbor_struct_key_less(plan, prep.meta, kb, m_a, m_b, order) {
						break
					}
					sub[j + 1] = sub[j]
					j -= 1
				}
				sub[j + 1] = cur_idx
			}
			prep.meta[em].span_lo = u32(lo)
			prep.meta[em].span_n = u32(scount)
		}
	}
	prep.kbuf = raw_data(kbuf_slice)
	prep.sidx = sidx_slice
	return nil
}

@(private = "file")
cbor_struct_key_less :: proc "contextless" (plan: ^Plan, meta: []Cbor_Meta_Info, kbuf: [^]u8, ma, mb: u32, order: Cbor_Key_Order) -> bool #no_bounds_check {
	na, nb := plan.meta[ma].name, plan.meta[mb].name
	if order == .Text {
		return na < nb
	}
	ra, rb := meta[ma], meta[mb]
	if ra.size > 0 && rb.size > 0 {
		if order == .Length_First && ra.size != rb.size {
			return ra.size < rb.size
		}
		return string(kbuf[ra.off:][:ra.size]) < string(kbuf[rb.off:][:rb.size])
	}
	return len(na) < len(nb) || len(na) == len(nb) && na < nb
}

@(private)
cbor_prep_destroy :: proc(prep: ^Cbor_Prep) {
	if prep.meta_heap {
		delete(prep.meta, prep.allocator)
	}
	if prep.kbuf_heap {
		delete(prep.kbuf_dyn)
	}
	if prep.sidx_heap {
		delete(prep.sidx_dyn)
	}
}
