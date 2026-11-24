package toml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The records of a TOML text. A TOML text is one table with no mark that ends it, so it holds no list of its own: under
// `.Concatenated` the one record is the whole text, and under `.Members` each member of the root table is a record,
// with its key, in the order the text first names them. A text of no bytes holds no record under `.Concatenated`.
// Under a path the records are the members of the table or the elements of the array it reaches. `.Lines`, and
// `.Elements` with no path, are refused, as no TOML text is a list of lines or a root array.

// The records of a text of a TOML spec, which `records_open` makes and each call of `records_validate`, `records_find`
// or `records_scan` reads in batches, as `tape.Records` says. Under `.Members` and `.Elements` the text is read whole
// at the first record into a tree in the records' allocator, which `tape.destroy_records` frees.
Records :: struct {
	using records: tape.Records,
	spec:          Spec,
	held:          ^Parser, // under `.Members` and `.Elements`, the text read whole, nil before the first record
	member:        u32, // under `.Members` and `.Elements`, the child read next
	// Under `.Members` and `.Elements`, the walk's count of `Budget.steps`, which counts the containers of the text.
	steps:         u64,
}

// Opens the records of `src`, a text of `spec` framed as `framing`, each read under `opts`. Under `.Members` and
// `.Elements` the records are those of the container `path` reaches, the root table for none, as `tape.Records` says,
// a text with no value there holds no records and ends them with the verdict `validate` gives for it, and a value of
// another kind ends them with `build.records_kind_refusal`. The budget's limits hold for each record, but
// `Budget.steps` under `.Members` and `.Elements`, which counts the containers of the whole text. Another format's options, `.Lines`, `.Elements` with no path, a `path` the framing does
// not take and a text in pieces under `.Members` or `.Elements` end the records with `tape.Bad_Option` before any is
// read. Under `.Concatenated` a text in pieces holds one record, the whole text, so no batch gives it before the last
// window, which must hold the text from its first byte.
records_open :: proc(src: []u8, framing := tape.Framing.Concatenated, spec := Spec.Toml_1_0, opts := Options{}, path: []tape.Step = nil) -> (r: Records) {
	if spec > max(Spec) {
		panic("toml: spec out of range")
	}
	r.src, r.framing, r.spec, r.opts, r.member, r.release, r.allocator, r.path = src, framing, spec, opts, NIL, records_close, context.allocator, path
	if opts.pieces != nil {
		r.src = tape.piece_src(src, opts.pieces.from)
	}
	if err := tape.options_refused(&FORMATS[spec], opts); err != nil {
		r.err, r.at = err, .Done
	} else if framing == .Lines || framing == .Elements && len(path) == 0 {
		r.err, r.at = tape.Bad_Option{"framing"}, .Done
	} else if err = build.records_path_refused(&FORMATS[spec], framing, path, opts); err != nil {
		r.err, r.at = err, .Done
	} else if opts.pieces != nil && framing != .Concatenated {
		r.err, r.at = tape.Bad_Option{"pieces"}, .Done
	}
	return
}

// Frees the tree the records `r` read their text into.
@(private)
records_close :: proc(records: ^tape.Records) {
	r := (^Records)(records)
	if r.held != nil {
		context.allocator = r.allocator
		parser_destroy(r.held)
		free(r.held)
		r.held = nil
	}
}

// Reads the next records of `r` and judges each, as `validate` judges its bytes alone, and under `.Members` and
// `.Elements` as the child of the text it is, keeping in `out` those that do not read. Returns how many it filled, and
// fewer than `len(out)` once the records have ended, when `err` says why, nil at the text's end.
@(require_results)
records_validate :: proc(r: ^Records, out: []tape.Record, allocator := context.allocator) -> (n: int) {
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Toml_1_0:
		if lax {
			return records_validate_as(r, out, .Toml_1_0, true, allocator)
		}
		return records_validate_as(r, out, .Toml_1_0, false, allocator)
	case .Toml_1_1:
		if lax {
			return records_validate_as(r, out, .Toml_1_1, true, allocator)
		}
		return records_validate_as(r, out, .Toml_1_1, false, allocator)
	}
	return
}

// Reads the next records of `r` into `out`, and for each the first value `path` reaches in it into the same place of
// `answers`, with every offset from the text's first byte. The walk reads each record to its end whatever
// `read.stop_early` says, as the next starts there.
@(require_results)
records_find :: proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Toml_1_0:
		if lax {
			return records_find_as(r, path, out, answers, .Toml_1_0, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Toml_1_0, false, read, allocator)
	case .Toml_1_1:
		if lax {
			return records_find_as(r, path, out, answers, .Toml_1_1, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Toml_1_1, false, read, allocator)
	}
	return
}

// Reads the next records of `r` into `out`, and for each the document of its nodes the paths of `demand` reach into the
// same place of `docs`. The documents are in the records' block, valid until the next call or `tape.destroy_records`,
// as `tape.Record_Block` says.
@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Toml_1_0:
		if lax {
			return records_scan_as(r, demand, out, docs, .Toml_1_0, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Toml_1_0, false, read, allocator)
	case .Toml_1_1:
		if lax {
			return records_scan_as(r, demand, out, docs, .Toml_1_1, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Toml_1_1, false, read, allocator)
	}
	return
}

@(private)
records_validate_as :: #force_no_inline proc(r: ^Records, out: []tape.Record, $S: Spec, $LAX: bool, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records, _: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(container_of(r, Records, "records"), S, LAX, h, regs, a, ctx, hook.no_hook)
	}
	return build.records_validate(r, out, &FORMATS[S], &RULES, caller, frame, walk)
}

@(private)
records_find_as :: #force_no_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records, _: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(container_of(r, Records, "records"), S, LAX, h, regs, a, ctx, build.finder_key_skip_hook)
	}
	return build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, respell, nil, frame, walk)
}

@(private)
records_scan_as :: #force_no_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records, _: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		// Records of a text in pieces hold the bytes they keep, which the walk gives out of text order.
		h.scattered = true
		return record_walk(container_of(r, Records, "records"), S, LAX, h, regs, a, ctx, build.scanner_key_skip_hook)
	}
	n := build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, nil, node_bound, frame, walk)
	for &doc in docs[:n] {
		doc, _ = spelled_present(doc, nil)
	}
	return n
}

// The next record's first byte and the text's end, or false once the records have ended. Otherwise the first
// record reads the text whole, and a fault in it ends the records with the fault `validate` gives for the text.
@(private)
record_frame :: proc(r: ^Records, $S: Spec) -> (lo, cut: u64, ok: bool) {
	n := u64(len(r.src))
	if r.at == .Done {
		return
	}
	if r.framing == .Concatenated {
		if p := r.opts.pieces; p != nil && !p.last {
			// The record is the whole text, which the last window ends.
			r.at, r.pos = .Open, 0
			return
		}
		if r.pos >= n {
			r.at = .Done
			return
		}
		// The record starts past a byte order mark, which is the text's and not its value's.
		return u64(text_start(r.src, int(r.pos))), n, true
	}
	if r.at == .Start && !members_open(r, S) {
		return
	}
	if r.member == NIL {
		r.at = .Done
		return
	}
	m := r.held.tree.nodes[r.member]
	r.key = m.key
	lo = m.value.lo
	if m.kind == .Scalar {
		head, _ := bounds(r.src, m.value)
		lo -= u64(head)
	}
	return lo, n, true
}

// Reads the text whole into the tree `r.held` and finds the container `r.path` reaches, false with the records ended
// when memory is refused, the text faults or holds no such container. The root takes a step, as each container does.
// Under a path with `Budget.steps` the records end first with the verdict `validate` gives, which the tree's containers
// counted in the walk's order give, as the containers outside the one reached are not walked.
@(private)
members_open :: proc(r: ^Records, $S: Spec) -> bool {
	context.allocator = r.allocator
	r.at = .Open
	r.steps = build.read_steps(r.opts)
	p, err := new(Parser)
	if err != nil {
		r.err, r.at = runtime.Allocator_Error.Out_Of_Memory, .Done
		return false
	}
	r.held = p
	if !parser_init(p, r.src, S == .Toml_1_1, build.read_depth(r.opts)) {
		r.err, r.at = runtime.Allocator_Error.Out_Of_Memory, .Done
		return false
	}
	p.pos = text_start(r.src, 0)
	if !parse_rest(p) {
		_, r.err, _ = hook.walk_error(p.fail, &RULES)
		r.at = .Done
		return false
	}
	r.steps -= 1
	if r.steps == 0 {
		r.err, r.at = tape.Exceeded{kind = .Steps}, .Done
		return false
	}
	if len(r.path) > 0 && r.opts.budget.steps != 0 {
		if at, past := steps_past(&p.tree, r.steps); past {
			r.err, r.at = tape.Exceeded{at = at, kind = .Steps}, .Done
			return false
		}
	}
	at := path_node(&p.tree, r.path)
	if at == NIL || p.tree.nodes[at].kind != (.Table if r.framing == .Members else .Array) {
		if at != NIL {
			r.err = build.records_kind_refusal()
		}
		r.at = .Done
		return false
	}
	r.member = p.tree.nodes[at].first
	return true
}

// Where the walk of the whole tree `t` stops with `left` steps of `Budget.steps` left past the root: at the first
// container in the walk's order past them. False when every container is within them.
@(private)
steps_past :: proc "contextless" (t: ^Table_Tree, left: u64) -> (at: u64, past: bool) {
	left := left
	id := t.nodes[0].first
	for id != NIL {
		n := &t.nodes[id]
		if n.kind != .Scalar {
			left -= 1
			if left == 0 {
				return n.value.lo, true
			}
			if n.first != NIL {
				id = n.first
				continue
			}
		}
		for id != 0 && t.nodes[id].next == NIL {
			id = t.nodes[id].parent
		}
		if id == 0 {
			break
		}
		id = t.nodes[id].next
	}
	return
}

// The node `path` reaches from the root of `t`, each `Name` a table's member and each `Index` an array's element, or
// NIL.
@(private)
path_node :: proc(t: ^Table_Tree, path: []tape.Step) -> u32 {
	at := u32(0)
	for step in path {
		#partial switch s in step {
		case tape.Name:
			if t.nodes[at].kind != .Table {
				return NIL
			}
			at = find_child(t, at, string(s))
		case tape.Index:
			if t.nodes[at].kind != .Array {
				return NIL
			}
			at = t.nodes[at].first
			for i := 0; i < int(s) && at != NIL; i += 1 {
				at = t.nodes[at].next
			}
		}
		if at == NIL {
			return NIL
		}
	}
	return at
}

// Walks the next record for hook `h` from registers `regs`, and returns the walk's result and the record's end. False
// once the records have ended, as a fault in a record ends them with the fault.
@(private)
record_walk :: proc(r: ^Records, $S: Spec, $LAX: bool, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	if r.framing != .Concatenated {
		return member_walk(r, LAX, h, regs, allocator, on)
	}
	_, err, _ := walk_text(r.src, S, LAX, r.opts, h, regs, allocator, ctx, on)
	if err == nil {
		walked.res = hook.walk_result(u64(len(r.src)), 0)
	} else if fault, is_fault := err.(tape.Fault); is_fault {
		r.err, r.at = fault, .Done
		return
	} else {
		// The hook refused the text, so a walk with no hook judges it, and the refusal is the record's error.
		none: hook.No_Hooks
		none_regs: hook.Regs
		if _, e, _ := walk_text(r.src, S, LAX, r.opts, &none, &none_regs, allocator, ctx, hook.no_hook); e != nil {
			r.err, r.at = e, .Done
			return
		}
		walked.res = record_refusal(err)
	}
	walked.hi, walked.ok = u64(len(r.src)), true
	r.pos, r.at = walked.hi, .After
	return
}

// The walk result of a read's error other than a fault, for `hook.walk_error` to give back.
@(private)
record_refusal :: proc "contextless" (err: tape.Error) -> hook.Walk_Result {
	#partial switch e in err {
	case tape.Exceeded:
		#partial switch e.kind {
		case .Depth:
			return hook.walk_result(e.at, hook.WALK_TOO_DEEP)
		case .Steps:
			return hook.walk_result(e.at, hook.WALK_STEPS)
		}
	}
	return hook.walk_result(0, hook.WALK_NO_MEMORY)
}

// Gives the hook the value of the root's member `r.member`, read from the tree, and moves to the next member.
@(private)
member_walk :: proc(r: ^Records, $LAX: bool, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	context.allocator = allocator
	p := r.held
	id := r.member
	m := p.tree.nodes[id]
	frames: [dynamic]Frame
	defer delete(frames)
	w := Walk(H, LAX, C) {
		p      = p,
		hooks  = h,
		frames = &frames,
		levels = int(regs.c) + int(p.tree.deepest) + 1,
	}
	when LAX {
		w.steps[0] = r.steps
	}
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	hs := regs^
	res: hook.Walk_Result
	if m.kind == .Scalar {
		_, tail := bounds(p.src, m.value)
		end := m.value.lo + u64(m.value.n) + u64(tail)
		res = hook.walk_result(end, 0)
		if give(&w, &hs, m.value, on) == .Stop {
			res = stopped(end)
		}
		when H == build.Builder {
			spelled_value(&w, m.value, false)
		}
	} else {
		t := tape.Token{lo = m.value.lo, kind = m.value.kind, spelling = m.value.spelling}
		a := give(&w, &hs, t, on)
		if _, err := append(&frames, frame_in(&p.tree, {}, id, t.lo)); err != nil {
			w.failed = true
			res = stopped(t.lo)
		} else if a != .Next {
			res, _ = enter(&w, &hs, a, t, false, on)
		} else {
			res, _ = run(&w, 0, &hs, on)
		}
	}
	regs^ = hs
	spelled_into(&w)
	if u8(res) == hook.WALK_STOPPED {
		when LAX {
			if w.steps[0] == 0 {
				r.err, r.at = tape.Exceeded{at = u64(res) >> 16, kind = .Steps}, .Done
				return
			}
		}
		res = hook.walk_result(u64(res) >> 16, hook.WALK_NO_MEMORY)
	}
	when LAX {
		r.steps = w.steps[0]
	}
	walked.res, walked.hi, walked.ok = res, u64(res) >> 16, true
	if u8(res) != 0 {
		walked.hi = u64(len(r.src))
	}
	r.member = p.tree.nodes[id].next
	r.pos, r.at = walked.hi, .After
	return
}
