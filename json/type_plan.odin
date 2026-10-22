package json

// The type plan `marshal` runs, and that unmarshal lowers into its read shape (`core_pkg.Type_Plan`), as JSON
// maps types: its options and hooks, how JSON spells and matches the plan's names, and this thread's cache of
// the plans calls made without one use.

import "base:runtime"
import core_pkg "../core"
import enc "encode"

// How a plan maps types to JSON. `marshal` writes by it and `unmarshal` reads by it, so the text one plan
// writes reads back with a plan made with the same opts. A call without a plan maps by the zero value.
Plan_Opts :: struct {
	enums:     Enum_Spelling,
	// The member that names a struct arm of a union with two or more named struct arms: `marshal` writes it
	// first in the arm's object and `unmarshal` picks the arm by it, falling back to the value's JSON kind
	// for an object without it. Empty writes every arm untagged and reads every union by kind alone.
	union_tag: string,
	// The value `union_tag` names an arm type by, in place of its type name.
	tag_names: []Tag_Name,
	// Types written by the caller's procs instead of by the plan.
	hooks:     []Type_Hook,
}

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
Type_Hook :: struct {
	type:  typeid,
	write: Marshal_Hook,
	read:  Unmarshal_Hook,
}

// Write the value at `v`, of the hook's type, as exactly one JSON value: one `marshal_into(out, x)`, where `x`
// is any value `marshal` writes (a `Raw` for text the hook writes itself). None, or a second, is
// `.Bad_State`. Its indentation and re-escaping follow the call's `Encode_Opts`.
Marshal_Hook :: #type proc(out: ^Marshal_Out, v: rawptr) -> Encode_Error

// Read `text`, one JSON value as authored and checked in full, into the value at `dest`, of the hook's type,
// allocating from `allocator`.
//
//	- `dest` holds what the target held, as any value is read over it.
//	- `text` is the source's bytes: copy what must outlive them. Under `.Jsonc` a container's text keeps its
//	  comments.
//	- A kind refuses the value with that kind, at the value. Nil reads it.
//	- It runs only for a value read into a target: not under `unmarshal_check`, nor for a duplicate `.First`
//	  skips.
Unmarshal_Hook :: #type proc(text: []byte, dest: rawptr, allocator: runtime.Allocator) -> Maybe(Unmarshal_Error_Kind)

// A type's fields, tags and forms, compiled once per `typeid` for both directions (`type_plan_init`).
// It owns every field below, in its allocator, and grows as values of new types are met. `destroy` frees it.
// Its fields are the plan's own: read none of them.
Type_Plan :: struct {
	using base: core_pkg.Type_Plan,
	// The writing half of `Plan_Opts.hooks`, at the indices of `opts.hooks`.
	writes: []Marshal_Hook,
}

// A plan for values of type `T`, mapped by `opts`, which it copies. Nothing is compiled until first use.
@(require_results)
type_plan_init :: proc(T: typeid, opts := Plan_Opts{}, allocator := context.allocator) -> Type_Plan {
	// The core plan copies `reads`.
	reads, rerr := make([]core_pkg.Plan_Hook, len(opts.hooks), allocator)
	writes, werr := make([]Marshal_Hook, len(opts.hooks), allocator)
	lost := rerr != nil || werr != nil
	if !lost {
		for h, k in opts.hooks {
			// One proc type: both answers are a `Maybe` of a u8 enum numbered alike.
			reads[k] = {h.type, cast(core_pkg.Shape_Hook)h.read}
			writes[k] = h.write
		}
	}
	mapping := core_pkg.Plan_Opts{enums = opts.enums, union_tag = opts.union_tag, tag_names = opts.tag_names, hooks = reads}
	p := Type_Plan{base = core_pkg.type_plan_init(T, mapping, json_plan_format(), allocator), writes = writes}
	delete(reads, allocator)
	p.opts_lost ||= lost
	return p
}

@(private)
Plan_Op :: core_pkg.Plan_Op
@(private)
Plan_Field :: core_pkg.Plan_Field
@(private)
Plan_Member :: core_pkg.Plan_Member

@(private)
type_plan_destroy :: proc(p: ^Type_Plan) {
	delete(p.writes, p.ops.allocator)
	core_pkg.type_plan_destroy(&p.base)
	p^ = {}
}

@(private)
plan_op :: #force_inline proc(p: ^Type_Plan, ti: ^runtime.Type_Info) -> (u32, Encode_Error) {
	idx, err := core_pkg.plan_op(&p.base, ti)
	return idx, Encode_Error(err)
}

// A plan's error is the writer's error of its name.
#assert(u8(core_pkg.Plan_Error.Bad_Name) == u8(Encode_Error.Bad_Utf8))
#assert(u8(core_pkg.Plan_Error.Out_Of_Memory) == u8(Encode_Error.Out_Of_Memory))

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
		tag_key    = "json",
		spell      = spell_plan_key,
		types      = json_plan_types[:],
		key_words  = colon_key_words,
		plain_name = plain_key_name,
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

// `f.colon_key` and `f.colon_mask`: `"name":` in two little-endian words, or the zero word no key matches
// when it takes more than sixteen bytes. And the bit in `op.first` of the byte after the key's opening quote.
@(private = "file")
colon_key_words :: proc(op: ^core_pkg.Shape_Op, f: ^core_pkg.Shape_Field) {
	// An empty key's byte after the opening quote is the closing one.
	first := f.name[0] if len(f.name) > 0 else '"'
	op.first[first >> 6] |= u64(1) << (first & 63)
	spelled := len(f.name) + 3
	if spelled > 16 {
		f.colon_mask[0] = max(u64)
		return
	}
	for k in 0 ..< spelled {
		b := u64('"')
		if k == spelled - 1 {
			b = ':'
		} else if k > 0 && k <= len(f.name) {
			b = u64(f.name[k - 1])
		}
		f.colon_key[k / 8] |= b << (uint(k % 8) * 8)
		f.colon_mask[k / 8] |= u64(0xff) << (uint(k % 8) * 8)
	}
}

// Whether `name` is written in printable ASCII with no quote or backslash, so a key whose bytes equal it is its
// whole unescaped token.
@(private = "file")
plain_key_name :: proc(name: string) -> bool {
	for b in transmute([]u8)name {
		if b < ' ' || b >= 0x7f || b == '"' || b == '\\' {
			return false
		}
	}
	return true
}

@(private, thread_local)
plan_cache: core_pkg.Plan_Cache(Type_Plan)

@(private = "file")
type_plan_default :: proc(T: typeid, a: runtime.Allocator) -> Type_Plan {
	return type_plan_init(T, {}, a)
}

// Frees every plan this thread's cache holds, as eviction frees one: in the heap allocator they were made
// in, whatever `context.allocator` is.
//
//	- For a thread that is done with the default plan, so its cache is not left allocated at exit. The next
//	  call without a plan makes one again.
//	- It does nothing while a call on this thread is using the cache (from inside a hook).
plan_cache_clear :: proc() {
	core_pkg.plan_cache_clear(&plan_cache, type_plan_destroy)
}

@(fini, private)
plan_cache_fini :: proc "contextless" () {
	context = runtime.default_context()
	plan_cache_clear()
}

// The plan a call for `T` runs: `given`, which must have been made for `T` (`ok` false otherwise), else this
// thread's cached plan, else a temporary one made in `tmp`. `plan_done` gives it back.
@(private)
plan_for :: #force_inline proc(given: ^Type_Plan, T: typeid, tmp: ^Type_Plan) -> (p: ^Type_Plan, ok: bool) {
	return core_pkg.plan_for(&plan_cache, given, T, tmp, type_plan_default, type_plan_destroy)
}

// A call is done with `p`, the plan `plan_for` gave it for `given` and `tmp`.
@(private)
plan_done :: #force_inline proc(p, given, tmp: ^Type_Plan, out_of_memory: bool) {
	core_pkg.plan_done(&plan_cache, p, given, tmp, out_of_memory, type_plan_destroy)
}
