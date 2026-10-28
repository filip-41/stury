package core

// The type plan a format's writer runs, and that its typed reader lowers into a read shape: one flat op per
// type, its kind the read shape's (`Shape_Kind`), struct fields and union arms as runs with their keys
// pre-written in the format's spelling (`Plan_Format`), compiled once per type and on first use. An `any`'s
// dynamic type is compiled the first time a value of it is met, so a plan holding one grows while it is used.
// Compiling a type into ops is plan_compile.odin's, laying out its fields plan_layout.odin's.

import "base:runtime"
import "core:strings"

Plan_Op :: struct {
	info:       ^runtime.Type_Info, // read at write time by Union and Map
	elem:       u32, // Slice/Dynamic/Array/Fixed_List/Pointer/Bit_Set: the element op; Map: the value op; Struct: first field; Union: first arm; Enum_*: first member; Hook: the hook
	key:        u32, // Map: the key op; a refused Struct: the index in `fields` of the offending field
	count:      u32, // Array/Fixed_List: element capacity; Struct: field count; Union: arm count; Enum_*: member count
	stride:     u32, // Slice/Dynamic/Array/Fixed_List: element size
	len_offset: u32, // Fixed_List
	size:       u8,  // Bool/Int/Uint/Float/Enum_*: byte width
	kind:       Shape_Kind,
	flat:       bool, // Struct: every field is a Bool, Int, Uint, Float, String or Enum_* without omitempty; Enum_*: member k is k
	tagged:     bool, // Union: two or more arms are named structs, which `union_tag` tells apart by name
	refused:    bool, // an `.Unsupported` Struct: field `key` is the one that refused it
}

// An enum member: its value, and its name as the format spells a name (`Key_Role.Value`), as `keys[lo:hi]`.
Plan_Member :: struct {
	value:  i64,
	lo, hi: u32,
}

// A struct field, or a union arm.
Plan_Field :: struct {
	offset:    uintptr, // a field's offset; an arm's tag value
	op:        u32,
	key_lo:    u32, // a field's member key (`Key_Role.Member`) is keys[key_lo:key_hi]; a struct arm's name (`Key_Role.Value`), empty for any other arm
	key_hi:    u32,
	kind:      Shape_Kind, // ops[op].kind once compiled, so a scalar field is written without the op
	size:      u8, // ops[op].size
	omitempty: bool,
	required:  bool, // the typed reader refuses an object without it as `.Missing_Field`
}

// Where a struct field's `Plan_Field` came from, kept beside it: the field's name, as its tag or name gives it,
// and its type. Empty beside a union arm.
Field_Source :: struct {
	name: string,
	info: ^runtime.Type_Info,
}

// How a plan maps types, in every format and both directions: the text one plan writes reads back with a plan
// made with the same opts. A format ignores an option it does not have.
Plan_Opts :: struct {
	enums:     Enum_Spelling,
	// The member that names a struct arm of a union with two or more named struct arms: `marshal` writes it
	// first in the arm's object and `unmarshal` picks the arm by it, falling back to the value's kind for an
	// object without it. Empty writes every arm untagged and reads every union by kind alone. JSON's.
	union_tag: string,
	// The value `union_tag` names an arm type by, in place of its type name. JSON's.
	tag_names: []Tag_Name,
	// Types written and read by the caller's procs instead of by the plan.
	hooks:     []Type_Hook,
}

// `Plan_Opts` as a compiled plan holds it: the hooks' read procs only, their write procs being the
// `Hooked_Plan`'s.
Plan_Mapping :: struct {
	enums:     Enum_Spelling,
	union_tag: string,
	tag_names: []Tag_Name,
	// A `.Hook` op's `elem` indexes this.
	hooks:     []Plan_Hook,
}

// How the writer writes an enum, and how the reader reads one.
Enum_Spelling :: enum u8 {
	Name, // the member's name, as a string (a value no member has is refused)
	Int,  // the backing integer
}

// A union arm's tag value in place of its type name (`Plan_Opts.tag_names`): `name` is written for an arm of
// exactly `type`, and read as it. Copied into the plan.
Tag_Name :: struct {
	type: typeid,
	name: string,
}

// A hooked type: wherever a value of exactly `type` is met, the format's hook runs instead of the plan. `read`
// is its reading, nil when the type is not read.
Plan_Hook :: struct {
	type: typeid,
	read: Shape_Hook,
}

// Why a plan could not compile a type. Each member has the value of its `Marshal_Error_Kind` namesake.
Plan_Error :: enum u8 {
	None          = 0,
	Bad_Name      = 2,  // the format cannot spell a field's, member's or arm's name
	Out_Of_Memory = 11, // the allocator refused
	Bad_Tag       = 14, // a field tag has a flag the format does not know
}

// What a name in `Type_Plan.keys` is spelled as.
Key_Role :: enum u8 {
	Member, // a struct field's member key, as it follows a member before it
	Value,  // an enum member's or a struct arm's name, as a value
	Tag,    // `Plan_Opts.union_tag`, as the first member key of an object
}

// One of a format's own types, compiled to its kind instead of by its structure.
Format_Type :: struct {
	type: typeid,
	kind: Shape_Kind,
}

// The struct tag key every format reads a field's name and flags from when the field has no tag under its own
// (`Plan_Format.tag_key`): `stury:"id"` names the field `id` in every format, `json:"Id"` overrides it in JSON.
SHARED_TAG_KEY :: "stury"

// What a format supplies to a plan, read only while ops compile and while the read shape is lowered.
Plan_Format :: struct {
	// The struct tag key a field's name and flags are read from, before SHARED_TAG_KEY.
	tag_key: string,
	// The format has no empty value to omit, so a tag's `omitempty` is `.Bad_Tag`.
	refuse_omitempty: bool,
	// Appends `name` to `keys` as the format spells it in `role`.
	spell:   proc(keys: ^[dynamic]u8, name: string, role: Key_Role) -> Plan_Error,
	types:   []Format_Type,
	// Annotates the read shape for the format's walk after every op is lowered, and resets to `.Unsupported`
	// any op the walk cannot read. Runs before the shape reachable from the root is checked. Nil for none.
	lowered: proc(r: ^Read_Shape) -> runtime.Allocator_Error,
}

// A type's fields, tags and forms, compiled once per `typeid` for both directions (`type_plan_init`).
// It owns every field below, in its allocator, and grows as values of new types are met.
// `type_plan_destroy` frees it. Its fields are the plan's own: read none of them.
//
// A write grows the plan while it runs: a value a hook writes (`plan_hook_value`) or an `any` holds
// (`plan_write_any`) compiles its type when first met, and appending may move `ops`, `fields`, `sources`, `keys`,
// `members` and `unescaped`. Across any call that may write such a value, a writer holds an index into these
// arrays or a copy of an element, never a slice of one or a pointer into it. The read shape is lowered into
// `read` once, before a read, and a read hook has no plan to grow.
Type_Plan :: struct {
	root:   typeid,
	ops:    [dynamic]Plan_Op,
	fields: [dynamic]Plan_Field,
	// sources[k] is where fields[k] came from.
	sources: [dynamic]Field_Source,
	keys:    [dynamic]u8,
	members: [dynamic]Plan_Member,
	// The field names a tag escaped, unescaped and allocated here: the tag text is read-only, and a name without
	// an escape is borrowed from it or the field, so `sources[k].name` outlives the call either way.
	unescaped: [dynamic]string,
	index:     map[typeid]u32,
	// The typed reader's read shape, lowered on first use (`read_shape_of`). Empty until then.
	read:   Read_Shape,
	// Why the type has no read shape, once lowering refused it.
	read_refused: Maybe(Unmarshal_Error),
	// The mapping, its strings and slices copied into the plan's allocator.
	opts:   Plan_Mapping,
	// Copying `opts` ran out of memory: every use refuses with `.Out_Of_Memory`.
	opts_lost: bool,
	// `opts.union_tag` spelled as `Key_Role.Tag`, as keys[tag_lo:tag_hi]. Empty until a union it tags
	// compiles.
	tag_lo, tag_hi: u32,
	format: Plan_Format,
}

// A plan for values of type `T`, mapped by `opts`, which it copies, and spelled by `format`. Nothing is
// compiled until first use.
@(require_results)
type_plan_init :: proc(T: typeid, opts: Plan_Mapping, format: Plan_Format, allocator: runtime.Allocator) -> Type_Plan {
	p := Type_Plan{
		root = T,
		ops = make([dynamic]Plan_Op, allocator = allocator),
		fields = make([dynamic]Plan_Field, allocator = allocator),
		sources = make([dynamic]Field_Source, allocator = allocator),
		keys = make([dynamic]u8, allocator = allocator),
		members = make([dynamic]Plan_Member, allocator = allocator),
		unescaped = make([dynamic]string, allocator = allocator),
		index = make(map[typeid]u32, allocator = allocator),
		format = format,
	}
	p.opts_lost = plan_opts_copy(&p.opts, opts, allocator) != nil
	return p
}

// One value an `Unmarshal_Hook` reads, validated. Its strings live only for the call: copy what must outlive it.
Hook_Value :: struct {
	kind:    Kind, // a CSV cell is a `.String`
	// The value as the format spells it: JSON's text of it, quotes, escapes and containers included; a CSV cell
	// as written, quotes included.
	text:    string,
	// A string's text, escapes and quotes decoded; `text` for any other kind. `number_of_loose_text` reads a
	// number from it in either format.
	decoded: string,
}

// Reads `v` into `dest`, a value of the hook's type, allocating from `allocator`. `dest` holds the target's
// previous value. Return nil on success, or an error kind, which is reported at the value.
Unmarshal_Hook :: #type proc(v: Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(Unmarshal_Error_Kind)

// Where a `Marshal_Hook` writes: a handle on the format's writer, around the hooked value, valid for the hook's
// call. A hook writes through `marshal_into`.
Marshal_Out :: distinct rawptr

// Write the value at `v`, of the hook's type, as exactly one value of the format: one `marshal_into(out, x)`,
// where `x` is any value the format's `marshal` writes. None, or a second, is `.Bad_State`.
Marshal_Hook :: #type proc(out: Marshal_Out, v: rawptr) -> Marshal_Error_Kind

// From inside a `Marshal_Hook`: write `value` as the hooked value, as the format's `marshal` writes a value of
// its type by the call's plan.
@(require_results)
marshal_into :: proc(out: Marshal_Out, value: any) -> Marshal_Error_Kind {
	w := (^Plan_Writer)(out)
	return w.hook_write(w, value)
}

// A caller-defined reader and writer for one type. For every value of exactly `type`, these procs run instead
// of the plan. A nil proc makes that direction `.Unsupported`.
Type_Hook :: struct {
	type:  typeid,
	write: Marshal_Hook,
	read:  Unmarshal_Hook,
}

// A plan whose hooks also write (`hooked_plan_init`).
Hooked_Plan :: struct {
	using base: Type_Plan,
	// The hooks' write procs, at the same indices as `opts.hooks`.
	writes: []Marshal_Hook,
	// The format the plan is spelled for.
	made_for: proc() -> Plan_Format,
}

// Calls `type_plan_init` with `hooks` in place of `opts.hooks`, spelled by `format()`. The hooks' read procs
// become the plan's `opts.hooks` and their write procs its `writes`. `hooked_plan_destroy` frees the plan.
@(require_results)
hooked_plan_init :: proc(T: typeid, opts: Plan_Opts, format: proc() -> Plan_Format, allocator: runtime.Allocator) -> (p: Hooked_Plan) {
	hooks := opts.hooks
	reads, rerr := make([]Plan_Hook, len(hooks), allocator)
	werr: runtime.Allocator_Error
	p.writes, werr = make([]Marshal_Hook, len(hooks), allocator)
	lost := rerr != nil || werr != nil
	mapping := Plan_Mapping{enums = opts.enums, union_tag = opts.union_tag, tag_names = opts.tag_names}
	if !lost {
		for h, k in hooks {
			// `Shape_Fault` and `Unmarshal_Error_Kind` share member values, so the cast is exact.
			reads[k] = {h.type, cast(Shape_Hook)h.read}
			p.writes[k] = h.write
		}
		mapping.hooks = reads
	}
	p.base = type_plan_init(T, mapping, format(), allocator)
	p.made_for = format
	delete(reads, allocator)
	p.opts_lost ||= lost
	return
}

hooked_plan_destroy :: proc(p: ^Hooked_Plan) {
	delete(p.writes, p.ops.allocator)
	type_plan_destroy(&p.base)
	p^ = {}
}

// How many formats one `Shared_Plan` serves: one per format stury has.
PLAN_FORMATS :: 2

// The plan a caller makes once, with any format's `type_plan_init`, and passes to every format's calls: one
// `Hooked_Plan` per format, each spelled as that format spells names and tags. The first is the one `init` made;
// another format's is made from its mapping and hooks on that format's first call. An option a format does not
// have is ignored by it.
Shared_Plan :: struct {
	formats: [PLAN_FORMATS]Hooked_Plan,
}

@(require_results)
shared_plan_init :: proc(T: typeid, opts: Plan_Opts, format: proc() -> Plan_Format, allocator: runtime.Allocator) -> (s: Shared_Plan) {
	s.formats[0] = hooked_plan_init(T, opts, format, allocator)
	return
}

shared_plan_destroy :: proc(s: ^Shared_Plan) {
	for &p in s.formats {
		if p.made_for != nil {
			hooked_plan_destroy(&p)
		}
	}
}

// The plan `s` runs in `format`, made on that format's first call: in the first's allocator, from its mapping
// and hooks. Nil for a plan never made.
shared_plan_for :: #force_inline proc(s: ^Shared_Plan, format: proc() -> Plan_Format) -> ^Hooked_Plan {
	if s.formats[0].made_for == format {
		return &s.formats[0]
	}
	return shared_plan_other(s, format)
}

@(private = "file")
shared_plan_other :: #force_no_inline proc(s: ^Shared_Plan, format: proc() -> Plan_Format) -> ^Hooked_Plan {
	first := &s.formats[0]
	if first.made_for == nil {
		return nil
	}
	for &p in s.formats[1:] {
		if p.made_for == format {
			return &p
		}
		if p.made_for == nil {
			a := first.ops.allocator
			p.base = type_plan_init(first.root, first.opts, format(), a)
			p.made_for = format
			err: runtime.Allocator_Error
			p.writes, err = make([]Marshal_Hook, len(first.writes), a)
			copy(p.writes, first.writes)
			p.opts_lost ||= first.opts_lost || err != nil
			return &p
		}
	}
	return nil
}

// `o` into `c`, its strings and slices copied from `a`. A refusal leaves in `c` what was copied, every string
// and slice not yet copied empty, for `type_plan_destroy`.
@(private = "file")
plan_opts_copy :: proc(c: ^Plan_Mapping, o: Plan_Mapping, a: runtime.Allocator) -> runtime.Allocator_Error {
	c.enums = o.enums
	c.union_tag = strings.clone(o.union_tag, a) or_return
	c.hooks = make([]Plan_Hook, len(o.hooks), a) or_return
	copy(c.hooks, o.hooks)
	c.tag_names = make([]Tag_Name, len(o.tag_names), a) or_return
	for t, k in o.tag_names {
		name := strings.clone(t.name, a) or_return
		c.tag_names[k] = {t.type, name}
	}
	return nil
}

type_plan_destroy :: proc(p: ^Type_Plan) {
	a := p.ops.allocator
	delete(p.opts.union_tag, a)
	delete(p.opts.hooks, a)
	for t in p.opts.tag_names {
		delete(t.name, a)
	}
	delete(p.opts.tag_names, a)
	delete(p.ops)
	delete(p.fields)
	delete(p.sources)
	delete(p.keys)
	delete(p.members)
	for s in p.unescaped {
		delete(s, a)
	}
	delete(p.unescaped)
	delete(p.index)
	read_shape_destroy(&p.read)
	p^ = {}
}
