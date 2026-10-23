package walk

import "base:runtime"

// The `Error` kind the shape walk returns on a typed fault, `Shape_Run.fault` saying which. `Error_Kind`
// covers syntax and budget faults, none of them `.None`, so the two never meet.
TYPED_FAULT :: Error_Kind.None

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
