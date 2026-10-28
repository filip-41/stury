package csv

import "base:runtime"
import "core:reflect"
import "core:unicode/utf8"
import core_pkg "../core"

// How a plan maps types, in every format. CSV reads `enums` and `hooks` (each hooked type one cell), and ignores
// the union tag: a union it reads or writes is a `Maybe` of one cell. A call without a plan uses the zero value.
Plan_Opts :: core_pkg.Plan_Opts

// How an enum is written and read: `.Name` as its member's name (the default), `.Int` as its backing integer.
Enum_Spelling :: core_pkg.Enum_Spelling

// A type the caller reads and writes as one cell. A struct field of exactly `type` is a column whatever its
// kind, and the hook's procs run in place of the plan's.
//
//	- A nil proc leaves that direction `.Unsupported`.
//	- It applies to a field of the row, and to the arm of a `Maybe` field. `unmarshal_check` does not run `read`.
Type_Hook :: core_pkg.Type_Hook

// Write the value at `v`, of the hook's type, as one cell: one `marshal_into(out, x)`, where `x` is a string,
// cstring, rune, bool, number or enum. `marshal` quotes or escapes the cell as it does a string (`.Unwritable`
// where the dialect cannot), and writes an empty string as an empty string. None, or a second, is `.Bad_State`.
// To refuse, return a `Marshal_Error_Kind`; `marshal` returns it unchanged.
Marshal_Hook :: core_pkg.Marshal_Hook

// From inside a `Marshal_Hook`: write `value` as the hooked cell.
marshal_into :: core_pkg.marshal_into

// Where a `Marshal_Hook` writes: a handle valid for the hook's call.
Marshal_Out :: core_pkg.Marshal_Out

// Reads `v`, a present cell (`.String`, its `text` as written and its `decoded` text), into the value at `dest`,
// of the hook's type, allocating from `allocator`.
//
//	- `dest` holds the target's previous value, zero for a new record.
//	- `v`'s strings live for the call: copy what must outlive it.
//	- Returning a kind refuses the cell with that kind, at the cell. Nil accepts it.
Unmarshal_Hook :: core_pkg.Unmarshal_Hook

// One value an `Unmarshal_Hook` reads: its kind, its text, and a string's decoded text.
Hook_Value :: core_pkg.Hook_Value

// A type's columns, compiled once per `typeid` for `unmarshal` and `marshal` (`type_plan_init`). A column is
// a struct field, named by its `csv:"name"` tag or its own name. `destroy` frees it. Its fields are
// internal. Any format's calls take it; a format's first call compiles that format's spelling of it.
Type_Plan :: core_pkg.Shared_Plan

// The plan a call runs in this format: a `Type_Plan`'s, or the cached or temporary one (`plan_for`).
@(private)
Format_Plan :: core_pkg.Hooked_Plan

// A plan for values of type `T`, mapped by `opts`, which it copies. Nothing is compiled until first use.
@(require_results)
type_plan_init :: proc(T: typeid, opts := Plan_Opts{}, allocator := context.allocator) -> Type_Plan {
	return core_pkg.shared_plan_init(T, opts, csv_plan_format, allocator)
}

// CSV writes a name unchanged; the writer quotes per cell.
@(private)
csv_plan_format :: proc() -> core_pkg.Plan_Format {
	return {
		tag_key = "csv",
		refuse_omitempty = true,
		spell = proc(keys: ^[dynamic]u8, name: string, role: core_pkg.Key_Role) -> core_pkg.Plan_Error {
			if !utf8.valid_string(name) {
				return .Bad_Name
			}
			if _, err := append(keys, name); err != nil {
				return .Out_Of_Memory
			}
			return .None
		},
	}
}

@(private)
plan_for :: #force_inline proc(given: ^Type_Plan, T: typeid, tmp: ^Format_Plan) -> (p: ^Format_Plan, ok: bool) {
	return core_pkg.plan_for(given, T, tmp, csv_plan_format)
}

@(private)
plan_done :: #force_inline proc(p: ^Format_Plan, given: ^Type_Plan, tmp: ^Format_Plan, out_of_memory: bool) {
	core_pkg.plan_done(p, given, tmp, out_of_memory)
}

// The kinds a column may have, each one cell.
@(private)
CELL_KINDS :: bit_set[core_pkg.Shape_Kind]{.Bool, .Int, .Uint, .Enum_Int, .Enum_Uint, .Wide_Int, .Wide_Uint, .Float, .String, .Cstring, .Rune, .Hook}

// Whether `op` is one cell: a `CELL_KINDS` kind, or a `Maybe` of one (a union of one arm, with a tag). A hook
// must have the proc of the direction asked: `writes[op.elem]` when `writes` is set, else its reader.
@(private)
is_cell :: proc(p: ^core_pkg.Type_Plan, op: Plan_Op, writes: []Marshal_Hook) -> bool {
	#partial switch op.kind {
	case .Hook:
		return writes[op.elem] != nil if writes != nil else p.opts.hooks[op.elem].read != nil
	case .Union:
		ti := runtime.type_info_base(op.info).variant.(runtime.Type_Info_Union)
		return op.count == 1 && !reflect.type_info_union_is_pure_maybe(ti) && is_cell(p, p.ops[p.fields[op.elem].op], writes)
	}
	return op.kind in CELL_KINDS
}

