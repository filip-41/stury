package jq

// jq 1.8.2's parser: bison's LALR driver running jq's own tables (grammar_tables.odin).

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "stury:lib/base/kernel"
import "stury:lib/query"

@(private)
Loc :: struct { start, end: int }

Compile_Error_Kind :: enum u8 { Located, Unlocated, Raw }

Compile_Error :: struct {
	msg, file, src: string,
	loc:            Loc,
	kind:           Compile_Error_Kind,
	uncounted:      bool,
}

@(private)
Parsed :: struct {
	body, defs: ^Node,
	meta:       query.Value,
	deps:       []query.Value,
}

@(private)
Mode :: enum u8 { Paren, Bracket, Brace, Interp, Fact, String }

@(private)
Computed_Step :: enum u8 { None, Fact, Attribute }

@(private)
Sem :: struct {
	node:    ^Node,
	text:    string,
	value:   query.Value,
	fn:      ^Func,
	pat:     ^Pattern,
	nodes:   [dynamic]^Node,
	names:   [dynamic]string,
	pats:    [dynamic]^Pattern,
	members: [dynamic]Pattern_Member,
}

@(private)
Parser :: struct {
	src, file: string,
	pos:       int,
	modes:     [dynamic]Mode,
	last:      Loc,
	errors:    ^[dynamic]Compile_Error,
	prog:      Parsed,
	unit:      ^Unit,
	max_depth: int,
	computed:  map[int]Computed_Step,
}

@(private)
Unit :: struct {
	arena:     mem.Dynamic_Arena,
	allocator: runtime.Allocator,
	heap:      query.Heap,
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
	tok_loc: Loc
	have, recovering := false, 0
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
					recovering, have = max(recovering - 1, 0), false
					append(&states, t)
					append(&sems, tok_sem)
					append(&locs, tok_loc)
					continue
				}
				rule = 0 if TABLE[n] == TABLE_NINF else -int(TABLE[n])
			}
		}
		if rule != 0 {
			reduce(p, rule, &states, &sems, &locs)
			continue
		}
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

@(private = "file")
error_target :: proc(state: int) -> int {
	n := int(PACT[state])
	if n == PACT_NINF {
		return 0
	}
	n += int(Sym.Error)
	return max(int(TABLE[n]), 0) if n >= 0 && n <= LAST && int(CHECK[n]) == int(Sym.Error) else 0
}

@(private = "file")
syntax_message :: proc(state: int, tok: Sym, have: bool) -> string {
	if !have {
		return "syntax error"
	}
	expected: [4]Sym
	count, listed := 0, true
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
	n, top := int(RULE_LEN[rule]), len(states) - 1
	at := Loc{locs[top - n + 1].start, locs[top].end} if n > 0 else Loc{locs[top].end, locs[top].end}
	r := act(p, rule, sems^[top - n:], locs^[top - n:], at)
	resize(states, len(states) - n)
	resize(sems, len(sems) - n)
	resize(locs, len(locs) - n)
	lhs, s := int(RULE_LHS[rule]), states[len(states) - 1]
	i := int(PGOTO[lhs]) + s
	append(states, int(TABLE[i]) if i >= 0 && i <= LAST && int(CHECK[i]) == s else int(DEFGOTO[lhs]))
	append(sems, r)
	append(locs, at)
}
