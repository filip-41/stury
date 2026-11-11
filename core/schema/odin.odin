package schema

import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../regex"
import "../spell"
import core "../"
import "../rules"

// Writes the Odin source of package `package_name`: types a model compiled from them reads `d`'s values with, and a
// procedure `register` that adds the rules no tag holds to a `model.Registry`. The root's type comes first, else an
// alias `Root` names it. An object with members is a struct whose tags name a member in JSON (`json:`) and hold its
// rules (`model:`), with an `extra` map for the other members where a schema judges them, and one with none is a map.
// A member that may be left out and takes no null is a `Maybe` that a write leaves out when nil. A value that may be
// null is a `Maybe`, null alone the empty union `Null`, a struct that holds itself a pointer, a format that asserts
// (under `format_assert`, or the schema's vocabulary) a carrier where the model has one (`time.Time`,
// `uuid.Identifier`, `model.Email`) or a `format=` rule, an integer an `i64` (a `u64` past its range), a number an
// `f64` when both bounds are finite doubles and `core.Number_Text` otherwise, an `enum` or `const` an Odin enum or
// `bool` (a union of them for operands of several kinds), an `anyOf`, a `oneOf` and a list of kinds a union, and a
// value of any kind `core.Value`. An `allOf` and a `$ref` beside other keywords are one value that passes each. A rule
// where no tag stands makes a distinct type, and `not`, `if`, `contains`, `propertyNames`, `patternProperties` and the
// dependents make a named type whose JSON Schema fragment of them, written in `as`, which is JSON's, `register` adds
// with `model.register_schema`. A member's scalar `default` is a `model.register_default` line. Annotations are left
// out but for `description` and a format that does not assert, which are comments. A keyword no model spells is
// refused as `.Unsupported`, naming it in `want.text`, at the path of the value. A package name that is no Odin
// identifier, or that names a package a program holding the source imports, is refused as `.Bad_Option`.
write_odin :: proc(d: ^rules.Description, package_name: string, as: core.As, format_assert := false, allocator := context.allocator) -> (source: string, err: core.Error) {
	arena: virtual.Arena
	virtual.arena_init_growing(&arena) or_return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	if !package_spelled(package_name) {
		return "", core.error_of(core.Typed_Refusal{kind = .Bad_Option, want = {text = package_name}})
	}
	// A conjunction is spelled as a node of its own, which the copy holds.
	local := d^
	local.nodes = slice.clone_to_dynamic(d.nodes[:])
	local.arrays = slice.clone_to_dynamic(d.arrays[:])
	local.objects = slice.clone_to_dynamic(d.objects[:])
	local.names = make(map[rules.Node_Index]string)
	for k, v in d.names {
		local.names[k] = v
	}
	s, root := root_spelled(&local, as, format_assert, "Root")
	alias := root.decl != 0 || root.null
	if alias && s.taken["Root"] {
		s, root = root_spelled(&local, as, format_assert, "Root_Value")
	}
	if s.refused.kind != .None {
		return "", core.error_of(s.refused)
	}
	b := strings.builder_make()
	strings.write_string(&b, "// The types of a schema's values, written by stury's schema.write_odin.\npackage ")
	strings.write_string(&b, package_name)
	strings.write_string(&b, "\n\n")
	if s.fragments || s.defaults {
		s.imports += {.Core, .Json} if s.fragments else {.Core}
	} else {
		strings.write_string(&b, "import \"base:runtime\"\n")
	}
	for name, i in IMPORTS {
		if Import(i) in s.imports {
			strings.write_string(&b, name)
		}
	}
	strings.write_string(&b, "import model \"stury:core/model\"\n")
	if alias {
		strings.write_string(&b, "\n")
		if root.note != "" {
			comment(&b, "", strings.concatenate({"format: ", root.note}))
		}
		strings.write_string(&b, unique(&s.taken, "Root"))
		strings.write_string(&b, " :: ")
		strings.write_string(&b, held_type(root))
		strings.write_string(&b, "\n")
	}
	for x in s.decls {
		strings.write_string(&b, "\n")
		strings.write_string(&b, x.text)
	}
	strings.write_string(&b, "\n// Adds the rules of these types that their tags do not hold to `reg`, before `model.compile`.\n")
	strings.write_string(&b, "register :: proc(reg: ^model.Registry) -> ")
	strings.write_string(&b, "core.Error {\n" if s.fragments || s.defaults else "runtime.Allocator_Error {\n")
	strings.write_string(&b, strings.to_string(s.registers))
	strings.write_string(&b, "\treturn nil\n}\n")
	if s.fragments {
		strings.write_string(&b, REGISTER_FRAGMENT)
	}
	out, cloned := strings.clone(strings.to_string(b), allocator)
	if cloned != nil {
		return "", cloned
	}
	return out, nil
}

// The procedure of the source that adds a fragment's text to the rules of a type.
@(private = "file")
REGISTER_FRAGMENT ::
	"\n// Adds the JSON Schema `text` to the rules of `T`.\n" +
	"register_fragment :: proc(reg: ^model.Registry, T: typeid, text: string) -> core.Error {\n" +
	"\ts := json.load_schema(transmute([]u8)text) or_return\n" +
	"\tdefer json.destroy(s)\n" +
	"\tmodel.register_schema(reg, T, s.description) or_return\n" +
	"\treturn nil\n" +
	"}\n"

@(private = "file")
root_spelled :: proc(d: ^rules.Description, as: core.As, format_assert: bool, hint: string) -> (s: Source, root: Spelled) {
	s = Source{d = d, as = as, format_assert = format_assert, originals = len(d.nodes)}
	s.taken["Maybe"] = true
	root = odin_type(&s, d.root, hint, true)
	return
}

@(private = "file")
Import :: enum u8 {
	Uuid,
	Time,
	Core,
	Json,
}

@(private = "file", rodata)
IMPORTS := [Import]string {
	.Uuid = "import \"core:encoding/uuid\"\n",
	.Time = "import \"core:time\"\n",
	.Core = "import core \"stury:core\"\n",
	.Json = "import json \"stury:json\"\n",
}

@(private = "file")
Source :: struct {
	d:             ^rules.Description,
	as:            core.As, // the format a fragment is written in
	format_assert: bool,
	// A judged type's fragment is written, which `register_fragment` adds.
	fragments:     bool,
	// A member's default is written, which `register` adds and which may refuse as a `core.Error`.
	defaults:      bool,
	decls:         [dynamic]Decl,
	// The declaration of a node, or of one kind of a node of several kinds.
	of_node:       map[Part]int,
	taken:         map[string]bool,
	// The parts being spelled, so that a reference back to one that is no struct or union is refused.
	spelling:      map[Part]bool,
	// The node a conjunction is spelled as, by the indices of its nodes of the description.
	joined:        map[string]rules.Node_Index,
	originals:     int, // the description's nodes, before the conjunctions
	null_type:     string,
	registers:     strings.Builder,
	imports:       bit_set[Import],
	path:          [dynamic]core.Step,
	refused:       core.Typed_Refusal,
	// Above 0 while spelling a value whose written text a check judges: a judged type's or a unique list's element.
	whole:         int,
}

@(private = "file")
Part :: struct {
	node:  rules.Node_Index,
	kind:  Maybe(rules.Kind),
	// A struct of it keeps the members it does not declare, so that its written text is the text it read.
	whole: bool,
}

// The part of node `i`, of `kind` alone where it is set.
@(private = "file")
part_of :: proc(s: ^Source, i: rules.Node_Index, kind: Maybe(rules.Kind) = nil) -> Part {
	return {i, kind, s.whole > 0 && s.d.nodes[i].kinds & {.Array, .Object} != {}}
}

@(private = "file")
Decl :: struct {
	name: string,
	text: string,
	// Being written: a struct or union that holds a value of it holds it by pointer.
	open: bool,
	// The value may be null, which the declared type does not take.
	null: bool,
}

// A value's Odin type, without its null, the rules a member's tag adds to it, and the format it only annotates.
@(private = "file")
Spelled :: struct {
	type:  string,
	rules: rules.Rules,
	decl:  int, // the declaration `type` names, -1 for none
	null:  bool, // the value may be null, which `type` does not take
	note:  string,
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

// The Odin type of node `at`'s values, `hint` naming a declaration it needs. Where `held`, no member's tag holds its
// rules, so a value with rules has a declaration of its own.
@(private = "file")
odin_type :: proc(s: ^Source, at: rules.Node_Index, hint: string, held: bool) -> (out: Spelled) {
	out.decl = -1
	i := settled(s, target(s, at))
	if i == rules.NONE {
		s.imports += {.Core}
		out.type = "core.Value"
		return
	}
	part := part_of(s, i)
	if k, ok := s.of_node[part]; ok {
		return {type = s.decls[k].name, decl = k, null = s.decls[k].null}
	}
	if s.spelling[part] || s.refused.kind != .None {
		refuse(s, "$ref")
		return
	}
	s.spelling[part] = true
	defer delete_key(&s.spelling, part)
	out = node_spelled(s, i, hint, held)
	if k, ok := s.of_node[part]; ok {
		s.decls[k].null = out.null
	}
	return
}

@(private = "file")
node_spelled :: proc(s: ^Source, i: rules.Node_Index, hint: string, held: bool) -> (out: Spelled) {
	out.decl = -1
	n := s.d.nodes[i]
	if keyword := unspelled(s, &n); keyword != "" {
		refuse(s, keyword)
		return
	}
	if judged(s, &n) {
		return judged_spelled(s, i, hint, held)
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
	case count == 0 && .Null in kinds:
		return {type = null_type(s), decl = -1}
	case count == 0:
		refuse(s, "false")
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
	end, _ := rules.ref_end(s.d, i)
	if end == rules.NONE && i != rules.NONE {
		refuse(s, "$ref")
	}
	return end
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
	case n.dynamic_ref != nil:
		return "$dynamicRef"
	case n.unevaluated_items != nil:
		return "unevaluatedItems"
	case n.unevaluated_properties != nil:
		return "unevaluatedProperties"
	case n.rules.markup != .Any:
		return "xml"
	case (len(n.any_of) > 0 || len(n.one_of) > 0) && (n.kinds != rules.EVERY_KIND || n.rules != {} || n.array >= 0 || n.object >= 0 || n.has_enum || n.const_of != nil):
		return "anyOf" if len(n.any_of) > 0 else "oneOf"
	case len(n.any_of) > 0 && len(n.one_of) > 0:
		return "oneOf"
	}
	return ""
}

// Whether node `n` holds an applicator that a model registers on its type: `not`, `if`, `contains`, `propertyNames`,
// `patternProperties` or a dependent.
@(private = "file")
judged :: proc(s: ^Source, n: ^rules.Node) -> bool {
	if n.not != nil || n.cond != {} {
		return true
	}
	if n.array >= 0 && .Array in n.kinds && s.d.arrays[n.array].contains != nil {
		return true
	}
	if n.object >= 0 && .Object in n.kinds {
		o := s.d.objects[n.object]
		return o.keys != rules.NONE || len(o.patterns) > 0 || len(o.dependents) > 0
	}
	return false
}

// The named type of node `i` without its applicators, and the `register_fragment` line that adds them to the type as a
// JSON Schema fragment, each operand as the schema states it. A `Maybe` reads null before its type, so a node of kinds that holds null is a `Maybe`
// where null passes its applicators and leaves null out where it fails them. Pattern members beside a rule on the
// other members, which an `extra` map would read, are refused, and so is a node of arms that takes a null that `not`
// or `if` refuses.
@(private = "file")
judged_spelled :: proc(s: ^Source, i: rules.Node_Index, hint: string, held: bool) -> (out: Spelled) {
	out.decl = -1
	n := s.d.nodes[i]
	outer := part_of(s, i)
	base := n
	base.not, base.cond = nil, {}
	kinds_null := .Null in n.kinds && len(n.any_of) == 0 && len(n.one_of) == 0
	if kinds_null {
		base.kinds -= {.Null}
	}
	a: rules.Array
	if n.array >= 0 && .Array in n.kinds {
		a = s.d.arrays[n.array]
		x := a
		x.contains, x.min_contains, x.max_contains = nil, nil, nil
		base.array = block(&s.d.arrays, x)
	}
	o := rules.Object{additional = rules.NONE, keys = rules.NONE}
	// The members past the declared ones are an `extra` map of the one pattern's type where no other may stand, and the
	// names the struct holds are the declared ones and the pattern's.
	pattern_extra := false
	if n.object >= 0 && .Object in n.kinds {
		o = s.d.objects[n.object]
		kinds, plain := kinds_only(s, o.additional)
		pattern_extra = len(o.patterns) == 1 && o.keys == rules.NONE && o.additional != rules.NONE && plain && kinds == {}
		if len(o.patterns) > 0 && o.additional != rules.NONE && (!plain || kinds != rules.EVERY_KIND) && !pattern_extra {
			refuse(s, "patternProperties")
			return
		}
		x := o
		x.keys, x.patterns, x.dependents = rules.NONE, nil, nil
		if pattern_extra {
			x.additional = o.patterns[0].node
			o.keys = names_node(s, o)
		}
		base.object = block(&s.d.objects, x)
	}
	at := rules.Node_Index(len(s.d.nodes))
	append(&s.d.nodes, base)
	if name, named := s.d.names[i]; named {
		s.d.names[at] = name
	}
	s.whole += 1
	inner := part_of(s, at)
	out = node_spelled(s, at, hint, held)
	s.whole -= 1
	switch {
	case kinds_null:
		out.null = takes_null(s, i)
	case (n.not != nil || n.cond != {}) && out.null && !takes_null(s, i):
		refuse(s, "not" if n.not != nil else "if")
	}
	if s.refused.kind != .None {
		return
	}
	// The type is the node's own, else a distinct one that the rules name.
	if k, own := s.of_node[inner]; !own || k != out.decl {
		k = declare(s, inner, hint)
		s.decls[k].text = strings.concatenate({s.decls[k].name, " :: distinct ", out.type, "\n"})
		s.decls[k].open = false
		out.type, out.decl = s.decls[k].name, k
	}
	s.of_node[outer] = out.decl
	// The fragment holds the node's applicators, with the operands as the schema states them.
	f := rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, not = n.not, cond = n.cond, resource = n.resource}
	if c, has := a.contains.?; has {
		f.array = block(&s.d.arrays, rules.Array{items = rules.NONE, contains = c, min_contains = a.min_contains, max_contains = a.max_contains})
	}
	if o.keys != rules.NONE || len(o.patterns) > 0 || len(o.dependents) > 0 {
		// The `extra` map reads the members the pattern names as its type, so the names are what is left to judge.
		f.object = block(&s.d.objects, rules.Object{additional = rules.NONE, keys = o.keys, patterns = nil if pattern_extra else o.patterns, dependents = o.dependents})
	}
	append(&s.d.nodes, f)
	fragment := s.d^
	fragment.root = rules.Node_Index(len(s.d.nodes) - 1)
	text, err := write(&fragment, s.as)
	if err != nil {
		e, _ := err.(core.Typed_Error)
		first := "not" if n.not != nil else "if" if n.cond != {} else "contains" if a.contains != nil else "propertyNames"
		refuse(s, e.want.text if e.want.text != "" else first)
		return
	}
	s.fragments = true
	strings.write_string(&s.registers, "\tregister_fragment(reg, ")
	strings.write_string(&s.registers, out.type)
	strings.write_string(&s.registers, ", ")
	literal(&s.registers, string(text))
	strings.write_string(&s.registers, ") or_return\n")
	return
}

// Writes `text` as an Odin string: a raw one where it holds no backquote and no control byte but a tab, else a quoted one.
@(private = "file")
literal :: proc(b: ^strings.Builder, text: string) {
	raw := true
	for c in transmute([]u8)text {
		raw &&= c >= ' ' && c != '`' && c != 0x7f || c == '\t'
	}
	if !raw {
		strings.write_quoted_string(b, text)
		return
	}
	strings.write_byte(b, '`')
	strings.write_string(b, text)
	strings.write_byte(b, '`')
}

// A node of the strings that are a declared member's name of `o` or that its patterns match.
@(private = "file")
names_node :: proc(s: ^Source, o: rules.Object) -> rules.Node_Index {
	b := strings.builder_make()
	if len(o.members) > 0 {
		strings.write_string(&b, "^(?:")
		for m, j in o.members {
			strings.write_string(&b, "|" if j > 0 else "")
			for c in m.name {
				if strings.contains_rune(`\^$.|?*+()[]{}/-`, c) {
					strings.write_byte(&b, '\\')
				}
				strings.write_rune(&b, c)
			}
		}
		strings.write_string(&b, ")$")
	}
	for p in o.patterns {
		strings.write_string(&b, "|(?:" if strings.builder_len(b) > 0 else "(?:")
		strings.write_string(&b, p.expression)
		strings.write_string(&b, ")")
	}
	append(&s.d.nodes, rules.Node{kinds = {.String}, array = -1, object = -1, rules = {pattern = strings.to_string(b)}})
	return rules.Node_Index(len(s.d.nodes) - 1)
}

// The node that node `i` is spelled as: `i`, or a node of the description's copy that holds what `i` and the nodes its
// `allOf` and `$ref` reach judge together, a `not` of kinds alone taken out of its kinds, and its `unevaluatedItems`
// and `unevaluatedProperties` as the other elements and members where no other applicator evaluates them.
@(private = "file")
settled :: proc(s: ^Source, i: rules.Node_Index) -> rules.Node_Index {
	if i == rules.NONE || s.refused.kind != .None {
		return i
	}
	n := s.d.nodes[i]
	if len(n.all_of) == 0 && n.ref == nil && n.not == nil && n.unevaluated_items == nil && n.unevaluated_properties == nil {
		return i
	}
	conjuncts := []rules.Node_Index{i}
	if len(n.all_of) > 0 || n.ref != nil {
		ways, complete := rules.branches(s.d, {i}, false, 1)
		if !complete || len(ways) != 1 {
			refuse(s, "allOf" if len(n.all_of) > 0 else "$ref")
			return i
		}
		conjuncts = ways[0][:]
	}
	key := strings.builder_make()
	sorted := slice.clone(conjuncts)
	slice.sort(sorted)
	for c in sorted {
		if int(c) < s.originals {
			strings.write_string(&key, int_text(int(c)))
			strings.write_byte(&key, ',')
		}
	}
	if k, ok := s.joined[strings.to_string(key)]; ok {
		return k
	}
	j := joined_node(s, i, conjuncts, len(n.all_of) > 0 || n.ref != nil)
	s.joined[strings.to_string(key)] = j
	return j
}

@(private = "file")
joined_node :: proc(s: ^Source, top: rules.Node_Index, conjuncts: []rules.Node_Index, conjunction: bool) -> rules.Node_Index {
	t := s.d.nodes[top]
	out := rules.Node {
		kinds       = rules.EVERY_KIND,
		array       = -1,
		object      = -1,
		any_of      = nil if conjunction else t.any_of,
		description = t.description,
		title       = t.title,
		resource    = t.resource,
	}
	arrays := make([dynamic]i32)
	objects := make([dynamic]i32)
	for c in conjuncts {
		x := s.d.nodes[c]
		clash := ""
		out.rules, clash = rules.merged(&rules.Node{rules = out.rules}, x.rules)
		out.kinds &= x.kinds + ({.Integer} if .Number in x.kinds else {})
		out.integer_spelled ||= x.integer_spelled
		out.content_encoding = x.content_encoding if x.content_encoding != "" else out.content_encoding
		if x.array >= 0 && !slice.contains(arrays[:], x.array) {
			append(&arrays, x.array)
		}
		if x.object >= 0 && !slice.contains(objects[:], x.object) {
			append(&objects, x.object)
		}
		if not, has := x.not.?; has {
			if kinds, plain := kinds_only(s, not); plain {
				if .Integer in kinds && .Number not_in kinds && .Number in out.kinds {
					clash = "not"
				}
				out.kinds -= kinds + ({.Integer} if .Number in kinds else {})
			} else {
				clash = "not" if out.not != nil else clash
				out.not = not
			}
		}
		if x.has_enum || x.const_of != nil {
			clash = "enum" if out.has_enum || out.const_of != nil else clash
			out.has_enum, out.enum_of, out.const_of = x.has_enum, x.enum_of, x.const_of
		}
		if len(x.one_of) > 0 {
			clash = "oneOf" if len(out.one_of) > 0 else clash
			out.one_of = x.one_of
		}
		if x.cond != {} {
			clash = "if" if out.cond != {} else clash
			out.cond = x.cond
		}
		if x.dynamic_ref != nil {
			clash = "$dynamicRef" if out.dynamic_ref != nil else clash
			out.dynamic_ref = x.dynamic_ref
		}
		if c != top && x.unevaluated_items != nil {
			clash = "unevaluatedItems"
		} else if c != top && x.unevaluated_properties != nil {
			clash = "unevaluatedProperties"
		}
		if clash != "" {
			refuse(s, clash)
			return top
		}
	}
	if .Array in out.kinds && len(arrays) > 0 {
		out.array = arrays[0]
		if len(arrays) > 1 {
			items := make([dynamic]rules.Node_Index)
			for a in arrays {
				x := s.d.arrays[a]
				if len(x.prefix) > 0 || x.contains != nil {
					refuse(s, "prefixItems" if len(x.prefix) > 0 else "contains")
					return top
				}
				append(&items, x.items)
			}
			out.array = block(&s.d.arrays, rules.Array{items = joined_of(s, items[:])})
		}
	}
	if .Object in out.kinds && len(objects) > 0 {
		out.object = objects[0]
		if len(objects) > 1 {
			out.object = joined_object(s, objects[:])
			if s.refused.kind != .None {
				return top
			}
		}
	}
	keyword := "unevaluatedProperties" if t.unevaluated_properties != nil else "unevaluatedItems" if t.unevaluated_items != nil else ""
	if keyword != "" && (len(out.any_of) > 0 || len(out.one_of) > 0 || out.cond != {} || out.dynamic_ref != nil || out.not != nil) {
		refuse(s, keyword)
		return top
	}
	if u, has := t.unevaluated_properties.?; has && .Object in out.kinds {
		o := s.d.objects[out.object] if out.object >= 0 else rules.Object{additional = rules.NONE, keys = rules.NONE}
		if o.additional == rules.NONE {
			o.additional = u
			out.object = block(&s.d.objects, o)
		}
	}
	if u, has := t.unevaluated_items.?; has && .Array in out.kinds {
		a := s.d.arrays[out.array] if out.array >= 0 else rules.Array{items = rules.NONE}
		if a.items == rules.NONE {
			a.items = u
			out.array = block(&s.d.arrays, a)
		}
	}
	append(&s.d.nodes, out)
	if name, named := s.d.names[top]; named {
		s.d.names[rules.Node_Index(len(s.d.nodes) - 1)] = name
	}
	return rules.Node_Index(len(s.d.nodes) - 1)
}

// The members of objects `objects` judge together: each name's nodes joined, and the other members' nodes where every
// object that judges other members names all of them.
@(private = "file")
joined_object :: proc(s: ^Source, objects: []i32) -> i32 {
	named :: proc(o: rules.Object, name: string) -> bool {
		for m in o.members {
			if m.name == name && !m.only_required {
				return true
			}
		}
		return false
	}
	out := rules.Object{keys = rules.NONE}
	members := make([dynamic]rules.Member)
	for o in objects {
		for m in s.d.objects[o].members {
			at := -1
			for x, j in members {
				at = j if x.name == m.name else at
			}
			if at < 0 {
				append(&members, rules.Member{name = m.name, node = rules.NONE, only_required = true})
				at = len(members) - 1
			}
			x := &members[at]
			x.required ||= m.required
			if m.only_required {
				continue
			}
			clash := ""
			x.rules, clash = rules.merged(&rules.Node{rules = x.rules}, m.rules)
			if clash != "" {
				refuse(s, clash)
				return -1
			}
			x.node = m.node if x.only_required else joined_of(s, {x.node, m.node})
			x.only_required = false
		}
	}
	others := make([dynamic]rules.Node_Index)
	for i in objects {
		o := s.d.objects[i]
		if o.additional != rules.NONE {
			for m in members {
				if !named(o, m.name) {
					refuse(s, "additionalProperties")
					return -1
				}
			}
			append(&others, o.additional)
		}
		out.keys = o.keys if o.keys != rules.NONE else out.keys
		out.patterns = o.patterns if len(o.patterns) > 0 else out.patterns
		out.dependents = o.dependents if len(o.dependents) > 0 else out.dependents
	}
	out.members, out.additional = members[:], joined_of(s, others[:])
	return block(&s.d.objects, out)
}

// A node that passes each of `nodes`: NONE for none, the one, or a new conjunction of them.
@(private = "file")
joined_of :: proc(s: ^Source, nodes: []rules.Node_Index) -> rules.Node_Index {
	switch len(nodes) {
	case 0:
		return rules.NONE
	case 1:
		return nodes[0]
	}
	append(&s.d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, all_of = slice.clone(nodes)})
	return rules.Node_Index(len(s.d.nodes) - 1)
}

@(private = "file")
block :: proc(blocks: ^[dynamic]$T, x: T) -> i32 {
	append(blocks, x)
	return i32(len(blocks) - 1)
}

// The kinds of node `at` where it judges nothing but kinds.
@(private = "file")
kinds_only :: proc(s: ^Source, at: rules.Node_Index) -> (kinds: rules.Kinds, plain: bool) {
	i := target(s, at)
	if i == rules.NONE {
		return
	}
	x := &s.d.nodes[i]
	return x.kinds, x.rules == {} && x.array < 0 && x.object < 0 && !x.integer_spelled && !x.has_enum && x.const_of == nil && len(x.any_of) == 0 && len(x.all_of) == 0 && len(x.one_of) == 0 && x.not == nil && x.cond == {} && x.ref == nil && x.dynamic_ref == nil && x.unevaluated_items == nil && x.unevaluated_properties == nil
}

// Whether node `at` takes null, which an arm of it may take. An operand past `depth` of operands is held not to.
@(private = "file")
takes_null :: proc(s: ^Source, at: rules.Node_Index, depth := 0) -> bool {
	i := settled(s, target(s, at))
	if i == rules.NONE {
		return true
	}
	n := s.d.nodes[i]
	if .Null not_in n.kinds || depth > 32 {
		return false
	}
	if x, has := n.not.?; has && takes_null(s, x, depth + 1) {
		return false
	}
	if test, has := n.cond.test.?; has {
		branch := n.cond.then if takes_null(s, test, depth + 1) else n.cond.other
		if x, set := branch.?; set && !takes_null(s, x, depth + 1) {
			return false
		}
	}
	if n.has_enum || n.const_of != nil {
		for v in (n.enum_of if n.has_enum else []core.Value{n.const_of.?}) {
			if core.kind(v) == .Null {
				return true
			}
		}
		return false
	}
	taken := 0
	for x in n.any_of {
		if takes_null(s, x, depth + 1) {
			return true
		}
	}
	for x in n.one_of {
		taken += int(takes_null(s, x, depth + 1))
	}
	return len(n.any_of) == 0 && (len(n.one_of) == 0 || taken == 1)
}

// The empty union that takes null alone, declared once.
@(private = "file")
null_type :: proc(s: ^Source) -> string {
	if s.null_type == "" {
		s.null_type = unique(&s.taken, "Null")
		append(&s.decls, Decl{name = s.null_type, text = strings.concatenate({s.null_type, " :: union {}\n"})})
	}
	return s.null_type
}

// The type of node `i`'s values of kind `kind`, with the node's rules on that kind.
@(private = "file")
kind_spelled :: proc(s: ^Source, i: rules.Node_Index, kind: rules.Kind, hint: string, held: bool) -> (out: Spelled) {
	n := &s.d.nodes[i]
	out.decl, out.rules = -1, rules_on(n.rules, kind)
	part := part_of(s, i, nil if card(kinds_apart(n.kinds)) == 1 else kind)
	carrier := false
	#partial switch kind {
	case .Bool:
		out.type = "bool"
	case .Integer:
		out.type, out.rules = integer_spelled(s, out.rules)
	case .Number:
		// A number whose bounds a double may not hold keeps its text, so a number past a double is not refused.
		out.type = "f64" if f64_holds(out.rules) else NUMBER_TEXT
		s.imports += {} if out.type == "f64" else {.Core}
	case .String:
		format := rules.format_of(out.rules.format)
		out.type = "string"
		switch {
		case !out.rules.assert_format && (!s.format_assert || out.rules.format_foreign) || format == .None:
			out.note = out.rules.format
			out.rules.format, out.rules.assert_format = "", false
		case CARRIED[format] != "":
			out.type, carrier = CARRIED[format], true
			out.rules.format, out.rules.assert_format = "", false
			s.imports += {.Time} if format == .Date_Time else {.Uuid} if format == .Uuid else {}
		case:
			out.rules.assert_format = true
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
	strings.write_quoted_string(&s.registers, tag_items(s, spelled.rules))
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
		out.min_items, out.max_items, out.unique = r.min_items, r.max_items, r.unique
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
	}
	for low, j in ([?]u64{r.min_length, r.min_items, r.min_members}) {
		if low > 0 {
			return MIN_KEYS[j]
		}
	}
	for high, j in ([?]Maybe(u64){r.max_length, r.max_items, r.max_members}) {
		if high != nil {
			return MAX_KEYS[j]
		}
	}
	return ""
}

// An `i64`, or a `u64` where no bound is negative and one passes `i64`'s range, and `r` with its bounds as the least
// and the greatest integer they take, left out where the type holds no other. A `multipleOf` of p/q in lowest terms
// takes the integers that p divides. A bound past both types' range is refused, and so are two bounds whose range
// neither type holds whole. With one bound, the type holds what it can of the range.
@(private = "file")
integer_spelled :: proc(s: ^Source, r: rules.Rules) -> (type: string, out: rules.Rules) {
	out = r
	out.minimum, out.maximum, out.multiple_of = "", "", ""
	out.exclusive_minimum, out.exclusive_maximum = false, false
	low, has_low := whole_bound(r.minimum, r.exclusive_minimum, true)
	high, has_high := whole_bound(r.maximum, r.exclusive_maximum, false)
	wide := has_low && low >= 0 && (has_high && high > i128(max(i64)) || low > i128(max(i64)))
	least := i128(0) if wide else i128(min(i64))
	most := i128(max(u64)) if wide else i128(max(i64))
	switch {
	case has_low && (low > most || has_high && low < least):
		refuse(s, "exclusiveMinimum" if r.exclusive_minimum else "minimum")
	case has_high && (high < least || has_low && high > most):
		refuse(s, "exclusiveMaximum" if r.exclusive_maximum else "maximum")
	}
	if has_low && low > least {
		out.minimum = whole_text(low)
	}
	if has_high && high < most {
		out.maximum = whole_text(high)
	}
	if r.multiple_of != "" {
		p, held := numerator(spell.decimal_of(r.multiple_of))
		if !held {
			refuse(s, "multipleOf")
		} else if p != 1 {
			out.multiple_of = whole_text(p)
		}
	}
	return "u64" if wide else "i64", out
}

// Past both integer types' range.
@(private = "file")
WIDE :: i128(1) << 80

// The least integer the bound `text` takes where `up`, else the greatest, `exclusive` leaving `text` out. WIDE and
// -WIDE stand for a bound past both integer types.
@(private = "file")
whole_bound :: proc(text: string, exclusive, up: bool) -> (v: i128, set: bool) {
	if text == "" {
		return
	}
	d := spell.decimal_of(text)
	digits := strings.concatenate({d.head, d.tail})
	fraction := false
	switch {
	case digits == "":
	case d.wide != "" && !d.wide_neg || d.point > 24:
		v = WIDE
	case d.wide != "" || d.point <= 0:
		fraction = true
	case:
		for c, j in transmute([]u8)digits {
			if j < int(d.point) {
				v = v * 10 + i128(c - '0')
			} else {
				fraction = true
			}
		}
		for _ in len(digits) ..< int(d.point) {
			v *= 10
		}
	}
	v = -v if d.neg else v
	switch {
	case fraction && up && !d.neg:
		v += 1
	case fraction && !up && d.neg:
		v -= 1
	case exclusive && !fraction:
		v += 1 if up else -1
	}
	return v, true
}

// The numerator of decimal `d` in lowest terms, false past a u64.
@(private = "file")
numerator :: proc(d: spell.Decimal) -> (p: i128, held: bool) {
	digits := strings.concatenate({d.head, d.tail})
	if d.wide != "" || len(digits) > 19 || d.point - i128(len(digits)) > 19 {
		return 0, false
	}
	for c in transmute([]u8)digits {
		p = p * 10 + i128(c - '0')
	}
	for _ in len(digits) ..< int(max(d.point, 0)) {
		p *= 10
	}
	for factor in ([2]i128{2, 5}) {
		for _ in d.point ..< i128(len(digits)) {
			if p % factor != 0 {
				break
			}
			p /= factor
		}
	}
	return p, p <= i128(max(u64))
}

@(private = "file")
whole_text :: proc(v: i128) -> string {
	return strings.concatenate({"-", uint_text(u64(-v))}) if v < 0 else uint_text(u64(v))
}

// A list of the node's items, or a fixed array where the node closes a prefix whose elements are of one type.
@(private = "file")
array_spelled :: proc(s: ^Source, i: rules.Node_Index, part: Part, r: rules.Rules, hint: string, held: bool) -> Spelled {
	n := s.d.nodes[i]
	a := s.d.arrays[n.array] if n.array >= 0 else rules.Array{items = rules.NONE}
	out := Spelled{decl = -1, rules = r}
	element := strings.concatenate({hint, "_Item"})
	append(&s.path, core.All{})
	// A unique list's elements are compared as they are written.
	s.whole += int(r.unique)
	unfixed := false
	if len(a.prefix) > 0 {
		element_type := ""
		unfixed = r.min_items != u64(len(a.prefix)) || (r.max_items.? or_else 0) != u64(len(a.prefix))
		for x, j in a.prefix {
			item := odin_type(s, x, element, true)
			t := member_type(s, item)
			// A pointer element takes null, which a fixed array's element may not.
			unfixed ||= j > 0 && t != element_type || strings.has_prefix(t, "^") && !takes_null(s, x)
			element_type = t
		}
		out.type = strings.concatenate({"[", int_text(len(a.prefix)), "]", element_type})
		out.rules.min_items, out.rules.max_items = 0, nil
	} else {
		item := odin_type(s, a.items, element, true)
		out.type = strings.concatenate({"[]", held_type(item)})
		// A list's element has a size.
		if item.type == s.null_type && !item.null {
			refuse(s, "type")
		}
	}
	s.whole -= int(r.unique)
	pop(&s.path)
	if unfixed {
		refuse(s, "prefixItems")
	}
	if !held || rules_on(out.rules, .Array) == {} {
		return out
	}
	return distinct_spelled(s, part, out, hint)
}

// A map of the node's other members where it names none, else a struct of its members, with a map of the other
// members where a schema judges them.
@(private = "file")
object_spelled :: proc(s: ^Source, i: rules.Node_Index, part: Part, r: rules.Rules, hint: string, held: bool) -> Spelled {
	n := s.d.nodes[i]
	o := s.d.objects[n.object] if n.object >= 0 else rules.Object{additional = rules.NONE, keys = rules.NONE}
	other := o.additional
	forbids := false
	if kinds, plain := kinds_only(s, other); plain {
		other = rules.NONE if kinds == rules.EVERY_KIND else other
		forbids = kinds == {}
	}
	if len(o.members) == 0 && !forbids {
		append(&s.path, core.All{})
		value := odin_type(s, other, strings.concatenate({hint, "_Value"}), true)
		pop(&s.path)
		out := Spelled{type = strings.concatenate({"map[string]", held_type(value)}), rules = r, decl = -1}
		if !held || rules_on(r, .Object) == {} {
			return out
		}
		return distinct_spelled(s, part, out, hint)
	}
	if r.min_members > 0 || r.max_members != nil {
		refuse(s, first_keyword(r))
	}
	k := declare(s, part, hint)
	s.decls[k].null = part.kind == nil && .Null in n.kinds
	name := s.decls[k].name
	b := strings.builder_make()
	comment(&b, "", n.description)
	strings.write_string(&b, name)
	strings.write_string(&b, " :: struct {\n")
	fields := make(map[string]bool)
	n_unset := 0
	for m in o.members {
		if m.only_required && forbids {
			refuse(s, "required")
		}
		node := other if m.only_required else m.node
		append(&s.path, core.Name(m.name))
		// A member named "" has no field name, and is refused at its own path.
		if m.name == "" {
			refuse(s, "properties")
		}
		field_type := spelled_as_is(m.name, true)
		value := odin_type(s, node, strings.concatenate({name, "_", field_type if field_type != "" else "Member"}), false)
		clash := ""
		value.rules, clash = rules.merged(&rules.Node{rules = value.rules}, m.rules)
		if clash != "" {
			refuse(s, clash)
		}
		pop(&s.path)
		field := unique(&fields, spelled_as_is(m.name, false) if spelled_as_is(m.name, false) != "" else "member")
		if at := target(s, node); at != rules.NONE {
			comment(&b, "\t", s.d.nodes[at].description)
		}
		if value.note != "" {
			comment(&b, "\t", strings.concatenate({"format: ", value.note}))
		}
		strings.write_byte(&b, '\t')
		strings.write_string(&b, field)
		strings.write_string(&b, ": ")
		t := member_type(s, value)
		// An optional member that takes no null is nil when absent, which a write leaves out: a `Maybe`, or the pointer
		// of a struct that holds itself.
		absent := !m.required && !takes_null(s, node)
		if absent && !strings.has_prefix(t, "^") && !strings.has_prefix(t, "Maybe(") {
			t = strings.concatenate({"Maybe(", t, ")"})
		}
		strings.write_string(&b, t)
		// A nullable optional member tells absent from null by its struct's `Fields_Set`.
		unset := !m.required && takes_null(s, node)
		n_unset += int(unset)
		member_tag(s, &b, name, m, field, value.rules, (absent || strings.has_prefix(t, "^") || t == NUMBER_TEXT) && !takes_null(s, node), absent, unset)
		strings.write_string(&b, ",\n")
		if !m.required {
			default_spelled(s, name, field, node, value)
		}
	}
	if n_unset > 0 {
		if len(o.members) > 128 {
			refuse(s, "properties")
		}
		strings.write_byte(&b, '\t')
		strings.write_string(&b, unique(&fields, "set"))
		strings.write_string(&b, ": model.Fields_Set,\n")
	}
	// A whole struct keeps the members it does not declare.
	if (other != rules.NONE || part.whole) && !forbids {
		append(&s.path, core.All{})
		value := odin_type(s, other, strings.concatenate({name, "_Value"}), true)
		pop(&s.path)
		strings.write_byte(&b, '\t')
		strings.write_string(&b, unique(&fields, "extra"))
		strings.write_string(&b, ": map[string]")
		strings.write_string(&b, held_type(value))
		strings.write_string(&b, " `json:\",unknown\"`,\n")
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

// Adds to `register` the `default` of node `at`, the value of member `field` of `owner`, which `v` spells: a string, a
// number or a boolean of a member whose type is that scalar. A null default is the zero of the optional member, and any
// other default, which no literal of the member's type holds, is refused.
@(private = "file")
default_spelled :: proc(s: ^Source, owner, field: string, at: rules.Node_Index, v: Spelled) {
	x, has := s.d.nodes[at].default_of.?
	if !has {
		if found := target(s, at); found != rules.NONE {
			x, has = s.d.nodes[found].default_of.?
		}
	}
	kind := core.value_kind(x)
	if !has || kind == .Null {
		return
	}
	base := v.type
	if v.decl >= 0 {
		base = strings.trim_space(strings.trim_prefix(s.decls[v.decl].text, strings.concatenate({v.type, " :: distinct "})))
	}
	b := strings.builder_make()
	x = core.plain(x)
	#partial switch kind {
	case .String:
		if base != "string" && base != "model.Email" {
			refuse(s, "default")
			return
		}
		node, is_node := x.(core.Node_Ref)
		strings.write_string(&b, v.type)
		strings.write_byte(&b, '(')
		literal(&b, core.node_string(node.doc, node.node) if is_node else x.(string) or_else "")
		strings.write_byte(&b, ')')
	case .Number:
		text, held := default_number(x, base)
		if !held {
			refuse(s, "default")
			return
		}
		if base == NUMBER_TEXT {
			strings.write_string(&b, text)
		} else {
			strings.write_string(&b, v.type)
			strings.write_byte(&b, '(')
			strings.write_string(&b, text)
			strings.write_byte(&b, ')')
		}
	case .True, .False:
		if base != "bool" {
			refuse(s, "default")
			return
		}
		strings.write_string(&b, v.type)
		strings.write_string(&b, "(true)" if kind == .True else "(false)")
	case:
		refuse(s, "default")
		return
	}
	s.defaults = true
	strings.write_string(&s.registers, "\tmodel.register_default(reg, ")
	strings.write_string(&s.registers, owner)
	strings.write_string(&s.registers, ", ")
	strings.write_quoted_string(&s.registers, field)
	strings.write_string(&s.registers, ", ")
	strings.write_string(&s.registers, strings.to_string(b))
	strings.write_string(&s.registers, ") or_return\n")
}

// The type of a member's number that a double may not hold, which keeps the number's text.
@(private = "file")
NUMBER_TEXT :: "core.Number_Text"

// Whether every number rules `r` take is one a double holds: both bounds are set and finite.
@(private = "file")
f64_holds :: proc(r: rules.Rules) -> bool {
	low, low_ok := strconv.parse_f64(r.minimum)
	high, high_ok := strconv.parse_f64(r.maximum)
	return low_ok && high_ok && abs(low) <= max(f64) && abs(high) <= max(f64)
}

// The Odin literal of the number `x` as a value of the number type `base`, and whether `base` holds it: an integer of
// the type's range, for `f64` any number a double holds, and for a number text any number.
@(private = "file")
default_number :: proc(x: core.Value, base: string) -> (string, bool) {
	text := ""
	#partial switch v in x {
	case core.Node_Ref:
		text = string(core.span(v.doc, v.node))
	case ^core.Number_Text:
		text = v.text
	case f64:
		digits: [spell.F64_ROOM]u8
		text = strings.clone(string(digits[:spell.f64_text(&digits[0], v)]))
	}
	text, _ = strings.replace_all(text, "E", "e")
	n, _ := core.number(x)
	switch base {
	case NUMBER_TEXT:
		return strings.concatenate({NUMBER_TEXT, "{\"", text, "\", core.text_f64(\"", text, "\")}"}), true
	case "f64":
		return text, n.kind != .Wide
	case "i64", "u64":
		whole, set := whole_bound(text, false, true)
		least := i128(0) if base == "u64" else i128(min(i64))
		most := i128(max(u64)) if base == "u64" else i128(max(i64))
		floor, _ := whole_bound(text, false, false)
		return whole_text(whole), set && floor == whole && whole >= least && whole <= most
	}
	return "", false
}

// The tag of member `m`: its JSON name where the field's differs, `omitempty` where a write leaves it out when nil,
// `optional` where it is not required, `not_null` on a `Maybe` or a pointer that does not take null, and its rules. A tag Odin's raw
// string cannot hold is a quoted one.
@(private = "file")
member_tag :: proc(s: ^Source, b: ^strings.Builder, owner: string, m: rules.Member, field: string, r: rules.Rules, not_null: bool, omit := false, unset := false) {
	r := r
	if strings.contains_any(r.pattern, "\",") {
		// A struct tag cannot hold a quote, and a `pattern=` item, which takes the rest of the tag, refuses text after a
		// comma that reads as another item, so `register` adds such a pattern as the member's rule.
		strings.write_string(&s.registers, "\tmodel.register_field(reg, {")
		strings.write_string(&s.registers, owner)
		strings.write_string(&s.registers, ", ")
		strings.write_quoted_string(&s.registers, field)
		strings.write_string(&s.registers, ", ")
		strings.write_quoted_string(&s.registers, strings.concatenate({"pattern=", r.pattern}))
		strings.write_string(&s.registers, "}) or_return\n")
		r.pattern = ""
	}
	tag := strings.builder_make()
	named := field != m.name || omit || unset
	if named {
		strings.write_string(&tag, "json:\"")
		// A tag of `-` alone leaves the field out, and an empty name keeps the field's.
		for c in transmute([]u8)m.name if field != m.name else nil {
			if c == '\\' || c == ',' || c == '"' || m.name == "-" {
				strings.write_byte(&tag, '\\')
			}
			strings.write_byte(&tag, c)
		}
		strings.write_string(&tag, ",omitempty" if omit else "")
		strings.write_string(&tag, ",omitunset\"" if unset else "\"")
	}
	items := tag_items(s, r, !m.required, not_null)
	if items != "" {
		strings.write_string(&tag, " model:\"" if named else "model:\"")
		strings.write_string(&tag, items)
		strings.write_string(&tag, "\"")
	}
	text := strings.to_string(tag)
	raw := true
	for c in transmute([]u8)text {
		raw &&= c >= ' ' && c != '`' && c != 0x7f || c == '\t' || c == '\n'
	}
	switch {
	case text == "":
	case raw:
		strings.write_string(b, " `")
		strings.write_string(b, text)
		strings.write_byte(b, '`')
	case:
		strings.write_byte(b, ' ')
		strings.write_quoted_string(b, text)
	}
}

// `r` as the items of a `model:` tag, the pattern last since it takes the rest of the tag.
@(private = "file")
tag_items :: proc(s: ^Source, r: rules.Rules, optional := false, not_null := false) -> string {
	b := strings.builder_make()
	item :: proc(b: ^strings.Builder, parts: ..string) {
		if strings.builder_len(b^) > 0 {
			strings.write_byte(b, ',')
		}
		for p in parts {
			strings.write_string(b, p)
		}
	}
	if optional {
		item(&b, "optional")
	}
	if not_null {
		item(&b, "not_null")
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
	if r.unique {
		item(&b, "unique")
	}
	if r.format != "" {
		item(&b, "format=", r.format)
	}
	if r.pattern != "" {
		item(&b, "pattern=", r.pattern)
	}
	return strings.to_string(b)
}

// The type of an `enum` or `const`: an enum of its strings by their names, one of its integers by number, `bool` for
// both booleans, null alone `Null`, and a union of these for operands of several kinds. The operands that fail the
// node's kinds or rules are left out.
@(private = "file")
enum_spelled :: proc(s: ^Source, i: rules.Node_Index, hint: string) -> (out: Spelled) {
	n := s.d.nodes[i]
	out.decl = -1
	keyword := "enum" if n.has_enum else "const"
	values := n.enum_of if n.has_enum else []core.Value{n.const_of.?}
	if n.has_enum && n.const_of != nil {
		refuse(s, "const")
		return
	}
	kinds := n.kinds + ({.Integer} if .Number in n.kinds else {})
	judged := rules.Node{kinds = n.kinds, rules = n.rules, array = -1, object = -1}
	judged.rules.assert_format ||= s.format_assert && !n.rules.format_foreign
	leaf, refused := rules.leaf_of(&judged, {})
	if refused != "" {
		refuse(s, refused)
		return
	}
	scratch: regex.Scratch
	defer regex.scratch_destroy(&scratch)
	texts := make([dynamic]string)
	numbers := make([dynamic]i64)
	truth: [2]bool
	for v in values {
		switch core.kind(v) {
		case .Null:
			out.null ||= .Null in kinds
		case .True, .False:
			truth[int(core.kind(v) == .True)] ||= .Bool in kinds
		case .String:
			room: [dynamic]u8
			if ref, is_ref := v.(core.Node_Ref); is_ref {
				resize(&room, core.text_room(ref.doc, ref.node))
			}
			text, _ := core.text(v, room[:])
			if .String in kinds && rules.judge_string(&leaf, text, &scratch) == {} && !slice.contains(texts[:], text) {
				append(&texts, text)
			}
		case .Number:
			f, digits, _ := core.double_of(v)
			fits := abs(f) <= 1 << 53
			x := i64(f) if fits else 0
			whole := !fits || f64(x) == f
			if digits != "" {
				d := spell.decimal_of(digits)
				whole = rules.integral(d)
				x, fits = rules.decimal_i64(d)
				fits &&= x >= -(1 << 53) && x <= 1 << 53
			}
			passes := digits == "" || rules.judge_number(&leaf, digits, x if fits else nil) == {}
			switch {
			case !passes || .Integer not_in kinds || !whole && .Number not_in kinds:
			case !whole || !fits:
				// An Odin enum holds integers, and the model writes an enum's operands as doubles.
				refuse(s, keyword)
			case !slice.contains(numbers[:], x):
				append(&numbers, x)
			}
		case .Array, .Object, .Plain, .End:
			refuse(s, keyword)
			return
		}
	}
	if truth[0] != truth[1] {
		refuse(s, keyword)
		return
	}
	classes := int(len(texts) > 0) + int(len(numbers) > 0) + int(truth[0])
	switch {
	case classes == 0 && out.null:
		return {type = null_type(s), decl = -1}
	case classes == 0:
		refuse(s, keyword)
		return
	case classes == 1 && truth[0]:
		out.type = "bool"
		return
	case classes == 1:
		out.decl = enum_declared(s, part_of(s, i), n.description, texts[:], numbers[:], hint)
		out.type = s.decls[out.decl].name
		return
	}
	k := declare(s, part_of(s, i), hint)
	name := s.decls[k].name
	b := strings.builder_make()
	comment(&b, "", n.description)
	strings.write_string(&b, name)
	strings.write_string(&b, " :: union {" if out.null else " :: union #no_nil {")
	if len(texts) > 0 {
		arm := enum_declared(s, part_of(s, i, .String), "", texts[:], nil, strings.concatenate({name, "_String"}))
		strings.write_string(&b, s.decls[arm].name)
	}
	if len(numbers) > 0 {
		arm := enum_declared(s, part_of(s, i, .Integer), "", nil, numbers[:], strings.concatenate({name, "_Integer"}))
		strings.write_string(&b, ", " if len(texts) > 0 else "")
		strings.write_string(&b, s.decls[arm].name)
	}
	strings.write_string(&b, ", bool}\n" if truth[0] else "}\n")
	s.decls[k].text, s.decls[k].open = strings.to_string(b), false
	return {type = name, decl = k}
}

// The declaration of an enum of `texts` by their names, or of `numbers`, with what `register` adds for it.
@(private = "file")
enum_declared :: proc(s: ^Source, part: Part, description: string, texts: []string, numbers: []i64, hint: string) -> int {
	k := declare(s, part, hint)
	name := s.decls[k].name
	b := strings.builder_make()
	comment(&b, "", description)
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
			strings.write_quoted_string(&renames, member)
			strings.write_string(&renames, ", ")
			strings.write_quoted_string(&renames, x)
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
	return k
}

// A union of `anyOf`'s or `oneOf`'s arms, or of the node's kinds each with its rules. Arms that share a kind are read
// by first match, and under `oneOf` a value two arms read is refused. A false arm adds nothing, and a null one makes
// the union's nil, which two arms of a `oneOf` may not take.
@(private = "file")
arms_spelled :: proc(s: ^Source, i: rules.Node_Index, hint: string) -> (out: Spelled) {
	n := s.d.nodes[i]
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
	overlap, null_twice := false, false
	for x in (n.any_of if len(n.any_of) > 0 else n.one_of) {
		at := settled(s, target(s, x))
		if at == rules.NONE || s.refused.kind != .None {
			return
		}
		arm := s.d.nodes[at]
		plain := arm.rules == {} && arm.array < 0 && arm.object < 0 && !arm.has_enum && arm.const_of == nil && len(arm.any_of) == 0 && len(arm.one_of) == 0
		null_twice ||= len(n.one_of) > 0 && null && .Null in arm.kinds
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
	case null_twice:
		refuse(s, "oneOf")
		return
	case len(arms) == 0 && null:
		return {type = null_type(s), decl = -1}
	case len(arms) == 0:
		refuse(s, "false")
		return
	case len(arms) == 1 && arms[0].kind == nil:
		out = odin_type(s, arms[0].node, hint, true)
		out.null ||= null
		return
	}
	k := declare(s, part_of(s, i), hint)
	name := s.decls[k].name
	types := make([dynamic]string)
	for a, j in arms {
		arm_hint := strings.concatenate({name, "_", KIND_NAMES[a.kind.?] if a.kind != nil else int_text(j + 1)})
		value := kind_spelled(s, a.node, a.kind.?, arm_hint, true) if a.kind != nil else odin_type(s, a.node, arm_hint, true)
		// A union's nil reads null, so no arm of a `oneOf` may take null as well.
		if len(n.one_of) > 0 && !value.null && takes_null(s, a.node) {
			refuse(s, "oneOf")
		}
		null ||= value.null
		value.null = false
		// Two `oneOf` arms of one type pass the same values, so no value of theirs passes.
		if t := member_type(s, value); !slice.contains(types[:], t) {
			append(&types, t)
		} else if len(n.one_of) > 0 {
			refuse(s, "oneOf")
		}
	}
	b := strings.builder_make()
	comment(&b, "", n.description)
	strings.write_string(&b, name)
	// Arms that are all one type are that type.
	if len(types) == 1 && !null {
		strings.write_string(&b, " :: ")
		strings.write_string(&b, types[0])
		strings.write_string(&b, "\n")
		s.decls[k].text, s.decls[k].open = strings.to_string(b), false
		return {type = name, decl = k}
	}
	strings.write_string(&b, " :: union {" if null else " :: union #no_nil {")
	for t, j in types {
		strings.write_string(&b, ", " if j > 0 else "")
		strings.write_string(&b, t)
	}
	strings.write_string(&b, "}\n")
	s.decls[k].text, s.decls[k].open = strings.to_string(b), false
	if overlap {
		strings.write_string(&s.registers, "\tmodel.register_union(reg, {")
		strings.write_string(&s.registers, name)
		strings.write_string(&s.registers, ", .One_Match, \"\"}) or_return\n" if len(n.one_of) > 0 else ", .First_Match, \"\"}) or_return\n")
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
// pointer, which takes null unless a rule says not.
@(private = "file")
member_type :: proc(s: ^Source, v: Spelled) -> string {
	if v.decl >= 0 && s.decls[v.decl].open {
		return strings.concatenate({"^", v.type})
	}
	return held_type(v)
}

// The type of a value held behind a list or a map, which a struct or union being written may be.
@(private = "file")
held_type :: proc(v: Spelled) -> string {
	return strings.concatenate({"Maybe(", v.type, ")"}) if v.null else v.type
}

// A new declaration of `part`, open, named for the node or by `hint`.
@(private = "file")
declare :: proc(s: ^Source, part: Part, hint: string) -> int {
	name := ""
	if part.kind == nil {
		name = spelled_as_is(s.d.names[part.node] or_else s.d.nodes[part.node].title, true)
	}
	append(&s.decls, Decl{name = unique(&s.taken, name if name != "" else hint), open = true})
	s.of_node[part] = len(s.decls) - 1
	return len(s.decls) - 1
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
// lowercased for a field. A word splits where a lowercase letter meets an uppercase one. A keyword takes a trailing
// `_`, and a leading digit a leading `_`.
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
	return strings.concatenate({out, "_"}) if slice.contains(KEYWORDS[:], out) else out
}

// Whether `name` may name the package: an ASCII identifier, no keyword, and no package a program that holds the source
// imports, since Odin keeps a program's package names apart.
@(private = "file")
package_spelled :: proc(name: string) -> bool {
	if name == "" || name == "_" || slice.contains(KEYWORDS[:], name) || slice.contains(PACKAGES[:], name) {
		return false
	}
	for c, j in transmute([]u8)name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || j > 0 && c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

// The packages the source's imports reach.
@(private = "file", rodata)
PACKAGES := [?]string {
	"_blake2", "_sha3", "_subtle", "blake2b", "blake2s", "bufio", "build", "builtin", "bytes", "c", "compose",
	"container_queue", "core", "crypto", "crypto_hash", "darwin", "datetime", "encoding_base64", "encoding_endian", "fmt",
	"hash", "intrinsics", "io", "keccak", "kernel", "kqueue", "libc", "linux", "math", "math_bits", "md5", "mem",
	"mem_virtual", "model", "os", "posix", "rand", "records", "reflect", "regex", "rules", "runtime", "sha1", "sha2",
	"sha3", "simd", "simd_arm", "simd_x86", "slice", "sm3", "spell", "strconv", "strconv_decimal", "strings", "sync",
	"sys_valgrind", "sysinfo", "time", "typed", "unicode", "unix", "utf16", "utf8", "uuid", "windows", "write",
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

// Writes `text` as `//` lines after `indent`, a control byte but a tab as `\x` and its hex digits.
@(private = "file")
comment :: proc(b: ^strings.Builder, indent, text: string) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		strings.write_string(b, indent)
		strings.write_string(b, "//" if line == "" else "// ")
		for c in transmute([]u8)line {
			if c < ' ' && c != '\t' || c == 0x7f {
				hex := "0123456789abcdef"
				strings.write_string(b, "\\x")
				strings.write_byte(b, hex[c >> 4])
				strings.write_byte(b, hex[c & 15])
			} else {
				strings.write_byte(b, c)
			}
		}
		strings.write_byte(b, '\n')
	}
}

@(private = "file")
uint_text :: proc(n: u64) -> string {
	return string(strconv.write_uint(make([]u8, 24), n, 10))
}
