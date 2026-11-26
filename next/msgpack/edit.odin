package msgpack

import "base:runtime"
import "core:encoding/endian"
import "core:strconv"
import "core:unicode/utf8"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import ops_write "stury:lib/ops/write"

// Byte-preserving MessagePack overlay editing (`edit_init`, `edit_destroy`, `commit`, `commit_document`, `walk_fragment`).
// Untouched compatible subtrees copy verbatim; edited, `.Base_Ref`, and cross-spec upgraded subtrees
// encode iteratively (zero recursion), supporting MessagePack `.Tag` overrides (`-128..127` / `"datetime"`),
// `.Bytes`, `.Raw`, structural deltas, reorder validation, and incremental document splicing.

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
	target := as(resolved)
	same_family := ov != nil && ov.base != nil && ov.base.format != nil && (ov.base.format == as(.Msgpack) || ov.base.format == as(.Compact))
	same_format := same_family && (target == ov.base.format || resolved != .Compact)
	val_ctx := Edit_Ctx{spec = resolved, budget = opts.budget}
	fast, _, fast_res, gerr := edit.commit_guard(ov, target, opts, same_format, edit_validate_cb, &val_ctx, allocator)
	if gerr != nil {
		return {}, gerr
	}
	if fast {
		return fast_res, nil
	}
	if ov.unlinked_parents {
		edit.ensure_linked(ov) or_return
	}
	doc := ov.base
	cx := Edit_Cx {
		ov          = ov,
		doc         = doc,
		src         = doc.src,
		spec        = resolved,
		verbatim_ok = same_family && (resolved != .Compact || doc.format == as(.Compact)),
		allocator   = allocator,
	}
	out := make([dynamic]u8, 0, len(doc.src), allocator)
	defer if err != nil {
		delete(out)
	}
	recs := make([dynamic]edit.Splice_Record, 0, 8, allocator)
	defer if err != nil {
		delete(recs)
	}
	emit_msgpack_iterative(&cx, &out, &recs) or_return
	if verr := validate(out[:], resolved, {budget = opts.budget}, allocator); verr != nil {
		return {}, to_edit_error(verr)
	}
	return Commit_Result {
		bytes     = out[:],
		dropped   = cx.dropped,
		splices   = recs[:],
		allocator = allocator,
	}, nil
}

@(private = "file")
to_edit_error :: proc "contextless" (err: tape.Error) -> Edit_Error {
	#partial switch e in err {
	case tape.Fault:
		return e
	case tape.Exceeded:
		return e
	case tape.Bad_Option:
		return e
	case runtime.Allocator_Error:
		return e
	}
	return edit.refuse(.Invalid_Result, "edited MessagePack invalid")
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
	spec:   Spec,
	budget: tape.Budget,
}

@(private = "file")
Edit_Cx :: struct {
	ov:          ^Overlay,
	doc:         ^tape.Document,
	src:         []u8,
	spec:        Spec,
	verbatim_ok: bool,
	dropped:     tape.Facts,
	allocator:   runtime.Allocator,
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
	cc := (^Edit_Ctx)(data)
	return walk_fragment(src, range, ctx, cc.spec, allocator)
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
item_span :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (tags_lo, item_lo, item_hi: u64) {
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
Tag_Edit :: enum u8 {
	Keep,
	Delete,
	Ext_Int,
	Datetime,
}

@(private = "file")
parse_tag_override :: proc(cx: ^Edit_Cx, n: ^edit.Edit_Node) -> (mode: Tag_Edit, ext_type: i8, err: Edit_Error) {
	has_tag := false
	tag_fo: edit.Fact_Override
	for f in n.facts {
		if f.kind == .Tag {
			has_tag = true
			tag_fo = f
		} else if !f.deleted {
			cx.dropped += {f.kind}
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
write_base_subtree :: proc(cx: ^Edit_Cx, at: tape.Node_Index, dst: ^[dynamic]u8) -> Edit_Error {
	encoded, dropped, werr := write(cx.doc, cx.spec, {node = at}, cx.allocator)
	if werr != nil {
		return map_write_err(werr)
	}
	defer delete(encoded, cx.allocator)
	cx.dropped += dropped
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
	n := u32(len(s))
	switch {
	case n <= 31:
		append(dst, 0xa0 | u8(n)) or_return
	case n <= 0xff:
		append(dst, 0xd9, u8(n)) or_return
	case n <= 0xffff:
		b: [3]u8 = {0xda, 0, 0}
		endian.unchecked_put_u16be(b[1:], u16(n))
		append(dst, ..b[:]) or_return
	case:
		b: [5]u8 = {0xdb, 0, 0, 0, 0}
		endian.unchecked_put_u32be(b[1:], n)
		append(dst, ..b[:]) or_return
	}
	append(dst, s) or_return
	return nil
}

@(private = "file")
append_msgpack_bin :: proc(dst: ^[dynamic]u8, raw: []u8, node: tape.Node_Index) -> Edit_Error {
	if u64(len(raw)) > u64(max(u32)) {
		return edit.refuse(.Unspellable_Value, "oversized binary payload", node)
	}
	n := u32(len(raw))
	switch {
	case n <= 0xff:
		append(dst, 0xc4, u8(n)) or_return
	case n <= 0xffff:
		b: [3]u8 = {0xc5, 0, 0}
		endian.unchecked_put_u16be(b[1:], u16(n))
		append(dst, ..b[:]) or_return
	case:
		b: [5]u8 = {0xc6, 0, 0, 0, 0}
		endian.unchecked_put_u32be(b[1:], n)
		append(dst, ..b[:]) or_return
	}
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
	if nsec == 0 && sec >= 0 && sec <= 0xFFFF_FFFF {
		b: [6]u8 = {0xd6, 0xff, 0, 0, 0, 0}
		endian.unchecked_put_u32be(b[2:], u32(sec))
		_, err := append(dst, ..b[:])
		return err
	}
	if sec >= 0 && sec <= 0x3_FFFF_FFFF {
		b: [10]u8 = {0xd7, 0xff, 0, 0, 0, 0, 0, 0, 0, 0}
		endian.unchecked_put_u64be(b[2:], (u64(nsec) << 34) | u64(sec))
		_, err := append(dst, ..b[:])
		return err
	}
	b: [15]u8 = {0xc7, 12, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	endian.unchecked_put_u32be(b[3:7], nsec)
	endian.unchecked_put_u64be(b[7:15], u64(sec))
	_, err := append(dst, ..b[:])
	return err
}

@(private = "file")
append_container_head_bytes :: proc(dst: ^[dynamic]u8, object: bool, count: int) -> Edit_Error {
	if u64(count) > u64(max(u32)) {
		return edit.refuse(.Unspellable_Value, "container exceeds MessagePack max count")
	}
	c := u32(count)
	switch {
	case c <= 15:
		append(dst, (0x80 if object else 0x90) | u8(c)) or_return
	case c <= 0xffff:
		b: [3]u8 = {0xde if object else 0xdc, 0, 0}
		endian.unchecked_put_u16be(b[1:], u16(c))
		append(dst, ..b[:]) or_return
	case:
		b: [5]u8 = {0xdf if object else 0xdd, 0, 0, 0, 0}
		endian.unchecked_put_u32be(b[1:], c)
		append(dst, ..b[:]) or_return
	}
	return nil
}

@(private = "file")
emit_scalar_node :: proc(cx: ^Edit_Cx, n: ^edit.Edit_Node, dst: ^[dynamic]u8) -> Edit_Error {
	tag_mode, ext_type := parse_tag_override(cx, n) or_return
	#partial switch n.val.kind {
	case .Null:
		if tag_mode == .Ext_Int || tag_mode == .Datetime {
			return edit.refuse(.Fact_No_Place, "cannot apply MessagePack ext tag to null", n.base)
		}
		append(dst, 0xc0) or_return
	case .False:
		if tag_mode == .Ext_Int || tag_mode == .Datetime {
			return edit.refuse(.Fact_No_Place, "cannot apply MessagePack ext tag to boolean", n.base)
		}
		append(dst, 0xc2) or_return
	case .True:
		if tag_mode == .Ext_Int || tag_mode == .Datetime {
			return edit.refuse(.Fact_No_Place, "cannot apply MessagePack ext tag to boolean", n.base)
		}
		append(dst, 0xc3) or_return
	case .Int:
		if tag_mode == .Ext_Int || tag_mode == .Datetime {
			return edit.refuse(.Fact_No_Place, "cannot apply MessagePack ext tag to integer", n.base)
		}
		put_compact_number_bytes(dst, {u64(n.val.i), .Int}) or_return
	case .Uint:
		if tag_mode == .Ext_Int || tag_mode == .Datetime {
			return edit.refuse(.Fact_No_Place, "cannot apply MessagePack ext tag to unsigned integer", n.base)
		}
		put_compact_number_bytes(dst, {n.val.u, .Uint}) or_return
	case .Float:
		if tag_mode == .Ext_Int || tag_mode == .Datetime {
			return edit.refuse(.Fact_No_Place, "cannot apply MessagePack ext tag to float", n.base)
		}
		put_compact_number_bytes(dst, {transmute(u64)n.val.f, .Float}) or_return
	case .Number_Text:
		if tag_mode == .Ext_Int || tag_mode == .Datetime {
			return edit.refuse(.Fact_No_Place, "cannot apply MessagePack ext tag to number", n.base)
		}
		num, ok := parse_token_number(n.val.text)
		if !ok {
			return edit.refuse(.Unspellable_Value, "number cannot be represented in MessagePack", n.base)
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
			append_msgpack_ext(dst, ext_type, n.val.raw, n.base) or_return
			return nil
		}
		append_msgpack_bin(dst, n.val.raw, n.base) or_return
	case .Raw:
		append(dst, n.val.text) or_return
	case:
		return edit.refuse(.Unspellable_Value, "unsupported edit value kind", n.base)
	}
	return nil
}

@(private = "file")
emit_msgpack_iterative :: proc(cx: ^Edit_Cx, out: ^[dynamic]u8, recs: ^[dynamic]edit.Splice_Record) -> Edit_Error {
	Item_Ref :: struct {
		handle:      Handle,
		base_key:    tape.Node_Index,
		base_val:    tape.Node_Index,
		key_text:    string,
		use_key_str: bool,
	}
	Frame :: struct {
		is_obj:     bool,
		items:      []Item_Ref,
		owned_keys: []string,
		idx:        int,
	}
	stack := make([dynamic]Frame, 0, 32, cx.allocator)
	defer {
		for &fr in stack {
			delete(fr.items, cx.allocator)
			for s in fr.owned_keys {
				delete(s, cx.allocator)
			}
			delete(fr.owned_keys, cx.allocator)
		}
		delete(stack)
	}

	emit_or_push :: proc(
		cx: ^Edit_Cx,
		dst: ^[dynamic]u8,
		recs: ^[dynamic]edit.Splice_Record,
		stack: ^[dynamic]Frame,
		h: Handle,
		base_node: tape.Node_Index,
	) -> Edit_Error {
		if h == edit.NO_HANDLE {
			if cx.verbatim_ok {
				tags_lo, _, item_hi := item_span(cx.doc, base_node)
				append(dst, ..cx.src[tags_lo:item_hi]) or_return
				return nil
			}
			return write_base_subtree(cx, base_node, dst)
		}
		n, ok := edit.get_node(cx.ov, h)
		if !ok {
			return edit.refuse(.Bad_Handle, "invalid overlay handle")
		}
		if !n.has_edits && n.base != tape.NO_NODE && n.base_ref == tape.NO_NODE {
			if cx.verbatim_ok {
				tags_lo, _, item_hi := item_span(cx.doc, n.base)
				append(dst, ..cx.src[tags_lo:item_hi]) or_return
				return nil
			}
			return write_base_subtree(cx, n.base, dst)
		}
		tags_lo, item_lo, item_hi: u64
		if n.base != tape.NO_NODE {
			tags_lo, item_lo, item_hi = item_span(cx.doc, n.base)
		}
		dst_start := u64(len(dst))

		if n.state == .Replaced || (n.base == tape.NO_NODE && n.base_ref == tape.NO_NODE) {
			if n.val.kind == .Base_Ref {
				tag_mode, ext_type := parse_tag_override(cx, n) or_return
				if tag_mode == .Keep {
					if cx.verbatim_ok {
						rlo, _, rhi := item_span(cx.doc, n.val.base_ref)
						append(dst, ..cx.src[rlo:rhi]) or_return
					} else {
						write_base_subtree(cx, n.val.base_ref, dst) or_return
					}
				} else {
					ref_node := cx.doc.nodes[n.val.base_ref]
					if ref_node.kind >= .Array {
						return edit.refuse(.Fact_No_Place, "MessagePack ext tag cannot wrap containers", n.base)
					}
					apply_tag_on_base_leaf(cx, n.val.base_ref, tag_mode, ext_type, dst) or_return
				}
			} else if n.val.kind == .Array || n.val.kind == .Object {
				tag_mode, _ := parse_tag_override(cx, n) or_return
				if tag_mode == .Ext_Int || tag_mode == .Datetime {
					return edit.refuse(.Fact_No_Place, "MessagePack ext tag cannot wrap containers", n.base)
				}
				is_obj := n.val.kind == .Object
				items: []Item_Ref
				ok_push := false
				defer if !ok_push {
					delete(items, cx.allocator)
				}
				if is_obj {
					items = make([]Item_Ref, len(n.members), cx.allocator) or_return
					for m, i in n.members {
						items[i] = {handle = m.value, base_val = tape.NO_NODE, base_key = tape.NO_NODE, key_text = m.key, use_key_str = true}
					}
				} else {
					items = make([]Item_Ref, len(n.elems), cx.allocator) or_return
					for e, i in n.elems {
						items[i] = {handle = e, base_val = tape.NO_NODE, base_key = tape.NO_NODE}
					}
				}
				append_container_head_bytes(dst, is_obj, len(items)) or_return
				append(stack, Frame{is_obj = is_obj, items = items}) or_return
				ok_push = true
				if n.base != tape.NO_NODE {
					append(recs, edit.Splice_Record{
						base_node   = n.base,
						src_lo      = tags_lo,
						src_hi      = item_hi,
						dst_lo      = dst_start,
						dst_hi      = dst_start,
						full_rewalk = true,
					}) or_return
				}
				return nil
			} else {
				emit_scalar_node(cx, n, dst) or_return
			}
			if n.base != tape.NO_NODE {
				append(recs, edit.Splice_Record{
					base_node    = n.base,
					src_lo       = tags_lo,
					src_hi       = item_hi,
					dst_lo       = dst_start,
					dst_hi       = u64(len(dst)),
					subtree_only = true,
				}) or_return
			}
			return nil
		}

		// Base node in `.Ancestor` or `.Container_Delta` (including `.Base_Ref` containers with structural edits):
		base_c := edit.node_base_container(n)
		if base_c == tape.NO_NODE {
			return edit.refuse(.Bad_Handle, "missing base container for overlay edit")
		}
		bnode := cx.doc.nodes[base_c]
		err_node := n.base if n.base != tape.NO_NODE else base_c
		if bnode.kind < .Array {
			tag_mode, ext_type := parse_tag_override(cx, n) or_return
			if tag_mode == .Keep {
				if cx.verbatim_ok {
					append(dst, ..cx.src[tags_lo:item_hi]) or_return
				} else {
					write_base_subtree(cx, base_c, dst) or_return
				}
			} else {
				if !read_as_msgpack(cx.doc) {
					for f in tape.facts_of(cx.doc, base_c) {
						if f.kind != .Tag {
							cx.dropped += {f.kind}
						}
					}
				}
				apply_tag_on_base_leaf(cx, base_c, tag_mode, ext_type, dst) or_return
			}
			if n.base != tape.NO_NODE {
				append(recs, edit.Splice_Record{
					base_node    = n.base,
					src_lo       = tags_lo,
					src_hi       = item_hi,
					dst_lo       = dst_start,
					dst_hi       = u64(len(dst)),
					subtree_only = true,
				}) or_return
			}
			return nil
		}

		tag_mode, _ := parse_tag_override(cx, n) or_return
		if tag_mode == .Ext_Int || tag_mode == .Datetime {
			return edit.refuse(.Fact_No_Place, "MessagePack ext tag cannot wrap containers", err_node)
		}
		if !read_as_msgpack(cx.doc) {
			for f in tape.facts_of(cx.doc, base_c) {
				if f.kind != .Tag || tag_mode != .Delete {
					cx.dropped += {f.kind}
				}
			}
		}
		is_obj := bnode.kind == .Object
		if d := n.delta; n.state == .Container_Delta && d != nil && len(d.order) > 0 {
			bc := max(0, tape.child_count(cx.doc, base_c, bnode))
			deleted_flags := make([]bool, bc, cx.allocator) or_return
			defer delete(deleted_flags, cx.allocator)
			if is_obj {
				c, _, cerr := tape.children(tape.Reader{doc = cx.doc}, base_c, cx.allocator)
				if cerr != nil {
					return cerr
				}
				bi := 0
				for {
					kn, _, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
					if np != .Found || bi >= bc {
						break
					}
					if kn != tape.NO_NODE {
						tk := edit.decode_node_text_tmp(cx.doc, kn, cx.allocator)
						for dk in d.deleted_keys {
							if dk == tk.text {
								deleted_flags[bi] = true
								break
							}
						}
						edit.free_tmp_text(tk, cx.allocator)
					} else if c.keys_n != 0 {
						kt := tape.cell_key(tape.Reader{doc = cx.doc}, c)
						kroom := tape.text_room(cx.doc, kt)
						if kroom == 0 {
							ktext := string(tape.span_bytes(cx.doc, kt.lo, kt.n))
							for dk in d.deleted_keys {
								if dk == ktext {
									deleted_flags[bi] = true
									break
								}
							}
						} else {
							kbuf := make([]u8, kroom, cx.allocator) or_return
							if ktext, kok := tape.node_text(cx.doc, kt, kbuf); kok {
								for dk in d.deleted_keys {
									if dk == ktext {
										deleted_flags[bi] = true
										break
									}
								}
							}
							delete(kbuf, cx.allocator)
						}
					}
					bi += 1
				}
				tape.destroy_children(&c)
				edit.validate_order(d.order, deleted_flags[:bi], len(d.inserted_members), cx.allocator) or_return
			} else {
				for di in d.deleted_indices {
					if int(di) < bc {
						deleted_flags[di] = true
					}
				}
				edit.validate_order(d.order, deleted_flags, len(d.inserted_elems), cx.allocator) or_return
			}
		}

		items: []Item_Ref
		owned_keys: []string
		ok_push := false
		defer if !ok_push {
			delete(items, cx.allocator)
			for s in owned_keys {
				delete(s, cx.allocator)
			}
			delete(owned_keys, cx.allocator)
		}
		if is_obj {
			eff, ok_keys, merr := edit.effective_members(cx.ov, h, cx.allocator)
			if merr != nil {
				return merr
			}
			owned_keys = ok_keys
			defer delete(eff, cx.allocator)
			items = make([]Item_Ref, len(eff), cx.allocator) or_return
			for m, i in eff {
				items[i] = {
					handle      = m.handle,
					base_key    = m.base_key,
					base_val    = m.base_val,
					key_text    = m.key,
					use_key_str = m.is_inserted || m.renamed || m.base_key == tape.NO_NODE,
				}
			}
		} else {
			eff, eerr := edit.effective_elements(cx.ov, h, cx.allocator)
			if eerr != nil {
				return eerr
			}
			defer delete(eff, cx.allocator)
			items = make([]Item_Ref, len(eff), cx.allocator) or_return
			for e, i in eff {
				items[i] = {handle = e.handle, base_key = tape.NO_NODE, base_val = e.base}
			}
		}

		head_start := len(dst)
		append_container_head_bytes(dst, is_obj, len(items)) or_return
		if n.base != tape.NO_NODE {
			orig_head_len := u64(container_head_len(cx.src[item_lo])) if read_as_msgpack(cx.doc) && n.base_ref == tape.NO_NODE else u64(0)
			head_changed := u64(len(dst) - head_start) != orig_head_len
			if n.state == .Container_Delta || n.base_ref != tape.NO_NODE || head_changed || !cx.verbatim_ok {
				append(recs, edit.Splice_Record{
					base_node   = n.base,
					src_lo      = tags_lo,
					src_hi      = item_hi,
					dst_lo      = dst_start,
					dst_hi      = dst_start,
					full_rewalk = true,
				}) or_return
			}
		}
		append(stack, Frame{is_obj = is_obj, items = items, owned_keys = owned_keys}) or_return
		ok_push = true
		return nil
	}

	emit_or_push(cx, out, recs, &stack, cx.ov.root, tape.ROOT) or_return
	for len(stack) > 0 {
		fr := &stack[len(stack) - 1]
		if fr.idx >= len(fr.items) {
			delete(fr.items, cx.allocator)
			for s in fr.owned_keys {
				delete(s, cx.allocator)
			}
			delete(fr.owned_keys, cx.allocator)
			pop(&stack)
			continue
		}
		item := fr.items[fr.idx]
		fr.idx += 1
		if fr.is_obj {
			if item.use_key_str {
				append_msgpack_str(out, item.key_text, item.base_key) or_return
			} else if cx.verbatim_ok {
				ktlo, _, khi := item_span(cx.doc, item.base_key)
				append(out, ..cx.src[ktlo:khi]) or_return
			} else {
				append_compact_base_key(cx, item.base_key, out) or_return
			}
		}
		emit_or_push(cx, out, recs, &stack, item.handle, item.base_val) or_return
	}
	return nil
}

@(private = "file")
append_compact_base_key :: proc(cx: ^Edit_Cx, base_key: tape.Node_Index, dst: ^[dynamic]u8) -> Edit_Error {
	bnode := cx.doc.nodes[base_key]
	is_mp := read_as_msgpack(cx.doc)
	if !is_mp {
		for f in tape.facts_of(cx.doc, base_key) {
			cx.dropped += {f.kind}
		}
		if cx.doc.format != nil && cx.doc.format.fact_name != nil {
			if _, has := cx.doc.format.fact_name(cx.doc, base_key, .Tag); has {
				cx.dropped += {.Tag}
			}
		}
	}
	#partial switch bnode.kind {
	case .Number:
		if is_mp {
			put_compact_number_bytes(dst, number_value(cx.src, bnode)) or_return
			return nil
		}
		num, ok := tape.node_number(cx.doc, base_key)
		if !ok || (num.kind != .Int && num.kind != .Uint) {
			return edit.refuse(.Unspellable_Value, "unsupported MessagePack map key number", base_key)
		}
		put_compact_number_bytes(dst, num) or_return
		return nil
	case .Bytes:
		return append_msgpack_bin(dst, tape.span_bytes(cx.doc, bnode.lo, bnode.n), base_key)
	case .String, .Plain:
		if is_mp && bnode.spelling & STR_TIMESTAMP != 0 {
			sec, nsec, tok := timestamp_decode(tape.span_bytes(cx.doc, bnode.lo, bnode.n))
			if !tok {
				return edit.refuse(.Unspellable_Value, "invalid MessagePack timestamp key", base_key)
			}
			append_msgpack_timestamp(dst, sec, nsec) or_return
			return nil
		}
		tk := edit.decode_node_text_tmp(cx.doc, base_key, cx.allocator)
		defer edit.free_tmp_text(tk, cx.allocator)
		return append_msgpack_str(dst, tk.text, base_key)
	}
	return edit.refuse(.Unspellable_Value, "unsupported MessagePack map key kind", base_key)
}

@(private = "file")
apply_tag_on_base_leaf :: proc(cx: ^Edit_Cx, base_idx: tape.Node_Index, mode: Tag_Edit, ext_type: i8, dst: ^[dynamic]u8) -> Edit_Error {
	bnode := cx.doc.nodes[base_idx]
	switch mode {
	case .Keep:
		return write_base_subtree(cx, base_idx, dst)
	case .Delete:
		if bnode.kind == .Bytes {
			return append_msgpack_bin(dst, tape.span_bytes(cx.doc, bnode.lo, bnode.n), base_idx)
		}
		if bnode.kind == .String || bnode.kind == .Plain {
			tk := edit.decode_node_text_tmp(cx.doc, base_idx, cx.allocator)
			defer edit.free_tmp_text(tk, cx.allocator)
			return append_msgpack_str(dst, tk.text, base_idx)
		}
		return write_base_subtree(cx, base_idx, dst)
	case .Datetime:
		if bnode.kind == .Bytes {
			sec, nsec, ok := timestamp_decode(tape.span_bytes(cx.doc, bnode.lo, bnode.n))
			if !ok {
				return edit.refuse(.Fact_No_Place, "MessagePack timestamp requires 4/8/12-byte payload", base_idx)
			}
			append_msgpack_timestamp(dst, sec, nsec) or_return
			return nil
		}
		if bnode.kind == .String || bnode.kind == .Plain {
			tk := edit.decode_node_text_tmp(cx.doc, base_idx, cx.allocator)
			defer edit.free_tmp_text(tk, cx.allocator)
			sec, nsec, ok := spell.date_time_utc(tk.text)
			if !ok {
				return edit.refuse(.Fact_No_Place, "MessagePack datetime tag requires RFC 3339 date-time string", base_idx)
			}
			append_msgpack_timestamp(dst, sec, nsec) or_return
			return nil
		}
		return edit.refuse(.Fact_No_Place, "cannot apply MessagePack datetime tag to this value", base_idx)
	case .Ext_Int:
		if ext_type == -1 {
			if bnode.kind == .Bytes {
				sec, nsec, ok := timestamp_decode(tape.span_bytes(cx.doc, bnode.lo, bnode.n))
				if !ok {
					return edit.refuse(.Fact_No_Place, "MessagePack timestamp requires 4/8/12-byte payload", base_idx)
				}
				append_msgpack_timestamp(dst, sec, nsec) or_return
				return nil
			}
			if bnode.kind == .String || bnode.kind == .Plain {
				tk := edit.decode_node_text_tmp(cx.doc, base_idx, cx.allocator)
				defer edit.free_tmp_text(tk, cx.allocator)
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
		return append_msgpack_ext(dst, ext_type, tape.span_bytes(cx.doc, bnode.lo, bnode.n), base_idx)
	}
	return nil
}
