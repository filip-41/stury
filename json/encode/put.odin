package encode

// The put layer: appends without a container check, for callers that own the structure (the node-row walk,
// the marshal plan). Each reserves room once per item, writes through the returned address, then commits
// the length. Nothing is committed on a refusal.

import "base:intrinsics"
import core_pkg "../../core"
import "../scan/walk"
import "../../core/spell"

MAX_DEPTH :: walk.MAX_DEPTH

Marshal_Opts :: struct {
	pretty:           bool,          // false (the zero value) is compact
	indent:           u8,            // pretty: 0 indents one tab per open container, N indents N spaces
	ascii_only:       bool,          // every character past U+007F as `\uXXXX`, a surrogate pair past U+FFFF
	escape_html:      bool,          // `<`, `>`, `&`, U+2028 and U+2029 as `\uXXXX`
	trailing_newline: bool,          // a `\n` after the root value
	jq_spelling:      bool,          // `marshal` of a `Document` written as the jq-compatible CLI prints it
	sort_keys:        bool,          // `marshal` of a `Document` with each object's keys in byte order, as `stury -S`, ignored for an `any`
}

// The reason the canonical writer refused a value (core's `Marshal_Error`). `.None` is success. JSON never
// reports `Bad_Option` or `Unwritable`.
Marshal_Error :: core_pkg.Marshal_Error

// Room for `n` more bytes past `len(dst)`: the address of the first, or nil when the allocator refused.
// Growth at least doubles, so a run of appends costs amortized O(1) each.
@(private)
put_reserve :: #force_inline proc(dst: ^[dynamic]u8, n: int) -> [^]u8 {
	return put_room(dst, len(dst^), n)
}

// Room for `n` bytes at `w`, a write cursor the caller keeps past `len(dst)` instead of committing each
// item: the address of `dst[w]`, or nil when the allocator refused. Growing first commits up to `w`, so the
// bytes before it survive the move.
put_room :: #force_inline proc(dst: ^[dynamic]u8, w, n: int) -> [^]u8 {
	if w + n > cap(dst^) {
		walk.edge_publish(dst, w)
		if non_zero_reserve(dst, max(w + n, 2 * cap(dst^))) != nil {
			return nil
		}
	}
	return raw_data(dst^)[w:]
}

// Say that `n` more bytes were written past `len(dst)`. Legal only after a `put_reserve` that covers them.
put_commit :: #force_inline proc(dst: ^[dynamic]u8, n: int) {
	walk.edge_publish(dst, len(dst^) + n)
}

put_byte :: #force_inline proc(dst: ^[dynamic]u8, x: u8) -> Marshal_Error {
	p := put_reserve(dst, 1)
	if p == nil {
		return .Out_Of_Memory
	}
	p[0] = x
	put_commit(dst, 1)
	return .None
}

put_bytes :: proc(dst: ^[dynamic]u8, s: string) -> Marshal_Error {
	p := put_reserve(dst, len(s))
	if p == nil {
		return .Out_Of_Memory
	}
	intrinsics.mem_copy_non_overlapping(p, raw_data(s), len(s))
	put_commit(dst, len(s))
	return .None
}

// A line break and `ind`'s indent for `depth` open containers. Writes run up to INDENT_SLACK bytes past it.
put_newline :: proc(dst: ^[dynamic]u8, depth: u32, ind: ^Indent) -> Marshal_Error {
	p := put_reserve(dst, 1 + int(depth) * ind.unit + INDENT_SLACK)
	if p == nil {
		return .Out_Of_Memory
	}
	put_commit(dst, put_indent(p, int(depth), ind, false))
	return .None
}

// Pretty output's indent: a line break, then `unit` fill bytes per open container.
Indent :: struct {
	head: [16]u8, // `\n` and 15 fill bytes
	body: [16]u8, // 16 fill bytes
	unit: int,
}

// One tab per container when `opts.indent` is 0, else that many spaces.
indent_of :: proc(opts: Marshal_Opts) -> Indent {
	if opts.indent == 0 {
		return {INDENT_HEAD, INDENT_TABS, 1}
	}
	ind := Indent{unit = int(opts.indent)}
	for k in 0 ..< 16 {
		ind.head[k] = ' '
		ind.body[k] = ' '
	}
	ind.head[0] = '\n'
	return ind
}

// `\n` and the first 15 tabs of an indent, then tabs only.
@(private, rodata)
INDENT_HEAD: [16]u8 = {'\n', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t'}
@(private, rodata)
INDENT_TABS: [16]u8 = {'\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t', '\t'}

// Room past an indent that `put_indent` may write into.
@(private)
INDENT_SLACK :: 16

// A line break and the indent for `depth` levels at `p` in whole 16-byte stores. Returns the count that belongs to
// the indent. `TABS` is `ind` being one tab per level.
@(private)
put_indent :: #force_inline proc "contextless" (p: [^]u8, depth: int, ind: ^Indent, $TABS: bool) -> int #no_bounds_check {
	n := 1 + depth when TABS else 1 + depth * ind.unit
	intrinsics.unaligned_store((^[16]u8)(p), INDENT_HEAD when TABS else ind.head)
	for k := 16; k < n; k += 16 {
		intrinsics.unaligned_store((^[16]u8)(&p[k]), INDENT_TABS when TABS else ind.body)
	}
	return n
}

// What follows a key: `:`, and one space when pretty.
put_colon :: #force_inline proc(dst: ^[dynamic]u8, pretty: bool) -> Marshal_Error {
	if pretty {
		return put_bytes(dst, ": ")
	}
	return put_byte(dst, ':')
}

put_i64 :: proc(dst: ^[dynamic]u8, v: i64) -> Marshal_Error {
	p := put_reserve(dst, spell.INT_ROOM)
	if p == nil {
		return .Out_Of_Memory
	}
	put_commit(dst, spell.spell_i64(p, v))
	return .None
}

put_u64 :: proc(dst: ^[dynamic]u8, v: u64) -> Marshal_Error {
	p := put_reserve(dst, spell.INT_ROOM)
	if p == nil {
		return .Out_Of_Memory
	}
	put_commit(dst, spell.spell_u64(p, v))
	return .None
}

put_f64 :: proc(dst: ^[dynamic]u8, f: f64) -> Marshal_Error {
	if spell.is_non_finite(f) {
		return .Non_Finite
	}
	p := put_reserve(dst, spell.F64_ROOM)
	if p == nil {
		return .Out_Of_Memory
	}
	put_commit(dst, spell.spell_f64(p, f))
	return .None
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
