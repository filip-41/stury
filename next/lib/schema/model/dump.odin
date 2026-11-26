// Model dumping: iteratively marshals an Odin value respecting model tags, roles, defaults,
// carriers, tagged union discriminators, and omit options into a `tape.Document`, `write.Token_Tape`,
// or any format's `write` / `write_to`. Backed by `mem.Dynamic_Arena` (WASM-clean, O(1) native stack).
package model

import "base:intrinsics"
import "base:runtime"
import "core:encoding/uuid"
import "core:io"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:time"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/schema/rules"

Dump_Opts :: struct {
	exclude_unset:    bool,
	exclude_none:     bool,
	exclude_defaults: bool,
	check:            bool,
}

Format_Write_Proc :: proc(doc: ^tape.Document, opts: write.Options, allocator: runtime.Allocator) -> ([]u8, tape.Facts, write.Error)
Format_Write_To_Proc :: proc(w: io.Writer, doc: ^tape.Document, opts: write.Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error)

// Emits `v` according to `m` and `opts` into a self-contained `tape.Document` owned by `allocator` (zero double-copy!).
@(require_results)
dump_document :: proc(m: ^Model($T), v: ^T, opts := Dump_Opts{}, sink: ^Sink = nil, allocator := context.allocator) -> (doc: tape.Document, err: Error) {
	if m == nil || v == nil || len(m.plan.nodes) == 0 {
		return {}, Model_Error{kind = .Bad_Option, want = {text = "value"}}
	}
	sc: Scratch_Scope
	sp := (^Scratch_Scope)(rawptr(&sc))
	scratch_begin(sp, {}, allocator)
	defer scratch_end(sp)

	tt: write.Token_Tape
	if aerr := write.token_tape_start(&tt, false, 0, allocator); aerr != nil {
		return {}, aerr
	}
	defer write.token_tape_drop(&tt)

	dump_tokens_inner(&m.plan, m.judging, rawptr(v), &tt, opts, sink, allocator, sp.scratch) or_return
	view, terr := write.token_tape_document(&tt)
	if terr != nil {
		return {}, terr
	}
	view.flags += {.Owns_Src}
	tt.nodes, tt.texts, tt.counts = {}, {}, {}
	return view, nil
}

@(require_results)
dump_tokens :: proc(m: ^Model($T), v: ^T, tt: ^write.Token_Tape, opts := Dump_Opts{}, sink: ^Sink = nil, allocator := context.allocator) -> Error {
	if m == nil || v == nil || tt == nil || len(m.plan.nodes) == 0 {
		return Model_Error{kind = .Bad_Option, want = {text = "value"}}
	}
	sc: Scratch_Scope
	sp := (^Scratch_Scope)(rawptr(&sc))
	scratch_begin(sp, {}, allocator)
	defer scratch_end(sp)
	return dump_tokens_inner(&m.plan, m.judging, rawptr(v), tt, opts, sink, allocator, sp.scratch)
}

@(require_results)
dump :: proc(m: ^Model($T), v: ^T, format_write: Format_Write_Proc, opts := Dump_Opts{}, wopts := write.Options{}, sink: ^Sink = nil, allocator := context.allocator) -> (text: []u8, err: Error) {
	if format_write == nil {
		return nil, Model_Error{kind = .Bad_Option, want = {text = "format_write"}}
	}
	doc := dump_document(m, v, opts, sink, allocator) or_return
	defer tape.destroy(&doc)
	bytes, _, werr := format_write(&doc, wopts, allocator)
	if werr != nil {
		return nil, werr
	}
	return bytes, nil
}

@(require_results)
dump_stream :: proc(w: io.Writer, m: ^Model($T), v: ^T, format_write_to: Format_Write_To_Proc, opts := Dump_Opts{}, wopts := write.Options{}, sink: ^Sink = nil, allocator := context.allocator) -> Error {
	if format_write_to == nil {
		return Model_Error{kind = .Bad_Option, want = {text = "format_write_to"}}
	}
	doc := dump_document(m, v, opts, sink, allocator) or_return
	defer tape.destroy(&doc)
	_, werr := format_write_to(w, &doc, wopts, allocator)
	return werr if werr != nil else nil
}

@(private)
Dump_Omit :: struct {
	plan:       ^Type_Plan,
	opts:       Dump_Opts,
	defaults:   mem.Dynamic_Arena,
	made:       map[rawptr]rawptr,
	zero:       rawptr,
	zero_size:  int,
	zero_align: int,
}

@(private)
dump_field_omitted :: proc(ctx: rawptr, si: ^Struct_Info, fi: int, struct_ptr: rawptr) -> bool {
	o := (^Dump_Omit)(ctx)
	f := &si.fields[fi]
	field_ptr := rawptr(uintptr(struct_ptr) + f.offset)
	ftn := &o.plan.nodes[f.node]

	if f.omit_unset && holds_null_value(o.plan, ftn, field_ptr) { return true }
	if f.omit_empty && is_empty_value(o.plan, ftn, field_ptr) { return true }
	if !f.optional { return false }
	if o.opts.exclude_none && holds_null_value(o.plan, ftn, field_ptr) { return true }
	if o.opts.exclude_unset && si.has_fields_set && f.access != .Read_Only {
		if !fields_set_has((^Fields_Set)(uintptr(struct_ptr) + si.fields_set_offset)^, fi) {
			return true
		}
	}
	if !o.opts.exclude_defaults { return false }
	def_ptr := default_value_for(o, f, ftn)
	return def_ptr != nil && equal_values(field_ptr, def_ptr, ftn.ti, mem.dynamic_arena_allocator(&o.defaults))
}

@(private)
default_value_for :: proc(o: ^Dump_Omit, f: ^Field_Info, ftn: ^Type_Node) -> rawptr {
	memory := mem.dynamic_arena_allocator(&o.defaults)
	if !f.has_default {
		need_align := max(ftn.align, 16)
		if o.zero == nil || o.zero_size < ftn.size || o.zero_align < need_align {
			sz := max(ftn.size, 64)
			z, err := mem.alloc(sz, need_align, memory)
			if err != nil { return nil }
			o.zero, o.zero_size, o.zero_align = z, sz, need_align
		}
		return o.zero
	}
	if cached, found := o.made[rawptr(f)]; found { return cached }
	if o.made == nil { o.made = make(map[rawptr]rawptr, 16, memory) }
	held, err := mem.alloc(max(ftn.size, 1), ftn.align, memory)
	if err != nil || f.make_default(held, f.default_data, memory) != nil { return nil }
	o.made[rawptr(f)] = held
	return held
}

@(private)
holds_null_value :: proc(plan: ^Type_Plan, tn: ^Type_Node, ptr: rawptr) -> bool {
	#partial switch tn.kind {
	case .Maybe:       return !maybe_is_set(tn, ptr)
	case .Ptr:         return (^rawptr)(ptr)^ == nil
	case .Cstring:     return (^cstring)(ptr)^ == nil
	case .Number_Text: return (^Number_Text)(ptr)^.text == ""
	case .Union:
		u := &plan.unions[tn.union_idx]
		return !u.no_nil && read_union_tag(ptr, u.tag_offset, u.tag_size) == 0
	case .Value:
		_, is_null := (^rules.Value)(ptr)^.(rules.Null)
		return is_null || (^rules.Value)(ptr)^ == nil
	}
	return false
}

@(private)
is_empty_value :: proc(plan: ^Type_Plan, tn: ^Type_Node, ptr: rawptr) -> bool {
	if holds_null_value(plan, tn, ptr) { return true }
	#partial switch tn.kind {
	case .String, .Email:             return len((^string)(ptr)^) == 0
	case .Cstring:                    return len(string((^cstring)(ptr)^)) == 0
	case .Bytes, .Base64, .Hex:       return len((^[]u8)(ptr)^) == 0
	case .Bool:                       return !(^bool)(ptr)^
	case .Bool_Wide:                  return !read_wide_bool(ptr, tn.size)
	case .I8 ..= .I64:                return read_signed_int(ptr, tn.kind) == 0
	case .U8 ..= .U64:                return read_unsigned_int(ptr, tn.kind) == 0
	case .F32:                        return (^f32)(ptr)^ == 0
	case .F64:                        return (^f64)(ptr)^ == 0
	case .Slice, .Dynamic, .Fixed_List: _, n := list_span(tn, ptr); return n == 0
	case .Map:                        return (^runtime.Raw_Map)(ptr).len == 0
	}
	return false
}

@(private)
dump_tokens_inner :: proc(plan: ^Type_Plan, judging: ^Applied, val_ptr: rawptr, tt: ^write.Token_Tape, opts: Dump_Opts, sink: ^Sink, allocator, scratch: runtime.Allocator) -> Error {
	omit_state := Dump_Omit{plan = plan, opts = opts}
	mem.dynamic_arena_init(&omit_state.defaults, scratch, scratch)
	defer mem.dynamic_arena_destroy(&omit_state.defaults)

	omit_hook := Omit_Hook{fn = dump_field_omitted, ctx = &omit_state}
	if opts.check {
		dump_check_with_omit(plan, judging, val_ptr, sink, &omit_hook, allocator, scratch) or_return
	}
	em := Emitter{plan = plan, tt = tt, omit = &omit_hook, allocator = allocator, scratch = scratch}
	return emit_node(&em, plan.root, val_ptr, "")
}

@(private)
Emitter :: struct {
	plan:      ^Type_Plan,
	tt:        ^write.Token_Tape,
	omit:      ^Omit_Hook,
	allocator: runtime.Allocator,
	scratch:   runtime.Allocator,
}

@(private)
emit_tok :: #force_inline proc(em: ^Emitter, kind: write.Token_Kind, text: string) -> Error {
	werr := write.token_tape_take(em.tt, kind, text)
	return werr if werr != nil else nil
}

@(private)
Emit_Frame_Kind :: enum u8 { Node, Close, Struct_Fields, List_Elems, Map_Entries }

@(private)
Emit_Frame :: struct {
	kind:     Emit_Frame_Kind,
	node_idx: i32,
	ptr:      rawptr,
	tag_key:  string,
	tag_val:  string,
	si:       ^Struct_Info,
	idx:      int,
	count:    int,
	stride:   uintptr,
	base:     uintptr,
	entries:  []Sorted_Map_Entry,
	is_cap:   bool,
}

@(private)
push_e :: #force_inline proc(s: ^[dynamic]Emit_Frame, f: Emit_Frame) -> Error {
	_, err := append(s, f)
	return err if err != nil else nil
}

@(private)
emit_node :: proc(em: ^Emitter, root_idx: i32, root_ptr: rawptr, root_tag_key: string, root_tag_val := "") -> Error {
	stack, serr := make([dynamic]Emit_Frame, 0, 32, em.scratch)
	if serr != nil { return serr }
	defer delete(stack)
	push_e(&stack, {kind = .Node, node_idx = root_idx, ptr = root_ptr, tag_key = root_tag_key, tag_val = root_tag_val}) or_return

	for len(stack) > 0 {
		top := &stack[len(stack) - 1]
		switch top.kind {
		case .Close:
			pop(&stack)
			emit_tok(em, .Close, "") or_return

		case .Struct_Fields:
			si := top.si
			if top.idx < len(si.fields) {
				fi := top.idx; top.idx += 1
				f := &si.fields[fi]
				if f.access == .Write_Only || (em.omit != nil && em.omit.fn(em.omit.ctx, si, fi, top.ptr)) {
					continue
				}
				emit_tok(em, .Key, f.name) or_return
				push_e(&stack, {kind = .Node, node_idx = f.node, ptr = rawptr(uintptr(top.ptr) + f.offset)}) or_return
				continue
			}
			ptr := top.ptr; pop(&stack)
			if si.capture_idx >= 0 {
				cap_tn := &em.plan.nodes[si.capture_node]
				entries, merr := collect_sorted_map_entries(cap_tn.ti, rawptr(uintptr(ptr) + si.capture_offset), em.scratch)
				if merr != nil { return merr }
				if len(entries) > 0 {
					push_e(&stack, {kind = .Map_Entries, node_idx = cap_tn.child, si = si, entries = entries, is_cap = true}) or_return
				}
			}

		case .List_Elems:
			if top.idx >= top.count { pop(&stack); continue }
			i := top.idx; top.idx += 1
			push_e(&stack, {kind = .Node, node_idx = top.node_idx, ptr = rawptr(top.base + uintptr(i) * top.stride)}) or_return

		case .Map_Entries:
			if top.idx >= len(top.entries) { pop(&stack); continue }
			e := top.entries[top.idx]; top.idx += 1
			if top.is_cap && struct_find_field(top.si, e.key_text) >= 0 {
				return make_owned_error(.Duplicate_Key, 0, {tape.Name(e.key_text)}, "", {}, em.allocator, nil)
			}
			emit_tok(em, .Key, e.key_text) or_return
			push_e(&stack, {kind = .Node, node_idx = top.node_idx, ptr = e.val_ptr}) or_return

		case .Node:
			f := pop(&stack)
			tn := &em.plan.nodes[f.node_idx]
			ptr := f.ptr
			#partial switch tn.kind {
			case .Maybe:
				if !maybe_is_set(tn, ptr) { emit_tok(em, .Null, "") or_return } else {
					push_e(&stack, {kind = .Node, node_idx = tn.child, ptr = ptr, tag_key = f.tag_key, tag_val = f.tag_val}) or_return
				}
			case .Ptr:
				if inner := (^rawptr)(ptr)^; inner == nil { emit_tok(em, .Null, "") or_return } else {
					push_e(&stack, {kind = .Node, node_idx = tn.child, ptr = inner, tag_key = f.tag_key, tag_val = f.tag_val}) or_return
				}
			case .Struct:
				emit_tok(em, .Object, "") or_return
				if f.tag_key != "" {
					emit_tok(em, .Key, f.tag_key) or_return
					emit_tok(em, .String, f.tag_val) or_return
				}
				push_e(&stack, {kind = .Close}) or_return
				push_e(&stack, {kind = .Struct_Fields, si = &em.plan.structs[tn.struct_idx], ptr = ptr}) or_return
			case .Slice, .Dynamic, .Array, .Fixed_List:
				base, n := list_span(tn, ptr)
				emit_tok(em, .Array, "") or_return
				push_e(&stack, {kind = .Close}) or_return
				if n > 0 {
					push_e(&stack, {kind = .List_Elems, node_idx = tn.child, base = base, count = n, stride = uintptr(em.plan.nodes[tn.child].size)}) or_return
				}
			case .Map:
				emit_tok(em, .Object, "") or_return
				push_e(&stack, {kind = .Close}) or_return
				entries, merr := collect_sorted_map_entries(tn.ti, ptr, em.scratch)
				if merr != nil { return merr }
				if len(entries) > 0 { push_e(&stack, {kind = .Map_Entries, node_idx = tn.child, entries = entries}) or_return }
			case .Bit_Set:
				emit_bit_set(em, tn, ptr) or_return
			case .Union:
				u := &em.plan.unions[tn.union_idx]
				arm_idx := int(read_union_tag(ptr, u.tag_offset, u.tag_size)) - (0 if u.no_nil else 1)
				if arm_idx < 0 { emit_tok(em, .Null, "") or_return } else if arm_idx >= len(u.arms) { return Model_Error{kind = .No_Arm} } else {
					arm := u.arms[arm_idx]
					tkey := u.tag_key if u.mode == .Tag && u.tag_key != "" && arm.is_struct && arm.name != "" else ""
					push_e(&stack, {kind = .Node, node_idx = arm.node, ptr = ptr, tag_key = tkey, tag_val = arm.name}) or_return
				}
			case .Custom:
				c := &em.plan.customs[tn.custom_idx]
				ctn := &em.plan.nodes[tn.child]
				cbuf, cerr := runtime.mem_alloc(max(ctn.size, 1), ctn.align, em.scratch)
				if cerr != nil { return cerr }
				if ck := c.convert_to(c.to, ptr, raw_data(cbuf), em.scratch); ck != .None { return Model_Error{kind = ck} }
				push_e(&stack, {kind = .Node, node_idx = tn.child, ptr = raw_data(cbuf)}) or_return
			case .Enum:
				ei := &em.plan.enums[tn.enum_idx]
				ev := read_enum_value(ptr, tn.size, ei.ti)
				found := false
				for val, i in ei.values {
					if val == ev {
						found = true
						if ei.by_name { emit_tok(em, .String, ei.names[i]) or_return } else {
							buf: [32]u8 = ---
							emit_tok(em, .Number, strconv.write_uint(buf[:], u64(ev), 10) if ei.is_unsigned else strconv.write_int(buf[:], ev, 10)) or_return
						}
						break
					}
				}
				if !found { return Model_Error{kind = .Not_A_Member} }
			case .String, .Email:
				emit_tok(em, .String, (^string)(ptr)^) or_return
			case .Cstring:
				if cs := (^cstring)(ptr)^; cs == nil { emit_tok(em, .Null, "") or_return } else { emit_tok(em, .String, string(cs)) or_return }
			case .Bytes, .Base64:
				enc, err := encode_base64((^[]u8)(ptr)^, em.scratch)
				if err != nil { return err }
				emit_tok(em, .String, enc) or_return
			case .Hex:
				enc, err := encode_hex((^Hex)(ptr)^, em.scratch)
				if err != nil { return err }
				emit_tok(em, .String, enc) or_return
			case .Bool:
				emit_tok(em, .True if (^bool)(ptr)^ else .False, "") or_return
			case .Bool_Wide:
				emit_tok(em, .True if read_wide_bool(ptr, tn.size) else .False, "") or_return
			case .I8 ..= .I64:
				buf: [32]u8 = ---
				emit_tok(em, .Number, strconv.write_int(buf[:], read_signed_int(ptr, tn.kind), 10)) or_return
			case .U8 ..= .U64:
				buf: [32]u8 = ---
				emit_tok(em, .Number, strconv.write_uint(buf[:], read_unsigned_int(ptr, tn.kind), 10)) or_return
			case .F32:
				x := (^f32)(ptr)^
				if math.is_nan(x) || math.is_inf(x, 0) { return Model_Error{kind = .Non_Finite} }
				buf: [64]u8 = ---
				emit_tok(em, .Number, strconv.write_float(buf[:], f64(x), 'g', -1, 32, {})) or_return
			case .F64:
				x := (^f64)(ptr)^
				if math.is_nan(x) || math.is_inf(x, 0) { return Model_Error{kind = .Non_Finite} }
				buf: [64]u8 = ---
				emit_tok(em, .Number, strconv.write_float(buf[:], x, 'g', -1, 64, {})) or_return
			case .Number_Text:
				if nt := (^Number_Text)(ptr)^; nt.text == "" { emit_tok(em, .Null, "") or_return } else { emit_tok(em, .Number, nt.text) or_return }
			case .Time:
				buf: [40]u8 = ---
				s, ok := format_rfc3339_utc((^time.Time)(ptr)^, &buf)
				if !ok { return Model_Error{kind = .Bad_Format} }
				emit_tok(em, .String, s) or_return
			case .Uuid:
				buf: [36]u8 = ---
				emit_tok(em, .String, format_uuid((^uuid.Identifier)(ptr)^, &buf)) or_return
			case .Decimal:
				d := (^Decimal)(ptr)^
				emit_tok(em, .Number, d.text if d.text != "" else "0") or_return
			case .Value:
				emit_rules_value_tokens(em.tt, (^rules.Value)(ptr)^, em.scratch) or_return
			case .Raw:
				return Model_Error{kind = .Unsupported, want = {text = "Raw"}}
			case:
				return Model_Error{kind = .Unsupported}
			}
		}
	}
	return nil
}

@(private)
emit_bit_set :: proc(em: ^Emitter, tn: ^Type_Node, ptr: rawptr) -> Error {
	emit_tok(em, .Array, "") or_return
	bytes := ([^]u8)(ptr)[:tn.size]
	buf: [32]u8 = ---
	for bit in 0 ..< tn.count {
		if (bytes[bit / 8] >> uint(bit % 8)) & 1 == 0 { continue }
		val := tn.bit_lower + i64(bit)
		if tn.enum_idx >= 0 {
			ei := &em.plan.enums[tn.enum_idx]
			for ev, i in ei.values {
				if ev == val {
					if ei.by_name { emit_tok(em, .String, ei.names[i]) or_return } else { emit_tok(em, .Number, strconv.write_int(buf[:], val, 10)) or_return }
					break
				}
			}
		} else {
			emit_tok(em, .Number, strconv.write_int(buf[:], val, 10)) or_return
		}
	}
	return emit_tok(em, .Close, "")
}

// ============================================================================
// Direct-buffer JSON dumping (zero Token_Tape / tape.Document / Dynamic_Arena!)
// ============================================================================

JSON_LEAF_ROOM :: 64
JSON_LINE_MAX :: 1024
JSON_MEMBER_ROOM :: 1 + 256 + 16 + JSON_LEAF_ROOM
JSON_PRETTY_MEMBER_ROOM :: 1 + 1 + JSON_LINE_MAX + 256 + 16 + 1 + JSON_LEAF_ROOM
JSON_PRETTY_CLOSE_ROOM :: 2 * (1 + JSON_LINE_MAX) + 16

@(private)
JSON_NULL_U32 :: u32le('n') | u32le('u') << 8 | u32le('l') << 16 | u32le('l') << 24
@(private)
JSON_TRUE_U32 :: u32le('t') | u32le('r') << 8 | u32le('u') << 16 | u32le('e') << 24
@(private)
JSON_FALSE_U64 :: u64le('f') | u64le('a') << 8 | u64le('l') << 16 | u64le('s') << 24 | u64le('e') << 32
@(private)
DUMP_INLINE_FRAMES :: 32

@(private)
Dump_Frame_Mode :: enum u8 { Root, Struct, List, Map, Bits }

// Zero-padding layout so `[DUMP_INLINE_FRAMES]Dump_Frame = ---` is never zeroed by Odin.
@(private)
Dump_Frame :: struct {
	sf:        ^Stream_Field,
	si:        ^Struct_Info,
	at:        uintptr,
	left:      int,
	step:      int,
	entries:   []Sorted_Map_Entry,
	node_idx:  i32,
	mode:      Dump_Frame_Mode,
	lead:      u8,
	is_cap:    bool,
	check_opt: bool,
}
when size_of(uintptr) == 8 { #assert(size_of(Dump_Frame) == 64) }

@(private)
Lazy_Scratch :: struct {
	arena:   mem.Dynamic_Arena,
	ready:   bool,
	backing: runtime.Allocator,
}

@(private)
lazy_scratch_get :: proc(ls: ^Lazy_Scratch) -> runtime.Allocator {
	if !ls.ready {
		mem.dynamic_arena_init(&ls.arena, ls.backing, ls.backing, block_size = 16 * 1024)
		ls.ready = true
	}
	return mem.dynamic_arena_allocator(&ls.arena)
}

@(private)
lazy_scratch_end :: proc(ls: ^Lazy_Scratch) {
	if ls.ready { mem.dynamic_arena_destroy(&ls.arena) }
}

@(private)
dump_check_with_omit :: proc(plan: ^Type_Plan, judging: ^Applied, val_ptr: rawptr, sink: ^Sink, omit_hook: ^Omit_Hook, allocator, scratch: runtime.Allocator) -> Error {
	if verr := validate_inner(plan, judging, val_ptr, sink, {scratch = scratch}, omit_hook, allocator); verr != nil {
		if me, is_me := verr.(Model_Error); is_me {
			code := error_code(me.kind)
			if me.owned {
				delete(me.operand, allocator); delete(me.want.text, allocator)
				wt, cerr := strings.clone(code, allocator)
				if cerr != nil { delete(me.pointer, allocator); return cerr }
				return Model_Error{kind = .Check_Failed, at = me.at, pointer = me.pointer, want = {text = wt}, owned = true}
			}
			return Model_Error{kind = .Check_Failed, at = me.at, pointer = me.pointer, want = {text = code}}
		}
		return verr
	}
	return nil
}

@(private)
dump_check_value :: proc(plan: ^Type_Plan, judging: ^Applied, val_ptr: rawptr, opts: Dump_Opts, sink: ^Sink, allocator: runtime.Allocator, ls: ^Lazy_Scratch) -> Error {
	scratch := lazy_scratch_get(ls)
	omit_state := Dump_Omit{plan = plan, opts = opts}
	mem.dynamic_arena_init(&omit_state.defaults, scratch, scratch)
	defer mem.dynamic_arena_destroy(&omit_state.defaults)
	omit_hook := Omit_Hook{fn = dump_field_omitted, ctx = &omit_state}
	return dump_check_with_omit(plan, judging, val_ptr, sink, &omit_hook, allocator, scratch)
}

// Writes `v` directly as JSON into `w` via format callbacks, avoiding `Token_Tape`, `tape.Document`, and per-call arenas.
dump_json :: proc(
	m: ^Model($T),
	v: ^T,
	opts: Dump_Opts,
	sink: ^Sink,
	w: ^$W,
	$PRETTY: bool,
	$room: proc(w: ^W, n: int) -> [^]u8,
	$cursor_of: proc "contextless" (w: ^W) -> ^int,
	$has_err: proc "contextless" (w: ^W) -> bool,
	$put_string: proc(w: ^W, p: [^]u8, s: string) -> bool,
	$put_line: proc(w: ^W, p: [^]u8, depth: int, after: int) -> [^]u8,
	allocator := context.allocator,
) -> Error #no_bounds_check {
	if m == nil || v == nil || len(m.plan.nodes) == 0 {
		return Model_Error{kind = .Bad_Option, want = {text = "value"}}
	}
	plan := &m.plan
	ls := Lazy_Scratch{backing = allocator}
	defer lazy_scratch_end(&ls)

	if opts.check {
		dump_check_value(plan, m.judging, rawptr(v), opts, sink, allocator, &ls) or_return
	}

	omit_state := Dump_Omit{plan = plan, opts = opts}
	omit_ready := false
	defer if omit_ready { mem.dynamic_arena_destroy(&omit_state.defaults) }
	if opts.exclude_defaults {
		scr := lazy_scratch_get(&ls)
		mem.dynamic_arena_init(&omit_state.defaults, scr, scr)
		omit_ready = true
	}
	any_exclude := opts.exclude_unset || opts.exclude_none || opts.exclude_defaults

	inline_frames: [DUMP_INLINE_FRAMES]Dump_Frame = ---
	frames := raw_data(inline_frames[:])
	top, cap_frames := 0, DUMP_INLINE_FRAMES
	defer if cap_frames > DUMP_INLINE_FRAMES {
		runtime.mem_free_with_size(frames, cap_frames * size_of(Dump_Frame), allocator)
	}

	keys := raw_data(plan.json_keys)
	cursor := cursor_of(w)
	cur := Dump_Frame{mode = .Root, node_idx = plan.root, at = uintptr(v), left = 1}

	next: for {
		vkind: Type_Kind
		vnode: i32
		vsidx: i32
		va: uintptr
		p: [^]u8
		tag_key, tag_val: string

		if cur.mode == .Struct {
			sf := cur.sf
			if cur.check_opt {
				for sf.kind != .Invalid {
					if .Write_Only in sf.flags || dump_sf_omitted(&omit_state, cur.si, sf, cur.at) {
						sf = intrinsics.ptr_offset(sf, 1)
						continue
					}
					break
				}
			}
			if sf.kind == .Invalid {
				si := cur.si
				if si.capture_idx >= 0 {
					cap_tn := &plan.nodes[si.capture_node]
					entries, merr := collect_sorted_map_entries(cap_tn.ti, rawptr(cur.at + si.capture_offset), lazy_scratch_get(&ls))
					if merr != nil { return merr }
					if len(entries) > 0 {
						cur = Dump_Frame{mode = .Map, lead = cur.lead, is_cap = true, node_idx = cap_tn.child, si = si, entries = entries, step = 0, left = len(entries)}
						continue next
					}
				}
				when PRETTY {
					p = room(w, JSON_PRETTY_CLOSE_ROOM)
					if cur.lead == '{' { p[0], p[1] = '{', '}'; cursor^ += 2; p = p[2:] } else { p = put_line(w, p, top - 1, 2); p[0] = '}'; cursor^ += 1; p = p[1:] }
				} else {
					p = room(w, 3)
					if cur.lead == '{' { p[0], p[1] = '{', '}'; cursor^ += 2; p = p[2:] } else { p[0] = '}'; cursor^ += 1; p = p[1:] }
				}
				top -= 1
				cur = frames[top]
				if has_err(w) { return nil }
				continue next
			}
			ks := int(sf.key_size)
			if ks != 0 {
				when PRETTY {
					p = room(w, JSON_PRETTY_MEMBER_ROOM)
					p[0] = cur.lead; cur.lead = ','; cursor^ += 1
					p = put_line(w, p[1:], top, 256 + 16 + 1 + JSON_LEAF_ROOM)
					ksrc := keys[uint(sf.key_off):]
					if ks <= 16 {
						intrinsics.unaligned_store((^u128)(p), intrinsics.unaligned_load((^u128)(ksrc)))
					} else if ks <= 32 {
						intrinsics.unaligned_store((^u128)(p), intrinsics.unaligned_load((^u128)(ksrc)))
						intrinsics.unaligned_store((^u128)(p[ks - 16:]), intrinsics.unaligned_load((^u128)(ksrc[ks - 16:])))
					} else {
						intrinsics.mem_copy_non_overlapping(p, ksrc, ks)
					}
					p = p[ks:]; p[0] = ' '; p = p[1:]; cursor^ += ks + 1
				} else {
					ksrc := keys[uint(sf.key_off):]
					if ks <= 32 {
						p = room(w, 1 + 32 + JSON_LEAF_ROOM)
						p[0] = cur.lead; cur.lead = ','
						intrinsics.unaligned_store((^u128)(p[1:]), intrinsics.unaligned_load((^u128)(ksrc)))
						if ks > 16 {
							intrinsics.unaligned_store((^u128)(p[1 + ks - 16:]), intrinsics.unaligned_load((^u128)(ksrc[ks - 16:])))
						}
					} else {
						p = room(w, JSON_MEMBER_ROOM)
						p[0] = cur.lead; cur.lead = ','
						intrinsics.mem_copy_non_overlapping(p[1:], ksrc, ks)
					}
					cursor^ += 1 + ks; p = p[1 + ks:]
				}
			} else {
				when PRETTY {
					p = room(w, 1 + 1 + JSON_LINE_MAX + JSON_LEAF_ROOM)
					p[0] = cur.lead; cur.lead = ','; cursor^ += 1
					p = put_line(w, p[1:], top, JSON_LEAF_ROOM)
				} else {
					p = room(w, 1 + JSON_LEAF_ROOM)
					p[0] = cur.lead; cur.lead = ','; p = p[1:]; cursor^ += 1
				}
				if !put_string(w, p, cur.si.fields[sf.field_idx].name) { return write.Error(write.Refused{0, .No_Spelling}) }
				p = room(w, 2 + JSON_LEAF_ROOM)
				when PRETTY { p[0], p[1] = ':', ' '; p = p[2:]; cursor^ += 2 } else { p[0] = ':'; p = p[1:]; cursor^ += 1 }
			}
			cur.sf = intrinsics.ptr_offset(sf, 1)
			vkind, vnode, vsidx, va = sf.kind, sf.node, sf.struct_idx, cur.at + uintptr(sf.offset)
		} else if cur.mode == .List {
			if cur.left == 0 {
				when PRETTY {
					p = room(w, 1 + JSON_LINE_MAX + 8)
					p = put_line(w, p, top - 1, 1); p[0] = ']'; cursor^ += 1
				} else {
					p = room(w, 1); p[0] = ']'; cursor^ += 1
				}
				top -= 1
				cur = frames[top]
				if has_err(w) { return nil }
				continue next
			}
			cur.left -= 1
			when PRETTY {
				p = room(w, 1 + 1 + JSON_LINE_MAX + JSON_LEAF_ROOM)
				p[0] = ','; p = p[cur.lead:]; cursor^ += int(cur.lead); cur.lead = 1
				p = put_line(w, p, top, JSON_LEAF_ROOM)
			} else {
				p = room(w, 1 + JSON_LEAF_ROOM)
				p[0] = ','; p = p[cur.lead:]; cursor^ += int(cur.lead); cur.lead = 1
			}
			ctn := &plan.nodes[cur.node_idx]
			vkind, vnode, vsidx, va = ctn.kind, cur.node_idx, ctn.struct_idx, cur.at
			cur.at += uintptr(cur.step)
		} else if cur.mode == .Map {
			if cur.step >= cur.left {
				when PRETTY {
					p = room(w, 1 + JSON_LINE_MAX + 8)
					if cur.lead == '{' { p[0], p[1] = '{', '}'; cursor^ += 2 } else { p = put_line(w, p, top - 1, 1); p[0] = '}'; cursor^ += 1 }
				} else {
					p = room(w, 2)
					if cur.lead == '{' { p[0], p[1] = '{', '}'; cursor^ += 2 } else { p[0] = '}'; cursor^ += 1 }
				}
				top -= 1
				cur = frames[top]
				if has_err(w) { return nil }
				continue next
			}
			e := cur.entries[cur.step]; cur.step += 1
			if cur.is_cap && struct_find_field(cur.si, e.key_text) >= 0 {
				first: Model_Error
				oom := false
				_ = record_failure(sink, &first, &oom, allocator, .Duplicate_Key, 0, {tape.Name(e.key_text)}, "", {}, false)
				if oom { return runtime.Allocator_Error.Out_Of_Memory }
				return first
			}
			when PRETTY {
				p = room(w, 1 + 1 + JSON_LINE_MAX + JSON_LEAF_ROOM)
				p[0] = cur.lead; cur.lead = ','; cursor^ += 1
				p = put_line(w, p[1:], top, JSON_LEAF_ROOM)
			} else {
				p = room(w, 1 + JSON_LEAF_ROOM)
				p[0] = cur.lead; cur.lead = ','; p = p[1:]; cursor^ += 1
			}
			if !put_string(w, p, e.key_text) { return write.Error(write.Refused{0, .No_Spelling}) }
			p = room(w, 2 + JSON_LEAF_ROOM)
			when PRETTY { p[0], p[1] = ':', ' '; p = p[2:]; cursor^ += 2 } else { p[0] = ':'; p = p[1:]; cursor^ += 1 }
			vtn := &plan.nodes[cur.node_idx]
			vkind, vnode, vsidx, va = vtn.kind, cur.node_idx, vtn.struct_idx, uintptr(e.val_ptr)
		} else if cur.mode == .Bits {
			tn := &plan.nodes[cur.node_idx]
			bytes := ([^]u8)(cur.at)[:tn.size]
			i := cur.step
			for i < cur.left && (bytes[i >> 3] >> uint(i & 7)) & 1 == 0 { i += 1 }
			if i >= cur.left {
				when PRETTY {
					p = room(w, 1 + JSON_LINE_MAX + 8)
					if cur.lead != 0 { p = put_line(w, p, top - 1, 1) }
					p[0] = ']'; cursor^ += 1
				} else {
					p = room(w, 1); p[0] = ']'; cursor^ += 1
				}
				top -= 1
				cur = frames[top]
				if has_err(w) { return nil }
				continue next
			}
			cur.step = i + 1
			when PRETTY {
				p = room(w, 1 + 1 + JSON_LINE_MAX + JSON_LEAF_ROOM)
				p[0] = ','; p = p[cur.lead:]; cursor^ += int(cur.lead); cur.lead = 1
				p = put_line(w, p, top, JSON_LEAF_ROOM)
			} else {
				p = room(w, 1 + JSON_LEAF_ROOM)
				p[0] = ','; p = p[cur.lead:]; cursor^ += int(cur.lead); cur.lead = 1
			}
			val := tn.bit_lower + i64(i)
			if tn.enum_idx >= 0 {
				ei := &plan.enums[tn.enum_idx]
				for ev, k in ei.values {
					if ev == val {
						if ei.by_name {
							if !put_string(w, p, ei.names[k]) { return write.Error(write.Refused{0, .No_Spelling}) }
						} else {
							cursor^ += dump_put_u64(p, u64(val)) if ei.is_unsigned else dump_put_i64(p, val)
						}
						break
					}
				}
			} else {
				cursor^ += dump_put_i64(p, val)
			}
			continue next
		} else {
			if cur.left == 0 { return nil }
			cur.left = 0
			p = room(w, JSON_LEAF_ROOM)
			rtn := &plan.nodes[cur.node_idx]
			vkind, vnode, vsidx, va = rtn.kind, cur.node_idx, rtn.struct_idx, cur.at
		}

		ptr_hops := 0
		value: for {
			if vkind == .String {
				if !put_string(w, p, (^string)(va)^) { return write.Error(write.Refused{0, .No_Spelling}) }
				continue next
			}
			#partial switch vkind {
			case .I64:
				cursor^ += dump_put_i64(p, (^i64)(va)^)
			case .F64:
				n, ok := dump_put_f64(p, (^f64)(va)^)
				if !ok {
					if sink != nil { _ = sink_push(sink, allocator, .Non_Finite, 0, nil) }
					return Model_Error{kind = .Non_Finite}
				}
				cursor^ += n
			case .Bool:
				if (^bool)(va)^ { intrinsics.unaligned_store((^u32le)(p), JSON_TRUE_U32); cursor^ += 4 } else { intrinsics.unaligned_store((^u64le)(p), JSON_FALSE_U64); cursor^ += 5 }
			case .Struct:
				if top >= int(tape.DEFAULT_DEPTH) { return tape.Error(tape.Exceeded{kind = .Depth}) }
				if !dump_push_frame(&frames, &top, &cap_frames, cur, allocator) { return runtime.Allocator_Error.Out_Of_Memory }
				si := &plan.structs[vsidx]
				lead := u8('{')
				if tag_key != "" {
					when PRETTY {
						p = room(w, 1 + 1 + JSON_LINE_MAX + JSON_LEAF_ROOM)
						p[0] = '{'; cursor^ += 1
						p = put_line(w, p[1:], top, JSON_LEAF_ROOM)
					} else {
						p = room(w, 1 + JSON_LEAF_ROOM)
						p[0] = '{'; p = p[1:]; cursor^ += 1
					}
					if !put_string(w, p, tag_key) { return write.Error(write.Refused{0, .No_Spelling}) }
					p = room(w, 2 + JSON_LEAF_ROOM)
					when PRETTY { p[0], p[1] = ':', ' '; p = p[2:]; cursor^ += 2 } else { p[0] = ':'; p = p[1:]; cursor^ += 1 }
					if !put_string(w, p, tag_val) { return write.Error(write.Refused{0, .No_Spelling}) }
					lead = ','
				}
				cur = Dump_Frame{
					mode      = .Struct,
					lead      = lead,
					check_opt = si.has_omit_tag || (any_exclude && si.has_optional),
					sf        = raw_data(si.stream_fields),
					si        = si,
					at        = va,
				}
			case .Slice, .Dynamic, .Array, .Fixed_List:
				tn := &plan.nodes[vnode]
				base, n := list_span(tn, rawptr(va))
				if n == 0 {
					p[0], p[1] = '[', ']'; cursor^ += 2
				} else {
					if top >= int(tape.DEFAULT_DEPTH) { return tape.Error(tape.Exceeded{kind = .Depth}) }
					if !dump_push_frame(&frames, &top, &cap_frames, cur, allocator) { return runtime.Allocator_Error.Out_Of_Memory }
					p[0] = '['; cursor^ += 1
					cur = Dump_Frame{mode = .List, lead = 0, node_idx = tn.child, at = base, left = n, step = plan.nodes[tn.child].size}
				}
			case .Map:
				tn := &plan.nodes[vnode]
				if (^runtime.Raw_Map)(va).len == 0 {
					p[0], p[1] = '{', '}'; cursor^ += 2
				} else {
					if top >= int(tape.DEFAULT_DEPTH) { return tape.Error(tape.Exceeded{kind = .Depth}) }
					entries, merr := collect_sorted_map_entries(tn.ti, rawptr(va), lazy_scratch_get(&ls))
					if merr != nil { return merr }
					if !dump_push_frame(&frames, &top, &cap_frames, cur, allocator) { return runtime.Allocator_Error.Out_Of_Memory }
					cur = Dump_Frame{mode = .Map, lead = '{', node_idx = tn.child, entries = entries, step = 0, left = len(entries)}
				}
			case .Maybe:
				tn := &plan.nodes[vnode]
				if !maybe_is_set(tn, rawptr(va)) {
					intrinsics.unaligned_store((^u32le)(p), JSON_NULL_U32); cursor^ += 4
				} else {
					ctn := &plan.nodes[tn.child]
					vkind, vnode, vsidx = ctn.kind, tn.child, ctn.struct_idx
					continue value
				}
			case .Ptr:
				inner := (^uintptr)(va)^
				if inner == 0 {
					intrinsics.unaligned_store((^u32le)(p), JSON_NULL_U32); cursor^ += 4
				} else {
					ptr_hops += 1
					if top + ptr_hops > int(tape.DEFAULT_DEPTH) { return tape.Error(tape.Exceeded{kind = .Depth}) }
					tn := &plan.nodes[vnode]
					ctn := &plan.nodes[tn.child]
					vkind, vnode, vsidx, va = ctn.kind, tn.child, ctn.struct_idx, inner
					continue value
				}
			case .Union:
				tn := &plan.nodes[vnode]
				u := &plan.unions[tn.union_idx]
				arm_idx := int(read_union_tag(rawptr(va), u.tag_offset, u.tag_size)) - (0 if u.no_nil else 1)
				if arm_idx < 0 {
					intrinsics.unaligned_store((^u32le)(p), JSON_NULL_U32); cursor^ += 4
				} else if arm_idx >= len(u.arms) {
					return Model_Error{kind = .No_Arm}
				} else {
					arm := u.arms[arm_idx]
					if u.mode == .Tag && u.tag_key != "" && arm.is_struct && arm.name != "" {
						tag_key, tag_val = u.tag_key, arm.name
					}
					atn := &plan.nodes[arm.node]
					vkind, vnode, vsidx = atn.kind, arm.node, atn.struct_idx
					continue value
				}
			case .Custom:
				tn := &plan.nodes[vnode]
				c := &plan.customs[tn.custom_idx]
				ctn := &plan.nodes[tn.child]
				scr := lazy_scratch_get(&ls)
				cbuf, cerr := runtime.mem_alloc(max(ctn.size, 1), ctn.align, scr)
				if cerr != nil { return cerr }
				if ck := c.convert_to(c.to, rawptr(va), raw_data(cbuf), scr); ck != .None { return Model_Error{kind = ck} }
				vkind, vnode, vsidx, va = ctn.kind, tn.child, ctn.struct_idx, uintptr(raw_data(cbuf))
				continue value
			case .Bit_Set:
				if top >= int(tape.DEFAULT_DEPTH) { return tape.Error(tape.Exceeded{kind = .Depth}) }
				tn := &plan.nodes[vnode]
				if !dump_push_frame(&frames, &top, &cap_frames, cur, allocator) { return runtime.Allocator_Error.Out_Of_Memory }
				p[0] = '['; cursor^ += 1
				cur = Dump_Frame{mode = .Bits, lead = 0, node_idx = vnode, at = va, left = tn.count, step = 0}
			case:
				if rerr := dump_put_rare(plan, &plan.nodes[vnode], rawptr(va), w, p, cursor, &ls, sink, allocator, PRETTY, room, put_string, put_line, top); rerr != nil {
					return rerr
				}
			}
			continue next
		}
	}
}

@(private)
dump_sf_omitted :: #force_inline proc(o: ^Dump_Omit, si: ^Struct_Info, sf: ^Stream_Field, struct_at: uintptr) -> bool {
	if .Omit_Unset not_in sf.flags && .Omit_Empty not_in sf.flags && .Optional not_in sf.flags { return false }
	return dump_field_omitted(o, si, int(sf.field_idx), rawptr(struct_at))
}

@(private)
dump_push_frame :: #force_inline proc(frames: ^[^]Dump_Frame, top, cap_frames: ^int, frame: Dump_Frame, allocator: runtime.Allocator) -> bool #no_bounds_check {
	if top^ == cap_frames^ && !dump_grow_frames(frames, cap_frames, allocator) { return false }
	frames^[top^] = frame
	top^ += 1
	return true
}

@(private, cold)
dump_grow_frames :: #force_no_inline proc(frames: ^[^]Dump_Frame, cap_frames: ^int, allocator: runtime.Allocator) -> bool {
	next_cap := cap_frames^ * 2
	raw, aerr := runtime.mem_alloc_non_zeroed(next_cap * size_of(Dump_Frame), align_of(Dump_Frame), allocator)
	if aerr != nil || raw_data(raw) == nil { return false }
	grown := ([^]Dump_Frame)(raw_data(raw))
	intrinsics.mem_copy_non_overlapping(grown, frames^, cap_frames^ * size_of(Dump_Frame))
	if cap_frames^ > DUMP_INLINE_FRAMES {
		runtime.mem_free_with_size(frames^, cap_frames^ * size_of(Dump_Frame), allocator)
	}
	frames^, cap_frames^ = grown, next_cap
	return true
}

@(private, cold)
dump_put_rare :: #force_no_inline proc(
	plan: ^Type_Plan, tn: ^Type_Node, ptr: rawptr, w: ^$W, p: [^]u8, cursor: ^int, ls: ^Lazy_Scratch, sink: ^Sink, allocator: runtime.Allocator, $PRETTY: bool,
	$room: proc(w: ^W, n: int) -> [^]u8,
	$put_string: proc(w: ^W, p: [^]u8, s: string) -> bool,
	$put_line: proc(w: ^W, p: [^]u8, depth: int, after: int) -> [^]u8,
	depth: int,
) -> Error #no_bounds_check {
	#partial switch tn.kind {
	case .I8:  cursor^ += dump_put_i64(p, i64((^i8)(ptr)^))
	case .I16: cursor^ += dump_put_i64(p, i64((^i16)(ptr)^))
	case .I32: cursor^ += dump_put_i64(p, i64((^i32)(ptr)^))
	case .U8:  cursor^ += dump_put_u64(p, u64((^u8)(ptr)^))
	case .U16: cursor^ += dump_put_u64(p, u64((^u16)(ptr)^))
	case .U32: cursor^ += dump_put_u64(p, u64((^u32)(ptr)^))
	case .U64: cursor^ += dump_put_u64(p, (^u64)(ptr)^)
	case .F32:
		x := (^f32)(ptr)^
		if math.is_nan(x) || math.is_inf(x, 0) {
			if sink != nil { _ = sink_push(sink, allocator, .Non_Finite, 0, nil) }
			return Model_Error{kind = .Non_Finite}
		}
		cursor^ += len(strconv.write_float(p[:JSON_LEAF_ROOM - 2], f64(x), 'g', -1, 32, {}))
	case .Bool_Wide:
		if read_wide_bool(ptr, tn.size) { intrinsics.unaligned_store((^u32le)(p), JSON_TRUE_U32); cursor^ += 4 } else { intrinsics.unaligned_store((^u64le)(p), JSON_FALSE_U64); cursor^ += 5 }
	case .Email:
		if !put_string(w, p, (^string)(ptr)^) { return write.Error(write.Refused{0, .No_Spelling}) }
	case .Cstring:
		if cs := (^cstring)(ptr)^; cs == nil { intrinsics.unaligned_store((^u32le)(p), JSON_NULL_U32); cursor^ += 4 } else if !put_string(w, p, string(cs)) { return write.Error(write.Refused{0, .No_Spelling}) }
	case .Bytes, .Base64:
		enc, err := encode_base64((^[]u8)(ptr)^, lazy_scratch_get(ls))
		if err != nil { return err }
		if !put_string(w, p, enc) { return write.Error(write.Refused{0, .No_Spelling}) }
	case .Hex:
		enc, err := encode_hex((^Hex)(ptr)^, lazy_scratch_get(ls))
		if err != nil { return err }
		if !put_string(w, p, enc) { return write.Error(write.Refused{0, .No_Spelling}) }
	case .Number_Text:
		nt := (^Number_Text)(ptr)^
		if nt.text == "" { intrinsics.unaligned_store((^u32le)(p), JSON_NULL_U32); cursor^ += 4 } else { dump_put_raw(w, cursor, nt.text, room) }
	case .Decimal:
		d := (^Decimal)(ptr)^
		dump_put_raw(w, cursor, d.text if d.text != "" else "0", room)
	case .Time:
		buf: [40]u8 = ---
		s, ok := format_rfc3339_utc((^time.Time)(ptr)^, &buf)
		if !ok { return Model_Error{kind = .Bad_Format} }
		p[0] = '"'; intrinsics.mem_copy_non_overlapping(p[1:], raw_data(s), len(s)); p[1 + len(s)] = '"'
		cursor^ += len(s) + 2
	case .Uuid:
		buf: [36]u8 = ---
		s := format_uuid((^uuid.Identifier)(ptr)^, &buf)
		p[0] = '"'; intrinsics.mem_copy_non_overlapping(p[1:], raw_data(s), len(s)); p[1 + len(s)] = '"'
		cursor^ += len(s) + 2
	case .Enum:
		ei := &plan.enums[tn.enum_idx]
		ev := read_enum_value(ptr, tn.size, ei.ti)
		for val, i in ei.values {
			if val == ev {
				if ei.by_name {
					if !put_string(w, p, ei.names[i]) { return write.Error(write.Refused{0, .No_Spelling}) }
				} else {
					cursor^ += dump_put_u64(p, u64(ev)) if ei.is_unsigned else dump_put_i64(p, ev)
				}
				return nil
			}
		}
		return Model_Error{kind = .Not_A_Member}
	case .Value:
		return dump_put_rules_value((^rules.Value)(ptr)^, w, p, cursor, lazy_scratch_get(ls), sink, allocator, PRETTY, room, put_string, put_line, depth)
	case .Raw:
		return Model_Error{kind = .Unsupported, want = {text = "Raw"}}
	case:
		return Model_Error{kind = .Unsupported}
	}
	return nil
}

@(private)
dump_put_raw :: proc(w: ^$W, cursor: ^int, s: string, $room: proc(w: ^W, n: int) -> [^]u8) #no_bounds_check {
	for at := 0; at < len(s); at += write.ROOM_MAX {
		k := min(write.ROOM_MAX, len(s) - at)
		intrinsics.mem_copy_non_overlapping(room(w, k), raw_data(s[at:]), k)
		cursor^ += k
	}
}

@(private, cold)
dump_put_rules_value :: proc(
	root: rules.Value, w: ^$W, p0: [^]u8, cursor: ^int, scratch: runtime.Allocator, sink: ^Sink, allocator: runtime.Allocator, $PRETTY: bool,
	$room: proc(w: ^W, n: int) -> [^]u8,
	$put_string: proc(w: ^W, p: [^]u8, s: string) -> bool,
	$put_line: proc(w: ^W, p: [^]u8, depth: int, after: int) -> [^]u8,
	base_depth: int,
) -> Error #no_bounds_check {
	Rv_Frame :: struct { is_obj: bool, idx: int, elems: []rules.Value, members: []rules.Member_Value }
	stack := make([dynamic]Rv_Frame, 0, 8, scratch) or_return
	defer delete(stack)
	cur_v, have_v, p := root, true, p0
	for {
		if !have_v {
			if len(stack) == 0 { return nil }
			top := &stack[len(stack) - 1]
			n_items := len(top.members) if top.is_obj else len(top.elems)
			if top.idx >= n_items {
				ch := u8('}') if top.is_obj else u8(']')
				pop(&stack)
				when PRETTY {
					p = room(w, 1 + JSON_LINE_MAX + 8)
					if n_items > 0 { p = put_line(w, p, base_depth + len(stack), 1) }
					p[0] = ch; cursor^ += 1
				} else {
					room(w, 1)[0] = ch; cursor^ += 1
				}
				continue
			}
			first := top.idx == 0
			top.idx += 1
			if top.is_obj {
				m := top.members[top.idx - 1]
				when PRETTY {
					p = room(w, 1 + 1 + JSON_LINE_MAX + JSON_LEAF_ROOM)
					if !first { p[0] = ','; p = p[1:]; cursor^ += 1 }
					p = put_line(w, p, base_depth + len(stack), JSON_LEAF_ROOM)
				} else {
					p = room(w, 1 + JSON_LEAF_ROOM)
					if !first { p[0] = ','; p = p[1:]; cursor^ += 1 }
				}
				if !put_string(w, p, m.key) { return write.Error(write.Refused{0, .No_Spelling}) }
				p = room(w, 2 + JSON_LEAF_ROOM)
				when PRETTY { p[0], p[1] = ':', ' '; p = p[2:]; cursor^ += 2 } else { p[0] = ':'; p = p[1:]; cursor^ += 1 }
				cur_v, have_v = m.value, true
			} else {
				cur_v, have_v = top.elems[top.idx - 1], true
				when PRETTY {
					p = room(w, 1 + 1 + JSON_LINE_MAX + JSON_LEAF_ROOM)
					if !first { p[0] = ','; p = p[1:]; cursor^ += 1 }
					p = put_line(w, p, base_depth + len(stack), JSON_LEAF_ROOM)
				} else {
					p = room(w, 1 + JSON_LEAF_ROOM)
					if !first { p[0] = ','; p = p[1:]; cursor^ += 1 }
				}
			}
		}
		have_v = false
		switch x in cur_v {
		case rules.Null:        intrinsics.unaligned_store((^u32le)(p), JSON_NULL_U32); cursor^ += 4
		case bool:              if x { intrinsics.unaligned_store((^u32le)(p), JSON_TRUE_U32); cursor^ += 4 } else { intrinsics.unaligned_store((^u64le)(p), JSON_FALSE_U64); cursor^ += 5 }
		case i64:               cursor^ += dump_put_i64(p, x)
		case u64:               cursor^ += dump_put_u64(p, x)
		case f64:
			n, ok := dump_put_f64(p, x)
			if !ok {
				if sink != nil { _ = sink_push(sink, allocator, .Non_Finite, 0, nil) }
				return Model_Error{kind = .Non_Finite}
			}
			cursor^ += n
		case rules.Number_Text: dump_put_raw(w, cursor, x.text, room)
		case string:            if !put_string(w, p, x) { return write.Error(write.Refused{0, .No_Spelling}) }
		case []rules.Value:
			if base_depth + len(stack) >= int(tape.DEFAULT_DEPTH) { return tape.Error(tape.Exceeded{kind = .Depth}) }
			p[0] = '['; cursor^ += 1; append(&stack, Rv_Frame{elems = x}) or_return
		case []rules.Member_Value:
			if base_depth + len(stack) >= int(tape.DEFAULT_DEPTH) { return tape.Error(tape.Exceeded{kind = .Depth}) }
			p[0] = '{'; cursor^ += 1; append(&stack, Rv_Frame{is_obj = true, members = x}) or_return
		case rules.Node_Ref:    cur_v = clone_rules_value(cur_v, scratch, scratch) or_return; have_v = true
		case:                   intrinsics.unaligned_store((^u32le)(p), JSON_NULL_U32); cursor^ += 4
		}
	}
}

@(private)
DUMP_ZEROS8 :: u64(0x3030_3030_3030_3030)

@(private)
dump_bcd8 :: #force_inline proc "contextless" (x: u64) -> u64 {
	abcd_efgh := x + (1 << 32 - 10000) * ((x * ((1 << 40) / 10000 + 1)) >> 40)
	ab_cd_ef_gh := abcd_efgh + (1 << 16 - 100) * ((abcd_efgh * ((1 << 19) / 100 + 1)) >> 19 & 0x7f_0000_007f)
	a_b_c_d_e_f_g_h := ab_cd_ef_gh + (1 << 8 - 10) * ((ab_cd_ef_gh * ((1 << 10) / 10 + 1)) >> 10 & 0xf_000f_000f_000f)
	return intrinsics.byte_swap(a_b_c_d_e_f_g_h)
}

@(private)
dump_lead8 :: #force_inline proc "contextless" (dst: [^]u8, x: u64) -> int #no_bounds_check {
	digits := dump_bcd8(x)
	skip := int(intrinsics.count_trailing_zeros(digits | 1 << 56)) >> 3
	intrinsics.unaligned_store((^u64le)(dst), u64le((digits + DUMP_ZEROS8) >> (8 * uint(skip))))
	return 8 - skip
}

@(private)
dump_put_u64 :: #force_inline proc "contextless" (dst: [^]u8, u: u64) -> int #no_bounds_check {
	if u < 100_000_000 { return dump_lead8(dst, u) }
	if u < 10_000_000_000_000_000 {
		high := u / 100_000_000
		n := dump_lead8(dst, high)
		intrinsics.unaligned_store((^u64le)(dst[n:]), u64le(dump_bcd8(u - high * 100_000_000) | DUMP_ZEROS8))
		return n + 8
	}
	top := u / 10_000_000_000_000_000
	low16 := u - top * 10_000_000_000_000_000
	mid := low16 / 100_000_000
	n := dump_lead8(dst, top)
	intrinsics.unaligned_store((^u64le)(dst[n:]), u64le(dump_bcd8(mid) | DUMP_ZEROS8))
	intrinsics.unaligned_store((^u64le)(dst[n + 8:]), u64le(dump_bcd8(low16 - mid * 100_000_000) | DUMP_ZEROS8))
	return n + 16
}

@(private)
dump_put_i64 :: #force_inline proc "contextless" (dst: [^]u8, v: i64) -> int #no_bounds_check {
	neg := int(v < 0)
	dst[0] = '-'
	u := u64(v)
	return neg + dump_put_u64(dst[neg:], 0 - u if neg != 0 else u)
}

@(private)
dump_put_f64 :: #force_inline proc(dst: [^]u8, f: f64) -> (int, bool) #no_bounds_check {
	if f - f != 0 { return 0, false }
	bits := transmute(u64)f
	neg := int(bits >> 63)
	abs_f := transmute(f64)(bits & 0x7FFF_FFFF_FFFF_FFFF)
	if abs_f < 1_000_000.0 && (abs_f >= 0.001 || abs_f == 0) {
		scaled := abs_f * 1000.0
		k := u64(scaled + 0.5)
		diff := scaled - f64(k)
		if diff > -1e-7 && diff < 1e-7 && k < 1_000_000_000 && f64(k) / 1000.0 == abs_f {
			dst[0] = '-'
			whole := k / 1000
			frac := k - whole * 1000
			n := neg + dump_lead8(dst[neg:], whole)
			if frac == 0 { return n, true }
			dst[n] = '.'
			d1 := frac / 100
			rem := frac - d1 * 100
			d2 := rem / 10
			d3 := rem - d2 * 10
			dst[n + 1] = '0' + u8(d1)
			if d3 != 0 { dst[n + 2] = '0' + u8(d2); dst[n + 3] = '0' + u8(d3); return n + 4, true }
			if d2 != 0 { dst[n + 2] = '0' + u8(d2); return n + 3, true }
			return n + 2, true
		}
	}
	return dump_put_f64_slow(dst, f), true
}

@(private, cold)
dump_put_f64_slow :: #force_no_inline proc(dst: [^]u8, f: f64) -> int #no_bounds_check {
	return len(strconv.write_float(dst[:JSON_LEAF_ROOM - 2], f, 'g', -1, 64, {}))
}
