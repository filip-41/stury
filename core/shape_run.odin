package core

// The typed walk's state, shared by every format that reads a value into a typed target along a read shape:
// a format's walk calls the transitions (shape_walk.odin) as it meets each value, key and close.

import "base:runtime"

// A walk's fault, two words, carried through every inlined return of a format's walk: a third field moves the
// spills of every walk. A format may number its own faults past the last `Error_Kind`.
Walk_Error :: struct {
	offset: u64,
	kind:   Error_Kind,
}

// The `Walk_Error` kind the shape walk returns on a typed fault; `Shape_Run.fault` holds the fault. No
// `Error_Kind` is 0, so this value never collides with one.
TYPED_FAULT :: Error_Kind(0)

// A value's walk class, which the transitions dispatch on: `Value_Class`'s numbering, with `null` and the
// booleans one literal class and 0 for no value. The container classes are adjacent and the scalar ones follow,
// so `vc <= VC_ARRAY` and `vc >= VC_STRING` split them. A union's `arm_of` is indexed by it; `null` reads
// `arm_of[0]`.
VC_NONE :: 0
VC_OBJECT :: 1
VC_ARRAY :: 2
VC_STRING :: 3
VC_LITERAL :: 4
VC_NUMBER :: 5
#assert(VC_OBJECT == int(KIND_CLASS[.Object]))
#assert(VC_ARRAY == int(KIND_CLASS[.Array]))
#assert(VC_STRING == int(KIND_CLASS[.String]))
#assert(VC_LITERAL == int(KIND_CLASS[.True]) && VC_LITERAL == int(KIND_CLASS[.False]))
#assert(VC_NUMBER == int(KIND_CLASS[.Number]))
#assert(int(KIND_CLASS[.Null]) == 0)

// The seen-field words (`Shape_Run.wide`) shared by all open structs for their fields past the first 64. One
// struct reads at most 64 * (1 + SHAPE_WIDE_WORDS) fields; needing more words at once is `.Out_Of_Memory`.
SHAPE_WIDE_WORDS :: 256

// One open container. The fields are ordered from 8-byte to 4-byte with no padding, because the frame array is
// declared `---` and Odin still zeroes a padded struct.
Shape_Frame :: struct {
	dest:   rawptr, // the container's target (nil when it is validated only)
	data:   rawptr, // Slice/Dynamic: the element buffer. Map: the target map, when `.First` reads into a fresh one. Struct: its claimed seen words for fields past 63
	seen:   u64,    // Struct: bit i set once field i (of the first 64) has appeared
	key_lo: u64,    // Struct, Map: the span of the open member key, for error paths
	key_hi: u64,
	op:     u32,
	n:      u32,    // Slice/Dynamic/Array/Fixed_List: elements opened. Struct: 1 when a union tag selected it, 2 after the tag member
	cap:    u32,    // Slice/Dynamic: element capacity of `data` (validate only: 0, then the count cap). Struct: the predicted next field
	field:  u32,    // Struct: the open field, or NO_FIELD
}
#assert(size_of(Shape_Frame) == 56)

// The last number token the walk validated, with its digits already folded, so a number leaf decodes it without
// rereading. The rest of the token follows from these fields and its text: an optional `-`, `int_digits` digits,
// a fraction when `frac_digits > 0`, and an exponent when the integer and fraction do not reach the token's end.
Shape_Number :: struct {
	mant:        u64, // all digits folded; wraps past 19 digits, which `int_digits + frac_digits` reveals
	int_digits:  u64,
	frac_digits: u64,
	exp:         i64, // the exponent's value, within the scale cap the walk validated
}

// The shape walk's state. `frames[:sp]` are the open containers, one per frame of the walk's `frames[:sp]`. A
// value at walk depth `sp` is read only when `sp == run.sp`. Deeper values belong to a container that is not
// read, or to a `Raw`, which reads them as one span.
Shape_Run :: struct {
	shape:          ^Read_Shape,
	// Copies of `shape.ops` and `shape.fields`, which no walk resizes, to save a load per access.
	ops:            [^]Shape_Op,
	fields:         [^]Shape_Field,
	frames:         ^[MAX_DEPTH]Shape_Frame,
	src:            []byte,
	allocator:      runtime.Allocator,
	sp:             u64,
	// The target of the next value at depth `sp`, set by a member key (or for the root, by the format's entry).
	pend_dest:      rawptr,
	// The target of the open scalar, or of the container being read whole into a `Raw`; `shape_scalar` or
	// `shape_close` writes it.
	cur_dest:       rawptr,
	raw_lo:         u64,    // Raw: the offset where the container being read whole opened
	raw_sp:         u64,    // Raw: that container's walk frame index
	num:            Shape_Number, // written by the format's number lexer as it checks a number
	pend_op:        u32,
	cur_op:         u32,
	// The number of frames whose steps the error path reports: every open frame, or one fewer for a fault about
	// the innermost container itself.
	fault_steps:    u32,
	fault:          Shape_Fault,
	pend_live:      bool,   // a member key or the root set a target for the next value
	cur_live:       bool,   // the open scalar has a target
	reads:          bool,   // the open value is read (by its leaf, its members or as a Raw)
	raw_open:       bool,   // a container is being read whole into a Raw
	borrow:         bool,
	refuse_unknown: bool,
	keep_first:     bool,
	read_over:      bool,   // `.All`: a repeated member is read over the earlier occurrence, not into a zeroed value
	enum_ints:      bool,   // an enum is read from its backing integer, not its name
	skip_pays:      bool,   // a format's lazy probe chose its skipping walk, so the walk stops probing
	// The member key that selects a tagged union's struct arm. When empty, unions are selected by shape alone.
	union_tag:      string,
	// SHAPE_WIDE_WORDS seen words. Open wide structs claim them from the front (`Shape_Frame.data`) and release
	// them at their close; wide[:wide_top] are claimed.
	wide:           []u64,
	wide_top:       u32,
	fault_at:       u64,    // the typed descent's `Out_Of_Memory`: the offset of the value it could not read
}
