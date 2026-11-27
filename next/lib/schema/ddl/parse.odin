// SQL DDL parser: parses `CREATE TABLE` definitions (columns, types, constraints, `CHECK` expressions)
// and `CREATE TYPE ... AS ENUM` while safely skipping non-table statements.
// Explicit heap operator stack with bounded depth (`MAX_EXPR_DEPTH`); `mem.Dynamic_Arena` for O(1) cleanup.
// Zero `core:os`, zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.
package ddl

import "base:runtime"
import "core:mem"
import "core:strconv"
import "core:strings"
import "stury:lib/schema/rules"

MAX_EXPR_DEPTH :: 128

Expr_Index :: distinct i32
NO_EXPR :: Expr_Index(-1)

Sql_Type_Kind :: enum u8 {
	Unknown,
	TinyInt, SmallInt, MediumInt, Int, BigInt,
	SmallSerial, Serial, BigSerial,
	Float, Double, Numeric, Bool,
	Text, Varchar, Char,
	Uuid, Date, Time, Timestamp,
	Json, Bytes, Enum, Named,
}

Sql_Type :: struct {
	kind:        Sql_Type_Kind,
	has_len:     bool,
	len:         u64,
	has_scale:   bool,
	scale:       u64,
	unsigned:    bool,
	is_array:    bool,
	enum_values: []string,
	named:       string,
}

Literal_Kind :: enum u8 { Null, Bool, Integer, Decimal, String }

Literal :: struct {
	kind:     Literal_Kind,
	bool_val: bool,
	int_val:  i64,
	text:     string,
}

Cmp_Op :: enum u8 { Eq, Neq, Lt, Lte, Gt, Gte }

Expr_Kind :: enum u8 {
	Ident, Literal, Length_Call, Compare, Between, In_List, Is_Null, Like, And, Or, Not, Unsupported,
}

Expr :: struct {
	kind:       Expr_Kind,
	cmp:        Cmp_Op,
	negated:    bool,
	lhs:        Expr_Index,
	rhs:        Expr_Index,
	hi:         Expr_Index,
	ident:      string,
	table_qual: string,
	lit:        Literal,
	literals:   []Literal,
	pattern:    string,
	escape:     u8,
	line:       u32,
	col:        u32,
	offset:     u64,
}

Foreign_Key :: struct {
	name:        string,
	columns:     []string,
	ref_table:   string,
	ref_columns: []string,
}

Unique_Constraint :: struct {
	name:    string,
	columns: []string,
	primary: bool,
}

Column_Def :: struct {
	name:            string,
	type:            Sql_Type,
	not_null:        bool,
	primary_key:     bool,
	unique:          bool,
	has_default:     bool,
	has_default_lit: bool,
	default_lit:     Literal,
	checks:          []Expr_Index,
	references:      Maybe(Foreign_Key),
	line:            u32,
	col:             u32,
	offset:          u64,
}

Table_Def :: struct {
	schema_name:  string,
	name:         string,
	columns:      []Column_Def,
	primary_key:  []string,
	uniques:      []Unique_Constraint,
	foreign_keys: []Foreign_Key,
	checks:       []Expr_Index,
	line:         u32,
	col:          u32,
	offset:       u64,
}

Enum_Type_Def :: struct {
	schema_name: string,
	name:        string,
	values:      []string,
}

Parsed :: struct {
	tables:      []Table_Def,
	enums:       []Enum_Type_Def,
	exprs:       []Expr,
	arena:       mem.Dynamic_Arena,
	arena_ready: bool,
}

parsed_destroy :: proc(p: ^Parsed) {
	if p == nil {
		return
	}
	if p.arena_ready {
		mem.dynamic_arena_destroy(&p.arena)
	}
	p^ = {}
}

@(private = "file")
Parser :: struct {
	src:       []u8,
	lex:       Lexer,
	cur:       Token,
	peek_tok:  Token,
	has_peek:  bool,
	a:         runtime.Allocator,
	err_alloc: runtime.Allocator,
	exprs:     [dynamic]Expr,
	tables:    [dynamic]Table_Def,
	enums:     [dynamic]Enum_Type_Def,
	err:       Error,
}

@(private = "file")
p_advance :: proc(p: ^Parser) -> Token {
	prev := p.cur
	if p.has_peek {
		p.cur = p.peek_tok
		p.has_peek = false
	} else {
		p.cur = lexer_next(&p.lex)
	}
	if p.cur.kind == .Error && p.err.kind == .None {
		msg := p.lex.err_msg if p.lex.err_msg != "" else "lexical error in SQL DDL"
		p.err = make_error(.Syntax, msg, p.lex.err_offset, p.lex.err_line, p.lex.err_col, allocator = p.err_alloc)
	}
	return prev
}

@(private = "file")
p_peek :: proc(p: ^Parser) -> Token {
	if !p.has_peek {
		p.peek_tok = lexer_next(&p.lex)
		p.has_peek = true
	}
	return p.peek_tok
}

@(private = "file")
p_fail :: proc(p: ^Parser, kind: Error_Kind, msg: string, tok: Token, table := "", column := "") {
	if p.err.kind == .None {
		p.err = make_error(kind, msg, u64(tok.lo), tok.line, tok.col, table = table, column = column, allocator = p.err_alloc)
	}
}

@(private = "file")
p_oom :: proc(p: ^Parser) {
	p_fail(p, .No_Memory, "out of memory", p.cur)
}

@(private = "file")
p_push :: proc(p: ^Parser, arr: ^[dynamic]$T, val: T) -> bool {
	if _, err := append(arr, val); err != nil {
		p_oom(p)
		return false
	}
	return true
}

@(private = "file")
p_is_kw :: proc "contextless" (p: ^Parser, kw: string) -> bool {
	return token_is_kw(p.src, p.cur, kw)
}

@(private = "file")
p_is_any_kw :: proc "contextless" (p: ^Parser, kws: ..string) -> bool {
	if p.cur.kind != .Ident {
		return false
	}
	raw := token_raw(p.src, p.cur)
	for kw in kws {
		if ascii_eq_fold(raw, kw) {
			return true
		}
	}
	return false
}

@(private = "file")
p_peek_any_kw :: proc(p: ^Parser, kws: ..string) -> bool {
	pk := p_peek(p)
	if pk.kind != .Ident {
		return false
	}
	raw := token_raw(p.src, pk)
	for kw in kws {
		if ascii_eq_fold(raw, kw) {
			return true
		}
	}
	return false
}

@(private = "file")
p_eat_kw :: proc(p: ^Parser, kw: string) -> bool {
	if p_is_kw(p, kw) {
		p_advance(p)
		return true
	}
	return false
}

@(private = "file")
p_eat_any_kw :: proc(p: ^Parser, kws: ..string) -> bool {
	if p_is_any_kw(p, ..kws) {
		p_advance(p)
		return true
	}
	return false
}

@(private = "file")
p_expect :: proc(p: ^Parser, kind: Token_Kind, msg: string) -> bool {
	if p.cur.kind != kind {
		p_fail(p, .Syntax, msg, p.cur)
		return false
	}
	p_advance(p)
	return true
}

@(private = "file")
p_clone :: proc(p: ^Parser, s: string) -> string {
	out, aerr := strings.clone(s, p.a)
	if aerr != nil {
		p_oom(p)
		return ""
	}
	return out
}

@(private = "file")
p_read_ident :: proc(p: ^Parser) -> (string, bool) {
	if p.cur.kind == .Ident {
		raw := token_raw(p.src, p_advance(p))
		return p_clone(p, raw), p.err.kind == .None
	}
	if p.cur.kind == .Quoted_Ident {
		dec, err := decode_quoted(p.src, p_advance(p), p.a)
		if err != nil {
			p_oom(p)
			return "", false
		}
		return dec, true
	}
	return "", false
}

@(private = "file")
p_read_string :: proc(p: ^Parser) -> (string, bool) {
	if p.cur.kind != .String {
		return "", false
	}
	dec, err := decode_quoted(p.src, p_advance(p), p.a)
	if err != nil {
		p_oom(p)
		return "", false
	}
	return dec, true
}

@(private = "file")
p_read_qualified_name :: proc(p: ^Parser) -> (schema_name, name: string, ok: bool) {
	first, ok1 := p_read_ident(p)
	if !ok1 {
		return "", "", false
	}
	if p.cur.kind == .Dot {
		p_advance(p)
		second, ok2 := p_read_ident(p)
		if !ok2 {
			p_fail(p, .Syntax, "expected identifier after '.'", p.cur)
			return "", "", false
		}
		return first, second, true
	}
	return "", first, true
}

@(private = "file")
p_expr :: proc(p: ^Parser, tok: Token, e: Expr) -> Expr_Index {
	e := e
	e.line = tok.line
	e.col = tok.col
	e.offset = u64(tok.lo)
	if !p_push(p, &p.exprs, e) {
		return NO_EXPR
	}
	return Expr_Index(len(p.exprs) - 1)
}

@(private = "file")
p_unsupported :: proc(p: ^Parser, tok: Token) -> Expr_Index {
	return p_expr(p, tok, Expr{kind = .Unsupported})
}

@(require_results)
parse_ddl :: proc(src: []u8, allocator := context.allocator) -> (out: Parsed, err: Error) {
	mem.dynamic_arena_init(&out.arena, allocator, allocator)
	out.arena_ready = true
	a := mem.dynamic_arena_allocator(&out.arena)

	p := Parser {
		src       = src,
		a         = a,
		err_alloc = allocator,
		exprs     = make([dynamic]Expr, a),
		tables    = make([dynamic]Table_Def, a),
		enums     = make([dynamic]Enum_Type_Def, a),
	}
	lexer_init(&p.lex, src)
	p_advance(&p)

	for p.cur.kind != .Eof && p.err.kind == .None {
		if p.cur.kind == .Semi {
			p_advance(&p)
		} else if p_is_kw(&p, "CREATE") {
			parse_create(&p)
		} else {
			skip_statement(&p)
		}
	}

	if p.err.kind != .None {
		parsed_destroy(&out)
		return {}, p.err
	}
	out.tables = p.tables[:]
	out.enums = p.enums[:]
	out.exprs = p.exprs[:]
	return out, {}
}

@(private = "file")
skip_statement :: proc(p: ^Parser) {
	depth := 0
	for p.cur.kind != .Eof && p.err.kind == .None {
		if p.cur.kind == .LParen {
			depth += 1
		} else if p.cur.kind == .RParen && depth > 0 {
			depth -= 1
		} else if p.cur.kind == .Semi && depth == 0 {
			p_advance(p)
			return
		}
		p_advance(p)
	}
}

@(private = "file")
skip_open_parens :: proc(p: ^Parser, initial_depth: int) {
	depth := initial_depth
	for p.cur.kind != .Eof && depth > 0 && p.err.kind == .None {
		if p.cur.kind == .LParen {
			depth += 1
		} else if p.cur.kind == .RParen {
			depth -= 1
		}
		p_advance(p)
	}
}

@(private = "file")
skip_balanced_parens :: proc(p: ^Parser) {
	if p.cur.kind == .LParen {
		p_advance(p)
		skip_open_parens(p, 1)
	}
}

@(private = "file")
skip_constraint_tail :: proc(p: ^Parser) {
	depth := 0
	for p.cur.kind != .Eof && p.err.kind == .None {
		if p.cur.kind == .LParen {
			depth += 1
		} else if p.cur.kind == .RParen {
			if depth == 0 {
				return
			}
			depth -= 1
		} else if p.cur.kind == .Comma && depth == 0 {
			return
		}
		p_advance(p)
	}
}

@(private = "file")
parse_create :: proc(p: ^Parser) {
	p_advance(p) // CREATE
	_ = p_eat_kw(p, "OR") && p_eat_kw(p, "REPLACE")
	_ = p_eat_any_kw(p, "GLOBAL", "LOCAL")
	_ = p_eat_any_kw(p, "TEMPORARY", "TEMP", "UNLOGGED")

	if p_eat_kw(p, "TABLE") {
		parse_create_table(p)
	} else if p_eat_kw(p, "TYPE") {
		parse_create_type(p)
	} else {
		skip_statement(p)
	}
}

@(private = "file")
parse_enum_values :: proc(p: ^Parser, table := "", col := "") -> ([]string, bool) {
	if !p_expect(p, .LParen, "expected '(' after ENUM") {
		return nil, false
	}
	vals := make([dynamic]string, p.a)
	for p.cur.kind != .RParen && p.cur.kind != .Eof && p.err.kind == .None {
		s, sok := p_read_string(p)
		if !sok {
			p_fail(p, .Syntax, "expected string literal in ENUM definition", p.cur, table = table, column = col)
			return nil, false
		}
		if !p_push(p, &vals, s) {
			return nil, false
		}
		if p.cur.kind == .Comma {
			p_advance(p)
			continue
		}
		break
	}
	if !p_expect(p, .RParen, "expected ')' after ENUM values") {
		return nil, false
	}
	return vals[:], true
}

@(private = "file")
parse_create_type :: proc(p: ^Parser) {
	schema_name, name, ok := p_read_qualified_name(p)
	if !ok || !p_eat_kw(p, "AS") || !p_eat_kw(p, "ENUM") {
		skip_statement(p)
		return
	}
	vals, vok := parse_enum_values(p)
	if !vok {
		return
	}
	if p.cur.kind == .Semi {
		p_advance(p)
	}
	_ = p_push(p, &p.enums, Enum_Type_Def{schema_name = schema_name, name = name, values = vals})
}

@(private = "file")
parse_create_table :: proc(p: ^Parser) {
	if p_eat_kw(p, "IF") && (!p_eat_kw(p, "NOT") || !p_eat_kw(p, "EXISTS")) {
		p_fail(p, .Syntax, "expected 'NOT EXISTS' after 'IF'", p.cur)
		return
	}

	name_tok := p.cur
	schema_name, name, ok := p_read_qualified_name(p)
	if !ok {
		p_fail(p, .Syntax, "expected table name after CREATE TABLE", name_tok)
		return
	}
	if p_is_any_kw(p, "AS", "LIKE") {
		skip_statement(p)
		return
	}
	if !p_expect(p, .LParen, "expected '(' after table name") {
		return
	}

	tbl := Table_Def{schema_name = schema_name, name = name, line = name_tok.line, col = name_tok.col, offset = u64(name_tok.lo)}
	cols := make([dynamic]Column_Def, p.a)
	uniques := make([dynamic]Unique_Constraint, p.a)
	fks := make([dynamic]Foreign_Key, p.a)
	checks := make([dynamic]Expr_Index, p.a)

	for p.cur.kind != .RParen && p.cur.kind != .Eof && p.err.kind == .None {
		if is_table_constraint_start(p) {
			parse_table_constraint(p, &tbl, &uniques, &fks, &checks)
		} else {
			col, cok := parse_column_def(p, tbl.name)
			if !cok {
				return
			}
			for existing in cols {
				if ascii_eq_fold(existing.name, col.name) {
					p_fail(p, .Duplicate_Column, "duplicate column name in CREATE TABLE", Token{lo = u32(col.offset), line = col.line, col = col.col}, table = tbl.name, column = col.name)
					return
				}
			}
			if !p_push(p, &cols, col) {
				return
			}
		}
		if p.err.kind != .None {
			return
		}
		if p.cur.kind == .Comma {
			p_advance(p)
			if p.cur.kind == .RParen {
				p_fail(p, .Syntax, "unexpected trailing ',' before ')' in CREATE TABLE", p.cur, table = tbl.name)
				return
			}
			continue
		}
		break
	}

	if !p_expect(p, .RParen, "expected ')' or ',' in CREATE TABLE column list") {
		return
	}
	// Skip trailing table options (`ENGINE=InnoDB`, `WITHOUT ROWID`, `WITH (...)`, etc.) up to `;`, EOF, or next `CREATE`.
	for depth := 0; p.cur.kind != .Eof && p.err.kind == .None; {
		if p.cur.kind == .LParen {
			depth += 1
		} else if p.cur.kind == .RParen {
			if depth == 0 {
				p_fail(p, .Syntax, "unexpected ')' in table options", p.cur)
				return
			}
			depth -= 1
		} else if p.cur.kind == .Semi && depth == 0 {
			p_advance(p)
			break
		} else if depth == 0 && p_is_kw(p, "CREATE") {
			break
		}
		p_advance(p)
	}
	if p.err.kind != .None {
		return
	}

	tbl.columns = cols[:]
	tbl.uniques = uniques[:]
	tbl.foreign_keys = fks[:]
	tbl.checks = checks[:]
	_ = p_push(p, &p.tables, tbl)
}

@(private = "file")
is_table_constraint_start :: proc(p: ^Parser) -> bool {
	if p_is_any_kw(p, "CONSTRAINT", "PRIMARY", "UNIQUE", "FOREIGN", "CHECK", "FULLTEXT", "SPATIAL") {
		return true
	}
	if p_is_any_kw(p, "INDEX", "KEY") {
		pk := p_peek(p)
		if pk.kind == .LParen {
			return true
		}
		if pk.kind == .Ident || pk.kind == .Quoted_Ident {
			_, known := lookup_sql_type(token_raw(p.src, pk))
			return !(pk.kind == .Ident && known)
		}
	}
	return false
}

@(private = "file")
parse_check_parens :: proc(p: ^Parser) -> (Expr_Index, bool) {
	if !p_expect(p, .LParen, "expected '(' after CHECK") {
		return NO_EXPR, false
	}
	ex := parse_expr(p)
	if p.err.kind != .None || !p_expect(p, .RParen, "expected ')' closing CHECK expression") {
		return NO_EXPR, false
	}
	return ex, true
}

@(private = "file")
parse_table_constraint :: proc(
	p: ^Parser,
	tbl: ^Table_Def,
	uniques: ^[dynamic]Unique_Constraint,
	fks: ^[dynamic]Foreign_Key,
	checks: ^[dynamic]Expr_Index,
) {
	cname := ""
	if p_eat_kw(p, "CONSTRAINT") {
		nm, ok := p_read_ident(p)
		if !ok {
			p_fail(p, .Syntax, "expected constraint name after CONSTRAINT", p.cur, table = tbl.name)
			return
		}
		cname = nm
	}

	if p_eat_kw(p, "PRIMARY") {
		if !p_eat_kw(p, "KEY") {
			p_fail(p, .Syntax, "expected KEY after PRIMARY", p.cur, table = tbl.name)
			return
		}
		cols := parse_column_name_list(p, tbl.name)
		if p.err.kind != .None {
			return
		}
		skip_constraint_tail(p)
		tbl.primary_key = cols
		_ = p_push(p, uniques, Unique_Constraint{name = cname, columns = cols, primary = true})
		return
	}

	if p_eat_kw(p, "UNIQUE") {
		if p_eat_kw(p, "NULLS") {
			_ = p_eat_kw(p, "NOT")
			_ = p_eat_kw(p, "DISTINCT")
		}
		_ = p_eat_any_kw(p, "INDEX", "KEY")
		if p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident {
			idx_name, _ := p_read_ident(p)
			if cname == "" {
				cname = idx_name
			}
		}
		cols := parse_column_name_list(p, tbl.name)
		if p.err.kind != .None {
			return
		}
		skip_constraint_tail(p)
		_ = p_push(p, uniques, Unique_Constraint{name = cname, columns = cols})
		return
	}

	if p_eat_kw(p, "FOREIGN") {
		if !p_eat_kw(p, "KEY") {
			p_fail(p, .Syntax, "expected KEY after FOREIGN", p.cur, table = tbl.name)
			return
		}
		if p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident {
			_, _ = p_read_ident(p)
		}
		cols := parse_column_name_list(p, tbl.name)
		if p.err.kind != .None {
			return
		}
		if !p_eat_kw(p, "REFERENCES") {
			p_fail(p, .Syntax, "expected REFERENCES in FOREIGN KEY constraint", p.cur, table = tbl.name)
			return
		}
		if fk, fok := parse_references_clause(p, cname, cols, tbl.name); fok {
			_ = p_push(p, fks, fk)
		}
		return
	}

	if p_eat_kw(p, "CHECK") {
		if ex, cok := parse_check_parens(p); cok {
			skip_constraint_tail(p)
			_ = p_push(p, checks, ex)
		}
		return
	}

	skip_constraint_tail(p)
}

@(private = "file")
parse_column_name_list :: proc(p: ^Parser, table_name: string) -> []string {
	if !p_expect(p, .LParen, "expected '(' for column list") {
		return nil
	}
	list := make([dynamic]string, p.a)
	for p.cur.kind != .RParen && p.cur.kind != .Eof && p.err.kind == .None {
		nm, ok := p_read_ident(p)
		if !ok {
			p_fail(p, .Syntax, "expected column name in constraint column list", p.cur, table = table_name)
			return nil
		}
		if !p_push(p, &list, nm) {
			return nil
		}
		skip_balanced_parens(p)
		for {
			if p_eat_any_kw(p, "ASC", "DESC") {
				continue
			}
			if p_eat_kw(p, "COLLATE") {
				if p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident || p.cur.kind == .String {
					p_advance(p)
				}
				continue
			}
			if p_eat_kw(p, "NULLS") {
				_ = p_eat_any_kw(p, "FIRST", "LAST")
				continue
			}
			break
		}
		if p.cur.kind == .Comma {
			p_advance(p)
			continue
		}
		break
	}
	if !p_expect(p, .RParen, "expected ')' after column list") {
		return nil
	}
	return list[:]
}

@(private = "file")
parse_references_clause :: proc(p: ^Parser, cname: string, cols: []string, table_name: string) -> (fk: Foreign_Key, ok: bool) {
	ref_schema, ref_tbl, rok := p_read_qualified_name(p)
	if !rok {
		p_fail(p, .Syntax, "expected referenced table name after REFERENCES", p.cur, table = table_name)
		return {}, false
	}
	full_ref := ref_tbl
	if ref_schema != "" {
		joined, jerr := strings.concatenate({ref_schema, ".", ref_tbl}, p.a)
		if jerr != nil {
			p_oom(p)
			return {}, false
		}
		full_ref = joined
	}
	ref_cols: []string
	if p.cur.kind == .LParen {
		ref_cols = parse_column_name_list(p, table_name)
		if p.err.kind != .None {
			return {}, false
		}
	}
	for p.err.kind == .None {
		if p_eat_kw(p, "MATCH") {
			if p.cur.kind == .Ident {
				p_advance(p)
			}
			continue
		}
		if p_eat_kw(p, "ON") {
			_ = p_eat_any_kw(p, "DELETE", "UPDATE")
			if p_eat_kw(p, "NO") {
				_ = p_eat_kw(p, "ACTION")
			} else if p_eat_kw(p, "SET") {
				_ = p_eat_any_kw(p, "NULL", "DEFAULT")
				skip_balanced_parens(p)
			} else {
				_ = p_eat_any_kw(p, "CASCADE", "RESTRICT")
			}
			continue
		}
		break
	}
	consume_deferrable(p)
	return Foreign_Key{name = cname, columns = cols, ref_table = full_ref, ref_columns = ref_cols}, true
}

@(private = "file")
consume_deferrable :: proc(p: ^Parser) {
	for p.err.kind == .None {
		if p_is_kw(p, "NOT") && p_peek_any_kw(p, "DEFERRABLE", "ENFORCED", "VALID") {
			p_advance(p)
			p_advance(p)
		} else if p_eat_any_kw(p, "DEFERRABLE", "ENFORCED") {
			// consumed
		} else if p_eat_kw(p, "INITIALLY") {
			_ = p_eat_any_kw(p, "DEFERRED", "IMMEDIATE")
		} else {
			break
		}
	}
}

@(private = "file")
is_col_constraint_kw :: proc "contextless" (p: ^Parser) -> bool {
	return p_is_any_kw(
		p,
		"NOT", "NULL", "PRIMARY", "UNIQUE", "DEFAULT", "CHECK", "REFERENCES",
		"CONSTRAINT", "COLLATE", "COMMENT", "AUTO_INCREMENT", "AUTOINCREMENT",
		"GENERATED", "ON", "DEFERRABLE",
	)
}

@(private = "file")
parse_column_def :: proc(p: ^Parser, table_name: string) -> (col: Column_Def, ok: bool) {
	tok := p.cur
	cname, nok := p_read_ident(p)
	if !nok {
		p_fail(p, .Syntax, "expected column name in CREATE TABLE", tok, table = table_name)
		return {}, false
	}
	col = {name = cname, line = tok.line, col = tok.col, offset = u64(tok.lo)}
	col.type, ok = parse_sql_type(p, table_name, cname)
	if !ok {
		return {}, false
	}

	checks := make([dynamic]Expr_Index, p.a)
	for p.cur.kind != .Comma && p.cur.kind != .RParen && p.cur.kind != .Eof && p.err.kind == .None {
		cname_c := ""
		if p_eat_kw(p, "CONSTRAINT") {
			nm, cok := p_read_ident(p)
			if !cok {
				p_fail(p, .Syntax, "expected constraint name after CONSTRAINT", p.cur, table = table_name, column = col.name)
				return {}, false
			}
			cname_c = nm
		}

		if p_eat_kw(p, "NOT") {
			if p_eat_kw(p, "NULL") {
				col.not_null = true
			} else if !p_eat_any_kw(p, "DEFERRABLE", "ENFORCED", "VALID") {
				p_fail(p, .Syntax, "expected NULL after NOT in column constraint", p.cur, table = table_name, column = col.name)
				return {}, false
			}
		} else if p_eat_any_kw(p, "NULL", "AUTO_INCREMENT", "AUTOINCREMENT") {
			// accepted no-op
		} else if p_eat_kw(p, "PRIMARY") {
			if !p_eat_kw(p, "KEY") {
				p_fail(p, .Syntax, "expected KEY after PRIMARY", p.cur, table = table_name, column = col.name)
				return {}, false
			}
			col.primary_key = true
			col.not_null = true
			col.unique = true
			_ = p_eat_any_kw(p, "ASC", "DESC")
			_ = p_eat_kw(p, "AUTOINCREMENT")
			if p_eat_kw(p, "ON") && p_eat_kw(p, "CONFLICT") && p.cur.kind == .Ident {
				p_advance(p)
			}
		} else if p_eat_kw(p, "UNIQUE") {
			col.unique = true
			if p_eat_kw(p, "NULLS") {
				_ = p_eat_kw(p, "NOT")
				_ = p_eat_kw(p, "DISTINCT")
			}
			if p_eat_kw(p, "ON") && p_eat_kw(p, "CONFLICT") && p.cur.kind == .Ident {
				p_advance(p)
			}
		} else if p_eat_kw(p, "DEFAULT") {
			col.has_default = true
			lit, has_lit := parse_default_value(p)
			if p.err.kind != .None {
				return {}, false
			}
			if has_lit {
				col.has_default_lit = true
				col.default_lit = lit
			}
		} else if p_eat_kw(p, "CHECK") {
			ex, cok := parse_check_parens(p)
			if !cok || !p_push(p, &checks, ex) {
				return {}, false
			}
		} else if p_eat_kw(p, "REFERENCES") {
			ref_cols, rerr := make([]string, 1, p.a)
			if rerr != nil {
				p_oom(p)
				return {}, false
			}
			ref_cols[0] = col.name
			fk, fok := parse_references_clause(p, cname_c, ref_cols, table_name)
			if !fok {
				return {}, false
			}
			col.references = fk
		} else if p_eat_kw(p, "GENERATED") {
			_ = p_eat_kw(p, "ALWAYS") || (p_eat_kw(p, "BY") && p_eat_kw(p, "DEFAULT"))
			if p_eat_kw(p, "AS") {
				if p_eat_kw(p, "IDENTITY") {
					skip_balanced_parens(p)
				} else if p.cur.kind == .LParen {
					skip_balanced_parens(p)
					_ = p_eat_any_kw(p, "STORED", "VIRTUAL")
				}
			}
		} else if p_eat_kw(p, "COLLATE") {
			if p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident || p.cur.kind == .String {
				p_advance(p)
			}
		} else if p_eat_kw(p, "COMMENT") {
			if p.cur.kind == .String {
				p_advance(p)
			}
		} else if p_eat_kw(p, "ON") {
			_ = p_eat_any_kw(p, "UPDATE", "DELETE")
			for p.cur.kind != .Comma && p.cur.kind != .RParen && p.cur.kind != .Eof && p.err.kind == .None && !is_col_constraint_kw(p) {
				if p.cur.kind == .LParen {
					skip_balanced_parens(p)
				} else {
					p_advance(p)
				}
			}
		} else if p_eat_any_kw(p, "DEFERRABLE", "INITIALLY", "ENFORCED") {
			consume_deferrable(p)
		} else {
			p_fail(p, .Syntax, "unexpected token in column definition", p.cur, table = table_name, column = col.name)
			return {}, false
		}
	}

	col.checks = checks[:]
	return col, true
}

@(private = "file")
Type_Flag :: enum u8 { Params, Signed, Charset, Time_Zone, Double_Prec, Char_Varying, Bit, Enum }

@(private = "file")
Type_Spec :: struct {
	name:  string,
	kind:  Sql_Type_Kind,
	flags: bit_set[Type_Flag],
}

@(private = "file")
SQL_TYPES := [?]Type_Spec{
	{"TINYINT",     .TinyInt,     {.Params, .Signed}},
	{"SMALLINT",    .SmallInt,    {.Params, .Signed}},
	{"INT2",        .SmallInt,    {.Params, .Signed}},
	{"MEDIUMINT",   .MediumInt,   {.Params, .Signed}},
	{"INT",         .Int,         {.Params, .Signed}},
	{"INTEGER",     .Int,         {.Params, .Signed}},
	{"INT4",        .Int,         {.Params, .Signed}},
	{"BIGINT",      .BigInt,      {.Params, .Signed}},
	{"INT8",        .BigInt,      {.Params, .Signed}},
	{"SMALLSERIAL", .SmallSerial, {}},
	{"SERIAL2",     .SmallSerial, {}},
	{"SERIAL",      .Serial,      {}},
	{"SERIAL4",     .Serial,      {}},
	{"BIGSERIAL",   .BigSerial,   {}},
	{"SERIAL8",     .BigSerial,   {}},
	{"REAL",        .Float,       {.Params, .Signed}},
	{"FLOAT",       .Float,       {.Params, .Signed}},
	{"FLOAT4",      .Float,       {.Params, .Signed}},
	{"DOUBLE",      .Double,      {.Params, .Signed, .Double_Prec}},
	{"FLOAT8",      .Double,      {.Params, .Signed, .Double_Prec}},
	{"NUMERIC",     .Numeric,     {.Params, .Signed}},
	{"DECIMAL",     .Numeric,     {.Params, .Signed}},
	{"DEC",         .Numeric,     {.Params, .Signed}},
	{"FIXED",       .Numeric,     {.Params, .Signed}},
	{"MONEY",       .Numeric,     {.Params, .Signed}},
	{"BOOL",        .Bool,        {}},
	{"BOOLEAN",     .Bool,        {}},
	{"BIT",         .Bool,        {.Params, .Bit}},
	{"CHARACTER",   .Char,        {.Params, .Charset, .Char_Varying}},
	{"CHAR",        .Char,        {.Params, .Charset, .Char_Varying}},
	{"NCHAR",       .Char,        {.Params, .Charset, .Char_Varying}},
	{"BPCHAR",      .Char,        {.Params, .Charset, .Char_Varying}},
	{"VARCHAR",     .Varchar,     {.Params, .Charset}},
	{"NVARCHAR",    .Varchar,     {.Params, .Charset}},
	{"VARCHAR2",    .Varchar,     {.Params, .Charset}},
	{"TEXT",        .Text,        {.Params, .Charset}},
	{"CLOB",        .Text,        {.Params, .Charset}},
	{"TINYTEXT",    .Text,        {.Params, .Charset}},
	{"MEDIUMTEXT",  .Text,        {.Params, .Charset}},
	{"LONGTEXT",    .Text,        {.Params, .Charset}},
	{"STRING",      .Text,        {.Params, .Charset}},
	{"CITEXT",      .Text,        {.Params, .Charset}},
	{"UUID",        .Uuid,        {}},
	{"DATE",        .Date,        {}},
	{"TIME",        .Time,        {.Params, .Time_Zone}},
	{"TIMETZ",      .Time,        {.Params, .Time_Zone}},
	{"TIMESTAMP",   .Timestamp,   {.Params, .Time_Zone}},
	{"TIMESTAMPTZ", .Timestamp,   {.Params, .Time_Zone}},
	{"DATETIME",    .Timestamp,   {.Params, .Time_Zone}},
	{"JSON",        .Json,        {}},
	{"JSONB",       .Json,        {}},
	{"BYTEA",       .Bytes,       {.Params}},
	{"BLOB",        .Bytes,       {.Params}},
	{"TINYBLOB",    .Bytes,       {.Params}},
	{"MEDIUMBLOB",  .Bytes,       {.Params}},
	{"LONGBLOB",    .Bytes,       {.Params}},
	{"BINARY",      .Bytes,       {.Params}},
	{"VARBINARY",   .Bytes,       {.Params}},
	{"ENUM",        .Enum,        {.Enum}},
}

@(private = "file")
lookup_sql_type :: proc "contextless" (s: string) -> (Type_Spec, bool) {
	for spec in SQL_TYPES {
		if ascii_eq_fold(s, spec.name) {
			return spec, true
		}
	}
	return {}, false
}

@(private = "file")
parse_sql_type :: proc(p: ^Parser, table_name, col_name: string) -> (t: Sql_Type, ok: bool) {
	leading_unsigned := false
	if p_eat_kw(p, "UNSIGNED") {
		leading_unsigned = true
		if p_is_kw(p, "UNSIGNED") {
			p_fail(p, .Syntax, "duplicate UNSIGNED modifier in SQL type", p.cur, table = table_name, column = col_name)
			return {}, false
		}
	} else if p_eat_kw(p, "SIGNED") {
		if p_is_any_kw(p, "SIGNED", "UNSIGNED") {
			p_fail(p, .Syntax, "duplicate signedness modifier in SQL type", p.cur, table = table_name, column = col_name)
			return {}, false
		}
	}

	tok := p.cur
	if tok.kind != .Ident && tok.kind != .Quoted_Ident {
		p_fail(p, .Syntax, "expected SQL type name for column", tok, table = table_name, column = col_name)
		return {}, false
	}

	first_raw := token_raw(p.src, tok)
	first_quoted := tok.kind == .Quoted_Ident
	first_name, nok := p_read_ident(p)
	if !nok {
		return {}, false
	}

	if p.cur.kind == .Dot {
		p_advance(p)
		second_name, sok := p_read_ident(p)
		if !sok {
			p_fail(p, .Syntax, "expected type name after '.'", p.cur, table = table_name, column = col_name)
			return {}, false
		}
		t = {kind = .Named, named = second_name}
		parse_array_suffix(p, &t)
		return t, true
	}

	if first_quoted {
		t = {kind = .Named, named = first_name}
		parse_array_suffix(p, &t)
		return t, true
	}

	if spec, found := lookup_sql_type(first_raw); found {
		t.kind = spec.kind
		if .Double_Prec in spec.flags {
			_ = p_eat_kw(p, "PRECISION")
		}
		if .Char_Varying in spec.flags && p_eat_kw(p, "VARYING") {
			t.kind = .Varchar
		}
		if .Enum in spec.flags {
			vals, vok := parse_enum_values(p, table_name, col_name)
			if !vok {
				return {}, false
			}
			t.enum_values = vals
		}
		if .Params in spec.flags {
			parse_type_params(p, &t)
			if p.err.kind != .None {
				return {}, false
			}
		}
		if .Bit in spec.flags && t.has_len && t.len != 1 {
			t.kind = .Bytes
		}
		if .Signed in spec.flags {
			for {
				if p_eat_kw(p, "UNSIGNED") {
					t.unsigned = true
				} else if !p_eat_any_kw(p, "SIGNED", "ZEROFILL") {
					break
				}
			}
		}
		if .Charset in spec.flags {
			if (p_eat_kw(p, "CHARACTER") && p_eat_kw(p, "SET")) || p_eat_kw(p, "CHARSET") {
				if p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident {
					p_advance(p)
				}
			}
		}
		if .Time_Zone in spec.flags {
			skip_time_zone(p)
		}
	} else {
		t = {kind = .Named, named = first_name}
		skip_balanced_parens(p)
	}

	if p.err.kind != .None {
		return {}, false
	}
	if leading_unsigned {
		t.unsigned = true
	}
	parse_array_suffix(p, &t)
	return t, true
}

@(private = "file")
parse_nonneg_int_param :: proc(p: ^Parser, msg: string) -> (u64, bool) {
	if p.cur.kind != .Number {
		p_fail(p, .Syntax, msg, p.cur)
		return 0, false
	}
	raw := token_raw(p.src, p.cur)
	if strings.contains_any(raw, ".eE") {
		p_fail(p, .Syntax, msg, p.cur)
		return 0, false
	}
	n, nok := strconv.parse_u64(raw)
	if !nok {
		p_fail(p, .Syntax, msg, p.cur)
		return 0, false
	}
	p_advance(p)
	return n, true
}

@(private = "file")
parse_type_params :: proc(p: ^Parser, t: ^Sql_Type) {
	if p.cur.kind != .LParen {
		return
	}
	p_advance(p)
	if !p_eat_kw(p, "MAX") {
		n, nok := parse_nonneg_int_param(p, "invalid integer length/precision in SQL type parameter")
		if !nok {
			return
		}
		t.has_len = true
		t.len = n
	}
	if p.cur.kind == .Comma {
		p_advance(p)
		sc, sok := parse_nonneg_int_param(p, "invalid integer scale in SQL type parameter")
		if !sok {
			return
		}
		t.has_scale = true
		t.scale = sc
	}
	_ = p_eat_any_kw(p, "CHAR", "BYTE")
	_ = p_expect(p, .RParen, "expected ')' closing type parameters")
}

@(private = "file")
skip_time_zone :: proc(p: ^Parser) {
	if p_eat_any_kw(p, "WITH", "WITHOUT") {
		_ = p_eat_kw(p, "TIME")
		_ = p_eat_kw(p, "ZONE")
	}
}

@(private = "file")
parse_array_suffix :: proc(p: ^Parser, t: ^Sql_Type) {
	for p.cur.kind == .Empty_Brackets || p_is_kw(p, "ARRAY") {
		t.is_array = true
		p_advance(p)
	}
}

@(private = "file")
is_arith_op :: proc "contextless" (k: Token_Kind) -> bool {
	#partial switch k {
	case .Plus, .Minus, .Star, .Slash, .Percent, .Concat:
		return true
	}
	return false
}

@(private = "file")
parse_default_value :: proc(p: ^Parser) -> (Literal, bool) {
	unwrapped := p.cur.kind == .LParen
	if unwrapped {
		p_advance(p)
	}
	if l, ok := try_parse_literal(p); ok {
		skip_pg_cast(p)
		if unwrapped {
			if p.cur.kind == .RParen {
				p_advance(p)
				skip_pg_cast(p)
				return l, true
			}
			skip_open_parens(p, 1)
			skip_pg_cast(p)
			return {}, false
		}
		if is_arith_op(p.cur.kind) && p.cur.kind != .Percent {
			skip_default_expr_tail(p)
			return {}, false
		}
		return l, true
	}
	if unwrapped {
		skip_open_parens(p, 1)
		skip_pg_cast(p)
	} else {
		skip_default_expr_tail(p)
	}
	return {}, false
}

@(private = "file")
skip_default_expr_tail :: proc(p: ^Parser) {
	depth := 0
	for p.cur.kind != .Eof && p.err.kind == .None {
		if p.cur.kind == .LParen {
			depth += 1
		} else if p.cur.kind == .RParen {
			if depth == 0 {
				return
			}
			depth -= 1
		} else if depth == 0 && (p.cur.kind == .Comma || is_col_constraint_kw(p)) {
			return
		}
		p_advance(p)
	}
}

@(private = "file")
skip_pg_cast :: proc(p: ^Parser) {
	for p.cur.kind == .Cast {
		p_advance(p)
		if p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident {
			p_advance(p)
			if p.cur.kind == .Dot {
				p_advance(p)
				if p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident {
					p_advance(p)
				}
			}
			_ = p_eat_any_kw(p, "VARYING", "PRECISION")
			skip_balanced_parens(p)
			skip_time_zone(p)
			for p.cur.kind == .Empty_Brackets {
				p_advance(p)
			}
		}
	}
}

@(private = "file")
try_parse_literal :: proc(p: ^Parser) -> (Literal, bool) {
	if p_eat_kw(p, "NULL") {
		return {kind = .Null}, true
	}
	if p_eat_kw(p, "TRUE") {
		return {kind = .Bool, bool_val = true}, true
	}
	if p_eat_kw(p, "FALSE") {
		return {kind = .Bool, bool_val = false}, true
	}
	if p.cur.kind == .String {
		s, sok := p_read_string(p)
		return {kind = .String, text = s}, sok
	}
	neg := false
	if p.cur.kind == .Minus || p.cur.kind == .Plus {
		if p_peek(p).kind != .Number {
			return {}, false
		}
		neg = p.cur.kind == .Minus
		p_advance(p)
	}
	if p.cur.kind != .Number {
		return {}, false
	}
	raw := token_raw(p.src, p_advance(p))
	text: string
	if neg {
		joined, jerr := strings.concatenate({"-", raw}, p.a)
		if jerr != nil {
			p_oom(p)
			return {}, false
		}
		text = joined
	} else {
		text = p_clone(p, raw)
	}
	if !rules.valid_decimal_text(text) || strings.has_prefix(text, ".") || strings.has_prefix(text, "-.") || strings.has_suffix(text, ".") {
		if norm, _, nok := rules.normalize_decimal_text(text, nil, p.a); nok {
			text = norm
		}
	}
	if !strings.contains_any(text, ".eE") {
		if iv, iok := strconv.parse_i64(text); iok {
			return {kind = .Integer, int_val = iv, text = text}, true
		}
	}
	return {kind = .Decimal, text = text}, true
}

// ============================================================================
// Explicit-stack, bounded-depth SQL `CHECK` expression parser
// ============================================================================

@(private = "file")
Op_Kind :: enum u8 { LParen, Or, And, Not } // ordered by precedence

@(private = "file")
Op_Entry :: struct {
	kind: Op_Kind,
	tok:  Token,
}

@(private = "file")
reduce_op :: proc(p: ^Parser, op: Op_Entry, vals: ^[dynamic]Expr_Index) -> bool {
	if op.kind == .Not {
		if len(vals) < 1 {
			p_fail(p, .Syntax, "missing operand for NOT in CHECK expression", op.tok)
			return false
		}
		idx := p_expr(p, op.tok, Expr{kind = .Not, lhs = pop(vals)})
		return idx != NO_EXPR && p_push(p, vals, idx)
	}
	if op.kind == .And || op.kind == .Or {
		if len(vals) < 2 {
			p_fail(p, .Syntax, "missing operand for boolean operator in CHECK expression", op.tok)
			return false
		}
		rhs := pop(vals)
		lhs := pop(vals)
		ek: Expr_Kind = .And if op.kind == .And else .Or
		idx := p_expr(p, op.tok, Expr{kind = ek, lhs = lhs, rhs = rhs})
		return idx != NO_EXPR && p_push(p, vals, idx)
	}
	return false
}

@(private = "file")
parse_expr :: proc(p: ^Parser) -> Expr_Index {
	ops := make([dynamic]Op_Entry, p.a)
	vals := make([dynamic]Expr_Index, p.a)
	paren_depth := 0
	not_chain := 0
	expect_operand := true

	for p.cur.kind != .Eof && p.err.kind == .None {
		if expect_operand {
			if p.cur.kind == .LParen || p_is_kw(p, "NOT") {
				okind: Op_Kind = .LParen if p.cur.kind == .LParen else .Not
				if okind == .LParen { paren_depth += 1 } else { not_chain += 1 }
				if paren_depth + not_chain > MAX_EXPR_DEPTH {
					p_fail(p, .Depth_Limit, "CHECK expression nesting depth exceeded", p.cur)
					return NO_EXPR
				}
				if !p_push(p, &ops, Op_Entry{kind = okind, tok = p_advance(p)}) {
					return NO_EXPR
				}
				continue
			}
			lhs := parse_term(p)
			if p.err.kind != .None {
				return NO_EXPR
			}
			atom := parse_predicate_rhs(p, lhs)
			if p.err.kind != .None || !p_push(p, &vals, atom) {
				return NO_EXPR
			}
			not_chain = 0
			expect_operand = false
			continue
		}

		if p.cur.kind == .RParen {
			if paren_depth == 0 {
				break
			}
			p_advance(p)
			paren_depth -= 1
			matched := false
			for len(ops) > 0 {
				top := pop(&ops)
				if top.kind == .LParen {
					matched = true
					break
				}
				if !reduce_op(p, top, &vals) {
					return NO_EXPR
				}
			}
			if !matched {
				p_fail(p, .Syntax, "mismatched ')' in CHECK expression", p.cur)
				return NO_EXPR
			}
			if len(vals) > 0 && is_predicate_continuation(p) {
				pred := parse_predicate_rhs(p, pop(&vals))
				if p.err.kind != .None || !p_push(p, &vals, pred) {
					return NO_EXPR
				}
			}
			continue
		}

		if p_is_any_kw(p, "AND", "OR") {
			tok := p_advance(p)
			okind: Op_Kind = .And if token_is_kw(p.src, tok, "AND") else .Or
			for len(ops) > 0 && ops[len(ops) - 1].kind != .LParen && ops[len(ops) - 1].kind >= okind {
				if !reduce_op(p, pop(&ops), &vals) {
					return NO_EXPR
				}
			}
			if !p_push(p, &ops, Op_Entry{kind = okind, tok = tok}) {
				return NO_EXPR
			}
			expect_operand = true
			continue
		}

		p_fail(p, .Syntax, "unexpected token in CHECK expression", p.cur)
		return NO_EXPR
	}

	if p.err.kind != .None {
		return NO_EXPR
	}
	if expect_operand {
		p_fail(p, .Syntax, "unexpected end of CHECK expression", p.cur)
		return NO_EXPR
	}
	if paren_depth > 0 {
		p_fail(p, .Syntax, "unclosed '(' in CHECK expression", p.cur)
		return NO_EXPR
	}
	for len(ops) > 0 {
		top := pop(&ops)
		if top.kind == .LParen {
			p_fail(p, .Syntax, "unclosed '(' in CHECK expression", p.cur)
			return NO_EXPR
		}
		if !reduce_op(p, top, &vals) {
			return NO_EXPR
		}
	}
	if len(vals) != 1 {
		p_fail(p, .Syntax, "malformed CHECK expression", p.cur)
		return NO_EXPR
	}
	return vals[0]
}

@(private = "file")
is_predicate_continuation :: proc(p: ^Parser) -> bool {
	if _, ok := token_to_cmp(p.cur.kind); ok || is_arith_op(p.cur.kind) {
		return true
	}
	return p_is_any_kw(p, "BETWEEN", "IN", "IS", "LIKE", "ILIKE") ||
		(p_is_kw(p, "NOT") && p_peek_any_kw(p, "BETWEEN", "IN", "LIKE", "ILIKE"))
}

@(private = "file")
parse_predicate_rhs :: proc(p: ^Parser, lhs: Expr_Index) -> Expr_Index {
	if is_arith_op(p.cur.kind) {
		tok := p.cur
		skip_unsupported_atom(p)
		return p_unsupported(p, tok)
	}

	if p_is_kw(p, "IS") {
		tok := p_advance(p)
		neg := p_eat_kw(p, "NOT")
		if p_eat_kw(p, "NULL") {
			return p_expr(p, tok, Expr{kind = .Is_Null, lhs = lhs, negated = neg})
		}
		if p_is_any_kw(p, "TRUE", "FALSE") {
			bval := p_is_kw(p, "TRUE")
			lit_idx := p_expr(p, p_advance(p), Expr{kind = .Literal, lit = {kind = .Bool, bool_val = bval}})
			if lit_idx == NO_EXPR {
				return NO_EXPR
			}
			return p_expr(p, tok, Expr{kind = .Compare, cmp = .Neq if neg else .Eq, lhs = lhs, rhs = lit_idx})
		}
		p_fail(p, .Syntax, "expected NULL after IS", p.cur)
		return NO_EXPR
	}

	neg := false
	start_tok := p.cur
	if p_is_kw(p, "NOT") && p_peek_any_kw(p, "BETWEEN", "IN", "LIKE", "ILIKE") {
		neg = true
		p_advance(p)
	}

	if p_eat_kw(p, "BETWEEN") {
		lo := parse_term(p)
		if p.err.kind != .None {
			return NO_EXPR
		}
		if !p_eat_kw(p, "AND") {
			p_fail(p, .Syntax, "expected AND in BETWEEN expression", p.cur)
			return NO_EXPR
		}
		hi := parse_term(p)
		if p.err.kind != .None {
			return NO_EXPR
		}
		return p_expr(p, start_tok, Expr{kind = .Between, lhs = lhs, rhs = lo, hi = hi, negated = neg})
	}

	if p_eat_kw(p, "IN") {
		if !p_expect(p, .LParen, "expected '(' after IN") {
			return NO_EXPR
		}
		lits := make([dynamic]Literal, p.a)
		unsupported := false
		for p.cur.kind != .RParen && p.cur.kind != .Eof && p.err.kind == .None {
			if l, lok := try_parse_literal(p); lok {
				skip_pg_cast(p)
				if !p_push(p, &lits, l) {
					return NO_EXPR
				}
			} else {
				unsupported = true
				skip_constraint_tail(p)
			}
			if p.cur.kind == .Comma {
				p_advance(p)
				continue
			}
			break
		}
		if !p_expect(p, .RParen, "expected ')' after IN list") {
			return NO_EXPR
		}
		if unsupported {
			return p_unsupported(p, start_tok)
		}
		return p_expr(p, start_tok, Expr{kind = .In_List, lhs = lhs, literals = lits[:], negated = neg})
	}

	if p_eat_kw(p, "LIKE") {
		pat, pok := p_read_string(p)
		if !pok {
			skip_unsupported_atom(p)
			return p_unsupported(p, start_tok)
		}
		skip_pg_cast(p)
		esc: u8
		if p_eat_kw(p, "ESCAPE") {
			es, eok := p_read_string(p)
			if !eok || len(es) != 1 {
				p_fail(p, .Syntax, "expected single-character string literal after ESCAPE", p.cur)
				return NO_EXPR
			}
			esc = es[0]
		}
		return p_expr(p, start_tok, Expr{kind = .Like, lhs = lhs, pattern = pat, escape = esc, negated = neg})
	}

	if p_eat_kw(p, "ILIKE") {
		skip_unsupported_atom(p)
		return p_unsupported(p, start_tok)
	}

	if cmp, is_cmp := token_to_cmp(p.cur.kind); is_cmp {
		tok := p_advance(p)
		rhs := parse_term(p)
		if p.err.kind != .None {
			return NO_EXPR
		}
		if is_arith_op(p.cur.kind) {
			skip_unsupported_atom(p)
			return p_unsupported(p, tok)
		}
		return p_expr(p, tok, Expr{kind = .Compare, cmp = cmp, lhs = lhs, rhs = rhs})
	}

	return lhs
}

@(private = "file")
token_to_cmp :: proc "contextless" (k: Token_Kind) -> (Cmp_Op, bool) {
	#partial switch k {
	case .Eq:  return .Eq, true
	case .Neq: return .Neq, true
	case .Lt:  return .Lt, true
	case .Lte: return .Lte, true
	case .Gt:  return .Gt, true
	case .Gte: return .Gte, true
	}
	return .Eq, false
}

@(private = "file")
parse_term :: proc(p: ^Parser) -> Expr_Index {
	tok := p.cur
	if lit, lok := try_parse_literal(p); lok {
		skip_pg_cast(p)
		return p_expr(p, tok, Expr{kind = .Literal, lit = lit})
	}

	if tok.kind == .Ident || tok.kind == .Quoted_Ident {
		first_raw := token_raw(p.src, tok)
		is_unquoted := tok.kind == .Ident
		name, nok := p_read_ident(p)
		if !nok {
			return NO_EXPR
		}

		if p.cur.kind == .LParen {
			if is_unquoted && (ascii_eq_fold(first_raw, "LENGTH") || ascii_eq_fold(first_raw, "CHAR_LENGTH") || ascii_eq_fold(first_raw, "CHARACTER_LENGTH")) {
				p_advance(p)
				arg_qual, arg_col, aok := p_read_qualified_name(p)
				if aok && p.cur.kind == .RParen {
					p_advance(p)
					skip_pg_cast(p)
					return p_expr(p, tok, Expr{kind = .Length_Call, ident = arg_col, table_qual = arg_qual})
				}
				skip_open_parens(p, 1)
			} else {
				skip_balanced_parens(p)
			}
			skip_pg_cast(p)
			return p_unsupported(p, tok)
		}

		qual := ""
		if p.cur.kind == .Dot {
			p_advance(p)
			second, sok := p_read_ident(p)
			if !sok {
				p_fail(p, .Syntax, "expected column name after '.' in CHECK expression", p.cur)
				return NO_EXPR
			}
			qual = name
			name = second
		}
		skip_pg_cast(p)
		return p_expr(p, tok, Expr{kind = .Ident, ident = name, table_qual = qual})
	}

	if p_eat_kw(p, "CASE") {
		for depth := 1; p.cur.kind != .Eof && depth > 0 && p.err.kind == .None; {
			if p_is_kw(p, "CASE") { depth += 1 } else if p_is_kw(p, "END") { depth -= 1 }
			p_advance(p)
		}
		return p_unsupported(p, tok)
	}

	p_fail(p, .Syntax, "expected column, literal, or expression in CHECK", tok)
	return NO_EXPR
}

@(private = "file")
skip_unsupported_atom :: proc(p: ^Parser) {
	depth := 0
	for p.cur.kind != .Eof && p.err.kind == .None {
		if p.cur.kind == .LParen {
			depth += 1
		} else if p.cur.kind == .RParen {
			if depth == 0 {
				return
			}
			depth -= 1
		} else if depth == 0 && p_is_any_kw(p, "AND", "OR") {
			return
		}
		p_advance(p)
	}
}
