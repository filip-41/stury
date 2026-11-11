package dsv

// The check of a delimited text or document against a description's plan, `Format_Reads.check` and `node_check` of a plan
// made with `checking`. The check is `typed.Check`, the one the other formats read with, and this file feeds it what a
// JSON text of the same records gives it: a text is an array of objects keyed by the header, or of arrays under
// `no_header`, and an empty unquoted cell is an absent member. A cell is one kind for the whole verdict, the one
// `spelling_resolve` reads it as: a string, or under `infer` a number, `true` or `false` when its text is exactly one.
// A check that keeps `readings`, which the schema-directed conversion runs, lets the leaf a cell lands on pick its kind
// instead (`plain_token` of `core/typed`). A column whose name another column repeats is judged
// by the read's `Duplicates`: the earlier one is dropped under `.Last`, the later under `.First`, and a repeat is
// refused under `.Refuse`, where the dropped cell is not judged and does not count as a member.

import "base:runtime"
import core "../core"
import build "../core/build"
import typed "../core/typed"

@(private)
Check_Cells :: struct {
	c:     typed.Check,
	keys:  []core.Token, // the header's cells
	drop:  []bool, // a column whose cell a repeated name replaces
	key:   core.Token, // the column key whose cell has not come
	col:   int, // the column of the next cell
	dups:  core.Duplicates,
	held:  bool,
	bound: bool,
	infer: bool, // a cell that is exactly a JSON number, `true` or `false` is that kind
}

// The token of the value cell `t` as the check judges it: its one kind, unless the check keeps readings.
@(private)
cell_token :: #force_inline proc "contextless" (h: ^Check_Cells, t: core.Token) -> core.Token {
	t := t
	if h.c.readings != nil {
		return t
	}
	t.kind = .String
	if h.infer && t.spelling == 0 && t.n != 0 && t.role == .Value {
		context = h.c.ctx
		// A number is spelled as the generic decimal, which the check judges by its text.
		kind, integer := core.plain_kind(h.c.src, t.lo, t.lo + u64(t.n), true, true)
		if kind != .String {
			t.kind = kind
		}
		if kind == .Number {
			t.spelling = core.number_spelling(core.NUMBER_DECIMAL, 1, 0 if integer else 1)
		}
	}
	return t
}

// The hook of a check. A column key waits for its cell, so an empty cell drops both and a dropped column drops both.
@(private)
on_check_cell :: #force_inline proc "contextless" (h: ^Check_Cells, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if t.kind != .Plain {
		if t.kind == .Object || t.kind == .Array {
			h.col = 0
		}
		if !h.bound && (t.kind == .Object || t.kind == .End) {
			// The header is read by the first record, or by the end of a table that has none.
			if bind_repeats(h, regs) == .Stop {
				return regs, .Stop
			}
		}
		return typed.on_token_check(&h.c, regs, t)
	}
	empty := t.n == 0 && t.spelling & core.SPELLING_QUOTED == 0
	switch {
	case t.role == .Key:
		h.key, h.held = t, true
	case t.role != .Value:
	case !h.held:
		// An element of a row with no header.
		t := t
		if empty {
			t.kind = .Null
		} else {
			t = cell_token(h, t)
		}
		return typed.on_token_check(&h.c, regs, t)
	case:
		column := h.col
		h.col, h.held = column + 1, false
		if empty || column < len(h.drop) && h.drop[column] {
			break
		}
		out, action := typed.on_token_check(&h.c, regs, h.key)
		if action != .Next {
			// A key the check passed over takes its cell with it.
			return out, .Stop if action == .Stop else .Next
		}
		return typed.on_token_check(&h.c, out, cell_token(h, t))
	}
	return regs, .Next
}

// Decides once the header is read which columns a repeated name drops, and refuses each repeat under `.Refuse`.
@(cold, private)
bind_repeats :: #force_no_inline proc "contextless" (h: ^Check_Cells, regs: core.Hook_Regs) -> core.Action {
	h.bound = true
	context = h.c.ctx
	seen := make(map[string]int, allocator = context.temp_allocator)
	defer delete(seen)
	for key, c in h.keys {
		name, ok := core.token_text(h.c.plan.readers, &h.c.view, key, context.temp_allocator)
		if !ok {
			_, action := typed.refuse(&h.c, regs, {kind = .No_Memory, at = key.lo})
			return .Stop if action == .Stop else .Next
		}
		earlier, repeated := note_column(&seen, name, c, h.dups == .First)
		if !repeated {
			continue
		}
		#partial switch h.dups {
		case .Refuse:
			// A header's refusal has its column alone as a path.
			sp := h.c.sp
			h.c.sp = 1
			_, action := typed.refuse(&h.c, regs, {kind = .Duplicate_Key, at = key.lo, steps = {0 = core.Name(name)}, n_steps = 1})
			h.c.sp = sp
			if action == .Stop {
				return .Stop
			}
		case .First:
			h.drop[c] = true
		case:
			h.drop[earlier] = true
		}
	}
	return .Next
}

// A pointer to what outlives the read that holds it, hidden from the stack escape check, which cannot see through the
// base `Reader` of a `typed.Check` that the pointer stays within the call.
@(private)
untracked :: #force_inline proc "contextless" (p: ^$T) -> ^T {
	return (^T)(uintptr(p))
}

@(private)
untracked_frames :: #force_inline proc "contextless" (f: []typed.Frame) -> []typed.Frame {
	return ([^]typed.Frame)(untracked(raw_data(f)))[:len(f)]
}

// Checks `src`, a text of spec `S`, as the plan's description says.
@(private)
check_cells :: proc(src: []u8, $S: Spec, target: rawptr, T: typeid, plan: ^typed.Plan, opts: Options, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	h := Check_Cells{dups = read.dups, infer = opts.infer}
	frames: [ROW_FRAMES]typed.Frame = ---
	regs, err := typed.check_start(&h.c, src, untracked(plan), bound_as(S, opts), T, target, read, untracked_frames(frames[:]), allocator)
	if err.kind != .None {
		return err
	}
	if !opts.no_header {
		start := int(core.text_start(src, 0))
		if record_start(src, start, opts.comment) < len(src) {
			failed: runtime.Allocator_Error
			if h.keys, failed = make([]core.Token, header_cells(src, start, S, opts), context.temp_allocator); failed != nil {
				return {kind = .No_Memory}
			}
			h.drop = make([]bool, len(h.keys), context.temp_allocator)
		}
	}
	defer delete(h.keys, context.temp_allocator)
	defer delete(h.drop, context.temp_allocator)
	_, fault := walk_keys(src, 0, S, opts, &h, &regs, on_check_cell, h.keys)
	return typed.read_end(&h.c, regs, fault)
}

// A check of a document: the cells' state beside the document and the position of the next kept cell of a record read by
// position.
@(private)
Check_Document :: struct {
	cells:      Check_Cells,
	doc:        ^core.Document,
	kept:       int, // the first of `Document.kept` that may name a node not yet read
	pos:        int, // the position of the next cell of a record read by position
	positional: bool, // the rows are lists, so a record a path left partial names its cells by position
	fill:       bool, // the record being fed is partial and positional
}

// The plan's `node_check` of the record `node` of `doc`, or of the root as a list of its records, fed by
// `build.feed_nodes` with the cell step. A cell reaches the check as a `Plain` of its text whatever kind the document gave
// it, as the text's cells do, with an empty cell for a `null`. A partial document names its columns beside each cell it
// kept, or by position, where a cell it did not keep is an empty one.
@(private)
document_check :: proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	if node != core.ROOT && doc.nodes[node].kind <= .Plain {
		return {kind = .Unsupported}
	}
	d := Check_Document{doc = doc, cells = {dups = read.dups, infer = options_of(doc.as).infer}, positional = options_of(doc.as).no_header}
	h := &d.cells
	frames: [ROW_FRAMES]typed.Frame = ---
	regs, err := typed.check_start(&h.c, doc.src, untracked(plan), doc.as, T, target, read, untracked_frames(frames[:]), allocator)
	if err.kind != .None {
		return err
	}
	if core.header_of(doc) != 0 {
		h.keys = header_keys(doc)
		h.drop = make([]bool, len(h.keys), context.temp_allocator)
		defer delete(h.drop, context.temp_allocator)
	}
	// A row holds scalars, so the replay never nests past the root and a record.
	ends: [2 * 4]u32 = ---
	if !build.feed_nodes(doc, u32(node), u32(node) + doc.nodes[node].n, &d, &regs, ends[:], check_step, check_keyed, build.no_deepen, true) {
		return {kind = .No_Memory}
	}
	return typed.read_end(&h.c, regs, nil)
}

// A token of the replay as the text's walk gives it to `on_check_cell`: a cell is a `Plain` of its text, a partial
// record's cells before the one it kept are empty, and an `End` stands at its record's line end.
@(private)
check_step :: proc "contextless" (d: ^Check_Document, regs: core.Hook_Regs, t: core.Token, at: core.Node_Index) -> (core.Hook_Regs, core.Action) {
	t := t
	switch {
	case t.role == .Key:
	case t.kind == .End:
		if at == core.ROOT {
			t.lo, t.n = u64(len(d.doc.src)), 0
		} else {
			context = d.cells.c.ctx
			end := d.doc.readers.close_end(d.doc, at)
			t.n = u32(len(line_end_before(d.doc.src, end)))
			t.lo = end - u64(t.n)
		}
	case t.kind == .Object || t.kind == .Array:
		d.pos, d.fill = 0, t.role == .Partial && d.positional
		t.role = .Value
	case:
		regs, action := regs, core.Action.Next
		if d.fill {
			k := kept_position(d.doc, &d.kept, at)
			for ; d.pos < k && action == .Next; d.pos += 1 {
				regs, action = on_check_cell(&d.cells, regs, {kind = .Plain, role = .Value, lo = t.lo})
			}
			d.pos += 1
		}
		if t.kind == .Number || t.kind == .True || t.kind == .False {
			t.spelling = 0
		}
		t.kind = .Plain
		if action != .Next {
			return regs, action
		}
		return on_check_cell(&d.cells, regs, t)
	}
	return on_check_cell(&d.cells, regs, t)
}

// The header's cell above the value at node `i` of the record `open`.
@(private)
check_keyed :: proc "contextless" (d: ^Check_Document, _: core.Hook_Regs, i, open: core.Node_Index) -> (core.Node_Index, bool) {
	return core.header_of(d.doc) + 1 + (i - open - 1), d.doc.nodes[open].kind == .Object
}
