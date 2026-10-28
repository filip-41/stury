package json

// `marshal` writes an Odin value as canonical JSON by running its type plan. The plan fixes the structure, so
// writes go through the put layer with no per-value state check.
//
// Every `data` is the address of a value of the type its op was compiled for. The root has `v`'s type; a
// plan for another type is `.Plan_Mismatch`. A field is at its type-info offset, and the elements are `stride`
// apart, up to their count. The `#no_bounds_check` writers store only into room that `enc.put_room` reserved.
// For a scalar that is the key plus `spell.SCALAR_ROOM`; `close_object` takes 3 bytes. `ptrs` has MAX_DEPTH slots, and a target is pushed
// only below that depth.

import "base:intrinsics"
import "base:runtime"
import "core:io"
import enc "encode"
import core_pkg "../core"
import scan_pkg "scan"
import "scan/walk"
import "../core/spell"

// Write a value as JSON into a new buffer from `allocator`: a `^Document` as `marshal_document` writes it
// (a `Document` met as an `any` too), any other value by its type plan (`marshal_value`). A refusal returns
// a nil slice.
marshal :: proc {
	marshal_document,
	marshal_value,
}

// `marshal` appended to `out`, after the bytes already in it. On a refusal `out` is as it was on entry; its
// capacity may have grown.
marshal_append :: proc {
	marshal_document_append,
	marshal_value_append,
}

// `marshal` written to `w` as the text is made. On a refusal `w` may already hold a prefix of the text.
marshal_to_writer :: proc {
	marshal_document_to_writer,
	marshal_value_to_writer,
}

// Write `v` as JSON into a new buffer from `allocator`. With `plan` nil the plan is this thread's cached one for
// `v`'s type.
@(private, require_results)
marshal_value :: proc(v: any, opts := Marshal_Opts{}, plan: ^Type_Plan = nil, allocator := context.allocator) -> (out: []byte, err: Maybe(Marshal_Error)) {
	buf, aerr := make([dynamic]u8, 0, MARSHAL_BUF_START, allocator)
	if aerr != nil {
		return nil, Marshal_Error{kind = .Out_Of_Memory}
	}
	fault: Marshal_Error
	if kind := append_value(&buf, v, opts, plan, fault = &fault); kind != .None {
		delete(buf)
		return nil, core_pkg.marshal_error_of(kind, fault)
	}
	// Only a grown buffer is shrunk: a copy of the text, worth it only for the half a doubling may leave
	// unused.
	if cap(buf) > MARSHAL_BUF_START {
		_, _ = shrink(&buf)
	}
	return buf[:], nil
}

// `marshal_value` appended to `out`.
@(private, require_results)
marshal_value_append :: proc(out: ^[dynamic]u8, v: any, opts := Marshal_Opts{}, plan: ^Type_Plan = nil) -> Maybe(Marshal_Error) {
	fault: Marshal_Error
	return core_pkg.marshal_error_of(append_value(out, v, opts, plan, fault = &fault), fault)
}

// The capacity `marshal` starts its buffer at.
@(private)
MARSHAL_BUF_START :: 256

// Write `v` as JSON to `w` as it is made, through a buffer of about `SINK_FLUSH_AT` bytes from
// `allocator`, freed before return.
@(private, require_results)
marshal_value_to_writer :: proc(w: io.Writer, v: any, opts := Marshal_Opts{}, plan: ^Type_Plan = nil, allocator := context.allocator) -> Maybe(Marshal_Error) {
	buf, aerr := make([dynamic]u8, 0, 2 * spell.SINK_FLUSH_AT, allocator)
	if aerr != nil {
		return Marshal_Error{kind = .Out_Of_Memory}
	}
	defer delete(buf)
	sink := enc.Sink{w, enc.reescape_of(opts)}
	fault: Marshal_Error
	if kind := append_value(&buf, v, opts, plan, &sink, fault = &fault); kind != .None {
		return core_pkg.marshal_error_of(kind, fault)
	}
	return core_pkg.marshal_error_of(enc.sink_drain(&sink, &buf))
}

// Where a `Marshal_Hook` writes: a handle valid for the hook's call. A hook writes through `marshal_into`.
Marshal_Out :: core_pkg.Marshal_Out

// From inside a `Marshal_Hook`: write `value` as the hooked value, as `marshal` writes a value of its type by
// the call's plan, hooks included. A hook writes exactly one value, and a second call is `.Bad_State`.
marshal_into :: core_pkg.marshal_into

// The output so far and the state of the call: what a hook's `Marshal_Out` writes through.
@(private)
Marshal_State :: struct {
	using walk: core_pkg.Plan_Writer,
	out:    ^[dynamic]u8,
	// Streaming: `out` goes to the writer between elements (`element`).
	sink:   ^enc.Sink,
	indent: enc.Indent,
	pretty: bool,
	// An object is opened before its members are written rather than patched open after them, so no write
	// goes back before a point `out` may be handed over at: pretty, or streaming. Under `sort_keys` too, whose
	// structs are written in their own order.
	eager:  bool,
	// A flat struct is opened eagerly too: pretty, or `sort_keys`.
	open_flat: bool,
	sort_keys: bool,
	enum_ints: bool,
	// The grammar a `Raw` is validated by: a dialect that reads comments only for an edit of a text in it.
	dialect:   Dialect,
	nest:   u32, // JSON containers open: the indent and the depth a `Raw` nests from
}

// `marshal_into` of a hook running under the call `w`, a `^Marshal_State`.
@(private = "file")
hook_write :: proc(w: ^core_pkg.Plan_Writer, value: any) -> Marshal_Error_Kind {
	st := (^Marshal_State)(w)
	idx, null := core_pkg.plan_hook_value(st, value) or_return
	if null {
		return put_null(st)
	}
	return core_pkg.plan_write_target(st, idx, value.data, write_value)
}

@(private)
put_null :: proc(st: ^Marshal_State) -> Marshal_Error_Kind {
	return enc.put_bytes(st.out, "null")
}

// Append `v` to `dst`, or with `sink` stream it through `dst`. A `Raw` in it is validated under `dialect`, the
// grammar of the text it is written into. On a refusal `dst` is truncated back to its length on entry, and `fault`,
// when set, holds the path to the value refused.
@(private)
append_value :: proc(dst: ^[dynamic]u8, v: any, opts: Marshal_Opts, plan: ^Type_Plan, sink: ^enc.Sink = nil, dialect := Dialect.Json, fault: ^Marshal_Error = nil) -> Marshal_Error_Kind {
	if v.data != nil {
		switch v.id {
		case Document:
			return append_document(dst, (^Document)(v.data), {opts = opts})
		case ^Document:
			if doc := (^^Document)(v.data)^; doc != nil {
				return append_document(dst, doc, {opts = opts})
			}
		}
	}
	mark := len(dst^)
	err := marshal_root(dst, v, opts, plan, sink, dialect, fault)
	if err == .None && opts.trailing_newline {
		err = enc.put_byte(dst, '\n')
	}
	if flags := enc.reescape_of(opts); err == .None && flags != {} && sink == nil {
		err = enc.reescape_tail(dst, mark, flags)
	}
	if err != .None {
		walk.edge_publish(dst, min(mark, len(dst^)))
	}
	return err
}

@(private)
marshal_root :: proc(dst: ^[dynamic]u8, v: any, opts: Marshal_Opts, plan: ^Type_Plan, sink: ^enc.Sink, dialect: Dialect, fault: ^Marshal_Error) -> Marshal_Error_Kind {
	if v.id == nil || v.data == nil {
		return enc.put_bytes(dst, "null")
	}
	tmp: Format_Plan = ---
	p, ok := plan_for(plan, v.id, &tmp)
	if !ok {
		return .Plan_Mismatch
	}
	err := marshal_planned(dst, v, opts, p, sink, dialect, fault)
	plan_done(p, plan, &tmp, err == .Out_Of_Memory)
	return err
}

@(private)
marshal_planned :: proc(dst: ^[dynamic]u8, v: any, opts: Marshal_Opts, p: ^Format_Plan, sink: ^enc.Sink, dialect: Dialect, fault: ^Marshal_Error) -> Marshal_Error_Kind {
	// The root is the first op a plan compiles.
	root := u32(0)
	if len(p.ops) == 0 {
		if p.opts_lost {
			return .Out_Of_Memory
		}
		core_pkg.plan_op_m(p, type_info_of(v.id)) or_return
	}
	ptrs: [MAX_DEPTH]core_pkg.Plan_Target = ---
	st := Marshal_State{
		walk      = {plan = p, ptrs = raw_data(ptrs[:]), fault = fault, hook_write = hook_write},
		out       = dst,
		sink      = sink,
		indent    = enc.indent_of(opts),
		pretty    = opts.pretty,
		eager     = opts.pretty || sink != nil || opts.sort_keys,
		open_flat = opts.pretty || opts.sort_keys,
		sort_keys = opts.sort_keys,
		enum_ints = p.opts.enums == .Int,
		dialect   = dialect,
	}
	return write_value(&st, root, v.data)
}

@(private)
write_value :: proc(st: ^Marshal_State, idx: u32, data: rawptr) -> Marshal_Error_Kind {
	// A copy: compiling a union arm or an `any` below may move `ops`.
	op := st.plan.ops[idx]
	return core_pkg.plan_write_value(st, op, data, write_value, put_null, put_scalar_of, put_wide_of, put_text, put_enum, write_arm, write_hooked, put_own, write_elems, write_struct_of, write_map, write_bit_set)
}

@(private = "file")
put_scalar_of :: #force_inline proc(st: ^Marshal_State, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {
	return put_scalar(st.out, op.kind, data, op.size)
}

@(private = "file")
put_wide_of :: #force_inline proc(st: ^Marshal_State, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {
	return put_wide(st.out, data, op.kind == .Wide_Int)
}

@(private = "file")
put_text :: #force_inline proc(st: ^Marshal_State, s: string) -> Marshal_Error_Kind {
	return enc.put_string(st.out, s)
}

@(private = "file")
put_enum :: proc(st: ^Marshal_State, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {
	if st.enum_ints {
		return put_enum_int(st.out, st.plan, op, data)
	}
	m, _ := core_pkg.plan_enum_written(st.plan, op, data) or_return
	return enc.put_bytes(st.out, string(st.plan.keys[m.lo:m.hi]))
}

// A union's arm: a struct arm of a tagged union with its tag as its first member.
@(private = "file")
write_arm :: proc(st: ^Marshal_State, arm: u32, data: rawptr, tag: string) -> Marshal_Error_Kind {
	if len(tag) > 0 {
		return write_struct_eager(st, st.plan.ops[arm], data, tag)
	}
	return write_value(st, arm, data)
}

// JSON's own types: `Raw`, `Number`, `Digits`, `Decoded` and `Null`.
@(private = "file")
put_own :: #force_inline proc(st: ^Marshal_State, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {
	#partial switch op.kind {
	case .Raw:
		return put_raw(st, string((^Raw)(data)^))
	case .Number:
		return put_number(st, (^Number)(data)^)
	case .Digits:
		return put_digits(st, string((^Digits)(data)^))
	case .Decoded:
		return write_decoded(st, (^Decoded)(data)^)
	}
	return put_null(st)
}

@(private = "file")
write_struct_of :: #force_inline proc(st: ^Marshal_State, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {
	return write_struct(st, op, data)
}

// A hooked value: the caller's proc writes it through `marshal_into`.
@(private)
write_hooked :: proc(st: ^Marshal_State, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {
	return core_pkg.plan_write_hooked(st, op, data)
}

// A bit_set as an array of its elements in ascending order: an enum's member names (or, under `enums = .Int`,
// their integers), a range's integers.
@(private)
write_bit_set :: #force_no_inline proc(st: ^Marshal_State, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {
	lower := runtime.type_info_base(op.info).variant.(runtime.Type_Info_Bit_Set).lower
	elem := st.plan.ops[op.elem]
	bits := bit_set_bits(op, data)
	open_container(st, '[') or_return
	n := 0
	for ; bits != 0; bits &= bits - 1 {
		element(st, n) or_return
		n += 1
		v := lower + i64(intrinsics.count_trailing_zeros(bits))
		if elem.kind != .Enum_Int && elem.kind != .Enum_Uint {
			enc.put_i64(st.out, v) or_return
			continue
		}
		// A bit no member stands for is refused under either notation, as unmarshal refuses it.
		m, member := core_pkg.plan_enum_member(st.plan, elem, v)
		if !member {
			return .Not_A_Member
		}
		if st.enum_ints {
			enc.put_i64(st.out, v) or_return
		} else {
			enc.put_bytes(st.out, string(st.plan.keys[m.lo:m.hi])) or_return
		}
	}
	return close_container(st, ']', n)
}

@(private)
bit_set_bits :: proc(op: Plan_Op, data: rawptr) -> (bits: u128) {
	runtime.mem_copy_non_overlapping(&bits, data, int(op.size))
	return
}

// An enum's backing integer. A value no member has is refused, as unmarshal refuses it.
@(private)
put_enum_int :: proc(dst: ^[dynamic]u8, p: ^Format_Plan, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {
	_, v := core_pkg.plan_enum_written(p, op, data) or_return
	return enc.put_i64(dst, v) if op.kind == .Enum_Int else enc.put_u64(dst, u64(v))
}

@(private)
write_decoded :: #force_no_inline proc(st: ^Marshal_State, d: Decoded) -> Marshal_Error_Kind {
	switch x in d {
	case Null:
		return enc.put_bytes(st.out, "null")
	case bool:
		return enc.put_bytes(st.out, "true" if x else "false")
	case i64:
		return enc.put_i64(st.out, x)
	case u64:
		return enc.put_u64(st.out, x)
	case Number:
		return put_number(st, x)
	case Digits:
		return put_digits(st, string(x))
	case string:
		return enc.put_string(st.out, x)
	}
	return enc.put_bytes(st.out, "null")
}

// A `Number`: its binary64 value (`1e-400`, `.Underflowed`, is +-0, its correctly rounded value), or
// `.Non_Finite` when it holds none (`.None`, such as `1e400`). `Digits` writes the authored text.
@(private)
put_number :: proc(st: ^Marshal_State, n: Number) -> Marshal_Error_Kind {
	if n.exactness == .None {
		return .Non_Finite
	}
	return enc.put_f64(st.out, n.value)
}

// A `Digits`: one number token, checked as a `Raw` is; an empty one is `null`.
@(private)
put_digits :: proc(st: ^Marshal_State, s: string) -> Marshal_Error_Kind {
	if len(s) != 0 && s[0] != '-' && (s[0] < '0' || s[0] > '9') {
		return .Bad_Raw
	}
	return put_raw(st, s)
}

@(private)
open_container :: proc(st: ^Marshal_State, open: u8) -> Marshal_Error_Kind {
	if st.depth == MAX_DEPTH {
		return .Too_Deep
	}
	st.depth += 1
	st.nest += 1
	return enc.put_byte(st.out, open)
}

// Before element `k` of the open container: a comma unless it is the first, then the pretty line break.
// Streaming, this is where `out` goes to the writer: every open object already has its `{`.
@(private)
element :: proc(st: ^Marshal_State, k: int) -> Marshal_Error_Kind {
	if st.sink != nil && len(st.out^) >= spell.SINK_FLUSH_AT {
		enc.sink_drain(st.sink, st.out) or_return
	}
	if k > 0 {
		enc.put_byte(st.out, ',') or_return
	}
	if st.pretty {
		return enc.put_newline(st.out, st.nest, &st.indent)
	}
	return .None
}

@(private)
close_container :: proc(st: ^Marshal_State, close: u8, count: int) -> Marshal_Error_Kind {
	st.depth -= 1
	st.nest -= 1
	if st.pretty && count > 0 {
		enc.put_newline(st.out, st.nest, &st.indent) or_return
	}
	return enc.put_byte(st.out, close)
}

@(private)
put_wide :: #force_no_inline proc(dst: ^[dynamic]u8, data: rawptr, signed: bool) -> Marshal_Error_Kind {
	buf: [48]u8
	return enc.put_bytes(dst, spell.spell_u128(buf[:], (^u128)(data)^, signed))
}

// An empty `Raw` is `null`. Otherwise a `Raw` is exactly one value of `st.dialect`, strict JSON unless an edit
// writes it into JSONC: it begins with a value's first byte (so no whitespace, BOM or comment) and ends on the
// value's last byte (no whitespace, and under JSONC no comment). Its containers nest inside the open ones, all
// within MAX_DEPTH.
@(private)
put_raw :: proc(st: ^Marshal_State, s: string) -> Marshal_Error_Kind {
	if len(s) == 0 {
		return enc.put_bytes(st.out, "null")
	}
	switch s[0] {
	case '{', '[':
		if st.nest == MAX_DEPTH {
			return .Too_Deep
		}
	case '"', '-', '0' ..= '9', 't', 'f', 'n':
	case:
		return .Bad_Raw
	}
	switch s[len(s) - 1] {
	case ' ', '\t', '\n', '\r':
		return .Bad_Raw
	}
	limits := Limits{max_depth = u64(MAX_DEPTH - st.nest)}
	fault, bad := validate(transmute([]byte)s, {limits = limits}).?
	if bad {
		if scan_pkg.has_comments(st.dialect) {
			fault, bad = commented_raw_fault(s, limits, st.dialect).?
		}
	}
	if bad {
		#partial switch fault.kind {
		case .Too_Deep:
			return .Too_Deep
		case .Out_Of_Memory:
			return .Out_Of_Memory
		}
		return .Bad_Raw
	}
	return enc.put_bytes(st.out, s)
}

// `s` validated as `dialect`, which reads comments, a comment ending it refused (`.Trailing`): what follows the value would be inside it.
// Its comments are listed in `context.allocator`.
@(private = "file")
commented_raw_fault :: proc(s: string, limits: Limits, dialect: Dialect) -> Maybe(Error) {
	comments := make([dynamic]Fact)
	defer delete(comments)
	if fault, bad := validate_facts(transmute([]byte)s, {dialect = dialect, limits = limits}, &comments).?; bad {
		return fault
	}
	if n := len(comments); n > 0 && comments[n - 1].hi == u64(len(s)) {
		return Error{kind = .Trailing, offset = comments[n - 1].lo}
	}
	return nil
}
