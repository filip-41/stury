package core

import "base:runtime"

// What one read-shape op reads. A shape op is lowered from a plan op (whose `kind` is this enum), never cast
// from another type.
Shape_Kind :: enum u8 {
	Unsupported,
	Null,
	Bool,
	Int,
	Uint,
	Enum_Int,   // Int whose value must be a declared member
	Enum_Uint,
	Wide_Int,
	Wide_Uint,
	Float,
	String,
	Cstring,
	Rune,
	// A format's own types (`Plan_Format.types`): `Raw` is a value's source text, `Decoded` a scalar of any
	// kind, `Number` a number, and `Digits` a number's source text.
	Raw,
	Decoded,
	Number,
	Digits,
	Slice,
	Dynamic,
	Array,      // a fixed or an enumerated array
	Fixed_List, // `[dynamic; N]T`
	Map,
	Struct,
	Pointer,
	Union,      // a union; the value's class selects the arm (`Maybe` is the one-arm case)
	Any,        // an `any`: a scalar as its `Decoded` arm, a container as a tree (or `Raw`), boxed in the allocator
	Bit_Set,    // a `bit_set`: an array of its elements, read whole at its `]`
	Hook,       // a type the caller reads: any value, validated whole, handed to `Read_Shape.hooks[elem]`
}

// The classes of a value's `Kind` that select a union's arm (`Shape_Op.arm_of`): its kinds with `false` and
// `true` one class (`KIND_CLASS`). A format's walk indexes `arm_of` by its value's class, numbered as here.
Value_Class :: enum u8 {
	Null,
	Object,
	Array,
	String,
	Bool,
	Number,
}

// The class of each kind. Complete, so a kind added to `Kind` is a compile error here until it has a class.
KIND_CLASS :: [Kind]Value_Class {
	.Null   = .Null,
	.False  = .Bool,
	.True   = .Bool,
	.Number = .Number,
	.String = .String,
	.Array  = .Array,
	.Object = .Object,
}
SHAPE_CLASSES :: len(Value_Class)
// `arm_of[0]` of a `#no_nil` union with no `Null` arm: it has no nil to read `null` as.
UNION_NO_NIL :: max(u8)

// One op per `Plan_Op`, at the same index.
Shape_Op :: struct {
	map_info:   ^runtime.Map_Info,               // Map
	enum_info:  ^runtime.Type_Info_Enum,         // Enum_Int, Enum_Uint: the declared names and values
	first:      [4]u64,                          // Struct: bit b set when some field name starts with byte b (set by `Plan_Format.lowered`)
	required:   u64,                             // Struct: bit i set when field i (of the first 64) must appear. Bit_Set: the value bit 0 stands for, as i64 bits
	elem:       u32, // Slice/Dynamic/Array/Fixed_List/Pointer: the element op. Map: the value op. Struct: first field. Union: first arm. Hook: the hook
	key:        u32, // Map: the key op. Struct past 64 fields: its first word in `Read_Shape.wide`
	count:      u32, // Array/Fixed_List: element count or capacity. Struct: field count. Union: arm count. Bit_Set: values spanned
	stride:     u32, // Slice/Dynamic/Array/Fixed_List: element size. Pointer: pointee size. Map: value size
	size:       u32, // the target's own size
	align:      u32, // Slice/Dynamic: element alignment. Pointer: pointee alignment
	len_offset: u32, // Fixed_List
	tag_offset: u32, // Union
	tag_size:   u8,  // Union: the tag's width, 0 for a pure maybe (a pointer variant, nil is the pointer)
	// Union: per value class, 1 + the arm that takes it, or 0 for none. `null` (index 0) takes no arm but the
	// `Null` one of a `#no_nil` union: it reads as nil, or is refused where `UNION_NO_NIL` says there is none.
	arm_of:     [SHAPE_CLASSES]u8,
	width:      u8,  // Int/Uint/Enum_*/Float: byte width. Bit_Set: 8, an element's value read as an i64
	kind:       Shape_Kind,
	// Union: some arm is a named struct, which an object may select through its `Plan_Opts.union_tag` member.
	// When no arm is at `.Object`, two or more such arms accept an object and only the tag distinguishes them.
	tagged:     bool,
	// Struct: some field is a whole leaf and every name is plain printable ASCII, so a walk may read the members
	// in one loop and match keys by their raw bytes. Set by `Plan_Format.lowered`.
	members_fused:  bool,
	// Slice/Dynamic: the element is a whole leaf, so a walk may read the elements in one loop.
	// Set by `Plan_Format.lowered`.
	elements_fused: bool,
}

// One field of a struct op (at the index of its `Plan_Field`) or one arm of a union op (after every field).
Shape_Field :: struct {
	name:   string, // the decoded name, or a named struct arm's type name (borrowed from type info or the tag text)
	offset: u32,    // a field's offset, or an arm's tag value
	op:     u32,
	// A member's compact form, `"name":`, as two little-endian words and the masks of the bytes it fills,
	// so a fused struct's predicted key and its colon are matched by two word compares. A name too long for
	// sixteen bytes has `colon_key[0]` zero, which no key's opening quote matches. Set by `Plan_Format.lowered`.
	colon_key:  [2]u64,
	colon_mask: [2]u64,
}

// What a typed read does with a member or column that the target type does not name. Each format documents how
// it validates an ignored one.
Unknown_Fields :: enum u8 {
	Ignore,
	Refuse, // an `.Unknown_Field` error at its name
}

// A type's own reading (`Plan_Hook.read`): one validated value into `dest`. It answers nil or an
// `Unmarshal_Error_Kind`, which `Shape_Fault` numbers alike.
Shape_Hook :: #type proc(v: Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(Shape_Fault)

Read_Shape :: struct {
	ops:    [dynamic]Shape_Op,
	fields: [dynamic]Shape_Field,
	hooks:  []Shape_Hook,
	// For each struct past 64 fields, from its op's `key`: `(count - 1) / 64` words, bit i of word w set when
	// field 64 + 64 * w + i must appear.
	wide:   [dynamic]u64,
	// Zeroed bytes as wide as the widest map value in the shape: the value a new map entry is inserted with.
	zero:   []u8,
	root:   u32,
	// Every op reachable from the root is a fused struct, a sequence or a scalar leaf with no container arm, and
	// no list holds flat records (those have a faster loop). The format's walk may then read the document by
	// descent. Set by `Plan_Format.lowered`.
	descends: bool,
}

read_shape_destroy :: proc(r: ^Read_Shape) {
	delete(r.ops)
	delete(r.fields)
	delete(r.wide)
	delete(r.hooks, r.ops.allocator)
	delete(r.zero, r.ops.allocator)
	r^ = {}
}

// Reports whether field `k` of the struct op `op` is required. The first 64 fields use bit `k` of `op.required`;
// later fields use the words of `r.wide` starting at `op.key`.
shape_field_required :: proc(r: ^Read_Shape, op: ^Shape_Op, k: int) -> bool {
	if k < 64 {
		return op.required >> uint(k) & 1 != 0
	}
	return r.wide[int(op.key) + (k - 64) / 64] >> uint((k - 64) % 64) & 1 != 0
}

// Why a format's shape walk refused a value; the walk's run state stores it. Each is
// numbered as `Unmarshal_Error_Kind` numbers its namesake, so a hook's answer passes through unchanged,
// a kind with no namesake here included. Keep this order: the leaves answer with these small numbers.
Shape_Fault :: enum u8 {
	None,
	Wrong_Kind,
	Out_Of_Range,
	Not_A_Member,
	Wrong_Length,
	Missing_Field,
	Unknown_Field,
	Missing_Tag,
	Repeated_Tag,
	Out_Of_Memory,
}

// A walk frame's field when no field is open: before the first key, after an unknown key, or at a column no field
// reads.
NO_FIELD :: max(u32)
