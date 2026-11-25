// Generates idiomatic Odin types (structs, enums, unions, distinct types, json:/model: tags, and `register` proc)
// from a `rules.Description`.
// Zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.
package schema

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

// Writes Odin source for package `package_name` describing the values of `d`.
// Returns generated source owned by `allocator`, or an `Error` (`.Bad_Option` for invalid package name,
// `.Unsupported` naming the first unspellable keyword).
@(require_results)
write_odin :: proc(d: ^rules.Description, package_name: string, format_assert := false, allocator := context.allocator) -> (source: string, err: Error) {
	if d == nil || d.root < 0 || int(d.root) >= len(d.nodes) {
		return "", make_error(.Bad_Option, "description", "empty description", allocator = allocator)
	}
	if !package_spelled(package_name) {
		return "", make_error(.Bad_Option, package_name, "invalid Odin package name", allocator = allocator)
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	local := d^
	local.nodes = slice.clone_to_dynamic(d.nodes[:], a)
	local.arrays = slice.clone_to_dynamic(d.arrays[:], a)
	local.objects = slice.clone_to_dynamic(d.objects[:], a)
	local.names = make(map[rules.Node_Index]string, len(d.names), a)
	for k, v in d.names {
		local.names[k] = v
	}

	s, root := root_spelled(&local, format_assert, "Root", a, allocator)
	alias := root.decl != 0 || root.null
	if alias && s.taken["Root"] {
		s, root = root_spelled(&local, format_assert, "Root_Value", a, allocator)
	}
	if s.refused.kind != .None {
		return "", make_error(s.refused.kind, s.refused.keyword, s.refused.message, 0, s.refused.path, allocator)
	}

	b := strings.builder_make(a)
	odin_put(&b, "// The types of a schema's values, written by stury's schema.write_odin.\npackage ", package_name, "\n\n")
	if s.fragments {
		s.imports += {.Schema}
	}
	if !s.defaults || s.fragments {
		strings.write_string(&b, "import \"base:runtime\"\n")
	}
	for name, i in ODIN_IMPORTS {
		if Odin_Import(i) in s.imports {
			strings.write_string(&b, name)
		}
	}
	strings.write_string(&b, "import model \"stury:lib/schema/model\"\n")
	if alias {
		strings.write_string(&b, "\n")
		if root.note != "" {
			odin_comment(&b, "", strings.concatenate({"format: ", root.note}, a))
		}
		odin_put(&b, odin_unique(&s.taken, "Root", a), " :: ", odin_held_type(root, a), "\n")
	}
	for x in s.decls {
		odin_put(&b, "\n", x.text)
	}
	odin_put(
		&b,
		"\n// Adds the rules of these types that their tags do not hold to `reg`, before `model.compile`.\n",
		"register :: proc(reg: ^model.Registry) -> ",
		"model.Error {\n" if (s.fragments || s.defaults) else "runtime.Allocator_Error {\n",
		strings.to_string(s.registers),
		"\treturn nil\n}\n",
	)
	if s.fragments {
		strings.write_string(&b, REGISTER_FRAGMENT)
	}
	out, cloned := strings.clone(strings.to_string(b), allocator)
	if cloned != nil {
		return "", make_error(.No_Memory, "", "out of memory", allocator = allocator)
	}
	return out, {}
}

@(private = "file")
REGISTER_FRAGMENT ::
	"\n// Adds the JSON Schema `text` to the rules of `T`.\n" +
	"register_fragment :: proc(reg: ^model.Registry, T: typeid, text: string) -> model.Error {\n" +
	"\ts, serr := schema.compile_json(transmute([]u8)text)\n" +
	"\tif serr.kind != .None {\n" +
	"\t\tkind := serr.kind\n" +
	"\t\tschema.error_destroy(&serr)\n" +
	"\t\treturn runtime.Allocator_Error.Out_Of_Memory if kind == .No_Memory else runtime.Allocator_Error.Invalid_Argument\n" +
	"\t}\n" +
	"\tdefer schema.destroy(s)\n" +
	"\tmodel.register_schema(reg, T, s.description) or_return\n" +
	"\treturn nil\n" +
	"}\n"

@(private = "file")
root_spelled :: proc(d: ^rules.Description, format_assert: bool, hint: string, a, backing: runtime.Allocator) -> (s: Source, root: Spelled) {
	s = Source {
		d             = d,
		format_assert = format_assert,
		originals     = len(d.nodes),
		a             = a,
		backing       = backing,
		decls         = make([dynamic]Decl, a),
		of_node       = make(map[Odin_Part]int, 16, a),
		taken         = make(map[string]bool, 32, a),
		spelling      = make(map[Odin_Part]bool, 16, a),
		joined        = make(map[string]rules.Node_Index, 8, a),
		registers     = strings.builder_make(a),
		path          = make([dynamic]tape.Step, a),
	}
	s.taken["Maybe"] = true
	root = odin_type(&s, d.root, hint, true)
	return
}

@(private = "file")
Odin_Import :: enum u8 {
	Uuid,
	Time,
	Rules,
	Schema,
}

@(private = "file", rodata)
ODIN_IMPORTS := [Odin_Import]string {
	.Uuid   = "import \"core:encoding/uuid\"\n",
	.Time   = "import \"core:time\"\n",
	.Rules  = "import rules \"stury:lib/schema/rules\"\n",
	.Schema = "import schema \"stury:lib/schema/schema\"\n",
}

@(private = "file")
Judged_Bind :: struct {
	inner:  Odin_Part,
	outer:  Odin_Part,
	active: bool,
}

@(private = "file")
Source :: struct {
	d:             ^rules.Description,
	format_assert: bool,
	fragments:     bool,
	defaults:      bool,
	decls:         [dynamic]Decl,
	of_node:       map[Odin_Part]int,
	taken:         map[string]bool,
	spelling:      map[Odin_Part]bool,
	joined:        map[string]rules.Node_Index,
	originals:     int,
	null_type:     string,
	registers:     strings.Builder,
	imports:       bit_set[Odin_Import],
	path:          [dynamic]tape.Step,
	refused:       Error,
	whole:         int,
	judged_bind:   Judged_Bind,
	a:             runtime.Allocator,
	backing:       runtime.Allocator,
}

@(private = "file")
Odin_Part :: struct {
	node:  rules.Node_Index,
	kind:  Maybe(rules.Kind),
	whole: bool,
}

@(private = "file")
part_of :: proc "contextless" (s: ^Source, i: rules.Node_Index, kind: Maybe(rules.Kind) = nil) -> Odin_Part {
	return {i, kind, s.whole > 0 && s.d.nodes[i].kinds & {.Array, .Object} != {}}
}

@(private = "file")
Decl :: struct {
	name:     string,
	text:     string,
	open:     bool,
	null:     bool,
	literals: map[string]string,
	arms:     map[rules.Kind]Spelled,
}

@(private = "file")
Spelled :: struct {
	type:  string,
	rules: rules.Rules,
	decl:  int,
	null:  bool,
	note:  string,
}

@(private = "file")
odin_refuse :: proc(s: ^Source, keyword: string) {
	if s.refused.kind != .None {
		return
	}
	s.refused = Error {
		kind    = .Unsupported,
		keyword = keyword,
		message = "unsupported keyword for Odin code generation",
		path    = steps_clone(s.path[:], s.a),
	}
}

@(private = "file")
odin_type :: proc(s: ^Source, at: rules.Node_Index, hint: string, held: bool) -> (out: Spelled) {
	out.decl = -1
	i := settled(s, odin_target(s, at))
	if i == rules.NONE {
		s.imports += {.Rules}
		out.type = "rules.Value"
		return
	}
	part := part_of(s, i)
	if k, ok := s.of_node[part]; ok {
		return {type = s.decls[k].name, decl = k, null = s.decls[k].null}
	}
	if s.spelling[part] || s.refused.kind != .None {
		odin_refuse(s, "$ref")
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
	if keyword := unspelled(&n); keyword != "" {
		odin_refuse(s, keyword)
		return
	}
	if odin_judged(s, &n) {
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
		odin_refuse(s, "false")
		return
	case kinds == rules.EVERY_KIND && n.rules == {} && n.array < 0 && n.object < 0:
		s.imports += {.Rules}
		out.type = "rules.Value"
		return
	case count == 1:
		out = kind_spelled(s, i, one, hint, held)
		out.null = .Null in kinds
		return
	}
	return arms_spelled(s, i, hint)
}

@(private = "file")
odin_target :: proc(s: ^Source, i: rules.Node_Index) -> rules.Node_Index {
	end, _ := rules.ref_end(s.d, i)
	if end == rules.NONE && i != rules.NONE {
		odin_refuse(s, "$ref")
	}
	return end
}

@(private = "file")
kinds_apart :: proc "contextless" (kinds: rules.Kinds) -> rules.Kinds {
	k := kinds - {.Null}
	if .Number in k {
		k -= {.Integer}
	}
	return k
}

@(private = "file")
unspelled :: proc "contextless" (n: ^rules.Node) -> string {
	switch {
	case n.integer_spelled:
		return "type"
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

@(private = "file")
odin_judged :: proc(s: ^Source, n: ^rules.Node) -> bool {
	if enums, _ := enum_judged(s, n); n.not != nil || n.cond != {} || enums {
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

@(private = "file")
judged_spelled :: proc(s: ^Source, i: rules.Node_Index, hint: string, held: bool) -> (out: Spelled) {
	out.decl = -1
	n := s.d.nodes[i]
	outer := part_of(s, i)
	base := n
	base.not, base.cond = nil, {}
	enums, operands := enum_judged(s, &n)
	if enums {
		base.has_enum, base.enum_of, base.const_of = false, nil, nil
		base.kinds = operands.kinds
	}
	kinds_null := .Null in n.kinds && len(n.any_of) == 0 && len(n.one_of) == 0
	if kinds_null {
		base.kinds -= {.Null}
	}
	a: rules.Array
	if n.array >= 0 && .Array in n.kinds {
		a = s.d.arrays[n.array]
		x := a
		x.contains, x.min_contains, x.max_contains = nil, nil, nil
		base.array = add_block(&s.d.arrays, x)
	}
	o := rules.Object{additional = rules.NONE, keys = rules.NONE}
	pattern_extra, pattern_other := false, false
	if n.object >= 0 && .Object in n.kinds {
		o = s.d.objects[n.object]
		kinds, plain := kinds_only(s, o.additional)
		pattern_extra = len(o.patterns) == 1 && o.keys == rules.NONE && o.additional != rules.NONE && plain && kinds == {}
		pattern_other = len(o.patterns) > 0 && o.additional != rules.NONE && (!plain || kinds != rules.EVERY_KIND) && !pattern_extra
		x := o
		x.keys, x.patterns, x.dependents = rules.NONE, nil, nil
		if pattern_extra {
			x.additional = o.patterns[0].node
			o.keys = names_node(s, o)
		} else if pattern_other {
			x.additional = rules.NONE
		}
		base.object = add_block(&s.d.objects, x)
	}
	at := node_added(s, base)
	if name, named := s.d.names[i]; named {
		s.d.names[at] = name
	}
	s.whole += 1
	inner := part_of(s, at)
	saved_bind := s.judged_bind
	s.judged_bind = {inner = inner, outer = outer, active = true}
	out = node_spelled(s, at, hint, held)
	s.judged_bind = saved_bind
	s.whole -= 1
	switch {
	case kinds_null:
		out.null = takes_null(s, i)
	case (n.not != nil || n.cond != {}) && out.null && !takes_null(s, i):
		odin_refuse(s, "not" if n.not != nil else "if")
	}
	if s.refused.kind != .None {
		return
	}
	if k, own := s.of_node[inner]; !own || k != out.decl {
		k = odin_declare(s, inner, hint)
		s.decls[k].text = strings.concatenate({s.decls[k].name, " :: distinct ", out.type, "\n"}, s.a)
		s.decls[k].open = false
		out.type, out.decl = s.decls[k].name, k
	}
	s.of_node[outer] = out.decl

	f := rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, not = n.not, cond = n.cond, resource = n.resource}
	if enums {
		f.has_enum, f.enum_of, f.const_of = n.has_enum, n.enum_of, n.const_of
	}
	if c, has := a.contains.?; has {
		f.array = add_block(&s.d.arrays, rules.Array{items = rules.NONE, contains = c, min_contains = a.min_contains, max_contains = a.max_contains})
	}
	if o.keys != rules.NONE || len(o.patterns) > 0 || len(o.dependents) > 0 {
		x := rules.Object{additional = rules.NONE, keys = o.keys, patterns = nil if pattern_extra else o.patterns, dependents = o.dependents}
		if pattern_other {
			names := make([dynamic]rules.Member, s.a)
			any_val := odin_any_node(s)
			for m in o.members {
				if !m.only_required {
					append(&names, rules.Member{name = m.name, node = any_val})
				}
			}
			x.members, x.additional = names[:], o.additional
		}
		f.object = add_block(&s.d.objects, x)
	}
	first := "not" if n.not != nil else "if" if n.cond != {} else "enum" if n.has_enum else "const" if enums else "contains" if a.contains != nil else "propertyNames"
	fragment_registered(s, out.type, f, first)
	return
}

@(private = "file")
fragment_registered :: proc(s: ^Source, type: string, f: rules.Node, first: string) {
	root := node_added(s, f)
	fragment := s.d^
	fragment.root = root
	text, werr := write_schema(&fragment, {}, s.a)
	if werr.kind != .None {
		kw := werr.keyword if werr.keyword != "" else first
		odin_refuse(s, kw)
		return
	}
	s.fragments = true
	odin_put(&s.registers, "\tregister_fragment(reg, ", type, ", ")
	odin_literal(&s.registers, string(text))
	strings.write_string(&s.registers, ") or_return\n")
}

@(private = "file")
odin_literal :: proc(b: ^strings.Builder, text: string, newline := false) {
	raw := true
	for c in transmute([]u8)text {
		raw &&= (c >= ' ' && c != '`' && c != 0x7f) || c == '\t' || (newline && c == '\n')
	}
	if !raw {
		strings.write_quoted_string(b, text)
		return
	}
	odin_put(b, "`", text, "`")
}

@(private = "file")
names_node :: proc(s: ^Source, o: rules.Object) -> rules.Node_Index {
	b := strings.builder_make(s.a)
	if len(o.members) > 0 {
		strings.write_string(&b, "^(?:")
		for m, j in o.members {
			if j > 0 {
				strings.write_byte(&b, '|')
			}
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
		odin_put(&b, "|(?:" if strings.builder_len(b) > 0 else "(?:", p.expression, ")")
	}
	return node_added(s, rules.Node{kinds = {.String}, array = -1, object = -1, rules = {pattern = strings.to_string(b)}})
}

@(private = "file")
settled :: proc(s: ^Source, i: rules.Node_Index) -> rules.Node_Index {
	if i == rules.NONE || s.refused.kind != .None {
		return i
	}
	n := s.d.nodes[i]
	conjunction := len(n.all_of) > 0 || n.ref != nil || n.dynamic_ref != nil
	if !conjunction && n.not == nil && n.unevaluated_items == nil && n.unevaluated_properties == nil {
		return i
	}
	conjuncts := []rules.Node_Index{i}
	roots := make([dynamic]rules.Node_Index, s.a)
	append(&roots, i)
	for grown := conjunction; grown; {
		ways, complete := rules.branches(s.d, roots[:], false, 1, s.a, s.a)
		if !complete || len(ways) != 1 {
			odin_refuse(s, "allOf" if len(n.all_of) > 0 else "$ref")
			return i
		}
		conjuncts, grown = ways[0][:], false
		for c in conjuncts {
			if s.d.nodes[c].dynamic_ref != nil {
				end := dynamic_end(s, &s.d.nodes[c])
				if end == rules.NONE {
					return i
				}
				if !slice.contains(conjuncts, end) {
					append(&roots, end)
					grown = true
				}
			}
		}
	}
	key := strings.builder_make(s.a)
	sorted := slice.clone(conjuncts, s.a)
	slice.sort(sorted)
	ibuf: [24]u8 = ---
	for c in sorted {
		odin_put(&key, strconv.write_int(ibuf[:], i64(c), 10), ",")
	}
	ks := strings.to_string(key)
	if k, ok := s.joined[ks]; ok {
		return k
	}
	j := joined_node(s, i, conjuncts, conjunction)
	s.joined[ks] = j
	return j
}

@(private = "file")
dynamic_end :: proc(s: ^Source, n: ^rules.Node) -> rules.Node_Index {
	end := n.dynamic_ref.?
	if .Dynamic_Static in n.spelled {
		return end
	}
	for a in s.d.anchors {
		for b in s.d.anchors {
			if a.node == end && b.name == a.name && b.node != end {
				odin_refuse(s, rules.dynamic_keyword(n))
				return rules.NONE
			}
		}
	}
	return end
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
	arrays := make([dynamic]i32, s.a)
	objects := make([dynamic]i32, s.a)
	for c in conjuncts {
		x := s.d.nodes[c]
		clash := ""
		tmp := rules.Node{rules = out.rules}
		out.rules, clash = rules.merged(&tmp, x.rules)
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
		if c != top && x.unevaluated_items != nil {
			clash = "unevaluatedItems"
		} else if c != top && x.unevaluated_properties != nil {
			clash = "unevaluatedProperties"
		}
		if clash != "" {
			odin_refuse(s, clash)
			return top
		}
	}
	if .Array in out.kinds && len(arrays) > 0 {
		out.array = arrays[0]
		if len(arrays) > 1 {
			items := make([dynamic]rules.Node_Index, s.a)
			for a in arrays {
				x := s.d.arrays[a]
				if len(x.prefix) > 0 || x.contains != nil {
					odin_refuse(s, "prefixItems" if len(x.prefix) > 0 else "contains")
					return top
				}
				append(&items, x.items)
			}
			out.array = add_block(&s.d.arrays, rules.Array{items = joined_of(s, items[:])})
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
	if keyword != "" && (len(out.any_of) > 0 || len(out.one_of) > 0 || out.cond != {} || out.not != nil) {
		odin_refuse(s, keyword)
		return top
	}
	if u, has := t.unevaluated_properties.?; has && .Object in out.kinds {
		o := s.d.objects[out.object] if out.object >= 0 else rules.Object{additional = rules.NONE, keys = rules.NONE}
		if o.additional == rules.NONE {
			o.additional = u
			out.object = add_block(&s.d.objects, o)
		}
	}
	if u, has := t.unevaluated_items.?; has && .Array in out.kinds {
		a := s.d.arrays[out.array] if out.array >= 0 else rules.Array{items = rules.NONE}
		if a.items == rules.NONE {
			a.items = u
			out.array = add_block(&s.d.arrays, a)
		}
	}
	idx := node_added(s, out)
	if name, named := s.d.names[top]; named {
		s.d.names[idx] = name
	}
	return idx
}

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
	members := make([dynamic]rules.Member, s.a)
	for o in objects {
		for m in s.d.objects[o].members {
			at := -1
			for x, j in members {
				if x.name == m.name {
					at = j
				}
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
			tmp := rules.Node{rules = x.rules}
			x.rules, clash = rules.merged(&tmp, m.rules)
			if clash != "" {
				odin_refuse(s, clash)
				return -1
			}
			x.node = m.node if x.only_required else joined_of(s, {x.node, m.node})
			x.only_required = false
		}
	}
	others := make([dynamic]rules.Node_Index, s.a)
	for i in objects {
		o := s.d.objects[i]
		if o.additional != rules.NONE {
			for m in members {
				if !named(o, m.name) {
					odin_refuse(s, "additionalProperties")
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
	return add_block(&s.d.objects, out)
}

@(private = "file")
joined_of :: proc(s: ^Source, nodes: []rules.Node_Index) -> rules.Node_Index {
	switch len(nodes) {
	case 0: return rules.NONE
	case 1: return nodes[0]
	}
	return node_added(s, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, all_of = slice.clone(nodes, s.a)})
}

@(private = "file")
odin_any_node :: proc(s: ^Source) -> rules.Node_Index {
	return node_added(s, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1})
}

@(private = "file")
node_added :: proc(s: ^Source, n: rules.Node) -> rules.Node_Index {
	append(&s.d.nodes, n)
	return rules.Node_Index(len(s.d.nodes) - 1)
}

@(private = "file")
add_block :: proc(blocks: ^[dynamic]$T, x: T) -> i32 {
	append(blocks, x)
	return i32(len(blocks) - 1)
}

@(private = "file")
kinds_only :: proc(s: ^Source, at: rules.Node_Index) -> (kinds: rules.Kinds, plain: bool) {
	i := odin_target(s, at)
	if i == rules.NONE {
		return
	}
	x := &s.d.nodes[i]
	return x.kinds, x.rules == {} && x.array < 0 && x.object < 0 && !x.integer_spelled && !x.has_enum && x.const_of == nil &&
		len(x.any_of) == 0 && len(x.all_of) == 0 && len(x.one_of) == 0 && x.not == nil && x.cond == {} &&
		x.ref == nil && x.dynamic_ref == nil && x.unevaluated_items == nil && x.unevaluated_properties == nil
}

@(private = "file")
takes_null :: proc(s: ^Source, at: rules.Node_Index, depth := 0) -> bool {
	i := settled(s, odin_target(s, at))
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
		vals := n.enum_of if n.has_enum else []rules.Value{n.const_of.?}
		for v in vals {
			if rules.value_kind(v) == .Null {
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

@(private = "file")
null_type :: proc(s: ^Source) -> string {
	if s.null_type == "" {
		s.null_type = odin_unique(&s.taken, "Null", s.a)
		append(&s.decls, Decl{name = s.null_type, text = strings.concatenate({s.null_type, " :: union {}\n"}, s.a)})
	}
	return s.null_type
}

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
		out.type = "f64" if f64_holds(out.rules) else NUMBER_TEXT
	case .String:
		format := rules.format_of(out.rules.format)
		out.type = "string"
		switch {
		case (!out.rules.assert_format && (!s.format_assert || out.rules.format_foreign)) || format == .None:
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
		odin_refuse(s, first_keyword(out.rules))
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

@(private = "file")
distinct_spelled :: proc(s: ^Source, part: Odin_Part, spelled: Spelled, hint: string) -> Spelled {
	k := odin_declare(s, part, hint)
	name := s.decls[k].name
	s.decls[k].text = strings.concatenate({name, " :: distinct ", spelled.type, "\n"}, s.a)
	s.decls[k].open = false
	if items := tag_items(s, spelled.rules); items != "" {
		odin_put(&s.registers, "\tmodel.register_type(reg, {", name, ", ")
		strings.write_quoted_string(&s.registers, items)
		strings.write_string(&s.registers, "}) or_return\n")
	}
	return {type = name, decl = k}
}

@(private = "file")
rules_on :: proc "contextless" (r: rules.Rules, kind: rules.Kind) -> (out: rules.Rules) {
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
first_keyword :: proc "contextless" (r: rules.Rules) -> string {
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

@(private = "file")
integer_spelled :: proc(s: ^Source, r: rules.Rules) -> (type: string, out: rules.Rules) {
	out = r
	out.minimum, out.maximum, out.multiple_of = "", "", ""
	out.exclusive_minimum, out.exclusive_maximum = false, false
	low, has_low := whole_bound(r.minimum, r.exclusive_minimum, true, s.a)
	high, has_high := whole_bound(r.maximum, r.exclusive_maximum, false, s.a)
	wide := has_low && low >= 0 && ((has_high && high > i128(max(i64))) || low > i128(max(i64)))
	least := i128(0) if wide else i128(min(i64))
	most := i128(max(u64)) if wide else i128(max(i64))
	switch {
	case has_low && (low > most || (has_high && low < least)):
		odin_refuse(s, "exclusiveMinimum" if r.exclusive_minimum else "minimum")
	case has_high && (high < least || (has_low && high > most)):
		odin_refuse(s, "exclusiveMaximum" if r.exclusive_maximum else "maximum")
	}
	if has_low && low > least {
		out.minimum = whole_text(low, s.a)
	}
	if has_high && high < most {
		out.maximum = whole_text(high, s.a)
	}
	if r.multiple_of != "" {
		p, held := numerator(rules.decimal_of(r.multiple_of), s.a)
		if !held {
			odin_refuse(s, "multipleOf")
		} else if p != 1 {
			out.multiple_of = whole_text(p, s.a)
		}
	}
	return "u64" if wide else "i64", out
}

@(private = "file")
WIDE :: i128(1) << 80

@(private = "file")
whole_bound :: proc(text: string, exclusive, up: bool, a: runtime.Allocator) -> (v: i128, set: bool) {
	if text == "" {
		return
	}
	d := rules.decimal_of(text)
	digits := strings.concatenate({d.head, d.tail}, a)
	fraction := false
	switch {
	case digits == "":
	case (d.wide != "" && !d.wide_neg) || d.point > 24:
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

@(private = "file")
numerator :: proc(d: rules.Decimal, a: runtime.Allocator) -> (p: i128, held: bool) {
	digits := strings.concatenate({d.head, d.tail}, a)
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
whole_text :: proc(v: i128, a: runtime.Allocator) -> string {
	buf: [32]u8 = ---
	if v < 0 {
		return strings.concatenate({"-", strconv.write_uint(buf[:], u64(-v), 10)}, a)
	}
	return strings.clone(strconv.write_uint(buf[:], u64(v), 10), a)
}

@(private = "file")
array_spelled :: proc(s: ^Source, i: rules.Node_Index, part: Odin_Part, r: rules.Rules, hint: string, held: bool) -> Spelled {
	n := s.d.nodes[i]
	a := s.d.arrays[n.array] if n.array >= 0 else rules.Array{items = rules.NONE}
	out := Spelled{decl = -1, rules = r}
	element := strings.concatenate({hint, "_Item"}, s.a)
	append(&s.path, tape.All{})
	s.whole += int(r.unique) + int(len(a.prefix) > 0)
	tuple := len(a.prefix) > 0 && (r.min_items != u64(len(a.prefix)) || (r.max_items.? or_else 0) != u64(len(a.prefix)))
	ibuf: [24]u8 = ---
	if len(a.prefix) > 0 && !tuple {
		element_type := ""
		for x, j in a.prefix {
			t := odin_member_type(s, odin_type(s, x, element, true))
			tuple ||= (j > 0 && t != element_type) || (strings.has_prefix(t, "^") && !takes_null(s, x))
			element_type = t
		}
		out.type = strings.concatenate({"[", strconv.write_int(ibuf[:], i64(len(a.prefix)), 10), "]", element_type}, s.a)
		out.rules.min_items, out.rules.max_items = 0, nil
	}
	if len(a.prefix) == 0 || tuple {
		items := a.items
		if tuple {
			arms := slice.clone_to_dynamic(a.prefix, s.a)
			append(&arms, a.items if a.items != rules.NONE else odin_any_node(s))
			items = node_added(s, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, any_of = arms[:]})
		}
		item := odin_type(s, items, element, true)
		out.type, out.rules = strings.concatenate({"[]", odin_held_type(item, s.a)}, s.a), r
		if item.type == s.null_type && !item.null {
			odin_refuse(s, "type")
		}
	}
	s.whole -= int(r.unique) + int(len(a.prefix) > 0)
	pop(&s.path)
	if !tuple && (!held || rules_on(out.rules, .Array) == {}) {
		return out
	}
	out = distinct_spelled(s, part, out, hint)
	if tuple {
		f := rules.Node{kinds = rules.EVERY_KIND, array = add_block(&s.d.arrays, rules.Array{prefix = a.prefix, items = a.items}), object = -1, resource = n.resource}
		fragment_registered(s, out.type, f, "prefixItems")
	}
	return out
}

@(private = "file")
object_spelled :: proc(s: ^Source, i: rules.Node_Index, part: Odin_Part, r: rules.Rules, hint: string, held: bool) -> Spelled {
	n := s.d.nodes[i]
	o := s.d.objects[n.object] if n.object >= 0 else rules.Object{additional = rules.NONE, keys = rules.NONE}
	other := o.additional
	forbids := false
	if kinds, plain := kinds_only(s, other); plain {
		other = rules.NONE if kinds == rules.EVERY_KIND else other
		forbids = kinds == {}
	}
	if len(o.members) == 0 && !forbids {
		append(&s.path, tape.All{})
		value := odin_type(s, other, strings.concatenate({hint, "_Value"}, s.a), true)
		pop(&s.path)
		out := Spelled{type = strings.concatenate({"map[string]", odin_held_type(value, s.a)}, s.a), rules = r, decl = -1}
		if !held || rules_on(r, .Object) == {} {
			return out
		}
		return distinct_spelled(s, part, out, hint)
	}
	if r.min_members > 0 || r.max_members != nil {
		odin_refuse(s, first_keyword(r))
	}
	k := odin_declare(s, part, hint)
	s.decls[k].null = part.kind == nil && .Null in n.kinds
	name := s.decls[k].name
	b := strings.builder_make(s.a)
	odin_comment(&b, "", n.description)
	odin_put(&b, name, " :: struct {\n")
	fields := make(map[string]bool, len(o.members) + 2, s.a)
	for m in o.members {
		if m.only_required && forbids {
			odin_refuse(s, "required")
		}
		node := other if m.only_required else m.node
		append(&s.path, tape.Name(m.name))
		if m.name == "" {
			odin_refuse(s, "properties")
		}
		field_type := spelled_as_is(m.name, true, s.a)
		value := odin_type(s, node, strings.concatenate({name, "_", field_type if field_type != "" else "Member"}, s.a), false)
		clash := ""
		tmp := rules.Node{rules = value.rules}
		value.rules, clash = rules.merged(&tmp, m.rules)
		if clash != "" {
			odin_refuse(s, clash)
		}
		if at := settled(s, odin_target(s, node)); at != rules.NONE {
			value.rules.read_only ||= s.d.nodes[at].rules.read_only
			value.rules.write_only ||= s.d.nodes[at].rules.write_only
		}
		if value.rules.read_only && value.rules.write_only {
			odin_refuse(s, "writeOnly")
		}
		pop(&s.path)
		raw_field := spelled_as_is(m.name, false, s.a)
		field := odin_unique(&fields, raw_field if raw_field != "" else "member", s.a)
		if at := odin_target(s, node); at != rules.NONE {
			odin_comment(&b, "\t", s.d.nodes[at].description)
		}
		if value.note != "" {
			odin_comment(&b, "\t", strings.concatenate({"format: ", value.note}, s.a))
		}
		odin_put(&b, "\t", field, ": ")
		t := odin_member_type(s, value)
		absent := !m.required && !takes_null(s, node)
		if absent && !strings.has_prefix(t, "^") && !strings.has_prefix(t, "Maybe(") {
			t = strings.concatenate({"Maybe(", t, ")"}, s.a)
		}
		strings.write_string(&b, t)
		unset := !m.required && takes_null(s, node)
		member_tag(s, &b, name, m, field, value.rules, (absent || strings.has_prefix(t, "^") || t == NUMBER_TEXT) && !takes_null(s, node), absent, unset)
		strings.write_string(&b, ",\n")
		if !m.required {
			default_spelled(s, name, field, node, value)
		}
	}
	odin_put(&b, "\t", odin_unique(&fields, "set", s.a), ": model.Fields_Set,\n")
	if (other != rules.NONE || part.whole) && !forbids {
		append(&s.path, tape.All{})
		value := odin_type(s, other, strings.concatenate({name, "_Value"}, s.a), true)
		pop(&s.path)
		odin_put(&b, "\t", odin_unique(&fields, "extra", s.a), ": map[string]", odin_held_type(value, s.a), " `json:\",unknown\"`,\n")
	}
	strings.write_string(&b, "}\n")
	s.decls[k].text, s.decls[k].open = strings.to_string(b), false
	if forbids {
		odin_put(&s.registers, "\tmodel.register_extra(reg, ", name, ", .Forbid) or_return\n")
	}
	return {type = name, decl = k}
}

@(private = "file")
default_spelled :: proc(s: ^Source, owner, field: string, at: rules.Node_Index, v: Spelled) {
	x, has := s.d.nodes[at].default_of.?
	if !has {
		if found := odin_target(s, at); found != rules.NONE {
			x, has = s.d.nodes[found].default_of.?
		}
	}
	if !has || rules.value_kind(x) == .Null {
		return
	}
	value, held := "", false
	switch {
	case v.decl >= 0 && s.decls[v.decl].literals != nil:
		value, held = s.decls[v.decl].literals[odin_operand_key(x, s.a)]
	case v.decl >= 0 && len(s.decls[v.decl].arms) > 0:
		for arm_kind in ([?]rules.Kind{.String, .Bool, .Integer, .Number}) {
			if arm, found := s.decls[v.decl].arms[arm_kind]; found {
				if value, held = scalar_literal(s, arm, x); held {
					break
				}
			}
		}
		if held {
			value = strings.concatenate({v.type, "(", value, ")"}, s.a)
		}
	case:
		value, held = scalar_literal(s, v, x)
	}
	if !held {
		odin_refuse(s, "default")
		return
	}
	s.defaults = true
	odin_put(&s.registers, "\tmodel.register_default(reg, ", owner, ", ")
	strings.write_quoted_string(&s.registers, field)
	odin_put(&s.registers, ", ", value, ") or_return\n")
}

@(private = "file")
odin_operand_key :: proc(x: rules.Value, a: runtime.Allocator) -> string {
	#partial switch rules.value_kind(x) {
	case .String:
		return strings.concatenate({"s", default_text(x, a)}, a)
	case .Number:
		if digits, whole := default_number(x, "i64", a); whole {
			return strings.concatenate({"n", digits}, a)
		}
	case .True:
		return "true"
	case .False:
		return "false"
	}
	return ""
}

@(private = "file")
default_text :: proc(x: rules.Value, a: runtime.Allocator) -> string {
	buf: [256]u8 = ---
	s, owned, ok := rules.value_string(x, buf[:], a)
	if !ok {
		return ""
	}
	return s if owned else strings.clone(s, a)
}

@(private = "file")
scalar_literal :: proc(s: ^Source, v: Spelled, x: rules.Value) -> (string, bool) {
	base := v.type
	if v.decl >= 0 {
		pfx := strings.concatenate({v.type, " :: distinct "}, s.a)
		base = strings.trim_space(strings.trim_prefix(s.decls[v.decl].text, pfx))
	}
	b := strings.builder_make(s.a)
	kind := rules.value_kind(x)
	#partial switch kind {
	case .String:
		if base != "string" && base != "model.Email" {
			return "", false
		}
		odin_put(&b, v.type, "(")
		odin_literal(&b, default_text(x, s.a))
		strings.write_byte(&b, ')')
	case .Number:
		text, held := default_number(x, base, s.a)
		if !held {
			return "", false
		}
		if v.type == NUMBER_TEXT {
			strings.write_string(&b, text)
		} else {
			odin_put(&b, v.type, "(", text, ")")
		}
	case .True, .False:
		if base != "bool" {
			return "", false
		}
		odin_put(&b, v.type, "(true)" if kind == .True else "(false)")
	case:
		return "", false
	}
	return strings.to_string(b), true
}

@(private = "file")
NUMBER_TEXT :: "model.Number_Text"

@(private = "file")
f64_holds :: proc(r: rules.Rules) -> bool {
	low, low_ok := strconv.parse_f64(r.minimum)
	high, high_ok := strconv.parse_f64(r.maximum)
	return low_ok && high_ok && abs(low) <= max(f64) && abs(high) <= max(f64)
}

@(private = "file")
default_number :: proc(x: rules.Value, base: string, a: runtime.Allocator) -> (string, bool) {
	buf: [128]u8 = ---
	raw, owned, ok := rules.value_number_text(x, buf[:], a)
	if !ok {
		return "", false
	}
	clean := raw[1:] if len(raw) > 0 && raw[0] == '+' else raw
	text := strings.clone(clean, a)
	if owned {
		delete(raw, a)
	}
	text, _ = strings.replace_all(text, "E", "e", a)
	switch base {
	case NUMBER_TEXT:
		return strings.concatenate({NUMBER_TEXT, `{text = "`, text, `"}`}, a), true
	case "f64":
		f, fok := strconv.parse_f64(text)
		return text, fok && abs(f) <= max(f64)
	case "i64", "u64":
		whole, set := whole_bound(text, false, true, a)
		least := i128(0) if base == "u64" else i128(min(i64))
		most := i128(max(u64)) if base == "u64" else i128(max(i64))
		floor, _ := whole_bound(text, false, false, a)
		return whole_text(whole, a), set && floor == whole && whole >= least && whole <= most
	}
	return "", false
}

@(private = "file")
member_tag :: proc(s: ^Source, b: ^strings.Builder, owner: string, m: rules.Member, field: string, r: rules.Rules, not_null: bool, omit := false, unset := false) {
	r := r
	if strings.contains_any(r.pattern, "\",") {
		odin_put(&s.registers, "\tmodel.register_field(reg, {", owner, ", ")
		strings.write_quoted_string(&s.registers, field)
		strings.write_string(&s.registers, ", ")
		strings.write_quoted_string(&s.registers, strings.concatenate({"pattern=", r.pattern}, s.a))
		strings.write_string(&s.registers, "}) or_return\n")
		r.pattern = ""
	}
	tag := strings.builder_make(s.a)
	named := field != m.name || omit || unset
	if named {
		strings.write_string(&tag, "json:\"")
		if field != m.name {
			for c in transmute([]u8)m.name {
				if c == '\\' || c == ',' || c == '"' || m.name == "-" {
					strings.write_byte(&tag, '\\')
				}
				strings.write_byte(&tag, c)
			}
		}
		odin_put(&tag, ",omitempty" if omit else "", ",omitunset\"" if unset else "\"")
	}
	items := tag_items(s, r, !m.required, not_null)
	if items != "" {
		odin_put(&tag, " model:\"" if named else "model:\"", items, "\"")
	}
	if text := strings.to_string(tag); text != "" {
		strings.write_byte(b, ' ')
		odin_literal(b, text, true)
	}
}

@(private = "file")
tag_items :: proc(s: ^Source, r: rules.Rules, optional := false, not_null := false) -> string {
	b := strings.builder_make(s.a)
	item :: proc(b: ^strings.Builder, parts: ..string) {
		if strings.builder_len(b^) > 0 {
			strings.write_byte(b, ',')
		}
		odin_put(b, ..parts)
	}
	if optional {
		item(&b, "optional")
	}
	if not_null {
		item(&b, "not_null")
	}
	if r.read_only || r.write_only {
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
	ubuf: [24]u8 = ---
	for c in ([?]struct {
			low:  u64,
			high: Maybe(u64),
		}{{r.min_length, r.max_length}, {r.min_items, r.max_items}, {r.min_members, r.max_members}}) {
		high, bounded := c.high.?
		switch {
		case bounded && c.low == high:
			item(&b, "len=", strconv.write_uint(ubuf[:], high, 10))
		case:
			if c.low > 0 {
				item(&b, "len>=", strconv.write_uint(ubuf[:], c.low, 10))
			}
			if bounded {
				item(&b, "len<=", strconv.write_uint(ubuf[:], high, 10))
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

@(private = "file")
Operands :: struct {
	texts:     [dynamic]string,
	numbers:   [dynamic]i64,
	truth:     [2]bool,
	null:      bool,
	kinds:     rules.Kinds,
	unspelled: rules.Kinds,
}

@(private = "file")
operands_of :: proc(s: ^Source, n: ^rules.Node) -> (o: Operands, refused: string) {
	o.texts.allocator = s.a
	o.numbers.allocator = s.a
	values := n.enum_of if n.has_enum else []rules.Value{n.const_of.?}
	kinds := n.kinds + ({.Integer} if .Number in n.kinds else {})
	judged := rules.Node{kinds = n.kinds, rules = n.rules, array = -1, object = -1}
	judged.rules.assert_format ||= s.format_assert && !n.rules.format_foreign
	leaf: rules.Leaf
	if leaf, refused = rules.leaf_of(&judged, {}, s.a, nil, s.backing); refused != "" {
		return
	}
	rs, rserr := regex.scratch_make(s.backing)
	defer if rserr.kind == .None {
		regex.scratch_destroy(&rs)
	}
	listed_texts := make(map[string]struct{}, len(values), s.a)
	listed_numbers := make(map[i64]struct{}, len(values), s.a)
	buf: [256]u8 = ---
	for v in values {
		switch rules.value_kind(v) {
		case .Null:
			o.null ||= .Null in kinds
		case .True, .False:
			o.truth[int(rules.value_kind(v) == .True)] ||= .Bool in kinds
		case .String:
			text, owned, sok := rules.value_string(v, buf[:], s.a)
			if sok {
				if !owned {
					text = strings.clone(text, s.a)
				}
				fails, _ := rules.judge_string(&leaf, text, &rs, 0, s.backing)
				if .String in kinds && fails == {} && text not_in listed_texts {
					listed_texts[text] = {}
					append(&o.texts, text)
				}
			}
		case .Number:
			digits, _, nok := rules.value_number_text(v, buf[:], s.a)
			if !nok {
				o.kinds += {.Number}
				o.unspelled += {.Number}
				continue
			}
			d := rules.decimal_of(digits)
			whole := rules.integral(d)
			x, fits := rules.decimal_i64(d)
			fits &&= x >= -(1 << 53) && x <= 1 << 53
			passes := rules.judge_number(&leaf, digits, x if fits else nil) == {}
			switch {
			case !passes || .Integer not_in kinds || (!whole && .Number not_in kinds):
			case !whole || !fits:
				o.kinds += {.Integer if whole else .Number}
				o.unspelled += {.Number}
			case x not_in listed_numbers:
				listed_numbers[x] = {}
				append(&o.numbers, x)
			}
		case .Array:
			if .Array in kinds {
				o.kinds += {.Array}
				o.unspelled += {.Array}
			}
		case .Object:
			if .Object in kinds {
				o.kinds += {.Object}
				o.unspelled += {.Object}
			}
		}
	}
	o.kinds += ({.String} if len(o.texts) > 0 else {}) + ({.Integer} if len(o.numbers) > 0 else {}) + ({.Null} if o.null else {})
	if o.truth[0] || o.truth[1] {
		o.kinds += {.Bool}
		o.unspelled += {} if o.truth[0] == o.truth[1] else {.Bool}
	}
	return
}

@(private = "file")
enum_judged :: proc(s: ^Source, n: ^rules.Node) -> (judged: bool, o: Operands) {
	if !n.has_enum && n.const_of == nil {
		return
	}
	refused: string
	o, refused = operands_of(s, n)
	return refused == "" && (o.unspelled != {} || (n.has_enum && n.const_of != nil)), o
}

@(private = "file")
enum_spelled :: proc(s: ^Source, i: rules.Node_Index, hint: string) -> (out: Spelled) {
	n := s.d.nodes[i]
	out.decl = -1
	o, refused := operands_of(s, &n)
	if refused != "" {
		odin_refuse(s, refused)
		return
	}
	texts, numbers, truth := o.texts, o.numbers, o.truth
	out.null = o.null
	classes := int(len(texts) > 0) + int(len(numbers) > 0) + int(truth[0])
	switch {
	case classes == 0 && out.null:
		return {type = null_type(s), decl = -1}
	case classes == 0:
		odin_refuse(s, "enum" if n.has_enum else "const")
		return
	case classes == 1 && truth[0]:
		out.type = "bool"
		return
	case classes == 1:
		out.decl = enum_declared(s, part_of(s, i), n.description, texts[:], numbers[:], hint)
		out.type = s.decls[out.decl].name
		return
	}
	k := odin_declare(s, part_of(s, i), hint)
	name := s.decls[k].name
	b := strings.builder_make(s.a)
	odin_comment(&b, "", n.description)
	odin_put(&b, name, " :: union {" if out.null else " :: union #no_nil {")
	literals := make(map[string]string, 16, s.a)
	if len(texts) > 0 {
		arm := enum_declared(s, part_of(s, i, .String), "", texts[:], nil, strings.concatenate({name, "_String"}, s.a))
		strings.write_string(&b, s.decls[arm].name)
		union_literals(&literals, name, s.decls[arm].literals, s.a)
	}
	if len(numbers) > 0 {
		arm := enum_declared(s, part_of(s, i, .Integer), "", nil, numbers[:], strings.concatenate({name, "_Integer"}, s.a))
		odin_put(&b, ", " if len(texts) > 0 else "", s.decls[arm].name)
		union_literals(&literals, name, s.decls[arm].literals, s.a)
	}
	strings.write_string(&b, ", bool}\n" if truth[0] else "}\n")
	if truth[0] {
		literals["true"] = strings.concatenate({name, "(true)"}, s.a)
		literals["false"] = strings.concatenate({name, "(false)"}, s.a)
	}
	s.decls[k].text, s.decls[k].open, s.decls[k].literals = strings.to_string(b), false, literals
	return {type = name, decl = k}
}

@(private = "file")
union_literals :: proc(out: ^map[string]string, name: string, literals: map[string]string, a: runtime.Allocator) {
	for operand, value in literals {
		out[operand] = strings.concatenate({name, "(", value, ")"}, a)
	}
}

@(private = "file")
enum_declared :: proc(s: ^Source, part: Odin_Part, description: string, texts: []string, numbers: []i64, hint: string) -> int {
	k := odin_declare(s, part, hint)
	name := s.decls[k].name
	b := strings.builder_make(s.a)
	odin_comment(&b, "", description)
	odin_put(&b, name, " :: enum i64 {\n" if len(numbers) > 0 else " :: enum {\n")
	members := make(map[string]bool, len(texts) + len(numbers), s.a)
	literals := make(map[string]string, len(texts) + len(numbers), s.a)
	renames := strings.builder_make(s.a)
	ibuf, ubuf: [24]u8 = ---, ---
	for x in numbers {
		ux := u64(-x) if x < 0 else u64(x)
		member := strings.concatenate({"V", "M" if x < 0 else "", strconv.write_uint(ubuf[:], ux, 10)}, s.a)
		xs := strconv.write_int(ibuf[:], x, 10)
		odin_put(&b, "\t", member, " = ", xs, ",\n")
		literals[strings.concatenate({"n", xs}, s.a)] = strings.concatenate({name, ".", member}, s.a)
	}
	for x in texts {
		member := odin_unique(&members, enum_member(x, s.a), s.a)
		odin_put(&b, "\t", member, ",\n")
		literals[strings.concatenate({"s", x}, s.a)] = strings.concatenate({name, ".", member}, s.a)
		if member != x {
			strings.write_string(&renames, "{" if strings.builder_len(renames) == 0 else ", {")
			strings.write_quoted_string(&renames, member)
			strings.write_string(&renames, ", ")
			strings.write_quoted_string(&renames, x)
			strings.write_string(&renames, "}")
		}
	}
	strings.write_string(&b, "}\n")
	s.decls[k].text, s.decls[k].open, s.decls[k].literals = strings.to_string(b), false, literals
	if len(numbers) > 0 || strings.builder_len(renames) > 0 {
		odin_put(&s.registers, "\tmodel.register_enum(reg, {", name)
		if len(numbers) > 0 {
			strings.write_string(&s.registers, ", true, nil")
		} else {
			odin_put(&s.registers, ", false, []model.Enum_Rename{", strings.to_string(renames), "}")
		}
		strings.write_string(&s.registers, "}) or_return\n")
	}
	return k
}

@(private = "file")
arms_spelled :: proc(s: ^Source, i: rules.Node_Index, hint: string) -> (out: Spelled) {
	n := s.d.nodes[i]
	out.decl = -1
	Arm :: struct {
		node:  rules.Node_Index,
		kind:  Maybe(rules.Kind),
		kinds: rules.Kinds,
	}
	arms := make([dynamic]Arm, s.a)
	null := .Null in n.kinds && len(n.any_of) == 0 && len(n.one_of) == 0
	if len(n.any_of) == 0 && len(n.one_of) == 0 {
		for k in kinds_apart(n.kinds) {
			append(&arms, Arm{i, k, {k} if k != .Number else {.Integer, .Number}})
		}
	}
	overlap, null_twice := false, false
	for x in (n.any_of if len(n.any_of) > 0 else n.one_of) {
		at := settled(s, odin_target(s, x))
		if at == rules.NONE || s.refused.kind != .None {
			return
		}
		arm := s.d.nodes[at]
		plain := arm.rules == {} && arm.array < 0 && arm.object < 0 && !arm.has_enum && arm.const_of == nil && len(arm.any_of) == 0 && len(arm.one_of) == 0
		null_twice ||= len(n.one_of) > 0 && null && .Null in arm.kinds
		switch {
		case arm.kinds == rules.EVERY_KIND && plain && len(n.one_of) <= 1:
			s.imports += {.Rules}
			return {type = "rules.Value", decl = -1}
		case arm.kinds - {.Null} == {} && plain:
			null ||= .Null in arm.kinds
		case:
			null ||= .Null in arm.kinds
			append(&arms, Arm{x, nil, arm.kinds + ({.Integer} if .Number in arm.kinds else {}) - {.Null}})
		}
	}
	taken: rules.Kinds
	for a in arms {
		overlap ||= a.kinds & taken != {}
		taken += a.kinds
	}
	switch {
	case null_twice:
		odin_refuse(s, "oneOf")
		return
	case len(arms) == 0 && null:
		return {type = null_type(s), decl = -1}
	case len(arms) == 0:
		odin_refuse(s, "false")
		return
	case len(arms) == 1 && arms[0].kind == nil:
		out = odin_type(s, arms[0].node, hint, true)
		out.null ||= null
		return
	}
	k := odin_declare(s, part_of(s, i), hint)
	name := s.decls[k].name
	types := make([dynamic]string, s.a)
	listed := make(map[string]struct{}, len(arms), s.a)
	s.decls[k].arms = make(map[rules.Kind]Spelled, len(arms), s.a)
	ibuf: [24]u8 = ---
	for a, j in arms {
		suffix := KIND_NAMES[a.kind.?] if a.kind != nil else strconv.write_int(ibuf[:], i64(j + 1), 10)
		arm_hint := strings.concatenate({name, "_", suffix}, s.a)
		value := kind_spelled(s, a.node, a.kind.?, arm_hint, true) if a.kind != nil else odin_type(s, a.node, arm_hint, true)
		if kind, one := a.kind.?; one {
			s.decls[k].arms[kind] = value
		} else if a.kinds <= {.String, .Bool, .Integer, .Number} {
			for sk in kinds_apart(a.kinds) {
				if sk not_in s.decls[k].arms {
					s.decls[k].arms[sk] = value
				}
			}
		}
		if len(n.one_of) > 0 && !value.null && takes_null(s, a.node) {
			odin_refuse(s, "oneOf")
		}
		null ||= value.null
		value.null = false
		if t := odin_member_type(s, value); t not_in listed {
			listed[t] = {}
			append(&types, t)
		} else if len(n.one_of) > 0 {
			odin_refuse(s, "oneOf")
		}
	}
	b := strings.builder_make(s.a)
	odin_comment(&b, "", n.description)
	strings.write_string(&b, name)
	if len(types) == 1 && !null {
		odin_put(&b, " :: ", types[0], "\n")
		s.decls[k].text, s.decls[k].open = strings.to_string(b), false
		return {type = name, decl = k}
	}
	strings.write_string(&b, " :: union {" if null else " :: union #no_nil {")
	for t, j in types {
		odin_put(&b, ", " if j > 0 else "", t)
	}
	strings.write_string(&b, "}\n")
	s.decls[k].text, s.decls[k].open = strings.to_string(b), false
	if overlap {
		odin_put(&s.registers, "\tmodel.register_union(reg, {", name, ", .One_Match, \"\"}) or_return\n" if len(n.one_of) > 0 else ", .First_Match, \"\"}) or_return\n")
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

@(private = "file")
odin_member_type :: proc(s: ^Source, v: Spelled) -> string {
	if v.decl >= 0 && s.decls[v.decl].open {
		return strings.concatenate({"^", v.type}, s.a)
	}
	return odin_held_type(v, s.a)
}

@(private = "file")
odin_held_type :: proc(v: Spelled, a: runtime.Allocator) -> string {
	return strings.concatenate({"Maybe(", v.type, ")"}, a) if v.null else v.type
}

@(private = "file")
odin_declare :: proc(s: ^Source, part: Odin_Part, hint: string) -> int {
	name := ""
	if part.kind == nil {
		name = spelled_as_is(s.d.names[part.node] or_else s.d.nodes[part.node].title, true, s.a)
	}
	append(&s.decls, Decl{name = odin_unique(&s.taken, name if name != "" else hint, s.a), open = true})
	idx := len(s.decls) - 1
	s.of_node[part] = idx
	if s.judged_bind.active && s.judged_bind.inner == part {
		s.of_node[s.judged_bind.outer] = idx
	}
	return idx
}

@(private = "file")
odin_unique :: proc(taken: ^map[string]bool, name: string, a: runtime.Allocator) -> string {
	out := name
	ibuf: [24]u8 = ---
	for k := 2; taken[out]; k += 1 {
		out = strings.concatenate({name, "_", strconv.write_int(ibuf[:], i64(k), 10)}, a)
	}
	taken[out] = true
	return out
}

@(private = "file")
spelled_as_is :: proc(text: string, type: bool, a: runtime.Allocator) -> string {
	b := strings.builder_make(a)
	start, prev := true, u8(0)
	for c in transmute([]u8)text {
		alnum := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
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
		out = strings.concatenate({"_", out}, a)
	}
	return strings.concatenate({out, "_"}, a) if slice.contains(ODIN_KEYWORDS[:], out) else out
}

@(private = "file")
package_spelled :: proc(name: string) -> bool {
	if name == "" || name == "_" || slice.contains(ODIN_KEYWORDS[:], name) || slice.contains(ODIN_PACKAGES[:], name) {
		return false
	}
	for c, j in transmute([]u8)name {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || (j > 0 && c >= '0' && c <= '9')) {
			return false
		}
	}
	return true
}

@(private = "file", rodata)
ODIN_PACKAGES := [?]string {
	"_blake2", "_sha3", "_subtle", "blake2b", "blake2s", "bufio", "build", "builtin", "bytes", "c", "check", "compose",
	"container_queue", "core", "crypto", "crypto_hash", "darwin", "datetime", "encoding_base64", "encoding_endian", "fmt",
	"hash", "hook", "intrinsics", "io", "keccak", "kernel", "kqueue", "libc", "linux", "markup", "math", "math_bits",
	"md5", "mem", "mem_virtual", "model", "os", "posix", "rand", "records", "reflect", "regex", "rules", "runtime",
	"schema", "sha1", "sha2", "sha3", "simd", "simd_arm", "simd_x86", "slice", "sm3", "spell", "strconv",
	"strconv_decimal", "strings", "sync", "sys_valgrind", "sysinfo", "tape", "time", "typed", "unicode", "unix",
	"utf16", "utf8", "uuid", "windows", "write",
}

@(private = "file")
enum_member :: proc(text: string, a: runtime.Allocator) -> string {
	name := spelled_as_is(text, true, a)
	return "Empty" if name == "" else name
}

@(private = "file", rodata)
ODIN_KEYWORDS := [?]string {
	"asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context", "continue", "defer", "distinct", "do",
	"dynamic", "else", "enum", "fallthrough", "false", "for", "foreign", "if", "import", "in", "map", "matrix", "nil",
	"not_in", "or_break", "or_continue", "or_else", "or_return", "package", "proc", "return", "struct", "switch",
	"transmute", "true", "typeid", "union", "using", "when", "where",
}

@(private = "file")
odin_comment :: proc(b: ^strings.Builder, indent, text: string) {
	hex_digits := "0123456789abcdef"
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		odin_put(b, indent, "//" if line == "" else "// ")
		for c in transmute([]u8)line {
			if (c < ' ' && c != '\t') || c == 0x7f {
				esc := [4]u8{'\\', 'x', hex_digits[c >> 4], hex_digits[c & 0xF]}
				strings.write_bytes(b, esc[:])
			} else {
				strings.write_byte(b, c)
			}
		}
		strings.write_byte(b, '\n')
	}
}

@(private = "file")
odin_put :: proc(b: ^strings.Builder, parts: ..string) {
	for p in parts {
		strings.write_string(b, p)
	}
}
