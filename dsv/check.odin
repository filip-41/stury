package dsv

// The check of a delimited text or document against a description's plan, `Format_Reads.check` and `node_check` of a plan
// made with `checking`. The check is `typed.Check`, the one the other formats read with, and this file feeds it what a
// JSON text of the same records gives it: a text is an array of objects keyed by the header, or of arrays under
// `no_header`, and an empty unquoted cell is an absent member. A cell has no kind, so it reaches the check as `Plain`
// and the leaf it lands on reads it (`plain_token` of `core/typed`). A column whose name another column repeats is judged
// by the read's `Duplicates`: the earlier one is dropped under `.Last`, the later under `.First`, and a repeat is
// refused under `.Refuse`, where the dropped cell is not judged and does not count as a member.

import "base:runtime"
import spell "../core/spell"
import core "../core"
import rules "../core/rules"
import build "../core/build"
import typed "../core/typed"
import records "../core/records"

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
	// A model's rows: the plan reads into structs, so a cell is stored by its member and judged by the member's rules.
	model:  bool,
	record: bool, // a model's row is a struct, so a cell is stored by its member and not as a map's value
	judged: bool, // the header was judged by an earlier record, so its refusals are not made again
	halted: bool, // the header stopped the read: a required member has no column, which no row can make up
	single: bool, // the target is one row
	positional: bool, // the rows are lists, so a cell is stored by its column's position
	tabled:     bool, // the table's own open has come
	met:    int, // the records of a single row's text so far
}

// Readies a model's read of a table, whose rows are structs: a cell is stored by member and judged by the member's rules,
// by column name under a header and by position under `no_header`.
@(private)
model_rows :: proc(h: ^Check_Cells, plan: ^typed.Plan, opts: Options) -> core.Typed_Error {
	row, listed := row_of(plan)
	h.model, h.single, h.record, h.positional = true, !listed, is_record(row), opts.no_header && is_record(row)
	return {}
}

// The hook of a check. A column key waits for its cell, so an empty cell drops both and a dropped column drops both.
@(private)
on_check_cell :: #force_inline proc "contextless" (h: ^Check_Cells, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if t.kind != .Plain {
		t := t
		if h.positional && t.kind == .Array {
			// A row read by position is the object a header would have made.
			if h.tabled {
				t.kind = .Object
			}
			h.tabled = true
		}
		if h.single && h.c.sp == 1 {
			if out, action, handled := single_row(h, regs, t); handled {
				return out, action
			}
		}
		if t.kind == .Object || t.kind == .Array {
			h.col = 0
		}
		if !h.bound && (t.kind == .Object || t.kind == .End) {
			// The header is read by the first record, or by the end of a table that has none.
			if bind_repeats(h, regs) == .Stop {
				h.halted = true
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
	case h.model && h.positional:
		column := h.col
		h.col = column + 1
		if empty {
			break
		}
		out, action := typed.select_member(&h.c, regs, t, column)
		if action != .Next {
			return out, .Stop if action == .Stop else .Next
		}
		return model_cell(h, out, t)
	case !h.held:
		// An element of a row with no header.
		if h.model {
			if empty {
				return typed.on_token_check(&h.c, regs, {kind = .Null, role = .Value, lo = t.lo})
			}
			return typed.on_token_check(&h.c, regs, element_token(h, t, typed.field_at(regs.b)))
		}
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
		if h.record {
			return model_cell(h, out, t)
		}
		if h.model {
			// A map's value is read as an element of a row with no header is.
			return typed.on_token_check(&h.c, out, element_token(h, t, typed.field_at(out.b)))
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
	names := make([]string, len(h.keys), context.temp_allocator)
	defer delete(names, context.temp_allocator)
	at := make([]u64, len(h.keys), context.temp_allocator)
	defer delete(at, context.temp_allocator)
	for key, c in h.keys {
		name, ok := core.token_text(h.c.plan.readers, &h.c.view, key, context.temp_allocator)
		if !ok {
			_, action := typed.refuse(&h.c, regs, {kind = .No_Memory, at = key.lo})
			return .Stop if action == .Stop else .Next
		}
		names[c], at[c] = name, key.lo
		earlier, repeated := note_column(&seen, name, c, h.dups == .First)
		if !repeated {
			continue
		}
		#partial switch h.dups {
		case .Refuse:
			// A header's refusal has its column alone as a path.
			if !h.judged && header_refused(h, regs, {kind = .Duplicate_Key, at = key.lo, steps = {0 = core.Name(name)}, n_steps = 1}) == .Stop {
				return .Stop
			}
		case .First:
			h.drop[c] = true
		case:
			h.drop[earlier] = true
		}
	}
	if h.record && len(h.keys) > 0 {
		row, _ := row_of(h.c.plan)
		sp := h.c.sp
		h.c.sp = 1
		defer h.c.sp = sp
		if h.judged {
			// The header was refused by an earlier record, which only the columns it drops are wanted from.
			sink, first := h.c.sink, h.c.first
			h.c.sink = nil
			typed.judge_header(&h.c, regs, row, names, at, h.drop)
			h.c.sink, h.c.first = sink, first
			return .Next
		}
		return typed.judge_header(&h.c, regs, row, names, at, h.drop)
	}
	return .Next
}

// Refuses `e`, a fault of the header, with no frame open, so its path is its column alone.
@(cold, private)
header_refused :: proc "contextless" (h: ^Check_Cells, regs: core.Hook_Regs, e: core.Typed_Error) -> core.Action {
	sp := h.c.sp
	h.c.sp = 1
	defer h.c.sp = sp
	_, action := typed.refuse(&h.c, regs, e)
	return action
}

// The table's tokens of a single row's text: the table's open and close are not the row's, and a record past the first
// is refused and passed over.
@(cold, private)
single_row :: proc "contextless" (h: ^Check_Cells, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action, bool) {
	switch {
	case t.kind == .End:
		return regs, .Next, true
	case t.kind == .Array && h.met == 0:
		h.met = 1
		return regs, .Next, true
	case t.kind == .Object:
		h.met += 1
		if h.met > 2 {
			sp := h.c.sp
			_, action := typed.refuse(&h.c, regs, {kind = .Wrong_Length, at = t.lo})
			h.c.sp = sp
			return regs, .Stop if action == .Stop else .Skip, true
		}
	}
	return regs, .Next, false
}

// Stores the cell `t` in the member the cursor stands at, as the typed read of the table stores it, and judges the member's
// rules. A refused cell leaves the member as it was.
@(private)
model_cell :: proc "contextless" (h: ^Check_Cells, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = h.c.ctx
	fld := typed.field_at(regs.b)
	dest := uintptr(regs.c) + uintptr(fld.offset)
	if fld.kind == .Before {
		return before_cell(h, regs, t, h.c.plan.meta[fld.meta].before, dest)
	}
	reason, token := read_member(h, t, fld, dest)
	if reason != .None {
		return typed.refuse_value(&h.c, regs, t, reason)
	}
	return regs, typed.check_member(&h.c, regs, token, fld, dest)
}

// Reads the cell `t` into the member `fld` at `dest`, and returns the token its rules judge.
@(private)
read_member :: proc "contextless" (h: ^Check_Cells, t: core.Token, fld: ^typed.Field, dest: uintptr) -> (core.Typed_Error_Kind, core.Token) {
	context = h.c.ctx
	token := rule_token(h, t, fld)
	reason := read_cell(&h.c, fld, t, dest)
	if reason == .Wrong_Kind && token.kind == .Number && spelled_number(h, token) {
		// A check takes `1.0` and `1e2` into an integer, as it takes a JSON number of that spelling.
		plain := token
		plain.spelling = 0
		reason = store_integral_cell(h, plain, fld, dest)
	}
	return reason, token
}

// Stores the integral number `t` into the integer under `fld`, which may stand in a `Maybe` or a union of one arm.
@(private)
store_integral_cell :: proc "contextless" (h: ^Check_Cells, t: core.Token, fld: ^typed.Field, dest: uintptr) -> core.Typed_Error_Kind {
	context = h.c.ctx
	#partial switch fld.kind {
	case .Maybe, .Union:
		m := &h.c.plan.meta[fld.meta]
		leaf := typed.field_at(u64(uintptr(fld.first))) if fld.kind == .Maybe else one_arm(h.c.plan, m)
		store_integral_cell(h, t, leaf, dest) or_return
		typed.mark_arm(dest, fld, m, 0)
		return .None
	case .I8 ..= .U64:
		return typed.store_integral(&h.c, t, fld, dest)
	}
	return .Wrong_Kind
}

// The record a member of a `Maybe` or a one-arm union stores its value by.
@(private)
leaf_of :: proc "contextless" (h: ^Check_Cells, fld: ^typed.Field) -> ^typed.Field {
	context = h.c.ctx
	k := fld
	for k.kind == .Maybe || k.kind == .Union {
		k = typed.field_at(u64(uintptr(k.first))) if k.kind == .Maybe else one_arm(h.c.plan, &h.c.plan.meta[k.meta])
	}
	return k
}

// Rewrites the cell `t` by the member's `before`, then reads the replacement as a cell of its own into the member at
// `dest`. A refusal names the cell's bytes.
@(cold, private)
before_cell :: proc "contextless" (h: ^Check_Cells, regs: core.Hook_Regs, t: core.Token, b: ^typed.Before, dest: uintptr) -> (core.Hook_Regs, core.Action) {
	context = h.c.ctx
	hi := t.lo + u64(t.n)
	cell := t
	cell.kind = .String
	text, read := core.token_text(h.c.plan.readers, &h.c.view, cell, context.temp_allocator)
	if !read {
		return typed.refuse(&h.c, regs, {kind = .No_Memory, at = t.lo}, hi)
	}
	out, back, action, failed := typed.run_before(&h.c, regs, b, text, t.lo, hi)
	if failed {
		return back, action
	}
	buf: [spell.F64_ROOM]u8
	replaced, spelled := typed.scalar_text(out, &buf)
	if !spelled {
		return typed.refuse(&h.c, regs, {kind = .Unsupported, at = t.lo}, hi)
	}
	// The replacement is read from a text of its own, and what it refuses is placed at the cell.
	own := make([]u8, len(replaced))
	copy(own, replaced)
	defer if !h.c.borrow {
		delete(own)
	}
	sink := h.c.sink
	entries := len(sink.entries) if sink != nil else 0
	failed_before := h.c.first.kind != .None
	held := h.c.src
	h.c.src = own
	reason, token := read_member(h, {n = u32(len(own)), kind = t.kind, role = t.role}, &b.field, dest)
	action = .Next
	if reason == .None {
		action = typed.check_member(&h.c, regs, token, &b.field, dest)
	}
	h.c.src = held
	if sink != nil {
		for &e in sink.entries[entries:] {
			e.start, e.end = t.lo, hi
		}
	}
	if !failed_before && h.c.first.kind != .None {
		h.c.first.at = t.lo
	}
	if reason != .None {
		return typed.refuse_value(&h.c, regs, t, reason)
	}
	return regs, action
}

// Whether the number token `t` spells a number by the loose grammar.
@(private)
spelled_number :: proc "contextless" (h: ^Check_Cells, t: core.Token) -> bool {
	context = h.c.ctx
	_, _, _, ok := spell.number_loose(h.c.src, t.lo, t.lo + u64(t.n))
	return ok
}

// The token the rules of a stored cell judge: its text as the kind of the member reads it, a number by the loose grammar.
@(private)
rule_token :: proc "contextless" (h: ^Check_Cells, t: core.Token, fld: ^typed.Field) -> core.Token {
	context = h.c.ctx
	k := leaf_of(h, fld)
	token := t
	token.kind = .String
	if k.kind == .Bool || k.kind == .Bool_Wide {
		switch inner_text(&h.c, t) {
		case "true":
			token.kind = .True
		case "false":
			token.kind = .False
		}
	}
	if k.kind >= .I8 && k.kind <= .F64 {
		text := inner_text(&h.c, t)
		lo := u64(uintptr(raw_data(text)) - uintptr(raw_data(h.c.src)))
		_, integer, _, _ := spell.number_loose(h.c.src, lo, lo + u64(len(text)))
		token = {kind = .Number, role = .Value, lo = lo, n = u32(len(text)), spelling = core.number_spelling(core.NUMBER_DECIMAL, 1, 0 if integer else 1)}
	}
	return token
}

// The token of a cell of a row that is no struct, which the check stores as the walk would store a JSON number: an integer
// of at most 18 digits carries its folded digits in the read's `mant`, and any other number is decoded from its text.
@(private)
element_token :: proc "contextless" (h: ^Check_Cells, t: core.Token, fld: ^typed.Field) -> core.Token {
	token := rule_token(h, t, fld)
	if token.kind != .Number {
		return token
	}
	text := string(h.c.src[token.lo:][:token.n])
	if leaf := leaf_of(h, fld); leaf.kind >= .I8 && leaf.kind <= .U64 && spelled_number(h, token) && integral_digits(h, text) {
		width := 1
		for m := h.c.mant; m >= 10; m /= 10 {
			width += 1
		}
		token.spelling = core.number_spelling(core.NUMBER_DECIMAL, u64(width), 0)
		return token
	}
	digits := text[1:] if len(text) > 0 && (text[0] == '-' || text[0] == '+') else text
	mant: u64
	for c in transmute([]u8)digits {
		if c < '0' || c > '9' || len(digits) > 18 {
			token.spelling = core.number_spelling(core.NUMBER_DECIMAL, 31, 31)
			return token
		}
		mant = mant * 10 + u64(c - '0')
	}
	h.c.mant = mant
	token.spelling = core.number_spelling(core.NUMBER_DECIMAL, u64(len(digits)), 0)
	return token
}

// Whether `text`, a number the cell spells with a fraction or an exponent, is an integer of at most 18 digits, whose value
// it leaves in the read's `mant` for the store of an integer.
@(private)
integral_digits :: proc "contextless" (h: ^Check_Cells, text: string) -> bool {
	context = h.c.ctx
	d := spell.decimal_of(text)
	if !rules.integral(d) {
		return false
	}
	v, fits := rules.decimal_i64(d)
	if !fits || v > 999_999_999_999_999_999 || v < -999_999_999_999_999_999 {
		return false
	}
	h.c.mant = u64(v if v >= 0 else -v)
	return true
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
	if plan.model_plan == .Load {
		if err = model_rows(&h, plan, opts); err.kind != .None {
			return err
		}
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
document_check :: proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Error {
	if node != core.ROOT && doc.nodes[node].kind <= .Plain {
		return {kind = .Unsupported}
	}
	d := Check_Document{doc = doc, cells = {dups = read.dups}, positional = options_of(doc.as).no_header}
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

// A model's read of the row `next` gave last, as `check_cells` reads a one-row table: the header's cells are the keys,
// judged with the first row only, and the row's cells follow as the walk of a text would give them. On a stream the text is
// the header's line then the row's, and the offsets of an error are put back to the window's.
@(private)
check_row_spec :: proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Error, $S: Spec) -> bool {
	rec, ok := next_row_spec(it, S)
	opts := options_of(it.as)
	b := (^Batch)(it.format)
	if !ok {
		if b != nil && b.judged == 0 && !opts.no_header && len(b.keys) > 0 && (it.input.procedure == nil || it.eof) {
			judge_header_only(it, b, target, T, plan, read, allocator, err)
		}
		return false
	}
	// A record the read takes again judges the header again, so only a later record is halted.
	place := it.base + rec.at + 1
	if b.halted != 0 && b.halted != place {
		return false
	}
	row := b.rows[b.at - 1]
	src, at, joinable := joined(it, b, row)
	if !joinable {
		err^ = {kind = .No_Memory}
		return false
	}
	// A record the read takes again, which a short window makes it do, judges the header again: the first judgment stands
	// only once a later record is read.
	record := read.sink.record + 1 if read.sink != nil else max(i64)
	h := Check_Cells{dups = read.dups, judged = b.judged != 0 && b.judged < record}
	regs, started := typed.check_start(&h.c, src, untracked(plan), it.as, T, target, read, untracked_frames(it.frames), allocator)
	if started.kind != .None {
		err^ = started
		return false
	}
	h.c.ctx.temp_allocator = runtime.arena_allocator(&it.scratch)
	model_rows(&h, plan, opts)
	kept := typed.sink_mark(read.sink)
	failed: runtime.Allocator_Error
	if !opts.no_header {
		if h.keys, failed = make([]core.Token, len(b.keys), context.temp_allocator); failed != nil {
			err^ = {kind = .No_Memory}
			return false
		}
		copy(h.keys, b.keys)
		h.drop = make([]bool, len(h.keys), context.temp_allocator)
	}
	action: core.Action
	regs, action = on_check_cell(&h, regs, {kind = .Array, role = .Value, lo = at.at})
	if action == .Next {
		regs, action = on_check_cell(&h, regs, {kind = .Array if h.positional else .Object, role = .Value, lo = at.at})
	}
	if action == .Next {
		regs, action = split_cells(src, at, S, opts, .Value, &h, regs, on_row_cell)
	}
	if action != .Stop {
		regs, _ = on_check_cell(&h, regs, {kind = .End, role = .Value, lo = at.hi})
		regs, _ = on_check_cell(&h, regs, {kind = .End, role = .Value, lo = at.hi})
	}
	if b.judged == 0 || b.judged >= record {
		b.judged = record
	}
	if h.halted && b.halted == 0 {
		b.halted = place
	}
	if h.c.first.kind != .None {
		err^ = typed.read_end(&h.c, regs, nil)
	}
	if it.input.procedure != nil {
		place_error(it, b, row, err)
		if read.sink != nil {
			for &e in read.sink.errors[kept.errors:] {
				place_error(it, b, row, &e)
			}
			for &e in read.sink.entries[kept.entries:] {
				e.start, e.end = place_at(it, b, row, e.start), place_at(it, b, row, e.end)
			}
		}
	}
	return true
}

// Judges the header of a table that has no row, which no record reads, as the check of a text judges it at the table's end.
@(cold, private)
judge_header_only :: proc(it: ^records.Reader, b: ^Batch, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Error) {
	src := it.src if it.input.procedure == nil else b.key_src
	h := Check_Cells{dups = read.dups}
	regs, started := typed.check_start(&h.c, src, untracked(plan), it.as, T, target, read, untracked_frames(it.frames), allocator)
	if started.kind != .None {
		err^ = started
		return
	}
	h.c.ctx.temp_allocator = runtime.arena_allocator(&it.scratch)
	model_rows(&h, plan, options_of(it.as))
	failed: runtime.Allocator_Error
	if h.keys, failed = make([]core.Token, len(b.keys), context.temp_allocator); failed != nil {
		err^ = {kind = .No_Memory}
		return
	}
	copy(h.keys, b.keys)
	h.drop = make([]bool, len(h.keys), context.temp_allocator)
	action: core.Action
	regs, action = on_check_cell(&h, regs, {kind = .Array, role = .Value})
	if action == .Next {
		// A single row's text has no table close that binds the header.
		if bind_repeats(&h, regs) == .Next {
			regs, _ = on_check_cell(&h, regs, {kind = .End, role = .Value, lo = u64(len(src))})
		}
	}
	b.judged = max(i64)
	if h.c.first.kind != .None {
		err^ = typed.read_end(&h.c, regs, nil)
	}
}

// A cell of a row that `check_row_spec` feeds, with the key of its column before it.
@(private)
on_row_cell :: proc "contextless" (h: ^Check_Cells, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if !h.positional {
		if h.col >= len(h.keys) {
			return regs, .Next
		}
		if out, action := on_check_cell(h, regs, h.keys[h.col]); action != .Next {
			return out, action
		}
	}
	return on_check_cell(h, regs, t)
}
