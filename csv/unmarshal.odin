package csv

import "base:intrinsics"
import "base:runtime"
import core_pkg "../core"

// What `unmarshal` does with a column the struct does not name. `.Ignore` checks its cells as CSV and does not
// read them. `.Refuse` refuses it with `.Unknown_Field` at its header cell.
Unknown_Fields :: core_pkg.Unknown_Fields

// What `unmarshal` does with a header name that two columns share: core's `Duplicates`.
//
//	.Default  `.Last`
//	.Refuse   `.Duplicate_Key` at the second column's header cell
//	.First    the first column fills the field, the later ones are read as unknown columns
//	.Last     the last column fills the field, the earlier ones are read as unknown columns
//	.All      every column fills the field in order, so the last one's cell stays and each is judged as
//	          the field's type
Duplicates :: core_pkg.Duplicates

// How `unmarshal` and `unmarshal_check` read: the zero value reads RFC 4180 with a header, judges every byte,
// keeps the last of a repeated header name, ignores unknown columns and copies strings. Of the `Read_Opts` fields:
//
//	strictness  `.Lazy` judges the UTF-8 of the header and of every cell a field reads, and of no other cell.
//	duplicates  which column a repeated header name fills. A column the field does not take is read as unknown,
//	            but `unknown_fields = .Refuse` refuses only a name the struct lacks.
//	no_header   the first record is data: column k is the struct's field k, and columns past its last field
//	            are unknown.
//
// `borrow_strings` slices `src` for a string with no `""` or escape.
Unmarshal_Opts :: core_pkg.Unmarshal_Opts(Read_Opts)

// What `unmarshal` refused. The kinds are shared with JSON. A cell's fault is at the cell, with path
// `[row].field`, the row counted from the first record after the header. A header's fault has the field alone
// as its path.
Unmarshal_Error_Kind :: core_pkg.Unmarshal_Error_Kind
Unmarshal_Error :: core_pkg.Unmarshal_Error

// Read the records of `src` into `ptr^`, a slice or dynamic array of rows: one element per record from index
// zero, replacing what `ptr^` held. A row is
//
//	- a struct, whose fields the header names (`csv:"name"`, or the field's own name).
//	- a slice or dynamic array of one cell type (`[]string`, `[]Maybe(string)`, ...). Every record is a row, the
//	  first too, and each of its cells an element: `no_header` and `unknown_fields` are not read. A refused
//	  cell's path is `[row][cell]`.
//	- a map of `string` keys to one cell type (`map[string]string`, ...). The header's names are the keys, and a
//	  record's absent cell is no entry; `duplicates` is read as for a struct's fields, and `no_header` is
//	  `.Unsupported`. A refused cell's path is `[row].name`.
//
// Cells:
//
//	- An unquoted empty cell is absent: its field keeps its zero value, or is `.Missing_Field` when tagged
//	  `csv:",required"`. A required field no column names is `.Missing_Field` at the header. A quoted `""` is
//	  a present empty text. Where cells are not quoted every empty cell is absent. In a `ragged` dialect a record's
//	  cells past the header's are unknown columns, and the cells it lacks are absent.
//	- A field reads the cell's text (`field_text`): a quoted cell without its quotes and with each `""` as one
//	  quote, an escaped cell with each escape as the byte it spells. It accepts
//	  `true` or `false` into a bool, `[+-]?digits` into an integer (`.Out_Of_Range` when it does not fit),
//	  a decimal (`1.5`, `.5` or `1.`, with an optional exponent) into an f32 or f64, an enum's member name (or, under
//	  `Plan_Opts.enums = .Int`, its integer), one code point into a rune, any text into a string. Other text is
//	  `.Wrong_Kind`.
//	- A `Maybe` of one of those is set when its cell is present.
//
// A refusal before reading starts (`.Bad_Option`, `.Plan_Mismatch`, `.Bad_Tag`, `.Unsupported` for a field of any other
// type, `.Out_Of_Memory` lowering the plan) leaves `ptr^` untouched. A later refusal leaves the records read
// before it, the refused one last. Everything is allocated from `allocator` and nothing is freed, so read into
// an arena and free it whole. With `plan` nil the plan is this thread's cached one for `T`.
//
// A `^Record_Read` reads one row at a time, the same way, and says whether there was one: `more` is false once
// no row is left, with `err` nil at the input's end (see `Record_Read`).
unmarshal :: proc {
	unmarshal_records,
	unmarshal_record,
}

@(private, require_results)
unmarshal_records :: proc(
	src: []byte,
	ptr: ^$T,
	opts := Unmarshal_Opts{},
	plan: ^Type_Plan = nil,
	allocator: runtime.Allocator,
) -> (err: Maybe(Unmarshal_Error)) where intrinsics.type_is_slice(T) || intrinsics.type_is_dynamic_array(T) {
	if ptr == nil {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	return read_records(src, ptr, T, opts, plan, allocator, false)
}

@(private, require_results)
unmarshal_record :: proc(rd: ^Record_Read, ptr: ^$T) -> (more: bool, err: Maybe(Unmarshal_Error)) {
	return core_pkg.unmarshal(rd, ptr)
}

// Whether `src` reads as a `T` under `opts`, with the same checks and results as `unmarshal` except that no
// hook runs. It keeps nothing: each record is read into one scratch element. Whatever the input's size, it
// allocates only that element, one record's fields, the column table, and the plan when `plan` is nil.
@(require_results)
unmarshal_check :: proc(
	src: []byte,
	$T: typeid,
	opts := Unmarshal_Opts{},
	plan: ^Type_Plan = nil,
) -> (err: Maybe(Unmarshal_Error)) where intrinsics.type_is_slice(T) || intrinsics.type_is_dynamic_array(T) {
	return read_records(src, (^T)(nil), T, opts, plan, runtime.nil_allocator(), true)
}

// `unmarshal` into `ptr^` (a `P` whose element is the record), or with `CHECK` into a scratch element
// and no `ptr`. A record is a struct, a list of cells (`LIST_ROW`, each record one) or a map of cells (`MAP_ROW`).
@(private)
read_records :: proc(
	src: []byte,
	ptr: ^$P,
	root: typeid,
	opts: Unmarshal_Opts,
	plan: ^Type_Plan,
	allocator: runtime.Allocator,
	$CHECK: bool,
) -> (err: Maybe(Unmarshal_Error)) {
	E :: intrinsics.type_elem_type(P)
	MAP_ROW :: intrinsics.type_is_map(E)
	LIST_ROW :: intrinsics.type_is_slice(E) || intrinsics.type_is_dynamic_array(E)
	// Under `.Lazy` the scan finds the UTF-8 faults, and only those in cells a field reads are refused
	// (`judge_utf8`).
	s, dialect_ok := scan_setup(opts.dialect, opts.limits, .Structural if opts.strictness == .Structural else .Strict)
	if !dialect_ok {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	tmp: Format_Plan = ---
	p, ok := plan_for(plan, root, &tmp)
	if !ok {
		return Unmarshal_Error{kind = .Plan_Mismatch}
	}
	defer {
		e, refused := err.?
		plan_done(p, plan, &tmp, refused && e.kind == .Out_Of_Memory)
	}
	r: Reader
	r.src, r.borrow, r.enum_ints, r.allocator = src, opts.borrow_strings || CHECK, p.opts.enums == .Int, allocator
	r.dialect, r.check = opts.dialect, CHECK
	row_reader(&r, &p.base, true) or_return

	it := records_of(src, s, context.allocator)
	defer destroy(&it)
	defer delete(r.columns)
	defer delete(r.cols)
	defer delete(r.required)
	defer delete(r.req_more)
	defer delete(r.keys)
	lazy := opts.strictness == .Lazy
	if lazy {
		it.carry.utf8 = max(int)
	}
	refuse := opts.unknown_fields == .Refuse
	when MAP_ROW {
		if opts.no_header {
			return Unmarshal_Error{kind = .Unsupported}
		}
	}
	if !LIST_ROW && !opts.no_header {
		header, more := next_record(&it)
		if !more {
			return records_fault(&it, -1)
		}
		if lazy && it.carry.utf8 <= int(header.fields[len(header.fields) - 1].hi) {
			judge_utf8(&r, &it, header, -1) or_return
		}
		read_header(&r, header, refuse, opts.duplicates) or_return
	}
	when CHECK {
		// One element, reused for every record; a list or map row's, one cell.
		size := int(r.row.size)
		when LIST_ROW || MAP_ROW {
			size = int(r.row.stride)
		}
		scratch_bytes, aerr := runtime.mem_alloc(size, 16, context.allocator)
		if aerr != nil {
			return Unmarshal_Error{kind = .Out_Of_Memory}
		}
		scratch := raw_data(scratch_bytes)
		defer free(scratch, context.allocator)
		rows := 0
	} else {
		list := make([dynamic]E, allocator)
		defer {
			when intrinsics.type_is_slice(P) {
				ptr^ = list[:]
			} else {
				ptr^ = list
			}
		}
	}
	when !LIST_ROW {
		// Only a lazy or ragged read has work per record past its cells.
		per_record := lazy || opts.dialect.ragged
	}
	for rec in next_record(&it) {
		when !LIST_ROW && !MAP_ROW {
			if r.columns == nil {
				columns_in_order(&r, rec, refuse) or_return
			}
		}
		when CHECK {
			row := rows
			rows += 1
			dest := scratch
		} else {
			row := len(list)
		}
		cells := rec.fields
		when LIST_ROW {
			if lazy && it.carry.utf8 <= int(cells[len(cells) - 1].hi) {
				judge_utf8(&r, &it, rec, row) or_return
			}
		} else {
			if per_record {
				cells = record_cells(&r, &it, rec, row, lazy, refuse) or_return
			}
		}
		when !CHECK {
			if _, aerr := append(&list, E{}); aerr != nil {
				return Unmarshal_Error{kind = .Out_Of_Memory, offset = rec.at}
			}
			dest := &list[row]
		}
		when LIST_ROW {
			read_list_row(&r, cells, dest, row) or_return
		} else when MAP_ROW {
			read_map_row(&r, cells, dest, row) or_return
		} else {
			if kind, at, name, refused := read_row(&r, cells, dest); refused {
				return cell_error(kind, at, row, core_pkg.Name(name))
			}
		}
	}
	when CHECK {
		return records_fault(&it, rows)
	} else {
		return records_fault(&it, len(list))
	}
}

// The iterator's fault, if it ended on one, at record `row` (-1 for the header).
@(private)
records_fault :: proc(it: ^Records, row: int) -> Maybe(Unmarshal_Error) {
	e, faulted := it.err.?
	if !faulted {
		return nil
	}
	err := core_pkg.unmarshal_error_from(e)
	if row >= 0 && err.kind == .Syntax {
		core_pkg.error_path_prepend(&err, core_pkg.Index(row))
	}
	return err
}

@(private)
cell_error :: proc(kind: Unmarshal_Error_Kind, at: u64, row: int, name: Maybe(core_pkg.Name)) -> Unmarshal_Error {
	err := Unmarshal_Error{kind = kind, offset = at}
	if n, ok := name.?; ok {
		core_pkg.error_path_prepend(&err, n)
	}
	if row >= 0 {
		core_pkg.error_path_prepend(&err, core_pkg.Index(row))
	}
	return err
}
