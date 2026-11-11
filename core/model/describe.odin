// Models: an Odin type with rules, read, checked and written by its plan.
package model

import "base:runtime"
import "core:strconv"
import "core:strings"
import core ".."
import rules "../rules"
import typed "../typed"

// Reads the description of the values `plan`, a type's plan, reads, allocating with `allocator`. A record's type gives
// one node, which every use of the type shares, and a `Maybe` or pointer a copy that also takes null and shares the
// node's blocks. A number's range is its node's `minimum` and `maximum`, a fixed array's length its item counts, a map's
// integer or enum keys its object's `keys`, a member's rules sit on its edge and a value's other rules on its node. The
// description borrows the plan's names, so the plan must outlive it. It describes what a load reads, or under `.Dump`
// what a write writes: a member is required unless it may be left out.
@(private)
describe :: proc(plan: ^typed.Plan, direction: Direction, allocator: runtime.Allocator, judging: ^Applied = nil) -> (d: rules.Description, err: core.Error) {
	context.allocator = allocator
	d.allocator = allocator
	d.names = make(map[rules.Node_Index]string, allocator)
	if plan.type == nil {
		return d, core.error_of(core.Typed_Refusal{kind = .Bad_Option})
	}
	r := Reading{plan = plan, d = &d, direction = direction, judging = judging}
	defer delete(r.nodes)
	defer delete(r.shapes)
	d.root = node_of(&r, 0)
	if r.failed {
		rules.description_destroy(&d)
		return d, runtime.Allocator_Error.Out_Of_Memory
	}
	return d, nil
}

@(private)
Reading :: struct {
	plan:   ^typed.Plan,
	d:      ^rules.Description,
	nodes:  map[Use]rules.Node_Index,
	shapes: map[i32]i32, // a list or struct block's array or object block in the description
	failed: bool,
	direction: Direction,
	judging: ^Applied, // the judged types whose fragments a node holds, nil for none
}

// What a description of a model describes: what a load reads or what a write writes. A load skips a read-only member,
// which its description then lets hold any value, and a write leaves out a write-only member, which its description then
// omits.
Direction :: enum {
	Load,
	Dump,
}

// The description of `m`'s values in `direction`, as `describe` reads it.
schema :: proc(m: ^Model($T), direction: Direction, allocator := context.allocator) -> (rules.Description, core.Error) {
	return describe(&m.plan, direction, allocator, m.judging)
}

@(private)
Use :: struct {
	type:     typeid,
	nullable: bool,
	rule_set: i32,
}

// What each integer kind holds, `I8` first.
@(private)
@(rodata)
LIMITS := [8][2]string {
	{"-128", "127"},
	{"-32768", "32767"},
	{"-2147483648", "2147483647"},
	{"-9223372036854775808", "9223372036854775807"},
	{"0", "255"},
	{"0", "65535"},
	{"0", "4294967295"},
	{"0", "18446744073709551615"},
}

// The least decimal that rounds to an f32 infinity, `2^128 - 2^103`.
@(private)
F32_PAST :: "340282356779733661637539395458142568448"

// The least decimal that rounds to an f64 infinity, `2^1024 - 2^970`.
@(private)
F64_PAST :: "179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497792"

// The record a value at record `at` is read by once its `Maybe`s and pointers are passed, and whether one of them
// takes null.
@(private)
target :: proc(plan: ^typed.Plan, at: i32) -> (i32, bool) {
	at, nullable := at, false
	for plan.fields[at].kind == .Maybe || plan.fields[at].kind == .Ptr {
		nullable ||= !plan.meta[at].no_nil
		at = plan.meta[at].block
	}
	return at, nullable
}

// The member a tagged union names a struct arm by, and the arm's name.
@(private)
Arm_Tag :: struct {
	member, name: string,
}

// The node of the value at `record`, with the record's rules unless they sit on the edge of the member it is. An arm
// takes no null of its own: the union reads null. A struct arm a union names by `tag` gets a node of its own, whose
// object requires the tag member and holds the arm's name in it.
@(private)
node_of :: proc(r: ^Reading, record: i32, ruled := true, arm := false, tag := Arm_Tag{}) -> rules.Node_Index {
	at, nullable := target(r.plan, record)
	nullable &&= !arm
	f, m := r.plan.fields[at], r.plan.meta[at]
	takes_null := nullable || f.kind == .Union && !m.no_nil
	use := Use{m.type, takes_null, m.rule_set if ruled else 0}
	if found, ok := r.nodes[use]; ok && tag.member == "" {
		return found
	}
	index := add(r, &r.d.nodes, rules.Node{array = -1, object = -1})
	if tag.member == "" {
		if _, failed := map_insert(&r.nodes, use, index); failed != nil {
			r.failed = true
		}
	}
	if r.failed {
		return 0
	}
	n := rules.Node{array = -1, object = -1}
	#partial switch f.kind {
	case .Slice, .Dynamic, .Array, .Fixed_List, .Bit_Set:
		n.kinds = {.Array}
		n.array = array_of(r, m)
		if f.kind == .Array {
			n.rules.min_items, n.rules.max_items = u64(m.count), u64(m.count)
		} else if f.kind == .Fixed_List {
			n.rules.max_items = u64(m.count)
		}
	case .Map, .Struct, .Required:
		n.kinds = {.Object}
		n.object = object_of(r, m, f.kind == .Map, tag)
	case .Union:
		n.kinds = rules.EVERY_KIND
		n.any_of = arms_of(r, at, takes_null)
		if len(n.any_of) == 1 {
			// One arm is the union's value itself.
			n.ref = n.any_of[0]
			delete(n.any_of)
			n.any_of = nil
		} else if one_match(r.judging, m.type) {
			n.one_of, n.any_of = n.any_of, nil
		}
	case:
		n = leaf(r, f.kind, m, typed.extra_at(r.plan, u32(at)).data)
	}
	if nullable {
		n.kinds += {.Null}
	}
	if use.rule_set > 0 {
		n.rules, _ = rules.merged(&n, r.plan.rule_sets[use.rule_set - 1])
	}
	if r.judging != nil {
		fragments, failed := fragments_of(r.judging, r.d, m.type)
		r.failed ||= failed != nil
		if len(fragments) > 0 {
			n.all_of = fragments
		}
	}
	r.d.nodes[index] = n
	if named, ok := type_info_of(m.type).variant.(runtime.Type_Info_Named); ok && f.kind == .Struct {
		r.d.names[index] = named.name
	}
	return index
}

// The node of a value `kind` reads, with the range of an integer, an f32, an enum read as integers and a bit_set's
// element. `m` is the record's, or a map's for its key.
@(private)
leaf :: proc(r: ^Reading, kind: typed.Read_Kind, m: typed.Meta, hook_data: rawptr) -> (n: rules.Node) {
	n.array, n.object = -1, -1
	#partial switch kind {
	case .String:
		n.kinds = {.String}
	case .Cstring:
		// A nil cstring reads from null and writes as null.
		n.kinds = {.String, .Null}
	case .Bool, .Bool_Wide:
		n.kinds = {.Bool}
	case .I8 ..= .U64:
		n.kinds = {.Integer}
		limits := LIMITS[u8(kind) - u8(typed.Read_Kind.I8)]
		n.rules.minimum, n.rules.maximum = limits[0], limits[1]
	case .F32:
		n.kinds = {.Number}
		n.rules = {minimum = "-" + F32_PAST, maximum = F32_PAST, exclusive_minimum = true, exclusive_maximum = true}
	case .F64:
		n.kinds = {.Number}
		n.rules = {minimum = "-" + F64_PAST, maximum = F64_PAST, exclusive_minimum = true, exclusive_maximum = true}
	case .Number:
		n.kinds = {.Number}
	case .Number_Text:
		// The empty text reads from null, unless the member is `not_null`.
		n.kinds = {.Number} if m.no_nil else {.Number, .Null}
	case .Scalar:
		n.kinds = {.Null, .Bool, .Number, .String}
	case .Enum, .Bit_Elem:
		by_name := m.enum_info != nil && !typed.enum_by_number(r.plan, m.enum_info)
		if m.enum_info != nil && (by_name || exact_values(m.enum_info)) {
			n.kinds = {.String} if by_name else {.Integer}
			n.enum_of, n.has_enum = enum_operands(r, m.enum_info, by_name), true
			break
		}
		n.kinds = {.Integer}
		low, high := m.lower, m.lower + i64(m.count) - 1
		if kind == .Enum {
			low, high = max(i64), min(i64)
			for v in m.enum_info.values {
				low, high = min(low, i64(v)), max(high, i64(v))
			}
		}
		n.rules.minimum, n.rules.maximum = decimal(r, low), decimal(r, high)
	case:
		n.kinds = rules.EVERY_KIND
		if kind == .Hook && hook_data != nil {
			return carrier_node(r, &(^Custom_Of)(hook_data).plan)
		}
		if c, is_carrier := carrier_of(m.type); kind == .Hook && is_carrier {
			n.kinds, n.content_encoding = c.kinds, c.encoding
		}
	}
	return
}

// The node of a custom's value: the root's of its carrier's plan, whose blocks it shares.
@(private)
carrier_node :: proc(r: ^Reading, plan: ^typed.Plan) -> rules.Node {
	sub := Reading{plan = plan, d = r.d, direction = r.direction}
	at := node_of(&sub, 0)
	delete(sub.nodes)
	delete(sub.shapes)
	r.failed ||= sub.failed
	return {array = -1, object = -1} if r.failed else r.d.nodes[at]
}

@(private)
array_of :: proc(r: ^Reading, m: typed.Meta) -> i32 {
	at, fresh := shape(r, m.block, &r.d.arrays, rules.Array{})
	if !fresh {
		return at
	}
	items: rules.Node_Index
	if r.plan.fields[m.block].kind == .Bit_Elem {
		items = add(r, &r.d.nodes, leaf(r, .Bit_Elem, r.plan.meta[m.block], nil))
	} else {
		items = node_of(r, m.block)
	}
	if r.failed {
		return at
	}
	r.d.arrays[at].items = items
	return at
}

@(private)
object_of :: proc(r: ^Reading, m: typed.Meta, is_map: bool, tag := Arm_Tag{}) -> i32 {
	empty := rules.Object{additional = rules.NONE, keys = rules.NONE}
	at, fresh := i32(0), false
	if tag.member == "" {
		at, fresh = shape(r, m.block, &r.d.objects, empty)
	} else {
		at, fresh = i32(add(r, &r.d.objects, empty)), !r.failed
	}
	if !fresh {
		return at
	}
	if is_map {
		additional := node_of(r, m.block)
		keys := rules.NONE
		if m.key_kind != .String && m.key_kind != .Cstring {
			keys = add(r, &r.d.nodes, key_node(r, m))
		}
		if !r.failed {
			r.d.objects[at].additional, r.d.objects[at].keys = additional, keys
		}
		return at
	}
	members, failed := make([dynamic]rules.Member, 0, m.members + (1 if tag.member != "" else 0))
	r.failed ||= failed != nil
	if tag.member != "" {
		named := add(r, &r.d.nodes, rules.Node{kinds = rules.EVERY_KIND, const_of = tag.name, array = -1, object = -1})
		append(&members, rules.Member{name = tag.member, node = named, required = true})
	}
	required := r.plan.meta[m.block + m.members].required
	forbids := typed.extra_at(r.plan, u32(m.block + m.members)).forbid
	for j in 0 ..< m.members {
		record := m.block + j
		role := typed.extra_at(r.plan, u32(record)).access
		if role == .Write_Only && r.direction == .Dump {
			continue
		}
		x := rules.Member{name = r.plan.meta[record].name}
		if role == .Read_Only && r.direction == .Load {
			// A load skips the member, so any value passes, or refuses it where the struct forbids what it does not name.
			x.node = add(r, &r.d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1})
			if forbids {
				x.node = add(r, &r.d.nodes, rules.Node{kinds = rules.EVERY_KIND, not = x.node, array = -1, object = -1})
			}
		} else {
			x.node = node_of(r, record, false)
			folded, _ := target(r.plan, record)
			if set := r.plan.meta[folded].rule_set; set > 0 {
				x.rules = r.plan.rule_sets[set - 1]
			}
			for k in required {
				x.required ||= k == j
			}
		}
		x.rules.read_only, x.rules.write_only = role == .Read_Only, role == .Write_Only
		// A dump with no option leaves out only what `omitempty` finds empty.
		if r.direction == .Dump {
			x.required = !typed.extra_at(r.plan, u32(record)).omit_empty
		}
		append(&members, x)
	}
	r.d.objects[at].members = members[:]
	if capture := r.plan.meta[m.block + m.members].capture; capture >= 0 {
		r.d.objects[at].additional = node_of(r, r.plan.meta[capture].block)
	} else if forbids && r.direction == .Load {
		r.d.objects[at].additional = add(r, &r.d.nodes, rules.Node{array = -1, object = -1})
	}
	return at
}

@(private)
arms_of :: proc(r: ^Reading, union_at: i32, null: bool) -> []rules.Node_Index {
	m := r.plan.meta[union_at]
	arms, failed := make([]rules.Node_Index, len(m.arms) + (1 if null else 0))
	r.failed ||= failed != nil
	for arm, k in m.arms {
		tag := Arm_Tag{typed.extra_at(r.plan, u32(union_at)).union_tag, arm.name} if m.tagged && arm.name != "" else {}
		// An arm's record holds the union's rules, with the arm type's own merged in when it has some.
		arms[k] = node_of(r, arm.fields, r.plan.meta[arm.fields].rule_set != m.rule_set, true, tag)
	}
	if null && !r.failed {
		arms[len(m.arms)] = add(r, &r.d.nodes, rules.Node{kinds = {.Null}, array = -1, object = -1})
	}
	return arms
}

// The description's block for the plan's block `block`, added to `list` as `empty` when it is new, and whether it was.
@(private)
shape :: proc(r: ^Reading, block: i32, list: ^[dynamic]$T, empty: T) -> (at: i32, fresh: bool) {
	if found, ok := r.shapes[block]; ok {
		return found, false
	}
	at = i32(add(r, list, empty))
	if _, failed := map_insert(&r.shapes, block, at); failed != nil {
		r.failed = true
	}
	return at, !r.failed
}

// Whether a binary64 holds each value of `e` exactly, as an enum operand does.
@(private)
exact_values :: proc(e: ^runtime.Type_Info_Enum) -> bool {
	for v in e.values {
		if i64(v) < -(1 << 53) || i64(v) > 1 << 53 {
			return false
		}
	}
	return true
}

// The operands of the enum `e`: its names, or its values. The names are the plan's and outlive the description.
@(private)
enum_operands :: proc(r: ^Reading, e: ^runtime.Type_Info_Enum, names: bool) -> []core.Value {
	out, failed := make([]core.Value, len(e.values))
	r.failed ||= failed != nil
	if failed == nil {
		for &o, k in out {
			o = e.names[k] if names else f64(i64(e.values[k]))
		}
	}
	return out
}

// The decimal text of `n`, which the description owns.
@(private)
decimal :: proc(r: ^Reading, n: i64) -> string {
	buf: [24]u8
	return keep(r, strconv.write_int(buf[:], n, 10))
}

// A copy of `s` the description owns.
@(private)
keep :: proc(r: ^Reading, s: string) -> string {
	text, failed := strings.clone(s)
	if _, no_room := append(&r.d.texts, text); failed != nil || no_room != nil {
		delete(text)
		r.failed = true
		return ""
	}
	return text
}

// Appends `x` to `list` and returns its index, with `r.failed` set when it could not.
@(private)
add :: proc(r: ^Reading, list: ^[dynamic]$T, x: T) -> rules.Node_Index {
	if _, failed := append(list, x); failed != nil {
		r.failed = true
		return 0
	}
	return rules.Node_Index(len(list) - 1)
}

// The node of a map's integer or enum key, which is a member name and so a string: an enum's names, or the decimals of
// the integers the key reads as, spelled as a key's number reads, by a pattern.
@(private)
key_node :: proc(r: ^Reading, m: typed.Meta) -> (n: rules.Node) {
	n = leaf(r, m.key_kind, m, nil)
	if n.kinds != {.Integer} {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "^(?:")
	if n.has_enum {
		for v, i in n.enum_of {
			buf: [24]u8
			strings.write_string(&b, "|" if i > 0 else "")
			strings.write_string(&b, strconv.write_int(buf[:], i64(v.(f64)), 10))
		}
		delete(n.enum_of)
		n.enum_of, n.has_enum = nil, false
	} else {
		lo, _ := strconv.parse_i128(n.rules.minimum)
		hi, _ := strconv.parse_i128(n.rules.maximum)
		if lo <= 0 {
			strings.write_string(&b, "-(?:")
			magnitudes(&b, u64(max(0, -hi)), u64(-lo))
			strings.write_string(&b, ")")
		}
		if hi >= 0 {
			strings.write_string(&b, "|" if lo <= 0 else "")
			magnitudes(&b, u64(max(lo, 0)), u64(hi))
		}
	}
	strings.write_string(&b, ")$")
	n.kinds, n.rules = {.String}, {pattern = keep(r, strings.to_string(b))}
	return
}

// Writes the alternatives of a pattern of the decimals from `lo` to `hi`, with no leading zero.
@(private)
magnitudes :: proc(b: ^strings.Builder, lo, hi: u64) {
	low, high: [20]u8
	lo_text, hi_text := strconv.write_uint(low[:], lo, 10), strconv.write_uint(high[:], hi, 10)
	for width in len(lo_text) ..= len(hi_text) {
		from := lo_text if width == len(lo_text) else ONES_THEN_ZEROS[:width]
		to := hi_text if width == len(hi_text) else NINES[:width]
		strings.write_string(b, "|" if width > len(lo_text) else "")
		digit_range(b, from, to)
	}
}

// Writes a pattern of the decimals from `lo` to `hi`, two texts of one length.
@(private)
digit_range :: proc(b: ^strings.Builder, lo, hi: string) {
	if lo == hi {
		strings.write_string(b, lo)
		return
	}
	n := len(lo) - 1
	if lo[0] == hi[0] {
		strings.write_byte(b, lo[0])
		digit_range(b, lo[1:], hi[1:])
		return
	}
	from_zeros, to_nines := lo[1:] == ZEROS[:n], hi[1:] == NINES[:n]
	first, last := lo[0] + (0 if from_zeros else 1), hi[0] - (0 if to_nines else 1)
	strings.write_string(b, "(?:")
	if !from_zeros {
		strings.write_byte(b, lo[0])
		digit_range(b, lo[1:], NINES[:n])
	}
	if first <= last {
		strings.write_string(b, "" if from_zeros else "|")
		strings.write_byte(b, '[')
		strings.write_byte(b, first)
		strings.write_byte(b, '-')
		strings.write_byte(b, last)
		strings.write_byte(b, ']')
		for _ in 0 ..< n {
			strings.write_string(b, "[0-9]")
		}
	}
	if !to_nines {
		strings.write_byte(b, '|')
		strings.write_byte(b, hi[0])
		digit_range(b, ZEROS[:n], hi[1:])
	}
	strings.write_string(b, ")")
}

@(private, rodata)
NINES := "99999999999999999999"

@(private, rodata)
ZEROS := "00000000000000000000"

// The least decimal of each width past one.
@(private, rodata)
ONES_THEN_ZEROS := "10000000000000000000"
