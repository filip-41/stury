// Compiled type plan (`Type_Plan`) for Odin reflection: structs (including `using` flattening),
// unions, enums, carriers, tags, leaf rules, defaults, coercions, and validators.
// Backed by `mem.Dynamic_Arena` (WASM-clean).
package model

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:strings"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

@(private)
NO_KEY :: max(u64)

@(private)
KEY_MASK :: u64(0xFFFF_FFFF) | u64(0xFFFF) << 32 | u64(tape.SPELLING_DECODE) << 48

@(private)
Stream_Field_Flag :: enum u8 {
	Read_Only,
	Write_Only,
	Optional,
	Required,
	Not_Null,
	Has_Default,
	Nonzero_Default,
	Has_After,
	Omit_Empty,
	Omit_Unset,
	Is_Root,
	Is_Elem,
}

@(private)
Stream_Field_Flags :: bit_set[Stream_Field_Flag; u16]

// 48-byte hot record for both `.Expects` streaming load and direct-buffer JSON dump.
// Zero pointers so `size_of(Stream_Field) == hook.EXPECTED_STRIDE` on both 64-bit and wasm32.
@(private)
Stream_Field :: struct {
	using expected: hook.Expected_Key,
	node:           i32,
	rule_idx:       i32,
	offset:         u32,
	struct_idx:     i32,
	field_idx:      u16,
	flags:          Stream_Field_Flags,
	key_off:        u16,
	key_size:       u8,
	kind:           Type_Kind,
}

#assert(size_of(Stream_Field) == hook.EXPECTED_STRIDE)

@(private)
Type_Kind :: enum u8 {
	Invalid, Struct, Slice, Dynamic, Array, Fixed_List, Map, Enum, Bit_Set, Maybe, Ptr, Union,
	String, Cstring, Bytes, Bool, Bool_Wide, I8, I16, I32, I64, U8, U16, U32, U64, F32, F64,
	Number_Text, Time, Uuid, Email, Base64, Hex, Decimal, Custom, Raw, Value,
}

@(private)
Type_Node :: struct {
	kind:           Type_Kind,
	type:           typeid,
	ti:             ^runtime.Type_Info,
	size, align:    int,
	child:          i32,
	key_node:       i32,
	count:          int,
	tag_offset:     uintptr,
	tag_size:       int,
	no_nil:         bool,
	pure_maybe:     bool,
	len_offset:     uintptr,
	bit_lower:      i64,
	struct_idx:     i32,
	enum_idx:       i32,
	union_idx:      i32,
	custom_idx:     i32,
	rule_idx:       i32,
	elem_field_idx: i32,
	has_unique:     bool,
	judged:         bool,
}

@(private)
Field_Info :: struct {
	odin_name, name: string,
	offset:          uintptr,
	node, rule_idx:  i32,
	has_unique:      bool,
	access:          Access,
	optional:        bool,
	required:        bool,
	not_null:        bool,
	omit_empty:      bool,
	omit_unset:      bool,
	has_default:     bool,
	make_default:    Make_Default,
	default_data:    rawptr,
	has_before:      bool,
	before:          Before,
	afters:          []Validator,
}

@(private)
Struct_Info :: struct {
	type:              typeid,
	name:              string,
	fields:            []Field_Info,
	slots:             []u32,
	stream_fields:     []Stream_Field,
	req_mask0:         u64,
	def_mask0:         u64,
	has_req_hi:        bool,
	has_def_hi:        bool,
	has_omit_tag:      bool,
	has_optional:      bool,
	has_field_afters:  bool,
	has_fields_set:    bool,
	fields_set_offset: uintptr,
	capture_idx:       i32,
	capture_offset:    uintptr,
	capture_node:      i32,
	capture_name:      string,
	forbid_extra:      bool,
	validators:        []Validator,
}

@(private)
Enum_Info :: struct {
	type:        typeid,
	ti:          ^runtime.Type_Info_Enum,
	by_name:     bool,
	is_unsigned: bool,
	names:       []string,
	values:      []i64,
}

@(private)
Union_Arm :: struct {
	name:      string,
	tag_value: i64,
	node:      i32,
	is_struct: bool,
}

@(private)
Union_Info :: struct {
	type:       typeid,
	mode:       Union_Mode,
	tag_key:    string,
	no_nil:     bool,
	tag_offset: uintptr,
	tag_size:   int,
	arms:       []Union_Arm,
}

@(private)
Type_Plan :: struct {
	root:           i32,
	type:           typeid,
	tag:            string,
	nodes:          []Type_Node,
	structs:        []Struct_Info,
	enums:          []Enum_Info,
	unions:         []Union_Info,
	customs:        []Custom_Of,
	rule_sets:      []rules.Rules,
	leaves:         []rules.Leaf,
	root_field:     Stream_Field,
	elem_fields:    []Stream_Field,
	json_keys:      []u8,
	dump_hint:      int,
	can_stream:     bool,
	has_validators: bool,
	arena:          mem.Dynamic_Arena,
	arena_ready:    bool,
	allocator:      runtime.Allocator,
}

@(private)
type_plan_destroy :: proc(p: ^Type_Plan) {
	if p == nil { return }
	if p.arena_ready { mem.dynamic_arena_destroy(&p.arena) }
	p^ = {}
}

@(private)
Plan_Builder :: struct {
	reg:        ^Registry,
	tag:        string,
	defaults:   []Default_Of,
	arena:      runtime.Allocator,
	scratch:    runtime.Allocator,
	nodes:      [dynamic]Type_Node,
	structs:    [dynamic]Struct_Info,
	enums:      [dynamic]Enum_Info,
	unions:     [dynamic]Union_Info,
	customs:    [dynamic]Custom_Of,
	rule_sets:  [dynamic]rules.Rules,
	leaves:     [dynamic]rules.Leaf,
	programs:   rules.Programs,
	type_cache: map[typeid]i32,
	err:        Error,
}

@(private)
b_push :: #force_inline proc(b: ^Plan_Builder, list: ^[dynamic]$T, x: T) -> bool {
	if _, err := append(list, x); err != nil { b.err = err; return false }
	return true
}

@(private)
build_type_plan :: proc(reg: ^Registry, T: typeid, tag: string, defaults: []Default_Of, allocator, scratch: runtime.Allocator) -> (p: Type_Plan, err: Error) {
	p = {type = T, tag = tag, allocator = allocator, arena_ready = true}
	mem.dynamic_arena_init(&p.arena, allocator, allocator)
	arena := mem.dynamic_arena_allocator(&p.arena)
	defer if err != nil { type_plan_destroy(&p) }

	b := Plan_Builder{reg = reg, tag = tag, defaults = defaults, arena = arena, scratch = scratch}
	b.nodes.allocator, b.structs.allocator, b.enums.allocator = arena, arena, arena
	b.unions.allocator, b.customs.allocator, b.rule_sets.allocator, b.leaves.allocator = arena, arena, arena, arena
	b.programs = make(rules.Programs, 16, scratch) or_return
	b.type_cache = make(map[typeid]i32, 32, scratch) or_return

	if reg != nil {
		for c in reg.customs { append(&b.customs, c) or_return }
	}
	p.root = compile_type_node(&b, type_info_of(T))
	if b.err != nil { return p, b.err }
	p.nodes, p.structs, p.enums, p.unions = b.nodes[:], b.structs[:], b.enums[:], b.unions[:]
	p.customs, p.rule_sets, p.leaves = b.customs[:], b.rule_sets[:], b.leaves[:]
	if ferr := finalize_stream_plan(&p, arena); ferr != nil { return p, ferr }
	return p, nil
}

@(private)
compile_rule_leaf :: proc(b: ^Plan_Builder, r: rules.Rules, ti: ^runtime.Type_Info) -> i32 {
	if r == {} { return 0 }
	cloned, cerr := clone_rules(r, b.arena)
	if cerr != nil { b.err = cerr; return 0 }
	dummy := rules.Node{kinds = rules.EVERY_KIND, rules = cloned, array = -1, object = -1}
	leaf, refused := rules.leaf_of(&dummy, {}, b.arena, &b.programs, b.scratch)
	if refused != "" { b.err = Model_Error{kind = .Bad_Tag, want = {ti.id if ti != nil else nil, refused}}; return 0 }
	if !b_push(b, &b.rule_sets, cloned) || !b_push(b, &b.leaves, leaf) { return 0 }
	return i32(len(b.rule_sets))
}

@(private)
clone_rules :: proc(r: rules.Rules, a: runtime.Allocator) -> (out: rules.Rules, err: runtime.Allocator_Error) {
	out = r
	if len(r.minimum) > 0     { out.minimum = strings.clone(r.minimum, a) or_return }
	if len(r.maximum) > 0     { out.maximum = strings.clone(r.maximum, a) or_return }
	if len(r.multiple_of) > 0 { out.multiple_of = strings.clone(r.multiple_of, a) or_return }
	if len(r.pattern) > 0     { out.pattern = strings.clone(r.pattern, a) or_return }
	if len(r.format) > 0      { out.format = strings.clone(r.format, a) or_return }
	return out, nil
}

@(private)
collect_type_rules :: proc(b: ^Plan_Builder, ti: ^runtime.Type_Info, mr: ^Member_Rule) -> bool {
	subject := subject_of(ti, b.reg)
	for cur := ti; cur != nil; cur = held_type(cur) {
		carrier := carried(b.reg, cur.id)
		if c, is_c := carrier_of(carrier); is_c && !read_tag(c.tag, subject, false, mr, b.scratch) { return false }
		if b.reg != nil {
			for x in b.reg.types {
				if (x.type == cur.id || x.type == carrier) && !read_tag(x.tag, subject, false, mr, b.scratch) { return false }
			}
		}
	}
	return true
}

@(private)
compile_type_node :: proc(b: ^Plan_Builder, ti: ^runtime.Type_Info) -> i32 {
	if b.err != nil || ti == nil { return -1 }
	if existing, ok := b.type_cache[ti.id]; ok { return existing }

	idx := i32(len(b.nodes))
	if !b_push(b, &b.nodes, Type_Node{type = ti.id, ti = ti, size = ti.size, align = ti.align, child = -1, key_node = -1, struct_idx = -1, enum_idx = -1, union_idx = -1, custom_idx = -1, elem_field_idx = -1}) { return -1 }
	if _, merr := map_insert(&b.type_cache, ti.id, idx); merr != nil { b.err = merr; return idx }

	type_mr: Member_Rule
	if !collect_type_rules(b, ti, &type_mr) { b.err = Model_Error{kind = .Bad_Tag, want = {ti.id, type_mr.refused}}; return idx }
	if type_mr.rules != {} {
		ridx := compile_rule_leaf(b, type_mr.rules, ti)
		if b.err != nil { return idx }
		b.nodes[idx].rule_idx, b.nodes[idx].has_unique = ridx, type_mr.rules.unique
	}

	for &c, ci in b.customs {
		if c.type == ti.id {
			cidx := compile_type_node(b, type_info_of(c.carrier))
			if b.err == nil { b.nodes[idx].kind, b.nodes[idx].custom_idx, b.nodes[idx].child = .Custom, i32(ci), cidx }
			return idx
		}
	}
	if ck := builtin_carrier_kind(ti); ck != .Invalid { b.nodes[idx].kind = ck; return idx }

	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case ^runtime.Type_Info_String:  b.nodes[idx].kind = .Cstring if v.is_cstring else .String
	case ^runtime.Type_Info_Boolean: b.nodes[idx].kind = .Bool if base.size == 1 else .Bool_Wide
	case ^runtime.Type_Info_Integer:
		if v.endianness == .Platform || v.endianness == (.Little if ODIN_ENDIAN == .Little else .Big) {
			switch base.size {
			case 1: b.nodes[idx].kind = .I8 if v.signed else .U8
			case 2: b.nodes[idx].kind = .I16 if v.signed else .U16
			case 4: b.nodes[idx].kind = .I32 if v.signed else .U32
			case 8: b.nodes[idx].kind = .I64 if v.signed else .U64
			}
		}
	case ^runtime.Type_Info_Float:
		if v.endianness == .Platform && (base.size == 4 || base.size == 8) {
			b.nodes[idx].kind = .F32 if base.size == 4 else .F64
		}
	case ^runtime.Type_Info_Slice:
		if v.elem.id == u8 && base.id == []u8 { b.nodes[idx].kind = .Bytes } else {
			child := compile_type_node(b, v.elem)
			b.nodes[idx].kind, b.nodes[idx].child = .Slice, child
		}
	case ^runtime.Type_Info_Dynamic_Array:
		child := compile_type_node(b, v.elem)
		b.nodes[idx].kind, b.nodes[idx].child = .Dynamic, child
	case ^runtime.Type_Info_Array:
		child := compile_type_node(b, v.elem)
		b.nodes[idx].kind, b.nodes[idx].child, b.nodes[idx].count = .Array, child, v.count
	case ^runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		child := compile_type_node(b, v.elem)
		b.nodes[idx].kind, b.nodes[idx].child, b.nodes[idx].count, b.nodes[idx].len_offset = .Fixed_List, child, v.capacity, v.len_offset
	case ^runtime.Type_Info_Pointer:
		if v.elem == nil { b.err = Model_Error{kind = .Unsupported, want = {ti.id, "rawptr"}}; return idx }
		child := compile_type_node(b, v.elem)
		b.nodes[idx].kind, b.nodes[idx].child = .Ptr, child
	case ^runtime.Type_Info_Map:
		kn, vn := compile_type_node(b, v.key), compile_type_node(b, v.value)
		if b.err != nil { return idx }
		kk := b.nodes[kn].kind
		if kk != .String && kk != .Cstring && kk != .Enum && !(kk >= .I8 && kk <= .U64) {
			b.err = Model_Error{kind = .Unsupported, want = {ti.id, "map key"}}; return idx
		}
		b.nodes[idx].kind, b.nodes[idx].key_node, b.nodes[idx].child = .Map, kn, vn
	case ^runtime.Type_Info_Enum:
		eidx := compile_enum(b, ti, v^)
		b.nodes[idx].kind, b.nodes[idx].enum_idx = .Enum, eidx
	case ^runtime.Type_Info_Bit_Set:
		b.nodes[idx].kind, b.nodes[idx].bit_lower, b.nodes[idx].count = .Bit_Set, v.lower, int(v.upper - v.lower + 1)
		if e, is_enum := runtime.type_info_base(v.elem).variant.(^runtime.Type_Info_Enum); is_enum {
			b.nodes[idx].enum_idx = compile_enum(b, v.elem, e^)
		}
	case ^runtime.Type_Info_Union:
		tag_sz := v.tag_type.size if v.tag_type != nil else 0
		if len(v.variants) == 1 && !v.no_nil {
			child := compile_type_node(b, v.variants[0])
			b.nodes[idx].kind, b.nodes[idx].child, b.nodes[idx].tag_offset, b.nodes[idx].tag_size = .Maybe, child, v.tag_offset, tag_sz
			b.nodes[idx].pure_maybe = reflect.type_info_union_is_pure_maybe(v^)
		} else {
			uidx := compile_union(b, ti, v^)
			b.nodes[idx].kind, b.nodes[idx].union_idx, b.nodes[idx].no_nil, b.nodes[idx].tag_offset, b.nodes[idx].tag_size = .Union, uidx, v.no_nil, v.tag_offset, tag_sz
		}
	case ^runtime.Type_Info_Struct:
		if v.soa_kind != .None || .raw_union in v.flags { b.err = Model_Error{kind = .Unsupported, want = {ti.id, "raw_union/soa"}}; return idx }
		sidx := compile_struct(b, ti, v^)
		b.nodes[idx].kind, b.nodes[idx].struct_idx = .Struct, sidx
	}
	if b.nodes[idx].kind == .Invalid && b.err == nil { b.err = Model_Error{kind = .Unsupported, want = {ti.id, type_name_short(ti)}} }
	return idx
}

@(private)
compile_enum :: proc(b: ^Plan_Builder, ti: ^runtime.Type_Info, v: runtime.Type_Info_Enum) -> i32 {
	for e, i in b.enums { if e.type == ti.id { return i32(i) } }
	names, nerr := make([]string, len(v.names), b.arena)
	vals, verr := make([]i64, len(v.values), b.arena)
	if nerr != nil || verr != nil { b.err = nerr if nerr != nil else verr; return -1 }
	for name, i in v.names { names[i], vals[i] = name, i64(v.values[i]) }
	by_name := true
	if b.reg != nil {
		en_err: runtime.Allocator_Error
		by_name, en_err = enum_names(b.reg, ti.id, names, b.arena)
		if en_err != nil { b.err = en_err; return -1 }
	}
	if by_name {
		for i in 0 ..< len(names) {
			for j in i + 1 ..< len(names) {
				if names[i] == names[j] { b.err = Model_Error{kind = .Bad_Tag, want = {ti.id, names[i]}}; return -1 }
			}
		}
	}
	base_iv, _ := runtime.type_info_base(v.base).variant.(^runtime.Type_Info_Integer)
	eidx := i32(len(b.enums))
	if !b_push(b, &b.enums, Enum_Info{ti.id, runtime.type_info_base(ti).variant.(^runtime.Type_Info_Enum), by_name, base_iv != nil && !base_iv.signed, names, vals}) { return -1 }
	return eidx
}

@(private)
compile_union :: proc(b: ^Plan_Builder, ti: ^runtime.Type_Info, v: runtime.Type_Info_Union) -> i32 {
	mode, tag_key := union_rule_of(b.reg, ti.id)
	arms, aerr := make([]Union_Arm, len(v.variants), b.arena)
	if aerr != nil { b.err = aerr; return -1 }
	for arm_ti, i in v.variants {
		arm_node := compile_type_node(b, arm_ti)
		if b.err != nil { return -1 }
		arm_name := ""
		if named, ok := arm_ti.variant.(^runtime.Type_Info_Named); ok { arm_name = named.name }
		_, is_st := runtime.type_info_base(arm_ti).variant.(^runtime.Type_Info_Struct)
		arms[i] = {arm_name, i64(i) if v.no_nil else i64(i + 1), arm_node, is_st}
	}
	uidx := i32(len(b.unions))
	tag_cp := ""
	if len(tag_key) > 0 {
		cerr: runtime.Allocator_Error
		tag_cp, cerr = strings.clone(tag_key, b.arena)
		if cerr != nil { b.err = cerr; return -1 }
	}
	if !b_push(b, &b.unions, Union_Info{ti.id, mode, tag_cp, v.no_nil, v.tag_offset, v.tag_type.size if v.tag_type != nil else 0, arms}) { return -1 }
	return uidx
}

@(private)
compile_struct :: proc(b: ^Plan_Builder, ti: ^runtime.Type_Info, v: runtime.Type_Info_Struct) -> i32 {
	sidx := i32(len(b.structs))
	sname := ""
	if named, ok := ti.variant.(^runtime.Type_Info_Named); ok { sname = named.name }
	if !b_push(b, &b.structs, Struct_Info{type = ti.id, name = sname, capture_idx = -1, capture_node = -1, forbid_extra = forbids_extra(b.reg, ti.id)}) { return -1 }

	fields_list, ferr := make([dynamic]Field_Info, 0, int(v.field_count), b.arena)
	if ferr != nil { b.err = ferr; return sidx }
	collect_struct_fields(b, ti, ti, v, 0, &fields_list, sidx)
	if b.err != nil { return sidx }

	fields := fields_list[:]
	slots: []u32
	if len(fields) > 0 {
		cap_slots := 8
		for cap_slots < 2 * len(fields) { cap_slots <<= 1 }
		slots_buf, serr := make([]u32, cap_slots, b.arena)
		if serr != nil { b.err = serr; return sidx }
		mask := u32(cap_slots - 1)
		for f, fi in fields {
			h := tape.text_hash(transmute([]u8)f.name) & mask
			for slots_buf[h] != 0 {
				if fields[slots_buf[h] - 1].name == f.name { b.err = Model_Error{kind = .Bad_Tag, pointer = f.odin_name, want = {ti.id, f.name}}; return sidx }
				h = (h + 1) & mask
			}
			slots_buf[h] = u32(fi + 1)
		}
		slots = slots_buf
	}

	svals := make([dynamic]Validator, b.arena)
	if b.reg != nil {
		for x in b.reg.validators {
			if x.type == ti.id && len(x.field) == 0 && !b_push(b, &svals, x.v) { return sidx }
		}
	}
	b.structs[sidx].fields, b.structs[sidx].slots, b.structs[sidx].validators = fields, slots, svals[:]
	return sidx
}

@(private)
collect_struct_fields :: proc(b: ^Plan_Builder, owner_ti, ti: ^runtime.Type_Info, v: runtime.Type_Info_Struct, base_offset: uintptr, fields_list: ^[dynamic]Field_Info, sidx: i32) {
	for i in 0 ..< int(v.field_count) {
		fname := v.names[i]
		if fname == "_" { continue }
		fti, ftag, foff := v.types[i], v.tags[i], base_offset + v.offsets[i]
		fmt_tag := parse_format_tag(ftag, b.tag)
		if fmt_tag.skip { continue }

		// H5: Flatten `using` embedded structs!
		if v.usings[i] {
			if emb, is_emb := runtime.type_info_base(fti).variant.(^runtime.Type_Info_Struct); is_emb && emb.soa_kind == .None && .raw_union not_in emb.flags && builtin_carrier_kind(fti) == .Invalid {
				collect_struct_fields(b, owner_ti, fti, emb^, foff, fields_list, sidx)
				if b.err != nil { return }
				continue
			}
		}
		if fti.id == Fields_Set {
			if b.structs[sidx].has_fields_set { b.err = Model_Error{kind = .Bad_Tag, pointer = fname, want = {owner_ti.id, "Fields_Set"}}; return }
			b.structs[sidx].has_fields_set, b.structs[sidx].fields_set_offset = true, foff
			continue
		}
		if fmt_tag.unknown {
			m_info, is_map := runtime.type_info_base(fti).variant.(^runtime.Type_Info_Map)
			if b.structs[sidx].forbid_extra || b.structs[sidx].capture_idx >= 0 || !is_map || runtime.type_info_base(m_info.key).id != string {
				b.err = Model_Error{kind = .Bad_Tag, pointer = fname, want = {owner_ti.id, "unknown"}}; return
			}
			cnode := compile_type_node(b, fti)
			if b.err != nil { return }
			b.structs[sidx].capture_idx, b.structs[sidx].capture_offset, b.structs[sidx].capture_node, b.structs[sidx].capture_name = i32(i), foff, cnode, fname
			continue
		}

		wire_name := fname
		if fmt_tag.has_name {
			cerr: runtime.Allocator_Error
			wire_name, cerr = strings.clone(fmt_tag.name, b.arena)
			if cerr != nil { b.err = cerr; return }
		} else if b.reg != nil && b.reg.naming.fields != .None {
			rerr: runtime.Allocator_Error
			wire_name, rerr = rename_text(fname, b.reg.naming.fields, b.arena)
			if rerr != nil { b.err = rerr; return }
		}

		fnode := compile_type_node(b, fti)
		if b.err != nil { return }

		mr: Member_Rule
		subject := subject_of(fti, b.reg)
		if !collect_type_rules(b, fti, &mr) { b.err = Model_Error{kind = .Bad_Tag, pointer = fname, want = {owner_ti.id, mr.refused}}; return }
		if b.reg != nil {
			for x in b.reg.fields {
				if (x.type == owner_ti.id || x.type == ti.id) && x.field == fname && !read_tag(x.tag, subject, true, &mr, b.scratch) {
					b.err = Model_Error{kind = .Bad_Tag, pointer = fname, want = {owner_ti.id, mr.refused}}; return
				}
			}
		}
		if model_tag, has_mtag := tag_lookup(ftag, "model"); has_mtag && !read_tag(model_tag, subject, true, &mr, b.scratch, swallows = true) {
			b.err = Model_Error{kind = .Bad_Tag, pointer = fname, want = {owner_ti.id, mr.refused}}; return
		}
		if fmt_tag.required && mr.access == .Read_Only { b.err = Model_Error{kind = .Bad_Tag, pointer = fname, want = {owner_ti.id, "required"}}; return }

		has_def := false
		var_make: Make_Default
		var_data: rawptr
		for d in b.defaults {
			if (d.type == owner_ti.id || d.type == ti.id) && d.field == fname { has_def, var_make, var_data = true, d.make, d.data }
		}
		bf, has_bf := before_of(b.reg, owner_ti.id, fname)
		if !has_bf && ti.id != owner_ti.id { bf, has_bf = before_of(b.reg, ti.id, fname) }

		afters_dyn := make([dynamic]Validator, b.arena)
		if b.reg != nil {
			for x in b.reg.validators {
				if (x.type == owner_ti.id || x.type == ti.id) && x.field == fname && !b_push(b, &afters_dyn, x.v) { return }
			}
		}
		ridx := compile_rule_leaf(b, mr.rules, fti)
		if b.err != nil { return }

		is_optional := (mr.optional || has_def) && !fmt_tag.required
		if !b_push(b, fields_list, Field_Info{
			odin_name = fname, name = wire_name, offset = foff, node = fnode, rule_idx = ridx,
			has_unique = mr.rules.unique, access = mr.access, optional = is_optional,
			required = (fmt_tag.required || !is_optional) && mr.access != .Read_Only,
			not_null = mr.not_null, omit_empty = fmt_tag.omit_empty, omit_unset = fmt_tag.omit_unset,
			has_default = has_def, make_default = var_make, default_data = var_data,
			has_before = has_bf, before = bf, afters = afters_dyn[:],
		}) { return }
	}
}

@(private)
struct_find_field :: proc "contextless" (s: ^Struct_Info, name: string) -> int {
	if len(s.slots) == 0 { return -1 }
	mask := u32(len(s.slots) - 1)
	for h := tape.text_hash(transmute([]u8)name) & mask; ; h = (h + 1) & mask {
		k := s.slots[h]
		if k == 0 { return -1 }
		if s.fields[k - 1].name == name { return int(k - 1) }
	}
}

@(private)
find_struct_info :: proc "contextless" (plan: ^Type_Plan, S: typeid) -> ^Struct_Info {
	for &s in plan.structs { if s.type == S { return &s } }
	return nil
}

@(private)
is_clean_ascii_key :: proc "contextless" (name: string) -> bool {
	for c in transmute([]u8)name {
		if c < 0x20 || c >= 0x80 || c == '"' || c == '\\' { return false }
	}
	return true
}

@(private)
set_expected_key :: proc "contextless" (e: ^hook.Expected_Key, name: string) {
	n := len(name)
	for c in transmute([]u8)name {
		if c == '"' || c == '\\' || c < 0x20 { e^ = {word = NO_KEY}; return }
	}
	e.word = tape.key_word(u64(n))
	e.head, e.tail = 0, 0
	for i in 0 ..< min(n, 8) { e.head |= u64(name[i]) << (8 * uint(i)) }
	if n <= 8 {
		e.tail = ~u64(0) >> (64 - 8 * uint(n)) if n > 0 else 0
		return
	}
	for i in 0 ..< 8 { e.tail |= u64(name[n - 8 + i]) << (8 * uint(i)) }
}

@(private)
finalize_stream_plan :: proc(p: ^Type_Plan, arena: runtime.Allocator) -> runtime.Allocator_Error {
	p.can_stream = true
	keys_buf := make([dynamic]u8, 0, 256, arena) or_return
	elem_buf := make([dynamic]Stream_Field, 0, 16, arena) or_return

	for &tn in p.nodes {
		if tn.kind == .Union || tn.kind == .Value || tn.kind == .Custom || tn.kind == .Bit_Set || tn.kind == .Raw || tn.has_unique || tn.judged {
			p.can_stream = false
		}
		if tn.child >= 0 {
			ctn := &p.nodes[tn.child]
			tn.elem_field_idx = i32(len(elem_buf))
			append(&elem_buf, Stream_Field{
				expected   = {word = NO_KEY},
				node       = tn.child,
				rule_idx   = ctn.rule_idx,
				struct_idx = ctn.struct_idx,
				flags      = {.Is_Elem},
				kind       = ctn.kind,
			}) or_return
		}
	}

	for &si in p.structs {
		if si.capture_idx >= 0 { p.can_stream = false }
		if len(si.validators) > 0 { p.has_validators = true }
		sfs := make([]Stream_Field, len(si.fields) + 1, arena) or_return
		for &f, fi in si.fields {
			ftn := &p.nodes[f.node]
			if f.has_before || f.has_unique { p.can_stream = false }
			if len(f.afters) > 0 { si.has_field_afters = true; p.has_validators = true }
			if f.access == .Write_Only || f.omit_empty || f.omit_unset { si.has_omit_tag = true }
			if f.optional { si.has_optional = true }

			sf := Stream_Field{
				expected   = {word = NO_KEY},
				node       = f.node,
				rule_idx   = f.rule_idx if f.rule_idx > 0 else ftn.rule_idx,
				offset     = u32(f.offset),
				struct_idx = ftn.struct_idx,
				field_idx  = u16(fi),
				kind       = ftn.kind,
			}
			if f.access == .Read_Only  { sf.flags += {.Read_Only} }
			if f.access == .Write_Only { sf.flags += {.Write_Only} }
			if f.optional              { sf.flags += {.Optional} }
			if f.required              { sf.flags += {.Required} }
			if f.not_null              { sf.flags += {.Not_Null} }
			if f.omit_empty            { sf.flags += {.Omit_Empty} }
			if f.omit_unset            { sf.flags += {.Omit_Unset} }
			if len(f.afters) > 0       { sf.flags += {.Has_After} }
			if f.has_default {
				sf.flags += {.Has_Default}
				if !default_is_zero(f.make_default, f.default_data) {
					sf.flags += {.Nonzero_Default}
					if fi < 64 { si.def_mask0 |= u64(1) << uint(fi) } else { si.has_def_hi = true }
				}
			}
			if f.required {
				if fi < 64 { si.req_mask0 |= u64(1) << uint(fi) } else { si.has_req_hi = true }
			}
			if f.access != .Read_Only {
				set_expected_key(&sf.expected, f.name)
			}
			if len(f.name) + 3 <= int(max(u8)) && len(keys_buf) <= int(max(u16)) && is_clean_ascii_key(f.name) {
				off := len(keys_buf)
				append(&keys_buf, '"') or_return
				append(&keys_buf, ..transmute([]u8)f.name) or_return
				append(&keys_buf, '"', ':') or_return
				sf.key_off = u16(off)
				sf.key_size = u8(len(f.name) + 3)
			}
			sfs[fi] = sf
		}
		sfs[len(si.fields)] = Stream_Field{expected = {word = NO_KEY}, node = -1, struct_idx = -1, kind = .Invalid}
		si.stream_fields = sfs
	}

	if len(elem_buf) > 0 {
		append(&elem_buf, Stream_Field{expected = {word = NO_KEY}, node = -1, struct_idx = -1, kind = .Invalid}) or_return
	}
	if len(keys_buf) > 0 {
		pad: [16]u8
		append(&keys_buf, ..pad[:]) or_return
	}
	p.json_keys = keys_buf[:]
	p.elem_fields = elem_buf[:]
	p.dump_hint = estimate_dump_size(p, p.root, 0)

	rtn := &p.nodes[p.root]
	p.root_field = Stream_Field{
		expected   = {word = NO_KEY},
		node       = p.root,
		rule_idx   = rtn.rule_idx,
		struct_idx = rtn.struct_idx,
		flags      = {.Is_Root},
		kind       = rtn.kind,
	}
	return nil
}

@(private)
estimate_dump_size :: proc(p: ^Type_Plan, node_idx: i32, depth: int) -> int {
	if node_idx < 0 || depth > 8 { return 32 }
	tn := &p.nodes[node_idx]
	#partial switch tn.kind {
	case .Struct:
		si := &p.structs[tn.struct_idx]
		est := 2
		for f in si.fields {
			if f.access == .Write_Only { continue }
			est += len(f.name) + 4 + estimate_dump_size(p, f.node, depth + 1)
		}
		return est
	case .String, .Email, .Cstring: return 32
	case .I8 ..= .F64:              return 12
	case .Bool, .Bool_Wide:         return 6
	case .Maybe, .Ptr:              return estimate_dump_size(p, tn.child, depth + 1)
	}
	return 64
}

// Estimated compact JSON byte size for initial output buffer sizing.
dump_size_hint :: proc "contextless" (m: ^Model($T)) -> int {
	return m.plan.dump_hint if m != nil else 0
}
