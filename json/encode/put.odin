package encode

import "base:intrinsics"
import core_pkg "../../core"
import "../../core/spell"

MAX_DEPTH :: core_pkg.MAX_DEPTH

// The put layer, by the names this package's writers use.
put_reserve :: spell.put_reserve
put_room :: spell.put_room
put_commit :: spell.put_commit
put_publish :: spell.put_publish
put_byte :: spell.put_byte
put_bytes :: spell.put_bytes
put_i64 :: spell.put_i64
put_u64 :: spell.put_u64
put_f64 :: spell.put_f64
copy_lead :: spell.copy_lead

Marshal_Opts :: struct {
	pretty:           bool,          // false (the zero value) is compact
	indent:           u8,            // pretty: 0 indents one tab per open container, N indents N spaces
	ascii_only:       bool,          // every character past U+007F as `\uXXXX`, a surrogate pair past U+FFFF
	escape_html:      bool,          // `<`, `>`, `&`, U+2028 and U+2029 as `\uXXXX`
	trailing_newline: bool,          // a `\n` after the root value
	sort_keys:        bool,          // every object's keys in byte order, as `stury -S`
}

// The reason the canonical writer refused a value (core's `Marshal_Error_Kind`). `.None` is success. JSON never
// reports `Bad_Option` or `Unwritable`.
Marshal_Error_Kind :: core_pkg.Marshal_Error_Kind

// A line break and `ind`'s indent for `depth` open containers. Writes run up to INDENT_SLACK bytes past it.
put_newline :: proc(dst: ^[dynamic]u8, depth: u32, ind: ^Indent) -> Marshal_Error_Kind {
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
put_colon :: #force_inline proc(dst: ^[dynamic]u8, pretty: bool) -> Marshal_Error_Kind {
	if pretty {
		return put_bytes(dst, ": ")
	}
	return put_byte(dst, ':')
}

