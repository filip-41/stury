package typed

import "base:runtime"
import "core:mem"
import spell "../spell"
import core ".."

// `Hook_Regs` while reading: `b` walks the plan's records, `c` is the struct the members are read into or the list's
// next element, and `a` is one past the list's capacity, or `NO_LIMIT` outside a list, so one compare guards every
// value and a value in a struct pays no branch on what holds it.
@(private)
NO_LIMIT :: max(u64)

// An open container, with the registers its close gives back. `data` is a list's first element, a map, or a struct's
// base once a key arrived out of order. `seen` holds which members of a struct have been read, kept only once a key
// arrives out of order, since until then the cursor says, with `SEEN_ON` set then, and a map's keys under `.First`.
// `run` is the member after the one last found by key, and a map's last key's length. `extra` holds the repeats of a
// member past the 63rd, and points at a map's last key's text, which a key named by its position holds outside the source.
Frame :: struct {
	a, b, c: u64,
	data:    rawptr,
	seen:    u64,
	run:     ^Field,
	extra:   [^]u64,
	owner:   ^Field, // the record that reads this container when a `Ptr`, a `Maybe`, a `Union` or an `Any` wraps it
	target:  uintptr, // where such a container's list header goes
	kind:    core.Kind, // a container read whole's
}

// Set in `Frame.seen` once the members are tracked. The members past the 63rd are tracked in `Frame.extra`.
@(private)
SEEN_ON :: u64(1) << 63

// A typed read's options. `dups` picks among a repeated key, `.Refuse` reads the whole text first and refuses a
// repeated key anywhere in it, and `.All` is `.Bad_Option`, since a field holds one value. `unknown` says what a key the type does not name does. `borrow_strings` makes a string
// with nothing to decode a slice of `src` in place of a copy. `sink`, when set, reads past a refusal.
Read_Options :: struct {
	dups:           core.Duplicates,
	unknown:        Unknown_Fields,
	borrow_strings: bool,
	sink:        ^Sink,
	// What a `Check`'s entries start their paths with, nil for none.
	outer:       ^Outer,
	// How a `Check` meets a key that repeats in its object.
	repeats:     Repeats,
	// A model's patch: the structs `model.patch` merges member by member, the root and its struct members whose
	// structs hold a `Fields_Set`, miss no member and take no default. Every other struct reads as a full load reads it.
	partial:     bool,
	// What a `Check` keeps for the next value it checks, nil for nothing.
	checker:     ^Checker,
	// Where a `Check` keeps the kind it reads each `Plain` value as, nil for none.
	readings:    ^Readings,
}

// How a `Check` meets a key that repeats inside one object. `.Ignore` judges every value as it comes, which is the
// view of a read that counts each repeat as a member. `.Notice` ends the read with `.Duplicate_Key` at the first repeat
// that can change a verdict, so the caller reads again with `.Judge`. `.Judge` judges the object as `dups` reads it, a
// repeat under `.Last` taking back the errors of the earlier value and under `.First` being skipped, and counts distinct
// keys. `.Judge` needs a sink, which is where the earlier value's errors are taken back from.
Repeats :: enum u8 {
	Ignore,
	Notice,
	Judge,
}

// What a key the type does not name does.
Unknown_Fields :: enum u8 {
	Ignore,
	Refuse,
}

// A value's text, kept as the format spells it: a struct field's or a captured unknown member's whole value.
Raw :: distinct string

// A byte string, read from a string of RFC 4648 base64 with padding into bytes from `context.allocator`.
Bytes :: distinct []u8
// The arm of `Scalar` for a null.
Null :: struct {}

// One decoded scalar. An integer that fits and is not `-0` is an `i64` or, past `max(i64)`, a `u64`.
Scalar :: union {
	Null,
	bool,
	i64,
	u64,
	f64,
	core.Number_Text,
	string,
}

// The state of one read. Its `expect` and `mant` are the fields the walk finds by name: `expect` says the records `b`
// walks hold an `Expected_Key` first, and `mant` receives a number's folded digits.
Reader :: struct {
	expect:    ^Field,
	mant:      u64,
	frames:    [^]Frame,
	home:      [^]Frame, // the frames the read started with, its caller's
	sp:        int,
	borrow:    bool,
	first_key: bool, // `.First`
	refuse_unknown: bool,
	// A check, whose sink takes `core.Error_Entry`s: a `Check` when `as_schema` holds, else a `Reader` that checks a text
	// against a type.
	wide:      bool,
	partial:   bool, // as `Read_Options.partial`
	wrap_sp:   u32, // the depth `wrap`'s element is read at, 0 for none
	// The source, the format and its read, which a token's text and number read through.
	using view: core.Token_View,
	plan:      ^Plan,
	// The registers of the outermost wrapper whose element is read at depth `wrap_sp`. A refusal of that element takes
	// its path from them, since the element's own registers name no member and no index.
	wrap:      ^core.Hook_Regs,
	ctx:       runtime.Context,
	first:     core.Typed_Refusal,
	sink:      ^Sink,
	// Finds the member `name` of the object at a byte, for a union that reads by its tag.
	find_tag:  proc(h: ^Reader, at: u64, name: string) -> Tag_Scan,
	// The format's own options, for `find_tag`.
	format:    rawptr,
}

// Starts a read of `src` into `target`, a value of `plan`'s type. `frames` holds two more than the walk's
// depth, for the frame below the root's and the root's. The walk then runs with `r` and the returned registers, and
// `read_end` ends it. A read that is no `Check` passes `judged` false.
read_start :: #force_inline proc(r: ^Reader, src: []u8, plan: ^Plan, as: core.As, T: typeid, target: rawptr, read: Read_Options, frames: []Frame, allocator: runtime.Allocator, judged := true) -> (regs: core.Hook_Regs, err: core.Typed_Refusal) {
	// A model's plan reads only as its load does: by the load plan, as a check, which judges the rules, into a zeroed
	// target.
	if plan == nil || !core.same_format(plan.readers, as.readers) || plan.type != T || plan.model_plan == .Whole || plan.model_plan == .Load && !judged {
		err = plan_mismatch(plan, as.readers, T)
		return
	}
	if target == nil {
		err.kind = .Bad_Option
		return
	}
	if plan.model_plan == .Load {
		runtime.mem_zero(target, type_info_of(T).size)
	}
	r.ctx = context
	r.ctx.allocator = allocator
	// The frame below the root's is read as a parent's and never written past `seen`.
	frames[0].seen = 0
	r.frames, r.home, r.sp, r.src, r.plan = raw_data(frames), raw_data(frames), 1, src, plan
	r.borrow, r.sink = read.borrow_strings, read.sink
	r.view.as = as
	if read.dups == .All {
		err = {kind = .Bad_Option, want = {text = "a field holds one value, so dups = .All reads into no type"}}
		return
	}
	r.first_key = read.dups == .First
	r.refuse_unknown = read.unknown == .Refuse
	r.partial = read.partial
	return {NO_LIMIT, u64(uintptr(plan.root)), u64(uintptr(target))}, {}
}

// Gives the read room for at least `want` frames in place of the `have` it holds, on the default heap with the frames
// open, for a walk that nests past those it has. Returns the room, or false when it does not fit in memory. A copy holds
// the old frames beside the new, so the room grows eightfold, and to as deep as the text can nest once a step would
// pass half of that. The frames a read starts with are its caller's, and `read_release` frees a grown copy.
@(cold)
grow_frames :: #force_no_inline proc "contextless" (h: ^Reader, have, want: int) -> (int, bool) {
	bound := len(h.src) + 18
	n := min(max(want, 8 * have), bound)
	if 2 * n > bound {
		n = bound
	}
	if n <= have {
		return have, true
	}
	grown := h.frames != h.home
	wide := runtime.heap_resize(h.frames, n * size_of(Frame)) if grown else runtime.heap_alloc(n * size_of(Frame), false)
	if wide == nil {
		return have, false
	}
	if !grown {
		mem.copy_non_overlapping(wide, h.frames, min(h.sp + 1, have) * size_of(Frame))
	}
	h.frames = ([^]Frame)(wide)
	return n, true
}

// Frees the frames `grow_frames` gave a read that started with `frames`.
read_release :: proc "contextless" (r: ^Reader, frames: []Frame) {
	if r.frames != raw_data(frames) {
		runtime.heap_free(r.frames)
	}
}

// The refusal of a read or write given `plan` for a value of `T` in the format `readers` reads, which the plan does not
// read: the plan's own error when `plan_make` refused it, `.Bad_Option` saying so for a model's plan of the format and
// type, which only `model.load` reads, else `.Plan_Mismatch` naming the two formats, or the plan's type when the formats
// agree.
plan_mismatch :: proc "contextless" (plan: ^Plan, readers: ^core.Readers, T: typeid) -> core.Typed_Refusal {
	e := core.Typed_Refusal{kind = .Plan_Mismatch}
	if plan == nil {
		return e
	}
	if plan.err.kind != .None {
		return plan.err
	}
	same := core.same_format(plan.readers, readers)
	if same && plan.model_plan != .None && plan.type == T {
		return {kind = .Bad_Option, want = {text = "a model's plan reads only through model.load"}}
	}
	e.plans = {plan.readers, readers, plan.type if same else nil}
	return e
}

// Ends a read: gives the open lists to their destinations, so what the read allocated is reachable from the target, and
// returns the first refusal or `fault`.
read_end :: proc(r: ^Reader, regs: core.Hook_Regs, fault: Maybe(core.Fault)) -> core.Typed_Refusal {
	if r.plan.checking {
		taken_settle((^Check)(r))
	}
	if f, faulted := fault.?; faulted {
		context = r.ctx
		e := core.Typed_Refusal{kind = .Walk, at = f.at, inner = f}
		if r.sink != nil {
			r.sink.fatal = e
		}
		if !r.plan.checking || !fault_note((^Check)(r), regs, e) {
			note(r, regs, e, f.at)
		}
	}
	if as_schema(r) && r.sink == nil && (^Check)(r).repeats == .Notice && r.first.kind != .None && r.first.kind != .Walk && r.first.kind != .No_Memory && r.first.kind != .Duplicate_Key && repeat_may_retract(r) {
		// With no sink the first refusal ends the read, before a later repeat can take it back.
		r.first = {kind = .Duplicate_Key, at = r.first.at}
	}
	if r.first.kind != .None {
		publish_open(r, regs, 1)
	}
	return r.first
}

// Gives each list open in the frames from `r.sp` less one down to `floor`, innermost first, to its destination, so what a
// read ended early allocated is reachable from the target. `regs` are the registers of the innermost frame's next value.
@(private)
publish_open :: proc(r: ^Reader, regs: core.Hook_Regs, floor: int) {
	top, child := regs, false
	for i := r.sp - 1; i >= floor; i -= 1 {
		f := &r.frames[i]
		if owner := frame_owner(f); owner.kind == .Slice || owner.kind == .Dynamic || owner.kind == .Fixed_List {
			publish_list(r, f, owner, top.a, top.c, child)
		}
		top, child = {f.a, f.b, f.c}, true
	}
}

field_at :: #force_inline proc "contextless" (b: u64) -> ^Field {
	return ([^]Field)(uintptr(b))[-1:]
}

@(private)
F32_NORMAL :: 1.1754943508222875e-38

// Whether the binary64 `v` of a decimal may narrow to a different f32 than the decimal rounds to: its low 29 bits are
// a normal f32's midpoint, or it is below the normal range, where an f32 keeps fewer bits. Otherwise a cast rounds once.
@(private)
f32_double_rounds :: #force_inline proc "contextless" (v: f64) -> bool {
	return transmute(u64)v & (1 << 29 - 1) == 1 << 28 || abs(v) < F32_NORMAL && v != 0
}

// The hook. A value's open takes no call on the hot kinds, and every kind past `F64` fails the compares here and
// reaches `indirect`.
on_token :: #force_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return hook(h, regs, t)
}

// `on_token` for a `Check`, which judges a record's rules as it reads, and a `Checked` record's in place of a store.
on_token_check :: #force_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return hook(h, regs, t)
}

// Refuses the missing member `at` of the struct that closes at `t`, then judges the members that are there by their
// validators, as `validate` judges a value that holds them. The struct's own validators wait for its members.
@(cold, private)
refuse_missing_settled :: #force_no_inline proc "contextless" (h: ^$H, f: ^Frame, owner: ^Field, back, regs: core.Hook_Regs, t: core.Token, at: i32) -> (core.Hook_Regs, core.Action) {
	out, action := refuse_missing(h, f, owner, back, regs, t, at)
	when H == Check {
		if sm := h.plan.meta[owner.meta].model; action != .Stop && sm != nil && sm.settle != nil {
			sm.settle(h, sm, f, owner, regs, t.lo)
		}
	}
	return out, action
}

// Settles the struct that closes at `t` by its model: a validator's failure has been recorded and skips the struct.
@(cold, private)
settle_close :: #force_no_inline proc "contextless" (h: ^$H, sm: ^Struct_Model, f: ^Frame, owner: ^Field, back, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	// Only a `Check` reads a load's plan, whose structs settle.
	when H == Check {
		kind, reported := sm.settle(h, sm, f, owner, regs, t.lo)
		switch {
		case kind != .None:
			return refuse(h, back, {kind = kind, at = t.lo}, t.lo + u64(t.n))
		case reported:
			return back, .Stop if h.sink == nil else .Skip
		}
	}
	return back, .Next
}

@(private)
hook :: #force_inline proc "contextless" (h: ^$H, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	if t.role == .Key {
		when H == Check {
			if field_at(h.frames[h.sp - 1].b).kind == .Checked {
				return check_key(h, regs, t)
			}
		}
		return on_key(h, regs, t)
	}
	if t.role != .Value {
		return regs, .Next
	}
	regs := regs
	if t.kind == .End {
		h.sp -= 1
		f := &h.frames[h.sp]
		owner := field_at(f.b)
		if owner.kind == .Required {
			if f.seen != 0 || regs.b < u64(uintptr(owner.first)) + u64(h.plan.meta[owner.meta].required_end) * size_of(Field) {
				if at := missing_member(h, f, owner, regs, 0); at >= 0 {
					return refuse_missing_settled(h, f, owner, {f.a, f.b, f.c + u64(owner.stride)}, regs, t, at)
				}
				if sm := h.plan.meta[owner.meta].model; sm != nil && sm.settle != nil {
					return settle_close(h, sm, f, owner, {f.a, f.b, f.c + u64(owner.stride)}, regs, t)
				}
			}
		} else if owner.kind != .Struct {
			return close_container(h, f, owner, regs, t)
		}
		return {f.a, f.b, f.c + u64(owner.stride)}, .Next
	}
	if regs.c >= regs.a {
		kind: core.Typed_Error_Kind
		regs, kind = grow_list(h, regs)
		if kind != .None {
			return refuse_element(h, regs, t, kind)
		}
	}
	fld := field_at(regs.b)
	when H == Check {
		if fld.kind == .Checked {
			return check_value(h, regs, t)
		}
	}
	dest := uintptr(regs.c) + uintptr(fld.offset)
	reason: core.Typed_Error_Kind
	#partial switch t.kind {
	case .String:
		if fld.kind != .String {
			return indirect(h, regs, t)
		}
		if t.spelling & core.SPELLING_DECODE != 0 || !h.borrow {
			reason = store_string(h, t, (^string)(dest))
		} else {
			(^runtime.Raw_String)(dest)^ = {raw_data(h.src)[t.lo:], int(t.n)}
		}
	case .Number:
		#partial switch fld.kind {
		case .I64:
			if core.number_shape(t.spelling) <= 19 && h.mant >> 63 == 0 {
				(^i64)(dest)^ = -i64(h.mant) if raw_data(h.src)[t.lo] == '-' else i64(h.mant)
			} else {
				reason = number_cold(h, t, fld, dest)
			}
		case .F64, .F32:
			frac, sum := core.number_digits(t.spelling)
			if sum <= 15 {
				v := f64(h.mant) / spell.POW10_F64[frac]
				v = -v if raw_data(h.src)[t.lo] == '-' else v
				if fld.kind == .F64 {
					(^f64)(dest)^ = v
				} else if !f32_double_rounds(v) {
					(^f32)(dest)^ = f32(v)
				} else {
					reason = number_cold(h, t, fld, dest)
				}
			} else {
				reason = number_cold(h, t, fld, dest)
			}
		case .I8 ..= .I32, .U8 ..= .U64:
			if core.number_shape(t.spelling) <= 19 {
				reason = store_int(h.mant, raw_data(h.src)[t.lo] == '-', fld.kind, dest)
			} else {
				reason = number_cold(h, t, fld, dest)
			}
		case:
			return indirect(h, regs, t)
		}
	case .True, .False:
		if fld.kind != .Bool {
			return indirect(h, regs, t)
		}
		(^bool)(dest)^ = t.kind == .True
	case .Object:
		if fld.kind != .Struct && fld.kind != .Required {
			return open_map(h, regs, fld, dest, t)
		}
		parent := &h.frames[h.sp - 1]
		if parent.seen != 0 {
			revisit(h, parent, regs, fld, dest)
		}
		f := &h.frames[h.sp]
		h.sp += 1
		f.a, f.b, f.c, f.seen = regs.a, regs.b, regs.c, 0
		return {NO_LIMIT, u64(uintptr(fld.first)), u64(dest)}, .Next
	case .Array:
		if fld.kind != .Slice && fld.kind != .Dynamic {
			return open_array(h, regs, fld, dest, t)
		}
		f := &h.frames[h.sp]
		h.sp += 1
		f.a, f.b, f.c, f.data, f.seen = regs.a, regs.b, regs.c, nil, 0
		return {0, u64(uintptr(fld.first)), 0}, .Next
	case:
		return indirect(h, regs, t)
	}
	when H == Check {
		if reason == .Wrong_Kind && t.kind == .Number && fld.kind >= .I8 && fld.kind <= .U64 {
			reason = store_integral(h, t, fld, dest)
		}
	}
	if reason != .None {
		return refuse_value(h, regs, t, reason)
	}
	when H == Check {
		if h.plan.meta[fld.meta].rule_set > 0 && check_rules(h, regs, t, fld, dest) == .Stop {
			return regs, .Stop
		}
	}
	regs.c += u64(fld.stride)
	return regs, .Next
}

// `on_token` for a spec whose numbers may have a spelling of their own, which the walk does not fold.
on_token_spelled :: #force_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return hook_spelled(h, regs, t)
}

// `on_token_spelled` for a `Check`.
on_token_check_spelled :: #force_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return hook_spelled(h, regs, t)
}

@(private)
hook_spelled :: #force_inline proc "contextless" (h: ^$H, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if t.kind == .Number && t.role == .Value && t.spelling & core.NUMBER_KIND_MASK != 0 {
		return spelled_number(h, regs, t)
	}
	return hook(h, regs, t)
}

@(private)
on_token_cold :: #force_no_inline proc "contextless" (h: ^$H, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return hook_spelled(h, regs, t)
}

// Stores a string token's text: a decoded buffer, or the span as the read keeps one.
@(cold)
store_string :: #force_no_inline proc "contextless" (h: ^Reader, t: core.Token, dest: ^string) -> core.Typed_Error_Kind {
	context = h.ctx
	if t.spelling & core.SPELLING_DECODE != 0 {
		s, ok := core.token_text(h.plan.readers, &h.view, t, context.allocator)
		if !ok {
			return .No_Memory
		}
		dest^ = s
		return .None
	}
	return store_span(h, t.lo, u64(t.n), dest)
}

// Gives the open list room for one more element. A fixed array or a full fixed list has no more room, which is `.Too_Many`.
@(cold)
grow_list :: #force_no_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs) -> (core.Hook_Regs, core.Typed_Error_Kind) {
	context = h.ctx
	f := &h.frames[h.sp - 1]
	owner := frame_owner(f)
	if owner.kind == .Array || owner.kind == .Fixed_List {
		return regs, .Too_Many
	}
	m := &h.plan.meta[owner.meta]
	stride := u64(m.elem_size)
	data := u64(uintptr(f.data))
	n, room: u64
	if f.data != nil {
		n, room = (regs.c - data) / stride, (regs.a - data) / stride
	}
	wide := max(8, room * 2)
	bytes, err := runtime.non_zero_mem_resize(f.data, int(room * stride), int(wide * stride), int(m.align), context.allocator)
	if err != nil {
		return regs, .No_Memory
	}
	if m.zeroed {
		mem.zero(raw_data(bytes)[room * stride:], int((wide - room) * stride))
	}
	f.data = raw_data(bytes)
	data = u64(uintptr(f.data))
	return {data + wide * stride, regs.b, data + n * stride}, .None
}

// The record that reads the container a frame holds.
@(private)
frame_owner :: #force_inline proc "contextless" (f: ^Frame) -> ^Field {
	owner := field_at(f.b)
	return f.owner if wrapper(owner) else owner
}

// Reports the `required` member `at`, absent from the struct that closes, and under a `Check` every one after it.
@(cold)
@(private)
refuse_missing :: #force_no_inline proc "contextless" (h: ^$H, f: ^Frame, owner: ^Field, back, regs: core.Hook_Regs, t: core.Token, at: i32) -> (core.Hook_Regs, core.Action) {
	at := at
	for at >= 0 {
		// The struct's frame is reopened for the path, whose last step the name replaces.
		h.sp += 1
		r, action := refuse(h, back, core.Typed_Refusal{kind = .Missing_Field, at = t.lo, steps = {0 = core.Name(h.plan.meta[int(h.plan.meta[owner.meta].block) + int(at)].name)}, n_steps = 1}, t.lo + u64(t.n))
		h.sp -= 1
		// A `Check` reports every absent member, a read the first.
		when H != Check {
			return r, action
		}
		if action == .Stop {
			return r, action
		}
		at = missing_member(h, f, owner, regs, at + 1)
	}
	return back, .Next
}

// Writes the header of the list that closes at `regs.c`, or does what else a container's close does. Reports a refusal.
@(cold)
@(private)
close_container :: #force_no_inline proc "contextless" (h: ^$H, f: ^Frame, own: ^Field, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	owner := frame_owner(f)
	when H == Check {
		if owner.kind == .Checked {
			return check_close(h, f, owner, regs, t)
		}
		if n := len(h.opens); n > 0 && h.opens[n - 1].sp == h.sp {
			return judged_close(h, f, own, owner, regs, t)
		}
	}
	return #force_inline close_read(h, f, own, owner, regs, t)
}

// The close of the container `f` holds, which record `owner` reads and `own` returns to.
@(private)
close_read :: proc "contextless" (h: ^$H, f: ^Frame, own, owner: ^Field, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	back := core.Hook_Regs{f.a, f.b, f.c + u64(own.stride)}
	when H == Check {
		if h.plan.meta[owner.meta].rule_set > 0 && count_rules(h, f, owner, regs, t) == .Stop {
			return back, .Stop
		}
	}
	#partial switch owner.kind {
	case .Raw, .Hook, .Value, .Before:
		// A container inside the value read whole counts in `seen`, with no frame of its own.
		if f.seen != 0 {
			f.seen -= 1
			h.sp += 1
			return regs, .Next
		}
		context = h.ctx
		lo := u64(uintptr(f.data))
		when H == Check {
			if owner.kind == .Before {
				m := &h.plan.meta[owner.meta]
				return extra_of(h.plan, m).before.value(h, back, m, list_dest(f, owner), f.kind, lo, t.lo + u64(t.n))
			}
		}
		if reason := store_whole(h, owner, &h.plan.meta[owner.meta], list_dest(f, owner), f.kind, lo, t.lo + u64(t.n), t); reason != .None {
			return refuse(h, back, {kind = reason, at = lo}, t.lo + u64(t.n))
		}
	case .Required:
		if at := missing_member(h, f, owner, regs, 0); at >= 0 {
			return refuse_missing_settled(h, f, owner, back, regs, t, at)
		}
		if sm := h.plan.meta[owner.meta].model; sm != nil && sm.settle != nil {
			return settle_close(h, sm, f, owner, back, regs, t)
		}
	case .Array:
		if regs.c != regs.a {
			return refuse(h, back, core.Typed_Refusal{kind = .Too_Few, at = t.lo}, t.lo + u64(t.n))
		}
	case .Slice, .Dynamic, .Fixed_List:
		publish_list(h, f, owner, regs.a, regs.c, false)
	}
	return back, .Next
}

// Writes the list `f` holds to its destination, with the element at `c` counted when `open` says it is being read.
@(private)
publish_list :: proc "contextless" (h: ^Reader, f: ^Frame, owner: ^Field, a, c: u64, open: bool) {
	dest := list_dest(f, owner)
	m := &h.plan.meta[owner.meta]
	stride := u64(m.elem_size)
	data := u64(uintptr(f.data))
	n, room: int
	if f.data != nil {
		n, room = int((c - data) / stride) + (1 if open else 0), int((a - data) / stride)
	}
	#partial switch owner.kind {
	case .Slice:
		(^runtime.Raw_Slice)(dest)^ = {f.data, n}
	case .Dynamic:
		(^runtime.Raw_Dynamic_Array)(dest)^ = {f.data, n, room, h.ctx.allocator}
	case .Fixed_List:
		(^int)(uintptr(f.data) + uintptr(m.tag))^ = n
	}
}

// Where a container's start goes. A wrapper's frame holds the record it returns to, so it holds the address too.
@(private)
list_dest :: #force_inline proc "contextless" (f: ^Frame, owner: ^Field) -> uintptr {
	if wrapper(field_at(f.b)) {
		return f.target
	}
	return uintptr(f.c) + uintptr(owner.offset)
}
