package dsv

// The typed write of a delimited text: a list of rows as records. A struct row writes a header of its field names then a
// record per element, a list row writes its cells, and a map row writes the sorted union of its keys as the header and a
// cell per key. The cell writers are the leaves of `core/write`, and the loop is dsv's own, since a record has no tree to
// walk: the plan's `marshal` is `marshal_text`, which holds the spec compiled in.

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:simd"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import spell "../core/spell"
import core "../core"
import kernel "../core/kernel"
import typed "../core/typed"
import write "../core/write"

@(private)
V :: #simd[16]u8

// The room a number's text takes, and the quotes a guard adds to it.
@(private)
CELL_ROOM :: 64
#assert(CELL_ROOM >= spell.F64_ROOM + 2 && CELL_ROOM >= spell.INT_ROOM + 2)

// The source bytes one reservation of an escaped text covers. Every byte is written as at most 2.
@(private)
SEGMENT :: 1024
#assert(2 * SEGMENT + 2 <= write.ROOM_MAX)

// Per byte, in `Rows.class`: a byte the spec quotes or escapes, and a byte past 0x7F.
@(private)
SPECIAL :: u8(1)
@(private)
HIGH :: u8(2)

// The deepest chain of hooks whose stand-ins are hooked types too.
@(private)
HOOK_DEPTH :: 8

// The least an arena block of a write holds.
@(private)
ARENA_BLOCK :: 64 * 1024

// A write's state.
@(private)
Rows :: struct {
	out:     write.Out,
	plan:    ^typed.Plan,
	opts:    Options, // `delimiter` is the byte, never 0
	spec:    Spec,
	ev, nv:  V, // what `scan_text` tests past the delimiter, CR and LF
	arena:   runtime.Arena, // what lasts the call, the hooks' allocations too
	side:    map[typeid]^typed.Plan, // the plans of the types hooks answer with
	class:   [256]u8,
	sort:    bool,
	numbers: bool, // a number's text may hold the delimiter or start with the comment byte
	words:   bool, // `true` and `false` hold neither the delimiter nor the comment byte
	depth:   int,
	dropped: int, // the cells a repeated key overwrote
	kept:    int, // the comments a document's write wrote
	width:   int, // a list row's cell count, set by the first row written, which the others keep unless `.Ragged`
	cols:    []Named, // a struct row's columns, in the order written
	keys:    []string, // a map row's columns, sorted
	headed:  bool, // the columns are bound
	omits:   ^typed.Omits, // a model's dump's, whose left-out members write empty cells
	err:     core.Typed_Refusal,
}

@(private)
Named :: struct {
	f:    ^typed.Field,
	name: string,
}

// Whether `spec` reads `layout`'s delimiter and comment byte, so a text written with them reads back. An empty text
// faults only on its options.
@(private)
layout_ok :: proc(spec: Spec, layout: Options) -> bool {
	switch spec {
	case .Csv:   return option_fault(.Csv, layout) == nil
	case .Tsv:   return option_fault(.Tsv, layout) == nil
	case .Plain: return option_fault(.Plain, layout) == nil
	}
	return false
}

// The plan's `marshal`: the value is the list of rows.
@(private)
marshal_text :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, omits: ^typed.Omits) -> ([]u8, core.Typed_Refusal) {
	spill: [write.ROOM_MAX]u8 = ---
	w: Rows
	rows_start(&w, &spill, options_of(plan.as), Spec(plan.spec), opts, stream, allocator, 0)
	w.plan, w.omits = plan, omits
	return rows_end((^Rows)(rawptr(&w)), write_rows(&w, uintptr(value)))
}

// The handle of the rows a plan writes: `spec`, and `layout`'s delimiter, comment byte, `no_header`, `crlf` and
// `.Ragged`.
@(private)
layout_as :: proc(spec: Spec, layout: Options) -> core.As {
	return as_of(&PLAN_READERS, spec, {delimiter = layout.delimiter, comment = layout.comment, no_header = layout.no_header, crlf = layout.crlf, tolerate = layout.tolerate & {.Ragged}})
}

@(private)
rows_start :: proc(w: ^Rows, spill: ^[write.ROOM_MAX]u8, layout: Options, spec: Spec, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, hint: int) {
	write.init(&w.out, spill, allocator, stream, hint)
	w.opts = layout
	w.spec = spec
	w.opts.delimiter = spec_delimiter(spec, layout.delimiter)
	w.sort = opts.sort_keys
	w.arena.backing_allocator, w.arena.minimum_block_size = context.allocator, ARENA_BLOCK
	w.side.allocator = context.allocator
	delim, comment := w.opts.delimiter, layout.comment
	for c in 0x80 ..< 0x100 {
		w.class[c] = HIGH
	}
	w.class[delim], w.class['\r'], w.class['\n'] = SPECIAL, SPECIAL, SPECIAL
	w.ev, w.nv = V(delim), V(delim)
	if spec == .Csv {
		w.class['"'] = SPECIAL
		w.ev = V('"')
	} else if spec == .Tsv {
		w.class['\\'], w.class[0] = SPECIAL, SPECIAL
		w.ev, w.nv = V('\\'), V(0)
	}
	w.numbers = strings.index_byte("0123456789+-.eE", delim) >= 0 || strings.index_byte("0123456789+-.eE", comment) >= 0
	w.words = strings.index_byte("truefals", delim) < 0 && strings.index_byte("truefals", comment) < 0
}

// Frees what a write allocated besides its output.
@(private)
rows_free :: proc(w: ^Rows) {
	runtime.arena_destroy(&w.arena)
	write.release_sides(&w.side)
}

// Ends a write: the text, or the refusal `kind` with the path `w.err` holds.
@(private)
rows_end :: proc(w: ^Rows, kind: core.Typed_Error_Kind) -> ([]u8, core.Typed_Refusal) {
	rows_free(w)
	w.err.kind = kind
	return write.finish(&w.out, w.err)
}

@(private)
total :: #force_inline proc "contextless" (w: ^Rows) -> int {
	return w.out.flushed + w.out.cursor
}

// The delimiter before a cell that is not its record's first.
@(private)
put_sep :: #force_inline proc(w: ^Rows, more: bool) {
	if more {
		write.put_byte(&w.out, w.opts.delimiter)
	}
}

// Writes the header: `names`, then the line end. A header that wrote nothing would be a blank line, and the first record
// would read as the header.
@(private)
put_header :: proc(w: ^Rows, names: []string) -> core.Typed_Error_Kind {
	start := total(w)
	for name, k in names {
		put_sep(w, k > 0)
		put_string(w, name, k == 0, false) or_return
	}
	return end_record(w, start, -1)
}

// Ends record `i`, which began at output offset `start`. A record that wrote nothing would be a blank line, which reads
// back as no record.
@(private)
end_record :: proc(w: ^Rows, start, i: int) -> core.Typed_Error_Kind {
	if total(w) == start {
		return refuse(w, .Unwritable, i)
	}
	return end_line(w)
}

// Ends a line, and returns the output's error: once it failed the cursor stops counting.
@(private)
end_line :: proc(w: ^Rows) -> core.Typed_Error_Kind {
	p := write.room(&w.out, 2)
	n := 1
	if w.opts.crlf {
		p[0] = '\r'
		n = 2
	}
	p[n - 1] = '\n'
	w.out.cursor += n
	return w.out.err
}

// The path of a refusal in record `i`, none for -1.
@(cold, private)
refuse :: proc(w: ^Rows, kind: core.Typed_Error_Kind, i: int) -> core.Typed_Error_Kind {
	w.err.n_steps = 0
	if i >= 0 {
		w.err.n_steps = 1
		w.err.steps[0] = core.Index(i)
	}
	return kind
}

// The path of a refusal in cell `step` of record `i`. A name is copied, since the plan ends with the call.
@(cold, private)
refuse_in :: proc(w: ^Rows, kind: core.Typed_Error_Kind, i: int, step: core.Step) -> core.Typed_Error_Kind {
	step := step
	if name, named := step.(core.Name); named {
		step = core.Name(strings.clone(string(name), context.temp_allocator))
	}
	refuse(w, kind, i)
	w.err.steps[w.err.n_steps] = step
	w.err.n_steps += 1
	return kind
}

@(private)
write_rows :: proc(w: ^Rows, value: uintptr) -> core.Typed_Error_Kind {
	row, listed := row_of(w.plan)
	list := runtime.Raw_Slice{rawptr(value), 1}
	if listed {
		list = (^runtime.Raw_Slice)(value)^
	}
	write_header(w, row, list) or_return
	return write_list(w, row, list, true)
}

// Binds the columns of `row` and writes the header: a struct row's field names in order, or a map row's sorted union of
// the keys of `list`'s rows. A list row has no header.
@(private)
write_header :: proc(w: ^Rows, row: ^typed.Field, list: runtime.Raw_Slice, named := true) -> core.Typed_Error_Kind {
	w.headed = true
	pl := w.plan
	scratch := runtime.arena_allocator(&w.arena)
	#partial switch row.kind {
	case .Struct, .Required:
		members := ([^]typed.Field)(row.first)[:pl.meta[row.meta].members]
		cols, failed := make([]Named, len(members), scratch)
		names, no_names := make([]string, len(members), scratch)
		if failed != nil || no_names != nil {
			return .No_Memory
		}
		for &f, k in members {
			cols[k] = {&f, pl.meta[f.meta].name}
		}
		if w.sort {
			slice.sort_by(cols, proc(a, b: Named) -> bool {return a.name < b.name})
		}
		w.cols = cols
		if named && !w.opts.no_header {
			for c, k in cols {
				names[k] = c.name
			}
			return put_header(w, names)
		}
	case .Map:
		// The reader names a map row's keys from the header, so a text without one is not read back.
		if w.opts.no_header {
			return .Unsupported
		}
		info := pl.meta[row.meta].map_info
		keys := make([dynamic]string, scratch)
		seen := make(map[string]struct{}, scratch)
		for i in 0 ..< list.len {
			m := (^runtime.Raw_Map)(uintptr(list.data) + uintptr(i) * uintptr(row.stride))^
			ks, _, hs, _, _ := runtime.map_kvh_data_dynamic(m, info)
			for k in 0 ..< uintptr(runtime.map_cap(m)) {
				if !runtime.map_hash_is_valid(hs[k]) {
					continue
				}
				key := (^string)(runtime.map_cell_index_dynamic(ks, info.ks, k))^
				if key in seen {
					continue
				}
				_, _, _, no_seen := map_entry(&seen, key)
				_, no_key := append(&keys, key)
				if no_seen != nil || no_key != nil {
					return .No_Memory
				}
			}
		}
		slice.sort(keys[:])
		w.keys = keys[:]
		if named && len(keys) > 0 {
			return put_header(w, w.keys)
		}
	}
	return .None
}

// Writes the rows of `list` by the columns `write_header` bound, as records `0 ..< list.len`, or as no record a path
// names when `indexed` is false, as a record write's row is. A member a dump's `omits` leaves out writes an empty cell,
// so the row keeps the header's columns. A map row writes a cell per header key, an empty one where
// the row lacks it, and refuses a key the header lacks. A cell that is present and empty would read back as no entry, so
// it is refused too. A list row whose cell count differs from the first row's is `.Wrong_Length` unless `.Ragged`, since
// a read without it refuses the row.
@(private)
write_list :: proc(w: ^Rows, row: ^typed.Field, list: runtime.Raw_Slice, indexed: bool) -> core.Typed_Error_Kind {
	pl := w.plan
	#partial switch row.kind {
	case .Struct, .Required:
		cols := w.cols
		for i in 0 ..< list.len {
			start := total(w)
			e := uintptr(list.data) + uintptr(i) * uintptr(row.stride)
			for c, k in cols {
				put_sep(w, k > 0)
				at := e + uintptr(c.f.offset)
				if c.f.omit && w.omits != nil && w.omits.call(w.omits, pl, c.f, at) {
					continue
				}
				if kind := write_cell(w, pl, c.f, at, k == 0, false); kind != .None {
					return refuse_in(w, kind, i if indexed else -1, core.Name(c.name))
				}
			}
			end_record(w, start, i if indexed else -1) or_return
		}
	case .Slice, .Dynamic:
		cell := typed.field_at(u64(uintptr(row.first)))
		for i in 0 ..< list.len {
			start := total(w)
			inner := (^runtime.Raw_Slice)(uintptr(list.data) + uintptr(i) * uintptr(row.stride))^
			if w.width != 0 && inner.len != w.width && .Ragged not_in w.opts.tolerate {
				return refuse(w, .Wrong_Length, i if indexed else -1)
			}
			for k in 0 ..< inner.len {
				put_sep(w, k > 0)
				if kind := write_cell(w, pl, cell, uintptr(inner.data) + uintptr(k) * uintptr(cell.stride), k == 0, false); kind != .None {
					return refuse_in(w, kind, i if indexed else -1, core.Index(k))
				}
			}
			end_record(w, start, i if indexed else -1) or_return
			w.width = inner.len
		}
	case .Map:
		info := pl.meta[row.meta].map_info
		cell := typed.field_at(u64(uintptr(row.first)))
		for i in 0 ..< list.len {
			start := total(w)
			m := (^runtime.Raw_Map)(uintptr(list.data) + uintptr(i) * uintptr(row.stride))
			found := 0
			for &key, k in w.keys {
				put_sep(w, k > 0)
				value := runtime.__dynamic_map_get(m, info, info.key_hasher(&key, runtime.map_seed(m^)), &key)
				if value == nil {
					continue
				}
				found += 1
				at := total(w)
				kind := write_cell(w, pl, cell, uintptr(value), k == 0, false)
				if kind == .None && total(w) == at {
					kind = .Unwritable
				}
				if kind != .None {
					return refuse_in(w, kind, i if indexed else -1, core.Name(key))
				}
			}
			if found < int(m.len) {
				return refuse(w, .Unwritable, i if indexed else -1)
			}
			end_record(w, start, i if indexed else -1) or_return
		}
	}
	return .None
}

// One row of a record write, by a plan of the row's type, which must be of the writer's layout. The first row binds the
// columns and writes the header, unless the caller already wrote the head of the text, and every row after it takes the
// same plan. What hooks allocate lasts the row.
@(private)
token_record :: proc(t: ^write.Tokens, plan: ^typed.Plan, value: rawptr, err: ^core.Typed_Refusal) -> core.Typed_Error_Kind {
	w := (^Rows)(t.state)
	row, listed := row_of(plan)
	if listed || w.plan != nil && w.plan != plan || plan.as != layout_as(w.spec, w.opts) {
		err^ = {kind = .Plan_Mismatch}
		return .Plan_Mismatch
	}
	w.plan = plan
	temp := runtime.arena_temp_begin(&w.arena)
	first := !w.headed
	kind := write_header(w, row, {value, 1}, t.mark == 0) if first else .None
	if kind == .None {
		kind = write_list(w, row, {value, 1}, false)
	}
	if first && kind == .None {
		runtime.arena_temp_ignore(temp)
		return .None
	}
	runtime.arena_temp_end(temp)
	if kind != .None {
		// The header goes with a refused first row, which the record writer takes back when it can, and the plan with it.
		if first {
			w.headed, w.plan = false, nil
		}
		err^ = w.err
		err.kind, err.cause = kind, w.out.cause
	}
	return kind
}

// One cell. The kinds a row is made of are written in line, and `write_other` takes the rest: its frame is large, and a
// call that pays for it on every number is slower than the number's own work.
@(private)
write_cell :: #force_inline proc(w: ^Rows, pl: ^typed.Plan, f: ^typed.Field, v: uintptr, first, inner: bool) -> core.Typed_Error_Kind #no_bounds_check {
	#partial switch f.kind {
	case .String:
		return put_string(w, (^string)(v)^, first, inner)
	case .I8 ..= .U64:
		p := write.room(&w.out, CELL_ROOM)
		return put_number(w, p, write.int_text(p, f.kind, v), first)
	case .F64:
		x := (^f64)(v)^
		if x - x != 0 {
			return .Non_Finite
		}
		p := write.room(&w.out, CELL_ROOM)
		return put_number(w, p, spell.f64_text(p, x), first)
	case .Bool:
		return put_word(w, (^bool)(v)^, first)
	}
	return write_other(w, pl, f, v, first, inner)
}

// The cell of a kind that is not common in a row. A kind that is no cell is `.Unsupported`, and a nil `Maybe`, union or
// cstring is an empty cell. `inner` says the value is the content of a `Maybe` or union, where a spec that has no empty
// string for it refuses an empty text.
@(private)
write_other :: #force_no_inline proc(w: ^Rows, pl: ^typed.Plan, f: ^typed.Field, v: uintptr, first, inner: bool) -> core.Typed_Error_Kind #no_bounds_check {
	out := &w.out
	#partial switch f.kind {
	case .F32:
		x := (^f32)(v)^
		if x - x != 0 {
			return .Non_Finite
		}
		p := write.room(out, CELL_ROOM)
		return put_number(w, p, spell.f32_text(p, x), first)
	case .Bool_Wide:
		return put_word(w, write.loaded(v, int(pl.meta[f.meta].size)) != 0, first)
	case .Cstring:
		if cs := (^cstring)(v)^; cs != nil {
			return put_string(w, string(cs), first, inner)
		}
	case .Enum:
		info := pl.meta[f.meta].enum_info
		p := write.room(out, CELL_ROOM)
		name := write.enum_spelled(pl, info, write.enum_value(info, v), p) or_return
		if typed.enum_by_number(pl, info) {
			return put_number(w, p, len(name), first)
		}
		return put_string(w, name, first, inner)
	case .Maybe:
		if (^bool)(v + uintptr(pl.meta[f.meta].tag))^ {
			return write_cell(w, pl, typed.field_at(u64(uintptr(f.first))), v, first, true)
		}
	case .Union:
		if arm := write.union_arm(&pl.meta[f.meta], v); arm != nil {
			return write_cell(w, pl, &pl.fields[arm.fields], v, first, true)
		}
	case .Hook:
		return put_hooked(w, pl, f, v, first, inner)
	case .Number_Text:
		// The empty text, a null, is an empty cell.
		text := (^core.Number_Text)(v).text
		p := write.room(out, len(text) + 2)
		intrinsics.mem_copy(p, raw_data(text), len(text))
		return put_number(w, p, len(text), first)
	case:
		return .Unsupported
	}
	return .None
}

// The stand-in of a hook is written as a value of its own type, by a plan built for this call.
@(private)
put_hooked :: proc(w: ^Rows, pl: ^typed.Plan, f: ^typed.Field, v: uintptr, first, inner: bool) -> core.Typed_Error_Kind {
	hook := pl.meta[f.meta].write
	if hook == nil {
		return .Unsupported
	}
	data := typed.extra_at(pl, f.meta).data
	context.user_ptr = data if data != nil else context.user_ptr
	a, kind := hook(rawptr(v), runtime.arena_allocator(&w.arena))
	if kind != .None {
		return kind
	}
	if a.id == nil || a.data == nil {
		return .None
	}
	if w.depth == HOOK_DEPTH {
		return .Too_Deep
	}
	side := write.side_plan(&w.side, pl, a.id) or_return
	w.depth += 1
	kind = write_cell(w, side, &side.fields[0], uintptr(a.data), first, inner)
	w.depth -= 1
	return kind
}

// A number's text, which `p` holds and the cursor has not passed.
@(private)
put_number :: #force_inline proc(w: ^Rows, p: [^]u8, n: int, first: bool) -> core.Typed_Error_Kind {
	if w.numbers {
		return guard_number(w, p, n, first)
	}
	w.out.cursor += n
	return .None
}

// A number that holds the delimiter or starts a record with the comment byte is quoted, or refused where the spec has no
// quotes.
@(cold, private)
guard_number :: proc(w: ^Rows, p: [^]u8, n: int, first: bool) -> core.Typed_Error_Kind {
	n := n
	if strings.index_byte(string(p[:n]), w.opts.delimiter) >= 0 || first && w.opts.comment != 0 && p[0] == w.opts.comment {
		if w.spec != .Csv {
			return .Unwritable
		}
		intrinsics.mem_copy(p[1:], p, n)
		p[0], p[n + 1] = '"', '"'
		n += 2
	}
	w.out.cursor += n
	return .None
}

// `true` or `false`, which are quoted only where the delimiter or the comment byte is one of their letters.
@(private)
put_word :: proc(w: ^Rows, yes: bool, first: bool) -> core.Typed_Error_Kind {
	if w.words {
		// Stored whole under a reservation of 8, and the cursor passes the 4 or 5 bytes that count.
		word := transmute(u64)[8]u8{'f', 'a', 'l', 's', 'e', 0, 0, 0}
		if yes {
			word = transmute(u64)[8]u8{'t', 'r', 'u', 'e', 0, 0, 0, 0}
		}
		intrinsics.unaligned_store((^u64)(write.room(&w.out, 8)), word)
		w.out.cursor += 5 - int(yes)
		return .None
	}
	return put_string(w, "true" if yes else "false", first, false)
}

// `s` as one cell. Under CSV it is quoted when it holds the delimiter, a quote, CR or LF, when it starts a record with the
// comment byte, or when it starts the output with a BOM, which would read as the text's. Under TSV those are escaped, and
// under Plain they are refused. An empty string is `""` under CSV, and under the others an empty cell, which inside a
// `Maybe` or a union would read back as no value, so it is refused there.
@(private)
put_string :: proc(w: ^Rows, s: string, first, inner: bool) -> core.Typed_Error_Kind {
	out := &w.out
	if len(s) == 0 {
		if w.spec != .Csv {
			return .Unwritable if inner else .None
		}
		p := write.room(out, 2)
		p[0], p[1] = '"', '"'
		out.cursor += 2
		return .None
	}
	if put_plain_cell(w, s, first) {
		return .None
	}
	special, high := scan_text(w, s)
	bom := false
	if high {
		if !utf8.valid_string(s) {
			return .Invalid_Utf8
		}
		bom = out.cursor == 0 && out.flushed == 0 && strings.has_prefix(s, "\xEF\xBB\xBF")
	}
	marked := first && w.opts.comment != 0 && s[0] == w.opts.comment
	if !special && !marked && !bom {
		write.put_text(out, s)
		return .None
	}
	return put_guarded(w, s, marked, bom)
}

// A string cell of a text read back with `infer`. One that would read back as a number, true or false is quoted, or
// refused where the spec has no quotes.
@(cold, private)
put_inferred_string :: proc(w: ^Rows, s: string, first: bool) -> core.Typed_Error_Kind {
	if s != "true" && s != "false" {
		if _, is_number := spell.number_strict(transmute([]u8)s, 0, u64(len(s))); !is_number {
			return put_string(w, s, first, false)
		}
	}
	if w.spec != .Csv {
		return .Unwritable
	}
	return put_guarded(w, s, false, false)
}

// A number cell by its text, which must be a JSON number.
@(cold, private)
put_number_literal :: proc(w: ^Rows, s: string, first: bool) -> core.Typed_Error_Kind {
	if _, is_number := spell.number_strict(transmute([]u8)s, 0, u64(len(s))); !is_number {
		return .Bad_Raw
	}
	if !w.numbers {
		write.put_text(&w.out, s)
		return .None
	}
	if strings.index_byte(s, w.opts.delimiter) < 0 && !(first && w.opts.comment != 0 && s[0] == w.opts.comment) {
		write.put_text(&w.out, s)
		return .None
	}
	return put_guarded(w, s, true, false) if w.spec == .Csv else .Unwritable
}

// The longest cell `put_plain_cell` copies under one reservation.
@(private)
PLAIN_MAX :: write.ROOM_MAX - 16

// Copies `s` while it tests it and returns true, or returns false with the cursor unmoved when it holds a byte that asks
// for more: one the spec quotes or escapes, one past 0x7F, or a comment byte that starts a record. A cell under 16 bytes
// takes one load, and a longer one 16-byte blocks, the last overlapping the one before.
@(private)
put_plain_cell :: #force_inline proc(w: ^Rows, s: string, first: bool) -> bool #no_bounds_check {
	n := len(s)
	src := raw_data(s)
	if n > PLAIN_MAX || first && w.opts.comment != 0 && src[0] == w.opts.comment {
		return false
	}
	dv, cv, lv := V(w.opts.delimiter), V('\r'), V('\n')
	stop :: #force_inline proc "contextless" (v, dv, ev, nv, cv, lv: V) -> V {
		return simd.lanes_eq(v, dv) | simd.lanes_eq(v, ev) | simd.lanes_eq(v, nv) | simd.lanes_eq(v, cv) | simd.lanes_eq(v, lv) | simd.lanes_ge(v, V(0x80))
	}
	p := write.room(&w.out, n + 16)
	if n < 16 {
		v, live, ok := kernel.head16(src, n)
		if !ok || kernel.any_lane16(stop(v, dv, w.ev, w.nv, cv, lv) & live) {
			return false
		}
		intrinsics.unaligned_store((^V)(p), v)
		w.out.cursor += n
		return true
	}
	for k := 0; k < n - 16; k += 16 {
		v := intrinsics.unaligned_load((^V)(src[k:]))
		if kernel.any_lane16(stop(v, dv, w.ev, w.nv, cv, lv)) {
			return false
		}
		intrinsics.unaligned_store((^V)(p[k:]), v)
	}
	v := intrinsics.unaligned_load((^V)(src[n - 16:]))
	if kernel.any_lane16(stop(v, dv, w.ev, w.nv, cv, lv)) {
		return false
	}
	intrinsics.unaligned_store((^V)(p[n - 16:]), v)
	w.out.cursor += n
	return true
}

// The cell that needs quotes or escapes.
@(cold, private)
put_guarded :: proc(w: ^Rows, s: string, marked, bom: bool) -> core.Typed_Error_Kind {
	switch w.spec {
	case .Csv:
		// A cell that fits one segment takes one reservation, so the cursor moves once.
		quote := V('"')
		for rest, open := s, true; ; open = false {
			take := min(len(rest), SEGMENT)
			p := write.room(&w.out, 2 * take + 2)
			src := raw_data(rest)
			i, n := 0, 0
			if open {
				p[0] = '"'
				n = 1
			}
			// A 16-byte block with no quote is stored whole, and `p` holds twice `take`, so the store stays inside it.
			for i + 16 <= take {
				v := intrinsics.unaligned_load((^V)(src[i:]))
				intrinsics.unaligned_store((^V)(p[n:]), v)
				if kernel.any_lane16(simd.lanes_eq(v, quote)) {
					n = put_doubled(p, n, src, i, i + 16)
				} else {
					n += 16
				}
				i += 16
			}
			n = put_doubled(p, n, src, i, take)
			rest = rest[take:]
			if len(rest) == 0 {
				p[n] = '"'
				w.out.cursor += n + 1
				return .None
			}
			w.out.cursor += n
		}
	case .Tsv:
		// A first byte equal to a tab comment is spelled `\t`, and no other comment byte can be escaped.
		if bom || marked && w.opts.comment != '\t' {
			return .Unwritable
		}
		rest := s
		if marked {
			write.put_text(&w.out, `\t`)
			rest = s[1:]
		}
		for len(rest) > 0 {
			take := min(len(rest), SEGMENT)
			p := write.room(&w.out, 2 * take)
			n := 0
			for c in transmute([]u8)rest[:take] {
				if c == w.opts.delimiter || c == '\r' || c == '\n' || c == '\\' || c == 0 {
					letter := escape_letter(c)
					if letter == 0 {
						return .Unwritable
					}
					p[n], p[n + 1] = '\\', letter
					n += 2
				} else {
					p[n] = c
					n += 1
				}
			}
			w.out.cursor += n
			rest = rest[take:]
		}
		return .None
	case .Plain:
	}
	return .Unwritable
}

// `src[i:end]` written to `p` from `n`, each quote doubled. Where the write ends.
@(private)
put_doubled :: proc(p: [^]u8, n: int, src: [^]u8, i, end: int) -> int #no_bounds_check {
	n := n
	for k in i ..< end {
		p[n] = src[k]
		n += 1
		if src[k] == '"' {
			p[n] = '"'
			n += 1
		}
	}
	return n
}

// The letter that follows a backslash to spell `c`, 0 for a byte no escape spells.
@(private)
escape_letter :: proc "contextless" (c: u8) -> u8 {
	for k in 0 ..< len(TSV_ESCAPED) {
		if TSV_ESCAPED[k] == c {
			return TSV_LETTERS[k]
		}
	}
	return 0
}

// The bytes a TSV cell writes as a backslash and a letter, and their letters in the same order.
@(private, rodata)
TSV_ESCAPED := [?]u8{'\t', '\n', '\r', '\\', 0}
@(private, rodata)
TSV_LETTERS := [?]u8{'t', 'n', 'r', '\\', '0'}

// Whether `s` holds a byte `put_guarded` changes, and whether it holds one past 0x7F. A text under 16 bytes goes through
// the byte classes, and a longer one by 16-byte blocks, the last overlapping the one before.
@(private)
scan_text :: #force_inline proc(w: ^Rows, s: string) -> (special, high: bool) #no_bounds_check {
	n := len(s)
	p := raw_data(s)
	if n < 16 {
		class: u8
		for c in transmute([]u8)s {
			class |= w.class[c]
		}
		return class & SPECIAL != 0, class & HIGH != 0
	}
	dv, cv, lv := V(w.opts.delimiter), V('\r'), V('\n')
	ev, nv := w.ev, w.nv
	hits, bits: V
	for k := 0; ; k += 16 {
		i := min(k, n - 16)
		v := intrinsics.unaligned_load((^V)(p[i:]))
		m := simd.lanes_eq(v, dv) | simd.lanes_eq(v, ev) | simd.lanes_eq(v, cv) | simd.lanes_eq(v, lv) | simd.lanes_eq(v, nv)
		hits |= m
		bits |= v
		if i == n - 16 {
			return kernel.any_lane16(hits), kernel.any_lane16(simd.lanes_ge(bits, V(0x80)))
		}
	}
}

// The token write of a delimited text: a scalar call is a cell, written by the rules of the typed write.
@(private, rodata)
TOKENS := write.Token_Spelling {
	start  = tokens_start,
	value  = token_cell,
	line   = proc(t: ^write.Tokens) -> core.Typed_Error_Kind {
		w := (^Rows)(t.state)
		return end_line(w) if total(w) != t.mark else .Unwritable
	},
	stop   = proc(t: ^write.Tokens) {
		if w := (^Rows)(t.state); w != nil {
			rows_free(w)
			free(w, t.base.allocator)
		}
	},
	record = token_record,
}

// Writes the delimiter if a cell came before in the record, then the cell `v`.
@(private)
token_cell :: proc(t: ^write.Tokens, v: write.Scalar) -> core.Typed_Error_Kind {
	w := (^Rows)(t.state)
	put_sep(w, !t.first)
	switch x in v {
	case string:
		if w.opts.infer {
			return put_inferred_string(w, x, t.first)
		}
		return put_string(w, x, t.first, false)
	case core.Number:
		p := write.room(&w.out, CELL_ROOM)
		size, kind := write.number_text(p, x)
		return kind if kind != .None else put_number(w, p, size, t.first)
	case write.Number_Literal:
		return put_number_literal(w, x.text, t.first)
	case write.Tree_Part:
		if x != .Null {
			return put_word(w, x == .True, t.first)
		}
	}
	return .None
}

// Sets up the rows of a token write, which `Tokens.state` holds and `Tokens.out` points into.
@(private)
tokens_start :: proc(t: ^write.Tokens, as: core.As) -> core.Typed_Error_Kind {
	spec, layout := Spec(as.spec), options_of(as)
	if !layout_ok(spec, layout) {
		return .Bad_Option
	}
	w, err := new(Rows, t.base.allocator)
	if err != nil {
		return .No_Memory
	}
	rows_start(w, &t.spill, layout, spec, t.opts, t.base.stream, t.base.allocator, 0)
	t.state, t.out = w, &w.out
	return .None
}
