package cbor

// The typed read and write of CBOR. `marshal` writes a value through the shared walk of `core/write` with CBOR's heads,
// and `unmarshal` reads an item through the shared reader of `core/typed`, which takes a struct as a map of its members
// by name or as an array of them by position.

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:simd"
import core "../core"
import kernel "../core/kernel"
import typed "../core/typed"
import write "../core/write"

// CBOR's heads, in the layout `write.Head` gives: unsigned and negative integers, byte and text strings, arrays, maps
// and tags, then the half, single and double float markers.
@(private)
TREE :: write.Tree {
	.Open_Object  = "",
	.Close_Object = "",
	.Open_Array   = "",
	.Close_Array  = "",
	.Comma        = "",
	.Colon        = "",
	.After_Colon  = "",
	.Point_Zero   = "",
	.Inf          = "",
	.Neg_Inf      = "",
	.Nan          = "",
	.Null         = "\xf6",
	.True         = "\xf5",
	.False        = "\xf4",
	.Heads        = "\x00\x17\x18\x19\x1a\x1b" + "\x20\x17\x38\x39\x3a\x3b" + "\x40\x17\x58\x59\x5a\x5b" + "\x60\x17\x78\x79\x7a\x7b" + "\x80\x17\x98\x99\x9a\x9b" + "\xa0\x17\xb8\xb9\xba\xbb" + "\xc0\x17\xd8\xd9\xda\xdb" + "\xf9\xfa\xfb",
	.Bytes_Tag    = "",
}

// The walk's string writer: a text string's head and its bytes, which must be UTF-8. `p` is `write.room(out, 18)`.
@(private)
put_string :: proc(out: ^write.Out, p: [^]u8, s: string, _: ^core.Write_Options) -> core.Typed_Error_Kind #no_bounds_check {
	n := len(s)
	if n < 16 {
		v, live, ok := kernel.head16(raw_data(s), n)
		if ok {
			v = simd.select(simd.lanes_ne(live, Lanes(0)), v, Lanes(0))
			if simd.reduce_or(v) < 0x80 {
				p[0] = 0x60 | u8(n)
				intrinsics.unaligned_store((^Lanes)(p[1:]), v)
				out.cursor += n + 1
				return .None
			}
		}
	}
	return put_long_string(out, s)
}

// A text string past the short case, whose bytes are judged as a walk judges them.
@(private)
put_long_string :: proc(out: ^write.Out, s: string) -> core.Typed_Error_Kind {
	if !utf8_valid(transmute([]u8)s) {
		return .Invalid_Utf8
	}
	out.cursor += write.put_head(write.room(out, 9), u64(len(s)), TREE, .Text)
	write.put_text(out, s)
	return .None
}

// The plan's `marshal`. A deterministic spec sorts a struct's members by their written keys, as it sorts a map's.
@(private)
marshal_text :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, omits: ^typed.Omits) -> ([]u8, core.Typed_Refusal) {
	return write.marshal_binary(plan, value, write_options(opts, plan.as), stream, allocator, omits, binary_options(plan.as), TREE, put_string)
}

@(private)
write_options :: #force_inline proc "contextless" (opts: core.Write_Options, as: core.As) -> core.Write_Options {
	w := opts
	w.sort_keys ||= Spec(as.spec) >= .Deterministic
	return w
}

@(private)
binary_options :: #force_inline proc "contextless" (as: core.As) -> write.Binary_Options {
	return {positional = options_of(as).structs == .Array, length_first = Spec(as.spec) == .Length_First}
}

// Writes `value` as one CBOR item of `spec` into new bytes from `allocator`, as `opts` says: in preferred serialization,
// with a map's keys sorted by their encoded bytes, a struct as `opts.structs` says, and under `.Deterministic` and
// `.Length_First` a struct's members sorted as a map's keys are. A `typed.Bytes` is a byte string, and a
// `core.Number_Text` past 64 bits a bignum or a decimal fraction. `write.sort_keys` sorts a struct's members too, and the
// layout options have no meaning in a binary text. The form with no plan builds and frees one for the call, and a plan
// built once with `plan_make` is the form for many writes.
marshal :: proc {marshal_once, write.marshal}

@(private)
marshal_once :: proc(value: any, spec := Spec.Cbor, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error) {
	nothing: any
	v := typed.marshal_target(value, &nothing)
	plan, refusal := plan_bound(v.id, spec, opts, {}, nil, context.allocator)
	return typed.marshal_planned(&plan, core.error_of(refusal), v.data, write, allocator)
}

// Reads `src`, exactly one CBOR item of `spec`, into `target`. An absent member keeps what `target` holds. A struct
// reads from a map by its members' names or from an array by their positions, whatever `opts.structs` says, and an
// array's items past the last member are skipped. The form with no plan builds one with `context.allocator` and frees
// it before it returns, and a plan built once with `plan_make` is the form for many reads. A refusal leaves everything
// the read allocated reachable from `target`.
unmarshal :: proc {unmarshal_once, unmarshal_plan}

@(private)
unmarshal_once :: proc(src: []u8, spec: Spec, target: ^$T, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return unmarshal_any(src, spec, target, T, opts, read, allocator)
}

@(private)
unmarshal_plan :: proc(src: []u8, spec: Spec, target: ^$T, plan: ^typed.Plan, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	if plan == nil {
		return core.error_of(typed.plan_mismatch(plan, &PLAN_READERS, T))
	}
	return core.error_of(read_text(src, spec, opts, target, T, plan, read, allocator, false))
}

@(private)
unmarshal_any :: proc(src: []u8, spec: Spec, target: rawptr, T: typeid, opts: Options, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Error {
	plan, refusal := plan_bound(T, spec, opts, {}, &BUILDS, context.allocator)
	if refusal.kind != .None {
		return core.error_of(refusal)
	}
	defer typed.plan_destroy(&plan)
	err := read_text(src, spec, opts, target, T, &plan, read, allocator, false)
	typed.own_errors(&err, read.sink)
	return core.error_of(err)
}

// Reads `src` into `target` by `plan` as `unmarshal` does, with every refusal in `read.sink.entries`, and returns the
// first. The options are the plan's, and any plan of the format reads.
check :: proc(src: []u8, spec: Spec, target: ^$T, plan: ^typed.Plan, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return typed.check_by(src, bound_as(spec, options_of(typed.handle_of(plan))), target, T, plan, read, allocator, proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {return read_text(src, Spec(as.spec), options_of(as), target, T, plan, read, allocator, true)})
}

// The typed reads of a plan made from a type.
@(private, rodata)
READS := typed.Format_Reads {
	read  = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {return read_text(src, Spec(as.spec), options_of(as), target, T, plan, read, allocator, false)},
	build = build_value,
	plan  = proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {return plan_bound(T, .Cbor, {}, opts, &READS, allocator)},
}

// The reads of a plan made from a description or from a model, and of the handle: `READS` with the read that reports to
// a sink. A program that only reads into types does not name it, so it does not link a model's or a description's check.
@(private, rodata)
CHECKS := typed.Format_Reads {
	read  = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {return read_text(src, Spec(as.spec), options_of(as), target, T, plan, read, allocator, false)},
	check = proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {return read_text(src, Spec(as.spec), options_of(as), target, T, plan, read, allocator, true)},
	build = build_value,
	plan  = proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {return plan_bound(T, .Cbor, {}, opts, &CHECKS, allocator)},
}

// The reads of the plan `unmarshal` makes for one call, which holds the build of a `core.Value` member and no read.
@(private, rodata)
BUILDS := typed.Format_Reads {
	build = build_value,
}

// A plan's build of a value read whole.
@(private)
build_value :: proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	return build_item(src, as, false, allocator)
}

// A typed read's state beside the reader's: what the walk reads, whether each open level is a struct read from an array
// by position, and where the item the hook holds starts, its tags included.
@(private)
Read_State :: struct {
	rules:      Walk_Rules,
	item_lo:    u64,
	tagged:     bool, // `item_lo` is the first tag of the item that comes next
	positional: [core.MAX_DEPTH + 2]bool,
}

// Reads a whole text. A check that noticed a repeated key reads again, judging the repeats as `read.dups` says.
@(private)
read_text :: proc(src: []u8, spec: Spec, opts: Options, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, $CHECK: bool) -> core.Typed_Refusal {
	stack: [core.MAX_DEPTH + 2]typed.Frame = ---
	err: core.Typed_Refusal
	when CHECK {
		mark := typed.sink_mark(read.sink)
	}
	read_item(src, spec, opts, target, T, plan, read, stack[:], allocator, &err, CHECK)
	when CHECK {
		if err.kind == .Duplicate_Key && read.repeats == .Notice && read.dups != .Refuse {
			own: typed.Sink
			judged := typed.rejudge(read, mark, untracked(&own), allocator)
			err = {}
			read_item(src, spec, opts, target, T, plan, judged, stack[:], allocator, &err, CHECK)
			if judged.sink == untracked(&own) {
				err = typed.rejudged(untracked(&own), err)
			}
		}
	}
	return err
}

// Reads the one item of `src` into `target` with `frames`, and stores its error in `err`. A read under `.Refuse` builds
// the item first, in the temp allocator, to find a repeated key anywhere in it.
@(private)
read_item :: proc(src: []u8, spec: Spec, opts: Options, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, frames: []typed.Frame, allocator: runtime.Allocator, err: ^core.Typed_Refusal, $CHECK: bool) {
	if read.dups == .Refuse {
		arena := runtime.Arena{backing_allocator = context.temp_allocator, minimum_block_size = 4096}
		defer runtime.arena_destroy(&arena)
		_, built := build_item(src, bound_as(spec, opts), true, runtime.arena_allocator(&arena))
		if built.kind == .Walk || built.kind == .Duplicate_Key {
			err^ = {kind = .Walk if built.kind == .Walk else .Duplicate_Key, at = built.at, inner = built.inner}
			context.allocator = allocator
			typed.sink_refusal(read.sink, err^, CHECK)
			return
		}
		if built.kind != .None {
			err^ = {kind = .No_Memory}
			return
		}
	}
	H :: typed.Check when CHECK else typed.Reader
	h: H
	state: Read_State = ---
	state.rules, state.tagged = rules_of(spec, opts), false
	regs: core.Hook_Regs
	started: core.Typed_Refusal
	when CHECK {
		item_reader(&h.reader, untracked(&state))
		regs, started = typed.check_start(&h, src, plan, bound_as(spec, opts), T, target, read, untracked_frames(frames), allocator)
	} else {
		item_reader(&h, &state)
		regs, started = typed.read_start(&h, src, plan, bound_as(spec, opts), T, target, read, frames, allocator, false)
	}
	if started.kind != .None {
		err^ = started
		return
	}
	defer typed.read_release(&h, frames)
	state.positional[h.sp] = false
	on :: on_item_check when CHECK else on_item
	hi, fault := walk_rules(src, 0, state.rules, &h, &regs, on)
	if fault == nil {
		fault = tail_fault(src, hi)
	}
	// `read_end` only reports, so a read with no fault and no refusal leaves `err` as it is.
	if fault != nil || h.first.kind != .None {
		err^ = typed.read_end(&h, regs, fault)
	}
}

// A pointer to what outlives the read that holds it, hidden from the stack escape check, which cannot see through the
// base `Reader` of a `typed.Check` that the pointer stays within the call. Only the `Check` read uses it.
@(private)
untracked :: #force_inline proc "contextless" (p: ^$T) -> ^T {
	return (^T)(uintptr(p))
}

@(private)
untracked_frames :: #force_inline proc "contextless" (f: []typed.Frame) -> []typed.Frame {
	return ([^]typed.Frame)(untracked(raw_data(f)))[:len(f)]
}

// Points the typed reader `h` at CBOR's walk under the rules of `state`, which a union's tag scan walks with, and at
// the bytes of an item, which a value read whole takes.
@(private)
item_reader :: #force_inline proc(h: ^typed.Reader, state: ^Read_State) {
	h.format = state
	h.ends = proc "contextless" (h: ^typed.Reader, t: core.Token) -> (lo, hi: u64) {
		_, hi = item_ends(t)
		return (^Read_State)(h.format).item_lo, hi
	}
	h.find_tag = proc(h: ^typed.Reader, at: u64, name: string) -> typed.Tag_Scan {
		s := typed.Tag_Scan{view = {src = h.src, as = h.plan.as}, name = name}
		_, s.fault = walk_rules(h.src, at, (^Read_State)(h.format).rules, &s, nil, typed.on_tag_token)
		return s
	}
}

// The first byte and the byte past the item token `t` is of, without its tags: a string's head, and the first byte and
// the break of one in chunks, lie outside its token.
@(private)
item_ends :: #force_inline proc "contextless" (t: core.Token) -> (lo, hi: u64) {
	lo, hi = t.lo, t.lo + u64(t.n)
	if (t.kind == .String || t.kind == .Bytes) && t.spelling & INT_KEY == 0 {
		lo -= u64(t.spelling >> HEAD_SHIFT & 15)
		if t.spelling & STR_INDEF != 0 {
			hi += 1
		}
	}
	return
}

@(private)
on_item :: proc "contextless" (h: ^typed.Reader, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return item_hook(h, regs, t)
}

@(private)
on_item_check :: proc "contextless" (h: ^typed.Check, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return item_hook(h, regs, t)
}

// The reader's hook with what CBOR adds: where an item starts, a struct's members by position, and integers and floats
// read from their heads, which the shared hook reads through `number`.
@(private)
item_hook :: #force_inline proc "contextless" (h: ^$H, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	on :: typed.on_token_check_spelled when H == typed.Check else typed.on_token_spelled
	s := (^Read_State)(h.format)
	if t.role != .Value || t.kind == .End {
		if t.role == .Tag {
			if !s.tagged {
				s.tagged, s.item_lo = true, t.lo
			}
		} else if t.role == .Key {
			s.item_lo, _ = item_ends(t)
		}
		return on(h, regs, t)
	}
	if !s.tagged {
		s.item_lo, _ = item_ends(t)
	}
	s.tagged = false
	regs := regs
	if s.positional[h.sp] {
		next := regs.b + size_of(typed.Field)
		if typed.field_at(next).kind == .Never {
			return regs, .Skip
		}
		regs.b = next
	}
	#partial switch t.kind {
	case .Number:
		when H == typed.Reader {
			if regs.c < regs.a {
				if read, done := head_number(h, regs, t); done {
					return read, .Next
				}
			}
		}
	case .Array, .Object:
		sp := h.sp
		open := t
		kind := typed.field_at(regs.b).kind
		by_position := t.kind == .Array && (kind == .Struct || kind == .Required)
		if by_position {
			open.kind = .Object
		}
		read, action := on(h, regs, open)
		if h.sp > sp {
			s.positional[h.sp] = by_position
		}
		return read, action
	}
	return on(h, regs, t)
}

// Reads an integer or a float into a member of the kinds a struct holds most, from its head. It returns false for
// any other, which the shared hook reads.
@(private)
head_number :: #force_inline proc "contextless" (h: ^typed.Reader, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, bool) #no_bounds_check {
	regs := regs
	fld := typed.field_at(regs.b)
	dest := uintptr(regs.c) + uintptr(fld.offset)
	src := raw_data(h.src)[t.lo:]
	switch t.spelling {
	case CN_INT:
		arg := u64(src[0] & 31)
		switch t.n {
		case 2:
			arg = u64(src[1])
		case 3:
			arg = u64(intrinsics.unaligned_load((^u16be)(src[1:])))
		case 5:
			arg = u64(intrinsics.unaligned_load((^u32be)(src[1:])))
		case 9:
			arg = u64(intrinsics.unaligned_load((^u64be)(src[1:])))
		}
		neg := src[0] >= 0x20
		#partial switch fld.kind {
		case .I64:
			if arg > u64(max(i64)) {
				return regs, false
			}
			(^i64)(dest)^ = ~i64(arg) if neg else i64(arg)
		case .I32:
			if arg > u64(max(i32)) {
				return regs, false
			}
			(^i32)(dest)^ = ~i32(arg) if neg else i32(arg)
		case .U64:
			if neg {
				return regs, false
			}
			(^u64)(dest)^ = arg
		case .F64:
			if arg >= 1 << 53 {
				return regs, false
			}
			x := f64(arg)
			(^f64)(dest)^ = -1 - x if neg else x
		case:
			return regs, false
		}
	case CN_FLOAT | FRACTION:
		if fld.kind != .F64 {
			return regs, false
		}
		(^u64)(dest)^ = float(src[:t.n])
	case:
		return regs, false
	}
	regs.c += u64(fld.stride)
	return regs, true
}
