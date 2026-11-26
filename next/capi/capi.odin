package capi

import "base:runtime"
import "core:c"
import "core:io"
import "core:mem"
import "stury:engine"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import ops_write "stury:lib/ops/write"
import schema_check "stury:lib/schema/check"
import schema_pkg "stury:lib/schema/schema"
import "stury:stury"

// C99/C11 ABI implementation matching `stury.h`.
// Zero global mutable state, caller-arena-owned outputs and diagnostics, NULL/length-checked at every entry point,
// and never panics across FFI boundaries.

FORMAT_UNKNOWN :: u32(255)

Err_Code :: enum u32 {
	Ok             = 0,
	Invalid_Arg    = 1,
	Syntax         = 2,
	Budget         = 3,
	No_Memory      = 4,
	Unspellable    = 5,
	Schema_Invalid = 6,
	Edit_Refused   = 7,
	Query_Runtime  = 8,
	Stopped        = 9,
	Unsupported    = 10,
	Halted         = 11,
}

Err :: struct {
	code:    Err_Code,
	at:      u64,
	message: cstring,
}

Budget :: struct {
	depth:     u32,
	nodes:     u32,
	memory:    u64,
	steps:     u64,
	expansion: u64,
}

Arena :: struct {
	dyn:     mem.Dynamic_Arena,
	backing: runtime.Allocator,
}

Emit_Fn :: #type proc "c" (ctx: rawptr, bytes: [^]u8, n: c.size_t) -> bool
Jsonpath_Emit_Fn :: #type proc "c" (ctx: rawptr, bytes: [^]u8, n: c.size_t, norm_path: [^]u8, norm_path_len: c.size_t) -> bool

#assert(len(engine.Format_Id) == 13)
#assert(size_of(tape.Caps) == size_of(u32))
#assert(len(tape.Fact_Kind) <= 16)
#assert(size_of(Budget) == size_of(tape.Budget))
#assert(size_of(Err) == 24)
#assert(offset_of(Err, code) == 0)
#assert(offset_of(Err, at) == 8)
#assert(offset_of(Err, message) == 16)

// Rejects signed-negative-to-size_t wraparound and lengths that cannot fit safely in Odin `int`.
@(private = "file")
MAX_C_LEN :: c.size_t(max(int) >> 1)

@(private = "file")
c_bytes :: proc "contextless" (p: [^]u8, n: c.size_t) -> (out: []u8, ok: bool) {
	if n > MAX_C_LEN {
		return nil, false
	}
	if n == 0 {
		return nil, true
	}
	if p == nil {
		return nil, false
	}
	return p[:int(n)], true
}

@(private = "file")
c_string :: proc "contextless" (p: [^]u8, n: c.size_t) -> (out: string, ok: bool) {
	b, valid := c_bytes(p, n)
	if !valid {
		return "", false
	}
	return string(b), true
}

@(private = "file")
format_id_from_c :: proc "contextless" (v: u32) -> (id: engine.Format_Id, ok: bool) {
	if v >= u32(len(engine.Format_Id)) {
		return {}, false
	}
	return engine.Format_Id(v), true
}

@(private = "file")
facts_to_u16 :: #force_inline proc "contextless" (f: tape.Facts) -> u16 {
	return u16(transmute(u32)f)
}

@(private = "file")
caps_to_u32 :: #force_inline proc "contextless" (c_val: tape.Caps) -> u32 {
	return transmute(u32)c_val
}

@(private = "file")
budget_from_c :: proc "contextless" (b: ^Budget) -> tape.Budget {
	if b == nil {
		return {}
	}
	return {
		depth     = b.depth,
		nodes     = b.nodes,
		memory    = b.memory,
		steps     = b.steps,
		expansion = b.expansion,
	}
}

@(private = "file")
arena_allocator :: #force_inline proc(a: ^Arena) -> runtime.Allocator {
	return mem.dynamic_arena_allocator(&a.dyn)
}

@(private = "file")
arena_cstring :: proc(a: ^Arena, msg: string, fallback: cstring) -> cstring {
	if len(msg) == 0 {
		return fallback
	}
	if a == nil {
		return fallback
	}
	buf, aerr := make([]u8, len(msg) + 1, arena_allocator(a))
	if aerr != nil || len(buf) < len(msg) + 1 {
		return fallback
	}
	copy(buf, msg)
	buf[len(msg)] = 0
	return cstring(raw_data(buf))
}

@(private = "file")
err_ok :: #force_inline proc "contextless" () -> Err {
	return {code = .Ok, at = tape.NO_BYTE, message = nil}
}

@(private = "file")
err_static :: #force_inline proc "contextless" (code: Err_Code, msg: cstring, at := tape.NO_BYTE) -> Err {
	return {code = code, at = at, message = msg}
}

@(private = "file")
err_from_tape :: proc(a: ^Arena, e: tape.Error, src: []u8, fmt_handle: ^tape.Format) -> Err {
	buf: [256]u8
	msg := tape.error_message(buf[:], e, src, fmt_handle)
	switch v in e {
	case tape.Fault:
		return {code = .Syntax, at = v.at, message = arena_cstring(a, msg, "syntax error")}
	case tape.Exceeded:
		return {code = .Budget, at = v.at, message = arena_cstring(a, msg, "budget exceeded")}
	case runtime.Allocator_Error:
		return err_static(.No_Memory, "out of memory")
	case tape.Bad_Option:
		return {code = .Invalid_Arg, at = tape.NO_BYTE, message = arena_cstring(a, msg, "invalid option")}
	case tape.Piece_Gap:
		return {code = .Invalid_Arg, at = v.at, message = arena_cstring(a, msg, "piece gap")}
	}
	return err_static(.Syntax, "read error")
}

@(private = "file")
err_from_write :: proc(a: ^Arena, e: ops_write.Error) -> Err {
	switch v in e {
	case ops_write.Refused:
		switch v.why {
		case .No_Spelling:
			return err_static(.Unspellable, "target format cannot spell value")
		case .Not_A_Table:
			return err_static(.Unspellable, "value is not a table")
		case .Row_Keys:
			return err_static(.Unspellable, "row keys do not match header")
		case .Partial:
			return err_static(.Unspellable, "cannot write partial document")
		case .Malformed:
			return err_static(.Unspellable, "malformed token sequence")
		}
		return err_static(.Unspellable, "write refused")
	case runtime.Allocator_Error:
		return err_static(.No_Memory, "out of memory")
	case tape.Bad_Option:
		return {code = .Invalid_Arg, at = tape.NO_BYTE, message = arena_cstring(a, v.option, "invalid write option")}
	case io.Error:
		return err_static(.Unspellable, "write error")
	}
	return err_static(.Unspellable, "write error")
}

@(private = "file")
err_from_edit :: proc(a: ^Arena, e: edit.Error) -> Err {
	switch v in e {
	case edit.Refusal:
		return {code = .Edit_Refused, at = v.at, message = arena_cstring(a, v.detail, "edit refused")}
	case tape.Fault:
		return {code = .Syntax, at = v.at, message = arena_cstring(a, tape.fault_rule(v).message, "syntax error")}
	case tape.Exceeded:
		return {code = .Budget, at = v.at, message = "budget exceeded"}
	case tape.Bad_Option:
		return {code = .Invalid_Arg, at = tape.NO_BYTE, message = arena_cstring(a, v.option, "invalid edit option")}
	case runtime.Allocator_Error:
		return err_static(.No_Memory, "out of memory")
	}
	return err_static(.Edit_Refused, "edit refused")
}

// =========================================================================
// Arena lifecycle
// =========================================================================

@(export)
stury_arena_new :: proc "c" () -> ^Arena {
	context = runtime.default_context()
	backing := runtime.default_allocator()
	a, err := new(Arena, backing)
	if err != nil {
		return nil
	}
	a.backing = backing
	mem.dynamic_arena_init(&a.dyn, backing, backing)
	return a
}

@(export)
stury_arena_reset :: proc "c" (a: ^Arena) {
	if a == nil {
		return
	}
	context = runtime.default_context()
	mem.dynamic_arena_reset(&a.dyn)
}

@(export)
stury_arena_free :: proc "c" (a: ^Arena) {
	if a == nil {
		return
	}
	context = runtime.default_context()
	backing := a.backing
	mem.dynamic_arena_destroy(&a.dyn)
	free(a, backing)
}

// =========================================================================
// Format lookup, detection, and capabilities
// =========================================================================

@(export)
stury_format_by_name :: proc "c" (name: [^]u8, n: c.size_t) -> u32 {
	s, ok := c_string(name, n)
	if !ok || len(s) == 0 {
		return FORMAT_UNKNOWN
	}
	entry, found := engine.format_by_name(s)
	if !found {
		return FORMAT_UNKNOWN
	}
	return u32(entry.id)
}

@(export)
stury_format_of_path :: proc "c" (path: [^]u8, n: c.size_t) -> u32 {
	s, ok := c_string(path, n)
	if !ok || len(s) == 0 {
		return FORMAT_UNKNOWN
	}
	entry, _, found := engine.format_of_path(s)
	if !found {
		return FORMAT_UNKNOWN
	}
	return u32(entry.id)
}

@(export)
stury_format_detect :: proc "c" (src: [^]u8, n: c.size_t) -> u32 {
	context = runtime.default_context()
	bytes, ok := c_bytes(src, n)
	if !ok || len(bytes) == 0 {
		return FORMAT_UNKNOWN
	}
	entry, _, found := engine.detect_format(bytes, runtime.default_allocator())
	if !found {
		return FORMAT_UNKNOWN
	}
	return u32(entry.id)
}

@(export)
stury_format_caps :: proc "c" (fmt_id: u32) -> u32 {
	id, ok := format_id_from_c(fmt_id)
	if !ok {
		return 0
	}
	h := engine.format_handle_of_id(id)
	if h == nil {
		return 0
	}
	return caps_to_u32(h.caps)
}

@(export)
stury_format_facts :: proc "c" (fmt_id: u32) -> u16 {
	id, ok := format_id_from_c(fmt_id)
	if !ok {
		return 0
	}
	h := engine.format_handle_of_id(id)
	if h == nil {
		return 0
	}
	return facts_to_u16(h.facts)
}

// =========================================================================
// Validate, build, document inspection, write, and convert
// =========================================================================

@(export)
stury_validate :: proc "c" (a: ^Arena, src: [^]u8, n: c.size_t, fmt_id: u32, budget: ^Budget) -> Err {
	context = runtime.default_context()
	bytes, ok := c_bytes(src, n)
	if !ok {
		return err_static(.Invalid_Arg, "invalid input buffer or length")
	}
	id, fmt_ok := format_id_from_c(fmt_id)
	if !fmt_ok {
		return err_static(.Invalid_Arg, "unknown format id")
	}
	spec := engine.spec_of_id(id)
	opts := tape.Options{budget = budget_from_c(budget)}
	rerr := engine.validate(bytes, spec, opts, runtime.default_allocator())
	if rerr != nil {
		return err_from_tape(a, rerr, bytes, engine.format_handle_of_id(id))
	}
	return err_ok()
}

@(export)
stury_build :: proc "c" (
	a: ^Arena,
	src: [^]u8,
	n: c.size_t,
	fmt_id: u32,
	budget: ^Budget,
	out: ^^tape.Document,
) -> Err {
	context = runtime.default_context()
	if out != nil {
		out^ = nil
	}
	if out == nil {
		return err_static(.Invalid_Arg, "null output document pointer")
	}
	bytes, ok := c_bytes(src, n)
	if !ok {
		return err_static(.Invalid_Arg, "invalid input buffer or length")
	}
	id, fmt_ok := format_id_from_c(fmt_id)
	if !fmt_ok {
		return err_static(.Invalid_Arg, "unknown format id")
	}
	heap_alloc := runtime.default_allocator()
	opts := tape.Options {
		budget  = budget_from_c(budget),
		scratch = heap_alloc,
	}
	doc, rerr := engine.build(bytes, engine.spec_of_id(id), opts, heap_alloc)
	if rerr != nil {
		return err_from_tape(a, rerr, bytes, engine.format_handle_of_id(id))
	}
	doc_ptr, aerr := new(tape.Document, heap_alloc)
	if aerr != nil {
		tape.destroy_document(&doc)
		return err_static(.No_Memory, "out of memory")
	}
	doc_ptr^ = doc
	out^ = doc_ptr
	return err_ok()
}

@(export)
stury_doc_free :: proc "c" (doc: ^tape.Document) {
	if doc == nil {
		return
	}
	context = runtime.default_context()
	alloc := doc.allocator
	tape.destroy_document(doc)
	if alloc.procedure != nil {
		free(doc, alloc)
	}
}

@(export)
stury_doc_facts :: proc "c" (doc: ^tape.Document) -> u16 {
	if doc == nil {
		return 0
	}
	return facts_to_u16(doc.present)
}

@(export)
stury_doc_node_count :: proc "c" (doc: ^tape.Document) -> c.size_t {
	if doc == nil {
		return 0
	}
	return c.size_t(len(doc.nodes))
}

@(export)
stury_write :: proc "c" (
	a: ^Arena,
	doc: ^tape.Document,
	to: u32,
	out: ^[^]u8,
	out_len: ^c.size_t,
	dropped: ^u16,
) -> Err {
	context = runtime.default_context()
	if out != nil {
		out^ = nil
	}
	if out_len != nil {
		out_len^ = 0
	}
	if dropped != nil {
		dropped^ = 0
	}
	if a == nil {
		return err_static(.Invalid_Arg, "null arena")
	}
	if doc == nil {
		return err_static(.Invalid_Arg, "null document")
	}
	if out == nil || out_len == nil {
		return err_static(.Invalid_Arg, "null output pointer")
	}
	id, fmt_ok := format_id_from_c(to)
	if !fmt_ok {
		return err_static(.Invalid_Arg, "unknown target format id")
	}
	text, drop, werr := engine.write(doc, engine.spec_of_id(id), {}, arena_allocator(a))
	if werr != nil {
		return err_from_write(a, werr)
	}
	out^ = raw_data(text)
	out_len^ = c.size_t(len(text))
	if dropped != nil {
		dropped^ = facts_to_u16(drop)
	}
	return err_ok()
}

@(export)
stury_convert :: proc "c" (
	a: ^Arena,
	src: [^]u8,
	n: c.size_t,
	from: u32,
	to: u32,
	budget: ^Budget,
	out: ^[^]u8,
	out_len: ^c.size_t,
	dropped: ^u16,
) -> Err {
	context = runtime.default_context()
	if out != nil {
		out^ = nil
	}
	if out_len != nil {
		out_len^ = 0
	}
	if dropped != nil {
		dropped^ = 0
	}
	if a == nil {
		return err_static(.Invalid_Arg, "null arena")
	}
	if out == nil || out_len == nil {
		return err_static(.Invalid_Arg, "null output pointer")
	}
	bytes, ok := c_bytes(src, n)
	if !ok {
		return err_static(.Invalid_Arg, "invalid input buffer or length")
	}
	from_id, from_ok := format_id_from_c(from)
	if !from_ok {
		return err_static(.Invalid_Arg, "unknown source format id")
	}
	to_id, to_ok := format_id_from_c(to)
	if !to_ok {
		return err_static(.Invalid_Arg, "unknown target format id")
	}
	heap_alloc := runtime.default_allocator()
	doc, rerr := engine.build(bytes, engine.spec_of_id(from_id), {budget = budget_from_c(budget)}, heap_alloc)
	if rerr != nil {
		return err_from_tape(a, rerr, bytes, engine.format_handle_of_id(from_id))
	}
	defer tape.destroy_document(&doc)

	text, drop, werr := engine.write(&doc, engine.spec_of_id(to_id), {}, arena_allocator(a))
	if werr != nil {
		return err_from_write(a, werr)
	}
	out^ = raw_data(text)
	out_len^ = c.size_t(len(text))
	if dropped != nil {
		dropped^ = facts_to_u16(drop)
	}
	return err_ok()
}

// =========================================================================
// JSON Schema 2020-12 compile & streaming check
// =========================================================================

@(export)
stury_schema_compile :: proc "c" (
	a: ^Arena,
	schema_src: [^]u8,
	schema_len: c.size_t,
	out: ^^schema_pkg.Compiled,
) -> Err {
	context = runtime.default_context()
	if out != nil {
		out^ = nil
	}
	if out == nil {
		return err_static(.Invalid_Arg, "null output schema pointer")
	}
	bytes, ok := c_bytes(schema_src, schema_len)
	if !ok {
		return err_static(.Invalid_Arg, "invalid schema buffer or length")
	}
	compiled, serr := schema_pkg.compile_json(bytes, {}, runtime.default_allocator())
	if serr.kind != .None {
		defer schema_pkg.error_destroy(&serr)
		if serr.kind == .No_Memory {
			return err_static(.No_Memory, "out of memory")
		}
		code := Err_Code.Invalid_Arg if serr.kind == .Bad_Option else .Syntax
		msg := serr.message if len(serr.message) > 0 else serr.keyword
		return {code = code, at = serr.at, message = arena_cstring(a, msg, "schema compile error")}
	}
	out^ = compiled
	return err_ok()
}

@(export)
stury_schema_free :: proc "c" (s: ^schema_pkg.Compiled) {
	if s == nil {
		return
	}
	context = runtime.default_context()
	schema_pkg.destroy(s)
}

@(export)
stury_schema_check :: proc "c" (
	a: ^Arena,
	s: ^schema_pkg.Compiled,
	src: [^]u8,
	n: c.size_t,
	fmt_id: u32,
	budget: ^Budget,
	out_valid: ^bool,
) -> Err {
	context = runtime.default_context()
	if out_valid != nil {
		out_valid^ = false
	}
	if s == nil {
		return err_static(.Invalid_Arg, "null schema")
	}
	bytes, ok := c_bytes(src, n)
	if !ok {
		return err_static(.Invalid_Arg, "invalid input buffer or length")
	}
	id, fmt_ok := format_id_from_c(fmt_id)
	if !fmt_ok {
		return err_static(.Invalid_Arg, "unknown format id")
	}
	heap_alloc := runtime.default_allocator()
	copts := schema_check.Options {
		dups   = s.opts.dups,
		budget = budget_from_c(budget) if budget != nil else s.opts.budget,
	}
	res := engine.check_schema(bytes, engine.spec_of_id(id), &s.plan, copts, nil, heap_alloc)
	defer schema_check.result_destroy(&res)

	if res.valid {
		if out_valid != nil {
			out_valid^ = true
		}
		return err_ok()
	}
	if res.walk_err != nil {
		return err_from_tape(a, res.walk_err, bytes, engine.format_handle_of_id(id))
	}
	if res.err.walk_err != nil {
		return err_from_tape(a, res.err.walk_err, bytes, engine.format_handle_of_id(id))
	}
	if res.err.kind == .No_Memory {
		return err_static(.No_Memory, "out of memory")
	}
	if res.err.kind == .Bad_Option {
		return {code = .Invalid_Arg, at = tape.NO_BYTE, message = arena_cstring(a, res.err.keyword, "invalid option")}
	}
	if res.err.kind == .Unsupported {
		return {code = .Unsupported, at = tape.NO_BYTE, message = arena_cstring(a, res.err.keyword, "unsupported schema feature")}
	}
	if res.err.kind == .Exceeded {
		at := res.err.at if res.err.at != 0 else tape.NO_BYTE
		return {code = .Budget, at = at, message = arena_cstring(a, res.err.expected, "budget exceeded")}
	}
	msg := res.err.expected
	if len(msg) == 0 {
		msg = res.err.keyword
	}
	return {code = .Schema_Invalid, at = res.err.at, message = arena_cstring(a, msg, "schema validation failed")}
}

// =========================================================================
// Format-preserving overlay editing (RFC 6901 JSON Pointer paths)
// =========================================================================

@(private = "file")
parse_pointer_index :: proc "contextless" (seg: string) -> (idx: int, ok: bool) {
	if len(seg) == 0 {
		return 0, false
	}
	if len(seg) > 1 && seg[0] == '0' {
		return 0, false
	}
	v: u64
	for i in 0 ..< len(seg) {
		ch := seg[i]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		d := u64(ch - '0')
		if v > (u64(max(int)) - d) / 10 {
			return 0, false
		}
		v = v * 10 + d
	}
	return int(v), true
}

@(private = "file")
unescape_pointer_seg :: proc(seg: string, alloc: runtime.Allocator) -> (out: string, owned: bool, err_code: Err_Code) {
	has_tilde := false
	for i in 0 ..< len(seg) {
		if seg[i] == '~' {
			has_tilde = true
			break
		}
	}
	if !has_tilde {
		return seg, false, .Ok
	}
	buf, aerr := make([dynamic]u8, 0, len(seg), alloc)
	if aerr != nil {
		return "", false, .No_Memory
	}
	for i := 0; i < len(seg); i += 1 {
		ch := seg[i]
		if ch == '~' {
			if i + 1 >= len(seg) {
				delete(buf)
				return "", false, .Invalid_Arg
			}
			next := seg[i + 1]
			if next == '0' {
				ch = '~'
			} else if next == '1' {
				ch = '/'
			} else {
				delete(buf)
				return "", false, .Invalid_Arg
			}
			i += 1
		}
		if _, perr := append(&buf, ch); perr != nil {
			delete(buf)
			return "", false, .No_Memory
		}
	}
	return string(buf[:]), true, .Ok
}

// Parses an RFC 6901 JSON Pointer (`""` for root, `"/a/0/b"`) into concrete `tape.Step`s,
// resolving array indices vs object keys against `ov`'s current structure.
@(private = "file")
resolve_pointer_steps :: proc(
	ov: ^edit.Overlay,
	pointer: string,
	alloc: runtime.Allocator,
) -> (
	steps: []tape.Step,
	owned_names: [dynamic]string,
	err_code: Err_Code,
) {
	if len(pointer) == 0 {
		return nil, {}, .Ok
	}
	if pointer[0] != '/' {
		return nil, {}, .Invalid_Arg
	}
	out_steps, serr := make([dynamic]tape.Step, 0, 8, alloc)
	if serr != nil {
		return nil, {}, .No_Memory
	}
	owned_names = make([dynamic]string, 0, 4, alloc)
	defer if err_code != .Ok {
		delete(out_steps)
		for s in owned_names {
			delete(s, alloc)
		}
		delete(owned_names)
		owned_names = {}
	}

	cur_h := ov.root
	cur_base := tape.ROOT
	have_cur := true

	pos := 1
	for {
		end := pos
		for end < len(pointer) && pointer[end] != '/' {
			end += 1
		}
		raw_seg := pointer[pos:end]
		seg, owned, uerr := unescape_pointer_seg(raw_seg, alloc)
		if uerr != .Ok {
			return nil, owned_names, uerr
		}
		if owned {
			if _, aerr := append(&owned_names, seg); aerr != nil {
				delete(seg, alloc)
				return nil, owned_names, .No_Memory
			}
		}

		cur_kind := tape.Kind.Null
		if have_cur {
			if cur_h != edit.NO_HANDLE {
				cur_kind = edit.node_kind(ov, cur_h)
			} else if cur_base != tape.NO_NODE && ov.base != nil && int(cur_base) < len(ov.base.nodes) {
				cur_kind = ov.base.nodes[cur_base].kind
			}
		}

		if cur_kind == .Array {
			if idx, is_idx := parse_pointer_index(seg); is_idx {
				if _, aerr := append(&out_steps, tape.Step(tape.Index(idx))); aerr != nil {
					return nil, owned_names, .No_Memory
				}
				if have_cur {
					if cur_h != edit.NO_HANDLE {
						nh, nb, found := edit.lookup_element(ov, cur_h, idx)
						cur_h, cur_base, have_cur = nh, nb, found
					} else if cur_base != tape.NO_NODE {
						nb, p := tape.element(tape.Reader{doc = ov.base}, cur_base, idx)
						if p == .Found {
							cur_h = ov.by_base[nb] or_else edit.NO_HANDLE
							cur_base = nb
							have_cur = true
						} else {
							have_cur = false
						}
					}
				}
			} else {
				if _, aerr := append(&out_steps, tape.Step(tape.Name(seg))); aerr != nil {
					return nil, owned_names, .No_Memory
				}
				have_cur = false
			}
		} else {
			if _, aerr := append(&out_steps, tape.Step(tape.Name(seg))); aerr != nil {
				return nil, owned_names, .No_Memory
			}
			if have_cur && cur_kind == .Object {
				if cur_h != edit.NO_HANDLE {
					nh, nb, found := edit.lookup_member(ov, cur_h, seg)
					cur_h, cur_base, have_cur = nh, nb, found
				} else if cur_base != tape.NO_NODE {
					nb, p := tape.member(tape.Reader{doc = ov.base}, cur_base, seg)
					if p == .Found {
						cur_h = ov.by_base[nb] or_else edit.NO_HANDLE
						cur_base = nb
						have_cur = true
					} else {
						have_cur = false
					}
				}
			} else {
				have_cur = false
			}
		}

		if end >= len(pointer) {
			break
		}
		pos = end + 1
	}

	return out_steps[:], owned_names, .Ok
}

@(private = "file")
free_pointer_steps :: proc(steps: []tape.Step, owned_names: ^[dynamic]string, alloc: runtime.Allocator) {
	delete(steps, alloc)
	for s in owned_names^ {
		delete(s, alloc)
	}
	delete(owned_names^)
}

@(export)
stury_overlay_new :: proc "c" (a: ^Arena, doc: ^tape.Document, out: ^^edit.Overlay) -> Err {
	context = runtime.default_context()
	if out != nil {
		out^ = nil
	}
	if doc == nil {
		return err_static(.Invalid_Arg, "null document")
	}
	if out == nil {
		return err_static(.Invalid_Arg, "null output overlay pointer")
	}
	alloc := runtime.default_allocator()
	ov, aerr := new(edit.Overlay, alloc)
	if aerr != nil {
		return err_static(.No_Memory, "out of memory")
	}
	if ierr := edit.init(ov, doc, alloc); ierr != nil {
		free(ov, alloc)
		return err_from_edit(a, ierr)
	}
	out^ = ov
	return err_ok()
}

@(export)
stury_overlay_free :: proc "c" (ov: ^edit.Overlay) {
	if ov == nil {
		return
	}
	context = runtime.default_context()
	alloc := ov.allocator
	edit.destroy(ov)
	if alloc.procedure != nil {
		free(ov, alloc)
	}
}

@(private = "file")
overlay_set_value :: proc(
	a: ^Arena,
	ov: ^edit.Overlay,
	pointer: [^]u8,
	pointer_len: c.size_t,
	val: edit.Edit_Value,
) -> Err {
	if ov == nil {
		return err_static(.Invalid_Arg, "null overlay")
	}
	ptr, ok := c_string(pointer, pointer_len)
	if !ok {
		return err_static(.Invalid_Arg, "invalid pointer buffer or length")
	}
	alloc := runtime.default_allocator()
	steps, owned, perr := resolve_pointer_steps(ov, ptr, alloc)
	if perr != .Ok {
		return err_static(perr, "out of memory" if perr == .No_Memory else "invalid JSON Pointer")
	}
	defer free_pointer_steps(steps, &owned, alloc)

	if _, serr := edit.set_path(ov, steps, val); serr != nil {
		return err_from_edit(a, serr)
	}
	return err_ok()
}

@(export)
stury_overlay_set_raw :: proc "c" (
	a: ^Arena,
	ov: ^edit.Overlay,
	pointer: [^]u8,
	pointer_len: c.size_t,
	raw: [^]u8,
	raw_len: c.size_t,
) -> Err {
	context = runtime.default_context()
	raw_str, ok := c_string(raw, raw_len)
	if !ok {
		return err_static(.Invalid_Arg, "invalid raw value buffer or length")
	}
	return overlay_set_value(a, ov, pointer, pointer_len, edit.val_raw(raw_str))
}

@(export)
stury_overlay_set_string :: proc "c" (
	a: ^Arena,
	ov: ^edit.Overlay,
	pointer: [^]u8,
	pointer_len: c.size_t,
	val: [^]u8,
	val_len: c.size_t,
) -> Err {
	context = runtime.default_context()
	val_str, ok := c_string(val, val_len)
	if !ok {
		return err_static(.Invalid_Arg, "invalid string buffer or length")
	}
	return overlay_set_value(a, ov, pointer, pointer_len, edit.val_string(val_str))
}

@(export)
stury_overlay_set_int :: proc "c" (
	a: ^Arena,
	ov: ^edit.Overlay,
	pointer: [^]u8,
	pointer_len: c.size_t,
	val: i64,
) -> Err {
	context = runtime.default_context()
	return overlay_set_value(a, ov, pointer, pointer_len, edit.val_int(val))
}

@(export)
stury_overlay_del_path :: proc "c" (
	a: ^Arena,
	ov: ^edit.Overlay,
	pointer: [^]u8,
	pointer_len: c.size_t,
) -> Err {
	context = runtime.default_context()
	if ov == nil {
		return err_static(.Invalid_Arg, "null overlay")
	}
	ptr, ok := c_string(pointer, pointer_len)
	if !ok {
		return err_static(.Invalid_Arg, "invalid pointer buffer or length")
	}
	alloc := runtime.default_allocator()
	steps, owned, perr := resolve_pointer_steps(ov, ptr, alloc)
	if perr != .Ok {
		return err_static(perr, "out of memory" if perr == .No_Memory else "invalid JSON Pointer")
	}
	defer free_pointer_steps(steps, &owned, alloc)

	if derr := edit.del_path(ov, steps); derr != nil {
		return err_from_edit(a, derr)
	}
	return err_ok()
}

@(export)
stury_overlay_commit :: proc "c" (
	a: ^Arena,
	ov: ^edit.Overlay,
	target: u32,
	reflow: bool,
	out: ^[^]u8,
	out_len: ^c.size_t,
	dropped: ^u16,
) -> Err {
	context = runtime.default_context()
	if out != nil {
		out^ = nil
	}
	if out_len != nil {
		out_len^ = 0
	}
	if dropped != nil {
		dropped^ = 0
	}
	if a == nil {
		return err_static(.Invalid_Arg, "null arena")
	}
	if ov == nil {
		return err_static(.Invalid_Arg, "null overlay")
	}
	if out == nil || out_len == nil {
		return err_static(.Invalid_Arg, "null output pointer")
	}
	target_spec: engine.Spec = nil
	if target != FORMAT_UNKNOWN {
		id, fmt_ok := format_id_from_c(target)
		if !fmt_ok {
			return err_static(.Invalid_Arg, "unknown target format id")
		}
		target_spec = engine.spec_of_id(id)
	}
	cres, cerr := engine.edit_commit(ov, target_spec, {reflow = reflow}, runtime.default_allocator())
	if cerr != nil {
		return err_from_edit(a, cerr)
	}
	defer edit.destroy_commit_result(&cres)

	if len(cres.bytes) > 0 {
		copied, aerr := make([]u8, len(cres.bytes), arena_allocator(a))
		if aerr != nil {
			return err_static(.No_Memory, "out of memory")
		}
		copy(copied, cres.bytes)
		out^ = raw_data(copied)
		out_len^ = c.size_t(len(copied))
	}
	if dropped != nil {
		dropped^ = facts_to_u16(cres.dropped)
	}
	return err_ok()
}

// =========================================================================
// jq compile & callback-based evaluation
// =========================================================================

@(export)
stury_jq_compile :: proc "c" (
	a: ^Arena,
	src: [^]u8,
	n: c.size_t,
	out: ^^stury.Jq_Program,
) -> Err {
	context = runtime.default_context()
	if out != nil {
		out^ = nil
	}
	if out == nil {
		return err_static(.Invalid_Arg, "null output program pointer")
	}
	text, ok := c_string(src, n)
	if !ok {
		return err_static(.Invalid_Arg, "invalid jq source buffer or length")
	}
	alloc := runtime.default_allocator()
	prog, errs := stury.jq_compile(text, {}, alloc)
	if len(errs) > 0 {
		msg := stury.jq_compile_error_message(errs, alloc)
		defer delete(msg, alloc)
		at := u64(errs[0].loc.start) if errs[0].loc.start >= 0 else tape.NO_BYTE
		res_err := Err{code = .Syntax, at = at, message = arena_cstring(a, msg, "jq compile error")}
		stury.jq_destroy(prog)
		return res_err
	}
	out^ = prog
	return err_ok()
}

@(export)
stury_jq_free :: proc "c" (prog: ^stury.Jq_Program) {
	if prog == nil {
		return
	}
	context = runtime.default_context()
	stury.jq_destroy(prog)
}

@(private = "file")
Jq_C_Bridge :: struct {
	fn:  Emit_Fn,
	ctx: rawptr,
}

@(private = "file")
jq_c_emit :: proc(data: rawptr, bytes: []u8) -> bool {
	b := (^Jq_C_Bridge)(data)
	if b.fn == nil {
		return true
	}
	return b.fn(b.ctx, raw_data(bytes), c.size_t(len(bytes)))
}

@(export)
stury_jq_eval :: proc "c" (
	a: ^Arena,
	prog: ^stury.Jq_Program,
	src: [^]u8,
	n: c.size_t,
	fmt_id: u32,
	budget: ^Budget,
	emit: Emit_Fn,
	emit_ctx: rawptr,
) -> Err {
	context = runtime.default_context()
	if prog == nil {
		return err_static(.Invalid_Arg, "null jq program")
	}
	bytes, ok := c_bytes(src, n)
	if !ok {
		return err_static(.Invalid_Arg, "invalid input buffer or length")
	}
	id, fmt_ok := format_id_from_c(fmt_id)
	if !fmt_ok {
		return err_static(.Invalid_Arg, "unknown format id")
	}
	bridge := Jq_C_Bridge{fn = emit, ctx = emit_ctx}
	res := stury.jq_run(
		prog,
		bytes,
		engine.spec_of_id(id),
		jq_c_emit,
		&bridge,
		{budget = budget_from_c(budget)},
		runtime.default_allocator(),
	)
	defer stury.jq_run_result_destroy(&res)

	switch res.err {
	case .None:
		return err_ok()
	case .Stopped:
		return err_static(.Stopped, "stopped by callback")
	case .Read_Error:
		return err_from_tape(a, res.read_err, bytes, engine.format_handle_of_id(id))
	case .Exceeded:
		if res.read_err != nil {
			return err_from_tape(a, res.read_err, bytes, engine.format_handle_of_id(id))
		}
		return {code = .Budget, at = tape.NO_BYTE, message = arena_cstring(a, res.message, "budget exceeded")}
	case .No_Memory:
		return err_static(.No_Memory, "out of memory")
	case .Bad_Option:
		return {code = .Invalid_Arg, at = tape.NO_BYTE, message = arena_cstring(a, res.message, "invalid argument")}
	case .Write_Error:
		return err_static(.Unspellable, "failed to format query output")
	case .Halted:
		return err_static(.Halted, "jq program halted")
	case .Failed, .Tainted:
		return {code = .Query_Runtime, at = tape.NO_BYTE, message = arena_cstring(a, res.message, "jq runtime error")}
	}
	return err_static(.Query_Runtime, "jq runtime error")
}

// =========================================================================
// RFC 9535 JSONPath compile & callback-based evaluation
// =========================================================================

@(export)
stury_jsonpath_compile :: proc "c" (
	a: ^Arena,
	src: [^]u8,
	n: c.size_t,
	out: ^^stury.Jsonpath_Program,
) -> Err {
	context = runtime.default_context()
	if out != nil {
		out^ = nil
	}
	if out == nil {
		return err_static(.Invalid_Arg, "null output program pointer")
	}
	text, ok := c_string(src, n)
	if !ok {
		return err_static(.Invalid_Arg, "invalid JSONPath source buffer or length")
	}
	prog, cerr := stury.jsonpath_compile(text, {}, runtime.default_allocator())
	if cerr.kind != .None {
		code := Err_Code.Syntax
		switch cerr.kind {
		case .None:
		case .Syntax, .Type:
			code = .Syntax
		case .Depth:
			code = .Budget
		case .Memory:
			code = .No_Memory
		}
		at := u64(cerr.offset) if cerr.offset >= 0 else tape.NO_BYTE
		return {code = code, at = at, message = arena_cstring(a, cerr.message, "JSONPath compile error")}
	}
	out^ = prog
	return err_ok()
}

@(export)
stury_jsonpath_free :: proc "c" (prog: ^stury.Jsonpath_Program) {
	if prog == nil {
		return
	}
	context = runtime.default_context()
	stury.jsonpath_destroy(prog)
}

@(private = "file")
Jsonpath_C_Bridge :: struct {
	fn:         Jsonpath_Emit_Fn,
	ctx:        rawptr,
	want_paths: bool,
}

@(private = "file")
jsonpath_c_emit :: proc(data: rawptr, bytes: []u8, norm_path: string) -> bool {
	b := (^Jsonpath_C_Bridge)(data)
	if b.fn == nil {
		return true
	}
	np_ptr: [^]u8 = nil
	np_len: c.size_t = 0
	if b.want_paths {
		np_ptr = raw_data(norm_path)
		np_len = c.size_t(len(norm_path))
	}
	return b.fn(b.ctx, raw_data(bytes), c.size_t(len(bytes)), np_ptr, np_len)
}

@(export)
stury_jsonpath_eval :: proc "c" (
	a: ^Arena,
	prog: ^stury.Jsonpath_Program,
	src: [^]u8,
	n: c.size_t,
	fmt_id: u32,
	budget: ^Budget,
	want_paths: bool,
	emit: Jsonpath_Emit_Fn,
	emit_ctx: rawptr,
) -> Err {
	context = runtime.default_context()
	if prog == nil {
		return err_static(.Invalid_Arg, "null JSONPath program")
	}
	bytes, ok := c_bytes(src, n)
	if !ok {
		return err_static(.Invalid_Arg, "invalid input buffer or length")
	}
	id, fmt_ok := format_id_from_c(fmt_id)
	if !fmt_ok {
		return err_static(.Invalid_Arg, "unknown format id")
	}
	bridge := Jsonpath_C_Bridge{fn = emit, ctx = emit_ctx, want_paths = want_paths}
	res := stury.jsonpath_eval(
		prog,
		bytes,
		engine.spec_of_id(id),
		jsonpath_c_emit,
		&bridge,
		{want_paths = want_paths, budget = budget_from_c(budget)},
		runtime.default_allocator(),
	)
	switch res.err {
	case .None:
		return err_ok()
	case .Stopped:
		return err_static(.Stopped, "stopped by callback")
	case .Read_Error:
		return err_from_tape(a, res.read_err, bytes, engine.format_handle_of_id(id))
	case .Exceeded:
		if res.read_err != nil {
			return err_from_tape(a, res.read_err, bytes, engine.format_handle_of_id(id))
		}
		return err_static(.Budget, "budget exceeded")
	case .No_Memory:
		return err_static(.No_Memory, "out of memory")
	case .Bad_Option:
		return err_static(.Invalid_Arg, "invalid argument")
	case .Write_Error:
		return err_static(.Unspellable, "failed to format query output")
	case .Halted:
		return err_static(.Halted, "evaluation halted")
	case .Failed, .Tainted:
		return err_static(.Query_Runtime, "JSONPath evaluation error")
	}
	return err_static(.Query_Runtime, "JSONPath evaluation error")
}
