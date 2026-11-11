package dsv

// The typed read of a delimited text, over the plan and the stores of `core/typed`: `unmarshal` reads the records into a
// list of rows. A cell has no kind of its own, so it reads by its column's field, and the columns are bound to fields
// once, when the header has been read. `Cells` wraps `typed.Reader`, whose hook reads the records' open and close, and
// takes each cell before that hook sees a token.

import "base:intrinsics"
import "base:runtime"
import spell "../core/spell"
import core "../core"
import rules "../core/rules"
import typed "../core/typed"
import write "../core/write"

// Reads `src`, a text of spec `S`, into `target`, a slice or dynamic array of rows, replacing what it held, or into one
// row, which reads the first record and refuses a second as `.Wrong_Length`. A row is a struct whose fields the header
// names, a list of cells, or a map of string keys to cells. See `docs/typed.md`. The form with no plan builds one with
// `context.allocator` and frees it before it returns, and a plan built once with `plan_make` is the form for many
// reads. A refusal leaves everything the read allocated reachable from `target`. A constant `spec` links the pass of
// that spec alone, and a `spec` chosen at run time links the passes of every spec. The target of that form is any
// pointer, and a target that is no pointer is `.Plan_Mismatch`.
unmarshal :: proc {unmarshal_bound, unmarshal_bound_plan, unmarshal_chosen, unmarshal_chosen_plan}

// Reads `src` into `target` by `plan` as `unmarshal` does, with every refusal in `read.sink.entries`, and returns the
// first. The options are the plan's, and any plan of the format reads.
check :: proc {check_bound, check_chosen}

// Returns the typed reads of spec `S`, which `plan_make` takes to read and check by that spec.
reads :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	return reads_of(S)
}

// Returns the checks of spec `S` read and written with `opts`, which `model.compile` and `schema.bind` take: the reads of
// a plan made from a description or a model, which check a text or a document by that spec, and the layout its plans
// read and write by. It reaches only the passes of `S`, where `as(spec, opts)` reaches every spec's. `reads` serves a
// plan made from a type.
checks :: proc "contextless" ($S: Spec, opts := Options{}) -> typed.Format_Checks {
	return {checks_of(S), bound_as(S, opts)}
}

// The reads `checks` gives for the spec of `as`, a handle `as` made with a spec chosen at run time, or nil for a
// handle of another format.
checks_for :: proc "contextless" (as: core.As) -> ^typed.Format_Reads {
	if as.spec > u8(max(Spec)) || as.readers != &HANDLES[Spec(as.spec)] {
		return nil
	}
	switch Spec(as.spec) {
	case .Csv:   return checks_of(.Csv)
	case .Tsv:   return checks_of(.Tsv)
	case .Plain: return checks_of(.Plain)
	}
	return nil
}

// Builds the plan of `T` for dsv's spelling, as `typed.plan_make` does, and refuses a `T` that is no list of rows and no
// row. A write by the plan is of spec `spec` with the delimiter, comment byte, `no_header`, `crlf` and `.Ragged` of
// `opts`, and `.Bad_Option` when the spec cannot spell them. A read takes its spec and options at the call. The plan
// reads a text only with `reads`, whose reads bind a spec and so the pass of that spec, and with none it reads through
// `unmarshal` and `check`.
plan_make :: proc(T: typeid, spec := Spec.Csv, opts := Options{}, plan := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := plan_built(T, spec, opts, plan, reads, allocator)
	return made, core.error_of(err)
}

// Builds the plan that reads values of description `d` as `spec`, as `typed.plan_of` does, and refuses a description that
// is no list of rows and no row, as `plan_make` does. The reads are the plan's with `reads`, as for `plan_make`.
plan_of :: proc(d: ^rules.Description, spec := Spec.Csv, opts := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	if !layout_ok(spec, {}) {
		return {}, core.error_of(core.Typed_Refusal{kind = .Bad_Option})
	}
	made, err := typed.plan_of(d, layout_as(spec, {}), reads, opts, allocator)
	if err != nil {
		return made, err
	}
	if refusal := rows_supported(&made); refusal.kind != .None {
		typed.plan_destroy(&made)
		return {}, core.error_of(refusal)
	}
	plan_bind(&made)
	return made, nil
}

// The plan of `T` with the writer, the token writer and the document read of dsv, and the reads `reads` holds.
@(private)
plan_built :: proc(T: typeid, spec: Spec, layout: Options, opts: typed.Plan_Options, reads: ^typed.Format_Reads, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	if !layout_ok(spec, layout) {
		return {}, {kind = .Bad_Option}
	}
	p, err := typed.plan_build(T, layout_as(spec, layout), opts, allocator)
	if err.kind != .None {
		return p, err
	}
	if err = rows_supported(&p); err.kind != .None {
		typed.plan_destroy(&p)
		return {}, err
	}
	plan_bind(&p)
	typed.plan_reads(&p, reads)
	return p, {}
}

// Gives a plan dsv's writer, token writer and document read.
@(private)
plan_bind :: proc(p: ^typed.Plan) {
	p.marshal, p.tokens, p.node_read = marshal_text, &TOKENS, document_read
	p.value_text = write.value_text
}

@(private)
unmarshal_bound :: proc(src: []u8, $S: Spec, target: ^$T, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	plan, refusal := plan_make(T, S)
	if refusal != nil {
		return refusal
	}
	defer typed.plan_destroy(&plan)
	err := read_text(src, S, T, target, &plan, opts, read, allocator, false, typed.Reader)
	typed.own_errors(&err, read.sink)
	return core.error_of(err)
}

@(private)
unmarshal_bound_plan :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return core.error_of(read_text(src, S, T, target, plan, opts, read, allocator, false, typed.Reader))
}

@(private)
unmarshal_chosen :: proc(src: []u8, spec: Spec, target: any, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	data, T, pointer := typed.pointer_target(target)
	if !pointer {
		return core.error_of(core.Typed_Refusal{kind = .Plan_Mismatch})
	}
	plan, refusal := plan_make(T, spec)
	if refusal != nil {
		return refusal
	}
	defer typed.plan_destroy(&plan)
	err := read_spec(src, spec, opts, data, T, &plan, read, allocator, false)
	typed.own_errors(&err, read.sink)
	return core.error_of(err)
}

@(private)
unmarshal_chosen_plan :: proc(src: []u8, spec: Spec, target: any, plan: ^typed.Plan, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	data, T, pointer := typed.pointer_target(target)
	if !pointer {
		return core.error_of(core.Typed_Refusal{kind = .Plan_Mismatch})
	}
	return core.error_of(read_spec(src, spec, opts, data, T, plan, read, allocator, false))
}

@(private)
check_bound :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return core.error_of(check_one(src, S, T, target, plan, options_of(plan.as), read, allocator))
}

@(private)
check_chosen :: proc(src: []u8, spec: Spec, target: any, plan: ^typed.Plan, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	data, T, pointer := typed.pointer_target(target)
	if !pointer {
		return core.error_of(core.Typed_Refusal{kind = .Plan_Mismatch})
	}
	return core.error_of(read_spec(src, spec, options_of(plan.as), data, T, plan, read, allocator, true))
}

// Whether `plan` was made by `typed.plan_make` and not `plan_make`, which alone checks that a type is a list of rows of
// cells or a row.
@(private)
foreign_plan :: proc "contextless" (plan: ^typed.Plan) -> bool {
	return plan != nil && plan.marshal == nil && plan.err.kind == .None
}

@(private)
read_spec :: proc(src: []u8, spec: Spec, opts: Options, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, check: bool) -> core.Typed_Refusal {
	switch spec {
	case .Csv:   return read_one(src, .Csv, T, target, plan, opts, read, allocator, check)
	case .Tsv:   return read_one(src, .Tsv, T, target, plan, opts, read, allocator, check)
	case .Plain: return read_one(src, .Plain, T, target, plan, opts, read, allocator, check)
	}
	return {kind = .Bad_Option}
}

// A read or a check of spec `S`, a check being the description's when the plan has one.
@(private)
read_one :: proc(src: []u8, $S: Spec, T: typeid, target: rawptr, plan: ^typed.Plan, opts: Options, read: typed.Read_Options, allocator: runtime.Allocator, check: bool) -> core.Typed_Refusal {
	if !check {
		return read_text(src, S, T, target, plan, opts, read, allocator, false, typed.Reader)
	}
	return check_one(src, S, T, target, plan, opts, read, allocator)
}

// The check of a text of spec `S`: the description's when the plan has one, else the typed read's.
@(private)
check_one :: proc(src: []u8, $S: Spec, T: typeid, target: rawptr, plan: ^typed.Plan, opts: Options, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	if plan != nil && plan.checking {
		return check_cells(src, S, target, T, plan, opts, read, allocator)
	}
	if plan != nil && plan.model_plan == .Load {
		return read_text(src, S, T, target, plan, opts, read, allocator, true, typed.Check)
	}
	return read_text(src, S, T, target, plan, opts, read, allocator, true, typed.Reader)
}

@(private)
read_text :: proc(src: []u8, $S: Spec, T: typeid, target: rawptr, plan: ^typed.Plan, opts: Options, read: typed.Read_Options, allocator: runtime.Allocator, $CHECK: bool, $H: typeid) -> core.Typed_Refusal {
	if foreign_plan(plan) {
		return {kind = .Plan_Mismatch}
	}
	h := Cells_Of(H){refuse_repeats = read.dups == .Refuse}
	frames: [ROW_FRAMES]typed.Frame = ---
	regs, err := start_cells(&h, src, plan, bound_as(S, opts), T, target, read, frames[:], allocator)
	if err.kind != .None {
		return err
	}
	h.r.wide = CHECK
	rows_of(&h, plan, len(src))
	if h.row.kind == .Map && opts.no_header {
		return {kind = .Unsupported}
	}
	walk_opts := opts
	// A list row holds every record, the first too.
	walk_opts.no_header = opts.no_header || h.opens == .Array
	h.no_header = walk_opts.no_header
	if !h.no_header {
		start := int(core.text_start(src, 0))
		// With no header there is no list of rows to give the target, so it keeps what it held.
		if record_start(src, start, opts.comment) >= len(src) {
			if f, faulted := validate_spec(src, S, opts).?; faulted {
				return {kind = .Walk, at = f.at, inner = f}
			}
			return {}
		}
		failed: runtime.Allocator_Error
		h.keys, failed = make([]core.Token, header_cells(src, start, S, opts), context.temp_allocator)
		if failed != nil {
			return {kind = .No_Memory}
		}
	}
	defer delete(h.keys, context.temp_allocator)
	defer delete(h.cols, context.temp_allocator)
	_, fault := walk_keys(src, 0, S, walk_opts, &h, &regs, on_cell, h.keys)
	if fault != nil {
		fault_position(&h, &regs)
	}
	return typed.read_end(&h.r, regs, fault)
}

// Starts the typed read of `h`, a model's check under `typed.Check`.
@(private)
start_cells :: proc(h: ^Cells_Of($H), src: []u8, plan: ^typed.Plan, as: core.As, T: typeid, target: rawptr, read: typed.Read_Options, frames: []typed.Frame, allocator: runtime.Allocator) -> (core.Hook_Regs, core.Typed_Refusal) {
	when H == typed.Check {
		return typed.check_start(&h.r, src, untracked(plan), as, T, target, read, untracked_frames(frames), allocator)
	} else {
		return typed.read_start(&h.r, src, plan, as, T, target, read, frames, allocator, false)
	}
}

// Reads the plan's row type into `h`: the row, whether the target is one row, the token that opens a row, the register
// that names no field, and where a hot read stops short of the text's end.
@(private)
rows_of :: proc(h: ^Cells_Of($H), plan: ^typed.Plan, text_len: int) {
	listed: bool
	h.row, listed = row_of(plan)
	h.single = !listed
	h.opens = .Array if h.row.kind == .Slice || h.row.kind == .Dynamic else .Object
	// A record's own `Never`, which the typed read's check at a row's close counts as past every member. Any other row
	// has no check and takes the plan's.
	h.past = u64(uintptr(plan.root)) + size_of(typed.Field)
	if is_record(h.row) {
		h.past = u64(uintptr(h.row.first)) + u64(plan.meta[h.row.meta].members + 1) * size_of(typed.Field)
	}
	h.hot_end = u64(text_len - HOT_REACH) if text_len > HOT_REACH else 0
}

// A text nests a record in the list of records, over the frame below the root's. A row target has no frame for the list.
@(private)
ROW_FRAMES :: 4

// The read's depth inside a row.
@(private)
row_depth :: #force_inline proc "contextless" (h: ^Cells_Of($H)) -> int {
	return ROW_FRAMES - 1 - int(h.single)
}

// The bytes from a cell's first that a hot read may load, so the last cells of a text take the cold read.
@(private)
HOT_REACH :: 24

// A column of the read. `kind` is `.Inside` for a column no field reads and `.Never` for the entry past a row's last
// field, where the cursor stays. `step` moves the cursor, 0 for a list row, whose one column reads every cell. `must`
// says this column or a later one holds a required field. `rec` is what `Hook_Regs.b` holds when the field is read.
@(private)
Column :: struct {
	kind:     typed.Read_Kind,
	must:     bool,
	required: bool,
	repeat:   bool, // an `.Inside` column of a field another column reads, whose cells are judged and dropped
	offset:   u32,
	stride:   u32,
	step:     u32,
	rec:      ^typed.Field,
	name:     string, // a map row's key
	key:      core.Token, // its span when that spells it, else the header cell
}

// `Hook_Regs` inside a row: `b` is the column of the next cell, and `c` the row or, in a list row, the next cell's
// element. A map row keeps `a` and `c` 0, so the room test sends each cell to the read that makes its entry. `single`
// says the target is one row, which reads the text's first record, and `opens` counts the text's open and the rows a
// single read has met. `H` is `typed.Reader`, or `typed.Check` for a model's load, which judges each cell by its
// member's rules and leaves an empty cell of a struct row absent for the row's close to judge.
@(private)
Cells_Of :: struct($H: typeid) {
	r:              H,
	row:            ^typed.Field,
	cols:           []Column,
	keys:           []core.Token,
	past:           u64, // the `Hook_Regs.b` that names no field
	hot_end:        u64,
	opens:          core.Kind, // the token that opens a row
	met:            int,
	single:         bool,
	no_header:      bool,
	refuse_repeats: bool,
	quiet:          bool, // a model's record past the one that judged the header, which refuses none of it again
	halted:         bool, // a model's header lacks a required column, which no row can make up
}

@(private)
Cells :: Cells_Of(typed.Reader)

@(private)
is_record :: #force_inline proc "contextless" (f: ^typed.Field) -> bool {
	return f.kind == .Struct || f.kind == .Required
}

// The hook of a typed read. A role other than `Value` is a column's key, which the column table has already read, or a
// comment. The hot kinds read a cell in place, and all else, an empty cell included, fails these reads and goes to
// `cell_cold`.
@(private)
on_cell :: #force_inline proc "contextless" (h: ^Cells_Of($H), regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	if t.kind != .Plain {
		return row_token(h, regs, t)
	}
	if t.role != .Value {
		return regs, .Next
	}
	col := (^Column)(uintptr(regs.b))
	when H == typed.Check {
		return cell_cold(h, regs, col, t)
	}
	if regs.c >= regs.a || t.lo >= h.hot_end {
		return cell_cold(h, regs, col, t)
	}
	regs := regs
	dest := uintptr(regs.c) + uintptr(col.offset)
	p := raw_data(h.r.src)[t.lo:]
	ok := false
	#partial switch col.kind {
	case .Inside:
		ok = true
	case .String:
		// A quoted cell is its inner span unless the walk saw a `""`.
		quotes := u64(t.spelling >> 1 & 1)
		if t.spelling == u16(quotes * 3) && t.n != 0 {
			lo, n := t.lo + quotes, u64(t.n) - 2 * quotes
			if h.r.borrow {
				(^runtime.Raw_String)(dest)^ = {raw_data(h.r.src)[lo:], int(n)}
				ok = true
			} else {
				ok = typed.store_string(&h.r, core.Token{lo = lo, n = u32(n)}, (^string)(dest)) == .None
			}
		}
	case .I64:
		v: i64
		if v, ok = spell.short_integer(p, u64(t.n)); ok {
			(^i64)(dest)^ = v
		}
	case .F64:
		v: f64
		if v, ok = spell.short_decimal(p, u64(t.n)); ok {
			(^f64)(dest)^ = v
		}
	case .Bool:
		word := intrinsics.unaligned_load((^u64)(p))
		yes := t.n == 4 && u32(word) == 0x65757274
		ok = yes || t.n == 5 && word & 0xff_ffff_ffff == 0x65_736c_6166
		if ok {
			(^bool)(dest)^ = yes
		}
	}
	if !ok {
		return cell_cold(h, regs, col, t)
	}
	regs.b += u64(col.step)
	regs.c += u64(col.stride)
	return regs, .Next
}

// The typed read's hook, a check's for a model's load.
@(private)
read_token :: #force_inline proc "contextless" (h: ^Cells_Of($H), regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	when H == typed.Check {
		return typed.on_token_check(&h.r, regs, t)
	} else {
		return typed.on_token(&h.r, regs, t)
	}
}

// A row's open and close, and the text's. The first row's open, or the text's close when it has no row, comes after the
// header, so the columns are bound there.
@(private)
row_token :: #force_no_inline proc "contextless" (h: ^Cells_Of($H), regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	regs := regs
	if t.kind == .End {
		if h.r.sp == row_depth(h) {
			col := (^Column)(uintptr(regs.b))
			when H == typed.Check {
				// A model's struct row marked the members it read, which its close judges with the cursor before them all.
				if is_record(h.row) {
					return read_token(h, {regs.a, u64(uintptr(h.row.first)), regs.c}, t)
				}
			}
			if col.must {
				return missing_cell(h, regs, col, t)
			}
			regs.b = h.past
		} else if h.cols == nil && !h.no_header {
			if action := bind_columns(h, regs, t.lo); action != .Next {
				return regs, action
			}
		}
		if h.single && h.r.sp == 1 {
			return regs, .Next
		}
		return read_token(h, regs, t)
	}
	if h.r.sp == 1 {
		if !h.single {
			return read_token(h, regs, t)
		}
		// The text's open, then its first row. A row target holds one row, and a later one is refused and passed over.
		h.met += 1
		if h.met == 1 {
			return regs, .Next
		}
		if h.met > 2 {
			_, action := typed.refuse(&h.r, regs, {kind = .Wrong_Length, at = t.lo})
			return regs, .Stop if action == .Stop else .Skip
		}
	}
	if h.cols == nil {
		if action := bind_columns(h, regs, t.lo); action != .Next {
			return regs, action
		}
	}
	token := t
	token.kind = h.opens
	action: core.Action
	regs, action = read_token(h, regs, token)
	if action == .Next {
		regs.b = u64(uintptr(raw_data(h.cols)))
		if h.row.kind == .Map {
			regs.a = 0
		}
	}
	return regs, action
}

// Refuses the required field the cursor stands before, and under a check each one after it, at the row's end, and closes
// the row.
@(private, cold)
missing_cell :: #force_no_inline proc "contextless" (h: ^Cells_Of($H), regs: core.Hook_Regs, col: ^Column, t: core.Token) -> (core.Hook_Regs, core.Action) {
	cols := ([^]Column)(col)
	regs := regs
	regs.b = h.past
	for {
		for !cols[0].required {
			cols = cols[1:]
		}
		name := h.r.plan.meta[typed.field_at(u64(uintptr(cols[0].rec))).meta].name
		_, action := typed.refuse(&h.r, regs, {kind = .Missing_Field, at = t.lo, steps = {0 = core.Name(name)}, n_steps = 1}, t.lo + u64(t.n))
		if action == .Stop {
			return regs, action
		}
		cols = cols[1:]
		if !h.r.wide || !cols[0].must {
			break
		}
	}
	return read_token(h, regs, t)
}

// The byte past the cell `t` as written, where the entry of a refused cell ends.
@(private)
cell_end :: #force_inline proc "contextless" (t: core.Token) -> u64 {
	_, hi := core.scalar_ends(t)
	return hi
}

// A cell no hot read took: an empty cell, a kind or a spelling the hot reads leave out, a cell near the text's end, and
// the cell that needs room made for it first.
@(private, cold)
cell_cold :: #force_no_inline proc "contextless" (h: ^Cells_Of($H), regs: core.Hook_Regs, col: ^Column, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = h.r.ctx
	next := regs
	next.b += u64(col.step)
	at := core.Hook_Regs{regs.a, u64(uintptr(col.rec)), regs.c}
	#partial switch col.kind {
	case .Inside:
		return next, .Next
	case .Never:
		if col.repeat {
			// The cell is read into a scratch value, so it is judged and the other column's value stands.
			if t.n == 0 {
				return next, .Next
			}
			fld := typed.field_at(at.b)
			scratch, no_scratch := runtime.mem_alloc(int(h.r.plan.meta[fld.meta].size), 16, context.temp_allocator)
			reason := read_cell(&h.r, fld, t, uintptr(raw_data(scratch))) if no_scratch == nil else .No_Memory
			if reason == .None {
				return next, .Next
			}
			_, action := typed.refuse(&h.r, at, {kind = reason, at = t.lo}, cell_end(t))
			return next, action
		}
		if !h.no_header {
			// A headed row's cursor stands here past the header's last column only under `.Ragged`, at a column the row
			// binds now, named by its position.
			return widen_columns(h, regs, t)
		}
		kind := core.Typed_Error_Kind.Unknown_Field
		at.b = h.past
		if !h.r.refuse_unknown {
			// A model's struct that forbids the members it does not name refuses a longer row at its last member.
			if !is_record(h.row) || !typed.extra_at(h.r.plan, h.row.meta).forbid {
				return next, .Next
			}
			kind, at.b = .Wrong_Length, at.b - size_of(typed.Field)
		}
		_, action := typed.refuse(&h.r, at, {kind = kind, at = t.lo}, cell_end(t))
		return regs, action
	}
	map_row := h.row.kind == .Map
	when H == typed.Check {
		// A model's row reads an empty unquoted cell as null, as a check of the text sees it.
		if is_record(h.row) {
			typed.mark_member(&h.r, regs, int(uintptr(col.rec) - uintptr(h.row.first)) / size_of(typed.Field) - 1)
			fld := typed.field_at(at.b)
			if fld.kind == .Before {
				_, action := before_cell(h, at, t, fld, uintptr(regs.c) + uintptr(col.offset))
				return next, action
			}
			if t.n == 0 {
				_, action := null_cell(&h.r, at, t, fld, uintptr(regs.c) + uintptr(col.offset))
				return next, action
			}
		}
	}
	if t.n == 0 {
		if col.required {
			_, action := typed.refuse(&h.r, at, {kind = .Missing_Field, at = t.lo}, cell_end(t))
			return next, action
		}
		if map_row {
			return next, .Next
		}
	}
	reason: core.Typed_Error_Kind
	if map_row {
		f := &h.r.frames[h.r.sp - 1]
		spelled := col.name if col.key.spelling & SPELLING_COLUMN != 0 else inner_text(&h.r, col.key)
		f.extra, f.run = cast([^]u64)raw_data(spelled), (^typed.Field)(uintptr(len(spelled)))
		slot: rawptr
		slot, reason = typed.map_slot(&h.r, &h.r.plan.meta[h.row.meta], (^runtime.Raw_Map)(f.data), col.name, col.key, typed.field_at(at.b), false)
		at.c = u64(uintptr(slot))
		if reason != .None {
			_, action := typed.refuse(&h.r, at, {kind = reason, at = t.lo}, cell_end(t))
			return next, action
		}
	} else if regs.c >= regs.a {
		at, reason = typed.grow_list(&h.r, at)
		if reason != .None {
			out, action := typed.refuse_element(&h.r, at, t, reason)
			next.a, next.c = out.a, out.c
			return next, action
		}
	}
	action := core.Action.Next
	if t.n == 0 {
		runtime.mem_zero(rawptr(uintptr(at.c)), int(col.stride))
		at.c += u64(col.stride)
	} else if reason = read_cell(&h.r, typed.field_at(at.b), t, uintptr(at.c) + uintptr(col.offset)); reason != .None {
		at, action = typed.refuse_value(&h.r, at, t, reason)
	} else {
		when H == typed.Check {
			action = judge_cell(&h.r, at, t, typed.field_at(at.b), uintptr(at.c) + uintptr(col.offset))
		}
		at.c += u64(col.stride)
	}
	if !map_row {
		next.a, next.c = at.a, at.c
	}
	return next, action
}

// Judges the cell `t` that `fld` stored at `dest` by the record's rules, a number read by the loose grammar.
@(private)
judge_cell :: proc(c: ^typed.Check, regs: core.Hook_Regs, t: core.Token, fld: ^typed.Field, dest: uintptr) -> core.Action {
	if c.plan.meta[fld.meta].rule_set == 0 {
		return .Next
	}
	leaf := fld
	for leaf.kind == .Maybe || leaf.kind == .Union {
		leaf = typed.field_at(u64(uintptr(leaf.first))) if leaf.kind == .Maybe else one_arm(c.plan, &c.plan.meta[leaf.meta])
	}
	token := t
	token.kind = .String
	if leaf.kind >= .I8 && leaf.kind <= .F64 || leaf.kind == .Number_Text {
		text := inner_text(c, t)
		lo := u64(uintptr(raw_data(text)) - uintptr(raw_data(c.src)))
		_, integer, _, _ := spell.number_loose(c.src, lo, lo + u64(len(text)))
		token = {kind = .Number, role = .Value, lo = lo, n = u32(len(text)), spelling = core.number_spelling(core.NUMBER_DECIMAL, 1, 0 if integer else 1)}
	}
	return typed.check_rules(c, regs, token, fld, dest)
}

// Rewrites the cell `t` by the `before` of the member `fld`, then reads the replacement into the member at `dest`. An
// empty cell is null.
@(cold, private)
before_cell :: proc(h: ^Cells_Of(typed.Check), regs: core.Hook_Regs, t: core.Token, fld: ^typed.Field, dest: uintptr) -> (core.Hook_Regs, core.Action) {
	c := &h.r
	m := &c.plan.meta[fld.meta]
	b := typed.extra_at(c.plan, fld.meta).before
	hi := t.lo + u64(t.n)
	if b.call == nil || b.judge != nil {
		return typed.refuse(c, regs, {kind = .Unsupported, at = t.lo}, hi)
	}
	// The cell's text, the replacement and its spelling live only for this cell, unless a refusal holds the spelling.
	context = c.ctx
	own_temp := context.allocator == context.temp_allocator
	guard := runtime.default_temp_allocator_temp_begin()
	cell := t
	cell.kind = .String
	value: core.Value
	if t.n > 0 {
		text, read := core.token_text(c.plan.readers, &c.view, cell, context.temp_allocator)
		if !read {
			return typed.refuse(c, regs, {kind = .No_Memory, at = t.lo}, hi)
		}
		value = text
	}
	back, action := typed.read_replacement(c, regs, m, dest, value, t.lo, hi)
	if !own_temp && action == .Next {
		runtime.default_temp_allocator_temp_end(guard)
	}
	return back, action
}

// The plans' `replace`: reads the scalar `v` as a cell of its own through `c` at `regs`, a null as an empty cell. A
// string member under `borrow_strings` keeps the cell's text, which is in the read's allocator for that.
@(private)
replace_cell :: proc(c: ^typed.Check, regs: core.Hook_Regs, v: core.Value, _: u32) -> ([]u8, core.Hook_Regs, core.Action) {
	if v == nil {
		fld := typed.field_at(regs.b)
		back, action := null_cell(c, regs, {kind = .Plain, role = .Value}, fld, uintptr(regs.c) + uintptr(fld.offset))
		return nil, back, action
	}
	buf: [spell.F64_ROOM]u8
	spelled, ok := scalar_text(v, &buf)
	if !ok {
		back, action := typed.refuse(c, regs, {kind = .Unsupported})
		return nil, back, action
	}
	text, failed := make([]u8, len(spelled), c.ctx.allocator if c.borrow else context.temp_allocator)
	if failed != nil {
		back, action := typed.refuse(c, regs, {kind = .No_Memory})
		return nil, back, action
	}
	copy(text, spelled)
	fld := typed.field_at(regs.b)
	dest := uintptr(regs.c) + uintptr(fld.offset)
	held := c.src
	c.src = text
	cell := core.Token{n = u32(len(text)), kind = .Plain, role = .Value}
	action := core.Action.Next
	if reason := read_cell(c, fld, cell, dest); reason != .None {
		_, action = typed.refuse_value(c, regs, cell, reason)
	} else {
		action = judge_cell(c, regs, cell, fld, dest)
	}
	c.src = held
	return text, regs, action
}

// A null, the empty cell `t`, read into the member `fld` at `dest`: a `Maybe` or union takes nil where it has one, a
// cstring nil, a hook reads it, and any other member refuses it. A null has no rules to judge.
@(private)
null_cell :: proc(c: ^typed.Check, regs: core.Hook_Regs, t: core.Token, fld: ^typed.Field, dest: uintptr) -> (core.Hook_Regs, core.Action) {
	m := &c.plan.meta[fld.meta]
	null := t
	null.kind = .Null
	reason := core.Typed_Error_Kind.None
	#partial switch fld.kind {
	case .Maybe, .Union:
		if m.no_nil {
			reason = .Wrong_Kind
		} else {
			runtime.mem_zero(rawptr(dest), int(m.size))
		}
	case .Cstring:
		(^cstring)(dest)^ = nil
	case .Hook:
		reason = typed.store_whole(c, fld, m, dest, .Null, t.lo, t.lo, null)
	case:
		reason = .Wrong_Kind
	}
	if reason != .None {
		return typed.refuse_value(c, regs, null, reason)
	}
	return regs, .Next
}

// The text of the scalar `v` as a cell, in `buf` when it is a number. A null spells an empty cell.
@(private)
scalar_text :: proc "contextless" (v: core.Value, buf: ^[spell.F64_ROOM]u8) -> (text: string, ok: bool) {
	switch x in v {
	case nil:
		return "", true
	case string:
		return x, true
	case bool:
		return "true" if x else "false", true
	case ^core.Number_Text:
		return x.text, true
	case f64:
		if x != x || abs(x) > max(f64) {
			return "", false
		}
		return string(buf[:spell.f64_text(&buf[0], x)]), true
	case ^core.Array, ^core.Object, core.Node_Ref, ^core.Commented, core.Trail:
	}
	return "", false
}

// Stores the text of a quoted cell holding a `""` into the string at `dest`, in memory of the read's allocator.
@(private)
store_undoubled :: proc (r: ^typed.Reader, t: core.Token, dest: uintptr) -> bool {
	buf, err := runtime.mem_alloc_non_zeroed(int(t.n), 1)
	if err != nil {
		return false
	}
	(^string)(dest)^ = undoubled(buf, inner_text(r, t))
	return true
}

// The bytes of a cell without the quote pair of a quoted cell.
@(private)
inner_text :: #force_inline proc "contextless" (r: ^typed.Reader, t: core.Token) -> string {
	quotes := u64(t.spelling >> 1 & 1)
	return string(r.src[t.lo + quotes:t.lo + u64(t.n) - quotes])
}

// Reads a present cell into the field `fld` at `dest`. A number, a bool and an enum's value read the cell's bytes,
// since what decodes to other bytes spells none of them. The rest read as a string token, whose text `Readers.text`
// gives.
@(private)
read_cell :: proc(r: ^$R, fld: ^typed.Field, t: core.Token, dest: uintptr) -> core.Typed_Error_Kind {
	m := &r.plan.meta[fld.meta]
	cell := t
	cell.kind = .String
	#partial switch fld.kind {
	case .String:
		// The walk marked it, so a `""` takes no scan and no general decode.
		if t.spelling & (SPELLING_DOUBLED | core.SPELLING_LAX) == SPELLING_DOUBLED {
			return .None if store_undoubled(r, t, dest) else .No_Memory
		}
		if t.spelling & (core.SPELLING_QUOTED | SPELLING_DOUBLED) == core.SPELLING_QUOTED && plain_quoted(r.src, t) {
			lo, hi := inner_span(t)
			cell = core.Token{lo = lo, n = u32(hi - lo)}
		}
		return typed.store_string(r, cell, (^string)(dest))
	case .Bool, .Bool_Wide:
		text := inner_text(r, t)
		if text != "true" && text != "false" {
			return .Wrong_Kind
		}
		runtime.mem_zero(rawptr(dest), int(m.size))
		(^bool)(dest)^ = text == "true"
	case .I8 ..= .F64, .Enum:
		if fld.kind == .Enum && !typed.enum_by_number(r.plan, m.enum_info) {
			return typed.store_enum(r, cell, m.enum_info, dest, m.size)
		}
		text := inner_text(r, t)
		lo := u64(uintptr(raw_data(text)) - uintptr(raw_data(r.src)))
		n, integer, _, ok := spell.number_loose(r.src, lo, lo + u64(len(text)))
		if !ok || !integer && fld.kind == .Enum {
			return .Wrong_Kind
		}
		if fld.kind == .Enum {
			return typed.store_enum_value(m.enum_info, n, dest, m.size)
		}
		token := core.Token{lo = lo, n = u32(len(text))}
		reason := typed.store_number(n, integer, r, token, fld, dest)
		when R == typed.Check {
			// A check takes `1.0` and `1e2` into an integer, as it takes a JSON number of that spelling.
			if reason == .Wrong_Kind && fld.kind <= .U64 {
				reason = typed.store_integral(r, token, fld, dest)
			}
		}
		return reason
	case .Cstring:
		return typed.store_cstring(r, cell, dest)
	case .Number_Text:
		text := inner_text(r, t)
		lo := u64(uintptr(raw_data(text)) - uintptr(raw_data(r.src)))
		if _, _, _, ok := spell.number_loose(r.src, lo, lo + u64(len(text))); !ok {
			return .Wrong_Kind
		}
		n := (^core.Number_Text)(dest)
		typed.store_string(r, {lo = lo, n = u32(len(text))}, &n.text) or_return
		n.double = core.text_f64(n.text)
	case .Hook:
		return typed.store_whole(r, fld, m, dest, .String, t.lo, t.lo + u64(t.n), cell)
	case .Maybe, .Union:
		read_cell(r, typed.field_at(u64(uintptr(fld.first))) if fld.kind == .Maybe else one_arm(r.plan, m), t, dest) or_return
		typed.mark_arm(dest, fld, m, 0)
	}
	return .None
}

// `s`, a quoted cell's inner bytes, with each `""` as one quote, in `buf`. The walk paired every quote. A word goes to
// `buf` whole and only its bytes up to a quote count, and `buf` is no shorter than `s`.
@(private)
undoubled :: proc "contextless" (buf: []u8, s: string) -> string #no_bounds_check {
	from, to := raw_data(s), raw_data(buf)
	i, out := 0, 0
	for i + 8 <= len(s) {
		word := intrinsics.unaligned_load((^u64)(from[i:]))
		intrinsics.unaligned_store((^u64)(to[out:]), word)
		x := word ~ 0x2222_2222_2222_2222
		quotes := (x - 0x0101_0101_0101_0101) & ~x & 0x8080_8080_8080_8080
		// With no branch on the quote, which a cell's text places at random. An empty mask counts eight bytes.
		k := int(intrinsics.count_trailing_zeros(quotes)) / 8
		found := int(quotes != 0)
		i += k + 2 * found
		out += k + found
	}
	for i < len(s) {
		to[out] = from[i]
		out += 1
		i += 2 if from[i] == '"' else 1
	}
	return string(buf[:out])
}

// The record of the one arm of a union that `cell_supported` passed, a `Maybe` of a wider cell.
@(private)
one_arm :: #force_inline proc "contextless" (plan: ^typed.Plan, m: ^typed.Meta) -> ^typed.Field {
	return &plan.fields[m.arms[0].fields]
}

// Binds the columns to the row's fields, the first time the read needs them: the header's when the text has one, else
// the fields in order. Returns how the walk goes on. A refused header leaves the target as it was. `from` above 0 binds
// one more column, past the `from` bound before, and refuses for that column alone, which keeps the rows read before it.
@(private, cold)
bind_columns :: #force_no_inline proc "contextless" (h: ^Cells_Of($H), regs: core.Hook_Regs, at: u64, from := 0) -> core.Action {
	context = h.r.ctx
	sp := h.r.sp
	// A header's refusal has its field alone as a path.
	h.r.sp = 1
	action := columns_of(h, regs, at, from)
	if action != .Stop || from > 0 {
		h.r.sp = sp
	}
	return action
}

// Binds the column at the cursor, past the last bound, and reads cell `t` there.
@(private, cold)
widen_columns :: #force_no_inline proc "contextless" (h: ^Cells_Of($H), regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	from := len(h.cols) - 1
	// A refused allocation leaves the columns as they were, and the cell passes.
	if action := bind_columns(h, regs, t.lo, from); action == .Stop || len(h.cols) == from + 1 {
		return regs, action
	}
	regs := regs
	regs.b = u64(uintptr(&h.cols[from]))
	return cell_cold(h, regs, &h.cols[from], t)
}

// Records column `c` as the one that reads `name` and returns the column it repeats, if any. Under `first` a repeat leaves
// the earlier column the reader of the name, else the later column takes it.
@(private)
note_column :: proc(bound: ^map[string]int, name: string, c: int, first: bool) -> (earlier: int, repeated: bool) {
	earlier, repeated = bound[name]
	if !repeated || !first {
		bound[name] = c
	}
	return
}

// Refuses a header's column, which a model's record past the one that judged the header leaves unjudged.
@(private)
refuse_header :: proc(h: ^Cells_Of($H), regs: core.Hook_Regs, kind: core.Typed_Error_Kind, at: u64, name: string) -> core.Action {
	if h.quiet && kind != .No_Memory {
		return .Next
	}
	_, action := typed.refuse(&h.r, regs, {kind = kind, at = at, steps = {0 = core.Name(name)}, n_steps = 1})
	return .Stop if action == .Stop else .Next
}

@(private)
columns_of :: proc(h: ^Cells_Of($H), regs: core.Hook_Regs, at: u64, from: int) -> core.Action {
	plan := h.r.plan
	row := h.row
	record := is_record(row)
	members := ([^]typed.Field)(row.first)[:plan.meta[row.meta].members if record else 0]
	width := max(len(h.keys), from + 1) if !h.no_header else len(members) if record else 1
	cols, failed := make([]Column, width + 1, context.temp_allocator)
	if failed != nil {
		return refuse_header(h, regs, .No_Memory, at, "")
	}
	h.cols = cols
	elem := typed.field_at(u64(uintptr(row.first)))
	cols[width].kind = .Never
	if !record && h.no_header {
		cols[0] = {kind = elem.kind, offset = elem.offset, stride = elem.stride, rec = row.first}
		return .Next
	}
	// The column that reads each name so far.
	bound := make(map[string]int, allocator = context.temp_allocator)
	defer delete(bound)
	fields := ([^]typed.Field)(row.first)
	for &col, c in cols[:width] {
		col = {kind = .Inside, step = size_of(Column)}
		if h.no_header {
			col.kind, col.offset, col.rec = members[c].kind, members[c].offset, &fields[c + 1]
			continue
		}
		// A column past the header's last is named by its position, and a refusal names it once, when it is bound.
		key := column_key(h.keys, c)
		positional, refusing := key.spelling & SPELLING_COLUMN != 0, c >= from
		name, ok := core.token_text(h.r.plan.readers, &h.r.view, key, context.temp_allocator)
		if !ok {
			return refuse_header(h, regs, .No_Memory, key.lo, "")
		}
		spelled := name if positional else inner_text(&h.r, key)
		k := -1
		for &m, i in members {
			if plan.meta[m.meta].name == name {
				k = i
				spelled = plan.meta[m.meta].name
				break
			}
		}
		if record && k < 0 && refusing {
			// A read_only member's name is refused only where the struct forbids the names it does not read.
			x := typed.extra_at(plan, row.meta)
			// A model's struct that forbids them refuses them as its schema does.
			kind := core.Typed_Error_Kind.Not_Allowed if x.forbid else .Unknown_Field if h.r.refuse_unknown else .None
			if typed.read_only_key(plan.meta[row.meta].model, name) {
				kind = .Not_Allowed if x.forbid else .None
			}
			if kind != .None && refuse_header(h, regs, kind, key.lo, spelled) == .Stop {
				return .Stop
			}
		}
		if prev, repeated := note_column(&bound, name, c, h.r.first_key); repeated {
			if h.refuse_repeats && refusing && refuse_header(h, regs, .Duplicate_Key, key.lo, spelled) == .Stop {
				return .Stop
			}
			if h.r.first_key {
				if k >= 0 {
					col.kind, col.rec, col.repeat = .Never, &fields[k + 1], true
				}
				continue
			}
			// Only a wide record holds a positional column, so the column it repeats still reads a narrower record's
			// cell, and a wide record's cell here replaces it.
			if !positional {
				cols[prev].kind, cols[prev].repeat = .Never if k >= 0 else .Inside, k >= 0
			}
		}
		if k >= 0 {
			col.kind, col.offset, col.rec = members[k].kind, members[k].offset, &fields[k + 1]
		} else if !record {
			col.kind, col.offset, col.stride, col.rec = elem.kind, elem.offset, elem.stride, row.first
			col.name, col.key = name, key
			if at := uintptr(raw_data(name)) - uintptr(raw_data(h.r.src)); at < uintptr(len(h.r.src)) {
				col.key = core.Token{lo = u64(at), n = u32(len(name))}
			}
		}
	}
	if !record {
		return .Next
	}
	end := &plan.meta[int(plan.meta[row.meta].block) + len(members)]
	required := end.required
	when H == typed.Check {
		// A partial load misses no column of a row it reads as its root, the patch of one record.
		if h.r.partial && typed.holds_set(plan, &plan.fields[0]) {
			required = nil
		}
	}
	for r in required {
		name := plan.meta[members[r].meta].name
		c, found := bound[name]
		if h.no_header {
			c, found = int(r), true
		}
		if found {
			cols[c].required = true
			continue
		}
		if from == 0 && refuse_header(h, regs, .Missing_Field, h.keys[0].lo if len(h.keys) > 0 else at, name) == .Stop {
			return .Stop
		}
		// A model's record cannot make up a column its header lacks, so the check reports the header alone.
		h.halted = H == typed.Check
	}
	if h.halted {
		return .Stop
	}
	must := false
	#reverse for &col in cols[:width] {
		must ||= col.required
		col.must = must
	}
	return .Next
}

// Where a walk's fault leaves the read. A fault in the header has no list to give the target and no path. A fault past it
// has the header refused first, and one in a row stands at the row, which keeps the cells it read, with no field to name.
@(private)
fault_position :: proc(h: ^Cells_Of($H), regs: ^core.Hook_Regs) {
	if h.cols == nil && !h.no_header {
		last := h.keys[len(h.keys) - 1] if len(h.keys) > 0 else core.Token{}
		if last.lo == 0 && last.n == 0 {
			h.r.sp = 1
		} else {
			bind_columns(h, regs^, 0)
		}
	} else if h.r.sp == row_depth(h) {
		regs.b = h.past
		if h.opens == .Object {
			h.r.frames[h.r.sp - 1].b = regs.b
		} else if !is_record(h.row) {
			// A list row closes, to be counted where it opened.
			regs^, _ = read_token(h, regs^, core.Token{kind = .End, role = .Value})
			regs.c -= u64(h.row.stride)
		}
	}
}

// The row of a plan, and whether the plan is of a list of them. A list whose elements are cells is one row.
@(private)
row_of :: proc(plan: ^typed.Plan) -> (row: ^typed.Field, listed: bool) {
	root := typed.field_at(u64(uintptr(plan.root)))
	if root.kind == .Slice || root.kind == .Dynamic {
		first := typed.field_at(u64(uintptr(root.first)))
		if !cell_supported(plan, first) {
			return first, true
		}
	}
	return root, false
}

// Why a type that is no row, or no list of rows, is refused.
@(private)
NOT_FLAT :: "CSV and TSV hold flat records, so a row is a struct, a map or a list, and a cell a scalar"

// Refuses a type no text can be made of: a row or cell of a kind this format has no spelling for.
@(private)
rows_supported :: proc(plan: ^typed.Plan) -> core.Typed_Refusal {
	row, _ := row_of(plan)
	#partial switch row.kind {
	case .Struct, .Required:
		m := &plan.meta[row.meta]
		if plan.meta[int(m.block) + int(m.members)].capture >= 0 {
			return not_flat({core.All{}})
		}
		for &f in ([^]typed.Field)(row.first)[:m.members] {
			if !cell_supported(plan, &f) {
				return not_flat({core.All{}, core.Name(plan.meta[f.meta].name)})
			}
		}
	case .Slice, .Dynamic, .Map:
		if row.kind == .Map && plan.meta[row.meta].key_kind != .String {
			return not_flat({core.All{}})
		}
		if !cell_supported(plan, typed.field_at(u64(uintptr(row.first)))) {
			return not_flat({core.All{}, core.All{}})
		}
	case:
		return not_flat({core.All{}})
	}
	return {}
}

// The refusal of a type that is no row or holds no cell, at `steps`.
@(private)
not_flat :: proc(steps: []core.Step) -> (e: core.Typed_Refusal) {
	e = {kind = .Unsupported, want = {text = NOT_FLAT}, n_steps = u8(len(steps))}
	copy(e.steps[:], steps)
	return
}

@(private)
cell_supported :: proc(plan: ^typed.Plan, f: ^typed.Field) -> bool {
	inner: ^typed.Field
	#partial switch f.kind {
	case .String, .Bool, .Bool_Wide, .I8 ..= .U64, .F32, .F64, .Enum, .Cstring, .Number_Text, .Hook:
		return true
	case .Before:
		return cell_supported(plan, &typed.extra_at(plan, f.meta).before.field)
	case .Maybe:
		inner = typed.field_at(u64(uintptr(f.first)))
	case .Union:
		m := &plan.meta[f.meta]
		if len(m.arms) != 1 {
			return false
		}
		inner = one_arm(plan, m)
	case:
		return false
	}
	return inner.kind != .Maybe && inner.kind != .Union && cell_supported(plan, inner)
}
