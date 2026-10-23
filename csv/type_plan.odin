package csv

import "base:runtime"
import "core:unicode/utf8"
import core_pkg "../core"

// How a plan maps types to cells. `marshal` writes by it and `unmarshal` reads by it, so the text one plan
// writes reads back with a plan made with the same opts. A call without a plan maps by the zero value.
Plan_Opts :: struct {
	enums: Enum_Spelling,
	// Types read and written by the caller's procs, each as one cell.
	hooks: []Type_Hook,
}

// How an enum is written and read: `.Name` as its member's name (the default), `.Int` as its backing integer.
Enum_Spelling :: core_pkg.Enum_Spelling

// A type the caller reads and writes as one cell: a struct field of exactly `type` is a column whatever its
// kind, and its procs run in place of the plan's.
//
//	- A nil proc leaves that direction `.Unsupported`.
//	- It applies to a field of the row, and to the arm of a `Maybe` field. `unmarshal_check` does not run `read`.
Type_Hook :: core_pkg.Type_Hook(Marshal_Hook)

// Append the text of the value at `v`, of the hook's type, to `out`, empty on entry. `marshal` quotes or
// escapes it as it does a string (`.Unwritable` where the dialect cannot), and an empty text as an empty
// string. A refusal is the hook's `Marshal_Error`, which `marshal` returns as it is.
Marshal_Hook :: #type proc(out: ^[dynamic]u8, v: rawptr) -> Marshal_Error

// Read `text`, the cell's text (`field_text`) of a present cell, into the value at `dest`, of the hook's type,
// allocating from `allocator`.
//
//	- `dest` holds what the target held, which is zero for a new record.
//	- `text` is `src`'s bytes or a copy `unmarshal` frees after the call: copy what must outlive it.
//	- A kind refuses the cell with that kind, at the cell. Nil reads it.
Unmarshal_Hook :: core_pkg.Unmarshal_Hook

// A type's columns, compiled once per `typeid` for `unmarshal` and `marshal` (`type_plan_init`). A column is
// a struct field, named by its `csv:"name"` tag or its own name. `type_plan_destroy` frees it. Its fields are
// the plan's own: read none of them.
Type_Plan :: core_pkg.Hooked_Plan(Marshal_Hook)

// A plan for values of type `T`, mapped by `opts`, which it copies. Nothing is compiled until first use.
@(require_results)
type_plan_init :: proc(T: typeid, opts := Plan_Opts{}, allocator := context.allocator) -> Type_Plan {
	return core_pkg.hooked_plan_init(T, {enums = opts.enums}, opts.hooks, csv_plan_format(), allocator)
}

type_plan_destroy :: proc(p: ^Type_Plan) {
	core_pkg.hooked_plan_destroy(p)
}

// CSV spells a name as it is: quoting is the writer's, per cell.
@(private)
csv_plan_format :: proc() -> core_pkg.Plan_Format {
	return {
		tag_key = "csv",
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

@(private, thread_local)
plan_cache: core_pkg.Plan_Cache(Type_Plan)

@(private = "file")
type_plan_default :: proc(T: typeid, a: runtime.Allocator) -> Type_Plan {
	return type_plan_init(T, {}, a)
}

// Frees every plan this thread's cache holds, in the heap allocator they were made in. It does nothing while a
// call on this thread is using the cache.
plan_cache_clear :: proc() {
	core_pkg.plan_cache_clear(&plan_cache, type_plan_destroy)
}

@(fini, private)
plan_cache_fini :: proc "contextless" () {
	context = runtime.default_context()
	plan_cache_clear()
}

@(private)
plan_for :: #force_inline proc(given: ^Type_Plan, T: typeid, tmp: ^Type_Plan) -> (p: ^Type_Plan, ok: bool) {
	return core_pkg.plan_for(&plan_cache, given, T, tmp, type_plan_default, type_plan_destroy)
}

@(private)
plan_done :: #force_inline proc(p, given, tmp: ^Type_Plan, out_of_memory: bool) {
	core_pkg.plan_done(&plan_cache, p, given, tmp, out_of_memory, type_plan_destroy)
}

// `core_pkg.plan_op`, its refusal as `marshal` names it.
@(private)
plan_op :: proc(p: ^Type_Plan, ti: ^runtime.Type_Info) -> (idx: u32, err: Marshal_Error) {
	perr: core_pkg.Plan_Error
	idx, perr = core_pkg.plan_op(&p.base, ti)
	return idx, Marshal_Error(perr)
}

// The kinds a column may be: one cell each.
@(private)
CELL_KINDS :: bit_set[core_pkg.Shape_Kind]{.Bool, .Int, .Uint, .Enum_Int, .Enum_Uint, .Wide_Int, .Wide_Uint, .Float, .String, .Cstring, .Rune, .Hook}

// Whether a value of `kind` and byte width `width` is one cell: not an f16, which neither direction reads.
@(private)
is_cell_kind :: proc(kind: core_pkg.Shape_Kind, width: u8) -> bool {
	return kind in CELL_KINDS && !(kind == .Float && width == 2)
}
