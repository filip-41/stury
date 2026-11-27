// Writes a `rules.Description` as a Draft 2020-12 JSON Schema using `Json_Writer` (`write.Out`).
// Explicit heap stack (zero unbounded recursion), zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.
package schema

import "base:runtime"
import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/schema/rules"

Write_Options :: struct {
	indent: u8,
	tab:    bool,
}

DIALECT_URI :: "https://raw.githubusercontent.com/filip-41/stury/main/core/schema/meta/stury/format-assertion.json"
@(private)
DIALECT :: #load("meta/stury/format-assertion.json", string)

@(require_results)
write_schema :: proc(d: ^rules.Description, opts := Write_Options{}, allocator := context.allocator) -> ([]u8, Error) {
	if d == nil || d.root < 0 || int(d.root) >= len(d.nodes) {
		return nil, make_error(.Bad_Option, "root", "empty description", allocator = allocator)
	}
	uses, e1 := make([]u8, len(d.nodes), allocator)
	if e1 != nil { return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator) }
	defer delete(uses, allocator)
	refs, e2 := make([]string, len(d.nodes), allocator)
	if e2 != nil { return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator) }
	defer {
		for r in refs { delete(r, allocator) }
		delete(refs, allocator)
	}
	w := Schema_Writer{d = d, uses = uses, refs = refs, allocator = allocator}
	count_uses(&w, d.root, false)
	for changed := true; changed; {
		changed = false
		for x in d.anchors {
			if w.uses[x.node] != 2 && dynamic_reached(&w, x.name) {
				count_uses(&w, x.node, true)
				changed = true
			}
		}
	}
	for u, j in w.uses {
		if u > 0 {
			w.anchored ||= d.nodes[j].dynamic_ref != nil
			w.has_uneval_items ||= d.nodes[j].unevaluated_items != nil
		}
	}
	for changed := w.anchored; changed; {
		changed = false
		for u, j in w.uses {
			if resource := d.nodes[j].resource; u == 2 && resource != d.root && w.uses[resource] != 2 {
				count_uses(&w, resource, true)
				changed = true
			}
		}
	}
	if w.oom { return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator) }
	if w.refused != "" { return nil, make_error(.Unsupported, w.refused, "unsupported schema feature for 2020-12 writer", allocator = allocator) }
	name_defs(&w)
	if w.oom || !jw_init(&w.jw, opts.indent, opts.tab, allocator) {
		return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator)
	}
	w.ops.allocator = allocator
	defer delete(w.ops)

	root := &d.nodes[d.root]
	if root.kinds == {} {
		jw_bool(&w.jw, false)
	} else {
		jw_open_object(&w.jw)
		sw_put(&w, "$schema", DIALECT_URI if asserts_any(d) else "https://json-schema.org/draft/2020-12/schema")
		sw_push(&w, {kind = .Close_Object}, {kind = .Put_Defs, node = d.root}, {kind = .Body, node = d.root, rl = root.rules})
		sw_run(&w)
	}
	if w.oom || w.jw.err == .No_Memory {
		jw_drop(&w.jw)
		return nil, make_error(.No_Memory, w.keyword, "out of memory", allocator = allocator)
	}
	if w.refused != "" {
		jw_drop(&w.jw)
		return nil, make_error(.Unsupported, w.refused, "unsupported schema feature", allocator = allocator)
	}
	out, ok := jw_finish(&w.jw)
	if !ok { return nil, make_error(.No_Memory, w.keyword, "failed writing schema JSON", allocator = allocator) }
	return out, {}
}

@(private = "file")
asserts_any :: proc(d: ^rules.Description) -> bool {
	for n in d.nodes { if n.rules.assert_format && rules.format_of(n.rules.format) != .None { return true } }
	for o in d.objects {
		for m in o.members { if m.rules.assert_format && rules.format_of(m.rules.format) != .None { return true } }
	}
	return false
}

@(private = "file")
Write_Op_Kind :: enum u8 {
	Key, Key_Raw, Open_Object, Close_Object, Open_Array, Close_Array,
	Schema, Node_Object, Body, Put_Defs, Format_Pattern, Wrap_Contains, Count, String_Array,
}

@(private = "file")
Write_Op :: struct {
	kind:  Write_Op_Kind,
	node:  rules.Node_Index,
	extra: rules.Rules,
	rl:    rules.Rules,
	text:  string,
	count: u64,
	names: []string,
	arr:   i32,
}

@(private = "file")
Schema_Writer :: struct {
	jw:               Json_Writer,
	d:                ^rules.Description,
	uses:             []u8,
	refs:             []string,
	ops:              [dynamic]Write_Op,
	keyword:          string,
	refused:          string,
	anchored:         bool,
	has_uneval_items: bool,
	oom:              bool,
	allocator:        runtime.Allocator,
}

@(private = "file")
sw_push :: proc(w: ^Schema_Writer, ops: ..Write_Op) {
	if _, err := append(&w.ops, ..ops); err != nil { w.oom = true }
}

@(private = "file")
sw_run :: proc(w: ^Schema_Writer) {
	for len(w.ops) > 0 && !w.oom && w.jw.err == .None {
		op := pop(&w.ops)
		switch op.kind {
		case .Key:          sw_key(w, op.text)
		case .Key_Raw:      jw_key(&w.jw, op.text)
		case .Open_Object:  jw_open_object(&w.jw)
		case .Close_Object: jw_close_object(&w.jw)
		case .Open_Array:   jw_open_array(&w.jw)
		case .Close_Array:  jw_close_array(&w.jw)
		case .Count:        sw_put_count(w, op.text, op.count)
		case .String_Array:
			jw_open_array(&w.jw)
			for s in op.names { jw_string(&w.jw, s) }
			jw_close_array(&w.jw)
		case .Format_Pattern:
			jw_open_object(&w.jw)
			sw_put(w, "pattern", op.text)
			jw_close_object(&w.jw)
		case .Wrap_Contains:
			a := w.d.arrays[op.arr]
			c, has := a.contains.?
			if !has { continue }
			mark := len(w.ops)
			sw_push(w, {kind = .Open_Object}, {kind = .Key, text = "not"}, {kind = .Open_Object}, {kind = .Key, text = "not"}, {kind = .Open_Object}, {kind = .Key, text = "contains"}, {kind = .Schema, node = c})
			if count, ok := a.min_contains.?; ok { sw_push(w, {kind = .Count, text = "minContains", count = count}) }
			if count, ok := a.max_contains.?; ok { sw_push(w, {kind = .Count, text = "maxContains", count = count}) }
			sw_push(w, {kind = .Close_Object}, {kind = .Close_Object}, {kind = .Close_Object})
			slice.reverse(w.ops[mark:])
		case .Put_Defs:    sw_expand_defs(w, op.node)
		case .Schema:      sw_expand_schema(w, op.node, op.extra)
		case .Node_Object: sw_expand_node(w, op.node, op.extra)
		case .Body:        sw_expand_body(w, op.node, op.rl)
		}
	}
}

@(private = "file")
dynamic_reached :: proc(w: ^Schema_Writer, name: string) -> bool {
	for u, j in w.uses {
		target, has := w.d.nodes[j].dynamic_ref.?
		if u == 0 || !has { continue }
		for x in w.d.anchors { if x.node == target && x.name == name { return true } }
	}
	return false
}

@(private = "file")
count_uses :: proc(w: ^Schema_Writer, start: rules.Node_Index, start_by_ref: bool) {
	Item :: struct { node: rules.Node_Index, by_ref: bool }
	stack, serr := make([dynamic]Item, 0, 32, w.allocator)
	if serr != nil { w.oom = true; return }
	defer delete(stack)
	push_item :: proc(w: ^Schema_Writer, stack: ^[dynamic]Item, node: rules.Node_Index, by_ref: bool) {
		if node != rules.NONE { if _, err := append(stack, Item{node, by_ref}); err != nil { w.oom = true } }
	}
	push_item(w, &stack, start, start_by_ref)
	for len(stack) > 0 && !w.oom {
		it := pop(&stack)
		i := it.node
		seen := w.uses[i] > 0
		w.uses[i] = 2 if it.by_ref || (seen && w.d.nodes[i].kinds != {}) || w.uses[i] == 2 else 1
		if seen { continue }
		n := &w.d.nodes[i]
		if n.integer_spelled { sw_refuse(w, "integer") }
		if dr, has := n.dynamic_ref.?; has { push_item(w, &stack, dr, true) }
		if r, has := n.ref.?; has { push_item(w, &stack, r, true) }
		for list in ([?][]rules.Node_Index{n.any_of, n.all_of, n.one_of}) {
			for c in list { push_item(w, &stack, c, false) }
		}
		for c in ([?]Maybe(rules.Node_Index){n.not, n.cond.test, n.cond.then, n.cond.other, n.unevaluated_items, n.unevaluated_properties}) {
			if id, has := c.?; has { push_item(w, &stack, id, false) }
		}
		if n.array >= 0 {
			a := w.d.arrays[n.array]
			for c in a.prefix { push_item(w, &stack, c, false) }
			push_item(w, &stack, a.items, false)
			if c, has := a.contains.?; has { push_item(w, &stack, c, false) }
		}
		if n.object >= 0 {
			o := w.d.objects[n.object]
			for m in o.members { push_item(w, &stack, m.node, false) }
			for p in o.patterns { push_item(w, &stack, p.node, false) }
			for x in o.dependents { if id, has := x.node.?; has { push_item(w, &stack, id, false) } }
			push_item(w, &stack, o.additional, false)
			push_item(w, &stack, o.keys, false)
		}
	}
}

@(private = "file")
DEFS :: "#/$defs/"

@(private = "file")
name_defs :: proc(w: ^Schema_Writer) {
	taken, terr := make(map[string]bool, 16, w.allocator)
	if terr != nil { w.oom = true; return }
	owned_names := make([dynamic]string, w.allocator)
	defer {
		for s in owned_names { delete(s, w.allocator) }
		delete(owned_names)
		delete(taken)
	}
	keep_owned :: proc(w: ^Schema_Writer, owned: ^[dynamic]string, parts: ..string) -> (string, bool) {
		s, err := strings.concatenate(parts, w.allocator)
		if err != nil { w.oom = true; return "", false }
		if _, aerr := append(owned, s); aerr != nil { delete(s, w.allocator); w.oom = true; return "", false }
		return s, true
	}
	ibuf: [24]u8 = ---
	for u, j in w.uses {
		if u != 2 { continue }
		name := w.d.names[rules.Node_Index(j)] or_else ""
		if name == "" || taken[name] || !plain_name(name) {
			cand, ok := keep_owned(w, &owned_names, "n", strconv.write_int(ibuf[:], i64(j), 10))
			if !ok { return }
			for taken[cand] {
				cand, ok = keep_owned(w, &owned_names, cand, "_")
				if !ok { return }
			}
			name = cand
		}
		taken[name] = true
		ref_s, rerr := strings.concatenate({DEFS, name}, w.allocator)
		if rerr != nil { w.oom = true; return }
		w.refs[j] = ref_s
	}
}

@(private = "file")
plain_name :: proc "contextless" (name: string) -> bool {
	for c in transmute([]u8)name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-' || c == '.') { return false }
	}
	return true
}

@(private = "file")
sw_put_ref :: proc(w: ^Schema_Writer, key: string, i: rules.Node_Index) {
	if !w.anchored {
		sw_put(w, key, "#" if i == w.d.root else w.refs[i])
		return
	}
	id := id_of(w.d.nodes[i].resource, w.allocator)
	defer delete(id, w.allocator)
	if w.d.nodes[i].resource == i {
		sw_put(w, key, id)
		return
	}
	full := strings.concatenate({id, w.refs[i]}, w.allocator)
	sw_put(w, key, full)
	delete(full, w.allocator)
}

@(private = "file")
anchor_name :: proc(name: string, allocator: runtime.Allocator) -> (string, bool) {
	if strings.has_prefix(name, "$") { return strings.concatenate({"_", name[1:]}, allocator), true }
	return name, false
}

@(private = "file")
id_of :: proc(resource: rules.Node_Index, allocator: runtime.Allocator) -> string {
	buf: [24]u8 = ---
	return strings.concatenate({"https://schema.invalid/r", strconv.write_int(buf[:], i64(resource), 10)}, allocator)
}

@(private = "file")
home_of :: proc "contextless" (w: ^Schema_Writer, j: rules.Node_Index) -> rules.Node_Index {
	return w.d.root if (!w.anchored || w.d.nodes[j].resource == j) else w.d.nodes[j].resource
}

@(private = "file")
sw_expand_defs :: proc(w: ^Schema_Writer, owner: rules.Node_Index) {
	mark := len(w.ops)
	opened := false
	for u, j in w.uses {
		at := rules.Node_Index(j)
		if u != 2 || at == owner || at == w.d.root || home_of(w, at) != owner { continue }
		if !opened {
			sw_push(w, {kind = .Key, text = "$defs"}, {kind = .Open_Object})
			opened = true
		}
		sw_push(w, {kind = .Key_Raw, text = w.refs[j][len(DEFS):]}, {kind = .Node_Object, node = at})
	}
	if opened {
		sw_push(w, {kind = .Close_Object})
		slice.reverse(w.ops[mark:])
	}
}

@(private = "file")
sw_expand_schema :: proc(w: ^Schema_Writer, i: rules.Node_Index, extra: rules.Rules) {
	if w.d.nodes[i].kinds == {} { jw_bool(&w.jw, false); return }
	if w.uses[i] != 2 { sw_expand_node(w, i, extra); return }
	jw_open_object(&w.jw)
	sw_put_ref(w, "$ref", i)
	if pat := sw_put_rules(w, extra); pat != "" {
		sw_key(w, "allOf")
		jw_open_array(&w.jw)
		jw_open_object(&w.jw)
		sw_put(w, "pattern", pat)
		jw_close_object(&w.jw)
		jw_close_array(&w.jw)
	}
	jw_close_object(&w.jw)
}

@(private = "file")
sw_expand_node :: proc(w: ^Schema_Writer, i: rules.Node_Index, extra: rules.Rules) {
	n := &w.d.nodes[i]
	if n.kinds == {} { jw_bool(&w.jw, false); return }
	jw_open_object(&w.jw)
	rl, clash := rules.merged(n, extra)
	if clash == "" && n.rules.assert_format && extra.assert_format && n.rules.format != extra.format { clash = "format" }
	if clash != "" { sw_refuse(w, clash) }
	mark := len(w.ops)
	sw_push(w, {kind = .Body, node = i, rl = rl})
	if w.anchored && n.resource == i { sw_push(w, {kind = .Put_Defs, node = i}) }
	sw_push(w, {kind = .Close_Object})
	slice.reverse(w.ops[mark:])
}

@(private = "file")
sw_expand_body :: proc(w: ^Schema_Writer, i: rules.Node_Index, rl: rules.Rules) {
	n := &w.d.nodes[i]
	if w.anchored {
		if n.resource == i {
			id := id_of(i, w.allocator)
			sw_put(w, "$id", id)
			delete(id, w.allocator)
		}
		for x in w.d.anchors {
			if x.node == i {
				an, an_own := anchor_name(x.name, w.allocator)
				sw_put(w, "$dynamicAnchor", an)
				if an_own { delete(an, w.allocator) }
			}
		}
	}
	if n.kinds != rules.EVERY_KIND {
		sw_key(w, "type")
		many := card(n.kinds) > 1
		if many { jw_open_array(&w.jw) }
		for t in TYPE_KINDS { if t.kinds <= n.kinds { jw_string(&w.jw, t.name) } }
		if many { jw_close_array(&w.jw) }
	}
	for f in ([?]struct { k, v: string }{{"title", n.title}, {"description", n.description}, {"contentEncoding", n.content_encoding}, {"contentMediaType", n.content_media_type}}) {
		if f.v != "" { sw_put(w, f.k, f.v) }
	}
	if v, ok := n.default_of.?; ok {
		sw_key(w, "default")
		if !jw_value(&w.jw, v, w.allocator) { sw_refuse(w, "default") }
	}
	if len(n.examples) > 0 {
		sw_key(w, "examples")
		jw_open_array(&w.jw)
		for v in n.examples { if !jw_value(&w.jw, v, w.allocator) { sw_refuse(w, "examples") } }
		jw_close_array(&w.jw)
	}
	if n.deprecated { sw_key(w, "deprecated"); jw_bool(&w.jw, true) }
	if ref, ok := n.ref.?; ok { sw_put_ref(w, "$ref", ref) }
	if target, ok := n.dynamic_ref.?; ok && .Dynamic_Static in n.spelled {
		sw_put_ref(w, "$dynamicRef", target)
	} else if ok {
		for x in w.d.anchors {
			if x.node == target {
				id := id_of(x.resource, w.allocator)
				an, an_own := anchor_name(x.name, w.allocator)
				dr := strings.concatenate({id, "#", an}, w.allocator)
				sw_put(w, "$dynamicRef", dr)
				delete(dr, w.allocator)
				delete(id, w.allocator)
				if an_own { delete(an, w.allocator) }
				break
			}
		}
	}
	if n.has_enum {
		sw_key(w, "enum")
		jw_open_array(&w.jw)
		for v in n.enum_of { if !jw_value(&w.jw, v, w.allocator) { sw_refuse(w, "enum") } }
		jw_close_array(&w.jw)
	}
	if v, ok := n.const_of.?; ok {
		sw_key(w, "const")
		if !jw_value(&w.jw, v, w.allocator) { sw_refuse(w, "const") }
	}

	format_pat := sw_put_rules(w, rl)
	wrap_contains := n.array >= 0 && w.d.arrays[n.array].contains != nil && !w.d.arrays[n.array].evaluates_contains && w.has_uneval_items

	mark := len(w.ops)
	if len(n.all_of) > 0 || format_pat != "" || wrap_contains {
		sw_push(w, {kind = .Key, text = "allOf"}, {kind = .Open_Array})
		for c in n.all_of { sw_push(w, {kind = .Schema, node = c}) }
		if format_pat != "" { sw_push(w, {kind = .Format_Pattern, text = format_pat}) }
		if wrap_contains { sw_push(w, {kind = .Wrap_Contains, arr = n.array}) }
		sw_push(w, {kind = .Close_Array})
	}
	sw_push_nodes(w, "anyOf", n.any_of)
	sw_push_nodes(w, "oneOf", n.one_of)
	for s in ([?]struct { k: string, id: Maybe(rules.Node_Index) }{
		{"not", n.not}, {"if", n.cond.test}, {"then", n.cond.then}, {"else", n.cond.other},
		{"unevaluatedItems", n.unevaluated_items}, {"unevaluatedProperties", n.unevaluated_properties},
	}) {
		if id, ok := s.id.?; ok { sw_push(w, {kind = .Key, text = s.k}, {kind = .Schema, node = id}) }
	}
	if n.array >= 0 { sw_push_array(w, w.d.arrays[n.array], wrap_contains) }
	if n.object >= 0 { sw_push_object(w, w.d.objects[n.object]) }
	slice.reverse(w.ops[mark:])
}

@(private = "file")
sw_push_nodes :: proc(w: ^Schema_Writer, name: string, list: []rules.Node_Index) {
	if len(list) == 0 { return }
	sw_push(w, {kind = .Key, text = name}, {kind = .Open_Array})
	for c in list { sw_push(w, {kind = .Schema, node = c}) }
	sw_push(w, {kind = .Close_Array})
}

@(private = "file")
sw_push_array :: proc(w: ^Schema_Writer, a: rules.Array, wrapped_contains: bool) {
	sw_push_nodes(w, "prefixItems", a.prefix)
	if a.items != rules.NONE { sw_push(w, {kind = .Key, text = "items"}, {kind = .Schema, node = a.items}) }
	if !wrapped_contains {
		if c, has := a.contains.?; has {
			sw_push(w, {kind = .Key, text = "contains"}, {kind = .Schema, node = c})
			if count, ok := a.min_contains.?; ok { sw_push(w, {kind = .Count, text = "minContains", count = count}) }
			if count, ok := a.max_contains.?; ok { sw_push(w, {kind = .Count, text = "maxContains", count = count}) }
		}
	}
}

@(private = "file")
sw_push_object :: proc(w: ^Schema_Writer, o: rules.Object) {
	listed, required := false, false
	for m in o.members { listed ||= !m.only_required; required ||= m.required }
	if listed {
		sw_push(w, {kind = .Key, text = "properties"}, {kind = .Open_Object})
		for m in o.members {
			if !m.only_required { sw_push(w, {kind = .Key_Raw, text = m.name}, {kind = .Schema, node = m.node, extra = m.rules}) }
		}
		sw_push(w, {kind = .Close_Object})
	}
	if required {
		sw_key(w, "required")
		jw_open_array(&w.jw)
		for m in o.members { if m.required { jw_string(&w.jw, m.name) } }
		jw_close_array(&w.jw)
	}
	if len(o.patterns) > 0 {
		sw_push(w, {kind = .Key, text = "patternProperties"}, {kind = .Open_Object})
		for p in o.patterns { sw_push(w, {kind = .Key_Raw, text = p.expression}, {kind = .Schema, node = p.node}) }
		sw_push(w, {kind = .Close_Object})
	}
	if o.additional != rules.NONE { sw_push(w, {kind = .Key, text = "additionalProperties"}, {kind = .Schema, node = o.additional}) }
	if o.keys != rules.NONE { sw_push(w, {kind = .Key, text = "propertyNames"}, {kind = .Schema, node = o.keys}) }
	for pass, j in ([?]string{"dependentRequired", "dependentSchemas"}) {
		started := false
		for x in o.dependents {
			if (x.node == nil) != (j == 0) { continue }
			if !started { sw_push(w, {kind = .Key, text = pass}, {kind = .Open_Object}); started = true }
			sw_push(w, {kind = .Key_Raw, text = x.name})
			if node, ok := x.node.?; ok { sw_push(w, {kind = .Schema, node = node}) } else { sw_push(w, {kind = .String_Array, names = x.required}) }
		}
		if started { sw_push(w, {kind = .Close_Object}) }
	}
}

@(private = "file", rodata)
BOUND_KEYS := [?]string{"minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"}
@(private, rodata)
MIN_KEYS := [?]string{"minLength", "minItems", "minProperties"}
@(private, rodata)
MAX_KEYS := [?]string{"maxLength", "maxItems", "maxProperties"}

@(private = "file")
sw_put_rules :: proc(w: ^Schema_Writer, rl: rules.Rules) -> string {
	for text, j in ([?]string{rl.minimum, rl.maximum}) {
		if text != "" {
			sw_put_number(w, BOUND_KEYS[j + 2 * int(rl.exclusive_minimum if j == 0 else rl.exclusive_maximum)], text)
		}
	}
	if rl.multiple_of != "" { sw_put_number(w, "multipleOf", rl.multiple_of) }
	for count, j in ([?]u64{rl.min_length, rl.min_items, rl.min_members}) { if count > 0 { sw_put_count(w, MIN_KEYS[j], count) } }
	for count, j in ([?]Maybe(u64){rl.max_length, rl.max_items, rl.max_members}) { if c, ok := count.?; ok { sw_put_count(w, MAX_KEYS[j], c) } }
	spelled := rules.FORMAT_PATTERNS[rules.format_of(rl.format)] if rl.assert_format else ""
	if rl.pattern != "" || spelled != "" { sw_put(w, "pattern", rl.pattern if rl.pattern != "" else spelled) }
	if rl.format != "" { sw_put(w, "format", rl.format) }
	for flag in ([?]struct { set: bool, name: string }{{rl.unique, "uniqueItems"}, {rl.read_only, "readOnly"}, {rl.write_only, "writeOnly"}}) {
		if flag.set { sw_key(w, flag.name); jw_bool(&w.jw, true) }
	}
	if rl.markup != .Any {
		sw_key(w, "xml")
		jw_open_object(&w.jw)
		sw_put(w, "nodeType", NODE_TYPES[rl.markup])
		jw_close_object(&w.jw)
	}
	return spelled if rl.pattern != "" && spelled != rl.pattern else ""
}

@(private = "file", rodata)
NODE_TYPES := [rules.Markup_Node]string{.Any = "", .Attribute = "attribute", .Element = "element", .Text = "text"}

@(private = "file")
sw_key :: proc(w: ^Schema_Writer, name: string) {
	if w.jw.err == .None { w.keyword = name }
	jw_key(&w.jw, name)
}

@(private = "file")
sw_refuse :: proc(w: ^Schema_Writer, keyword: string) {
	if w.refused == "" { w.refused = keyword }
}

@(private = "file")
sw_put_number :: proc(w: ^Schema_Writer, name, text: string) {
	sw_key(w, name)
	if rules.valid_decimal_text(text) {
		b := strings.builder_make(w.allocator)
		defer strings.builder_destroy(&b)
		rules.write_decimal(&b, rules.decimal_of(text))
		jw_number(&w.jw, strings.to_string(b))
		return
	}
	if strings.contains_any(text, "xX") {
		if n, ok := strconv.parse_i64_maybe_prefixed(text); ok { jw_int(&w.jw, n); return }
	}
	sw_refuse(w, name)
}

@(private = "file")
sw_put :: proc(w: ^Schema_Writer, name, text: string) { sw_key(w, name); jw_string(&w.jw, text) }

@(private = "file")
sw_put_count :: proc(w: ^Schema_Writer, name: string, n: u64) { sw_key(w, name); jw_uint(&w.jw, n) }
