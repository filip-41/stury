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
	Raw,
	Decoded,
	Number,
	Digits,     // `json.Digits`: a number, as its authored text
	Slice,
	Dynamic,
	Array,      // a fixed or an enumerated array
	Fixed_List, // `[dynamic; N]T`
	Map,
	Struct,
	Pointer,
	Union,      // a union: the arm a value's JSON kind picks (`Maybe` is the one-arm case)
	Any,        // an `any`: a scalar as its `Decoded` arm, a container as a tree (or `Raw`), boxed in the allocator
	Bit_Set,    // a `bit_set`: an array of its elements, read whole at its `]`
	Hook,       // a type the caller reads: any value, validated whole, handed to `Read_Shape.hooks[elem]`
}

// `Shape_Op.arm_of` is indexed by a value's class, the walk's `vc` (`VC_OBJECT` to `VC_NUMBER`, where
// `VC_LITERAL` is `true` or `false`), with `null` at 0.
SHAPE_CLASSES :: VC_NUMBER + 1
// `arm_of[0]` of a `#no_nil` union with no `Null` arm: it has no nil to read `null` as.
UNION_NO_NIL :: max(u8)

// The ops whose leaf writes every byte of its target, so a slot holding one needs no zeros first.
SHAPE_WHOLE_LEAVES :: bit_set[Shape_Kind]{.Bool, .Int, .Uint, .Float, .String}

// One op per `Plan_Op`, at the same index.
Shape_Op :: struct {
	map_info:   ^runtime.Map_Info,               // Map
	enum_info:  ^runtime.Type_Info_Enum,         // Enum_Int, Enum_Uint: the declared names and values
	first:      [4]u64,                          // Struct: bit b set when some field name starts with byte b
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
	// Union: some arm is a named struct, which an object may name in its `Shape_Run.union_tag` member. With
	// `arm_of[1]` 0, two or more such arms take an object, and only the tag tells them apart.
	tagged:     bool,
	// Struct: some field is a whole leaf and every name is plain printable ASCII, so `shape_take_members` may
	// read its members in one loop, matching a key by its raw bytes.
	members_fused:  bool,
	// Slice/Dynamic: the element is a whole leaf, so `shape_take_elements` may read its elements in one loop.
	elements_fused: bool,
}

// One field of a struct op (at the index of its `Plan_Field`) or one arm of a union op (after every field).
Shape_Field :: struct {
	name:   string, // the decoded JSON name, or a named struct arm's type name (borrowed from type info or the tag)
	offset: u32,    // a field's offset, or an arm's tag value
	op:     u32,
	// A member's compact form, `"name":`, as two little-endian words and the masks of the bytes it fills,
	// so a fused struct's predicted key and its colon are matched by two word compares. A name too long for
	// sixteen bytes has `colon_key[0]` zero, which no key's opening quote matches.
	colon_key:  [2]u64,
	colon_mask: [2]u64,
}

// A type's own reading (`Plan_Hook.read`): `text`, one value as authored and validated, into `dest`. It
// answers nil or an `Unmarshal_Error_Kind`, which `Shape_Fault` numbers alike.
Shape_Hook :: #type proc(text: []byte, dest: rawptr, allocator: runtime.Allocator) -> Maybe(Shape_Fault)

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
	// Every op reachable from the root is a fused struct, a sequence or a scalar leaf with no container arm,
	// and no list is of flat records, which the walk reads faster: `json/scan.shape_descend` reads the document.
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

// The `Error` kind the shape walk returns on a typed fault, `Shape_Run.fault` saying which. `Error_Kind`
// covers syntax and budget faults, none of them `.None`, so the two never meet.
TYPED_FAULT :: Error_Kind.None

// Why the shape walk refused a value. `Shape_Run.fault` holds it when the walk returns `TYPED_FAULT`. Each is
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

// `Shape_Frame.field` when no field is open: before the first key, or after an unknown one.
NO_FIELD :: max(u32)

// The seen words (`Shape_Run.wide`) the structs open at once share for their fields past the first 64: one
// struct reads at most 64 * (1 + SHAPE_WIDE_WORDS) fields, and more open at once is `.Out_Of_Memory`.
SHAPE_WIDE_WORDS :: 256

// One live container. The fields run from 8-byte to 4-byte with no padding, because the frame array is `---`
// and Odin zeroes a padded struct even then.
Shape_Frame :: struct {
	dest:   rawptr, // the container's target (nil when it is validated only)
	data:   rawptr, // Slice/Dynamic: the element buffer. Map: the target map, when `.First` reads into a fresh one. Struct: its seen words past field 63, once claimed
	seen:   u64,    // Struct: bit i set once field i (of the first 64) has appeared
	key_lo: u64,    // Struct, Map: the span of the member key now open, for the error path
	key_hi: u64,
	op:     u32,
	n:      u32,    // Slice/Dynamic/Array/Fixed_List: elements opened. Struct: 1 when its union's tag picked it, 2 once that tag member was passed
	cap:    u32,    // Slice/Dynamic: elements `data` holds (validated only: 0, then the count cap). Struct: the field predicted next
	field:  u32,    // Struct: the field now open, or NO_FIELD
}
#assert(size_of(Shape_Frame) == 56)

// The number token the walk validated last, as its digit runs folded it, so a number leaf decodes it without
// reading it again. The token's other facts follow from these and its text: `-` first, then
// `int_digits` digits, then a fraction when `frac_digits > 0`, then an exponent when the integer and
// fraction do not reach its end.
Shape_Number :: struct {
	mant:        u64, // every digit, folded. Wraps past 19 digits, which `int_digits + frac_digits` shows
	int_digits:  u64,
	frac_digits: u64,
	exp:         i64, // the exponent's value, within the scale cap the walk validated
}

// The shape walk's state. `frames[:sp]` are the live containers, and they are exactly the walk's
// `frames[:sp]`. A value at walk depth `sp` is read only when `sp == run.sp`. Deeper values belong to a
// container nothing reads (or to a `Raw`, which reads them as one span).
Shape_Run :: struct {
	shape:          ^Read_Shape,
	// `shape.ops` and `shape.fields`, which no walk resizes, one load from the run instead of two.
	ops:            [^]Shape_Op,
	fields:         [^]Shape_Field,
	frames:         ^[MAX_DEPTH]Shape_Frame,
	src:            []byte,
	allocator:      runtime.Allocator,
	sp:             u64,
	// The target the next value at depth `sp` fills, latched by a member key (or the root, by `scan_shape`).
	pend_dest:      rawptr,
	// The scalar now open, or the container being read whole into a `Raw`: what `shape_scalar` or
	// `shape_close` writes.
	cur_dest:       rawptr,
	raw_lo:         u64,    // Raw: where the container being read whole opened
	raw_sp:         u64,    // Raw: that container's walk frame index
	num:            Shape_Number, // written by the number leaf `parse_number_q` under `.Shape`
	pend_op:        u32,
	cur_op:         u32,
	// How many frames' steps the error path takes: every live frame, or one fewer for a fault that is about
	// the innermost container itself.
	fault_steps:    u32,
	fault:          Shape_Fault,
	pend_live:      bool,   // a member key or the root named a target for the next value
	cur_live:       bool,   // the scalar now open has a target
	reads:          bool,   // the value now open is read (by its leaf, its members or as a Raw)
	raw_open:       bool,   // a container is being read whole into a Raw
	borrow:         bool,
	refuse_unknown: bool,
	keep_first:     bool,
	read_over:      bool,   // `.All`: a repeated member is read over the earlier occurrence, not into a zeroed value
	enum_ints:      bool,   // an enum is read from its backing integer, not its name
	skip_pays:      bool,   // `scan_shape_lazy`'s probe chose the skipping walk, so `scan_shape` probes no more
	// The member key that names a tagged union's struct arm. Empty reads every union by shape alone.
	union_tag:      string,
	// SHAPE_WIDE_WORDS seen words, claimed from the front by open wide structs (`Shape_Frame.data`) and given
	// back at their close: wide[:wide_top] are claimed.
	wide:           []u64,
	wide_top:       u32,
	fault_at:       u64,    // the typed descent's `Out_Of_Memory`: the offset of the value it could not read
}
