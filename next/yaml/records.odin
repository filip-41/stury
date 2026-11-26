package yaml

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// YAML 1.2 records reader:
// - `.Concatenated`: multi-document YAML streams (`---` / `...`, including `Options.pieces` streaming windows and
//   `records_skip` error recovery via `cut_document` + `opens_past`). Uses `allow_complex = false` uniformly across
//   `records_validate`, `records_find`, and `records_scan` so `validate_keeps_faults` and `records_alone_agree` match.
// - `.Elements` / `.Members`: elements of an array or members of a mapping at `path` (iteratively traversed and walked
//   through the v2 hook protocol with zero native recursion).
// - `.Lines` / `.Seq`: refused (`Bad_Option{"framing"}`).

@(private)
Item_Record :: struct {
	lo, hi: u64,
	key:    tape.Token,
	value:  tape.Node_Index,
}

Records :: struct {
	using records:  tape.Records,
	spec:           Spec,
	held:           tape.Document,
	items:          [dynamic]Item_Record,
	cursor:         int,
	steps:          u64,
	tree_allocator: runtime.Allocator,
	tree_budget:    hook.Memory_Budget,
	end_err:        tape.Error,
	skip_line:      bool,
}

records_open :: proc(src: []u8, framing := tape.Framing.Concatenated, spec := Spec.Yaml_1_2, opts := Options{}, path: []tape.Step = nil) -> (r: Records) {
	if spec > max(Spec) {
		panic("yaml: spec out of range")
	}
	r.src, r.framing, r.spec, r.opts, r.path = src, framing, spec, opts, path
	r.release = yaml_records_release
	if framing == .Concatenated {
		r.skip = yaml_records_skip
	}
	if opts.pieces != nil {
		r.src = tape.piece_src(src, opts.pieces.from)
	}
	if e := tape.options_refused(&FORMATS[spec], opts); e != nil {
		r.err, r.at = e, .Done
	} else if framing == .Lines || framing == .Seq {
		r.err, r.at = tape.Bad_Option{"framing"}, .Done
	} else if e = build.records_path_refused(&FORMATS[spec], framing, path, opts); e != nil {
		r.err, r.at = e, .Done
	}
	return
}

@(private)
yaml_records_release :: proc(base_r: ^tape.Records) {
	r := container_of(base_r, Records, "records")
	tape.destroy_document(&r.held)
	delete(r.items)
}

@(require_results)
records_validate :: proc(r: ^Records, out: []tape.Record, allocator := context.allocator) -> int {
	lax := build.read_lax(r.opts)
	switch r.spec {
	case .Yaml_1_2:
		if lax {
			return records_validate_as(r, out, .Yaml_1_2, true, allocator)
		}
		return records_validate_as(r, out, .Yaml_1_2, false, allocator)
	case .Yaml_Merge:
		if lax {
			return records_validate_as(r, out, .Yaml_Merge, true, allocator)
		}
		return records_validate_as(r, out, .Yaml_Merge, false, allocator)
	}
	return 0
}

@(require_results)
records_find :: proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read := tape.Read_Options{}, allocator := context.allocator) -> int {
	lax := build.read_lax(r.opts)
	switch r.spec {
	case .Yaml_1_2:
		if lax {
			return records_find_as(r, path, out, answers, .Yaml_1_2, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Yaml_1_2, false, read, allocator)
	case .Yaml_Merge:
		if lax {
			return records_find_as(r, path, out, answers, .Yaml_Merge, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Yaml_Merge, false, read, allocator)
	}
	return 0
}

@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> int {
	lax := build.read_lax(r.opts)
	switch r.spec {
	case .Yaml_1_2:
		if lax {
			return records_scan_as(r, demand, out, docs, .Yaml_1_2, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Yaml_1_2, false, read, allocator)
	case .Yaml_Merge:
		if lax {
			return records_scan_as(r, demand, out, docs, .Yaml_Merge, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Yaml_Merge, false, read, allocator)
	}
	return 0
}

@(private)
records_validate_as :: #force_no_inline proc(r: ^Records, out: []tape.Record, $S: Spec, $LAX: bool, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(br: ^tape.Records, alloc: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return yaml_record_frame(container_of(br, Records, "records"), S, alloc)
	}
	walk :: #force_inline proc(br: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return yaml_record_walk(container_of(br, Records, "records"), S, LAX, lo, cut, h, regs, a, ctx, hook.no_hook)
	}
	return build.records_validate(r, out, &FORMATS[S], &RULES, caller, frame, walk)
}

@(private)
records_find_as :: #force_no_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(br: ^tape.Records, alloc: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return yaml_record_frame(container_of(br, Records, "records"), S, alloc)
	}
	walk :: #force_inline proc(br: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return yaml_record_walk(container_of(br, Records, "records"), S, LAX, lo, cut, h, regs, a, ctx, build.finder_key_skip_hook)
	}
	return build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, respell_number, nil, frame, walk)
}

@(private)
records_scan_as :: #force_no_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(br: ^tape.Records, alloc: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return yaml_record_frame(container_of(br, Records, "records"), S, alloc)
	}
	walk :: #force_inline proc(br: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		if r_rec := container_of(br, Records, "records"); r_rec.opts.pieces != nil || r_rec.framing != .Concatenated {
			h.scattered = true
		}
		return yaml_record_walk(container_of(br, Records, "records"), S, LAX, lo, cut, h, regs, a, ctx, build.scanner_key_skip_hook)
	}
	return build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, nil, yaml_record_node_bound, frame, walk)
}

@(private)
yaml_record_node_bound :: #force_inline proc "contextless" (src: []u8, _: u64) -> u64 {
	return node_bound(src, 0)
}

@(private)
yaml_record_frame :: proc(r: ^Records, $S: Spec, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) #no_bounds_check {
	n := u64(len(r.src))
	if r.at == .Done {
		return
	}
	if r.framing == .Concatenated {
		streaming := r.opts.pieces != nil && !r.opts.pieces.last
		if r.skip_line {
			if next, found := cut_document(r.src, r.pos, n); found {
				r.pos = next
				r.skip_line = false
			} else {
				if streaming {
					if n > 4 {
						ls := u64(bytes.last_index_byte(r.src[:n], '\n') + 1)
						r.pos = max(r.pos, ls)
					}
					return
				}
				r.pos = n
				r.at = .Done
				return
			}
		}
		if r.pos >= n {
			if !streaming {
				r.at = .Done
			}
			return
		}
		if streaming && r.pos == 0 && n < 3 {
			return
		}
		return r.pos, n, true
	}

	if r.at == .Start {
		if !members_open(r, S) {
			return
		}
	}
	if r.cursor >= len(r.items) {
		r.err = r.end_err
		r.at = .Done
		return
	}
	item := r.items[r.cursor]
	r.key = item.key
	return item.lo, n, true
}

@(private)
yaml_record_walk :: proc(
	r: ^Records,
	$S: Spec,
	$LAX: bool,
	lo, cut: u64,
	h: ^$H,
	regs: ^hook.Regs,
	allocator: runtime.Allocator,
	ctx: ^runtime.Context,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
) -> (walked: build.Record_Walk) {
	if r.framing != .Concatenated {
		return member_walk(r, LAX, h, regs, allocator, on)
	}
	streaming := r.opts.pieces != nil && !r.opts.pieces.last
	// When `skip_bad` or `quarantine` skipped a doc starting at BOM or middle, walk starting at `lo`.
	end_pos: u64
	found: bool
	opts := r.opts
	// Do not pass `pieces` into single-doc walk; `records` manages windowing directly.
	opts.pieces = nil
	_, err, tolerated := walk_text(r.src, S, LAX, opts, h, regs, allocator, ctx, on, lo, allow_empty = true, check_tail = false, allow_complex = false, end_pos = &end_pos, found_out = &found)
	if err != nil {
		if streaming {
			// Wait for the rest of the stream before finalizing faults or refusals so cuts match whole reads.
			return
		}
		when H != hook.No_Hooks {
			if _, is_fault := err.(tape.Fault); !is_fault {
				// Hook stopped or refused; check syntax cleanly on `r.src[lo:]` when non-fault.
				none: hook.No_Hooks
				none_regs: hook.Regs
				plain_end: u64
				plain_found: bool
				if _, verr, _ := walk_text(r.src, S, LAX, opts, &none, &none_regs, allocator, ctx, hook.no_hook, lo, allow_empty = true, check_tail = false, allow_complex = false, end_pos = &plain_end, found_out = &plain_found); verr != nil {
					r.err, r.at = verr, .Done
					return
				}
				walked.res = record_refusal(err)
				walked.hi = plain_end if plain_found && plain_end > lo else u64(len(r.src))
				walked.ok = true
				r.pos = walked.hi
				r.at = .After if r.pos < u64(len(r.src)) else .Done
				return
			}
		}
		r.err, r.at = err, .Done
		return
	}
	if !found {
		if streaming {
			if r.pos != 0 {
				r.at = .Open
			}
			return
		}
		r.at = .Done
		return
	}
	if streaming {
		n := u64(len(r.src))
		// Document is guaranteed finished before window end ONLY when strictly before `n` and not ending right on a cut `---` line.
		if end_pos >= n || (end_pos + 4 > n && r.src[end_pos] == '-') {
			return
		}
	}
	walked.res = hook.walk_result(end_pos, 0)
	walked.hi = end_pos
	walked.tolerated = tolerated
	walked.ok = true
	r.pos = end_pos
	r.at = .After if r.pos < u64(len(r.src)) || streaming else .Done
	return
}

@(private)
record_refusal :: proc "contextless" (err: tape.Error) -> hook.Walk_Result {
	#partial switch e in err {
	case tape.Exceeded:
		#partial switch e.kind {
		case .Depth:
			return hook.walk_result(e.at, hook.WALK_TOO_DEEP)
		case .Steps:
			return hook.walk_result(e.at, hook.WALK_STEPS)
		case .Expansion:
			return hook.walk_result(e.at, hook.WALK_EXPANSION)
		case .Nodes, .Memory:
			return hook.walk_result(e.at, hook.WALK_NO_MEMORY)
		}
	}
	return hook.walk_result(0, hook.WALK_NO_MEMORY)
}

@(private)
members_open :: proc(r: ^Records, $S: Spec) -> bool {
	if r.opts.pieces != nil && !r.opts.pieces.last {
		return false
	}
	r.tree_allocator = hook.scratch(r.opts, r.allocator, &r.tree_budget)
	r.at = .Open
	r.steps = build.read_steps(r.opts)
	build_opts := Options {
		dups    = .Refuse if r.opts.dups == .Refuse else .All,
		budget  = {
			depth     = r.opts.budget.depth,
			nodes     = r.opts.budget.nodes,
			expansion = r.opts.budget.expansion,
			memory    = r.opts.budget.memory,
		},
		format  = r.opts.format,
		scratch = r.opts.scratch,
	}
	doc, err := build_as(r.src, S, false, build_opts, r.tree_allocator)
	if err != nil {
		r.err = hook.memory_budget_error(&r.tree_budget, err)
		r.at = .Done
		return false
	}
	r.held = doc
	r.items.allocator = r.tree_allocator
	if r.opts.budget.steps != 0 {
		if at, past := steps_past(&r.held, r.steps); past {
			r.err = tape.Exceeded{at = at, kind = .Steps}
			r.at = .Done
			return false
		}
	}
	collect_records(r, S)
	if r.end_err != nil && len(r.items) == 0 {
		r.err = r.end_err
		r.at = .Done
		return false
	}
	if len(r.items) == 0 {
		r.at = .Done
		return false
	}
	return true
}

@(private)
steps_past :: proc "contextless" (doc: ^tape.Document, left: u64) -> (at: u64, past: bool) #no_bounds_check {
	left := left
	for n in doc.nodes {
		if n.kind > .Plain {
			left -= 1
			if left == 0 {
				return n.lo, true
			}
		}
	}
	return
}

@(private)
collect_records :: proc(r: ^Records, $S: Spec) #no_bounds_check {
	doc := &r.held
	nodes := doc.nodes
	dups := FORMATS[S].dups if r.opts.dups == .Default else r.opts.dups
	want_kind: tape.Kind = .Array if r.framing == .Elements else .Object

	Visit_Frame :: struct {
		node:       tape.Node_Index,
		end:        tape.Node_Index,
		child:      tape.Node_Index,
		step_idx:   int,
		matched_one: bool,
	}

	stack, serr := make([dynamic]Visit_Frame, 0, max(16, len(r.path) + 1), r.tree_allocator)
	if serr != nil {
		r.end_err = serr
		return
	}
	defer delete(stack)

	root_n := nodes[tape.ROOT]
	root_end := tape.Node_Index(root_n.n) if root_n.kind >= .Array else 1
	if _, err := append(&stack, Visit_Frame{node = tape.ROOT, end = root_end, child = 1, step_idx = 0}); err != nil {
		r.end_err = err
		return
	}

	given := false
	pending := false

	for len(stack) > 0 && r.end_err == nil {
		f := &stack[len(stack) - 1]
		if f.step_idx == len(r.path) {
			if nodes[f.node].kind != want_kind {
				if dups == .Last {
					pending = true
					pop(&stack)
					continue
				}
				r.end_err = build.records_kind_refusal()
				break
			}
			pending = false
			end := f.end
			if want_kind == .Object {
				for k := f.node + 1; k < end; {
					v := tape.node_after(doc, k)
					lo, hi := record_bounds(doc, v)
					if _, err := append(&r.items, Item_Record{lo = lo, hi = hi, key = nodes[k], value = v}); err != nil {
						r.end_err = err
						break
					}
					given = true
					k = tape.node_after(doc, v)
				}
			} else {
				for v := f.node + 1; v < end; v = tape.node_after(doc, v) {
					lo, hi := record_bounds(doc, v)
					if _, err := append(&r.items, Item_Record{lo = lo, hi = hi, value = v}); err != nil {
						r.end_err = err
						break
					}
					given = true
				}
			}
			pop(&stack)
			continue
		}

		step := r.path[f.step_idx]
		node := f.node
		#partial switch s in step {
		case tape.Index:
			if nodes[node].kind != .Array {
				pop(&stack)
				continue
			}
			target := int(s)
			place := 0
			v := f.node + 1
			matched := tape.NO_NODE
			for v < f.end {
				if place == target {
					matched = v
					break
				}
				place += 1
				v = tape.node_after(doc, v)
			}
			next_step := f.step_idx + 1
			pop(&stack)
			if matched != tape.NO_NODE {
				pending = false
				mn := nodes[matched]
				mend := matched + (tape.Node_Index(mn.n) if mn.kind >= .Array else 1)
				if _, err := append(&stack, Visit_Frame{node = matched, end = mend, child = matched + 1, step_idx = next_step}); err != nil {
					r.end_err = err
					break
				}
			}
		case tape.Name:
			if nodes[node].kind != .Object || (dups == .First && f.matched_one) {
				pop(&stack)
				continue
			}
			descended := false
			for f.child < f.end {
				k := f.child
				v := tape.node_after(doc, k)
				f.child = tape.node_after(doc, v)
				kn := nodes[k]
				if tape.key_names(&FORMATS[S], doc.src, kn, string(s)) {
					if dups == .Last && given {
						head, _ := bounds(doc.src, kn)
						r.end_err = tape.Fault{at = kn.lo - u64(head), rules = &RULES, kind = .Duplicate_Key}
						break
					}
					pending = false
					f.matched_one = true
					next_step := f.step_idx + 1
					vn := nodes[v]
					vend := v + (tape.Node_Index(vn.n) if vn.kind >= .Array else 1)
					if _, err := append(&stack, Visit_Frame{node = v, end = vend, child = v + 1, step_idx = next_step}); err != nil {
						r.end_err = err
					}
					descended = true
					break
				}
			}
			if !descended && r.end_err == nil {
				pop(&stack)
			}
		}
	}
	if r.end_err == nil && pending {
		r.end_err = build.records_kind_refusal()
	}
}

@(private)
record_bounds :: proc "contextless" (doc: ^tape.Document, value: tape.Node_Index) -> (lo, hi: u64) #no_bounds_check {
	n := doc.nodes[value]
	lo, hi = n.lo, n.lo + u64(n.n)
	if n.kind > .Plain {
		hi, _ = close_end(doc, value)
	} else {
		head, tail := bounds(doc.src, n)
		lo, hi = lo - u64(head), hi + u64(tail)
	}
	for f in tape.facts_of(doc, value) {
		if f.kind == .Tag {
			lo = min(lo, f.lo)
		}
	}
	return
}

// Replays subtree `[item.value ..< node_after(&r.held, item.value))` iteratively into hook `h` through the exact
// v2 `Walk` protocol (`Rooms`, `Levels`, `Skips`, `Keeps`, `Budget.steps`, `Budget.memory`).
@(private)
member_walk :: proc(
	r: ^Records,
	$LAX: bool,
	h: ^$H,
	regs: ^hook.Regs,
	allocator: runtime.Allocator,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
) -> (walked: build.Record_Walk) #no_bounds_check {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	doc := &r.held
	item := r.items[r.cursor]
	root_v := item.value
	end := tape.node_after(doc, root_v)

	Mem_Walk :: struct {
		hooks:      ^H,
		regs:       hook.Regs,
		rooms:      uintptr,
		open_depth: u64,
		mute:       u64,
		keep_depth: u64,
		steps:      [int(LAX)]u64,
		skip_value: bool,
		mute_end:   bool,
		keep_stubs: bool,
		failed_mem: bool,
		bad_hook:   bool,
		stopped:    bool,
		last_at:    u64,
	}

	mw := Mem_Walk {
		hooks   = h,
		regs    = regs^ if regs != nil else {},
		last_at = item.lo,
	}
	when .Rooms in C {
		if h != nil {
			mw.rooms = hook.rooms_end(h)
		}
	}
	when LAX {
		mw.steps[0] = r.steps
	}

	give :: proc "contextless" (mw: ^Mem_Walk, t: tape.Token) -> bool {
		mw.last_at = t.lo
		container := t.kind > .Plain && t.kind != .End
		if container {
			mw.open_depth += 1
		}
		when .Skips in C {
			if mw.mute != 0 {
				when LAX {
					if container {
						mw.steps[0] -= 1
						if mw.steps[0] == 0 {
							return false
						}
					}
				}
				if t.kind == .End {
					mw.open_depth -= 1
					if mw.mute != max(u64) && mw.open_depth + 1 == mw.mute {
						send_end := !mw.mute_end
						mw.mute, mw.mute_end = 0, false
						if send_end {
							return give_outer(mw, t, false)
						}
					}
				}
				return true
			} else if mw.skip_value {
				if t.role > .Key {
				} else {
					mw.skip_value = false
					if container {
						when LAX {
							mw.steps[0] -= 1
							if mw.steps[0] == 0 {
								return false
							}
						}
						mw.mute = mw.open_depth
						mw.mute_end = true
					}
					return true
				}
			}
		}

		if t.kind == .End {
			mw.open_depth -= 1
			when .Keeps in C {
				if mw.keep_depth != 0 && mw.open_depth + 1 == mw.keep_depth {
					if !give_inner(mw, t) {
						return false
					}
					mw.keep_depth = 0
					when .Rooms in C {
						mw.rooms = hook.rooms_end(mw.hooks)
					}
				}
			}
		}

		when .Keeps in C {
			if mw.keep_depth != 0 {
				when LAX {
					if container {
						mw.steps[0] -= 1
						if mw.steps[0] == 0 {
							return false
						}
					}
				}
				return give_inner(mw, t)
			}
		}

		return give_outer(mw, t, container)
	}
	give_outer :: proc "contextless" (mw: ^Mem_Walk, t: tape.Token, container: bool) -> bool {
		when .Rooms in C {
			if t.kind != .End && t.role <= .Key && uintptr(mw.regs.a) >= mw.rooms {
				if !hook.rooms_grow(mw.hooks, &mw.regs, t.lo) {
					mw.failed_mem = true
					return false
				}
				mw.rooms = hook.rooms_end(mw.hooks)
			}
		}
		if container {
			when .Levels in C {
				held := hook.levels_held(mw.hooks)
				if held <= int(mw.regs.c) {
					want := max(2 * held, int(mw.regs.c) + 1)
					if !hook.levels_grow(mw.hooks, want, &mw.regs, t.lo) {
						mw.failed_mem = true
						return false
					}
					when .Rooms in C {
						mw.rooms = hook.rooms_end(mw.hooks)
					}
				}
			}
			when LAX {
				mw.steps[0] -= 1
				if mw.steps[0] == 0 {
					return false
				}
			}
		}
		when H == hook.No_Hooks {
			return true
		} else {
			act: hook.Action
			mw.regs, act = on(mw.hooks, mw.regs, t)
			#partial switch act {
			case .Next:
				return true
			case .Stop:
				mw.stopped = true
				return false
			case .Skip:
				when .Skips in C {
					if t.role == .Key {
						mw.skip_value = true
					} else if container {
						mw.mute = mw.open_depth
						mw.mute_end = false
					}
					return true
				}
				mw.bad_hook = true
				return false
			case .Rest:
				when .Skips in C {
					mw.mute = max(u64)
					return true
				}
				mw.bad_hook = true
				return false
			case .Keep, .Keep_Stubs:
				when .Keeps in C {
					if !container {
						mw.bad_hook = true
						return false
					}
					mw.keep_depth = mw.open_depth
					mw.keep_stubs = (act == .Keep_Stubs)
					return give_inner(mw, t)
				}
				mw.bad_hook = true
				return false
			}
			mw.bad_hook = true
			return false
		}
	}

	give_inner :: proc "contextless" (mw: ^Mem_Walk, t: tape.Token) -> bool {
		when .Keeps in C {
			K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
			Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
			IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
			inner := (^Inner)(hook.keeps_inner(mw.hooks))
			container := t.kind > .Plain && t.kind != .End
			when .Rooms in IC {
				if t.kind != .End && t.role <= .Key && uintptr(mw.regs.a) >= hook.rooms_end(inner) {
					if !hook.rooms_grow(inner, &mw.regs, t.lo) {
						mw.failed_mem = true
						return false
					}
				}
			}
			if container {
				when .Levels in IC {
					held := hook.levels_held(inner)
					if held <= int(mw.regs.c) {
						want := max(2 * held, int(mw.regs.c) + 1)
						if !hook.levels_grow(inner, want, &mw.regs, t.lo) {
							mw.failed_mem = true
							return false
						}
					}
				}
			}
			act: hook.Action
			if mw.keep_stubs {
				mw.regs, act = hook.keeps_give(mw.hooks, mw.regs, t, true)
			} else {
				mw.regs, act = hook.keeps_give(mw.hooks, mw.regs, t, false)
			}
			if act == .Stop {
				mw.stopped = true
				return false
			}
			return true
		} else {
			return false
		}
	}

	Open_C :: struct {
		node: tape.Node_Index,
		end:  tape.Node_Index,
	}
	stack, merr := make([dynamic]Open_C, 0, 16, allocator)
	if merr != nil {
		r.err = merr
		r.at = .Done
		return
	}
	defer delete(stack)

	emit_pre_facts :: proc "contextless" (mw: ^Mem_Walk, doc: ^tape.Document, idx: tape.Node_Index) -> bool {
		for f in tape.facts_of(doc, idx) {
			#partial switch f.kind {
			case .Comment:
				give(mw, tape.Token{f.lo, f.n, .Plain, .Comment, f.spelling}) or_return
			case .Anchor:
				give(mw, tape.Token{f.lo, f.n, .Plain, .Anchor, f.spelling}) or_return
			case .Tag:
				give(mw, tape.Token{f.lo, f.n, .Plain, .Tag, f.spelling}) or_return
			case .Alias:
				give(mw, tape.Token{f.lo, f.n, .Plain, .Alias, f.spelling}) or_return
			}
		}
		return true
	}

	emit_post_facts :: proc "contextless" (mw: ^Mem_Walk, doc: ^tape.Document, idx: tape.Node_Index) -> bool {
		for f in tape.facts_of(doc, idx) {
			if f.kind == .Comment_Inline {
				give(mw, tape.Token{f.lo, f.n, .Plain, .Comment_Inline, f.spelling}) or_return
			}
		}
		return true
	}

	emit_foot_facts :: proc "contextless" (mw: ^Mem_Walk, doc: ^tape.Document, idx: tape.Node_Index) -> bool {
		for f in tape.facts_of(doc, idx) {
			if f.kind == .Comment_Foot {
				give(mw, tape.Token{f.lo, f.n, .Plain, .Comment_Foot, f.spelling}) or_return
			}
		}
		return true
	}

	ok := true
	idx := root_v
	for idx < end || len(stack) > 0 {
		if len(stack) > 0 && idx >= stack[len(stack) - 1].end {
			closed := pop(&stack)
			if !emit_foot_facts(&mw, doc, closed.node) {
				ok = false
				break
			}
			cn := doc.nodes[closed.node]
			end_tok := tape.Token{lo = item.hi, kind = .End, role = .Value, spelling = cn.spelling & tape.CONTAINER_STYLE}
			if !give(&mw, end_tok) || !emit_post_facts(&mw, doc, closed.node) {
				ok = false
				break
			}
			continue
		}
		if idx >= end {
			break
		}
		if !emit_pre_facts(&mw, doc, idx) {
			ok = false
			break
		}
		n := doc.nodes[idx]
		tok := tape.Token(n)
		if idx == root_v {
			tok.role = .Value
		}
		if n.kind >= .Array {
			tok.lo = n.lo
			tok.n = 0
			if !give(&mw, tok) {
				ok = false
				break
			}
			cend := idx + tape.Node_Index(n.n)
			if _, aerr := append(&stack, Open_C{node = idx, end = cend}); aerr != nil {
				mw.failed_mem = true
				ok = false
				break
			}
			idx += 1
		} else {
			if !give(&mw, tok) || !emit_post_facts(&mw, doc, idx) {
				ok = false
				break
			}
			idx += 1
		}
	}

	if regs != nil {
		regs^ = mw.regs
	}
	res: hook.Walk_Result
	if !ok {
		when LAX {
			if mw.steps[0] == 0 {
				res = hook.walk_result(mw.last_at, hook.WALK_STEPS)
			}
		}
		if u8(res) == 0 {
			if mw.bad_hook {
				r.err = tape.Bad_Option{"action"}
				r.at = .Done
				return
			}
			if mw.failed_mem {
				res = hook.walk_result(mw.last_at, hook.WALK_NO_MEMORY)
			} else if mw.stopped {
				res = hook.walk_result(item.hi, 0)
			} else {
				res = hook.walk_result(mw.last_at, hook.WALK_NO_MEMORY)
			}
		}
	} else {
		res = hook.walk_result(item.hi, 0)
	}
	when LAX {
		r.steps = mw.steps[0]
	}
	walked.res = res
	walked.hi = item.hi
	walked.ok = true
	r.cursor += 1
	r.at = .After if r.cursor < len(r.items) else .Done
	return
}

// Skips past a faulting `.Concatenated` YAML document using `cut_document` (`---` / post-`...`), leaving `RECORDS_RULES`
// and `.Too_Wide` faults unskippable just like JSON `.Concatenated`.
@(private)
yaml_records_skip :: proc(base_r: ^tape.Records) -> (bad: tape.Bad_Record, ok: bool) #no_bounds_check {
	r := container_of(base_r, Records, "records")
	if r.framing != .Concatenated {
		return
	}
	f, is_fault := r.err.(tape.Fault)
	if !is_fault || f.rules == &tape.RECORDS_RULES || f.kind == .Too_Wide {
		return
	}
	src := r.src
	n := u64(len(src))
	lo := min(r.pos, n)
	from := min(f.at, n)
	ls := u64(bytes.last_index_byte(src[:from], '\n') + 1)
	search_from := ls - 1 if ls > lo else lo
	streaming := r.opts.pieces != nil && !r.opts.pieces.last

	next: u64
	if at, found := cut_document(src, search_from, n); found && at > lo {
		next = at
	} else {
		next = n
		if streaming {
			r.skip_line = true
		}
	}
	hi := next
	for hi > lo && kernel.is_ws(src[hi - 1]) {
		hi -= 1
	}
	bad = {lo = lo, hi = hi, err = r.err, text = src[lo:hi]}
	r.err = nil
	r.pos = next
	r.at = .Open if next < n || streaming else .Done
	return bad, true
}

@(private)
cut_document :: proc(src: []u8, lo, to: u64) -> (u64, bool) #no_bounds_check {
	hi := min(to, u64(len(src)))
	if lo >= hi {
		return 0, false
	}
	ls := u64(bytes.last_index_byte(src[:lo], '\n') + 1)
	for i := lo; i < hi; {
		k := bytes.index_byte(src[i:hi], '\n')
		if k < 0 {
			break
		}
		lf := i + u64(k)
		if marker_slice_at(src, ls) == '.' && !lone_cr(src[ls:lf]) && ls > 0 && opens_past(src, ls - 1) {
			return lf + 1, true
		}
		if marker_slice_at(src, lf + 1) == '-' && opens_past(src, lf) {
			return lf + 1, true
		}
		ls, i = lf + 1, lf + 1
	}
	return 0, false
}

@(private = "file")
marker_slice_at :: proc "contextless" (src: []u8, ls: u64) -> u8 #no_bounds_check {
	n := u64(len(src))
	if ls + 3 > n {
		return 0
	}
	b := src[ls]
	if (b == '-' || b == '.') && src[ls + 1] == b && src[ls + 2] == b {
		if ls + 3 == n || src[ls + 3] == ' ' || src[ls + 3] == '\t' || src[ls + 3] == '\n' || src[ls + 3] == '\r' {
			return b
		}
	}
	return 0
}

@(private = "file")
opens_past :: proc "contextless" (src: []u8, lf: u64) -> bool #no_bounds_check {
	end := lf
	for {
		ls := u64(bytes.last_index_byte(src[:end], '\n') + 1)
		line := src[ls:end]
		if lone_cr(line) {
			return false
		}
		j := 0
		for j < len(line) && (line[j] == ' ' || line[j] == '\t') {
			j += 1
		}
		if j < len(line) && line[j] != '#' && line[j] != '\r' {
			return line[0] != '%' && line[0] != 0xef && marker_slice_at(src, ls) != '.'
		}
		if ls == 0 {
			return false
		}
		end = ls - 1
	}
}

@(private = "file")
lone_cr :: #force_inline proc "contextless" (line: []u8) -> bool {
	k := bytes.index_byte(line, '\r')
	return k >= 0 && k < len(line) - 1
}
