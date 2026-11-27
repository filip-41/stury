// Generates idiomatic Odin types (structs, enums, unions, distinct types, json:/model: tags, and `register` proc)
// from a `rules.Description` using an explicit heap frame stack (zero unbounded native recursion).
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

@(require_results)
write_odin :: proc(d: ^rules.Description, package_name: string, format_assert := false, allocator := context.allocator) -> (string, Error) {
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
	for k, v in d.names { local.names[k] = v }

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
	if s.fragments { s.imports += {.Schema, .Strings} }
	if !s.defaults || s.fragments || s.factories { strings.write_string(&b, "import \"base:runtime\"\n") }
	for name, i in ODIN_IMPORTS {
		if Odin_Import(i) in s.imports { strings.write_string(&b, name) }
	}
	strings.write_string(&b, "import model \"stury:lib/schema/model\"\n")
	if alias {
		strings.write_string(&b, "\n")
		if root.note != "" { odin_comment(&b, "", strings.concatenate({"format: ", root.note}, a)) }
		odin_put(&b, odin_unique(&s.taken, "Root", a), " :: ", odin_held_type(root, a), "\n")
	}
	for x in s.decls { odin_put(&b, "\n", x.text) }
	odin_put(
		&b,
		"\n// Adds the rules of these types that their tags do not hold to `reg`, before `model.compile`.\n",
		"register :: proc(reg: ^model.Registry) -> ",
		"model.Error {\n" if (s.fragments || s.defaults) else "runtime.Allocator_Error {\n",
		strings.to_string(s.registers),
		"\treturn nil\n}\n",
	)
	if s.fragments { strings.write_string(&b, REGISTER_FRAGMENT) }
	out, cloned := strings.clone(strings.to_string(b), allocator)
	if cloned != nil { return "", make_error(.No_Memory, "", "out of memory", allocator = allocator) }
	return out, {}
}

@(private = "file")
REGISTER_FRAGMENT ::
	"\n// Adds the JSON Schema `text` to the rules of `T`.\n" +
	"register_fragment :: proc(reg: ^model.Registry, T: typeid, text: string) -> model.Error {\n" +
	"\ts, serr := schema.compile_json(transmute([]u8)text)\n" +
	"\tif serr.kind != .None {\n" +
	"\t\tdefer schema.error_destroy(&serr)\n" +
	"\t\tif serr.kind == .No_Memory { return runtime.Allocator_Error.Out_Of_Memory }\n" +
	"\t\tkind: model.Error_Kind = .Unsupported if serr.kind == .Unsupported else .Bad_Option if serr.kind == .Bad_Option else .Walk if serr.kind == .Parse else .Check_Failed\n" +
	"\t\top, err1 := strings.clone(serr.keyword)\n" +
	"\t\tif err1 != nil { return err1 }\n" +
	"\t\tmsg, err2 := strings.clone(serr.message)\n" +
	"\t\tif err2 != nil { delete(op); return err2 }\n" +
	"\t\treturn model.Model_Error{kind = kind, at = serr.at, operand = op, want = {text = msg}, owned = true}\n" +
	"\t}\n" +
	"\tdefer schema.destroy(s)\n" +
	"\tmodel.register_schema(reg, T, s.description) or_return\n" +
	"\treturn nil\n}\n"

@(private = "file")
Odin_Import :: enum u8 { Uuid, Strings, Time, Rules, Schema }

@(private = "file", rodata)
ODIN_IMPORTS := [Odin_Import]string {
	.Uuid    = "import \"core:encoding/uuid\"\n",
	.Strings = "import \"core:strings\"\n",
	.Time    = "import \"core:time\"\n",
	.Rules   = "import rules \"stury:lib/schema/rules\"\n",
	.Schema  = "import schema \"stury:lib/schema/schema\"\n",
}

@(private = "file")
Judged_Bind :: struct {
	inner, outer: Odin_Part,
	active:       bool,
}

@(private = "file")
Odin_Part :: struct {
	node:  rules.Node_Index,
	kind:  Maybe(rules.Kind),
	whole: bool,
}

@(private = "file")
Decl :: struct {
	name, text: string,
	open, null: bool,
	literals:   map[string]string,
	arms:       map[rules.Kind]Spelled,
}

@(private = "file")
Spelled :: struct {
	type, note: string,
	rules:      rules.Rules,
	decl:       int,
	null:       bool,
}

@(private = "file")
Odin_Arm :: struct {
	node:  rules.Node_Index,
	kind:  Maybe(rules.Kind),
	kinds: rules.Kinds,
}

@(private = "file")
Frame_Kind :: enum u8 { Type, Node, Judged, Kind, Array, Object, Arms }

@(private = "file")
Odin_Frame :: struct {
	kind:          Frame_Kind,
	stage:         u8,
	at:            rules.Node_Index,
	i:             rules.Node_Index,
	part:          Odin_Part,
	outer:         Odin_Part,
	inner:         Odin_Part,
	saved_bind:    Judged_Bind,
	hint:          string,
	held:          bool,
	set_null:      bool,
	one:           rules.Kind,
	r:             rules.Rules,
	n:             rules.Node,
	a:             rules.Array,
	o:             rules.Object,
	other:         rules.Node_Index,
	forbids:       bool,
	pattern_extra: bool,
	pattern_other: bool,
	enums:         bool,
	kinds_null:    bool,
	tuple:         bool,
	whole_inc:     int,
	element:       string,
	element_type:  string,
	k:             int,
	name:          string,
	b:             strings.Builder,
	fields:        map[string]bool,
	arms:          [dynamic]Odin_Arm,
	types:         [dynamic]string,
	listed:        map[string]struct{},
	overlap:       bool,
	null:          bool,
	idx:           int,
}

@(private = "file")
Source :: struct {
	d:             ^rules.Description,
	format_assert: bool,
	fragments:     bool,
	defaults:      bool,
	factories:     bool,
	decls:         [dynamic]Decl,
	of_node:       map[Odin_Part]int,
	taken:         map[string]bool,
	spelling:      map[Odin_Part]bool,
	joined:        map[string]rules.Node_Index,
	null_type:     string,
	registers:     strings.Builder,
	imports:       bit_set[Odin_Import],
	path:          [dynamic]tape.Step,
	frames:        [dynamic]Odin_Frame,
	res:           Spelled,
	refused:       Error,
	whole:         int,
	judged_bind:   Judged_Bind,
	a:             runtime.Allocator,
	backing:       runtime.Allocator,
}

@(private = "file")
root_spelled :: proc(d: ^rules.Description, format_assert: bool, hint: string, a, backing: runtime.Allocator) -> (s: Source, root: Spelled) {
	s = Source {
		d             = d,
		format_assert = format_assert,
		a             = a,
		backing       = backing,
		decls         = make([dynamic]Decl, a),
		of_node       = make(map[Odin_Part]int, 16, a),
		taken         = make(map[string]bool, 32, a),
		spelling      = make(map[Odin_Part]bool, 16, a),
		joined        = make(map[string]rules.Node_Index, 8, a),
		registers     = strings.builder_make(a),
		path          = make([dynamic]tape.Step, a),
		frames        = make([dynamic]Odin_Frame, 0, 32, a),
	}
	s.taken["Maybe"] = true
	append(&s.frames, Odin_Frame{kind = .Type, at = d.root, hint = hint, held = true})
	odin_run(&s)
	return s, s.res
}

@(private = "file")
part_of :: proc "contextless" (s: ^Source, i: rules.Node_Index, kind: Maybe(rules.Kind) = nil) -> Odin_Part {
	return {i, kind, s.whole > 0 && s.d.nodes[i].kinds & {.Array, .Object} != {}}
}

@(private = "file")
odin_refuse :: proc(s: ^Source, keyword: string) {
	if s.refused.kind == .None {
		s.refused = {kind = .Unsupported, keyword = keyword, message = "unsupported keyword for Odin code generation", path = steps_clone(s.path[:], s.a)}
	}
}

// Iterative driver for type generation (O(1) native stack regardless of schema nesting depth).
@(private = "file")
odin_run :: proc(s: ^Source) {
	for len(s.frames) > 0 {
		fi := len(s.frames) - 1
		switch s.frames[fi].kind {
		case .Type:   step_type(s, fi)
		case .Node:   step_node(s, fi)
		case .Judged: step_judged(s, fi)
		case .Kind:   step_kind(s, fi)
		case .Array:  step_array(s, fi)
		case .Object: step_object(s, fi)
		case .Arms:   step_arms(s, fi)
		}
	}
}

@(private = "file")
step_type :: proc(s: ^Source, fi: int) {
	f := &s.frames[fi]
	if f.stage == 0 {
		i := settled(s, odin_target(s, f.at))
		if i == rules.NONE {
			s.imports += {.Rules}
			s.res = {type = "rules.Value", decl = -1}
			pop(&s.frames)
			return
		}
		part := part_of(s, i)
		if k, ok := s.of_node[part]; ok {
			s.res = {type = s.decls[k].name, decl = k, null = s.decls[k].null}
			pop(&s.frames)
			return
		}
		if s.spelling[part] || s.refused.kind != .None {
			odin_refuse(s, "$ref")
			s.res = {decl = -1}
			pop(&s.frames)
			return
		}
		s.spelling[part] = true
		f.part, f.stage = part, 1
		hint, held := f.hint, f.held
		append(&s.frames, Odin_Frame{kind = .Node, i = i, hint = hint, held = held})
		return
	}
	if k, ok := s.of_node[f.part]; ok {
		s.decls[k].null = s.res.null
	}
	delete_key(&s.spelling, f.part)
	pop(&s.frames)
}

@(private = "file")
step_node :: proc(s: ^Source, fi: int) {
	f := s.frames[fi]
	n := s.d.nodes[f.i]
	if keyword := unspelled(&n); keyword != "" {
		odin_refuse(s, keyword)
		s.res = {decl = -1}
		pop(&s.frames)
		return
	}
	if odin_judged(s, &n) {
		s.frames[fi] = Odin_Frame{kind = .Judged, i = f.i, hint = f.hint, held = f.held}
		return
	}
	kinds := n.kinds + ({.Integer} if .Number in n.kinds else {})
	one, count := rules.Kind.Null, 0
	for k in kinds_apart(kinds) { one, count = k, count + 1 }
	switch {
	case n.has_enum || n.const_of != nil:
		s.res = enum_spelled(s, f.i, f.hint)
		pop(&s.frames)
	case len(n.any_of) > 0 || len(n.one_of) > 0:
		s.frames[fi] = Odin_Frame{kind = .Arms, i = f.i, hint = f.hint}
	case count == 0 && .Null in kinds:
		s.res = {type = null_type(s), decl = -1}
		pop(&s.frames)
	case count == 0:
		odin_refuse(s, "false")
		s.res = {decl = -1}
		pop(&s.frames)
	case kinds == rules.EVERY_KIND && n.rules == {} && n.array < 0 && n.object < 0:
		s.imports += {.Rules}
		s.res = {type = "rules.Value", decl = -1}
		pop(&s.frames)
	case count == 1:
		s.frames[fi] = Odin_Frame{kind = .Kind, i = f.i, one = one, hint = f.hint, held = f.held, set_null = .Null in kinds}
	case:
		s.frames[fi] = Odin_Frame{kind = .Arms, i = f.i, hint = f.hint}
	}
}

@(private = "file")
step_judged :: proc(s: ^Source, fi: int) {
	if s.frames[fi].stage == 0 {
		f := &s.frames[fi]
		n := s.d.nodes[f.i]
		outer := part_of(s, f.i)
		base := n
		base.not, base.cond = nil, {}
		enums, operands := enum_judged(s, &n)
		if enums {
			base.has_enum, base.enum_of, base.const_of = false, nil, nil
			base.kinds = operands.kinds
		}
		kinds_null := .Null in n.kinds && len(n.any_of) == 0 && len(n.one_of) == 0
		if kinds_null { base.kinds -= {.Null} }
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
		if name, named := s.d.names[f.i]; named { s.d.names[at] = name }
		s.whole += 1
		inner := part_of(s, at)
		f.saved_bind = s.judged_bind
		f.outer, f.inner, f.n, f.a, f.o = outer, inner, n, a, o
		f.pattern_extra, f.pattern_other, f.enums, f.kinds_null = pattern_extra, pattern_other, enums, kinds_null
		f.stage = 1
		s.judged_bind = {inner = inner, outer = outer, active = true}
		hint, held := f.hint, f.held
		append(&s.frames, Odin_Frame{kind = .Node, i = at, hint = hint, held = held})
		return
	}
	f := pop(&s.frames)
	s.judged_bind = f.saved_bind
	s.whole -= 1
	out := s.res
	switch {
	case f.kinds_null:
		out.null = takes_null(s, f.i)
	case (f.n.not != nil || f.n.cond != {}) && out.null && !takes_null(s, f.i):
		odin_refuse(s, "not" if f.n.not != nil else "if")
	}
	if s.refused.kind != .None {
		s.res = out
		return
	}
	if k, own := s.of_node[f.inner]; !own || k != out.decl {
		k = odin_declare(s, f.inner, f.hint)
		s.decls[k].text = strings.concatenate({s.decls[k].name, " :: distinct ", out.type, "\n"}, s.a)
		s.decls[k].open = false
		out.type, out.decl = s.decls[k].name, k
	}
	s.of_node[f.outer] = out.decl
	fr := rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, not = f.n.not, cond = f.n.cond, resource = f.n.resource}
	if f.enums { fr.has_enum, fr.enum_of, fr.const_of = f.n.has_enum, f.n.enum_of, f.n.const_of }
	if c, has := f.a.contains.?; has {
		fr.array = add_block(&s.d.arrays, rules.Array{items = rules.NONE, contains = c, min_contains = f.a.min_contains, max_contains = f.a.max_contains})
	}
	if f.o.keys != rules.NONE || len(f.o.patterns) > 0 || len(f.o.dependents) > 0 {
		x := rules.Object{additional = rules.NONE, keys = f.o.keys, patterns = nil if f.pattern_extra else f.o.patterns, dependents = f.o.dependents}
		if f.pattern_other {
			names := make([dynamic]rules.Member, s.a)
			any_val := odin_any_node(s)
			for m in f.o.members {
				if !m.only_required { append(&names, rules.Member{name = m.name, node = any_val}) }
			}
			x.members, x.additional = names[:], f.o.additional
		}
		fr.object = add_block(&s.d.objects, x)
	}
	first := "not" if f.n.not != nil else "if" if f.n.cond != {} else "enum" if f.n.has_enum else "const" if f.enums else "contains" if f.a.contains != nil else "propertyNames"
	fragment_registered(s, out.type, fr, first)
	s.res = out
}

@(private = "file")
step_kind :: proc(s: ^Source, fi: int) {
	if s.frames[fi].stage == 1 {
		f := pop(&s.frames)
		if f.set_null { s.res.null = true }
		return
	}
	f := &s.frames[fi]
	n := &s.d.nodes[f.i]
	r := rules_on(n.rules, f.one)
	part := part_of(s, f.i, nil if card(kinds_apart(n.kinds)) == 1 else f.one)
	if f.one == .Array || f.one == .Object {
		f.stage = 1
		fk: Frame_Kind = .Array if f.one == .Array else .Object
		i, hint, held := f.i, f.hint, f.held
		append(&s.frames, Odin_Frame{kind = fk, i = i, part = part, r = r, hint = hint, held = held})
		return
	}
	out := Spelled{decl = -1, rules = r}
	carrier := false
	#partial switch f.one {
	case .Bool:    out.type = "bool"
	case .Integer: out.type, out.rules = integer_spelled(s, out.rules)
	case .Number:  out.type = "f64" if f64_holds(out.rules) else NUMBER_TEXT
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
	}
	if f.held && out.rules != {} {
		if carrier {
			odin_refuse(s, first_keyword(out.rules))
		} else {
			out = distinct_spelled(s, part, out, f.hint)
		}
	}
	if f.set_null { out.null = true }
	s.res = out
	pop(&s.frames)
}

@(private = "file")
step_array :: proc(s: ^Source, fi: int) {
	f := &s.frames[fi]
	if f.stage == 0 {
		n := s.d.nodes[f.i]
		a := s.d.arrays[n.array] if n.array >= 0 else rules.Array{items = rules.NONE}
		f.n, f.a = n, a
		f.element = strings.concatenate({f.hint, "_Item"}, s.a)
		append(&s.path, tape.All{})
		f.whole_inc = int(f.r.unique) + int(len(a.prefix) > 0)
		s.whole += f.whole_inc
		f.tuple = len(a.prefix) > 0 && (f.r.min_items != u64(len(a.prefix)) || (f.r.max_items.? or_else 0) != u64(len(a.prefix)))
		if len(a.prefix) > 0 && !f.tuple {
			f.stage, f.idx = 1, 0
			el := f.element
			append(&s.frames, Odin_Frame{kind = .Type, at = a.prefix[0], hint = el, held = true})
			return
		}
		start_array_items(s, fi)
		return
	}
	if f.stage == 1 {
		t := odin_member_type(s, s.res)
		f.tuple ||= (f.idx > 0 && t != f.element_type) || (strings.has_prefix(t, "^") && !takes_null(s, f.a.prefix[f.idx]))
		f.element_type = t
		f.idx += 1
		if f.idx < len(f.a.prefix) {
			next_at, el := f.a.prefix[f.idx], f.element
			append(&s.frames, Odin_Frame{kind = .Type, at = next_at, hint = el, held = true})
			return
		}
		if f.tuple {
			start_array_items(s, fi)
			return
		}
		ibuf: [24]u8 = ---
		out := Spelled{decl = -1, rules = f.r, type = strings.concatenate({"[", strconv.write_int(ibuf[:], i64(len(f.a.prefix)), 10), "]", f.element_type}, s.a)}
		out.rules.min_items, out.rules.max_items = 0, nil
		finish_array(s, pop(&s.frames), out)
		return
	}
	item := s.res
	out := Spelled{decl = -1, rules = f.r, type = strings.concatenate({"[]", odin_held_type(item, s.a)}, s.a)}
	if item.type == s.null_type && !item.null { odin_refuse(s, "type") }
	finish_array(s, pop(&s.frames), out)
}

@(private = "file")
start_array_items :: proc(s: ^Source, fi: int) {
	f := &s.frames[fi]
	items := f.a.items
	if f.tuple {
		arms := slice.clone_to_dynamic(f.a.prefix, s.a)
		append(&arms, f.a.items if f.a.items != rules.NONE else odin_any_node(s))
		items = node_added(s, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, any_of = arms[:]})
	}
	f.stage = 2
	el := f.element
	append(&s.frames, Odin_Frame{kind = .Type, at = items, hint = el, held = true})
}

@(private = "file")
finish_array :: proc(s: ^Source, f: Odin_Frame, out: Spelled) {
	out := out
	s.whole -= f.whole_inc
	pop(&s.path)
	if f.tuple || (f.held && rules_on(out.rules, .Array) != {}) {
		out = distinct_spelled(s, f.part, out, f.hint)
		if f.tuple {
			fr := rules.Node{kinds = rules.EVERY_KIND, array = add_block(&s.d.arrays, rules.Array{prefix = f.a.prefix, items = f.a.items}), object = -1, resource = f.n.resource}
			fragment_registered(s, out.type, fr, "prefixItems")
		}
	}
	s.res = out
}

@(private = "file")
step_object :: proc(s: ^Source, fi: int) {
	f := &s.frames[fi]
	if f.stage == 0 {
		n := s.d.nodes[f.i]
		o := s.d.objects[n.object] if n.object >= 0 else rules.Object{additional = rules.NONE, keys = rules.NONE}
		other, forbids := o.additional, false
		if kinds, plain := kinds_only(s, other); plain {
			other = rules.NONE if kinds == rules.EVERY_KIND else other
			forbids = kinds == {}
		}
		if len(o.members) == 0 && !forbids {
			append(&s.path, tape.All{})
			f.stage = 1
			vhint := strings.concatenate({f.hint, "_Value"}, s.a)
			append(&s.frames, Odin_Frame{kind = .Type, at = other, hint = vhint, held = true})
			return
		}
		if f.r.min_members > 0 || f.r.max_members != nil { odin_refuse(s, first_keyword(f.r)) }
		k := odin_declare(s, f.part, f.hint)
		s.decls[k].null = f.part.kind == nil && .Null in n.kinds
		name := s.decls[k].name
		b := strings.builder_make(s.a)
		odin_comment(&b, "", n.description)
		odin_put(&b, name, " :: struct {\n")
		f.o, f.other, f.forbids, f.k, f.name, f.b, f.fields = o, other, forbids, k, name, b, make(map[string]bool, len(o.members) + 2, s.a)
		f.stage, f.idx = 2, 0
		if len(o.members) > 0 {
			push_object_member(s, fi)
		} else {
			finish_object_members(s, fi)
		}
		return
	}
	if f.stage == 1 {
		f_done := pop(&s.frames)
		pop(&s.path)
		out := Spelled{type = strings.concatenate({"map[string]", odin_held_type(s.res, s.a)}, s.a), rules = f_done.r, decl = -1}
		s.res = distinct_spelled(s, f_done.part, out, f_done.hint) if (f_done.held && rules_on(f_done.r, .Object) != {}) else out
		return
	}
	if f.stage == 2 {
		m := f.o.members[f.idx]
		node := f.other if m.only_required else m.node
		value := s.res
		tmp := rules.Node{rules = value.rules}
		clash := ""
		value.rules, clash = rules.merged(&tmp, m.rules)
		if clash != "" { odin_refuse(s, clash) }
		if at := settled(s, odin_target(s, node)); at != rules.NONE {
			value.rules.read_only ||= s.d.nodes[at].rules.read_only
			value.rules.write_only ||= s.d.nodes[at].rules.write_only
		}
		if value.rules.read_only && value.rules.write_only { odin_refuse(s, "writeOnly") }
		pop(&s.path)
		raw_field := spelled_as_is(m.name, false, s.a)
		field := odin_unique(&f.fields, raw_field if raw_field != "" else "member", s.a)
		if at := odin_target(s, node); at != rules.NONE { odin_comment(&f.b, "\t", s.d.nodes[at].description) }
		if value.note != "" { odin_comment(&f.b, "\t", strings.concatenate({"format: ", value.note}, s.a)) }
		odin_put(&f.b, "\t", field, ": ")
		t := odin_member_type(s, value)
		tn := takes_null(s, node)
		absent := !m.required && !tn
		if absent && !strings.has_prefix(t, "^") && !strings.has_prefix(t, "Maybe(") {
			t = strings.concatenate({"Maybe(", t, ")"}, s.a)
		}
		strings.write_string(&f.b, t)
		member_tag(s, &f.b, f.name, m, field, value.rules, (absent || strings.has_prefix(t, "^") || t == NUMBER_TEXT) && !tn, absent, !m.required && tn)
		strings.write_string(&f.b, ",\n")
		if !m.required { default_spelled(s, f.name, field, t, node, value) }
		f.idx += 1
		if f.idx < len(f.o.members) {
			push_object_member(s, fi)
		} else {
			finish_object_members(s, fi)
		}
		return
	}
	pop(&s.path)
	odin_put(&f.b, "\t", odin_unique(&f.fields, "extra", s.a), ": map[string]", odin_held_type(s.res, s.a), " `json:\",unknown\"`,\n")
	close_object_struct(s, pop(&s.frames))
}

@(private = "file")
push_object_member :: proc(s: ^Source, fi: int) {
	f := &s.frames[fi]
	m := f.o.members[f.idx]
	if m.only_required && f.forbids { odin_refuse(s, "required") }
	node := f.other if m.only_required else m.node
	append(&s.path, tape.Name(m.name))
	if m.name == "" { odin_refuse(s, "properties") }
	ft := spelled_as_is(m.name, true, s.a)
	hint := strings.concatenate({f.name, "_", ft if ft != "" else "Member"}, s.a)
	append(&s.frames, Odin_Frame{kind = .Type, at = node, hint = hint, held = false})
}

@(private = "file")
finish_object_members :: proc(s: ^Source, fi: int) {
	f := &s.frames[fi]
	odin_put(&f.b, "\t", odin_unique(&f.fields, "set", s.a), ": model.Fields_Set,\n")
	if (f.other != rules.NONE || f.part.whole) && !f.forbids {
		append(&s.path, tape.All{})
		f.stage = 3
		other, hint := f.other, strings.concatenate({f.name, "_Value"}, s.a)
		append(&s.frames, Odin_Frame{kind = .Type, at = other, hint = hint, held = true})
		return
	}
	close_object_struct(s, pop(&s.frames))
}

@(private = "file")
close_object_struct :: proc(s: ^Source, f: Odin_Frame) {
	b := f.b
	strings.write_string(&b, "}\n")
	s.decls[f.k].text, s.decls[f.k].open = strings.to_string(b), false
	if f.forbids { odin_put(&s.registers, "\tmodel.register_extra(reg, ", f.name, ", .Forbid) or_return\n") }
	s.res = {type = f.name, decl = f.k}
}

@(private = "file")
step_arms :: proc(s: ^Source, fi: int) {
	f := &s.frames[fi]
	if f.stage == 0 {
		n := s.d.nodes[f.i]
		arms := make([dynamic]Odin_Arm, s.a)
		null := .Null in n.kinds && len(n.any_of) == 0 && len(n.one_of) == 0
		if len(n.any_of) == 0 && len(n.one_of) == 0 {
			for k in kinds_apart(n.kinds) {
				append(&arms, Odin_Arm{f.i, k, {k} if k != .Number else {.Integer, .Number}})
			}
		}
		overlap, null_twice := false, false
		for x in (n.any_of if len(n.any_of) > 0 else n.one_of) {
			at := settled(s, odin_target(s, x))
			if at == rules.NONE || s.refused.kind != .None {
				s.res = {decl = -1}
				pop(&s.frames)
				return
			}
			arm := s.d.nodes[at]
			plain := arm.rules == {} && arm.array < 0 && arm.object < 0 && !arm.has_enum && arm.const_of == nil && len(arm.any_of) == 0 && len(arm.one_of) == 0
			null_twice ||= len(n.one_of) > 0 && null && .Null in arm.kinds
			switch {
			case arm.kinds == rules.EVERY_KIND && plain && len(n.one_of) <= 1:
				s.imports += {.Rules}
				s.res = {type = "rules.Value", decl = -1}
				pop(&s.frames)
				return
			case arm.kinds - {.Null} == {} && plain:
				null ||= .Null in arm.kinds
			case:
				null ||= .Null in arm.kinds
				append(&arms, Odin_Arm{x, nil, arm.kinds + ({.Integer} if .Number in arm.kinds else {}) - {.Null}})
			}
		}
		taken: rules.Kinds
		for a in arms { overlap ||= a.kinds & taken != {}; taken += a.kinds }
		switch {
		case null_twice:
			odin_refuse(s, "oneOf"); s.res = {decl = -1}; pop(&s.frames); return
		case len(arms) == 0 && null:
			s.res = {type = null_type(s), decl = -1}; pop(&s.frames); return
		case len(arms) == 0:
			odin_refuse(s, "false"); s.res = {decl = -1}; pop(&s.frames); return
		case len(arms) == 1 && arms[0].kind == nil:
			f.null, f.stage = null, 1
			hint := f.hint
			append(&s.frames, Odin_Frame{kind = .Type, at = arms[0].node, hint = hint, held = true})
			return
		}
		k := odin_declare(s, part_of(s, f.i), f.hint)
		s.decls[k].arms = make(map[rules.Kind]Spelled, len(arms), s.a)
		f.n, f.k, f.name, f.arms, f.overlap, f.null = n, k, s.decls[k].name, arms, overlap, null
		f.types, f.listed, f.stage, f.idx = make([dynamic]string, s.a), make(map[string]struct{}, len(arms), s.a), 2, 0
		push_arm(s, fi)
		return
	}
	if f.stage == 1 {
		f_done := pop(&s.frames)
		s.res.null ||= f_done.null
		return
	}
	a := f.arms[f.idx]
	value := s.res
	if kind, one := a.kind.?; one {
		s.decls[f.k].arms[kind] = value
	} else if a.kinds <= {.String, .Bool, .Integer, .Number} {
		for sk in kinds_apart(a.kinds) {
			if sk not_in s.decls[f.k].arms { s.decls[f.k].arms[sk] = value }
		}
	}
	if len(f.n.one_of) > 0 && !value.null && takes_null(s, a.node) { odin_refuse(s, "oneOf") }
	f.null ||= value.null
	value.null = false
	if t := odin_member_type(s, value); t not_in f.listed {
		f.listed[t] = {}
		append(&f.types, t)
	} else if len(f.n.one_of) > 0 {
		odin_refuse(s, "oneOf")
	}
	f.idx += 1
	if f.idx < len(f.arms) {
		push_arm(s, fi)
		return
	}
	f_done := pop(&s.frames)
	b := strings.builder_make(s.a)
	odin_comment(&b, "", f_done.n.description)
	strings.write_string(&b, f_done.name)
	if len(f_done.types) == 1 && !f_done.null {
		odin_put(&b, " :: ", f_done.types[0], "\n")
		s.decls[f_done.k].text, s.decls[f_done.k].open = strings.to_string(b), false
		s.res = {type = f_done.name, decl = f_done.k}
		return
	}
	strings.write_string(&b, " :: union {" if f_done.null else " :: union #no_nil {")
	for t, j in f_done.types { odin_put(&b, ", " if j > 0 else "", t) }
	strings.write_string(&b, "}\n")
	s.decls[f_done.k].text, s.decls[f_done.k].open = strings.to_string(b), false
	if f_done.overlap {
		odin_put(&s.registers, "\tmodel.register_union(reg, {", f_done.name, ", .One_Match, \"\"}) or_return\n" if len(f_done.n.one_of) > 0 else ", .First_Match, \"\"}) or_return\n")
	}
	s.res = {type = f_done.name, decl = f_done.k}
}

@(private = "file")
push_arm :: proc(s: ^Source, fi: int) {
	f := &s.frames[fi]
	a := f.arms[f.idx]
	ibuf: [24]u8 = ---
	suffix := KIND_NAMES[a.kind.?] if a.kind != nil else strconv.write_int(ibuf[:], i64(f.idx + 1), 10)
	arm_hint := strings.concatenate({f.name, "_", suffix}, s.a)
	if kind, one := a.kind.?; one {
		append(&s.frames, Odin_Frame{kind = .Kind, i = a.node, one = kind, hint = arm_hint, held = true})
	} else {
		append(&s.frames, Odin_Frame{kind = .Type, at = a.node, hint = arm_hint, held = true})
	}
}

@(private = "file")
odin_target :: proc(s: ^Source, i: rules.Node_Index) -> rules.Node_Index {
	end, _ := rules.ref_end(s.d, i)
	if end == rules.NONE && i != rules.NONE { odin_refuse(s, "$ref") }
	return end
}

@(private = "file")
kinds_apart :: proc "contextless" (kinds: rules.Kinds) -> rules.Kinds {
	k := kinds - {.Null}
	return k - {.Integer} if .Number in k else k
}

@(private = "file")
unspelled :: proc "contextless" (n: ^rules.Node) -> string {
	switch {
	case n.integer_spelled: return "type"
	case n.unevaluated_items != nil: return "unevaluatedItems"
	case n.unevaluated_properties != nil: return "unevaluatedProperties"
	case n.rules.markup != .Any: return "xml"
	case (len(n.any_of) > 0 || len(n.one_of) > 0) && (n.kinds != rules.EVERY_KIND || n.rules != {} || n.array >= 0 || n.object >= 0 || n.has_enum || n.const_of != nil):
		return "anyOf" if len(n.any_of) > 0 else "oneOf"
	case len(n.any_of) > 0 && len(n.one_of) > 0: return "oneOf"
	}
	return ""
}

@(private = "file")
odin_judged :: proc(s: ^Source, n: ^rules.Node) -> bool {
	if enums, _ := enum_judged(s, n); n.not != nil || n.cond != {} || enums { return true }
	if n.array >= 0 && .Array in n.kinds && s.d.arrays[n.array].contains != nil { return true }
	if n.object >= 0 && .Object in n.kinds {
		o := s.d.objects[n.object]
		return o.keys != rules.NONE || len(o.patterns) > 0 || len(o.dependents) > 0
	}
	return false
}

@(private = "file")
fragment_registered :: proc(s: ^Source, type: string, f: rules.Node, first: string) {
	root := node_added(s, f)
	fragment := s.d^
	fragment.root = root
	text, werr := write_schema(&fragment, {}, s.a)
	if werr.kind != .None {
		odin_refuse(s, werr.keyword if werr.keyword != "" else first)
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
	if !raw { strings.write_quoted_string(b, text); return }
	odin_put(b, "`", text, "`")
}

@(private = "file")
names_node :: proc(s: ^Source, o: rules.Object) -> rules.Node_Index {
	b := strings.builder_make(s.a)
	emitted := 0
	for m in o.members {
		if m.only_required { continue }
		strings.write_string(&b, "|" if emitted > 0 else "^(?:")
		for c in m.name {
			if strings.contains_rune(`\^$.|?*+()[]{}/-`, c) { strings.write_byte(&b, '\\') }
			strings.write_rune(&b, c)
		}
		emitted += 1
	}
	if emitted > 0 { strings.write_string(&b, ")$") }
	for p in o.patterns {
		odin_put(&b, "|(?:" if strings.builder_len(b) > 0 else "(?:", p.expression, ")")
	}
	return node_added(s, rules.Node{kinds = {.String}, array = -1, object = -1, rules = {pattern = strings.to_string(b)}})
}

@(private = "file")
settled :: proc(s: ^Source, i: rules.Node_Index) -> rules.Node_Index {
	if i == rules.NONE || s.refused.kind != .None { return i }
	n := s.d.nodes[i]
	conjunction := len(n.all_of) > 0 || n.ref != nil || n.dynamic_ref != nil
	if !conjunction && n.not == nil && n.unevaluated_items == nil && n.unevaluated_properties == nil { return i }
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
				if end == rules.NONE { return i }
				if !slice.contains(conjuncts, end) { append(&roots, end); grown = true }
			}
		}
	}
	key := strings.builder_make(s.a)
	sorted := slice.clone(conjuncts, s.a)
	slice.sort(sorted)
	ibuf: [24]u8 = ---
	for c in sorted { odin_put(&key, strconv.write_int(ibuf[:], i64(c), 10), ",") }
	ks := strings.to_string(key)
	if k, ok := s.joined[ks]; ok { return k }
	j := joined_node(s, i, conjuncts, conjunction)
	s.joined[ks] = j
	return j
}

@(private = "file")
dynamic_end :: proc(s: ^Source, n: ^rules.Node) -> rules.Node_Index {
	end := n.dynamic_ref.?
	if .Dynamic_Static in n.spelled { return end }
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
	out := rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, any_of = nil if conjunction else t.any_of, description = t.description, title = t.title, resource = t.resource}
	arrays, objects := make([dynamic]i32, s.a), make([dynamic]i32, s.a)
	for c in conjuncts {
		x := s.d.nodes[c]
		tmp := rules.Node{rules = out.rules}
		clash := ""
		out.rules, clash = rules.merged(&tmp, x.rules)
		out.kinds &= x.kinds + ({.Integer} if .Number in x.kinds else {})
		out.integer_spelled ||= x.integer_spelled
		if x.content_encoding != "" { out.content_encoding = x.content_encoding }
		if x.array >= 0 && !slice.contains(arrays[:], x.array) { append(&arrays, x.array) }
		if x.object >= 0 && !slice.contains(objects[:], x.object) { append(&objects, x.object) }
		if not, has := x.not.?; has {
			if kinds, plain := kinds_only(s, not); plain {
				if .Integer in kinds && .Number not_in kinds && .Number in out.kinds { clash = "not" }
				out.kinds -= kinds + ({.Integer} if .Number in kinds else {})
			} else {
				if out.not != nil { clash = "not" }
				out.not = not
			}
		}
		if x.has_enum || x.const_of != nil {
			if out.has_enum || out.const_of != nil { clash = "enum" }
			out.has_enum, out.enum_of, out.const_of = x.has_enum, x.enum_of, x.const_of
		}
		if len(x.one_of) > 0 { if len(out.one_of) > 0 { clash = "oneOf" }; out.one_of = x.one_of }
		if x.cond != {} { if out.cond != {} { clash = "if" }; out.cond = x.cond }
		if c != top && x.unevaluated_items != nil { clash = "unevaluatedItems" } else if c != top && x.unevaluated_properties != nil { clash = "unevaluatedProperties" }
		if clash != "" { odin_refuse(s, clash); return top }
	}
	if .Array in out.kinds && len(arrays) > 0 {
		out.array = arrays[0]
		if len(arrays) > 1 {
			items := make([dynamic]rules.Node_Index, s.a)
			for a in arrays {
				x := s.d.arrays[a]
				if len(x.prefix) > 0 || x.contains != nil { odin_refuse(s, "prefixItems" if len(x.prefix) > 0 else "contains"); return top }
				append(&items, x.items)
			}
			out.array = add_block(&s.d.arrays, rules.Array{items = joined_of(s, items[:])})
		}
	}
	if .Object in out.kinds && len(objects) > 0 {
		out.object = objects[0] if len(objects) == 1 else joined_object(s, objects[:])
		if s.refused.kind != .None { return top }
	}
	keyword := "unevaluatedProperties" if t.unevaluated_properties != nil else "unevaluatedItems" if t.unevaluated_items != nil else ""
	if keyword != "" && (len(out.any_of) > 0 || len(out.one_of) > 0 || out.cond != {} || out.not != nil) { odin_refuse(s, keyword); return top }
	if u, has := t.unevaluated_properties.?; has && .Object in out.kinds {
		o := s.d.objects[out.object] if out.object >= 0 else rules.Object{additional = rules.NONE, keys = rules.NONE}
		if o.additional == rules.NONE { o.additional = u; out.object = add_block(&s.d.objects, o) }
	}
	if u, has := t.unevaluated_items.?; has && .Array in out.kinds {
		a := s.d.arrays[out.array] if out.array >= 0 else rules.Array{items = rules.NONE}
		if a.items == rules.NONE { a.items = u; out.array = add_block(&s.d.arrays, a) }
	}
	idx := node_added(s, out)
	if name, named := s.d.names[top]; named { s.d.names[idx] = name }
	return idx
}

@(private = "file")
joined_object :: proc(s: ^Source, objects: []i32) -> i32 {
	out := rules.Object{keys = rules.NONE}
	members := make([dynamic]rules.Member, s.a)
	for o in objects {
		for m in s.d.objects[o].members {
			at := -1
			for x, j in members { if x.name == m.name { at = j } }
			if at < 0 {
				append(&members, rules.Member{name = m.name, node = rules.NONE, only_required = true})
				at = len(members) - 1
			}
			x := &members[at]
			x.required ||= m.required
			if m.only_required { continue }
			tmp := rules.Node{rules = x.rules}
			clash := ""
			x.rules, clash = rules.merged(&tmp, m.rules)
			if clash != "" { odin_refuse(s, clash); return -1 }
			x.node = m.node if x.only_required else joined_of(s, {x.node, m.node})
			x.only_required = false
		}
	}
	others := make([dynamic]rules.Node_Index, s.a)
	for i in objects {
		o := s.d.objects[i]
		if o.additional != rules.NONE {
			for m in members {
				found := false
				for om in o.members { if om.name == m.name && !om.only_required { found = true; break } }
				if !found { odin_refuse(s, "additionalProperties"); return -1 }
			}
			append(&others, o.additional)
		}
		if o.keys != rules.NONE { out.keys = o.keys }
		if len(o.patterns) > 0 { out.patterns = o.patterns }
		if len(o.dependents) > 0 { out.dependents = o.dependents }
	}
	out.members, out.additional = members[:], joined_of(s, others[:])
	return add_block(&s.d.objects, out)
}

@(private = "file")
joined_of :: proc(s: ^Source, nodes: []rules.Node_Index) -> rules.Node_Index {
	if len(nodes) == 0 { return rules.NONE }
	if len(nodes) == 1 { return nodes[0] }
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
kinds_only :: proc(s: ^Source, at: rules.Node_Index) -> (rules.Kinds, bool) {
	i := odin_target(s, at)
	if i == rules.NONE { return {}, false }
	x := &s.d.nodes[i]
	return x.kinds, x.rules == {} && x.array < 0 && x.object < 0 && !x.integer_spelled && !x.has_enum && x.const_of == nil &&
		len(x.any_of) == 0 && len(x.all_of) == 0 && len(x.one_of) == 0 && x.not == nil && x.cond == {} &&
		x.ref == nil && x.dynamic_ref == nil && x.unevaluated_items == nil && x.unevaluated_properties == nil
}

@(private = "file")
takes_null :: proc(s: ^Source, at: rules.Node_Index, depth := 0) -> bool {
	i := settled(s, odin_target(s, at))
	if i == rules.NONE { return true }
	n := s.d.nodes[i]
	if .Null not_in n.kinds || depth > 32 { return false }
	if x, has := n.not.?; has && takes_null(s, x, depth + 1) { return false }
	if test, has := n.cond.test.?; has {
		branch := n.cond.then if takes_null(s, test, depth + 1) else n.cond.other
		if x, set := branch.?; set && !takes_null(s, x, depth + 1) { return false }
	}
	if n.has_enum || n.const_of != nil {
		for v in (n.enum_of if n.has_enum else []rules.Value{n.const_of.?}) {
			if rules.value_kind(v) == .Null { return true }
		}
		return false
	}
	taken := 0
	for x in n.any_of { if takes_null(s, x, depth + 1) { return true } }
	for x in n.one_of { taken += int(takes_null(s, x, depth + 1)) }
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

@(private = "file", rodata)
CARRIED := #partial [rules.String_Format]string{.Date_Time = "time.Time", .Uuid = "uuid.Identifier", .Email = "model.Email"}

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
	case r.minimum != "":     return "exclusiveMinimum" if r.exclusive_minimum else "minimum"
	case r.maximum != "":     return "exclusiveMaximum" if r.exclusive_maximum else "maximum"
	case r.multiple_of != "": return "multipleOf"
	case r.pattern != "":     return "pattern"
	case r.format != "":      return "format"
	}
	for low, j in ([?]u64{r.min_length, r.min_items, r.min_members}) { if low > 0 { return MIN_KEYS[j] } }
	for high, j in ([?]Maybe(u64){r.max_length, r.max_items, r.max_members}) { if high != nil { return MAX_KEYS[j] } }
	return ""
}

@(private = "file")
integer_spelled :: proc(s: ^Source, r: rules.Rules) -> (string, rules.Rules) {
	out := r
	out.minimum, out.maximum, out.multiple_of, out.exclusive_minimum, out.exclusive_maximum = "", "", "", false, false
	low, has_low := whole_bound(r.minimum, r.exclusive_minimum, true, s.a)
	high, has_high := whole_bound(r.maximum, r.exclusive_maximum, false, s.a)
	wide := has_low && low >= 0 && ((has_high && high > i128(max(i64))) || low > i128(max(i64)))
	least := i128(0) if wide else i128(min(i64))
	most := i128(max(u64)) if wide else i128(max(i64))
	if has_low && (low > most || (has_high && low < least)) {
		odin_refuse(s, "exclusiveMinimum" if r.exclusive_minimum else "minimum")
	} else if has_high && (high < least || (has_low && high > most)) {
		odin_refuse(s, "exclusiveMaximum" if r.exclusive_maximum else "maximum")
	}
	if has_low && low > least { out.minimum = whole_text(low, s.a) }
	if has_high && high < most { out.maximum = whole_text(high, s.a) }
	if r.multiple_of != "" {
		if p, held := numerator(rules.decimal_of(r.multiple_of), s.a); !held {
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
	if text == "" { return }
	d := rules.decimal_of(text)
	digits := strings.concatenate({d.head, d.tail}, a)
	fraction := false
	switch {
	case digits == "":
	case (d.wide != "" && !d.wide_neg) || d.point > 24: v = WIDE
	case d.wide != "" || d.point <= 0: fraction = true
	case:
		for c, j in transmute([]u8)digits {
			if j < int(d.point) { v = v * 10 + i128(c - '0') } else { fraction = true }
		}
		for _ in len(digits) ..< int(d.point) { v *= 10 }
	}
	v = -v if d.neg else v
	if fraction && up && !d.neg { v += 1 } else if fraction && !up && d.neg { v -= 1 } else if exclusive && !fraction { v += 1 if up else -1 }
	return v, true
}

@(private = "file")
numerator :: proc(d: rules.Decimal, a: runtime.Allocator) -> (p: i128, held: bool) {
	digits := strings.concatenate({d.head, d.tail}, a)
	if d.wide != "" || len(digits) > 19 || d.point - i128(len(digits)) > 19 { return 0, false }
	for c in transmute([]u8)digits { p = p * 10 + i128(c - '0') }
	for _ in len(digits) ..< int(max(d.point, 0)) { p *= 10 }
	for factor in ([2]i128{2, 5}) {
		for _ in d.point ..< i128(len(digits)) {
			if p % factor != 0 { break }
			p /= factor
		}
	}
	return p, p <= i128(max(u64))
}

@(private = "file")
whole_text :: proc(v: i128, a: runtime.Allocator) -> string {
	buf: [32]u8 = ---
	if v < 0 { return strings.concatenate({"-", strconv.write_uint(buf[:], u64(-v), 10)}, a) }
	return strings.clone(strconv.write_uint(buf[:], u64(v), 10), a)
}

@(private = "file")
default_spelled :: proc(s: ^Source, owner, field, field_type: string, at: rules.Node_Index, v: Spelled) {
	x, has := s.d.nodes[at].default_of.?
	if !has {
		if found := odin_target(s, at); found != rules.NONE { x, has = s.d.nodes[found].default_of.? }
	}
	if !has || rules.value_kind(x) == .Null { return }
	value, held := "", false
	switch {
	case v.decl >= 0 && s.decls[v.decl].literals != nil:
		value, held = s.decls[v.decl].literals[odin_operand_key(x, s.a)]
	case v.decl >= 0 && len(s.decls[v.decl].arms) > 0:
		for arm_kind in ([?]rules.Kind{.String, .Bool, .Integer, .Number}) {
			if arm, found := s.decls[v.decl].arms[arm_kind]; found {
				if value, held = scalar_literal(s, arm, x); held { break }
			}
		}
		if held { value = strings.concatenate({v.type, "(", value, ")"}, s.a) }
	case:
		value, held = scalar_literal(s, v, x)
	}
	if !held { odin_refuse(s, "default"); return }
	if strings.has_prefix(field_type, "^") {
		s.factories = true
		odin_put(&s.registers, "\tmodel.register_factory(reg, ", owner, ", ")
		strings.write_quoted_string(&s.registers, field)
		odin_put(&s.registers, ", proc(a: runtime.Allocator) -> ", field_type, " {\n\t\tp, _ := new_clone(", value, ", a)\n\t\treturn p\n\t}) or_return\n")
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
	case .String: return strings.concatenate({"s", default_text(x, a)}, a)
	case .Number: if digits, whole := default_number(x, "i64", a); whole { return strings.concatenate({"n", digits}, a) }
	case .True:   return "true"
	case .False:  return "false"
	}
	return ""
}

@(private = "file")
default_text :: proc(x: rules.Value, a: runtime.Allocator) -> string {
	buf: [256]u8 = ---
	s, owned, ok := rules.value_string(x, buf[:], a)
	return (s if owned else strings.clone(s, a)) if ok else ""
}

@(private = "file")
scalar_literal :: proc(s: ^Source, v: Spelled, x: rules.Value) -> (string, bool) {
	base := v.type
	if v.decl >= 0 {
		base = strings.trim_space(strings.trim_prefix(s.decls[v.decl].text, strings.concatenate({v.type, " :: distinct "}, s.a)))
	}
	b := strings.builder_make(s.a)
	kind := rules.value_kind(x)
	#partial switch kind {
	case .String:
		if base != "string" && base != "model.Email" { return "", false }
		odin_put(&b, v.type, "(")
		odin_literal(&b, default_text(x, s.a))
		strings.write_byte(&b, ')')
	case .Number:
		text, held := default_number(x, base, s.a)
		if !held { return "", false }
		if v.type == NUMBER_TEXT { strings.write_string(&b, text) } else { odin_put(&b, v.type, "(", text, ")") }
	case .True, .False:
		if base != "bool" { return "", false }
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
	return low_ok && high_ok && abs(low) <= max(f64) && abs(high) <= max(f64) && (r.multiple_of == "" || f64_exact_decimal(r.multiple_of))
}

@(private = "file")
f64_exact_decimal :: proc "contextless" (text: string) -> bool {
	if !rules.valid_decimal_text(text) { return false }
	d := rules.decimal_of(text)
	nd := len(d.head) + len(d.tail)
	k := d.point - i128(nd)
	if d.wide != "" || d.neg || d.head == "" || nd > 38 || k < -55 || k > 22 { return false }
	sig := u128(0)
	for c in transmute([]u8)d.head { sig = sig * 10 + u128(c - '0') }
	for c in transmute([]u8)d.tail { sig = sig * 10 + u128(c - '0') }
	if k < 0 {
		for _ in 0 ..< int(-k) { if sig % 5 != 0 { return false }; sig /= 5 }
	} else {
		for _ in 0 ..< int(k) { if sig > max(u128) / 5 { return false }; sig *= 5 }
	}
	e := k
	for sig > 0 && (sig & 1) == 0 { sig >>= 1; e += 1 }
	if sig >= (u128(1) << 53) || e < -1074 { return false }
	bits := i128(0)
	for tmp := sig; tmp > 0; tmp >>= 1 { bits += 1 }
	return e + bits - 1 <= 1023
}

@(private = "file")
default_number :: proc(x: rules.Value, base: string, a: runtime.Allocator) -> (string, bool) {
	buf: [128]u8 = ---
	raw, owned, ok := rules.value_number_text(x, buf[:], a)
	if !ok { return "", false }
	text := strings.clone(raw[1:] if len(raw) > 0 && raw[0] == '+' else raw, a)
	if owned { delete(raw, a) }
	text, _ = strings.replace_all(text, "E", "e", a)
	switch base {
	case NUMBER_TEXT:
		if f, fok := strconv.parse_f64(text); fok && abs(f) <= max(f64) {
			fbuf: [64]u8 = ---
			return strings.concatenate({NUMBER_TEXT, `{text = "`, text, `", value = `, strconv.write_float(fbuf[:], f, 'g', -1, 64, {}), `}`}, a), true
		}
		return strings.concatenate({NUMBER_TEXT, `{text = "`, text, `"}`}, a), true
	case "f64":
		f, fok := strconv.parse_f64(text)
		return text, fok && abs(f) <= max(f64)
	case "i64", "u64":
		whole, set := whole_bound(text, false, true, a)
		floor, _ := whole_bound(text, false, false, a)
		least := i128(0) if base == "u64" else i128(min(i64))
		most := i128(max(u64)) if base == "u64" else i128(max(i64))
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
				if c == '\\' || c == ',' || c == '"' || m.name == "-" { strings.write_byte(&tag, '\\') }
				strings.write_byte(&tag, c)
			}
		}
		odin_put(&tag, ",omitempty" if omit else "", ",omitunset\"" if unset else "\"")
	}
	if items := tag_items(s, r, !m.required, not_null); items != "" {
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
		if strings.builder_len(b^) > 0 { strings.write_byte(b, ',') }
		odin_put(b, ..parts)
	}
	if optional { item(&b, "optional") }
	if not_null { item(&b, "not_null") }
	if r.read_only || r.write_only { item(&b, "read_only" if r.read_only else "write_only") }
	if r.minimum != "" { item(&b, ">" if r.exclusive_minimum else ">=", r.minimum) }
	if r.maximum != "" { item(&b, "<" if r.exclusive_maximum else "<=", r.maximum) }
	if r.multiple_of != "" { item(&b, "multiple_of=", r.multiple_of) }
	ubuf: [24]u8 = ---
	for c in ([?]struct { low: u64, high: Maybe(u64) }{{r.min_length, r.max_length}, {r.min_items, r.max_items}, {r.min_members, r.max_members}}) {
		high, bounded := c.high.?
		if bounded && c.low == high {
			item(&b, "len=", strconv.write_uint(ubuf[:], high, 10))
		} else {
			if c.low > 0 { item(&b, "len>=", strconv.write_uint(ubuf[:], c.low, 10)) }
			if bounded { item(&b, "len<=", strconv.write_uint(ubuf[:], high, 10)) }
		}
	}
	if r.unique { item(&b, "unique") }
	if r.format != "" { item(&b, "format=", r.format) }
	if r.pattern != "" { item(&b, "pattern=", r.pattern) }
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
	o.texts.allocator, o.numbers.allocator = s.a, s.a
	values := n.enum_of if n.has_enum else []rules.Value{n.const_of.?}
	kinds := n.kinds + ({.Integer} if .Number in n.kinds else {})
	judged := rules.Node{kinds = n.kinds, rules = n.rules, array = -1, object = -1}
	judged.rules.assert_format ||= s.format_assert && !n.rules.format_foreign
	leaf: rules.Leaf
	if leaf, refused = rules.leaf_of(&judged, {}, s.a, nil, s.backing); refused != "" { return }
	rs, rserr := regex.scratch_make(s.backing)
	defer if rserr.kind == .None { regex.scratch_destroy(&rs) }
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
			if text, owned, sok := rules.value_string(v, buf[:], s.a); sok {
				if !owned { text = strings.clone(text, s.a) }
				fails, _ := rules.judge_string(&leaf, text, &rs, 0, s.backing)
				if .String in kinds && fails == {} && text not_in listed_texts {
					listed_texts[text] = {}
					append(&o.texts, text)
				}
			}
		case .Number:
			digits, _, nok := rules.value_number_text(v, buf[:], s.a)
			if !nok { o.kinds += {.Number}; o.unspelled += {.Number}; continue }
			d := rules.decimal_of(digits)
			whole := rules.integral(d)
			x, fits := rules.decimal_i64(d)
			fits &&= x >= -(1 << 53) && x <= 1 << 53
			if rules.judge_number(&leaf, digits, x if fits else nil) != {} || .Integer not_in kinds || (!whole && .Number not_in kinds) {
				continue
			}
			if !whole || !fits {
				o.kinds += {.Integer if whole else .Number}
				o.unspelled += {.Number}
			} else if x not_in listed_numbers {
				listed_numbers[x] = {}
				append(&o.numbers, x)
			}
		case .Array:
			if .Array in kinds { o.kinds += {.Array}; o.unspelled += {.Array} }
		case .Object:
			if .Object in kinds { o.kinds += {.Object}; o.unspelled += {.Object} }
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
enum_judged :: proc(s: ^Source, n: ^rules.Node) -> (bool, Operands) {
	if !n.has_enum && n.const_of == nil { return false, {} }
	o, refused := operands_of(s, n)
	return refused == "" && (o.unspelled != {} || (n.has_enum && n.const_of != nil)), o
}

@(private = "file")
enum_spelled :: proc(s: ^Source, i: rules.Node_Index, hint: string) -> (out: Spelled) {
	n := s.d.nodes[i]
	out.decl = -1
	o, refused := operands_of(s, &n)
	if refused != "" { odin_refuse(s, refused); return }
	out.null = o.null
	classes := int(len(o.texts) > 0) + int(len(o.numbers) > 0) + int(o.truth[0])
	switch {
	case classes == 0 && out.null: return {type = null_type(s), decl = -1}
	case classes == 0: odin_refuse(s, "enum" if n.has_enum else "const"); return
	case classes == 1 && o.truth[0]: out.type = "bool"; return
	case classes == 1:
		out.decl = enum_declared(s, part_of(s, i), n.description, o.texts[:], o.numbers[:], hint)
		out.type = s.decls[out.decl].name
		return
	}
	k := odin_declare(s, part_of(s, i), hint)
	name := s.decls[k].name
	b := strings.builder_make(s.a)
	odin_comment(&b, "", n.description)
	odin_put(&b, name, " :: union {" if out.null else " :: union #no_nil {")
	literals := make(map[string]string, 16, s.a)
	if len(o.texts) > 0 {
		arm := enum_declared(s, part_of(s, i, .String), "", o.texts[:], nil, strings.concatenate({name, "_String"}, s.a))
		strings.write_string(&b, s.decls[arm].name)
		for op, val in s.decls[arm].literals { literals[op] = strings.concatenate({name, "(", val, ")"}, s.a) }
	}
	if len(o.numbers) > 0 {
		arm := enum_declared(s, part_of(s, i, .Integer), "", nil, o.numbers[:], strings.concatenate({name, "_Integer"}, s.a))
		odin_put(&b, ", " if len(o.texts) > 0 else "", s.decls[arm].name)
		for op, val in s.decls[arm].literals { literals[op] = strings.concatenate({name, "(", val, ")"}, s.a) }
	}
	strings.write_string(&b, ", bool}\n" if o.truth[0] else "}\n")
	if o.truth[0] {
		literals["true"] = strings.concatenate({name, "(true)"}, s.a)
		literals["false"] = strings.concatenate({name, "(false)"}, s.a)
	}
	s.decls[k].text, s.decls[k].open, s.decls[k].literals = strings.to_string(b), false, literals
	return {type = name, decl = k}
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
		member := strings.concatenate({"V", "M" if x < 0 else "", strconv.write_uint(ubuf[:], u64(-x) if x < 0 else u64(x), 10)}, s.a)
		xs := strconv.write_int(ibuf[:], x, 10)
		odin_put(&b, "\t", member, " = ", xs, ",\n")
		literals[strings.concatenate({"n", xs}, s.a)] = strings.concatenate({name, ".", member}, s.a)
	}
	for x in texts {
		sp := spelled_as_is(x, true, s.a)
		member := odin_unique(&members, "Empty" if sp == "" else sp, s.a)
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

@(private = "file", rodata)
KIND_NAMES := [rules.Kind]string{.Null = "Null", .Bool = "Bool", .Integer = "Integer", .Number = "Number", .String = "String", .Array = "List", .Object = "Object"}

@(private = "file")
odin_member_type :: proc(s: ^Source, v: Spelled) -> string {
	return strings.concatenate({"^", v.type}, s.a) if (v.decl >= 0 && s.decls[v.decl].open) else odin_held_type(v, s.a)
}

@(private = "file")
odin_held_type :: proc(v: Spelled, a: runtime.Allocator) -> string {
	return strings.concatenate({"Maybe(", v.type, ")"}, a) if v.null else v.type
}

@(private = "file")
odin_declare :: proc(s: ^Source, part: Odin_Part, hint: string) -> int {
	name := spelled_as_is(s.d.names[part.node] or_else s.d.nodes[part.node].title, true, s.a) if part.kind == nil else ""
	append(&s.decls, Decl{name = odin_unique(&s.taken, name if name != "" else hint, s.a), open = true})
	idx := len(s.decls) - 1
	s.of_node[part] = idx
	if s.judged_bind.active && s.judged_bind.inner == part { s.of_node[s.judged_bind.outer] = idx }
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
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
			start, prev = true, 0
			continue
		}
		upper := c >= 'A' && c <= 'Z'
		if upper && prev >= 'a' && prev <= 'z' { start = true }
		if start && strings.builder_len(b) > 0 { strings.write_byte(&b, '_') }
		strings.write_byte(&b, c - 32 if type && start && c >= 'a' && c <= 'z' else (c + 32 if !type && upper else c))
		start, prev = false, c
	}
	out := strings.to_string(b)
	if out == "" { return "" }
	if out[0] >= '0' && out[0] <= '9' { out = strings.concatenate({"_", out}, a) }
	return strings.concatenate({out, "_"}, a) if slice.contains(ODIN_KEYWORDS[:], out) else out
}

@(private = "file")
package_spelled :: proc(name: string) -> bool {
	if name == "" || name == "_" || slice.contains(ODIN_KEYWORDS[:], name) || slice.contains(ODIN_PACKAGES[:], name) { return false }
	for c, j in transmute([]u8)name {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || (j > 0 && c >= '0' && c <= '9')) { return false }
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
	for p in parts { strings.write_string(b, p) }
}
