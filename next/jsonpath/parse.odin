package jsonpath

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "stury:lib/query"

// Strict RFC 9535 lexer, explicit-stack parser (zero native recursion), and §2.4 well-typedness checker.

// Compiles RFC 9535 JSONPath `src` into an immutable `^Program` with precompiled literal I-Regexps and `query.Plan`.
// On error, returns `(nil, err)` with zero leaked allocations; `err.message` is a static string.
compile :: proc(src: string, opts := Compile_Options{}, allocator := context.allocator) -> (prog: ^Program, err: Compile_Error) {
	alloc_err: runtime.Allocator_Error
	prog, alloc_err = new(Program, allocator)
	if alloc_err != nil {
		return nil, {.Memory, 0, "out of memory allocating program"}
	}
	prog.backing = allocator
	mem.dynamic_arena_init(&prog.arena, allocator, allocator, block_size = 4096, out_band_size = 1024)
	prog.allocator = mem.dynamic_arena_allocator(&prog.arena)

	p: Parser
	p.src = src
	p.prog = prog
	p.arena = prog.allocator
	p.scratch = allocator
	p.max_depth = compile_depth_limit(opts)
	defer {
		for &f in p.frames {
			delete(f.segs)
			delete(f.sels)
			delete(f.args)
		}
		delete(p.frames)
	}

	if len(src) == 0 || src[0] != '$' {
		destroy_program(prog)
		return nil, {.Syntax, 0, "expected '$' at start of JSONPath query"}
	}

	root_q, perr := parse_root(&p)
	if perr.kind != .None {
		destroy_program(prog)
		return nil, perr
	}
	if p.i != len(src) {
		off := p.i
		destroy_program(prog)
		return nil, {.Syntax, off, "unexpected trailing characters after JSONPath query"}
	}
	prog.root = root_q
	if plan_err := build_plan(prog); plan_err != nil {
		destroy_program(prog)
		return nil, {.Memory, 0, "out of memory building query plan"}
	}
	return prog, {}
}

@(private = "file")
Frame_Kind :: enum u8 {
	Query,
	Bracket,
	Or_Expr,
	And_Expr,
	Basic_Expr,
	Comparable,
	Func_Call,
}

@(private = "file")
Parse_Frame :: struct {
	kind:             Frame_Kind,
	stage:            u8,
	allow_bare_value: bool,
	negated:          bool,
	has_space:        bool,
	seg_kind:         Segment_Kind,
	query_kind:       Query_Kind,
	cmp_op:           Compare_Op,
	func_kind:        Func_Kind,
	func_offset:      int,
	lhs:              ^Expr,
	segs:             [dynamic]Segment,
	sels:             [dynamic]Selector,
	args:             [dynamic]^Expr,
}

@(private = "file")
Parser :: struct {
	src:          string,
	i:            int,
	prog:         ^Program,
	arena:        runtime.Allocator,
	scratch:      runtime.Allocator,
	max_depth:    int,
	frames:       [dynamic]Parse_Frame,
	result_query: Query,
	result_seg:   Segment,
	result_expr:  ^Expr,
	err:          Compile_Error,
}

@(private = "file")
fail :: proc(p: ^Parser, kind: Error_Kind, offset: int, msg: string) -> bool {
	if p.err.kind == .None {
		p.err = {kind = kind, offset = offset, message = msg}
	}
	return false
}

@(private = "file")
push_frame :: proc(p: ^Parser, f: Parse_Frame) -> bool {
	if len(p.frames) >= p.max_depth {
		return fail(p, .Depth, p.i, "JSONPath expression exceeds maximum nesting depth")
	}
	if _, err := append(&p.frames, f); err != nil {
		return fail(p, .Memory, p.i, "out of memory growing parser stack")
	}
	return true
}

@(private = "file")
pop_frame :: proc(p: ^Parser) {
	f := &p.frames[len(p.frames) - 1]
	delete(f.segs)
	delete(f.sels)
	delete(f.args)
	pop(&p.frames)
}

@(private = "file")
alloc_expr :: proc(p: ^Parser, e: Expr) -> ^Expr {
	ptr, err := new_clone(e, p.arena)
	if err != nil {
		fail(p, .Memory, p.i, "out of memory allocating AST expression")
		return nil
	}
	return ptr
}

// RFC 9535 §2.1 blank space: ONLY SP (0x20), HTAB (0x09), LF (0x0A), CR (0x0D).
@(private = "file")
is_blank :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

@(private = "file")
skip_s :: #force_inline proc "contextless" (p: ^Parser) -> bool {
	start := p.i
	for p.i < len(p.src) && is_blank(p.src[p.i]) {
		p.i += 1
	}
	return p.i > start
}

@(private = "file")
parse_root :: proc(p: ^Parser) -> (Query, Compile_Error) {
	frames, ferr := make([dynamic]Parse_Frame, 0, 16, p.scratch)
	if ferr != nil {
		return {}, {.Memory, 0, "out of memory allocating parser stack"}
	}
	p.frames = frames
	if !push_frame(p, {kind = .Query, query_kind = .Root}) {
		return {}, p.err
	}
	// Consume leading `$`.
	p.i += 1

	for len(p.frames) > 0 && p.err.kind == .None {
		f := &p.frames[len(p.frames) - 1]
		switch f.kind {
		case .Query:
			step_query(p, f)
		case .Bracket:
			step_bracket(p, f)
		case .Or_Expr:
			step_or_expr(p, f)
		case .And_Expr:
			step_and_expr(p, f)
		case .Basic_Expr:
			step_basic_expr(p, f)
		case .Comparable:
			step_comparable(p, f)
		case .Func_Call:
			step_func_call(p, f)
		}
	}
	if p.err.kind != .None {
		return {}, p.err
	}
	return p.result_query, {}
}

// ---- Query & Segment Parsing ----

@(private = "file")
step_query :: proc(p: ^Parser, f: ^Parse_Frame) {
	if f.stage == 1 {
		// Returned from `.Bracket` child frame.
		if _, err := append(&f.segs, p.result_seg); err != nil {
			fail(p, .Memory, p.i, "out of memory appending segment")
			return
		}
		f.stage = 0
	}

	for {
		saved := p.i
		skip_s(p)
		if p.i >= len(p.src) {
			p.i = saved
			break
		}
		c := p.src[p.i]
		if c == '[' {
			p.i += 1
			f.stage = 1
			push_frame(p, {kind = .Bracket, seg_kind = .Child})
			return
		}
		if c != '.' {
			p.i = saved
			break
		}
		// Child `.` or Descendant `..`.
		if p.i + 1 < len(p.src) && p.src[p.i + 1] == '.' {
			p.i += 2
			if p.i >= len(p.src) {
				fail(p, .Syntax, p.i, "unexpected end of query after '..'")
				return
			}
			nc := p.src[p.i]
			if nc == '[' {
				p.i += 1
				f.stage = 1
				push_frame(p, {kind = .Bracket, seg_kind = .Descendant})
				return
			}
			if nc == '*' {
				p.i += 1
				sels, err := make([]Selector, 1, p.arena)
				if err != nil {
					fail(p, .Memory, p.i, "out of memory allocating selector")
					return
				}
				sels[0] = {kind = .Wildcard}
				if _, aerr := append(&f.segs, Segment{kind = .Descendant, selectors = sels}); aerr != nil {
					fail(p, .Memory, p.i, "out of memory appending segment")
					return
				}
				continue
			}
			name, ok := parse_member_shorthand(p)
			if !ok {
				return
			}
			sels, err := make([]Selector, 1, p.arena)
			if err != nil {
				fail(p, .Memory, p.i, "out of memory allocating selector")
				return
			}
			sels[0] = {kind = .Name, name = name}
			if _, aerr := append(&f.segs, Segment{kind = .Descendant, selectors = sels, shorthand = true}); aerr != nil {
				fail(p, .Memory, p.i, "out of memory appending segment")
				return
			}
			continue
		}
		// Child `.` followed immediately by `*` or `member-name-shorthand` (no S allowed).
		p.i += 1
		if p.i >= len(p.src) {
			fail(p, .Syntax, p.i, "unexpected end of query after '.'")
			return
		}
		if p.src[p.i] == '*' {
			p.i += 1
			sels, err := make([]Selector, 1, p.arena)
			if err != nil {
				fail(p, .Memory, p.i, "out of memory allocating selector")
				return
			}
			sels[0] = {kind = .Wildcard}
			if _, aerr := append(&f.segs, Segment{kind = .Child, selectors = sels}); aerr != nil {
				fail(p, .Memory, p.i, "out of memory appending segment")
				return
			}
			continue
		}
		name, ok := parse_member_shorthand(p)
		if !ok {
			return
		}
		sels, err := make([]Selector, 1, p.arena)
		if err != nil {
			fail(p, .Memory, p.i, "out of memory allocating selector")
			return
		}
		sels[0] = {kind = .Name, name = name}
		if _, aerr := append(&f.segs, Segment{kind = .Child, selectors = sels, shorthand = true}); aerr != nil {
			fail(p, .Memory, p.i, "out of memory appending segment")
			return
		}
	}

	segs_out, cerr := slice.clone(f.segs[:], p.arena)
	if cerr != nil {
		fail(p, .Memory, p.i, "out of memory cloning segments")
		return
	}
	is_sing := true
	for seg in segs_out {
		if seg.kind != .Child || len(seg.selectors) != 1 || seg.has_bracket_space {
			is_sing = false
			break
		}
		sk := seg.selectors[0].kind
		if sk != .Name && sk != .Index {
			is_sing = false
			break
		}
	}
	p.result_query = Query{
		kind        = f.query_kind,
		segments    = segs_out,
		is_singular = is_sing,
	}
	pop_frame(p)
}

@(private = "file")
step_bracket :: proc(p: ^Parser, f: ^Parse_Frame) {
	if f.stage == 1 {
		// Returned from `.Or_Expr` for a `?filter` selector.
		if _, err := append(&f.sels, Selector{kind = .Filter, filter = p.result_expr}); err != nil {
			fail(p, .Memory, p.i, "out of memory appending filter selector")
			return
		}
		f.stage = 2
	}

	for {
		if f.stage == 0 {
			if skip_s(p) {
				f.has_space = true
			}
			if p.i >= len(p.src) {
				fail(p, .Syntax, p.i, "unclosed '[' in bracketed selection")
				return
			}
			c := p.src[p.i]
			switch c {
			case ']':
				if len(f.sels) == 0 {
					fail(p, .Syntax, p.i, "empty bracketed selection '[]' is not allowed")
					return
				}
				fail(p, .Syntax, p.i, "trailing comma before ']' in bracketed selection")
				return
			case '\'', '"':
				str_val, ok := parse_string_literal(p)
				if !ok {
					return
				}
				if _, err := append(&f.sels, Selector{kind = .Name, name = str_val}); err != nil {
					fail(p, .Memory, p.i, "out of memory appending name selector")
					return
				}
				f.stage = 2
			case '*':
				p.i += 1
				if _, err := append(&f.sels, Selector{kind = .Wildcard}); err != nil {
					fail(p, .Memory, p.i, "out of memory appending wildcard selector")
					return
				}
				f.stage = 2
			case '?':
				p.i += 1
				skip_s(p)
				f.stage = 1
				push_frame(p, {kind = .Or_Expr, allow_bare_value = false})
				return
			case ':', '-', '0' ..= '9':
				sel, ok := parse_index_or_slice(p)
				if !ok {
					return
				}
				if _, err := append(&f.sels, sel); err != nil {
					fail(p, .Memory, p.i, "out of memory appending index/slice selector")
					return
				}
				f.stage = 2
			case:
				fail(p, .Syntax, p.i, "expected selector inside '['")
				return
			}
		}

		// f.stage == 2: after a selector, expect optional S then `,` or `]`.
		if skip_s(p) {
			f.has_space = true
		}
		if p.i >= len(p.src) {
			fail(p, .Syntax, p.i, "unclosed '[' in bracketed selection")
			return
		}
		if p.src[p.i] == ',' {
			p.i += 1
			f.stage = 0
			continue
		}
		if p.src[p.i] == ']' {
			p.i += 1
			sels_out, cerr := slice.clone(f.sels[:], p.arena)
			if cerr != nil {
				fail(p, .Memory, p.i, "out of memory cloning selectors")
				return
			}
			p.result_seg = Segment{
				kind              = f.seg_kind,
				selectors         = sels_out,
				has_bracket_space = f.has_space,
			}
			pop_frame(p)
			return
		}
		fail(p, .Syntax, p.i, "expected ',' or ']' after selector")
		return
	}
}

// ---- Filter Expression Parsing ----

@(private = "file")
step_logical_expr :: proc(p: ^Parser, f: ^Parse_Frame, $child: Frame_Kind, $op_ch: u8, $kind: Expr_Kind, $err_msg: string) {
	switch f.stage {
	case 0:
		f.stage = 1
		push_frame(p, {kind = child, allow_bare_value = f.allow_bare_value})
	case 1:
		f.lhs = p.result_expr
		saved := p.i
		skip_s(p)
		if p.i + 1 < len(p.src) && p.src[p.i] == op_ch && p.src[p.i + 1] == op_ch {
			if !is_logical_or_nodes(f.lhs) {
				fail(p, .Type, saved, err_msg)
				return
			}
			p.i += 2
			skip_s(p)
			f.stage = 2
			push_frame(p, {kind = child, allow_bare_value = false})
			return
		}
		p.i = saved
		p.result_expr = f.lhs
		pop_frame(p)
	case 2:
		rhs := p.result_expr
		node := alloc_expr(p, {kind = kind, type = .Logical, a = f.lhs, b = rhs})
		if node == nil {
			return
		}
		f.lhs = node
		saved := p.i
		skip_s(p)
		if p.i + 1 < len(p.src) && p.src[p.i] == op_ch && p.src[p.i + 1] == op_ch {
			p.i += 2
			skip_s(p)
			push_frame(p, {kind = child, allow_bare_value = false})
			return
		}
		p.i = saved
		p.result_expr = f.lhs
		pop_frame(p)
	}
}

@(private = "file")
step_or_expr :: proc(p: ^Parser, f: ^Parse_Frame) {
	step_logical_expr(p, f, .And_Expr, '|', .Or, "ValueType expression cannot be operand of '||'")
}

@(private = "file")
step_and_expr :: proc(p: ^Parser, f: ^Parse_Frame) {
	step_logical_expr(p, f, .Basic_Expr, '&', .And, "ValueType expression cannot be operand of '&&'")
}

@(private = "file")
is_logical_or_nodes :: #force_inline proc "contextless" (e: ^Expr) -> bool {
	return e != nil && (e.type == .Logical || e.type == .Nodes)
}

@(private = "file")
step_basic_expr :: proc(p: ^Parser, f: ^Parse_Frame) {
	switch f.stage {
	case 0:
		if p.i >= len(p.src) {
			fail(p, .Syntax, p.i, "unexpected end of filter expression")
			return
		}
		c := p.src[p.i]
		if c == '!' {
			p.i += 1
			skip_s(p)
			f.negated = true
			if p.i >= len(p.src) {
				fail(p, .Syntax, p.i, "unexpected end of filter expression after '!'")
				return
			}
			nc := p.src[p.i]
			if nc == '(' {
				p.i += 1
				skip_s(p)
				f.stage = 10
				push_frame(p, {kind = .Or_Expr, allow_bare_value = false})
				return
			}
			if nc == '$' || nc == '@' {
				qkind := Query_Kind.Root if nc == '$' else Query_Kind.Relative
				p.i += 1
				f.stage = 11
				push_frame(p, {kind = .Query, query_kind = qkind})
				return
			}
			if nc >= 'a' && nc <= 'z' && !starts_bare_keyword_literal(p) {
				f.stage = 12
				push_frame(p, {kind = .Func_Call})
				return
			}
			fail(p, .Syntax, p.i, "expected '(', query, or function call after '!'")
			return
		}
		if c == '(' {
			p.i += 1
			skip_s(p)
			f.stage = 10
			push_frame(p, {kind = .Or_Expr, allow_bare_value = false})
			return
		}
		if c == '$' || c == '@' {
			qkind := Query_Kind.Root if c == '$' else Query_Kind.Relative
			p.i += 1
			f.stage = 20
			push_frame(p, {kind = .Query, query_kind = qkind})
			return
		}
		if starts_literal(p) {
			lit_off := p.i
			lit_val, ok := parse_literal(p)
			if !ok {
				return
			}
			lit_node := alloc_expr(p, {kind = .Literal, type = .Value, literal = lit_val})
			if lit_node == nil {
				return
			}
			saved := p.i
			skip_s(p)
			if op, has_op := peek_and_consume_cmp(p); has_op {
				skip_s(p)
				f.lhs = lit_node
				f.cmp_op = op
				f.stage = 30
				push_frame(p, {kind = .Comparable})
				return
			}
			p.i = saved
			if f.allow_bare_value {
				p.result_expr = lit_node
				pop_frame(p)
				return
			}
			fail(p, .Syntax, lit_off, "literal cannot be used as a test expression without comparison")
			return
		}
		if c >= 'a' && c <= 'z' {
			f.stage = 21
			push_frame(p, {kind = .Func_Call})
			return
		}
		fail(p, .Syntax, p.i, "unexpected token in filter expression")

	case 10:
		// Returned from `(` logical-expr `)`.
		inner := p.result_expr
		skip_s(p)
		if p.i >= len(p.src) || p.src[p.i] != ')' {
			fail(p, .Syntax, p.i, "expected ')' to close parenthesized expression")
			return
		}
		p.i += 1
		node := alloc_expr(p, {kind = .Paren, type = .Logical, a = inner})
		if node == nil {
			return
		}
		if f.negated {
			node = alloc_expr(p, {kind = .Not, type = .Logical, a = node})
			if node == nil {
				return
			}
		}
		p.result_expr = node
		pop_frame(p)

	case 11:
		// Returned from `!` filter-query.
		qnode := alloc_expr(p, {kind = .Query, type = .Nodes, query = p.result_query})
		if qnode == nil {
			return
		}
		node := alloc_expr(p, {kind = .Not, type = .Logical, a = qnode})
		if node == nil {
			return
		}
		p.result_expr = node
		pop_frame(p)

	case 12:
		// Returned from `!` function-expr.
		fn := p.result_expr
		if fn.type == .Value {
			fail(p, .Type, p.i, "ValueType function cannot be negated as a test expression")
			return
		}
		node := alloc_expr(p, {kind = .Not, type = .Logical, a = fn})
		if node == nil {
			return
		}
		p.result_expr = node
		pop_frame(p)

	case 20:
		// Returned from `$` or `@` query; check if followed by comparison-op.
		q := p.result_query
		qnode := alloc_expr(p, {kind = .Query, type = .Nodes, query = q})
		if qnode == nil {
			return
		}
		saved := p.i
		skip_s(p)
		if op, has_op := peek_and_consume_cmp(p); has_op {
			if !q.is_singular {
				fail(p, .Type, saved, "non-singular query is not allowed in comparison")
				return
			}
			skip_s(p)
			f.lhs = qnode
			f.cmp_op = op
			f.stage = 30
			push_frame(p, {kind = .Comparable})
			return
		}
		p.i = saved
		p.result_expr = qnode
		pop_frame(p)

	case 21:
		// Returned from function-expr; check if followed by comparison-op.
		fn := p.result_expr
		saved := p.i
		skip_s(p)
		if op, has_op := peek_and_consume_cmp(p); has_op {
			if fn.type != .Value {
				fail(p, .Type, saved, "function in comparison must return ValueType")
				return
			}
			skip_s(p)
			f.lhs = fn
			f.cmp_op = op
			f.stage = 30
			push_frame(p, {kind = .Comparable})
			return
		}
		p.i = saved
		if !f.allow_bare_value && fn.type == .Value {
			fail(p, .Type, saved, "ValueType function cannot be used as a test expression")
			return
		}
		p.result_expr = fn
		pop_frame(p)

	case 30:
		// Returned from RHS `.Comparable`.
		rhs := p.result_expr
		node := alloc_expr(p, {kind = .Compare, type = .Logical, op = f.cmp_op, a = f.lhs, b = rhs})
		if node == nil {
			return
		}
		p.result_expr = node
		pop_frame(p)
	}
}

@(private = "file")
step_comparable :: proc(p: ^Parser, f: ^Parse_Frame) {
	switch f.stage {
	case 0:
		if p.i >= len(p.src) {
			fail(p, .Syntax, p.i, "expected comparable expression after comparison operator")
			return
		}
		c := p.src[p.i]
		if c == '$' || c == '@' {
			qkind := Query_Kind.Root if c == '$' else Query_Kind.Relative
			p.i += 1
			f.stage = 1
			push_frame(p, {kind = .Query, query_kind = qkind})
			return
		}
		if starts_literal(p) {
			lit_val, ok := parse_literal(p)
			if !ok {
				return
			}
			node := alloc_expr(p, {kind = .Literal, type = .Value, literal = lit_val})
			if node == nil {
				return
			}
			p.result_expr = node
			pop_frame(p)
			return
		}
		if c >= 'a' && c <= 'z' {
			f.stage = 2
			push_frame(p, {kind = .Func_Call})
			return
		}
		fail(p, .Syntax, p.i, "expected literal, singular query, or ValueType function in comparison")
	case 1:
		q := p.result_query
		if !q.is_singular {
			fail(p, .Type, p.i, "non-singular query is not allowed in comparison")
			return
		}
		node := alloc_expr(p, {kind = .Query, type = .Nodes, query = q})
		if node == nil {
			return
		}
		p.result_expr = node
		pop_frame(p)
	case 2:
		fn := p.result_expr
		if fn.type != .Value {
			fail(p, .Type, p.i, "function in comparison must return ValueType")
			return
		}
		p.result_expr = fn
		pop_frame(p)
	}
}

// ---- Function Call Parsing & RFC 9535 §2.4 Type Checking ----

@(private = "file")
Func_Sig :: struct {
	kind:       Func_Kind,
	ret:        Expr_Type,
	arity:      int,
	param_type: [2]Expr_Type,
}

@(private = "file", rodata)
FUNC_SIGS := [Func_Kind]Func_Sig {
	.Length = {.Length, .Value, 1, {.Value, .Value}},
	.Count  = {.Count, .Value, 1, {.Nodes, .Nodes}},
	.Match  = {.Match, .Logical, 2, {.Value, .Value}},
	.Search = {.Search, .Logical, 2, {.Value, .Value}},
	.Value  = {.Value, .Value, 1, {.Nodes, .Nodes}},
}

@(private = "file")
lookup_func :: proc "contextless" (name: string) -> (sig: Func_Sig, ok: bool) {
	switch name {
	case "length":
		return FUNC_SIGS[.Length], true
	case "count":
		return FUNC_SIGS[.Count], true
	case "match":
		return FUNC_SIGS[.Match], true
	case "search":
		return FUNC_SIGS[.Search], true
	case "value":
		return FUNC_SIGS[.Value], true
	}
	return {}, false
}

@(private = "file")
is_func_name_char :: #force_inline proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
}

@(private = "file")
step_func_call :: proc(p: ^Parser, f: ^Parse_Frame) {
	if f.stage == 0 {
		f.func_offset = p.i
		start := p.i
		if start >= len(p.src) || !(p.src[start] >= 'a' && p.src[start] <= 'z') {
			fail(p, .Syntax, start, "expected lowercase function name")
			return
		}
		p.i += 1
		for p.i < len(p.src) && is_func_name_char(p.src[p.i]) {
			p.i += 1
		}
		name := p.src[start:p.i]
		// RFC 9535 §2.4: NO whitespace allowed between function-name and `(`.
		if p.i >= len(p.src) || p.src[p.i] != '(' {
			fail(p, .Syntax, p.i, "expected '(' immediately after function name")
			return
		}
		p.i += 1
		sig, found := lookup_func(name)
		if !found {
			fail(p, .Type, start, "unknown JSONPath function extension")
			return
		}
		f.func_kind = sig.kind
		skip_s(p)
		if p.i < len(p.src) && p.src[p.i] == ')' {
			p.i += 1
			finish_func_call(p, f)
			return
		}
		f.stage = 1
		push_frame(p, {kind = .Or_Expr, allow_bare_value = true})
		return
	}

	// f.stage == 1: returned from argument `.Or_Expr`.
	if _, err := append(&f.args, p.result_expr); err != nil {
		fail(p, .Memory, p.i, "out of memory appending function argument")
		return
	}
	skip_s(p)
	if p.i >= len(p.src) {
		fail(p, .Syntax, p.i, "unclosed '(' in function call")
		return
	}
	if p.src[p.i] == ',' {
		p.i += 1
		skip_s(p)
		push_frame(p, {kind = .Or_Expr, allow_bare_value = true})
		return
	}
	if p.src[p.i] == ')' {
		p.i += 1
		finish_func_call(p, f)
		return
	}
	fail(p, .Syntax, p.i, "expected ',' or ')' after function argument")
}

@(private = "file")
finish_func_call :: proc(p: ^Parser, f: ^Parse_Frame) {
	sig := FUNC_SIGS[f.func_kind]
	if len(f.args) != sig.arity {
		fail(p, .Type, f.func_offset, "wrong number of arguments to JSONPath function")
		return
	}
	for arg, idx in f.args {
		if !arg_matches_param(arg, sig.param_type[idx]) {
			fail(p, .Type, f.func_offset, "argument type does not match RFC 9535 function parameter type")
			return
		}
	}
	args_out, cerr := slice.clone(f.args[:], p.arena)
	if cerr != nil {
		fail(p, .Memory, p.i, "out of memory cloning function arguments")
		return
	}
	node := alloc_expr(p, {
		kind = .Func,
		type = sig.ret,
		func = sig.kind,
		args = args_out,
	})
	if node == nil {
		return
	}
	// Precompile static literal I-Regexp patterns for `match` / `search`.
	if (sig.kind == .Match || sig.kind == .Search) && args_out[1].kind == .Literal {
		if query.type_of(args_out[1].literal) == .String {
			pat := query.text_of(args_out[1].literal)
			re, state, oom := compile_iregexp(pat, anchored = sig.kind == .Match, allocator = p.arena, scratch = p.scratch)
			if oom {
				fail(p, .Memory, f.func_offset, "out of memory compiling I-Regexp literal")
				return
			}
			node.pat_state = state
			node.compiled_re = re
		} else {
			node.pat_state = .Invalid
		}
	}
	p.result_expr = node
	pop_frame(p)
}

// RFC 9535 §2.4.3 well-typedness of `arg` against parameter type `want`.
@(private = "file")
arg_matches_param :: proc "contextless" (arg: ^Expr, want: Expr_Type) -> bool {
	switch want {
	case .Value:
		switch arg.kind {
		case .Literal:
			return true
		case .Query:
			return arg.query.is_singular
		case .Func:
			return arg.type == .Value
		case .Or, .And, .Not, .Paren, .Compare:
			return false
		}
	case .Nodes:
		switch arg.kind {
		case .Query:
			return true
		case .Func:
			return arg.type == .Nodes
		case .Literal, .Or, .And, .Not, .Paren, .Compare:
			return false
		}
	case .Logical:
		switch arg.kind {
		case .Or, .And, .Not, .Paren, .Compare, .Query:
			return true
		case .Func:
			return arg.type == .Logical || arg.type == .Nodes
		case .Literal:
			return false
		}
	}
	return false
}

// ---- Lexical Helpers ----

@(private = "file")
peek_and_consume_cmp :: proc(p: ^Parser) -> (op: Compare_Op, ok: bool) {
	if p.i >= len(p.src) {
		return {}, false
	}
	c := p.src[p.i]
	if p.i + 1 < len(p.src) {
		c2 := p.src[p.i + 1]
		switch {
		case c == '=' && c2 == '=':
			p.i += 2
			return .Eq, true
		case c == '!' && c2 == '=':
			p.i += 2
			return .Ne, true
		case c == '<' && c2 == '=':
			p.i += 2
			return .Le, true
		case c == '>' && c2 == '=':
			p.i += 2
			return .Ge, true
		}
	}
	switch c {
	case '<':
		p.i += 1
		return .Lt, true
	case '>':
		p.i += 1
		return .Gt, true
	}
	return {}, false
}

@(private = "file")
starts_bare_keyword_literal :: proc "contextless" (p: ^Parser) -> bool {
	s := p.src[p.i:]
	kw_len := 0
	switch {
	case len(s) >= 4 && s[:4] == "true":
		kw_len = 4
	case len(s) >= 5 && s[:5] == "false":
		kw_len = 5
	case len(s) >= 4 && s[:4] == "null":
		kw_len = 4
	case:
		return false
	}
	if kw_len < len(s) {
		next := s[kw_len]
		if is_func_name_char(next) || next == '(' {
			return false
		}
	}
	return true
}

@(private = "file")
starts_literal :: proc "contextless" (p: ^Parser) -> bool {
	if p.i >= len(p.src) {
		return false
	}
	c := p.src[p.i]
	if c == '"' || c == '\'' || c == '-' || (c >= '0' && c <= '9') {
		return true
	}
	return starts_bare_keyword_literal(p)
}

@(private = "file")
parse_literal :: proc(p: ^Parser) -> (val: query.Value, ok: bool) {
	c := p.src[p.i]
	if c == '"' || c == '\'' {
		s, sok := parse_string_literal(p)
		if !sok {
			return {}, false
		}
		// `s` lives in `prog.arena` and outlives all runs.
		return query.text_borrowed(s), true
	}
	if c == '-' || (c >= '0' && c <= '9') {
		return parse_filter_number(p)
	}
	s := p.src[p.i:]
	switch {
	case strings.has_prefix(s, "true"):
		p.i += 4
		return query.TRUE, true
	case strings.has_prefix(s, "false"):
		p.i += 5
		return query.FALSE, true
	case strings.has_prefix(s, "null"):
		p.i += 4
		return query.NULL, true
	}
	fail(p, .Syntax, p.i, "invalid literal")
	return {}, false
}

// RFC 9535 §2.3.5.1 `number = (int / "-0") [ frac ] [ exp ]`.
@(private = "file")
parse_filter_number :: proc(p: ^Parser) -> (val: query.Value, ok: bool) {
	start := p.i
	n := len(p.src)
	if p.i < n && p.src[p.i] == '-' {
		p.i += 1
	}
	if p.i >= n {
		fail(p, .Syntax, start, "invalid number literal")
		return {}, false
	}
	if p.src[p.i] == '0' {
		p.i += 1
		if p.i < n && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
			fail(p, .Syntax, start, "leading zeros are not allowed in number literal")
			return {}, false
		}
	} else if p.src[p.i] >= '1' && p.src[p.i] <= '9' {
		for p.i < n && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
			p.i += 1
		}
	} else {
		fail(p, .Syntax, start, "expected digit in number literal")
		return {}, false
	}
	if p.i < n && p.src[p.i] == '.' {
		p.i += 1
		frac_start := p.i
		for p.i < n && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
			p.i += 1
		}
		if p.i == frac_start {
			fail(p, .Syntax, p.i, "expected digit after decimal point in number literal")
			return {}, false
		}
	}
	if p.i < n && (p.src[p.i] == 'e' || p.src[p.i] == 'E') {
		p.i += 1
		if p.i < n && (p.src[p.i] == '+' || p.src[p.i] == '-') {
			p.i += 1
		}
		exp_start := p.i
		for p.i < n && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
			p.i += 1
		}
		if p.i == exp_start {
			fail(p, .Syntax, p.i, "expected digit in number exponent")
			return {}, false
		}
	}
	text := p.src[start:p.i]
	if !p.prog.has_heap {
		// Arena-backed heap so frozen `.Big` digit slices are reclaimed by `mem.dynamic_arena_destroy`.
		query.heap_init(&p.prog.const_heap, p.prog.allocator)
		p.prog.has_heap = true
	}
	num, good, st := query.parse_number(&p.prog.const_heap, text, loose = false)
	if st != .Ok {
		fail(p, .Memory, start, "out of memory parsing number literal")
		return {}, false
	}
	if !good {
		fail(p, .Syntax, start, "invalid number literal")
		return {}, false
	}
	return query.freeze(num), true
}

// RFC 9535 §2.5.1.1 `member-name-shorthand = name-first *name-char`.
// `name-first = ALPHA / "_" / %x80-D7FF / %xE000-10FFFF`
// `name-char  = name-first / DIGIT`
@(private = "file")
parse_member_shorthand :: proc(p: ^Parser) -> (name: string, ok: bool) {
	start := p.i
	n := len(p.src)
	if start >= n {
		fail(p, .Syntax, start, "expected member name")
		return "", false
	}
	first := true
	for p.i < n {
		c := p.src[p.i]
		if c < 0x80 {
			is_alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
			is_digit := c >= '0' && c <= '9'
			if is_alpha || (!first && is_digit) {
				p.i += 1
				first = false
				continue
			}
			break
		}
		r, w := decode_strict_utf8(p.src[p.i:])
		if w == 0 || !is_scalar_value(r) {
			fail(p, .Syntax, p.i, "invalid UTF-8 in member name shorthand")
			return "", false
		}
		p.i += w
		first = false
	}
	if p.i == start {
		fail(p, .Syntax, start, "expected member name shorthand")
		return "", false
	}
	cloned, cerr := strings.clone(p.src[start:p.i], p.arena)
	if cerr != nil {
		fail(p, .Memory, start, "out of memory cloning member name")
		return "", false
	}
	return cloned, true
}

// RFC 9535 §2.3.1.1 string-literal (`'...'` or `"..."`) with strict quote-specific escapes and UTF-16 surrogates.
@(private = "file")
parse_string_literal :: proc(p: ^Parser) -> (out: string, ok: bool) {
	start := p.i
	quote := p.src[p.i]
	p.i += 1
	n := len(p.src)

	b: strings.Builder
	strings.builder_init_len_cap(&b, 0, 32, p.scratch)
	defer strings.builder_destroy(&b)

	for p.i < n {
		c := p.src[p.i]
		if c == quote {
			p.i += 1
			cloned, cerr := strings.clone(strings.to_string(b), p.arena)
			if cerr != nil {
				fail(p, .Memory, start, "out of memory cloning string literal")
				return "", false
			}
			return cloned, true
		}
		if c < 0x20 {
			fail(p, .Syntax, p.i, "unescaped control character in string literal")
			return "", false
		}
		if c == '\\' {
			esc_off := p.i
			p.i += 1
			if p.i >= n {
				fail(p, .Syntax, esc_off, "unterminated escape sequence in string literal")
				return "", false
			}
			ec := p.src[p.i]
			p.i += 1
			switch ec {
			case 'b':
				strings.write_byte(&b, '\b')
			case 'f':
				strings.write_byte(&b, '\f')
			case 'n':
				strings.write_byte(&b, '\n')
			case 'r':
				strings.write_byte(&b, '\r')
			case 't':
				strings.write_byte(&b, '\t')
			case '/':
				strings.write_byte(&b, '/')
			case '\\':
				strings.write_byte(&b, '\\')
			case '"':
				// RFC 9535 §2.3.1.1: `\"` is valid ONLY inside double-quoted strings.
				if quote != '"' {
					fail(p, .Syntax, esc_off, "'\\\"' escape is not allowed in single-quoted string")
					return "", false
				}
				strings.write_byte(&b, '"')
			case '\'':
				// RFC 9535 §2.3.1.1: `\'` is valid ONLY inside single-quoted strings.
				if quote != '\'' {
					fail(p, .Syntax, esc_off, "'\\'' escape is not allowed in double-quoted string")
					return "", false
				}
				strings.write_byte(&b, '\'')
			case 'u':
				u1, uok := parse_hex4(p)
				if !uok {
					fail(p, .Syntax, esc_off, "invalid \\uXXXX escape sequence")
					return "", false
				}
				if u1 >= 0xDC00 && u1 <= 0xDFFF {
					fail(p, .Syntax, esc_off, "unexpected lone low surrogate in string literal")
					return "", false
				}
				cp: rune
				if u1 >= 0xD800 && u1 <= 0xDBFF {
					// High surrogate MUST be followed by `\uYYYY` low surrogate.
					if p.i + 6 > n || p.src[p.i] != '\\' || p.src[p.i + 1] != 'u' {
						fail(p, .Syntax, esc_off, "lone high surrogate without matching low surrogate")
						return "", false
					}
					p.i += 2
					u2, u2ok := parse_hex4(p)
					if !u2ok || u2 < 0xDC00 || u2 > 0xDFFF {
						fail(p, .Syntax, esc_off, "invalid low surrogate after high surrogate")
						return "", false
					}
					cp = rune(0x10000 + ((u32(u1) - 0xD800) << 10) + (u32(u2) - 0xDC00))
				} else {
					cp = rune(u1)
				}
				bytes, w := utf8.encode_rune(cp)
				strings.write_bytes(&b, bytes[:w])
			case:
				fail(p, .Syntax, esc_off, "invalid escape sequence in string literal")
				return "", false
			}
			continue
		}
		if c < 0x80 {
			strings.write_byte(&b, c)
			p.i += 1
		} else {
			r, w := decode_strict_utf8(p.src[p.i:])
			if w == 0 || !is_scalar_value(r) {
				fail(p, .Syntax, p.i, "invalid UTF-8 in string literal")
				return "", false
			}
			strings.write_string(&b, p.src[p.i:p.i + w])
			p.i += w
		}
	}
	fail(p, .Syntax, start, "unterminated string literal")
	return "", false
}

@(private = "file")
parse_hex4 :: proc(p: ^Parser) -> (val: u16, ok: bool) {
	if p.i + 4 > len(p.src) {
		return 0, false
	}
	acc: u16
	for k in 0 ..< 4 {
		c := p.src[p.i + k]
		d: u16
		switch c {
		case '0' ..= '9':
			d = u16(c - '0')
		case 'a' ..= 'f':
			d = u16(c - 'a' + 10)
		case 'A' ..= 'F':
			d = u16(c - 'A' + 10)
		case:
			return 0, false
		}
		acc = (acc << 4) | d
	}
	p.i += 4
	return acc, true
}

// RFC 9535 §2.3.3.1 `int = "0" / (["-"] DIGIT1 *DIGIT)`, bounded to [-(2^53)+1, (2^53)-1].
@(private = "file")
parse_safe_int :: proc(p: ^Parser) -> (val: i64, ok: bool) {
	start := p.i
	n := len(p.src)
	neg := false
	if p.i < n && p.src[p.i] == '-' {
		neg = true
		p.i += 1
	}
	if p.i >= n {
		fail(p, .Syntax, start, "expected integer")
		return 0, false
	}
	if p.src[p.i] == '0' {
		if neg {
			fail(p, .Syntax, start, "-0 is not allowed in index or slice selector")
			return 0, false
		}
		p.i += 1
		if p.i < n && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
			fail(p, .Syntax, start, "leading zeros are not allowed in integer")
			return 0, false
		}
		return 0, true
	}
	if p.src[p.i] < '1' || p.src[p.i] > '9' {
		fail(p, .Syntax, start, "expected integer digit")
		return 0, false
	}
	acc: i64
	for p.i < n && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
		d := i64(p.src[p.i] - '0')
		if acc > (MAX_SAFE_INT - d) / 10 {
			fail(p, .Syntax, start, "integer out of RFC 9535 safe range [-(2^53)+1, (2^53)-1]")
			return 0, false
		}
		acc = acc * 10 + d
		p.i += 1
	}
	return -acc if neg else acc, true
}

// Parses either an `index-selector` or `slice-selector = [start S] ":" S [end S] [":" [S step]]`.
@(private = "file")
parse_index_or_slice :: proc(p: ^Parser) -> (sel: Selector, ok: bool) {
	has_start := false
	start_val: i64
	if p.src[p.i] != ':' {
		start_val = parse_safe_int(p) or_return
		has_start = true
		saved := p.i
		skip_s(p)
		if p.i >= len(p.src) || p.src[p.i] != ':' {
			p.i = saved
			return Selector{kind = .Index, index = start_val}, true
		}
	}
	// Consume first ':'.
	p.i += 1
	skip_s(p)

	has_end := false
	end_val: i64
	if p.i < len(p.src) && (p.src[p.i] == '-' || (p.src[p.i] >= '0' && p.src[p.i] <= '9')) {
		end_val = parse_safe_int(p) or_return
		has_end = true
		skip_s(p)
	}

	has_step := false
	step_val := i64(1)
	if p.i < len(p.src) && p.src[p.i] == ':' {
		p.i += 1
		skip_s(p)
		if p.i < len(p.src) && (p.src[p.i] == '-' || (p.src[p.i] >= '0' && p.src[p.i] <= '9')) {
			step_val = parse_safe_int(p) or_return
			has_step = true
		}
	}

	return Selector{
		kind      = .Slice,
		start     = start_val,
		end       = end_val,
		step      = step_val,
		has_start = has_start,
		has_end   = has_end,
		has_step  = has_step,
	}, true
}
