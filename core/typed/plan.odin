// A type plan as one array of records, which `Hook_Regs.b` walks through. A struct's block holds one record per member
// in the type's order, then a `Never` record, and a list's, a map's or a pointer's holds its element's record, then a
// `Never` record. The record before `b` is always the one the next value is read by, so a value needs no frame lookup.
package typed

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:reflect"
import "core:strings"
import core ".."

// What a value is read as. The kinds up to `F64` are the ones the hook's hot compares take. The rest reach the cold
// paths, since every hot compare fails for them, so a type that has none of them pays nothing for them.
Read_Kind :: enum u8 {
	Never,
	Struct,
	Slice,
	Dynamic,
	Array,
	Map,
	String,
	Bool,
	I8,
	I16,
	I32,
	I64,
	U8,
	U16,
	U32,
	U64,
	F32,
	F64,
	Enum,
	Ptr, // `Meta.whole` for a `Maybe` of a pointer, whose element is replaced where a pointer's is read into
	Maybe, // holds its element in place, then a tag
	Union,
	Any,
	Hook,
	Raw,
	Number_Text,
	Number,
	Scalar,
	Cstring,
	Bool_Wide,
	Bit_Set,
	Bit_Elem, // an element of the `Bit_Set` whose block holds it
	Fixed_List,
	Required, // a struct with `required` members, or one that captures unknown members
	Inside, // a token of a value read whole
}

// A member's or element's record. `stride` is what a value moves `Hook_Regs.c` by: the element size in a list, 0
// elsewhere. `first` is a container's starting `Hook_Regs.b`.
Field :: struct {
	using key: core.Expected_Key,
	kind:      Read_Kind,
	omit:      bool, // a member a write leaves out when it is empty, the tag's `omitempty`
	key_size:  u8, // what a write stores of `key`, 0 for a member it must look at first: `omit`, the end, or a name to escape
	offset:    u32,
	stride:    u32,
	meta:      u32,
	first:     ^Field,
}

// The longest key text a write stores in line. A longer one is written through the format's string writer.
KEY_SIZE_MAX :: 240

// What only the cold paths read, indexed like `Plan.fields`.
Meta :: struct {
	name:       string,
	type:       typeid, // what a refusal of a value read by the record names
	map_info:   ^runtime.Map_Info,
	enum_info:  ^runtime.Type_Info_Enum,
	arms:       []Arm, // a `Union`'s
	read:       Unmarshal_Hook, // a `Hook`'s
	write:      Marshal_Hook, // a `Hook`'s
	required:   []i32, // on a struct's `Never` record, the members that must be present
	names:      u64, // a struct's members' `name_bit`s, so most keys it does not hold are known by one test
	lower:      i64, // a `Bit_Set`'s lowest element
	count:      u32, // a fixed array's length, a `Fixed_List`'s capacity, a `Bit_Set`'s bit count
	size:       u32,
	elem_size:  u32,
	align:      u32,
	tag:        u32, // a `Maybe`'s or `Union`'s tag offset, a `Fixed_List`'s length offset
	tag_size:   u8, // a `Union`'s, 0 for a pure maybe
	key_kind:   Read_Kind, // a `Map`'s key, a `Hook`'s own kind, which says when `omitempty` finds it empty
	block:      i32,
	members:    i32, // a struct's member count
	capture:    i32, // on a struct's `Never` record, the record of the map that captures unknown members, or -1
	whole:      bool,
	list:       bool, // `block` is a list's or map's, so `first` is past its element's record
	zeroed:     bool, // a list's new elements must start zeroed, since their readers may leave bytes unwritten
	tagged:     bool, // a `Union` that reads objects by `Plan.union_tag`, or such a union's named struct arm
	no_nil:     bool, // a `Union` that has no nil
}

// A union's arm: the value classes it takes, its tag value, and its tag name when the tag names it.
Arm :: struct {
	classes: bit_set[Value_Class],
	tag:     u32,
	fields:  i32,
	name:    string,
}

// The classes of value a union picks its arm by.
Value_Class :: enum u8 {
	Bool,
	Number,
	String,
	Object,
	Array,
}

@(private)
EVERY_CLASS :: bit_set[Value_Class]{.Bool, .Number, .String, .Object, .Array}

// How a plan reads an enum: `.Name` as a member's name, `.Int` as its backing integer.
Enum_Spelling :: enum u8 {
	Name,
	Int,
}

// The name a type's arm of a union goes by in place of its type name.
Tag_Name :: struct {
	type: typeid,
	name: string,
}

// One whole value a `Type_Hook` reads. `text` is the value as the format spells it, and `decoded` a string's text
// decoded, or `text` for any other kind. Both live for the call.
Hook_Value :: struct {
	kind:    core.Kind,
	text:    string,
	decoded: string,
}

// Reads `v` into `dest`, a value of the hook's type that holds what the target held, allocating with `allocator`. Nil
// reads it, and a kind refuses it at the value.
Unmarshal_Hook :: #type proc(v: Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind)

// Answers what to write in place of `v`, a value of the hook's type: any value, which is written as a value of its own
// type, through hooks too, and nil writes a null. A value the call must allocate comes from `allocator`, which lasts as
// long as the write. A kind refuses the value.
Marshal_Hook :: #type proc(v: rawptr, allocator: runtime.Allocator) -> (stand_in: any, refuse: core.Typed_Error_Kind)

// A type read or written by the caller's procs instead of by the plan. A nil `read` or `write` refuses the type on that
// side as `.Unsupported`, at the value.
Type_Hook :: struct {
	type:  typeid,
	read:  Unmarshal_Hook,
	write: Marshal_Hook,
}

// How a field with no name of its own in its tag is spelled from its Odin name.
Rename :: enum u8 {
	None,
	Camel, // `lastName`
	Pascal, // `LastName`
	Kebab, // `last-name`
	Screaming, // `LAST_NAME`
}

// What a plan is built with. `union_tag` is the member that names a struct arm of a union with two or more named struct
// arms, and `tag_names` the names that replace the arms' type names.
Plan_Options :: struct {
	enums:     Enum_Spelling,
	union_tag: string,
	tag_names: []Tag_Name,
	hooks:     []Type_Hook,
	rename:    Rename,
}

// A plan is a value the caller owns, for one type and one format. `plan_make` builds it and `plan_destroy` frees it. It
// is read only while reading, so a read needs nothing else and any number of reads may share it. A plan is not copied,
// since a copy and the original would free the same memory. It outlives every reader and writer that was given it.
Plan :: struct {
	fields:    []Field,
	// Each of `fields` followed by a `Never` record, the place a key found out of order moves the cursor to when no
	// later key may match by its bytes.
	solo:      []Field,
	meta:      []Meta,
	root:      ^Field,
	// A zeroed value as wide as the widest map value, the value a new entry is inserted with.
	zero:      []u8,
	// The format, and for a format whose writer reads them, the spec and option bytes a write by the plan takes.
	using as:  core.As,
	type:      typeid,
	// What a key's writing adds to its name, `Field.n` less the name's length.
	key_frame: u32,
	// The name bytes of records and of renamed or unescaped names.
	strings:   [dynamic]string,
	allocator: runtime.Allocator,
	// A format whose tokens do not type their values reads a document's node through this, where its plan maker sets it.
	node_read: proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^Plan, read: Read_Options, allocator: runtime.Allocator) -> core.Typed_Error,
	// The format's value writer, which holds its spelling compiled in, where its plan maker sets it.
	marshal:   Marshal_Text,
	// The options the plan was built with, which its reads and writes take, and so do the plans a write builds for a type
	// met in an `any`.
	using options: Plan_Options,
	// What `plan_make` refused a plan with, which a read or write given the refused plan returns.
	err:       core.Typed_Error,
	// A hash of the type, format and options the plan was built from, so a reader that kept what it bound to one plan's
	// records can tell a plan built the same at their address from another made there after the first was destroyed.
	stamp:     u64,
}

// Writes the value of `plan`'s type at `value` as `opts` says, to `stream` when it has a procedure, else to new bytes
// from `allocator`.
Marshal_Text :: #type proc(plan: ^Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error)

// The members a plan builder names in a refusal's path, the outermost ones when the type nests deeper.
@(private)
TRAIL_MAX :: 32

@(private)
Builder :: struct {
	using options: ^Plan_Options, // the plan's, which own their strings
	p:             ^Plan,
	fields:        [dynamic]Field,
	meta:          [dynamic]Meta,
	blocks:        map[typeid]i32,
	ends:          map[i32]i32, // a struct block's `Never` record
	widest:        int,
	err:           core.Typed_Error,
	// The names of the members being filled, outermost first, which a refusal reports as its path.
	trail:         [TRAIL_MAX]string,
	depth:         int,
}

// A format's plan maker, which `core.Spelling.plans` points at: `plan_build` and what the format's reads and writes add.
Plan_Make :: #type proc(T: typeid, as: core.As, opts: Plan_Options, allocator: runtime.Allocator) -> (Plan, core.Typed_Error)

// Builds the plan of `T` for format `as`, by the format's plan maker, allocating with `allocator`. A type the read
// cannot take is an error, with the path to it, and the plan is then the zero value with that error in `err`. `opts`'s
// strings and slices are read here only. A format with no plan maker gets `plan_build`'s plan, and a nil spelling is
// `.Bad_Option`.
plan_make :: proc(T: typeid, as: core.As, opts := Plan_Options{}, allocator := context.allocator) -> (Plan, core.Typed_Error) {
	if as.spelling == nil {
		err := core.Typed_Error{kind = .Bad_Option}
		return {err = err}, err
	}
	if as.spelling.plans != nil {
		return (Plan_Make)(as.spelling.plans)(T, as, opts, allocator)
	}
	return plan_build(T, as, opts, allocator)
}

// The plan of `T` for format `as` with nothing a format adds: no writer and no document read of its own. A format's
// plan maker starts from it, and so does a write's plan for a type met in an `any`.
plan_build :: proc(T: typeid, as: core.As, opts := Plan_Options{}, allocator := context.allocator) -> (p: Plan, err: core.Typed_Error) {
	context.allocator = allocator
	spelling := as.spelling
	p = {as = as, type = T, key_frame = u32(len(spelling.key_open) + len(spelling.key_close)), allocator = allocator}
	b := Builder{options = &p.options, p = &p}
	hooks, no_hooks := make([]Type_Hook, len(opts.hooks))
	tag_names, no_names := make([]Tag_Name, len(opts.tag_names))
	p.options = {enums = opts.enums, union_tag = owned_copy(&b, opts.union_tag), rename = opts.rename, hooks = hooks, tag_names = tag_names}
	copy(hooks, opts.hooks)
	for &t, i in tag_names {
		t = {opts.tag_names[i].type, owned_copy(&b, opts.tag_names[i].name)}
	}
	defer delete(b.blocks)
	defer delete(b.ends)
	// The root's block, then the block a value read whole passes through.
	if reserve_block(&b, 4, nil) >= 0 {
		fill(&b, 0, type_info_of(T), "", 0, 0)
		never(&b, 1)
		never(&b, 2)
		b.fields[2].kind = .Inside
		never(&b, 3)
	}
	if b.err.kind == .None {
		refuse_tag_members(&b)
	}
	solo, no_solo := make([]Field, 2 * len(b.fields))
	zero, no_zero := make([]u8, max(b.widest, 1))
	p.solo, p.zero, p.fields, p.meta = solo, zero, b.fields[:], b.meta[:]
	if no_hooks != nil || no_names != nil || no_solo != nil || no_zero != nil {
		refuse_plan(&b, .No_Memory)
	}
	if b.err.kind != .None {
		err = b.err
		own_names(&err)
		plan_destroy(&p)
		return {err = err}, err
	}
	for i in 0 ..< len(b.fields) {
		m := &b.meta[i]
		if m.block >= 0 {
			b.fields[i].first = &b.fields[int(m.block) + (1 if m.list else 0)]
		}
		if m.members > 0 {
			for &f, j in b.fields[m.block:][:m.members] {
				name := b.meta[int(m.block) + j].name
				m.names |= max(u64) if len(name) == 0 || f.n == 0 else name_bit(name)
			}
		}
	}
	for &f, i in b.fields {
		p.solo[2 * i] = f
		p.solo[2 * i + 1] = b.fields[1]
	}
	p.root = &b.fields[1]
	p.stamp = plan_stamp(T, as, opts)
	return
}

@(private)
plan_stamp :: proc(T: typeid, as: core.As, opts: Plan_Options) -> u64 {
	h := u64(0xcbf29ce484222325)
	mix :: proc(h: ^u64, x: u64) {
		h^ = (h^ ~ x) * 0x100000001b3
	}
	text :: proc(h: ^u64, s: string) {
		mix(h, u64(len(s)))
		for c in transmute([]u8)s {
			mix(h, u64(c))
		}
	}
	mix(&h, transmute(u64)T)
	mix(&h, u64(uintptr(as.spelling)))
	mix(&h, u64(as.max_depth) | u64(as.spec) << 32 | u64(transmute(u8)as.tolerate) << 40)
	for b in as.opts {
		mix(&h, u64(b))
	}
	mix(&h, u64(opts.enums) | u64(opts.rename) << 8)
	text(&h, opts.union_tag)
	for t in opts.tag_names {
		mix(&h, transmute(u64)t.type)
		text(&h, t.name)
	}
	for x in opts.hooks {
		mix(&h, transmute(u64)x.type)
		mix(&h, u64(uintptr(rawptr(x.read))))
		mix(&h, u64(uintptr(rawptr(x.write))))
	}
	return h
}

// Frees what `plan_make` allocated and sets `p` to the zero value.
plan_destroy :: proc(p: ^Plan) {
	context.allocator = p.allocator
	for s in p.strings {
		delete(s)
	}
	delete(p.strings)
	for &m in p.meta {
		delete(m.arms)
		delete(m.required)
	}
	delete(p.fields)
	delete(p.solo)
	delete(p.meta)
	delete(p.zero)
	delete(p.options.hooks)
	delete(p.options.tag_names)
	p^ = {}
}

// Adds a block of `n` records and returns its first, or -1 with the plan refused. A block of type `id` is recorded for the
// next use of the type and for a type that holds itself.
@(private)
reserve_block :: proc(b: ^Builder, n: int, id: typeid) -> i32 {
	at := len(b.fields)
	_, slot, _, no_slot := map_entry(&b.blocks, id)
	if no_slot != nil || resize(&b.fields, at + n) != nil || resize(&b.meta, at + n) != nil {
		refuse_plan(b, .No_Memory)
		return -1
	}
	slot^ = i32(at)
	return i32(at)
}

@(private)
never :: proc(b: ^Builder, at: int) {
	f := &b.fields[at]
	f.mask = {max(u64), max(u64)}
	f.kind = .Never
	b.meta[at] = {block = -1, capture = -1}
}

// Keeps `s` for as long as the plan, or frees it with the plan refused.
@(private)
owned :: proc(b: ^Builder, s: []u8) -> string {
	if _, failed := append(&b.p.strings, string(s)); failed != nil {
		refuse_plan(b, .No_Memory)
		delete(s)
		return ""
	}
	return string(s)
}

@(private)
owned_copy :: proc(b: ^Builder, s: string) -> string {
	text, failed := strings.clone(s)
	if failed != nil {
		refuse_plan(b, .No_Memory)
		return ""
	}
	return owned(b, transmute([]u8)text)
}

// Holds `name` as the format writes a key when the record can compare it. A format with no such writing, an element's
// record, which has no name, and a name with a byte a key may not hold as written leave `word` zero, for the hook to
// find.
@(private)
expect_name :: proc(b: ^Builder, f: ^Field, name: string) {
	f.mask = {max(u64), max(u64)}
	open, close := b.p.spelling.key_open, b.p.spelling.key_close
	if len(open) == 0 || len(name) == 0 {
		return
	}
	for i in 0 ..< len(name) {
		if name[i] < 0x20 || name[i] == '"' || name[i] == '\\' || name[i] >= 0x80 {
			return
		}
	}
	n := len(open) + len(name) + len(close)
	buf, failed := make([]u8, max(n, 16))
	if failed != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	copy(buf[copy(buf, open):], name)
	copy(buf[len(open) + len(name):], close)
	f.word, f.mask = {}, {}
	for i in 0 ..< min(n, 16) {
		f.word[i / 8] |= u64(buf[i]) << uint(8 * (i % 8))
		f.mask[i / 8] |= 0xff << uint(8 * (i % 8))
	}
	f.rest = raw_data(buf[16:])
	f.n = u32(n)
	owned(b, buf)
}

// One of 64 bits for a key's text, which is not empty.
@(private)
name_bit :: #force_inline proc "contextless" (name: string) -> u64 #no_bounds_check {
	return 1 << ((u32(name[0]) * 31 + u32(name[len(name) - 1]) * 5 + u32(len(name))) & 63)
}

// Records the plan's first refusal, `kind` at the members being filled and then the member `at`, with `text` saying
// what the kind's message names.
@(private)
refuse_plan :: proc(b: ^Builder, kind: core.Typed_Error_Kind, at := "", text := "") {
	if b.err.kind != .None {
		return
	}
	b.err.kind = kind
	b.err.want.text = text
	b.err.truncated = b.depth > TRAIL_MAX
	if len(at) > 0 {
		path_add(&b.err, core.Name(at))
	}
	#reverse for name in b.trail[:min(b.depth, TRAIL_MAX)] {
		path_add(&b.err, core.Name(name))
	}
	path_close(&b.err)
}

@(private)
fill :: proc(b: ^Builder, at: int, ti: ^runtime.Type_Info, name: string, offset, stride: u32) {
	if len(name) > 0 {
		if b.depth < TRAIL_MAX {
			b.trail[b.depth] = name
		}
		b.depth += 1
	}
	defer if len(name) > 0 {
		b.depth -= 1
	}
	base := runtime.type_info_base(ti)
	f := Field{offset = offset, stride = stride, meta = u32(at)}
	m := Meta{name = name, type = ti.id, size = u32(base.size), block = -1}
	// A record holds a size, offset, stride or count in 32 bits, and each of them is at most its type's size.
	if base.size > int(max(u32)) {
		refuse_plan(b, .Unsupported)
	}
	expect_name(b, &f, name)
	if hook, hooked := hook_of(b, ti.id); hooked {
		f.kind, m.read, m.write = .Hook, hook.read, hook.write
		m.key_kind = hooked_kind(base)
		if hook.read == nil && hook.write == nil {
			refuse_plan(b, .Unsupported)
		}
		b.fields[at], b.meta[at] = f, m
		return
	}
	switch ti.id {
	case typeid_of(Raw):
		f.kind = .Raw
	case typeid_of(Number_Text):
		f.kind = .Number_Text
	case typeid_of(core.Number):
		f.kind = .Number
	case typeid_of(Scalar):
		f.kind = .Scalar
	case typeid_of(any):
		f.kind = .Any
		m.block, m.list = any_block(b), true
	case:
		fill_base(b, &f, &m, ti, base)
	}
	b.fields[at], b.meta[at] = f, m
}

// The kind whose test for empty a hooked value of base type `base` takes, `.Never` for a type with none.
@(private)
hooked_kind :: proc(base: ^runtime.Type_Info) -> Read_Kind {
	#partial switch v in base.variant {
	case runtime.Type_Info_String:
		return .Cstring if v.is_cstring else .String
	case runtime.Type_Info_Slice:
		return .Slice
	case runtime.Type_Info_Dynamic_Array:
		return .Dynamic
	case runtime.Type_Info_Map:
		return .Map
	case runtime.Type_Info_Pointer:
		return .Ptr
	}
	return .Never
}

// Whether `ti` is an integer of at most `max_size` bytes that the plan's stores write.
@(private)
plain_integer :: proc(ti: ^runtime.Type_Info, max_size := 8) -> bool {
	base := runtime.type_info_base(ti)
	v := base.variant.(runtime.Type_Info_Integer)
	return base.size <= max_size && platform_order(v.endianness)
}

@(private)
platform_order :: proc(e: runtime.Platform_Endianness) -> bool {
	return e == .Platform || (e == .Little) == (ODIN_ENDIAN == .Little)
}

@(private)
integer_kind :: proc(base: ^runtime.Type_Info, v: runtime.Type_Info_Integer) -> Read_Kind {
	return Read_Kind(u8(Read_Kind.I8 if v.signed else Read_Kind.U8) + u8(intrinsics.count_trailing_zeros(base.size)))
}

// `fill` for a value the plan reads by its base type.
@(private)
fill_base :: proc(b: ^Builder, f: ^Field, m: ^Meta, ti, base: ^runtime.Type_Info) {
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		f.kind = .Bool if base.size == 1 else .Bool_Wide
	case runtime.Type_Info_Integer:
		if !plain_integer(base) {
			refuse_plan(b, .Unsupported)
			return
		}
		f.kind = integer_kind(base, v)
	case runtime.Type_Info_Float:
		if base.size < 4 || !platform_order(v.endianness) {
			refuse_plan(b, .Unsupported)
			return
		}
		f.kind = .F64 if base.size == 8 else .F32
	case runtime.Type_Info_String:
		if v.encoding != .UTF_8 {
			refuse_plan(b, .Unsupported)
			return
		}
		f.kind = .Cstring if v.is_cstring else .String
	case runtime.Type_Info_Slice:
		f.kind = .Slice
		list(b, m, ti, v.elem, u32(v.elem_size))
	case runtime.Type_Info_Dynamic_Array:
		f.kind = .Dynamic
		list(b, m, ti, v.elem, u32(v.elem_size))
	case runtime.Type_Info_Array:
		f.kind = .Array
		m.count = u32(v.count)
		list(b, m, ti, v.elem, u32(v.elem_size))
	case runtime.Type_Info_Enumerated_Array:
		f.kind = .Array
		m.count = u32(v.count)
		list(b, m, ti, v.elem, u32(v.elem_size))
	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		f.kind = .Fixed_List
		m.count, m.tag = u32(v.capacity), u32(v.len_offset)
		list(b, m, ti, v.elem, u32(v.elem_size))
	case runtime.Type_Info_Map:
		f.kind = .Map
		m.map_info = v.map_info
		m.key_kind = map_key_kind(b, v.key)
		if m.key_kind == .Enum {
			m.enum_info = &runtime.type_info_base(v.key).variant.(runtime.Type_Info_Enum)
		}
		b.widest = max(b.widest, v.value.size)
		list(b, m, ti, v.value, 0)
	case runtime.Type_Info_Enum:
		if !plain_integer(v.base) {
			refuse_plan(b, .Unsupported)
			return
		}
		f.kind = .Enum
		m.enum_info = &base.variant.(runtime.Type_Info_Enum)
	case runtime.Type_Info_Pointer:
		if v.elem == nil {
			refuse_plan(b, .Unsupported)
			return
		}
		f.kind = .Ptr
		list(b, m, ti, v.elem, 0)
	case runtime.Type_Info_Union:
		fill_union(b, f, m, ti, v)
	case runtime.Type_Info_Struct:
		if v.flags & {.raw_union} != {} || v.soa_kind != .None {
			refuse_plan(b, .Unsupported)
			return
		}
		fill_struct(b, f, m, ti, v)
	case runtime.Type_Info_Bit_Set:
		fill_bit_set(b, f, m, ti, v)
	case:
		refuse_plan(b, .Unsupported)
	}
	// A list's length is its stride's multiple, so an element of no size could spell no length.
	#partial switch f.kind {
	case .Slice, .Dynamic, .Array, .Fixed_List:
		if m.elem_size == 0 {
			refuse_plan(b, .Unsupported)
		}
	}
}

@(private)
map_key_kind :: proc(b: ^Builder, key: ^runtime.Type_Info) -> Read_Kind {
	base := runtime.type_info_base(key)
	#partial switch v in base.variant {
	case runtime.Type_Info_String:
		return .Cstring if v.is_cstring else .String
	case runtime.Type_Info_Enum:
		return .Enum
	case runtime.Type_Info_Integer:
		if plain_integer(base) {
			return integer_kind(base, v)
		}
	}
	refuse_plan(b, .Unsupported)
	return .Never
}

@(private)
fill_bit_set :: proc(b: ^Builder, f: ^Field, m: ^Meta, ti: ^runtime.Type_Info, v: runtime.Type_Info_Bit_Set) {
	elem := runtime.type_info_base(v.elem)
	_, is_int := elem.variant.(runtime.Type_Info_Integer)
	_, is_enum := elem.variant.(runtime.Type_Info_Enum)
	if !is_int && !is_enum || (v.underlying != nil && !plain_integer(v.underlying, 16)) {
		refuse_plan(b, .Unsupported)
		return
	}
	f.kind = .Bit_Set
	m.list = true
	if at, ok := b.blocks[ti.id]; ok {
		m.block = at
		return
	}
	m.block = reserve_block(b, 2, ti.id)
	if m.block < 0 {
		return
	}
	never(b, int(m.block))
	never(b, int(m.block) + 1)
	e := &b.fields[m.block]
	e.kind, e.meta = .Bit_Elem, u32(m.block)
	em := &b.meta[m.block]
	em.lower, em.count = v.lower, u32(v.upper - v.lower + 1)
	if is_enum {
		em.enum_info = &elem.variant.(runtime.Type_Info_Enum)
	}
}

// The block of an `any`'s boxed containers: a `map[string]any`'s record, a `Never` record, a `[dynamic]any`'s record,
// a `Never` record.
@(private)
any_block :: proc(b: ^Builder) -> i32 {
	if at, ok := b.blocks[typeid_of(any)]; ok {
		return at
	}
	at := reserve_block(b, 4, typeid_of(any))
	if at < 0 {
		return -1
	}
	never(b, int(at) + 1)
	never(b, int(at) + 3)
	fill(b, int(at), type_info_of(map[string]any), "", 0, 0)
	fill(b, int(at) + 2, type_info_of([dynamic]any), "", 0, 0)
	return at
}

@(private)
list :: proc(b: ^Builder, m: ^Meta, ti, elem: ^runtime.Type_Info, stride: u32) {
	base := runtime.type_info_base(elem)
	m.list = true
	m.elem_size = u32(base.size)
	m.align = u32(base.align)
	#partial switch _ in base.variant {
	case runtime.Type_Info_Boolean, runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_String:
		// A hook is handed the element as its `dest`, which must hold what the target held.
		_, m.zeroed = hook_of(b, elem.id)
	case:
		m.zeroed = true
	}
	if at, ok := b.blocks[ti.id]; ok {
		m.block = at
		return
	}
	m.block = reserve_block(b, 2, ti.id)
	if m.block < 0 {
		return
	}
	never(b, int(m.block) + 1)
	fill(b, int(m.block), elem, "", 0, stride)
}

// A union reads a value into the arm its class picks, so no two arms may take one class, except named struct arms under
// a `union_tag`, which leave objects to the tag.
@(private)
fill_union :: proc(b: ^Builder, f: ^Field, m: ^Meta, ti: ^runtime.Type_Info, v: runtime.Type_Info_Union) {
	f.kind = .Union
	m.tag, m.no_nil = u32(v.tag_offset), v.no_nil
	m.tag_size = 0 if reflect.type_info_union_is_pure_maybe(v) else u8(v.tag_type.size)
	// A `Maybe`, the one arm reads on the hot kinds' own path.
	if len(v.variants) == 1 && !v.no_nil {
		elem := runtime.type_info_base(v.variants[0])
		if p, is_ptr := elem.variant.(runtime.Type_Info_Pointer); is_ptr && p.elem != nil && m.tag_size == 0 {
			f.kind = .Ptr
			m.whole = true
			list(b, m, ti, p.elem, 0)
			return
		}
		if m.tag_size == 1 {
			f.kind = .Maybe
			list(b, m, ti, v.variants[0], 0)
			return
		}
	}
	if at, ok := b.blocks[ti.id]; ok {
		m.block = at
	} else {
		m.block = reserve_block(b, len(v.variants) + 1, ti.id)
		if m.block < 0 {
			return
		}
		never(b, int(m.block) + len(v.variants))
		for arm, k in v.variants {
			fill(b, int(m.block) + k, arm, "", 0, 0)
		}
	}
	arms, failed := make([]Arm, len(v.variants))
	if failed != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	m.arms = arms
	named: int
	for arm, k in v.variants {
		n, is_named := arm.variant.(runtime.Type_Info_Named)
		_, is_struct := runtime.type_info_base(arm).variant.(runtime.Type_Info_Struct)
		m.arms[k] = {classes_of(b, arm, 0), u32(k if v.no_nil else k + 1), m.block + i32(k), ""}
		if is_named && is_struct {
			named += 1
			m.arms[k].name = n.name
			for t in b.tag_names {
				if t.type == arm.id {
					m.arms[k].name = t.name
				}
			}
		}
	}
	m.tagged = named >= 2 && len(b.union_tag) > 0
	taken: bit_set[Value_Class]
	untagged_objects := 0
	for &arm, k in m.arms {
		if m.tagged && len(arm.name) > 0 {
			b.meta[int(m.block) + k].tagged = true
		} else {
			arm.name = ""
			if .Object in arm.classes {
				untagged_objects += 1
			}
		}
		if arm.classes & taken - {.Object} != {} {
			refuse_plan(b, .Ambiguous_Union, text = "two arms read the same kind of value")
		}
		taken |= arm.classes
	}
	if untagged_objects > 1 || (m.tagged && untagged_objects > 0) {
		refuse_plan(b, .Ambiguous_Union, text = "two arms read objects, so set Plan_Options.union_tag to the member that names the arm")
	}
}

// Refuses a struct arm of a union read by its tag that has a member keyed as the tag, which the tag's value would fill.
// The pass runs once the type is filled, since an arm that holds the union has its members filled after the union.
@(private)
refuse_tag_members :: proc(b: ^Builder) {
	for m in b.meta {
		for arm in m.arms {
			if len(arm.name) == 0 {
				continue
			}
			s := &b.meta[arm.fields]
			for j in 0 ..< int(s.members) {
				if name := b.meta[int(s.block) + j].name; name == b.union_tag {
					refuse_plan(b, .Unsupported, name)
				}
			}
		}
	}
}

// The classes of value `ti` reads. `depth` bounds a union that holds a pointer to itself.
@(private)
classes_of :: proc(b: ^Builder, ti: ^runtime.Type_Info, depth: int) -> (c: bit_set[Value_Class]) {
	if depth > 16 {
		return
	}
	if _, hooked := hook_of(b, ti.id); hooked {
		return EVERY_CLASS
	}
	switch ti.id {
	case typeid_of(Raw), typeid_of(any):
		return EVERY_CLASS
	case typeid_of(Number_Text), typeid_of(core.Number):
		return {.Number}
	case typeid_of(Scalar):
		return {.String, .Bool, .Number}
	}
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		return {.Bool}
	case runtime.Type_Info_Integer, runtime.Type_Info_Float:
		return {.Number}
	case runtime.Type_Info_String:
		return {.String}
	case runtime.Type_Info_Struct, runtime.Type_Info_Map:
		return {.Object}
	case runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Array, runtime.Type_Info_Enumerated_Array, runtime.Type_Info_Fixed_Capacity_Dynamic_Array, runtime.Type_Info_Bit_Set:
		return {.Array}
	case runtime.Type_Info_Enum:
		return {.String, .Number}
	case runtime.Type_Info_Pointer:
		return classes_of(b, v.elem, depth + 1) if v.elem != nil else {}
	case runtime.Type_Info_Union:
		for arm in v.variants {
			c |= classes_of(b, arm, depth + 1)
		}
	}
	return
}

// A member as `lay_out` found it.
@(private)
Member :: struct {
	name:     string,
	type:     ^runtime.Type_Info,
	offset:   uintptr,
	required: bool,
	omit:     bool,
}

// A struct's block holds its members, a `Never` record that holds in its `Meta` what is true of every use of the struct,
// and, when it captures unknown members, the record of the capturing map and a `Never` record. The block's layout is
// fixed before any member's type is read, so a recursive type meets it whole.
@(private)
fill_struct :: proc(b: ^Builder, f: ^Field, m: ^Meta, ti: ^runtime.Type_Info, v: runtime.Type_Info_Struct) {
	f.kind = .Struct
	if at, ok := b.blocks[ti.id]; ok {
		m.block, m.members = at, b.ends[at] - at
		if end := &b.meta[b.ends[at]]; len(end.required) > 0 || end.capture >= 0 {
			f.kind = .Required
		}
		return
	}
	members: [dynamic]Member
	defer delete(members)
	capture: Maybe(Member)
	lay_out(b, v, 0, &members, &capture)
	for x, i in members {
		for y in members[:i] {
			if x.name == y.name {
				refuse_plan(b, .Unsupported, x.name)
			}
		}
	}
	n := len(members)
	at := reserve_block(b, n + 1 + (2 if capture != nil else 0), ti.id)
	if at < 0 {
		return
	}
	_, end_slot, _, no_end := map_entry(&b.ends, at)
	if no_end != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	end_slot^ = at + i32(n)
	m.block, m.members = at, i32(n)
	end := at + i32(n)
	never(b, int(end))
	required: [dynamic]i32
	for x, i in members {
		if x.required {
			// A write would leave out what the read then finds missing.
			if x.omit {
				refuse_plan(b, .Unsupported, x.name)
			}
			if _, failed := append(&required, i32(i)); failed != nil {
				refuse_plan(b, .No_Memory)
			}
		}
	}
	b.meta[end].required = required[:]
	if c, ok := capture.?; ok {
		b.meta[end].capture = end + 1
		never(b, int(end) + 2)
		fill(b, int(end) + 1, c.type, "", u32(c.offset), 0)
	}
	if len(required) > 0 || capture != nil {
		f.kind = .Required
	}
	for x, i in members {
		fill(b, int(at) + i, x.type, x.name, u32(x.offset), 0)
		r := &b.fields[int(at) + i]
		r.omit = x.omit
		if !x.omit && r.n <= KEY_SIZE_MAX && plain_name(x.name) {
			r.key_size = u8(r.n)
		}
	}
}

// Whether a name's written text is its bytes whatever the options of a write: letters, digits, `_` and `-`.
@(private)
plain_name :: proc(name: string) -> bool {
	for c in transmute([]u8)name {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
		case:
			return false
		}
	}
	return true
}

// Collects a struct's members, with a `using` member its tag gives no name flattened into the struct that holds it.
@(private)
lay_out :: proc(b: ^Builder, v: runtime.Type_Info_Struct, base: uintptr, out: ^[dynamic]Member, capture: ^Maybe(Member)) {
	for i in 0 ..< int(v.field_count) {
		tag, bad_flag := field_tag(b, v.names[i], v.tags[i])
		if len(bad_flag) > 0 {
			refuse_plan(b, .Bad_Tag, v.names[i], bad_flag)
			return
		}
		if !tag.keep {
			continue
		}
		_, hooked := hook_of(b, v.types[i].id)
		if inner, is_struct := runtime.type_info_base(v.types[i]).variant.(runtime.Type_Info_Struct); is_struct && v.usings[i] && !tag.named && !hooked && .raw_union not_in inner.flags && inner.soa_kind == .None {
			lay_out(b, inner, base + v.offsets[i], out, capture)
			continue
		}
		x := Member{tag.name, v.types[i], base + v.offsets[i], tag.required, tag.omit}
		if tag.unknown {
			if tag.required {
				refuse_plan(b, .Bad_Tag, tag.name, "required")
			}
			if v.types[i].id != typeid_of(map[string]Raw) || capture^ != nil {
				refuse_plan(b, .Unsupported, tag.name)
			}
			capture^ = x
			continue
		}
		if _, failed := append(out, x); failed != nil {
			refuse_plan(b, .No_Memory)
			return
		}
	}
}

@(private)
hook_of :: proc(b: ^Builder, T: typeid) -> (hook: Type_Hook, ok: bool) {
	for h in b.hooks {
		if h.type == T {
			return h, true
		}
	}
	return
}
