package spell

// The put layer every writer appends through: no container check, for callers that own the structure. Each
// reserves room once per item, writes through the returned address, then commits the length. Nothing is
// committed on a refusal.

import "base:intrinsics"
import "base:runtime"
import core_pkg ".."

// Room for `n` more bytes past `len(dst)`: the address of the first, or nil when the allocator refused.
put_reserve :: #force_inline proc(dst: ^[dynamic]u8, n: int) -> [^]u8 {
	return put_room(dst, len(dst^), n)
}

// Room for `n` bytes at `w`, a write cursor the caller keeps past `len(dst)` instead of committing each
// item: the address of `dst[w]`, or nil when the allocator refused. Growing first commits up to `w`, so the
// bytes before it survive the move. Growth at least doubles, so a run of appends costs amortized O(1) each.
put_room :: #force_inline proc(dst: ^[dynamic]u8, w, n: int) -> [^]u8 {
	if w + n > cap(dst^) {
		(^runtime.Raw_Dynamic_Array)(dst).len = w
		if non_zero_reserve(dst, max(w + n, 2 * cap(dst^))) != nil {
			return nil
		}
	}
	return raw_data(dst^)[w:]
}

// Say that `n` more bytes were written past `len(dst)`. Legal only after a `put_reserve` that covers them.
put_commit :: #force_inline proc(dst: ^[dynamic]u8, n: int) {
	(^runtime.Raw_Dynamic_Array)(dst).len += n
}

put_byte :: #force_inline proc(dst: ^[dynamic]u8, x: u8) -> core_pkg.Marshal_Error {
	p := put_reserve(dst, 1)
	if p == nil {
		return .Out_Of_Memory
	}
	p[0] = x
	put_commit(dst, 1)
	return .None
}

put_bytes :: proc(dst: ^[dynamic]u8, s: string) -> core_pkg.Marshal_Error {
	p := put_reserve(dst, len(s))
	if p == nil {
		return .Out_Of_Memory
	}
	intrinsics.mem_copy_non_overlapping(p, raw_data(s), len(s))
	put_commit(dst, len(s))
	return .None
}

put_i64 :: proc(dst: ^[dynamic]u8, v: i64) -> core_pkg.Marshal_Error {
	p := put_reserve(dst, INT_ROOM)
	if p == nil {
		return .Out_Of_Memory
	}
	put_commit(dst, spell_i64(p, v))
	return .None
}

put_u64 :: proc(dst: ^[dynamic]u8, v: u64) -> core_pkg.Marshal_Error {
	p := put_reserve(dst, INT_ROOM)
	if p == nil {
		return .Out_Of_Memory
	}
	put_commit(dst, spell_u64(p, v))
	return .None
}

put_f64 :: proc(dst: ^[dynamic]u8, f: f64) -> core_pkg.Marshal_Error {
	if is_non_finite(f) {
		return .Non_Finite
	}
	p := put_reserve(dst, F64_ROOM)
	if p == nil {
		return .Out_Of_Memory
	}
	put_commit(dst, spell_f64(p, f))
	return .None
}

// Room for a scalar `spell_scalar` writes: an integer, a float, or the `true`/`false` word (one u64 store).
SCALAR_ROOM :: max(INT_ROOM, F64_ROOM, size_of(u64))

// `true` and `false`, low byte first.
TRUE_WORD :: u64(0x65_75_72_74)
FALSE_WORD :: u64(0x65_73_6c_61_66)

// Write the `.Int`, `.Uint`, `.Float` or `.Bool` scalar of `size` bytes at `at` into `p`, which has
// SCALAR_ROOM bytes. Returns the count written.
spell_scalar :: #force_inline proc(p: [^]u8, kind: core_pkg.Shape_Kind, at: rawptr, size: u8) -> (int, core_pkg.Marshal_Error) #no_bounds_check {
	#partial switch kind {
	case .Int:
		return spell_i64(p, #force_inline core_pkg.shape_int_load(at, size)), .None
	case .Uint:
		return spell_u64(p, #force_inline core_pkg.shape_uint_load(at, size)), .None
	case .Float:
		x := #force_inline core_pkg.shape_float_load(at, size)
		if is_non_finite(x) {
			return 0, .Non_Finite
		}
		return spell_f64(p, x), .None
	}
	yes := #force_inline core_pkg.shape_uint_load(at, size) != 0
	intrinsics.unaligned_store((^u64)(p), TRUE_WORD if yes else FALSE_WORD)
	return 5 - int(yes), .None
}

// `n` bytes, at least 4, from `src` to `dst` in whole-word stores that overlap rather than run past either
// end.
copy_lead :: #force_inline proc "contextless" (dst, src: [^]u8, n: int) #no_bounds_check {
	switch {
	case n > 16:
		for k := 0; k < n - 16; k += 16 {
			intrinsics.unaligned_store((^[16]u8)(&dst[k]), intrinsics.unaligned_load((^[16]u8)(&src[k])))
		}
		intrinsics.unaligned_store((^[16]u8)(&dst[n - 16]), intrinsics.unaligned_load((^[16]u8)(&src[n - 16])))
	case n >= 8:
		head := intrinsics.unaligned_load((^u64)(src))
		tail := intrinsics.unaligned_load((^u64)(&src[n - 8]))
		intrinsics.unaligned_store((^u64)(dst), head)
		intrinsics.unaligned_store((^u64)(&dst[n - 8]), tail)
	case:
		head := intrinsics.unaligned_load((^u32)(src))
		tail := intrinsics.unaligned_load((^u32)(&src[n - 4]))
		intrinsics.unaligned_store((^u32)(dst), head)
		intrinsics.unaligned_store((^u32)(&dst[n - 4]), tail)
	}
}

// `n` bytes from `src` to `dst`, 0 included: `copy_lead` from 4 bytes, a long run left to `mem_copy`.
copy_short :: #force_inline proc "contextless" (dst, src: [^]u8, n: int) #no_bounds_check {
	switch {
	case n > 64:
		intrinsics.mem_copy_non_overlapping(dst, src, n)
	case n >= 4:
		copy_lead(dst, src, n)
	case n > 0:
		dst[0], dst[n / 2], dst[n - 1] = src[0], src[n / 2], src[n - 1]
	}
}
