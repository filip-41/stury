package dsv

import "base:runtime"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import ops_write "stury:lib/ops/write"

// Byte-preserving DSV (CSV, TSV, Plain) editing over `edit.Overlay`, reusing `dsv.write` / `lib/ops/write`
// for cell spelling (`infer` quoting, `.Bytes` base64, BOM/comment guards) and `walk_fragment` splicing.

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
	dopts := dsv_options_of(ov.base, resolved)
	ctx := Dsv_Edit_Ctx{spec = resolved, dopts = dopts}
	tspec := edit.Tabular_Spec {
		target     = as(resolved),
		delimiter  = dopts.delimiter,
		comment    = dopts.comment,
		no_header  = dopts.no_header,
		spell_cell = dsv_spell_cell,
		validate   = dsv_edit_validate,
		data       = &ctx,
	}
	return edit.commit_tabular(ov, &tspec, opts, allocator)
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
	dopts := dsv_options_of(ov.base, resolved)
	ctx := Dsv_Edit_Ctx{spec = resolved, dopts = dopts}
	eff_opts := opts
	eff_opts.target = as(resolved)
	d, serr := edit.splice_document(ov.base, &r, eff_opts, dsv_walk_fragment_cb, &ctx, dsv_full_build_cb, &ctx, allocator)
	if serr != nil {
		edit.destroy_commit_result(&r)
		return {}, {}, serr
	}
	return d, r, nil
}

// Walks ONLY `src[range.lo:range.hi]` as a single DSV cell (including empty cell `""` without full rebuild!).
walk_fragment :: proc(
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	spec := Spec.Csv,
	dopts := tape.Dsv_Options{},
	allocator := context.allocator,
) -> (
	ft: edit.Fragment_Tape,
	err: tape.Error,
) {
	_ = ctx
	sub := src[range.lo:range.hi]
	// Empty cell: fast-path directly to one `.Null`/`.String` node at `range.lo` without full-doc fallback!
	if len(sub) == 0 {
		out_nodes, aerr := make([]tape.Node, 1, allocator)
		if aerr != nil {
			return {}, aerr
		}
		k := tape.Kind.Null if dopts.infer else tape.Kind.String
		out_nodes[0] = tape.Node{lo = range.lo, n = 0, kind = k, role = .Value}
		return edit.Fragment_Tape{nodes = out_nodes, allocator = allocator}, nil
	}
	cell_opts := dopts
	cell_opts.no_header = true
	d := build(sub, spec, {format = cell_opts}, allocator) or_return
	// `d.nodes`: `[0]=Array(table), [1]=Array(row), [2]=cell`.
	sft, serr := edit.shift_fragment_tape(&d, range.lo, 2, 0, allocator)
	if serr != nil {
		return {}, serr
	}
	return sft, nil
}

@(private = "file")
Dsv_Edit_Ctx :: struct {
	spec:  Spec,
	dopts: tape.Dsv_Options,
}

@(private = "file")
resolve_edit_spec :: proc "contextless" (ov: ^Overlay, spec: Maybe(Spec), opts: Edit_Options) -> Spec {
	dsv_spec_of :: #force_inline proc "contextless" (f: ^tape.Format) -> Spec {
		if f != nil && f.id >= FIRST_ID && f.id <= FIRST_ID + 2 {
			return Spec(f.id - FIRST_ID)
		}
		return .Csv
	}
	if opts.target != nil {
		return dsv_spec_of(opts.target)
	}
	if s, ok := spec.?; ok {
		return s
	}
	if ov != nil && ov.base != nil {
		return dsv_spec_of(ov.base.format)
	}
	return .Csv
}

@(private = "file")
dsv_options_of :: proc "contextless" (doc: ^tape.Document, spec: Spec) -> tape.Dsv_Options {
	d: tape.Dsv_Options
	if doc != nil && doc.ext != nil {
		if tex, ok := doc.ext.format.(tape.Tabular_Ext); ok {
			d = tex.options
		}
	}
	if d.delimiter == 0 {
		d.delimiter = spec_delimiter(spec, 0)
	}
	return d
}

@(private = "file")
dsv_walk_fragment_cb :: proc(
	data: rawptr,
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	allocator: runtime.Allocator,
) -> (edit.Fragment_Tape, tape.Error) {
	dc := (^Dsv_Edit_Ctx)(data)
	return walk_fragment(src, range, ctx, dc.spec, dc.dopts, allocator)
}

@(private = "file")
dsv_full_build_cb :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	dc := (^Dsv_Edit_Ctx)(data)
	return build(src, dc.spec, {format = dc.dopts}, allocator)
}

@(private = "file")
dsv_edit_validate :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error {
	dc := (^Dsv_Edit_Ctx)(data)
	return validate(src, dc.spec, {format = dc.dopts}, allocator)
}

// Reuses `dsv.write` (`lib/ops/write/table.odin`) to spell a single scalar cell — automatically inherits
// `dopts.infer` quoting, `.Bytes` base64 encoding, BOM/comment-byte guards, and CSV/TSV/Plain cell rules!
@(private = "file")
dsv_spell_cell :: proc(data: rawptr, ov: ^Overlay, h: Handle, out: ^[dynamic]u8) -> edit.Error {
	dc := (^Dsv_Edit_Ctx)(data)
	if h == edit.NO_HANDLE {
		return nil
	}
	k := edit.node_kind(ov, h)
	if k >= .Array {
		return edit.refuse(.Unspellable_Value, "DSV cell must be a scalar value")
	}
	if n, ok := edit.get_node(ov, h); ok && n.state == .Replaced {
		if n.val.kind == .Raw {
			append(out, n.val.text)
			return nil
		}
		if !dc.dopts.infer && (n.val.kind == .Null || (n.val.kind == .String && len(n.val.text) == 0)) {
			return nil
		}
	}
	// Materialize the single scalar as a 1-cell document and write through `dsv.write` with `no_header = true`.
	tmp_doc := edit.materialize_subtree(ov, h, tape.NO_NODE, {}, ov.allocator) or_return
	defer tape.destroy_document(&tmp_doc)

	cell_opts := dc.dopts
	cell_opts.no_header = true
	cell_opts.crlf = false
	text, _, werr := write(&tmp_doc, dc.spec, {format = cell_opts}, ov.allocator)
	if werr != nil {
		#partial switch e in werr {
		case runtime.Allocator_Error:
			return e
		case ops_write.Refused:
			return edit.refuse(.Unspellable_Value, "value cannot be spelled as a DSV cell", e.node)
		}
		return edit.refuse(.Unspellable_Value, "value cannot be spelled as a DSV cell")
	}
	defer delete(text, ov.allocator)
	// Strip trailing line ending added by `write.table` for a single-cell document.
	cell := text
	if len(cell) > 0 && cell[len(cell) - 1] == '\n' {
		cell = cell[:len(cell) - 1]
		if len(cell) > 0 && cell[len(cell) - 1] == '\r' {
			cell = cell[:len(cell) - 1]
		}
	}
	append(out, ..cell)
	return nil
}
