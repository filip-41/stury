package csv

import "base:runtime"
import "core:reflect"
import "core:unicode/utf8"
import core_pkg "../core"

// How a plan maps types to cells. `marshal` writes and `unmarshal` reads by it, so text written with one plan
// reads back with a plan made from the same opts. A call without a plan uses the zero value.
Plan_Opts :: struct {
	enums: Enum_Spelling,
	// Types read and written by the caller's procs, each as one cell.
	hooks: []Type_Hook,
}

// How an enum is written and read: `.Name` as its member's name (the default), `.Int` as its backing integer.
Enum_Spelling :: core_pkg.Enum_Spelling

// A type the caller reads and writes as one cell. A struct field of exactly `type` is a column whatever its
// kind, and the hook's procs run in place of the plan's.
//
//	- A nil proc leaves that direction `.Unsupported`.
//	- It applies to a field of the row, and to the arm of a `Maybe` field. `unmarshal_check` does not run `read`.
Type_Hook :: core_pkg.Type_Hook(Marshal_Hook)

// Appends the text of the value at `v`, of the hook's type, to `out`, which is empty on entry. `marshal`
// quotes or escapes the text as it does a string (`.Unwritable` where the dialect cannot), and writes an
// empty text as an empty string. To refuse, return a `Marshal_Error`; `marshal` returns it unchanged.
Marshal_Hook :: #type proc(out: ^[dynamic]u8, v: rawptr) -> Marshal_Error

// Reads `text`, a present cell's text (`field_text`), into the value at `dest`, of the hook's type, allocating
// from `allocator`.
//
//	- `dest` holds the target's previous value, zero for a new record.
//	- `text` is either `src`'s bytes or a copy `unmarshal` frees after the call: copy what must outlive it.
//	- Returning a kind refuses the cell with that kind, at the cell. Nil accepts it.
Unmarshal_Hook :: core_pkg.Unmarshal_Hook

// A type's columns, compiled once per `typeid` for `unmarshal` and `marshal` (`type_plan_init`). A column is
// a struct field, named by its `csv:"name"` tag or its own name. `destroy` frees it. Its fields are
// internal.
Type_Plan :: core_pkg.Hooked_Plan(Marshal_Hook)

// A plan for values of type `T`, mapped by `opts`, which it copies. Nothing is compiled until first use.
@(require_results)
type_plan_init :: proc(T: typeid, opts := Plan_Opts{}, allocator := context.allocator) -> Type_Plan {
	return core_pkg.hooked_plan_init(T, {enums = opts.enums}, opts.hooks, csv_plan_format(), allocator)
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

@(private, thread_local)
plan_cache: core_pkg.Plan_Cache(Marshal_Hook)

// Frees every plan in this thread's cache, with the heap allocator they were made in. Does nothing while a
// call on this thread is using the cache.
plan_cache_clear :: proc() {
	core_pkg.plan_cache_clear(&plan_cache)
}

@(fini, private)
plan_cache_fini :: proc "contextless" () {
	context = runtime.default_context()
	plan_cache_clear()
}

@(private)
plan_for :: #force_inline proc(given: ^Type_Plan, T: typeid, tmp: ^Type_Plan) -> (p: ^Type_Plan, ok: bool) {
	return core_pkg.plan_for(&plan_cache, given, T, tmp, csv_plan_format)
}

@(private)
plan_done :: #force_inline proc(p, given, tmp: ^Type_Plan, out_of_memory: bool) {
	core_pkg.plan_done(&plan_cache, p, given, tmp, out_of_memory)
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

