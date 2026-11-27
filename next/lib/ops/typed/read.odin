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

// An open container, with the registers its close gives back. `seen` holds which members of a struct were read, kept
// from the first key that arrives out of order, as until then the cursor says, with `SEEN_ON` set then, and `run` is
// the cursor the members marked last reached. A struct's or a fixed array's `seen` has `SEEN_TARGET` when its bytes may
// hold the target's own values, and a map's is 1 when the map held entries at its open. `data` is a list's first
// element, a map, a fixed array or bit set's base, or a raw value's first byte. `owner` reads the container and
// `target` is where it goes when the record before `b` is a wrapper's.
@(private)
Frame :: struct {
	a, b, c: u64,
	seen:    u64,
	data:    rawptr,
	run:     u64,
	owner:   ^Record,
	target:  uintptr,
}

// The bits of `Frame.seen` past the members' own: `SEEN_ON` once the struct's members are tracked, `SEEN_WIDE` when
// members from `SEEN_BITS` on are tracked in the words at `Frame.data`, and `SEEN_TARGET` when the bytes of the struct
// or fixed array may hold the target's own values, as the read did not make them.
@(private)
SEEN_ON :: u64(1) << 63

@(private)
SEEN_WIDE :: u64(1) << 62

@(private)
SEEN_TARGET :: u64(1) << 61

@(private)
SEEN_BITS :: 61

// The open levels a read keeps in its own frame. A deeper text moves them to the read's scratch allocator.
@(private = "file")
FRAME_ROOM :: 64

// The target bytes a read keeps in its own frame. A larger target's are kept in the read's scratch allocator.
@(private = "file")
BEFORE_ROOM :: 128

// Cold state flags of `Reader`, packed into one byte inside Cache Line 0.
@(private)
Reader_Flag :: enum u8 {
	First,       // repeated keys under `.First`
	Unknown,     // `refuse_unknown`
	Made,        // the read made its plan, and frees it on return
	Dead,        // a refusal ended the read, and the walk judges the rest of the text
	Fresh,       // the last map key read made a new entry, which an empty cell takes back
	Worker_List, // parallel worker's top-level list (`h.sp == 2`) allocates its temporary element buffer from `scratch`
}

@(private)
Reader_Flags :: bit_set[Reader_Flag; u8]

// The state of one read, which a format's walk reaches through its hook, a `Text_Reader`, a `Refusing_Reader` or a
// `Cells_Reader`. Hot fields sit first so all per-token fields and `expected` fit in Cache Line 0, while keeping
// `Text_Reader.reader` at offset 0 so `&h.reader` requires no pointer adjustment.
@(private)
Reader :: struct {
	base:             [^]u8,
	len:              u64,
	frames:           [^]Frame,
	sp:               int,
	room:             int, // the frames `frames` holds
	borrow:           bool,
	flags:            Reader_Flags,
	optional_seconds: bool, // a date-time may omit `:SS`, as TOML 1.1 allows
	plan:             ^Plan,
	expected:         ^hook.Expected_Memo, // used by `Text_Reader` walks with `.Expects`
	// Cold fields past Cache Line 0.
	home:             [^]Frame, // the frames in the read's caller's frame
	format:           ^tape.Format,
	err:              tape.Error, // the first refusal
	// The registers of the outermost wrapper whose element is being read, nil outside one. A refusal of the element is
	// the wrapper's, as its registers name the element's place.
	outer:            ^hook.Regs,
	path:             ^[dynamic]tape.Step,
	map_keys:         []tape.Token, // each open map frame's last key when `path != nil`, indexed by frame
	zero:             []u8, // zeroes as wide as the widest map value read, for a new entry
	key:              [2]u64, // the last map key read
	// The target, and its bytes as the read found them, so a repeat frees what the read put in the target and nothing
	// the target held, and sets back what the target held.
	target:           uintptr,
	before:           []u8,
	// The blocks the target held that the read went into, as `before` holds the target's: its pointees and maps.
	held:             [dynamic]Held,
	// One past the head of the last tag 1 the walk gave, so a number that starts there is a count of seconds since the
	// epoch, as a `time.Time` takes it, which the format notes. 0 for none, as a value after a tag starts past the tag's first byte.
	epoch:            u64,
	allocator:        runtime.Allocator, // the caller's, counted under `Budget.memory` (persistent result data)
	caller:           runtime.Allocator, // the one a dynamic array or map read keeps for its owner
	scratch:          runtime.Allocator, // short-lived read scratch (frames, before, held, seen, first_met, refusing tables)
	ctx:              runtime.Context,
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
	protocol:     hook.Protocol({.Skips, .Expects}, hook.Unused, hook.Unused, hook.Unused),
}

// The hook of a read of a delimited text, whose records hold cells by the header's places. Once a record's keys mapped
// its columns to members, every later record of a text of fixed width is replayed: the walk gives its cells with no
// key, each read by that map, with `b` at its column.
Cells_Reader :: struct {
	using reader: Reader,
	replay:       hook.Replay,
	dropped:      u64,
	taken:        int,
	alike:        bool,
	learn:        Learn,
	columns:      [hook.COLUMN_BITS]Column, // each column the first record took, in its order
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

#assert(offset_of(Text_Reader, reader) == 0)
#assert(offset_of(Text_Reader, expected) + size_of(^hook.Expected_Memo) <= 64)
when size_of(uintptr) == 8 {
	#assert(size_of(Frame) == 64)
	#assert(size_of(Column) == 16)
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
	if h.learn == .Ready && t.kind == .Object && t.role == .Value && h.sp == RECORD_SP - 1 && h.replay.fixed {
		// `t.kind == .Object` is constant here so LLVM folds `reader_hook` to only the struct open path.
		r, a := reader_hook(&h.reader, s, t, number, true)
		if a == .Next && h.sp == RECORD_SP {
			// The record's cells come with no keys, each read by its column.
			h.replay.replays = true
			r.b = u64(uintptr(&h.columns[0]))
		}
		return r, a
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

// Reads `src`, a text of `format`, into `target`, a value of type `T`, by `uopts.plan` or by a plan made for the call,
// through `walk`, the format's walk for hook `H`, a `Text_Reader`, a `Refusing_Reader` or a `Cells_Reader`. `tag` is the
// format's struct tag key. A plan for another type or tag is `Bad_Option{"plan"}`, a nil target `Bad_Option{"target"}`,
// and a text in pieces `Bad_Option{"pieces"}`. Repeated keys follow `opts.dups`, the format's own for `.Default`.
// `.All` and `.Group` are `Bad_Option{"dups"}`, as a member holds one value. The read takes `.Refuse` as `.Last`, as the
// repeats it refuses are judged by a `Refusing_Reader` or by the format, which faults on a repeat or judges the header
// of a delimited text before the read. A member the text does not hold keeps the target's value, and a value the type
// does not take is a `Fault` of kind `.Refused`, whose detail is a `Typed_Refusal`, at the value's first byte, unless the
// text fails as the format's `validate` fails it, which is then the error. Each string and list is an allocation of its
// own from `caller`, so an arena gives the speed of one block, and under `uopts.borrow_strings` a string with nothing to
// decode is a span of `src`.
@(require_results)
read :: proc(src: []u8, target: rawptr, T: typeid, format: ^tape.Format, tag: string, opts: tape.Options, uopts: Unmarshal_Options, caller: runtime.Allocator, $H: typeid, $walk: proc "contextless" (src: []u8, opts: tape.Options, h: ^H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool)) -> tape.Error {
	if uopts.path != nil {
		clear(uopts.path)
	}
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
	// Unzeroed backing for a one-shot plan so cached-plan calls skip zeroing `size_of(Plan)` bytes.
	made_buf: [size_of(Plan) / size_of(u64)]u64 = ---
	#assert(size_of(made_buf) == size_of(Plan))
	#assert(align_of(Plan) <= align_of(u64))
	plan := uopts.plan
	made := false
	if plan == nil {
		p := (^Plan)(&made_buf[0])
		if err := make_temp_plan(T, tag, caller, p); err != nil {
			return err
		}
		plan = p
		made = true
	} else if !plan_matches(plan, T, tag) {
		return tape.Bad_Option{"plan"}
	}
	defer if made {
		destroy_temp_plan(plan)
	}
	m_buf: [size_of(hook.Read_Budget) / size_of(u64)]u64 = ---
	#assert(size_of(m_buf) == size_of(hook.Read_Budget))
	#assert(align_of(hook.Read_Budget) <= align_of(u64))
	m := (^hook.Read_Budget)(rawptr(&m_buf[0]))
	scratch_buf: [size_of(hook.Memory_Budget) / size_of(u64)]u64 = ---
	#assert(size_of(scratch_buf) == size_of(hook.Memory_Budget))
	#assert(align_of(hook.Memory_Budget) <= align_of(u64))
	allocator := caller
	scratch: runtime.Allocator
	if opts.budget.memory == 0 {
		scratch = parallel_scratch_backing(opts, allocator)
	} else {
		allocator = hook.read_budget(m, opts, caller)
		scratch = hook.scratch(opts, allocator, (^hook.Memory_Budget)(rawptr(&scratch_buf[0])))
	}
	frames: [FRAME_ROOM]Frame = ---
	flags := reader_flags(dups, uopts, made)
	ctx := context
	ctx.allocator = allocator
	// Unzeroed backing for `H` so `Cells_Reader.columns`/`row` (1,104 B) are not zeroed on every call, while every live
	// field of `Reader` and `H` is initialized once below.
	hk_buf: [size_of(H) / size_of(u64)]u64 = ---
	#assert(size_of(hk_buf) == size_of(H))
	#assert(align_of(H) <= align_of(u64))
	hk := (^H)(&hk_buf[0])
	init_reader(hk, src, format, plan, flags, uopts.borrow_strings, uopts.path, target, allocator, caller, scratch, &ctx, frames[:])
	when H == Text_Reader {
		// Left unzeroed, as a walk reads only the entries it wrote. A `when` opens no scope, so it lives as `hk` does.
		memo: hook.Expected_Memo = ---
		hk.expected = &memo
	}
	h := &hk.reader
	frames[0] = {b = u64(uintptr(&DEAD_BLOCK[1])), seen = SEEN_TARGET}
	before: [BEFORE_ROOM]u8 = ---
	// Only `.Last` (and refusing walks that still overwrite during the walk) can call `reset` on a repeated key.
	// `.First` skips repeats, and DSV `.Refuse` rejects duplicate headers before entering `read`.
	if dups != .First && !(H == Cells_Reader && dups == .Refuse) {
		if !snapshot_before(h, target, before[:]) {
			err := tape.Error(runtime.Allocator_Error.Out_Of_Memory)
			return hook.memory_budget_error(&m.main, err) if opts.budget.memory != 0 else err
		}
	}
	regs := hook.Regs{NO_LIMIT, u64(uintptr(plan.root)), u64(uintptr(target))}
	// TOML derives its own `hook.scratch` from `allocator` so its tree stays inside `m`'s shared budget.
	walk_alloc := allocator if format.id >= tape.FORMAT_ID_TOML && format.id < tape.FORMAT_ID_XML else scratch
	_, err, _ := walk(src, opts, hk, &regs, walk_alloc, &h.ctx)
	if err == nil {
		err = h.err
	} else if .Dead not_in h.flags {
		settle_open(h, regs, h.sp)
	}
	if h.frames != h.home || h.map_keys != nil || h.zero != nil || len(h.before) > BEFORE_ROOM || h.held != nil {
		cleanup_reader(h, BEFORE_ROOM)
	}
	return hook.memory_budget_error(&m.main, err) if opts.budget.memory != 0 else err
}

// Cold wrapper for one-shot `plan_make` so cached-plan reads keep it out of their hot blocks.
@(private, cold)
make_temp_plan :: #force_no_inline proc(T: typeid, tag: string, caller: runtime.Allocator, out: ^Plan) -> tape.Error {
	p, err := plan_make(T, tag, {}, caller)
	if err == nil {
		out^ = p
	}
	return err
}

@(private, cold)
destroy_temp_plan :: #force_no_inline proc(plan: ^Plan) {
	plan_destroy(plan)
}

// The hook. A value's open takes no call on the hot kinds, and a key takes none when it is the one the struct expects
// next. `number` is the format's reader of a number token, and `CELLS` says the format's values have no kind of their
// own, as a delimited text's cells: a cell is text for a string and read by its field otherwise, and an empty one is
// absent.
// Invariants for `#no_bounds_check`: `h.sp >= 1` at every `.End` (`close_container` restores `h.sp = 1` when `.Dead`),
// `h.sp < h.room` holds after `frames_grow`, `s.b` points into a valid plan record block (so `owner.meta` indexes
// `h.plan.meta`), and the walk guarantees `t.lo + u64(t.n) <= h.len` for plain string/number tokens.
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
						if n, ok := spell.number_strict(h.base[:h.len], t.lo, t.lo + u64(t.n)); ok && store_number(rec.kind, n, dest, t.n) {
							break value
						}
					} else if rec.kind == .Bool {
						if bval, bok := match_bool_word(h.base, t.lo, h.len, t.n); bok {
							(^bool)(dest)^ = bval
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
		if !store_number(rec.kind, n, dest, t.n) {
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
		f.a, f.b, f.c, f.seen, f.data = s.a, s.b, s.c, 0, nil
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
// Invariant for `#no_bounds_check`: when `KEY_MASK` matches `k.word`, `t` has `SPELLING_DECODE == 0` so the walk
// guarantees `t.lo + u64(t.n) <= h.len`; for `n <= 8` the `t.lo + 8 <= h.len` guard precedes `load8`, and for `n > 8`
// both `p[:8]` and `p[n - 8:n]` lie inside `h.base[:h.len]`.
@(private)
key_hit :: #force_inline proc "contextless" (h: ^Reader, k: ^Record, t: tape.Token) -> bool #no_bounds_check {
	when ODIN_ENDIAN != .Little {
		#panic("key_hit assumes little-endian Token layout")
	}
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

// Whether the middle bytes past the first eight and before the last eight of the `n`-byte key at `p` are those of
// record `k`'s name.
// Invariant for `#no_bounds_check`: called from `key_hit` only after proving `n > 16`, `k.word` matched (so
// `len(h.plan.meta[k.meta].name) == n` and `k.meta < len(h.plan.meta)`), `t.lo + n <= h.len`, and both `p[:8]` and
// `p[n - 8:n]` already match `name`.
@(private = "file", cold)
key_rest :: #force_no_inline proc "contextless" (h: ^Reader, k: ^Record, p: [^]u8, n: u64) -> bool #no_bounds_check {
	return string(p[8:n - 8]) == h.plan.meta[k.meta].name[8:n - 8]
}

// Stores number `n` (whose token has `tok_len` bytes) at `dest` as a record of `kind` reads it, false when it does not
// fit there exactly, as an integer out of range, a fraction for an integer, `-0` into a float, or a float `f32` may
// round twice.
// Invariant for `#no_bounds_check`: `kind` is a valid `Read_Kind` enum value indexing `INT_LO` and `INT_HI`.
@(private)
store_number :: #force_inline proc "contextless" (kind: Read_Kind, n: spell.Number, dest: uintptr, tok_len: u32) -> bool #no_bounds_check {
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
		// `-0` reads as the integer 0 with `tok_len >= 2`, which the cold path gives its sign; plain `0` has `tok_len == 1`.
		if n.kind == .Int && (n.bits != 0 || tok_len == 1) {
			(^f64)(dest)^ = f64(i64(n.bits))
			return true
		}
	case .F32:
		if n.kind == .Float {
			u := n.bits & 0x7FFF_FFFF_FFFF_FFFF
			if (u - F32_NORMAL_BITS <= F32_MAX_BITS - F32_NORMAL_BITS || u == 0) && u & (1 << 29 - 1) != 1 << 28 {
				(^f32)(dest)^ = f32(transmute(f64)n.bits)
				return true
			}
		} else if n.kind == .Int && (n.bits != 0 || tok_len == 1) {
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

@(private = "file")
F32_NORMAL_BITS :: u64(0x3810_0000_0000_0000) // binary64 bit pattern of 2^-126 (smallest normal f32)

@(private = "file")
F32_MAX_BITS :: u64(0x47EF_FFFF_E000_0000) // binary64 bit pattern of max(f32)

// Whether the binary64 `v` of a decimal may narrow to a different `f32` than the decimal rounds to: its low 29 bits are
// a normal `f32`'s midpoint, or it is below the normal range, where an `f32` keeps fewer bits. Otherwise a cast rounds
// once.
@(private)
f32_double_rounds :: #force_inline proc "contextless" (v: f64) -> bool {
	u := transmute(u64)v & 0x7FFF_FFFF_FFFF_FFFF
	return u & (1 << 29 - 1) == 1 << 28 || u - 1 < F32_NORMAL_BITS - 1
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

// `true` and `false` read in one 8-byte load when at least 8 bytes remain in `src`.
@(private)
match_bool_word :: #force_inline proc "contextless" (base: [^]u8, lo, hi_len: u64, n: u32) -> (val, ok: bool) #no_bounds_check {
	if lo + 8 <= hi_len {
		w := load8(base[lo:])
		if n == 4 && u32(w) == 0x6575_7274 || n == 5 && w & 0xFF_FFFF_FFFF == 0x65_736C_6166 {
			return n == 4, true
		}
	}
	return false, false
}

// The index of record `r` in its block, the block's first record being `first`.
@(private)
index_in :: #force_inline proc "contextless" (r, first: ^Record) -> int {
	return int((uintptr(r) - uintptr(first)) / size_of(Record))
}
