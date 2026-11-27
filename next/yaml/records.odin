package yaml

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// YAML 1.2 records reader (`.Concatenated`, `.Elements`, `.Members`; `.Lines`/`.Seq` refused).

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
	if spec > max(Spec) { panic("yaml: spec out of range") }
	r.src, r.framing, r.spec, r.opts, r.path = src, framing, spec, opts, path
	r.release = yaml_records_release
	if framing == .Concatenated { r.skip = yaml_records_skip }
	if opts.pieces != nil { r.src = tape.piece_src(src, opts.pieces.from) }
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
	case .Yaml_1_2:   return records_validate_as(r, out, .Yaml_1_2, true, allocator) if lax else records_validate_as(r, out, .Yaml_1_2, false, allocator)
	case .Yaml_Merge: return records_validate_as(r, out, .Yaml_Merge, true, allocator) if lax else records_validate_as(r, out, .Yaml_Merge, false, allocator)
	}
	return 0
}

@(require_results)
records_find :: proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read := tape.Read_Options{}, allocator := context.allocator) -> int {
	lax := build.read_lax(r.opts)
	switch r.spec {
	case .Yaml_1_2:   return records_find_as(r, path, out, answers, .Yaml_1_2, true, read, allocator) if lax else records_find_as(r, path, out, answers, .Yaml_1_2, false, read, allocator)
	case .Yaml_Merge: return records_find_as(r, path, out, answers, .Yaml_Merge, true, read, allocator) if lax else records_find_as(r, path, out, answers, .Yaml_Merge, false, read, allocator)
	}
	return 0
}

@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> int {
	lax := build.read_lax(r.opts)
	switch r.spec {
	case .Yaml_1_2:   return records_scan_as(r, demand, out, docs, .Yaml_1_2, true, read, allocator) if lax else records_scan_as(r, demand, out, docs, .Yaml_1_2, false, read, allocator)
	case .Yaml_Merge: return records_scan_as(r, demand, out, docs, .Yaml_Merge, true, read, allocator) if lax else records_scan_as(r, demand, out, docs, .Yaml_Merge, false, read, allocator)
	}
	return 0
}

@(private)
records_validate_as :: #force_no_inline proc(r: ^Records, out: []tape.Record, $S: Spec, $LAX: bool, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(br: ^tape.Records, alloc: runtime.Allocator) -> (u64, u64, bool) {
		return yaml_record_frame(container_of(br, Records, "records"), S, alloc)
	}
	walk :: #force_inline proc(br: ^tape.Records, lo, cut: u64, _: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return yaml_record_walk(container_of(br, Records, "records"), S, LAX, lo, cut, h, regs, a, ctx, hook.no_hook)
	}
	return build.records_validate(r, out, &FORMATS[S], &RULES, caller, frame, walk)
}

@(private)
records_find_as :: #force_no_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(br: ^tape.Records, alloc: runtime.Allocator) -> (u64, u64, bool) {
		return yaml_record_frame(container_of(br, Records, "records"), S, alloc)
	}
	walk :: #force_inline proc(br: ^tape.Records, lo, cut: u64, _: bool, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return yaml_record_walk(container_of(br, Records, "records"), S, LAX, lo, cut, h, regs, a, ctx, build.finder_key_skip_hook)
	}
	return build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, respell_number, nil, frame, walk)
}

@(private)
records_scan_as :: #force_no_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(br: ^tape.Records, alloc: runtime.Allocator) -> (u64, u64, bool) {
		return yaml_record_frame(container_of(br, Records, "records"), S, alloc)
	}
	walk :: #force_inline proc(br: ^tape.Records, lo, cut: u64, _: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		rec := container_of(br, Records, "records")
		if rec.opts.pieces != nil || rec.framing != .Concatenated { h.scattered = true }
		return yaml_record_walk(rec, S, LAX, lo, cut, h, regs, a, ctx, build.scanner_key_skip_hook)
	}
	return build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, nil, node_bound, frame, walk)
}

@(private)
yaml_record_frame :: proc(r: ^Records, $S: Spec, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) #no_bounds_check {
	n := u64(len(r.src))
	if r.at == .Done { return }
	if r.framing == .Concatenated {
		streaming := r.opts.pieces != nil && !r.opts.pieces.last
		if r.skip_line {
			if next, found := cut_document(r.src, r.pos, n); found {
				r.pos, r.skip_line = next, false
			} else if streaming {
				if n > 4 { r.pos = max(r.pos, u64(bytes.last_index_byte(r.src[:n], '\n') + 1)) }
				return
			} else {
				r.pos, r.at = n, .Done
				return
			}
		}
		if r.pos >= n {
			if !streaming { r.at = .Done }
			return
		}
		if streaming && r.pos == 0 && n < 3 { return }
		return r.pos, n, true
	}
	if r.at == .Start && !members_open(r, S) { return }
	if r.cursor >= len(r.items) { r.err, r.at = r.end_err, .Done; return }
	item := r.items[r.cursor]
	r.key = item.key
	return item.lo, n, true
}

@(private)
yaml_record_walk :: proc(
	r: ^Records, $S: Spec, $LAX: bool, lo, cut: u64, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
) -> (walked: build.Record_Walk) {
	if r.framing != .Concatenated { return member_walk(r, LAX, h, regs, allocator, on) }
	streaming := r.opts.pieces != nil && !r.opts.pieces.last
	end_pos: u64
	found: bool
	opts := r.opts
	opts.pieces = nil
	_, err, tolerated := walk_text(r.src, S, LAX, opts, h, regs, allocator, ctx, on, lo, allow_empty = true, check_tail = false, allow_complex = false, end_pos = &end_pos, found_out = &found)
	if err != nil {
		if streaming { return }
		when H != hook.No_Hooks {
			if _, is_fault := err.(tape.Fault); !is_fault {
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
		if streaming { if r.pos != 0 { r.at = .Open } } else { r.at = .Done }
		return
	}
	n := u64(len(r.src))
	if streaming && (end_pos >= n || (end_pos + 4 > n && r.src[end_pos] == '-')) { return }
	walked = {res = hook.walk_result(end_pos, 0), hi = end_pos, tolerated = tolerated, ok = true}
	r.pos = end_pos
	r.at = .After if r.pos < n || streaming else .Done
	return
}

@(private)
record_refusal :: proc "contextless" (err: tape.Error) -> hook.Walk_Result {
	if e, ok := err.(tape.Exceeded); ok {
		#partial switch e.kind {
		case .Depth:          return hook.walk_result(e.at, hook.WALK_TOO_DEEP)
		case .Steps:          return hook.walk_result(e.at, hook.WALK_STEPS)
		case .Expansion:      return hook.walk_result(e.at, hook.WALK_EXPANSION)
		case .Nodes, .Memory: return hook.walk_result(e.at, hook.WALK_NO_MEMORY)
		}
	}
	return hook.walk_result(0, hook.WALK_NO_MEMORY)
}

@(private)
members_open :: proc(r: ^Records, $S: Spec) -> bool {
	if r.opts.pieces != nil && !r.opts.pieces.last { return false }
	r.tree_allocator = hook.scratch(r.opts, r.allocator, &r.tree_budget)
	r.at, r.steps = .Open, build.read_steps(r.opts)
	build_opts := Options {
		dups    = .Refuse if r.opts.dups == .Refuse else .All,
		budget  = {depth = r.opts.budget.depth, nodes = r.opts.budget.nodes, expansion = r.opts.budget.expansion, memory = r.opts.budget.memory},
		format  = r.opts.format,
		scratch = r.opts.scratch,
	}
	doc, err := build_as(r.src, S, false, build_opts, r.tree_allocator)
	if err != nil { r.err, r.at = hook.memory_budget_error(&r.tree_budget, err), .Done; return false }
	r.held = doc
	r.items.allocator = r.tree_allocator
	if r.opts.budget.steps != 0 {
		left := r.steps
		for n in r.held.nodes {
			if n.kind > .Plain {
				left -= 1
				if left == 0 { r.err, r.at = tape.Exceeded{at = n.lo, kind = .Steps}, .Done; return false }
			}
		}
	}
	collect_records(r, S)
	if len(r.items) == 0 {
		r.err = r.end_err
		r.at = .Done
		return false
	}
	return true
}

@(private)
collect_records :: proc(r: ^Records, $S: Spec) #no_bounds_check {
	doc := &r.held
	nodes := doc.nodes
	dups := FORMATS[S].dups if r.opts.dups == .Default else r.opts.dups
	want_kind: tape.Kind = .Array if r.framing == .Elements else .Object

	Visit_Frame :: struct { node, end, child: tape.Node_Index, step_idx: int, matched_one: bool }
	stack, serr := make([dynamic]Visit_Frame, 0, max(16, len(r.path) + 1), r.tree_allocator)
	if serr != nil { r.end_err = serr; return }
	defer delete(stack)

	root_end := tape.Node_Index(nodes[tape.ROOT].n) if nodes[tape.ROOT].kind >= .Array else 1
	if _, err := append(&stack, Visit_Frame{tape.ROOT, root_end, 1, 0, false}); err != nil { r.end_err = err; return }

	given, pending := false, false
	for len(stack) > 0 && r.end_err == nil {
		f := &stack[len(stack) - 1]
		if f.step_idx == len(r.path) {
			if nodes[f.node].kind != want_kind {
				if dups == .Last { pending = true; pop(&stack); continue }
				r.end_err = build.records_kind_refusal()
				break
			}
			pending = false
			for cur := f.node + 1; cur < f.end; {
				k_tok: tape.Token
				v := cur
				if want_kind == .Object { k_tok = nodes[cur]; v = tape.node_after(doc, cur) }
				lo, hi := record_bounds(doc, v)
				if _, err := append(&r.items, Item_Record{lo = lo, hi = hi, key = k_tok, value = v}); err != nil { r.end_err = err; break }
				given = true
				cur = tape.node_after(doc, v)
			}
			pop(&stack)
			continue
		}
		node := f.node
		#partial switch s in r.path[f.step_idx] {
		case tape.Index:
			if nodes[node].kind != .Array { pop(&stack); continue }
			target, place, matched := int(s), 0, tape.NO_NODE
			for v := f.node + 1; v < f.end; v = tape.node_after(doc, v) {
				if place == target { matched = v; break }
				place += 1
			}
			next_step := f.step_idx + 1
			pop(&stack)
			if matched != tape.NO_NODE {
				pending = false
				mn := nodes[matched]
				mend := matched + (tape.Node_Index(mn.n) if mn.kind >= .Array else 1)
				if _, err := append(&stack, Visit_Frame{matched, mend, matched + 1, next_step, false}); err != nil { r.end_err = err; break }
			}
		case tape.Name:
			if nodes[node].kind != .Object || (dups == .First && f.matched_one) { pop(&stack); continue }
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
					pending, f.matched_one = false, true
					vn := nodes[v]
					vend := v + (tape.Node_Index(vn.n) if vn.kind >= .Array else 1)
					if _, err := append(&stack, Visit_Frame{v, vend, v + 1, f.step_idx + 1, false}); err != nil { r.end_err = err }
					descended = true
					break
				}
			}
			if !descended && r.end_err == nil { pop(&stack) }
		}
	}
	if r.end_err == nil && pending { r.end_err = build.records_kind_refusal() }
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
		if f.kind == .Tag { lo = min(lo, f.lo) }
	}
	return
}

// Replays subtree `[item.value ..< node_after(&r.held, item.value))` iteratively into hook `h` using shared `Walk_Hook`.
@(private)
member_walk :: proc(
	r: ^Records, $LAX: bool, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
) -> (walked: build.Record_Walk) #no_bounds_check {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	doc := &r.held
	item := r.items[r.cursor]
	root_v := item.value
	end := tape.node_after(doc, root_v)

	wh: Walk_Hook(H, LAX, C)
	walk_hook_init(&wh, h, regs, r.steps, item.lo)

	Open_C :: struct { node, end: tape.Node_Index }
	stack, merr := make([dynamic]Open_C, 0, 16, allocator)
	if merr != nil { r.err, r.at = merr, .Done; return }
	defer delete(stack)

	emit_facts :: proc "contextless" (wh: ^Walk_Hook(H, LAX, C), doc: ^tape.Document, idx: tape.Node_Index, mask: tape.Facts) -> bool {
		for f in tape.facts_of(doc, idx) {
			if f.kind not_in mask { continue }
			role: tape.Role
			#partial switch f.kind {
			case .Comment:        role = .Comment
			case .Comment_Inline: role = .Comment_Inline
			case .Comment_Foot:   role = .Comment_Foot
			case .Anchor:         role = .Anchor
			case .Tag:            role = .Tag
			case .Alias:          role = .Alias
			case:                 continue
			}
			walk_hook_deliver(wh, tape.Token{f.lo, f.n, .Plain, role, f.spelling}, on) or_return
		}
		return true
	}

	PRE :: tape.Facts{.Comment, .Anchor, .Tag, .Alias}
	ok := true
	idx := root_v
	for idx < end || len(stack) > 0 {
		if len(stack) > 0 && idx >= stack[len(stack) - 1].end {
			closed := pop(&stack)
			cn := doc.nodes[closed.node]
			end_tok := tape.Token{lo = item.hi, kind = .End, role = .Value, spelling = cn.spelling & tape.CONTAINER_STYLE}
			if !emit_facts(&wh, doc, closed.node, {.Comment_Foot}) || !walk_hook_deliver(&wh, end_tok, on) || !emit_facts(&wh, doc, closed.node, {.Comment_Inline}) {
				ok = false; break
			}
			continue
		}
		if idx >= end { break }
		if !emit_facts(&wh, doc, idx, PRE) { ok = false; break }
		n := doc.nodes[idx]
		tok := tape.Token(n)
		if idx == root_v { tok.role = .Value }
		if n.kind >= .Array {
			tok.lo, tok.n = n.lo, 0
			if !walk_hook_deliver(&wh, tok, on) { ok = false; break }
			if _, aerr := append(&stack, Open_C{idx, idx + tape.Node_Index(n.n)}); aerr != nil {
				wh.failed_mem, ok = true, false; break
			}
		} else if !walk_hook_deliver(&wh, tok, on) || !emit_facts(&wh, doc, idx, {.Comment_Inline}) {
			ok = false; break
		}
		idx += 1
	}

	if regs != nil { regs^ = wh.regs }
	res: hook.Walk_Result
	if !ok {
		when LAX { if wh.steps[0] == 0 { res = hook.walk_result(wh.last_at, hook.WALK_STEPS) } }
		if u8(res) == 0 {
			if wh.bad_hook { r.err, r.at = tape.Bad_Option{"action"}, .Done; return }
			res = hook.walk_result(item.hi, 0) if wh.stopped else hook.walk_result(wh.last_at, hook.WALK_NO_MEMORY)
		}
	} else {
		res = hook.walk_result(item.hi, 0)
	}
	when LAX { r.steps = wh.steps[0] }
	walked = {res = res, hi = item.hi, ok = true}
	r.cursor += 1
	r.at = .After if r.cursor < len(r.items) else .Done
	return
}

// Skips past a faulting `.Concatenated` YAML document using `cut_document` (`---` / post-`...`).
@(private)
yaml_records_skip :: proc(base_r: ^tape.Records) -> (bad: tape.Bad_Record, ok: bool) #no_bounds_check {
	r := container_of(base_r, Records, "records")
	if r.framing != .Concatenated { return }
	f, is_fault := r.err.(tape.Fault)
	if !is_fault || f.rules == &tape.RECORDS_RULES || f.kind == .Too_Wide { return }
	src, n := r.src, u64(len(r.src))
	lo, from := min(r.pos, n), min(f.at, n)
	ls := u64(bytes.last_index_byte(src[:from], '\n') + 1)
	streaming := r.opts.pieces != nil && !r.opts.pieces.last

	next := n
	if at, found := cut_document(src, ls - 1 if ls > lo else lo, n); found && at > lo {
		next = at
	} else if streaming {
		r.skip_line = true
	}
	hi := next
	for hi > lo && kernel.is_ws(src[hi - 1]) { hi -= 1 }
	bad = {lo = lo, hi = hi, err = r.err, text = src[lo:hi]}
	r.err, r.pos = nil, next
	r.at = .Open if next < n || streaming else .Done
	return bad, true
}

@(private)
cut_document :: proc(src: []u8, lo, to: u64) -> (u64, bool) #no_bounds_check {
	hi := min(to, u64(len(src)))
	if lo >= hi { return 0, false }
	ls := u64(bytes.last_index_byte(src[:lo], '\n') + 1)
	for i := lo; i < hi; {
		k := bytes.index_byte(src[i:hi], '\n')
		if k < 0 { break }
		lf := i + u64(k)
		if marker_slice_at(src, ls) == '.' && !lone_cr(src[ls:lf]) && ls > 0 && opens_past(src, ls - 1) { return lf + 1, true }
		if marker_slice_at(src, lf + 1) == '-' && opens_past(src, lf) { return lf + 1, true }
		ls, i = lf + 1, lf + 1
	}
	return 0, false
}

@(private = "file")
marker_slice_at :: proc "contextless" (src: []u8, ls: u64) -> u8 #no_bounds_check {
	n := u64(len(src))
	if ls + 3 > n { return 0 }
	b := src[ls]
	if (b == '-' || b == '.') && src[ls + 1] == b && src[ls + 2] == b {
		if ls + 3 == n || src[ls + 3] == ' ' || src[ls + 3] == '\t' || src[ls + 3] == '\n' || src[ls + 3] == '\r' { return b }
	}
	return 0
}

@(private = "file")
opens_past :: proc "contextless" (src: []u8, lf: u64) -> bool #no_bounds_check {
	end := lf
	for {
		ls := u64(bytes.last_index_byte(src[:end], '\n') + 1)
		line := src[ls:end]
		if lone_cr(line) { return false }
		j := 0
		for j < len(line) && (line[j] == ' ' || line[j] == '\t') { j += 1 }
		if j < len(line) && line[j] != '#' && line[j] != '\r' {
			return line[0] != '%' && line[0] != 0xef && marker_slice_at(src, ls) != '.'
		}
		if ls == 0 { return false }
		end = ls - 1
	}
}

@(private = "file")
lone_cr :: #force_inline proc "contextless" (line: []u8) -> bool {
	k := bytes.index_byte(line, '\r')
	return k >= 0 && k < len(line) - 1
}
