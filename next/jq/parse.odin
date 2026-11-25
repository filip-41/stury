package jq

// jq 1.8.2's parser: bison's LALR driver running jq's own tables (grammar_tables.odin), so a program parses, fails, and
// recovers from its errors as it does in jq, with jq's messages at jq's locations. lex.odin is jq's lexer
// (src/lexer.l) and actions.odin the rule actions of jq's parser.y. The parse stack is the only stack it takes: no
// part of parsing recurses.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "stury:lib/base/kernel"
import "stury:lib/query"

// A span of the program, in bytes.
@(private)
Loc :: struct {
	start, end: int,
}

// How `locate` words a compile error.
Compile_Error_Kind :: enum u8 {
	Located, // the message at `loc` of the program or of the module `file`, whose text is `src`
	Unlocated, // the message alone, which jq prints after `jq: error: `
	Raw, // the message as jq prints it whole
}

// An error that keeps a program from compiling, at `loc` of the module `file` (its path, "" for the program) whose text
// is `src`. `uncounted` marks an error jq does not count in its total, the ones a stopped import list had before its own.
Compile_Error :: struct {
	msg:       string,
	loc:       Loc,
	file, src: string,
	kind:      Compile_Error_Kind,
	uncounted: bool,
}

// A parsed program or module.
@(private)
Parsed :: struct {
	body: ^Node, // nil when it only defines functions
	defs: ^Node, // those definitions, a chain of `Def` nodes ending in nil, when it is only definitions
	// Its `module` directive's metadata, `.Absent` without one, and what it imports, each as jq's linker and
	// `modulemeta` see it.
	meta: query.Value,
	deps: []query.Value,
}

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
	value:   query.Value, // a number or a string's text
	fn:      ^Func,
	pat:     ^Pattern,
	nodes:   [dynamic]^Node, // a string's parts, a call's arguments, or an object's keys and values
	names:   [dynamic]string, // parameters
	pats:    [dynamic]^Pattern, // alternatives, or an array pattern's elements
	members: [dynamic]Pattern_Member,
}

@(private)
Parser :: struct {
	src:       string,
	pos:       int,
	modes:     [dynamic]Mode,
	last:      Loc, // the span the lexer matched last, where the end of the program is reported
	errors:    ^[dynamic]Compile_Error,
	prog:      Parsed,
	file:      string, // the module's path, "" for the program
	unit:      ^Unit,
	max_depth: int, // the deepest parse stack, bison's YYMAXDEPTH, past which a parse is "memory exhausted"
}

// The memory of a program and the modules it links: nodes, names and constants in one arena freed whole, and every
// node in the order it was made, children first.
@(private)
Unit :: struct {
	arena:     mem.Dynamic_Arena,
	allocator: runtime.Allocator, // the arena's
	heap:      query.Heap, // the constants', in the arena, frozen once made
	order:     [dynamic]^Node,
}

@(private)
unit_init :: proc(u: ^Unit, allocator: runtime.Allocator) {
	mem.dynamic_arena_init(&u.arena, allocator, allocator)
	u.allocator = mem.dynamic_arena_allocator(&u.arena)
	query.heap_init(&u.heap, u.allocator)
	u.order = make([dynamic]^Node, 0, 64, u.allocator)
}

@(private)
unit_destroy :: proc(u: ^Unit) {
	mem.dynamic_arena_destroy(&u.arena)
	u^ = {}
}

// `src` as a program, or as the module at path `file`, its errors appended to `errors` as jq reports them. Nodes,
// names and constants are made in `u`'s arena. A parse stack deeper than `max_depth` is "memory exhausted".
@(private)
parse :: proc(u: ^Unit, src: string, errors: ^[dynamic]Compile_Error, max_depth: int, file := "") -> Parsed {
	context.allocator = u.allocator
	p := Parser{src = src, file = file, unit = u, errors = errors, max_depth = max_depth, prog = {meta = query.ABSENT}}
	start := len(errors)
	run(&p)
	for &e in errors[start:] {
		e.file, e.src = file, src
	}
	return p.prog
}

// `e` as jq reports it (locfile_locate): the message, its line and column, the line, and carets under the span (cut at
// the end of the line), or its message alone when it has no place.
locate :: proc(e: Compile_Error, allocator := context.allocator) -> string {
	if e.kind != .Located {
		return e.msg
	}
	src := e.src
	start := min(e.loc.start, len(src))
	offset := strings.last_index_byte(src[:start], '\n') + 1
	line_end := strings.index_byte(src[offset:], '\n')
	line_end = len(src) if line_end < 0 else offset + line_end
	end := min(e.loc.end, max(line_end, start + 1))
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "%s at %s, line %d, column %d:\n    %s\n    ", e.msg, e.file if e.file != "" else "<top-level>", kernel.count_byte(transmute([]u8)src[:start], '\n') + 1, start - offset + 1, src[offset:line_end])
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
		if len(states) >= p.max_depth {
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
	append(p.errors, Compile_Error{msg = msg, loc = loc})
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

