package toml

import "base:runtime"
import "core:unicode/utf8"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import ops_write "stury:lib/ops/write"

// Byte-preserving TOML 1.0 / 1.1 editing over `edit.Overlay`, reusing `toml.write` (full document reflow,
// `"""x""""` multiline string safety, valid UTF-8, `.Bytes` base64, datetimes, styles) and `walk_fragment` splicing.

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
	ctx := Toml_Edit_Ctx{spec = resolved}
	sspec := edit.Section_Spec {
		target         = as(resolved),
		v11            = resolved == .Toml_1_1,
		spell_value    = toml_spell_value,
		spell_key      = toml_spell_key,
		spell_document = toml_spell_document,
		validate       = toml_edit_validate,
		data           = &ctx,
	}
	return edit.commit_section(ov, &sspec, opts, allocator)
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
	ctx := Toml_Edit_Ctx{spec = resolved}
	eff_opts := opts
	eff_opts.target = as(resolved)
	d, serr := edit.splice_document(ov.base, &r, eff_opts, toml_walk_fragment_cb, &ctx, toml_full_build_cb, &ctx, allocator)
	if serr != nil {
		edit.destroy_commit_result(&r)
		return {}, {}, serr
	}
	return d, r, nil
}

// Walks ONLY `src[range.lo:range.hi]` as a single TOML value via a 2-byte `v=` wrapper and shifts
// every node/fact/count offset cleanly via `shift_fragment_tape`!
walk_fragment :: proc(
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	spec := Spec.Toml_1_0,
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
	sub := src[range.lo:range.hi]
	buf, aerr := make([]u8, 2 + len(sub), allocator)
	if aerr != nil {
		return {}, aerr
	}
	defer delete(buf, allocator)
	buf[0] = 'v'
	buf[1] = '='
	copy(buf[2:], sub)

	d := build(buf, spec, {budget = {depth = avail + 1}}, allocator) or_return
	// `d.nodes`: `[0]=root Object, [1]=Key("v"), [2..]=value subtree`.
	sft, serr := edit.shift_fragment_tape(&d, range.lo, 2, 2, allocator)
	if serr != nil {
		return {}, serr
	}
	return sft, nil
}

@(private = "file")
Toml_Edit_Ctx :: struct {
	spec: Spec,
}

@(private = "file")
resolve_edit_spec :: proc "contextless" (ov: ^Overlay, spec: Maybe(Spec), opts: Edit_Options) -> Spec {
	toml_spec_of :: #force_inline proc "contextless" (f: ^tape.Format) -> Spec {
		return .Toml_1_1 if (f != nil && f.id == ID + 1) else .Toml_1_0
	}
	if opts.target != nil {
		return toml_spec_of(opts.target)
	}
	if s, ok := spec.?; ok {
		return s
	}
	if ov != nil && ov.base != nil {
		return toml_spec_of(ov.base.format)
	}
	return .Toml_1_0
}

@(private = "file")
toml_walk_fragment_cb :: proc(
	data: rawptr,
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	allocator: runtime.Allocator,
) -> (edit.Fragment_Tape, tape.Error) {
	tc := (^Toml_Edit_Ctx)(data)
	return walk_fragment(src, range, ctx, tc.spec, allocator)
}

@(private = "file")
toml_full_build_cb :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	tc := (^Toml_Edit_Ctx)(data)
	return build(src, tc.spec, {}, allocator)
}

@(private = "file")
toml_edit_validate :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error {
	tc := (^Toml_Edit_Ctx)(data)
	return validate(src, tc.spec, {}, allocator)
}

@(private = "file")
toml_bare_key :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c in transmute([]u8)s {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
		if !ok {
			return false
		}
	}
	return true
}

@(private = "file")
toml_spell_key :: proc(data: rawptr, key: string, out: ^[dynamic]u8) -> edit.Error {
	_ = data
	if !utf8.valid_string(key) {
		return edit.refuse(.Bad_Name, "TOML key must be valid UTF-8")
	}
	if toml_bare_key(key) {
		append(out, key)
		return nil
	}
	edit.append_quoted_escaped(out, key, '"', escape_del = true)
	return nil
}

@(private = "file")
toml_can_literal :: proc "contextless" (s: string, multiline: bool) -> bool {
	if !utf8.valid_string(s) {
		return false
	}
	q_run := 0
	for c in transmute([]u8)s {
		if c == '\'' {
			if !multiline {
				return false
			}
			q_run += 1
			if q_run >= 3 {
				return false
			}
		} else {
			q_run = 0
		}
		if c < 0x20 && c != '\t' && !(multiline && (c == '\n' || c == '\r')) {
			return false
		}
		if c == 0x7F {
			return false
		}
	}
	// In multiline literal `'''...'''`, trailing `'` cannot exceed 2 quotes (avoid `''''''`).
	return !multiline || q_run == 0
}

// Reuses `toml.write` via `edit.materialize_subtree` for full-document `--reflow`!
@(private = "file")
toml_spell_document :: proc(data: rawptr, ov: ^Overlay, out: ^[dynamic]u8) -> edit.Error {
	tc := (^Toml_Edit_Ctx)(data)
	root_h := edit.ensure_root(ov) or_return
	tmp_doc := edit.materialize_subtree(ov, root_h, tape.ROOT, {include_root_comments = true}, ov.allocator) or_return
	defer tape.destroy_document(&tmp_doc)

	encoded, _, werr := write(&tmp_doc, tc.spec, {}, ov.allocator)
	if werr != nil {
		return toml_write_err(werr)
	}
	defer delete(encoded, ov.allocator)
	append(out, ..encoded)
	return nil
}

// Reuses `toml.write` via `edit.materialize_subtree` wrapped in `v = <val>` for scalars, arrays, and inline tables!
// Handles explicit `.Style` (`"literal"`, `"multiline"`, `"multiline_literal"`), `.Tag` datetimes, `.Bytes` base64,
// valid UTF-8, and `"""x""""` escaping automatically!
@(private = "file")
toml_spell_value :: proc(
	data: rawptr,
	ov: ^Overlay,
	h: Handle,
	out: ^[dynamic]u8,
	style: string,
	tag: string,
) -> edit.Error {
	tc := (^Toml_Edit_Ctx)(data)
	n, ok := edit.get_node(ov, h)
	if !ok {
		return edit.refuse(.Bad_Handle, "invalid handle in toml_spell_value")
	}
	if n.state == .Replaced && n.val.kind == .Raw {
		append(out, n.val.text)
		return nil
	}
	// TOML has no null.
	if edit.node_kind(ov, h) == .Null {
		return edit.refuse(.Unspellable_Value, "TOML has no null value", n.base)
	}

	// Explicit datetime `.Tag`: validate tag name and value, then emit unquoted!
	if len(tag) > 0 {
		known_dt := tag == "datetime" || tag == "date-time" || tag == "date" || tag == "time" ||
			tag == "date-local" || tag == "time-local" || tag == "datetime-local" ||
			tag == "offset-date-time" || tag == "local-date-time" || tag == "local-date" || tag == "local-time"
		if !known_dt {
			return edit.refuse(.Fact_No_Place, "unknown TOML datetime tag", n.base)
		}
		txt: string
		tmp_tk: edit.Tmp_Text
		if n.state == .Replaced && n.val.kind == .String {
			txt = n.val.text
		} else if n.base != tape.NO_NODE {
			tmp_tk = edit.decode_node_text_tmp(ov.base, n.base, ov.allocator)
			txt = tmp_tk.text
		}
		defer edit.free_tmp_text(tmp_tk, ov.allocator)
		// Validate via `toml.validate` on `v = <txt>`.
		chk := make([]u8, 4 + len(txt), ov.allocator)
		defer delete(chk, ov.allocator)
		copy(chk[:4], "v = ")
		copy(chk[4:], txt)
		if validate(chk, tc.spec, {}, ov.allocator) != nil {
			return edit.refuse(.Fact_No_Place, "invalid TOML date-time value", n.base)
		}
		append(out, txt)
		return nil
	}

	// Explicit string style overrides (`"literal"`, `"multiline"`, `"multiline_literal"`):
	if len(style) > 0 && edit.node_kind(ov, h) == .String {
		txt: string
		tmp_tk: edit.Tmp_Text
		if n.state == .Replaced && n.val.kind == .String {
			txt = n.val.text
		} else if n.base != tape.NO_NODE {
			tmp_tk = edit.decode_node_text_tmp(ov.base, n.base, ov.allocator)
			txt = tmp_tk.text
		}
		defer edit.free_tmp_text(tmp_tk, ov.allocator)
		if !utf8.valid_string(txt) {
			return edit.refuse(.Unspellable_Value, "TOML string must be valid UTF-8", n.base)
		}
		switch style {
		case "literal":
			if toml_can_literal(txt, false) {
				append(out, '\'')
				append(out, txt)
				append(out, '\'')
				return nil
			}
		case "multiline_literal":
			if toml_can_literal(txt, true) {
				append(out, "'''\n")
				append(out, txt)
				append(out, "'''")
				return nil
			}
		case "multiline":
			// Delegate safely: escape every `"` inside `"""..."""` when trailing or triple-quoted (prevents `"""x""""`!).
			append(out, "\"\"\"\n")
			toml_append_multiline_basic_body(out, txt)
			append(out, "\"\"\"")
			return nil
		}
	}

	// Materialize as a 1-member wrapper `{v: h}` with `style = "inline"` on objects so `toml.write` writes `v = <inline_val>\n`!
	mat_style := "inline" if edit.node_kind(ov, h) == .Object else ""
	tmp_doc := edit.materialize_subtree(ov, h, tape.NO_NODE, {
		wrap_key   = "v",
		root_style = mat_style,
	}, ov.allocator) or_return
	defer tape.destroy_document(&tmp_doc)

	// Validate UTF-8 on strings before calling `toml.write` (which replaces invalid bytes with U+FFFD).
	for nd in tmp_doc.nodes {
		if nd.kind == .String && !utf8.valid_string(string(tape.span_bytes(&tmp_doc, nd.lo, nd.n))) {
			return edit.refuse(.Unspellable_Value, "TOML string must be valid UTF-8", n.base)
		}
	}

	encoded, _, werr := write(&tmp_doc, tc.spec, {}, ov.allocator)
	if werr != nil {
		return toml_write_err(werr)
	}
	defer delete(encoded, ov.allocator)

	// Strip `v = ` prefix and trailing `\n`.
	val_bytes := encoded
	if len(val_bytes) >= 4 && string(val_bytes[:4]) == "v = " {
		val_bytes = val_bytes[4:]
	}
	if len(val_bytes) > 0 && val_bytes[len(val_bytes) - 1] == '\n' {
		val_bytes = val_bytes[:len(val_bytes) - 1]
	}
	append(out, ..val_bytes)
	return nil
}

// Safely spells body of a TOML multiline basic string (`"""..."""`), escaping `"` whenever it would form 3+ quotes
// OR sit at the very end of the string (fixing `"""x""""` -> `"""x\"` + `"""`!).
@(private = "file")
toml_append_multiline_basic_body :: proc(out: ^[dynamic]u8, s: string) {
	hex := "0123456789abcdef"
	b := transmute([]u8)s
	q_run := 0
	for c, i in b {
		if c == '"' {
			q_run += 1
			// Escape if 3rd consecutive quote OR if at end of string (avoids colliding with closing `"""`!).
			if q_run >= 3 || i + 1 == len(b) {
				append(out, `\"`)
				q_run = 0
			} else {
				append(out, '"')
			}
			continue
		}
		q_run = 0
		switch c {
		case '\\': append(out, `\\`)
		case '\b': append(out, `\b`)
		case '\f': append(out, `\f`)
		case '\r': append(out, `\r`)
		case '\n', '\t': append(out, c)
		case:
			if c < 0x20 || c == 0x7F {
				append(out, `\u00`)
				append(out, hex[c >> 4], hex[c & 0xF])
			} else {
				append(out, c)
			}
		}
	}
}

@(private = "file")
toml_write_err :: proc "contextless" (err: Write_Error) -> edit.Error {
	#partial switch e in err {
	case runtime.Allocator_Error:
		return e
	case ops_write.Refused:
		return edit.refuse(.Unspellable_Value, "value cannot be spelled in TOML", e.node)
	case tape.Bad_Option:
		return e
	case:
		return edit.refuse(.Unspellable_Value, "TOML write failed")
	}
}
