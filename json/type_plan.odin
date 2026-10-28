package json

// JSON's side of the type plan (`core_pkg.Type_Plan`) that `marshal` runs and `unmarshal` lowers into its read
// shape: its options and hooks, and how JSON spells its names. A call made without a plan takes core's cached
// one (`core_pkg.plan_cache_clear`).

import core_pkg "../core"
import enc "encode"
import scan_pkg "scan"

// How a plan maps types, in every format: JSON reads every option.
Plan_Opts :: core_pkg.Plan_Opts

// How marshal writes an enum, and how unmarshal reads one: `.Name`, the member's name, as a string (a value no
// member has is refused), or `.Int`, the backing integer.
Enum_Spelling :: core_pkg.Enum_Spelling

// A union arm's tag value in place of its type name (`Plan_Opts.tag_names`): `name` is written for an arm of
// exactly `type`, and read as it. Copied into the plan.
Tag_Name :: core_pkg.Tag_Name

// A type the caller writes: wherever a value of exactly `type` is written or read, its proc runs instead of
// the plan.
//
//	- A nil proc leaves that direction `.Unsupported`.
//	- A hooked type cannot be a map key or a bit_set's element.
//	- As a union arm it takes every JSON kind, so `unmarshal` reads it only as a union's one arm, as in a
//	  `Maybe`.
Type_Hook :: core_pkg.Type_Hook

// Write the value at `v`, of the hook's type, as exactly one JSON value: one `marshal_into(out, x)`, where `x`
// is any value `marshal` writes (a `Raw` for text the hook writes itself). None, or a second, is
// `.Bad_State`. Its indentation and re-escaping follow the call's `Marshal_Opts`.
Marshal_Hook :: core_pkg.Marshal_Hook

// Read `v`, one JSON value checked in full, into the value at `dest`, of the hook's type, allocating from
// `allocator`.
//
//	- `dest` holds what the target held, as any value is read over it.
//	- `v.text` is the value's JSON text as authored, `v.decoded` a string's decoded text. They live for the
//	  call: copy what must outlive it. Under `.Jsonc` a container's text keeps its comments.
//	- A kind refuses the value with that kind, at the value. Nil reads it.
//	- It runs only for a value read into a target: not under `unmarshal_check`, nor for a duplicate `.First`
//	  skips.
Unmarshal_Hook :: core_pkg.Unmarshal_Hook

// One value an `Unmarshal_Hook` reads: its kind, its text, and a string's decoded text.
Hook_Value :: core_pkg.Hook_Value

// A type's fields, tags and forms, compiled once per `typeid` for both directions (`type_plan_init`).
// It owns every field below, in its allocator, and grows as values of new types are met. `destroy` frees it.
// Its fields are the plan's own: read none of them. Any format's calls take it, and ignore an option they do
// not have; a format's first call compiles that format's spelling of it.
Type_Plan :: core_pkg.Shared_Plan

// The plan a call runs in this format: a `Type_Plan`'s, or the cached or temporary one (`plan_for`).
@(private)
Format_Plan :: core_pkg.Hooked_Plan

// A plan for values of type `T`, mapped by `opts`, which it copies. Nothing is compiled until first use.
@(require_results)
type_plan_init :: proc(T: typeid, opts := Plan_Opts{}, allocator := context.allocator) -> Type_Plan {
	return core_pkg.shared_plan_init(T, opts, json_plan_format, allocator)
}

@(private)
Plan_Op :: core_pkg.Plan_Op
@(private)
Plan_Field :: core_pkg.Plan_Field

@(private, rodata)
json_plan_types := [?]core_pkg.Format_Type{
	{Raw, .Raw},
	{Decoded, .Decoded},
	{Number, .Number},
	{Digits, .Digits},
	{Null, .Null},
}

@(private)
json_plan_format :: proc() -> core_pkg.Plan_Format {
	return {
		tag_key = "json",
		spell   = spell_plan_key,
		types   = json_plan_types[:],
		lowered = scan_pkg.shape_lowered,
	}
}

// `name` as JSON writes it in `role`: a member key with the comma that separates it from the member before,
// `,"name":`, a value as a string, `"name"`, and the union tag as a first member key, `"tag":`. A name that is
// not valid UTF-8 is `.Bad_Name`.
@(private = "file")
spell_plan_key :: proc(keys: ^[dynamic]u8, name: string, role: core_pkg.Key_Role) -> core_pkg.Plan_Error {
	err := enc.put_byte(keys, ',') if role == .Member else .None
	if err == .None {
		err = enc.put_string(keys, name)
	}
	if err == .None && role != .Value {
		err = enc.put_byte(keys, ':')
	}
	return core_pkg.Plan_Error(err)
}

// The plan a call for `T` runs: `given`, which must have been made for `T` and JSON (`ok` false otherwise),
// else this thread's cached plan, else a temporary one made in `tmp`. `plan_done` gives it back.
@(private)
plan_for :: #force_inline proc(given: ^Type_Plan, T: typeid, tmp: ^Format_Plan) -> (p: ^Format_Plan, ok: bool) {
	return core_pkg.plan_for(given, T, tmp, json_plan_format)
}

// A call is done with `p`, the plan `plan_for` gave it for `given` and `tmp`.
@(private)
plan_done :: #force_inline proc(p: ^Format_Plan, given: ^Type_Plan, tmp: ^Format_Plan, out_of_memory: bool) {
	core_pkg.plan_done(p, given, tmp, out_of_memory)
}
