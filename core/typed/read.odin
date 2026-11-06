package typed

import "base:runtime"
import "core:mem"
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

// A typed read's options. `dups` is nil for `.Last`, and `refuse_duplicates` reads the whole text first and refuses a
// repeated key anywhere in it. `unknown` says what a key the type does not name does. `borrow_strings` makes a string
// with nothing to decode a slice of `src` in place of a copy. `collect`, when set, reads past a refusal.
Read_Options :: struct {
	dups:              Maybe(core.Duplicates),
	refuse_duplicates: bool,
	unknown:           Unknown_Fields,
	borrow_strings:    bool,
	collect:           ^Collected,
}

// What a key the type does not name does.
Unknown_Fields :: enum u8 {
	Ignore,
	Refuse,
}

// A value's text, kept as the format spells it: a struct field's or a captured unknown member's whole value.
Raw :: distinct string

// A number's text. As a target it takes any number, and an `any` holds a number no integer or binary64 reads as one.
Number_Text :: distinct string

// The arm of `Scalar` for a null.
Null :: struct {}

// One decoded scalar. An integer that fits and is not `-0` is an `i64` or, past `max(i64)`, a `u64`.
Scalar :: union {
	Null,
	bool,
	i64,
	u64,
	f64,
	Number_Text,
	string,
}

// The state of one read. Its `expect` and `mant` are the fields the walk finds by name: `expect` says the records `b`
// walks hold an `Expected_Key` first, and `mant` receives a number's folded digits.
Reader :: struct {
	expect:    ^Field,
	mant:      u64,
	base:      [^]u8,
	frames:    [^]Frame,
	sp:        int,
	borrow:    bool,
	first_key: bool, // `.First`
	refuse_unknown: bool,
	// The source, the format and its read, which a token's text and number read through.
	using view: core.Token_View,
	plan:      ^Plan,
	ctx:       runtime.Context,
	first:     core.Typed_Error,
	collect:   ^Collected,
	// Finds the member `Plan.union_tag` of the object at a byte, for a union that reads by its tag.
	find_tag:  proc(h: ^Reader, at: u64) -> Tag_Scan,
	// The format's own options, for `find_tag`.
	format:    rawptr,
}

// Starts a read of `src` into `target`, a value of `plan`'s type. `frames` holds two more than the walk's
// depth, for the frame below the root's and the root's. The walk then runs with `r` and the returned registers, and
// `read_end` ends it.
read_start :: proc(r: ^Reader, src: []u8, plan: ^Plan, spelling: ^core.Spelling, T: typeid, target: rawptr, read: Read_Options, frames: []Frame, allocator: runtime.Allocator) -> (regs: core.Hook_Regs, err: core.Typed_Error) {
	if plan == nil || plan.spelling != spelling || plan.type != T {
		err.kind = .Plan_Mismatch
		return
	}
	if target == nil {
		err.kind = .Bad_Option
		return
	}
	r.ctx = context
	r.ctx.allocator = allocator
	// The frame below the root's is read as a parent's and never written past `seen`.
	frames[0].seen = 0
	r.base, r.frames, r.sp, r.src, r.plan = raw_data(src), raw_data(frames), 1, src, plan
	r.borrow, r.collect = read.borrow_strings, read.collect
	r.spelling = spelling
	r.first_key = read.dups == .First
	r.refuse_unknown = read.unknown == .Refuse
	return {NO_LIMIT, u64(uintptr(plan.root)), u64(uintptr(target))}, {}
}

// Ends a read: gives the open lists to their destinations, so what the read allocated is reachable from the target, and
// returns the first refusal or `fault`.
read_end :: proc(r: ^Reader, regs: core.Hook_Regs, fault: Maybe(core.Fault)) -> core.Typed_Error {
	if f, faulted := fault.?; faulted {
		e := core.Typed_Error{kind = .Walk, at = f.at, inner = f}
		note(r, regs, e)
	}
	// A read ended early gives each open list to its destination.
	top, child := regs, false
	for i := r.sp - 1; r.first.kind != .None && i >= 1; i -= 1 {
		f := &r.frames[i]
		if owner := frame_owner(f); owner.kind == .Slice || owner.kind == .Dynamic || owner.kind == .Fixed_List {
			publish_list(r, f, owner, top.a, top.c, child)
		}
		top, child = {f.a, f.b, f.c}, true
	}
	return r.first
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

@(rodata, private)
POW10 := [16]f64{1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15}

// The hook. A value's open takes no call on the hot kinds, and every kind past `F64` fails the compares here and
// reaches `indirect`.
on_token :: #force_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	if t.role == .Key {
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
		if owner.kind != .Struct {
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
			(^runtime.Raw_String)(dest)^ = {h.base[t.lo:], int(t.n)}
		}
	case .Number:
		#partial switch fld.kind {
		case .I64:
			if core.number_shape(t.spelling) <= 19 && h.mant >> 63 == 0 {
				(^i64)(dest)^ = -i64(h.mant) if h.base[t.lo] == '-' else i64(h.mant)
			} else {
				reason = number_cold(h, t, fld, dest)
			}
		case .F64, .F32:
			frac, sum := core.number_digits(t.spelling)
			if sum <= 15 {
				v := f64(h.mant) / POW10[frac]
				v = -v if h.base[t.lo] == '-' else v
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
				reason = store_int(h.mant, h.base[t.lo] == '-', fld.kind, dest)
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
	case .Map:
		if fld.kind != .Struct {
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
	if reason != .None {
		return refuse_value(h, regs, t, reason)
	}
	regs.c += u64(fld.stride)
	return regs, .Next
}

// `on_token` for a spec whose numbers may have a spelling of their own, which the walk does not fold.
on_token_spelled :: #force_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if t.kind == .Number && t.role == .Value && t.spelling & core.NUMBER_KIND_MASK != 0 {
		return spelled_number(h, regs, t)
	}
	return on_token(h, regs, t)
}

@(private)
on_token_cold :: #force_no_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return on_token_spelled(h, regs, t)
}

// Stores a string token's text: a decoded buffer, or the span as the read keeps one.
@(cold)
store_string :: #force_no_inline proc "contextless" (h: ^Reader, t: core.Token, dest: ^string) -> core.Typed_Error_Kind {
	context = h.ctx
	if t.spelling & core.SPELLING_DECODE != 0 {
		s, ok := core.token_text(h.plan.spelling, &h.view, t, context.allocator)
		if !ok {
			return .Out_Of_Memory
		}
		dest^ = s
		return .None
	}
	return store_span(h, t.lo, u64(t.n), dest)
}

// Gives the open list room for one more element. A fixed array has no more room.
@(cold)
grow_list :: #force_no_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs) -> (core.Hook_Regs, core.Typed_Error_Kind) {
	context = h.ctx
	f := &h.frames[h.sp - 1]
	owner := frame_owner(f)
	if owner.kind == .Array || owner.kind == .Fixed_List {
		return regs, .Wrong_Length
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
		return regs, .Out_Of_Memory
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

// Writes the header of the list that closes at `regs.c`, or does what else a container's close does. Reports a refusal.
@(cold)
@(private)
close_container :: #force_no_inline proc "contextless" (h: ^Reader, f: ^Frame, own: ^Field, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	owner := frame_owner(f)
	back := core.Hook_Regs{f.a, f.b, f.c + u64(own.stride)}
	#partial switch owner.kind {
	case .Raw, .Hook:
		// A container inside the value read whole counts in `seen`, with no frame of its own.
		if f.seen != 0 {
			f.seen -= 1
			h.sp += 1
			return regs, .Next
		}
		context = h.ctx
		lo := u64(uintptr(f.data))
		if reason := store_whole(h, owner, &h.plan.meta[owner.meta], list_dest(f, owner), f.kind, lo, t.lo + u64(t.n), t); reason != .None {
			return refuse(h, back, {kind = reason, at = lo})
		}
	case .Required:
		if at := missing_member(h, f, owner, regs); at >= 0 {
			// The struct's frame is reopened for the path, whose last step this name replaces.
			h.sp += 1
			r, action := refuse(h, back, core.Typed_Error{kind = .Missing_Field, at = t.lo, steps = {0 = core.Name(h.plan.meta[int(h.plan.meta[owner.meta].block) + int(at)].name)}, n_steps = 1})
			h.sp -= 1
			return r, action
		}
	case .Array:
		if regs.c != regs.a {
			return refuse(h, back, core.Typed_Error{kind = .Wrong_Length, at = t.lo})
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
