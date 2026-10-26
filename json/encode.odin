package json

// The writer's options and refusals, and `marshal` of a `Document`. The writer lives in encode/, and `marshal`
// is its only entry.

import "core:io"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strconv"
import enc "encode"
import scan_pkg "scan"

// How the writer formats its output. The zero value is compact UTF-8 copying the source's number and string
// text.
//
//	- `pretty` with `indent`: 0 is a tab per level, N is N spaces.
//	- `ascii_only` and `escape_html` escaping, and a `trailing_newline`.
//	- `jq_spelling` makes `marshal` of a `Document` write as the command line does: a number as decNumber
//	  prints it (`1E2` is `1E+2`) or, past its range, as a double, a string with jq's escapes (`"\/"` is
//	  `"/"`, DEL is `\u007f`), a repeated key once, at its first place with its last value, and a JSONC
//	  document's comments where the command line prints them.
//	- `sort_keys` writes each object's members by decoded key, in byte order, as `stury -S` does. With
//	  `jq_spelling` a repeated key has been merged first, without it repeated keys keep their source order
//	  (a stable sort), and a JSONC member's comments move with it.
//	- Neither `jq_spelling` nor `sort_keys` is applied to a `marshal` of an `any` (a map is already sorted,
//	  a struct keeps its declaration order).
Marshal_Opts :: enc.Marshal_Opts

// A writer refusal (`.None` is success). `marshal`'s: `Bad_Utf8`, `Non_Finite` (a NaN, an infinity, or a
// `Number` that is `.None` or `.Underflowed`), `Too_Deep` (past `MAX_DEPTH`), `Cycle`, `Unsupported`, `Bad_Raw`,
// `Bad_Tag` (a field tag flag the format does not know), `Plan_Mismatch`, `Not_A_Member`, `Bad_State` (a hook
// writing other than one value), `Write_Failed` (the `io.Writer`, after a prefix written) and `Out_Of_Memory`.
Marshal_Error :: enc.Marshal_Error

// Write `doc` as JSON text: every key and scalar as authored, whitespace removed (compact) or re-indented
// (pretty, `opts.indent`). A JSONC document keeps its comments where they are attached and drops its
// trailing commas (`encode_rows_jsonc`). `out` is allocated with `allocator` and owned by the caller.
// `.Bad_State` for a document with no rows. `.Too_Deep` for one nested past `MAX_DEPTH`, which only a
// document read under a raised `max_depth` can be.
@(private, require_results)
marshal_document :: proc(doc: ^Document, opts := Marshal_Opts{}, allocator := context.allocator) -> (out: []byte, err: Marshal_Error) {
	when ODIN_DEBUG {
		check_document(doc)
	}
	if doc.deep && enc.rows_too_deep(doc.rows[:]) {
		return nil, .Too_Deep
	}
	if opts.jq_spelling || opts.sort_keys || doc.dialect == .Json5 {
		return marshal_document_jq(doc, opts, allocator)
	}
	if doc.dialect == .Jsonc {
		return enc.encode_rows_jsonc(doc.src, doc.rows[:], doc.facts[:], opts, allocator)
	}
	return enc.encode_rows(doc.src, doc.rows[:], opts, allocator)
}

// A `Document`, or a pointer to one, met as an `any` (a `marshal` of its value, or the value of `set` or `insert`):
// appended to `dst` as `marshal_document` writes it, not reflected over as a struct.
@(private)
marshal_document_append :: proc(dst: ^[dynamic]u8, doc: ^Document, opts: Marshal_Opts) -> Marshal_Error {
	out := marshal_document(doc, opts, dst.allocator) or_return
	defer delete(out, dst.allocator)
	if _, aerr := append(dst, ..out); aerr != nil {
		return .Out_Of_Memory
	}
	return .None
}

// `marshal_document` written to `w` as it is made, through a buffer of about 64 KiB from `allocator`, freed
// before return.
@(private, require_results)
marshal_document_to_writer :: proc(w: io.Writer, doc: ^Document, opts := Marshal_Opts{}, allocator := context.allocator) -> Marshal_Error {
	if doc.deep && enc.rows_too_deep(doc.rows[:]) {
		return .Too_Deep
	}
	if doc.dialect != .Json || opts.jq_spelling || opts.sort_keys {
		// A dialect's document, or one in jq's notation or with sorted keys, is made whole, then written.
		out, err := marshal_document(doc, opts, allocator)
		if err != .None {
			return err
		}
		defer delete(out, allocator)
		if _, werr := io.write_full(w, out); werr != nil {
			return .Write_Failed
		}
		return .None
	}
	return enc.encode_rows_to_writer(w, doc.src, doc.rows[:], opts, allocator)
}

// `marshal_document` under `Marshal_Opts.jq_spelling` or `sort_keys`: the document walked by its accessors. Under
// `jq_spelling` each scalar is written by `enc.put_jq_literal` and `enc.put_string_escaping_del`, the implementation
// the command line prints with, and each object's repeated key once with its last value's comments
// (`document_members`). Without it scalars and keys are copied as authored. A JSONC document's comments
// are placed by the printer the command line shares (`enc.put_leads` and the rest).
@(private = "file")
marshal_document_jq :: proc(doc: ^Document, opts: Marshal_Opts, allocator: mem.Allocator) -> (out: []byte, err: Marshal_Error) {
	if len(doc.rows) == 0 || doc.rows[0].subtree_size != u32(len(doc.rows)) {
		return nil, .Bad_State
	}
	buf := make([dynamic]byte, 0, len(doc.src) + 1, allocator)
	cl := enc.Comment_Layout{src = doc.src, pretty = opts.pretty, indent = enc.indent_of(opts)}
	err = jq_root(&buf, doc, &cl, opts, allocator)
	if err == .None {
		err = enc.reescape_tail(&buf, 0, enc.reescape_of(opts))
	}
	if err != .None {
		delete(buf)
		return nil, err
	}
	return buf[:], .None
}

// The root with its comments, then the `trailing_newline`, which a line comment ending the output has made.
@(private = "file")
jq_root :: proc(buf: ^[dynamic]byte, doc: ^Document, cl: ^enc.Comment_Layout, opts: Marshal_Opts, allocator: mem.Allocator) -> Marshal_Error {
	own := facts(doc, ROOT)
	enc.put_leads(buf, cl, own, 0, root = true) or_return
	jq_value(buf, doc, ROOT, cl, opts, 0, allocator) or_return
	enc.put_trails(buf, cl, own, 0, root = true) or_return
	if opts.trailing_newline && buf[len(buf) - 1] != '\n' {
		return enc.put_byte(buf, '\n')
	}
	return .None
}

@(private = "file")
jq_value :: proc(buf: ^[dynamic]byte, doc: ^Document, n: Node, cl: ^enc.Comment_Layout, opts: Marshal_Opts, depth: int, allocator: mem.Allocator) -> Marshal_Error {
	k, _ := kind(doc, n)
	switch k {
	case .Null, .False, .True:
		return enc.put_bytes(buf, string(get_raw(doc, n)))
	case .Number:
		return jq_number(buf, doc, n, opts)
	case .String:
		return jq_string(buf, doc, n, opts)
	case .Array, .Object:
		return jq_container(buf, doc, n, k, cl, opts, depth, allocator)
	}
	return .None
}

@(private = "file")
jq_number :: proc(buf: ^[dynamic]byte, doc: ^Document, n: Node, opts: Marshal_Opts) -> Marshal_Error {
	lit := string(get_raw(doc, n))
	if doc.dialect == .Json5 && doc.rows[n].first_esc == scan_pkg.DIALECT_SPELLED {
		return json5_number_as_json(buf, doc, n, lit)
	}
	if !opts.jq_spelling {
		return enc.put_bytes(buf, lit)
	}
	// The written form is at most a few bytes longer than the literal (or a double's 40): room for it first,
	// so its appends cannot be refused.
	if enc.put_room(buf, len(buf^), len(lit) + 64) == nil {
		return .Out_Of_Memory
	}
	enc.put_jq_literal(buf, lit)
	return .None
}

@(private = "file")
jq_string :: proc(buf: ^[dynamic]byte, doc: ^Document, n: Node, opts: Marshal_Opts) -> Marshal_Error {
	// A JSON5 string is plain only double-quoted with no escape.
	if !opts.jq_spelling && (doc.dialect != .Json5 || .Str_Escaped not_in doc.rows[n].flags) {
		return enc.put_bytes(buf, string(get_raw(doc, n)))
	}
	s, _ := get_string(doc, n)
	return enc.put_string_escaping_del(buf, s)
}

// An array or object `n` of kind `k`: its members in `document_members` order, each with its comments.
@(private = "file")
jq_container :: proc(buf: ^[dynamic]byte, doc: ^Document, n: Node, k: Kind, cl: ^enc.Comment_Layout, opts: Marshal_Opts, depth: int, allocator: mem.Allocator) -> Marshal_Error {
	open, close := u8('['), u8(']')
	if k == .Object {
		open, close = '{', '}'
	}
	if child_count(doc, n) == 0 {
		enc.put_byte(buf, open) or_return
		if enc.put_feet(buf, cl, facts(doc, n), depth) or_return {
			enc.put_line_break(buf, cl, depth) or_return
		}
		return enc.put_byte(buf, close)
	}
	entries, ok := document_members(doc, n, opts, allocator)
	defer delete(entries)
	if !ok {
		return .Out_Of_Memory
	}
	enc.put_byte(buf, open) or_return
	own: []Fact // the entry written last's, whose trailing comments follow its comma
	for e, i in entries {
		v := e.val
		if i > 0 {
			enc.put_byte(buf, ',') or_return
			enc.put_trails(buf, cl, own, depth + 1) or_return
		}
		enc.put_line_break(buf, cl, depth + 1) or_return
		own = facts(doc, v)
		enc.put_leads(buf, cl, own, depth + 1) or_return
		if k == .Object {
			if opts.jq_spelling || (doc.dialect == .Json5 && .Key_Escaped in doc.rows[v].flags) {
				enc.put_string_escaping_del(buf, e.key) or_return
			} else {
				enc.put_bytes(buf, string(doc.src[doc.rows[v].key_lo:doc.rows[v].key_hi])) or_return
			}
			enc.put_colon(buf, cl.pretty) or_return
			enc.put_inlines(buf, cl, own, depth + 1) or_return
		}
		jq_value(buf, doc, v, cl, opts, depth + 1, allocator) or_return
	}
	enc.put_trails(buf, cl, own, depth + 1) or_return
	enc.put_feet(buf, cl, facts(doc, n), depth) or_return
	enc.put_line_break(buf, cl, depth) or_return
	return enc.put_byte(buf, close)
}

// One member of a container as `document_members` lists it (`key` is empty for an array's element).
@(private = "file")
Entry :: struct {
	key: string,
	val: Node,
}

// The members of container `n`: an array's elements, an object's keys and values. Under `jq_spelling` a repeated
// key is at its first place with its last value, as jq reads it. Under `sort_keys` an object's members are in
// byte order of their decoded keys, repeated keys (without `jq_spelling`) in source order. Made in `allocator`,
// and `ok` is false when the allocator refused.
@(private = "file")
document_members :: proc(doc: ^Document, n: Node, opts: Marshal_Opts, allocator: mem.Allocator) -> (entries: [dynamic]Entry, ok: bool) {
	entries = make([dynamic]Entry, allocator)
	if kd, _ := kind(doc, n); kd == .Array {
		it := children(doc, n)
		for v in children(&it) {
			if _, e := append(&entries, Entry{val = v}); e != nil {
				return
			}
		}
		return entries, true
	}
	at: map[string]int
	if opts.jq_spelling {
		at = make(map[string]int, child_count(doc, n), allocator)
	}
	defer delete(at)
	it := members(doc, n)
	for key, v in members(&it) {
		if i, seen := at[key]; seen {
			entries[i].val = v
			continue
		}
		if opts.jq_spelling && map_insert(&at, key, len(entries)) == nil {
			return
		}
		if _, e := append(&entries, Entry{key, v}); e != nil {
			return
		}
	}
	if opts.sort_keys {
		slice.stable_sort_by(entries[:], proc(a, b: Entry) -> bool {return a.key < b.key})
	}
	return entries, true
}

// A JSON5 number spelled outside JSON's grammar (`DIALECT_SPELLED`), in JSON's spelling: a hex integer in
// decimal (past `u64`, its nearest double), a decimal without its `+`, with a `0` before a leading point and
// without a trailing point. `Infinity` and `NaN` have no JSON spelling and are `.Non_Finite`.
@(private = "file")
json5_number_as_json :: proc(buf: ^[dynamic]byte, doc: ^Document, n: Node, lit: string) -> Marshal_Error {
	v, _ := get_number(doc, n)
	if math.is_nan(v.value) || math.is_inf(v.value) {
		return .Non_Finite
	}
	p := 0
	if lit[0] == '+' || lit[0] == '-' {
		p = 1
	}
	if lit[0] == '-' {
		enc.put_byte(buf, '-') or_return
	}
	if len(lit) > p + 1 && lit[p + 1] | 0x20 == 'x' {
		digits: [32]u8
		if mag, ok := strconv.parse_u64_of_base(lit[p + 2:], 16); ok {
			return enc.put_bytes(buf, strconv.write_uint(digits[:], mag, 10))
		}
		// `write_float` leads with the sign.
		return enc.put_bytes(buf, strconv.write_float(digits[:], abs(v.value), 'g', -1, 64)[1:])
	}
	if lit[p] == '.' {
		enc.put_byte(buf, '0') or_return
	}
	for i in p ..< len(lit) {
		if lit[i] == '.' && (i + 1 == len(lit) || lit[i + 1] - '0' >= 10) {
			continue
		}
		enc.put_byte(buf, lit[i]) or_return
	}
	return .None
}
