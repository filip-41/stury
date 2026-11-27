package jsonpath

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "stury:lib/query"

// Strict RFC 9535 lexer, explicit-stack parser (zero native recursion), and §2.4 well-typedness checker.

// Compiles RFC 9535 JSONPath `src` into an immutable `^Program` with precompiled literal I-Regexps and `query.Plan`.
compile :: proc(src: string, opts := Compile_Options{}, allocator := context.allocator) -> (prog: ^Program, err: Compile_Error) {
	alloc_err: runtime.Allocator_Error
	prog, alloc_err = new(Program, allocator)
	if alloc_err != nil {
		return nil, {.Memory, 0, "out of memory allocating program"}
	}
	prog.backing = allocator
	mem.dynamic_arena_init(&prog.arena, allocator, allocator, block_size = 4096, out_band_size = 1024)
	prog.allocator = mem.dynamic_arena_allocator(&prog.arena)

	p := Parser{src = src, prog = prog, arena = prog.allocator, scratch = allocator, max_depth = compile_depth_limit(opts)}
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
	if build_plan(prog) != nil {
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
	p.i += 1
	for len(p.frames) > 0 && p.err.kind == .None {
		f := &p.frames[len(p.frames) - 1]
		switch f.kind {
		case .Query:      step_query(p, f)
		case .Bracket:    step_bracket(p, f)
		case .Or_Expr:    step_logical_expr(p, f, .And_Expr, '|', .Or, "ValueType expression cannot be operand of '||'")
		case .And_Expr:   step_logical_expr(p, f, .Basic_Expr, '&', .And, "ValueType expression cannot be operand of '&&'")
		case .Basic_Expr: step_basic_expr(p, f)
		case .Comparable: step_comparable(p, f)
		case .Func_Call:  step_func_call(p, f)
		}
	}
	if p.err.kind != .None {
		return {}, p.err
	}
	return p.result_query, {}
}

// ---- Query & Segment Parsing ----

@(private = "file")
append_single_seg :: proc(p: ^Parser, f: ^Parse_Frame, seg_kind: Segment_Kind, sel: Selector, shorthand: bool) -> bool {
	sels, err := make([]Selector, 1, p.arena)
	if err != nil {
		return fail(p, .Memory, p.i, "out of memory allocating selector")
	}
	sels[0] = sel
	if _, aerr := append(&f.segs, Segment{kind = seg_kind, selectors = sels, shorthand = shorthand}); aerr != nil {
		return fail(p, .Memory, p.i, "out of memory appending segment")
	}
	return true
}

@(private = "file")
step_query :: proc(p: ^Parser, f: ^Parse_Frame) {
	if f.stage == 1 {
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
		is_desc := p.i + 1 < len(p.src) && p.src[p.i + 1] == '.'
		p.i += 2 if is_desc else 1
		if p.i >= len(p.src) {
			fail(p, .Syntax, p.i, "unexpected end of query after '..'" if is_desc else "unexpected end of query after '.'")
			return
		}
		seg_kind := Segment_Kind.Descendant if is_desc else .Child
		if is_desc && p.src[p.i] == '[' {
			p.i += 1
			f.stage = 1
			push_frame(p, {kind = .Bracket, seg_kind = .Descendant})
			return
		}
		if p.src[p.i] == '*' {
			p.i += 1
			if !append_single_seg(p, f, seg_kind, {kind = .Wildcard}, false) {
				return
			}
			continue
		}
		name, ok := parse_member_shorthand(p)
		if !ok || !append_single_seg(p, f, seg_kind, {kind = .Name, name = name}, true) {
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
		if seg.kind != .Child || len(seg.selectors) != 1 || seg.has_bracket_space ||
		   (seg.selectors[0].kind != .Name && seg.selectors[0].kind != .Index) {
			is_sing = false
			break
		}
	}
	p.result_query = {kind = f.query_kind, segments = segs_out, is_singular = is_sing}
	pop_frame(p)
}

@(private = "file")
append_sel :: proc(p: ^Parser, f: ^Parse_Frame, sel: Selector) -> bool {
	if _, err := append(&f.sels, sel); err != nil {
		return fail(p, .Memory, p.i, "out of memory appending selector")
	}
	f.stage = 2
	return true
}

@(private = "file")
step_bracket :: proc(p: ^Parser, f: ^Parse_Frame) {
	if f.stage == 1 && !append_sel(p, f, {kind = .Filter, filter = p.result_expr}) {
		return
	}
	for {
		if f.stage == 0 {
			f.has_space = skip_s(p) || f.has_space
			if p.i >= len(p.src) {
				fail(p, .Syntax, p.i, "unclosed '[' in bracketed selection")
				return
			}
			switch p.src[p.i] {
			case ']':
				fail(p, .Syntax, p.i, "empty bracketed selection '[]' is not allowed" if len(f.sels) == 0 else "trailing comma before ']' in bracketed selection")
				return
			case '\'', '"':
				s, ok := parse_string_literal(p)
				if !ok || !append_sel(p, f, {kind = .Name, name = s}) {
					return
				}
			case '*':
				p.i += 1
				if !append_sel(p, f, {kind = .Wildcard}) {
					return
				}
			case '?':
				p.i += 1
				skip_s(p)
				f.stage = 1
				push_frame(p, {kind = .Or_Expr, allow_bare_value = false})
				return
			case ':', '-', '0' ..= '9':
				sel, ok := parse_index_or_slice(p)
				if !ok || !append_sel(p, f, sel) {
					return
				}
			case:
				fail(p, .Syntax, p.i, "expected selector inside '['")
				return
			}
		}
		f.has_space = skip_s(p) || f.has_space
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
			p.result_seg = {kind = f.seg_kind, selectors = sels_out, has_bracket_space = f.has_space}
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
	if f.stage == 0 {
		f.stage = 1
		push_frame(p, {kind = child, allow_bare_value = f.allow_bare_value})
		return
	}
	if f.stage == 1 {
		f.lhs = p.result_expr
	} else {
		node := alloc_expr(p, {kind = kind, type = .Logical, a = f.lhs, b = p.result_expr})
		if node == nil {
			return
		}
		f.lhs = node
	}
	saved := p.i
	skip_s(p)
	if p.i + 1 < len(p.src) && p.src[p.i] == op_ch && p.src[p.i + 1] == op_ch {
		if f.stage == 1 && (f.lhs == nil || (f.lhs.type != .Logical && f.lhs.type != .Nodes)) {
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
}

@(private = "file")
try_start_compare :: proc(p: ^Parser, f: ^Parse_Frame, lhs: ^Expr, valid: bool, err_msg: string) -> bool {
	saved := p.i
	skip_s(p)
	if op, has_op := peek_and_consume_cmp(p); has_op {
		if !valid {
			fail(p, .Type, saved, err_msg)
			return true
		}
		skip_s(p)
		f.lhs, f.cmp_op, f.stage = lhs, op, 30
		push_frame(p, {kind = .Comparable})
		return true
	}
	p.i = saved
	return false
}

@(private = "file")
step_basic_expr :: proc(p: ^Parser, f: ^Parse_Frame) {
	switch f.stage {
	case 0:
		if p.i >= len(p.src) {
			fail(p, .Syntax, p.i, "unexpected end of filter expression")
			return
		}
		if p.src[p.i] == '!' {
			p.i += 1
			skip_s(p)
			f.negated = true
			if p.i >= len(p.src) {
				fail(p, .Syntax, p.i, "unexpected end of filter expression after '!'")
				return
			}
		}
		c := p.src[p.i]
		if c == '(' {
			p.i += 1
			skip_s(p)
			f.stage = 10
			push_frame(p, {kind = .Or_Expr, allow_bare_value = false})
			return
		}
		if c == '$' || c == '@' {
			p.i += 1
			f.stage = 11 if f.negated else 20
			push_frame(p, {kind = .Query, query_kind = .Root if c == '$' else .Relative})
			return
		}
		if !f.negated && starts_literal(p) {
			lit_off := p.i
			lit_val, ok := parse_literal(p)
			if !ok {
				return
			}
			lit_node := alloc_expr(p, {kind = .Literal, type = .Value, literal = lit_val})
			if lit_node == nil || try_start_compare(p, f, lit_node, true, "") {
				return
			}
			if f.allow_bare_value {
				p.result_expr = lit_node
				pop_frame(p)
				return
			}
			fail(p, .Syntax, lit_off, "literal cannot be used as a test expression without comparison")
			return
		}
		if c >= 'a' && c <= 'z' && (!f.negated || !starts_bare_keyword_literal(p)) {
			f.stage = 12 if f.negated else 21
			push_frame(p, {kind = .Func_Call})
			return
		}
		fail(p, .Syntax, p.i, "expected '(', query, or function call after '!'" if f.negated else "unexpected token in filter expression")

	case 10:
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

	case 11, 12:
		inner := p.result_expr
		if f.stage == 11 {
			inner = alloc_expr(p, {kind = .Query, type = .Nodes, query = p.result_query})
			if inner == nil {
				return
			}
		} else if inner.type == .Value {
			fail(p, .Type, p.i, "ValueType function cannot be negated as a test expression")
			return
		}
		if node := alloc_expr(p, {kind = .Not, type = .Logical, a = inner}); node != nil {
			p.result_expr = node
			pop_frame(p)
		}

	case 20:
		q := p.result_query
		qnode := alloc_expr(p, {kind = .Query, type = .Nodes, query = q})
		if qnode == nil || try_start_compare(p, f, qnode, q.is_singular, "non-singular query is not allowed in comparison") {
			return
		}
		p.result_expr = qnode
		pop_frame(p)

	case 21:
		fn := p.result_expr
		if try_start_compare(p, f, fn, fn.type == .Value, "function in comparison must return ValueType") {
			return
		}
		if !f.allow_bare_value && fn.type == .Value {
			fail(p, .Type, p.i, "ValueType function cannot be used as a test expression")
			return
		}
		p.result_expr = fn
		pop_frame(p)

	case 30:
		if node := alloc_expr(p, {kind = .Compare, type = .Logical, op = f.cmp_op, a = f.lhs, b = p.result_expr}); node != nil {
			p.result_expr = node
			pop_frame(p)
		}
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
			p.i += 1
			f.stage = 1
			push_frame(p, {kind = .Query, query_kind = .Root if c == '$' else .Relative})
			return
		}
		if starts_literal(p) {
			lit_val, ok := parse_literal(p)
			if !ok {
				return
			}
			if node := alloc_expr(p, {kind = .Literal, type = .Value, literal = lit_val}); node != nil {
				p.result_expr = node
				pop_frame(p)
			}
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
		if node := alloc_expr(p, {kind = .Query, type = .Nodes, query = q}); node != nil {
			p.result_expr = node
			pop_frame(p)
		}
	case 2:
		if p.result_expr.type != .Value {
			fail(p, .Type, p.i, "function in comparison must return ValueType")
			return
		}
		pop_frame(p)
	}
}

// ---- Function Call Parsing & RFC 9535 §2.4 Type Checking ----

@(private = "file")
Func_Sig :: struct {
	name:       string,
	kind:       Func_Kind,
	ret:        Expr_Type,
	arity:      int,
	param_type: [2]Expr_Type,
}

@(private = "file", rodata)
FUNC_SIGS := [Func_Kind]Func_Sig {
	.Length = {"length", .Length, .Value, 1, {.Value, .Value}},
	.Count  = {"count", .Count, .Value, 1, {.Nodes, .Nodes}},
	.Match  = {"match", .Match, .Logical, 2, {.Value, .Value}},
	.Search = {"search", .Search, .Logical, 2, {.Value, .Value}},
	.Value  = {"value", .Value, .Value, 1, {.Nodes, .Nodes}},
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
		for p.i += 1; p.i < len(p.src) && is_func_name_char(p.src[p.i]); p.i += 1 {}
		name := p.src[start:p.i]
		if p.i >= len(p.src) || p.src[p.i] != '(' {
			fail(p, .Syntax, p.i, "expected '(' immediately after function name")
			return
		}
		p.i += 1
		found := false
		for sig in FUNC_SIGS {
			if sig.name == name {
				f.func_kind, found = sig.kind, true
				break
			}
		}
		if !found {
			fail(p, .Type, start, "unknown JSONPath function extension")
			return
		}
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
	node := alloc_expr(p, {kind = .Func, type = sig.ret, func = sig.kind, args = args_out})
	if node == nil {
		return
	}
	if (sig.kind == .Match || sig.kind == .Search) && args_out[1].kind == .Literal {
		if query.type_of(args_out[1].literal) == .String {
			re, state, oom := compile_iregexp(query.text_of(args_out[1].literal), anchored = sig.kind == .Match, allocator = p.arena, scratch = p.scratch)
			if oom {
				fail(p, .Memory, f.func_offset, "out of memory compiling I-Regexp literal")
				return
			}
			node.pat_state, node.compiled_re = state, re
		} else {
			node.pat_state = .Invalid
		}
	}
	p.result_expr = node
	pop_frame(p)
}

@(private = "file")
arg_matches_param :: proc "contextless" (arg: ^Expr, want: Expr_Type) -> bool {
	switch want {
	case .Value:
		return arg.kind == .Literal || (arg.kind == .Query && arg.query.is_singular) || (arg.kind == .Func && arg.type == .Value)
	case .Nodes:
		return arg.kind == .Query || (arg.kind == .Func && arg.type == .Nodes)
	case .Logical:
		return arg.kind != .Literal && (arg.kind != .Func || arg.type == .Logical || arg.type == .Nodes)
	}
	return false
}

// ---- Lexical Helpers ----

@(private = "file")
peek_and_consume_cmp :: proc(p: ^Parser) -> (op: Compare_Op, ok: bool) {
	s := p.src[p.i:]
	OPS := [6]struct { text: string, op: Compare_Op }{{"==", .Eq}, {"!=", .Ne}, {"<=", .Le}, {">=", .Ge}, {"<", .Lt}, {">", .Gt}}
	for entry in OPS {
		if strings.has_prefix(s, entry.text) {
			p.i += len(entry.text)
			return entry.op, true
		}
	}
	return {}, false
}

@(private = "file")
starts_bare_keyword_literal :: proc(p: ^Parser) -> bool {
	s := p.src[p.i:]
	kw_len := 4 if (strings.has_prefix(s, "true") || strings.has_prefix(s, "null")) else (5 if strings.has_prefix(s, "false") else 0)
	return kw_len > 0 && (kw_len == len(s) || (!is_func_name_char(s[kw_len]) && s[kw_len] != '('))
}

@(private = "file")
starts_literal :: proc(p: ^Parser) -> bool {
	if p.i >= len(p.src) {
		return false
	}
	c := p.src[p.i]
	return c == '"' || c == '\'' || c == '-' || (c >= '0' && c <= '9') || starts_bare_keyword_literal(p)
}

@(private = "file")
parse_literal :: proc(p: ^Parser) -> (val: query.Value, ok: bool) {
	c := p.src[p.i]
	if c == '"' || c == '\'' {
		s := parse_string_literal(p) or_return
		return query.text_borrowed(s), true
	}
	if c == '-' || (c >= '0' && c <= '9') {
		return parse_filter_number(p)
	}
	s := p.src[p.i:]
	switch {
	case strings.has_prefix(s, "true"):  p.i += 4; return query.TRUE, true
	case strings.has_prefix(s, "false"): p.i += 5; return query.FALSE, true
	case strings.has_prefix(s, "null"):  p.i += 4; return query.NULL, true
	}
	fail(p, .Syntax, p.i, "invalid literal")
	return {}, false
}

@(private = "file")
parse_filter_number :: proc(p: ^Parser) -> (val: query.Value, ok: bool) {
	start, n := p.i, len(p.src)
	if p.i < n && p.src[p.i] == '-' {
		p.i += 1
	}
	if p.i >= n {
		return {}, fail(p, .Syntax, start, "invalid number literal")
	}
	if p.src[p.i] == '0' {
		p.i += 1
		if p.i < n && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
			return {}, fail(p, .Syntax, start, "leading zeros are not allowed in number literal")
		}
	} else if p.src[p.i] >= '1' && p.src[p.i] <= '9' {
		for p.i < n && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
			p.i += 1
		}
	} else {
		return {}, fail(p, .Syntax, start, "expected digit in number literal")
	}
	if p.i < n && p.src[p.i] == '.' {
		p.i += 1
		fs := p.i
		for p.i < n && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
			p.i += 1
		}
		if p.i == fs {
			return {}, fail(p, .Syntax, p.i, "expected digit after decimal point in number literal")
		}
	}
	if p.i < n && (p.src[p.i] == 'e' || p.src[p.i] == 'E') {
		p.i += 1
		if p.i < n && (p.src[p.i] == '+' || p.src[p.i] == '-') {
			p.i += 1
		}
		es := p.i
		for p.i < n && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
			p.i += 1
		}
		if p.i == es {
			return {}, fail(p, .Syntax, p.i, "expected digit in number exponent")
		}
	}
	if !p.prog.has_heap {
		query.heap_init(&p.prog.const_heap, p.prog.allocator)
		p.prog.has_heap = true
	}
	num, good, st := query.parse_number(&p.prog.const_heap, p.src[start:p.i], loose = false)
	if st != .Ok {
		return {}, fail(p, .Memory, start, "out of memory parsing number literal")
	}
	if !good {
		return {}, fail(p, .Syntax, start, "invalid number literal")
	}
	return query.freeze(num), true
}

@(private = "file")
parse_member_shorthand :: proc(p: ^Parser) -> (name: string, ok: bool) {
	start, n := p.i, len(p.src)
	if start >= n {
		return "", fail(p, .Syntax, start, "expected member name")
	}
	for first := true; p.i < n; first = false {
		c := p.src[p.i]
		if c < 0x80 {
			if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || (!first && c >= '0' && c <= '9') {
				p.i += 1
				continue
			}
			break
		}
		r, w := decode_strict_utf8(p.src[p.i:])
		if w == 0 || !is_scalar_value(r) {
			return "", fail(p, .Syntax, p.i, "invalid UTF-8 in member name shorthand")
		}
		p.i += w
	}
	if p.i == start {
		return "", fail(p, .Syntax, start, "expected member name shorthand")
	}
	cloned, cerr := strings.clone(p.src[start:p.i], p.arena)
	if cerr != nil {
		return "", fail(p, .Memory, start, "out of memory cloning member name")
	}
	return cloned, true
}

@(private = "file")
parse_string_literal :: proc(p: ^Parser) -> (out: string, ok: bool) {
	start, quote, n := p.i, p.src[p.i], len(p.src)
	p.i += 1
	b: strings.Builder
	strings.builder_init_len_cap(&b, 0, 32, p.scratch)
	defer strings.builder_destroy(&b)

	for p.i < n {
		c := p.src[p.i]
		if c == quote {
			p.i += 1
			cloned, cerr := strings.clone(strings.to_string(b), p.arena)
			if cerr != nil {
				return "", fail(p, .Memory, start, "out of memory cloning string literal")
			}
			return cloned, true
		}
		if c < 0x20 {
			return "", fail(p, .Syntax, p.i, "unescaped control character in string literal")
		}
		if c == '\\' {
			esc_off := p.i
			p.i += 1
			if p.i >= n {
				return "", fail(p, .Syntax, esc_off, "unterminated escape sequence in string literal")
			}
			ec := p.src[p.i]
			p.i += 1
			switch ec {
			case 'b':  strings.write_byte(&b, '\b')
			case 'f':  strings.write_byte(&b, '\f')
			case 'n':  strings.write_byte(&b, '\n')
			case 'r':  strings.write_byte(&b, '\r')
			case 't':  strings.write_byte(&b, '\t')
			case '/', '\\': strings.write_byte(&b, ec)
			case '"', '\'':
				if ec != quote {
					return "", fail(p, .Syntax, esc_off, "'\\\"' escape is not allowed in single-quoted string" if ec == '"' else "'\\'' escape is not allowed in double-quoted string")
				}
				strings.write_byte(&b, ec)
			case 'u':
				u1, uok := parse_hex4(p)
				if !uok {
					return "", fail(p, .Syntax, esc_off, "invalid \\uXXXX escape sequence")
				}
				if u1 >= 0xDC00 && u1 <= 0xDFFF {
					return "", fail(p, .Syntax, esc_off, "unexpected lone low surrogate in string literal")
				}
				cp := rune(u1)
				if u1 >= 0xD800 && u1 <= 0xDBFF {
					if p.i + 6 > n || p.src[p.i] != '\\' || p.src[p.i + 1] != 'u' {
						return "", fail(p, .Syntax, esc_off, "lone high surrogate without matching low surrogate")
					}
					p.i += 2
					u2, u2ok := parse_hex4(p)
					if !u2ok || u2 < 0xDC00 || u2 > 0xDFFF {
						return "", fail(p, .Syntax, esc_off, "invalid low surrogate after high surrogate")
					}
					cp = rune(0x10000 + ((u32(u1) - 0xD800) << 10) + (u32(u2) - 0xDC00))
				}
				bytes, w := utf8.encode_rune(cp)
				strings.write_bytes(&b, bytes[:w])
			case:
				return "", fail(p, .Syntax, esc_off, "invalid escape sequence in string literal")
			}
			continue
		}
		if c < 0x80 {
			strings.write_byte(&b, c)
			p.i += 1
		} else {
			r, w := decode_strict_utf8(p.src[p.i:])
			if w == 0 || !is_scalar_value(r) {
				return "", fail(p, .Syntax, p.i, "invalid UTF-8 in string literal")
			}
			strings.write_string(&b, p.src[p.i:p.i + w])
			p.i += w
		}
	}
	return "", fail(p, .Syntax, start, "unterminated string literal")
}

@(private = "file")
parse_hex4 :: proc(p: ^Parser) -> (val: u16, ok: bool) {
	if p.i + 4 > len(p.src) {
		return 0, false
	}
	acc: u16
	for k in 0 ..< 4 {
		c := p.src[p.i + k]
		switch c {
		case '0' ..= '9': acc = (acc << 4) | u16(c - '0')
		case 'a' ..= 'f': acc = (acc << 4) | u16(c - 'a' + 10)
		case 'A' ..= 'F': acc = (acc << 4) | u16(c - 'A' + 10)
		case: return 0, false
		}
	}
	p.i += 4
	return acc, true
}

@(private = "file")
parse_safe_int :: proc(p: ^Parser) -> (val: i64, ok: bool) {
	start, n := p.i, len(p.src)
	neg := p.i < n && p.src[p.i] == '-'
	if neg {
		p.i += 1
	}
	if p.i >= n {
		return 0, fail(p, .Syntax, start, "expected integer")
	}
	if p.src[p.i] == '0' {
		if neg {
			return 0, fail(p, .Syntax, start, "-0 is not allowed in index or slice selector")
		}
		p.i += 1
		if p.i < n && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
			return 0, fail(p, .Syntax, start, "leading zeros are not allowed in integer")
		}
		return 0, true
	}
	if p.src[p.i] < '1' || p.src[p.i] > '9' {
		return 0, fail(p, .Syntax, start, "expected integer digit")
	}
	acc: i64
	for p.i < n && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
		d := i64(p.src[p.i] - '0')
		if acc > (MAX_SAFE_INT - d) / 10 {
			return 0, fail(p, .Syntax, start, "integer out of RFC 9535 safe range [-(2^53)+1, (2^53)-1]")
		}
		acc = acc * 10 + d
		p.i += 1
	}
	return -acc if neg else acc, true
}

@(private = "file")
parse_index_or_slice :: proc(p: ^Parser) -> (sel: Selector, ok: bool) {
	has_int :: #force_inline proc(p: ^Parser) -> bool {
		return p.i < len(p.src) && (p.src[p.i] == '-' || (p.src[p.i] >= '0' && p.src[p.i] <= '9'))
	}
	sel = {kind = .Slice, step = 1}
	if p.src[p.i] != ':' {
		sel.start = parse_safe_int(p) or_return
		sel.has_start = true
		saved := p.i
		skip_s(p)
		if p.i >= len(p.src) || p.src[p.i] != ':' {
			p.i = saved
			return {kind = .Index, index = sel.start}, true
		}
	}
	p.i += 1
	skip_s(p)
	if has_int(p) {
		sel.end = parse_safe_int(p) or_return
		sel.has_end = true
		skip_s(p)
	}
	if p.i < len(p.src) && p.src[p.i] == ':' {
		p.i += 1
		skip_s(p)
		if has_int(p) {
			sel.step = parse_safe_int(p) or_return
			sel.has_step = true
		}
	}
	return sel, true
}
