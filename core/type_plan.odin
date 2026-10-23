package core

// The type plan a format's writer runs, and that its typed reader lowers into a read shape: one flat op per
// type, its kind the read shape's (`Shape_Kind`), struct fields and union arms as runs with their keys
// pre-written in the format's spelling (`Plan_Format`), compiled once per type and on first use. An `any`'s
// dynamic type is compiled the first time a value of it is met, so a plan holding one grows while it is used.
// A plan that reported `.Out_Of_Memory` is unusable, so destroy it.

import "base:runtime"
import "core:reflect"
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

// Where a struct field's `Plan_Field` came from, kept beside it: the field's name, as its tag or name gives
// it, and its type. Empty beside a union arm.
Field_Source :: struct {
	name: string,
	info: ^runtime.Type_Info,
}

// How a plan maps types, for both directions: the text one plan writes reads back with a plan made with the
// same opts.
Plan_Opts :: struct {
	enums:     Enum_Spelling,
	// The member that names a struct arm of a union with two or more named struct arms. Empty writes every arm
	// untagged and reads every union by kind alone.
	union_tag: string,
	// The value `union_tag` names an arm type by, in place of its type name.
	tag_names: []Tag_Name,
	// Types the format's hooks write and read instead of the plan: a `.Hook` op's `elem` indexes this.
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

// Why a plan could not compile a type. Each member has the value of its `Marshal_Error` namesake.
Plan_Error :: enum u8 {
	None          = 0,
	Bad_Name      = 2,  // the format cannot spell a field's, member's or arm's name
	Out_Of_Memory = 11, // the allocator refused
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

// What a format supplies to a plan, read only while ops compile and while the read shape is lowered.
Plan_Format :: struct {
	// The struct tag key a field's name and flags are read from.
	tag_key: string,
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
Type_Plan :: struct {
	root:   typeid,
	ops:    [dynamic]Plan_Op,
	fields: [dynamic]Plan_Field,
	// sources[k] is where fields[k] came from.
	sources: [dynamic]Field_Source,
	keys:    [dynamic]u8,
	members: [dynamic]Plan_Member,
	index:   map[typeid]u32,
	// The typed reader's read shape, lowered on first use (`read_shape_of`). Empty until then.
	read:   Read_Shape,
	// Why the type has no read shape, once lowering refused it.
	read_refused: Maybe(Unmarshal_Error),
	// The mapping, its strings and slices copied into the plan's allocator.
	opts:   Plan_Opts,
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
type_plan_init :: proc(T: typeid, opts: Plan_Opts, format: Plan_Format, allocator: runtime.Allocator) -> Type_Plan {
	p := Type_Plan{
		root = T,
		ops = make([dynamic]Plan_Op, allocator = allocator),
		fields = make([dynamic]Plan_Field, allocator = allocator),
		sources = make([dynamic]Field_Source, allocator = allocator),
		keys = make([dynamic]u8, allocator = allocator),
		members = make([dynamic]Plan_Member, allocator = allocator),
		index = make(map[typeid]u32, allocator = allocator),
		format = format,
	}
	p.opts_lost = plan_opts_copy(&p.opts, opts, allocator) != nil
	return p
}

// Reads `text`, the fully validated source text of one value, into `dest`, a value of the hook's type,
// allocating from `allocator`. `dest` holds the target's previous value. `text` is the source bytes, or a copy
// freed after the call, so copy anything that must outlive it. Return nil on success, or an error kind, which is
// reported at the value.
Unmarshal_Hook :: #type proc(text: []byte, dest: rawptr, allocator: runtime.Allocator) -> Maybe(Unmarshal_Error_Kind)

// A caller-defined reader and writer for one type. For every value of exactly `type`, these procs run instead
// of the plan. `W` is the format's writing proc type. A nil proc makes that direction `.Unsupported`.
Type_Hook :: struct($W: typeid) {
	type:  typeid,
	write: W,
	read:  Unmarshal_Hook,
}

// A plan whose hooks also write; `W` is the format's writing proc type (`hooked_plan_init`).
Hooked_Plan :: struct($W: typeid) {
	using base: Type_Plan,
	// The hooks' write procs, at the same indices as `opts.hooks`.
	writes: []W,
}

// Calls `type_plan_init` with `hooks` in place of `opts.hooks`. The hooks' read procs become the plan's
// `opts.hooks` and their write procs its `writes`. `hooked_plan_destroy` frees the plan.
@(require_results)
hooked_plan_init :: proc(T: typeid, opts: Plan_Opts, hooks: []Type_Hook($W), format: Plan_Format, allocator: runtime.Allocator) -> (p: Hooked_Plan(W)) {
	reads, rerr := make([]Plan_Hook, len(hooks), allocator)
	werr: runtime.Allocator_Error
	p.writes, werr = make([]W, len(hooks), allocator)
	lost := rerr != nil || werr != nil
	mapping := opts
	if !lost {
		for h, k in hooks {
			// `Shape_Fault` and `Unmarshal_Error_Kind` share member values, so the cast is exact.
			reads[k] = {h.type, cast(Shape_Hook)h.read}
			p.writes[k] = h.write
		}
		mapping.hooks = reads
	}
	p.base = type_plan_init(T, mapping, format, allocator)
	delete(reads, allocator)
	p.opts_lost ||= lost
	return
}

hooked_plan_destroy :: proc(p: ^Hooked_Plan($W)) {
	delete(p.writes, p.ops.allocator)
	type_plan_destroy(&p.base)
	p^ = {}
}

// `o` into `c`, its strings and slices copied from `a`. A refusal leaves in `c` what was copied, every string
// and slice not yet copied empty, for `type_plan_destroy`.
@(private = "file")
plan_opts_copy :: proc(c: ^Plan_Opts, o: Plan_Opts, a: runtime.Allocator) -> runtime.Allocator_Error {
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
	delete(p.index)
	read_shape_destroy(&p.read)
	p^ = {}
}

// The op for `ti`. A type already in the plan, including one still being compiled further up this call (a
// recursive type), answers its existing index.
plan_op :: proc(p: ^Type_Plan, ti: ^runtime.Type_Info) -> (idx: u32, err: Plan_Error) {
	if found, ok := p.index[ti.id]; ok {
		return found, .None
	}
	idx = u32(len(p.ops))
	if _, aerr := append(&p.ops, Plan_Op{info = ti}); aerr != nil {
		return 0, .Out_Of_Memory
	}
	if map_insert(&p.index, ti.id, idx) == nil {
		return 0, .Out_Of_Memory
	}
	op := compile_op(p, ti, idx) or_return
	// Indexed after the call: compiling element types may have moved `p.ops`.
	p.ops[idx] = op
	return idx, .None
}

// The op for `ti`, whose slot is `p.ops[idx]`.
@(private = "file")
compile_op :: proc(p: ^Type_Plan, ti: ^runtime.Type_Info, idx: u32) -> (op: Plan_Op, err: Plan_Error) {
	op.info = ti
	if k, hooked := hook_of(p, ti.id); hooked {
		op.kind = .Hook
		op.elem = u32(k)
		return
	}
	for t in p.format.types {
		if t.type == ti.id {
			op.kind = t.kind
			return
		}
	}
	base := runtime.type_info_base(ti)
	op.size = u8(min(base.size, 255))
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		op.kind = .Bool
	case runtime.Type_Info_Integer:
		switch {
		case v.endianness != .Platform:
			op.kind = .Unsupported
		case base.size == 16:
			op.kind = .Wide_Int if v.signed else .Wide_Uint
		case:
			op.kind = .Int if v.signed else .Uint
		}
	case runtime.Type_Info_Rune:
		op.kind = .Rune
	case runtime.Type_Info_Float:
		op.kind = .Float if v.endianness == .Platform else .Unsupported
	case runtime.Type_Info_String:
		switch {
		case v.encoding != .UTF_8:
			op.kind = .Unsupported
		case v.is_cstring:
			op.kind = .Cstring
		case:
			op.kind = .String
		}
	case runtime.Type_Info_Enum:
		compile_enum_op(p, ti, v, &op) or_return
	case runtime.Type_Info_Pointer:
		if v.elem == nil {
			op.kind = .Unsupported
		} else {
			op.kind = .Pointer
			op.elem = plan_op(p, v.elem) or_return
		}
	case runtime.Type_Info_Array:
		op.kind = .Array
		op.count = u32(v.count)
		op.stride = u32(v.elem_size)
		op.elem = plan_op(p, v.elem) or_return
	case runtime.Type_Info_Enumerated_Array:
		op.kind = .Array
		op.count = u32(v.count)
		op.stride = u32(v.elem_size)
		op.elem = plan_op(p, v.elem) or_return
	case runtime.Type_Info_Slice:
		op.kind = .Slice
		op.stride = u32(v.elem_size)
		op.elem = plan_op(p, v.elem) or_return
	case runtime.Type_Info_Dynamic_Array:
		op.kind = .Dynamic
		op.stride = u32(v.elem_size)
		op.elem = plan_op(p, v.elem) or_return
	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		op.kind = .Fixed_List
		op.count = u32(v.capacity)
		op.stride = u32(v.elem_size)
		op.len_offset = u32(v.len_offset)
		op.elem = plan_op(p, v.elem) or_return
	case runtime.Type_Info_Map:
		compile_map_op(p, v, &op) or_return
	case runtime.Type_Info_Struct:
		compile_struct_op(p, v, &op, idx) or_return
	case runtime.Type_Info_Bit_Set:
		compile_bit_set_op(p, v, &op) or_return
	case runtime.Type_Info_Union:
		compile_union_op(p, v, &op) or_return
	case runtime.Type_Info_Any:
		op.kind = .Any
	case:
		op.kind = .Unsupported
	}
	return
}

// An enum's op in `op`: its integer kind with the member table, or its backing op for a 128-bit backing.
@(private = "file")
compile_enum_op :: proc(p: ^Type_Plan, ti: ^runtime.Type_Info, v: runtime.Type_Info_Enum, op: ^Plan_Op) -> (err: Plan_Error) {
	backing := plan_op(p, v.base) or_return
	if k := p.ops[backing].kind; k != .Int && k != .Uint {
		// A 128-bit backing writes its integer.
		op^ = p.ops[backing]
		op.info = ti
		return
	}
	op.kind = .Enum_Int if p.ops[backing].kind == .Int else .Enum_Uint
	op.elem = u32(len(p.members))
	op.count = u32(len(v.names))
	op.flat = true
	for name, k in v.names {
		lo := u32(len(p.keys))
		p.format.spell(&p.keys, name, .Value) or_return
		if _, aerr := append(&p.members, Plan_Member{i64(v.values[k]), lo, u32(len(p.keys))}); aerr != nil {
			return .Out_Of_Memory
		}
		op.flat &&= i64(v.values[k]) == i64(k)
	}
	return .None
}

// A map's op in `op`: supported for string and integer keys.
@(private = "file")
compile_map_op :: proc(p: ^Type_Plan, v: runtime.Type_Info_Map, op: ^Plan_Op) -> (err: Plan_Error) {
	op.key = plan_op(p, v.key) or_return
	#partial switch p.ops[op.key].kind {
	case .String, .Cstring, .Int, .Uint, .Wide_Int, .Wide_Uint, .Enum_Int, .Enum_Uint:
		op.kind = .Map
		op.elem = plan_op(p, v.value) or_return
	case:
		op.kind = .Unsupported
	}
	return .None
}

// A struct's op in `op`, whose slot is `p.ops[idx]`.
@(private = "file")
compile_struct_op :: proc(p: ^Type_Plan, v: runtime.Type_Info_Struct, op: ^Plan_Op, idx: u32) -> (err: Plan_Error) {
	if .raw_union in v.flags || v.soa_kind != .None {
		op.kind = .Unsupported
	} else {
		op.elem = u32(len(p.fields))
		refused := lay_out_run(p, v, 0, op.elem) or_return
		op.count = u32(len(p.fields)) - op.elem
		if at, bad := refused.?; bad {
			op.kind = .Unsupported
			op.refused = true
			op.key = at
			return
		}
		op.kind = .Struct
		// Published before the field types compile: a recursive type meets this op again (through a
		// pointer, a list or a union) while it is compiled, and a union reads its arms' kinds.
		p.ops[idx] = op^
		compile_field_types(p, op.elem, op.count) or_return
		op.flat = true
		for f in p.fields[op.elem:][:op.count] {
			#partial switch f.kind {
			case .Bool, .Int, .Uint, .Float, .String, .Enum_Int, .Enum_Uint:
				op.flat &&= !f.omitempty
			case:
				op.flat = false
			}
		}
	}
	return .None
}

// A bit_set's op in `op`.
@(private = "file")
compile_bit_set_op :: proc(p: ^Type_Plan, v: runtime.Type_Info_Bit_Set, op: ^Plan_Op) -> (err: Plan_Error) {
	// An enum's names or a range's integers. A 128-bit enum lowers to its integer kind, refused here, and
	// so is a backing integer of another byte order, as an integer of one is.
	if v.underlying != nil && runtime.type_info_base(v.underlying).variant.(runtime.Type_Info_Integer).endianness != .Platform {
		op.kind = .Unsupported
		return
	}
	op.elem = plan_op(p, v.elem) or_return
	#partial switch p.ops[op.elem].kind {
	case .Enum_Int, .Enum_Uint, .Int, .Uint:
		op.kind = .Bit_Set
	case:
		op.kind = .Unsupported
	}
	return .None
}

// A union's op in `op`.
@(private = "file")
compile_union_op :: proc(p: ^Type_Plan, v: runtime.Type_Info_Union, op: ^Plan_Op) -> (err: Plan_Error) {
	op.kind = .Union
	op.elem, op.count = compile_arms(p, v) or_return
	named := 0
	for arm in p.fields[op.elem:][:op.count] {
		named += int(arm.key_hi > arm.key_lo)
	}
	op.tagged = named >= 2
	if op.tagged && len(p.opts.union_tag) > 0 && (tag_clashes(p, op^) or_return) {
		op.kind = .Unsupported
	}
	return .None
}

// The hook `opts.hooks[k]` that handles type `T`.
@(private = "file")
hook_of :: proc(p: ^Type_Plan, T: typeid) -> (k: int, hooked: bool) {
	for h, j in p.opts.hooks {
		if h.type == T {
			return j, true
		}
	}
	return -1, false
}

// Lay the fields that take part (all but those tagged `-`) out as one run in `p.fields` from `first`, `base`
// bytes into the struct the run is for, keys pre-written as `Key_Role.Member`, each type in `p.sources` for
// `compile_field_types`. `refused` is the index in `p.fields` of the field that makes the struct unsupported:
// the second of two writing one key, which no object can hold twice, or one asking for `,string`. The run is
// laid out before any field type compiles, so a nested struct's run lands after it. A `using` field of a
// struct type its tag gives no name, and no hook handles, is flattened, as Go flattens an embedded struct:
// its fields join the run in its place.
@(private = "file")
lay_out_run :: proc(p: ^Type_Plan, v: runtime.Type_Info_Struct, base: uintptr, first: u32) -> (refused: Maybe(u32), err: Plan_Error) {
	for i in 0 ..< int(v.field_count) {
		tag := field_spelling(v.names[i], v.tags[i], p.format.tag_key)
		if !tag.keep {
			continue
		}
		if inner, ok := runtime.type_info_base(v.types[i]).variant.(runtime.Type_Info_Struct); ok && v.usings[i] && !tag.named {
			if _, hooked := hook_of(p, v.types[i].id); !hooked && .raw_union not_in inner.flags && inner.soa_kind == .None {
				inner_refused := lay_out_run(p, inner, base + v.offsets[i], first) or_return
				if refused == nil {
					refused = inner_refused
				}
				continue
			}
		}
		at := u32(len(p.fields))
		if tag.quoted && refused == nil {
			refused = at
		}
		key_lo := u32(len(p.keys))
		p.format.spell(&p.keys, tag.key, .Member) or_return
		f := Plan_Field{offset = base + v.offsets[i], key_lo = key_lo, key_hi = u32(len(p.keys)), omitempty = tag.omitempty, required = tag.required}
		// Keys are spelled canonically, so two fields name one key exactly when their spelled forms are equal.
		for g in p.fields[first:] {
			if refused == nil && string(p.keys[g.key_lo:g.key_hi]) == string(p.keys[f.key_lo:f.key_hi]) {
				refused = at
			}
		}
		if _, aerr := append(&p.fields, f); aerr != nil {
			return nil, .Out_Of_Memory
		}
		if _, aerr := append(&p.sources, Field_Source{tag.key, v.types[i]}); aerr != nil {
			return nil, .Out_Of_Memory
		}
	}
	return
}

// Compile the types of the laid-out run `p.fields[first:][:count]`.
@(private = "file")
compile_field_types :: proc(p: ^Type_Plan, first, count: u32) -> Plan_Error {
	for k in first ..< first + count {
		field_op := plan_op(p, p.sources[k].info) or_return
		// A type still being compiled further up (a recursive type, through a pointer, a list or a union) is
		// not final here: a struct's kind is, and any other's caches as `.Unsupported`, read only by the
		// scalar fast paths, which no type in progress is.
		op := p.ops[field_op]
		p.fields[k].op = field_op
		p.fields[k].kind = op.kind
		p.fields[k].size = op.size
	}
	return .None
}

// A union's arms as one run in `p.fields`, in declaration order: each its op and tag value, and a named
// struct arm its `arm_tag_name` spelled as `Key_Role.Value`.
@(private = "file")
compile_arms :: proc(p: ^Type_Plan, u: runtime.Type_Info_Union) -> (first, count: u32, err: Plan_Error) {
	first = u32(len(p.fields))
	count = u32(len(u.variants))
	if resize(&p.fields, int(first + count)) != nil || resize(&p.sources, int(first + count)) != nil {
		return 0, 0, .Out_Of_Memory
	}
	for variant, k in u.variants {
		arm_op := plan_op(p, variant) or_return
		// Tag 0 is nil, unless the union has no nil.
		arm := Plan_Field{offset = uintptr(k if u.no_nil else k + 1), op = arm_op, kind = p.ops[arm_op].kind, size = p.ops[arm_op].size}
		if named, ok := variant.variant.(runtime.Type_Info_Named); ok && arm.kind == .Struct {
			arm.key_lo = u32(len(p.keys))
			p.format.spell(&p.keys, arm_tag_name(p, variant.id, named.name), .Value) or_return
			arm.key_hi = u32(len(p.keys))
		}
		p.fields[first + u32(k)] = arm
	}
	return
}

// The value `union_tag` names a struct arm of type `T` by: its `tag_names` entry, else its type name.
arm_tag_name :: proc(p: ^Type_Plan, T: typeid, type_name: string) -> string {
	for t in p.opts.tag_names {
		if t.type == T {
			return t.name
		}
	}
	return type_name
}

// Whether a named struct arm of the tagged union `op` has a field the `union_tag` member would repeat. The
// first call spells the tag's key.
@(private = "file")
tag_clashes :: proc(p: ^Type_Plan, op: Plan_Op) -> (clash: bool, err: Plan_Error) {
	if p.tag_hi == 0 {
		p.tag_lo = u32(len(p.keys))
		p.format.spell(&p.keys, p.opts.union_tag, .Tag) or_return
		p.tag_hi = u32(len(p.keys))
	}
	for arm in p.fields[op.elem:][:op.count] {
		if arm.key_hi == arm.key_lo {
			continue
		}
		aop := p.ops[arm.op]
		for f in p.sources[aop.elem:][:aop.count] {
			if f.name == p.opts.union_tag {
				return true, .None
			}
		}
	}
	return false, .None
}

// A field's tag, read by `field_spelling`.
@(private = "file")
Field_Tag :: struct {
	key:       string, // the field's name in the format
	omitempty: bool,
	required:  bool,
	quoted:    bool, // Go's `,string`
	named:     bool, // the tag gave a name
	keep:      bool, // false for a tag of `-`
}

// A field's name and flags from its tag under `tag_key`: `name,omitempty,required`, `-` to omit, an empty
// name keeps the field's own and is not `named`. `quoted` is Go's `,string`, a number or bool written inside
// a string, which the plan refuses. A hook on a distinct type writes it. Other flags are ignored.
@(private = "file")
field_spelling :: proc(name, tag, tag_key: string) -> (t: Field_Tag) {
	value, ok := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), tag_key)
	if !ok {
		return {key = name, keep = true}
	}
	if value == "-" {
		return {}
	}
	t.key = value
	flags := ""
	if comma := strings.index_byte(value, ','); comma >= 0 {
		t.key, flags = value[:comma], value[comma + 1:]
	}
	t.named = t.key != ""
	if !t.named {
		t.key = name
	}
	for flag in strings.split_iterator(&flags, ",") {
		switch flag {
		case "omitempty":
			t.omitempty = true
		case "required":
			t.required = true
		case "string":
			t.quoted = true
		}
	}
	t.keep = true
	return
}
