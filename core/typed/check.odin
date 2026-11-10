package typed

import "base:runtime"
import "core:mem"
import "core:strconv"
import "core:strings"
import regex "../regex"
import spell "../spell"
import core ".."
import rules "../rules"

// A read that reports every refusal to its sink as a `core.Error_Entry` with the full path, a `Reader` with the hook the
// checks of a model add to. `check_start` starts one.
Check :: struct {
	using reader: Reader,
	// The keyword steps a failure's path takes after its value's use site, before the rule's keyword.
	after:        []core.Step,
	// The run of an arm this check is, nil for the outermost check, the held value open in it, and the runs it shares.
	run:          ^Run,
	fork:         ^Fork,
	pool:         ^Pool,
	// The held containers a run took over, innermost first.
	taken:        ^Fork,
	// The held values this check's value is judged by one inside the other, which `MAX_HELD` bounds.
	nest:         int,
	// What stopped the check past its sink, which stops the checks it is an arm of.
	fatal:        core.Typed_Error_Kind,
	// What the path and the keyword path of the outermost check's entries start with, nil for none.
	outer:        ^Outer,
	// How a key that repeats in its object is met.
	repeats:      Repeats,
	// The sink's entries below this are an earlier record's, which a repeat never takes back.
	floor:        int,
	// The keys of the open objects that track them, outermost first: the first `tracked` of `trackers` are in use. The
	// trackers and what they hold are in the temp allocator and are reused, so a long text does not grow them.
	trackers:     [dynamic]Tracker,
	tracked:      int,
}

// The keys an open object has met, for a check that meets repeats. `sp` is the object's frame.
@(private)
Tracker :: struct {
	sp:      int,
	// Each key's text and the index of its span.
	keys:    map[string]int,
	// The source span of each key's latest member, from its key to the next key, whose end is `open`'s until the next key.
	spans:   [dynamic][2]u64,
	open:    int,
	// How many of the object's members repeat an earlier key.
	repeats: u64,
}

// The path to a value inside a larger one and the keyword steps to the subschema it is judged by, which a check of that
// value starts its entries' paths with.
Outer :: struct {
	path, words: []core.Step,
}

@(private)
@(rodata)
KEYS := [1]core.Step{core.Name("propertyNames")}

// A format's read of a whole text into `target`, a value of `plan`'s type `T`, under the handle `as`.
Text_Read :: #type proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator: runtime.Allocator) -> core.Typed_Error

// A format's read of a node of a built document into `target`.
Node_Read :: #type proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^Plan, read: Read_Options, allocator: runtime.Allocator) -> core.Typed_Error

// What a format reads typed values with, where its `Services.reads` points. A plan copies the procedures. `check` and
// `node_check` are the reads that report to a `Sink`'s `entries`, nil for a format that has none. `plan` builds the plan
// of a type that reads with these reads and writes the format, nil for reads that build none.
Format_Reads :: struct {
	read, check:           Text_Read,
	node_read, node_check: Node_Read,
	build:                 Text_Build,
	plan:                  proc(T: typeid, opts: Plan_Options, allocator: runtime.Allocator) -> (Plan, core.Typed_Error),
	// The format's `^records.Record_Docs` for a spec named at compile time, which a model's read of records installs in a
	// reader that has none. Nil for reads that give none.
	docs:                  proc "contextless" () -> rawptr,
}

// Builds `src` as a document of the format `as` names, as a format's `Format_Reads` does for `write.marshal_value`.
Text_Build :: #type proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error)

// Starts a `Check` read, as `read_start` starts a read of the plan's own type. Its sink takes `core.Error_Entry`s.
check_start :: proc(c: ^Check, src: []u8, plan: ^Plan, as: core.As, T: typeid, target: rawptr, read: Read_Options, frames: []Frame, allocator: runtime.Allocator) -> (regs: core.Hook_Regs, err: core.Typed_Error) {
	regs, err = read_start(&c.reader, src, plan, as, T, target, read, frames, allocator)
	c.wide, c.outer = true, read.outer
	c.repeats, c.tracked, c.floor = read.repeats, 0, len(read.sink.entries) if read.sink != nil else 0
	// A check started again over its own pool gives back the held value an earlier record stopped in.
	if c.fork != nil && c.fork.open {
		fork_release(c, c.fork)
	}
	return
}

// Reads `src` into `target` as the plan's format does, `.Plan_Mismatch` when the plan has no read.
unmarshal_text :: proc(src: []u8, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator := context.allocator) -> core.Error {
	if plan == nil || plan.read == nil {
		return core.error_of(plan_mismatch(plan, nil, T))
	}
	return core.error_of(plan.read(src, plan.as, target, T, plan, read, allocator))
}

// Reads `src` into `target` as `unmarshal_text` does, with every refusal in `read.sink.entries`. Returns the first.
check_text :: proc(src: []u8, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator := context.allocator) -> core.Error {
	if plan == nil || plan.check == nil {
		return core.error_of(plan_mismatch(plan, nil, T))
	}
	return core.error_of(plan.check(src, plan.as, target, T, plan, read, allocator))
}

// Whether the keys of an object at record `owner`'s use reach `check_key` whatever the cursor predicts: the object's names are
// judged, or a check that judges repeats needs every key, on a block that ends in the `Never` record.
@(private)
keyed :: #force_inline proc "contextless" (h: ^Check, m: ^Meta, u: ^Use) -> bool #no_bounds_check {
	return u.keys != 0 || h.repeats == .Judge && h.plan.fields[m.block + m.members].kind == .Never
}

// Whether the frame `f` is the open object whose keys the innermost tracker holds.
@(private)
tracks :: #force_inline proc "contextless" (h: ^Check, f: ^Frame) -> bool {
	return h.tracked > 0 && h.trackers[h.tracked - 1].sp == int((uintptr(f) - uintptr(h.frames)) / size_of(Frame))
}

// Starts tracking the keys of the object just opened at frame `h.sp - 1`. A check that notices tracks only an object
// whose verdict a repeat of an unnamed key can change: a count, a rule for the members no record names, or names to judge.
@(cold)
@(private)
track_open :: #force_no_inline proc "contextless" (h: ^Check, m: ^Meta, u: ^Use, l: ^rules.Leaf) {
	if h.repeats == .Judge {
		if !keyed(h, m, u) {
			return
		}
	} else if u.additional == 0 && u.keys == 0 && !(l != nil && (l.min_members > 0 || l.max_members < max(u64))) {
		return
	}
	context = h.ctx
	context.allocator = context.temp_allocator
	if h.tracked == len(h.trackers) {
		if _, grown := append(&h.trackers, Tracker{}); grown != nil {
			return
		}
	}
	t := &h.trackers[h.tracked]
	h.tracked += 1
	clear(&t.keys)
	clear(&t.spans)
	t.sp, t.open, t.repeats = h.sp - 1, -1, 0
}

// What a key met by a tracker leaves to do.
@(private)
Key_Met :: enum {
	New,
	Skip,
	Stop,
}

// Notes the key `t`, whose text is `key`, in the object `tr` tracks. A repeat ends the read when it is to notice one. It
// takes back the errors of the earlier value under `.Last`, and under `.First` is skipped. Either is one member fewer.
@(cold)
@(private)
track_key :: #force_no_inline proc "contextless" (h: ^Check, tr: ^Tracker, t: core.Token, key: string) -> Key_Met {
	context = h.ctx
	context.allocator = context.temp_allocator
	lo, _ := core.scalar_ends(t)
	if tr.open >= 0 {
		tr.spans[tr.open][1] = lo
	}
	at, repeated := tr.keys[key]
	if !repeated {
		text, cloned := strings.clone(key)
		_, grown := append(&tr.spans, [2]u64{lo, 0})
		if cloned != nil || grown != nil {
			return .Stop
		}
		tr.keys[text] = len(tr.spans) - 1
		tr.open = len(tr.spans) - 1
		return .New
	}
	if h.repeats == .Notice {
		noticed(h, t)
		return .Stop
	}
	tr.repeats += 1
	if h.first_key {
		tr.open = -1
		return .Skip
	}
	take_back(h, tr.spans[at])
	tr.spans[at] = {lo, 0}
	tr.open = at
	return .New
}

// Ends the read at the repeated key `t` with the refusal a caller that reads again with `.Judge` looks for.
@(cold)
@(private)
noticed :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token) -> core.Action {
	h.first = {kind = .Duplicate_Key, at = t.lo}
	return .Stop
}

// Takes back the entries of this read that start inside `span`, the member a later value of its key replaces.
@(cold)
@(private)
take_back :: proc "contextless" (h: ^Check, span: [2]u64) {
	c := h.sink
	if c == nil {
		return
	}
	context = h.ctx
	kept := h.floor
	for i in h.floor ..< len(c.entries) {
		e := &c.entries[i]
		if e.start >= span[0] && e.start < span[1] {
			entry_destroy(e, c.entries.allocator)
		} else {
			c.entries[kept] = e^
			kept += 1
		}
	}
	if kept == len(c.entries) {
		return
	}
	resize(&c.entries, kept)
	// What the read first refused is taken back with it, unless a limit left an entry out.
	if kept == h.floor && !c.truncated {
		h.first = {}
	} else if kept > h.floor {
		h.first = {kind = c.entries[h.floor].kind, at = c.entries[h.floor].start}
	}
}

// The value `t` at a `Checked` record: judges a scalar by the record's leaf, and opens a container a rule reads inside,
// which its close judges, so a container's failure spans it. A container's frame keeps its open byte in `data` and its
// kind, and an object's frame its last key's span and spelling in `owner` and `target`. `c` counts the values of the
// open container.
@(private)
check_value :: #force_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	fld := field_at(regs.b)
	m, u := &h.plan.meta[fld.meta], &h.plan.uses[fld.meta]
	next := core.Hook_Regs{regs.a, regs.b + (size_of(Field) if u.step else 0), regs.c + 1}
	l: ^rules.Leaf
	if m.rule_set > 0 {
		l = &h.plan.leaves[m.rule_set - 1]
	}
	first: ^Field
	#partial switch t.kind {
	case .Object:
		if m.members > 0 || u.additional != 0 || u.pattern != 0 || u.keys != 0 || l != nil && (l.min_members > 0 || l.max_members < max(u64) || container_fails(l, .Object) != {}) {
			// The block's `Never` record predicts no key, so each key reaches `check_key` and its name rules.
			first = &h.plan.fields[m.block + m.members] if keyed(h, m, u) else fld.first
		}
	case .Array:
		if u.inside || l != nil && (l.min_items > 0 || l.max_items < max(u64) || container_fails(l, .Array) != {}) {
			first = &h.plan.fields[u.items]
		}
	case:
		if l != nil {
			if judge_value(h, regs, plain_token(h, t, l) if t.kind == .Plain else t, l) == .Stop {
				return next, .Stop
			}
		} else if len(u.applies) > 0 {
			return fork_value(h, regs, next, u, t)
		}
		return next, .Next
	}
	if first == nil {
		if len(u.applies) > 0 {
			return fork_value(h, regs, next, u, t)
		}
		return next, .Skip
	}
	f := &h.frames[h.sp]
	h.sp += 1
	f.a, f.b, f.c, f.seen, f.run, f.extra = regs.a, regs.b, regs.c, 0, nil, nil
	f.data, f.kind, f.owner, f.target = rawptr(uintptr(t.lo)), t.kind, nil, 0
	if t.kind == .Object {
		if keyed(h, m, u) {
			// The cursor starts past every member, which it passed unread, so the members are tracked from here by their keys.
			f.seen, f.run = SEEN_ON, first
		}
		if h.repeats != .Ignore && len(u.applies) == 0 {
			track_open(h, m, u, l)
		}
	}
	return {NO_LIMIT, u64(uintptr(first)), 0}, .Next
}

// A `Plain` token, text a format gives no kind, as the kind `l` allows reads it. A leaf that allows numbers alone reads the
// text, quotes cut, with the loose number grammar, and one that allows booleans alone reads `true` and `false`, a null
// beside them changing neither. Any other leaf reads an unquoted text by the strict grammar: a null only when the leaf
// allows one, a boolean or a number only when it allows one, else a string. A leaf that allows a string beside that reading
// takes the string when the other reading fails its enum or its rules and the string passes, unless it allows every kind.
@(cold)
@(private)
plain_token :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf) -> core.Token {
	context = h.ctx
	lo, hi := t.lo, t.lo + u64(t.n)
	exact := t.spelling & (core.SPELLING_QUOTED | core.SPELLING_DECODE) == 0
	if t.spelling & core.SPELLING_QUOTED != 0 && hi - lo >= 2 {
		lo, hi = lo + 1, hi - 1
	}
	text := string(raw_data(h.src)[lo:hi])
	value, numbers, loose := t, l.plain & {.Integer, .Number}, l.plain - {.Null}
	value.kind = .String
	switch {
	case exact && text == "null" && .Null in l.plain:
		value.kind = .Null
	case loose != {} && loose <= {.Integer, .Number}:
		if _, integer, _, ok := spell.number_loose(h.src, lo, hi); ok {
			value.kind, value.spelling = .Number, core.number_spelling(core.NUMBER_DECIMAL, 1, 0 if integer else 1)
		}
	case loose == {.Bool}:
		value.kind = .True if text == "true" else .False if text == "false" else .String
	case exact:
		kind, integer := core.plain_kind(h.src, lo, hi, .Bool in l.plain, numbers != {})
		value.kind = kind
		if kind == .Number {
			value.spelling = core.number_spelling(core.NUMBER_DECIMAL, 1, 0 if integer else 1)
		}
		if value.kind != .String && .String in l.plain && (l.has_enum || l.kinds != rules.EVERY_KIND) {
			if value.kind == .Number {
				value.lo, value.n = lo, u32(hi - lo)
			}
			if !reading_passes(h, value, l) && judge_string(h, t, l, nil) == {} {
				value.kind = .String
			}
		}
	}
	if value.kind == .Number {
		value.lo, value.n = lo, u32(hi - lo)
	}
	return value
}

// Whether `value`, one reading of a text, passes the enum and the rules of its kind.
@(cold)
@(private)
reading_passes :: proc "contextless" (h: ^Check, value: core.Token, l: ^rules.Leaf) -> bool {
	if value.kind != .Number {
		return !l.has_enum || judge_operand(h, value, l) == {}
	}
	kind_ok := .Number in l.kinds
	return judge_number(h, value, l, &kind_ok) == {} && kind_ok
}

// Judges the scalar `t` by `l`: its kind, its enum and the rules of its kind. A plain integer an i64 holds is judged here
// when `l.fast` says its bounds are whole, and the other rules are cold.
@(private)
judge_value :: #force_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token, l: ^rules.Leaf) -> core.Action {
	fails := scalar_fails(h, t, l)
	if fails == {} {
		return .Next
	}
	lo, hi := core.scalar_ends(t)
	return check_report(h, regs, l, t.kind, fails, lo, hi)
}

// What the scalar `t` fails of `l`: its kind, its enum and the rules of its kind.
@(private)
scalar_fails :: #force_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf) -> (fails: rules.Failures) {
	ok: bool
	#partial switch t.kind {
	case .Null:
		ok = .Null in l.kinds
	case .True, .False:
		ok = .Bool in l.kinds
	case .String:
		ok = .String in l.kinds
		if l.has_enum || l.min_length > 0 || l.max_length < max(u64) || l.pattern != nil || l.formats != {} {
			fails = judge_string(h, t, l, nil)
		}
	case .Number:
		if l.fast && t.spelling & core.NUMBER_KIND_MASK == 0 && core.number_shape(t.spelling) <= 19 && h.mant >> 63 == 0 {
			v := -i64(h.mant) if raw_data(h.src)[t.lo] == '-' else i64(h.mant)
			ok = l.kinds & {.Integer, .Number} != {}
			if l.minimum.set && (v < l.minimum.int || v == l.minimum.int && l.minimum.exclusive) {
				fails += {.Below_Minimum}
			}
			if l.maximum.set && (v > l.maximum.int || v == l.maximum.int && l.maximum.exclusive) {
				fails += {.Above_Maximum}
			}
		} else {
			ok = .Number in l.kinds
			if !ok && .Integer in l.kinds || l.has_enum || l.minimum.set || l.maximum.set || l.multiple_of != nil {
				fails = judge_number(h, t, l, &ok)
			}
		}
	}
	if !ok {
		fails += {.Not_Allowed} if l.kinds == {} else {.Wrong_Kind}
	}
	if l.has_enum && t.kind != .String && t.kind != .Number {
		fails += judge_operand(h, t, l)
	}
	return
}

// Whether a value that is no string and no number fails `l`'s enum index.
@(cold)
@(private)
judge_operand :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf) -> rules.Failures {
	context = h.ctx
	return {} if rules.enum_has(l, t.kind, "") else {.Not_A_Member}
}

// The rules of `l` a string fails, from its decoded text: `key` when it is read already, else `t`'s.
@(cold)
@(private)
judge_string :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf, key: Maybe(string)) -> (fails: rules.Failures) {
	context = h.ctx
	context.allocator = context.temp_allocator
	buf: [TEXT_ROOM]u8 = ---
	text, read := key.?
	if !read {
		if text, read = decoded_text(h, t, buf[:]); !read {
			return {.No_Memory}
		}
	}
	if l.has_enum && !rules.enum_has(l, .String, text) {
		fails += {.Not_A_Member}
	}
	if l.pattern == nil {
		return fails + rules.judge_string(l, text, nil)
	}
	// A search's scratch starts on the stack, and a block that outgrows it moves to the temp allocator.
	room: [SCRATCH_ROOM]u8 = ---
	stack: mem.Arena
	scratch := stack_scratch(&stack, room[:])
	return fails + rules.judge_string(l, text, &scratch)
}

// Whether the compiled `^regex.Regex` at `re` matches in the member name `name`.
@(private)
key_matches :: #force_no_inline proc "contextless" (h: ^Check, re: rawptr, name: string) -> bool {
	context = h.ctx
	room: [SCRATCH_ROOM]u8 = ---
	stack: mem.Arena
	scratch := stack_scratch(&stack, room[:])
	return matches(re, name, &scratch)
}

// A search's scratch that starts in `room` and moves to the temp allocator when it outgrows it.
@(private)
stack_scratch :: proc(stack: ^mem.Arena, room: []u8) -> (scratch: regex.Scratch) {
	mem.arena_init(stack, room)
	spill := runtime.Allocator{spill_proc, stack}
	scratch.stack.allocator, scratch.slots.allocator, scratch.counts.allocator = spill, spill, spill
	scratch.seen.allocator, scratch.good.allocator, scratch.log.allocator = spill, spill, spill
	return
}

// The bytes a pattern's search takes on the stack before it moves to the temp allocator.
@(private)
SCRATCH_ROOM :: 2048

// Allocates from the arena at `data` while it has room and from the temp allocator past it, copying a block that grows
// out of the arena. A block in the arena is freed with it.
@(private)
spill_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	stack := (^mem.Arena)(data)
	base := uintptr(raw_data(stack.data))
	inside := uintptr(old) >= base && uintptr(old) < base + uintptr(len(stack.data))
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if old != nil && !inside {
			break
		}
		if got, err := mem.arena_allocator_proc(data, mode, size, alignment, old, old_size, loc); err != .Out_Of_Memory {
			return got, err
		}
		got, err := runtime.mem_alloc_bytes(size, alignment, context.temp_allocator, loc)
		if err == nil && old != nil {
			copy(got, mem.byte_slice(old, min(old_size, size)))
		}
		return got, err
	case .Free:
		if inside || old == nil {
			return nil, nil
		}
	case .Free_All:
		return nil, .Mode_Not_Implemented
	}
	return context.temp_allocator.procedure(context.temp_allocator.data, mode, size, alignment, old, old_size, loc)
}

// The text a decoded string up to this long is decoded into on the stack. A longer one goes to the temp allocator.
@(private)
TEXT_ROOM :: 256

// `t`'s decoded text, into `buf` when it fits there.
@(private)
decoded_text :: proc "contextless" (h: ^Check, t: core.Token, buf: []u8) -> (string, bool) {
	if t.spelling & core.SPELLING_DECODE == 0 {
		return string(raw_data(h.src)[t.lo:][:t.n]), true
	}
	context = h.ctx
	if 3 * int(t.n) + 4 <= len(buf) {
		return h.plan.readers.text(&h.view, t, buf)
	}
	return core.token_text(h.plan.readers, &h.view, t, context.temp_allocator)
}

// The rules of `l` a number fails, and in `kind_ok` whether it passes `l`'s integer kind. A plain decimal is judged by
// its text, and a number a format spells otherwise by the decimal its value writes as. NaN and the infinities fail
// every bound.
@(cold)
@(private)
judge_number :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf, kind_ok: ^bool) -> (fails: rules.Failures) {
	context = h.ctx
	text := string(raw_data(h.src)[t.lo:][:t.n])
	small: Maybe(i64)
	plain := core.number_shape(t.spelling) < 32
	buf: [max(spell.F64_ROOM, 24)]u8 = ---
	if t.spelling & core.NUMBER_KIND_MASK > core.NUMBER_DECIMAL {
		n, read := h.plan.readers.number(&h.view, t)
		switch {
		case !read:
			return {.Wrong_Kind}
		case n.kind == .Int:
			text, small = strconv.write_int(buf[:], i64(n.bits), 10), i64(n.bits)
		case n.kind == .Uint:
			text = strconv.write_uint(buf[:], n.bits, 10)
		case n.kind == .Float && abs(transmute(f64)n.bits) <= max(f64):
			text = string(buf[:spell.f64_text(&buf[0], transmute(f64)n.bits)])
			plain = false
		case:
			kind_ok^ ||= .Number in l.kinds
			if l.minimum.set {
				fails += {.Below_Minimum}
			}
			if l.maximum.set {
				fails += {.Above_Maximum}
			}
			if l.multiple_of != nil {
				fails += {.Not_Multiple}
			}
			if l.has_enum {
				fails += {.Not_A_Member}
			}
			return
		}
		plain ||= n.kind != .Float
	} else if t.spelling & core.NUMBER_KIND_MASK == 0 && core.number_shape(t.spelling) <= 19 && h.mant >> 63 == 0 {
		small = -i64(h.mant) if text[0] == '-' else i64(h.mant)
	}
	if !kind_ok^ && .Integer in l.kinds {
		kind_ok^ = plain || !l.integer_spelled && rules.integral(spell.decimal_of(text))
	}
	if l.has_enum && !rules.enum_has(l, .Number, text) {
		fails += {.Not_A_Member}
	}
	return fails + rules.judge_number(l, text, small)
}

// Reports each of `fails`, the rules a value of kind `of` at `regs` fails by `l`, spanning `lo` to `hi`, under the
// keyword `keyword_of` names, or `keyword`. Returns `.Stop` for a read with no sink.
@(cold)
@(private)
check_report :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, l: ^rules.Leaf, of: core.Kind, fails: rules.Failures, lo, hi: u64, keyword := "") -> core.Action {
	context = h.ctx
	for kind in fails {
		note(h, regs, {kind = kind, at = lo}, hi, keyword if keyword != "" else keyword_of(l, kind, of))
		if h.sink == nil {
			return .Stop
		}
	}
	return .Next
}

// The keyword of `l` that holds the rule a value of kind `of` fails as `kind`, none for a value its use takes nowhere,
// whose keyword path ends at the use.
@(private)
keyword_of :: proc "contextless" (l: ^rules.Leaf, kind: core.Typed_Error_Kind, of: core.Kind) -> string {
	#partial switch kind {
	case .Not_A_Member:
		return "const" if l.constant else "enum"
	case .Below_Minimum:
		return "exclusiveMinimum" if l.minimum.exclusive else "minimum"
	case .Above_Maximum:
		return "exclusiveMaximum" if l.maximum.exclusive else "maximum"
	case .Too_Few:
		return "minProperties" if of == .Object else "minItems"
	case .Too_Many:
		return "maxProperties" if of == .Object else "maxItems"
	}
	return KEYWORDS[kind]
}

@(private)
@(rodata)
KEYWORDS := #partial [core.Typed_Error_Kind]string {
	.Wrong_Kind    = "type",
	.Not_Multiple  = "multipleOf",
	.Too_Short     = "minLength",
	.Too_Long      = "maxLength",
	.No_Match      = "pattern",
	.Bad_Format    = "format",
	.Missing_Field = "required",
}

// The rules of `l` a container of kind `kind` fails before its count: its kind, and an enum, which holds no container.
@(private)
container_fails :: #force_inline proc "contextless" (l: ^rules.Leaf, kind: core.Kind) -> (fails: rules.Failures) {
	if (rules.Kind.Object if kind == .Object else rules.Kind.Array) not_in l.kinds {
		fails += {.Not_Allowed} if l.kinds == {} else {.Wrong_Kind}
	}
	if l.has_enum {
		fails += {.Not_A_Member}
	}
	return
}

// A key of an open object at a `Checked` record: judges it by the object's name rules, and moves the cursor to the
// member it names, to the record of the members no record names, or past the member.
@(private)
check_key :: proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	regs := regs
	f := &h.frames[h.sp - 1]
	owner := field_at(f.b)
	m, u := &h.plan.meta[owner.meta], &h.plan.uses[owner.meta]
	f.owner, f.target = (^Field)(uintptr(t.lo)), uintptr(t.n) | uintptr(t.spelling) << 32
	buf: [TEXT_ROOM]u8 = ---
	key, ok := member_text(h, owner, t, buf[:])
	if !ok {
		return regs, .Stop
	}
	if h.tracked > 0 && h.trackers[h.tracked - 1].sp == h.sp - 1 {
		switch track_key(h, &h.trackers[h.tracked - 1], t, key) {
		case .New:
		case .Skip:
			regs.c += 1
			return regs, .Skip
		case .Stop:
			return regs, .Stop
		}
	}
	if u.keys != 0 {
		l := &h.plan.leaves[u.keys - 1]
		fails := judge_string(h, t, l, key) if .String in l.kinds else ({.Not_Allowed} if l.kinds == {} else {.Wrong_Kind})
		if fails != {} {
			lo, hi := core.scalar_ends(t)
			// The name is judged as the object's, under the keyword path of the names' own node.
			h.sp -= 1
			h.after = KEYS[:]
			action := check_report(h, {f.a, f.b, f.c}, l, .String, fails, lo, hi)
			h.after = nil
			h.sp += 1
			if action == .Stop {
				return regs, .Stop
			}
		}
	}
	if m.members > 0 {
		at := ([^]Field)(owner.first)
		// The cursor leaves where it stood, so the members it passed are marked first.
		mark_run(h, f, owner, (^Field)(uintptr(regs.b)))
		f.seen |= SEEN_ON
		if len(key) == 0 || m.names & name_bit(key) != 0 {
			if i := member_index(h, owner, m, key); i >= 0 {
				if seen_set(h, f, owner, i) && h.repeats == .Notice {
					return regs, noticed(h, t)
				}
				next := &at[i + 1]
				if keyed(h, m, u) {
					next = &h.plan.solo[2 * (int(uintptr(&at[i]) - uintptr(raw_data(h.plan.fields))) / size_of(Field)) + 1]
				}
				regs.b, f.run = u64(uintptr(next)), &at[i + 1]
				return regs, .Next
			}
		}
	}
	if u.pattern != 0 && key_matches(h, u.regex, key) {
		regs.b = u64(uintptr(&h.plan.fields[u.pattern]))
		return regs, .Next
	}
	if u.additional != 0 {
		regs.b = u64(uintptr(&h.plan.fields[u.additional]))
		return regs, .Next
	}
	if len(u.applies) > 0 {
		return regs, fork_token(h, t)
	}
	regs.c += 1
	return regs, .Skip
}

// The close of a container at a `Checked` record: judges an object's required members and its count, or an array's,
// then gives back the registers past the container.
@(cold)
@(private)
check_close :: #force_no_inline proc "contextless" (h: ^Check, f: ^Frame, owner: ^Field, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	if h.taken != nil && h.sp == h.taken.below {
		return taken_close(h, f, owner, regs, t)
	}
	if len(h.plan.uses[owner.meta].applies) > 0 {
		return fork_close(h, f, regs, t)
	}
	m := &h.plan.meta[owner.meta]
	at := core.Hook_Regs{f.a, f.b, f.c}
	back := core.Hook_Regs{f.a, f.b + (size_of(Field) if h.plan.uses[owner.meta].step else 0), f.c + 1}
	lo, hi := u64(uintptr(f.data)), t.lo + u64(t.n)
	count := regs.c
	if tracks(h, f) {
		count -= h.trackers[h.tracked - 1].repeats
		h.tracked -= 1
	}
	if f.kind == .Object && m.required_end > 0 {
		context = h.ctx
		for i := missing_member(h, f, owner, regs, 0); i >= 0; i = missing_member(h, f, owner, regs, i + 1) {
			// The object's frame is reopened for the path, whose last step the name replaces.
			// The path is the object's, as a schema's output names it, and the entry's operand names the member.
			e := core.Typed_Error{kind = .Missing_Field, at = lo}
			e.want.text = h.plan.meta[m.block + i].name
			note(h, at, e, hi, "required")
			if h.sink == nil {
				return back, .Stop
			}
		}
	}
	if f.kind == .Object && len(h.plan.uses[owner.meta].requires) > 0 && dependent_missing(h, f, owner, regs, at, lo, hi) == .Stop {
		return back, .Stop
	}
	if m.rule_set == 0 {
		return back, .Next
	}
	l := &h.plan.leaves[m.rule_set - 1]
	fails := container_fails(l, f.kind)
	fails += rules.judge_count(count, l.min_members, l.max_members) if f.kind == .Object else rules.judge_count(count, l.min_items, l.max_items)
	if fails != {} && check_report(h, at, l, f.kind, fails, lo, hi) == .Stop {
		return back, .Stop
	}
	return back, .Next
}

// Reports each member the object's `dependentRequired` asks for and the object lacks. Returns `.Stop` for a read with no
// sink.
@(cold)
@(private)
dependent_missing :: #force_no_inline proc "contextless" (h: ^Check, f: ^Frame, owner: ^Field, regs, at: core.Hook_Regs, lo, hi: u64) -> core.Action {
	context = h.ctx
	m := &h.plan.meta[owner.meta]
	for r in h.plan.uses[owner.meta].requires {
		if !member_seen(h, f, owner, regs, r.trigger) {
			continue
		}
		for want in r.wants {
			if !member_seen(h, f, owner, regs, want) {
				e := core.Typed_Error{kind = .Missing_Field, at = lo}
				e.want.text = h.plan.meta[m.block + want].name
				note(h, at, e, hi, "dependentRequired")
				if h.sink == nil {
					return .Stop
				}
			}
		}
	}
	return .Next
}

// Stores into the integer record `fld` a number spelled with a fraction or an exponent that is an integer, `1.0` or
// `1e2`, which a check takes where a read refuses it.
@(cold)
store_integral :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, fld: ^Field, dest: uintptr) -> core.Typed_Error_Kind {
	if t.spelling & core.NUMBER_KIND_MASK != 0 {
		return .Wrong_Kind
	}
	context = h.ctx
	d := spell.decimal_of(string(raw_data(h.src)[t.lo:][:t.n]))
	if !rules.integral(d) {
		return .Wrong_Kind
	}
	v, fits := rules.decimal_i64(d)
	if !fits {
		return .Out_Of_Range
	}
	return store_int(u64(v) if v >= 0 else u64(-(v + 1)) + 1, v < 0, fld.kind, dest)
}

// Judges a scalar a type's plan stored by its record's rules, which the record's `Meta.rule_set` names. A string
// record's stored text is its decoded text.
@(cold)
@(private)
check_rules :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token, fld: ^Field, dest: uintptr) -> core.Action {
	l := &h.plan.leaves[h.plan.meta[fld.meta].rule_set - 1]
	fails: rules.Failures
	#partial switch t.kind {
	case .String:
		stored: Maybe(string)
		if fld.kind == .String {
			stored = (^string)(dest)^
		}
		fails = judge_string(h, t, l, stored)
	case .Number:
		kind_ok := true
		fails = judge_number(h, t, l, &kind_ok)
	}
	if fails == {} {
		return .Next
	}
	context = h.ctx
	lo, hi := core.scalar_ends(t)
	for kind in fails {
		note(h, regs, {kind = kind, at = lo}, hi)
		if h.sink == nil {
			return .Stop
		}
	}
	return .Next
}

// The step of the value at `at` inside the container `f` of the `Checked` record `owner`: its index, the name of the
// member whose record reads it, or the text of the object's last key.
@(private)
checked_step :: proc(h: ^Reader, f: ^Frame, owner: ^Field, at: core.Hook_Regs) -> (core.Step, bool) {
	if f.kind == .Array {
		return core.Index(at.c), true
	}
	m := &h.plan.meta[owner.meta]
	if rec := i32(field_at(at.b).meta); rec >= m.block && rec < m.block + m.members {
		return core.Name(h.plan.meta[rec].name), true
	}
	key := core.Token{lo = u64(uintptr(f.owner)), n = u32(f.target), kind = .String, role = .Key, spelling = u16(f.target >> 32)}
	if key.spelling == TEXT_KEY {
		return core.Name(TEXT_NAME), true
	}
	// The text is the input's or the temp allocator's, never the reader's.
	text, ok := core.token_text(h.plan.readers, &h.view, key, context.temp_allocator)
	return core.Name(text), ok
}

// How many entries a read judged again for its repeats keeps when the caller gave no sink, which a failure past it
// reports as a failure with the entries it did keep.
@(private)
REJUDGE_ENTRIES :: 1 << 16

// Starts the second read of a check that ended on `.Duplicate_Key` while noticing repeats: takes back what the first
// read put in `read.sink` since `mark`, and returns the options of the read that judges them. A read with no sink gets
// `own` as its sink, for `rejudged` to settle.
rejudge :: proc(read: Read_Options, mark: Sink_Mark, own: ^Sink, allocator: runtime.Allocator) -> Read_Options {
	judged := read
	judged.repeats = .Judge
	if read.sink != nil {
		sink_restore(read.sink, mark)
	} else {
		own^ = {max_errors = REJUDGE_ENTRIES}
		own.entries.allocator = allocator
		judged.sink = own
	}
	return judged
}

// The refusal of a read `rejudge` gave `own` as its sink, `e` when it ended on a fault, else the first entry it kept, none
// for a text whose repeats left it nothing to fail. Frees `own`.
rejudged :: proc(own: ^Sink, e: core.Typed_Error) -> (first: core.Typed_Error) {
	defer sink_destroy(own)
	switch {
	case e.kind == .Walk || e.kind == .No_Memory:
		return e
	case len(own.entries) > 0:
		return {kind = own.entries[0].kind, at = own.entries[0].start}
	case own.truncated:
		return {kind = .Bad_Option}
	}
	return
}

// Whether a check with no sink that stopped on a refusal had an object open, whose later repeat of a key could take the
// refusal back, so the caller reads again judging repeats.
@(private)
repeat_may_retract :: proc(r: ^Reader) -> bool {
	for i in 1 ..< r.sp {
		if r.frames[i].kind == .Object {
			return true
		}
	}
	return false
}
