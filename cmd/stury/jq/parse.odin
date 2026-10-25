package jq

// jq 1.8.2's parser: bison's LALR driver running jq's own tables (grammar_tables.odin), so a program
// parses, fails, and recovers from its errors as it does in jq, with jq's messages at jq's locations.
// lex.odin is jq's lexer (src/lexer.l) and actions.odin the rule actions of jq's parser.y.

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
@(private)
Mode :: enum u8 {
	Paren,
	Bracket,
	Brace,
	Interp,
	String,
}

// A symbol's semantic value: what a token carries, or what a rule built.
@(private)
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

@(private)
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

@(private)
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

