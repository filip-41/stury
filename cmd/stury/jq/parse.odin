package jq

// jq 1.8.2's parser. The lexer is jq's src/lexer.l (the longest match wins, then the earlier rule), and
// the parser is bison's LALR driver running jq's own tables (grammar_tables.odin), so a program parses,
// fails, and recovers from its errors as it does in jq, with jq's messages at jq's locations. The
// actions are those of jq's parser.y, folding constants where jq's gen_* functions do.

import "core:fmt"
import "core:strings"

// A span of the program, in bytes.
Loc :: struct {
	start, end: int,
}

Compile_Error :: struct {
	msg: string,
	loc: Loc,
	// The module it is in, by its path and text, "" for the program.
	file, src: string,
}

// A parsed program: its body, nil when it only defines functions. Those definitions, a chain of `Def` nodes ending in
// nil, when it is only definitions. Its `module` directive's metadata, nil without one, and what it imports, each as
// jq's linker and `modulemeta` see it: the directive's metadata with `as` (an import's name), `is_data` and `relpath`
// set over it.
Program :: struct {
	body: ^Node,
	defs: ^Node,
	meta: Value,
	deps: []Value,
}

// bison's YYMAXDEPTH: a parse this deep is "memory exhausted".
@(private = "file")
MAX_PARSE_DEPTH :: 10000

// The lexer's start conditions, innermost last: inside (), [], {}, an interpolation, or a string.
@(private = "file")
Mode :: enum u8 {
	Paren,
	Bracket,
	Brace,
	Interp,
	String,
}

// A symbol's semantic value: what a token carries, or what a rule built.
@(private = "file")
Sem :: struct {
	node:    ^Node,
	text:    string, // a name, a field, a format, a keyword, or an import path
	value:   Value, // a number or a string's text
	fn:      ^Func,
	pat:     ^Pattern,
	nodes:   [dynamic]^Node, // a string's parts, a call's arguments, or an object's keys and values
	names:   [dynamic]string, // parameters
	pats:    [dynamic]^Pattern, // alternatives, or an array pattern's elements
	members: [dynamic]Pattern_Member,
}

@(private = "file")
Parser :: struct {
	src:    string,
	pos:    int,
	modes:  [dynamic]Mode,
	last:   Loc, // the span the lexer matched last, where the end of the program is reported
	errors: [dynamic]Compile_Error,
	prog:   Program,
	file:   string, // the module's path, "" for the program
	ip:     Interp, // folds constants
}

// `src` as a program, or as the module at path `file`, and the errors jq reports for it (none if it
// parsed). The nodes are allocated with the context allocator and live as long as it.
parse :: proc(src: string, file := "") -> (Program, []Compile_Error) {
	p := Parser{src = src, file = file}
	run(&p)
	for &e in p.errors {
		e.file, e.src = file, src
	}
	return p.prog, p.errors[:]
}

// `e` as jq reports it (locfile_locate): the message, its line and column, the line, and carets under
// the span (cut at the end of the line).
locate :: proc(src: string, e: Compile_Error) -> string {
	src := e.src if e.file != "" else src
	start := e.loc.start
	offset := strings.last_index_byte(src[:start], '\n') + 1
	line_end := strings.index_byte(src[offset:], '\n')
	line_end = len(src) if line_end < 0 else offset + line_end
	end := min(e.loc.end, max(line_end, start + 1))
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s at %s, line %d, column %d:\n    %s\n    ", e.msg, e.file if e.file != "" else "<top-level>", strings.count(src[:start], "\n") + 1, start - offset + 1, src[offset:line_end])
	carets := max(end - start, 0)
	for _ in 0 ..< max(end - offset - carets, 0) {
		strings.write_byte(&b, ' ')
	}
	for _ in 0 ..< carets {
		strings.write_byte(&b, '^')
	}
	return strings.to_string(b)
}

// ---- The parser: bison's yyparse

@(private = "file")
run :: proc(p: ^Parser) {
	states := make([dynamic]int, 0, 64)
	sems := make([dynamic]Sem, 0, 64)
	locs := make([dynamic]Loc, 0, 64)
	append(&states, 0)
	append(&sems, Sem{})
	append(&locs, Loc{})
	tok: Sym
	tok_sem: Sem
	tok_loc: Loc // the last token read, which a syntax error is reported at
	have := false // whether `tok` is the lookahead
	recovering := 0 // bison's yyerrstatus: tokens to shift before another syntax error is reported
	for {
		state := states[len(states) - 1]
		if len(states) >= MAX_PARSE_DEPTH {
			report(p, tok_loc, "memory exhausted")
			return
		}
		if state == FINAL {
			return
		}
		rule := int(DEFACT[state])
		if n := int(PACT[state]); n != PACT_NINF {
			if !have {
				tok, tok_sem, tok_loc = lex(p)
				have = true
			}
			n += int(tok)
			if n >= 0 && n <= LAST && int(CHECK[n]) == int(tok) {
				if t := int(TABLE[n]); t > 0 {
					recovering = max(recovering - 1, 0)
					append(&states, t)
					append(&sems, tok_sem)
					append(&locs, tok_loc)
					have = false
					continue
				} else {
					rule = 0 if t == TABLE_NINF else -t
				}
			}
		}
		if rule != 0 {
			reduce(p, rule, &states, &sems, &locs)
			continue
		}
		// A syntax error: report it unless just recovering from one, drop the lookahead if it already
		// failed once, then pop states until one shifts `error`.
		if recovering == 0 {
			report(p, tok_loc, syntax_message(state, tok, have))
		}
		from := tok_loc
		if recovering == 3 && have {
			if tok == .End {
				return
			}
			have = false
		}
		recovering = 3
		target := error_target(states[len(states) - 1])
		for target == 0 && len(states) > 1 {
			from = pop(&locs)
			pop(&states)
			pop(&sems)
			target = error_target(states[len(states) - 1])
		}
		if target == 0 {
			return
		}
		append(&states, target)
		append(&sems, Sem{})
		append(&locs, Loc{from.start, tok_loc.end})
	}
}

// The state `error` shifts to from `state`, or 0.
@(private = "file")
error_target :: proc(state: int) -> int {
	n := int(PACT[state])
	if n == PACT_NINF {
		return 0
	}
	n += int(Sym.Error)
	if n < 0 || n > LAST || int(CHECK[n]) != int(Sym.Error) {
		return 0
	}
	return max(int(TABLE[n]), 0)
}

// bison's verbose message: the unexpected token, and what `state` expects if that is four tokens or fewer.
@(private = "file")
syntax_message :: proc(state: int, tok: Sym, have: bool) -> string {
	if !have {
		return "syntax error"
	}
	expected: [4]Sym
	count := 0
	listed := true
	if n := int(PACT[state]); n != PACT_NINF {
		for x in max(0, -n) ..< min(LAST - n + 1, NTOKENS) {
			if int(CHECK[x + n]) == x && x != int(Sym.Error) && int(TABLE[x + n]) != TABLE_NINF {
				if count == len(expected) {
					listed = false
					break
				}
				expected[count] = Sym(x)
				count += 1
			}
		}
	}
	b := strings.builder_make()
	strings.write_string(&b, "syntax error, unexpected ")
	strings.write_string(&b, SYM_NAMES[tok])
	for x, i in expected[:count if listed else 0] {
		strings.write_string(&b, ", expecting " if i == 0 else " or ")
		strings.write_string(&b, SYM_NAMES[x])
	}
	return strings.to_string(b)
}

@(private = "file")
report :: proc(p: ^Parser, loc: Loc, msg: string) {
	append(&p.errors, Compile_Error{msg = msg, loc = loc})
}

@(private = "file")
reduce :: proc(p: ^Parser, rule: int, states: ^[dynamic]int, sems: ^[dynamic]Sem, locs: ^[dynamic]Loc) {
	n := int(RULE_LEN[rule])
	top := len(states) - 1
	at := Loc{locs[top - n + 1].start, locs[top].end} if n > 0 else Loc{locs[top].end, locs[top].end}
	r := act(p, rule, sems^[top - n:], locs^[top - n:], at)
	resize(states, len(states) - n)
	resize(sems, len(sems) - n)
	resize(locs, len(locs) - n)
	lhs := int(RULE_LHS[rule])
	s := states[len(states) - 1]
	i := int(PGOTO[lhs]) + s
	append(states, int(TABLE[i]) if i >= 0 && i <= LAST && int(CHECK[i]) == s else int(DEFGOTO[lhs]))
	append(sems, r)
	append(locs, at)
}

// ---- The actions, numbered as the rules of jq's parser.y. `v[k]` and `l[k]` are `$k` and `@k`, `at` is `@$`.

@(private = "file")
act :: proc(p: ^Parser, rule: int, v: []Sem, l: []Loc, at: Loc) -> (r: Sem) {
	if len(v) > 1 {
		r = v[1]
	}
	switch rule {
	case 2:
		p.prog = {body = v[3].node, meta = v[1].value, deps = dep_values(v[2].nodes[:])}
	case 3:
		p.prog = {defs = v[3].node, meta = v[1].value, deps = dep_values(v[2].nodes[:])}
	case 4, 6, 8, 153:
		r = {}
	case 5:
		r = {}
		if !meta_error(p, v[2].node, l[2]) {
			r.value = v[2].node.value
		}
	case 7:
		append(&r.nodes, ..v[2].nodes[:])
	case 9, 10:
		r = {node = node(.Def, v[2].node, at = at)}
		r.node.fn = v[1].fn
	case 11:
		r = {node = node(.Bind, v[1].node, v[5].node, at = at)}
		r.node.patterns = v[3].pats[:]
	case 12:
		r = {node = node(.Label, v[4].node, at = at)}
		r.node.name = v[2].text
	case 13:
		r = {node = node(.Pipe, v[1].node, v[3].node, at = at)}
	case 14:
		r = {node = node(.Comma, v[1].node, v[3].node, at = at)}
	case 16:
		r = {node = node(.Alt, v[1].node, v[3].node, at = at)}
	case 17, 20, 21, 23, 25, 27, 30, 31:
		r = {node = node(.Update, v[1].node, v[3].node, at = at)}
		r.node.op = UPDATE_OPS[rule]
	case 18:
		r = {node = node(.Or, v[1].node, v[3].node, at = at)}
	case 19:
		r = {node = node(.And, v[1].node, v[3].node, at = at)}
	case 22, 24, 26, 28, 29, 32, 33, 34, 35, 36, 37:
		r = {node = binop(p, BINARY_OPS[rule], v[1].node, v[3].node, at)}
	case 39:
		r = {}
		append(&r.nodes, literal(v[1].value, at))
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
		r = {}
		append(&r.names, v[1].text)
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
	case 54:
		r = {}
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
		f := node(.Format, v[3].node, at = l[3])
		f.name = v[0].text
		append(&r.nodes, f)
	case 57, 100:
		r = {node = node(.If, v[2].node, v[4].node, v[5].node, at = at)}
	case 58:
		r = v[2]
	case 59:
		r = {}
	case 60, 110, 111, 113:
		r = {node = node(.Identity, at = at)}
	case 61:
		r = {node = node(.Call, at = at)}
		r.node.name = "recurse"
	case 62:
		r = {node = node(.Break, at = at)}
		r.node.name = v[2].text
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
		r = {node = node(.Iterate, v[1].node, at = at)}
		r.node.opt = rule == 78 || rule == 80
	case 82, 85:
		r = {node = node(.Slice, v[1].node, v[3].node, v[5].node, at = at)}
		r.node.opt = rule == 82
	case 83, 86:
		r = {node = node(.Slice, v[1].node, v[3].node, at = at)}
		r.node.opt = rule == 83
	case 84, 87:
		r = {node = node(.Slice, v[1].node, nil, v[4].node, at = at)}
		r.node.opt = rule == 84
	case 88:
		r = {node = node(.Try, v[1].node, at = at)}
	case 89:
		r = {node = literal(v[1].value, at)}
	case 91:
		r = {node = node(.Format, at = at)}
		r.node.name = v[1].text
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
		r = {node = node(.Reduce, v[2].node, v[6].node, v[8].node, at = at)}
		r.node.patterns = v[4].pats[:]
	case 98:
		r = {node = node(.Foreach, v[2].node, v[6].node, v[8].node, v[10].node, at)}
		r.node.patterns = v[4].pats[:]
	case 99:
		r = {node = node(.Foreach, v[2].node, v[6].node, v[8].node, at = at)}
		r.node.patterns = v[4].pats[:]
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
			r = {node = node(.Call, at = at)}
			r.node.name = v[1].text
		}
	case 109:
		r = {node = node(.Call, at = l[1])}
		r.node.name = v[1].text
		r.node.args = v[3].nodes[:]
	case 112:
		r = v[1]
	case 114:
		r = {}
		append(&r.nodes, v[1].node)
	case 115:
		append(&r.nodes, v[3].node)
	case 117, 119, 125:
		append(&r.pats, v[3].pat)
	case 118, 120, 124:
		r = {}
		append(&r.pats, v[1].pat)
	case 121:
		r = {pat = new_clone(Pattern{kind = .Var, name = v[1].text})}
	case 122:
		r = {pat = new_clone(Pattern{kind = .Array, elems = v[2].pats[:]})}
	case 123:
		r = {pat = new_clone(Pattern{kind = .Object, members = v[2].members[:]})}
	case 127:
		append(&r.members, ..v[3].members[:])
	case 128:
		r = {}
		append(&r.members, Pattern_Member{key = literal(v[1].text, l[1]), var = v[1].text})
	case 129:
		r = {}
		append(&r.members, Pattern_Member{key = literal(v[1].text, l[1]), var = v[1].text, pattern = v[3].pat})
	case 130, 131:
		r = {}
		append(&r.members, Pattern_Member{key = literal(v[1].text, l[1]), pattern = v[3].pat})
	case 132:
		r = {}
		append(&r.members, Pattern_Member{key = v[1].node, pattern = v[3].pat})
	case 133:
		check_object_key(p, v[2].node, l[2])
		r = {}
		append(&r.members, Pattern_Member{key = v[2].node, pattern = v[5].pat})
	case 134:
		report(p, at, "May need parentheses around object key expression")
		r = {}
	case 155:
		append(&r.nodes, ..v[3].nodes[:])
	case 156, 157:
		r = {}
		append(&r.nodes, literal(v[1].text, l[1]), v[3].node)
	case 158:
		r = {}
		append(&r.nodes, v[1].node, v[3].node)
	case 159:
		r = {}
		append(&r.nodes, v[1].node, nil)
	case 160:
		r = {}
		append(&r.nodes, var_node(v[1].text, at), v[3].node)
	case 161:
		r = {}
		append(&r.nodes, literal(v[1].text, l[1]), var_node(v[1].text, at))
	case 162, 164:
		r = {}
		append(&r.nodes, literal(v[1].text, l[1]), index(node(.Identity, at = at), literal(v[1].text, l[1]), false, at))
	case 163:
		r = {}
		append(&r.nodes, literal("__loc__", at), loc_literal(p, at))
	case 165:
		check_object_key(p, v[2].node, l[2])
		r = {}
		append(&r.nodes, v[2].node, v[5].node)
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
node :: proc(kind: Node_Kind, a: ^Node = nil, b: ^Node = nil, c: ^Node = nil, d: ^Node = nil, at := Loc{}) -> ^Node {
	return new_clone(Node{kind = kind, a = a, b = b, c = c, d = d, loc = at})
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
	n: ^Node
	if name, ok := literal_string(key); ok {
		n = node(.Field, target, at = at)
		n.name = name
	} else {
		n = node(.Index, target, key, at = at)
	}
	n.opt = opt
	return n
}

// `target.name`. A fact accessor, which the lexer reads as a field named `@...` (`fact_accessor`), is a
// call on `target` of the builtin of that name.
@(private = "file")
field :: proc(target: ^Node, name: string, name_at: Loc, opt: bool, at: Loc) -> ^Node {
	if name[0] != '@' {
		return index(target, literal(name, name_at), opt, at)
	}
	read := new_clone(Node{kind = .Call, name = name, loc = name_at})
	return node(.Pipe, target, read, at = at)
}

// `a op b`, computed now when both are constants and the operation succeeds (jq's constant_fold).
@(private = "file")
binop :: proc(p: ^Parser, op: Op, a, b: ^Node, at: Loc) -> ^Node {
	if is_literal(a) && is_literal(b) {
		if v, sig := binary_op(&p.ip, op, a.value, b.value); sig == .Go {
			return literal(v, at)
		}
	}
	n := node(.Binary, a, b, at = at)
	n.op = op
	return n
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
	n := node(.String, at = at)
	n.args = parts
	return n
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
			n := node(.Object, at = at)
			n.args = entries
			return n
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
	object_put(o, "file", p.file if p.file != "" else "<top-level>")
	object_put(o, "line", num(f64(strings.count(p.src[:at.start], "\n") + 1)))
	return literal(o, at)
}

@(private = "file")
check_object_key :: proc(p: ^Parser, key: ^Node, at: Loc) {
	if is_literal(key) && kind(key.value) != .String {
		report(p, at, fmt.aprintf("Cannot use %s (%s) as object key", type_name(key.value), brief(key.value)))
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

// ---- The lexer: jq's src/lexer.l

@(private = "file")
lex :: proc(p: ^Parser) -> (Sym, Sem, Loc) {
	s := p.src
	if len(p.modes) > 0 && p.modes[len(p.modes) - 1] == .String {
		return lex_in_string(p)
	}
	for p.pos < len(s) {
		start := p.pos
		switch s[start] {
		case ' ', '\t', '\n', '\r':
			for p.pos < len(s) && is_space(s[p.pos]) {
				p.pos += 1
			}
			p.last = {start, p.pos}
			continue
		case '#':
			skip_comment(p)
			continue
		}
		break
	}
	if p.pos >= len(s) {
		return .End, {}, p.last
	}
	start := p.pos
	sym, sem := lex_token(p)
	p.last = {start, p.pos}
	return sym, sem, p.last
}

// A comment, each piece of it a match of its own: a `\` escapes a `\` or a line end.
@(private = "file")
skip_comment :: proc(p: ^Parser) {
	s := p.src
	p.last = {p.pos, p.pos + 1}
	p.pos += 1
	for p.pos < len(s) {
		start := p.pos
		rest := s[start:]
		switch {
		case strings.has_prefix(rest, "\n"), strings.has_prefix(rest, "\r\n"):
			p.pos += 1 if rest[0] == '\n' else 2
			p.last = {start, p.pos}
			return
		case strings.has_prefix(rest, "\\\\"), strings.has_prefix(rest, "\\\n"):
			p.pos += 2
		case strings.has_prefix(rest, "\\\r\n"):
			p.pos += 3
		case:
			p.pos += 1
		}
		p.last = {start, p.pos}
	}
}

@(private = "file", rodata)
KEYWORDS := [?]struct {
	text: string,
	sym:  Sym,
}{{"as", .As}, {"import", .Import}, {"include", .Include}, {"module", .Module}, {"def", .Def}, {"if", .If}, {"then", .Then}, {"else", .Else}, {"elif", .Elif}, {"and", .And}, {"or", .Or}, {"end", .End_Kw}, {"reduce", .Reduce}, {"foreach", .Foreach}, {"try", .Try}, {"catch", .Catch}, {"label", .Label}, {"break", .Break}}

@(private = "file", rodata)
OPERATORS := [?]struct {
	text: string,
	sym:  Sym,
}{{"?//", .Alternation}, {"//=", .Set_Alt}, {"!=", .Neq}, {"==", .Eq}, {"//", .Alt}, {"|=", .Set_Pipe}, {"+=", .Set_Plus}, {"-=", .Set_Minus}, {"*=", .Set_Mult}, {"/=", .Set_Div}, {"%=", .Set_Mod}, {"<=", .Less_Eq}, {">=", .Greater_Eq}, {"..", .Rec}, {"?", .Question}, {"=", .Assign}, {";", .Semi}, {",", .Comma}, {":", .Colon}, {"|", .Pipe}, {"+", .Plus}, {"-", .Minus}, {"*", .Star}, {"/", .Slash}, {"%", .Percent}, {"<", .Less}, {">", .Greater}}

// stury's comment accessors, which `rest`, the program after a `.`, starts with: `@comment`, `@comment_inline` or
// `@comment_foot`, "" for anything else. jq reads `.@name` only as `.@name "string"`, a format applied to a string
// key, which stays so: no jq program has one of these.
@(private = "file")
fact_accessor :: proc(rest: string) -> string {
	end := 1
	for end < len(rest) && ident_byte(rest[end]) {
		end += 1
	}
	name := rest[:end]
	if name != "@comment" && name != "@comment_inline" && name != "@comment_foot" {
		return ""
	}
	for end < len(rest) && is_space(rest[end]) {
		end += 1
	}
	return "" if end < len(rest) && rest[end] == '"' else name
}

@(private = "file")
lex_token :: proc(p: ^Parser) -> (Sym, Sem) {
	s := p.src
	start := p.pos
	c := s[start]
	next: u8 = s[start + 1] if start + 1 < len(s) else 0
	fact := fact_accessor(s[start + 1:]) if c == '.' && next == '@' else ""
	switch {
	case is_digit(c) || (c == '.' && is_digit(next)):
		return .Literal, {value = lex_number(p)}
	case fact != "":
		p.pos += 1 + len(fact)
		return .Field, {text = fact}
	case c == '.' && ident_start(next):
		p.pos += 1
		end := p.pos
		for end < len(s) && ident_byte(s[end]) {
			end += 1
		}
		p.pos = end
		return .Field, {text = s[start + 1:end]}
	case c == '$' && ident_start(next):
		p.pos += 1
		name := take_ident(p)
		return Sym.Loc if name == "__loc__" else Sym.Binding, {text = name}
	case ident_start(c):
		name := take_ident(p)
		for k in KEYWORDS {
			if k.text == name {
				return k.sym, {text = name}
			}
		}
		return .Ident, {text = name}
	case c == '@' && (ident_byte(next)):
		end := start + 1
		for end < len(s) && ident_byte(s[end]) {
			end += 1
		}
		p.pos = end
		return .Format, {text = s[start + 1:end]}
	case c == '"':
		p.pos += 1
		append(&p.modes, Mode.String)
		return .QQ_Start, {}
	case c == '(' || c == '[' || c == '{':
		p.pos += 1
		append(&p.modes, Mode.Paren if c == '(' else (Mode.Bracket if c == '[' else Mode.Brace))
		return Sym.LParen if c == '(' else (Sym.LBracket if c == '[' else Sym.LBrace), {}
	case c == ')' || c == ']' || c == '}':
		p.pos += 1
		return close(p, c), {}
	}
	for op in OPERATORS {
		if strings.has_prefix(s[start:], op.text) {
			p.pos += len(op.text)
			return op.sym, {}
		}
	}
	p.pos += 1
	if c == '.' {
		return .Dot, {}
	}
	if c == '$' {
		return .Dollar, {}
	}
	return .Invalid, {}
}

// A closing bracket ends the innermost (), [], {} or interpolation it matches, or is invalid.
@(private = "file")
close :: proc(p: ^Parser, c: u8) -> Sym {
	if len(p.modes) == 0 {
		return .Invalid
	}
	top := p.modes[len(p.modes) - 1]
	sym: Sym
	switch {
	case top == .Paren && c == ')':
		sym = .RParen
	case top == .Bracket && c == ']':
		sym = .RBracket
	case top == .Brace && c == '}':
		sym = .RBrace
	case top == .Interp && c == ')':
		sym = .QQ_Interp_End
	case:
		return .Invalid
	}
	pop(&p.modes)
	return sym
}

// `([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?`, as a number that keeps its original text.
@(private = "file")
lex_number :: proc(p: ^Parser) -> Value {
	s := p.src
	start := p.pos
	i := start
	for i < len(s) && is_digit(s[i]) {
		i += 1
	}
	if i < len(s) && s[i] == '.' {
		i += 1
		for i < len(s) && is_digit(s[i]) {
			i += 1
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		j := i + 1
		if j < len(s) && (s[j] == '+' || s[j] == '-') {
			j += 1
		}
		if j < len(s) && is_digit(s[j]) {
			for j < len(s) && is_digit(s[j]) {
				j += 1
			}
			i = j
		}
	}
	p.pos = i
	v, _ := read_number(s[start:i])
	return v
}

// Inside a string: an interpolation's start, the closing quote, a run of escapes, or plain text.
@(private = "file")
lex_in_string :: proc(p: ^Parser) -> (sym: Sym, sem: Sem, loc: Loc) {
	s := p.src
	start := p.pos
	if start >= len(s) {
		return .End, {}, p.last
	}
	switch {
	case strings.has_prefix(s[start:], "\\("):
		p.pos += 2
		append(&p.modes, Mode.Interp)
		sym = .QQ_Interp_Start
	case s[start] == '"':
		p.pos += 1
		pop(&p.modes)
		sym = .QQ_End
	case s[start] == '\\':
		end := start
		for end + 1 < len(s) && s[end] == '\\' && s[end + 1] != '(' {
			if s[end + 1] != 'u' {
				end += 2
				continue
			}
			j := end + 2
			for j < len(s) && j < end + 6 && is_alnum(s[j]) {
				j += 1
			}
			end = j
		}
		if end == start {
			p.pos += 1
			sym = .Invalid
		} else {
			p.pos = end
			sym = .QQ_Text
			sem.value = unescape(p, s[start:end], {start, end})
		}
	case:
		end := start
		for end < len(s) && s[end] != '\\' && s[end] != '"' {
			end += 1
		}
		p.pos = end
		sym = .QQ_Text
		sem.value = s[start:end]
	}
	p.last = {start, p.pos}
	return sym, sem, p.last
}

// A run of escapes decoded as jq's JSON parser decodes `"run"`, or nil after reporting why it cannot be.
@(private = "file")
unescape :: proc(p: ^Parser, run: string, at: Loc) -> Value {
	b := strings.builder_make()
	msg := decode_string(&b, run)
	if msg == "" {
		return strings.to_string(b)
	}
	// The JSON parser counts lines and columns over `"run"`, to its closing quote.
	line, column := 1, 1
	for ch in transmute([]byte)run {
		column += 1
		if ch == '\n' {
			line, column = line + 1, 0
		}
	}
	report(p, at, fmt.aprintf("%s at line %d, column %d (while parsing '\"%s\"')", msg, line, column + 1, run))
	return nil
}

@(private = "file")
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
is_alnum :: proc(c: u8) -> bool {
	return is_digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private = "file")
ident_start :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

ident_byte :: proc(c: u8) -> bool {
	return ident_start(c) || is_digit(c)
}

// `([a-zA-Z_][a-zA-Z_0-9]*::)*[a-zA-Z_][a-zA-Z_0-9]*` from `p.pos`, which starts one.
@(private = "file")
take_ident :: proc(p: ^Parser) -> string {
	s := p.src
	start := p.pos
	for {
		for p.pos < len(s) && ident_byte(s[p.pos]) {
			p.pos += 1
		}
		if p.pos + 2 < len(s) && s[p.pos] == ':' && s[p.pos + 1] == ':' && ident_start(s[p.pos + 2]) {
			p.pos += 2
			continue
		}
		return s[start:p.pos]
	}
}
