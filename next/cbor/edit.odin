package cbor

import "base:runtime"
import "core:encoding/endian"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import ops_write "stury:lib/ops/write"

// Byte-preserving CBOR editing over `edit.Overlay`, reusing `cbor.write` for all modified/upgraded
// subtrees (binary16 subnormals, bignums, canonical heads, sorted maps, child tags) and `walk_fragment` splicing.

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
	ctx := Cbor_Edit_Ctx{spec = resolved}
	bspec := edit.Binary_Spec {
		target       = as(resolved),
		strict       = resolved != .Cbor,
		sorted_maps  = resolved == .Deterministic || resolved == .Length_First,
		length_first = resolved == .Length_First,
		item_span    = cbor_item_span,
		put_head     = cbor_put_head_dyn,
		put_key      = cbor_put_key_dyn,
		spell_value  = cbor_spell_value,
		validate     = cbor_edit_validate,
		data         = &ctx,
	}
	return edit.commit_binary(ov, &bspec, opts, allocator)
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
	res = commit(ov, resolved, opts, allocator) or_return
	defer if err != nil {
		edit.destroy_commit_result(&res)
	}
	ctx := Cbor_Edit_Ctx{spec = resolved}
	eff_opts := opts
	eff_opts.target = as(resolved)
	doc = edit.splice_document(ov.base, &res, eff_opts, cbor_walk_fragment_cb, &ctx, cbor_full_build_cb, &ctx, allocator) or_return
	return doc, res, nil
}

// Walks ONLY `src[range.lo:range.hi]` as one CBOR item and shifts every token/fact/count offset by `range.lo`.
walk_fragment :: proc(
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	spec := Spec.Cbor,
	allocator := context.allocator,
) -> (
	ft: edit.Fragment_Tape,
	err: tape.Error,
) {
	_ = ctx
	d := build(src[range.lo:range.hi], spec, {}, allocator) or_return
	return edit.shift_fragment_tape(&d, range.lo, 0, 0, allocator)
}

@(private = "file")
Cbor_Edit_Ctx :: struct {
	spec: Spec,
}

@(private = "file")
resolve_edit_spec :: proc "contextless" (ov: ^Overlay, spec: Maybe(Spec), opts: Edit_Options) -> Spec {
	if opts.target != nil {
		return cbor_spec_from_format(opts.target)
	}
	if s, ok := spec.?; ok {
		return s
	}
	if ov != nil && ov.base != nil && ov.base.format != nil {
		return cbor_spec_from_format(ov.base.format)
	}
	return .Cbor
}

@(private = "file")
cbor_spec_from_format :: proc "contextless" (f: ^tape.Format) -> Spec {
	if f != nil && f.id >= ID && f.id <= ID + 3 {
		return Spec(f.id - ID)
	}
	return .Cbor
}

@(private = "file")
cbor_walk_fragment_cb :: proc(
	data: rawptr,
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	allocator: runtime.Allocator,
) -> (edit.Fragment_Tape, tape.Error) {
	cc := (^Cbor_Edit_Ctx)(data)
	return walk_fragment(src, range, ctx, cc.spec, allocator)
}

@(private = "file")
cbor_full_build_cb :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	cc := (^Cbor_Edit_Ctx)(data)
	return build(src, cc.spec, {}, allocator)
}

@(private = "file")
cbor_edit_validate :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error {
	cc := (^Cbor_Edit_Ctx)(data)
	return validate(src, cc.spec, {}, allocator)
}

@(private = "file")
cbor_item_span :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (tags_lo, item_lo, item_hi: u64) {
	item_lo, item_hi, _ = edit.node_byte_span(doc, at)
	tags_lo = item_lo
	for f in tape.facts_of(doc, at) {
		if f.kind == .Tag && f.lo < tags_lo {
			tags_lo = f.lo
		}
	}
	return tags_lo, item_lo, item_hi
}

@(private = "file")
cbor_put_head_dyn :: proc(data: rawptr, major: u8, arg: u64, out: ^[dynamic]u8) {
	_ = data
	m := major << 5
	switch {
	case arg < 24:
		append(out, m | u8(arg))
	case arg <= 0xFF:
		append(out, m | 24, u8(arg))
	case arg <= 0xFFFF:
		b := [3]u8{m | 25, u8(arg >> 8), u8(arg)}
		append(out, ..b[:])
	case arg <= 0xFFFF_FFFF:
		b := [5]u8{m | 26, u8(arg >> 24), u8(arg >> 16), u8(arg >> 8), u8(arg)}
		append(out, ..b[:])
	case:
		b: [9]u8
		b[0] = m | 27
		endian.unchecked_put_u64be(b[1:], arg)
		append(out, ..b[:])
	}
}

@(private = "file")
cbor_put_key_dyn :: proc(data: rawptr, key: string, out: ^[dynamic]u8) {
	cbor_put_head_dyn(data, 3, u64(len(key)), out)
	append(out, key)
}

// Reuses `cbor.write` via `edit.materialize_subtree` — zero duplicate CBOR serializer!
@(private = "file")
cbor_spell_value :: proc(data: rawptr, ov: ^Overlay, h: Handle, base_node: tape.Node_Index, out: ^[dynamic]u8) -> edit.Error {
	cc := (^Cbor_Edit_Ctx)(data)
	// Support `.Raw` directly if explicitly provided.
	if h != edit.NO_HANDLE {
		if n, ok := edit.get_node(ov, h); ok {
			if n.state == .Replaced && n.val.kind == .Raw {
				append(out, n.val.text)
				return nil
			}
			// Emit outer numeric CBOR tag override (or base tag(s)) before delegating to `cbor.write`!
			has_tag_override := false
			tag_fo: edit.Fact_Override
			for f in n.facts {
				if f.kind == .Tag {
					has_tag_override = true
					tag_fo = f
				}
			}
			if has_tag_override {
				if !tag_fo.deleted {
					tag_num, tok := cbor_parse_tag_fact(tag_fo)
					if !tok {
						return edit.refuse(.Fact_No_Place, "CBOR tag must be an unsigned 64-bit integer", n.base)
					}
					cbor_put_head_dyn(data, 6, tag_num, out)
				}
			} else if n.base != tape.NO_NODE {
				tlo, ilo, _ := cbor_item_span(ov.base, n.base)
				if tlo < ilo {
					append(out, ..ov.base.src[tlo:ilo])
				}
			}
		}
	} else if base_node != tape.NO_NODE {
		tlo, ilo, _ := cbor_item_span(ov.base, base_node)
		if tlo < ilo {
			append(out, ..ov.base.src[tlo:ilo])
		}
	}
	tmp_doc := edit.materialize_subtree(ov, h, base_node, {skip_root_tags = true}, ov.allocator) or_return
	defer tape.destroy_document(&tmp_doc)

	encoded, _, werr := write(&tmp_doc, cc.spec, {}, ov.allocator)
	if werr != nil {
		return cbor_write_err(werr)
	}
	defer delete(encoded, ov.allocator)
	append(out, ..encoded)
	return nil
}

@(private = "file")
cbor_parse_tag_fact :: proc "contextless" (f: edit.Fact_Override) -> (u64, bool) {
	if u, ok := f.num_tag.?; ok {
		return u, true
	}
	if len(f.values) == 0 || len(f.values[0]) == 0 {
		return 0, false
	}
	v := u64(0)
	for c in transmute([]u8)f.values[0] {
		if c < '0' || c > '9' {
			return 0, false
		}
		d := u64(c - '0')
		if v > (max(u64) - d) / 10 {
			return 0, false
		}
		v = v * 10 + d
	}
	return v, true
}

@(private = "file")
cbor_write_err :: proc "contextless" (err: Write_Error) -> edit.Error {
	#partial switch e in err {
	case runtime.Allocator_Error:
		return e
	case ops_write.Refused:
		return edit.refuse(.Unspellable_Value, "value cannot be encoded in target CBOR spec", e.node)
	case tape.Bad_Option:
		return e
	case:
		return edit.refuse(.Unspellable_Value, "CBOR write failed")
	}
}
