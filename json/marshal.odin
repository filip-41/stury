package json

// `marshal` writes an Odin value as canonical JSON by running its type plan. The plan fixes the structure, so
// writes go through the put layer with no per-value state check.
//
// Every `data` is the address of a value of the type its op was compiled for. The root has `v`'s type; a
// plan for another type is `.Plan_Mismatch`. A field is at its type-info offset, and the elements are `stride`
// apart, up to their count. The `#no_bounds_check` writers store only into room that `enc.put_room` reserved.
// For a scalar that is the key plus FIELD_VALUE_ROOM, which covers `spell.INT_ROOM`, `spell.F64_ROOM` and the
// 8-byte `true`/`false` word; `close_object` takes 3 bytes. `ptrs` has MAX_DEPTH slots, and a target is pushed
// only below that depth.

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:reflect"
import "core:unicode/utf8"
import enc "encode"
import core_pkg "../core"
import "scan/walk"
import "../core/spell"

// Write a value as JSON into a new buffer from `allocator`: a `^Document` as `marshal_document` writes it
// (a `Document` met as an `any` too), any other value by its type plan (`marshal_value`). A refusal returns
// a nil slice.
marshal :: proc {
	marshal_document,
	marshal_value,
}

// `marshal` written to `w` as the text is made. On a refusal `w` may already hold a prefix of the text.
marshal_to_writer :: proc {
	marshal_document_to_writer,
	marshal_value_to_writer,
}

// Write `v` as JSON into a new buffer from `allocator`. With `plan` nil the plan is this thread's cached one for
// `v`'s type.
@(private, require_results)
marshal_value :: proc(v: any, opts := Encode_Opts{}, plan: ^Type_Plan = nil, allocator := context.allocator) -> (out: []byte, err: Encode_Error) {
	buf, aerr := make([dynamic]u8, 0, MARSHAL_BUF_START, allocator)
	if aerr != nil {
		return nil, .Out_Of_Memory
	}
	if err = marshal_append(&buf, v, opts, plan); err != .None {
		delete(buf)
		return nil, err
	}
	// Only a grown buffer is shrunk: a copy of the text, worth it only for the half a doubling may leave
	// unused.
	if cap(buf) > MARSHAL_BUF_START {
		_, _ = shrink(&buf)
	}
	return buf[:], .None
}

// The capacity `marshal` starts its buffer at.
@(private)
MARSHAL_BUF_START :: 256

// Write `v` as JSON to `w` as it is made, through a buffer of about `SINK_FLUSH_AT` bytes from
// `allocator`, freed before return.
@(private, require_results)
marshal_value_to_writer :: proc(w: io.Writer, v: any, opts := Encode_Opts{}, plan: ^Type_Plan = nil, allocator := context.allocator) -> Encode_Error {
	buf, aerr := make([dynamic]u8, 0, 2 * spell.SINK_FLUSH_AT, allocator)
	if aerr != nil {
		return .Out_Of_Memory
	}
	defer delete(buf)
	sink := enc.Sink{w, enc.reescape_of(opts)}
	marshal_append(&buf, v, opts, plan, &sink) or_return
	return enc.sink_drain(&sink, &buf)
}

// Where a `Marshal_Hook` writes: the output so far and the state of the call around the hooked value. Its
// fields are internal. A hook writes through `marshal_into`.
Marshal_Out :: struct {
	plan:   ^Type_Plan,
	out:    ^[dynamic]u8,
	// Streaming: `out` goes to the writer between elements (`element`).
	sink:   ^enc.Sink,
	indent: enc.Indent,
	pretty: bool,
	// An object is opened before its members are written rather than patched open after them, so no write
	// goes back before a point `out` may be handed over at: pretty, or streaming.
	eager:  bool,
	enum_ints: bool,
	// The grammar a `Raw` is validated by: `.Jsonc` only for an edit of a JSONC text.
	dialect:   Dialect,
	// A hook is running and has not yet written its one value.
	hook_open: bool,
	// The op `marshal_into` last looked up, by type: a hook passes one type every time, so most calls skip the
	// plan's map.
	into_id: typeid,
	into_op: u32,
	depth:  u32, // containers and pointers open: the recursion ceiling
	nest:   u32, // JSON containers open: the indent and the depth a `Raw` nests from
	n_ptrs: u32,
	ptrs:   [^]Open_Target, // MAX_DEPTH slots, of which ptrs[:n_ptrs] are the targets on the open path
}

// From inside a `Marshal_Hook`: write `value` as the hooked value, as `marshal` writes a value of its type by
// the call's plan, hooks included. A hook writes exactly one value, and a second call is `.Bad_State`.
@(require_results)
marshal_into :: proc(out: ^Marshal_Out, value: any) -> Encode_Error {
	if !out.hook_open {
		return .Bad_State
	}
	out.hook_open = false
	if value.id == nil || value.data == nil {
		return enc.put_bytes(out.out, "null")
	}
	if value.id != out.into_id {
		out.into_op = plan_op(out.plan, type_info_of(value.id)) or_return
		out.into_id = value.id
	}
	return write_target(out, out.into_op, value.data)
}

// A pointer's or an `any`'s target on the open path. A cycle meets the same address as the same type
// again. A struct and its first field share an address but not an op.
@(private)
Open_Target :: struct {
	at: rawptr,
	op: u32,
}

// Append `v` to `dst`, or with `sink` stream it through `dst`. A `Raw` in it is validated under `dialect`, the
// grammar of the text it is written into. On a refusal `dst` is truncated back to its length on entry.
@(private)
marshal_append :: proc(dst: ^[dynamic]u8, v: any, opts: Encode_Opts, plan: ^Type_Plan, sink: ^enc.Sink = nil, dialect := Dialect.Json) -> Encode_Error {
	if v.data != nil {
		switch v.id {
		case Document:
			return marshal_document_append(dst, (^Document)(v.data), opts)
		case ^Document:
			if doc := (^^Document)(v.data)^; doc != nil {
				return marshal_document_append(dst, doc, opts)
			}
		}
	}
	mark := len(dst^)
	err := marshal_root(dst, v, opts, plan, sink, dialect)
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
marshal_root :: proc(dst: ^[dynamic]u8, v: any, opts: Encode_Opts, plan: ^Type_Plan, sink: ^enc.Sink, dialect: Dialect) -> Encode_Error {
	if v.id == nil || v.data == nil {
		return enc.put_bytes(dst, "null")
	}
	tmp: Type_Plan = ---
	p, ok := plan_for(plan, v.id, &tmp)
	if !ok {
		return .Plan_Mismatch
	}
	err := marshal_planned(dst, v, opts, p, sink, dialect)
	plan_done(p, plan, &tmp, err == .Out_Of_Memory)
	return err
}

@(private)
marshal_planned :: proc(dst: ^[dynamic]u8, v: any, opts: Encode_Opts, p: ^Type_Plan, sink: ^enc.Sink, dialect: Dialect) -> Encode_Error {
	// The root is the first op a plan compiles.
	root := u32(0)
	if len(p.ops) == 0 {
		if p.opts_lost {
			return .Out_Of_Memory
		}
		plan_op(p, type_info_of(v.id)) or_return
	}
	ptrs: [MAX_DEPTH]Open_Target = ---
	st := Marshal_Out{
		plan      = p,
		out       = dst,
		sink      = sink,
		indent    = enc.indent_of(opts),
		pretty    = opts.pretty,
		eager     = opts.pretty || sink != nil,
		enum_ints = p.opts.enums == .Int,
		dialect   = dialect,
		ptrs      = raw_data(ptrs[:]),
	}
	return write_value(&st, root, v.data)
}

@(private)
write_value :: proc(st: ^Marshal_Out, idx: u32, data: rawptr) -> Encode_Error {
	// A copy: compiling a union arm or an `any` below may move `ops`.
	op := st.plan.ops[idx]
	switch op.kind {
	case .Unsupported:
		return .Unsupported
	case .Null:
		return enc.put_bytes(st.out, "null")
	case .Bool, .Int, .Uint, .Float:
		return put_scalar(st.out, op.kind, data, op.size)
	case .Wide_Int, .Wide_Uint:
		return put_wide(st.out, data, op.kind == .Wide_Int)
	case .String:
		return enc.put_string(st.out, (^string)(data)^)
	case .Cstring, .Rune, .Union, .Any, .Enum_Int, .Enum_Uint:
		return write_rare_value(st, op, data)
	case .Raw:
		return put_raw(st, string((^Raw)(data)^))
	case .Number:
		return enc.put_f64(st.out, (^Number)(data).value)
	case .Digits:
		return put_digits(st, string((^Digits)(data)^))
	case .Decoded:
		return write_decoded(st, (^Decoded)(data)^)
	case .Slice, .Dynamic:
		raw := (^runtime.Raw_Slice)(data)^
		return write_elems(st, op, raw.data, raw.len)
	case .Array:
		return write_elems(st, op, data, int(op.count))
	case .Fixed_List:
		n := (^int)(uintptr(data) + uintptr(op.len_offset))^
		return write_elems(st, op, data, n)
	case .Map:
		return write_map(st, op, data)
	case .Struct:
		return write_struct(st, op, data)
	case .Pointer:
		return write_pointer(st, op, data)
	case .Bit_Set:
		return write_bit_set(st, op, data)
	case .Hook:
		return write_hooked(st, op, data)
	}
	return .None
}

// Writes the `write_value` cases that need locals of their own: a rune's bytes, a union's variant, an `any`'s
// plan and an enum's member. Each level of a nested write holds a `write_value` frame, and a value nested
// MAX_DEPTH deep must fit a Windows thread's 1 MB stack. These cases therefore stay out of that frame, as do
// the callees marked `#force_no_inline` (`write_map`, `write_bit_set`, `write_decoded`, `put_wide`).
@(private = "file")
write_rare_value :: #force_no_inline proc(st: ^Marshal_Out, op: Plan_Op, data: rawptr) -> Encode_Error {
	#partial switch op.kind {
	case .Cstring:
		cs := (^cstring)(data)^
		if cs == nil {
			return enc.put_bytes(st.out, "null")
		}
		return enc.put_string(st.out, string(cs))
	case .Rune:
		r := (^rune)(data)^
		if !utf8.valid_rune(r) {
			return .Bad_Utf8
		}
		bytes, n := utf8.encode_rune(r)
		return enc.put_string(st.out, string(bytes[:n]))
	case .Union:
		k := union_arm_of(op, data)
		if k < 0 {
			return enc.put_bytes(st.out, "null")
		}
		// A union's arm lives at offset 0.
		arm := st.plan.fields[op.elem + u32(k)]
		if op.tagged && st.plan.tag_hi > 0 && arm.key_hi > arm.key_lo {
			return write_struct_eager(st, st.plan.ops[arm.op], data, string(st.plan.keys[arm.key_lo:arm.key_hi]))
		}
		return write_value(st, arm.op, data)
	case .Any:
		a := (^any)(data)^
		if a.id == nil || a.data == nil {
			return enc.put_bytes(st.out, "null")
		}
		arm := plan_op(st.plan, type_info_of(a.id)) or_return
		return write_target(st, arm, a.data)
	case .Enum_Int, .Enum_Uint:
		if st.enum_ints {
			return put_enum_int(st.out, st.plan, op, data)
		}
		m := enum_member(st.plan, op, data) or_return
		return enc.put_bytes(st.out, string(st.plan.keys[m.lo:m.hi]))
	}
	return .None
}

// A hooked value: the caller's proc writes it through `marshal_into`, nested as deep as the containers open
// around it, and must write exactly one value.
@(private)
write_hooked :: proc(st: ^Marshal_Out, op: Plan_Op, data: rawptr) -> Encode_Error {
	write := st.plan.writes[op.elem]
	if write == nil {
		return .Unsupported
	}
	// Saved: the hook's value may hold a hooked value of its own.
	outer := st.hook_open
	st.hook_open = true
	err := write(st, data)
	if err == .None && st.hook_open {
		err = .Bad_State
	}
	st.hook_open = outer
	return err
}

// A bit_set as an array of its elements in ascending order: an enum's member names (or, under `enums = .Int`,
// their integers), a range's integers.
@(private)
write_bit_set :: #force_no_inline proc(st: ^Marshal_Out, op: Plan_Op, data: rawptr) -> Encode_Error {
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
		m := enum_member_of(st.plan, elem, v) or_return
		if st.enum_ints {
			enc.put_i64(st.out, v) or_return
		} else {
			enc.put_bytes(st.out, string(st.plan.keys[m.lo:m.hi])) or_return
		}
	}
	return close_container(st, ']', n)
}

// Returns the `op.size` bytes of the bit_set `op` at `data`.
@(private)
bit_set_bits :: proc(op: Plan_Op, data: rawptr) -> (bits: u128) {
	runtime.mem_copy_non_overlapping(&bits, data, int(op.size))
	return
}

// The arm the union `op` at `data` holds, as an index into its arm run, or -1 for nil.
@(private)
union_arm_of :: proc(op: Plan_Op, data: rawptr) -> int {
	u := runtime.type_info_base(op.info).variant.(runtime.Type_Info_Union)
	if len(u.variants) == 0 {
		return -1
	}
	// A pure maybe holds its pointer arm with no tag, and nil is the pointer.
	if reflect.type_info_union_is_pure_maybe(u) {
		return 0 if (^rawptr)(data)^ != nil else -1
	}
	tag := int(core_pkg.shape_uint_load(rawptr(uintptr(data) + u.tag_offset), u8(u.tag_type.size)))
	return tag if u.no_nil else tag - 1
}

// An enum's backing integer. A value no member has is refused, as unmarshal refuses it.
@(private)
put_enum_int :: proc(dst: ^[dynamic]u8, p: ^Type_Plan, op: Plan_Op, data: rawptr) -> Encode_Error {
	enum_member(p, op, data) or_return
	if op.kind == .Enum_Int {
		return enc.put_i64(dst, core_pkg.shape_int_load(data, op.size))
	}
	return enc.put_u64(dst, core_pkg.shape_uint_load(data, op.size))
}

// The member an enum value is: the first declared with its value.
@(private)
enum_member :: #force_inline proc(p: ^Type_Plan, op: Plan_Op, data: rawptr) -> (Plan_Member, Encode_Error) {
	return enum_member_of(p, op, core_pkg.plan_enum_value(op, data))
}

// The first member declared with value `v`.
@(private)
enum_member_of :: #force_inline proc(p: ^Type_Plan, op: Plan_Op, v: i64) -> (Plan_Member, Encode_Error) {
	m, ok := core_pkg.plan_enum_member(p, op, v)
	return m, .None if ok else .Not_A_Member
}

@(private)
write_decoded :: #force_no_inline proc(st: ^Marshal_Out, d: Decoded) -> Encode_Error {
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
		return enc.put_f64(st.out, x.value)
	case Digits:
		return put_digits(st, string(x))
	case string:
		return enc.put_string(st.out, x)
	}
	return enc.put_bytes(st.out, "null")
}

// A `Digits`: one number token, checked as a `Raw` is; an empty one is `null`.
@(private)
put_digits :: proc(st: ^Marshal_Out, s: string) -> Encode_Error {
	if len(s) != 0 && s[0] != '-' && (s[0] < '0' || s[0] > '9') {
		return .Bad_Raw
	}
	return put_raw(st, s)
}

@(private)
open_container :: proc(st: ^Marshal_Out, open: u8) -> Encode_Error {
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
element :: proc(st: ^Marshal_Out, k: int) -> Encode_Error {
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
close_container :: proc(st: ^Marshal_Out, close: u8, count: int) -> Encode_Error {
	st.depth -= 1
	st.nest -= 1
	if st.pretty && count > 0 {
		enc.put_newline(st.out, st.nest, &st.indent) or_return
	}
	return enc.put_byte(st.out, close)
}

@(private)
write_pointer :: proc(st: ^Marshal_Out, op: Plan_Op, data: rawptr) -> Encode_Error {
	target := (^rawptr)(data)^
	if target == nil {
		return enc.put_bytes(st.out, "null")
	}
	return write_target(st, op.elem, target)
}

// The value a pointer or an `any` refers to, counted toward the depth and checked against the open path.
@(private)
write_target :: proc(st: ^Marshal_Out, idx: u32, target: rawptr) -> Encode_Error {
	for k in 0 ..< st.n_ptrs {
		if st.ptrs[k] == {target, idx} {
			return .Cycle
		}
	}
	if st.depth == MAX_DEPTH {
		return .Too_Deep
	}
	st.ptrs[st.n_ptrs] = {target, idx}
	st.n_ptrs += 1
	st.depth += 1
	err := write_value(st, idx, target)
	st.n_ptrs -= 1
	st.depth -= 1
	return err
}

// Writes the 128-bit integer at `data`.
@(private)
put_wide :: #force_no_inline proc(dst: ^[dynamic]u8, data: rawptr, signed: bool) -> Encode_Error {
	buf: [48]u8
	return enc.put_bytes(dst, spell.spell_u128(buf[:], (^u128)(data)^, signed))
}

// An empty `Raw` is `null`. Otherwise a `Raw` is exactly one value of `st.dialect`, strict JSON unless an edit
// writes it into JSONC: it begins with a value's first byte (so no whitespace, BOM or comment) and ends on the
// value's last byte (no whitespace, and under JSONC no comment). Its containers nest inside the open ones, all
// within MAX_DEPTH.
@(private)
put_raw :: proc(st: ^Marshal_Out, s: string) -> Encode_Error {
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
	fault, bad := validate(transmute([]byte)s, .Json, .Strict, limits).?
	if bad && st.dialect == .Jsonc {
		fault, bad = jsonc_raw_fault(s, limits).?
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

// `s` validated as JSONC, a comment ending it refused (`.Trailing`): what follows the value would be inside it.
// Its comments are listed in `context.allocator`.
@(private = "file")
jsonc_raw_fault :: proc(s: string, limits: Limits) -> Maybe(Error) {
	comments := make([dynamic]Fact)
	defer delete(comments)
	if fault, bad := validate(transmute([]byte)s, .Jsonc, limits = limits, facts = &comments).?; bad {
		return fault
	}
	if n := len(comments); n > 0 && comments[n - 1].hi == u64(len(s)) {
		return Error{kind = .Trailing, offset = comments[n - 1].lo}
	}
	return nil
}
