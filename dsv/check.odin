package dsv

// The check of a delimited text or document against a description's plan, `Format_Reads.check` and `node_check` of a plan
// made with `checking`. The check is `typed.Check`, the one the other formats read with, and this file feeds it what a
// JSON text of the same records gives it: a text is an array of objects keyed by the header, or of arrays under
// `no_header`, and an empty unquoted cell is an absent member. A cell has no kind, so it reaches the check as `Plain`
// and the leaf it lands on reads it (`plain_token` of `core/typed`). A column whose name another column repeats is judged
// by the read's `Duplicates`: the earlier one is dropped under `.Last`, the later under `.First`, and a repeat is
// refused under `.Refuse`, where the dropped cell is not judged and does not count as a member.

import "base:runtime"
import core "../core"
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
		return typed.on_token_check(&h.c, out, t)
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
check_cells :: proc(src: []u8, $S: Spec, target: rawptr, T: typeid, plan: ^typed.Plan, opts: Options, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Error {
	h := Check_Cells{dups = read.dups}
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

// The plan's `node_check` of the record `node` of `doc`, or of the root as a list of its records. A header is the table's,
// so a partial document, whose records name their own columns, is refused. A cell reaches the check as a `Plain` of its
// text whatever kind the document gave it, as the text's cells do, with an empty cell for a `null`.
@(private)
document_check :: proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Error {
	root := node == core.ROOT
	if doc.partial || !root && doc.nodes[node].kind <= .Plain {
		return {kind = .Unsupported}
	}
	h := Check_Cells{dups = read.dups}
	frames: [ROW_FRAMES]typed.Frame = ---
	regs, err := typed.check_start(&h.c, doc.src, untracked(plan), doc.as, T, target, read, untracked_frames(frames[:]), allocator)
	if err.kind != .None {
		return err
	}
	header := core.header_of(doc)
	if header != 0 {
		h.keys = header_keys(doc)
		h.drop = make([]bool, len(h.keys), context.temp_allocator)
		defer delete(h.drop, context.temp_allocator)
	}
	action := core.Action.Next
	if root {
		regs, action = on_check_cell(&h, regs, {kind = .Array, role = .Value, lo = doc.nodes[0].lo})
	}
	to := u32(node) + doc.nodes[node].n
	for i := u32(node) + u32(root); i < to && action != .Stop; i += doc.nodes[i].n {
		if doc.nodes[i].role == .Key {
			continue
		}
		rec := doc.nodes[i]
		rec.role = .Value
		if regs, action = on_check_cell(&h, regs, rec); action == .Stop {
			break
		}
		for c in i + 1 ..< i + rec.n {
			cell := doc.nodes[c]
			if cell.kind == .Number || cell.kind == .True || cell.kind == .False {
				cell.spelling = 0
			}
			cell.kind = .Plain
			if header != 0 {
				if regs, action = on_check_cell(&h, regs, doc.nodes[int(header) + 1 + int(c - i - 1)]); action == .Stop {
					break
				}
			}
			if regs, action = on_check_cell(&h, regs, cell); action == .Stop {
				break
			}
		}
		if action != .Stop {
			end := doc.readers.close_end(doc, core.Node_Index(i))
			regs, action = on_check_cell(&h, regs, {kind = .End, role = .Value, lo = end - u64(len(line_end_before(doc.src, end))), n = u32(len(line_end_before(doc.src, end)))})
		}
	}
	if root && action != .Stop {
		regs, _ = on_check_cell(&h, regs, {kind = .End, role = .Value, lo = u64(len(doc.src))})
	}
	return typed.read_end(&h.c, regs, nil)
}
