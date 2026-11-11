package jq

// The rule actions of jq's parser.y, numbered as its rules, and the node builders they fold constants
// with. `v[k]` and `l[k]` are `$k` and `@k`, `at` is `@$`.

import "core:strings"
import "../message"

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
		r = {node = new_clone(Node{kind = .Def, a = v[2].node, fn = v[1].fn, loc = at})}
	case 11:
		r = {node = new_clone(Node{kind = .Bind, a = v[1].node, b = v[5].node, patterns = v[3].pats[:], loc = at})}
	case 12:
		r = {node = new_clone(Node{kind = .Label, a = v[4].node, name = v[2].text, loc = at})}
	case 13:
		r = {node = node(.Pipe, v[1].node, v[3].node, at = at)}
	case 14:
		r = {node = node(.Comma, v[1].node, v[3].node, at = at)}
	case 16:
		r = {node = node(.Alt, v[1].node, v[3].node, at = at)}
	case 17, 20, 21, 23, 25, 27, 30, 31:
		r = {node = new_clone(Node{kind = .Update, a = v[1].node, b = v[3].node, op = UPDATE_OPS[rule], loc = at})}
	case 18:
		r = {node = node(.Or, v[1].node, v[3].node, at = at)}
	case 19:
		r = {node = node(.And, v[1].node, v[3].node, at = at)}
	case 22, 24, 26, 28, 29, 32, 33, 34, 35, 36, 37:
		r = {node = binop(p, BINARY_OPS[rule], v[1].node, v[3].node, at)}
	case 39:
		r = {nodes = list(literal(v[1].value, at))}
	case 40:
		r = {}
		if !meta_error(p, v[2].node, l[2]) {
			// The metadata's members, then the directive's own over them.
			meta := own(v[2].node.value).(^Object)
			it := iterate(v[1].value)
			for k, x in next_member(&it) {
				object_put(meta, k, x)
			}
			append(&r.nodes, literal(meta, at))
		}
	case 41, 42, 43:
		// `import PATH as $NAME`, `import PATH as NAME`, `include PATH`.
		dep := new_object()
		if rule != 43 {
			object_put(dep, "as", v[4].text)
		}
		object_put(dep, "is_data", rule == 41)
		object_put(dep, "relpath", v[2].text)
		r = {value = dep}
	case 44:
		r = {}
		if s, ok := literal_string(v[1].node); ok {
			r.text = s
		} else {
			report(p, l[1], "Import path must be constant")
		}
	case 45:
		r = {fn = new_clone(Func{name = v[2].text, body = v[4].node})}
	case 46:
		r = {fn = new_clone(Func{name = v[2].text, params = v[4].names[:], body = v[7].node})}
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
		if text, ok := v[2].value.(string); ok {
			parts := len(r.nodes)
			if parts > 0 && r.nodes[parts - 1].kind == .Literal {
				r.nodes[parts - 1] = literal(strings.concatenate({r.nodes[parts - 1].value.(string), text}), at)
			} else {
				append(&r.nodes, literal(text, l[2]))
			}
		}
	case 56:
		append(&r.nodes, new_clone(Node{kind = .Format, a = v[3].node, name = v[0].text, loc = l[3]}))
	case 57, 100:
		r = {node = node(.If, v[2].node, v[4].node, v[5].node, at = at)}
	case 58:
		r = v[2]
	case 60, 110, 111, 113:
		r = {node = node(.Identity, at = at)}
	case 61:
		r = {node = new_clone(Node{kind = .Call, name = "recurse", loc = at})}
	case 62:
		r = {node = new_clone(Node{kind = .Break, name = v[2].text, loc = at})}
	case 63:
		report(p, at, "break requires a label to break to")
		r = {node = node(.Identity, at = at)}
	case 64:
		r = {node = field(v[1].node, v[2].text, l[2], true, at)}
	case 65:
		r = {node = field(node(.Identity, at = at), v[1].text, l[1], true, at)}
	case 66:
		r = {node = index(v[1].node, v[3].node, true, at)}
	case 67:
		r = {node = index(node(.Identity, at = at), v[2].node, true, at)}
	case 68:
		r = {node = field(v[1].node, v[2].text, l[2], false, at)}
	case 69:
		r = {node = field(node(.Identity, at = at), v[1].text, l[1], false, at)}
	case 70:
		r = {node = index(v[1].node, v[3].node, false, at)}
	case 71:
		r = {node = index(node(.Identity, at = at), v[2].node, false, at)}
	case 72, 73:
		report(p, at, `try .["field"] instead of .field for unusually named fields`)
		r = {node = node(.Identity, at = at)}
	case 74, 75:
		r = {node = index(v[1].node, v[3].node, rule == 74, at)}
	case 76, 77:
		r = {node = index(v[1].node, v[4].node, rule == 76, at)}
	case 78, 79, 80, 81:
		r = {node = new_clone(Node{kind = .Iterate, a = v[1].node, opt = rule == 78 || rule == 80, loc = at})}
	case 82, 85:
		r = {node = new_clone(Node{kind = .Slice, a = v[1].node, b = v[3].node, c = v[5].node, opt = rule == 82, loc = at})}
	case 83, 86:
		r = {node = new_clone(Node{kind = .Slice, a = v[1].node, b = v[3].node, opt = rule == 83, loc = at})}
	case 84, 87:
		r = {node = new_clone(Node{kind = .Slice, a = v[1].node, c = v[4].node, opt = rule == 84, loc = at})}
	case 88:
		r = {node = node(.Try, v[1].node, at = at)}
	case 89:
		r = {node = literal(v[1].value, at)}
	case 91:
		r = {node = new_clone(Node{kind = .Format, name = v[1].text, loc = at})}
	case 92:
		r = {node = node(.Neg, v[2].node, at = at)}
	case 93:
		r = v[2]
	case 94:
		r = {node = array_node(v[2].node, at)}
	case 95:
		r = {node = literal(new_array(), at)}
	case 96:
		r = {node = object_node(v[2].nodes[:], at)}
	case 97:
		r = {node = new_clone(Node{kind = .Reduce, a = v[2].node, b = v[6].node, c = v[8].node, patterns = v[4].pats[:], loc = at})}
	case 98, 99:
		r = {node = new_clone(Node{kind = .Foreach, a = v[2].node, b = v[6].node, c = v[8].node, d = v[10].node if rule == 98 else nil, patterns = v[4].pats[:], loc = at})}
	case 101:
		report(p, at, "Possibly unterminated 'if' statement")
		r = v[2]
	case 102:
		r = {node = node(.Try, v[2].node, v[4].node, at = at)}
	case 103:
		report(p, at, "Possibly unterminated 'try' statement")
		r = v[2]
	case 104:
		r = {node = node(.Try, v[2].node, at = at)}
	case 105:
		r = {node = var_node(v[4].text, at)}
	case 106:
		r = {node = var_node(v[1].text, at)}
	case 107:
		r = {node = loc_literal(p, at)}
	case 108:
		switch v[1].text {
		case "true", "false":
			r = {node = literal(v[1].text == "true", at)}
		case "null":
			r = {node = literal(nil, at)}
		case:
			r = {node = new_clone(Node{kind = .Call, name = v[1].text, loc = at})}
		}
	case 109:
		r = {node = new_clone(Node{kind = .Call, name = v[1].text, args = v[3].nodes[:], loc = l[1]})}
	case 112:
		r = v[1]
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
		r = {members = list(Pattern_Member{key = literal(v[1].text, l[1]), var = v[1].text})}
	case 129:
		r = {members = list(Pattern_Member{key = literal(v[1].text, l[1]), var = v[1].text, pattern = v[3].pat})}
	case 130, 131:
		r = {members = list(Pattern_Member{key = literal(v[1].text, l[1]), pattern = v[3].pat})}
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
		r = {nodes = list(literal(v[1].text, l[1]), v[3].node)}
	case 158:
		r = {nodes = list(v[1].node, v[3].node)}
	case 159:
		r = {nodes = list(v[1].node, nil)}
	case 160:
		r = {nodes = list(var_node(v[1].text, at), v[3].node)}
	case 161:
		r = {nodes = list(literal(v[1].text, l[1]), var_node(v[1].text, at))}
	case 162, 164:
		r = {nodes = list(literal(v[1].text, l[1]), index(node(.Identity, at = at), literal(v[1].text, l[1]), false, at))}
	case 163:
		r = {nodes = list(literal(string("__loc__"), at), loc_literal(p, at))}
	case 165:
		check_object_key(p, v[2].node, l[2])
		r = {nodes = list(v[2].node, v[5].node)}
	case 166:
		report(p, l[1], "May need parentheses around object key expression")
		r = {}
	case 167:
		r = {node = node(.Pipe, v[1].node, v[3].node, at = at)}
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

@(private = "file")
node :: proc(kind: Node_Kind, a: ^Node = nil, b: ^Node = nil, c: ^Node = nil, at := Loc{}) -> ^Node {
	return new_clone(Node{kind = kind, a = a, b = b, c = c, loc = at})
}

@(private = "file")
literal :: proc(v: Value, at: Loc) -> ^Node {
	return new_clone(Node{kind = .Literal, value = v, loc = at})
}

@(private = "file")
var_node :: proc(name: string, at: Loc) -> ^Node {
	return new_clone(Node{kind = .Var, name = name, loc = at})
}

@(private = "file")
is_literal :: proc(n: ^Node) -> bool {
	return n != nil && n.kind == .Literal
}

@(private = "file")
literal_string :: proc(n: ^Node) -> (string, bool) {
	if !is_literal(n) {
		return "", false
	}
	s, ok := n.value.(string)
	return s, ok
}

// `target[key]`. A constant string key is a field.
@(private = "file")
index :: proc(target, key: ^Node, opt: bool, at: Loc) -> ^Node {
	if name, ok := literal_string(key); ok {
		return new_clone(Node{kind = .Field, a = target, name = name, opt = opt, loc = at})
	}
	return new_clone(Node{kind = .Index, a = target, b = key, opt = opt, loc = at})
}

// `target.name`. A fact accessor, which the lexer reads as a field named `@...` (`fact_accessor`), is `target`
// indexed by the path step of that comment role.
@(private = "file")
field :: proc(target: ^Node, name: string, name_at: Loc, opt: bool, at: Loc) -> ^Node {
	if name[0] != '@' {
		return index(target, literal(name, name_at), opt, at)
	}
	names := COMMENT_ROLE_NAMES
	for role_name, role in names {
		if role_name == name[1:] {
			return index(target, literal(fact_key(role), name_at), opt, at)
		}
	}
	unreachable()
}

// `a op b`, computed now when both are constants and the operation succeeds (jq's constant_fold).
@(private = "file")
binop :: proc(p: ^Parser, op: Op, a, b: ^Node, at: Loc) -> ^Node {
	if is_literal(a) && is_literal(b) {
		if v, sig := binary_op(&p.ip, op, a.value, b.value); sig == .Go {
			return literal(v, at)
		}
	}
	return new_clone(Node{kind = .Binary, op = op, a = a, b = b, loc = at})
}

// A string literal: its text parts and its interpolations, or a constant when it interpolates nothing.
@(private = "file")
string_node :: proc(p: ^Parser, parts: []^Node, at: Loc) -> ^Node {
	switch {
	case len(parts) == 0:
		// Each `""` jq writes is a value of its own (jv_identical), as path() tells: an empty slice of the
		// source where it is written, which no other string shares.
		return literal(p.src[at.start:at.start], at)
	case len(parts) == 1 && parts[0].kind == .Literal:
		return literal(parts[0].value, at)
	}
	return new_clone(Node{kind = .String, args = parts, loc = at})
}

// `[q]`: a constant when `q` is constants joined by `,` from the left (jq's gen_const_array).
@(private = "file")
array_node :: proc(q: ^Node, at: Loc) -> ^Node {
	elems :: proc(n: ^Node, into: ^[dynamic]Value) -> bool {
		if is_literal(n) {
			append(into, n.value)
			return true
		}
		if n == nil || n.kind != .Comma || !is_literal(n.b) || !elems(n.a, into) {
			return false
		}
		append(into, n.b.value)
		return true
	}
	vals := make([dynamic]Value, context.temp_allocator)
	if !elems(q, &vals) {
		return node(.Array, q, at = at)
	}
	a := new_array(len(vals))
	append(&a.items, ..vals[:])
	return literal(a, at)
}

// `{...}`, its keys and values in turn: a constant when every key is a constant string and every value a
// constant (gen_const_object).
@(private = "file")
object_node :: proc(entries: []^Node, at: Loc) -> ^Node {
	for i := 0; i < len(entries); i += 2 {
		if _, ok := literal_string(entries[i]); !ok || !is_literal(entries[i + 1]) {
			return new_clone(Node{kind = .Object, args = entries, loc = at})
		}
	}
	o := new_object()
	for i := 0; i < len(entries); i += 2 {
		k, _ := literal_string(entries[i])
		object_put(o, k, entries[i + 1].value)
	}
	return literal(o, at)
}

// `$__loc__`: the file and the line it is on.
@(private = "file")
loc_literal :: proc(p: ^Parser, at: Loc) -> ^Node {
	o := new_object()
	object_put(o, "file", p.file if p.file != "" else string("<top-level>"))
	object_put(o, "line", num(f64(strings.count(p.src[:at.start], "\n") + 1)))
	return literal(o, at)
}

@(private = "file")
check_object_key :: proc(p: ^Parser, key: ^Node, at: Loc) {
	if is_literal(key) && kind(key.value) != .String {
		report(p, at, message.build("Cannot use %s (%s) as object key", type_name(key.value), brief(nil, key.value)))
	}
}

// Whether module metadata is not a constant object, which is reported.
@(private = "file")
meta_error :: proc(p: ^Parser, meta: ^Node, at: Loc) -> bool {
	switch {
	case !is_literal(meta):
		report(p, at, "Module metadata must be constant")
	case kind(meta.value) != .Object:
		report(p, at, "Module metadata must be an object")
	case:
		return false
	}
	return true
}

@(private = "file")
dep_values :: proc(nodes: []^Node) -> []Value {
	if len(nodes) == 0 {
		return nil
	}
	deps := make([]Value, len(nodes))
	for n, i in nodes {
		deps[i] = n.value
	}
	return deps
}
