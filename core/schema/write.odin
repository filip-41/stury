package schema

import "base:runtime"
import "core:strconv"
import "core:strings"
import "../spell"
import core "../"
import "../rules"
import "../write"

// Writes `d` as a 2020-12 JSON Schema in the format `as`. A node that is used twice, or that a `$ref` reaches, goes to
// `$defs` under its name in `d` or `n<index>` and is referred to, so a shared or recursive node is written once, with
// the rules a member adds beside its `$ref`. A description that writes a `$dynamicRef` writes each of its schema resources
// under an `$id` of its own, so the `$dynamicRef` reaches the anchors it reached, and refers to every node by an absolute
// URI. An operand the format cannot spell and a draft 4 integer are `.Unsupported`, naming the keyword in `want.text`. A
// description that asserts a format names `DIALECT_URI` as its `$schema`, so every `format` of it asserts, and writes
// beside each asserted format the pattern that spells it, in an `allOf` when the node has a pattern of its own.
write :: proc(d: ^rules.Description, as: core.As, opts := core.Write_Options{}, allocator := context.allocator) -> (text: []u8, err: core.Error) {
	uses, e := make([]u8, len(d.nodes), allocator)
	refs: []string
	if e == nil {
		refs, e = make([]string, len(d.nodes), allocator)
	}
	if e != nil {
		return nil, e
	}
	w := Writer {
		d    = d,
		uses = uses,
		refs = refs,
	}
	defer delete(w.uses, allocator)
	defer delete(w.refs, allocator)
	count(&w, d.root, false)
	// A dynamic anchor is written when a `$dynamicRef` of a written node names it.
	for changed := true; changed; {
		changed = false
		for x in d.anchors {
			if w.uses[x.node] != 2 && dynamic_reached(&w, x.name) {
				count(&w, x.node, true)
				changed = true
			}
		}
	}
	for u, j in w.uses {
		w.anchored ||= u > 0 && d.nodes[j].dynamic_ref != nil
	}
	// A node written under a resource's `$defs` needs the resource written, as a definition of the root.
	for changed := w.anchored; changed; {
		changed = false
		for u, j in w.uses {
			resource := d.nodes[j].resource
			if u == 2 && resource != d.root && w.uses[resource] != 2 {
				count(&w, resource, true)
				changed = true
			}
		}
	}
	if w.refused != "" {
		return nil, core.error_of(core.Typed_Refusal{kind = .Unsupported, want = {text = w.refused}})
	}
	name_defs(&w, allocator)
	defer for r in w.refs {
		delete(r, allocator)
	}
	if kind := write.tokens_init(&w.t, as, opts, allocator); kind != .None {
		return nil, core.error_of(core.Typed_Refusal{kind = kind})
	}
	root := &d.nodes[d.root]
	if root.kinds == {} {
		write.value_bool(&w.t, false)
	} else {
		write.open_object(&w.t)
		put(&w, "$schema", DIALECT_URI if asserts(d) else "https://json-schema.org/draft/2020-12/schema")
		body(&w, d.root, root, root.rules)
		put_defs(&w, d.root)
		write.close(&w.t)
	}
	terr: core.Typed_Refusal
	text, terr = write.tokens_finish(&w.t)
	if terr.kind == .None {
		return text, nil
	}
	if w.refused != "" {
		terr.kind = .Unsupported
	}
	terr.want.text = w.refused if w.refused != "" else w.keyword
	return text, core.error_of(terr)
}

// stury's dialect: 2020-12 with the format-assertion vocabulary in place of format-annotation. `DIALECT` is its
// meta-schema, which a reader of a schema that names it needs at `DIALECT_URI`. stury's own reader holds it.
DIALECT_URI :: "https://raw.githubusercontent.com/filip-41/stury/main/core/schema/meta/stury/format-assertion.json"
@(private)
DIALECT :: #load("meta/stury/format-assertion.json", string)

// Whether a node or a member's use of `d` asserts a format a check judges, which an unknown one, refused under the
// format-assertion vocabulary, does not make.
@(private = "file")
asserts :: proc(d: ^rules.Description) -> bool {
	for n in d.nodes {
		if n.rules.assert_format && rules.format_of(n.rules.format) != .None {
			return true
		}
	}
	for o in d.objects {
		for m in o.members {
			if m.rules.assert_format && rules.format_of(m.rules.format) != .None {
				return true
			}
		}
	}
	return false
}

@(private = "file")
Writer :: struct {
	t:       write.Tokens,
	d:       ^rules.Description,
	uses:    []u8, // per node, 0 unseen, 1 once, 2 twice or more or by a `$ref`
	refs:    []string, // per node reached twice, the reference to it
	keyword: string, // the keyword being written, which stops at the first refusal
	refused: string, // the first keyword the description holds that no schema spells
	anchored: bool, // a written node has a `$dynamicRef`, so every resource has an `$id` and every reference is absolute
}

// Whether a `$dynamicRef` of a written node names the dynamic anchor `name`.
@(private = "file")
dynamic_reached :: proc(w: ^Writer, name: string) -> bool {
	for u, j in w.uses {
		target, has := w.d.nodes[j].dynamic_ref.?
		if u == 0 || !has {
			continue
		}
		for x in w.d.anchors {
			if x.node == target && x.name == name {
				return true
			}
		}
	}
	return false
}

// Counts how each node is reached. A node's children are counted once.
@(private = "file")
count :: proc(w: ^Writer, i: rules.Node_Index, by_ref: bool) {
	if i == rules.NONE {
		return
	}
	seen := w.uses[i] > 0
	// A false schema is written in place wherever it is used, so only a `$ref` to it needs it defined.
	shared := by_ref || seen && w.d.nodes[i].kinds != {}
	w.uses[i] = 2 if shared || w.uses[i] == 2 else 1
	if seen {
		return
	}
	n := &w.d.nodes[i]
	count(w, n.dynamic_ref.? or_else rules.NONE, true)
	if n.integer_spelled {
		refuse(w, "integer")
	}
	for list in ([?][]rules.Node_Index{n.any_of, n.all_of, n.one_of}) {
		for c in list {
			count(w, c, false)
		}
	}
	for c in ([?]Maybe(rules.Node_Index){n.not, n.cond.test, n.cond.then, n.cond.other, n.unevaluated_items, n.unevaluated_properties}) {
		count(w, c.? or_else rules.NONE, false)
	}
	count(w, n.ref.? or_else rules.NONE, true)
	if n.array >= 0 {
		a := w.d.arrays[n.array]
		for c in a.prefix {
			count(w, c, false)
		}
		count(w, a.items, false)
		count(w, a.contains.? or_else rules.NONE, false)
	}
	if n.object >= 0 {
		o := w.d.objects[n.object]
		for m in o.members {
			count(w, m.node, false)
		}
		for p in o.patterns {
			count(w, p.node, false)
		}
		for x in o.dependents {
			count(w, x.node.? or_else rules.NONE, false)
		}
		count(w, o.additional, false)
		count(w, o.keys, false)
	}
}

@(private = "file")
DEFS :: "#/$defs/"

// Gives each node reached twice its reference: its name in the description when that is plain and unused, else
// `n<index>`.
@(private = "file")
name_defs :: proc(w: ^Writer, allocator: runtime.Allocator) {
	taken := make(map[string]bool, context.temp_allocator)
	for u, j in w.uses {
		if u != 2 {
			continue
		}
		name := w.d.names[rules.Node_Index(j)] or_else ""
		if name == "" || taken[name] || !plain_name(name) {
			name = strings.concatenate({"n", int_text(j)}, context.temp_allocator)
			for taken[name] {
				name = strings.concatenate({name, "_"}, context.temp_allocator)
			}
		}
		taken[name] = true
		w.refs[j] = strings.concatenate({DEFS, name}, allocator)
	}
}

// Whether `name` needs no escape in a JSON Pointer or a URI fragment.
@(private = "file")
plain_name :: proc(name: string) -> bool {
	for c in transmute([]u8)name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-' || c == '.') {
			return false
		}
	}
	return true
}

// The text of a reference to node `i`. A node of a description with dynamic anchors is reached through the `$id` of its
// resource, since the base of a reference is the resource it is in.
@(private = "file")
ref_to :: proc(w: ^Writer, i: rules.Node_Index) -> string {
	if !w.anchored {
		return "#" if i == w.d.root else w.refs[i]
	}
	if w.d.nodes[i].resource == i {
		return id_of(i)
	}
	return strings.concatenate({id_of(w.d.nodes[i].resource), w.refs[i]}, context.temp_allocator)
}

// A 2019-09 recursive anchor is named `$recursive`, which an anchor of 2020-12 cannot be.
@(private = "file")
anchor_name :: proc(name: string) -> string {
	return strings.concatenate({"_", name[1:]}, context.temp_allocator) if strings.has_prefix(name, "$") else name
}

@(private = "file")
id_of :: proc(resource: rules.Node_Index) -> string {
	return strings.concatenate({"https://schema.invalid/r", int_text(int(resource))}, context.temp_allocator)
}

// The node that holds the definition of node `j`: the root, or in a description with dynamic anchors the root of the
// resource of `j`, since a reference by name stays in the resource it is read in. A resource root is a definition of the
// root.
@(private = "file")
home_of :: proc(w: ^Writer, j: rules.Node_Index) -> rules.Node_Index {
	if !w.anchored || w.d.nodes[j].resource == j {
		return w.d.root
	}
	return w.d.nodes[j].resource
}

// The `$defs` of `owner`: the nodes reached twice that it holds.
@(private = "file")
put_defs :: proc(w: ^Writer, owner: rules.Node_Index) {
	opened := false
	for u, j in w.uses {
		at := rules.Node_Index(j)
		if u != 2 || at == owner || at == w.d.root || home_of(w, at) != owner {
			continue
		}
		if !opened {
			key(w, "$defs")
			write.open_object(&w.t)
			opened = true
		}
		write.key(&w.t, w.refs[j][len(DEFS):])
		node(w, at, {})
	}
	if opened {
		write.close(&w.t)
	}
}

// A schema for node `i`: a reference when the node is shared, with the rules `extra` that a use adds beside it, else
// its body with them merged in.
@(private = "file")
schema :: proc(w: ^Writer, i: rules.Node_Index, extra := rules.Rules{}) {
	switch {
	case w.d.nodes[i].kinds == {}:
		write.value_bool(&w.t, false)
	case w.uses[i] == 2:
		write.open_object(&w.t)
		put(w, "$ref", ref_to(w, i))
		put_nodes(w, "allOf", nil, put_rules(w, extra))
		write.close(&w.t)
	case:
		node(w, i, extra)
	}
}

@(private = "file")
node :: proc(w: ^Writer, i: rules.Node_Index, extra: rules.Rules) {
	n := &w.d.nodes[i]
	if n.kinds == {} {
		write.value_bool(&w.t, false)
		return
	}
	write.open_object(&w.t)
	rl, clash := rules.merged(n, extra)
	if clash == "" && n.rules.assert_format && extra.assert_format && n.rules.format != extra.format {
		clash = "format"
	}
	if clash != "" {
		refuse(w, clash)
	}
	body(w, i, n, rl)
	if w.anchored && n.resource == i {
		put_defs(w, i)
	}
	write.close(&w.t)
}

// The keywords of `n` with its rules `rl`, in the open object.
@(private = "file")
body :: proc(w: ^Writer, i: rules.Node_Index, n: ^rules.Node, rl: rules.Rules) {
	if w.anchored {
		if n.resource == i {
			put(w, "$id", id_of(i))
		}
		for x in w.d.anchors {
			if x.node == i {
				put(w, "$dynamicAnchor", anchor_name(x.name))
			}
		}
	}
	if n.kinds != rules.EVERY_KIND {
		key(w, "type")
		many := card(n.kinds) > 1
		if many {
			write.open_array(&w.t)
		}
		for t in TYPE_KINDS {
			if t.kinds <= n.kinds {
				write.value_string(&w.t, t.name)
			}
		}
		if many {
			write.close(&w.t)
		}
	}
	if n.title != "" {
		put(w, "title", n.title)
	}
	if n.description != "" {
		put(w, "description", n.description)
	}
	if v, ok := n.default_of.?; ok {
		key(w, "default")
		write.value_of(&w.t, v)
	}
	if len(n.examples) > 0 {
		key(w, "examples")
		write.open_array(&w.t)
		for v in n.examples {
			write.value_of(&w.t, v)
		}
		write.close(&w.t)
	}
	if n.deprecated {
		key(w, "deprecated")
		write.value_bool(&w.t, true)
	}
	if n.content_encoding != "" {
		put(w, "contentEncoding", n.content_encoding)
	}
	if n.content_media_type != "" {
		put(w, "contentMediaType", n.content_media_type)
	}
	if ref, ok := n.ref.?; ok {
		put(w, "$ref", ref_to(w, ref))
	}
	if target, ok := n.dynamic_ref.?; ok {
		for x in w.d.anchors {
			if x.node == target {
				put(w, "$dynamicRef", strings.concatenate({id_of(x.resource), "#", anchor_name(x.name)}, context.temp_allocator))
				break
			}
		}
	}
	if n.has_enum {
		key(w, "enum")
		write.open_array(&w.t)
		for v in n.enum_of {
			write.value_of(&w.t, v)
		}
		write.close(&w.t)
	}
	if v, ok := n.const_of.?; ok {
		key(w, "const")
		write.value_of(&w.t, v)
	}
	put_nodes(w, "allOf", n.all_of, put_rules(w, rl))
	put_nodes(w, "anyOf", n.any_of)
	put_nodes(w, "oneOf", n.one_of)
	put_node(w, "not", n.not)
	put_node(w, "if", n.cond.test)
	put_node(w, "then", n.cond.then)
	put_node(w, "else", n.cond.other)
	put_node(w, "unevaluatedItems", n.unevaluated_items)
	put_node(w, "unevaluatedProperties", n.unevaluated_properties)
	if n.array >= 0 {
		put_array(w, w.d.arrays[n.array])
	}
	if n.object >= 0 {
		put_object(w, w.d.objects[n.object])
	}
}

// The nodes of `list` under `name`, then a node of `pattern` alone when it is not "".
@(private = "file")
put_nodes :: proc(w: ^Writer, name: string, list: []rules.Node_Index, pattern := "") {
	if len(list) > 0 || pattern != "" {
		key(w, name)
		write.open_array(&w.t)
		for c in list {
			schema(w, c)
		}
		if pattern != "" {
			write.open_object(&w.t)
			put(w, "pattern", pattern)
			write.close(&w.t)
		}
		write.close(&w.t)
	}
}

@(private = "file")
put_node :: proc(w: ^Writer, name: string, c: Maybe(rules.Node_Index)) {
	if c, ok := c.?; ok {
		key(w, name)
		schema(w, c)
	}
}

@(private = "file", rodata)
BOUND_KEYS := [?]string{"minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"}

@(private, rodata)
MIN_KEYS := [?]string{"minLength", "minItems", "minProperties"}

@(private, rodata)
MAX_KEYS := [?]string{"maxLength", "maxItems", "maxProperties"}

// Writes `rl`, and answers the pattern of its asserted format when `rl` has a pattern of its own, for an `allOf`.
@(private = "file")
put_rules :: proc(w: ^Writer, rl: rules.Rules) -> (format_pattern: string) {
	for text, j in ([?]string{rl.minimum, rl.maximum}) {
		if text != "" {
			exclusive := rl.exclusive_minimum if j == 0 else rl.exclusive_maximum
			put_number(w, BOUND_KEYS[j + 2 * int(exclusive)], text)
		}
	}
	if rl.multiple_of != "" {
		put_number(w, "multipleOf", rl.multiple_of)
	}
	for count, j in ([?]u64{rl.min_length, rl.min_items, rl.min_members}) {
		if count > 0 {
			put_count(w, MIN_KEYS[j], count)
		}
	}
	for count, j in ([?]Maybe(u64){rl.max_length, rl.max_items, rl.max_members}) {
		if count, ok := count.?; ok {
			put_count(w, MAX_KEYS[j], count)
		}
	}
	spelled := rules.FORMAT_PATTERNS[rules.format_of(rl.format)] if rl.assert_format else ""
	if rl.pattern != "" || spelled != "" {
		put(w, "pattern", rl.pattern if rl.pattern != "" else spelled)
	}
	if rl.format != "" {
		put(w, "format", rl.format)
	}
	flags := [?]struct {
		set:  bool,
		name: string,
	}{{rl.unique, "uniqueItems"}, {rl.read_only, "readOnly"}, {rl.write_only, "writeOnly"}}
	for flag in flags {
		if flag.set {
			key(w, flag.name)
			write.value_bool(&w.t, true)
		}
	}
	if rl.markup != .Any {
		key(w, "xml")
		write.open_object(&w.t)
		put(w, "nodeType", NODE_TYPES[rl.markup])
		write.close(&w.t)
	}
	return spelled if rl.pattern != "" && spelled != rl.pattern else ""
}

@(private = "file", rodata)
NODE_TYPES := [rules.Markup_Node]string{.Any = "", .Attribute = "attribute", .Element = "element", .Text = "text"}

@(private = "file")
put_array :: proc(w: ^Writer, a: rules.Array) {
	put_nodes(w, "prefixItems", a.prefix)
	if a.items != rules.NONE {
		key(w, "items")
		schema(w, a.items)
	}
	if c, has := a.contains.?; has {
		key(w, "contains")
		schema(w, c)
		if count, ok := a.min_contains.?; ok {
			put_count(w, "minContains", count)
		}
		if count, ok := a.max_contains.?; ok {
			put_count(w, "maxContains", count)
		}
	}
}

@(private = "file")
put_object :: proc(w: ^Writer, o: rules.Object) {
	listed, required := false, false
	for m in o.members {
		listed ||= !m.only_required
		required ||= m.required
	}
	if listed {
		key(w, "properties")
		write.open_object(&w.t)
		for m in o.members {
			if !m.only_required {
				write.key(&w.t, m.name)
				schema(w, m.node, m.rules)
			}
		}
		write.close(&w.t)
	}
	if required {
		key(w, "required")
		write.open_array(&w.t)
		for m in o.members {
			if m.required {
				write.value_string(&w.t, m.name)
			}
		}
		write.close(&w.t)
	}
	if len(o.patterns) > 0 {
		key(w, "patternProperties")
		write.open_object(&w.t)
		for p in o.patterns {
			write.key(&w.t, p.expression)
			schema(w, p.node)
		}
		write.close(&w.t)
	}
	if o.additional != rules.NONE {
		key(w, "additionalProperties")
		schema(w, o.additional)
	}
	if o.keys != rules.NONE {
		key(w, "propertyNames")
		schema(w, o.keys)
	}
	for pass, j in ([?]string{"dependentRequired", "dependentSchemas"}) {
		started := false
		for x in o.dependents {
			if (x.node == nil) != (j == 0) {
				continue
			}
			if !started {
				key(w, pass)
				write.open_object(&w.t)
				started = true
			}
			write.key(&w.t, x.name)
			if node, ok := x.node.?; ok {
				schema(w, node)
			} else {
				write.open_array(&w.t)
				for name in x.required {
					write.value_string(&w.t, name)
				}
				write.close(&w.t)
			}
		}
		if started {
			write.close(&w.t)
		}
	}
}

@(private = "file")
key :: proc(w: ^Writer, name: string) {
	if w.t.err == .None {
		w.keyword = name
	}
	write.key(&w.t, name)
}

@(private = "file")
refuse :: proc(w: ^Writer, keyword: string) {
	if w.refused == "" {
		w.refused = keyword
	}
}

// A number by its decimal value: the text as it stands when JSON spells it, else the digits and exponent of its value.
// Another format's `+1`, `.5`, `5.` and hex are written as JSON, and a number that is not finite is refused.
@(private = "file")
put_number :: proc(w: ^Writer, name, text: string) {
	key(w, name)
	if _, _, _, strict := spell.number_shape_strict(transmute([]u8)text, 0, u64(len(text))); strict {
		write.value_of(&w.t, &core.Number_Text{text = text})
		return
	}
	spelled: string
	if strings.contains_any(text, "xX") {
		n, ok := strconv.parse_i64_maybe_prefixed(text)
		if !ok {
			refuse(w, name)
			return
		}
		spelled = int_text(int(n))
	} else if d := spell.decimal_of(text); strings.trim_left(text, "0123456789+-.eE") != "" {
		refuse(w, name)
		return
	} else if d.head == "" {
		spelled = "0"
	} else {
		digits := strings.concatenate({d.head, d.tail}, context.temp_allocator)
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "-" if d.neg else "")
		strings.write_string(&b, digits)
		strings.write_byte(&b, 'e')
		spell.write_point(&b, d, -i128(len(digits)))
		spelled = strings.to_string(b)
	}
	write.value_of(&w.t, &core.Number_Text{text = spelled})
}

@(private)
int_text :: proc(n: int) -> string {
	return string(strconv.write_int(make([]u8, 24, context.temp_allocator), i64(n), 10))
}

@(private = "file")
put :: proc(w: ^Writer, name, text: string) {
	key(w, name)
	write.value_string(&w.t, text)
}

@(private = "file")
put_count :: proc(w: ^Writer, name: string, n: u64) {
	key(w, name)
	write.value_uint(&w.t, n)
}
