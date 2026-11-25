package xml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/markup"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import ops_write "stury:lib/ops/write"

// Byte-preserving XML editing over `edit.Overlay`, reusing `xml.write` (exact `\r`/`\t`/`\n` escaping,
// XML 1.0 nonchar validation, iterative child + attribute spelling) and `walk_fragment` incremental splicing.

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
	opts := Edit_Options{},
	allocator := context.allocator,
) -> (
	res: Commit_Result,
	err: Edit_Error,
) {
	mspec := edit.Markup_Spec {
		target         = as(.Xml),
		self_closing   = true,
		element        = xml_element_of,
		is_name        = xml_is_name_bytes,
		is_void        = nil,
		spell_content  = xml_spell_content,
		spell_attr_val = xml_spell_attr_val,
		validate       = xml_edit_validate,
		data           = nil,
	}
	return edit.commit_markup(ov, &mspec, opts, allocator)
}

commit_document :: proc(
	ov: ^Overlay,
	opts := Edit_Options{},
	allocator := context.allocator,
) -> (
	doc: tape.Document,
	res: Commit_Result,
	err: Edit_Error,
) {
	res = commit(ov, opts, allocator) or_return
	defer if err != nil {
		edit.destroy_commit_result(&res)
	}
	eff_opts := opts
	eff_opts.target = as(.Xml)
	doc = edit.splice_document(ov.base, &res, eff_opts, xml_walk_fragment_cb, nil, xml_full_build_cb, nil, allocator) or_return
	return doc, res, nil
}

// Walks ONLY `src[range.lo:range.hi]` (element content) inside a minimal `<_>...</_>` wrapper, rebases
// all node/fact/count offsets cleanly via `shift_fragment_tape`, and preserves the enclosing element's `Node.lo`
// when replacing an `.Object` container's children!
walk_fragment :: proc(
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	allocator := context.allocator,
) -> (
	ft: edit.Fragment_Tape,
	err: tape.Error,
) {
	// If the edited bytes themselves declare a namespace (`xmlns`), fall back so `Markup_Ext.scopes` updates cleanly.
	sub := src[range.lo:range.hi]
	if len(sub) >= 5 {
		for i := 0; i + 5 <= len(sub); i += 1 {
			if sub[i] == 'x' && string(sub[i : i + 5]) == "xmlns" {
				full := build(src, .Xml, {}, allocator) or_return
				return edit.Fragment_Tape{full_doc = full, allocator = allocator}, nil
			}
		}
	}
	// Wrap `sub` in `<_>...</_>` (3-byte prefix `<_>`, 4-byte suffix `</_>`).
	buf, aerr := make([]u8, 3 + len(sub) + 4, allocator)
	if aerr != nil {
		return {}, aerr
	}
	defer delete(buf, allocator)
	copy(buf[:3], "<_>")
	copy(buf[3 : 3 + len(sub)], sub)
	copy(buf[3 + len(sub):], "</_>")

	d := build(buf, .Xml, {}, allocator) or_return
	// `d.nodes`: `[0]=doc Object, [1]=Key("_"), [2..]=value of <_>`.
	ft, aerr = edit.shift_fragment_tape(&d, range.lo, 2, 3, allocator)
	if aerr != nil {
		return {}, aerr
	}
	// When `<_>` parsed as an `.Object` (element with child elements), its `nodes[0].lo` points to the wrapper `<_>`
	// at offset 0 -> restore the original element's start tag `lo` from `ctx.base`!
	if len(ft.nodes) > 0 && ft.nodes[0].kind == .Object && ctx.base != nil && int(ctx.base_node) < len(ctx.base.nodes) {
		el := xml_element_of(ctx.base, ctx.base_node)
		ft.nodes[0].lo = el.lo
	}
	return ft, nil
}

@(private = "file")
xml_walk_fragment_cb :: proc(
	data: rawptr,
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	allocator: runtime.Allocator,
) -> (edit.Fragment_Tape, tape.Error) {
	_ = data
	return walk_fragment(src, range, ctx, allocator)
}

@(private = "file")
xml_full_build_cb :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	_ = data
	return build(src, .Xml, {}, allocator)
}

@(private = "file")
xml_edit_validate :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error {
	_ = data
	return validate(src, .Xml, {}, allocator)
}

// Allows full XML 1.0 Names including QNames with `:` (`xmlns:ns`, `xml:lang`, `ns:tag`) via `xml.name_end`.
@(private = "file")
xml_is_name_bytes :: proc "contextless" (name: []u8) -> bool {
	if len(name) == 0 {
		return false
	}
	p := raw_data(name)
	end := intrinsics.ptr_offset(p, len(name))
	q, fault := name_end(p, end)
	return fault == .None && q == end
}

// Locates element tag offsets `(lo, name, open, close, hi, empty, end_tag)` for XML node `v`.
@(private = "file")
xml_element_of :: proc "contextless" (doc: ^tape.Document, v: tape.Node_Index) -> (e: edit.Markup_Element) {
	v := v
	if v == tape.ROOT {
		if len(doc.nodes) > 2 {
			v = 2
		} else {
			return {}
		}
	}
	src := doc.src
	n := doc.nodes[v]
	if n.kind == .Object {
		e.lo = n.lo
		e.hi, _ = close_end(doc, v)
		quote: u8
		for e.open = e.lo + 1; e.open < u64(len(src)) && (quote != 0 || src[e.open] != '>'); e.open += 1 {
			if quote == 0 && (src[e.open] == '"' || src[e.open] == '\'') {
				quote = src[e.open]
			} else if src[e.open] == quote {
				quote = 0
			}
		}
		if e.open < u64(len(src)) {
			e.open += 1
		}
		e.close = e.hi
		for e.close > e.open {
			e.close -= 1
			if src[e.close] == '<' {
				break
			}
		}
	} else {
		e.lo = n.lo
		for e.lo > 0 {
			e.lo -= 1
			if src[e.lo] == '<' {
				break
			}
		}
		e.empty = n.n == 0 && n.lo < u64(len(src)) && src[n.lo] == '/'
		e.open = n.lo
		e.close = n.lo + u64(n.n)
		e.hi = n.lo + 2 if e.empty else end_tag_end(src, e.close)
	}
	e.end_tag = !e.empty
	e.name = e.lo + 1
	for e.name < u64(len(src)) && !kernel.is_markup_ws(src[e.name]) && src[e.name] != '>' && src[e.name] != '/' {
		e.name += 1
	}
	return e
}

@(private = "file")
xml_spell_attr_val :: proc(data: rawptr, val: string, quote: u8, out: ^[dynamic]u8) -> edit.Error {
	_ = data
	if !xml_valid_chars(transmute([]u8)val) {
		return edit.refuse(.Unspellable_Value, "XML 1.0 cannot encode control character or noncharacter")
	}
	for c in transmute([]u8)val {
		switch c {
		case '&': append(out, "&amp;")
		case '<': append(out, "&lt;")
		case '>': append(out, "&gt;")
		case '\t': append(out, "&#9;")
		case '\n': append(out, "&#10;")
		case '\r': append(out, "&#13;")
		case '"':
			if quote == '"' {
				append(out, "&quot;")
			} else {
				append(out, '"')
			}
		case '\'':
			if quote == '\'' {
				append(out, "&apos;")
			} else {
				append(out, '\'')
			}
		case:
			append(out, c)
		}
	}
	return nil
}

@(private = "file")
xml_valid_chars :: proc "contextless" (b: []u8) -> bool {
	p := raw_data(b)
	end := intrinsics.ptr_offset(p, len(b))
	for i := 0; i < len(b); {
		c := b[i]
		if c >= 0x80 {
			if c == 0xef && non_char(p[i:], end) {
				return false
			}
			i += 1
			continue
		}
		if c < 0x20 && c != '\t' && c != '\n' && c != '\r' {
			return false
		}
		i += 1
	}
	return true
}

// Reuses `xml.write` via `edit.materialize_subtree` wrapped in `<_>...</_>` (stripping outer wrapper tags) —
// automatically handles `\r -> &#13;`, nonchar validation, iterative child elements, attributes, `#text`, and arrays!
@(private = "file")
xml_spell_content :: proc(data: rawptr, ov: ^Overlay, h: Handle, out: ^[dynamic]u8) -> edit.Error {
	_ = data
	if h == edit.NO_HANDLE {
		return nil
	}
	if n, ok := edit.get_node(ov, h); ok && n.state == .Replaced && n.val.kind == .Raw {
		append(out, n.val.text)
		return nil
	}
	// Quick null check: empty content!
	if edit.node_kind(ov, h) == .Null {
		return nil
	}
	tmp_doc := edit.materialize_subtree(ov, h, tape.NO_NODE, {
		wrap_key        = "_",
		xml_attrs       = true,
		skip_root_attrs = true,
		target_format   = as(.Xml),
	}, ov.allocator) or_return
	defer tape.destroy_document(&tmp_doc)

	// Validate element names inside `tmp_doc` (because `xml.write` skips `is_name` when `doc.format == &FORMATS[.Xml]`).
	for nd in tmp_doc.nodes {
		if nd.role == .Key {
			kname := tape.span_bytes(&tmp_doc, nd.lo, nd.n)
			if string(kname) != markup.TEXT_KEY && !xml_is_name_bytes(kname) {
				return edit.refuse(.Bad_Name, "invalid XML element name")
			}
		}
	}

	encoded, _, werr := write(&tmp_doc, .Xml, {}, ov.allocator)
	if werr != nil {
		#partial switch e in werr {
		case runtime.Allocator_Error:
			return e
		case ops_write.Refused:
			return edit.refuse(.Unspellable_Value, "value cannot be spelled in XML", e.node)
		}
		return edit.refuse(.Unspellable_Value, "XML write failed")
	}
	defer delete(encoded, ov.allocator)

	// `xml.write` emits `<_ .../>` (empty) or `<_ ...>CONTENT</_>`. Strip the synthetic outer `<_>` / `</_>` wrapper!
	if len(encoded) >= 4 && string(encoded[:3]) == "<_>" && string(encoded[len(encoded) - 4:]) == "</_>" {
		append(out, ..encoded[3 : len(encoded) - 4])
		return nil
	}
	// If wrapper carried attributes (when `h` had attributes on itself), find the first `>` and strip trailing `</_>`.
	if len(encoded) >= 4 && encoded[0] == '<' && encoded[1] == '_' {
		if encoded[len(encoded) - 2] == '/' && encoded[len(encoded) - 1] == '>' {
			return nil
		}
		for i := 2; i < len(encoded); i += 1 {
			if encoded[i] == '>' && len(encoded) >= i + 5 && string(encoded[len(encoded) - 4:]) == "</_>" {
				append(out, ..encoded[i + 1 : len(encoded) - 4])
				return nil
			}
		}
	}
	return nil
}
