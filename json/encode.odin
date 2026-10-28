package json

// The writer's options and refusals, and `marshal` of a `Document`. The writer lives in encode/, and `marshal`
// is its only entry.

import "core:io"
import "core:mem"
import "core:slice"
import enc "encode"
import core_pkg "../core"
import scan_pkg "scan"

// How the writer formats its output. The zero value is compact UTF-8 copying the source's number and string
// text.
//
//	- `pretty` with `indent`: 0 is a tab per level, N is N spaces.
//	- `ascii_only` and `escape_html` escaping, and a `trailing_newline`.
//	- `sort_keys` writes each object with its members in byte order, as `stury -S` does: a `Document`'s by decoded
//	  key, a struct's by written name (a union arm's tag among them). With `jq_spelling` a document's repeated key
//	  has been merged first, without it repeated keys keep their source order (a stable sort), and a JSONC
//	  member's comments move with it. A map's keys are in byte order of their written text with or without it.
Marshal_Opts :: enc.Marshal_Opts

// How `marshal` writes a `Document`: its `Marshal_Opts`, and what only a document's text has to respell.
Document_Opts :: struct {
	using opts:  Marshal_Opts,
	// Write as the command line does: a number as decNumber prints it (`1E2` is `1E+2`) or, past its range, as a
	// double, a string with jq's escapes (`"\/"` is `"/"`, DEL is `\u007f`), a repeated key once, at its first
	// place with its last value, and a JSONC document's comments where the command line prints them.
	jq_spelling: bool,
}

// The literal jq keeps of number token `lit`, which `jq_spelling` prints: `lit` itself inside decNumber's range,
// a zero of its least exponent below it, or "" past it, where jq keeps only the double.
jq_literal :: enc.bounded_literal

// The order of number literals `a` and `b` as exact decimals, -1, 0 or 1, as jq compares them: `1.0` equals `1`, and
// `-1e-400` is below `0` though it is `-0.0` as a double.
compare_literals :: enc.compare_literals

// A writer refusal (`.None` is success). `marshal`'s: `Bad_Utf8`, `Non_Finite` (a NaN, an infinity, or a
// `Number` that is `.None` or `.Underflowed`), `Too_Deep` (past `MAX_DEPTH`), `Cycle`, `Unsupported`, `Bad_Raw`,
// `Bad_Tag` (a field tag flag the format does not know), `Plan_Mismatch`, `Not_A_Member`, `Bad_State` (a hook
// writing other than one value), `Write_Failed` (the `io.Writer`, after a prefix written) and `Out_Of_Memory`.
Marshal_Error_Kind :: enc.Marshal_Error_Kind

// A refusal of `marshal` or `marshal_to_writer`: its kind and the path to the value refused, which a document's
// refusal has none of. `render_error(nil, err)` writes it.
Marshal_Error :: core_pkg.Marshal_Error

// Write `doc` as JSON text: every key and scalar as authored, whitespace removed (compact) or re-indented
// (pretty, `opts.indent`). A JSONC document keeps its comments where they are attached and drops its
// trailing commas (`encode_rows_jsonc`). `out` is allocated with `allocator` and owned by the caller.
// `.Bad_State` for a document with no rows. `.Too_Deep` for one nested past `MAX_DEPTH`, which only a
// document read under a raised `max_depth` can be.
@(private, require_results)
marshal_document :: proc(doc: ^Document, opts := Document_Opts{}, allocator := context.allocator) -> (out: []byte, err: Maybe(Marshal_Error)) {
	kind: Marshal_Error_Kind
	out, kind = document_text(doc, opts, allocator)
	return out, core_pkg.marshal_error_of(kind)
}

// `marshal_document`'s text, or why not.
@(private)
document_text :: proc(doc: ^Document, opts: Document_Opts, allocator: mem.Allocator) -> (out: []byte, err: Marshal_Error_Kind) {
	when ODIN_DEBUG {
		check_document(doc)
	}
	if doc.deep && enc.rows_too_deep(doc.rows[:]) {
		// Every writer but the byte minifier keeps a frame per level of a MAX_DEPTH stack.
		if opts.pretty || opts.jq_spelling || opts.sort_keys || !scan_pkg.doc_plain_json(doc) {
			return nil, .Too_Deep
		}
		return enc.encode_minified(doc.src, doc.rows[0], opts.opts, allocator)
	}
	// A dialect with its own spelling has its tokens respelled one at a time, and a pruned document's containers
	// are written from their rows.
	if opts.jq_spelling || opts.sort_keys || scan_pkg.doc_own_spelling(doc) || doc.pruned {
		return marshal_document_jq(doc, opts, allocator)
	}
	if scan_pkg.has_comments(scan_pkg.dialect_of(doc)) {
		return enc.encode_rows_jsonc(doc.src, doc.rows[:], doc.facts[:], opts.opts, allocator)
	}
	return enc.encode_rows(doc.src, doc.rows[:], opts.opts, allocator)
}

// `marshal_document` appended to `out`. On a refusal `out` is as it was on entry.
@(private, require_results)
marshal_document_append :: proc(out: ^[dynamic]u8, doc: ^Document, opts := Document_Opts{}) -> Maybe(Marshal_Error) {
	return core_pkg.marshal_error_of(append_document(out, doc, opts))
}

// A `Document` appended to `dst` as `marshal_document` writes it: one given to `marshal_append`, or one met as an
// `any` (a `marshal` of its value, or the value of `set` or `insert`), not reflected over as a struct.
@(private)
append_document :: proc(dst: ^[dynamic]u8, doc: ^Document, opts: Document_Opts) -> Marshal_Error_Kind {
	out := document_text(doc, opts, dst.allocator) or_return
	defer delete(out, dst.allocator)
	if _, aerr := append(dst, ..out); aerr != nil {
		return .Out_Of_Memory
	}
	return .None
}

// `marshal_document` written to `w` as it is made, through a buffer of about 64 KiB from `allocator`, freed
// before return.
@(private, require_results)
marshal_document_to_writer :: proc(w: io.Writer, doc: ^Document, opts := Document_Opts{}, allocator := context.allocator) -> Maybe(Marshal_Error) {
	return core_pkg.marshal_error_of(document_to_writer(w, doc, opts, allocator))
}

@(private)
document_to_writer :: proc(w: io.Writer, doc: ^Document, opts: Document_Opts, allocator: mem.Allocator) -> Marshal_Error_Kind {
	if !scan_pkg.doc_plain_json(doc) || opts.jq_spelling || opts.sort_keys || doc.deep && enc.rows_too_deep(doc.rows[:]) {
		// A dialect's document, one in jq's notation or with sorted keys, or one nested past MAX_DEPTH, is made
		// whole, then written.
		out, err := document_text(doc, opts, allocator)
		if err != .None {
			return err
		}
		defer delete(out, allocator)
		if _, werr := io.write_full(w, out); werr != nil {
			return .Write_Failed
		}
		return .None
	}
	return enc.encode_rows_to_writer(w, doc.src, doc.rows[:], opts.opts, allocator)
}

// `marshal_document` under `Document_Opts.jq_spelling` or `sort_keys`: the document walked by its accessors, laid
// out by the `Writer` the command line prints with. Under `jq_spelling` each scalar is spelled as the command line
// spells it, and each object's repeated key once with its last value's comments (`document_members`). Without it
// scalars and keys are copied as authored.
@(private = "file")
marshal_document_jq :: proc(doc: ^Document, opts: Document_Opts, allocator: mem.Allocator) -> (out: []byte, err: Marshal_Error_Kind) {
	if len(doc.rows) == 0 || doc.rows[0].subtree_size != u32(len(doc.rows)) {
		return nil, .Bad_State
	}
	buf := make([dynamic]byte, 0, len(doc.src) + 1, allocator)
	w := Writer{out = &buf, pretty = opts.pretty, indent = -1 if opts.indent == 0 else int(opts.indent), jq_spelling = opts.jq_spelling, src = doc.src}
	err = jq_root(&w, doc, opts, allocator, scan_pkg.doc_own_spelling(doc))
	if err == .None {
		err = enc.reescape_tail(&buf, 0, enc.reescape_of(opts.opts))
	}
	if err != .None {
		delete(buf)
		return nil, err
	}
	return buf[:], .None
}

// Value `n` of `doc` in JSON's spelling, with its comments, appended to `buf` as `marshal_document` writes it.
// `.Non_Finite` for `Infinity` or `NaN` in it.
@(private)
node_json :: proc(buf: ^[dynamic]byte, doc: ^Document, n: Node) -> Marshal_Error_Kind {
	w := Writer{out = buf, src = doc.src}
	return jq_value(&w, doc, n, {}, buf.allocator, scan_pkg.doc_own_spelling(doc))
}

// The root with its comments, then the `trailing_newline`, which a line comment ending the output has made.
@(private = "file")
jq_root :: proc(w: ^Writer, doc: ^Document, opts: Document_Opts, allocator: mem.Allocator, respell: bool) -> Marshal_Error_Kind {
	own := facts(doc, ROOT)
	write_comments(w, own, .Lead, root = true) or_return
	jq_value(w, doc, ROOT, opts, allocator, respell) or_return
	write_comments(w, own, .Trail, root = true) or_return
	if opts.trailing_newline && w.out[len(w.out) - 1] != '\n' {
		return enc.put_byte(w.out, '\n')
	}
	return .None
}

@(private = "file")
jq_value :: proc(w: ^Writer, doc: ^Document, n: Node, opts: Document_Opts, allocator: mem.Allocator, respell: bool) -> Marshal_Error_Kind {
	k, _ := kind(doc, n)
	switch k {
	case .Null, .False, .True:
		return enc.put_bytes(w.out, string(get_raw(doc, n)))
	case .Number:
		return jq_number(w, doc, n, respell)
	case .String:
		return jq_string(w.out, doc, n, opts, respell)
	case .Array, .Object:
		return jq_container(w, doc, n, k, opts, allocator, respell)
	}
	return .None
}

@(private = "file")
jq_number :: proc(w: ^Writer, doc: ^Document, n: Node, respell: bool) -> Marshal_Error_Kind {
	lit := string(get_raw(doc, n))
	if respell && doc.rows[n].first_esc == scan_pkg.DIALECT_SPELLED {
		if enc.put_room(w.out, len(w.out), len(lit) + 32) == nil {
			return .Out_Of_Memory
		}
		if !scan_pkg.json5_number_json(lit, w.out) {
			return .Non_Finite
		}
		return .None
	}
	return write_number(w, lit)
}

@(private = "file")
jq_string :: proc(buf: ^[dynamic]byte, doc: ^Document, n: Node, opts: Document_Opts, respell: bool) -> Marshal_Error_Kind {
	// A string of a dialect with its own spelling is plain only double-quoted with no escape.
	if !opts.jq_spelling && (!respell || .Str_Escaped not_in doc.rows[n].flags) {
		return enc.put_bytes(buf, string(get_raw(doc, n)))
	}
	s, _ := get_string(doc, n)
	return enc.put_string_escaping_del(buf, s)
}

// An array or object `n` of kind `k`: its members in `document_members` order, each with its comments.
@(private = "file")
jq_container :: proc(w: ^Writer, doc: ^Document, n: Node, k: Kind, opts: Document_Opts, allocator: mem.Allocator, respell: bool) -> Marshal_Error_Kind {
	if child_count(doc, n) == 0 {
		write_open(w, k) or_return
		return write_close(w, k, 0, nil, facts(doc, n))
	}
	entries, ok := document_members(doc, n, opts, allocator)
	defer delete(entries)
	if !ok {
		return .Out_Of_Memory
	}
	write_open(w, k) or_return
	prev: []Fact // the entry written last's, whose trailing comments follow its comma
	for e, i in entries {
		v := e.val
		own := facts(doc, v)
		write_element(w, k, i, prev, own) or_return
		if k == .Object {
			if opts.jq_spelling || (respell && .Key_Escaped in doc.rows[v].flags) {
				enc.put_string_escaping_del(w.out, e.key) or_return
			} else {
				enc.put_bytes(w.out, string(doc.src[doc.rows[v].key_lo:doc.rows[v].key_hi])) or_return
			}
			key_tail(w, own) or_return
		}
		jq_value(w, doc, v, opts, allocator, respell) or_return
		prev = own
	}
	return write_close(w, k, len(entries), prev, facts(doc, n))
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
document_members :: proc(doc: ^Document, n: Node, opts: Document_Opts, allocator: mem.Allocator) -> (entries: [dynamic]Entry, ok: bool) {
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
