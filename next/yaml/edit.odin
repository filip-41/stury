package yaml

import "base:runtime"
import "core:bytes"
import "core:container/xar"
import "core:slice"
import "core:unicode/utf8"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import ops_write "stury:lib/ops/write"

// Byte-preserving YAML 1.2 / Yaml_Merge indent composer over `edit.Overlay`.

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
	yaml_opts := tape.Yaml_Options{},
) -> (res: Commit_Result, err: Edit_Error) {
	if yaml_opts.dialect > max(tape.Yaml_Dialect) { return {}, tape.Bad_Option{"format"} }
	resolved := resolve_edit_spec(ov, spec, opts)
	ctx := Yaml_Edit_Ctx{spec = resolved, depth = edit_depth_budget(ov), yaml_opts = yaml_opts}
	fast, target, fast_res, gerr := edit.commit_guard(ov, as(resolved), opts, true, yaml_edit_validate, &ctx, allocator)
	if gerr != nil { return {}, gerr }
	if fast { return fast_res, nil }

	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 64 * 1024}
	defer runtime.arena_destroy(&arena)
	scratch := runtime.arena_allocator(&arena)

	if ov.unlinked_parents { edit.ensure_linked(ov) or_return }

	cx := Cx {
		ov        = ov,
		doc       = ov.base,
		src       = ov.base.src,
		a         = scratch,
		spec      = resolved,
		opts      = opts,
		yaml_opts = yaml_opts,
		eol       = edit.detect_eol(ov.base.src),
		step      = -1,
		seq_off   = -1,
	}
	cx.splices = make([dynamic]edit.Splice, 0, max(8, xar.len(ov.nodes.items)), scratch) or_return
	cx.seen = make(map[u64]struct{}, 16, scratch) or_return
	cx.items = make(map[u32][]Item, 8, scratch) or_return
	cx.reflowed = make(map[u32]struct{}, 4, scratch) or_return
	cx.unshared = make(map[u32]struct{}, 4, scratch) or_return

	collect_merge_info(&cx) or_return
	build_geometry(&cx) or_return
	mark_frozen(&cx) or_return

	if ov.root != edit.NO_HANDLE { compose_walk(&cx, ov.root) or_return }
	for bn, h in ov.by_base {
		if int(bn) >= len(cx.doc.nodes) || cx.doc.nodes[bn].role != .Key || cx.dead[bn] { continue }
		skip := false
		for anc := cx.parent[bn]; anc != NIL; anc = cx.parent[anc] {
			if cx.dead[anc] || (anc in cx.reflowed) { skip = true; break }
		}
		if !skip {
			if n, ok := edit.get_node(ov, h); ok && n.has_edits && n.state == .Replaced {
				apply_key_replace(&cx, u32(bn), n) or_return
			}
		}
	}

	out, recs, rew, serr := edit.apply_splices(cx.doc.src, cx.splices[:], allocator)
	if serr != nil {
		delete(recs, allocator); delete(rew, allocator); delete(out, allocator)
		if !opts.reflow { return {}, serr }
		return reflow_fallback(&cx, allocator)
	}

	val_opts := Options{budget = {depth = ctx.depth}, format = yaml_opts}
	need_full := target != cx.doc.format || len(recs) == 0
	for rec in recs {
		if need_full { break }
		if !rec.subtree_only || rec.full_rewalk { need_full = true }
	}
	verr: tape.Error
	if !need_full {
		for rec in recs {
			frag := out[rec.dst_lo:rec.dst_hi]
			if bytes.index_any(frag, transmute([]u8)string("\n\r#*&!%")) >= 0 ||
				(len(frag) >= 3 && (string(frag[:3]) == "---" || string(frag[:3]) == "...")) {
				need_full = true
				break
			}
			if verr = validate(frag, resolved, val_opts, scratch); verr != nil { break }
		}
	}
	if verr == nil && need_full { verr = validate(out, resolved, val_opts, allocator) }
	if verr != nil {
		delete(out, allocator); delete(recs, allocator); delete(rew, allocator)
		return {}, convert_tape_error(verr)
	}
	return Commit_Result{bytes = out, dropped = cx.dropped, rewritten = rew, splices = recs, allocator = allocator}, nil
}

commit_as :: proc(ov: ^Overlay, spec: Spec, opts := Edit_Options{}, allocator := context.allocator, yaml_opts := tape.Yaml_Options{}) -> (Commit_Result, Edit_Error) {
	o := opts
	o.target = as(spec)
	return commit(ov, spec, o, allocator, yaml_opts)
}

commit_document :: proc(
	ov: ^Overlay,
	spec: Maybe(Spec) = nil,
	opts := Edit_Options{},
	allocator := context.allocator,
	yaml_opts := tape.Yaml_Options{},
) -> (doc: tape.Document, res: Commit_Result, err: Edit_Error) {
	if yaml_opts.dialect > max(tape.Yaml_Dialect) { return {}, {}, tape.Bad_Option{"format"} }
	resolved := resolve_edit_spec(ov, spec, opts)
	res = commit(ov, resolved, opts, allocator, yaml_opts) or_return
	defer if err != nil { edit.destroy_commit_result(&res) }
	ctx := Yaml_Edit_Ctx{spec = resolved, depth = edit_depth_budget(ov), yaml_opts = yaml_opts}
	eff_opts := opts
	eff_opts.target = as(resolved)
	doc = edit.splice_document(ov.base, &res, eff_opts, yaml_walk_fragment_cb, &ctx, yaml_full_build_cb, &ctx, allocator) or_return
	return doc, res, nil
}

commit_document_as :: proc(ov: ^Overlay, spec: Spec, opts := Edit_Options{}, allocator := context.allocator, yaml_opts := tape.Yaml_Options{}) -> (tape.Document, Commit_Result, Edit_Error) {
	o := opts
	o.target = as(spec)
	return commit_document(ov, spec, o, allocator, yaml_opts)
}

walk_fragment :: proc(
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	spec := Spec.Yaml_1_2,
	allocator := context.allocator,
	yaml_opts := tape.Yaml_Options{},
) -> (ft: edit.Fragment_Tape, err: tape.Error) {
	_ = ctx
	d := build(src[range.lo:range.hi], spec, {format = yaml_opts}, allocator) or_return
	defer destroy(&d)
	ft_out, aerr := edit.shift_fragment_tape(&d, range.lo, 0, 0, allocator)
	if aerr != nil { return {}, aerr }
	return ft_out, nil
}

// ---------- Internal Types & Helpers ----------

@(private = "file")
Yaml_Edit_Ctx :: struct {
	spec:      Spec,
	depth:     u32,
	yaml_opts: tape.Yaml_Options,
}

@(private = "file")
edit_depth_budget :: proc "contextless" (ov: ^Overlay) -> u32 {
	if ov != nil && ov.base != nil { return max(u32(tape.DEFAULT_DEPTH), u32(len(ov.base.nodes) + 64)) }
	return u32(tape.DEFAULT_DEPTH)
}

@(private = "file")
resolve_edit_spec :: proc "contextless" (ov: ^Overlay, spec: Maybe(Spec), opts: Edit_Options) -> Spec {
	if opts.target != nil { return yaml_spec_from_format(opts.target) }
	if s, ok := spec.?; ok { return s }
	if ov != nil && ov.base != nil && ov.base.format != nil { return yaml_spec_from_format(ov.base.format) }
	return .Yaml_1_2
}

@(private = "file")
yaml_spec_from_format :: proc "contextless" (f: ^tape.Format) -> Spec {
	return .Yaml_Merge if f != nil && f.id == ID + tape.Format_Id(Spec.Yaml_Merge) else .Yaml_1_2
}

@(private = "file")
yaml_walk_fragment_cb :: proc(data: rawptr, src: []u8, range: edit.Byte_Range, ctx: edit.Fragment_Context, allocator: runtime.Allocator) -> (edit.Fragment_Tape, tape.Error) {
	yc := (^Yaml_Edit_Ctx)(data)
	return walk_fragment(src, range, ctx, yc.spec, allocator, yc.yaml_opts)
}

@(private = "file")
yaml_full_build_cb :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	yc := (^Yaml_Edit_Ctx)(data)
	return build(src, yc.spec, {budget = {depth = yc.depth}, format = yc.yaml_opts}, allocator)
}

@(private = "file")
yaml_edit_validate :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error {
	yc := (^Yaml_Edit_Ctx)(data)
	return validate(src, yc.spec, {budget = {depth = yc.depth}, format = yc.yaml_opts}, allocator)
}

@(private = "file")
convert_tape_error :: proc "contextless" (err: tape.Error) -> Edit_Error {
	switch e in err {
	case tape.Fault:             return e
	case tape.Exceeded:          return e
	case tape.Bad_Option:        return e
	case runtime.Allocator_Error: return e
	case tape.Piece_Gap:         return edit.refuse(.Invalid_Result, "unexpected piece gap")
	}
	return nil
}

@(private = "file")
Node_Flag :: enum u8 { Bracket, Flow, Alias, After_Props, Merged_Member }

@(private = "file")
Node_Flags :: bit_set[Node_Flag; u8]

@(private = "file")
Frozen_Kind :: enum u8 { None, Aliased, Anchored, Merged }

@(private = "file")
NIL :: max(u32)

@(private = "file")
Item :: struct { key, value: u32, start, end: u64 }

@(private = "file")
Text_Form :: enum u8 { Inline, Lines, Block, Literal }

@(private = "file")
Text_Shape :: struct { form: Text_Form, seq: bool, head: int }

@(private = "file")
Merge_Map :: struct {
	raw_lo:        u64,
	true_lo:       u64,
	true_hi:       u64,
	explicit_keys: map[u64]struct{},
	source_keys:   map[string]struct{},
}

@(private = "file")
Merge_Alias :: struct {
	owner_lo:    u64,
	alias_lo:    u64,
	alias_hi:    u64,
	anchor_lo:   u64,
	anchor_kind: tape.Kind,
	flow:        bool,
	parent_col:  int,
}

@(private = "file")
Cx :: struct {
	ov:           ^Overlay,
	doc:          ^tape.Document,
	src:          []u8,
	a:            runtime.Allocator,
	spec:         Spec,
	opts:         Edit_Options,
	yaml_opts:    tape.Yaml_Options,
	eol:          string,
	parent:       []u32,
	last:         []u32,
	lo, hi:       []u64,
	flags:        []Node_Flags,
	frozen:       []Frozen_Kind,
	dead:         []bool,
	gone:         []bool,
	anchor_of:    []u32,
	merge_of:     []i32,
	merge_maps:   []Merge_Map,
	merge_aliases: []Merge_Alias,
	writes_alias: bool,
	step:         int,
	seq_off:      int,
	learnt:       bool,
	splices:      [dynamic]edit.Splice,
	seen:         map[u64]struct{},
	items:        map[u32][]Item,
	reflowed:     map[u32]struct{},
	unshared:     map[u32]struct{},
	dropped:      tape.Facts,
}

@(private = "file")
claim_seen :: proc(cx: ^Cx, node: u32, tag: u64, msg: string) -> Edit_Error {
	k := u64(node) << 8 | tag
	if _, existed := cx.seen[k]; existed { return edit.refuse(.Bad_Handle, msg, tape.Node_Index(node)) }
	if _, merr := map_insert(&cx.seen, k, struct{}{}); merr != nil { return merr }
	return nil
}

@(private = "file")
mark_dead_subtree :: proc "contextless" (cx: ^Cx, root: u32) #no_bounds_check {
	if int(root) >= len(cx.dead) { return }
	for i in root ..< root + subtree_len(cx.doc, tape.Node_Index(root)) { cx.dead[i] = true }
}

@(private = "file")
is_container :: #force_inline proc "contextless" (k: tape.Kind) -> bool { return k == .Array || k == .Object }

@(private = "file")
is_block :: #force_inline proc "contextless" (cx: ^Cx, i: u32) -> bool {
	return is_container(cx.doc.nodes[i].kind) && cx.flags[i] & {.Bracket, .Alias} == {}
}

@(private = "file")
subtree_len :: #force_inline proc "contextless" (doc: ^tape.Document, idx: tape.Node_Index) -> u32 #no_bounds_check {
	n := doc.nodes[idx]
	return n.n if n.kind >= .Array else 1
}

@(private = "file")
collect_merge_info :: proc(cx: ^Cx) -> Edit_Error {
	if cx.doc.format != &FORMATS[.Yaml_Merge] || !bytes.contains(cx.src, transmute([]u8)string("<<")) { return nil }
	depth := max(u32(tape.DEFAULT_DEPTH), u32(len(cx.doc.nodes) + 64))
	raw_doc, berr := build(cx.src, .Yaml_1_2, {budget = {depth = depth}, format = cx.yaml_opts}, cx.a)
	if berr != nil { return nil }
	defer tape.destroy_document(&raw_doc)

	rn := len(raw_doc.nodes)
	if rn == 0 { return nil }
	rlo := make([]u64, rn, cx.a) or_return
	rhi := make([]u64, rn, cx.a) or_return
	rparent := make([]u32, rn, cx.a) or_return
	rlast := make([]u32, rn, cx.a) or_return
	rflags := make([]Node_Flags, rn, cx.a) or_return
	Open :: struct { id, end: u32 }
	stack := make([dynamic]Open, 0, 16, cx.a) or_return
	fi := 0
	copy_end := u32(0)
	for i in 0 ..< rn {
		for len(stack) > 0 && u32(i) >= stack[len(stack) - 1].end { pop(&stack) }
		p := stack[len(stack) - 1].id if len(stack) > 0 else NIL
		rparent[i], rlast[i] = p, NIL
		if p != NIL {
			rlast[p] = u32(i)
			if .Flow in rflags[p] { rflags[i] += {.Flow} }
		}
		nd := raw_doc.nodes[i]
		head, tail := bounds(cx.src, nd)
		lo, hi := nd.lo - u64(head), nd.lo + u64(nd.n) + u64(tail)
		for fi < len(raw_doc.facts) && raw_doc.facts[fi].node < tape.Node_Index(i) { fi += 1 }
		for k := fi; k < len(raw_doc.facts) && raw_doc.facts[k].node == tape.Node_Index(i); k += 1 {
			if f := raw_doc.facts[k]; f.kind == .Alias {
				rflags[i] += {.Alias}
				lo, hi = f.lo, f.lo + u64(f.n)
			}
		}
		if u32(i) >= copy_end && (.Alias in rflags[i]) {
			copy_end = u32(i) + subtree_len(&raw_doc, tape.Node_Index(i))
		}
		if is_container(nd.kind) {
			if .Alias not_in rflags[i] {
				lo = nd.lo
				if is_flow(&raw_doc, nd) {
					rflags[i] += {.Bracket, .Flow}
					hi = flow_close_end(cx.src, lo)
				} else if nd.kind == .Object && i + 1 < rn {
					lo = min(lo, key_start(&raw_doc, cx.src, u32(i + 1), max(lo, raw_doc.nodes[i + 1].lo)))
				}
			}
			append(&stack, Open{u32(i), u32(i) + nd.n}) or_return
		}
		rlo[i], rhi[i] = lo, hi
	}
	for i := rn - 1; i >= 0; i -= 1 {
		if is_container(raw_doc.nodes[i].kind) && rflags[i] & {.Bracket, .Alias} == {} {
			rhi[i] = rhi[rlast[i]] if rlast[i] != NIL else rlo[i]
		}
	}

	mmaps := make([dynamic]Merge_Map, 0, 4, cx.a) or_return
	maliases := make([dynamic]Merge_Alias, 0, 4, cx.a) or_return

	collect_src_obj :: proc(cx: ^Cx, rdoc: ^tape.Document, obj: u32, rflags: []Node_Flags, owner_lo: u64, parent_flow: bool, parent_col: int, skeys: ^map[string]struct{}, maliases: ^[dynamic]Merge_Alias) -> Edit_Error {
		if .Alias in rflags[obj] {
			for f in tape.facts_of(rdoc, tape.Node_Index(obj)) {
				if f.kind == .Alias {
					append(maliases, Merge_Alias{
						owner_lo    = owner_lo,
						alias_lo    = f.lo,
						alias_hi    = f.lo + u64(f.n),
						anchor_lo   = rdoc.nodes[obj].lo,
						anchor_kind = rdoc.nodes[obj].kind,
						flow        = parent_flow,
						parent_col  = parent_col,
					}) or_return
					break
				}
			}
		}
		end := obj + rdoc.nodes[obj].n
		for j := obj + 1; j < end; {
			k := j
			v := k + 1
			tk := edit.decode_node_text_tmp(rdoc, tape.Node_Index(k), cx.a).text
			cloned := string(slice.clone(transmute([]u8)tk, cx.a) or_return)
			if _, merr := map_insert(skeys, cloned, struct{}{}); merr != nil { return merr }
			j = v + subtree_len(rdoc, tape.Node_Index(v))
		}
		return nil
	}

	for i := u32(0); i < u32(rn); i += 1 {
		if raw_doc.nodes[i].kind != .Object || (.Alias in rflags[i]) { continue }
		end := i + raw_doc.nodes[i].n
		has_active := false
		for j := i + 1; j < end; {
			k, v := j, j + 1
			kn := raw_doc.nodes[k]
			if (kn.kind == .String || kn.kind == .Plain) && kn.n == 2 && style_of(kn.spelling) == .Plain && cx.src[kn.lo] == '<' && cx.src[kn.lo + 1] == '<' {
				vn := raw_doc.nodes[v]
				if vn.kind == .Object {
					has_active = true; break
				} else if vn.kind == .Array && vn.n > 1 {
					all_obj := true
					cnt := 0
					for e := v + 1; e < v + vn.n; e += subtree_len(&raw_doc, tape.Node_Index(e)) {
						if raw_doc.nodes[e].kind != .Object { all_obj = false; break }
						cnt += 1
					}
					if all_obj && cnt > 0 { has_active = true; break }
				}
			}
			j = v + subtree_len(&raw_doc, tape.Node_Index(v))
		}
		if !has_active { continue }

		mm := Merge_Map {
			raw_lo        = raw_doc.nodes[i].lo,
			true_lo       = rlo[i],
			true_hi       = rhi[i],
			explicit_keys = make(map[u64]struct{}, 8, cx.a) or_return,
			source_keys   = make(map[string]struct{}, 8, cx.a) or_return,
		}
		pcol := column_of(cx.src, rlo[i])
		for j := i + 1; j < end; {
			k, v := j, j + 1
			kn, vn := raw_doc.nodes[k], raw_doc.nodes[v]
			is_merge := false
			if (kn.kind == .String || kn.kind == .Plain) && kn.n == 2 && style_of(kn.spelling) == .Plain && cx.src[kn.lo] == '<' && cx.src[kn.lo + 1] == '<' {
				if vn.kind == .Object {
					is_merge = true
					collect_src_obj(cx, &raw_doc, v, rflags, mm.raw_lo, .Flow in rflags[i], pcol, &mm.source_keys, &maliases) or_return
				} else if vn.kind == .Array && vn.n > 1 {
					all_obj := true
					for e := v + 1; e < v + vn.n; e += subtree_len(&raw_doc, tape.Node_Index(e)) {
						if raw_doc.nodes[e].kind != .Object { all_obj = false; break }
					}
					if all_obj {
						is_merge = true
						for e := v + 1; e < v + vn.n; e += subtree_len(&raw_doc, tape.Node_Index(e)) {
							collect_src_obj(cx, &raw_doc, e, rflags, mm.raw_lo, .Flow in rflags[v], pcol, &mm.source_keys, &maliases) or_return
						}
					}
				}
			}
			if !is_merge {
				if _, merr := map_insert(&mm.explicit_keys, kn.lo, struct{}{}); merr != nil { return merr }
			}
			j = v + subtree_len(&raw_doc, tape.Node_Index(v))
		}
		append(&mmaps, mm) or_return
	}
	cx.merge_maps = mmaps[:]
	cx.merge_aliases = maliases[:]
	return nil
}

@(private = "file")
build_geometry :: proc(cx: ^Cx) -> Edit_Error {
	doc, nodes := cx.doc, cx.doc.nodes
	n := len(nodes)
	cx.parent = make([]u32, n, cx.a) or_return
	cx.last = make([]u32, n, cx.a) or_return
	cx.lo = make([]u64, n, cx.a) or_return
	cx.hi = make([]u64, n, cx.a) or_return
	cx.flags = make([]Node_Flags, n, cx.a) or_return
	cx.dead = make([]bool, n, cx.a) or_return
	cx.anchor_of = make([]u32, n, cx.a) or_return
	cx.merge_of = make([]i32, n, cx.a) or_return
	slice.fill(cx.anchor_of, NIL)
	slice.fill(cx.merge_of, i32(-1))

	merge_by_lo := make(map[u64]i32, max(4, len(cx.merge_maps)), cx.a) or_return
	for mm, idx in cx.merge_maps {
		if _, merr := map_insert(&merge_by_lo, mm.raw_lo, i32(idx)); merr != nil { return merr }
	}
	anchor_by_pos := make(map[[2]u64]u32, 8, cx.a) or_return

	Open :: struct { id, end: u32 }
	stack := make([dynamic]Open, 0, 16, cx.a) or_return
	fi := 0
	copy_end, last_node := u32(0), NIL
	last_lo, last_end := u64(0), u64(0)
	for i in 0 ..< n {
		for len(stack) > 0 && u32(i) >= stack[len(stack) - 1].end { pop(&stack) }
		p := stack[len(stack) - 1].id if len(stack) > 0 else NIL
		cx.parent[i], cx.last[i] = p, NIL
		if p != NIL {
			cx.last[p] = u32(i)
			if .Flow in cx.flags[p] { cx.flags[i] += {.Flow} }
			if .Merged_Member in cx.flags[p] { cx.flags[i] += {.Merged_Member} }
		}
		nd := nodes[i]
		head, tail := bounds(cx.src, nd)
		lo, hi := nd.lo - u64(head), nd.lo + u64(nd.n) + u64(tail)
		for fi < len(doc.facts) && doc.facts[fi].node < tape.Node_Index(i) { fi += 1 }
		props_end := u64(0)
		has_anchor := false
		for k := fi; k < len(doc.facts) && doc.facts[k].node == tape.Node_Index(i); k += 1 {
			#partial switch f := doc.facts[k]; f.kind {
			case .Alias:
				cx.flags[i] += {.Alias}
				lo, hi = f.lo, f.lo + u64(f.n)
			case .Tag:
				props_end = max(props_end, f.lo + u64(f.n))
			case .Anchor:
				has_anchor = true
				props_end = max(props_end, f.lo + u64(f.n))
			}
		}
		is_merged_key := false
		if u32(i) >= copy_end && p != NIL && cx.merge_of[p] >= 0 && nd.role == .Key {
			mm := &cx.merge_maps[cx.merge_of[p]]
			if !(nd.lo in mm.explicit_keys) {
				is_merged_key = true
				cx.flags[i] += {.Merged_Member}
				if i + 1 < n {
					val_end := u32(i + 1) + subtree_len(doc, tape.Node_Index(i + 1))
					for j in u32(i + 1) ..< val_end { cx.flags[j] += {.Merged_Member} }
					copy_end = val_end
				}
			}
		}
		switch {
		case is_merged_key || u32(i) < copy_end:
		case .Alias in cx.flags[i]:
			if anch, found := anchor_by_pos[[2]u64{nd.lo, u64(nd.kind)}]; found { cx.anchor_of[i] = anch }
			copy_end = u32(i) + subtree_len(doc, tape.Node_Index(i))
			last_end = max(last_end, hi)
		case nd.role == .Key && (nd.lo < last_lo || nd.lo == last_lo && (last_node != p || u32(i) != p + 1)):
			cx.flags[i] += {.Alias}
			if anch, found := anchor_by_pos[[2]u64{nd.lo, u64(nd.kind)}]; found { cx.anchor_of[i] = anch }
			lo, hi = alias_key_at(cx.src, cx.lo[p] if u32(i) == p + 1 else last_end, .Flow in cx.flags[i])
			last_end = hi
		case:
			if has_anchor {
				if _, merr := map_insert(&anchor_by_pos, [2]u64{nd.lo, u64(nd.kind)}, u32(i)); merr != nil { return merr }
			}
			if nd.lo >= last_lo { last_lo, last_node = nd.lo, u32(i) }
			if nd.kind <= .Plain && nd.n == 0 {
				if nd.role == .Key { props_end = key_props_end(cx.src, lo) }
				if props_end > lo {
					lo, hi = props_end, props_end
					cx.flags[i] += {.After_Props}
				} else if p != NIL && nodes[p].kind == .Object && nd.role == .Value && lo < cx.hi[i - 1] {
					lo, hi = cx.hi[i - 1], cx.hi[i - 1]
				}
			}
			last_end = max(last_end, hi)
		}
		if is_container(nd.kind) {
			if .Alias not_in cx.flags[i] && .Merged_Member not_in cx.flags[i] {
				if nd.kind == .Object {
					if midx, is_m := merge_by_lo[nd.lo]; is_m {
						cx.merge_of[i] = midx
						lo = cx.merge_maps[midx].true_lo
						hi = cx.merge_maps[midx].true_hi
						if is_flow(doc, nd) { cx.flags[i] += {.Bracket, .Flow} }
						last_end = max(last_end, hi)
					} else {
						lo = nd.lo
						if is_flow(doc, nd) {
							cx.flags[i] += {.Bracket, .Flow}
							hi = flow_close_end(cx.src, lo)
						} else if i + 1 < n {
							lo = min(lo, key_start(doc, cx.src, u32(i + 1), max(lo, nodes[i + 1].lo)))
						}
					}
				} else {
					lo = nd.lo
					if is_flow(doc, nd) {
						cx.flags[i] += {.Bracket, .Flow}
						hi = flow_close_end(cx.src, lo)
					}
				}
			}
			append(&stack, Open{u32(i), u32(i) + nd.n}) or_return
		}
		cx.lo[i], cx.hi[i] = lo, hi
	}
	for i := n - 1; i >= 0; i -= 1 {
		if is_block(cx, u32(i)) && cx.merge_of[i] < 0 { cx.hi[i] = cx.hi[cx.last[i]] if cx.last[i] != NIL else cx.lo[i] }
	}
	return nil
}

@(private = "file")
alias_key_at :: proc "contextless" (src: []u8, from: u64, flow: bool) -> (lo, hi: u64) #no_bounds_check {
	lo = from
	for lo < u64(len(src)) {
		at_tok := lo == 0 || kernel.is_ws(src[lo - 1])
		if src[lo] == '#' && at_tok { lo = content_end(src, lo); continue }
		if src[lo] == '*' && (at_tok || bytes.index_byte(transmute([]u8)string(",[{?"), src[lo - 1]) >= 0) { break }
		lo += 1
	}
	hi = lo + 1
	for hi < u64(len(src)) && !kernel.is_ws(src[hi]) && !(flow && is_flow_indicator(src[hi])) { hi += 1 }
	return
}

@(private = "file")
key_props_end :: proc "contextless" (src: []u8, p: u64) -> u64 #no_bounds_check {
	end := p
	for i := p; i < u64(len(src)); {
		for i < u64(len(src)) && (src[i] == ' ' || src[i] == '\t') { i += 1 }
		if i == u64(len(src)) || (src[i] != '!' && src[i] != '&') { return end }
		for i < u64(len(src)) && !kernel.is_ws(src[i]) { i += 1 }
		end = i
	}
	return end
}

@(private = "file")
props_lo :: proc "contextless" (doc: ^tape.Document, i: u32, lo: u64) -> u64 #no_bounds_check {
	at := lo
	for f in tape.facts_of(doc, tape.Node_Index(i)) {
		if f.kind == .Tag || f.kind == .Anchor { at = min(at, f.lo) }
	}
	return at
}

@(private = "file")
key_start :: proc "contextless" (doc: ^tape.Document, src: []u8, j: u32, lo: u64) -> u64 #no_bounds_check {
	at := props_lo(doc, j, lo)
	if doc.nodes[j].n == 0 {
		q := at
		for q > 0 && kernel.is_ws(src[q - 1]) { q -= 1 }
		if q > 0 && src[q - 1] == '?' { return q - 1 }
	}
	for {
		k := lead_end(src, at)
		if k == at { return at }
		t := k
		for t > 0 && !kernel.is_ws(src[t - 1]) { t -= 1 }
		if src[t] != '!' && src[t] != '&' {
			for f := k; f > t; f -= 1 {
				if src[f - 1] == ',' || src[f - 1] == '[' || src[f - 1] == '{' { t = f; break }
			}
		}
		switch {
		case t == k:                           return at
		case src[t] == '!' || src[t] == '&':   at = t
		case k - t == 1 && src[t] == '?':      return t
		case:                                  return at
		}
	}
}

@(private = "file")
handle_has_raw_alias :: proc(ov: ^Overlay, h: Handle) -> bool {
	cn, ok := edit.get_node(ov, h)
	return ok && cn.val.kind == .Raw && bytes.index_byte(transmute([]u8)cn.val.text, '*') >= 0
}

@(private = "file")
mark_frozen :: proc(cx: ^Cx) -> Edit_Error {
	doc, nodes := cx.doc, cx.doc.nodes
	cx.frozen = make([]Frozen_Kind, len(nodes), cx.a) or_return

	aliases := make([dynamic]u32, 0, 8, cx.a) or_return
	for i := u32(0); i < u32(len(nodes)); i += 1 {
		if .Alias in cx.flags[i] && cx.frozen[i] == .None {
			for j in i + 1 ..< i + subtree_len(doc, tape.Node_Index(i)) { cx.frozen[j] = .Aliased }
			append(&aliases, i) or_return
		}
	}
	for i := u32(0); i < u32(len(nodes)); i += 1 {
		if cx.merge_of[i] >= 0 && cx.frozen[i] == .None {
			for j in i ..< i + subtree_len(doc, tape.Node_Index(i)) {
				if cx.frozen[j] == .None { cx.frozen[j] = .Merged }
			}
		}
	}
	if len(aliases) == 0 && len(cx.merge_aliases) == 0 { return nil }

	gone := make([]bool, len(nodes), cx.a) or_return
	writes_alias := false
	ov := cx.ov
	for idx in 0 ..< xar.len(ov.nodes.items) {
		en := xar.get_ptr_unsafe(&ov.nodes.items, idx)
		if en.handle.idx == 0 || !en.has_edits { continue }
		for fo in en.facts {
			if !fo.deleted && fo.kind == .Alias { writes_alias = true }
		}
		if en.state == .Replaced {
			if en.val.kind == .Raw && bytes.index_byte(transmute([]u8)en.val.text, '*') >= 0 { writes_alias = true }
			if en.base != tape.NO_NODE && int(en.base) < len(nodes) && nodes[en.base].role == .Value { gone[en.base] = true }
		} else if en.state == .Container_Delta && en.base != tape.NO_NODE && en.delta != nil {
			d := en.delta
			for ins in d.inserted_members { writes_alias ||= handle_has_raw_alias(ov, ins.value) }
			for ins in d.inserted_elems { writes_alias ||= handle_has_raw_alias(ov, ins.value) }
			bc := u32(en.base)
			items := items_of(cx, bc) or_return
			if nodes[bc].kind == .Object && len(d.deleted_keys) > 0 {
				del_set := make(map[string]struct{}, len(d.deleted_keys), cx.a) or_return
				for dk in d.deleted_keys { if _, merr := map_insert(&del_set, dk, struct{}{}); merr != nil { return merr } }
				for it in items {
					if edit.decode_node_text_tmp(doc, tape.Node_Index(it.key), cx.a).text in del_set { gone[it.value] = true }
				}
			} else if nodes[bc].kind == .Array {
				for di in d.deleted_indices { if int(di) < len(items) { gone[items[di].value] = true } }
			}
		}
	}

	if writes_alias {
		slice.fill(gone, false)
	} else {
		for i in 1 ..< len(nodes) { gone[i] ||= gone[cx.parent[i]] }
	}
	cx.gone = gone
	cx.writes_alias = writes_alias

	read_anchors := make(map[[2]u64]struct{}, len(aliases) + len(cx.merge_aliases), cx.a) or_return
	for i in aliases {
		if !gone[i] {
			if _, merr := map_insert(&read_anchors, [2]u64{nodes[i].lo, u64(nodes[i].kind)}, struct{}{}); merr != nil { return merr }
		}
	}
	for ma in cx.merge_aliases {
		owner_gone := false
		for i := u32(0); i < u32(len(nodes)); i += 1 {
			if cx.merge_of[i] >= 0 && nodes[i].lo == ma.owner_lo { owner_gone = gone[i]; break }
		}
		if !owner_gone {
			if _, merr := map_insert(&read_anchors, [2]u64{ma.anchor_lo, u64(ma.anchor_kind)}, struct{}{}); merr != nil { return merr }
		}
	}
	if len(read_anchors) == 0 { return nil }
	for i := u32(0); i < u32(len(nodes)); i += 1 {
		if .Alias not_in cx.flags[i] && .Merged_Member not_in cx.flags[i] && cx.frozen[i] != .Aliased && ([2]u64{nodes[i].lo, u64(nodes[i].kind)} in read_anchors) {
			for j in i ..< i + subtree_len(doc, tape.Node_Index(i)) {
				if cx.frozen[j] == .None || cx.frozen[j] == .Merged { cx.frozen[j] = .Anchored }
			}
		}
	}
	return nil
}

@(private = "file")
items_of :: proc(cx: ^Cx, c: u32) -> (out: []Item, err: Edit_Error) {
	if cached, ok := cx.items[c]; ok { return cached, nil }
	nodes := cx.doc.nodes
	list := make([dynamic]Item, 0, 8, cx.a) or_return
	end := c + nodes[c].n
	for j := c + 1; j < end; {
		it := Item{key = NIL, value = j}
		if nodes[c].kind == .Object {
			it.key, it.value = j, j + 1
			it.start = key_start(cx.doc, cx.src, j, cx.lo[j] if .Alias in cx.flags[j] else min(cx.lo[j], nodes[j].lo))
		} else if .Bracket in cx.flags[c] {
			it.start = props_lo(cx.doc, j, cx.lo[j])
		} else {
			it.start = cx.lo[c] if len(list) == 0 else dash_after(cx.src, list[len(list) - 1].end)
		}
		it.end = cx.hi[it.value]
		append(&list, it) or_return
		j = it.value + subtree_len(cx.doc, tape.Node_Index(it.value))
	}
	if _, merr := map_insert(&cx.items, c, list[:]); merr != nil { return nil, merr }
	return list[:], nil
}

@(private = "file")
dash_after :: proc "contextless" (src: []u8, p: u64) -> u64 #no_bounds_check {
	for i := p; i < u64(len(src)); {
		switch src[i] {
		case ' ', '\t', '\r', '\n': i += 1
		case '#':                   i = content_end(src, i)
		case:                       return i
		}
	}
	return u64(len(src))
}

// ---------- Compose Traversal (Iterative) ----------

@(private = "file")
queue_child_edits :: proc(cx: ^Cx, c: u32, stack: ^[dynamic]Handle) -> Edit_Error {
	for it in items_of(cx, c) or_return {
		if ch, has := cx.ov.by_base[tape.Node_Index(it.value)]; has {
			if cn, cok := edit.get_node(cx.ov, ch); cok && cn.has_edits { append(stack, ch) or_return }
		}
	}
	return nil
}

@(private = "file")
alias_has_interior_edit :: proc(cx: ^Cx, bn: u32, n: ^edit.Edit_Node) -> bool {
	if n.state == .Container_Delta { return true }
	for fo in n.facts {
		if fo.kind != .Alias || fo.deleted { return true }
	}
	if is_container(cx.doc.nodes[bn].kind) {
		for j in bn + 1 ..< bn + subtree_len(cx.doc, tape.Node_Index(bn)) {
			if ch, has := cx.ov.by_base[tape.Node_Index(j)]; has {
				if cn, ok := edit.get_node(cx.ov, ch); ok && cn.has_edits { return true }
			}
		}
	}
	return false
}

@(private = "file")
compose_walk :: proc(cx: ^Cx, root: Handle) -> Edit_Error {
	stack := make([dynamic]Handle, 0, 32, cx.a) or_return
	append(&stack, root) or_return
	for len(stack) > 0 {
		h := pop(&stack)
		n, ok := edit.get_node(cx.ov, h)
		if !ok || !n.has_edits { continue }
		bn := n.base
		has_base := bn != tape.NO_NODE && int(bn) < len(cx.doc.nodes)
		if has_base {
			if cx.dead[bn] { continue }
			if .Alias in cx.flags[bn] && n.state != .Replaced && alias_has_interior_edit(cx, u32(bn), n) {
				if !cx.opts.reflow {
					return edit.refuse(.Alias_Edit_Requires_Reflow, "editing through a YAML alias requires reflow", bn, cx.lo[bn])
				}
				emit_yaml_reflow(cx, h, u32(bn)) or_return
				continue
			}
			if cx.frozen[bn] == .Anchored {
				if !cx.opts.reflow {
					return edit.refuse(.Alias_Edit_Requires_Reflow, "editing an anchored node with live aliases requires reflow", bn, cx.lo[bn])
				}
				unshare_anchor(cx, u32(bn)) or_return
			}
			if cx.merge_of[bn] >= 0 {
				if !cx.opts.reflow {
					return edit.refuse(.Alias_Edit_Requires_Reflow, "editing a YAML mapping with active merge keys (<<) requires reflow", bn, cx.lo[bn])
				}
				if n.state == .Replaced {
					before_len := len(cx.splices)
					apply_replace(cx, h, n) or_return
					for i in before_len ..< len(cx.splices) { cx.splices[i].rewritten = true }
				} else {
					apply_merge_mapping(cx, h, n, u32(bn), &stack) or_return
				}
				continue
			}
			switch cx.frozen[bn] {
			case .None:
			case .Merged:   return edit.refuse(.Alias_Edit_Requires_Reflow, "cannot edit a document with active YAML merge keys (<<) without reflow", bn, cx.lo[bn])
			case .Aliased:  return edit.refuse(.Alias_Edit_Requires_Reflow, "node is inside an alias expansion; requires reflow to unshare", bn, cx.lo[bn])
			case .Anchored: return edit.refuse(.Alias_Edit_Requires_Reflow, "node has a live alias referencing its anchor; requires reflow to unshare", bn, cx.lo[bn])
			}
		}

		if n.state == .Replaced { apply_replace(cx, h, n) or_return; continue }

		if len(n.facts) > 0 {
			apply_facts(cx, u32(bn), n, h) or_return
			if u32(bn) in cx.reflowed { continue }
		}

		if has_base && cx.doc.nodes[bn].kind == .Object {
			if has_edited_duplicate_key(cx, n) or_return {
				if !cx.opts.reflow { return edit.refuse(.Layout_Reflow_Needed, "editing duplicated YAML mapping key requires reflow", bn, cx.lo[bn]) }
				emit_yaml_reflow(cx, h, u32(bn)) or_return
				continue
			}
		}

		if n.state == .Container_Delta {
			apply_container_delta(cx, h, n, &stack) or_return
			continue
		}
		if has_base && is_container(cx.doc.nodes[bn].kind) { queue_child_edits(cx, u32(bn), &stack) or_return }
	}
	return nil
}

@(private = "file")
has_edited_duplicate_key :: proc(cx: ^Cx, n: ^edit.Edit_Node) -> (has_dup: bool, err: Edit_Error) {
	if n.base == tape.NO_NODE || cx.doc.nodes[n.base].kind != .Object { return false, nil }
	Key_Count :: struct { count: int, edited: bool }
	seen := make(map[string]Key_Count, 8, cx.a) or_return
	edited_keys: map[string]struct{}
	if n.state != .Container_Delta && n.delta != nil && (len(n.delta.deleted_keys) > 0 || len(n.delta.renamed_members) > 0) {
		edited_keys = make(map[string]struct{}, len(n.delta.deleted_keys) + len(n.delta.renamed_members), cx.a) or_return
		for dk in n.delta.deleted_keys { if _, merr := map_insert(&edited_keys, dk, struct{}{}); merr != nil { return false, merr } }
		for r in n.delta.renamed_members { if _, merr := map_insert(&edited_keys, r.old_key, struct{}{}); merr != nil { return false, merr } }
	}
	for it in items_of(cx, u32(n.base)) or_return {
		tk := edit.decode_node_text_tmp(cx.doc, tape.Node_Index(it.key), cx.a).text
		is_ed := n.state == .Container_Delta || (tk in edited_keys)
		if !is_ed {
			if ch, has := cx.ov.by_base[tape.Node_Index(it.value)]; has {
				if cn, ok := edit.get_node(cx.ov, ch); ok && cn.has_edits { is_ed = true }
			}
		}
		cur := seen[tk]
		cur.count += 1
		cur.edited ||= is_ed
		if _, merr := map_insert(&seen, tk, cur); merr != nil { return false, merr }
	}
	for _, kc in seen {
		if kc.count > 1 && kc.edited { return true, nil }
	}
	return false, nil
}

@(private = "file")
apply_key_replace :: proc(cx: ^Cx, k: u32, n: ^edit.Edit_Node) -> Edit_Error {
	if cx.frozen[k] != .None {
		if !cx.opts.reflow { return edit.refuse(.Alias_Edit_Requires_Reflow, "cannot rename aliased, anchored, or merged key without reflow", tape.Node_Index(k)) }
		if cx.frozen[k] == .Anchored {
			anc := k
			for cx.parent[anc] != NIL && cx.frozen[cx.parent[anc]] == .Anchored { anc = cx.parent[anc] }
			unshare_anchor(cx, anc) or_return
		} else {
			return edit.refuse(.Alias_Edit_Requires_Reflow, "cannot rename aliased or merged key directly", tape.Node_Index(k))
		}
	}
	if n.val.kind != .String && n.val.kind != .Raw { return edit.refuse(.Bad_Name, "YAML mapping key must be a string", tape.Node_Index(k)) }
	return set_key(cx, k, n.val.text)
}

@(private = "file")
apply_replace :: proc(cx: ^Cx, h: Handle, n: ^edit.Edit_Node) -> Edit_Error {
	v := u32(n.base)
	style := extract_style_override(n)
	for fo in n.facts {
		if fo.kind == .Alias && !fo.deleted && len(fo.values) > 0 { return apply_facts(cx, v, n, h) }
	}

	raw_text: []u8
	is_raw := n.val.kind == .Raw
	if is_raw {
		raw_text = transmute([]u8)n.val.text
		validate_raw_value(raw_text, cx.spec, cx.yaml_opts, cx.a) or_return
	} else {
		buf := make([dynamic]u8, 0, 64, cx.a) or_return
		spell_overlay_value(cx, h, n, style, &buf) or_return
		raw_text = buf[:]
	}

	for fo in n.facts {
		#partial switch fo.kind {
		case .Comment, .Comment_Inline, .Comment_Foot: apply_single_comment_fact(cx, v, fo) or_return
		case .Tag, .Anchor:                            apply_single_prop_fact(cx, v, fo) or_return
		}
	}
	mark_dead_subtree(cx, v)

	t := trim_break(raw_text)
	if !is_raw && n.val.kind == .String && style == "" && n.base != tape.NO_NODE {
		t = spelled_as_before(cx, v, n.val.text, t)
	}
	sh := shape_text(cx, t)
	can_sub := v != u32(tape.ROOT) &&
		cx.doc.nodes[v].kind < .Array &&
		sh.form == .Inline &&
		len(n.facts) == 0 &&
		len(tape.facts_of(cx.doc, tape.Node_Index(v))) == 0 &&
		cx.parent[v] != NIL &&
		!(.Flow in cx.flags[cx.parent[v]]) &&
		!(n.base != tape.NO_NODE && (.After_Props in cx.flags[v] || cx.doc.nodes[v].n == 0))
	if is_raw {
		can_sub &&= bytes.index_any(t, transmute([]u8)string("\n\r#*&!%,[]{}")) < 0 &&
			!(len(t) >= 3 && (string(t[:3]) == "---" || string(t[:3]) == "..."))
	} else {
		can_sub &&= n.val.kind < .Array && n.val.kind != .Base_Ref
	}
	return place(cx, v, t, sh, can_sub)
}

@(private = "file")
extract_style_override :: proc "contextless" (n: ^edit.Edit_Node) -> string {
	for fo in n.facts {
		if fo.kind == .Style && !fo.deleted && len(fo.values) > 0 { return fo.values[0] }
	}
	return ""
}

@(private = "file")
validate_raw_value :: proc(raw: []u8, spec: Spec, yaml_opts: tape.Yaml_Options, a: runtime.Allocator) -> Edit_Error {
	if len(raw) == 0 || kernel.is_ws(raw[0]) || raw[0] == '#' || raw[0] == '%' || holds_marker(raw) {
		return edit.refuse(.Unspellable_Value, "invalid raw YAML value")
	}
	doc, val, _, err := build_value(raw, spec, yaml_opts, a)
	defer tape.destroy_document(&doc)
	if err != nil { return edit.refuse(.Unspellable_Value, "raw YAML value failed parse") }
	if int(val) < len(doc.nodes) {
		n := doc.nodes[val]
		if n.kind <= .Plain && n.n == 0 && len(tape.facts_of(&doc, val)) == 0 {
			return edit.refuse(.Unspellable_Value, "raw YAML value is empty")
		}
	}
	return nil
}

@(private = "file")
build_value :: proc(src: []u8, spec: Spec, yaml_opts: tape.Yaml_Options, a: runtime.Allocator) -> (doc: tape.Document, value: tape.Node_Index, offset: u64, err: tape.Error) {
	text := src
	anchors := make([dynamic]u8, 0, 64, a) or_return
	handles := make([dynamic]u8, 0, 64, a) or_return
	named := 0
	for tries := 0; ; tries += 1 {
		doc, err = build(text, spec, {format = yaml_opts}, a)
		if err == nil {
			if named > 0 { value, _ = tape.element(tape.Reader{doc = &doc}, tape.ROOT, named) }
			return doc, value, offset, nil
		}
		f, is_fault := err.(tape.Fault)
		if !is_fault || f.rules != &RULES || tries == 64 { return doc, 0, 0, err }
		#partial switch Detail(f.detail) {
		case .Undefined_Alias:
			rest := text[f.at + 1:]
			name := 0
			for name < len(rest) && !kernel.is_ws(rest[name]) && bytes.index_byte(transmute([]u8)string(",[]{}"), rest[name]) < 0 { name += 1 }
			append(&anchors, "- ") or_return
			append(&anchors, '&') or_return
			append(&anchors, ..rest[:name]) or_return
			append(&anchors, " ~\n") or_return
			named += 1
		case .Undeclared_Handle:
			rest := text[f.at:]
			bang := bytes.index_byte(rest[1:], '!') + 2
			append(&handles, "%TAG ") or_return
			append(&handles, ..rest[:bang]) or_return
			append(&handles, " tag:stury,0:\n") or_return
		case:
			return doc, 0, 0, err
		}
		tape.destroy_document(&doc)
		b := make([dynamic]u8, 0, len(handles) + len(anchors) + len(src) + 64, a) or_return
		if len(handles) > 0 { append(&b, ..handles[:]) or_return; append(&b, "---\n") or_return }
		if named == 0 {
			offset = u64(len(b))
			append(&b, ..src) or_return
		} else {
			append(&b, ..anchors[:]) or_return
			append(&b, "- ") or_return
			offset = u64(len(b))
			for c in src {
				append(&b, c) or_return
				if c == '\n' { append(&b, "  ") or_return }
			}
		}
		text = b[:]
	}
}

@(private = "file")
holds_marker :: proc(src: []u8) -> bool {
	for ls := 0; ls < len(src); {
		if rest := src[ls:]; len(rest) >= 3 && (string(rest[:3]) == "---" || string(rest[:3]) == "...") && (len(rest) == 3 || kernel.is_ws(rest[3])) {
			return true
		}
		nl := bytes.index_byte(src[ls:], '\n')
		if nl < 0 { break }
		ls += nl + 1
	}
	return false
}

@(private = "file")
spell_overlay_value :: proc(cx: ^Cx, h: Handle, n: ^edit.Edit_Node, style: string, out: ^[dynamic]u8) -> Edit_Error {
	if n.val.kind == .Base_Ref && len(n.facts) == 0 && !cx.opts.reflow {
		v := u32(n.val.base_ref)
		if int(v) < len(cx.doc.nodes) {
			basis := basis_of(cx, v)
			src := cx.src[cx.lo[v]:cx.hi[v]]
			pair := cx.doc.nodes[v].kind == .Object && (cx.flags[v] & {.Flow, .Bracket} == {.Flow})
			if pair { append(out, '{') or_return }
			for ls := 0; ls < len(src); {
				nl := bytes.index_byte(src[ls:], '\n')
				stop := len(src) if nl < 0 else ls + nl + 1
				line := src[ls:stop]
				if ls > 0 {
					cut := 0
					for cut < basis && cut < len(line) && line[cut] == ' ' { cut += 1 }
					line = line[cut:]
				}
				append(out, ..line) or_return
				ls = stop
			}
			if pair { append(out, '}') or_return }
			return nil
		}
	}

	if n.val.kind == .String && len(style) > 0 {
		step_ind := int(cx.opts.indent) if cx.opts.indent > 0 else 2
		if b := spell_styled_scalar(n.val.text, style, step_ind, cx.a) or_return; b != nil {
			append(out, ..b) or_return
			return nil
		}
	}

	tmp_doc := edit.materialize_subtree(cx.ov, h, tape.NO_NODE, {}, cx.a) or_return
	defer tape.destroy_document(&tmp_doc)
	step_ind := u8(0) if style == "flow" else (u8(cx.opts.indent) if cx.opts.indent > 0 else 2)
	encoded, _, werr := write(&tmp_doc, cx.spec, {indent = step_ind, format = cx.yaml_opts}, cx.a)
	if werr != nil { return convert_write_error(werr) }
	append(out, ..encoded) or_return
	return nil
}

@(private = "file")
spell_styled_scalar :: proc(s, style: string, ind: int, a: runtime.Allocator) -> ([]u8, Edit_Error) {
	f := facts_of_text(s, false)
	if f.invalid { return nil, edit.refuse(.Unspellable_Value, "YAML string must be valid UTF-8") }
	out: ops_write.Out
	if err := ops_write.out_start(&out, a, {}, ops_write.ROOM_MAX); err != nil { return nil, err }
	wrote := false
	switch style {
	case "single":
		if !f.escapes && !f.line_ends { put_single(&out, s); wrote = true }
	case "double":
		put_double(&out, s, false); wrote = true
	case "literal", "folded":
		if block_fits(s, f, Place{block = true, keeps = .Block, folded = style == "folded"}) {
			put_block(&out, s, .Folded if style == "folded" else .Literal, ind)
			wrote = true
		}
	case "plain":
		if !f.escapes && !f.line_ends && !f.tab && plain_fits(s, false) && !reads_as_other(s) { put_str(&out, s); wrote = true }
	}
	if !wrote { ops_write.out_drop(&out); return nil, nil }
	res, werr := ops_write.out_finish(&out)
	if werr != nil { return nil, convert_write_error(werr) }
	return res, nil
}

@(private = "file")
convert_write_error :: proc "contextless" (werr: Write_Error) -> Edit_Error {
	#partial switch e in werr {
	case runtime.Allocator_Error: return e
	case ops_write.Refused:       return edit.refuse(.Unspellable_Value, "value cannot be spelled in YAML", e.node)
	case tape.Bad_Option:         return e
	}
	return edit.refuse(.Unspellable_Value, "YAML write failed")
}

// ---------- Scalar & Key Helpers ----------

@(private = "file")
trim_break :: proc "contextless" (text: []u8) -> []u8 {
	t := text
	if len(t) > 0 && t[len(t) - 1] == '\n' {
		t = t[:len(t) - 1]
		if len(t) > 0 && t[len(t) - 1] == '\r' { t = t[:len(t) - 1] }
	}
	return t
}

@(private = "file")
may_be_block :: proc "contextless" (t: []u8) -> bool {
	if len(t) == 0 { return false }
	switch t[0] {
	case '-', '?', '|', '>', '!', '&': return true
	}
	if t[len(t) - 1] == ':' { return true }
	for i := 0; i + 1 < len(t); i += 1 {
		if t[i] == ':' && (t[i + 1] == ' ' || t[i + 1] == '\t') { return true }
	}
	return false
}

@(private = "file")
shape_text :: proc(cx: ^Cx, t: []u8) -> Text_Shape {
	nl := bytes.index_byte(t, '\n')
	if nl < 0 && !may_be_block(t) { return {form = .Inline} }
	doc, value, offset, err := build_value(t, cx.spec, cx.yaml_opts, cx.a)
	defer tape.destroy_document(&doc)
	if err != nil { return {form = .Inline if nl < 0 else .Lines} }
	root := doc.nodes[value]
	switch {
	case is_container(root.kind) && !is_flow(&doc, root):
		head := 0
		if start := props_lo(&doc, u32(value) + 1, root.lo) if root.kind == .Object && root.n > 1 else root.lo; nl >= 0 && u64(nl) + offset < start {
			head = len(trim_break(t[:nl + 1]))
		}
		return {form = .Block, seq = root.kind == .Array, head = head}
	case root.kind == .String && style_of(root.spelling) == .Block:
		return {form = .Literal}
	}
	return {form = .Inline if nl < 0 else .Lines}
}

@(private = "file")
spell_scalar_bytes :: proc(s: string, at: Place, a: runtime.Allocator) -> ([]u8, bool) {
	shape, valid := shape_of(s, at)
	if !valid { return nil, false }
	out: ops_write.Out
	if ops_write.out_start(&out, a, {}, ops_write.ROOM_MAX) != nil { return nil, false }
	put_scalar(&out, s, shape, false)
	res, err := ops_write.out_finish(&out)
	return res, err == nil
}

@(private = "file")
spell_key :: proc(name: string, flow: bool, a: runtime.Allocator, keeps: Maybe(Style) = nil) -> ([]u8, Edit_Error) {
	if len(name) > KEY_MAX { return nil, edit.refuse(.Bad_Name, "YAML implicit key exceeds 1024 bytes") }
	spelled, ok := spell_scalar_bytes(name, Place{flow = flow, key = true, keeps = keeps}, a)
	if !ok { return nil, edit.refuse(.Bad_Name, "YAML key is not valid UTF-8") }
	return spelled, nil
}

@(private = "file")
set_key :: proc(cx: ^Cx, k: u32, name: string) -> Edit_Error {
	claim_seen(cx, k, 0xff, "conflicting edits on same key") or_return
	lo, hi := cx.lo[k], cx.hi[k]
	keeps: Maybe(Style)
	if nd := cx.doc.nodes[k]; nd.kind == .String && .Alias not_in cx.flags[k] {
		if style := style_of(nd.spelling); style == .Single || style == .Double { keeps = style }
	}
	spelled := spell_key(name, .Flow in cx.flags[k], cx.a, keeps) or_return
	b := make([dynamic]u8, 0, len(spelled) + 4, cx.a) or_return
	if lo == hi && lo > 0 && !kernel.is_ws(cx.src[lo - 1]) && bytes.index_byte(transmute([]u8)string(",[{"), cx.src[lo - 1]) < 0 {
		append(&b, ' ') or_return
	}
	append(&b, ..spelled) or_return
	if hi > lo && cx.src[hi - 1] == '\n' { append(&b, cx.eol) or_return }
	return add_splice(cx, lo, hi, b[:], tape.Node_Index(k), false)
}

@(private = "file")
spelled_as_before :: proc(cx: ^Cx, v: u32, s: string, t: []u8) -> []u8 {
	nd := cx.doc.nodes[v]
	style := style_of(nd.spelling)
	if nd.kind != .String || len(t) == 0 || t[0] == '"' { return t }
	if style == .Block && nd.lo < u64(len(cx.src)) && cx.src[nd.lo] == '>' { return folded_as_before(cx, s, t) }
	if style != .Single && style != .Double { return t }
	quote: u8 = '\'' if style == .Single else '"'
	spelled, ok := spell_scalar_bytes(s, Place{flow = .Flow in cx.flags[v], keeps = style}, cx.a)
	return spelled if ok && len(spelled) > 0 && spelled[0] == quote else t
}

@(private = "file")
folded_as_before :: proc(cx: ^Cx, s: string, t: []u8) -> []u8 {
	body := bytes.trim_right(transmute([]u8)s, {'\n'})
	nl := bytes.index_byte(t, '\n')
	if t[0] != '|' || nl < 0 || bytes.index_byte(body, '\n') >= 0 { return t }
	shape, valid := shape_of(s, Place{block = true, keeps = .Block, folded = true})
	if !valid || shape != .Folded { return t }
	ind := 0
	for nl + 1 + ind < len(t) && t[nl + 1 + ind] == ' ' { ind += 1 }
	out: ops_write.Out
	if ops_write.out_start(&out, cx.a, {}, ops_write.ROOM_MAX) != nil { return t }
	put_block(&out, s, .Folded, ind)
	spelled, err := ops_write.out_finish(&out)
	return trim_break(spelled) if err == nil else t
}

@(private = "file")
flow_text :: proc(cx: ^Cx, at: u32, t: []u8, sh: Text_Shape) -> (out: []u8, err: Edit_Error) {
	if (sh.form == .Inline || sh.form == .Lines) &&
		(len(t) == 0 || bytes.index_byte(transmute([]u8)string("\"'[{*"), t[0]) >= 0 || bytes.index_any(t, transmute([]u8)string(",[]{}")) < 0) {
		return t, nil
	}
	parse_src := t
	if sh.head > 0 {
		pb := make([dynamic]u8, 0, len(t) + 4, cx.a) or_return
		append(&pb, "--- ") or_return
		append(&pb, ..t) or_return
		parse_src = pb[:]
	}
	doc, berr := build(parse_src, cx.spec, {format = cx.yaml_opts}, cx.a)
	defer tape.destroy_document(&doc)
	if berr != nil { return t, nil }
	if root := doc.nodes[tape.ROOT]; root.kind == .String && len(doc.facts) == 0 {
		tk := edit.decode_node_text_tmp(&doc, tape.ROOT, cx.a).text
		if spelled, ok := spell_scalar_bytes(tk, Place{flow = true}, cx.a); ok { return spelled, nil }
	}
	text, _, werr := write(&doc, cx.spec, {format = cx.yaml_opts}, cx.a)
	if werr != nil { return t, nil }
	if sh.head > 0 && len(text) >= 4 && string(text[:3]) == "---" && (text[3] == ' ' || text[3] == '\n') {
		text = text[4:]
	}
	text = bytes.trim_right(text, transmute([]u8)string(" \t"))
	if bytes.index_byte(text, '\n') < 0 { return text, nil }
	top := at
	for p := cx.parent[top]; p != NIL && (.Flow in cx.flags[p]); p = cx.parent[p] { top = p }
	from := edit.line_start(cx.src, cx.lo[top])
	ind := 0
	for from + u64(ind) < u64(len(cx.src)) && cx.src[from + u64(ind)] == ' ' { ind += 1 }
	b := make([dynamic]u8, 0, len(text) + 16, cx.a) or_return
	put_lines(cx, &b, text, ind + 2) or_return
	if text[len(text) - 1] == '\n' { put_spaces_to(&b, ind + 2) or_return }
	return b[:], nil
}

@(private = "file")
pair_text :: proc(cx: ^Cx, v: u32, t: []u8) -> (inner_out: []u8, ok: bool, err: Edit_Error) {
	if cx.doc.nodes[v].kind != .Object || cx.flags[v] & {.Flow, .Bracket} != {.Flow} { return nil, false, nil }
	pair, perr := build(t, cx.spec, {format = cx.yaml_opts}, cx.a)
	defer tape.destroy_document(&pair)
	if perr != nil || pair.nodes[tape.ROOT].kind != .Object || tape.child_count(&pair, tape.ROOT, pair.nodes[tape.ROOT]) != 1 {
		return nil, false, nil
	}
	inner := bytes.trim_space(t[1:len(t) - 1]) if len(t) >= 2 && t[0] == '{' && t[len(t) - 1] == '}' else t
	wrapped := make([dynamic]u8, 0, len(inner) + 2, cx.a) or_return
	append(&wrapped, '[') or_return; append(&wrapped, ..inner) or_return; append(&wrapped, ']') or_return
	seq, serr := build(wrapped[:], cx.spec, {format = cx.yaml_opts}, cx.a)
	defer tape.destroy_document(&seq)
	if serr != nil || tape.child_count(&seq, tape.ROOT, seq.nodes[tape.ROOT]) != 1 { return nil, false, nil }
	first, _ := tape.element(tape.Reader{doc = &seq}, tape.ROOT, 0)
	pa, _, ea := write(&pair, cx.spec, {format = cx.yaml_opts}, cx.a)
	pb, _, eb := write(&seq, cx.spec, {node = first, format = cx.yaml_opts}, cx.a)
	return inner, ea == nil && eb == nil && string(pa) == string(pb), nil
}

@(private = "file")
place :: proc(cx: ^Cx, v: u32, t_in: []u8, sh_in: Text_Shape, subtree_only_in := false) -> Edit_Error {
	if _, existed := cx.seen[u64(v) << 8 | 0xff]; existed { return nil }
	if _, merr := map_insert(&cx.seen, u64(v) << 8 | 0xff, struct{}{}); merr != nil { return merr }

	t, sh, subtree_only := t_in, sh_in, subtree_only_in
	src, lo, hi, p := cx.src, cx.lo[v], cx.hi[v], cx.parent[v]
	b := make([dynamic]u8, 0, len(t) + 16, cx.a) or_return
	need_prefix_space := .After_Props in cx.flags[v] && sh.form != .Block
	if p != NIL && (.Flow in cx.flags[p]) {
		if need_prefix_space { append(&b, ' ') or_return }
		if pair, pok := pair_text(cx, v, t) or_return; pok {
			append(&b, ..pair) or_return
		} else {
			ft := flow_text(cx, v, t, sh) or_return
			append(&b, ..ft) or_return
		}
		return add_splice(cx, lo, hi, b[:], tape.Node_Index(v), subtree_only && !need_prefix_space)
	}
	if sh.form == .Block && (.Bracket in cx.flags[v]) && !(v in cx.reflowed) {
		ft := flow_text(cx, v, t, sh) or_return
		t = bytes.trim_right(ft, transmute([]u8)string(" \r\n"))
		sh = {form = .Inline}
		subtree_only = false
		need_prefix_space = .After_Props in cx.flags[v]
	}
	if need_prefix_space { append(&b, ' ') or_return }

	from := lo
	first := edit.first_on_line(src, lo)
	placed_col := false
	switch {
	case p == NIL:
		col := 0
		if sh.form == .Block && first {
			from = indent_end(src, lo)
			put_spaces_to(&b, int(lo - from)) or_return
			col = column_of(src, lo)
		} else if sh.form == .Block {
			from = lead_end(src, lo)
			append(&b, cx.eol) or_return
		}
		put_lines(cx, &b, t, col) or_return
	case cx.doc.nodes[p].kind == .Object:
		done: bool
		from, done, placed_col = place_value(cx, &b, v, t, sh) or_return
		if done { return nil }
	case sh.form != .Block:
		if lo > 0 && src[lo - 1] == '-' { append(&b, ' ') or_return; need_prefix_space = true }
		put_lines(cx, &b, t, column_of(src, cx.lo[p])) or_return
	case first:
		from = indent_end(src, lo)
		put_spaces_to(&b, int(lo - from)) or_return
		put_lines(cx, &b, t, column_of(src, lo)) or_return
	case lead_end(src, lo) < lo && src[lead_end(src, lo) - 1] == '-' && bytes.index_byte(src[lead_end(src, lo):lo], '\t') < 0:
		put_lines(cx, &b, t, column_of(src, lo)) or_return
	case:
		from = lead_end(src, lo)
		col := column_of(src, cx.lo[p]) + 2
		if from > 0 && src[from - 1] == '-' {
			append(&b, ' ') or_return
			col = column_of(src, from) + 1
		} else {
			append_eol_indent(cx, &b, col) or_return
		}
		put_lines(cx, &b, t, col) or_return
	}
	eol_added := hi > lo && src[hi - 1] == '\n'
	if eol_added { append(&b, cx.eol) or_return }
	return add_splice(cx, from, hi, b[:], tape.Node_Index(v), subtree_only && from == lo && !need_prefix_space && !placed_col && !eol_added)
}

@(private = "file")
place_value :: proc(cx: ^Cx, b: ^[dynamic]u8, v: u32, t: []u8, sh: Text_Shape) -> (from: u64, done: bool, extra_space: bool, err: Edit_Error) {
	src, lo, hi, key := cx.src, cx.lo[v], cx.hi[v], v - 1
	kcol := column_of(src, cx.lo[cx.parent[v]])
	colon := colon_after(src, cx.hi[key])
	ks := key_start(cx.doc, src, key, cx.lo[key] if .Alias in cx.flags[key] else min(cx.lo[key], cx.doc.nodes[key].lo))
	explicit := ks < u64(len(src)) && src[ks] == '?' && (ks + 1 == u64(len(src)) || kernel.is_ws(src[ks + 1]))
	if explicit && (colon == u64(len(src)) || src[colon] != ':') {
		append_eol_indent(cx, b, kcol) or_return
		append(b, ": ") or_return
		put_lines(cx, b, t, kcol + 2) or_return
		return lo, false, true, nil
	}
	if sh.form == .Block {
		if edit.first_on_line(src, lo) {
			from = indent_end(src, lo)
			put_spaces_to(b, int(lo - from)) or_return
			put_lines(cx, b, t, column_of(src, lo)) or_return
			return from, false, from != lo, nil
		}
		if explicit && edit.first_on_line(src, colon) && edit.line_start(src, colon) == edit.line_start(src, lo) && lead_end(src, lo) == colon + 1 {
			put_lines(cx, b, t, column_of(src, lo)) or_return
			return lo, false, false, nil
		}
		learn_layout(cx)
		bcol := kcol + (cx.seq_off if sh.seq else cx.step)
		body := t
		if sh.head > 0 {
			append(b, ' ') or_return; append(b, ..t[:sh.head]) or_return
			body = t[min(len(t), bytes.index_byte(t, '\n') + 1):]
		}
		if hi > 0 && hi < u64(len(src)) && src[hi - 1] != '\n' && rest_is_blank(src, hi) && bytes.index_byte(src[hi:content_end(src, hi)], '#') >= 0 {
			add_splice(cx, lead_end(src, lo), hi, b[:], tape.Node_Index(v), false) or_return
			nl := edit.next_line(src, hi)
			lines := make([dynamic]u8, 0, len(body) + bcol + 4, cx.a) or_return
			if nl == u64(len(src)) && src[nl - 1] != '\n' { append(&lines, cx.eol) or_return }
			put_spaces_to(&lines, bcol) or_return
			put_lines(cx, &lines, body, bcol) or_return
			if nl < u64(len(src)) || src[nl - 1] == '\n' { append(&lines, cx.eol) or_return }
			add_splice(cx, nl, nl, lines[:], tape.Node_Index(v), false) or_return
			return hi, true, true, nil
		}
		append_eol_indent(cx, b, bcol) or_return
		put_lines(cx, b, body, bcol) or_return
		return lead_end(src, lo), false, true, nil
	}
	if !is_block(cx, v) {
		added_sp := lo == colon + 1
		if added_sp { append(b, ' ') or_return }
		put_lines(cx, b, t, kcol) or_return
		return lo, false, added_sp, nil
	}
	from = colon + 1
	comment: []u8
	for f in tape.facts_of(cx.doc, tape.Node_Index(v)) {
		if edit.line_start(src, f.lo) != edit.line_start(src, colon) { continue }
		#partial switch f.kind {
		case .Tag, .Anchor:    from = max(from, f.lo + u64(f.n))
		case .Comment_Inline:  comment = src[f.lo:f.lo + u64(f.n)]
		}
	}
	append(b, ' ') or_return
	if nl := bytes.index_byte(t, '\n'); sh.form == .Literal && comment != nil && nl >= 0 {
		append(b, ..trim_break(t[:nl + 1])) or_return
		append(b, ' ') or_return; append(b, ..comment) or_return
		put_lines(cx, b, t[nl:], kcol) or_return
		return from, false, true, nil
	}
	put_lines(cx, b, t, kcol) or_return
	if comment != nil { append(b, ' ') or_return; append(b, ..comment) or_return }
	return from, false, true, nil
}

// ---------- Container Delta Composer (Block & Flow) ----------

@(private = "file")
apply_container_delta :: proc(cx: ^Cx, h: Handle, n: ^edit.Edit_Node, stack: ^[dynamic]Handle) -> Edit_Error {
	c, d := u32(n.base), n.delta
	if d == nil { return queue_child_edits(cx, c, stack) }
	if cx.flags[c] & {.Flow, .Bracket} == {.Flow} {
		if !cx.opts.reflow { return edit.refuse(.Layout_Reflow_Needed, "implicit pair in a flow sequence holds one member", n.base, cx.lo[c]) }
		return emit_yaml_reflow(cx, h, c)
	}

	items := items_of(cx, c) or_return
	is_obj := cx.doc.nodes[c].kind == .Object
	removed := make([]bool, len(items), cx.a) or_return

	if is_obj && len(d.deleted_keys) > 0 {
		del_keys := make(map[string]struct{}, len(d.deleted_keys), cx.a) or_return
		for dk in d.deleted_keys { if _, merr := map_insert(&del_keys, dk, struct{}{}); merr != nil { return merr } }
		for it, idx in items {
			if edit.decode_node_text_tmp(cx.doc, tape.Node_Index(it.key), cx.a).text in del_keys { removed[idx] = true }
		}
	} else if !is_obj {
		for di in d.deleted_indices { if int(di) < len(items) { removed[di] = true } }
	}

	renames: map[string]string
	if is_obj && len(d.renamed_members) > 0 {
		renames = make(map[string]string, len(d.renamed_members), cx.a) or_return
		for r in d.renamed_members { if _, merr := map_insert(&renames, r.old_key, r.new_key); merr != nil { return merr } }
	}

	has_del := false
	for it, idx in items {
		if removed[idx] {
			has_del = true
			if it.key != NIL { cx.dead[it.key] = true }
			mark_dead_subtree(cx, it.value)
			continue
		}
		if len(renames) > 0 {
			if new_k, has_ren := renames[edit.decode_node_text_tmp(cx.doc, tape.Node_Index(it.key), cx.a).text]; has_ren {
				set_key(cx, it.key, new_k) or_return
			}
		}
		if ch, has := cx.ov.by_base[tape.Node_Index(it.value)]; has {
			if cn, ok := edit.get_node(cx.ov, ch); ok && cn.has_edits { append(stack, ch) or_return }
		}
	}

	ins_count := len(d.inserted_members) if is_obj else len(d.inserted_elems)
	has_order := len(d.order) > 0
	if !has_del && ins_count == 0 && !has_order { return nil }

	if has_order {
		edit.validate_order(d.order, removed, ins_count, cx.a) or_return
		plan_anchor_reorder(cx, c, items, removed, d.order) or_return
	}

	if .Bracket in cx.flags[c] { return regroup_flow(cx, h, n, c, items, removed, d, has_order) }
	if has_order { return reorder_block(cx, h, n, c, items, removed, d) }
	return regroup_block(cx, c, items, removed, d)
}

@(private = "file")
anchor_name_of :: proc "contextless" (doc: ^tape.Document, node: u32) -> (name: string, fact: tape.Fact, ok: bool) {
	for f in tape.facts_of(doc, tape.Node_Index(node)) {
		if f.kind == .Anchor {
			raw := tape.span_bytes(doc, f.lo, f.n)
			return string(raw[1:]) if len(raw) > 0 && raw[0] == '&' else string(raw), f, true
		}
	}
	return "", {}, false
}

@(private = "file")
extract_node_source :: proc(cx: ^Cx, a: u32, include_anchor, include_tag: bool) -> (out: []u8, sh: Text_Shape, err: Edit_Error) {
	doc := cx.doc
	nd := doc.nodes[a]
	b := make([dynamic]u8, 0, int(cx.hi[a] - cx.lo[a]) + 32, cx.a) or_return
	prop_facts: [2]tape.Fact
	prop_n := 0
	for f in tape.facts_of(doc, tape.Node_Index(a)) {
		if (f.kind == .Tag && include_tag) || (f.kind == .Anchor && include_anchor) {
			if prop_n < 2 { prop_facts[prop_n] = f; prop_n += 1 }
		}
	}
	if prop_n == 2 && prop_facts[1].lo < prop_facts[0].lo {
		prop_facts[0], prop_facts[1] = prop_facts[1], prop_facts[0]
	}
	has_prop := prop_n > 0
	for i in 0 ..< prop_n {
		if i > 0 { append(&b, ' ') or_return }
		append(&b, ..tape.span_bytes(doc, prop_facts[i].lo, prop_facts[i].n)) or_return
	}
	prop_head := len(b)
	empty_scalar := nd.kind <= .Plain && nd.n == 0
	if empty_scalar {
		if !has_prop { append(&b, "null") or_return }
		return b[:], {form = .Inline}, nil
	}
	basis := basis_of(cx, a)
	src := trim_break(cx.src[cx.lo[a]:cx.hi[a]])
	if has_prop {
		if is_block(cx, a) { append(&b, cx.eol) or_return } else { append(&b, ' ') or_return }
	}
	pair := nd.kind == .Object && (cx.flags[a] & {.Flow, .Bracket} == {.Flow})
	if pair { append(&b, '{') or_return }
	for ls := 0; ls < len(src); {
		nl := bytes.index_byte(src[ls:], '\n')
		stop := len(src) if nl < 0 else ls + nl + 1
		line := src[ls:stop]
		if ls > 0 {
			cut := 0
			for cut < basis && cut < len(line) && line[cut] == ' ' { cut += 1 }
			line = line[cut:]
		}
		append(&b, ..line) or_return
		ls = stop
	}
	if pair { append(&b, '}') or_return }
	t := trim_break(b[:])
	if is_block(cx, a) {
		return t, {form = .Block, seq = nd.kind == .Array, head = prop_head if has_prop else 0}, nil
	}
	if nd.kind == .String && style_of(nd.spelling) == .Block {
		return t, {form = .Literal}, nil
	}
	return t, {form = .Inline if bytes.index_byte(t, '\n') < 0 else .Lines}, nil
}

@(private = "file")
emit_anchor_as_alias :: proc(cx: ^Cx, a: u32, name: string) -> Edit_Error {
	old_lo := props_lo(cx.doc, a, cx.lo[a])
	old_hi := cx.hi[a]
	if old_hi > old_lo && cx.src[old_hi - 1] == '\n' {
		old_hi -= 1
		if old_hi > old_lo && cx.src[old_hi - 1] == '\r' { old_hi -= 1 }
	}
	b := make([dynamic]u8, 0, len(name) + 16, cx.a) or_return
	append(&b, '*') or_return
	append(&b, name) or_return
	if is_block(cx, a) {
		for f in tape.facts_of(cx.doc, tape.Node_Index(a)) {
			if f.kind == .Comment_Inline && edit.line_start(cx.src, f.lo) == edit.line_start(cx.src, old_lo) {
				append(&b, ' ') or_return
				append(&b, ..cx.src[f.lo : f.lo + u64(f.n)]) or_return
				break
			}
		}
	}
	return add_splice(cx, old_lo, old_hi, b[:], tape.Node_Index(a), false)
}

// Group 2 Anchor Reorder (default-enabled): when reordering moves an alias `*a` before its anchor `&a`,
// moves `&a` (with its anchored value) to the new first use and turns the old anchor site into `*a`.
// Still refuses with `.Bad_Order` on shadowing conflicts (duplicate anchor names) or cyclic/nested conflicts.
@(private = "file")
plan_anchor_reorder :: proc(cx: ^Cx, c: u32, items: []Item, removed: []bool, order: []u32) -> Edit_Error {
	doc := cx.doc
	if .Alias not_in doc.present { return nil }
	n_nodes := len(doc.nodes)
	place_of := make([]int, len(items), cx.a) or_return
	slice.fill(place_of, -1)
	for raw, p in order {
		if int(raw) < len(items) { place_of[int(raw)] = p }
	}

	// Count total anchor definitions per name across the entire document to catch shadowing conflicts.
	def_count := make(map[string]int, 8, cx.a) or_return
	for i := u32(0); i < u32(n_nodes); i += 1 {
		if name, _, ok := anchor_name_of(doc, i); ok {
			cur := def_count[name] + 1
			if _, merr := map_insert(&def_count, name, cur); merr != nil { return merr }
		}
	}

	// Check for duplicate-name shadowing crossings (same name defined >1 time in doc, relative order changes).
	Named :: struct { place: int, names: [dynamic]string }
	named := make([dynamic]Named, 0, len(items), cx.a) or_return
	item_of := make([]int, n_nodes, cx.a) or_return
	slice.fill(item_of, -1)
	Anchor_Swap :: struct { anchor, alias: u32, name: string, k_anchor, k_alias: int, skip: bool }
	anchors_in_c := make([dynamic]u32, 0, 4, cx.a) or_return
	aliases_in_c := make([dynamic]u32, 0, 8, cx.a) or_return

	for it, k in items {
		if removed[k] { continue }
		first := it.key if it.key != NIL else it.value
		end := it.value + subtree_len(doc, tape.Node_Index(it.value))
		dup_names := make([dynamic]string, 0, 4, cx.a) or_return
		for i := first; i < end; i += 1 {
			item_of[i] = k
			for f in tape.facts_of(doc, tape.Node_Index(i)) {
				if f.kind == .Anchor || f.kind == .Alias {
					raw := tape.span_bytes(doc, f.lo, f.n)
					nm := string(raw[1:]) if len(raw) > 0 && (raw[0] == '&' || raw[0] == '*') else string(raw)
					if def_count[nm] > 1 { append(&dup_names, nm) or_return }
					if f.kind == .Anchor { append(&anchors_in_c, i) or_return }
					if f.kind == .Alias { append(&aliases_in_c, i) or_return }
				}
			}
		}
		if len(dup_names) > 0 { append(&named, Named{place_of[k], dup_names}) or_return }
	}
	for a, i in named {
		for b in named[i + 1:] {
			if b.place > a.place { continue }
			for x in a.names {
				if slice.contains(b.names[:], x) {
					return edit.refuse(.Bad_Order, "reorder changes shadowing order of duplicate YAML anchor", tape.Node_Index(c), cx.lo[c])
				}
			}
		}
	}

	swaps := make([dynamic]Anchor_Swap, 0, len(anchors_in_c), cx.a) or_return
	for a in anchors_in_c {
		name, _, ok := anchor_name_of(doc, a)
		if !ok { continue }
		k_a := item_of[a]
		best_u := NIL
		best_pos := place_of[k_a]
		for u in aliases_in_c {
			if cx.anchor_of[u] != a { continue }
			ku := item_of[u]
			pu := place_of[ku]
			if pu < best_pos || (pu == best_pos && best_u != NIL && u < best_u) {
				best_pos, best_u = pu, u
			}
		}
		if best_u != NIL {
			append(&swaps, Anchor_Swap{anchor = a, alias = best_u, name = name, k_anchor = k_a, k_alias = item_of[best_u]}) or_return
		}
	}
	if len(swaps) == 0 { return nil }

	// Validate nesting / dependency interactions between swaps.
	for &sw, idx in swaps {
		a_end := sw.anchor + subtree_len(doc, tape.Node_Index(sw.anchor))
		if doc.nodes[sw.alias].role == .Key {
			if is_container(doc.nodes[sw.anchor].kind) || bytes.index_byte(cx.src[cx.lo[sw.anchor]:cx.hi[sw.anchor]], '\n') >= 0 {
				return edit.refuse(.Bad_Order, "cannot move multiline or container anchor into mapping key alias", tape.Node_Index(c), cx.lo[c])
			}
		}
		// Check nested anchors/swaps inside `sw.anchor`.
		for &other, oidx in swaps {
			if oidx == idx { continue }
			if other.anchor > sw.anchor && other.anchor < a_end {
				if place_of[other.k_alias] < place_of[sw.k_alias] {
					return edit.refuse(.Bad_Order, "nested anchor reorder conflicts with outer anchor move", tape.Node_Index(c), cx.lo[c])
				}
				other.skip = true
			}
		}
		// Check if `sw.anchor` itself contains an alias to another anchor in `c` that would end up after `sw.k_alias`.
		for j := sw.anchor + 1; j < a_end; j += 1 {
			if .Alias not_in cx.flags[j] { continue }
			targ := cx.anchor_of[j]
			if targ == NIL || item_of[targ] < 0 { continue }
			targ_pos := place_of[item_of[targ]]
			for o in swaps {
				if !o.skip && o.anchor == targ { targ_pos = place_of[o.k_alias]; break }
			}
			if targ_pos > place_of[sw.k_alias] {
				return edit.refuse(.Bad_Order, "moving anchor would place nested alias before its target anchor", tape.Node_Index(c), cx.lo[c])
			}
		}
	}

	for sw in swaps {
		if sw.skip { continue }
		t, sh := extract_node_source(cx, sw.anchor, true, true) or_return
		if doc.nodes[sw.alias].role == .Key {
			add_splice(cx, cx.lo[sw.alias], cx.hi[sw.alias], t, tape.Node_Index(sw.alias), false) or_return
		} else {
			place(cx, sw.alias, t, sh, false) or_return
		}
		emit_anchor_as_alias(cx, sw.anchor, sw.name) or_return
	}
	return nil
}

// Group 3 Anchor Unsharing (`opts.reflow == true`): strips `&name` from `a`, moves `&name` + original value to
// the first unedited surviving alias (so all other aliases retain their original value), and unfreezes `a`.
@(private = "file")
unshare_anchor :: proc(cx: ^Cx, a: u32) -> Edit_Error {
	if a in cx.unshared { return nil }
	if _, merr := map_insert(&cx.unshared, a, struct{}{}); merr != nil { return merr }
	doc, nodes := cx.doc, cx.doc.nodes

	// If `a` itself is not the anchor root (e.g. a descendant of an anchor), walk up to the anchor root.
	root_a := a
	for {
		if _, _, has_a := anchor_name_of(doc, root_a); has_a { break }
		if cx.parent[root_a] == NIL || cx.frozen[cx.parent[root_a]] != .Anchored { break }
		root_a = cx.parent[root_a]
	}
	if root_a != a {
		if root_a in cx.unshared { return nil }
		if _, merr := map_insert(&cx.unshared, root_a, struct{}{}); merr != nil { return merr }
	}
	anch_name, af, has_af := anchor_name_of(doc, root_a)
	if !has_af { return nil }

	// Collect unedited surviving aliases pointing to `root_a` (both normal aliases and `<<:` merge aliases).
	first_u := NIL
	first_lo := max(u64)
	first_ma := -1
	live_count := 0
	for i := u32(0); i < u32(len(nodes)); i += 1 {
		if .Alias not_in cx.flags[i] || cx.anchor_of[i] != root_a { continue }
		if cx.dead[i] || (len(cx.gone) > 0 && cx.gone[i]) { continue }
		if uh, has_uh := cx.ov.by_base[tape.Node_Index(i)]; has_uh {
			if un, uok := edit.get_node(cx.ov, uh); uok && un.has_edits && (un.state == .Replaced || alias_has_interior_edit(cx, i, un)) {
				continue
			}
		}
		live_count += 1
		if cx.lo[i] < first_lo { first_lo, first_u, first_ma = cx.lo[i], i, -1 }
	}
	for ma, midx in cx.merge_aliases {
		if ma.anchor_lo != nodes[root_a].lo || ma.anchor_kind != nodes[root_a].kind { continue }
		owner_gone := false
		for i := u32(0); i < u32(len(nodes)); i += 1 {
			if cx.merge_of[i] >= 0 && nodes[i].lo == ma.owner_lo {
				owner_gone = cx.dead[i] || (len(cx.gone) > 0 && cx.gone[i])
				break
			}
		}
		if owner_gone { continue }
		live_count += 1
		if ma.alias_lo < first_lo { first_lo, first_u, first_ma = ma.alias_lo, NIL, midx }
	}

	// Strip `&anch_name` from `root_a`.
	strip_anchor_fact(cx, root_a, af) or_return

	// Move original value (with `&anch_name` if >= 2 unedited aliases or raw alias writes exist) to first surviving alias.
	if live_count > 0 {
		need_anch := live_count >= 2 || cx.writes_alias
		t, sh := extract_node_source(cx, root_a, need_anch, true) or_return
		before_len := len(cx.splices)
		if first_u != NIL {
			if nodes[first_u].role == .Key {
				add_splice(cx, cx.lo[first_u], cx.hi[first_u], t, tape.Node_Index(first_u), false) or_return
			} else {
				place(cx, first_u, t, sh, false) or_return
			}
		} else if first_ma >= 0 {
			ma := cx.merge_aliases[first_ma]
			place_merge_alias(cx, ma, t, sh) or_return
		}
		for i in before_len ..< len(cx.splices) {
			cx.splices[i].rewritten = true
			cx.splices[i].subtree_only = false
		}
	}

	// Unfreeze `root_a` and its subtree (preserving nested distinct anchors and merge maps).
	end := root_a + subtree_len(doc, tape.Node_Index(root_a))
	cx.frozen[root_a] = .Merged if cx.merge_of[root_a] >= 0 else .None
	for j := root_a + 1; j < end; {
		if _, _, sub_a := anchor_name_of(doc, j); sub_a {
			j += subtree_len(doc, tape.Node_Index(j))
			continue
		}
		if cx.frozen[j] == .Anchored {
			cx.frozen[j] = .Merged if cx.merge_of[j] >= 0 else .None
		}
		j += 1
	}
	_ = anch_name
	return nil
}

@(private = "file")
strip_anchor_fact :: proc(cx: ^Cx, v: u32, f: tape.Fact) -> Edit_Error {
	before_len := len(cx.splices)
	src := cx.src
	p := cx.parent[v]
	if is_block(cx, v) && p != NIL && cx.doc.nodes[p].kind == .Object {
		colon := colon_after(src, cx.hi[v - 1])
		if edit.line_start(src, f.lo) == edit.line_start(src, colon) {
			add_splice(cx, lead_end(src, f.lo), f.lo + u64(f.n), nil, f.node, false) or_return
			for i in before_len ..< len(cx.splices) { cx.splices[i].rewritten = true }
			return nil
		}
	}
	hi := f.lo + u64(f.n)
	for hi < u64(len(src)) && (src[hi] == ' ' || src[hi] == '\t') { hi += 1 }
	if hi < u64(len(src)) && src[hi] != '\n' && src[hi] != '\r' {
		add_splice(cx, f.lo, hi, nil, f.node, false) or_return
	} else {
		cut_line_or_inline(cx, f.node, f.lo, hi) or_return
	}
	for i in before_len ..< len(cx.splices) { cx.splices[i].rewritten = true }
	return nil
}

@(private = "file")
place_merge_alias :: proc(cx: ^Cx, ma: Merge_Alias, t: []u8, sh: Text_Shape) -> Edit_Error {
	if ma.flow || sh.form != .Block {
		ft := t
		if ma.flow {
			parse_src := t
			if sh.head > 0 {
				pb := make([dynamic]u8, 0, len(t) + 4, cx.a) or_return
				append(&pb, "--- ") or_return
				append(&pb, ..t) or_return
				parse_src = pb[:]
			}
			doc, berr := build(parse_src, cx.spec, {format = cx.yaml_opts}, cx.a)
			defer tape.destroy_document(&doc)
			if berr == nil {
				if written, _, werr := write(&doc, cx.spec, {format = cx.yaml_opts}, cx.a); werr == nil {
					if sh.head > 0 && len(written) >= 4 && string(written[:3]) == "---" && (written[3] == ' ' || written[3] == '\n') {
						written = written[4:]
					}
					ft = bytes.trim_right(written, transmute([]u8)string(" \t\r\n"))
				}
			}
		}
		return add_splice(cx, ma.alias_lo, ma.alias_hi, ft, tape.ROOT, false)
	}
	le := lead_end(cx.src, ma.alias_lo)
	if le > 0 && cx.src[le - 1] == '-' && bytes.index_byte(cx.src[le:ma.alias_lo], '\t') < 0 {
		b := make([dynamic]u8, 0, len(t) + 16, cx.a) or_return
		put_lines(cx, &b, t, column_of(cx.src, ma.alias_lo)) or_return
		return add_splice(cx, ma.alias_lo, ma.alias_hi, b[:], tape.ROOT, false)
	}
	learn_layout(cx)
	bcol := ma.parent_col + cx.step
	b := make([dynamic]u8, 0, len(t) + 16, cx.a) or_return
	body := t
	if sh.head > 0 {
		append(&b, ' ') or_return; append(&b, ..t[:sh.head]) or_return
		body = t[min(len(t), bytes.index_byte(t, '\n') + 1):]
	}
	append_eol_indent(cx, &b, bcol) or_return
	put_lines(cx, &b, body, bcol) or_return
	return add_splice(cx, le, ma.alias_hi, b[:], tape.ROOT, false)
}

// Group 3 Merge-Key (`<<`) composer (`opts.reflow == true`):
// - Modifying a merged member writes an explicit override key into the mapping (preserving `<<:`).
// - Deleting/renaming a merged (or source-provided) member, reordering, or restyling expands `<<:` cleanly.
@(private = "file")
apply_merge_mapping :: proc(cx: ^Cx, h: Handle, n: ^edit.Edit_Node, c: u32, stack: ^[dynamic]Handle) -> Edit_Error {
	items := items_of(cx, c) or_return
	mi := &cx.merge_maps[cx.merge_of[c]]
	d := n.delta

	need_expand := false
	if has_edited_duplicate_key(cx, n) or_return { need_expand = true }
	for fo in n.facts {
		if fo.kind == .Style && !fo.deleted && len(fo.values) > 0 && (fo.values[0] == "flow" || fo.values[0] == "block") {
			need_expand = true
		}
	}
	if d != nil {
		if len(d.order) > 0 { need_expand = true }
		if len(d.deleted_keys) > 0 {
			for dk in d.deleted_keys {
				if dk in mi.source_keys { need_expand = true; break }
				for it in items {
					if .Merged_Member in cx.flags[it.value] && edit.decode_node_text_tmp(cx.doc, tape.Node_Index(it.key), cx.a).text == dk {
						need_expand = true; break
					}
				}
				if need_expand { break }
			}
			// Explicit key deletion on a merge mapping also expands cleanly so `items` bounds stay exact.
			need_expand = true
		}
		if len(d.renamed_members) > 0 {
			for r in d.renamed_members {
				if r.old_key in mi.source_keys { need_expand = true; break }
				for it in items {
					if .Merged_Member in cx.flags[it.value] && edit.decode_node_text_tmp(cx.doc, tape.Node_Index(it.key), cx.a).text == r.old_key {
						need_expand = true; break
					}
				}
				if need_expand { break }
			}
		}
	}
	for it in items {
		if .Merged_Member in cx.flags[it.key] {
			if kh, has_k := cx.ov.by_base[tape.Node_Index(it.key)]; has_k {
				if kn, ok := edit.get_node(cx.ov, kh); ok && kn.has_edits { need_expand = true; break }
			}
		}
	}

	if need_expand {
		keep_flow := (.Bracket in cx.flags[c]) && extract_style_override(n) != "block"
		return emit_yaml_reflow(cx, h, c, keep_flow)
	}

	if len(n.facts) > 0 {
		apply_facts(cx, c, n, h) or_return
		if c in cx.reflowed { return nil }
	}

	Override :: struct { key: string, val: []u8 }
	overrides := make([dynamic]Override, 0, 4, cx.a) or_return

	renames: map[string]string
	if d != nil && len(d.renamed_members) > 0 {
		renames = make(map[string]string, len(d.renamed_members), cx.a) or_return
		for r in d.renamed_members { if _, merr := map_insert(&renames, r.old_key, r.new_key); merr != nil { return merr } }
	}

	for it in items {
		if .Merged_Member in cx.flags[it.value] {
			if ch, has := cx.ov.by_base[tape.Node_Index(it.value)]; has {
				if cn, ok := edit.get_node(cx.ov, ch); ok && cn.has_edits {
					mark_dead_subtree(cx, it.value)
					k_name := edit.decode_node_text_tmp(cx.doc, tape.Node_Index(it.key), cx.a).text
					vt: []u8
					if cn.state == .Replaced && cn.val.kind == .Raw {
						vt = transmute([]u8)cn.val.text
						validate_raw_value(vt, cx.spec, cx.yaml_opts, cx.a) or_return
					} else {
						buf := make([dynamic]u8, 0, 64, cx.a) or_return
						spell_overlay_value(cx, ch, cn, extract_style_override(cn), &buf) or_return
						vt = buf[:]
					}
					append(&overrides, Override{k_name, vt}) or_return
				}
			}
			continue
		}
		// Explicit member: unfreeze (keeping nested anchors/aliases/merge-maps frozen) and edit in place!
		cx.frozen[it.key] = .None
		end := it.value + subtree_len(cx.doc, tape.Node_Index(it.value))
		for j := it.value; j < end; {
			if cx.merge_of[j] >= 0 || (.Alias in cx.flags[j]) {
				j += subtree_len(cx.doc, tape.Node_Index(j))
				continue
			}
			if cx.frozen[j] == .Merged { cx.frozen[j] = .None }
			j += 1
		}
		if len(renames) > 0 {
			if new_k, has_ren := renames[edit.decode_node_text_tmp(cx.doc, tape.Node_Index(it.key), cx.a).text]; has_ren {
				set_key(cx, it.key, new_k) or_return
			}
		}
		if ch, has := cx.ov.by_base[tape.Node_Index(it.value)]; has {
			if cn, ok := edit.get_node(cx.ov, ch); ok && cn.has_edits { append(stack, ch) or_return }
		}
	}

	if d != nil {
		for ins in d.inserted_members {
			vt := spell_inserted_value(cx, ins.value) or_return
			append(&overrides, Override{ins.key, vt}) or_return
		}
	}

	if len(overrides) == 0 { return nil }
	before_len := len(cx.splices)
	if .Bracket in cx.flags[c] {
		c_hi := cx.hi[c]
		inner_hi := c_hi - 1
		pos := inner_hi
		for pos > cx.lo[c] + 1 && (cx.src[pos - 1] == ' ' || cx.src[pos - 1] == '\t' || cx.src[pos - 1] == '\r' || cx.src[pos - 1] == '\n') { pos -= 1 }
		b := make([dynamic]u8, 0, 64, cx.a) or_return
		for ov_it in overrides {
			t := trim_break(ov_it.val)
			ft := flow_text(cx, c, t, shape_text(cx, t)) or_return
			k := spell_key(ov_it.key, true, cx.a) or_return
			append(&b, ", ") or_return
			append(&b, ..k) or_return
			append(&b, ": ") or_return
			append(&b, ..ft) or_return
		}
		add_splice(cx, pos, pos, b[:], tape.Node_Index(c), false) or_return
	} else {
		col := column_of(cx.src, cx.lo[c])
		pos := cx.hi[c]
		if !(pos > 0 && cx.src[pos - 1] == '\n') { pos = edit.next_line(cx.src, pos) }
		eof_no_nl := pos == u64(len(cx.src)) && (pos == 0 || cx.src[pos - 1] != '\n')
		b := make([dynamic]u8, 0, 64, cx.a) or_return
		for ov_it in overrides {
			mt := member_text(cx, ov_it.key, ov_it.val, true, col) or_return
			if eof_no_nl {
				append_eol_indent(cx, &b, col) or_return
				append(&b, ..mt) or_return
			} else {
				put_spaces_to(&b, col) or_return
				append(&b, ..mt) or_return
				append(&b, cx.eol) or_return
			}
		}
		add_splice(cx, pos, pos, b[:], tape.Node_Index(c), false) or_return
	}
	for i in before_len ..< len(cx.splices) { cx.splices[i].rewritten = true }
	return nil
}

@(private = "file")
spell_inserted_value :: proc(cx: ^Cx, ins_h: Handle) -> (out: []u8, err: Edit_Error) {
	cn, ok := edit.get_node(cx.ov, ins_h)
	if !ok { return nil, edit.refuse(.Bad_Handle, "invalid inserted handle") }
	if cn.state == .Replaced && cn.val.kind == .Raw {
		raw := transmute([]u8)cn.val.text
		validate_raw_value(raw, cx.spec, cx.yaml_opts, cx.a) or_return
		return raw, nil
	}
	b := make([dynamic]u8, 0, 64, cx.a) or_return
	spell_overlay_value(cx, ins_h, cn, extract_style_override(cn), &b) or_return
	return b[:], nil
}

@(private = "file")
spell_block_insert :: proc(cx: ^Cx, d: ^edit.Container_Delta, is_obj: bool, ins_idx, col: int) -> (text: []u8, at: int, err: Edit_Error) {
	if is_obj {
		ins := d.inserted_members[ins_idx]
		vt := spell_inserted_value(cx, ins.value) or_return
		return member_text(cx, ins.key, vt, true, col) or_return, ins.at, nil
	}
	ins := d.inserted_elems[ins_idx]
	vt := spell_inserted_value(cx, ins.value) or_return
	return member_text(cx, "", vt, false, col) or_return, ins.at, nil
}

@(private = "file")
reorder_block :: proc(cx: ^Cx, h: Handle, n: ^edit.Edit_Node, c: u32, items: []Item, removed: []bool, d: ^edit.Container_Delta) -> Edit_Error {
	for r in removed {
		if r {
			if !cx.opts.reflow { return edit.refuse(.Layout_Reflow_Needed, "combined block delete+reorder requires reflow", n.base, cx.lo[c]) }
			return emit_yaml_reflow(cx, h, c)
		}
	}
	src, count_base, is_obj := cx.src, len(items), cx.doc.nodes[c].kind == .Object
	if count_base == 0 {
		if !cx.opts.reflow { return edit.refuse(.Layout_Reflow_Needed, "reordering empty YAML block container requires reflow", n.base, cx.lo[c]) }
		return emit_yaml_reflow(cx, h, c)
	}
	col := column_of(src, items[0].start)
	compact := !edit.first_on_line(src, items[0].start)

	lo := make([]u64, count_base, cx.a) or_return
	hi := make([]u64, count_base, cx.a) or_return
	for j := count_base - 1; j >= 0; j -= 1 {
		if j > 0 {
			lo[j] = edit.line_start(src, head_of(cx, items, j))
		} else if compact {
			lo[j] = items[0].start
		} else {
			hh := items[0].start
			for f in tape.facts_of(cx.doc, tape.Node_Index(items[0].value)) {
				if f.kind == .Comment && f.lo < hh && edit.first_on_line(src, f.lo) { hh = f.lo }
			}
			lo[j] = edit.line_start(src, hh)
		}
		hi[j] = member_end(cx, items[j], col)
		if j + 1 < count_base { hi[j] = min(hi[j], lo[j + 1]) }
	}

	end := hi[count_base - 1]
	open_end := end > 0 && src[end - 1] != '\n'
	moves := make([dynamic]edit.Move, 0, 3 * len(d.order), cx.a) or_return

	for raw, p in d.order {
		if p > 0 && p < count_base && hi[p - 1] < lo[p] {
			append(&moves, edit.Move{text = src[hi[p - 1]:lo[p]], written = true}) or_return
		}
		last, k := p == len(d.order) - 1, int(raw)
		if k >= count_base {
			m, _ := spell_block_insert(cx, d, is_obj, k - count_base, col) or_return
			b := make([dynamic]u8, 0, len(m) + col + 2, cx.a) or_return
			if !(compact && p == 0) { put_spaces_to(&b, col) or_return }
			append(&b, ..m) or_return
			if !(last && open_end) { append(&b, cx.eol) or_return }
			append(&moves, edit.Move{text = b[:], written = true}) or_return
			continue
		}
		from, to := lo[k], hi[k]
		if compact && p == 0 && k != 0 {
			if edit.line_start(src, from) != edit.line_start(src, items[k].start) {
				if !cx.opts.reflow { return edit.refuse(.Layout_Reflow_Needed, "member with head comments cannot move onto compact dash line", tape.Node_Index(items[k].value), items[k].start) }
				return emit_yaml_reflow(cx, h, c)
			}
			from = items[k].start
		}
		if compact && p != 0 && k == 0 {
			b := make([dynamic]u8, 0, col, cx.a) or_return
			put_spaces_to(&b, col) or_return
			append(&moves, edit.Move{text = b[:], written = true}) or_return
		}
		if open_end && last && k != count_base - 1 {
			to -= 1
			if to > from && src[to - 1] == '\r' { to -= 1 }
		}
		append(&moves, edit.Move{lo = from, hi = to}) or_return
		if open_end && !last && k == count_base - 1 {
			append(&moves, edit.Move{text = transmute([]u8)cx.eol, written = true}) or_return
		}
	}
	append(&cx.splices, edit.Splice{lo = lo[0], hi = end, moves = moves[:], seq = len(cx.splices), base_node = tape.Node_Index(c)}) or_return
	return nil
}

@(private = "file")
regroup_block :: proc(cx: ^Cx, c: u32, items: []Item, removed: []bool, d: ^edit.Container_Delta) -> Edit_Error {
	src, num_items, is_obj := cx.src, len(items), cx.doc.nodes[c].kind == .Object
	left := num_items
	for r in removed { left -= int(r) }
	col := column_of(src, items[0].start) if num_items > 0 else 0
	compact := num_items > 0 && !edit.first_on_line(src, items[0].start)
	ins_n := len(d.inserted_members) if is_obj else len(d.inserted_elems)

	if left == 0 && ins_n == 0 {
		p := cx.parent[c]
		if hh := edit.line_start(src, head_of(cx, items, 0)); (p == NIL || cx.doc.nodes[p].kind != .Object) && !compact && hh < edit.line_start(src, items[0].start) {
			add_splice(cx, hh, edit.line_start(src, items[0].start), nil, tape.Node_Index(c), false) or_return
		}
		return place(cx, c, transmute([]u8)string("{}" if is_obj else "[]"), {form = .Inline}, false)
	}

	Block_Ins :: struct { at: int, text: []u8 }
	sorted_ins := make([]Block_Ins, ins_n, cx.a) or_return
	for i in 0 ..< ins_n {
		mt, raw_at := spell_block_insert(cx, d, is_obj, i, col) or_return
		sorted_ins[i] = {at = num_items if raw_at < 0 || raw_at > num_items else raw_at, text = mt}
	}
	slice.stable_sort_by(sorted_ins, proc(a, b: Block_Ins) -> bool { return a.at < b.at })

	joined := false
	if compact && removed[0] {
		has_at_1 := false
		for bi in sorted_ins { if bi.at == 1 { has_at_1 = true; break } }
		joined = num_items > 1 && !removed[1] && head_of(cx, items, 1) == items[1].start && !has_at_1
		if joined {
			add_splice(cx, items[0].start, items[1].start, nil, tape.Node_Index(c), false) or_return
		} else {
			q := items[0].end
			if q > 0 && src[q - 1] == '\n' {
				q -= 1
				if q > 0 && src[q - 1] == '\r' { q -= 1 }
			} else {
				q = content_end(src, q)
			}
			add_splice(cx, lead_end(src, items[0].start), q, nil, tape.Node_Index(c), false) or_return
		}
	}
	for j in 0 ..< num_items {
		if !removed[j] || (j == 0 && compact) { continue }
		add_splice(cx, slot_at(cx, items, j, compact), slot_at(cx, items, j + 1, compact), nil, tape.Node_Index(c), false) or_return
	}
	for idx := 0; idx < len(sorted_ins); {
		at := sorted_ins[idx].at
		b := make([dynamic]u8, 0, 64, cx.a) or_return
		if at == 0 && compact && (!removed[0] || joined) {
			for idx < len(sorted_ins) && sorted_ins[idx].at == at {
				append(&b, ..sorted_ins[idx].text) or_return
				append_eol_indent(cx, &b, col) or_return
				idx += 1
			}
			add_splice(cx, items[0].start, items[0].start, b[:], tape.Node_Index(c), false) or_return
			continue
		}
		pos := slot_at(cx, items, 1 if (at == 0 && compact) else at, compact)
		eof_no_nl := pos == u64(len(src)) && (pos == 0 || src[pos - 1] != '\n')
		for idx < len(sorted_ins) && sorted_ins[idx].at == at {
			if eof_no_nl {
				append_eol_indent(cx, &b, col) or_return
				append(&b, ..sorted_ins[idx].text) or_return
			} else {
				put_spaces_to(&b, col) or_return
				append(&b, ..sorted_ins[idx].text) or_return
				append(&b, cx.eol) or_return
			}
			idx += 1
		}
		add_splice(cx, pos, pos, b[:], tape.Node_Index(c), false) or_return
	}
	return nil
}

@(private = "file")
flow_eol_comment_end :: proc(cx: ^Cx, h: Handle, n: ^edit.Edit_Node, c: u32, from, bound: u64, allow_eol: bool) -> (end_pos: u64, reflowed: bool, err: Edit_Error) {
	src := cx.src
	q := from
	for q < bound && (src[q] == ' ' || src[q] == '\t') { q += 1 }
	if q >= bound || src[q] != '#' { return 0, false, nil }
	if !allow_eol {
		if !cx.opts.reflow { return 0, false, edit.refuse(.Layout_Reflow_Needed, "flow collection comment conflicts with reorder", n.base, q) }
		emit_yaml_reflow(cx, h, c) or_return
		return 0, true, nil
	}
	end_c := q + 1
	for end_c < bound && src[end_c] != '\n' && src[end_c] != '\r' { end_c += 1 }
	return end_c, false, nil
}

@(private = "file")
regroup_flow :: proc(cx: ^Cx, h: Handle, n: ^edit.Edit_Node, c: u32, items: []Item, removed: []bool, d: ^edit.Container_Delta, has_order: bool) -> Edit_Error {
	src, c_lo, c_hi := cx.src, cx.lo[c], cx.hi[c]
	if c_hi < c_lo + 2 { return edit.refuse(.Bad_Handle, "cannot locate flow container bounds", n.base, c_lo) }
	is_obj, num_base := cx.doc.nodes[c].kind == .Object, len(items)
	inner_lo, inner_hi := c_lo + 1, c_hi - 1

	ins_n := len(d.inserted_members) if is_obj else len(d.inserted_elems)
	ins_texts := make([][]u8, ins_n, cx.a) or_return
	ins_ats := make([]int, ins_n, cx.a) or_return
	for i in 0 ..< ins_n {
		raw_val := d.inserted_members[i].value if is_obj else d.inserted_elems[i].value
		raw_at := d.inserted_members[i].at if is_obj else d.inserted_elems[i].at
		t := trim_break(spell_inserted_value(cx, raw_val) or_return)
		ft := flow_text(cx, c, t, shape_text(cx, t)) or_return
		if is_obj {
			k := spell_key(d.inserted_members[i].key, true, cx.a) or_return
			b := make([dynamic]u8, 0, len(k) + len(ft) + 2, cx.a) or_return
			append(&b, ..k) or_return; append(&b, ": ") or_return; append(&b, ..ft) or_return
			ins_texts[i] = b[:]
		} else {
			ins_texts[i] = ft
		}
		ins_ats[i] = num_base if raw_at < 0 || raw_at > num_base else raw_at
	}

	multiline := bytes.index_byte(src[c_lo:c_hi], '\n') >= 0
	left := num_base
	for r in removed { left -= int(r) }
	if left == 0 && ins_n == 0 {
		if scan_hash_comment(src, inner_lo, inner_hi) >= 0 {
			if !cx.opts.reflow { return edit.refuse(.Layout_Reflow_Needed, "clearing commented flow collection requires reflow", n.base, c_lo) }
			return emit_yaml_reflow(cx, h, c)
		}
		return add_splice(cx, inner_lo, inner_hi, nil, tape.Node_Index(c), false)
	}

	if num_base == 0 {
		emit_texts := ins_texts
		if has_order {
			ordered := make([][]u8, len(d.order), cx.a) or_return
			for raw, pos in d.order { ordered[pos] = ins_texts[int(raw)] }
			emit_texts = ordered
		}
		close_indent := edit.line_indent(src, c_lo)
		b := make([dynamic]u8, 0, 64, cx.a) or_return
		for txt, i in emit_texts {
			if i > 0 {
				if multiline { append(&b, ',') or_return } else { append(&b, ", ") or_return }
			}
			if multiline { append(&b, cx.eol) or_return; append(&b, close_indent) or_return; append(&b, "  ") or_return }
			append(&b, ..txt) or_return
		}
		if multiline { append(&b, cx.eol) or_return; append(&b, close_indent) or_return }
		return add_splice(cx, inner_lo, inner_hi, b[:], tape.Node_Index(c), false)
	}

	sep := detect_flow_sep(src, items)
	item_lines := edit.first_on_line(src, items[0].start)
	item_indent := edit.line_indent(src, items[0].start)

	if has_order {
		item_lo := make([]u64, num_base, cx.a) or_return
		item_hi := make([]u64, num_base, cx.a) or_return
		allow_eol := multiline && item_lines
		for it, k in items {
			ilo, ihi := it.start, it.end
			next_bound := items[k + 1].start if k + 1 < num_base else inner_hi
			comma_pos := scan_flow_comma(src, ihi, next_bound)
			if comma_pos >= 0 || !removed[k] {
				start_c := u64(comma_pos) + 1 if comma_pos >= 0 else ihi
				if end_c, ref := flow_eol_comment_end(cx, h, n, c, start_c, next_bound, allow_eol) or_return; ref {
					return nil
				} else if end_c > 0 {
					ihi = end_c
				}
			}
			prev_end := item_hi[k - 1] if k > 0 else inner_lo
			if scan_hash_comment(src, prev_end, ilo) >= 0 || scan_hash_comment(src, ihi, next_bound) >= 0 {
				if !cx.opts.reflow { return edit.refuse(.Layout_Reflow_Needed, "flow collection comment conflicts with reorder", n.base, ilo) }
				return emit_yaml_reflow(cx, h, c)
			}
			item_lo[k], item_hi[k] = ilo, ihi
		}

		moves := make([dynamic]edit.Move, 0, len(d.order) * 3, cx.a) or_return
		comma_slice := make([]u8, 1, cx.a) or_return
		comma_slice[0] = ','
		for raw, pos in d.order {
			k := int(raw)
			if pos > 0 {
				sb := make([dynamic]u8, 0, 16, cx.a) or_return
				if item_lines {
					append(&sb, cx.eol) or_return; append(&sb, item_indent) or_return
				} else if ins_n == 0 && pos < num_base {
					sp := scan_flow_comma(src, items[pos - 1].end, items[pos].start)
					gap := src[u64(sp) + 1 : items[pos].start] if sp >= 0 else nil
					if sp >= 0 && bytes.index_any(gap, {'\n', '\r'}) < 0 && scan_hash_comment(src, u64(sp) + 1, items[pos].start) < 0 {
						append(&sb, ..gap) or_return
					} else {
						append(&sb, ' ') or_return
					}
				} else if ci := bytes.index_byte(transmute([]u8)sep, ','); ci >= 0 {
					append(&sb, sep[ci + 1:]) or_return
				} else {
					append(&sb, ' ') or_return
				}
				append(&moves, edit.Move{text = sb[:], written = true}) or_return
			}
			want_comma := pos + 1 < len(d.order)
			if k < num_base {
				it := items[k]
				cp := scan_flow_comma(src, it.end, item_hi[k])
				if cp >= 0 && !want_comma {
					append(&moves, edit.Move{lo = item_lo[k], hi = u64(cp)}) or_return
					if u64(cp) + 1 < item_hi[k] { append(&moves, edit.Move{lo = u64(cp) + 1, hi = item_hi[k]}) or_return }
				} else if cp < 0 && want_comma {
					append(&moves, edit.Move{lo = item_lo[k], hi = it.end}) or_return
					append(&moves, edit.Move{text = comma_slice, written = true}) or_return
					if it.end < item_hi[k] { append(&moves, edit.Move{lo = it.end, hi = item_hi[k]}) or_return }
				} else {
					append(&moves, edit.Move{lo = item_lo[k], hi = item_hi[k]}) or_return
				}
			} else {
				txt := ins_texts[k - num_base]
				tb := make([dynamic]u8, 0, len(txt) + 1, cx.a) or_return
				append(&tb, ..txt) or_return
				if want_comma { append(&tb, ',') or_return }
				append(&moves, edit.Move{text = tb[:], written = true}) or_return
			}
		}
		span_hi := item_hi[num_base - 1]
		if tc := scan_flow_comma(src, span_hi, inner_hi); tc >= 0 { span_hi = u64(tc) + 1 }
		append(&cx.splices, edit.Splice{lo = item_lo[0], hi = span_hi, moves = moves[:], seq = len(cx.splices), base_node = tape.Node_Index(c)}) or_return
		return nil
	}

	last_surv := -1
	for r, k in removed { if !r { last_surv = k } }
	slots := make([][dynamic]int, num_base + 1, cx.a) or_return
	for ins_i in 0 ..< ins_n {
		slot := num_base
		for k := ins_ats[ins_i]; k < num_base; k += 1 {
			if !removed[k] { slot = k; break }
		}
		if slots[slot].allocator.procedure == nil { slots[slot] = make([dynamic]int, 0, 2, cx.a) or_return }
		append(&slots[slot], ins_i) or_return
	}
	has_tail_ins := len(slots[num_base]) > 0

	for k in 0 ..< num_base {
		if !removed[k] { continue }
		it := items[k]
		bound := items[k + 1].start if k + 1 < num_base else inner_hi
		is_after_last := k == last_surv + 1 && !has_tail_ins
		if is_after_last {
			if cp := scan_flow_comma(src, items[last_surv].end, it.start); cp >= 0 {
				add_splice(cx, u64(cp), u64(cp) + 1, nil, tape.Node_Index(c), false) or_return
			}
		}
		del_lo, del_hi := it.start, it.end
		if k < last_surv || has_tail_ins {
			if cp := scan_flow_comma(src, del_hi, bound); cp >= 0 {
				if scan_hash_comment(src, del_hi, u64(cp)) >= 0 {
					if !cx.opts.reflow { return edit.refuse(.Layout_Reflow_Needed, "flow deletion hits comment before comma", n.base, del_hi) }
					return emit_yaml_reflow(cx, h, c)
				}
				del_hi = u64(cp) + 1
			}
		}
		if item_lines && edit.first_on_line(src, del_lo) {
			q := del_hi
			for q < bound && (src[q] == ' ' || src[q] == '\t' || src[q] == '\r') { q += 1 }
			if q < bound && src[q] == '\n' { del_lo, del_hi = edit.line_start(src, del_lo), q + 1 }
		} else {
			for del_hi < bound && (src[del_hi] == ' ' || src[del_hi] == '\t') { del_hi += 1 }
			if is_after_last && last_surv >= 0 {
				if cp := scan_flow_comma(src, items[last_surv].end, it.start); cp >= 0 && u64(cp) + 1 <= del_lo && scan_hash_comment(src, u64(cp) + 1, del_lo) < 0 {
					del_lo = u64(cp) + 1
				}
			}
		}
		add_splice(cx, del_lo, del_hi, nil, tape.Node_Index(c), false) or_return
	}

	for k in 0 ..< num_base {
		if len(slots[k]) == 0 { continue }
		b := make([dynamic]u8, 0, 64, cx.a) or_return
		for ins_i in slots[k] {
			append(&b, ..ins_texts[ins_i]) or_return
			if item_lines { append(&b, ',') or_return; append(&b, cx.eol) or_return; append(&b, item_indent) or_return } else { append(&b, sep) or_return }
		}
		add_splice(cx, items[k].start, items[k].start, b[:], tape.Node_Index(c), false) or_return
	}

	if has_tail_ins && last_surv >= 0 {
		ls := items[last_surv]
		next_bound := items[last_surv + 1].start if last_surv + 1 < num_base else inner_hi
		existing_comma := scan_flow_comma(src, ls.end, next_bound)
		b := make([dynamic]u8, 0, 64, cx.a) or_return
		ins_pos := ls.end
		if existing_comma >= 0 {
			ins_pos = edit.next_line(src, u64(existing_comma) + 1) if item_lines else u64(existing_comma) + 1
			for ins_i, idx in slots[num_base] {
				if item_lines {
					if idx > 0 { append(&b, ',') or_return; append(&b, cx.eol) or_return }
					append(&b, item_indent) or_return
				} else {
					append(&b, sep if idx > 0 else " ") or_return
				}
				append(&b, ..ins_texts[ins_i]) or_return
			}
			if item_lines { append(&b, cx.eol) or_return }
		} else {
			for ins_i in slots[num_base] {
				if item_lines { append(&b, ',') or_return; append(&b, cx.eol) or_return; append(&b, item_indent) or_return } else { append(&b, sep) or_return }
				append(&b, ..ins_texts[ins_i]) or_return
			}
		}
		add_splice(cx, ins_pos, ins_pos, b[:], tape.Node_Index(c), false) or_return
	}
	return nil
}

@(private = "file")
detect_flow_sep :: proc(src: []u8, items: []Item) -> string {
	if len(items) >= 2 {
		gap := src[items[0].end:items[1].start]
		if bytes.index_byte(gap, '#') < 0 && bytes.index_byte(gap, '\n') < 0 && bytes.index_byte(gap, ',') >= 0 { return string(gap) }
	}
	return ", "
}

@(private = "file")
scan_flow_comma :: proc "contextless" (src: []u8, lo, hi: u64) -> i64 #no_bounds_check {
	for p := lo; p < hi; {
		if src[p] == ',' { return i64(p) }
		if src[p] == '#' && (p == 0 || kernel.is_ws(src[p - 1])) {
			for p < hi && src[p] != '\n' { p += 1 }
		} else {
			p += 1
		}
	}
	return -1
}

@(private = "file")
scan_hash_comment :: proc "contextless" (src: []u8, lo, hi: u64) -> i64 #no_bounds_check {
	for p := lo; p < hi; p += 1 {
		if src[p] == '#' && (p == 0 || kernel.is_ws(src[p - 1]) || is_flow_indicator(src[p - 1])) { return i64(p) }
	}
	return -1
}

@(private = "file")
emit_yaml_reflow :: proc(cx: ^Cx, h: Handle, c: u32, keep_flow := false) -> Edit_Error {
	if _, merr := map_insert(&cx.reflowed, c, struct{}{}); merr != nil { return merr }
	mark_dead_subtree(cx, c)
	tmp_doc := edit.materialize_subtree(cx.ov, h, tape.NO_NODE, {dedup_keys = true, include_root_comments = (c == u32(tape.ROOT))}, cx.a) or_return
	defer tape.destroy_document(&tmp_doc)

	step_ind := u8(0) if keep_flow else (u8(cx.opts.indent) if cx.opts.indent > 0 else 2)
	encoded, dropped, werr := write(&tmp_doc, cx.spec, {indent = step_ind, format = cx.yaml_opts}, cx.a)
	if werr != nil { return convert_write_error(werr) }
	cx.dropped += dropped

	if c == u32(tape.ROOT) && cx.parent[c] == NIL {
		append(&cx.splices, edit.Splice{lo = 0, hi = u64(len(cx.src)), text = encoded, seq = len(cx.splices), base_node = tape.ROOT, rewritten = true, full_rewalk = true}) or_return
		return nil
	}
	t := trim_break(encoded)
	before_len := len(cx.splices)
	place(cx, c, t, shape_text(cx, t), false) or_return
	for i in before_len ..< len(cx.splices) {
		cx.splices[i].rewritten = true
		cx.splices[i].subtree_only = false
	}
	return nil
}

@(private = "file")
reflow_fallback :: proc(cx: ^Cx, allocator: runtime.Allocator) -> (res: Commit_Result, err: Edit_Error) {
	if cx.ov.root == edit.NO_HANDLE { return {}, edit.refuse(.Layout_Reflow_Needed, "cannot reflow empty overlay") }
	tmp_doc := edit.materialize_subtree(cx.ov, cx.ov.root, tape.ROOT, {dedup_keys = true, include_root_comments = true}, cx.a) or_return
	defer tape.destroy_document(&tmp_doc)
	step_ind := u8(cx.opts.indent) if cx.opts.indent > 0 else 2
	encoded, dropped, werr := write(&tmp_doc, cx.spec, {indent = step_ind, format = cx.yaml_opts}, allocator)
	if werr != nil { return {}, convert_write_error(werr) }
	if verr := validate(encoded, cx.spec, {budget = {depth = edit_depth_budget(cx.ov)}, format = cx.yaml_opts}, allocator); verr != nil {
		delete(encoded, allocator)
		return {}, convert_tape_error(verr)
	}
	rew, rerr := make([]edit.Byte_Range, 1, allocator)
	if rerr != nil { delete(encoded, allocator); return {}, rerr }
	rew[0] = {0, u64(len(encoded))}
	recs, rec_err := make([]edit.Splice_Record, 1, allocator)
	if rec_err != nil { delete(rew, allocator); delete(encoded, allocator); return {}, rec_err }
	recs[0] = {base_node = tape.ROOT, src_lo = 0, src_hi = u64(len(cx.src)), dst_lo = 0, dst_hi = u64(len(encoded)), full_rewalk = true}
	return Commit_Result{bytes = encoded, dropped = dropped, rewritten = rew, splices = recs, allocator = allocator}, nil
}

// ---------- Facts (Comments, Tags, Anchors, Aliases, Styles) ----------

@(private = "file")
apply_facts :: proc(cx: ^Cx, v: u32, n: ^edit.Edit_Node, h: Handle) -> Edit_Error {
	for fo in n.facts {
		#partial switch fo.kind {
		case .Comment, .Comment_Inline, .Comment_Foot:
			apply_single_comment_fact(cx, v, fo) or_return
		case .Tag, .Anchor, .Alias:
			apply_single_prop_fact(cx, v, fo) or_return
		case .Style:
			if fo.deleted || len(fo.values) == 0 || n.state == .Replaced { continue }
			if (fo.values[0] == "flow" || fo.values[0] == "block") && is_container(cx.doc.nodes[v].kind) {
				if !cx.opts.reflow { return edit.refuse(.Layout_Reflow_Needed, "changing container style requires reflow", n.base, cx.lo[v]) }
				return emit_yaml_reflow(cx, h, v)
			}
			if cx.doc.nodes[v].kind == .String || cx.doc.nodes[v].kind == .Plain {
				tk := edit.decode_node_text_tmp(cx.doc, tape.Node_Index(v), cx.a).text
				step_ind := int(cx.opts.indent) if cx.opts.indent > 0 else 2
				if b := spell_styled_scalar(tk, fo.values[0], step_ind, cx.a) or_return; b != nil {
					tb := trim_break(b)
					place(cx, v, tb, shape_text(cx, tb), false) or_return
				}
			}
		case:
			return edit.refuse(.Fact_No_Place, "YAML does not support this fact kind", n.base, cx.lo[v])
		}
	}
	return nil
}

@(private = "file")
apply_single_comment_fact :: proc(cx: ^Cx, v: u32, fo: edit.Fact_Override) -> Edit_Error {
	claim_seen(cx, v, u64(fo.kind), "conflicting comment edits") or_return

	if (.Flow in cx.flags[v]) && (fo.kind != .Comment_Inline || (cx.parent[v] != NIL && .Flow in cx.flags[cx.parent[v]])) {
		if !cx.opts.reflow { return edit.refuse(.Layout_Reflow_Needed, "comment inside a flow collection requires reflow", tape.Node_Index(v), cx.lo[v]) }
		top := v
		for cx.parent[top] != NIL && (.Flow in cx.flags[cx.parent[top]]) { top = cx.parent[top] }
		if cx.parent[top] != NIL && (.Bracket in cx.flags[top]) {
			th, found := cx.ov.by_base[tape.Node_Index(top)]
			if !found { th = edit.handle_for_base(cx.ov, tape.Node_Index(top)) or_return }
			return emit_yaml_reflow(cx, th, top)
		}
		return edit.refuse(.Layout_Reflow_Needed, "flow collection comment requires container reflow", tape.Node_Index(v), cx.lo[v])
	}

	existing := make([dynamic]tape.Fact, 0, 2, cx.a) or_return
	for f in tape.facts_of(cx.doc, tape.Node_Index(v)) { if f.kind == fo.kind { append(&existing, f) or_return } }
	lines: []string = nil if fo.deleted else fo.values
	for l in lines {
		for c in transmute([]u8)l {
			if (c < 0x20 && c != '\t') || c == 0x7f { return edit.refuse(.Fact_No_Place, "comment contains control characters", tape.Node_Index(v)) }
		}
		if !utf8.valid_string(l) { return edit.refuse(.Fact_No_Place, "comment must be valid UTF-8", tape.Node_Index(v)) }
	}

	if len(lines) == 0 {
		for f in existing { cut_line_or_inline(cx, f.node, f.lo, f.lo + u64(f.n)) or_return }
		return nil
	}
	for f in existing[min(1, len(existing)):] { cut_line_or_inline(cx, f.node, f.lo, f.lo + u64(f.n)) or_return }

	src := cx.src
	b := make([dynamic]u8, 0, 64, cx.a) or_return
	#partial switch fo.kind {
	case .Comment_Inline:
		if len(lines) > 1 { return edit.refuse(.Fact_No_Place, "inline comment cannot span multiple lines", tape.Node_Index(v)) }
		if len(existing) > 0 {
			spell_comment(&b, lines[0], fo.padded) or_return
			return add_splice(cx, existing[0].lo, existing[0].lo + u64(existing[0].n), b[:], tape.Node_Index(v), false)
		}
		if is_block(cx, v) || (cx.doc.nodes[v].kind == .String && style_of(cx.doc.nodes[v].spelling) == .Block) {
			if !cx.opts.reflow { return edit.refuse(.Layout_Reflow_Needed, "block collection or scalar has no line end for inline comment", tape.Node_Index(v), cx.lo[v]) }
			return edit.refuse(.Fact_No_Place, "block node cannot hold inline comment directly", tape.Node_Index(v), cx.lo[v])
		}
		if !rest_is_blank(src, cx.hi[v]) || bytes.index_byte(src[cx.hi[v]:content_end(src, cx.hi[v])], '#') >= 0 {
			return edit.refuse(.Fact_No_Place, "no line end available for inline comment", tape.Node_Index(v), cx.hi[v])
		}
		append(&b, ' ') or_return
		spell_comment(&b, lines[0], fo.padded) or_return
		return add_splice(cx, cx.hi[v], cx.hi[v], b[:], tape.Node_Index(v), false)
	case .Comment:
		if len(existing) > 0 {
			put_comment_lines(cx, &b, lines, fo.padded, column_of(src, existing[0].lo), false) or_return
			return add_splice(cx, existing[0].lo, existing[0].lo + u64(existing[0].n), b[:], tape.Node_Index(v), false)
		}
		start := member_start(cx, v) or_return
		if !edit.first_on_line(src, start) { return edit.refuse(.Fact_No_Place, "node has no line of its own for head comment", tape.Node_Index(v), start) }
		col := column_of(src, start)
		put_spaces_to(&b, col) or_return
		put_comment_lines(cx, &b, lines, fo.padded, col, true) or_return
		ls := edit.line_start(src, start)
		return add_splice(cx, ls, ls, b[:], tape.Node_Index(v), false)
	case .Comment_Foot:
		if !is_block(cx, v) { return edit.refuse(.Fact_No_Place, "only block collections hold foot comments", tape.Node_Index(v), cx.lo[v]) }
		if len(existing) > 0 {
			put_comment_lines(cx, &b, lines, fo.padded, column_of(src, existing[0].lo), false) or_return
			return add_splice(cx, existing[0].lo, existing[0].lo + u64(existing[0].n), b[:], tape.Node_Index(v), false)
		}
		col := column_of(src, cx.lo[v])
		q := cx.hi[v]
		if !(q > 0 && src[q - 1] == '\n') { q = edit.next_line(src, q) }
		eof_no_nl := q == u64(len(src)) && (q == 0 || src[q - 1] != '\n')
		if eof_no_nl { append(&b, cx.eol) or_return }
		put_spaces_to(&b, col) or_return
		put_comment_lines(cx, &b, lines, fo.padded, col, !eof_no_nl) or_return
		return add_splice(cx, q, q, b[:], tape.Node_Index(v), false)
	}
	return nil
}

@(private = "file")
apply_single_prop_fact :: proc(cx: ^Cx, v: u32, fo: edit.Fact_Override) -> Edit_Error {
	claim_seen(cx, v, u64(fo.kind), "conflicting property edits") or_return
	prefix := make([dynamic]u8, 0, 32, cx.a) or_return
	if !fo.deleted {
		if len(fo.values) != 1 || len(fo.values[0]) == 0 { return edit.refuse(.Fact_No_Place, "YAML tag/anchor/alias must be a single non-empty token", tape.Node_Index(v)) }
		body := fo.values[0]
		if !utf8.valid_string(body) { return edit.refuse(.Fact_No_Place, "property must be valid UTF-8", tape.Node_Index(v)) }
		sigil: u8 = '!' if fo.kind == .Tag else ('&' if fo.kind == .Anchor else '*')
		if body[0] != sigil { append(&prefix, sigil) or_return }
		append(&prefix, body) or_return
	}

	if .Alias in cx.flags[v] {
		if fo.kind != .Alias || fo.deleted { return edit.refuse(.Unspellable_Value, "cannot edit tag or anchor on an alias node", tape.Node_Index(v), cx.lo[v]) }
		return add_splice(cx, cx.lo[v], cx.hi[v], prefix[:], tape.Node_Index(v), false)
	}
	if fo.kind == .Alias {
		if !fo.deleted { mark_dead_subtree(cx, v); return place(cx, v, prefix[:], {form = .Inline}, false) }
		return nil
	}
	for f in tape.facts_of(cx.doc, tape.Node_Index(v)) {
		if f.kind != fo.kind { continue }
		if !fo.deleted { return add_splice(cx, f.lo, f.lo + u64(f.n), prefix[:], tape.Node_Index(v), false) }
		hi := f.lo + u64(f.n)
		for hi < u64(len(cx.src)) && (cx.src[hi] == ' ' || cx.src[hi] == '\t') { hi += 1 }
		if hi < u64(len(cx.src)) && cx.src[hi] != '\n' && cx.src[hi] != '\r' { return add_splice(cx, f.lo, hi, nil, f.node, false) }
		return cut_line_or_inline(cx, f.node, f.lo, hi)
	}
	if fo.deleted { return nil }

	src, lo, p := cx.src, cx.lo[v], cx.parent[v]
	b := make([dynamic]u8, 0, len(prefix) + 8, cx.a) or_return
	if at := props_lo(cx.doc, v, lo); at < lo {
		append(&b, ..prefix[:]) or_return; append(&b, ' ') or_return
		return add_splice(cx, at, at, b[:], tape.Node_Index(v), false)
	}
	switch {
	case !is_block(cx, v):
		empty := cx.doc.nodes[v].kind <= .Plain && cx.doc.nodes[v].n == 0
		if empty && lo > 0 && (src[lo - 1] == ':' || src[lo - 1] == '-') { append(&b, ' ') or_return }
		append(&b, ..prefix[:]) or_return
		if !empty { append(&b, ' ') or_return }
		return add_splice(cx, lo, lo, b[:], tape.Node_Index(v), false)
	case p != NIL && cx.doc.nodes[p].kind == .Object:
		append(&b, ' ') or_return; append(&b, ..prefix[:]) or_return
		colon := colon_after(src, cx.hi[v - 1])
		return add_splice(cx, colon + 1, colon + 1, b[:], tape.Node_Index(v), false)
	case:
		append(&b, ..prefix[:]) or_return
		append_eol_indent(cx, &b, column_of(src, lo)) or_return
		return add_splice(cx, lo, lo, b[:], tape.Node_Index(v), false)
	}
}

@(private = "file")
cut_line_or_inline :: proc(cx: ^Cx, node: tape.Node_Index, lo, hi: u64) -> Edit_Error {
	if edit.first_on_line(cx.src, lo) { return add_splice(cx, edit.line_start(cx.src, lo), edit.next_line(cx.src, hi), nil, node, false) }
	return add_splice(cx, lead_end(cx.src, lo), hi, nil, node, false)
}

// ---------- Low-Level Geometry & Splice Utilities ----------

@(private = "file")
add_splice :: proc(cx: ^Cx, lo, hi: u64, text: []u8, base_node: tape.Node_Index, subtree_only: bool) -> Edit_Error {
	append(&cx.splices, edit.Splice{lo = lo, hi = hi, text = text, seq = len(cx.splices), base_node = base_node, subtree_only = subtree_only}) or_return
	return nil
}

@(private = "file")
colon_after :: proc "contextless" (src: []u8, p: u64) -> u64 #no_bounds_check {
	i := p
	for i < u64(len(src)) && (src[i] == ' ' || src[i] == '\t') { i += 1 }
	for j := i; j < u64(len(src)); {
		switch src[j] {
		case ' ', '\t', '\r', '\n': j += 1
		case '#':                   j = content_end(src, j)
		case ':':                   return j
		case:                       return i
		}
	}
	return i
}

@(private = "file")
member_text :: proc(cx: ^Cx, key: string, raw_val: []u8, is_obj: bool, col: int) -> (out: []u8, err: Edit_Error) {
	t := trim_break(raw_val)
	sh := shape_text(cx, t)
	b := make([dynamic]u8, 0, len(key) + len(t) + 16, cx.a) or_return
	if !is_obj {
		append(&b, "- ") or_return
		put_lines(cx, &b, t, col + 2 if sh.form == .Block else col) or_return
		return b[:], nil
	}
	k := spell_key(key, false, cx.a) or_return
	append(&b, ..k) or_return
	if sh.form != .Block {
		append(&b, ": ") or_return
		put_lines(cx, &b, t, col) or_return
		return b[:], nil
	}
	learn_layout(cx)
	bcol := col + (cx.seq_off if sh.seq else cx.step)
	body := t
	if sh.head > 0 {
		append(&b, ": ") or_return; append(&b, ..t[:sh.head]) or_return
		body = t[bytes.index_byte(t, '\n') + 1:]
	} else {
		append(&b, ':') or_return
	}
	append_eol_indent(cx, &b, bcol) or_return
	put_lines(cx, &b, body, bcol) or_return
	return b[:], nil
}

@(private = "file")
slot_at :: proc(cx: ^Cx, items: []Item, j: int, compact: bool) -> u64 {
	if j == 0 { return items[0].start if compact else edit.line_start(cx.src, head_of(cx, items, 0)) }
	if j < len(items) { return edit.line_start(cx.src, head_of(cx, items, j)) }
	return member_end(cx, items[len(items) - 1], column_of(cx.src, items[0].start))
}

@(private = "file")
head_of :: proc "contextless" (cx: ^Cx, items: []Item, j: int) -> u64 #no_bounds_check {
	h := items[j].start
	after := items[j - 1].end if j > 0 else 0
	for f in tape.facts_of(cx.doc, tape.Node_Index(items[j].value)) {
		if f.kind == .Comment && f.lo < h && f.lo >= after { h = f.lo }
	}
	return h
}

@(private = "file")
member_end :: proc "contextless" (cx: ^Cx, it: Item, col: int) -> u64 #no_bounds_check {
	src := cx.src
	q := it.end
	if !(q > 0 && src[q - 1] == '\n') { q = edit.next_line(src, q) }
	for {
		r := q
		for r < u64(len(src)) && blank_line(src, r) { r = edit.next_line(src, r) }
		i := r
		for i < u64(len(src)) && (src[i] == ' ' || src[i] == '\t') { i += 1 }
		if r >= u64(len(src)) || i >= u64(len(src)) || src[i] != '#' || int(i - r) <= col { return q }
		q = edit.next_line(src, r)
	}
}

@(private = "file")
blank_line :: proc "contextless" (src: []u8, ls: u64) -> bool #no_bounds_check {
	for i := ls; i < u64(len(src)); i += 1 {
		if src[i] == '\n' { return true }
		if src[i] != ' ' && src[i] != '\t' && src[i] != '\r' { return false }
	}
	return true
}

@(private = "file")
member_start :: proc(cx: ^Cx, v: u32) -> (start: u64, err: Edit_Error) {
	p := cx.parent[v]
	if p == NIL { return props_lo(cx.doc, v, cx.lo[v]), nil }
	items := items_of(cx, p) or_return
	lo, hi := 0, len(items)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if items[mid].value == v { return items[mid].start, nil }
		if items[mid].value < v { lo = mid + 1 } else { hi = mid }
	}
	return cx.lo[v], nil
}

@(private = "file")
spell_comment :: proc(b: ^[dynamic]u8, line: string, padded: bool) -> Edit_Error {
	if padded && len(line) > 0 && line[0] != ' ' { append(b, "# ") or_return } else { append(b, '#') or_return }
	append(b, line) or_return
	return nil
}

@(private = "file")
put_comment_lines :: proc(cx: ^Cx, b: ^[dynamic]u8, lines: []string, padded: bool, col: int, ended: bool) -> Edit_Error {
	for line, k in lines {
		if k > 0 { append_eol_indent(cx, b, col) or_return }
		spell_comment(b, line, padded) or_return
	}
	if ended { append(b, cx.eol) or_return }
	return nil
}

@(private = "file")
basis_of :: proc(cx: ^Cx, v: u32) -> int {
	if is_block(cx, v) { return column_of(cx.src, cx.lo[v]) }
	p := cx.parent[v]
	return 0 if p == NIL || (.Flow in cx.flags[p]) else column_of(cx.src, cx.lo[p])
}

@(private = "file")
learn_layout :: proc(cx: ^Cx) {
	if cx.learnt { return }
	cx.learnt = true
	step, seq := -1, -1
	nodes := cx.doc.nodes
	for i in 1 ..< len(nodes) {
		p := cx.parent[i]
		if p == NIL || nodes[p].kind != .Object || nodes[i].role != .Value || !is_block(cx, u32(i)) || !is_block(cx, p) { continue }
		off := column_of(cx.src, cx.lo[i]) - column_of(cx.src, cx.lo[i - 1])
		if nodes[i].kind == .Object && step < 0 && off > 0 { step = off } else if nodes[i].kind == .Array && seq < 0 && off >= 0 { seq = off }
		if step >= 0 && seq >= 0 { break }
	}
	cx.step = step if step > 0 else 2
	cx.seq_off = seq if seq >= 0 else cx.step
}

@(private = "file")
indent_end :: proc "contextless" (src: []u8, p: u64) -> u64 #no_bounds_check {
	ls := edit.line_start(src, p)
	if i := bytes.index_byte(src[ls:p], '\t'); i >= 0 { return ls + u64(i) }
	return p
}

@(private = "file")
content_end :: proc "contextless" (src: []u8, p: u64) -> u64 #no_bounds_check {
	i := p
	for i < u64(len(src)) && src[i] != '\n' { i += 1 }
	if i > p && i < u64(len(src)) && src[i - 1] == '\r' { i -= 1 }
	return i
}

@(private = "file")
column_of :: #force_inline proc "contextless" (src: []u8, p: u64) -> int { return int(p - edit.line_start(src, p)) }

@(private = "file")
lead_end :: proc "contextless" (src: []u8, p: u64) -> u64 #no_bounds_check {
	i := p
	for i > 0 && (src[i - 1] == ' ' || src[i - 1] == '\t') { i -= 1 }
	return i
}

@(private = "file")
rest_is_blank :: proc "contextless" (src: []u8, p: u64) -> bool #no_bounds_check {
	for i := p; i < u64(len(src)) && src[i] != '\n' && src[i] != '\r'; i += 1 {
		if src[i] == '#' { return true }
		if src[i] != ' ' && src[i] != '\t' { return false }
	}
	return true
}

@(private = "file")
put_spaces_to :: proc(b: ^[dynamic]u8, n: int) -> Edit_Error {
	for _ in 0 ..< n { append(b, ' ') or_return }
	return nil
}

@(private = "file")
append_eol_indent :: proc(cx: ^Cx, b: ^[dynamic]u8, col: int) -> Edit_Error {
	append(b, cx.eol) or_return
	return put_spaces_to(b, col)
}

@(private = "file")
put_lines :: proc(cx: ^Cx, b: ^[dynamic]u8, text: []u8, n: int) -> Edit_Error {
	ls := 0
	for {
		nl := bytes.index_byte(text[ls:], '\n')
		line := text[ls:] if nl < 0 else text[ls:ls + nl]
		if len(line) > 0 && line[len(line) - 1] == '\r' { line = line[:len(line) - 1] }
		if ls > 0 && len(line) > 0 { put_spaces_to(b, n) or_return }
		append(b, ..line) or_return
		if nl < 0 { return nil }
		append(b, cx.eol) or_return
		ls += nl + 1
	}
}
