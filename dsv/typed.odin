package dsv

// The typed read of a delimited text, over the plan and the stores of `core/typed`: `unmarshal` reads the records into a
// list of rows. A cell has no kind of its own, so it reads by its column's field, and the columns are bound to fields
// once, when the header has been read. `Cells` wraps `typed.Reader`, whose hook reads the records' open and close, and
// takes each cell before that hook sees a token.

import "base:intrinsics"
import "base:runtime"
import spell "../core/spell"
import core "../core"
import typed "../core/typed"

// Reads `src`, a text of spec `S`, into `target`, a slice or dynamic array of rows, replacing what it held, or into one
// row, which reads the first record and refuses a second as `.Wrong_Length`. A row is a struct whose fields the header
// names, a list of cells, or a map of string keys to cells. See `docs/typed.md`. The form with no plan builds one with
// `context.allocator` and frees it before it returns, and a plan built once with `plan_make` is the form for many
// reads. A refusal leaves everything the read allocated reachable from `target`.
unmarshal :: proc {unmarshal_once, unmarshal_plan}

// Builds the plan of `T` for dsv's spelling, as `typed.plan_make` does, and refuses a `T` that is no list of rows and no
// row. A write by the plan is of spec `spec` with the delimiter, comment byte, `no_header`, `crlf` and `.Ragged` of
// `opts`, and `.Bad_Option` when the spec cannot spell them. A read takes its spec and options at the call.
plan_make :: proc(T: typeid, spec := Spec.Csv, opts := Options{}, plan := typed.Plan_Options{}, allocator := context.allocator) -> (typed.Plan, core.Typed_Error) {
	return plan_as(T, as(spec, opts), plan, allocator)
}

// The spelling's `plans`.
@(private)
plan_as :: proc(T: typeid, as: core.As, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Error) {
	spec, layout := Spec(as.spec), options_of(as)
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
	p.marshal, p.node_read = marshal_text, document_read
	return p, {}
}

@(private)
unmarshal_once :: proc(src: []u8, spec: Spec, target: ^$T, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Typed_Error {
	plan, err := plan_make(T, spec)
	if err.kind != .None {
		return err
	}
	defer typed.plan_destroy(&plan)
	err = unmarshal_plan(src, spec, target, &plan, opts, read, allocator)
	typed.own_errors(&err, read.collect)
	return err
}

@(private)
unmarshal_plan :: proc(src: []u8, spec: Spec, target: ^$T, plan: ^typed.Plan, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Typed_Error {
	// Only `plan_make` checks that a type is a list of rows of cells or a row.
	if plan != nil && plan.marshal == nil && plan.err.kind == .None {
		return {kind = .Plan_Mismatch}
	}
	switch spec {
	case .Csv:   return read_text(src, .Csv, T, target, plan, opts, read, allocator)
	case .Tsv:   return read_text(src, .Tsv, T, target, plan, opts, read, allocator)
	case .Plain: return read_text(src, .Plain, T, target, plan, opts, read, allocator)
	}
	return {kind = .Bad_Option}
}

@(private)
read_text :: proc(src: []u8, $S: Spec, T: typeid, target: rawptr, plan: ^typed.Plan, opts: Options, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Error {
	h := Cells{refuse_repeats = read.dups == .Refuse}
	frames: [ROW_FRAMES]typed.Frame = ---
	regs, err := typed.read_start(&h.r, src, plan, &SPELLING, T, target, read, frames[:], allocator)
	if err.kind != .None {
		return err
	}
	h.r.as.spec = u8(S)
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

// Reads the plan's row type into `h`: the row, whether the target is one row, the token that opens a row, the register
// that names no field, and where a hot read stops short of the text's end.
@(private)
rows_of :: proc(h: ^Cells, plan: ^typed.Plan, text_len: int) {
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
row_depth :: #force_inline proc "contextless" (h: ^Cells) -> int {
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
// single read has met.
@(private)
Cells :: struct {
	r:              typed.Reader,
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
}

@(private)
is_record :: #force_inline proc "contextless" (f: ^typed.Field) -> bool {
	return f.kind == .Struct || f.kind == .Required
}

// The hook of a typed read. A role other than `Value` is a column's key, which the column table has already read, or a
// comment. The hot kinds read a cell in place, and all else, an empty cell included, fails these reads and goes to
// `cell_cold`.
@(private)
on_cell :: #force_inline proc "contextless" (h: ^Cells, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	if t.kind != .Plain {
		return row_token(h, regs, t)
	}
	if t.role != .Value {
		return regs, .Next
	}
	col := (^Column)(uintptr(regs.b))
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

// A row's open and close, and the text's. The first row's open, or the text's close when it has no row, comes after the
// header, so the columns are bound there.
@(private)
row_token :: #force_no_inline proc "contextless" (h: ^Cells, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	regs := regs
	if t.kind == .End {
		if h.r.sp == row_depth(h) {
			col := (^Column)(uintptr(regs.b))
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
		return typed.on_token(&h.r, regs, t)
	}
	if h.r.sp == 1 {
		if !h.single {
			return typed.on_token(&h.r, regs, t)
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
	regs, action = typed.on_token(&h.r, regs, token)
	if action == .Next {
		regs.b = u64(uintptr(raw_data(h.cols)))
		if h.row.kind == .Map {
			regs.a = 0
		}
	}
	return regs, action
}

// Refuses the required field the cursor stands before, at the row's end, and closes the row.
@(private, cold)
missing_cell :: #force_no_inline proc "contextless" (h: ^Cells, regs: core.Hook_Regs, col: ^Column, t: core.Token) -> (core.Hook_Regs, core.Action) {
	cols := ([^]Column)(col)
	for !cols[0].required {
		cols = cols[1:]
	}
	regs := regs
	regs.b = h.past
	name := h.r.plan.meta[typed.field_at(u64(uintptr(cols[0].rec))).meta].name
	_, action := typed.refuse(&h.r, regs, {kind = .Missing_Field, at = t.lo, steps = {0 = core.Name(name)}, n_steps = 1})
	if action == .Stop {
		return regs, action
	}
	return typed.on_token(&h.r, regs, t)
}

// A cell no hot read took: an empty cell, a kind or a spelling the hot reads leave out, a cell near the text's end, and
// the cell that needs room made for it first.
@(private, cold)
cell_cold :: #force_no_inline proc "contextless" (h: ^Cells, regs: core.Hook_Regs, col: ^Column, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = h.r.ctx
	next := regs
	next.b += u64(col.step)
	if col.kind == .String && t.spelling == core.SPELLING_DECODE | core.SPELLING_QUOTED | SPELLING_DOUBLED && regs.c < regs.a {
		if store_undoubled(h, t, uintptr(regs.c) + uintptr(col.offset)) {
			next.c += u64(col.stride)
			return next, .Next
		}
	}
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
			reason := read_cell(h, fld, t, uintptr(raw_data(scratch))) if no_scratch == nil else .No_Memory
			if reason == .None {
				return next, .Next
			}
			_, action := typed.refuse(&h.r, at, {kind = reason, at = t.lo})
			return next, action
		}
		if !h.no_header {
			// A headed row's cursor stands here past the header's last column only under `.Ragged`, at a column the row
			// binds now, named by its position.
			return widen_columns(h, regs, t)
		}
		if !h.r.refuse_unknown {
			return next, .Next
		}
		at.b = h.past
		_, action := typed.refuse(&h.r, at, {kind = .Unknown_Field, at = t.lo})
		return regs, action
	}
	map_row := h.row.kind == .Map
	if t.n == 0 {
		if col.required {
			_, action := typed.refuse(&h.r, at, {kind = .Missing_Field, at = t.lo})
			return next, action
		}
		if map_row {
			return next, .Next
		}
	}
	reason: core.Typed_Error_Kind
	if map_row {
		f := &h.r.frames[h.r.sp - 1]
		spelled := col.name if col.key.spelling & SPELLING_COLUMN != 0 else inner_text(h, col.key)
		f.extra, f.run = cast([^]u64)raw_data(spelled), (^typed.Field)(uintptr(len(spelled)))
		slot: rawptr
		slot, reason = typed.map_slot(&h.r, &h.r.plan.meta[h.row.meta], (^runtime.Raw_Map)(f.data), col.name, col.key, typed.field_at(at.b), false)
		at.c = u64(uintptr(slot))
		if reason != .None {
			_, action := typed.refuse(&h.r, at, {kind = reason, at = t.lo})
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
	} else if reason = read_cell(h, typed.field_at(at.b), t, uintptr(at.c) + uintptr(col.offset)); reason != .None {
		at, action = typed.refuse_value(&h.r, at, t, reason)
	} else {
		at.c += u64(col.stride)
	}
	if !map_row {
		next.a, next.c = at.a, at.c
	}
	return next, action
}

// Stores the text of a quoted cell holding a `""` into the string at `dest`, in memory of the read's allocator.
@(private)
store_undoubled :: proc (h: ^Cells, t: core.Token, dest: uintptr) -> bool {
	buf, err := runtime.mem_alloc_non_zeroed(int(t.n), 1)
	if err != nil {
		return false
	}
	(^string)(dest)^ = undoubled(buf, inner_text(h, t))
	return true
}

// The bytes of a cell without the quote pair of a quoted cell.
@(private)
inner_text :: #force_inline proc "contextless" (h: ^Cells, t: core.Token) -> string {
	quotes := u64(t.spelling >> 1 & 1)
	return string(h.r.src[t.lo + quotes:t.lo + u64(t.n) - quotes])
}

// Reads a present cell into the field `fld` at `dest`. A number, a bool and an enum's value read the cell's bytes,
// since what decodes to other bytes spells none of them. The rest read as a string token, whose text `Spelling.text`
// gives.
@(private)
read_cell :: proc(h: ^Cells, fld: ^typed.Field, t: core.Token, dest: uintptr) -> core.Typed_Error_Kind {
	m := &h.r.plan.meta[fld.meta]
	cell := t
	cell.kind = .String
	#partial switch fld.kind {
	case .String:
		// The walk marked it, so a `""` takes no scan and no general decode.
		if t.spelling & (SPELLING_DOUBLED | core.SPELLING_LAX) == SPELLING_DOUBLED {
			return .None if store_undoubled(h, t, dest) else .No_Memory
		}
		if t.spelling & (core.SPELLING_QUOTED | SPELLING_DOUBLED) == core.SPELLING_QUOTED && plain_quoted(h.r.src, t) {
			lo, hi := inner_span(t)
			cell = core.Token{lo = lo, n = u32(hi - lo)}
		}
		return typed.store_string(&h.r, cell, (^string)(dest))
	case .Bool, .Bool_Wide:
		text := inner_text(h, t)
		if text != "true" && text != "false" {
			return .Wrong_Kind
		}
		runtime.mem_zero(rawptr(dest), int(m.size))
		(^bool)(dest)^ = text == "true"
	case .I8 ..= .F64, .Enum:
		if fld.kind == .Enum && h.r.plan.enums != .Int {
			return typed.store_enum(&h.r, cell, m.enum_info, dest, m.size)
		}
		text := inner_text(h, t)
		lo := u64(uintptr(raw_data(text)) - uintptr(raw_data(h.r.src)))
		n, integer, _, ok := spell.number_loose(h.r.src, lo, lo + u64(len(text)))
		if !ok || !integer && fld.kind == .Enum {
			return .Wrong_Kind
		}
		if fld.kind == .Enum {
			return typed.store_enum_value(m.enum_info, n, dest, m.size)
		}
		return typed.store_number(n, integer, &h.r, core.Token{lo = lo, n = u32(len(text))}, fld, dest)
	case .Cstring:
		return typed.store_cstring(&h.r, cell, dest)
	case .Hook:
		return typed.store_whole(&h.r, fld, m, dest, .String, t.lo, t.lo + u64(t.n), cell)
	case .Maybe, .Union:
		read_cell(h, typed.field_at(u64(uintptr(fld.first))) if fld.kind == .Maybe else one_arm(h.r.plan, m), t, dest) or_return
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
bind_columns :: #force_no_inline proc "contextless" (h: ^Cells, regs: core.Hook_Regs, at: u64, from := 0) -> core.Action {
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
widen_columns :: #force_no_inline proc "contextless" (h: ^Cells, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	from := len(h.cols) - 1
	// A refused allocation leaves the columns as they were, and the cell passes.
	if action := bind_columns(h, regs, t.lo, from); action == .Stop || len(h.cols) == from + 1 {
		return regs, action
	}
	regs := regs
	regs.b = u64(uintptr(&h.cols[from]))
	return cell_cold(h, regs, &h.cols[from], t)
}

@(private)
refuse_header :: proc(h: ^Cells, regs: core.Hook_Regs, kind: core.Typed_Error_Kind, at: u64, name: string) -> core.Action {
	_, action := typed.refuse(&h.r, regs, {kind = kind, at = at, steps = {0 = core.Name(name)}, n_steps = 1})
	return .Stop if action == .Stop else .Next
}

@(private)
columns_of :: proc(h: ^Cells, regs: core.Hook_Regs, at: u64, from: int) -> core.Action {
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
		name, ok := core.token_text(h.r.plan.spelling, &h.r.view, key, context.temp_allocator)
		if !ok {
			return refuse_header(h, regs, .No_Memory, key.lo, "")
		}
		spelled := name if positional else inner_text(h, key)
		k := -1
		for &m, i in members {
			if plan.meta[m.meta].name == name {
				k = i
				spelled = plan.meta[m.meta].name
				break
			}
		}
		if record && k < 0 && h.r.refuse_unknown && refusing && refuse_header(h, regs, .Unknown_Field, key.lo, spelled) == .Stop {
			return .Stop
		}
		if prev, repeated := bound[name]; repeated {
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
		bound[name] = c
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
	for r in end.required {
		name := plan.meta[members[r].meta].name
		c, found := bound[name]
		if h.no_header {
			c, found = int(r), true
		}
		if found {
			cols[c].required = true
		} else if from == 0 && refuse_header(h, regs, .Missing_Field, h.keys[0].lo if len(h.keys) > 0 else at, name) == .Stop {
			return .Stop
		}
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
fault_position :: proc(h: ^Cells, regs: ^core.Hook_Regs) {
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
			regs^, _ = typed.on_token(&h.r, regs^, core.Token{kind = .End, role = .Value})
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
rows_supported :: proc(plan: ^typed.Plan) -> core.Typed_Error {
	row, _ := row_of(plan)
	#partial switch row.kind {
	case .Struct, .Required:
		m := &plan.meta[row.meta]
		if plan.meta[int(m.block) + int(m.members)].capture >= 0 {
			return {kind = .Unsupported, want = {text = NOT_FLAT}, steps = {0 = core.All{}}, n_steps = 1}
		}
		for &f in ([^]typed.Field)(row.first)[:m.members] {
			if !cell_supported(plan, &f) {
				return {kind = .Unsupported, want = {text = NOT_FLAT}, steps = {0 = core.All{}, 1 = core.Name(plan.meta[f.meta].name)}, n_steps = 2}
			}
		}
	case .Slice, .Dynamic, .Map:
		if row.kind == .Map && plan.meta[row.meta].key_kind != .String {
			return {kind = .Unsupported, want = {text = NOT_FLAT}, steps = {0 = core.All{}}, n_steps = 1}
		}
		if !cell_supported(plan, typed.field_at(u64(uintptr(row.first)))) {
			return {kind = .Unsupported, want = {text = NOT_FLAT}, steps = {0 = core.All{}, 1 = core.All{}}, n_steps = 2}
		}
	case:
		return {kind = .Unsupported, want = {text = NOT_FLAT}, steps = {0 = core.All{}}, n_steps = 1}
	}
	return {}
}

@(private)
cell_supported :: proc(plan: ^typed.Plan, f: ^typed.Field) -> bool {
	inner: ^typed.Field
	#partial switch f.kind {
	case .String, .Bool, .Bool_Wide, .I8 ..= .U64, .F32, .F64, .Enum, .Cstring, .Hook:
		return true
	case .Maybe:
		inner = typed.field_at(u64(uintptr(f.first)))
	case .Union:
		m := &plan.meta[f.meta]
		if len(m.arms) != 1 || m.no_nil {
			return false
		}
		inner = one_arm(plan, m)
	case:
		return false
	}
	return inner.kind != .Maybe && inner.kind != .Union && cell_supported(plan, inner)
}
