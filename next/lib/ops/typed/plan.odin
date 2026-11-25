package typed

import "base:runtime"
import "core:time"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// A typed read fills an Odin value from a text during the walk, with no document between them. A plan is one type's
// reading as an array of records, which the read's register `b` walks. A struct's block holds one record per member in
// the type's order, then an `End` record, and a list's, a map's or a wrapper's block holds its element's record, then an
// `End` record. `b` points one past the record the next value is read by, so `b[-1]` reads a value and `b[0]` is the
// record whose key a struct expects next.

// What a record reads a value as. The kinds up to `F64` are the ones the hook's hot compares take, and every other kind
// fails them and reaches the cold paths, so a type that holds none of them pays nothing for them.
@(private)
Read_Kind :: enum u8 {
	End, // the end of a block: no key matches it and no value is read by it
	Struct,
	Required, // a struct with `required` members, opened as a struct is and closed through the check
	Slice,
	Dynamic,
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
	Array, // a fixed or enumerated array, read in place
	Map,
	Enum,
	Bit_Set,
	Bit_Elem, // an element of the `Bit_Set` whose block holds it
	Bool_Wide, // `b16`, `b32` and `b64`
	Maybe, // its element in place, then its tag
	Ptr, // its element, allocated when the pointer is nil
	Union,
	Raw, // the value's text as written
	Time, // `time.Time` from a date-time with an offset
	Dead, // the record a refused read reads every token by, which takes every token to a cold path
	Position, // the record the elements of an array a struct reads by position go through, to its members in turn
}

// A record. `word` is a member's key as a token's second word holds it, `head` its first eight bytes and `tail` its last
// eight, or for a key of at most eight bytes the mask of its bytes. `first` is the `b` a container's value starts its
// block with, `stride` what a value moves `c` by (the element size in a list, 0 elsewhere), and `meta` the record's
// index in `Plan.meta`.
@(private)
Record :: struct {
	using expected: hook.Expected_Key,
	first:  ^Record,
	offset: u32,
	stride: u32,
	meta:   u32,
	kind:   Read_Kind,
	_:      [3]u8,
}

#assert(size_of(Record) == hook.EXPECTED_STRIDE)

// The `word` of a record that no key matches.
@(private)
NO_KEY :: max(u64)

// The bits of a token's second word a key match compares: its length, kind, role and `SPELLING_DECODE`.
@(private)
KEY_MASK :: u64(0xFFFF_FFFF) | u64(0xFFFF) << 32 | u64(tape.SPELLING_DECODE) << 48

// What only the cold paths read of a record, indexed by `Record.meta`.
@(private)
Meta :: struct {
	name:      string, // a member's key, empty for any other record
	field:     string, // a member's Odin name, which outlives the plan
	type:      typeid,
	enum_info: ^runtime.Type_Info_Enum, // an `Enum`'s, a `Bit_Set`'s of enum elements, a `Map`'s enum key's
	map_info:  ^runtime.Map_Info,
	size:      u32, // the value's size, a list's element size
	align:     u32,
	count:     u32, // a fixed array's length, a struct's members, a `Bit_Set`'s bits, a union's arms
	tag:       u32, // a `Maybe`'s or `Union`'s tag offset
	slots:     u32, // a struct's member table in `Plan.slots`, `slots_n` long, a power of two
	slots_n:   u32,
	arms:      u32, // a union's first arm in `Plan.arms`
	required:  u32, // a struct's: one past its last `required` member
	solo:      u32, // a member's solo pair in `Plan.records`, its copy and an `End`, by the pair's `End`
	lower:     i64, // a `Bit_Set`'s lowest element
	tag_size:  u8, // a `Union`'s tag bytes
	key_kind:  Read_Kind, // a `Map`'s key: `String`, an integer kind or `Enum`
	zeroed:    bool, // a list whose new elements start zeroed, as their readers may leave bytes unwritten
	frees:     bool, // a value of the record may hold a block: a string, a list, a map or a pointer, or one in place
	must:      bool, // a `required` member
	omit_empty: bool, // a member a write leaves out when its value is empty (`omitempty`)
	omit_unset: bool, // a member a write leaves out when it is a nil pointer, `Maybe` or union (`omitunset`)
	signed:    bool, // a `Bit_Set` of integers
}

// A union's arm: the classes of value it takes and its tag value, its block's `b`.
@(private)
Arm :: struct {
	classes: Classes,
	tag:     u32,
	first:   u32,
}

// The classes of value a union picks its arm by.
@(private)
Class :: enum u8 {
	Bool,
	Number,
	String,
	Object,
	Array,
	Bytes, // a byte string, which a list of `u8` takes
}

@(private)
Classes :: bit_set[Class; u8]

// A value's text as written, its quotes and brackets included, which a read keeps whatever the value is.
Raw :: distinct string

// How a plan spells an enum: by a member's name, or by its value.
@(private)
Enum_Spelling :: enum u8 {
	Name,
	Int,
}

// How a member with no name of its own in its tag is spelled from its Odin name.
@(private)
Rename :: enum u8 {
	None,
	Camel, // `lastName`
	Pascal, // `LastName`
	Kebab, // `last-name`
	Screaming, // `LAST_NAME`
	Snake, // `last_name`
}

// What a plan is built with.
Plan_Options :: struct {
	enums:  Enum_Spelling,
	rename: Rename,
}

// A type's reading for the formats whose tags are read under `tag`. The caller owns it: `plan_make` builds it and
// `plan_destroy` frees it. It is only read by a read, so any number of reads on any threads may share it. It is not
// copied, since a copy and the original free the same memory.
Plan :: struct {
	records:   []Record,
	meta:      []Meta,
	slots:     []u32, // the structs' member tables, a member's index plus one by its key's hash, 0 for an empty slot
	arms:      []Arm,
	root:      ^Record, // the `b` the read starts with
	type:      typeid,
	size:      int, // the bytes of a value of `type`
	tag:       string, // the struct tag key the members' names were read under
	options:   Plan_Options,
	strings:   []u8, // the names the plan spells itself, renamed or unescaped
	allocator: runtime.Allocator,
}

// The tag key every format reads where a member has no tag under the format's own.
@(private)
SHARED_TAG :: "stury"

// Frees what `plan` holds and leaves it zero.
plan_destroy :: proc(plan: ^Plan) {
	context.allocator = plan.allocator
	delete(plan.records)
	delete(plan.meta)
	delete(plan.slots)
	delete(plan.arms)
	delete(plan.strings)
	plan^ = {}
}

// The plan of `T` for the formats whose struct tags are read under `tag`, allocated with `allocator`. A type the read
// cannot take is `Bad_Option` naming the member, or the type, that it cannot take, with nothing allocated.
@(require_results)
plan_make :: proc(T: typeid, tag: string, opts := Plan_Options{}, allocator := context.allocator) -> (p: Plan, err: tape.Error) {
	context.allocator = allocator
	b := Builder{tag = tag, options = opts}
	b.blocks.allocator, b.ends.allocator = allocator, allocator
	defer delete(b.blocks)
	defer delete(b.ends)
	defer delete(b.spelled)
	root := plan_block(&b, 1, nil)
	fill(&b, root, type_info_of(T), "")
	if b.err == nil {
		b.err = plan_finish(&b, &p)
	}
	if b.err != nil {
		delete(b.records)
		delete(b.meta)
		delete(b.slots)
		delete(b.arms)
		delete(b.strings)
		return {}, b.err
	}
	p.type, p.size, p.tag, p.options, p.allocator = T, type_info_of(T).size, tag, opts, allocator
	p.root = &p.records[root + 1]
	return p, nil
}

// The state of a plan build. Records refer to each other by index until `plan_finish` makes the indexes addresses.
@(private)
Builder :: struct {
	tag:     string,
	options: Plan_Options,
	records: [dynamic]Record,
	meta:    [dynamic]Meta,
	slots:   [dynamic]u32,
	arms:    [dynamic]Arm,
	strings: [dynamic]u8,
	// The block of each type whose block was made, so a type that holds itself reads its own block.
	blocks:  map[typeid]int,
	// The `End` record of each struct block, by the block's first record, whose meta holds the struct's own data.
	ends:    map[int]int,
	err:     tape.Error,
	// The names of `strings`, as spans until `plan_finish` gives them their place.
	spelled: [dynamic]Spelled,
}

// A name the plan spells itself, at `strings[lo:][:n]`, for meta `at`.
@(private)
Spelled :: struct {
	at, lo, n: int,
}

// Appends a block of `n` records and its `End`, each with a meta of its own, and returns its first record. `type`
// records the block for its next use when it is not nil.
@(private)
plan_block :: proc(b: ^Builder, n: int, type: typeid) -> int {
	at := len(b.records)
	for _ in 0 ..= n {
		if _, err := append(&b.records, Record{word = NO_KEY, meta = u32(len(b.meta))}); err != nil {
			b.err = err
			return at
		}
		if _, err := append(&b.meta, Meta{}); err != nil {
			b.err = err
			return at
		}
	}
	if type != nil {
		b.blocks[type] = at
	}
	return at
}

// Fills record `at` to read a value of type `ti`, named `name` as a struct's member.
@(private)
fill :: proc(b: ^Builder, at: int, ti: ^runtime.Type_Info, name: string) {
	if b.err != nil {
		return
	}
	m := &b.meta[b.records[at].meta]
	m.type, m.size, m.align, m.frees = ti.id, u32(ti.size), u32(ti.align), holds_block(ti)
	kind := Read_Kind.End
	if ti.id == time.Time || ti.id == Raw {
		set_kind(b, at, .Time if ti.id == time.Time else .Raw)
		return
	}
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case ^runtime.Type_Info_Integer:
		if v.endianness == .Platform || v.endianness == (.Little if ODIN_ENDIAN == .Little else .Big) {
			switch base.size {
			case 1: kind = .I8 if v.signed else .U8
			case 2: kind = .I16 if v.signed else .U16
			case 4: kind = .I32 if v.signed else .U32
			case 8: kind = .I64 if v.signed else .U64
			}
		}
	case ^runtime.Type_Info_Float:
		if v.endianness == .Platform {
			kind = .F32 if base.size == 4 else .F64 if base.size == 8 else .End
		}
	case ^runtime.Type_Info_Boolean:
		kind = .Bool if base.size == 1 else .Bool_Wide
	case ^runtime.Type_Info_String:
		if !v.is_cstring && v.encoding == .UTF_8 {
			kind = .String
		}
	case ^runtime.Type_Info_Struct:
		if v.soa_kind == .None && .raw_union not_in v.flags {
			fill_struct(b, at, ti, v)
			return
		}
	case ^runtime.Type_Info_Slice:
		fill_list(b, at, ti, .Slice, v.elem, 0)
		return
	case ^runtime.Type_Info_Dynamic_Array:
		fill_list(b, at, ti, .Dynamic, v.elem, 0)
		return
	case ^runtime.Type_Info_Array:
		fill_list(b, at, ti, .Array, v.elem, v.count)
		return
	case ^runtime.Type_Info_Enumerated_Array:
		if !v.is_sparse {
			fill_list(b, at, ti, .Array, v.elem, v.count)
			return
		}
	case ^runtime.Type_Info_Map:
		fill_map(b, at, ti, v)
		return
	case ^runtime.Type_Info_Enum:
		if int_kind(v.base) != .End {
			m.enum_info = v
			kind = .Enum
		}
	case ^runtime.Type_Info_Bit_Set:
		fill_bit_set(b, at, ti, v)
		return
	case ^runtime.Type_Info_Pointer:
		if v.elem != nil {
			fill_wrapper(b, at, ti, .Ptr, v.elem)
			return
		}
	case ^runtime.Type_Info_Union:
		fill_union(b, at, ti, v)
		return
	}
	if kind == .End {
		refuse_type(b, name, ti)
		return
	}
	set_kind(b, at, kind)
}

// Whether a value of `ti` may hold a block a read allocates, in it or in what it holds in place, which is no cycle.
@(private)
holds_block :: proc(ti: ^runtime.Type_Info) -> bool {
	#partial switch v in runtime.type_info_base(ti).variant {
	case ^runtime.Type_Info_String, ^runtime.Type_Info_Slice, ^runtime.Type_Info_Dynamic_Array, ^runtime.Type_Info_Map, ^runtime.Type_Info_Pointer:
		return true
	case ^runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			if holds_block(v.types[i]) {
				return true
			}
		}
	case ^runtime.Type_Info_Array:
		return holds_block(v.elem)
	case ^runtime.Type_Info_Enumerated_Array:
		return holds_block(v.elem)
	case ^runtime.Type_Info_Union:
		for variant in v.variants {
			if holds_block(variant) {
				return true
			}
		}
	}
	return false
}

// The integer kind of `ti`, `End` for a type that is none the read takes.
@(private)
int_kind :: proc(ti: ^runtime.Type_Info) -> Read_Kind {
	base := runtime.type_info_base(ti)
	if v, ok := base.variant.(^runtime.Type_Info_Integer); ok && (v.endianness == .Platform || v.endianness == (.Little if ODIN_ENDIAN == .Little else .Big)) {
		switch base.size {
		case 1: return .I8 if v.signed else .U8
		case 2: return .I16 if v.signed else .U16
		case 4: return .I32 if v.signed else .U32
		case 8: return .I64 if v.signed else .U64
		}
	}
	return .End
}

@(private)
set_kind :: #force_inline proc(b: ^Builder, at: int, kind: Read_Kind) {
	b.records[at].kind = kind
}

// Refuses the plan for `ti`, which no read takes, naming the member `name` that holds it, or the type.
@(private)
refuse_type :: proc(b: ^Builder, name: string, ti: ^runtime.Type_Info) {
	if b.err == nil {
		b.err = tape.Bad_Option{name if name != "" else "type"}
	}
}

// Fills record `at` as a list `kind` of `count` elements of `elem`: its block holds the element's record.
@(private)
fill_list :: proc(b: ^Builder, at: int, ti: ^runtime.Type_Info, kind: Read_Kind, elem: ^runtime.Type_Info, count: int) {
	if elem.size == 0 {
		refuse_type(b, "", ti)
		return
	}
	set_kind(b, at, kind)
	m := &b.meta[b.records[at].meta]
	m.size, m.align, m.count = u32(elem.size), u32(elem.align), u32(count)
	m.zeroed = !written_whole(elem)
	block, made := b.blocks[ti.id]
	if !made {
		block = plan_block(b, 1, ti.id)
		b.records[block].stride = u32(elem.size)
		fill(b, block, elem, "")
	}
	b.records[at].first = (^Record)(uintptr(block + 1))
}

// Whether a read of a value of `ti` writes each of its bytes, so a list of them needs no zeroing.
@(private)
written_whole :: proc(ti: ^runtime.Type_Info) -> bool {
	#partial switch v in runtime.type_info_base(ti).variant {
	case ^runtime.Type_Info_Integer, ^runtime.Type_Info_Float, ^runtime.Type_Info_Boolean, ^runtime.Type_Info_String, ^runtime.Type_Info_Enum, ^runtime.Type_Info_Slice:
		return true
	}
	return false
}

// Fills record `at` as a wrapper `kind` of `elem`: a pointer, or a `Maybe` whose tag follows its element.
@(private)
fill_wrapper :: proc(b: ^Builder, at: int, ti: ^runtime.Type_Info, kind: Read_Kind, elem: ^runtime.Type_Info) {
	set_kind(b, at, kind)
	m := &b.meta[b.records[at].meta]
	m.size, m.align = u32(elem.size), u32(elem.align)
	block, made := b.blocks[ti.id]
	if !made {
		block = plan_block(b, 1, ti.id)
		fill(b, block, elem, "")
	}
	b.records[at].first = (^Record)(uintptr(block + 1))
}

@(private)
fill_union :: proc(b: ^Builder, at: int, ti: ^runtime.Type_Info, v: ^runtime.Type_Info_Union) {
	m := &b.meta[b.records[at].meta]
	if len(v.variants) == 1 && !v.no_nil {
		m.tag, m.tag_size = u32(v.tag_offset), u8(v.tag_type.size)
		fill_wrapper(b, at, ti, .Maybe, v.variants[0])
		return
	}
	if len(v.variants) == 0 || v.tag_type == nil {
		refuse_type(b, "", ti)
		return
	}
	set_kind(b, at, .Union)
	m.tag, m.tag_size, m.count = u32(v.tag_offset), u8(v.tag_type.size), u32(len(v.variants))
	// The arms are placed before the variants are filled, as a variant may hold a union whose arms come first.
	first := len(b.arms)
	m.arms = u32(first)
	if err := resize(&b.arms, first + len(v.variants)); err != nil {
		b.err = err
		return
	}
	taken: Classes
	for variant, i in v.variants {
		block := plan_block(b, 1, nil)
		fill(b, block, variant, "")
		classes := classes_of(b, variant)
		if classes & taken != {} || classes == {} {
			refuse_type(b, "", ti)
			return
		}
		taken += classes
		// A union with no nil numbers its arms from 0, and one with a nil from 1.
		tag := u32(i) if v.no_nil else u32(i + 1)
		b.arms[first + i] = Arm{classes, tag, u32(block + 1)}
	}
}

// The classes of value a read of `ti` takes.
@(private)
classes_of :: proc(b: ^Builder, ti: ^runtime.Type_Info) -> Classes {
	if ti.id == time.Time {
		return {.String}
	}
	if ti.id == Raw {
		return {.Bool, .Number, .String, .Object, .Array, .Bytes}
	}
	#partial switch v in runtime.type_info_base(ti).variant {
	case ^runtime.Type_Info_Integer, ^runtime.Type_Info_Float:
		return {.Number}
	case ^runtime.Type_Info_Boolean:
		return {.Bool}
	case ^runtime.Type_Info_String:
		return {.String}
	case ^runtime.Type_Info_Enum:
		return {.Number} if b.options.enums == .Int else {.String}
	case ^runtime.Type_Info_Struct, ^runtime.Type_Info_Map:
		return {.Object}
	case ^runtime.Type_Info_Slice:
		return {.Array, .Bytes} if runtime.type_info_base(v.elem).id == u8 else {.Array}
	case ^runtime.Type_Info_Dynamic_Array:
		return {.Array, .Bytes} if runtime.type_info_base(v.elem).id == u8 else {.Array}
	case ^runtime.Type_Info_Array, ^runtime.Type_Info_Enumerated_Array, ^runtime.Type_Info_Bit_Set:
		return {.Array}
	case ^runtime.Type_Info_Pointer:
		return classes_of(b, v.elem) if v.elem != nil else {}
	case ^runtime.Type_Info_Union:
		c: Classes
		for variant in v.variants {
			c += classes_of(b, variant)
		}
		return c
	}
	return {}
}

@(private)
fill_map :: proc(b: ^Builder, at: int, ti: ^runtime.Type_Info, v: ^runtime.Type_Info_Map) {
	m := &b.meta[b.records[at].meta]
	m.map_info = v.map_info
	key := runtime.type_info_base(v.key)
	#partial switch k in key.variant {
	case ^runtime.Type_Info_String:
		if !k.is_cstring && k.encoding == .UTF_8 {
			m.key_kind = .String
		}
	case ^runtime.Type_Info_Integer:
		m.key_kind = int_kind(key)
	case ^runtime.Type_Info_Enum:
		if int_kind(k.base) != .End {
			m.key_kind, m.enum_info = .Enum, k
		}
	}
	if m.key_kind == .End {
		refuse_type(b, "", ti)
		return
	}
	set_kind(b, at, .Map)
	m.size, m.align = u32(v.value.size), u32(v.value.align)
	block, made := b.blocks[ti.id]
	if !made {
		block = plan_block(b, 1, ti.id)
		fill(b, block, v.value, "")
	}
	b.records[at].first = (^Record)(uintptr(block + 1))
}

@(private)
fill_bit_set :: proc(b: ^Builder, at: int, ti: ^runtime.Type_Info, v: ^runtime.Type_Info_Bit_Set) {
	m := &b.meta[b.records[at].meta]
	elem := runtime.type_info_base(v.elem)
	#partial switch e in elem.variant {
	case ^runtime.Type_Info_Enum:
		m.enum_info = e
		if b_int, ok := runtime.type_info_base(e.base).variant.(^runtime.Type_Info_Integer); ok {
			m.signed = b_int.signed
		}
	case ^runtime.Type_Info_Integer:
		m.signed = e.signed
	case ^runtime.Type_Info_Rune:
		m.signed = true
	case:
		refuse_type(b, "", ti)
		return
	}
	set_kind(b, at, .Bit_Set)
	m.lower, m.count = v.lower, u32(v.upper - v.lower + 1)
	elem_meta := m^
	block, made := b.blocks[ti.id]
	if !made {
		block = plan_block(b, 1, ti.id)
		set_kind(b, block, .Bit_Elem)
		b.meta[b.records[block].meta] = elem_meta
	}
	b.records[at].first = (^Record)(uintptr(block + 1))
}

// A member of a struct as its block reads it: its key, its Odin name, its type and its offset in the outermost struct.
@(private)
Member :: struct {
	name:     string,
	field:    string,
	type:     ^runtime.Type_Info,
	offset:   uintptr,
	required: bool,
	omit_empty, omit_unset: bool,
	spelled:  bool, // `name` is a span of `Builder.strings`, which `plan_finish` places
	lo:       int,
}

// Fills record `at` to read a struct. Each struct type has one block, whose `End` record's meta holds what a read of
// the struct needs: its member count, its last `required` member and its member table. A record of a struct still
// being filled, as a struct that holds itself through a pointer or a list, takes its kind in `plan_finish`.
@(private)
fill_struct :: proc(b: ^Builder, at: int, ti: ^runtime.Type_Info, v: ^runtime.Type_Info_Struct) {
	b.records[at].kind = .Struct
	if block, made := b.blocks[ti.id]; made {
		b.records[at].first = (^Record)(uintptr(block))
		return
	}
	members: [dynamic]Member
	defer delete(members)
	gather_members(b, v, 0, &members)
	if b.err != nil {
		return
	}
	block := plan_block(b, len(members), ti.id)
	if b.err != nil {
		return
	}
	b.records[at].first = (^Record)(uintptr(block))
	b.ends[block] = block + len(members)
	end := &b.meta[b.records[block + len(members)].meta]
	n := 4
	for n < 2 * len(members) {
		n *= 2
	}
	end.type, end.count, end.slots, end.slots_n = ti.id, u32(len(members)), u32(len(b.slots)), u32(n)
	if err := resize(&b.slots, len(b.slots) + n); err != nil {
		b.err = err
		return
	}
	for &member, i in members {
		r := block + i
		m := &b.meta[b.records[r].meta]
		m.must, m.field = member.required, member.field
		m.omit_empty, m.omit_unset = member.omit_empty, member.omit_unset
		if member.required {
			b.meta[b.records[block + len(members)].meta].required = u32(i + 1)
		}
		b.records[r].offset = u32(member.offset)
		if member.spelled {
			if _, err := append(&b.spelled, Spelled{int(b.records[r].meta), member.lo, len(member.name)}); err != nil {
				b.err = err
				return
			}
		} else {
			m.name = member.name
		}
		fill(b, r, member.type, member.field)
		if b.err != nil {
			return
		}
	}
}


// Appends the members of struct `v` at `base` to `out`, those of a `using` member in its place.
@(private)
gather_members :: proc(b: ^Builder, v: ^runtime.Type_Info_Struct, base: uintptr, out: ^[dynamic]Member) {
	for i in 0 ..< int(v.field_count) {
		name, tag, type, offset := v.names[i], v.tags[i], v.types[i], base + v.offsets[i]
		if v.usings[i] {
			if inner, ok := runtime.type_info_base(type).variant.(^runtime.Type_Info_Struct); ok {
				gather_members(b, inner, offset, out)
				continue
			}
		}
		if name == "_" {
			continue
		}
		t, ok := member_tag(b, name, tag)
		if !ok {
			if b.err == nil {
				b.err = tape.Bad_Option{name}
			}
			return
		}
		if t.skip {
			continue
		}
		member := Member{name = t.name, field = name, type = type, offset = offset, required = t.required, omit_empty = t.omit_empty, omit_unset = t.omit_unset, spelled = t.spelled, lo = t.lo}
		if _, err := append(out, member); err != nil {
			b.err = err
			return
		}
	}
}

// A member's tag as a plan reads it.
@(private)
Member_Tag :: struct {
	name:     string,
	spelled:  bool, // `name` is `Builder.strings[lo:][:len(name)]`
	lo:       int,
	skip:     bool,
	required: bool,
	omit_empty, omit_unset: bool,
}

// Reads the tag of member `name`: the value under the plan's tag key, or else under `stury`, is `name,flag,flag`, or `-`
// to leave the member out. An empty name keeps the member's own, renamed by `Plan_Options.rename`. In the name a
// backslash makes the byte after it literal. The flags are `required`, and `omitempty` and `omitunset`, which only a
// write reads. False for any other flag.
@(private)
member_tag :: proc(b: ^Builder, name, tag: string) -> (t: Member_Tag, ok: bool) {
	value, found := tag_lookup(tag, b.tag)
	if !found {
		value, found = tag_lookup(tag, SHARED_TAG)
	}
	if found && value == "-" {
		return {skip = true}, true
	}
	i := 0
	escaped := false
	for ; i < len(value) && value[i] != ','; i += 1 {
		if value[i] == '\\' && i + 1 < len(value) {
			escaped = true
			i += 1
		}
	}
	if i > 0 {
		if !escaped {
			t.name = value[:i]
		} else {
			t.lo, t.spelled = len(b.strings), true
			for k := 0; k < i; k += 1 {
				if value[k] == '\\' && k + 1 < i {
					k += 1
				}
				append(&b.strings, value[k])
			}
			t.name = string(b.strings[t.lo:])
		}
	} else if b.options.rename != .None {
		t.lo, t.spelled = len(b.strings), true
		renamed(b, name)
		t.name = string(b.strings[t.lo:])
	} else {
		t.name = name
	}
	flags := value[min(i + 1, len(value)):]
	for len(flags) > 0 {
		k := 0
		for k < len(flags) && flags[k] != ',' {
			k += 1
		}
		switch flags[:k] {
		case "":
		case "omitempty":
			t.omit_empty = true
		case "omitunset":
			t.omit_unset = true
		case "required":
			t.required = true
		case:
			return {}, false
		}
		flags = flags[min(k + 1, len(flags)):]
	}
	return t, true
}

// The value of key `key` in the struct tag `tag`, written `key:"value"`, with a backslash escaping the byte after it.
@(private)
tag_lookup :: proc(tag, key: string) -> (string, bool) {
	t := tag
	for len(t) > 0 {
		i := 0
		for i < len(t) && t[i] == ' ' {
			i += 1
		}
		t = t[i:]
		k := 0
		for k < len(t) && t[k] > ' ' && t[k] != ':' && t[k] != '"' {
			k += 1
		}
		if k == 0 || k + 1 >= len(t) || t[k] != ':' || t[k + 1] != '"' {
			return "", false
		}
		name := t[:k]
		t = t[k + 2:]
		e := 0
		for e < len(t) && t[e] != '"' {
			if t[e] == '\\' {
				e += 1
			}
			e += 1
		}
		if e >= len(t) {
			return "", false
		}
		if name == key {
			return t[:e], true
		}
		t = t[e + 1:]
	}
	return "", false
}

// Appends `name` to `Builder.strings` as `Plan_Options.rename` spells it. A name splits into words at each `_` and before
// each upper case letter that follows a lower case one.
@(private)
renamed :: proc(b: ^Builder, name: string) {
	first := true
	upper_next := false
	for i := 0; i < len(name); i += 1 {
		c := name[i]
		if c == '_' {
			upper_next = !first
			if b.options.rename == .Kebab || b.options.rename == .Snake || b.options.rename == .Screaming {
				if !first {
					append(&b.strings, '-' if b.options.rename == .Kebab else '_')
				}
				upper_next = false
			}
			continue
		}
		word_start := i > 0 && is_upper(c) && is_lower(name[i - 1])
		if word_start {
			switch b.options.rename {
			case .Kebab: append(&b.strings, '-')
			case .Snake, .Screaming: append(&b.strings, '_')
			case .Camel, .Pascal: upper_next = true
			case .None:
			}
		}
		switch b.options.rename {
		case .Camel:
			c = to_upper(c) if upper_next else to_lower(c) if first || !word_start && !upper_next else c
		case .Pascal:
			c = to_upper(c) if upper_next || first else to_lower(c)
		case .Kebab, .Snake:
			c = to_lower(c)
		case .Screaming:
			c = to_upper(c)
		case .None:
		}
		append(&b.strings, c)
		first, upper_next = false, false
	}
}

@(private)
is_upper :: #force_inline proc "contextless" (c: u8) -> bool {return c >= 'A' && c <= 'Z'}
@(private)
is_lower :: #force_inline proc "contextless" (c: u8) -> bool {return c >= 'a' && c <= 'z'}
@(private)
to_upper :: #force_inline proc "contextless" (c: u8) -> u8 {return c - 32 if is_lower(c) else c}
@(private)
to_lower :: #force_inline proc "contextless" (c: u8) -> u8 {return c + 32 if is_upper(c) else c}

// Moves the builder's lists into `p`, places the names the plan spells, gives each member record its key and solo pair,
// each struct record its struct's data and each struct its member table, and turns the records' block indexes into
// addresses. A member's solo pair is the `b` of a read whose keys all take the member table, as under `.First` once
// keys come out of order.
@(private)
plan_finish :: proc(b: ^Builder, p: ^Plan) -> tape.Error {
	for block, end in b.ends {
		for k in 0 ..< int(b.meta[b.records[end].meta].count) {
			b.meta[b.records[block + k].meta].solo = u32(len(b.records) + 1)
			if _, err := append(&b.records, b.records[block + k], Record{word = NO_KEY, meta = b.records[end].meta}); err != nil {
				return err
			}
		}
	}
	shrink(&b.records)
	shrink(&b.meta)
	shrink(&b.strings)
	p.records, p.meta, p.slots, p.arms, p.strings = b.records[:], b.meta[:], b.slots[:], b.arms[:], b.strings[:]
	for s in b.spelled {
		p.meta[s.at].name = string(p.strings[s.lo:][:s.n])
	}
	for block, end in b.ends {
		m := &p.meta[p.records[end].meta]
		table := p.slots[m.slots:][:m.slots_n]
		for k in 0 ..< int(m.count) {
			member := &p.records[block + k]
			name := p.meta[member.meta].name
			key_of(member, name)
			at := tape.text_hash(transmute([]u8)name) & (m.slots_n - 1)
			for table[at] != 0 {
				if p.meta[p.records[block + int(table[at]) - 1].meta].name == name {
					return tape.Bad_Option{p.meta[member.meta].field}
				}
				at = (at + 1) & (m.slots_n - 1)
			}
			table[at] = u32(k + 1)
		}
	}
	for &r in p.records {
		if r.kind == .Struct {
			end := p.meta[p.records[b.ends[int(uintptr(r.first))]].meta]
			m := &p.meta[r.meta]
			m.count, m.required, m.slots, m.slots_n = end.count, end.required, end.slots, end.slots_n
			r.kind = .Required if end.required > 0 else .Struct
		}
		if r.first != nil {
			r.first = &p.records[int(uintptr(r.first))]
		}
	}
	return nil
}

// Sets the key fields of member record `r` named `name`. A name with a byte a JSON string escapes is no key a token
// spells with nothing to decode, so it has `NO_KEY` and its member is found by its name alone, and a walk that matches
// an expected key by its bytes never takes an escape for it.
@(private)
key_of :: proc "contextless" (r: ^Record, name: string) {
	n := len(name)
	for c in transmute([]u8)name {
		if c == '"' || c == '\\' || c < 0x20 {
			r.word = NO_KEY
			return
		}
	}
	r.word = tape.key_word(u64(n))
	r.head, r.tail = 0, 0
	for i in 0 ..< min(n, 8) {
		r.head |= u64(name[i]) << (8 * uint(i))
	}
	if n <= 8 {
		r.tail = ~u64(0) >> (64 - 8 * uint(n)) if n > 0 else 0
		return
	}
	for i in 0 ..< 8 {
		r.tail |= u64(name[n - 8 + i]) << (8 * uint(i))
	}
}

// The integer bounds of the integer kinds, by kind.
@(private, rodata)
INT_LO := #partial [Read_Kind]i64 {
	.I8 = i64(min(i8)), .I16 = i64(min(i16)), .I32 = i64(min(i32)), .I64 = min(i64),
	.U8 = 0, .U16 = 0, .U32 = 0, .U64 = 0,
}

@(private, rodata)
INT_HI := #partial [Read_Kind]i64 {
	.I8 = i64(max(i8)), .I16 = i64(max(i16)), .I32 = i64(max(i32)), .I64 = max(i64),
	.U8 = i64(max(u8)), .U16 = i64(max(u16)), .U32 = i64(max(u32)), .U64 = max(i64),
}
