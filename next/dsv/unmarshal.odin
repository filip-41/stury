package dsv

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

// Typed reads: a delimited text read into a list of Odin values during the walk, with no document between them. A
// record reads into a struct whose members are named by the header's cells, through their tags under `csv`, or else
// under `stury`, and under `Dsv_Options.no_header` into a list of cells. A cell is text for a string, and a number or
// a boolean as its text spells it for a field of those, and an empty unquoted cell is absent.

Plan :: typed.Plan
Plan_Options :: typed.Plan_Options
Unmarshal_Options :: typed.Unmarshal_Options
Raw :: typed.Raw
Refusal :: typed.Refusal
plan_destroy :: typed.plan_destroy

@(private)
TAG :: "csv"

// The plan of `T` for delimited reads, which `unmarshal` takes in `Unmarshal_Options.plan`, in `allocator`, which
// `plan_destroy` frees. A type a read cannot take is `Bad_Option` naming the member, or the type.
@(require_results)
plan_make :: proc($T: typeid, opts := Plan_Options{}, allocator := context.allocator) -> (Plan, tape.Error) {
	return typed.plan_make(T, TAG, opts, allocator)
}

// Reads `src`, a text of `spec`, into `target`, a list of records. A member the record does not hold keeps its zero
// value, and a cell the type does not take is a `Fault` of kind `.Refused`, whose detail is a `Refusal`, at the cell,
// unless the text fails as `validate` fails it, which is then the error. Strings and lists are allocated with
// `allocator`, and a cell with nothing to decode is a span of `src` under `read.borrow_strings`.
@(require_results)
unmarshal :: proc(src: []u8, target: ^$T, spec := Spec.Csv, read := Unmarshal_Options{}, opts := Options{}, allocator := context.allocator) -> tape.Error {
	return unmarshal_type(src, target, T, spec, read, opts, allocator)
}

@(private)
unmarshal_type :: proc(src: []u8, target: rawptr, T: typeid, spec: Spec, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
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
	if e := refuse_repeat(src, S, opts, allocator); e != nil {
		return e
	}
	if opts.budget.steps != 0 {
		return unmarshal_walk(src, target, T, S, true, read, opts, allocator)
	}
	return unmarshal_walk(src, target, T, S, false, read, opts, allocator)
}

@(private)
unmarshal_walk :: #force_inline proc(src: []u8, target: rawptr, T: typeid, $S: Spec, $LAX: bool, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^typed.Cells_Reader, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		on :: #force_inline proc "contextless" (h: ^typed.Cells_Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
			return typed.cells_hook(h, s, t, number_value)
		}
		return walk_text(src, S, LAX, options_resolved(S, opts), h, regs, a, ctx, on, nil, opts.budget.steps)
	}
	// `.Refuse` was judged on the header, so the read takes the repeats as `.Last`.
	o := opts
	if o.dups == .Refuse {
		o.dups = .Last
	}
	return typed.read(src, target, T, &FORMATS[S], TAG, o, read, allocator, typed.Cells_Reader, walk)
}
