package jq

// The rule actions of jq's parser.y, numbered as its rules, and the node builders they fold constants with. `v[k]` and
// `l[k]` are `$k` and `@k`, `at` is `@$`. Every node is made through `mk`, which records it in the unit's order.

import "core:fmt"
import "core:strings"
import "stury:lib/base/kernel"
import "stury:lib/query"

@(private)
act :: proc(p: ^Parser, rule: int, v: []Sem, l: []Loc, at: Loc) -> (r: Sem) {
	if len(v) > 1 {
		r = v[1]
	}
	switch rule {
	case 2:
		p.prog = {body = v[3].node, meta = v[1].value, deps = dep_values(v[2].nodes[:])}
	case 3:
		p.prog = {defs = v[3].node, meta = v[1].value, deps = dep_values(v[2].nodes[:])}
	case 4, 6, 8, 54, 59, 153:
		r = {}
	case 5:
		r = {}
		if !meta_error(p, v[2].node, l[2]) {
			r.value = v[2].node.value
		}
	case 7:
		append(&r.nodes, ..v[2].nodes[:])
	case 9, 10:
		r = {node = mk(p, Node{kind = .Def, a = v[2].node, fn = v[1].fn, loc = at})}
	case 11:
		pats := v[3].pats[:]
		keys := pattern_keys(pats)
		r = {node = mk(p, Node{kind = .Bind, a = v[1].node, b = v[5].node, patterns = pats, keys = keys, loc = at})}
	case 12:
		r = {node = mk(p, Node{kind = .Label, a = v[4].node, name = v[2].text, loc = at})}
	case 13:
		r = {node = node(p, .Pipe, v[1].node, v[3].node, at = at)}
	case 14:
		r = {node = node(p, .Comma, v[1].node, v[3].node, at = at)}
	case 16:
		r = {node = node(p, .Alt, v[1].node, v[3].node, at = at)}
	case 17, 20, 21, 23, 25, 27, 30, 31:
		r = {node = mk(p, Node{kind = .Update, a = v[1].node, b = v[3].node, op = UPDATE_OPS[rule], loc = at})}
	case 18:
		r = {node = node(p, .Or, v[1].node, v[3].node, at = at)}
	case 19:
		r = {node = node(p, .And, v[1].node, v[3].node, at = at)}
	case 22, 24, 26, 28, 29, 32, 33, 34, 35, 36, 37:
		r = {node = binop(p, BINARY_OPS[rule], v[1].node, v[3].node, at)}
	case 39:
		r = {nodes = list(literal(p, v[1].value, at))}
	case 40:
		r = {}
		if !meta_error(p, v[2].node, l[2]) {
			// The metadata's members, then the directive's own over them.
			append(&r.nodes, literal(p, merge_constants(p, v[2].node.value, v[1].value), at))
		}
	case 41, 42, 43:
		// `import PATH as $NAME`, `import PATH as NAME`, `include PATH`.
		dep := constant_object(p)
		if rule != 43 {
			put_constant(p, &dep, "as", query.text_borrowed(v[4].text))
		}
		put_constant(p, &dep, "is_data", query.bool_value(rule == 41))
		put_constant(p, &dep, "relpath", query.text_borrowed(v[2].text))
		r = {value = freeze(p, dep)}
	case 44:
		r = {}
		if s, ok := literal_string(v[1].node); ok {
			r.text = s
		} else {
			report(p, l[1], "Import path must be constant")
		}
	case 45:
		r = {fn = new_clone(Func{name = v[2].text, body = v[4].node, loc = at})}
	case 46:
		r = {fn = new_clone(Func{name = v[2].text, params = v[4].names[:], body = v[7].node, loc = at})}
	case 47:
		r = {names = list(v[1].text)}
	case 48:
		append(&r.names, v[3].text)
	case 49:
		r = {text = strings.concatenate({"$", v[1].text})}
	case 51:
		r = {text = v[1].text}
	case 52:
		r = {text = "text"}
	case 53:
		r = {node = string_node(p, v[2].nodes[:], at)}
	case 55:
		if v[2].value.kind == .String {
			text := query.text_of(v[2].value)
			parts := len(r.nodes)
			if parts > 0 && r.nodes[parts - 1].kind == .Literal {
				joined := strings.concatenate({query.text_of(r.nodes[parts - 1].value), text})
				r.nodes[parts - 1] = literal(p, query.text_borrowed(joined), at)
			} else {
				append(&r.nodes, literal(p, v[2].value, l[2]))
			}
		}
	case 56:
		append(&r.nodes, mk(p, Node{kind = .Format, a = v[3].node, name = v[0].text, loc = l[3]}))
	case 57, 100:
		r = {node = node(p, .If, v[2].node, v[4].node, v[5].node, at = at)}
	case 58, 93:
		r = v[2]
	case 60, 110, 111, 113:
		r = {node = node(p, .Identity, at = at)}
	case 61:
		r = {node = mk(p, Node{kind = .Call, name = "recurse", loc = at})}
	case 62:
		r = {node = mk(p, Node{kind = .Break, name = v[2].text, loc = at})}
	case 63:
		report(p, at, "break requires a label to break to")
		r = {node = node(p, .Identity, at = at)}
	case 64:
		r = {node = field(p, v[1].node, v[2].text, l[2], true, at)}
	case 65:
		r = {node = field(p, node(p, .Identity, at = at), v[1].text, l[1], true, at)}
	case 66:
		r = {node = index(p, v[1].node, v[3].node, true, at)}
	case 67:
		r = {node = index(p, node(p, .Identity, at = at), v[2].node, true, at)}
	case 68:
		r = {node = field(p, v[1].node, v[2].text, l[2], false, at)}
	case 69:
		r = {node = field(p, node(p, .Identity, at = at), v[1].text, l[1], false, at)}
	case 70:
		r = {node = index(p, v[1].node, v[3].node, false, at)}
	case 71:
		r = {node = index(p, node(p, .Identity, at = at), v[2].node, false, at)}
	case 72, 73:
		report(p, at, `try .["field"] instead of .field for unusually named fields`)
		r = {node = node(p, .Identity, at = at)}
	case 74, 75:
		r = {node = index(p, v[1].node, v[3].node, rule == 74, at)}
	case 76, 77:
		r = {node = index(p, v[1].node, v[4].node, rule == 76, at)}
	case 78, 79, 80, 81:
		r = {node = mk(p, Node{kind = .Iterate, a = v[1].node, flags = opt_flag(rule == 78 || rule == 80), loc = at})}
	case 82, 85:
		r = {node = mk(p, Node{kind = .Slice, a = v[1].node, b = v[3].node, c = v[5].node, flags = opt_flag(rule == 82), loc = at})}
	case 83, 86:
		r = {node = mk(p, Node{kind = .Slice, a = v[1].node, b = v[3].node, flags = opt_flag(rule == 83), loc = at})}
	case 84, 87:
		r = {node = mk(p, Node{kind = .Slice, a = v[1].node, c = v[4].node, flags = opt_flag(rule == 84), loc = at})}
	case 88:
		r = {node = node(p, .Try, v[1].node, at = at)}
	case 89:
		r = {node = literal(p, v[1].value, at)}
	case 91:
		r = {node = mk(p, Node{kind = .Format, name = v[1].text, loc = at})}
	case 92:
		r = {node = node(p, .Neg, v[2].node, at = at)}
	case 94:
		r = {node = array_node(p, v[2].node, at)}
	case 95:
		r = {node = literal(p, freeze(p, empty_array(p)), at)}
	case 96:
		r = {node = object_node(p, v[2].nodes[:], at)}
	case 97:
		r = {node = mk(p, Node{kind = .Reduce, a = v[2].node, b = v[6].node, c = v[8].node, patterns = v[4].pats[:], keys = pattern_keys(v[4].pats[:]), loc = at})}
	case 98, 99:
		r = {node = mk(p, Node{kind = .Foreach, a = v[2].node, b = v[6].node, c = v[8].node, d = v[10].node if rule == 98 else nil, patterns = v[4].pats[:], keys = pattern_keys(v[4].pats[:]), loc = at})}
	case 101:
		report(p, at, "Possibly unterminated 'if' statement")
		r = v[2]
	case 102:
		r = {node = node(p, .Try, v[2].node, v[4].node, at = at)}
	case 103:
		report(p, at, "Possibly unterminated 'try' statement")
		r = v[2]
	case 104:
		r = {node = node(p, .Try, v[2].node, at = at)}
	case 105:
		r = {node = var_node(p, v[4].text, at)}
	case 106:
		r = {node = var_node(p, v[1].text, at)}
	case 107:
		r = {node = loc_literal(p, at)}
	case 108:
		switch v[1].text {
		case "true", "false":
			r = {node = literal(p, query.bool_value(v[1].text == "true"), at)}
		case "null":
			r = {node = literal(p, query.NULL, at)}
		case:
			r = {node = mk(p, Node{kind = .Call, name = v[1].text, loc = at})}
		}
	case 109:
		r = {node = mk(p, Node{kind = .Call, name = v[1].text, args = v[3].nodes[:], loc = l[1]})}
	case 114:
		r = {nodes = list(v[1].node)}
	case 115:
		append(&r.nodes, v[3].node)
	case 117, 119, 125:
		append(&r.pats, v[3].pat)
	case 118, 120, 124:
		r = {pats = list(v[1].pat)}
	case 121:
		r = {pat = new_clone(Pattern{kind = .Var, name = v[1].text})}
	case 122:
		r = {pat = new_clone(Pattern{kind = .Array, elems = v[2].pats[:]})}
	case 123:
		r = {pat = new_clone(Pattern{kind = .Object, members = v[2].members[:]})}
	case 127:
		append(&r.members, ..v[3].members[:])
	case 128:
		r = {members = list(Pattern_Member{key = literal(p, query.text_borrowed(v[1].text), l[1]), var = v[1].text})}
	case 129:
		r = {members = list(Pattern_Member{key = literal(p, query.text_borrowed(v[1].text), l[1]), var = v[1].text, pattern = v[3].pat})}
	case 130, 131:
		r = {members = list(Pattern_Member{key = literal(p, query.text_borrowed(v[1].text), l[1]), pattern = v[3].pat})}
	case 132:
		r = {members = list(Pattern_Member{key = v[1].node, pattern = v[3].pat})}
	case 133:
		check_object_key(p, v[2].node, l[2])
		r = {members = list(Pattern_Member{key = v[2].node, pattern = v[5].pat})}
	case 134:
		report(p, at, "May need parentheses around object key expression")
		r = {}
	case 155:
		append(&r.nodes, ..v[3].nodes[:])
	case 156, 157:
		r = {nodes = list(literal(p, query.text_borrowed(v[1].text), l[1]), v[3].node)}
	case 158:
		r = {nodes = list(v[1].node, v[3].node)}
	case 159:
		// `{"text"}`: the member of the input that the text names.
		if v[1].node.kind == .Literal {
			r = {nodes = list(v[1].node, index(p, node(p, .Identity, at = at), v[1].node, false, at))}
		} else {
			r = {nodes = list(v[1].node, (^Node)(nil))}
		}
	case 160:
		r = {nodes = list(var_node(p, v[1].text, at), v[3].node)}
	case 161:
		r = {nodes = list(literal(p, query.text_borrowed(v[1].text), l[1]), var_node(p, v[1].text, at))}
	case 162, 164:
		r = {nodes = list(literal(p, query.text_borrowed(v[1].text), l[1]), index(p, node(p, .Identity, at = at), literal(p, query.text_borrowed(v[1].text), l[1]), false, at))}
	case 163:
		r = {nodes = list(literal(p, query.text_borrowed("__loc__"), at), loc_literal(p, at))}
	case 165:
		check_object_key(p, v[2].node, l[2])
		r = {nodes = list(v[2].node, v[5].node)}
	case 166:
		report(p, l[1], "May need parentheses around object key expression")
		r = {}
	case 167:
		r = {node = node(p, .Pipe, v[1].node, v[3].node, at = at)}
	}
	return
}

@(private = "file", rodata)
UPDATE_OPS := [32]Op {
	17 = .Assign,
	20 = .Alt,
	21 = .Modify,
	23 = .Add,
	25 = .Sub,
	27 = .Mul,
	30 = .Div,
	31 = .Mod,
}

@(private = "file", rodata)
BINARY_OPS := [38]Op {
	22 = .Add,
	24 = .Sub,
	26 = .Mul,
	28 = .Div,
	29 = .Mod,
	32 = .Eq,
	33 = .Ne,
	34 = .Lt,
	35 = .Gt,
	36 = .Le,
	37 = .Ge,
}

@(private = "file")
list :: proc(first: $T, rest: ..T) -> [dynamic]T {
	l := make([dynamic]T, 0, 1 + len(rest))
	append(&l, first)
	append(&l, ..rest)
	return l
}

// A node, recorded in the unit's order, after its children.
@(private)
mk :: proc(p: ^Parser, n: Node) -> ^Node {
	x := new_clone(n)
	append(&p.unit.order, x)
	return x
}

@(private = "file")
node :: proc(p: ^Parser, kind: Node_Kind, a: ^Node = nil, b: ^Node = nil, c: ^Node = nil, at := Loc{}) -> ^Node {
	return mk(p, Node{kind = kind, a = a, b = b, c = c, loc = at})
}

@(private = "file")
literal :: proc(p: ^Parser, v: query.Value, at: Loc) -> ^Node {
	return mk(p, Node{kind = .Literal, value = v, loc = at})
}

@(private = "file")
var_node :: proc(p: ^Parser, name: string, at: Loc) -> ^Node {
	return mk(p, Node{kind = .Var, name = name, loc = at})
}

@(private = "file")
is_literal :: proc(n: ^Node) -> bool {
	return n != nil && n.kind == .Literal
}

@(private = "file")
literal_string :: proc(n: ^Node) -> (string, bool) {
	if !is_literal(n) || n.value.kind != .String {
		return "", false
	}
	return query.text_of(n.value), true
}

// `target[key]`. A constant string key is a field.
@(private = "file")
index :: proc(p: ^Parser, target, key: ^Node, opt: bool, at: Loc) -> ^Node {
	flags := Node_Flags{.Opt} if opt else {}
	if name, ok := literal_string(key); ok {
		return mk(p, Node{kind = .Field, a = target, name = name, value = key.value, flags = flags, loc = at})
	}
	return mk(p, Node{kind = .Index, a = target, b = key, flags = flags, loc = at})
}

// `target.name`.
@(private = "file")
field :: proc(p: ^Parser, target: ^Node, name: string, name_at: Loc, opt: bool, at: Loc) -> ^Node {
	return index(p, target, literal(p, query.text_borrowed(name), name_at), opt, at)
}

// `a op b`, computed now when both are constants and the operation succeeds (jq's constant_fold).
@(private = "file")
binop :: proc(p: ^Parser, op: Op, a, b: ^Node, at: Loc) -> ^Node {
	if is_literal(a) && is_literal(b) {
		h := &p.unit.heap
		if v, s := binary_value(h, op, a.value, b.value); s == .Ok {
			return literal(p, freeze(p, v), at)
		}
		query.clear_error(h)
	}
	return mk(p, Node{kind = .Binary, op = op, a = a, b = b, loc = at})
}

// A string literal: its text parts and its interpolations, or a constant when it interpolates nothing.
@(private = "file")
string_node :: proc(p: ^Parser, parts: []^Node, at: Loc) -> ^Node {
	switch {
	case len(parts) == 0:
		return literal(p, query.text_borrowed(""), at)
	case len(parts) == 1 && parts[0].kind == .Literal:
		return literal(p, parts[0].value, at)
	}
	return mk(p, Node{kind = .String, args = parts, loc = at})
}

// `[q]`: a constant when `q` is constants joined by `,` from the left (jq's gen_const_array).
@(private = "file")
array_node :: proc(p: ^Parser, q: ^Node, at: Loc) -> ^Node {
	// `a, b, c` is `(a, b), c`: its last element is the right side of the outermost comma.
	n := 0
	for k := q; ; k = k.a {
		if is_literal(k) {
			n += 1
			break
		}
		if k.kind != .Comma || !is_literal(k.b) {
			return node(p, .Array, q, at = at)
		}
		n += 1
	}
	a := query.make_array(&p.unit.heap, n) or_else query.NULL
	items := make([]query.Value, n)
	k := q
	for i := n - 1; i >= 0; i -= 1 {
		if k.kind == .Comma {
			items[i] = k.b.value
			k = k.a
		} else {
			items[i] = k.value
		}
	}
	for x in items {
		_ = query.append_owned(&p.unit.heap, &a, x)
	}
	return literal(p, freeze(p, a), at)
}

// `{...}`, its keys and values in turn: a constant when every key is a constant string and every value a constant
// (gen_const_object).
@(private = "file")
object_node :: proc(p: ^Parser, entries: []^Node, at: Loc) -> ^Node {
	for i := 0; i < len(entries); i += 2 {
		if _, ok := literal_string(entries[i]); !ok || !is_literal(entries[i + 1]) {
			return mk(p, Node{kind = .Object, args = entries, loc = at})
		}
	}
	o := constant_object(p)
	for i := 0; i < len(entries); i += 2 {
		k, _ := literal_string(entries[i])
		put_constant(p, &o, k, entries[i + 1].value)
	}
	return literal(p, freeze(p, o), at)
}

// `$__loc__`: the file and the line it is on.
@(private = "file")
loc_literal :: proc(p: ^Parser, at: Loc) -> ^Node {
	o := constant_object(p)
	put_constant(p, &o, "file", query.text_borrowed(p.file if p.file != "" else "<top-level>"))
	put_constant(p, &o, "line", query.int_value(i64(kernel.count_byte(transmute([]u8)p.src[:at.start], '\n') + 1)))
	return literal(p, freeze(p, o), at)
}

@(private = "file")
check_object_key :: proc(p: ^Parser, key: ^Node, at: Loc) {
	if is_literal(key) && query.type_of(key.value) != .String {
		report(p, at, fmt.aprintf("Cannot use %s (%s) as object key", type_name(key.value), brief(&p.unit.heap, key.value)))
	}
}

// Whether module metadata is not a constant object, which is reported.
@(private = "file")
meta_error :: proc(p: ^Parser, meta: ^Node, at: Loc) -> bool {
	switch {
	case !is_literal(meta):
		report(p, at, "Module metadata must be constant")
	case query.type_of(meta.value) != .Object:
		report(p, at, "Module metadata must be an object")
	case:
		return false
	}
	return true
}

@(private = "file")
dep_values :: proc(nodes: []^Node) -> []query.Value {
	if len(nodes) == 0 {
		return nil
	}
	deps := make([]query.Value, len(nodes))
	for n, i in nodes {
		deps[i] = n.value
	}
	return deps
}

// The key expressions of patterns `pats`, in the order the binding evaluates them, with no recursion.
@(private = "file")
pattern_keys :: proc(pats: []^Pattern) -> []^Node {
	keys: [dynamic]^Node
	stack: [dynamic]^Pattern
	#reverse for x in pats {
		append(&stack, x)
	}
	for len(stack) > 0 {
		x := pop(&stack)
		switch x.kind {
		case .Var:
		case .Array:
			#reverse for e in x.elems {
				append(&stack, e)
			}
		case .Object:
			// Each member's key before the members after it: keys are taken in order, nested patterns after them.
			for m in x.members {
				append(&keys, m.key)
			}
			#reverse for m in x.members {
				if m.pattern != nil {
					append(&stack, m.pattern)
				}
			}
		}
	}
	return keys[:]
}

@(private = "file")
constant_object :: proc(p: ^Parser) -> query.Value {
	return query.make_object(&p.unit.heap, 4) or_else query.NULL
}

@(private = "file")
empty_array :: proc(p: ^Parser) -> query.Value {
	return query.make_array(&p.unit.heap, 0) or_else query.NULL
}

@(private = "file")
put_constant :: proc(p: ^Parser, o: ^query.Value, key: string, v: query.Value) {
	_ = query.object_put(&p.unit.heap, o, query.text_borrowed(key), query.retain(v))
}

// Object `meta` with the members of object `over` set over it.
@(private = "file")
merge_constants :: proc(p: ^Parser, meta, over: query.Value) -> query.Value {
	o := query.make_object(&p.unit.heap, 4) or_else query.NULL
	for e in query.entries_of(meta) {
		put_constant(p, &o, query.text_of(e.key), e.value)
	}
	if over.kind == .Object {
		for e in query.entries_of(over) {
			put_constant(p, &o, query.text_of(e.key), e.value)
		}
	}
	return freeze(p, o)
}

// `v`, made in the unit's heap, as a constant the program holds: no run counts references on it.
@(private)
freeze :: proc(p: ^Parser, v: query.Value) -> query.Value {
	return query.freeze(v)
}

@(private = "file")
opt_flag :: #force_inline proc(opt: bool) -> Node_Flags {
	return {.Opt} if opt else {}
}
