package dsv

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

// Typed reads: a delimited text read into a list of Odin values during the walk, with no document between them. A
// record reads into a struct whose members are named by the header's cells, through their tags under `csv`, or else
// under `stury`, and under `Dsv_Options.no_header` by their places. A record reads into a list of cells too, the
// header's line being the first such record. A cell is text for a string, and a number or a boolean as its text spells
// it for a field of those, and an empty unquoted cell is absent.

Plan :: typed.Plan
Unmarshal_Options :: typed.Unmarshal_Options
Raw :: typed.Raw
Typed_Refusal :: typed.Typed_Refusal
plan_destroy :: typed.plan_destroy

@(private)
TAG :: "csv"

// The plan of `T` for delimited reads, as `typed.plan_make` makes it, which `unmarshal` takes in `Unmarshal_Options.plan`.
@(require_results)
plan_make :: proc($T: typeid, opts := typed.Plan_Options{}, allocator := context.allocator) -> (Plan, tape.Error) {
	return typed.plan_make(T, TAG, opts, allocator)
}

// Reads `src`, a text of `spec`, into `target`, a list of records, or one record, which reads the first and refuses a
// second as `.Too_Many`, as `typed.read` reads, a cell taking a value's place. A member a new record does not hold
// keeps its zero value.
@(require_results)
unmarshal :: #force_inline proc(src: []u8, target: ^$T, spec := Spec.Csv, read := Unmarshal_Options{}, opts := Options{}, allocator := context.allocator) -> tape.Error {
	return unmarshal_type(src, target, T, spec, read, opts, allocator)
}

@(private)
unmarshal_type :: #force_inline proc(src: []u8, target: rawptr, T: typeid, spec: Spec, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	switch spec {
	case .Csv:
		return unmarshal_as(src, target, T, .Csv, read, opts, allocator)
	case .Tsv:
		return unmarshal_as(src, target, T, .Tsv, read, opts, allocator)
	case .Plain:
		return unmarshal_as(src, target, T, .Plain, read, opts, allocator)
	}
	return tape.Bad_Option{"spec"}
}

@(private)
unmarshal_as :: #force_no_inline proc(src: []u8, target: rawptr, T: typeid, $S: Spec, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	if _, refused := pass_options(S, opts); refused != nil {
		return refused
	}
	o := opts
	if list_rows(T) {
		d, _ := o.format.(tape.Dsv_Options)
		d.no_header = true
		o.format = d
	}
	if e := refuse_repeat(src, S, o, allocator); e != nil {
		return e
	}
	if o.runner != nil && o.runner.threads > 0 && o.pieces == nil && o.budget.steps == 0 && len(src) >= typed.PARALLEL_FROM {
		if err, done := unmarshal_parallel(src, target, T, S, read, o, allocator); done {
			return err
		}
	}
	if o.budget.steps != 0 {
		return unmarshal_walk(src, target, T, S, true, read, o, allocator)
	}
	return unmarshal_walk(src, target, T, S, false, read, o, allocator)
}

// Whether `T` is a list of rows that are lists of cells, which take the header's line as a record.
@(private)
list_rows :: proc(T: typeid) -> bool {
	list :: proc(ti: ^runtime.Type_Info) -> ^runtime.Type_Info {
		#partial switch v in runtime.type_info_base(ti).variant {
		case ^runtime.Type_Info_Slice:
			return v.elem
		case ^runtime.Type_Info_Dynamic_Array:
			return v.elem
		case ^runtime.Type_Info_Array:
			return v.elem
		case ^runtime.Type_Info_Enumerated_Array:
			return v.elem
		}
		return nil
	}
	row := list(type_info_of(T))
	return row != nil && list(row) != nil
}

@(private)
unmarshal_walk :: #force_inline proc(src: []u8, target: rawptr, T: typeid, $S: Spec, $LAX: bool, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^typed.Cells_Reader, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		on :: #force_inline proc "contextless" (h: ^typed.Cells_Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
			return typed.cells_hook(h, s, t, number_value)
		}
		return walk_text(src, S, LAX, options_resolved(S, opts), h, regs, a, ctx, on, nil, opts.budget.steps)
	}
	return typed.read(src, target, T, &FORMATS[S], TAG, opts, read, allocator, typed.Cells_Reader, walk)
}
