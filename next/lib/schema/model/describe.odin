// Reflects a compiled `Model(T)` into a `rules.Description` consumable by `check.compile` and schema writers.
package model

import "base:runtime"
import "core:mem"
import "core:strconv"
import "core:strings"
import "stury:lib/schema/rules"

Direction :: enum u8 { Load, Dump }

@(require_results)
schema :: proc(m: ^Model($T), direction: Direction, allocator := context.allocator) -> (rules.Description, Error) {
	return describe(&m.plan, direction, allocator, m.judging)
}

@(private)
describe :: proc(plan: ^Type_Plan, direction: Direction, allocator: runtime.Allocator, judging: ^Applied = nil) -> (d: rules.Description, err: Error) {
	if plan == nil || plan.root < 0 || int(plan.root) >= len(plan.nodes) { return d, Model_Error{kind = .Bad_Option, want = {text = "plan"}} }
	init_desc(&d, allocator) or_return
	scratch_arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&scratch_arena, allocator, allocator); defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)
	r := Reading{plan, &d, make(map[Desc_Use]rules.Node_Index, 32, scratch), make(map[i32]i32, 32, scratch), false, direction, judging, allocator, scratch}
	d.root = desc_node_of(&r, plan.root, true, false, {})
	if r.failed { rules.description_destroy(&d); return {}, runtime.Allocator_Error.Out_Of_Memory }
	return d, nil
}

@(private)
Reading :: struct { plan: ^Type_Plan, d: ^rules.Description, nodes: map[Desc_Use]rules.Node_Index, shapes: map[i32]i32, failed: bool, direction: Direction, judging: ^Applied, allocator, scratch: runtime.Allocator }
@(private)
Desc_Use :: struct { node: i32, nullable, not_null: bool, rule_idx: i32 }
@(private)
Arm_Tag :: struct { member, name: string }

@(private, rodata)
LIMITS := [8][2]string{
	{"-128", "127"}, {"-32768", "32767"}, {"-2147483648", "2147483647"}, {"-9223372036854775808", "9223372036854775807"},
	{"0", "255"}, {"0", "65535"}, {"0", "4294967295"}, {"0", "18446744073709551615"},
}
@(private)
F32_PAST :: "340282356779733661637539395458142568448"
@(private)
F64_PAST :: "179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497792"

@(private)
unwrap_node :: proc(plan: ^Type_Plan, idx: i32, not_null: bool) -> (target: i32, nullable: bool) {
	cur := idx
	for cur >= 0 {
		tn := &plan.nodes[cur]
		if tn.kind == .Maybe || tn.kind == .Ptr { nullable ||= !not_null; cur = tn.child; continue }
		break
	}
	return cur, nullable
}

@(private)
desc_node_of :: proc(r: ^Reading, idx: i32, ruled, arm: bool, tag: Arm_Tag, not_null := false) -> rules.Node_Index {
	at, nullable := unwrap_node(r.plan, idx, not_null); nullable &&= !arm
	tn := &r.plan.nodes[at]; takes_null := nullable || (tn.kind == .Union && !tn.no_nil); ridx := tn.rule_idx if ruled else 0
	use := Desc_Use{at, takes_null, not_null, ridx}
	if found, ok := r.nodes[use]; ok && tag.member == "" { return found }

	index := desc_add(r, &r.d.nodes, rules.Node{array = -1, object = -1})
	if tag.member == "" { if _, ferr := map_insert(&r.nodes, use, index); ferr != nil { r.failed = true } }
	if r.failed { return 0 }

	n := rules.Node{array = -1, object = -1}
	#partial switch tn.kind {
	case .Slice, .Dynamic, .Array, .Fixed_List, .Bit_Set:
		n.kinds, n.array = {.Array}, desc_array_of(r, at)
		if tn.kind == .Array { n.rules.min_items, n.rules.max_items = u64(tn.count), u64(tn.count) } else if tn.kind == .Fixed_List { n.rules.max_items = u64(tn.count) }
	case .Map:    n.kinds, n.object = {.Object}, desc_map_of(r, at)
	case .Struct: n.kinds, n.object = {.Object}, desc_struct_of(r, tn.struct_idx, tag)
	case .Union:
		n.kinds = rules.EVERY_KIND; u := &r.plan.unions[tn.union_idx]; arms := desc_arms_of(r, u, takes_null)
		if len(arms) == 1 { n.ref = arms[0]; delete(arms, r.allocator) } else if u.mode == .One_Match || one_match(r.judging, tn.type) { n.one_of = arms } else { n.any_of = arms }
	case .Custom:
		cidx := desc_node_of(r, tn.child, true, false, {})
		if !r.failed {
			n = r.d.nodes[cidx]
			for s in ([?]^[]rules.Node_Index{&n.any_of, &n.all_of, &n.one_of}) { if len(s^) > 0 { s^ = clone_slice(s^, r.allocator, &r.failed) } }
			for s in ([?]^[]rules.Value{&n.enum_of, &n.examples}) { if len(s^) > 0 { s^ = clone_slice(s^, r.allocator, &r.failed) } }
		}
	case: n = desc_leaf(r, tn, not_null)
	}

	if nullable { n.kinds += {.Null} }
	if ridx > 0 { n.rules, _ = rules.merged(&n, r.plan.rule_sets[ridx - 1]) }
	if r.judging != nil {
		fragments, ferr := fragments_of(r.judging, r.d, tn.type); r.failed ||= ferr != nil
		if len(fragments) > 0 {
			if len(n.all_of) > 0 {
				combined, cerr := make([]rules.Node_Index, len(n.all_of) + len(fragments), r.allocator)
				if cerr != nil { r.failed = true } else { copy(combined, n.all_of); copy(combined[len(n.all_of):], fragments); delete(n.all_of, r.allocator); delete(fragments, r.allocator); n.all_of = combined }
			} else { n.all_of = fragments }
		}
	}
	r.d.nodes[index] = n
	if tn.kind == .Struct && tn.struct_idx >= 0 {
		if sname := r.plan.structs[tn.struct_idx].name; len(sname) > 0 { if _, merr := map_insert(&r.d.names, index, desc_keep(r, sname)); merr != nil { r.failed = true } }
	}
	return index
}

@(private)
desc_leaf :: proc(r: ^Reading, tn: ^Type_Node, not_null: bool) -> (n: rules.Node) {
	n.array, n.object = -1, -1
	#partial switch tn.kind {
	case .String, .Bytes, .Email, .Time, .Uuid: n.kinds = {.String}
	case .Cstring:                              n.kinds = {.String} if not_null else {.String, .Null}
	case .Bool, .Bool_Wide:                     n.kinds = {.Bool}
	case .I8 ..= .U64:                          lim := LIMITS[int(tn.kind) - int(Type_Kind.I8)]; n.kinds, n.rules.minimum, n.rules.maximum = {.Integer}, lim[0], lim[1]
	case .F32:         n.kinds, n.rules = {.Number}, {minimum = "-" + F32_PAST, maximum = F32_PAST, exclusive_minimum = true, exclusive_maximum = true}
	case .F64:         n.kinds, n.rules = {.Number}, {minimum = "-" + F64_PAST, maximum = F64_PAST, exclusive_minimum = true, exclusive_maximum = true}
	case .Number_Text: n.kinds = {.Number} if not_null else {.Number, .Null}
	case .Base64:      n.kinds, n.content_encoding = {.String}, "base64"
	case .Hex:         n.kinds, n.content_encoding = {.String}, "base16"
	case .Decimal:     n.kinds = {.Number, .String}
	case .Enum:
		if ei := &r.plan.enums[tn.enum_idx]; len(ei.values) == 0 { n.kinds = {} } else { n.kinds, n.enum_of, n.has_enum = {.String} if ei.by_name else {.Integer}, desc_enum_operands(r, ei), true }
	case: n.kinds = rules.EVERY_KIND
	}
	return
}

@(private)
desc_array_of :: proc(r: ^Reading, idx: i32) -> i32 {
	at, fresh := desc_shape(r, idx, &r.d.arrays, rules.Array{items = rules.NONE}); if !fresh { return at }
	tn := &r.plan.nodes[idx]; items: rules.Node_Index
	if tn.kind == .Bit_Set {
		elem := rules.Node{array = -1, object = -1}
		if tn.enum_idx >= 0 {
			if ei := &r.plan.enums[tn.enum_idx]; len(ei.values) > 0 { elem.kinds, elem.enum_of, elem.has_enum = {.String} if ei.by_name else {.Integer}, desc_enum_operands(r, ei), true }
		} else { elem.kinds, elem.rules.minimum, elem.rules.maximum = {.Integer}, desc_decimal(r, tn.bit_lower), desc_decimal(r, tn.bit_lower + i64(tn.count) - 1) }
		items = desc_add(r, &r.d.nodes, elem)
	} else { items = desc_node_of(r, tn.child, true, false, {}) }
	if !r.failed { r.d.arrays[at].items = items }
	return at
}

@(private)
desc_map_of :: proc(r: ^Reading, idx: i32) -> i32 {
	at, fresh := desc_shape(r, idx, &r.d.objects, rules.Object{additional = rules.NONE, keys = rules.NONE}); if !fresh { return at }
	tn := &r.plan.nodes[idx]; additional := desc_node_of(r, tn.child, true, false, {}); keys := rules.NONE
	if ktn := &r.plan.nodes[tn.key_node]; ktn.kind != .String && ktn.kind != .Cstring { keys = desc_add(r, &r.d.nodes, desc_key_node(r, ktn)) }
	if !r.failed { r.d.objects[at].additional, r.d.objects[at].keys = additional, keys }
	return at
}

@(private)
desc_struct_of :: proc(r: ^Reading, sidx: i32, tag: Arm_Tag) -> i32 {
	empty := rules.Object{additional = rules.NONE, keys = rules.NONE}
	at, fresh := i32(0), false
	if tag.member == "" { at, fresh = desc_shape(r, -1000 - sidx, &r.d.objects, empty) } else { at, fresh = i32(desc_add(r, &r.d.objects, empty)), !r.failed }
	if !fresh { return at }
	si := &r.plan.structs[sidx]
	members, merr := make([dynamic]rules.Member, 0, len(si.fields) + (1 if tag.member != "" else 0), r.allocator)
	if merr != nil { r.failed = true; return at }
	if tag.member != "" {
		named := desc_add(r, &r.d.nodes, rules.Node{kinds = rules.EVERY_KIND, const_of = rules.Value(tag.name), array = -1, object = -1})
		if _, aerr := append(&members, rules.Member{name = tag.member, node = named, required = true}); aerr != nil { r.failed = true }
	}
	for f in si.fields {
		if .Write_Only in f.flags && r.direction == .Dump { continue }
		x := rules.Member{name = f.name}
		if .Read_Only in f.flags && r.direction == .Load {
			x.node = desc_add(r, &r.d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1})
			if si.forbid_extra { x.node = desc_add(r, &r.d.nodes, rules.Node{kinds = rules.EVERY_KIND, not = x.node, array = -1, object = -1}) }
		} else {
			x.node = desc_node_of(r, f.node, false, false, {}, .Not_Null in f.flags)
			if f.rule_idx > 0 { x.rules = r.plan.rule_sets[f.rule_idx - 1] }
			x.required = .Required in f.flags
		}
		x.rules.read_only, x.rules.write_only = .Read_Only in f.flags, .Write_Only in f.flags
		if r.direction == .Dump { x.required = f.flags & {.Omit_Empty, .Omit_Unset} == {} }
		if _, aerr := append(&members, x); aerr != nil { r.failed = true }
	}
	r.d.objects[at].members = members[:]
	if si.capture_idx >= 0 { r.d.objects[at].additional = desc_node_of(r, r.plan.nodes[si.capture_node].child, true, false, {}) } else if si.forbid_extra && r.direction == .Load { r.d.objects[at].additional = desc_add(r, &r.d.nodes, rules.Node{array = -1, object = -1}) }
	return at
}

@(private)
desc_arms_of :: proc(r: ^Reading, u: ^Union_Info, takes_null: bool) -> []rules.Node_Index {
	arms, aerr := make([]rules.Node_Index, len(u.arms) + (1 if takes_null else 0), r.allocator)
	if aerr != nil { r.failed = true; return nil }
	for arm, k in u.arms { arms[k] = desc_node_of(r, arm.node, true, true, {u.tag_key, arm.name} if u.mode == .Tag && u.tag_key != "" && arm.is_struct && arm.name != "" else {}) }
	if takes_null && !r.failed { arms[len(u.arms)] = desc_add(r, &r.d.nodes, rules.Node{kinds = {.Null}, array = -1, object = -1}) }
	return arms
}

@(private)
desc_shape :: proc(r: ^Reading, key: i32, list: ^[dynamic]$T, empty: T) -> (at: i32, fresh: bool) {
	if found, ok := r.shapes[key]; ok { return found, false }
	at = i32(desc_add(r, list, empty)); if _, ferr := map_insert(&r.shapes, key, at); ferr != nil { r.failed = true }
	return at, !r.failed
}
@(private)
desc_enum_operands :: proc(r: ^Reading, ei: ^Enum_Info) -> []rules.Value {
	out, aerr := make([]rules.Value, len(ei.values), r.allocator); if aerr != nil { r.failed = true; return nil }
	for &o, k in out { o = rules.Value(ei.names[k]) if ei.by_name else (rules.Value(u64(ei.values[k])) if ei.is_unsigned else rules.Value(ei.values[k])) }
	return out
}
@(private)
desc_decimal :: proc(r: ^Reading, n: i64) -> string { buf: [24]u8 = ---; return desc_keep(r, strconv.write_int(buf[:], n, 10)) }
@(private)
desc_keep :: proc(r: ^Reading, s: string) -> string {
	text, err := strings.clone(s, r.allocator); if err != nil { r.failed = true; return "" }
	if _, aerr := append(&r.d.texts, text); aerr != nil { delete(text, r.allocator); r.failed = true; return "" }
	return text
}
@(private)
desc_add :: proc(r: ^Reading, list: ^[dynamic]$T, x: T) -> rules.Node_Index {
	if _, err := append(list, x); err != nil { r.failed = true; return 0 }
	return rules.Node_Index(len(list) - 1)
}
@(private)
clone_slice :: proc(xs: []$T, a: runtime.Allocator, failed: ^bool) -> []T {
	out, err := make([]T, len(xs), a); if err != nil { failed^ = true; return nil }; copy(out, xs); return out
}

@(private)
desc_key_node :: proc(r: ^Reading, ktn: ^Type_Node) -> (n: rules.Node) {
	n = desc_leaf(r, ktn, false); if n.kinds != {.Integer} { return }
	b, berr := strings.builder_make(0, 64, r.scratch); if berr != nil { r.failed = true; return }
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "^(?:")
	if n.has_enum {
		buf: [24]u8 = ---
		for v, i in n.enum_of {
			if i > 0 { strings.write_byte(&b, '|') }
			#partial switch num in v {
			case i64: strings.write_string(&b, strconv.write_int(buf[:], num, 10))
			case u64: strings.write_string(&b, strconv.write_uint(buf[:], num, 10))
			}
		}
		delete(n.enum_of, r.allocator); n.enum_of, n.has_enum = nil, false
	} else {
		lo, _ := strconv.parse_i128(n.rules.minimum); hi, _ := strconv.parse_i128(n.rules.maximum)
		if lo < 0 { strings.write_string(&b, "-(?:"); magnitudes(&b, u64(max(1, -hi)), u64(-lo)); strings.write_byte(&b, ')') }
		if hi >= 0 { if lo < 0 { strings.write_byte(&b, '|') }; magnitudes(&b, u64(max(lo, 0)), u64(hi)) }
	}
	strings.write_string(&b, ")$")
	n.kinds, n.rules = {.String}, {pattern = desc_keep(r, strings.to_string(b))}
	return
}

@(private)
magnitudes :: proc(b: ^strings.Builder, lo, hi: u64) {
	low, high: [20]u8 = ---, ---
	lo_text, hi_text := strconv.write_uint(low[:], lo, 10), strconv.write_uint(high[:], hi, 10)
	for width in len(lo_text) ..= len(hi_text) {
		if width > len(lo_text) { strings.write_byte(b, '|') }
		digit_range(b, lo_text if width == len(lo_text) else ONES_THEN_ZEROS[:width], hi_text if width == len(hi_text) else NINES[:width])
	}
}

@(private)
digit_range :: proc(b: ^strings.Builder, lo, hi: string) {
	if lo == hi { strings.write_string(b, lo); return }
	n := len(lo) - 1
	if lo[0] == hi[0] { strings.write_byte(b, lo[0]); digit_range(b, lo[1:], hi[1:]); return }
	from_z, to_9 := lo[1:] == ZEROS[:n], hi[1:] == NINES[:n]
	first, last := lo[0] + (0 if from_z else 1), hi[0] - (0 if to_9 else 1)
	strings.write_string(b, "(?:")
	if !from_z { strings.write_byte(b, lo[0]); digit_range(b, lo[1:], NINES[:n]) }
	if first <= last {
		if !from_z { strings.write_byte(b, '|') }
		strings.write_byte(b, '['); strings.write_byte(b, first); strings.write_byte(b, '-'); strings.write_byte(b, last); strings.write_byte(b, ']')
		for _ in 0 ..< n { strings.write_string(b, "[0-9]") }
	}
	if !to_9 { strings.write_byte(b, '|'); strings.write_byte(b, hi[0]); digit_range(b, ZEROS[:n], hi[1:]) }
	strings.write_byte(b, ')')
}

@(private, rodata)
NINES := "99999999999999999999"
@(private, rodata)
ZEROS := "00000000000000000000"
@(private, rodata)
ONES_THEN_ZEROS := "10000000000000000000"
