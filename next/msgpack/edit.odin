package msgpack

import "base:runtime"
import "core:strconv"
import "core:unicode/utf8"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import ops_write "stury:lib/ops/write"

// Byte-preserving MessagePack overlay editing over `edit.commit_binary` (`edit_init`, `edit_destroy`, `commit`,
// `commit_document`, `walk_fragment`), supporting `.Tag` overrides (`-128..127` / `"datetime"`), `.Bytes`, `.Raw`,
// `.Base_Ref`, structural deltas, reorder validation, cross-spec `.Compact` upgrades, and incremental splicing.

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
	same_family := ov != nil && ov.base != nil && read_as_msgpack(ov.base)
	ctx := Edit_Ctx {
		spec        = resolved,
		budget      = opts.budget,
		verbatim_ok = same_family && (resolved != .Compact || ov.base.format == as(.Compact)),
		allocator   = allocator,
	}
	bspec := edit.Binary_Spec {
		target         = as(resolved),
		same_family    = same_family,
		strict         = resolved == .Compact,
		no_prefix_tags = true,
		head_len       = msgpack_head_len,
		put_head       = msgpack_put_head,
		put_key        = msgpack_put_key,
		put_base_key   = msgpack_put_base_key,
		emit_tags      = msgpack_check_container_tags,
		spell_value    = msgpack_spell_value,
		validate       = edit_validate_cb,
		data           = &ctx,
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
	r := commit(ov, resolved, opts, allocator) or_return
	ctx := Edit_Ctx{spec = resolved, budget = opts.budget}
	eff_opts := opts
	eff_opts.target = as(resolved)
	d, serr := edit.splice_document(ov.base, &r, eff_opts, walk_fragment_cb, &ctx, full_build_cb, &ctx, allocator)
	if serr != nil {
		edit.destroy_commit_result(&r)
		return {}, {}, serr
	}
	return d, r, nil
}

// Walks ONLY `src[range.lo:range.hi]` as one MessagePack item and shifts offsets by `range.lo`.
walk_fragment :: proc(
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	spec := Spec.Msgpack,
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
Edit_Ctx :: struct {
	spec:        Spec,
	budget:      tape.Budget,
	verbatim_ok: bool,
	allocator:   runtime.Allocator,
}

@(private = "file")
Tag_Edit :: enum u8 {
	Keep,
	Delete,
	Ext_Int,
	Datetime,
}

@(private = "file")
resolve_edit_spec :: proc "contextless" (ov: ^Overlay, spec: Maybe(Spec), opts: Edit_Options) -> Spec {
	spec_of :: #force_inline proc "contextless" (f: ^tape.Format) -> Spec {
		if f != nil && f.id >= ID && f.id < ID + tape.Format_Id(len(Spec)) {
			return Spec(f.id - ID)
		}
		return .Msgpack
	}
	if opts.target != nil {
		return spec_of(opts.target)
	}
	if s, ok := spec.?; ok {
		return s
	}
	if ov != nil && ov.base != nil {
		return spec_of(ov.base.format)
	}
	return .Msgpack
}

@(private = "file")
walk_fragment_cb :: proc(
	data: rawptr,
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	allocator: runtime.Allocator,
) -> (edit.Fragment_Tape, tape.Error) {
	return walk_fragment(src, range, ctx, (^Edit_Ctx)(data).spec, allocator)
}

@(private = "file")
full_build_cb :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	cc := (^Edit_Ctx)(data)
	return build(src, cc.spec, {budget = cc.budget}, allocator)
}

@(private = "file")
edit_validate_cb :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error {
	cc := (^Edit_Ctx)(data)
	return validate(src, cc.spec, {budget = cc.budget}, allocator)
}

@(private = "file")
msgpack_head_len :: proc "contextless" (src: []u8, at: u64) -> u64 {
	return u64(container_head_len(src[at]))
}

@(private = "file")
msgpack_put_head :: proc(data: rawptr, major: u8, count: u64, dst: ^[dynamic]u8) -> Edit_Error {
	_ = data
	if count > u64(max(u32)) {
		return edit.refuse(.Unspellable_Value, "container exceeds MessagePack max count")
	}
	buf: [5]u8 = ---
	k := encode_container_head(&buf[0], major == 5, u32(count))
	append(dst, ..buf[:k]) or_return
	return nil
}

@(private = "file")
msgpack_put_key :: proc(data: rawptr, key: string, node: tape.Node_Index, dst: ^[dynamic]u8) -> Edit_Error {
	_ = data
	return append_msgpack_str(dst, key, node)
}

@(private = "file")
msgpack_check_container_tags :: proc(
	data: rawptr,
	doc: ^tape.Document,
	n: ^edit.Edit_Node,
	base_c: tape.Node_Index,
	tags_lo, item_lo: u64,
	dropped: ^tape.Facts,
	dst: ^[dynamic]u8,
) -> Edit_Error {
	_ = data
	_ = tags_lo
	_ = item_lo
	_ = dst
	err_node := n.base if n.base != tape.NO_NODE else base_c
	tag_mode, _ := parse_tag_override(dropped, n) or_return
	if tag_mode == .Ext_Int || tag_mode == .Datetime {
		return edit.refuse(.Fact_No_Place, "MessagePack ext tag cannot wrap containers", err_node)
	}
	if base_c != tape.NO_NODE && !read_as_msgpack(doc) {
		for f in tape.facts_of(doc, base_c) {
			if f.kind != .Tag || tag_mode != .Delete {
				dropped^ += {f.kind}
			}
		}
	}
	return nil
}

@(private = "file")
msgpack_put_base_key :: proc(data: rawptr, doc: ^tape.Document, base_key: tape.Node_Index, dropped: ^tape.Facts, dst: ^[dynamic]u8) -> Edit_Error {
	cc := (^Edit_Ctx)(data)
	bnode := doc.nodes[base_key]
	is_mp := read_as_msgpack(doc)
	if !is_mp {
		for f in tape.facts_of(doc, base_key) {
			dropped^ += {f.kind}
		}
		if doc.format != nil && doc.format.fact_name != nil {
			if _, has := doc.format.fact_name(doc, base_key, .Tag); has {
				dropped^ += {.Tag}
			}
		}
	}
	#partial switch bnode.kind {
	case .Number:
		if is_mp {
			put_compact_number_bytes(dst, number_value(doc.src, bnode)) or_return
			return nil
		}
		num, ok := tape.node_number(doc, base_key)
		if !ok || (num.kind != .Int && num.kind != .Uint) {
			return edit.refuse(.Unspellable_Value, "unsupported MessagePack map key number", base_key)
		}
		put_compact_number_bytes(dst, num) or_return
		return nil
	case .Bytes:
		return append_msgpack_bin(dst, tape.span_bytes(doc, bnode.lo, bnode.n), base_key)
	case .String, .Plain:
		if is_mp && bnode.spelling & STR_TIMESTAMP != 0 {
			sec, nsec, tok := timestamp_decode(tape.span_bytes(doc, bnode.lo, bnode.n))
			if !tok {
				return edit.refuse(.Unspellable_Value, "invalid MessagePack timestamp key", base_key)
			}
			append_msgpack_timestamp(dst, sec, nsec) or_return
			return nil
		}
		tk := edit.decode_node_text_tmp(doc, base_key, cc.allocator)
		defer edit.free_tmp_text(tk, cc.allocator)
		return append_msgpack_str(dst, tk.text, base_key)
	}
	return edit.refuse(.Unspellable_Value, "unsupported MessagePack map key kind", base_key)
}

@(private = "file")
msgpack_spell_value :: proc(
	data: rawptr,
	ov: ^Overlay,
	h: Handle,
	base_node: tape.Node_Index,
	dropped: ^tape.Facts,
	dst: ^[dynamic]u8,
) -> Edit_Error {
	cc := (^Edit_Ctx)(data)
	doc := ov.base
	if h == edit.NO_HANDLE {
		return write_base_subtree(doc, cc.spec, base_node, dropped, cc.allocator, dst)
	}
	n, ok := edit.get_node(ov, h)
	if !ok {
		return edit.refuse(.Bad_Handle, "invalid overlay handle")
	}
	if !n.has_edits && n.base != tape.NO_NODE && n.base_ref == tape.NO_NODE {
		return write_base_subtree(doc, cc.spec, n.base, dropped, cc.allocator, dst)
	}
	if base_node != tape.NO_NODE && n.state != .Replaced {
		// Fact-only edit on a base leaf.
		tag_mode, ext_type := parse_tag_override(dropped, n) or_return
		if tag_mode == .Keep {
			if cc.verbatim_ok && n.base != tape.NO_NODE {
				tlo, _, ihi := edit.binary_item_span(doc, n.base)
				append(dst, ..doc.src[tlo:ihi]) or_return
				return nil
			}
			return write_base_subtree(doc, cc.spec, base_node, dropped, cc.allocator, dst)
		}
		if !read_as_msgpack(doc) {
			for f in tape.facts_of(doc, base_node) {
				if f.kind != .Tag {
					dropped^ += {f.kind}
				}
			}
		}
		return apply_tag_on_base_leaf(doc, cc.spec, base_node, tag_mode, ext_type, dropped, cc.allocator, dst)
	}
	if n.val.kind == .Base_Ref {
		tag_mode, ext_type := parse_tag_override(dropped, n) or_return
		if tag_mode == .Keep {
			if cc.verbatim_ok {
				rlo, _, rhi := edit.binary_item_span(doc, n.val.base_ref)
				append(dst, ..doc.src[rlo:rhi]) or_return
				return nil
			}
			return write_base_subtree(doc, cc.spec, n.val.base_ref, dropped, cc.allocator, dst)
		}
		if doc.nodes[n.val.base_ref].kind >= .Array {
			return edit.refuse(.Fact_No_Place, "MessagePack ext tag cannot wrap containers", n.base)
		}
		return apply_tag_on_base_leaf(doc, cc.spec, n.val.base_ref, tag_mode, ext_type, dropped, cc.allocator, dst)
	}
	return emit_scalar_node(n, dropped, dst)
}

@(private = "file")
parse_tag_override :: proc(dropped: ^tape.Facts, n: ^edit.Edit_Node) -> (mode: Tag_Edit, ext_type: i8, err: Edit_Error) {
	has_tag := false
	tag_fo: edit.Fact_Override
	for f in n.facts {
		if f.kind == .Tag {
			has_tag = true
			tag_fo = f
		} else if !f.deleted {
			dropped^ += {f.kind}
		}
	}
	if !has_tag {
		return .Keep, 0, nil
	}
	if tag_fo.deleted {
		return .Delete, 0, nil
	}
	if num, ok := tag_fo.num_tag.?; ok {
		signed := i64(num)
		if signed < -128 || signed > 127 {
			return .Keep, 0, edit.refuse(.Fact_No_Place, "MessagePack ext type must fit signed i8 (-128..127)", n.base)
		}
		return .Ext_Int, i8(signed), nil
	}
	if len(tag_fo.values) != 1 {
		return .Keep, 0, edit.refuse(.Fact_No_Place, "MessagePack tag must be a single ext type (-128..127) or datetime", n.base)
	}
	v := tag_fo.values[0]
	if v == "datetime" || v == "!!timestamp" {
		return .Datetime, -1, nil
	}
	parsed, pok := strconv.parse_i64_maybe_prefixed(v)
	if !pok || parsed < -128 || parsed > 127 {
		return .Keep, 0, edit.refuse(.Fact_No_Place, "MessagePack ext type must be an integer in -128..127 or datetime", n.base)
	}
	return .Ext_Int, i8(parsed), nil
}

@(private = "file")
write_base_subtree :: proc(doc: ^tape.Document, spec: Spec, at: tape.Node_Index, dropped: ^tape.Facts, allocator: runtime.Allocator, dst: ^[dynamic]u8) -> Edit_Error {
	encoded, wdrop, werr := write(doc, spec, {node = at}, allocator)
	if werr != nil {
		return map_write_err(werr)
	}
	defer delete(encoded, allocator)
	dropped^ += wdrop
	append(dst, ..encoded) or_return
	return nil
}

@(private = "file")
map_write_err :: proc "contextless" (err: Write_Error) -> Edit_Error {
	#partial switch e in err {
	case runtime.Allocator_Error:
		return e
	case ops_write.Refused:
		return edit.refuse(.Unspellable_Value, "value cannot be encoded in MessagePack", e.node)
	case tape.Bad_Option:
		return e
	case:
		return edit.refuse(.Unspellable_Value, "MessagePack write failed")
	}
}

@(private = "file")
append_msgpack_str :: proc(dst: ^[dynamic]u8, s: string, node: tape.Node_Index) -> Edit_Error {
	if !utf8.valid_string(s) || u64(len(s)) > u64(max(u32)) {
		return edit.refuse(.Unspellable_Value, "invalid UTF-8 or oversized string", node)
	}
	buf: [5]u8 = ---
	k := encode_str_head(&buf[0], u32(len(s)))
	append(dst, ..buf[:k]) or_return
	append(dst, s) or_return
	return nil
}

@(private = "file")
append_msgpack_bin :: proc(dst: ^[dynamic]u8, raw: []u8, node: tape.Node_Index) -> Edit_Error {
	if u64(len(raw)) > u64(max(u32)) {
		return edit.refuse(.Unspellable_Value, "oversized binary payload", node)
	}
	buf: [5]u8 = ---
	k := encode_bin_head(&buf[0], u32(len(raw)))
	append(dst, ..buf[:k]) or_return
	append(dst, ..raw) or_return
	return nil
}

@(private = "file")
append_msgpack_ext :: proc(dst: ^[dynamic]u8, ext_type: i8, raw: []u8, node: tape.Node_Index) -> Edit_Error {
	if u64(len(raw)) > u64(max(u32)) {
		return edit.refuse(.Unspellable_Value, "oversized ext payload", node)
	}
	if ext_type == -1 {
		if _, _, ok := timestamp_decode(raw); !ok {
			return edit.refuse(.Fact_No_Place, "MessagePack timestamp ext -1 requires valid 4/8/12-byte payload", node)
		}
	}
	append_ext_head_bytes(dst, ext_type, u32(len(raw))) or_return
	append(dst, ..raw) or_return
	return nil
}

@(private = "file")
append_msgpack_timestamp :: proc(dst: ^[dynamic]u8, sec: i64, nsec: u32) -> runtime.Allocator_Error {
	buf: [15]u8 = ---
	total, _ := encode_timestamp(&buf[0], sec, nsec)
	_, err := append(dst, ..buf[:total])
	return err
}

@(private = "file")
emit_scalar_node :: proc(n: ^edit.Edit_Node, dropped: ^tape.Facts, dst: ^[dynamic]u8) -> Edit_Error {
	tag_mode, ext_type := parse_tag_override(dropped, n) or_return
	tagged := tag_mode == .Ext_Int || tag_mode == .Datetime
	#partial switch n.val.kind {
	case .Null, .False, .True:
		if tagged {
			return edit.refuse(.Fact_No_Place, "cannot apply MessagePack ext tag to null/boolean", n.base)
		}
		b := u8(0xc0) if n.val.kind == .Null else (u8(0xc2) if n.val.kind == .False else u8(0xc3))
		append(dst, b) or_return
	case .Int, .Uint, .Float, .Number_Text:
		if tagged {
			return edit.refuse(.Fact_No_Place, "cannot apply MessagePack ext tag to number", n.base)
		}
		num: spell.Number
		#partial switch n.val.kind {
		case .Int:   num = {u64(n.val.i), .Int}
		case .Uint:  num = {n.val.u, .Uint}
		case .Float: num = {transmute(u64)n.val.f, .Float}
		case .Number_Text:
			ok: bool
			num, ok = parse_token_number(n.val.text)
			if !ok {
				return edit.refuse(.Unspellable_Value, "number cannot be represented in MessagePack", n.base)
			}
		}
		put_compact_number_bytes(dst, num) or_return
	case .String:
		if tag_mode == .Datetime || (tag_mode == .Ext_Int && ext_type == -1) {
			sec, nsec, tok := spell.date_time_utc(n.val.text)
			if !tok {
				return edit.refuse(.Fact_No_Place, "MessagePack datetime tag requires RFC 3339 date-time string", n.base)
			}
			append_msgpack_timestamp(dst, sec, nsec) or_return
			return nil
		}
		if tag_mode == .Ext_Int {
			return edit.refuse(.Fact_No_Place, "MessagePack non-timestamp ext tag applies to Bytes values", n.base)
		}
		append_msgpack_str(dst, n.val.text, n.base) or_return
	case .Bytes:
		if tag_mode == .Datetime {
			sec, nsec, tok := timestamp_decode(n.val.raw)
			if !tok {
				return edit.refuse(.Fact_No_Place, "MessagePack timestamp requires 4/8/12-byte payload", n.base)
			}
			append_msgpack_timestamp(dst, sec, nsec) or_return
			return nil
		}
		if tag_mode == .Ext_Int {
			return append_msgpack_ext(dst, ext_type, n.val.raw, n.base)
		}
		return append_msgpack_bin(dst, n.val.raw, n.base)
	case .Raw:
		append(dst, n.val.text) or_return
	case:
		return edit.refuse(.Unspellable_Value, "unsupported edit value kind", n.base)
	}
	return nil
}

@(private = "file")
apply_tag_on_base_leaf :: proc(
	doc: ^tape.Document,
	spec: Spec,
	base_idx: tape.Node_Index,
	mode: Tag_Edit,
	ext_type: i8,
	dropped: ^tape.Facts,
	allocator: runtime.Allocator,
	dst: ^[dynamic]u8,
) -> Edit_Error {
	bnode := doc.nodes[base_idx]
	switch mode {
	case .Keep:
		return write_base_subtree(doc, spec, base_idx, dropped, allocator, dst)
	case .Delete:
		if bnode.kind == .Bytes {
			return append_msgpack_bin(dst, tape.span_bytes(doc, bnode.lo, bnode.n), base_idx)
		}
		if bnode.kind == .String || bnode.kind == .Plain {
			tk := edit.decode_node_text_tmp(doc, base_idx, allocator)
			defer edit.free_tmp_text(tk, allocator)
			return append_msgpack_str(dst, tk.text, base_idx)
		}
		return write_base_subtree(doc, spec, base_idx, dropped, allocator, dst)
	case .Datetime, .Ext_Int:
		if mode == .Datetime || ext_type == -1 {
			if bnode.kind == .Bytes {
				sec, nsec, ok := timestamp_decode(tape.span_bytes(doc, bnode.lo, bnode.n))
				if !ok {
					return edit.refuse(.Fact_No_Place, "MessagePack timestamp requires 4/8/12-byte payload", base_idx)
				}
				append_msgpack_timestamp(dst, sec, nsec) or_return
				return nil
			}
			if bnode.kind == .String || bnode.kind == .Plain {
				tk := edit.decode_node_text_tmp(doc, base_idx, allocator)
				defer edit.free_tmp_text(tk, allocator)
				sec, nsec, ok := spell.date_time_utc(tk.text)
				if !ok {
					return edit.refuse(.Fact_No_Place, "MessagePack timestamp tag requires RFC 3339 date-time string", base_idx)
				}
				append_msgpack_timestamp(dst, sec, nsec) or_return
				return nil
			}
			return edit.refuse(.Fact_No_Place, "cannot apply MessagePack timestamp tag to this value", base_idx)
		}
		if bnode.kind != .Bytes {
			return edit.refuse(.Fact_No_Place, "MessagePack ext tag applies to Bytes values", base_idx)
		}
		return append_msgpack_ext(dst, ext_type, tape.span_bytes(doc, bnode.lo, bnode.n), base_idx)
	}
	return nil
}
