package typed

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The read is a walk hook. Its registers: `b` points one past the record that reads the next value, `c` is the struct
// the members are read into or the list's next element, and `a` is one past the list's room, or `NO_LIMIT` outside a
// list, so one compare guards every value and a value in a struct pays no branch on what holds it.

// The options of a typed read beyond the read's `tape.Options`.
Unmarshal_Options :: struct {
	// A string with nothing to decode, and a `Raw`, is a slice of the text in place of a copy, so the text must outlive
	// the target. Without it each string the read copies is one allocation of its own, which the caller frees alone,
	// and an arena as the read's allocator gives the speed of one block for all of them.
	borrow_strings: bool,
	// A member the type does not name refuses the read, where by default the read passes it.
	refuse_unknown: bool,
	// When set, a refusal fills it with the path from the target's root to the value refused: a member by its key, an
	// element by its index. A name is the plan's, or a span of the text for a map's key, as written. A read with no
	// `plan` frees the plan it makes, so it names a member whose key the plan spelled (unescaped) by its Odin name.
	path:           ^[dynamic]tape.Step,
	// The plan of the target's type to read by, made once and shared by any number of reads. A read with none makes
	// one for the call.
	plan:           ^Plan,
}

@(private)
NO_LIMIT :: max(u64)

// An open container, with the registers its close gives back. `data` is a list's first element, a map, a fixed array
// or bit set's base, or a raw value's first byte. `seen` holds which members of a struct were read, kept from the first
// key that arrives out of order, as until then the cursor says, with `SEEN_ON` set then, and `run` is the cursor the
// members marked last reached. A struct's or a fixed array's `seen` has `SEEN_TARGET` when its bytes may hold the
// target's own values, and a map's is 1 when the map held entries at its open. `owner` reads the container and
// `target` is where it goes when the record before `b` is a wrapper's. `key` is a map's last key.
@(private)
Frame :: struct {
	a, b, c: u64,
	data:    rawptr,
	seen:    u64,
	run:     u64,
	owner:   ^Record,
	target:  uintptr,
	key:     tape.Token,
}

@(private)
SEEN_ON :: u64(1) << 63

// The open levels a read keeps in its own frame. A deeper text moves them to the read's allocator.
@(private)
FRAME_ROOM :: 64

// The target bytes a read keeps in its own frame. A larger target's are kept in the read's allocator.
@(private)
BEFORE_ROOM :: 128

// The state of one read, which a format's walk reaches through its hook, a `Text_Reader` or a `Cells_Reader`.
@(private)
Reader :: struct {
	base:      [^]u8,
	len:       u64,
	frames:    [^]Frame,
	sp:        int,
	room:      int, // the frames `frames` holds
	plan:      ^Plan,
	format:    ^tape.Format,
	home:      [^]Frame, // the frames in the read's caller's frame
	borrow:    bool,
	first:     bool, // repeated keys under `.First`
	unknown:   bool, // `refuse_unknown`
	made:             bool, // the read made its plan, and frees it on return
	dead:             bool, // a refusal ended the read, and the walk judges the rest of the text
	optional_seconds: bool, // a date-time may omit `:SS`, as TOML 1.1 allows
	err:       tape.Error, // the first refusal
	// The registers of the outermost wrapper whose element is being read, nil outside one. A refusal of the element is
	// the wrapper's, as its registers name the element's place.
	outer:     ^hook.Regs,
	path:      ^[dynamic]tape.Step,
	zero:      []u8, // zeroes as wide as the widest map value read, for a new entry
	key:       [2]u64, // the last map key read, and whether its entry is new, which an empty cell takes back
	fresh:     bool,
	// The target, and its bytes as the read found them, so a repeat frees what the read put in the target and nothing
	// the target held, and sets back what the target held.
	target:    uintptr,
	before:    []u8,
	// The blocks the target held that the read went into, as `before` holds the target's: its pointees and maps.
	held:      [dynamic]Held,
	// One past the head of the last tag 1 the walk gave, so a number that starts there is a count of seconds since the
	// epoch, as a `time.Time` takes it, which the format notes. 0 for none, as a value after a tag starts past the tag's first byte.
	epoch:     u64,
	allocator: runtime.Allocator, // the caller's, counted under `Budget.memory`
	caller:    runtime.Allocator, // the one a dynamic array or map read keeps for its owner
	ctx:       runtime.Context,
}

// A block the target held that the read went into: a pointee at `at` with its bytes as the read found them, or a map
// whose header is at `at` with a copy of the entries it held.
@(private)
Held :: struct {
	at:      uintptr,
	bytes:   []u8,
	entries: runtime.Raw_Map,
	info:    ^runtime.Map_Info,
}

// The hook of a read of a format whose values carry their kinds, as JSON's, CBOR's and TOML's do.
Text_Reader :: struct {
	using reader: Reader,
	expected:     ^hook.Expected_Memo,
	protocol:     hook.Protocol({.Skips, .Expects}, hook.Unused, hook.Unused, hook.Unused),
}

// The hook of a read of a delimited text, whose records hold cells by the header's places. Once a record's keys mapped
// its columns to members, every later record of a text of fixed width is replayed: the walk gives its cells with no
// key, each read by that map, with `b` at its column.
Cells_Reader :: struct {
	using reader: Reader,
	dropped:      u64,
	alike:        bool,
	replay:       hook.Replay,
	columns:      [hook.COLUMN_BITS]Column, // each column the first record took, in its order
	taken:        int,
	learn:        Learn,
	row:          [2]Record, // the records of a target that is one row, which `one_row` reads its records by
	protocol:     hook.Protocol({.Skips, .Columns, .Cell_Values}, hook.Unused, hook.Unused, hook.Unused),
}

// A column of a replayed record: the record that reads its cell, the member's place, and how a cell with nothing to
// decode is read with no call.
@(private)
Column :: struct {
	rec:    ^Record,
	offset: u32,
	kind:   Read_Kind,
	read:   Cell_Read,
}

// How a replayed record reads a cell with nothing to decode.
@(private)
Cell_Read :: enum u8 {
	Hook, // through the hook, as a kind the replay has no read of its own for
	String,
	I64,
	F64,
	Number, // another number kind, through `store_number`
	Bool,
}

// Where a `Cells_Reader` stands in learning its columns.
@(private)
Learn :: enum u8 {
	Before, // no record opened yet
	Learning, // in the first record
	Ready, // the first record mapped every column it took
	Off, // the columns are read by their keys
}

// The open frames while a delimited text's record is open: the read's own, the root list's and the record's.
@(private)
RECORD_SP :: 3

// The text reader's hook, `reader_hook` with `number` the format's reader of a number token.
text_hook :: #force_inline proc "contextless" (h: ^Text_Reader, s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> (hook.Regs, hook.Action) {
	return reader_hook(&h.reader, s, t, number, false)
}

// The delimited reader's hook: `reader_hook` for cells, which learns the columns in the first record and replays the
// records after it.
cells_hook :: #force_inline proc "contextless" (h: ^Cells_Reader, s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> (hook.Regs, hook.Action) {
	// A record is replayed only once its columns are learnt.
	if h.replay.replays {
		return replay_cell(h, s, t, number)
	}
	if h.learn == .Ready {
		if t.kind == .Object && t.role == .Value && h.sp == RECORD_SP - 1 && h.replay.fixed {
			r, a := reader_hook(&h.reader, s, t, number, true)
			if a == .Next && h.sp == RECORD_SP {
				// The record's cells come with no keys, each read by its column.
				h.replay.replays = true
				r.b = u64(uintptr(&h.columns[0]))
			}
			return r, a
		}
		return reader_hook(&h.reader, s, t, number, true)
	}
	return learn_columns(h, s, t, number)
}
// The records a refused read reads every token by: a `Dead` record, which takes every value to a cold path, and an
// `End` record, which every key misses.
@(private, rodata)
DEAD_BLOCK := [2]Record{{word = NO_KEY, kind = .Dead}, {word = NO_KEY, kind = .End}}

// The records of a struct read by position: a `Position` record, which takes every element to a cold path, and an
// `End` record.
@(private, rodata)
POSITION_BLOCK := [2]Record{{word = NO_KEY, kind = .Position}, {word = NO_KEY, kind = .End}}

// The registers of a refused read: no room, so every value takes the list's cold path.
@(private)
dead_regs :: #force_inline proc "contextless" () -> hook.Regs {
	return {0, u64(uintptr(&DEAD_BLOCK[1])), 0}
}

// Reads `src`, a text of `format`, into `target`, a value of type `T`, by `read.plan` or by a plan made for the call,
// through `walk`, the format's walk for hook `H`, a `Text_Reader`, a `Refusing_Reader` or a `Cells_Reader`. `tag` is the
// format's struct tag key. A plan for another type or tag is `Bad_Option{"plan"}`, a nil target `Bad_Option{"target"}`,
// and a text in pieces `Bad_Option{"pieces"}`. Repeated keys follow `opts.dups`, the format's own for `.Default`.
// `.All` and `.Group` are `Bad_Option{"dups"}`, as a member holds one value. The read takes `.Refuse` as `.Last`, as the
// repeats it refuses are judged by a `Refusing_Reader` or by the format, which faults on a repeat or judges the header
// of a delimited text before the read. A member the text does not hold keeps the target's value, and a value the type
// does not take is a `Fault` of kind `.Refused`, whose detail is a `Typed_Refusal`, at the value's first byte, unless the
// text fails as the format's `validate` fails it, which is then the error. Each string and list is an allocation of its
// own from `caller`, so an arena gives the speed of one block, and under `read.borrow_strings` a string with nothing to
// decode is a span of `src`.
@(require_results)
read :: proc(src: []u8, target: rawptr, T: typeid, format: ^tape.Format, tag: string, opts: tape.Options, read: Unmarshal_Options, caller: runtime.Allocator, $H: typeid, $walk: proc "contextless" (src: []u8, opts: tape.Options, h: ^H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool)) -> tape.Error {
	if e := tape.options_refused(format, opts); e != nil {
		return e
	}
	if target == nil {
		return tape.Bad_Option{"target"}
	}
	if opts.pieces != nil {
		return tape.Bad_Option{"pieces"}
	}
	dups := format.dups if opts.dups == .Default else opts.dups
	if dups == .All || dups == .Group {
		return tape.Bad_Option{"dups"}
	}
	plan := read.plan
	made: Plan
	if plan == nil {
		err: tape.Error
		if made, err = plan_make(T, tag, {}, caller); err != nil {
			return err
		}
		plan = &made
	}
	defer if plan == &made {
		plan_destroy(&made)
	}
	if plan.type != T || plan.tag != tag {
		return tape.Bad_Option{"plan"}
	}
	m: hook.Memory_Budget
	allocator := caller
	if opts.budget.memory != 0 {
		m = {backing = caller, limit = opts.budget.memory}
		allocator = hook.memory_budget(&m)
	}
	frames: [FRAME_ROOM]Frame = ---
	hk: H
	when H == Cells_Reader {
		hk.alike = true
	} else when H == Refusing_Reader {
		hk.repeat = max(u64)
	} else {
		// Left unzeroed, as a walk reads only the entries it wrote. A `when` opens no scope, so it lives as `hk` does.
		memo: hook.Expected_Memo = ---
		hk.expected = &memo
	}
	h := &hk.reader
	h^ = {
		base      = raw_data(src),
		len       = u64(len(src)),
		frames    = raw_data(frames[:]),
		home      = raw_data(frames[:]),
		sp        = 1,
		room      = FRAME_ROOM,
		plan      = plan,
		format    = format,
		borrow    = read.borrow_strings,
		first     = dups == .First,
		unknown   = read.refuse_unknown,
		made      = plan == &made,
		path      = read.path,
		allocator = allocator,
		caller    = caller,
	}
	h.ctx = context
	h.ctx.allocator = allocator
	frames[0] = {b = u64(uintptr(&DEAD_BLOCK[1])), seen = SEEN_TARGET}
	before: [BEFORE_ROOM]u8 = ---
	h.target = uintptr(target)
	size := plan.size
	h.before = before[:size] if size <= BEFORE_ROOM else (runtime.mem_alloc_non_zeroed(size, 1, allocator) or_else nil)
	if len(h.before) != size {
		return hook.memory_budget_error(&m, runtime.Allocator_Error.Out_Of_Memory)
	}
	intrinsics.mem_copy_non_overlapping(raw_data(h.before), target, size)
	if read.path != nil {
		clear(read.path)
	}
	regs := hook.Regs{NO_LIMIT, u64(uintptr(plan.root)), u64(uintptr(target))}
	_, err, _ := walk(src, opts, &hk, &regs, allocator, &h.ctx)
	if err == nil {
		err = h.err
	} else if !h.dead {
		settle_open(h, regs, h.sp)
	}
	if h.frames != h.home {
		runtime.heap_free(h.frames)
	}
	if h.zero != nil {
		runtime.mem_free_with_size(raw_data(h.zero), len(h.zero), allocator)
	}
	if len(h.before) > BEFORE_ROOM {
		runtime.mem_free_with_size(raw_data(h.before), len(h.before), allocator)
	}
	if h.held != nil {
		held_free(h)
	}
	return hook.memory_budget_error(&m, err)
}

// The hook. A value's open takes no call on the hot kinds, and a key takes none when it is the one the struct expects
// next. `number` is the format's reader of a number token, and `CELLS` says the format's values have no kind of their
// own, as a delimited text's cells: a cell is text for a string and read by its field otherwise, and an empty one is
// absent.
@(private)
reader_hook :: #force_inline proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number, $CELLS: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	s := s
	if t.role == .Key {
		if key_hit(h, (^Record)(uintptr(s.b)), t) {
			s.b += size_of(Record)
			return s, .Next
		}
		return key_miss(h, {s.a, s.b, s.c}, t)
	}
	if t.role != .Value {
		return s, .Next
	}
	if t.kind == .End {
		h.sp -= 1
		f := &h.frames[h.sp]
		owner := (^Record)(uintptr(f.b) - size_of(Record))
		if f.seen & SEEN_ON == 0 && (owner.kind == .Struct || owner.kind == .Required && s.b >= u64(uintptr(owner.first)) + u64(h.plan.meta[owner.meta].required) * size_of(Record)) {
			return {f.a, f.b, f.c + u64(owner.stride)}, .Next
		}
		return close_container(h, f, {s.a, s.b, s.c}, t)
	}
	if s.c >= s.a {
		a: hook.Action
		ok: bool
		if s, a, ok = grow_list(h, {s.a, s.b, s.c}, t); !ok {
			return s, a
		}
	}
	rec := (^Record)(uintptr(s.b) - size_of(Record))
	dest := uintptr(s.c) + uintptr(rec.offset)
	value: #partial switch t.kind {
	case .String:
		if rec.kind != .String {
			when CELLS {
				// A cell of a number or boolean field is read from its text here, and one that spells neither in the
				// cold path.
				if t.spelling & tape.SPELLING_DECODE == 0 {
					if rec.kind >= .I8 && rec.kind <= .F64 {
						if n, ok := spell.number_strict(h.base[:h.len], t.lo, t.lo + u64(t.n)); ok && store_number(rec.kind, n, dest) {
							break value
						}
					} else if rec.kind == .Bool && t.lo + 8 <= h.len {
						// `true` and `false` read in one load, which the eight bytes of text from the cell hold.
						w := load8(h.base[t.lo:])
						if t.n == 4 && u32(w) == 0x6575_7274 || t.n == 5 && w & 0xFF_FFFF_FFFF == 0x65_736C_6166 {
							(^bool)(dest)^ = t.n == 4
							break value
						}
					}
				}
			}
			return indirect(h, {s.a, s.b, s.c}, t, number, CELLS)
		}
		if t.spelling & tape.SPELLING_DECODE == 0 {
			if h.borrow {
				(^runtime.Raw_String)(dest)^ = {h.base[t.lo:], int(t.n)}
			} else if !copy_span(h, dest, t.lo, t.n) {
				return refuse_memory(h, {s.a, s.b, s.c}, t)
			}
		} else if !store_string(h, t, dest) {
			return refuse_memory(h, {s.a, s.b, s.c}, t)
		}
	case .Number:
		if rec.kind < .I8 || rec.kind > .F64 {
			return indirect(h, {s.a, s.b, s.c}, t, number, CELLS)
		}
		n := number(h.base[:h.len], t)
		if !store_number(rec.kind, n, dest) {
			return number_cold(h, {s.a, s.b, s.c}, t, n)
		}
	case .True, .False:
		if rec.kind != .Bool {
			return indirect(h, {s.a, s.b, s.c}, t, number, CELLS)
		}
		(^bool)(dest)^ = t.kind == .True
	case .Object:
		if rec.kind != .Struct && rec.kind != .Required {
			return indirect(h, {s.a, s.b, s.c}, t, number, CELLS)
		}
		if h.sp == h.room && !frames_grow(h) {
			return refuse_memory(h, {s.a, s.b, s.c}, t)
		}
		// A struct in place in the bytes of the frame below takes its `SEEN_TARGET`, which a list's and a map's lack.
		held := h.frames[h.sp - 1].seen & SEEN_TARGET
		f := &h.frames[h.sp]
		h.sp += 1
		f.a, f.b, f.c, f.seen = s.a, s.b, s.c, held
		return {NO_LIMIT, u64(uintptr(rec.first)), u64(dest)}, .Next
	case .Array:
		if rec.kind != .Slice && rec.kind != .Dynamic {
			return indirect(h, {s.a, s.b, s.c}, t, number, CELLS)
		}
		if h.sp == h.room && !frames_grow(h) {
			return refuse_memory(h, {s.a, s.b, s.c}, t)
		}
		f := &h.frames[h.sp]
		h.sp += 1
		f.a, f.b, f.c, f.data, f.seen = s.a, s.b, s.c, nil, 0
		return {0, u64(uintptr(rec.first)), 0}, .Next
	case:
		return indirect(h, {s.a, s.b, s.c}, t, number, CELLS)
	}
	s.c += u64(rec.stride)
	return s, .Next
}


// Whether key token `t` is the key of record `k`: a plain string key of its length, with its bytes. A key of at most
// eight bytes is one load masked by `tail`, which needs eight bytes of the text from the key on, and a longer one its
// first and last eight bytes, and past sixteen the rest compared out of line.
@(private)
key_hit :: #force_inline proc "contextless" (h: ^Reader, k: ^Record, t: tape.Token) -> bool #no_bounds_check {
	if (transmute([2]u64)t)[1] & KEY_MASK != k.word {
		return false
	}
	p := h.base[t.lo:]
	n := u64(t.n)
	if n <= 8 {
		return t.lo + 8 <= h.len && (load8(p) ~ k.head) & k.tail == 0
	}
	if load8(p) != k.head || load8(p[n - 8:]) != k.tail {
		return false
	}
	return n <= 16 || key_rest(h, k, p, n)
}

// `kernel.load8` for the polymorphic procs of other files, whose bodies a check of the package with no instance does
// not see using an import.
@(private)
load8 :: #force_inline proc "contextless" (p: [^]u8) -> u64 {
	return kernel.load8(p)
}

// Whether the bytes past the first eight of the `n`-byte key at `p` are those of record `k`'s name.
@(private)
key_rest :: #force_no_inline proc "contextless" (h: ^Reader, k: ^Record, p: [^]u8, n: u64) -> bool {
	return string(p[8:n]) == h.plan.meta[k.meta].name[8:]
}

// Stores number `n` at `dest` as a record of `kind` reads it, false when it does not fit there exactly, as an integer
// out of range, a fraction for an integer, or a float `f32` may round twice.
@(private)
store_number :: #force_inline proc "contextless" (kind: Read_Kind, n: spell.Number, dest: uintptr) -> bool #no_bounds_check {
	#partial switch kind {
	case .I64:
		if n.kind == .Int {
			(^u64)(dest)^ = n.bits
			return true
		}
	case .F64:
		if n.kind == .Float {
			(^u64)(dest)^ = n.bits
			return true
		}
		// `-0` reads as the integer 0, which the cold path gives its sign.
		if n.kind == .Int && n.bits != 0 {
			(^f64)(dest)^ = f64(i64(n.bits))
			return true
		}
	case .F32:
		if n.kind == .Float && !f32_double_rounds(transmute(f64)n.bits) {
			v := transmute(f64)n.bits
			if abs(v) <= f64(max(f32)) || v != v {
				(^f32)(dest)^ = f32(v)
				return true
			}
		}
		if n.kind == .Int && n.bits != 0 {
			(^f32)(dest)^ = f32(i64(n.bits))
			return true
		}
	case .I8 ..= .I32, .U8 ..= .U64:
		v := i64(n.bits)
		if n.kind == .Int && v >= INT_LO[kind] && v <= INT_HI[kind] {
			write_int(dest, n.bits, kind)
			return true
		}
	}
	return false
}

// Writes the low bytes of `v` that an integer of `kind` holds at `dest`.
@(private)
write_int :: #force_inline proc "contextless" (dest: uintptr, v: u64, kind: Read_Kind) {
	#partial switch kind {
	case .I8, .U8:
		(^u8)(dest)^ = u8(v)
	case .I16, .U16:
		(^u16)(dest)^ = u16(v)
	case .I32, .U32:
		(^u32)(dest)^ = u32(v)
	case:
		(^u64)(dest)^ = v
	}
}

@(private)
F32_NORMAL :: 1.1754943508222875e-38

// Whether the binary64 `v` of a decimal may narrow to a different `f32` than the decimal rounds to: its low 29 bits are
// a normal `f32`'s midpoint, or it is below the normal range, where an `f32` keeps fewer bits. Otherwise a cast rounds
// once.
@(private)
f32_double_rounds :: #force_inline proc "contextless" (v: f64) -> bool {
	return transmute(u64)v & (1 << 29 - 1) == 1 << 28 || abs(v) < F32_NORMAL && v != 0
}

// The record that reads the container a frame holds.
@(private)
frame_owner :: #force_inline proc "contextless" (f: ^Frame) -> ^Record {
	r := (^Record)(uintptr(f.b) - size_of(Record))
	return f.owner if wrapper(r.kind) else r
}

// Whether a record of `kind` wraps the record that reads its value, as a `Position` record passes each element to a
// member, so a frame it saved the registers of names its owner and destination itself.
@(private)
wrapper :: #force_inline proc "contextless" (kind: Read_Kind) -> bool {
	return kind == .Maybe || kind == .Ptr || kind == .Union || kind == .Position
}

// The index of record `r` in its block, the block's first record being `first`.
@(private)
index_in :: #force_inline proc "contextless" (r, first: ^Record) -> int {
	return int((uintptr(r) - uintptr(first)) / size_of(Record))
}
