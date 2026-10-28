package csv

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:simd"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import core_pkg "../core"
import "../core/spell"

// Why `marshal` refused: core's `Marshal_Error_Kind`. CSV reports `Bad_Utf8` (a string or field name), `Non_Finite`,
// `Unsupported` (a root that is not a list of rows, or a cell whose type `unmarshal` cannot read),
// `Bad_Tag` (a field tag flag the format does not know), `Plan_Mismatch`, `Not_A_Member`, `Bad_Option`,
// `Unwritable` (`Quoting.None` and `.Backslash`), `Write_Failed` (`marshal_to_writer`) and `Out_Of_Memory`. It never reports `Bad_State`, `Too_Deep`, `Cycle` or `Bad_Raw`.
Marshal_Error_Kind :: core_pkg.Marshal_Error_Kind

// A refusal of `marshal`, `marshal_append`, `marshal_to_writer` or `write_record`: its kind and the path to the value
// refused, `[record].field` (`.key` for a map row, `[record][cell]` for a list row, `[cell]` for `write_record`).
// `render_error(nil, err)` writes it.
Marshal_Error :: core_pkg.Marshal_Error

// How `marshal` writes: the zero value writes RFC 4180 with a header and LF after each record.
Marshal_Opts :: struct {
	dialect:   Dialect, // `ragged` is not read
	no_header: bool,
	crlf:      bool, // CRLF after each record, as RFC 4180 writes it
	// The header's names in byte order, each record's cells under them: a struct row's field names, a document's
	// or a `Table`'s keys. A map row's keys are in byte order with or without it.
	sort_keys: bool,
}

// Write a list of rows (`marshal_list`) or a document of records (`marshal_document`) as CSV.
marshal :: proc {
	marshal_document,
	marshal_list,
}

// Write `v`, a slice or dynamic array of rows as `unmarshal` reads them, as CSV that `unmarshal` reads back into
// equal values, into a new buffer from `allocator`. Struct rows write a header of the field names, then one record
// per element. List rows write no header, and each element's cells as one record. Map rows write a header of
// every row's keys, sorted, then each row's values under them, a key it lacks an empty cell; an entry whose cell
// would be empty reads back as no entry, so it is `.Unwritable`.
//
//	- Under `Quoting.Quotes` a cell holding the delimiter, a quote, CR or LF is quoted, with each quote
//	  doubled. An empty string is `""` and reads back present. A nil `Maybe` is an empty cell.
//	- Under `Quoting.None` and `.Backslash` a cell is written unchanged. An empty string is an empty cell, which reads back
//	  absent: as the zero string, so in a `Maybe` it is `.Unwritable`. Under `.Backslash` each delimiter, CR,
//	  LF, NUL and backslash is escaped. A cell holding one the dialect cannot escape is `.Unwritable`.
//	- A first cell starting with the comment byte, a BOM at the start of the output, and a number holding the
//	  delimiter are quoted or escaped, or else `.Unwritable`.
//	- A float is its shortest round-trip digits, an enum its member's name (or, under `Plan_Opts.enums =
//	  .Int`, its integer), a bool `true` or `false`.
//
// A record that is empty, or one empty cell (a nil `Maybe`, an empty string where cells are not quoted), would be a
// blank line, which reads back as no record: `.Unwritable`. With `plan` nil the plan is this thread's cached one
// for `T`. A refusal returns a nil slice.
@(private, require_results)
marshal_list :: proc(
	v: $T,
	opts := Marshal_Opts{},
	plan: ^Type_Plan = nil,
	allocator := context.allocator,
) -> (out: []byte, err: Maybe(Marshal_Error)) where intrinsics.type_is_slice(T) || intrinsics.type_is_dynamic_array(T) {
	buf := make([dynamic]u8, allocator)
	if err = marshal_list_append(&buf, v, opts, plan); err != nil {
		delete(buf)
		return nil, err
	}
	return buf[:], nil
}

// `marshal` appended to `out` as a text of its own: the bytes already in `out` are not part of it, and the
// BOM guard applies only when `out` is empty. On a refusal `out` is as it was on entry; its capacity may have
// grown.
marshal_append :: proc {
	marshal_document_append,
	marshal_list_append,
}

// `marshal_list` appended to `out`.
@(private, require_results)
marshal_list_append :: proc(
	out: ^[dynamic]u8,
	v: $T,
	opts := Marshal_Opts{},
	plan: ^Type_Plan = nil,
) -> Maybe(Marshal_Error) where intrinsics.type_is_slice(T) || intrinsics.type_is_dynamic_array(T) {
	fault: Marshal_Error
	return core_pkg.marshal_error_of(marshal_run(out, marshal_records(v), opts, plan, {}, &fault), fault)
}

// `marshal` written to `w` as the text is made, through a buffer of about `spell.SINK_FLUSH_AT` bytes from
// `allocator`, freed before return. On a refusal `w` may already hold a prefix of the text.
@(require_results)
marshal_to_writer :: proc(
	w: io.Writer,
	v: $T,
	opts := Marshal_Opts{},
	plan: ^Type_Plan = nil,
	allocator := context.allocator,
) -> Maybe(Marshal_Error) where intrinsics.type_is_slice(T) || intrinsics.type_is_dynamic_array(T) {
	buf, aerr := make([dynamic]u8, 0, 2 * spell.SINK_FLUSH_AT, allocator)
	if aerr != nil {
		return Marshal_Error{kind = .Out_Of_Memory}
	}
	defer delete(buf)
	fault: Marshal_Error
	return core_pkg.marshal_error_of(marshal_run(&buf, marshal_records(v), opts, plan, w, &fault), fault)
}

// The list `marshal` writes, by its type and its records' bytes: `count` records `size` bytes apart from `data`.
@(private)
Marshal_Records :: struct {
	type:  typeid,
	data:  rawptr,
	count: int,
	size:  int,
}

@(private)
marshal_records :: #force_inline proc(v: $T) -> Marshal_Records {
	return {T, raw_data(v), len(v), size_of(intrinsics.type_elem_type(T))}
}

// `v` appended to `buf`, or with `to` set streamed through it. `fault` gets the path to a value refused.
@(private)
marshal_run :: proc(buf: ^[dynamic]u8, v: Marshal_Records, opts: Marshal_Opts, plan: ^Type_Plan, to: io.Writer, fault: ^Marshal_Error) -> (err: Marshal_Error_Kind) {
	w, dialect_ok := spell_writer(opts.dialect, nil, buf^)
	if !dialect_ok {
		return .Bad_Option
	}
	w.hook_text.allocator = buf.allocator
	defer delete(w.hook_text)
	tmp: Format_Plan = ---
	p, ok := plan_for(plan, v.type, &tmp)
	if !ok {
		return .Plan_Mismatch
	}
	defer plan_done(p, plan, &tmp, err == .Out_Of_Memory)
	w.plan = p
	w.fault, w.records = fault, v.data
	start := len(buf^)
	defer {
		buf^ = w.buf
		if err != .None && to.procedure == nil {
			resize(buf, start)
		}
	}
	row := row_op(p) or_return
	w.keys.allocator = buf.allocator
	defer delete(w.keys)
	defer delete(w.row, buf.allocator)
	#partial switch row.kind {
	case .Map:
		map_header(&w, v, row) or_return
	case .Struct:
		w.row = row_fields(p, p.fields[row.elem:][:row.count], opts.sort_keys, buf.allocator) or_return
	}
	switch {
	case w.quotes && w.comment == 0:
		write_chunks(&w, v, row, opts, to, true, false) or_return
	case w.quotes:
		write_chunks(&w, v, row, opts, to, true, true) or_return
	case w.comment == 0:
		write_chunks(&w, v, row, opts, to, false, false) or_return
	case:
		write_chunks(&w, v, row, opts, to, false, true) or_return
	}
	return .None
}

// The header and the records of `v`, all at once, or with `to` set in chunks of records, each written to `to`
// before the next is made. Each chunk's record count is set from the one before it to fill about
// `spell.SINK_FLUSH_AT` bytes. Out of line: inlined into its caller, its record loop compiles worse.
@(private)
write_chunks :: #force_no_inline proc(w: ^Writer, v: Marshal_Records, row: Plan_Op, opts: Marshal_Opts, to: io.Writer, $Q, $C: bool) -> Marshal_Error_Kind {
	if to.procedure == nil {
		return write_records_of(w, v, row, opts, Q, C)
	}
	chunk := 256
	for at, first := 0, true; first || at < v.count; first = false {
		hi := min(v.count, at + chunk)
		o := opts
		o.no_header ||= !first
		part := v
		part.data, part.count = rawptr(uintptr(v.data) + uintptr(at * v.size)), hi - at
		write_records_of(w, part, row, o, Q, C) or_return
		written := len(w.buf)
		// Every chunk but the last keeps its final line break in the buffer. `put_text`'s BOM guard treats an
		// empty buffer as the output's start, so the buffer must not be empty after the first chunk.
		keep := 0 if hi == v.count else 1
		if _, err := io.write_full(to, w.buf[:written - keep]); err != nil {
			return .Write_Failed
		}
		remove_range(&w.buf, 0, written - keep)
		chunk = clamp(chunk * spell.SINK_FLUSH_AT / max(written, 1), 1, 1 << 20)
		at = hi
	}
	return .None
}

// The header (unless `opts.no_header`) and the records of `v`, in a dialect that quotes cells (`$Q`) or not, with a
// comment byte (`$C`) or none. A record that writes nothing would be a blank line, which reads back as no
// record, so it is `.Unwritable`. Only a plan of fewer than two fields can write nothing, since two fields
// write a delimiter; `$N` is set for such a plan.
@(private)
write_records :: proc(w: ^Writer, v: Marshal_Records, row: Plan_Op, opts: Marshal_Opts, $Q, $C, $N: bool) -> Marshal_Error_Kind {
	// `fields` is the writer's copy, which no hook moves; each field's op is looked up in `p.ops` by index.
	p, fields := w.plan, w.row
	if !opts.no_header {
		head_at := len(w.buf)
		for f, k in fields {
			if k > 0 {
				put(w, w.delim) or_return
			}
			put_text(w, string(p.keys[f.key_lo:f.key_hi]), Q) or_return
		}
		guard_record(w, head_at) or_return
		when N {
			if len(w.buf) == head_at {
				return .Unwritable
			}
		}
		put_break(w, opts.crlf) or_return
	}
	for i in 0 ..< v.count {
		e := rawptr(uintptr(v.data) + uintptr(i * v.size))
		when C || N {
			rec_at := len(w.buf)
		}
		for &f, k in fields {
			if k > 0 {
				put(w, w.delim) or_return
			}
			if err := put_value(w, &p.ops[f.op], rawptr(uintptr(e) + f.offset), Q); err != .None {
				return refused_in_record(w, e, v.size, &f, err)
			}
		}
		when C {
			if err := guard_record(w, rec_at); err != .None {
				return refused_in_record(w, e, v.size, nil, err)
			}
		}
		when N {
			if len(w.buf) == rec_at {
				return refused_in_record(w, e, v.size, nil, .Unwritable)
			}
		}
		put_break(w, opts.crlf) or_return
	}
	return .None
}

// The path of the refusal `err` in the record at `rec`, `size` bytes each: its index in the input, then the name of
// the field `f` of the plan, when there is one. Returns `err`.
@(private = "file", cold)
refused_in_record :: #force_no_inline proc(w: ^Writer, rec: rawptr, size: int, f: ^core_pkg.Plan_Field, err: Marshal_Error_Kind) -> Marshal_Error_Kind {
	err := err
	if f != nil {
		// `f` is in `w.row`, a copy, sorted under `sort_keys`: the plan's field is the one with its key.
		for g, k in w.plan.fields {
			if g.key_lo == f.key_lo && g.key_hi == f.key_hi {
				err = core_pkg.plan_refused_at_field(w, u32(k), err)
				break
			}
		}
	}
	// A record of no bytes writes nothing, so the first one is refused: index 0.
	return core_pkg.plan_refused_at_index(w, int(uintptr(rec) - uintptr(w.records)) / max(size, 1), err)
}

// `write_records` for the plan's width, or `write_cell_rows` for a list or map row.
@(private)
write_records_of :: proc(w: ^Writer, v: Marshal_Records, row: Plan_Op, opts: Marshal_Opts, $Q, $C: bool) -> Marshal_Error_Kind {
	if row.kind != .Struct {
		return write_cell_rows(w, v, row, opts, Q)
	}
	if row.count < 2 {
		return write_records(w, v, row, opts, Q, C, true)
	}
	return write_records(w, v, row, opts, Q, C, false)
}

@(private)
Writer :: struct {
	// Its `plan`, `fault` (where a refusal's path goes, nil when only the kind is wanted) and running hook.
	using walk: core_pkg.Plan_Writer,
	buf:        [dynamic]u8,
	delim:      byte,
	comment:    byte, // 0 for none
	// An empty `buf` is the output's start, where a cell starting with a BOM would read as the text's BOM.
	at_start:   bool,
	quotes:     bool,
	escapes:    bool,
	in_numbers: bool, // the delimiter is a byte a spelled number may hold
	hook_text:  [dynamic]u8, // the text a write hook made, before it is quoted
	keys:       [dynamic]string, // a map row's header: every record's keys, sorted
	records:    rawptr, // the first record `marshal` was given

	// Per byte: `SPECIAL` when `put_text` quotes or escapes a cell holding it, `HIGH` when it is not ASCII.
	class:      [256]u8,
	// A struct row's fields in header order, a copy of the plan's (`row_fields`), sorted by name under `sort_keys`.
	row:        []core_pkg.Plan_Field,
}

@(private)
SPECIAL :: 1
@(private)
HIGH :: 2

// A writer over `plan` for `dialect` appending to `buf`. `ok` is false for a dialect the scanner refuses.
@(private)
spell_writer :: proc(dialect: Dialect, plan: ^Format_Plan, buf: [dynamic]u8) -> (w: Writer, ok: bool) {
	s := scan_setup(dialect, {}) or_return
	w = Writer{walk = {plan = plan, hook_write = hook_write}, buf = buf, delim = s.delim, quotes = .Unquoted not_in s.mode, escapes = .Escapes in s.mode, comment = s.comment, at_start = true}
	w.in_numbers = strings.index_byte("0123456789+-.eE", w.delim) >= 0
	for c in 0x80 ..< 0x100 {
		w.class[c] = HIGH
	}
	w.class[w.delim], w.class['\r'], w.class['\n'] = SPECIAL, SPECIAL, SPECIAL
	if w.quotes {
		w.class['"'] = SPECIAL
	} else {
		w.class['\\'], w.class[0] = SPECIAL, SPECIAL
	}
	return w, true
}

// Quotes the cell written from `at` when it is a number holding the delimiter. `put_text` already quotes every
// other cell that needs it.
@(private)
quote_number :: proc(w: ^Writer, at: int) -> Marshal_Error_Kind {
	n := len(w.buf) - at
	if n == 0 || w.buf[at] == '"' || strings.index_byte(string(w.buf[at:]), w.delim) < 0 {
		return .None
	}
	if !w.quotes {
		return .Unwritable
	}
	room(w, 2) or_return
	commit(w, 2)
	cell := w.buf[at:]
	copy(cell[1:], cell[:n])
	cell[0], cell[n + 1] = '"', '"'
	return .None
}

// The element's op of the plan's list: a struct whose every field one `put_cell` writes, or a list of such cells,
// or a map of string keys to them.
@(private)
row_op :: proc(p: ^Format_Plan) -> (row: Plan_Op, err: Marshal_Error_Kind) {
	root := core_pkg.plan_op_m(p, type_info_of(p.root)) or_return
	row = p.ops[p.ops[root].elem]
	#partial switch row.kind {
	case .Map:
		if p.ops[row.key].kind != .String {
			return {}, .Unsupported
		}
		fallthrough
	case .Slice, .Dynamic:
		if !is_cell(&p.base, p.ops[row.elem], p.writes) {
			return {}, .Unsupported
		}
		return row, .None
	}
	return cell_struct(p, p.ops[root].elem)
}

// A copy of the struct row's `fields`, in `allocator`, sorted by name under `sort`. The record loop walks the
// copy: a hook that compiles a new type may move `p.fields` (`Type_Plan`).
@(private)
row_fields :: proc(p: ^Format_Plan, fields: []core_pkg.Plan_Field, sort: bool, allocator: runtime.Allocator) -> ([]core_pkg.Plan_Field, Marshal_Error_Kind) {
	sorted, err := slice.clone(fields, allocator)
	if err != nil {
		return nil, .Out_Of_Memory
	}
	if !sort {
		return sorted, .None
	}
	slice.sort_by_with_data(sorted, proc(a, b: core_pkg.Plan_Field, keys: rawptr) -> bool {
		k := ([^]u8)(keys)
		return string(k[a.key_lo:a.key_hi]) < string(k[b.key_lo:b.key_hi])
	}, raw_data(p.keys))
	return sorted, .None
}

// The header of map rows: the keys of every record of `v`, each once, sorted.
@(private, cold)
map_header :: proc(w: ^Writer, v: Marshal_Records, row: Plan_Op) -> Marshal_Error_Kind {
	info := runtime.type_info_base(row.info).variant.(runtime.Type_Info_Map).map_info
	seen := make(map[string]struct{}, context.allocator)
	defer delete(seen)
	for i in 0 ..< v.count {
		m := (^runtime.Raw_Map)(uintptr(v.data) + uintptr(i * v.size))^
		ks, _, hs, _, _ := runtime.map_kvh_data_dynamic(m, info)
		for k in 0 ..< uintptr(runtime.map_cap(m)) {
			if !runtime.map_hash_is_valid(hs[k]) {
				continue
			}
			key := (^string)(runtime.map_cell_index_dynamic(ks, info.ks, k))^
			if key in seen {
				continue
			}
			if map_insert(&seen, key, struct{}{}) == nil {
				return .Out_Of_Memory
			}
			if _, err := append(&w.keys, key); err != nil {
				return .Out_Of_Memory
			}
		}
	}
	slice.sort(w.keys[:])
	return .None
}

// The header (when `row` is a map, unless `opts.no_header`) and the records of `v`, lists or maps of cells. A
// list's cells are its elements. A map's are its values under the header's keys, a key it lacks an empty cell;
// an entry whose cell is empty would read back as no entry, so it is `.Unwritable`. A record that writes nothing
// would be a blank line: `.Unwritable`.
@(private, cold)
write_cell_rows :: #force_no_inline proc(w: ^Writer, v: Marshal_Records, row: Plan_Op, opts: Marshal_Opts, $Q: bool) -> Marshal_Error_Kind {
	// A copy: a hook that compiles a new type may move `ops`.
	cell := w.plan.ops[row.elem]
	info: ^runtime.Map_Info
	if row.kind == .Map {
		info = runtime.type_info_base(row.info).variant.(runtime.Type_Info_Map).map_info
		if !opts.no_header && len(w.keys) > 0 {
			head_at := len(w.buf)
			for key, k in w.keys {
				if k > 0 {
					put(w, w.delim) or_return
				}
				put_string(w, key, Q) or_return
			}
			guard_record(w, head_at) or_return
			if len(w.buf) == head_at {
				return .Unwritable
			}
			put_break(w, opts.crlf) or_return
		}
	}
	for i in 0 ..< v.count {
		e := rawptr(uintptr(v.data) + uintptr(i * v.size))
		rec_at := len(w.buf)
		if info == nil {
			list := (^runtime.Raw_Slice)(e)^
			for k in 0 ..< list.len {
				if k > 0 {
					put(w, w.delim) or_return
				}
				if err := put_value(w, &cell, rawptr(uintptr(list.data) + uintptr(k) * uintptr(row.stride)), Q); err != .None {
					return refused_in_record(w, e, v.size, nil, core_pkg.plan_refused_at_index(w, k, err))
				}
			}
		} else {
			m := (^runtime.Raw_Map)(e)
			for &key, k in w.keys {
				if k > 0 {
					put(w, w.delim) or_return
				}
				value := runtime.__dynamic_map_get(m, info, info.key_hasher(&key, runtime.map_seed(m^)), &key)
				if value == nil {
					continue
				}
				at := len(w.buf)
				err := put_value(w, &cell, value, Q)
				if err == .None && len(w.buf) == at {
					err = .Unwritable
				}
				if err != .None {
					return refused_in_record(w, e, v.size, nil, core_pkg.plan_refused_in(w, core_pkg.Name(key), err))
				}
			}
		}
		if err := guard_record(w, rec_at); err != .None {
			return refused_in_record(w, e, v.size, nil, err)
		}
		if len(w.buf) == rec_at {
			return refused_in_record(w, e, v.size, nil, .Unwritable)
		}
		put_break(w, opts.crlf) or_return
	}
	return .None
}

// The struct op at `idx`, every field one `put_cell` writes.
@(private)
cell_struct :: proc(p: ^Format_Plan, idx: u32) -> (op: Plan_Op, err: Marshal_Error_Kind) {
	op = p.ops[idx]
	if op.kind != .Struct || op.refused {
		return {}, .Unsupported
	}
	for f in p.fields[op.elem:][:op.count] {
		if !is_cell(&p.base, p.ops[f.op], p.writes) {
			return {}, .Unsupported
		}
	}
	return
}

@(private)
Plan_Op :: core_pkg.Plan_Op

// One cell. A string, bool or number is written here, so that the record loop pays no call for it; any other kind
// goes through core's walk with CSV's cell writers, which refuse the kinds that are no cell. No value (a nil cstring,
// union or pointer) is an empty cell. `op` may point into the plan's `ops`, so it is read only before a hook runs:
// a hook that compiles a new type may move them.
@(private)
put_cell :: proc(w: ^Writer, op: ^Plan_Op, data: rawptr, $Q: bool) -> Marshal_Error_Kind {
	#partial switch op.kind {
	case .String:
		return put_string(w, (^string)(data)^, Q)
	case .Bool, .Int, .Uint, .Float:
		return put_scalar(w, op^, data, Q)
	}
	return put_other(w, op, data, Q)
}

@(private = "file")
put_string :: #force_inline proc(w: ^Writer, s: string, $Q: bool) -> Marshal_Error_Kind {
	return put_empty(w, Q) if len(s) == 0 else put_text(w, s, Q)
}

@(private = "file")
put_scalar :: #force_inline proc(w: ^Writer, op: Plan_Op, data: rawptr, $Q: bool) -> Marshal_Error_Kind {
	if op.kind == .Bool {
		return put_text(w, "true" if #force_inline core_pkg.shape_uint_load(data, op.size) != 0 else "false", Q)
	}
	p := room(w, spell.SCALAR_ROOM) or_return
	commit(w, spell.spell_scalar(p, op.kind, data, op.size) or_return)
	return .None
}

@(private = "file", cold)
put_other :: #force_no_inline proc(w: ^Writer, op: ^Plan_Op, data: rawptr, $Q: bool) -> Marshal_Error_Kind {
	return core_pkg.plan_write_value(
		w,
		op^,
		data,
		proc(w: ^Writer, idx: u32, data: rawptr) -> Marshal_Error_Kind {return put_cell(w, &w.plan.ops[idx], data, Q)},
		proc(w: ^Writer) -> Marshal_Error_Kind {return .None},
		proc(w: ^Writer, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {return put_scalar(w, op, data, Q)},
		proc(w: ^Writer, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {
			buf: [48]u8
			return put_text(w, spell.spell_u128(buf[:], (^u128)(data)^, op.kind == .Wide_Int), Q)
		},
		proc(w: ^Writer, s: string) -> Marshal_Error_Kind {return put_string(w, s, Q)},
		proc(w: ^Writer, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {
			m, v := core_pkg.plan_enum_written(w.plan, op, data) or_return
			if w.plan.opts.enums == .Int {
				p := room(w, spell.INT_ROOM) or_return
				commit(w, spell.spell_i64(p, v) if op.kind == .Enum_Int else spell.spell_u64(p, u64(v)))
				return .None
			}
			return put_text(w, string(w.plan.keys[m.lo:m.hi]), Q)
		},
		proc(w: ^Writer, arm: u32, data: rawptr, _: string) -> Marshal_Error_Kind {
			p := &w.plan.ops[arm]
			when !Q {
				// An empty cell reads back as no value, not as an empty one.
				if p.kind == .String && len((^string)(data)^) == 0 {
					return .Unwritable
				}
				if p.kind == .Hook {
					return put_hooked(w, p^, data, Q, true)
				}
			}
			return put_cell(w, p, data, Q)
		},
		proc(w: ^Writer, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {
			return put_hooked(w, op, data, Q, false)
		},
		no_cell,
		proc(w: ^Writer, op: Plan_Op, base: rawptr, n: int) -> Marshal_Error_Kind {return .Unsupported},
		no_cell,
		no_cell,
		no_cell,
	)
}

@(private = "file")
no_cell :: proc(w: ^Writer, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {
	return .Unsupported
}

// One cell written from `w.buf`'s end: the value at `data`, quoted when it is a number holding the delimiter.
@(private)
put_value :: #force_inline proc(w: ^Writer, op: ^Plan_Op, data: rawptr, $Q: bool) -> Marshal_Error_Kind {
	at := len(w.buf)
	put_cell(w, op, data, Q) or_return
	if w.in_numbers {
		quote_number(w, at) or_return
	}
	return .None
}

// The text the hook of `op` writes for the value at `data`, as one cell. An empty text is an empty string.
// When `maybe` (the value of a `Maybe`) and no cell is quoted, an empty text is `.Unwritable`.
@(private, cold)
put_hooked :: #force_no_inline proc(w: ^Writer, op: Plan_Op, data: rawptr, $Q: bool, maybe: bool) -> Marshal_Error_Kind {
	clear(&w.hook_text)
	core_pkg.plan_write_hooked(w, op, data) or_return
	text := string(w.hook_text[:])
	if len(text) == 0 {
		when !Q {
			if maybe {
				return .Unwritable
			}
		}
		return put_empty(w, Q)
	}
	return put_text(w, text, Q)
}

// `marshal_into` from a hook: the text of `value`, one cell's, into `w.hook_text`, which `put_hooked` then quotes
// as a string. A string, cstring, rune or enum name is its own text; a bool or number its spelling.
@(private = "file")
hook_write :: proc(walk: ^core_pkg.Plan_Writer, value: any) -> Marshal_Error_Kind {
	w := (^Writer)(walk)
	idx, null := core_pkg.plan_hook_value(w, value) or_return
	if null {
		return .None
	}
	op := &w.plan.ops[idx]
	text: string
	#partial switch op.kind {
	case .String:
		text = (^string)(value.data)^
	case .Cstring:
		text = string((^cstring)(value.data)^)
	case .Rune:
		r := (^rune)(value.data)^
		if !utf8.valid_rune(r) {
			return .Bad_Utf8
		}
		bytes, n := utf8.encode_rune(r)
		if _, err := append(&w.hook_text, ..bytes[:n]); err != nil {
			return .Out_Of_Memory
		}
		return .None
	case .Enum_Int, .Enum_Uint:
		if w.plan.opts.enums == .Int {
			return hook_spell(w, op, value.data)
		}
		m, _ := core_pkg.plan_enum_written(w.plan, op^, value.data) or_return
		text = string(w.plan.keys[m.lo:m.hi])
	case .Bool, .Int, .Uint, .Wide_Int, .Wide_Uint, .Float:
		return hook_spell(w, op, value.data)
	case:
		return .Unsupported
	}
	if _, err := append(&w.hook_text, text); err != nil {
		return .Out_Of_Memory
	}
	return .None
}

// A bool's or a number's spelling, as `put_cell` writes it unquoted, into `w.hook_text`.
@(private = "file")
hook_spell :: proc(w: ^Writer, op: ^Plan_Op, data: rawptr) -> Marshal_Error_Kind {
	w.buf, w.hook_text = w.hook_text, w.buf
	err := put_cell(w, op, data, false)
	w.buf, w.hook_text = w.hook_text, w.buf
	return err
}

// An empty text: `""`, or an empty cell where no cell is quoted.
@(private)
put_empty :: proc(w: ^Writer, $Q: bool) -> Marshal_Error_Kind {
	when Q {
		p := room(w, 2) or_return
		p[0], p[1] = '"', '"'
		commit(w, 2)
	}
	return .None
}

// `s` as one cell. Where cells are quoted, it is quoted when it holds the delimiter, a quote, CR or LF.
// Where they are not, `put_unquoted` writes it when it holds the delimiter, a backslash, CR or LF.
@(private)
put_text :: proc(w: ^Writer, s: string, $Q: bool) -> Marshal_Error_Kind {
	p := room(w, 2 * len(s) + 2) or_return
	special, high := scan_text(w, s, Q)
	// A BOM at the start of the output would read as the text's BOM, not the cell's.
	special |= len(w.buf) == 0 && w.at_start && core_pkg.bom_len(transmute([]byte)s) > 0
	if high && !utf8.valid_string(s) {
		return .Bad_Utf8
	}
	if !special {
		spell.copy_short(p, raw_data(s), len(s))
		commit(w, len(s))
		return .None
	}
	when !Q {
		return put_unquoted(w, s, p)
	}
	// A 16-byte window with no quote is stored whole. `p` has room for twice `s` plus two quotes, so the store
	// stays inside it however many quotes came before.
	p[0] = '"'
	src := raw_data(s)
	i, n := 0, 1
	for i + 16 <= len(s) {
		v := core_pkg.load(src[i:])
		intrinsics.unaligned_store((^core_pkg.V)(p[n:]), v)
		if !core_pkg.any_eq(v, '"') {
			i += 16
			n += 16
			continue
		}
		n = put_doubled(p, n, src, i, i + 16)
		i += 16
	}
	n = put_doubled(p, n, src, i, len(s))
	p[n] = '"'
	commit(w, n + 1)
	return .None
}

// `src[i:end]` written to `p` from `n`, each quote doubled; where the write ends.
@(private)
put_doubled :: #force_inline proc(p: [^]u8, n: int, src: [^]u8, i, end: int) -> int {
	n := n
	for k in i ..< end {
		c := src[k]
		p[n] = c
		n += 1
		if c == '"' {
			p[n] = '"'
			n += 1
		}
	}
	return n
}

// `s` as a cell of a dialect with no quotes. Under `.Backslash` each delimiter, CR, LF, NUL and backslash is
// escaped. A delimiter, CR or LF the dialect cannot escape, or a BOM at the start of the output, is
// `.Unwritable`. `p` has room for twice `s`.
@(cold, private)
put_unquoted :: proc(w: ^Writer, s: string, p: [^]u8) -> Marshal_Error_Kind {
	if len(w.buf) == 0 && w.at_start && core_pkg.bom_len(transmute([]byte)s) > 0 {
		return .Unwritable
	}
	n := 0
	for c in transmute([]byte)s {
		if c == w.delim || c == '\r' || c == '\n' || (c == '\\' || c == 0) && w.escapes {
			p[n], p[n + 1] = '\\', escape_letter(c)
			if !w.escapes || p[n + 1] == 0 {
				return .Unwritable
			}
			n += 2
		} else {
			p[n] = c
			n += 1
		}
	}
	commit(w, n)
	return .None
}

// The letter that escapes `c` after a backslash, or 0 for a byte no escape spells.
@(private)
escape_letter :: proc(c: byte) -> byte {
	switch c {
	case '\t':
		return 't'
	case '\n':
		return 'n'
	case '\r':
		return 'r'
	case '\\':
		return '\\'
	case 0:
		return '0'
	}
	return 0
}

// Makes the record written from `at`, whose first cell starts with the comment byte, read back as a record:
// quotes that cell, escapes its first byte when the comment byte is a tab, or returns `.Unwritable`. The cell
// holds nothing `put_text` quotes.
@(cold, private)
guard_comment :: proc(w: ^Writer, at: int) -> Marshal_Error_Kind {
	switch {
	case w.quotes:
		end := at
		for end < len(w.buf) && w.buf[end] != w.delim {
			end += 1
		}
		if _, err := inject_at(&w.buf, end, '"'); err != nil {
			return .Out_Of_Memory
		}
		if _, err := inject_at(&w.buf, at, '"'); err != nil {
			return .Out_Of_Memory
		}
	case w.escapes && w.comment == '\t':
		w.buf[at] = '\\'
		if _, err := inject_at(&w.buf, at + 1, 't'); err != nil {
			return .Out_Of_Memory
		}
	case:
		return .Unwritable
	}
	return .None
}

// Makes the record starting at `from` in `w.buf` read back as a record when its first cell starts with the
// comment byte (`guard_comment`).
@(private)
guard_record :: #force_inline proc(w: ^Writer, from: int) -> Marshal_Error_Kind {
	if w.comment != 0 && len(w.buf) > from && w.buf[from] == w.comment {
		return guard_comment(w, from)
	}
	return .None
}

// Whether `s` holds the delimiter, CR, LF, and a quote (under `$Q`) or a backslash or NUL (otherwise), and
// whether it holds a non-ASCII byte. A short text is read one byte at a time through `w.class`.
@(private)
scan_text :: #force_inline proc(w: ^Writer, s: string, $Q: bool) -> (special, high: bool) {
	n := len(s)
	p := raw_data(s)
	delim := w.delim
	if n < 16 {
		class: u8
		for c in transmute([]byte)s {
			class |= w.class[c]
		}
		return class & SPECIAL != 0, class & HIGH != 0
	}
	dv, qv, cv, lv := core_pkg.V(delim), core_pkg.V('"' when Q else '\\'), core_pkg.V('\r'), core_pkg.V('\n')
	// 16-byte windows, the last one overlapping the one before.
	for k := 0; ; k += 16 {
		i := min(k, n - 16)
		v := core_pkg.load(p[i:])
		m := simd.lanes_eq(v, dv) | simd.lanes_eq(v, qv) | simd.lanes_eq(v, cv) | simd.lanes_eq(v, lv)
		when !Q {
			m |= simd.lanes_eq(v, core_pkg.V(0))
		}
		special |= core_pkg.any_lane(m)
		high |= core_pkg.any_high(v)
		if i == n - 16 {
			return
		}
	}
}

@(private)
put_break :: proc(w: ^Writer, crlf: bool) -> Marshal_Error_Kind {
	p := room(w, 2) or_return
	n := 1
	if crlf {
		p[0] = '\r'
		n = 2
	}
	p[n - 1] = '\n'
	commit(w, n)
	return .None
}

@(private)
put :: #force_inline proc(w: ^Writer, c: byte) -> Marshal_Error_Kind {
	return spell.put_byte(&w.buf, c)
}

// Room for `n` more bytes past the buffer's end, whose start is returned. `commit` counts those written.
@(private)
room :: #force_inline proc(w: ^Writer, n: int) -> (p: [^]u8, err: Marshal_Error_Kind) {
	p = spell.put_reserve(&w.buf, n)
	return p, .Out_Of_Memory if p == nil else .None
}

@(private)
commit :: #force_inline proc(w: ^Writer, n: int) {
	spell.put_commit(&w.buf, n)
}
