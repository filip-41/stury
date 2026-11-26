package json

import "base:runtime"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import ops_write "stury:lib/ops/write"

// Byte-preserving JSON / JSONC / JSON5 editing over `edit.Overlay`, reusing `json.write` (SIMD escaping,
// `.Bytes` base64, JSON5 styles, comments) and `walk_fragment` incremental tape splicing.

Overlay :: edit.Overlay
Handle :: edit.Handle
Edit_Value :: edit.Edit_Value
Edit_Options :: edit.Options
Edit_Error :: edit.Error
Commit_Result :: edit.Commit_Result

edit_init :: proc(ov: ^Overlay, doc: ^tape.Document, allocator := context.allocator) -> Edit_Error {
	return edit.init(ov, doc, allocator)
}

edit_destroy :: proc(ov: ^Overlay) {
	edit.destroy(ov)
}

commit :: proc(
	ov: ^Overlay,
	spec: Maybe(Spec) = nil,
	opts := Edit_Options{},
	allocator := context.allocator,
) -> (
	res: Commit_Result,
	err: Edit_Error,
) {
	resolved := resolve_edit_spec(ov, spec, opts)
	ctx := Json_Edit_Ctx{spec = resolved}
	bspec := edit.Bracket_Spec {
		target          = as(resolved),
		allows_comments = resolved != .Json,
		trailing_comma  = resolved == .Json5,
		comment         = {line = "//", open = "/*", close = "*/"},
		spell_value     = json_spell_value,
		spell_key       = json_spell_key,
		validate        = json_edit_validate,
		data            = &ctx,
	}
	return edit.commit_bracket(ov, &bspec, opts, allocator)
}

commit_as :: proc(
	ov: ^Overlay,
	spec: Spec,
	opts := Edit_Options{},
	allocator := context.allocator,
) -> (
	res: Commit_Result,
	err: Edit_Error,
) {
	o := opts
	o.target = as(spec)
	return commit(ov, spec, o, allocator)
}

commit_document :: proc(
	ov: ^Overlay,
	spec: Maybe(Spec) = nil,
	opts := Edit_Options{},
	allocator := context.allocator,
) -> (
	doc: tape.Document,
	res: Commit_Result,
	err: Edit_Error,
) {
	resolved := resolve_edit_spec(ov, spec, opts)
	r := commit(ov, resolved, opts, allocator) or_return
	ctx := Json_Edit_Ctx{spec = resolved}
	eff_opts := opts
	eff_opts.target = as(resolved)
	d, serr := edit.splice_document(ov.base, &r, eff_opts, json_walk_fragment_cb, &ctx, json_full_build_cb, &ctx, allocator)
	if serr != nil {
		edit.destroy_commit_result(&r)
		return {}, {}, serr
	}
	return d, r, nil
}

commit_document_as :: proc(
	ov: ^Overlay,
	spec: Spec,
	opts := Edit_Options{},
	allocator := context.allocator,
) -> (
	doc: tape.Document,
	res: Commit_Result,
	err: Edit_Error,
) {
	o := opts
	o.target = as(spec)
	return commit_document(ov, spec, o, allocator)
}

// Walks ONLY `src[range.lo:range.hi]` as a standalone JSON/JSONC/JSON5 value and shifts all offsets by `range.lo`.
walk_fragment :: proc(
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	spec := Spec.Json,
	allocator := context.allocator,
) -> (
	ft: edit.Fragment_Tape,
	err: tape.Error,
) {
	eff_depth := ctx.budget.depth if ctx.budget.depth > 0 else u32(tape.DEFAULT_DEPTH)
	if ctx.base_depth > eff_depth {
		return {}, tape.Exceeded{kind = .Depth, at = range.lo}
	}
	avail := max(u32(1), eff_depth - ctx.base_depth)
	d := build(src[range.lo:range.hi], spec, {budget = {depth = avail}}, allocator) or_return
	sft, aerr := edit.shift_fragment_tape(&d, range.lo, 0, 0, allocator)
	if aerr != nil {
		return {}, aerr
	}
	return sft, nil
}

@(private = "file")
Json_Edit_Ctx :: struct {
	spec: Spec,
}

@(private = "file")
resolve_edit_spec :: proc "contextless" (ov: ^Overlay, spec: Maybe(Spec), opts: Edit_Options) -> Spec {
	json_spec_of :: #force_inline proc "contextless" (f: ^tape.Format) -> Spec {
		if f != nil && f.id >= tape.FORMAT_ID_JSON && f.id <= tape.FORMAT_ID_JSON + 2 {
			return Spec(f.id - tape.FORMAT_ID_JSON)
		}
		return .Json
	}
	if opts.target != nil {
		return json_spec_of(opts.target)
	}
	if s, ok := spec.?; ok {
		return s
	}
	if ov != nil && ov.base != nil {
		return json_spec_of(ov.base.format)
	}
	return .Json
}

@(private = "file")
json_walk_fragment_cb :: proc(
	data: rawptr,
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	allocator: runtime.Allocator,
) -> (edit.Fragment_Tape, tape.Error) {
	jc := (^Json_Edit_Ctx)(data)
	return walk_fragment(src, range, ctx, jc.spec, allocator)
}

@(private = "file")
json_full_build_cb :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	jc := (^Json_Edit_Ctx)(data)
	return build(src, jc.spec, {}, allocator)
}

@(private = "file")
json_edit_validate :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error {
	jc := (^Json_Edit_Ctx)(data)
	return validate(src, jc.spec, {}, allocator)
}

@(private = "file")
json_spell_key :: proc(data: rawptr, key: string, out: ^[dynamic]u8, quote: u8) -> edit.Error {
	jc := (^Json_Edit_Ctx)(data)
	if jc.spec == .Json5 && quote == 0 && json5_ident(key) {
		append(out, key)
		return nil
	}
	q := u8('\'') if (jc.spec == .Json5 && quote == '\'') else u8('"')
	edit.append_quoted_escaped(out, key, q)
	return nil
}

@(private = "file")
json5_ident :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c, i in transmute([]u8)s {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' || (i > 0 && c >= '0' && c <= '9')
		if !ok {
			return false
		}
	}
	return true
}

// Reuses `json.write` via `edit.materialize_subtree` — zero duplicate JSON tree/scalar/base64 serializer!
@(private = "file")
json_spell_value :: proc(
	data: rawptr,
	ov: ^Overlay,
	h: Handle,
	out: ^[dynamic]u8,
	indent: string,
	unit: string,
	eol: string,
	style: string,
) -> edit.Error {
	jc := (^Json_Edit_Ctx)(data)
	if n, ok := edit.get_node(ov, h); ok {
		if n.state == .Replaced && n.val.kind == .Raw {
			append(out, n.val.text)
			return nil
		}
		if n.state == .Replaced && n.val.kind == .Base_Ref && n.val.base_ref != tape.NO_NODE && len(n.facts) == 0 {
			bf := ov.base.format
			same_compat := bf != nil && (bf.id == tape.FORMAT_ID_JSON || bf == as(jc.spec))
			if same_compat {
				if blo, bhi, bok := edit.node_byte_span(ov.base, n.val.base_ref); bok && bhi <= u64(len(ov.base.src)) {
					raw := ov.base.src[blo:bhi]
					has_nl := false
					for b in raw {
						if b == '\n' {
							has_nl = true
							break
						}
					}
					if !has_nl {
						append(out, ..raw)
						return nil
					}
				}
			}
		}
		// JSON5 single-quoted string override on a replaced or base string scalar.
		if jc.spec == .Json5 && style == "single" {
			if n.state == .Replaced && n.val.kind == .String {
				edit.append_quoted_escaped(out, n.val.text, '\'')
				return nil
			}
			if n.base != tape.NO_NODE && (ov.base.nodes[n.base].kind == .String || ov.base.nodes[n.base].kind == .Plain) {
				tk := edit.decode_node_text_tmp(ov.base, n.base, ov.allocator)
				defer edit.free_tmp_text(tk, ov.allocator)
				edit.append_quoted_escaped(out, tk.text, '\'')
				return nil
			}
		}
	}

	tmp_doc := edit.materialize_subtree(ov, h, tape.NO_NODE, {
		dedup_keys        = true,
		include_root_foot = jc.spec != .Json,
	}, ov.allocator) or_return
	defer tape.destroy_document(&tmp_doc)

	wopts: Write_Options
	if len(unit) > 0 {
		if unit[0] == '\t' {
			wopts.tab = true
		} else {
			wopts.indent = u8(min(len(unit), 255))
		}
	}
	encoded, _, werr := write(&tmp_doc, jc.spec, wopts, ov.allocator)
	if werr != nil {
		#partial switch e in werr {
		case runtime.Allocator_Error:
			return e
		case ops_write.Refused:
			return edit.refuse(.Unspellable_Value, "value cannot be spelled in target JSON spec", e.node)
		}
		return edit.refuse(.Unspellable_Value, "JSON write failed")
	}
	defer delete(encoded, ov.allocator)

	// Re-indent continuation lines by `indent` and normalize line endings to `eol` when multiline.
	if len(indent) == 0 && eol == "\n" {
		append(out, ..encoded)
		return nil
	}
	start := 0
	for i := 0; i < len(encoded); i += 1 {
		if encoded[i] == '\n' {
			append(out, ..encoded[start:i])
			append(out, eol)
			append(out, indent)
			start = i + 1
		}
	}
	append(out, ..encoded[start:])
	return nil
}
