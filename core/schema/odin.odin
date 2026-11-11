package schema

import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "../spell"
import core "../"
import "../rules"

// Writes the Odin source of package `package_name`: types a model compiled from them reads `d`'s values with, and a
// procedure `register` that adds the rules no tag holds to a `model.Registry`. The root's type comes first, named
// after the root's title or `Root`. An object with members is a struct whose member tags name it in JSON (`json:`), say
// it may be left out (`optional`), and hold its rules (`model:`); one with none is a map. A value that may be null is a
// `Maybe`, a struct that holds itself a pointer, a string format a carrier where the model has one (`time.Time`,
// `uuid.Identifier`, `model.Email`, `model.Base64` for `contentEncoding: base64`), an integer an `i64` (a `u64` past
// its range), a number an `f64`, `enum` and `const` an Odin enum, `anyOf`, a `oneOf` of arms of other kinds and a list of
// kinds a union, read by first match where arms share a kind, and a value of any kind `core.Value`. A rule where no tag
// stands, on an element or an arm, makes a distinct type. Annotations are left out but for `description`, which is a
// comment. A keyword no model spells is refused as `.Unsupported`, naming it in `want.text`, at the path of the value;
// an invalid package name as `.Bad_Option`.
write_odin :: proc(d: ^rules.Description, package_name: string, allocator := context.allocator) -> (source: string, err: core.Error) {
	arena: virtual.Arena
	virtual.arena_init_growing(&arena) or_return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	if package_name == "" || spelled_as_is(package_name, false) != package_name {
		return "", core.error_of(core.Typed_Refusal{kind = .Bad_Option, want = {text = package_name}})
	}
	s := Source{d = d}
	root := odin_type(&s, d.root, "Root", true)
	if s.refused.kind != .None {
		return "", core.error_of(s.refused)
	}
	b := strings.builder_make()
	strings.write_string(&b, "// The types of a schema's values, written by stury's schema.write_odin.\npackage ")
	strings.write_string(&b, package_name)
	strings.write_string(&b, "\n\nimport \"base:runtime\"\n")
	for name, i in IMPORTS {
		if Import(i) in s.imports {
			strings.write_string(&b, name)
		}
	}
	strings.write_string(&b, "import model \"stury:core/model\"\n")
	if root.decl != 0 || root.null {
		strings.write_string(&b, "\n")
		strings.write_string(&b, type_name(&s, d.root, "Root"))
		strings.write_string(&b, " :: ")
		strings.write_string(&b, held_type(&s, root))
		strings.write_string(&b, "\n")
	}
	for x in s.decls {
		strings.write_string(&b, "\n")
		strings.write_string(&b, x.text)
	}
	strings.write_string(&b, "\n// Adds the rules of these types that their tags do not hold to `reg`, before `model.compile`.\n")
	strings.write_string(&b, "register :: proc(reg: ^model.Registry) -> runtime.Allocator_Error {\n")
	strings.write_string(&b, strings.to_string(s.registers))
	strings.write_string(&b, "\treturn nil\n}\n")
	out, cloned := strings.clone(strings.to_string(b), allocator)
	if cloned != nil {
		return "", cloned
	}
	return out, nil
}

@(private = "file")
Import :: enum u8 {
	Uuid,
	Time,
	Core,
}

@(private = "file", rodata)
IMPORTS := [Import]string {
	.Uuid = "import \"core:encoding/uuid\"\n",
	.Time = "import \"core:time\"\n",
	.Core = "import core \"stury:core\"\n",
}

@(private = "file")
Source :: struct {
	d:         ^rules.Description,
	decls:     [dynamic]Decl,
	// The declaration of a node, or of one kind of a node of several kinds.
	of_node:   map[Part]int,
	taken:     map[string]bool,
	// The nodes being spelled, so that a reference back to one that is no struct or union is refused.
	spelling:  map[rules.Node_Index]bool,
	registers: strings.Builder,
	imports:   bit_set[Import],
	path:      [dynamic]core.Step,
	refused:   core.Typed_Refusal,
}

@(private = "file")
Part :: struct {
	node: rules.Node_Index,
	kind: Maybe(rules.Kind),
}

@(private = "file")
Decl :: struct {
	name: string,
	text: string,
	// Being written: a struct or union that holds a value of it holds it by pointer.
	open: bool,
	// A union whose nil is null.
	null: bool,
}

// A value's Odin type, without its null, and the rules a member's tag adds to it.
@(private = "file")
Spelled :: struct {
	type:  string,
	rules: rules.Rules,
	decl:  int, // the declaration `type` names, -1 for none
	null:  bool, // the value may be null, which `type` does not take
}

@(private = "file")
refuse :: proc(s: ^Source, keyword: string) {
	if s.refused.kind != .None {
		return
	}
	s.refused = {kind = .Unsupported, want = {text = keyword}}
	from := max(0, len(s.path) - core.MAX_ERROR_STEPS)
	s.refused.truncated = from > 0
	s.refused.n_steps = u8(copy(s.refused.steps[:], s.path[from:]))
}

// The Odin type of node `i`'s values, `hint` naming a declaration it needs. Where `held`, no member's tag holds its
// rules, so a value with rules has a declaration of its own.
@(private = "file")
odin_type :: proc(s: ^Source, at: rules.Node_Index, hint: string, held: bool) -> (out: Spelled) {
	out.decl = -1
	i := target(s, at)
	if i == rules.NONE {
		s.imports += {.Core}
		out.type = "core.Value"
		return
	}
	if k, ok := s.of_node[{i, nil}]; ok {
		return {type = s.decls[k].name, decl = k, null = .Null in s.d.nodes[i].kinds && !s.decls[k].null}
	}
	if s.spelling[i] || s.refused.kind != .None {
		refuse(s, "$ref")
		return
	}
	s.spelling[i] = true
	defer delete_key(&s.spelling, i)
	n := &s.d.nodes[i]
	if keyword := unspelled(s, n); keyword != "" {
		refuse(s, keyword)
		return
	}
	kinds := n.kinds + ({.Integer} if .Number in n.kinds else {})
	one, count := rules.Kind.Null, 0
	for k in kinds_apart(kinds) {
		one, count = k, count + 1
	}
	switch {
	case n.has_enum || n.const_of != nil:
		return enum_spelled(s, i, hint)
	case len(n.any_of) > 0 || len(n.one_of) > 0:
		return arms_spelled(s, i, hint)
	case count == 0:
		refuse(s, "type" if .Null in kinds else "false")
		return
	case kinds == rules.EVERY_KIND && n.rules == {} && n.array < 0 && n.object < 0:
		s.imports += {.Core}
		out.type = "core.Value"
		return
	case count == 1:
		out = kind_spelled(s, i, one, hint, held)
		out.null = .Null in kinds
		return
	}
	return arms_spelled(s, i, hint)
}

// The node `i` reaches through references, NONE for a loop of them, which is refused.
@(private = "file")
target :: proc(s: ^Source, i: rules.Node_Index) -> rules.Node_Index {
	i := i
	for hops := 0; i != rules.NONE && rules.ref_only(&s.d.nodes[i]); hops += 1 {
		if hops > len(s.d.nodes) {
			refuse(s, "$ref")
			return rules.NONE
		}
		i = s.d.nodes[i].ref.?
	}
	return i
}

// The kinds of `n` but null, `Integer` inside `Number` where the node takes numbers.
@(private = "file")
kinds_apart :: proc(kinds: rules.Kinds) -> rules.Kinds {
	k := kinds - {.Null}
	if .Number in k {
		k -= {.Integer}
	}
	return k
}

// The first keyword of `n` that no model spells, "" for none.
@(private = "file")
unspelled :: proc(s: ^Source, n: ^rules.Node) -> string {
	switch {
	case n.integer_spelled:
		return "type"
	case len(n.all_of) > 0:
		return "allOf"
	case n.not != nil:
		return "not"
	case n.cond.test != nil || n.cond.then != nil || n.cond.other != nil:
		return "if"
	case n.ref != nil:
		return "$ref"
	case n.dynamic_ref != nil:
		return "$dynamicRef"
	case n.unevaluated_items != nil:
		return "unevaluatedItems"
	case n.unevaluated_properties != nil:
		return "unevaluatedProperties"
	case n.rules.markup != .Any:
		return "xml"
	case n.rules.unique && .Array in n.kinds:
		return "uniqueItems"
	case (len(n.any_of) > 0 || len(n.one_of) > 0) && (n.kinds != rules.EVERY_KIND || n.rules != {} || n.array >= 0 || n.object >= 0 || n.has_enum || n.const_of != nil):
		return "anyOf" if len(n.any_of) > 0 else "oneOf"
	case len(n.any_of) > 0 && len(n.one_of) > 0:
		return "oneOf"
	}
	if n.array >= 0 && .Array in n.kinds {
		a := s.d.arrays[n.array]
		if a.contains != nil {
			return "contains"
		}
		for x in a.prefix {
			if x != a.items || n.rules.min_items != u64(len(a.prefix)) || (n.rules.max_items.? or_else 0) != u64(len(a.prefix)) {
				return "prefixItems"
			}
		}
	}
	if n.object >= 0 && .Object in n.kinds {
		o := s.d.objects[n.object]
		switch {
		case o.keys != rules.NONE:
			return "propertyNames"
		case len(o.patterns) > 0:
			return "patternProperties"
		case len(o.dependents) > 0:
			return "dependentRequired" if o.dependents[0].node == nil else "dependentSchemas"
		}
		for m in o.members {
			if m.only_required {
				return "required"
			}
		}
	}
	return ""
}

// The type of node `i`'s values of kind `kind`, with the node's rules on that kind.
@(private = "file")
kind_spelled :: proc(s: ^Source, i: rules.Node_Index, kind: rules.Kind, hint: string, held: bool) -> (out: Spelled) {
	n := &s.d.nodes[i]
	out.decl, out.rules = -1, rules_on(n.rules, kind)
	part := Part{i, nil if card(kinds_apart(n.kinds)) == 1 else kind}
	carrier := false
	#partial switch kind {
	case .Bool:
		out.type = "bool"
	case .Integer:
		out.type = integer_type(s, out.rules)
	case .Number:
		out.type = "f64"
	case .String:
		format := rules.format_of(out.rules.format)
		carried := CARRIED[format] if n.content_encoding != "base64" else "model.Base64"
		switch {
		case carried != "" && (n.content_encoding != "base64" || out.rules.pattern == ""):
			out.type, carrier = carried, true
			out.rules.format, out.rules.assert_format = "", false
			s.imports += {.Time} if format == .Date_Time else {.Uuid} if format == .Uuid else {}
		case n.content_encoding == "base64":
			refuse(s, "pattern")
		case:
			out.type = "string"
			if format == .None {
				out.rules.format, out.rules.assert_format = "", false
			}
		}
	case .Array:
		return array_spelled(s, i, part, out.rules, hint, held)
	case .Object:
		return object_spelled(s, i, part, out.rules, hint, held)
	}
	if !held || out.rules == {} {
		return
	}
	if carrier {
		refuse(s, first_keyword(out.rules))
		return
	}
	return distinct_spelled(s, part, out, hint)
}

@(private = "file", rodata)
CARRIED := #partial [rules.String_Format]string {
	.Date_Time = "time.Time",
	.Uuid      = "uuid.Identifier",
	.Email     = "model.Email",
}

// A declaration of `spelled.type` as a distinct type with `spelled.rules`, which `register` adds.
@(private = "file")
distinct_spelled :: proc(s: ^Source, part: Part, spelled: Spelled, hint: string) -> Spelled {
	k := declare(s, part, hint)
	name := s.decls[k].name
	s.decls[k].text = strings.concatenate({name, " :: distinct ", spelled.type, "\n"})
	s.decls[k].open = false
	strings.write_string(&s.registers, "\tmodel.register_type(reg, {")
	strings.write_string(&s.registers, name)
	strings.write_string(&s.registers, ", ")
	quoted(&s.registers, tag_items(s, spelled.rules, {}))
	strings.write_string(&s.registers, "}) or_return\n")
	return {type = name, decl = k}
}

// The rules of `r` that judge a value of `kind`.
@(private = "file")
rules_on :: proc(r: rules.Rules, kind: rules.Kind) -> (out: rules.Rules) {
	#partial switch kind {
	case .Integer, .Number:
		out.minimum, out.maximum, out.multiple_of = r.minimum, r.maximum, r.multiple_of
		out.exclusive_minimum, out.exclusive_maximum = r.exclusive_minimum, r.exclusive_maximum
	case .String:
		out.min_length, out.max_length, out.pattern, out.format, out.assert_format = r.min_length, r.max_length, r.pattern, r.format, r.assert_format
	case .Array:
		out.min_items, out.max_items = r.min_items, r.max_items
	case .Object:
		out.min_members, out.max_members = r.min_members, r.max_members
	}
	return
}

@(private = "file")
first_keyword :: proc(r: rules.Rules) -> string {
	switch {
	case r.minimum != "":
		return "exclusiveMinimum" if r.exclusive_minimum else "minimum"
	case r.maximum != "":
		return "exclusiveMaximum" if r.exclusive_maximum else "maximum"
	case r.multiple_of != "":
		return "multipleOf"
	case r.pattern != "":
		return "pattern"
	case r.format != "":
		return "format"
	case r.min_length > 0 || r.max_length != nil:
		return "minLength" if r.min_length > 0 else "maxLength"
	case r.min_items > 0 || r.max_items != nil:
		return "minItems" if r.min_items > 0 else "maxItems"
	case r.min_members > 0 || r.max_members != nil:
		return "minProperties" if r.min_members > 0 else "maxProperties"
	}
	return "readOnly" if r.read_only else "writeOnly"
}

@(private = "file")
I64_MAX :: "9223372036854775807"

// An `i64`, or a `u64` where the bounds are not negative and one passes `i64`'s range. A bound that is no integer, or
// that neither holds, is refused.
@(private = "file")
integer_type :: proc(s: ^Source, r: rules.Rules) -> string {
	order :: proc(a, b: string) -> int {
		return spell.decimal_compare(spell.decimal_of(a), spell.decimal_of(b))
	}
	low := "exclusiveMinimum" if r.exclusive_minimum else "minimum"
	high := "exclusiveMaximum" if r.exclusive_maximum else "maximum"
	for text, j in ([2]string{r.minimum, r.maximum}) {
		if text != "" && !rules.integral(spell.decimal_of(text)) {
			refuse(s, low if j == 0 else high)
		}
	}
	if r.multiple_of != "" && !rules.integral(spell.decimal_of(r.multiple_of)) {
		refuse(s, "multipleOf")
	}
	wide := r.minimum != "" && order(r.minimum, "0") >= 0 && (r.maximum != "" && order(r.maximum, I64_MAX) > 0 || order(r.minimum, I64_MAX) > 0)
	switch {
	case wide && r.maximum != "" && order(r.maximum, "18446744073709551615") > 0:
		refuse(s, high)
	case wide && order(r.minimum, "18446744073709551615") > 0:
		refuse(s, low)
	case !wide && r.minimum != "" && order(r.minimum, "-9223372036854775808") < 0:
		refuse(s, low)
	case !wide && r.maximum != "" && order(r.maximum, I64_MAX) > 0:
		refuse(s, high)
	}
	return "u64" if wide else "i64"
}

// A list of the node's items, or a fixed array where the node gives every element the items' node and the length.
@(private = "file")
array_spelled :: proc(s: ^Source, i: rules.Node_Index, part: Part, r: rules.Rules, hint: string, held: bool) -> Spelled {
	n := &s.d.nodes[i]
	a := s.d.arrays[n.array] if n.array >= 0 else rules.Array{items = rules.NONE}
	append(&s.path, core.All{})
	item := odin_type(s, a.items, strings.concatenate({hint, "_Item"}), true)
	pop(&s.path)
	out := Spelled{decl = -1, rules = r}
	if len(a.prefix) > 0 {
		out.type = strings.concatenate({"[", int_text(len(a.prefix)), "]", member_type(s, item)})
		out.rules.min_items, out.rules.max_items = 0, nil
	} else {
		out.type = strings.concatenate({"[]", held_type(s, item)})
	}
	if !held || rules_on(out.rules, .Array) == {} {
		return out
	}
	return distinct_spelled(s, part, out, hint)
}

// A map of the node's other members where it names none, else a struct of its members.
@(private = "file")
object_spelled :: proc(s: ^Source, i: rules.Node_Index, part: Part, r: rules.Rules, hint: string, held: bool) -> Spelled {
	n := &s.d.nodes[i]
	o := s.d.objects[n.object] if n.object >= 0 else rules.Object{additional = rules.NONE, keys = rules.NONE}
	forbids := o.additional != rules.NONE && s.d.nodes[o.additional].kinds == {}
	if len(o.members) == 0 && !forbids {
		append(&s.path, core.All{})
		value := odin_type(s, o.additional, strings.concatenate({hint, "_Value"}), true)
		pop(&s.path)
		out := Spelled{type = strings.concatenate({"map[string]", held_type(s, value)}), rules = r, decl = -1}
		if !held || rules_on(r, .Object) == {} {
			return out
		}
		return distinct_spelled(s, part, out, hint)
	}
	if o.additional != rules.NONE && !forbids {
		refuse(s, "additionalProperties")
	} else if r.min_members > 0 || r.max_members != nil {
		refuse(s, first_keyword(r))
	}
	k := declare(s, part, hint)
	name := s.decls[k].name
	b := strings.builder_make()
	comment(&b, "", n.description)
	strings.write_string(&b, name)
	strings.write_string(&b, " :: struct {\n")
	fields := make(map[string]bool)
	for m in o.members {
		append(&s.path, core.Name(m.name))
		value := odin_type(s, m.node, strings.concatenate({name, "_", spelled_as_is(m.name, true) if spelled_as_is(m.name, true) != "" else "Member"}), false)
		merged, clash := rules.merged(&rules.Node{rules = value.rules}, m.rules)
		if clash != "" {
			refuse(s, clash)
		}
		value.rules = merged
		value.rules.read_only ||= s.d.nodes[m.node].rules.read_only
		value.rules.write_only ||= s.d.nodes[m.node].rules.write_only
		pop(&s.path)
		field := unique(&fields, spelled_as_is(m.name, false) if spelled_as_is(m.name, false) != "" else "member")
		comment(&b, "\t", s.d.nodes[m.node].description)
		strings.write_byte(&b, '\t')
		strings.write_string(&b, field)
		strings.write_string(&b, ": ")
		strings.write_string(&b, member_type(s, value))
		member_tag(s, &b, m, field, value.rules)
		strings.write_string(&b, ",\n")
	}
	strings.write_string(&b, "}\n")
	s.decls[k].text, s.decls[k].open = strings.to_string(b), false
	if forbids {
		strings.write_string(&s.registers, "\tmodel.register_extra(reg, ")
		strings.write_string(&s.registers, name)
		strings.write_string(&s.registers, ", .Forbid) or_return\n")
	}
	return {type = name, decl = k}
}


// The tag of member `m`: its JSON name where the field's differs, `optional` where it is not required, and its rules.
@(private = "file")
member_tag :: proc(s: ^Source, b: ^strings.Builder, m: rules.Member, field: string, r: rules.Rules) {
	tag := strings.builder_make()
	if field != m.name {
		strings.write_string(&tag, "json:\"")
		for c in transmute([]u8)m.name {
			if c == '\\' || c == ',' || c == '"' {
				strings.write_byte(&tag, '\\')
			}
			strings.write_byte(&tag, c)
		}
		strings.write_string(&tag, "\"")
	}
	items := tag_items(s, r, {optional = !m.required})
	if items != "" {
		strings.write_string(&tag, " model:\"" if field != m.name else "model:\"")
		strings.write_string(&tag, items)
		strings.write_string(&tag, "\"")
	}
	text := strings.to_string(tag)
	switch {
	case text == "":
	case strings.contains_rune(text, '`') || strings.contains_rune(text, '\r'):
		strings.write_byte(b, ' ')
		quoted(b, text)
	case:
		strings.write_string(b, " `")
		strings.write_string(b, text)
		strings.write_byte(b, '`')
	}
}

@(private = "file")
Flags :: struct {
	optional: bool,
}

// `r` as the items of a `model:` tag, the pattern last since it takes the rest of the tag.
@(private = "file")
tag_items :: proc(s: ^Source, r: rules.Rules, flags: Flags) -> string {
	b := strings.builder_make()
	item :: proc(b: ^strings.Builder, parts: ..string) {
		if strings.builder_len(b^) > 0 {
			strings.write_byte(b, ',')
		}
		for p in parts {
			strings.write_string(b, p)
		}
	}
	if flags.optional {
		item(&b, "optional")
	}
	if r.read_only && r.write_only {
		refuse(s, "readOnly")
	} else if r.read_only || r.write_only {
		item(&b, "read_only" if r.read_only else "write_only")
	}
	if r.minimum != "" {
		item(&b, ">" if r.exclusive_minimum else ">=", r.minimum)
	}
	if r.maximum != "" {
		item(&b, "<" if r.exclusive_maximum else "<=", r.maximum)
	}
	if r.multiple_of != "" {
		item(&b, "multiple_of=", r.multiple_of)
	}
	for c in ([?]struct {
			low:  u64,
			high: Maybe(u64),
		}{{r.min_length, r.max_length}, {r.min_items, r.max_items}, {r.min_members, r.max_members}}) {
		high, bounded := c.high.?
		switch {
		case bounded && c.low == high:
			item(&b, "len=", uint_text(high))
		case:
			if c.low > 0 {
				item(&b, "len>=", uint_text(c.low))
			}
			if bounded {
				item(&b, "len<=", uint_text(high))
			}
		}
	}
	if r.format != "" {
		item(&b, "format=", r.format)
	}
	if r.pattern != "" {
		if strings.contains_rune(r.pattern, '"') {
			refuse(s, "pattern")
		}
		item(&b, "pattern=", r.pattern)
	}
	return strings.to_string(b)
}

// An enum of the node's values: its strings by their names, or its integers by number.
@(private = "file")
enum_spelled :: proc(s: ^Source, i: rules.Node_Index, hint: string) -> (out: Spelled) {
	n := &s.d.nodes[i]
	out.decl = -1
	values := n.enum_of if n.has_enum else []core.Value{n.const_of.?}
	keyword := "enum" if n.has_enum else "const"
	kinds := n.kinds + ({.Integer} if .Number in n.kinds else {})
	if rules_on(n.rules, .Integer) != {} || rules_on(n.rules, .String) != {} {
		refuse(s, first_keyword(n.rules))
		return
	}
	texts := make([dynamic]string)
	numbers := make([dynamic]i64)
	for v in values {
		switch core.kind(v) {
		case .Null:
			out.null = .Null in kinds
		case .String:
			room: [dynamic]u8
			if ref, is_ref := v.(core.Node_Ref); is_ref {
				resize(&room, core.text_room(ref.doc, ref.node))
			}
			text, _ := core.text(v, room[:])
			if .String in kinds && !contains(texts[:], text) {
				append(&texts, text)
			}
		case .Number:
			f, _, _ := core.double_of(v)
			if f != f64(i64(f)) || f < -(1 << 53) || f > 1 << 53 {
				refuse(s, keyword)
				return
			}
			if .Integer in kinds && !contains(numbers[:], i64(f)) {
				append(&numbers, i64(f))
			}
		case .True, .False, .Array, .Object, .Plain, .End:
			refuse(s, keyword)
			return
		}
	}
	if len(texts) > 0 && len(numbers) > 0 || len(texts) + len(numbers) == 0 {
		refuse(s, keyword)
		return
	}
	k := declare(s, {i, nil}, hint)
	name := s.decls[k].name
	b := strings.builder_make()
	comment(&b, "", n.description)
	strings.write_string(&b, name)
	strings.write_string(&b, " :: enum i64 {\n" if len(numbers) > 0 else " :: enum {\n")
	members := make(map[string]bool)
	renames := strings.builder_make()
	for x in numbers {
		strings.write_string(&b, "\tV")
		strings.write_string(&b, "M" if x < 0 else "")
		strings.write_string(&b, uint_text(u64(abs(x))))
		strings.write_string(&b, " = ")
		strings.write_string(&b, int_text(int(x)))
		strings.write_string(&b, ",\n")
	}
	for x in texts {
		member := unique(&members, enum_member(x))
		strings.write_byte(&b, '\t')
		strings.write_string(&b, member)
		strings.write_string(&b, ",\n")
		if member != x {
			strings.write_string(&renames, "{" if strings.builder_len(renames) == 0 else ", {")
			quoted(&renames, member)
			strings.write_string(&renames, ", ")
			quoted(&renames, x)
			strings.write_string(&renames, "}")
		}
	}
	strings.write_string(&b, "}\n")
	s.decls[k].text, s.decls[k].open = strings.to_string(b), false
	if len(numbers) > 0 || strings.builder_len(renames) > 0 {
		strings.write_string(&s.registers, "\tmodel.register_enum(reg, {")
		strings.write_string(&s.registers, name)
		if len(numbers) > 0 {
			strings.write_string(&s.registers, ", true, nil")
		} else {
			strings.write_string(&s.registers, ", false, []model.Enum_Rename{")
			strings.write_string(&s.registers, strings.to_string(renames))
			strings.write_string(&s.registers, "}")
		}
		strings.write_string(&s.registers, "}) or_return\n")
	}
	out.type, out.decl = name, k
	return
}

@(private = "file")
contains :: proc(list: []$T, x: T) -> bool {
	for y in list {
		if y == x {
			return true
		}
	}
	return false
}

// A union of `anyOf`'s arms, or of a `oneOf`'s whose kinds are apart, or of the node's kinds each with its rules. Arms
// that share a kind are read by first match. A false arm adds nothing, and a null one makes the union's nil.
@(private = "file")
arms_spelled :: proc(s: ^Source, i: rules.Node_Index, hint: string) -> (out: Spelled) {
	n := &s.d.nodes[i]
	out.decl = -1
	Arm :: struct {
		node:  rules.Node_Index,
		kind:  Maybe(rules.Kind),
		kinds: rules.Kinds,
	}
	arms := make([dynamic]Arm)
	null := .Null in n.kinds && len(n.any_of) == 0 && len(n.one_of) == 0
	if len(n.any_of) == 0 && len(n.one_of) == 0 {
		for k in kinds_apart(n.kinds) {
			append(&arms, Arm{i, k, {k} if k != .Number else {.Integer, .Number}})
		}
	}
	// A value of any kind is an arm's under anyOf, and under oneOf when no other arm takes one.
	overlap := false
	for x in (n.any_of if len(n.any_of) > 0 else n.one_of) {
		at := target(s, x)
		if at == rules.NONE {
			return
		}
		arm := &s.d.nodes[at]
		plain := arm.rules == {} && arm.array < 0 && arm.object < 0 && !arm.has_enum && arm.const_of == nil && len(arm.any_of) == 0 && len(arm.one_of) == 0
		overlap ||= len(n.one_of) > 0 && null && .Null in arm.kinds
		switch {
		case arm.kinds == rules.EVERY_KIND && plain && len(n.one_of) <= 1:
			s.imports += {.Core}
			return {type = "core.Value", decl = -1}
		case arm.kinds - {.Null} == {} && plain:
			null ||= .Null in arm.kinds
		case:
			null ||= .Null in arm.kinds
			append(&arms, Arm{x, nil, arm.kinds + ({.Integer} if .Number in arm.kinds else {}) - {.Null}})
		}
	}
	for a, j in arms {
		for b in arms[j + 1:] {
			overlap ||= a.kinds & b.kinds != {}
		}
	}
	switch {
	case overlap && len(n.one_of) > 0:
		refuse(s, "oneOf")
		return
	case len(arms) == 0:
		refuse(s, "type" if null else "false")
		return
	case len(arms) == 1 && arms[0].kind == nil:
		out = odin_type(s, arms[0].node, hint, true)
		out.null ||= null
		return
	}
	k := declare(s, {i, nil}, hint)
	name := s.decls[k].name
	types := make([dynamic]string)
	for a, j in arms {
		arm_hint := strings.concatenate({name, "_", KIND_NAMES[a.kind.?] if a.kind != nil else int_text(j + 1)})
		value := kind_spelled(s, a.node, a.kind.?, arm_hint, true) if a.kind != nil else odin_type(s, a.node, arm_hint, true)
		null ||= value.null
		value.null = false
		if t := member_type(s, value); !contains(types[:], t) {
			append(&types, t)
		}
	}
	b := strings.builder_make()
	comment(&b, "", n.description)
	strings.write_string(&b, name)
	strings.write_string(&b, " :: union {" if null else " :: union #no_nil {")
	for t, j in types {
		strings.write_string(&b, ", " if j > 0 else "")
		strings.write_string(&b, t)
	}
	strings.write_string(&b, "}\n")
	s.decls[k].text, s.decls[k].open, s.decls[k].null = strings.to_string(b), false, null
	if overlap {
		strings.write_string(&s.registers, "\tmodel.register_union(reg, {")
		strings.write_string(&s.registers, name)
		strings.write_string(&s.registers, ", .First_Match, \"\"}) or_return\n")
	}
	return {type = name, decl = k}
}

@(private = "file", rodata)
KIND_NAMES := [rules.Kind]string {
	.Null    = "Null",
	.Bool    = "Bool",
	.Integer = "Integer",
	.Number  = "Number",
	.String  = "String",
	.Array   = "List",
	.Object  = "Object",
}

// The type of a member or an element held in place: a struct or union being written, which would hold itself, by
// pointer, which also takes null, and a value that may be null as a `Maybe`.
@(private = "file")
member_type :: proc(s: ^Source, v: Spelled) -> string {
	if v.decl >= 0 && s.decls[v.decl].open {
		return strings.concatenate({"^", v.type})
	}
	return strings.concatenate({"Maybe(", v.type, ")"}) if v.null else v.type
}

// The type of an element held behind a list or a map, which a struct or union being written may be.
@(private = "file")
held_type :: proc(s: ^Source, v: Spelled) -> string {
	return strings.concatenate({"Maybe(", v.type, ")"}) if v.null else v.type
}

// A new declaration of `part`, open, named for the node or by `hint`.
@(private = "file")
declare :: proc(s: ^Source, part: Part, hint: string) -> int {
	name := type_name(s, part.node if part.kind == nil else rules.NONE, hint)
	append(&s.decls, Decl{name = name, open = true})
	s.of_node[part] = len(s.decls) - 1
	return len(s.decls) - 1
}

// A type name not yet taken: the node's name in the description or its title, else `hint`.
@(private = "file")
type_name :: proc(s: ^Source, i: rules.Node_Index, hint: string) -> string {
	name := ""
	if i != rules.NONE {
		name = spelled_as_is(s.d.names[i] or_else s.d.nodes[i].title, true)
	}
	return unique(&s.taken, name if name != "" else hint)
}

// `name`, or with the least `_2`, `_3`... that `taken` lacks, which then holds it.
@(private = "file")
unique :: proc(taken: ^map[string]bool, name: string) -> string {
	out := name
	for k := 2; taken[out]; k += 1 {
		out = strings.concatenate({name, "_", int_text(k)})
	}
	taken[out] = true
	return out
}

// `text` as an Odin identifier: its ASCII letters and digits, words joined by `_`, each word capitalized for a type and
// lowercased for a field or package. A word splits where a lowercase letter meets an uppercase one. A keyword takes a
// trailing `_`, and a leading digit a leading `_`.
@(private = "file")
spelled_as_is :: proc(text: string, type: bool) -> string {
	b := strings.builder_make()
	start, prev := true, u8(0)
	for c in transmute([]u8)text {
		alnum := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
		if !alnum {
			start = true
			prev = 0
			continue
		}
		upper := c >= 'A' && c <= 'Z'
		if upper && prev >= 'a' && prev <= 'z' {
			start = true
		}
		if start && strings.builder_len(b) > 0 {
			strings.write_byte(&b, '_')
		}
		switch {
		case type && start && c >= 'a' && c <= 'z':
			strings.write_byte(&b, c - 32)
		case !type && upper:
			strings.write_byte(&b, c + 32)
		case:
			strings.write_byte(&b, c)
		}
		start, prev = false, c
	}
	out := strings.to_string(b)
	if out == "" {
		return ""
	}
	if out[0] >= '0' && out[0] <= '9' {
		out = strings.concatenate({"_", out})
	}
	for k in KEYWORDS {
		if out == k {
			return strings.concatenate({out, "_"})
		}
	}
	return out
}

// An enum member's name for the string `text`, `Empty` for "".
@(private = "file")
enum_member :: proc(text: string) -> string {
	name := spelled_as_is(text, true)
	return "Empty" if name == "" else name
}

@(private = "file", rodata)
KEYWORDS := [?]string {
	"asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context", "continue", "defer", "distinct", "do",
	"dynamic", "else", "enum", "fallthrough", "false", "for", "foreign", "if", "import", "in", "map", "matrix", "nil",
	"not_in", "or_break", "or_continue", "or_else", "or_return", "package", "proc", "return", "struct", "switch",
	"transmute", "true", "typeid", "union", "using", "when", "where",
}

// Writes `text` as `//` lines after `indent`.
@(private = "file")
comment :: proc(b: ^strings.Builder, indent, text: string) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		strings.write_string(b, indent)
		strings.write_string(b, "//" if line == "" else "// ")
		strings.write_string(b, line)
		strings.write_byte(b, '\n')
	}
}

// Writes `text` as an Odin string literal.
@(private = "file")
quoted :: proc(b: ^strings.Builder, text: string) {
	strings.write_byte(b, '"')
	for c in transmute([]u8)text {
		switch c {
		case '"', '\\':
			strings.write_byte(b, '\\')
			strings.write_byte(b, c)
		case '\n':
			strings.write_string(b, "\\n")
		case 0 ..< ' ', 0x7f:
			hex := "0123456789abcdef"
			strings.write_string(b, "\\x")
			strings.write_byte(b, hex[c >> 4])
			strings.write_byte(b, hex[c & 15])
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}

@(private = "file")
uint_text :: proc(n: u64) -> string {
	return string(strconv.write_uint(make([]u8, 24), n, 10))
}

@(private = "file")
int_text :: proc(n: int) -> string {
	return string(strconv.write_int(make([]u8, 24), i64(n), 10))
}

