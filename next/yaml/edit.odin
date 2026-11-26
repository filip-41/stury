package yaml

import "base:runtime"
import "core:bytes"
import "core:container/xar"
import "core:slice"
import "core:unicode/utf8"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import ops_write "stury:lib/ops/write"

// Byte-preserving YAML 1.2 / Yaml_Merge indent composer over `edit.Overlay`:
// - Preserves all untargeted bytes verbatim (comments, anchors, tags, directives, blank lines, quotes, folded blocks,
//   block vs flow style, explicit `?` keys, CRLF vs LF, custom indentation widths).
// - Enforces Group 1 `Format_Impossible` refusals (even with `Options.reflow = true`): active `<<` merge keys, edits on
//   or inside alias expansions or anchored subtrees still read by live aliases, structural/property edits on `.Alias`
//   nodes, reorders crossing `&`/`*` names, implicit keys > 1024 bytes, invalid UTF-8 / control bytes, multi-line inline
//   comments, and invalid raw values.
// - Enforces Group 2 `Layout_Conflict` (`Layout_Reflow_Needed`), reflowing ONLY the smallest enclosing container via
//   `edit.materialize_subtree` + `yaml.write` when `Options.reflow = true`.
// - Supports incremental `walk_fragment` splicing on unadorned in-place subtree replacements in `commit_document`.

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
	depth_budget := u32(tape.DEFAULT_DEPTH)
	if ov != nil && ov.base != nil {
		depth_budget = max(u32(tape.DEFAULT_DEPTH), u32(len(ov.base.nodes) + 64))
	}
	ctx := Yaml_Edit_Ctx{spec = resolved, depth = depth_budget}
	fast, target, fast_res, gerr := edit.commit_guard(ov, as(resolved), opts, true, yaml_edit_validate, &ctx, allocator)
	if gerr != nil {
		return {}, gerr
	}
	if fast {
		return fast_res, nil
	}

	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 64 * 1024}
	defer runtime.arena_destroy(&arena)
	scratch := runtime.arena_allocator(&arena)

	if ov.unlinked_parents {
		link_overlay_parents(ov) or_return
	}

	cx := Cx {
		ov      = ov,
		doc     = ov.base,
		src     = ov.base.src,
		a       = scratch,
		spec    = resolved,
		opts    = opts,
		eol     = edit.detect_eol(ov.base.src),
		step    = -1,
		seq_off = -1,
	}
	cx.splices = make([dynamic]edit.Splice, 0, max(8, xar.len(ov.nodes.items)), scratch) or_return
	cx.seen = make(map[u64]struct{}, 16, scratch) or_return
	cx.items = make(map[u32][]Item, 8, scratch) or_return
	cx.reflowed = make(map[u32]struct{}, 4, scratch) or_return

	build_geometry(&cx) or_return
	mark_frozen(&cx) or_return

	if ov.root != edit.NO_HANDLE {
		compose_walk(&cx, ov.root) or_return
	}
	// Also apply any edits on unlinked/key handles reached via `ov.by_base` that `compose_walk` skipped (e.g. `.Key` edits).
	for bn, h in ov.by_base {
		if int(bn) < len(cx.doc.nodes) && cx.doc.nodes[bn].role == .Key {
			if cx.dead[bn] {
				continue
			}
			skip := false
			for anc := cx.parent[bn]; anc != NIL; anc = cx.parent[anc] {
				if cx.dead[anc] || (anc in cx.reflowed) {
					skip = true
					break
				}
			}
			if skip {
				continue
			}
			if n, ok := edit.get_node(ov, h); ok && n.has_edits && n.state == .Replaced {
				apply_key_replace(&cx, u32(bn), n) or_return
			}
		}
	}

	out, recs, rew, serr := edit.apply_splices(cx.doc.src, cx.splices[:], allocator)
	if serr != nil {
		if !opts.reflow {
			return {}, serr
		}
		// Overlapping local splices fallback: reflow smallest root/container if needed.
		delete(recs, allocator)
		delete(rew, allocator)
		delete(out, allocator)
		return reflow_fallback(&cx, target, allocator)
	}

	// Validate edited output cleanly.
	val_opts := Options{budget = {depth = ctx.depth}}
	need_full := target != cx.doc.format || len(recs) == 0
	if !need_full {
		for rec in recs {
			if !rec.subtree_only || rec.full_rewalk {
				need_full = true
				break
			}
		}
	}
	if need_full {
		if verr := validate(out, resolved, val_opts, allocator); verr != nil {
			delete(out, allocator)
			delete(recs, allocator)
			delete(rew, allocator)
			return {}, convert_tape_error(verr)
		}
	} else {
		// Validate each self-contained scalar/inline splice locally; fall back to full if it contains multiline/markers/alias/tag.
		local_ok := true
		for rec in recs {
			frag := out[rec.dst_lo:rec.dst_hi]
			if bytes.index_any(frag, transmute([]u8)string("\n\r#*&!%")) >= 0 ||
				(len(frag) >= 3 && (string(frag[:3]) == "---" || string(frag[:3]) == "...")) {
				local_ok = false
				break
			}
			if verr := validate(frag, resolved, val_opts, scratch); verr != nil {
				delete(out, allocator)
				delete(recs, allocator)
				delete(rew, allocator)
				return {}, convert_tape_error(verr)
			}
		}
		if !local_ok {
			if verr := validate(out, resolved, val_opts, allocator); verr != nil {
				delete(out, allocator)
				delete(recs, allocator)
				delete(rew, allocator)
				return {}, convert_tape_error(verr)
			}
		}
	}

	return Commit_Result {
		bytes     = out,
		dropped   = cx.dropped,
		rewritten = rew,
		splices   = recs,
		allocator = allocator,
	}, nil
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
	res = commit(ov, resolved, opts, allocator) or_return
	defer if err != nil {
		edit.destroy_commit_result(&res)
	}
	depth_budget := u32(tape.DEFAULT_DEPTH)
	if ov != nil && ov.base != nil {
		depth_budget = max(u32(tape.DEFAULT_DEPTH), u32(len(ov.base.nodes) + 64))
	}
	ctx := Yaml_Edit_Ctx{spec = resolved, depth = depth_budget}
	eff_opts := opts
	eff_opts.target = as(resolved)
	doc = edit.splice_document(ov.base, &res, eff_opts, yaml_walk_fragment_cb, &ctx, yaml_full_build_cb, &ctx, allocator) or_return
	return doc, res, nil
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

// Walks `src[range.lo:range.hi]` as a standalone YAML value and shifts offsets by `range.lo`.
walk_fragment :: proc(
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	spec := Spec.Yaml_1_2,
	allocator := context.allocator,
) -> (
	ft: edit.Fragment_Tape,
	err: tape.Error,
) {
	_ = ctx
	d := build(src[range.lo:range.hi], spec, {}, allocator) or_return
	ft_out, aerr := edit.shift_fragment_tape(&d, range.lo, 0, 0, allocator)
	if aerr != nil {
		return ft_out, aerr
	}
	return ft_out, nil
}

// ---------- Internal Types & Helpers ----------

@(private = "file")
Yaml_Edit_Ctx :: struct {
	spec:  Spec,
	depth: u32,
}

@(private = "file")
resolve_edit_spec :: proc "contextless" (ov: ^Overlay, spec: Maybe(Spec), opts: Edit_Options) -> Spec {
	if opts.target != nil {
		return yaml_spec_from_format(opts.target)
	}
	if s, ok := spec.?; ok {
		return s
	}
	if ov != nil && ov.base != nil && ov.base.format != nil {
		return yaml_spec_from_format(ov.base.format)
	}
	return .Yaml_1_2
}

@(private = "file")
yaml_spec_from_format :: proc "contextless" (f: ^tape.Format) -> Spec {
	if f != nil && f.id == ID + tape.Format_Id(Spec.Yaml_Merge) {
		return .Yaml_Merge
	}
	return .Yaml_1_2
}

@(private = "file")
yaml_walk_fragment_cb :: proc(
	data: rawptr,
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	allocator: runtime.Allocator,
) -> (edit.Fragment_Tape, tape.Error) {
	yc := (^Yaml_Edit_Ctx)(data)
	return walk_fragment(src, range, ctx, yc.spec, allocator)
}

@(private = "file")
yaml_full_build_cb :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	yc := (^Yaml_Edit_Ctx)(data)
	return build(src, yc.spec, {budget = {depth = yc.depth}}, allocator)
}

@(private = "file")
yaml_edit_validate :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error {
	yc := (^Yaml_Edit_Ctx)(data)
	return validate(src, yc.spec, {budget = {depth = yc.depth}}, allocator)
}

@(private = "file")
convert_tape_error :: proc "contextless" (err: tape.Error) -> Edit_Error {
	switch e in err {
	case tape.Fault:
		return e
	case tape.Exceeded:
		return e
	case tape.Bad_Option:
		return e
	case runtime.Allocator_Error:
		return e
	case tape.Piece_Gap:
		return edit.refuse(.Invalid_Result, "unexpected piece gap")
	}
	return nil
}

// Populates `n.parent` lazily across `ov.by_base` nodes, materializes missing ancestor handles up to `ov.root`,
// and propagates `has_edits` + `ov.dirty` upward (matching `edit.ensure_linked` without calling `@(private)` internals).
@(private = "file")
link_overlay_parents :: proc(ov: ^Overlay) -> Edit_Error {
	if !ov.unlinked_parents {
		return nil
	}
	doc := ov.base
	if ov.parents == nil && len(doc.nodes) > 0 {
		p, perr := make([]tape.Node_Index, len(doc.nodes), ov.allocator)
		if perr != nil {
			return perr
		}
		p_owned := true
		defer if p_owned {
			delete(p, ov.allocator)
		}
		Open :: struct {
			idx, end: tape.Node_Index,
		}
		stack := make([dynamic]Open, 0, 16, ov.allocator) or_return
		defer delete(stack)
		p[0] = tape.NO_NODE
		if doc.nodes[0].kind >= .Array && doc.nodes[0].n > 1 {
			append(&stack, Open{0, tape.Node_Index(doc.nodes[0].n)}) or_return
		}
		for i in 1 ..< len(doc.nodes) {
			for len(stack) > 0 && tape.Node_Index(i) >= stack[len(stack) - 1].end {
				pop(&stack)
			}
			parent := stack[len(stack) - 1].idx if len(stack) > 0 else tape.ROOT
			p[i] = parent
			if doc.nodes[i].kind >= .Array && doc.nodes[i].n > 1 {
				append(&stack, Open{tape.Node_Index(i), tape.Node_Index(i) + tape.Node_Index(doc.nodes[i].n)}) or_return
			}
		}
		p_owned = false
		ov.parents = p
	}
	unlinked := make([dynamic]Handle, 0, 16, ov.allocator) or_return
	defer delete(unlinked)
	for bn, h in ov.by_base {
		if n, ok := edit.get_node(ov, h); ok && bn != tape.NO_NODE && bn != tape.ROOT && n.parent == edit.NO_HANDLE {
			append(&unlinked, h) or_return
		}
	}
	chain := make([dynamic]tape.Node_Index, 0, 16, ov.allocator) or_return
	defer delete(chain)
	for h in unlinked {
		n, ok := edit.get_node(ov, h)
		if !ok || n.parent != edit.NO_HANDLE || n.base == tape.NO_NODE || int(n.base) >= len(ov.parents) {
			continue
		}
		edited := n.has_edits
		clear(&chain)
		cur := ov.parents[n.base]
		parent_h := edit.NO_HANDLE
		for cur != tape.NO_NODE {
			if existing, has := ov.by_base[cur]; has {
				parent_h = existing
				break
			}
			append(&chain, cur) or_return
			if cur == tape.ROOT {
				break
			}
			cur = ov.parents[cur]
		}
		#reverse for anc in chain {
			ah: Handle
			if anc == tape.ROOT {
				ah = edit.ensure_root(ov) or_return
			} else {
				ah = edit.handle_for_base(ov, anc) or_return
				if an, aok := edit.get_node(ov, ah); aok {
					an.parent = parent_h
				}
			}
			parent_h = ah
		}
		if n2, ok2 := edit.get_node(ov, h); ok2 {
			n2.parent = parent_h
		}
		if edited && parent_h != edit.NO_HANDLE {
			ov.dirty = true
			up := parent_h
			for up != edit.NO_HANDLE {
				pn, pok := edit.get_node(ov, up)
				if !pok {
					break
				}
				pn.has_edits = true
				up = pn.parent
			}
		}
	}
	if ov.root == edit.NO_HANDLE {
		if rh, has := ov.by_base[tape.ROOT]; has {
			ov.root = rh
		}
	}
	ov.unlinked_parents = false
	return nil
}

@(private = "file")
Node_Flag :: enum u8 {
	Bracket,     // flow collection enclosed by `{...}` or `[...]`
	Flow,        // inside (or equal to) a flow collection
	Alias,       // node is expanded from `*alias` (first byte at `*`)
	After_Props, // empty scalar positioned right after properties
}

@(private = "file")
Node_Flags :: bit_set[Node_Flag;u8]

@(private = "file")
Frozen_Kind :: enum u8 {
	None,
	Aliased,
	Anchored,
	Merged,
}

@(private = "file")
NIL :: max(u32)

@(private = "file")
Item :: struct {
	key, value: u32,
	start, end: u64,
}

@(private = "file")
Text_Form :: enum u8 {
	Inline,
	Lines,
	Block,
	Literal,
}

@(private = "file")
Text_Shape :: struct {
	form: Text_Form,
	seq:  bool,
	head: int,
}

@(private = "file")
Cx :: struct {
	ov:       ^Overlay,
	doc:      ^tape.Document,
	src:      []u8,
	a:        runtime.Allocator,
	spec:     Spec,
	opts:     Edit_Options,
	eol:      string,
	parent:   []u32,
	last:     []u32,
	lo, hi:   []u64,
	flags:    []Node_Flags,
	frozen:   []Frozen_Kind,
	dead:     []bool,
	step:     int,
	seq_off:  int,
	learnt:   bool,
	splices:  [dynamic]edit.Splice,
	seen:     map[u64]struct{},
	items:    map[u32][]Item,
	reflowed: map[u32]struct{},
	dropped:  tape.Facts,
}

@(private = "file")
mark_dead_subtree :: proc "contextless" (cx: ^Cx, root: u32) #no_bounds_check {
	if int(root) >= len(cx.dead) {
		return
	}
	end := root + subtree_len(cx.doc, tape.Node_Index(root))
	for i in root ..< end {
		cx.dead[i] = true
	}
}

@(private = "file")
is_container :: #force_inline proc "contextless" (k: tape.Kind) -> bool {
	return k == .Array || k == .Object
}

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
build_geometry :: proc(cx: ^Cx) -> Edit_Error {
	doc := cx.doc
	nodes := doc.nodes
	n := len(nodes)
	cx.parent = make([]u32, n, cx.a) or_return
	cx.last = make([]u32, n, cx.a) or_return
	cx.lo = make([]u64, n, cx.a) or_return
	cx.hi = make([]u64, n, cx.a) or_return
	cx.flags = make([]Node_Flags, n, cx.a) or_return
	cx.dead = make([]bool, n, cx.a) or_return
	Open :: struct {
		id, end: u32,
	}
	stack := make([dynamic]Open, 0, 16, cx.a) or_return
	fi := 0
	copy_end, last_node := u32(0), NIL
	last_lo, last_end := u64(0), u64(0)
	for i in 0 ..< n {
		for len(stack) > 0 && u32(i) >= stack[len(stack) - 1].end {
			pop(&stack)
		}
		p := stack[len(stack) - 1].id if len(stack) > 0 else NIL
		cx.parent[i], cx.last[i] = p, NIL
		if p != NIL {
			cx.last[p] = u32(i)
			if .Flow in cx.flags[p] {
				cx.flags[i] += {.Flow}
			}
		}
		nd := nodes[i]
		head, tail := bounds(cx.src, nd)
		lo := nd.lo - u64(head)
		hi := nd.lo + u64(nd.n) + u64(tail)
		for fi < len(doc.facts) && doc.facts[fi].node < tape.Node_Index(i) {
			fi += 1
		}
		props_end := u64(0)
		for k := fi; k < len(doc.facts) && doc.facts[k].node == tape.Node_Index(i); k += 1 {
			#partial switch f := doc.facts[k]; f.kind {
			case .Alias:
				cx.flags[i] += {.Alias}
				lo, hi = f.lo, f.lo + u64(f.n)
			case .Tag, .Anchor:
				props_end = max(props_end, f.lo + u64(f.n))
			}
		}
		switch {
		case u32(i) < copy_end:
		case .Alias in cx.flags[i]:
			copy_end = u32(i) + subtree_len(doc, tape.Node_Index(i))
			last_end = max(last_end, hi)
		case nd.role == .Key && (nd.lo < last_lo || nd.lo == last_lo && (last_node != p || u32(i) != p + 1)):
			cx.flags[i] += {.Alias}
			lo, hi = alias_key_at(cx.src, cx.lo[p] if u32(i) == p + 1 else last_end, .Flow in cx.flags[i])
			last_end = hi
		case:
			if nd.lo >= last_lo {
				last_lo, last_node = nd.lo, u32(i)
			}
			if nd.kind <= .Plain && nd.n == 0 {
				if nd.role == .Key {
					props_end = key_props_end(cx.src, lo)
				}
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
			if .Alias not_in cx.flags[i] {
				lo = nd.lo
				if is_flow(doc, nd) {
					cx.flags[i] += {.Bracket, .Flow}
					hi = flow_close_end(cx.src, lo)
				} else if nd.kind == .Object && i + 1 < n {
					lo = min(lo, key_start(doc, cx.src, u32(i + 1), max(lo, nodes[i + 1].lo)))
				}
			}
			append(&stack, Open{u32(i), u32(i) + nd.n}) or_return
		}
		cx.lo[i], cx.hi[i] = lo, hi
	}
	for i := n - 1; i >= 0; i -= 1 {
		if is_block(cx, u32(i)) {
			cx.hi[i] = cx.hi[cx.last[i]] if cx.last[i] != NIL else cx.lo[i]
		}
	}
	return nil
}

@(private = "file")
alias_key_at :: proc "contextless" (src: []u8, from: u64, flow: bool) -> (lo, hi: u64) #no_bounds_check {
	lo = from
	for lo < u64(len(src)) {
		at_token := lo == 0 || kernel.is_ws(src[lo - 1])
		if src[lo] == '#' && at_token {
			lo = content_end(src, lo)
			continue
		}
		if src[lo] == '*' && (at_token || bytes.index_byte(transmute([]u8)string(",[{?"), src[lo - 1]) >= 0) {
			break
		}
		lo += 1
	}
	hi = lo + 1
	for hi < u64(len(src)) && !kernel.is_ws(src[hi]) && !(flow && is_flow_indicator(src[hi])) {
		hi += 1
	}
	return
}

@(private = "file")
key_props_end :: proc "contextless" (src: []u8, p: u64) -> u64 #no_bounds_check {
	end := p
	for i := p; i < u64(len(src)); {
		for i < u64(len(src)) && (src[i] == ' ' || src[i] == '\t') {
			i += 1
		}
		if i == u64(len(src)) || (src[i] != '!' && src[i] != '&') {
			return end
		}
		for i < u64(len(src)) && !kernel.is_ws(src[i]) {
			i += 1
		}
		end = i
	}
	return end
}

@(private = "file")
props_lo :: proc "contextless" (doc: ^tape.Document, i: u32, lo: u64) -> u64 #no_bounds_check {
	at := lo
	for f in tape.facts_of(doc, tape.Node_Index(i)) {
		if f.kind == .Tag || f.kind == .Anchor {
			at = min(at, f.lo)
		}
	}
	return at
}

@(private = "file")
key_start :: proc "contextless" (doc: ^tape.Document, src: []u8, j: u32, lo: u64) -> u64 #no_bounds_check {
	at := props_lo(doc, j, lo)
	if doc.nodes[j].n == 0 {
		q := at
		for q > 0 && kernel.is_ws(src[q - 1]) {
			q -= 1
		}
		if q > 0 && src[q - 1] == '?' {
			return q - 1
		}
	}
	for {
		k := lead_end(src, at)
		if k == at {
			return at
		}
		t := k
		for t > 0 && !kernel.is_ws(src[t - 1]) {
			t -= 1
		}
		if src[t] != '!' && src[t] != '&' {
			for f := k; f > t; f -= 1 {
				if src[f - 1] == ',' || src[f - 1] == '[' || src[f - 1] == '{' {
					t = f
					break
				}
			}
		}
		switch {
		case t == k:
			return at
		case src[t] == '!' || src[t] == '&':
			at = t
		case k - t == 1 && src[t] == '?':
			return t
		case:
			return at
		}
	}
}

// Iteratively detects `<<` merge keys, `.Alias` interiors, and `.Anchored` subtrees still read by live aliases.
@(private = "file")
mark_frozen :: proc(cx: ^Cx) -> Edit_Error {
	doc := cx.doc
	nodes := doc.nodes
	cx.frozen = make([]Frozen_Kind, len(nodes), cx.a) or_return

	if doc.format == &FORMATS[.Yaml_Merge] && holds_merge_key(cx.src, cx.a, max(u32(tape.DEFAULT_DEPTH), u32(len(nodes) + 64))) {
		for &fz in cx.frozen {
			fz = .Merged
		}
		return nil
	}

	aliases := make([dynamic]u32, 0, 8, cx.a) or_return
	for i := u32(0); i < u32(len(nodes)); i += 1 {
		if .Alias in cx.flags[i] && cx.frozen[i] == .None {
			end := i + subtree_len(doc, tape.Node_Index(i))
			for j in i + 1 ..< end {
				cx.frozen[j] = .Aliased
			}
			append(&aliases, i) or_return
		}
	}
	if len(aliases) == 0 {
		return nil
	}

	// Mark nodes destroyed or replaced by current `ov` edits so anchors only referenced by removed aliases are unlocked!
	gone := make([]bool, len(nodes), cx.a) or_return
	writes_alias := false

	// Inspect all overlay nodes iteratively via `xar` storage.
	ov := cx.ov
	n_items := xar.len(ov.nodes.items)
	for idx in 0 ..< n_items {
		en := xar.get_ptr_unsafe(&ov.nodes.items, idx)
		if en.handle.idx == 0 || !en.has_edits {
			continue
		}
		for fo in en.facts {
			if !fo.deleted && fo.kind == .Alias {
				writes_alias = true
			}
			if !fo.deleted && fo.kind == .Tag {
				// Keep checking.
			}
		}
		if en.state == .Replaced {
			if en.val.kind == .Raw && bytes.index_byte(transmute([]u8)en.val.text, '*') >= 0 {
				writes_alias = true
			}
			if en.base != tape.NO_NODE && int(en.base) < len(nodes) && nodes[en.base].role == .Value {
				gone[en.base] = true
			}
		} else if en.state == .Container_Delta && en.base != tape.NO_NODE && en.delta != nil {
			d := en.delta
			for ins in d.inserted_members {
				if cn, cok := edit.get_node(ov, ins.value); cok && cn.val.kind == .Raw && bytes.index_byte(transmute([]u8)cn.val.text, '*') >= 0 {
					writes_alias = true
				}
			}
			for ins in d.inserted_elems {
				if cn, cok := edit.get_node(ov, ins.value); cok && cn.val.kind == .Raw && bytes.index_byte(transmute([]u8)cn.val.text, '*') >= 0 {
					writes_alias = true
				}
			}
			// Mark deleted child values in `gone`.
			bc := u32(en.base)
			items := items_of(cx, bc) or_return
			if nodes[bc].kind == .Object && len(d.deleted_keys) > 0 {
				del_set := make(map[string]struct{}, len(d.deleted_keys), cx.a) or_return
				for dk in d.deleted_keys {
					if _, merr := map_insert(&del_set, dk, struct{}{}); merr != nil {
						return merr
					}
				}
				for it in items {
					tk := edit.decode_node_text_tmp(doc, tape.Node_Index(it.key), cx.a)
					if tk.text in del_set {
						gone[it.value] = true
					}
					edit.free_tmp_text(tk, cx.a)
				}
			} else if nodes[bc].kind == .Array && len(d.deleted_indices) > 0 {
				for di in d.deleted_indices {
					if int(di) < len(items) {
						gone[items[di].value] = true
					}
				}
			}
		}
	}

	if writes_alias {
		slice.fill(gone, false)
	} else {
		for i in 1 ..< len(nodes) {
			gone[i] ||= gone[cx.parent[i]]
		}
	}

	read_anchors := make(map[[2]u64]struct{}, len(aliases), cx.a) or_return
	for i in aliases {
		if !gone[i] {
			if _, merr := map_insert(&read_anchors, [2]u64{nodes[i].lo, u64(nodes[i].kind)}, struct{}{}); merr != nil {
				return merr
			}
		}
	}
	if len(read_anchors) == 0 {
		return nil
	}
	for i := u32(0); i < u32(len(nodes)); i += 1 {
		key := [2]u64{nodes[i].lo, u64(nodes[i].kind)}
		if .Alias not_in cx.flags[i] && cx.frozen[i] == .None && (key in read_anchors) {
			end := i + subtree_len(doc, tape.Node_Index(i))
			for j in i ..< end {
				cx.frozen[j] = .Anchored
			}
		}
	}
	return nil
}

@(private = "file")
holds_merge_key :: proc(src: []u8, allocator: runtime.Allocator, depth_budget: u32) -> bool {
	if !bytes.contains(src, transmute([]u8)string("<<")) {
		return false
	}
	Seek :: struct {
		protocol: hook.Protocol(hook.NO_HOOKS_CAPS, hook.Unused, hook.Unused, hook.Unused),
		src:      []u8,
		found:    bool,
	}
	seek := Seek{src = src}
	on :: proc "contextless" (h: ^Seek, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
		if t.role == .Key && (t.kind == .String || t.kind == .Plain) && t.n == 2 && h.src[t.lo] == '<' && h.src[t.lo + 1] == '<' && style_of(t.spelling) == .Plain {
			h.found = true
			return s, .Stop
		}
		return s, .Next
	}
	regs: hook.Regs
	ctx := context
	_, _, _ = walk_text(src, .Yaml_1_2, false, {budget = {depth = depth_budget}}, &seek, &regs, allocator, &ctx, on, 0, allow_empty = true, check_tail = false, allow_complex = true)
	return seek.found
}

@(private = "file")
items_of :: proc(cx: ^Cx, c: u32) -> (out: []Item, err: Edit_Error) {
	if cached, ok := cx.items[c]; ok {
		return cached, nil
	}
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
	if _, merr := map_insert(&cx.items, c, list[:]); merr != nil {
		return nil, merr
	}
	return list[:], nil
}

@(private = "file")
dash_after :: proc "contextless" (src: []u8, p: u64) -> u64 #no_bounds_check {
	i := p
	for i < u64(len(src)) {
		switch src[i] {
		case ' ', '\t', '\r', '\n':
			i += 1
		case '#':
			i = content_end(src, i)
		case:
			return i
		}
	}
	return i
}

// ---------- Compose Traversal (Iterative) ----------

@(private = "file")
compose_walk :: proc(cx: ^Cx, root: Handle) -> Edit_Error {
	stack := make([dynamic]Handle, 0, 32, cx.a) or_return
	append(&stack, root) or_return
	for len(stack) > 0 {
		h := pop(&stack)
		n, ok := edit.get_node(cx.ov, h)
		if !ok || !n.has_edits {
			continue
		}
		bn := n.base
		has_base := bn != tape.NO_NODE && int(bn) < len(cx.doc.nodes)
		if has_base {
			if cx.frozen[bn] == .Merged {
				return edit.refuse(.Unspellable_Value, "cannot edit a document with active YAML merge keys (<<)", bn, cx.lo[bn])
			}
			if cx.frozen[bn] == .Aliased {
				return edit.refuse(.Unspellable_Value, "node is inside an alias expansion; edit the anchored node instead", bn, cx.lo[bn])
			}
			if cx.frozen[bn] == .Anchored {
				// Anchored node read by a live alias: only allowed to mutate descendants? No, ANY edit changes the alias!
				return edit.refuse(.Unspellable_Value, "node has a live alias referencing its anchor", bn, cx.lo[bn])
			}
		}

		// Alias node itself (`*alias`): allow `.Replaced` (value overwrite) or `.Alias` fact update; refuse delta or other facts!
		if has_base && (.Alias in cx.flags[bn]) {
			if n.state == .Container_Delta {
				return edit.refuse(.Unspellable_Value, "cannot modify members of an alias directly", bn, cx.lo[bn])
			}
			if len(n.facts) > 0 {
				for fo in n.facts {
					if fo.kind != .Alias || fo.deleted {
						return edit.refuse(.Unspellable_Value, "an alias holds no separate tag or anchor", bn, cx.lo[bn])
					}
				}
			}
		}

		if n.state == .Replaced {
			apply_replace(cx, h, n) or_return
			continue
		}

		if len(n.facts) > 0 {
			apply_facts(cx, u32(bn), n, h) or_return
			if u32(bn) in cx.reflowed {
				continue
			}
		}

		// Duplicate key conflict on edited base objects (Group 2 -> reflow smallest enclosing object).
		if has_base && cx.doc.nodes[bn].kind == .Object {
			has_dup, derr := has_edited_duplicate_key(cx, n)
			if derr != nil {
				return derr
			}
			if has_dup {
				if !cx.opts.reflow {
					return edit.refuse(.Layout_Reflow_Needed, "editing duplicated YAML mapping key requires reflow", bn, cx.lo[bn])
				}
				emit_yaml_reflow(cx, h, u32(bn)) or_return
				continue
			}
		}

		if n.state == .Container_Delta {
			apply_container_delta(cx, h, n, &stack) or_return
			continue
		}

		// `.Ancestor`: descend into modified base children.
		if has_base && is_container(cx.doc.nodes[bn].kind) {
			anc_items := items_of(cx, u32(bn)) or_return
			for it in anc_items {
				if ch, has := cx.ov.by_base[tape.Node_Index(it.value)]; has {
					if cn, cok := edit.get_node(cx.ov, ch); cok && cn.has_edits {
						append(&stack, ch) or_return
					}
				}
			}
		}
	}
	return nil
}

@(private = "file")
has_edited_duplicate_key :: proc(cx: ^Cx, n: ^edit.Edit_Node) -> (has_dup: bool, err: Edit_Error) {
	if n.base == tape.NO_NODE || cx.doc.nodes[n.base].kind != .Object {
		return false, nil
	}
	d := n.delta
	Key_Count :: struct {
		count:  int,
		edited: bool,
	}
	seen := make(map[string]Key_Count, 8, cx.a) or_return
	edited_keys: map[string]struct{}
	if n.state != .Container_Delta && d != nil && (len(d.deleted_keys) > 0 || len(d.renamed_members) > 0) {
		edited_keys = make(map[string]struct{}, len(d.deleted_keys) + len(d.renamed_members), cx.a) or_return
		for dk in d.deleted_keys {
			if _, merr := map_insert(&edited_keys, dk, struct{}{}); merr != nil {
				return false, merr
			}
		}
		for r in d.renamed_members {
			if _, merr := map_insert(&edited_keys, r.old_key, struct{}{}); merr != nil {
				return false, merr
			}
		}
	}
	base_items := items_of(cx, u32(n.base)) or_return
	for it in base_items {
		tk := edit.decode_node_text_tmp(cx.doc, tape.Node_Index(it.key), cx.a)
		is_ed := n.state == .Container_Delta
		if !is_ed {
			if ch, has := cx.ov.by_base[tape.Node_Index(it.value)]; has {
				if cn, ok := edit.get_node(cx.ov, ch); ok && cn.has_edits {
					is_ed = true
				}
			}
		}
		if !is_ed && len(edited_keys) > 0 {
			is_ed = tk.text in edited_keys
		}
		cur := seen[tk.text]
		cur.count += 1
		if is_ed {
			cur.edited = true
		}
		if _, merr := map_insert(&seen, tk.text, cur); merr != nil {
			edit.free_tmp_text(tk, cx.a)
			return false, merr
		}
		edit.free_tmp_text(tk, cx.a)
	}
	for _, kc in seen {
		if kc.count > 1 && kc.edited {
			return true, nil
		}
	}
	return false, nil
}

@(private = "file")
apply_key_replace :: proc(cx: ^Cx, k: u32, n: ^edit.Edit_Node) -> Edit_Error {
	if cx.frozen[k] == .Merged {
		return edit.refuse(.Unspellable_Value, "cannot rename key under merge keys", tape.Node_Index(k))
	}
	if cx.frozen[k] == .Aliased || cx.frozen[k] == .Anchored {
		return edit.refuse(.Unspellable_Value, "cannot rename aliased or anchored key", tape.Node_Index(k))
	}
	name: string
	if n.val.kind == .String || n.val.kind == .Raw {
		name = n.val.text
	} else {
		return edit.refuse(.Bad_Name, "YAML mapping key must be a string", tape.Node_Index(k))
	}
	return set_key(cx, k, name)
}

@(private = "file")
apply_replace :: proc(cx: ^Cx, h: Handle, n: ^edit.Edit_Node) -> Edit_Error {
	v := u32(n.base)
	// Handle explicit fact overrides that stay outside vs inside replacement.
	style := extract_style_override(n)
	tag_over := extract_fact_override(n, .Tag)
	anch_over := extract_fact_override(n, .Anchor)
	alias_over := extract_fact_override(n, .Alias)

	if alias_over != nil && !alias_over.deleted && len(alias_over.values) > 0 {
		return apply_facts(cx, v, n, h)
	}

	raw_text, is_raw := ([]u8)(nil), false
	if n.val.kind == .Raw {
		is_raw = true
		raw_text = transmute([]u8)n.val.text
		validate_raw_value(raw_text, cx.spec, cx.a) or_return
	} else {
		buf := make([dynamic]u8, 0, 64, cx.a) or_return
		spell_overlay_value(cx, h, n, style, &buf) or_return
		raw_text = buf[:]
	}

	if v == u32(tape.ROOT) && cx.parent[v] == NIL {
		t := trim_break(raw_text)
		sh := shape_text(cx, t)
		if sh.form == .Inline || sh.form == .Lines {
			// Still respect root `---` or comments above root!
		}
	}

	// Preserve deleted/updated properties/comments on `n` if requested via `n.facts`!
	if len(n.facts) > 0 {
		for fo in n.facts {
			if fo.kind == .Comment || fo.kind == .Comment_Inline || fo.kind == .Comment_Foot {
				apply_single_comment_fact(cx, v, fo) or_return
			} else if fo.kind == .Tag || fo.kind == .Anchor {
				apply_single_prop_fact(cx, v, fo) or_return
			}
		}
	}
	_ = tag_over
	_ = anch_over
	mark_dead_subtree(cx, v)

	if is_raw {
		t := trim_break(raw_text)
		sh := shape_text(cx, t)
		raw_safe := bytes.index_any(t, transmute([]u8)string("\n\r#*&!%,[]{}")) < 0 &&
			!(len(t) >= 3 && (string(t[:3]) == "---" || string(t[:3]) == "..."))
		can_sub := v != u32(tape.ROOT) &&
			cx.doc.nodes[v].kind < .Array &&
			sh.form == .Inline &&
			raw_safe &&
			len(n.facts) == 0 &&
			len(tape.facts_of(cx.doc, tape.Node_Index(v))) == 0 &&
			cx.parent[v] != NIL &&
			!(.Flow in cx.flags[cx.parent[v]]) &&
			!(n.base != tape.NO_NODE && (.After_Props in cx.flags[v] || cx.doc.nodes[v].n == 0))
		return place(cx, v, t, sh, can_sub)
	}
	return place_spelled_value(cx, h, n, raw_text, v)
}

@(private = "file")
place_spelled_value :: proc(cx: ^Cx, h: Handle, n: ^edit.Edit_Node, raw_text: []u8, v: u32) -> Edit_Error {
	_ = h
	t := trim_break(raw_text)
	// Preserve original quotes or folded block when setting a base string without explicit style override.
	style_override := extract_style_override(n)
	if n.val.kind == .String && style_override == "" && n.base != tape.NO_NODE {
		t = spelled_as_before(cx, v, n.val.text, t)
	}
	can_sub := v != u32(tape.ROOT) &&
		cx.doc.nodes[v].kind < .Array &&
		n.val.kind < .Array &&
		n.val.kind != .Base_Ref &&
		len(n.facts) == 0 &&
		len(tape.facts_of(cx.doc, tape.Node_Index(v))) == 0 &&
		cx.parent[v] != NIL &&
		!(.Flow in cx.flags[cx.parent[v]]) &&
		!(n.base != tape.NO_NODE && (.After_Props in cx.flags[v] || cx.doc.nodes[v].n == 0))
	sh := shape_text(cx, t)
	return place(cx, v, t, sh, can_sub && (sh.form == .Inline))
}

@(private = "file")
extract_style_override :: proc "contextless" (n: ^edit.Edit_Node) -> string {
	for fo in n.facts {
		if fo.kind == .Style && !fo.deleted && len(fo.values) > 0 {
			return fo.values[0]
		}
	}
	return ""
}

@(private = "file")
extract_fact_override :: proc "contextless" (n: ^edit.Edit_Node, kind: tape.Fact_Kind) -> ^edit.Fact_Override {
	for &fo in n.facts {
		if fo.kind == kind {
			return &fo
		}
	}
	return nil
}

@(private = "file")
validate_raw_value :: proc(raw: []u8, spec: Spec, a: runtime.Allocator) -> Edit_Error {
	if len(raw) == 0 || kernel.is_ws(raw[0]) || raw[0] == '#' || raw[0] == '%' || holds_marker(raw) {
		return edit.refuse(.Unspellable_Value, "invalid raw YAML value")
	}
	doc, val, _, err := build_value(raw, spec, a)
	defer tape.destroy_document(&doc)
	if err != nil {
		return edit.refuse(.Unspellable_Value, "raw YAML value failed parse")
	}
	if int(val) < len(doc.nodes) {
		n := doc.nodes[val]
		if n.kind <= .Plain && n.n == 0 && len(tape.facts_of(&doc, val)) == 0 {
			return edit.refuse(.Unspellable_Value, "raw YAML value is empty")
		}
	}
	return nil
}

@(private = "file")
build_value :: proc(src: []u8, spec: Spec, a: runtime.Allocator) -> (doc: tape.Document, value: tape.Node_Index, offset: u64, err: tape.Error) {
	text := src
	anchors := make([dynamic]u8, 0, 64, a) or_return
	handles := make([dynamic]u8, 0, 64, a) or_return
	named := 0
	NAMES_MAX :: 64
	for tries := 0; ; tries += 1 {
		doc, err = build(text, spec, {}, a)
		if err == nil {
			if named > 0 {
				value, _ = tape.element(tape.Reader{doc = &doc}, tape.ROOT, named)
			}
			return doc, value, offset, nil
		}
		f, is_fault := err.(tape.Fault)
		if !is_fault || f.rules != &RULES || tries == NAMES_MAX {
			return doc, 0, 0, err
		}
		#partial switch Detail(f.detail) {
		case .Undefined_Alias:
			rest := text[f.at + 1:]
			name := 0
			for name < len(rest) && !kernel.is_ws(rest[name]) && bytes.index_byte(transmute([]u8)string(",[]{}"), rest[name]) < 0 {
				name += 1
			}
			append(&anchors, "- &") or_return
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
		if len(handles) > 0 {
			append(&b, ..handles[:]) or_return
			append(&b, "---\n") or_return
		}
		if named == 0 {
			offset = u64(len(b))
			append(&b, ..src) or_return
		} else {
			append(&b, ..anchors[:]) or_return
			append(&b, "- ") or_return
			offset = u64(len(b))
			for c in src {
				append(&b, c) or_return
				if c == '\n' {
					append(&b, "  ") or_return
				}
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
		if nl < 0 {
			break
		}
		ls += nl + 1
	}
	return false
}

@(private = "file")
spell_overlay_value :: proc(
	cx: ^Cx,
	h: Handle,
	n: ^edit.Edit_Node,
	style: string,
	out: ^[dynamic]u8,
) -> Edit_Error {
	// Relocating an untouched `.Base_Ref` inside the same YAML doc preserves original indentation & layout cleanly!
	if n.val.kind == .Base_Ref && len(n.facts) == 0 && !cx.opts.reflow {
		v := u32(n.val.base_ref)
		if int(v) < len(cx.doc.nodes) {
			basis := basis_of(cx, v)
			src := cx.src[cx.lo[v]:cx.hi[v]]
			pair := cx.doc.nodes[v].kind == .Object && (cx.flags[v] & {.Flow, .Bracket} == {.Flow})
			if pair {
				append(out, '{') or_return
			}
			for ls := 0; ls < len(src); {
				nl := bytes.index_byte(src[ls:], '\n')
				stop := len(src) if nl < 0 else ls + nl + 1
				line := src[ls:stop]
				if ls > 0 {
					cut := 0
					for cut < basis && cut < len(line) && line[cut] == ' ' {
						cut += 1
					}
					line = line[cut:]
				}
				append(out, ..line) or_return
				ls = stop
			}
			if pair {
				append(out, '}') or_return
			}
			return nil
		}
	}

	// Explicit scalar `.Style` override for replaced string values (`"single"`, `"double"`, `"literal"`, `"folded"`, `"plain"`).
	if n.val.kind == .String && len(style) > 0 {
		s := n.val.text
		step_ind := int(cx.opts.indent) if cx.opts.indent > 0 else 2
		b, err := spell_styled_scalar(s, style, step_ind, cx.a)
		if err != nil {
			return err
		}
		if b != nil {
			append(out, ..b) or_return
			return nil
		}
	}

	// General value / container materialization through `edit.materialize_subtree` + `yaml.write`.
	tmp_doc := edit.materialize_subtree(cx.ov, h, tape.NO_NODE, {
		skip_root_tags = false,
		include_root_comments = false,
	}, cx.a) or_return
	defer tape.destroy_document(&tmp_doc)

	step_ind := u8(cx.opts.indent) if cx.opts.indent > 0 else 2
	// Inline flow style override on container (`"flow"`): pass compact `{}` opts (`indent = 0`).
	if style == "flow" {
		step_ind = 0
	}
	encoded, _, werr := write(&tmp_doc, cx.spec, {indent = step_ind}, cx.a)
	if werr != nil {
		return convert_write_error(werr)
	}
	defer delete(encoded, cx.a)
	append(out, ..encoded) or_return
	return nil
}

@(private = "file")
spell_styled_scalar :: proc(s, style: string, ind: int, a: runtime.Allocator) -> ([]u8, Edit_Error) {
	f := facts_of_text(s, false)
	if f.invalid {
		return nil, edit.refuse(.Unspellable_Value, "YAML string must be valid UTF-8")
	}
	spill: [ops_write.ROOM_MAX]u8 = ---
	out: ops_write.Out
	if err := ops_write.out_start(&out, a, {}, ops_write.ROOM_MAX); err != nil {
		return nil, err
	}
	_ = spill
	switch style {
	case "single":
		if !f.escapes && !f.line_ends {
			put_single(&out, s)
			res, werr := ops_write.out_finish(&out)
			if werr != nil {
				return nil, convert_write_error(werr)
			}
			return res, nil
		}
	case "double":
		put_double(&out, s, false)
		res, werr := ops_write.out_finish(&out)
		if werr != nil {
			return nil, convert_write_error(werr)
		}
		return res, nil
	case "literal", "folded":
		pl := Place{block = true, keeps = .Block, folded = style == "folded"}
		if block_fits(s, f, pl) {
			put_block(&out, s, .Folded if style == "folded" else .Literal, ind)
			res, werr := ops_write.out_finish(&out)
			if werr != nil {
				return nil, convert_write_error(werr)
			}
			return res, nil
		}
	case "plain":
		if !f.escapes && !f.line_ends && !f.tab && plain_fits(s, false) && !reads_as_other(s) {
			put_str(&out, s)
			res, werr := ops_write.out_finish(&out)
			if werr != nil {
				return nil, convert_write_error(werr)
			}
			return res, nil
		}
	}
	ops_write.out_drop(&out)
	return nil, nil
}

@(private = "file")
convert_write_error :: proc "contextless" (werr: Write_Error) -> Edit_Error {
	#partial switch e in werr {
	case runtime.Allocator_Error:
		return e
	case ops_write.Refused:
		return edit.refuse(.Unspellable_Value, "value cannot be spelled in YAML", e.node)
	case tape.Bad_Option:
		return e
	}
	return edit.refuse(.Unspellable_Value, "YAML write failed")
}

// ---------- Scalar & Key Helpers ----------

@(private = "file")
trim_break :: proc "contextless" (text: []u8) -> []u8 {
	t := text
	if len(t) > 0 && t[len(t) - 1] == '\n' {
		t = t[:len(t) - 1]
		if len(t) > 0 && t[len(t) - 1] == '\r' {
			t = t[:len(t) - 1]
		}
	}
	return t
}

@(private = "file")
may_be_block :: proc "contextless" (t: []u8) -> bool {
	if len(t) == 0 {
		return false
	}
	switch t[0] {
	case '-', '?', '|', '>', '!', '&':
		return true
	}
	if t[len(t) - 1] == ':' {
		return true
	}
	for i := 0; i + 1 < len(t); i += 1 {
		if t[i] == ':' && (t[i + 1] == ' ' || t[i + 1] == '\t') {
			return true
		}
	}
	return false
}

@(private = "file")
shape_text :: proc(cx: ^Cx, t: []u8) -> Text_Shape {
	nl := bytes.index_byte(t, '\n')
	if nl < 0 && !may_be_block(t) {
		return {form = .Inline}
	}
	doc, value, offset, err := build_value(t, cx.spec, cx.a)
	defer tape.destroy_document(&doc)
	if err != nil {
		return {form = .Inline if nl < 0 else .Lines}
	}
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
	if !valid {
		return nil, false
	}
	out: ops_write.Out
	if ops_write.out_start(&out, a, {}, ops_write.ROOM_MAX) != nil {
		return nil, false
	}
	put_scalar(&out, s, shape, false)
	res, err := ops_write.out_finish(&out)
	return res, err == nil
}

@(private = "file")
spell_key :: proc(name: string, flow: bool, a: runtime.Allocator, keeps: Maybe(Style) = nil) -> ([]u8, Edit_Error) {
	if len(name) > KEY_MAX {
		return nil, edit.refuse(.Bad_Name, "YAML implicit key exceeds 1024 bytes")
	}
	spelled, ok := spell_scalar_bytes(name, Place{flow = flow, key = true, keeps = keeps}, a)
	if !ok {
		return nil, edit.refuse(.Bad_Name, "YAML key is not valid UTF-8")
	}
	return spelled, nil
}

@(private = "file")
set_key :: proc(cx: ^Cx, k: u32, name: string) -> Edit_Error {
	if _, existed := cx.seen[u64(k) << 8 | 0xff]; existed {
		return edit.refuse(.Bad_Handle, "conflicting edits on same key", tape.Node_Index(k))
	}
	if _, merr := map_insert(&cx.seen, u64(k) << 8 | 0xff, struct{}{}); merr != nil {
		return merr
	}

	lo, hi := cx.lo[k], cx.hi[k]
	keeps: Maybe(Style)
	if nd := cx.doc.nodes[k]; nd.kind == .String && .Alias not_in cx.flags[k] {
		if style := style_of(nd.spelling); style == .Single || style == .Double {
			keeps = style
		}
	}
	spelled := spell_key(name, .Flow in cx.flags[k], cx.a, keeps) or_return
	b := make([dynamic]u8, 0, len(spelled) + 4, cx.a) or_return
	if lo == hi && lo > 0 && !kernel.is_ws(cx.src[lo - 1]) && cx.src[lo - 1] != ',' && cx.src[lo - 1] != '[' && cx.src[lo - 1] != '{' {
		append(&b, ' ') or_return
	}
	append(&b, ..spelled) or_return
	if hi > lo && cx.src[hi - 1] == '\n' {
		append(&b, cx.eol) or_return
	}
	return add_splice(cx, lo, hi, b[:], tape.Node_Index(k), false)
}

@(private = "file")
spelled_as_before :: proc(cx: ^Cx, v: u32, s: string, t: []u8) -> []u8 {
	nd := cx.doc.nodes[v]
	style := style_of(nd.spelling)
	if nd.kind != .String || len(t) == 0 || t[0] == '"' {
		return t
	}
	if style == .Block && nd.lo < u64(len(cx.src)) && cx.src[nd.lo] == '>' {
		return folded_as_before(cx, s, t)
	}
	if style != .Single && style != .Double {
		return t
	}
	quote: u8 = '\'' if style == .Single else '"'
	spelled, ok := spell_scalar_bytes(s, Place{flow = .Flow in cx.flags[v], keeps = style}, cx.a)
	if !ok || len(spelled) == 0 || spelled[0] != quote {
		return t
	}
	return spelled
}

@(private = "file")
folded_as_before :: proc(cx: ^Cx, s: string, t: []u8) -> []u8 {
	body := transmute([]u8)s
	for len(body) > 0 && body[len(body) - 1] == '\n' {
		body = body[:len(body) - 1]
	}
	nl := bytes.index_byte(t, '\n')
	if t[0] != '|' || nl < 0 || bytes.index_byte(body, '\n') >= 0 {
		return t
	}
	shape, valid := shape_of(s, Place{block = true, keeps = .Block, folded = true})
	if !valid || shape != .Folded {
		return t
	}
	ind := 0
	for nl + 1 + ind < len(t) && t[nl + 1 + ind] == ' ' {
		ind += 1
	}
	out: ops_write.Out
	if ops_write.out_start(&out, cx.a, {}, ops_write.ROOM_MAX) != nil {
		return t
	}
	put_block(&out, s, .Folded, ind)
	spelled, err := ops_write.out_finish(&out)
	return trim_break(spelled) if err == nil else t
}

@(private = "file")
flow_text :: proc(cx: ^Cx, at: u32, t: []u8, sh: Text_Shape) -> (out: []u8, err: Edit_Error) {
	switch sh.form {
	case .Block, .Literal:
	case .Inline, .Lines:
		if len(t) == 0 || t[0] == '"' || t[0] == '\'' || t[0] == '[' || t[0] == '{' || t[0] == '*' || bytes.index_any(t, transmute([]u8)string(",[]{}")) < 0 {
			return t, nil
		}
	}
	doc, berr := build(t, cx.spec, {}, cx.a)
	defer tape.destroy_document(&doc)
	if berr != nil {
		return t, nil
	}
	if root := doc.nodes[tape.ROOT]; !is_container(root.kind) && root.kind == .String && len(doc.facts) == 0 {
		tk := edit.decode_node_text_tmp(&doc, tape.ROOT, cx.a)
		defer edit.free_tmp_text(tk, cx.a)
		if spelled, ok := spell_scalar_bytes(tk.text, Place{flow = true}, cx.a); ok {
			return spelled, nil
		}
	}
	text, _, werr := write(&doc, cx.spec, {}, cx.a)
	if werr != nil {
		return t, nil
	}
	text = bytes.trim_right(text, transmute([]u8)string(" \t"))
	if bytes.index_byte(text, '\n') < 0 {
		return text, nil
	}
	top := at
	for p := cx.parent[top]; p != NIL && (.Flow in cx.flags[p]); p = cx.parent[p] {
		top = p
	}
	from := edit.line_start(cx.src, cx.lo[top])
	ind := 0
	for from + u64(ind) < u64(len(cx.src)) && cx.src[from + u64(ind)] == ' ' {
		ind += 1
	}
	b := make([dynamic]u8, 0, len(text) + 16, cx.a) or_return
	put_lines(cx, &b, text, ind + 2) or_return
	if text[len(text) - 1] == '\n' {
		put_spaces_to(&b, ind + 2) or_return
	}
	return b[:], nil
}

@(private = "file")
pair_text :: proc(cx: ^Cx, v: u32, t: []u8) -> (inner_out: []u8, ok: bool, err: Edit_Error) {
	if cx.doc.nodes[v].kind != .Object || cx.flags[v] & {.Flow, .Bracket} != {.Flow} {
		return nil, false, nil
	}
	pair, perr := build(t, cx.spec, {}, cx.a)
	defer tape.destroy_document(&pair)
	if perr != nil || pair.nodes[tape.ROOT].kind != .Object || tape.child_count(&pair, tape.ROOT, pair.nodes[tape.ROOT]) != 1 {
		return nil, false, nil
	}
	inner := t
	if len(t) >= 2 && t[0] == '{' && t[len(t) - 1] == '}' {
		inner = bytes.trim_space(t[1:len(t) - 1])
	}
	wrapped := make([dynamic]u8, 0, len(inner) + 2, cx.a) or_return
	append(&wrapped, '[') or_return
	append(&wrapped, ..inner) or_return
	append(&wrapped, ']') or_return
	seq, serr := build(wrapped[:], cx.spec, {}, cx.a)
	defer tape.destroy_document(&seq)
	if serr != nil || tape.child_count(&seq, tape.ROOT, seq.nodes[tape.ROOT]) != 1 {
		return nil, false, nil
	}
	first, _ := tape.element(tape.Reader{doc = &seq}, tape.ROOT, 0)
	// Confirm structurally identical via canonical compact YAML output comparison.
	pa, _, ea := write(&pair, cx.spec, {}, cx.a)
	pb, _, eb := write(&seq, cx.spec, {node = first}, cx.a)
	defer {
		delete(pa, cx.a)
		delete(pb, cx.a)
	}
	return inner, ea == nil && eb == nil && string(pa) == string(pb), nil
}

@(private = "file")
place :: proc(cx: ^Cx, v: u32, t: []u8, sh: Text_Shape, subtree_only := false) -> Edit_Error {
	if _, existed := cx.seen[u64(v) << 8 | 0xff]; existed {
		return nil
	}
	if _, merr := map_insert(&cx.seen, u64(v) << 8 | 0xff, struct{}{}); merr != nil {
		return merr
	}

	src := cx.src
	lo, hi := cx.lo[v], cx.hi[v]
	p := cx.parent[v]
	b := make([dynamic]u8, 0, len(t) + 16, cx.a) or_return
	need_prefix_space := .After_Props in cx.flags[v] && sh.form != .Block
	if need_prefix_space {
		append(&b, ' ') or_return
	}
	if p != NIL && (.Flow in cx.flags[p]) {
		pair, pok, perr := pair_text(cx, v, t)
		if perr != nil {
			return perr
		}
		if pok {
			append(&b, ..pair) or_return
		} else {
			ft := flow_text(cx, v, t, sh) or_return
			append(&b, ..ft) or_return
		}
		return add_splice(cx, lo, hi, b[:], tape.Node_Index(v), subtree_only && !need_prefix_space)
	}
	if sh.form == .Block && (.Bracket in cx.flags[v]) && !(v in cx.reflowed) {
		ft := flow_text(cx, v, t, sh) or_return
		place_flow := bytes.trim_right(ft, transmute([]u8)string(" \r\n"))
		delete_key(&cx.seen, u64(v) << 8 | 0xff)
		return place(cx, v, place_flow, {form = .Inline}, false)
	}
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
		}
		if sh.form == .Block && !first {
			from = lead_end(src, lo)
			append(&b, cx.eol) or_return
		}
		put_lines(cx, &b, t, col) or_return
	case cx.doc.nodes[p].kind == .Object:
		done: bool
		from, done, placed_col = place_value(cx, &b, v, t, sh) or_return
		if done {
			return nil
		}
	case sh.form != .Block:
		if lo > 0 && src[lo - 1] == '-' {
			append(&b, ' ') or_return
			need_prefix_space = true
		}
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
			append(&b, cx.eol) or_return
			put_spaces_to(&b, col) or_return
		}
		put_lines(cx, &b, t, col) or_return
	}
	eol_added := false
	if hi > lo && src[hi - 1] == '\n' {
		append(&b, cx.eol) or_return
		eol_added = true
	}
	can_fast := subtree_only && from == lo && !need_prefix_space && !placed_col && !eol_added
	return add_splice(cx, from, hi, b[:], tape.Node_Index(v), can_fast)
}

@(private = "file")
place_value :: proc(cx: ^Cx, b: ^[dynamic]u8, v: u32, t: []u8, sh: Text_Shape) -> (from: u64, done: bool, extra_space: bool, err: Edit_Error) {
	src := cx.src
	lo, hi := cx.lo[v], cx.hi[v]
	key := v - 1
	kcol := column_of(src, cx.lo[cx.parent[v]])
	colon := colon_after(src, cx.hi[key])
	ks := key_start(cx.doc, src, key, cx.lo[key] if .Alias in cx.flags[key] else min(cx.lo[key], cx.doc.nodes[key].lo))
	explicit := ks < u64(len(src)) && src[ks] == '?' && (ks + 1 == u64(len(src)) || kernel.is_ws(src[ks + 1]))
	if explicit && (colon == u64(len(src)) || src[colon] != ':') {
		append(b, cx.eol) or_return
		put_spaces_to(b, kcol) or_return
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
			append(b, ' ') or_return
			append(b, ..t[:sh.head]) or_return
			body = t[min(len(t), bytes.index_byte(t, '\n') + 1):]
		}
		if hi > 0 && hi < u64(len(src)) && src[hi - 1] != '\n' && rest_is_blank(src, hi) && bytes.index_byte(src[hi:content_end(src, hi)], '#') >= 0 {
			add_splice(cx, lead_end(src, lo), hi, b[:], tape.Node_Index(v), false) or_return
			nl := edit.next_line(src, hi)
			lines := make([dynamic]u8, 0, len(body) + bcol + 4, cx.a) or_return
			if nl == u64(len(src)) && src[nl - 1] != '\n' {
				append(&lines, cx.eol) or_return
			}
			put_spaces_to(&lines, bcol) or_return
			put_lines(cx, &lines, body, bcol) or_return
			if nl < u64(len(src)) || src[nl - 1] == '\n' {
				append(&lines, cx.eol) or_return
			}
			add_splice(cx, nl, nl, lines[:], tape.Node_Index(v), false) or_return
			return hi, true, true, nil
		}
		append(b, cx.eol) or_return
		put_spaces_to(b, bcol) or_return
		put_lines(cx, b, body, bcol) or_return
		return lead_end(src, lo), false, true, nil
	}
	if !is_block(cx, v) {
		added_sp := false
		if lo == colon + 1 {
			append(b, ' ') or_return
			added_sp = true
		}
		put_lines(cx, b, t, kcol) or_return
		return lo, false, added_sp, nil
	}
	from = colon + 1
	comment: []u8
	for f in tape.facts_of(cx.doc, tape.Node_Index(v)) {
		if edit.line_start(src, f.lo) != edit.line_start(src, colon) {
			continue
		}
		#partial switch f.kind {
		case .Tag, .Anchor:
			from = max(from, f.lo + u64(f.n))
		case .Comment_Inline:
			comment = src[f.lo:f.lo + u64(f.n)]
		}
	}
	append(b, ' ') or_return
	if nl := bytes.index_byte(t, '\n'); sh.form == .Literal && comment != nil && nl >= 0 {
		append(b, ..trim_break(t[:nl + 1])) or_return
		append(b, ' ') or_return
		append(b, ..comment) or_return
		put_lines(cx, b, t[nl:], kcol) or_return
		return from, false, true, nil
	}
	put_lines(cx, b, t, kcol) or_return
	if comment != nil {
		append(b, ' ') or_return
		append(b, ..comment) or_return
	}
	return from, false, true, nil
}

// ---------- Container Delta Composer (Block & Flow) ----------

@(private = "file")
apply_container_delta :: proc(cx: ^Cx, h: Handle, n: ^edit.Edit_Node, stack: ^[dynamic]Handle) -> Edit_Error {
	c := u32(n.base)
	d := n.delta
	if d == nil {
		items := items_of(cx, c) or_return
		for it in items {
			if ch, has := cx.ov.by_base[tape.Node_Index(it.value)]; has {
				if cn, ok := edit.get_node(cx.ov, ch); ok && cn.has_edits {
					append(stack, ch) or_return
				}
			}
		}
		return nil
	}
	if cx.flags[c] & {.Flow, .Bracket} == {.Flow} {
		// Implicit single-pair mapping inside a flow sequence (`[k: v]`): only supports reflow under `opts.reflow` for structural deltas!
		if !cx.opts.reflow {
			return edit.refuse(.Layout_Reflow_Needed, "implicit pair in a flow sequence holds one member", n.base, cx.lo[c])
		}
		return emit_yaml_reflow(cx, h, c)
	}

	items := items_of(cx, c) or_return
	is_obj := cx.doc.nodes[c].kind == .Object
	removed := make([]bool, len(items), cx.a) or_return

	// Mark removed members/elements.
	if is_obj && len(d.deleted_keys) > 0 {
		del_keys := make(map[string]struct{}, len(d.deleted_keys), cx.a) or_return
		for dk in d.deleted_keys {
			if _, merr := map_insert(&del_keys, dk, struct{}{}); merr != nil {
				return merr
			}
		}
		for it, idx in items {
			tk := edit.decode_node_text_tmp(cx.doc, tape.Node_Index(it.key), cx.a)
			if tk.text in del_keys {
				removed[idx] = true
			}
			edit.free_tmp_text(tk, cx.a)
		}
	} else if !is_obj {
		for di in d.deleted_indices {
			if int(di) < len(items) {
				removed[di] = true
			}
		}
	}

	renames: map[string]string
	if is_obj && len(d.renamed_members) > 0 {
		renames = make(map[string]string, len(d.renamed_members), cx.a) or_return
		for r in d.renamed_members {
			if _, merr := map_insert(&renames, r.old_key, r.new_key); merr != nil {
				return merr
			}
		}
	}

	// Queue edits on surviving base children AND handle renames!
	for it, idx in items {
		if removed[idx] {
			if it.key != NIL {
				cx.dead[it.key] = true
			}
			mark_dead_subtree(cx, it.value)
			continue
		}
		if len(renames) > 0 {
			tk := edit.decode_node_text_tmp(cx.doc, tape.Node_Index(it.key), cx.a)
			if new_k, has_ren := renames[tk.text]; has_ren {
				edit.free_tmp_text(tk, cx.a)
				set_key(cx, it.key, new_k) or_return
			} else {
				edit.free_tmp_text(tk, cx.a)
			}
		}
		if ch, has := cx.ov.by_base[tape.Node_Index(it.value)]; has {
			if cn, ok := edit.get_node(cx.ov, ch); ok && cn.has_edits {
				append(stack, ch) or_return
			}
		}
	}

	ins_count := len(d.inserted_members) if is_obj else len(d.inserted_elems)
	has_del := false
	for r in removed {
		if r {
			has_del = true
			break
		}
	}
	has_order := len(d.order) > 0

	if !has_del && ins_count == 0 && !has_order {
		return nil
	}

	if has_order {
		edit.validate_order(d.order, removed, ins_count, cx.a) or_return
		if cross, cerr := names_cross(cx, items, removed, d.order); cerr != nil {
			return cerr
		} else if cross {
			return edit.refuse(.Bad_Order, "reorder moves an alias past its anchor", n.base, cx.lo[c])
		}
	}

	if .Bracket in cx.flags[c] {
		return regroup_flow(cx, h, n, c, items, removed, d, has_order)
	}
	if has_order {
		return reorder_block(cx, h, n, c, items, removed, d)
	}
	return regroup_block(cx, h, n, c, items, removed, d)
}

@(private = "file")
names_cross :: proc(cx: ^Cx, items: []Item, removed: []bool, order: []u32) -> (cross: bool, err: Edit_Error) {
	doc := cx.doc
	if .Alias not_in doc.present {
		return false, nil
	}
	Named :: struct {
		place: int,
		names: [dynamic]string,
	}
	named := make([dynamic]Named, 0, len(items), cx.a) or_return
	place := make([]int, len(items), cx.a) or_return
	for raw, p in order {
		k := int(raw)
		if k < len(items) {
			place[k] = p
		}
	}
	for it, k in items {
		if removed[k] {
			continue
		}
		names := make([dynamic]string, 0, 4, cx.a) or_return
		first := it.key if it.key != NIL else it.value
		end := it.value + subtree_len(doc, tape.Node_Index(it.value))
		for i in first ..< end {
			for f in tape.facts_of(doc, tape.Node_Index(i)) {
				if f.kind == .Anchor || f.kind == .Alias {
					raw := tape.span_bytes(doc, f.lo, f.n)
					nm := string(raw[1:]) if len(raw) > 0 && (raw[0] == '&' || raw[0] == '*') else string(raw)
					append(&names, nm) or_return
				}
			}
		}
		if len(names) > 0 {
			append(&named, Named{place[k], names}) or_return
		}
	}
	for a, i in named {
		for b in named[i + 1:] {
			if b.place > a.place {
				continue
			}
			for x in a.names {
				if slice.contains(b.names[:], x) {
					return true, nil
				}
			}
		}
	}
	return false, nil
}

@(private = "file")
spell_inserted_value :: proc(cx: ^Cx, ins_h: Handle) -> (out: []u8, err: Edit_Error) {
	cn, ok := edit.get_node(cx.ov, ins_h)
	if !ok {
		return nil, edit.refuse(.Bad_Handle, "invalid inserted handle")
	}
	if cn.state == .Replaced && cn.val.kind == .Raw {
		raw := transmute([]u8)cn.val.text
		validate_raw_value(raw, cx.spec, cx.a) or_return
		return raw, nil
	}
	b := make([dynamic]u8, 0, 64, cx.a) or_return
	style := extract_style_override(cn)
	spell_overlay_value(cx, ins_h, cn, style, &b) or_return
	return b[:], nil
}

@(private = "file")
reorder_block :: proc(
	cx: ^Cx,
	h: Handle,
	n: ^edit.Edit_Node,
	c: u32,
	items: []Item,
	removed: []bool,
	d: ^edit.Container_Delta,
) -> Edit_Error {
	// If any base items were ALSO deleted alongside reorder, handle reorder via normalized flow or reflow!
	for r in removed {
		if r {
			if !cx.opts.reflow {
				return edit.refuse(.Layout_Reflow_Needed, "combined block delete+reorder requires reflow", n.base, cx.lo[c])
			}
			return emit_yaml_reflow(cx, h, c)
		}
	}

	src := cx.src
	count_base := len(items)
	is_obj := cx.doc.nodes[c].kind == .Object
	if count_base == 0 {
		// Reorder on empty base block collection with inserts: write reordered inserts cleanly into regroup_block via reflow.
		if !cx.opts.reflow {
			return edit.refuse(.Layout_Reflow_Needed, "reordering empty YAML block container requires reflow", n.base, cx.lo[c])
		}
		return emit_yaml_reflow(cx, h, c)
	}
	col := column_of(src, items[0].start)
	compact := !edit.first_on_line(src, items[0].start)

	lo := make([]u64, count_base, cx.a) or_return
	hi := make([]u64, count_base, cx.a) or_return
	for j := count_base - 1; j >= 0; j -= 1 {
		switch {
		case j > 0:
			lo[j] = edit.line_start(src, head_of(cx, items, j))
		case compact:
			lo[j] = items[0].start
		case:
			hh := items[0].start
			for f in tape.facts_of(cx.doc, tape.Node_Index(items[0].value)) {
				if f.kind == .Comment && f.lo < hh && edit.first_on_line(src, f.lo) {
					hh = f.lo
				}
			}
			lo[j] = edit.line_start(src, hh)
		}
		hi[j] = member_end(cx, items[j], col)
		if j + 1 < count_base {
			hi[j] = min(hi[j], lo[j + 1])
		}
	}

	end := hi[count_base - 1]
	open_end := end > 0 && src[end - 1] != '\n'
	moves := make([dynamic]edit.Move, 0, 3 * len(d.order), cx.a) or_return

	for raw, p in d.order {
		if p > 0 && p < count_base && hi[p - 1] < lo[p] {
			append(&moves, edit.Move{text = src[hi[p - 1]:lo[p]], written = true}) or_return
		}
		last := p == len(d.order) - 1
		k := int(raw)
		if k >= count_base {
			ins_idx := k - count_base
			m: []u8
			if is_obj {
				ins := d.inserted_members[ins_idx]
				vt := spell_inserted_value(cx, ins.value) or_return
				m = member_text(cx, ins.key, vt, true, col) or_return
			} else {
				ins := d.inserted_elems[ins_idx]
				vt := spell_inserted_value(cx, ins.value) or_return
				m = member_text(cx, "", vt, false, col) or_return
			}
			b := make([dynamic]u8, 0, len(m) + col + 2, cx.a) or_return
			if !(compact && p == 0) {
				put_spaces_to(&b, col) or_return
			}
			append(&b, ..m) or_return
			if !(last && open_end) {
				append(&b, cx.eol) or_return
			}
			append(&moves, edit.Move{text = b[:], written = true}) or_return
			continue
		}
		from, to := lo[k], hi[k]
		if compact && p == 0 && k != 0 {
			if edit.line_start(src, from) != edit.line_start(src, items[k].start) {
				if !cx.opts.reflow {
					return edit.refuse(.Layout_Reflow_Needed, "member with head comments cannot move onto compact dash line", tape.Node_Index(items[k].value), items[k].start)
				}
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
			if to > from && src[to - 1] == '\r' {
				to -= 1
			}
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
regroup_block :: proc(
	cx: ^Cx,
	h: Handle,
	n: ^edit.Edit_Node,
	c: u32,
	items: []Item,
	removed: []bool,
	d: ^edit.Container_Delta,
) -> Edit_Error {
	_ = h
	_ = n
	src := cx.src
	num_items := len(items)
	is_obj := cx.doc.nodes[c].kind == .Object
	left := num_items
	for r in removed {
		left -= int(r)
	}
	col := column_of(src, items[0].start) if num_items > 0 else 0
	compact := num_items > 0 && !edit.first_on_line(src, items[0].start)

	ins_n := len(d.inserted_members) if is_obj else len(d.inserted_elems)

	if left == 0 && ins_n == 0 {
		// Preserves head comments before the removed first member when emptying a root/sequence block collection!
		p := cx.parent[c]
		if hh := edit.line_start(src, head_of(cx, items, 0)); (p == NIL || cx.doc.nodes[p].kind != .Object) && !compact && hh < edit.line_start(src, items[0].start) {
			add_splice(cx, hh, edit.line_start(src, items[0].start), nil, tape.Node_Index(c), false) or_return
		}
		return place(cx, c, transmute([]u8)string("{}" if is_obj else "[]"), {form = .Inline}, false)
	}

	Block_Ins :: struct {
		at:   int,
		text: []u8,
	}
	sorted_ins := make([]Block_Ins, ins_n, cx.a) or_return
	if is_obj {
		for ins, i in d.inserted_members {
			vt := spell_inserted_value(cx, ins.value) or_return
			mt := member_text(cx, ins.key, vt, true, col) or_return
			at := num_items if ins.at < 0 || ins.at > num_items else ins.at
			sorted_ins[i] = {at = at, text = mt}
		}
	} else {
		for ins, i in d.inserted_elems {
			vt := spell_inserted_value(cx, ins.value) or_return
			mt := member_text(cx, "", vt, false, col) or_return
			at := num_items if ins.at < 0 || ins.at > num_items else ins.at
			sorted_ins[i] = {at = at, text = mt}
		}
	}
	slice.stable_sort_by(sorted_ins, proc(a, b: Block_Ins) -> bool { return a.at < b.at })

	inserts_at :: proc "contextless" (ins: []Block_Ins, target: int) -> bool #no_bounds_check {
		lo, hi := 0, len(ins)
		for lo < hi {
			mid := lo + (hi - lo) / 2
			if ins[mid].at == target {
				return true
			}
			if ins[mid].at < target {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		return false
	}

	joined := false
	if compact && removed[0] {
		joined = num_items > 1 && !removed[1] && head_of(cx, items, 1) == items[1].start && !inserts_at(sorted_ins, 1)
		if joined {
			add_splice(cx, items[0].start, items[1].start, nil, tape.Node_Index(c), false) or_return
		} else {
			q := items[0].end
			if q > 0 && src[q - 1] == '\n' {
				q -= 1
				if q > 0 && src[q - 1] == '\r' {
					q -= 1
				}
			} else {
				q = content_end(src, q)
			}
			add_splice(cx, lead_end(src, items[0].start), q, nil, tape.Node_Index(c), false) or_return
		}
	}
	for j in 0 ..< num_items {
		if !removed[j] || (j == 0 && compact) {
			continue
		}
		add_splice(cx, slot_at(cx, items, j, compact), slot_at(cx, items, j + 1, compact), nil, tape.Node_Index(c), false) or_return
	}
	// Group inserts by position so multiple inserts at the same byte offset emit a single splice (zero overlap)!
	for idx := 0; idx < len(sorted_ins); {
		at := sorted_ins[idx].at
		if at == 0 && compact && (!removed[0] || joined) {
			b := make([dynamic]u8, 0, 64, cx.a) or_return
			for idx < len(sorted_ins) && sorted_ins[idx].at == at {
				append(&b, ..sorted_ins[idx].text) or_return
				append(&b, cx.eol) or_return
				put_spaces_to(&b, col) or_return
				idx += 1
			}
			add_splice(cx, items[0].start, items[0].start, b[:], tape.Node_Index(c), false) or_return
			continue
		}
		eff_at := 1 if (at == 0 && compact) else at
		pos := slot_at(cx, items, eff_at, compact)
		b := make([dynamic]u8, 0, 64, cx.a) or_return
		for idx < len(sorted_ins) && sorted_ins[idx].at == at {
			m := sorted_ins[idx].text
			if pos == u64(len(src)) && (pos == 0 || src[pos - 1] != '\n') {
				append(&b, cx.eol) or_return
				put_spaces_to(&b, col) or_return
				append(&b, ..m) or_return
			} else {
				put_spaces_to(&b, col) or_return
				append(&b, ..m) or_return
				append(&b, cx.eol) or_return
			}
			idx += 1
		}
		add_splice(cx, pos, pos, b[:], tape.Node_Index(c), false) or_return
	}
	return nil
}

@(private = "file")
regroup_flow :: proc(
	cx: ^Cx,
	h: Handle,
	n: ^edit.Edit_Node,
	c: u32,
	items: []Item,
	removed: []bool,
	d: ^edit.Container_Delta,
	has_order: bool,
) -> Edit_Error {
	src := cx.src
	c_lo, c_hi := cx.lo[c], cx.hi[c]
	if c_hi < c_lo + 2 {
		return edit.refuse(.Bad_Handle, "cannot locate flow container bounds", n.base, c_lo)
	}
	is_obj := cx.doc.nodes[c].kind == .Object
	num_base := len(items)
	inner_lo := c_lo + 1
	inner_hi := c_hi - 1

	// Build inserted item texts cleanly in flow form.
	ins_n := len(d.inserted_members) if is_obj else len(d.inserted_elems)
	ins_texts := make([][]u8, ins_n, cx.a) or_return
	ins_ats := make([]int, ins_n, cx.a) or_return
	if is_obj {
		for ins, i in d.inserted_members {
			vt := spell_inserted_value(cx, ins.value) or_return
			t := trim_break(vt)
			k := spell_key(ins.key, true, cx.a) or_return
			b := make([dynamic]u8, 0, len(k) + len(t) + 4, cx.a) or_return
			append(&b, ..k) or_return
			append(&b, ": ") or_return
			ft := flow_text(cx, c, t, shape_text(cx, t)) or_return
			append(&b, ..ft) or_return
			ins_texts[i] = b[:]
			ins_ats[i] = num_base if ins.at < 0 || ins.at > num_base else ins.at
		}
	} else {
		for ins, i in d.inserted_elems {
			vt := spell_inserted_value(cx, ins.value) or_return
			t := trim_break(vt)
			ft := flow_text(cx, c, t, shape_text(cx, t)) or_return
			ins_texts[i] = ft
			ins_ats[i] = num_base if ins.at < 0 || ins.at > num_base else ins.at
		}
	}

	multiline := bytes.index_byte(src[c_lo:c_hi], '\n') >= 0
	left := 0
	for k in 0 ..< num_base {
		if !removed[k] {
			left += 1
		}
	}
	if left == 0 && ins_n == 0 {
		// Refuse without reflow if internal comments exist and would be lost!
		if scan_hash_comment(src, inner_lo, inner_hi) >= 0 {
			if !cx.opts.reflow {
				return edit.refuse(.Layout_Reflow_Needed, "clearing commented flow collection requires reflow", n.base, c_lo)
			}
			return emit_yaml_reflow(cx, h, c)
		}
		return add_splice(cx, inner_lo, inner_hi, nil, tape.Node_Index(c), false)
	}

	if num_base == 0 {
		// Empty `{}` / `[]`: insert all new items cleanly (respecting `d.order` if set)!
		emit_texts := ins_texts
		if has_order {
			ordered := make([][]u8, len(d.order), cx.a) or_return
			for raw, pos in d.order {
				ordered[pos] = ins_texts[int(raw)]
			}
			emit_texts = ordered
		}
		close_indent := edit.line_indent(src, c_lo)
		b := make([dynamic]u8, 0, 64, cx.a) or_return
		ml := multiline
		for txt, i in emit_texts {
			if i > 0 {
				if ml {
					append(&b, ',') or_return
					append(&b, cx.eol) or_return
					append(&b, close_indent) or_return
					append(&b, "  ") or_return
				} else {
					append(&b, ", ") or_return
				}
			} else if ml {
				append(&b, cx.eol) or_return
				append(&b, close_indent) or_return
				append(&b, "  ") or_return
			}
			append(&b, ..txt) or_return
		}
		if ml {
			append(&b, cx.eol) or_return
			append(&b, close_indent) or_return
		}
		return add_splice(cx, inner_lo, inner_hi, b[:], tape.Node_Index(c), false)
	}

	if has_order {
		// Reorder with attached end-of-line `# ...` comments!
		item_lo := make([]u64, num_base, cx.a) or_return
		item_hi := make([]u64, num_base, cx.a) or_return
		item_indent := edit.line_indent(src, items[0].start)
		sep := detect_flow_sep(src, items)

		for it, k in items {
			ilo := it.start
			ihi := it.end
			next_bound := items[k + 1].start if k + 1 < num_base else inner_hi
			comma_pos := scan_flow_comma(src, ihi, next_bound)
			if comma_pos >= 0 {
				q := u64(comma_pos) + 1
				for q < next_bound && (src[q] == ' ' || src[q] == '\t') {
					q += 1
				}
				if q < next_bound && src[q] == '#' {
					if !multiline || !edit.first_on_line(src, items[0].start) {
						if !cx.opts.reflow {
							return edit.refuse(.Layout_Reflow_Needed, "flow collection comment conflicts with reorder", n.base, q)
						}
						return emit_yaml_reflow(cx, h, c)
					}
					end_c := q + 1
					for end_c < next_bound && src[end_c] != '\n' && src[end_c] != '\r' {
						end_c += 1
					}
					ihi = end_c
				}
			} else if !removed[k] {
				q := ihi
				for q < next_bound && (src[q] == ' ' || src[q] == '\t') {
					q += 1
				}
				if q < next_bound && src[q] == '#' {
					if !multiline || !edit.first_on_line(src, items[0].start) {
						if !cx.opts.reflow {
							return edit.refuse(.Layout_Reflow_Needed, "flow collection comment conflicts with reorder", n.base, q)
						}
						return emit_yaml_reflow(cx, h, c)
					}
					end_c := q + 1
					for end_c < next_bound && src[end_c] != '\n' && src[end_c] != '\r' {
						end_c += 1
					}
					ihi = end_c
				}
			}
			prev_end := item_hi[k - 1] if k > 0 else inner_lo
			if scan_hash_comment(src, prev_end, ilo) >= 0 || scan_hash_comment(src, ihi, next_bound) >= 0 {
				if !cx.opts.reflow {
					return edit.refuse(.Layout_Reflow_Needed, "flow collection comment conflicts with reorder", n.base, ilo)
				}
				return emit_yaml_reflow(cx, h, c)
			}
			item_lo[k] = ilo
			item_hi[k] = ihi
		}

		moves := make([dynamic]edit.Move, 0, len(d.order) * 3, cx.a) or_return
		item_lines := edit.first_on_line(src, items[0].start)
		for raw, pos in d.order {
			k := int(raw)
			if pos > 0 {
				sb := make([dynamic]u8, 0, 16, cx.a) or_return
				if item_lines {
					append(&sb, cx.eol) or_return
					append(&sb, item_indent) or_return
				} else if ins_n == 0 && pos < num_base {
					if sp := scan_flow_comma(src, items[pos - 1].end, items[pos].start); sp >= 0 {
						gap := src[u64(sp) + 1 : items[pos].start]
						if bytes.index_byte(gap, '\n') < 0 && bytes.index_byte(gap, '\r') < 0 && scan_hash_comment(src, u64(sp) + 1, items[pos].start) < 0 {
							append(&sb, ..gap) or_return
						} else {
							append(&sb, ' ') or_return
						}
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
				if cp >= 0 {
					if want_comma {
						append(&moves, edit.Move{lo = item_lo[k], hi = item_hi[k]}) or_return
					} else {
						append(&moves, edit.Move{lo = item_lo[k], hi = u64(cp)}) or_return
						if u64(cp) + 1 < item_hi[k] {
							append(&moves, edit.Move{lo = u64(cp) + 1, hi = item_hi[k]}) or_return
						}
					}
				} else if want_comma {
					append(&moves, edit.Move{lo = item_lo[k], hi = it.end}) or_return
					cbuf := make([]u8, 1, cx.a) or_return
					cbuf[0] = ','
					append(&moves, edit.Move{text = cbuf, written = true}) or_return
					if it.end < item_hi[k] {
						append(&moves, edit.Move{lo = it.end, hi = item_hi[k]}) or_return
					}
				} else {
					append(&moves, edit.Move{lo = item_lo[k], hi = item_hi[k]}) or_return
				}
			} else {
				txt := ins_texts[k - num_base]
				tb := make([dynamic]u8, 0, len(txt) + 1, cx.a) or_return
				append(&tb, ..txt) or_return
				if want_comma {
					append(&tb, ',') or_return
				}
				append(&moves, edit.Move{text = tb[:], written = true}) or_return
			}
		}
		span_lo := item_lo[0]
		span_hi := item_hi[num_base - 1]
		if tc := scan_flow_comma(src, span_hi, inner_hi); tc >= 0 {
			span_hi = u64(tc) + 1
		}
		append(&cx.splices, edit.Splice{lo = span_lo, hi = span_hi, moves = moves[:], seq = len(cx.splices), base_node = tape.Node_Index(c)}) or_return
		return nil
	}

	// Non-reorder flow insert/delete (`num_base > 0`).
	sep := detect_flow_sep(src, items)
	item_lines := edit.first_on_line(src, items[0].start)
	item_indent := edit.line_indent(src, items[0].start) if item_lines else ""

	first_surv, last_surv := -1, -1
	for r, k in removed {
		if !r {
			if first_surv < 0 {
				first_surv = k
			}
			last_surv = k
		}
	}

	slots := make([][dynamic]int, num_base + 1, cx.a) or_return
	for ins_i in 0 ..< ins_n {
		at := ins_ats[ins_i]
		slot := num_base
		for k := at; k < num_base; k += 1 {
			if !removed[k] {
				slot = k
				break
			}
		}
		if slots[slot].allocator.procedure == nil {
			slots[slot] = make([dynamic]int, 0, 2, cx.a) or_return
		}
		append(&slots[slot], ins_i) or_return
	}
	has_tail_ins := len(slots[num_base]) > 0

	// Emit deletions.
	for k in 0 ..< num_base {
		if !removed[k] {
			continue
		}
		it := items[k]
		bound := items[k + 1].start if k + 1 < num_base else inner_hi
		if k == last_surv + 1 && !has_tail_ins {
			if cp := scan_flow_comma(src, items[last_surv].end, it.start); cp >= 0 {
				add_splice(cx, u64(cp), u64(cp) + 1, nil, tape.Node_Index(c), false) or_return
			}
		}
		del_lo, del_hi := it.start, it.end
		drop_comma := k < last_surv || has_tail_ins
		if drop_comma {
			if cp := scan_flow_comma(src, del_hi, bound); cp >= 0 {
				if scan_hash_comment(src, del_hi, u64(cp)) >= 0 {
					if !cx.opts.reflow {
						return edit.refuse(.Layout_Reflow_Needed, "flow deletion hits comment before comma", n.base, del_hi)
					}
					return emit_yaml_reflow(cx, h, c)
				}
				del_hi = u64(cp) + 1
			}
		}
		if item_lines && edit.first_on_line(src, del_lo) {
			q := del_hi
			for q < bound && (src[q] == ' ' || src[q] == '\t' || src[q] == '\r') {
				q += 1
			}
			if q < bound && src[q] == '\n' {
				del_lo = edit.line_start(src, del_lo)
				del_hi = q + 1
			}
		} else {
			q := del_hi
			for q < bound && (src[q] == ' ' || src[q] == '\t') {
				q += 1
			}
			del_hi = q
			if k == last_surv + 1 && last_surv >= 0 && !has_tail_ins {
				if cp := scan_flow_comma(src, items[last_surv].end, it.start); cp >= 0 {
					after_c := u64(cp) + 1
					if after_c <= del_lo && scan_hash_comment(src, after_c, del_lo) < 0 {
						del_lo = after_c
					}
				}
			}
		}
		add_splice(cx, del_lo, del_hi, nil, tape.Node_Index(c), false) or_return
	}

	// Emit inserts before surviving slots.
	for k in 0 ..< num_base {
		if len(slots[k]) == 0 {
			continue
		}
		b := make([dynamic]u8, 0, 64, cx.a) or_return
		for ins_i in slots[k] {
			append(&b, ..ins_texts[ins_i]) or_return
			if item_lines {
				append(&b, ',') or_return
				append(&b, cx.eol) or_return
				append(&b, item_indent) or_return
			} else {
				append(&b, sep) or_return
			}
		}
		add_splice(cx, items[k].start, items[k].start, b[:], tape.Node_Index(c), false) or_return
	}

	// Emit grouped tail inserts after `last_surv`.
	if has_tail_ins && last_surv >= 0 {
		ls := items[last_surv]
		next_bound := items[last_surv + 1].start if last_surv + 1 < num_base else inner_hi
		existing_comma := scan_flow_comma(src, ls.end, next_bound)
		b := make([dynamic]u8, 0, 64, cx.a) or_return
		ins_pos: u64
		if existing_comma >= 0 {
			ins_pos = u64(existing_comma) + 1
			if item_lines {
				ins_pos = edit.next_line(src, ins_pos)
				for ins_i, idx in slots[num_base] {
					if idx > 0 {
						append(&b, ',') or_return
						append(&b, cx.eol) or_return
					}
					append(&b, item_indent) or_return
					append(&b, ..ins_texts[ins_i]) or_return
				}
				append(&b, cx.eol) or_return
			} else {
				for ins_i, idx in slots[num_base] {
					append(&b, sep if idx > 0 else " ") or_return
					append(&b, ..ins_texts[ins_i]) or_return
				}
			}
		} else {
			ins_pos = ls.end
			for ins_i in slots[num_base] {
				if item_lines {
					append(&b, ',') or_return
					append(&b, cx.eol) or_return
					append(&b, item_indent) or_return
					append(&b, ..ins_texts[ins_i]) or_return
				} else {
					append(&b, sep) or_return
					append(&b, ..ins_texts[ins_i]) or_return
				}
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
		if bytes.index_byte(gap, '#') < 0 && bytes.index_byte(gap, '\n') < 0 && bytes.index_byte(gap, ',') >= 0 {
			return string(gap)
		}
	}
	return ", "
}

@(private = "file")
scan_flow_comma :: proc "contextless" (src: []u8, lo, hi: u64) -> i64 #no_bounds_check {
	p := lo
	for p < hi {
		switch src[p] {
		case ',':
			return i64(p)
		case '#':
			if p == 0 || kernel.is_ws(src[p - 1]) {
				for p < hi && src[p] != '\n' {
					p += 1
				}
			} else {
				p += 1
			}
		case:
			p += 1
		}
	}
	return -1
}

@(private = "file")
scan_hash_comment :: proc "contextless" (src: []u8, lo, hi: u64) -> i64 #no_bounds_check {
	p := lo
	for p < hi {
		if src[p] == '#' && (p == 0 || kernel.is_ws(src[p - 1]) || is_flow_indicator(src[p - 1])) {
			return i64(p)
		}
		p += 1
	}
	return -1
}

// Reflows smallest enclosing container `h` (base node `c`) in place and marks `rewritten = true`.
@(private = "file")
emit_yaml_reflow :: proc(cx: ^Cx, h: Handle, c: u32) -> Edit_Error {
	if _, merr := map_insert(&cx.reflowed, c, struct{}{}); merr != nil {
		return merr
	}
	mark_dead_subtree(cx, c)
	tmp_doc := edit.materialize_subtree(cx.ov, h, tape.NO_NODE, {
		dedup_keys = true,
		include_root_comments = (c == u32(tape.ROOT)),
	}, cx.a) or_return
	defer tape.destroy_document(&tmp_doc)

	// Reconstruct block/flow YAML via `yaml.write`.
	step_ind := u8(cx.opts.indent) if cx.opts.indent > 0 else 2
	encoded, dropped, werr := write(&tmp_doc, cx.spec, {indent = step_ind}, cx.a)
	if werr != nil {
		return convert_write_error(werr)
	}
	keep_encoded := false
	defer if !keep_encoded {
		delete(encoded, cx.a)
	}
	cx.dropped += dropped

	if c == u32(tape.ROOT) && cx.parent[c] == NIL {
		append(&cx.splices, edit.Splice{
			lo          = 0,
			hi          = u64(len(cx.src)),
			text        = encoded,
			seq         = len(cx.splices),
			base_node   = tape.ROOT,
			rewritten   = true,
			full_rewalk = true,
		}) or_return
		keep_encoded = true
		return nil
	}

	t := trim_break(encoded)
	// Replace container `c` cleanly with `t` and mark splice `rewritten = true`.
	before_len := len(cx.splices)
	place(cx, c, t, shape_text(cx, t), false) or_return
	for i in before_len ..< len(cx.splices) {
		cx.splices[i].rewritten = true
		cx.splices[i].subtree_only = false
	}
	return nil
}

@(private = "file")
reflow_fallback :: proc(cx: ^Cx, target: ^tape.Format, allocator: runtime.Allocator) -> (res: Commit_Result, err: Edit_Error) {
	_ = target
	if cx.ov.root == edit.NO_HANDLE {
		return {}, edit.refuse(.Layout_Reflow_Needed, "cannot reflow empty overlay")
	}
	tmp_doc := edit.materialize_subtree(cx.ov, cx.ov.root, tape.ROOT, {
		dedup_keys = true,
		include_root_comments = true,
	}, cx.a) or_return
	defer tape.destroy_document(&tmp_doc)

	step_ind := u8(cx.opts.indent) if cx.opts.indent > 0 else 2
	encoded, dropped, werr := write(&tmp_doc, cx.spec, {indent = step_ind}, allocator)
	if werr != nil {
		return {}, convert_write_error(werr)
	}
	depth_budget := max(u32(tape.DEFAULT_DEPTH), u32(len(cx.doc.nodes) + 64))
	if verr := validate(encoded, cx.spec, {budget = {depth = depth_budget}}, allocator); verr != nil {
		delete(encoded, allocator)
		return {}, convert_tape_error(verr)
	}
	rew, rerr := make([]edit.Byte_Range, 1, allocator)
	if rerr != nil {
		delete(encoded, allocator)
		return {}, rerr
	}
	rew[0] = {0, u64(len(encoded))}
	recs, rec_err := make([]edit.Splice_Record, 1, allocator)
	if rec_err != nil {
		delete(rew, allocator)
		delete(encoded, allocator)
		return {}, rec_err
	}
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
			if !fo.deleted && len(fo.values) > 0 && n.state != .Replaced {
				if fo.values[0] == "flow" || fo.values[0] == "block" {
					if is_container(cx.doc.nodes[v].kind) {
						if !cx.opts.reflow {
							return edit.refuse(.Layout_Reflow_Needed, "changing container style requires reflow", n.base, cx.lo[v])
						}
						return emit_yaml_reflow(cx, h, v)
					}
				}
				if cx.doc.nodes[v].kind == .String || cx.doc.nodes[v].kind == .Plain {
					tk := edit.decode_node_text_tmp(cx.doc, tape.Node_Index(v), cx.a)
					step_ind := int(cx.opts.indent) if cx.opts.indent > 0 else 2
					b, berr := spell_styled_scalar(tk.text, fo.values[0], step_ind, cx.a)
					edit.free_tmp_text(tk, cx.a)
					if berr != nil {
						return berr
					}
					if b != nil {
						place(cx, v, trim_break(b), shape_text(cx, trim_break(b)), false) or_return
					}
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
	if _, existed := cx.seen[u64(v) << 8 | u64(fo.kind)]; existed {
		return edit.refuse(.Bad_Handle, "conflicting comment edits", tape.Node_Index(v))
	}
	if _, merr := map_insert(&cx.seen, u64(v) << 8 | u64(fo.kind), struct{}{}); merr != nil {
		return merr
	}

	if (.Flow in cx.flags[v]) && (fo.kind != .Comment_Inline || (cx.parent[v] != NIL && .Flow in cx.flags[cx.parent[v]])) {
		if !cx.opts.reflow {
			return edit.refuse(.Layout_Reflow_Needed, "comment inside a flow collection requires reflow", tape.Node_Index(v), cx.lo[v])
		}
		// Find smallest enclosing block container (or flow container -> reflows to block).
		top := v
		for cx.parent[top] != NIL && (.Flow in cx.flags[cx.parent[top]]) {
			top = cx.parent[top]
		}
		if cx.parent[top] != NIL && (.Bracket in cx.flags[top]) {
			// Reflow the flow container `top` itself.
			if th, found := cx.ov.by_base[tape.Node_Index(top)]; found {
				return emit_yaml_reflow(cx, th, top)
			}
			// Allocate temp handle for `top` so materialize_subtree sees the child edit override.
			th, err := edit.handle_for_base(cx.ov, tape.Node_Index(top))
			if err != nil {
				return err
			}
			return emit_yaml_reflow(cx, th, top)
		}
		return edit.refuse(.Layout_Reflow_Needed, "flow collection comment requires container reflow", tape.Node_Index(v), cx.lo[v])
	}

	existing := make([dynamic]tape.Fact, 0, 2, cx.a) or_return
	for f in tape.facts_of(cx.doc, tape.Node_Index(v)) {
		if f.kind == fo.kind {
			append(&existing, f) or_return
		}
	}
	lines: []string = nil if fo.deleted else fo.values
	for l in lines {
		for c in transmute([]u8)l {
			if (c < 0x20 && c != '\t') || c == 0x7f {
				return edit.refuse(.Fact_No_Place, "comment contains control characters", tape.Node_Index(v))
			}
		}
		if !utf8.valid_string(l) {
			return edit.refuse(.Fact_No_Place, "comment must be valid UTF-8", tape.Node_Index(v))
		}
	}

	if len(lines) == 0 {
		for f in existing {
			cut_comment(cx, f) or_return
		}
		return nil
	}
	if len(existing) > 1 {
		for f in existing[1:] {
			cut_comment(cx, f) or_return
		}
	}

	src := cx.src
	b := make([dynamic]u8, 0, 64, cx.a) or_return
	#partial switch fo.kind {
	case .Comment_Inline:
		if len(lines) > 1 {
			return edit.refuse(.Fact_No_Place, "inline comment cannot span multiple lines", tape.Node_Index(v))
		}
		spell_comment(&b, lines[0], fo.padded) or_return
		if len(existing) > 0 {
			f0 := existing[0]
			return add_splice(cx, f0.lo, f0.lo + u64(f0.n), b[:], tape.Node_Index(v), false)
		}
		if is_block(cx, v) || (cx.doc.nodes[v].kind == .String && style_of(cx.doc.nodes[v].spelling) == .Block) {
			if !cx.opts.reflow {
				return edit.refuse(.Layout_Reflow_Needed, "block collection or scalar has no line end for inline comment", tape.Node_Index(v), cx.lo[v])
			}
			// Reflow container to flow if requested, else refuse.
			return edit.refuse(.Fact_No_Place, "block node cannot hold inline comment directly", tape.Node_Index(v), cx.lo[v])
		}
		if !rest_is_blank(src, cx.hi[v]) || bytes.index_byte(src[cx.hi[v]:content_end(src, cx.hi[v])], '#') >= 0 {
			return edit.refuse(.Fact_No_Place, "no line end available for inline comment", tape.Node_Index(v), cx.hi[v])
		}
		sp_b := make([dynamic]u8, 0, len(b) + 1, cx.a) or_return
		append(&sp_b, ' ') or_return
		append(&sp_b, ..b[:]) or_return
		return add_splice(cx, cx.hi[v], cx.hi[v], sp_b[:], tape.Node_Index(v), false)
	case .Comment:
		if len(existing) > 0 {
			f0 := existing[0]
			put_comment_lines(cx, &b, lines, fo.padded, column_of(src, f0.lo), false) or_return
			return add_splice(cx, f0.lo, f0.lo + u64(f0.n), b[:], tape.Node_Index(v), false)
		}
		start := member_start(cx, v) or_return
		if !edit.first_on_line(src, start) {
			return edit.refuse(.Fact_No_Place, "node has no line of its own for head comment", tape.Node_Index(v), start)
		}
		put_spaces_to(&b, column_of(src, start)) or_return
		put_comment_lines(cx, &b, lines, fo.padded, column_of(src, start), true) or_return
		ls := edit.line_start(src, start)
		return add_splice(cx, ls, ls, b[:], tape.Node_Index(v), false)
	case .Comment_Foot:
		if !is_block(cx, v) {
			return edit.refuse(.Fact_No_Place, "only block collections hold foot comments", tape.Node_Index(v), cx.lo[v])
		}
		col := column_of(src, cx.lo[v])
		if len(existing) > 0 {
			f0 := existing[0]
			put_comment_lines(cx, &b, lines, fo.padded, column_of(src, f0.lo), false) or_return
			return add_splice(cx, f0.lo, f0.lo + u64(f0.n), b[:], tape.Node_Index(v), false)
		}
		q := cx.hi[v]
		if !(q > 0 && src[q - 1] == '\n') {
			q = edit.next_line(src, q)
		}
		if q == u64(len(src)) && (q == 0 || src[q - 1] != '\n') {
			append(&b, cx.eol) or_return
			put_spaces_to(&b, col) or_return
			put_comment_lines(cx, &b, lines, fo.padded, col, false) or_return
		} else {
			put_spaces_to(&b, col) or_return
			put_comment_lines(cx, &b, lines, fo.padded, col, true) or_return
		}
		return add_splice(cx, q, q, b[:], tape.Node_Index(v), false)
	}
	return nil
}

@(private = "file")
apply_single_prop_fact :: proc(cx: ^Cx, v: u32, fo: edit.Fact_Override) -> Edit_Error {
	if _, existed := cx.seen[u64(v) << 8 | u64(fo.kind)]; existed {
		return edit.refuse(.Bad_Handle, "conflicting property edits", tape.Node_Index(v))
	}
	if _, merr := map_insert(&cx.seen, u64(v) << 8 | u64(fo.kind), struct{}{}); merr != nil {
		return merr
	}

	prefix := make([dynamic]u8, 0, 32, cx.a) or_return
	if !fo.deleted {
		if len(fo.values) != 1 || len(fo.values[0]) == 0 {
			return edit.refuse(.Fact_No_Place, "YAML tag/anchor/alias must be a single non-empty token", tape.Node_Index(v))
		}
		body := fo.values[0]
		if !utf8.valid_string(body) {
			return edit.refuse(.Fact_No_Place, "property must be valid UTF-8", tape.Node_Index(v))
		}
		#partial switch fo.kind {
		case .Tag:
			if len(body) > 0 && body[0] != '!' {
				append(&prefix, '!') or_return
			}
		case .Anchor:
			if body[0] != '&' {
				append(&prefix, '&') or_return
			}
		case .Alias:
			if body[0] != '*' {
				append(&prefix, '*') or_return
			}
		}
		append(&prefix, body) or_return
	}

	if .Alias in cx.flags[v] {
		if fo.kind != .Alias || fo.deleted {
			return edit.refuse(.Unspellable_Value, "cannot edit tag or anchor on an alias node", tape.Node_Index(v), cx.lo[v])
		}
		return add_splice(cx, cx.lo[v], cx.hi[v], prefix[:], tape.Node_Index(v), false)
	}
	if fo.kind == .Alias {
		if !fo.deleted {
			mark_dead_subtree(cx, v)
			return place(cx, v, prefix[:], {form = .Inline}, false)
		}
		return nil
	}
	for f in tape.facts_of(cx.doc, tape.Node_Index(v)) {
		if f.kind != fo.kind {
			continue
		}
		if !fo.deleted {
			return add_splice(cx, f.lo, f.lo + u64(f.n), prefix[:], tape.Node_Index(v), false)
		}
		return cut_property(cx, f)
	}
	if fo.deleted {
		return nil
	}
	src := cx.src
	b := make([dynamic]u8, 0, len(prefix) + 8, cx.a) or_return
	if at := props_lo(cx.doc, v, cx.lo[v]); at < cx.lo[v] {
		append(&b, ..prefix[:]) or_return
		append(&b, ' ') or_return
		return add_splice(cx, at, at, b[:], tape.Node_Index(v), false)
	}
	lo := cx.lo[v]
	p := cx.parent[v]
	switch {
	case !is_block(cx, v):
		empty := cx.doc.nodes[v].kind <= .Plain && cx.doc.nodes[v].n == 0
		if empty && lo > 0 && (src[lo - 1] == ':' || src[lo - 1] == '-') {
			append(&b, ' ') or_return
		}
		append(&b, ..prefix[:]) or_return
		if !empty {
			append(&b, ' ') or_return
		}
		return add_splice(cx, lo, lo, b[:], tape.Node_Index(v), false)
	case p != NIL && cx.doc.nodes[p].kind == .Object:
		append(&b, ' ') or_return
		append(&b, ..prefix[:]) or_return
		colon := colon_after(src, cx.hi[v - 1])
		return add_splice(cx, colon + 1, colon + 1, b[:], tape.Node_Index(v), false)
	case:
		append(&b, ..prefix[:]) or_return
		append(&b, cx.eol) or_return
		put_spaces_to(&b, column_of(src, lo)) or_return
		return add_splice(cx, lo, lo, b[:], tape.Node_Index(v), false)
	}
}

@(private = "file")
cut_comment :: proc(cx: ^Cx, f: tape.Fact) -> Edit_Error {
	lo, hi := f.lo, f.lo + u64(f.n)
	if edit.first_on_line(cx.src, lo) {
		return add_splice(cx, edit.line_start(cx.src, lo), edit.next_line(cx.src, hi), nil, f.node, false)
	}
	return add_splice(cx, lead_end(cx.src, lo), hi, nil, f.node, false)
}

@(private = "file")
cut_property :: proc(cx: ^Cx, f: tape.Fact) -> Edit_Error {
	src := cx.src
	lo, hi := f.lo, f.lo + u64(f.n)
	for hi < u64(len(src)) && (src[hi] == ' ' || src[hi] == '\t') {
		hi += 1
	}
	if hi < u64(len(src)) && src[hi] != '\n' && src[hi] != '\r' {
		return add_splice(cx, lo, hi, nil, f.node, false)
	}
	if edit.first_on_line(src, lo) {
		return add_splice(cx, edit.line_start(src, lo), edit.next_line(src, hi), nil, f.node, false)
	}
	return add_splice(cx, lead_end(src, lo), hi, nil, f.node, false)
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
	for i < u64(len(src)) && (src[i] == ' ' || src[i] == '\t') {
		i += 1
	}
	for j := i; j < u64(len(src)); {
		switch src[j] {
		case ' ', '\t', '\r', '\n':
			j += 1
		case '#':
			j = content_end(src, j)
		case ':':
			return j
		case:
			return i
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
		append(&b, ": ") or_return
		append(&b, ..t[:sh.head]) or_return
		body = t[bytes.index_byte(t, '\n') + 1:]
	} else {
		append(&b, ':') or_return
	}
	append(&b, cx.eol) or_return
	put_spaces_to(&b, bcol) or_return
	put_lines(cx, &b, body, bcol) or_return
	return b[:], nil
}

@(private = "file")
slot_at :: proc(cx: ^Cx, items: []Item, j: int, compact: bool) -> u64 {
	switch {
	case j == 0:
		return items[0].start if compact else edit.line_start(cx.src, head_of(cx, items, 0))
	case j < len(items):
		return edit.line_start(cx.src, head_of(cx, items, j))
	}
	return member_end(cx, items[len(items) - 1], column_of(cx.src, items[0].start))
}

@(private = "file")
head_of :: proc "contextless" (cx: ^Cx, items: []Item, j: int) -> u64 #no_bounds_check {
	h := items[j].start
	after := items[j - 1].end if j > 0 else 0
	for f in tape.facts_of(cx.doc, tape.Node_Index(items[j].value)) {
		if f.kind == .Comment && f.lo < h && f.lo >= after {
			h = f.lo
		}
	}
	return h
}

@(private = "file")
member_end :: proc "contextless" (cx: ^Cx, it: Item, col: int) -> u64 #no_bounds_check {
	src := cx.src
	q := it.end
	if !(q > 0 && src[q - 1] == '\n') {
		q = edit.next_line(src, q)
	}
	for {
		r := q
		for r < u64(len(src)) && blank_line(src, r) {
			r = edit.next_line(src, r)
		}
		ccol, comment := comment_line(src, r)
		if r >= u64(len(src)) || !comment || ccol <= col {
			return q
		}
		q = edit.next_line(src, r)
	}
}

@(private = "file")
blank_line :: proc "contextless" (src: []u8, ls: u64) -> bool #no_bounds_check {
	for i := ls; i < u64(len(src)); i += 1 {
		c := src[i]
		if c == '\n' {
			return true
		}
		if c != ' ' && c != '\t' && c != '\r' {
			return false
		}
	}
	return true
}

@(private = "file")
member_start :: proc(cx: ^Cx, v: u32) -> (start: u64, err: Edit_Error) {
	p := cx.parent[v]
	if p == NIL {
		return props_lo(cx.doc, v, cx.lo[v]), nil
	}
	items := items_of(cx, p) or_return
	lo, hi := 0, len(items)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if items[mid].value == v {
			return items[mid].start, nil
		}
		if items[mid].value < v {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return cx.lo[v], nil
}

@(private = "file")
spell_comment :: proc(b: ^[dynamic]u8, line: string, padded: bool) -> Edit_Error {
	if padded && len(line) > 0 && line[0] != ' ' {
		append(b, "# ") or_return
	} else {
		append(b, '#') or_return
	}
	append(b, line) or_return
	return nil
}

@(private = "file")
put_comment_lines :: proc(cx: ^Cx, b: ^[dynamic]u8, lines: []string, padded: bool, col: int, ended: bool) -> Edit_Error {
	for line, k in lines {
		if k > 0 {
			append(b, cx.eol) or_return
			put_spaces_to(b, col) or_return
		}
		spell_comment(b, line, padded) or_return
	}
	if ended {
		append(b, cx.eol) or_return
	}
	return nil
}

@(private = "file")
basis_of :: proc(cx: ^Cx, v: u32) -> int {
	if is_block(cx, v) {
		return column_of(cx.src, cx.lo[v])
	}
	p := cx.parent[v]
	if p == NIL || (.Flow in cx.flags[p]) {
		return 0
	}
	return column_of(cx.src, cx.lo[p])
}

@(private = "file")
learn_layout :: proc(cx: ^Cx) {
	if cx.learnt {
		return
	}
	cx.learnt = true
	step, seq := -1, -1
	nodes := cx.doc.nodes
	for i in 1 ..< len(nodes) {
		p := cx.parent[i]
		if p == NIL || nodes[p].kind != .Object || nodes[i].role != .Value || !is_block(cx, u32(i)) || !is_block(cx, p) {
			continue
		}
		off := column_of(cx.src, cx.lo[i]) - column_of(cx.src, cx.lo[i - 1])
		if nodes[i].kind == .Object && step < 0 && off > 0 {
			step = off
		} else if nodes[i].kind == .Array && seq < 0 && off >= 0 {
			seq = off
		}
		if step >= 0 && seq >= 0 {
			break
		}
	}
	cx.step = step if step > 0 else 2
	cx.seq_off = seq if seq >= 0 else cx.step
}

@(private = "file")
indent_end :: proc "contextless" (src: []u8, p: u64) -> u64 #no_bounds_check {
	ls := edit.line_start(src, p)
	if i := bytes.index_byte(src[ls:p], '\t'); i >= 0 {
		return ls + u64(i)
	}
	return p
}

@(private = "file")
content_end :: proc "contextless" (src: []u8, p: u64) -> u64 #no_bounds_check {
	i := p
	for i < u64(len(src)) && src[i] != '\n' {
		i += 1
	}
	if i > p && i < u64(len(src)) && src[i - 1] == '\r' {
		i -= 1
	}
	return i
}

@(private = "file")
column_of :: proc "contextless" (src: []u8, p: u64) -> int {
	return int(p - edit.line_start(src, p))
}

@(private = "file")
lead_end :: proc "contextless" (src: []u8, p: u64) -> u64 #no_bounds_check {
	i := p
	for i > 0 && (src[i - 1] == ' ' || src[i - 1] == '\t') {
		i -= 1
	}
	return i
}

@(private = "file")
rest_is_blank :: proc "contextless" (src: []u8, p: u64) -> bool #no_bounds_check {
	for i := p; i < u64(len(src)) && src[i] != '\n' && src[i] != '\r'; i += 1 {
		if src[i] == '#' {
			return true
		}
		if src[i] != ' ' && src[i] != '\t' {
			return false
		}
	}
	return true
}

@(private = "file")
comment_line :: proc "contextless" (src: []u8, ls: u64) -> (col: int, ok: bool) #no_bounds_check {
	i := ls
	for i < u64(len(src)) && (src[i] == ' ' || src[i] == '\t') {
		i += 1
	}
	return int(i - ls), i < u64(len(src)) && src[i] == '#'
}

@(private = "file")
put_spaces_to :: proc(b: ^[dynamic]u8, n: int) -> Edit_Error {
	for _ in 0 ..< n {
		append(b, ' ') or_return
	}
	return nil
}

@(private = "file")
put_lines :: proc(cx: ^Cx, b: ^[dynamic]u8, text: []u8, n: int) -> Edit_Error {
	ls := 0
	for {
		nl := bytes.index_byte(text[ls:], '\n')
		line := text[ls:] if nl < 0 else text[ls:ls + nl]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		if ls > 0 && len(line) > 0 {
			put_spaces_to(b, n) or_return
		}
		append(b, ..line) or_return
		if nl < 0 {
			return nil
		}
		append(b, cx.eol) or_return
		ls += nl + 1
	}
}
