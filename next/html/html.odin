package html

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

@(private)
READ_STACK :: 48 * 1024

@(require_results)
validate :: #force_inline proc(src: []u8, spec := Spec.Html, opts := Options{}, allocator := context.allocator) -> tape.Error {
	hook.probe_stack(READ_STACK)
	switch spec {
	case .Html:     return validate_pieces(src, .Html, opts, {}, allocator) if opts.pieces != nil else validate_as(src, .Html, build.read_lax(opts), opts, {}, allocator)
	case .Fragment: return validate_pieces(src, .Fragment, opts, {}, allocator) if opts.pieces != nil else validate_as(src, .Fragment, build.read_lax(opts), opts, {}, allocator)
	}
	runtime.panic_contextless("html: spec out of range")
}

@(require_results)
validate_fragment :: proc(src: []u8, fopts := Fragment_Options{}, opts := Options{}, allocator := context.allocator) -> tape.Error {
	hook.probe_stack(READ_STACK)
	return validate_pieces(src, .Fragment, opts, fopts, allocator) if opts.pieces != nil else validate_as(src, .Fragment, build.read_lax(opts), opts, fopts, allocator)
}

@(require_results)
build :: #force_inline proc(src: []u8, spec := Spec.Html, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	hook.probe_stack(READ_STACK)
	if spec > max(Spec) { panic("html: spec out of range") }
	if opts.pieces != nil {
		if spec == .Html { return build_pieces(src, .Html, opts, {}, allocator) }
		return build_pieces(src, .Fragment, opts, {}, allocator)
	}
	m: hook.Read_Budget
	return build_as_inner(src, spec, opts, {}, allocator, &m)
}

@(require_results)
build_fragment :: proc(src: []u8, fopts := Fragment_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	hook.probe_stack(READ_STACK)
	if opts.pieces != nil { return build_pieces(src, .Fragment, opts, fopts, allocator) }
	m: hook.Read_Budget
	return build_as_inner(src, .Fragment, opts, fopts, allocator, &m)
}

@(require_results)
find :: #force_inline proc(src: []u8, path: []tape.Step, spec := Spec.Html, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Span_Answer, tape.Error) {
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(opts)
	switch spec {
	case .Html:
		if opts.pieces != nil { return find_pieces(src, path, .Html, read, opts, {}, allocator) }
		if lax { return find_as(src, path, .Html, true, read, opts, {}, allocator) }
		return find_as(src, path, .Html, false, read, opts, {}, allocator)
	case .Fragment:
		if opts.pieces != nil { return find_pieces(src, path, .Fragment, read, opts, {}, allocator) }
		if lax { return find_as(src, path, .Fragment, true, read, opts, {}, allocator) }
		return find_as(src, path, .Fragment, false, read, opts, {}, allocator)
	}
	panic("html: spec out of range")
}

@(require_results)
find_fragment :: proc(src: []u8, path: []tape.Step, fopts := Fragment_Options{}, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Span_Answer, tape.Error) {
	hook.probe_stack(READ_STACK)
	if opts.pieces != nil { return find_pieces(src, path, .Fragment, read, opts, fopts, allocator) }
	if build.read_lax(opts) { return find_as(src, path, .Fragment, true, read, opts, fopts, allocator) }
	return find_as(src, path, .Fragment, false, read, opts, fopts, allocator)
}

@(require_results)
scan :: #force_inline proc(src: []u8, demand: ^tape.Demand, spec := Spec.Html, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	hook.probe_stack(READ_STACK)
	if spec > max(Spec) { panic("html: spec out of range") }
	if opts.pieces != nil {
		if spec == .Html { return scan_pieces(src, demand, .Html, read, opts, {}, allocator) }
		return scan_pieces(src, demand, .Fragment, read, opts, {}, allocator)
	}
	return build_scan_once(src, demand, spec, read, opts, {}, allocator, nil)
}

@(require_results)
scan_fragment :: proc(src: []u8, demand: ^tape.Demand, fopts := Fragment_Options{}, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	hook.probe_stack(READ_STACK)
	if opts.pieces != nil { return scan_pieces(src, demand, .Fragment, read, opts, fopts, allocator) }
	return build_scan_once(src, demand, .Fragment, read, opts, fopts, allocator, nil)
}

walk :: proc(
	src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
	allocator := context.allocator, fopts := Fragment_Options{},
) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	#assert(.Walk not_in intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0))
	hook.probe_stack(READ_STACK)
	if err = tape.options_refused(&FORMATS[S], opts); err != nil { return }
	ctx := context
	if opts.pieces != nil { return piece_read(src, S, opts, fopts, h, regs, allocator, &ctx, on) }
	tree_spec := Tree_Spec.Fragment if S == .Fragment else .Document
	if build.read_lax(opts) { return walk_tree_text(src, tree_spec, opts, fopts, 0, true, h, regs, allocator, &ctx, on) }
	return walk_tree_text(src, tree_spec, opts, fopts, 0, false, h, regs, allocator, &ctx, on)
}

@(private)
parse_error_fault :: proc "contextless" (first: Parse_Error) -> tape.Fault {
	kind := tape.Fault_Kind.Bad_Char
	#partial switch first.detail {
	case .Eof_Before_Tag_Name, .Eof_In_Cdata, .Eof_In_Comment, .Eof_In_Doctype,
	     .Eof_In_Processing_Instruction, .Eof_In_Script_Html_Comment_Like_Text, .Eof_In_Tag:
		kind = .Truncated
	}
	return {at = first.at, rules = &RULES, kind = kind, detail = u8(first.detail)}
}

@(private)
validate_as :: proc(src: []u8, $S: Spec, lax: bool, opts: Options, fopts: Fragment_Options, allocator: runtime.Allocator) -> tape.Error {
	if e := tape.options_refused(&FORMATS[S], opts); e != nil { return e }
	if !build.validate_dups(&FORMATS[S], opts) { return tape.Bad_Option{"dups"} }
	m: hook.Read_Budget
	a := hook.read_budget(&m, opts, allocator)
	scratch_local: hook.Memory_Budget
	tree_alloc := hook.scratch(opts, a, &scratch_local)
	tree_spec := Tree_Spec.Fragment if S == .Fragment else .Document
	t, terr := build_tree(src, tree_spec, opts, fopts, 0, tree_alloc, .First)
	if terr != nil { return hook.memory_budget_error(&m.main, hook.memory_budget_error(&scratch_local, terr)) }
	defer tree_destroy(&t)
	if lax {
		if at, exceeded := check_tree_steps(&t, tree_spec, build.read_steps(opts)); exceeded {
			return tape.Exceeded{at = at, kind = .Steps}
		}
	}
	return parse_error_fault(t.errors[0]) if len(t.errors) > 0 else nil
}

@(private)
Orig_Object :: struct { key_lo, obj_lo: u64, key_sp: u16, end: u64 }

@(private)
build_as_inner :: proc(src: []u8, spec: Spec, opts: Options, fopts: Fragment_Options, caller: runtime.Allocator, m: ^hook.Read_Budget) -> (tape.Document, tape.Error) {
	if e := tape.options_refused(&FORMATS[spec], opts); e != nil { return {}, e }
	allocator := hook.read_budget(m, opts, caller)
	scratch_local: hook.Memory_Budget
	scratch := hook.scratch(opts, allocator, &scratch_local)
	tree_spec := Tree_Spec.Fragment if spec == .Fragment else .Document
	t, terr := build_tree(src, tree_spec, opts, fopts, 0, scratch, .None)
	if terr != nil { return {}, hook.memory_budget_error(&m.main, hook.memory_budget_error(&scratch_local, terr)) }
	defer tree_destroy(&t)
	return build_from_tree(&t, src, spec, opts, allocator, scratch, &m.main, caller)
}

@(private)
build_from_tree :: proc(t: ^Html_Tree, src: []u8, spec: Spec, opts: Options, allocator, scratch: runtime.Allocator, budget: ^hook.Memory_Budget, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	depth := min(build.read_depth(opts), u64(len(src)) + 16)
	most := build.node_most(node_bound(src, depth), opts)

	frames: [build.FRAME_DEPTH]u64 = ---
	counts_buf: [build.COUNTS_STACK]tape.Child_Count = ---
	b_buf: build.Builder = ---
	b := &b_buf
	build.builder_start(b, src, &FORMATS[spec], len(src) / build.BUILD_BYTES_PER_NODE + 16, most, frames[:min(depth, build.FRAME_DEPTH)], allocator, budget if opts.budget.memory != 0 else nil, counts = most, counts_buf = counts_buf[:], scratch = scratch)
	if b.err != nil { return {}, hook.memory_budget_error(budget, b.err) }

	xo, _ := opts.format.(tape.Xml_Options)
	k := Kept{infer = xo.infer}
	k.ends.allocator, k.texts.allocator, k.pieces.allocator, k.open.allocator = scratch, scratch, scratch, scratch
	defer kept_destroy(&k)

	regs := build.builder_regs(b)
	tree_spec := Tree_Spec.Fragment if spec == .Fragment else .Document
	steps := build.read_steps(opts)
	r := emit_tree_walk(t, tree_spec, opts, b, &regs, steps, &k, true, build.builder_hook_facts) if build.read_lax(opts) else emit_tree_walk(t, tree_spec, opts, b, &regs, steps, &k, false, build.builder_hook_facts)
	root_close, werr, _ := hook.walk_error(hook.Walk_Result(r), &RULES)
	doc, e := build.builder_end(b, regs, root_close, werr, opts.dups == .Refuse, &RULES)
	if e == nil {
		track_dups := (opts.dups == .First || opts.dups == .Last) && len(k.ends) > 0
		orig: []Orig_Object
		defer if orig != nil { delete(orig, scratch) }
		if track_dups {
			slice.sort_by(k.ends[:], proc(a, b: tape.Html_End) -> bool { return a.node < b.node })
			o, oerr := make([]Orig_Object, len(k.ends), scratch)
			if oerr != nil { tape.destroy(&doc); return {}, hook.memory_budget_error(budget, oerr) }
			orig = o
			for en, i in k.ends { orig[i] = {doc.nodes[en.node - 1].lo, doc.nodes[en.node].lo, doc.nodes[en.node - 1].spelling, en.end} }
		}
		e = build.builder_dups(&doc, opts.dups, &RULES)
		if e == nil && track_dups && .Dropped in doc.flags { remap_end_entries(&doc, orig, &k) }
	}
	if e == nil && !seal_state(&doc, &k, doc.allocator) { tape.destroy(&doc); e = runtime.Allocator_Error.Out_Of_Memory }
	return doc, build.read_end(&doc, e, budget, false, caller)
}

@(private, cold)
remap_end_entries :: proc(doc: ^tape.Document, orig: []Orig_Object, k: ^Kept) {
	clear(&k.ends)
	oi := 0
	for node, idx in doc.nodes {
		if idx == 0 || node.kind != .Object { continue }
		kl, ks, ol := doc.nodes[idx - 1].lo, doc.nodes[idx - 1].spelling, node.lo
		for oi < len(orig) && (orig[oi].key_lo != kl || orig[oi].obj_lo != ol || orig[oi].key_sp != ks) { oi += 1 }
		if oi < len(orig) { append(&k.ends, tape.Html_End{node = tape.Node_Index(idx), end = orig[oi].end}); oi += 1 }
	}
}

@(private)
html_find_path :: #force_inline proc "contextless" (format: ^tape.Format, opts: Options, path: []tape.Step) -> ([]tape.Step, tape.Error) {
	if e := tape.options_refused(format, opts); e != nil { return nil, e }
	if !build.path_dups(format, opts) { return nil, tape.Bad_Option{"dups"} }
	n := len(path)
	for n > 0 {
		if _, descends := path[n - 1].(tape.Descend); !descends { break }
		n -= 1
	}
	for s in path[:n] { if _, descends := s.(tape.Descend); descends { return nil, tape.Bad_Option{"path"} } }
	return path[:n], nil
}

@(private)
find_as :: #force_no_inline proc(src: []u8, path: []tape.Step, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, fopts: Fragment_Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	steps, refused := html_find_path(&FORMATS[S], opts, path)
	if refused != nil { return {}, refused }
	m: hook.Read_Budget
	allocator := hook.read_budget(&m, opts, caller)
	room: build.Find_Room = ---
	f: build.Finder
	if err := build.finder_start(&f, src, &FORMATS[S], steps, opts.dups, read, respell, nil, &room, allocator); err != nil {
		return {}, hook.memory_budget_error(&m.main, err)
	}
	defer build.finder_end(&f)
	regs: hook.Regs
	_, werr, tolerated := walk_tree_text(src, .Fragment if S == .Fragment else .Document, opts, fopts, 0, LAX, &f, &regs, allocator, &f.ctx, build.finder_key_skip_hook)
	answer, err := build.finder_result(&f, werr, tolerated)
	return answer, hook.memory_budget_error(&m.main, err)
}

@(private)
html_scan_refused :: #force_inline proc "contextless" (format: ^tape.Format, opts: Options, demand: ^tape.Demand) -> tape.Error {
	tape.options_refused(format, opts) or_return
	if !build.path_dups(format, opts) { return tape.Bad_Option{"dups"} }
	if demand.deep {
		for node in demand.nodes {
			for edge in demand.edges[node.edges:][:node.n_edges] {
				if .Deep in node.flags && tape.step_reach(edge.step) > 0 { return tape.Bad_Option{"path"} }
			}
		}
	}
	return nil
}

@(private)
find_from_tree :: proc(t: ^Html_Tree, src: []u8, steps: []tape.Step, $S: Spec, lax: bool, read: tape.Read_Options, opts: Options, allocator: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	room: build.Find_Room = ---
	f: build.Finder
	if err := build.finder_start(&f, src, &FORMATS[S], steps, opts.dups, read, respell, nil, &room, allocator); err != nil {
		return {}, err
	}
	defer build.finder_end(&f)
	regs: hook.Regs
	tree_spec := Tree_Spec.Fragment if S == .Fragment else .Document
	r := emit_tree_walk(t, tree_spec, opts, &f, &regs, build.read_steps(opts), nil, true, build.finder_key_skip_hook) if lax else emit_tree_walk(t, tree_spec, opts, &f, &regs, build.read_steps(opts), nil, false, build.finder_key_skip_hook)
	_, werr, _ := hook.walk_error(hook.Walk_Result(r), &RULES)
	return build.finder_result(&f, werr, false)
}

@(private)
build_scan_once :: proc(src: []u8, demand: ^tape.Demand, spec: Spec, read: tape.Read_Options, opts: Options, fopts: Fragment_Options, caller: runtime.Allocator, ext_keep: ^Kept) -> (tape.Document, tape.Error) {
	if e := html_scan_refused(&FORMATS[spec], opts, demand); e != nil { return {}, e }
	m: hook.Read_Budget
	allocator := hook.read_budget(&m, opts, caller)
	scratch_local: hook.Memory_Budget
	scratch := hook.scratch(opts, allocator, &scratch_local)
	tree_spec := Tree_Spec.Fragment if spec == .Fragment else .Document
	t, terr := build_tree(src, tree_spec, opts, fopts, 0, scratch, .None)
	if terr != nil { return {}, hook.memory_budget_error(&m.main, hook.memory_budget_error(&scratch_local, terr)) }
	defer tree_destroy(&t)
	return scan_from_tree(&t, src, demand, spec, read, opts, allocator, scratch, &m.main, caller, ext_keep)
}

@(private)
scan_from_tree :: proc(t: ^Html_Tree, src: []u8, demand: ^tape.Demand, spec: Spec, read: tape.Read_Options, opts: Options, allocator, scratch: runtime.Allocator, budget: ^hook.Memory_Budget, caller: runtime.Allocator, ext_keep: ^Kept) -> (tape.Document, tape.Error) {
	depth := min(build.read_depth(opts), u64(len(src)) + 16)
	most := build.node_most(node_bound(src, depth), opts)

	frames: [build.FRAME_DEPTH]u64 = ---
	room: build.Scan_Room = ---
	h_buf: build.Scanner = ---
	h := &h_buf
	if err := build.scanner_start(h, src, &FORMATS[spec], demand, opts.dups, read, nil, build.SCAN_NODES, most, frames[:min(depth, build.FRAME_DEPTH)], &room, allocator, budget = budget if opts.budget.memory != 0 else nil, scratch = scratch); err != nil {
		return {}, hook.memory_budget_error(budget, err)
	}

	k_local: Kept
	k := ext_keep
	if k == nil {
		k_local.ends.allocator, k_local.texts.allocator, k_local.pieces.allocator, k_local.open.allocator = scratch, scratch, scratch, scratch
		k = &k_local
	}
	if xo, is_xml := opts.format.(tape.Xml_Options); is_xml && xo.infer { k.infer = true }
	defer if ext_keep == nil { kept_destroy(&k_local) }

	regs := build.builder_regs(&h.b)
	tree_spec := Tree_Spec.Fragment if spec == .Fragment else .Document
	steps := build.read_steps(opts)
	r := emit_tree_walk(t, tree_spec, opts, h, &regs, steps, k, true, build.scanner_key_skip_hook) if build.read_lax(opts) else emit_tree_walk(t, tree_spec, opts, h, &regs, steps, k, false, build.scanner_key_skip_hook)
	root_close, werr, _ := hook.walk_error(hook.Walk_Result(r), &RULES)
	doc, e := build.scanner_end(h, regs, root_close, werr)
	if e == nil && ext_keep == nil && !seal_state(&doc, k, doc.allocator) { tape.destroy(&doc); e = runtime.Allocator_Error.Out_Of_Memory }
	return doc, build.read_end(&doc, e, budget, false, caller)
}

@(private)
respell :: proc "contextless" (src: []u8, lo, hi: u64) -> u16 { return tape.infer_token(raw_data(src), lo, u32(hi - lo)).spelling }

@(private)
node_bound :: #force_inline proc "contextless" (src: []u8, _: u64) -> u64 { return 2 * u64(len(src)) + 32 }

@(private)
walk_tree_res :: proc "contextless" (
	src: []u8, tree_spec: Tree_Spec, opts: Options, fopts: Fragment_Options, lo: u64, $LAX: bool,
	h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), keep_state: ^Kept = nil,
) -> (hook.Walk_Result, bool) {
	context = ctx^
	scratch_local: hook.Memory_Budget
	t, terr := build_tree(src, tree_spec, opts, fopts, lo, hook.scratch(opts, allocator, &scratch_local), .None)
	if terr != nil {
		#partial switch ev in hook.memory_budget_error(&scratch_local, terr) {
		case tape.Exceeded:
			#partial switch ev.kind {
			case .Depth:     return hook.walk_result(ev.at, hook.WALK_TOO_DEEP), false
			case .Steps:     return hook.walk_result(ev.at, hook.WALK_STEPS), false
			case .Expansion: return hook.walk_result(ev.at, hook.WALK_EXPANSION), false
			case .Nodes, .Memory: return hook.walk_result(ev.at, hook.WALK_NO_MEMORY), false
			}
		case tape.Fault: return hook.walk_result(ev.at, u8(ev.kind), ev.detail), false
		}
		return hook.walk_result(lo, hook.WALK_NO_MEMORY), false
	}
	defer tree_destroy(&t)
	return hook.Walk_Result(emit_tree_walk(&t, tree_spec, opts, h, regs, build.read_steps(opts), keep_state, LAX, on)), false
}

@(private)
walk_tree_text :: proc "contextless" (
	src: []u8, tree_spec: Tree_Spec, opts: Options, fopts: Fragment_Options, lo: u64, $LAX: bool,
	h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), keep_state: ^Kept = nil,
) -> (u64, tape.Error, bool) {
	r, tol := walk_tree_res(src, tree_spec, opts, fopts, lo, LAX, h, regs, allocator, ctx, on, keep_state)
	at, walk_err, _ := hook.walk_error(r, &RULES)
	return at, walk_err, tol
}
