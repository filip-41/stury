// Model dumping: iteratively marshals an Odin value respecting model tags, roles, defaults,
// carriers, tagged union discriminators, and omit options into a `tape.Document`, `write.Token_Tape`,
// or any format's `write` / `write_to`. Backed by `mem.Dynamic_Arena` (WASM-clean, O(1) native stack).
package model

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
		if verr := validate_inner(plan, judging, val_ptr, sink, {scratch = scratch}, &omit_hook, allocator); verr != nil {
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
