// SQL DDL parser: parses one or more SQL statements, extracting `CREATE TABLE` definitions
// (columns, types, column & table constraints, `CHECK` expressions) and `CREATE TYPE ... AS ENUM`
// definitions while safely skipping non-table statements (`CREATE INDEX`, `COMMENT ON`, `SET`, etc.).
// Uses an explicit heap operator stack with bounded depth (`MAX_EXPR_DEPTH`) for `CHECK` expressions,
// and an internal `mem.Dynamic_Arena` for O(1) leak-free cleanup on all success/error/OOM paths.
// Zero `core:os`, zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.
package ddl

import "base:runtime"
import "core:mem"
import "core:strconv"
import "core:strings"
import "stury:lib/schema/rules"

// Maximum nesting depth for parenthesized or unary `CHECK` expressions.
MAX_EXPR_DEPTH :: 128

// Index into `Parsed.exprs`.
Expr_Index :: distinct i32

NO_EXPR :: Expr_Index(-1)

Sql_Type_Kind :: enum u8 {
	Unknown,
	TinyInt,
	SmallInt,
	MediumInt,
	Int,
	BigInt,
	SmallSerial,
	Serial,
	BigSerial,
	Float,
	Double,
	Numeric,
	Bool,
	Text,
	Varchar,
	Char,
	Uuid,
	Date,
	Time,
	Timestamp,
	Json,
	Bytes,
	Enum,
	Named,
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

Literal_Kind :: enum u8 {
	Null,
	Bool,
	Integer,
	Decimal,
	String,
}

Literal :: struct {
	kind:     Literal_Kind,
	bool_val: bool,
	int_val:  i64,
	text:     string,
}

Cmp_Op :: enum u8 {
	Eq,
	Neq,
	Lt,
	Lte,
	Gt,
	Gte,
}

Expr_Kind :: enum u8 {
	Ident,
	Literal,
	Length_Call,
	Compare,
	Between,
	In_List,
	Is_Null,
	Like,
	And,
	Or,
	Not,
	Unsupported,
}

Expr :: struct {
	kind:       Expr_Kind,
	cmp:        Cmp_Op,
	negated:    bool,
	lhs:        Expr_Index,
	rhs:        Expr_Index,
	hi:         Expr_Index, // upper bound for `.Between`
	ident:      string,     // column name for `.Ident` / `.Length_Call`
	table_qual: string,     // optional table qualifier `t.col`
	lit:        Literal,    // value for `.Literal`
	literals:   []Literal,  // list for `.In_List`
	pattern:    string,     // pattern for `.Like`
	escape:     u8,         // optional `ESCAPE` char for `.Like` (0 for none)
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

// Result of parsing a SQL DDL source buffer. All AST memory is owned by `arena`.
Parsed :: struct {
	tables:      []Table_Def,
	enums:       []Enum_Type_Def,
	exprs:       []Expr,
	arena:       mem.Dynamic_Arena,
	arena_ready: bool,
}

// Frees all memory owned by `p` and resets it to zero.
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
	a:         runtime.Allocator, // AST arena allocator
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
		p_fail_lex(p)
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
p_fail_lex :: proc(p: ^Parser) {
	if p.err.kind != .None {
		return
	}
	msg := p.lex.err_msg if p.lex.err_msg != "" else "lexical error in SQL DDL"
	p.err = make_error(.Syntax, msg, p.lex.err_offset, p.lex.err_line, p.lex.err_col, allocator = p.err_alloc)
}

@(private = "file")
p_fail :: proc(p: ^Parser, kind: Error_Kind, msg: string, tok: Token, table := "", column := "") {
	if p.err.kind != .None {
		return
	}
	p.err = make_error(kind, msg, u64(tok.lo), tok.line, tok.col, table = table, column = column, allocator = p.err_alloc)
}

@(private = "file")
p_oom :: proc(p: ^Parser) {
	if p.err.kind != .None {
		return
	}
	p.err = make_error(.No_Memory, "out of memory", u64(p.cur.lo), p.cur.line, p.cur.col, allocator = p.err_alloc)
}

@(private = "file")
p_is_kw :: proc "contextless" (p: ^Parser, kw: string) -> bool {
	return token_is_kw(p.src, p.cur, kw)
}

@(private = "file")
p_peek_is_kw :: proc(p: ^Parser, kw: string) -> bool {
	return token_is_kw(p.src, p_peek(p), kw)
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
p_read_ident :: proc(p: ^Parser) -> (name: string, ok: bool) {
	if p.cur.kind == .Ident {
		raw := token_raw(p.src, p.cur)
		p_advance(p)
		s := p_clone(p, raw)
		return s, p.err.kind == .None
	}
	if p.cur.kind == .Quoted_Ident {
		tok := p_advance(p)
		dec, derr := decode_quoted(p.src, tok, p.a)
		if derr != nil {
			p_oom(p)
			return "", false
		}
		return dec, true
	}
	return "", false
}

@(private = "file")
p_read_string :: proc(p: ^Parser) -> (s: string, ok: bool) {
	if p.cur.kind != .String {
		return "", false
	}
	tok := p_advance(p)
	dec, derr := decode_quoted(p.src, tok, p.a)
	if derr != nil {
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
p_add_expr :: proc(p: ^Parser, e: Expr) -> Expr_Index {
	if _, aerr := append(&p.exprs, e); aerr != nil {
		p_oom(p)
		return NO_EXPR
	}
	return Expr_Index(len(p.exprs) - 1)
}

// Parses SQL DDL text into a `Parsed` AST holding all `CREATE TABLE` and `CREATE TYPE ... AS ENUM`
// definitions. Non-table statements (such as `CREATE INDEX` or `COMMENT ON`) are skipped cleanly.
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
			continue
		}
		if p_is_kw(&p, "CREATE") {
			parse_create(&p)
			continue
		}
		// Safely skip non-CREATE statements (`SET`, `COMMENT`, `DROP`, `ALTER`, `INSERT`, `PRAGMA`, etc.)
		skip_statement(&p)
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
		} else if p.cur.kind == .RParen {
			if depth > 0 {
				depth -= 1
			}
		} else if p.cur.kind == .Semi && depth == 0 {
			p_advance(p)
			return
		}
		p_advance(p)
	}
}

@(private = "file")
parse_create :: proc(p: ^Parser) {
	start := p_advance(p) // consume CREATE
	_ = start
	// Optional table qualifiers: GLOBAL/LOCAL TEMPORARY | TEMP | UNLOGGED
	_ = p_eat_kw(p, "OR") && p_eat_kw(p, "REPLACE")
	_ = p_eat_kw(p, "GLOBAL") || p_eat_kw(p, "LOCAL")
	_ = p_eat_kw(p, "TEMPORARY") || p_eat_kw(p, "TEMP") || p_eat_kw(p, "UNLOGGED")

	if p_eat_kw(p, "TABLE") {
		parse_create_table(p)
		return
	}
	if p_eat_kw(p, "TYPE") {
		parse_create_type(p)
		return
	}
	// Non-table CREATE (`CREATE INDEX`, `CREATE UNIQUE INDEX`, `CREATE SCHEMA`, `CREATE VIEW`, etc.)
	skip_statement(p)
}

@(private = "file")
parse_create_type :: proc(p: ^Parser) {
	schema_name, name, ok := p_read_qualified_name(p)
	if !ok {
		skip_statement(p)
		return
	}
	if !p_eat_kw(p, "AS") || !p_eat_kw(p, "ENUM") {
		skip_statement(p)
		return
	}
	if !p_expect(p, .LParen, "expected '(' after ENUM") {
		return
	}
	vals := make([dynamic]string, p.a)
	for p.cur.kind != .RParen && p.cur.kind != .Eof && p.err.kind == .None {
		s, sok := p_read_string(p)
		if !sok {
			p_fail(p, .Syntax, "expected string literal in ENUM definition", p.cur)
			return
		}
		if _, aerr := append(&vals, s); aerr != nil {
			p_oom(p)
			return
		}
		if p.cur.kind == .Comma {
			p_advance(p)
			continue
		}
		break
	}
	if !p_expect(p, .RParen, "expected ')' after ENUM values") {
		return
	}
	if p.cur.kind == .Semi {
		p_advance(p)
	}
	if _, aerr := append(&p.enums, Enum_Type_Def{schema_name = schema_name, name = name, values = vals[:]}); aerr != nil {
		p_oom(p)
	}
}

@(private = "file")
parse_create_table :: proc(p: ^Parser) {
	// Optional `IF NOT EXISTS`
	if p_eat_kw(p, "IF") {
		if !p_eat_kw(p, "NOT") || !p_eat_kw(p, "EXISTS") {
			p_fail(p, .Syntax, "expected 'NOT EXISTS' after 'IF'", p.cur)
			return
		}
	}

	name_tok := p.cur
	schema_name, name, ok := p_read_qualified_name(p)
	if !ok {
		p_fail(p, .Syntax, "expected table name after CREATE TABLE", name_tok)
		return
	}

	// Handle `CREATE TABLE x AS SELECT ...` or `CREATE TABLE x LIKE y` gracefully by skipping.
	if p_is_kw(p, "AS") || p_is_kw(p, "LIKE") {
		skip_statement(p)
		return
	}

	if !p_expect(p, .LParen, "expected '(' after table name") {
		return
	}

	tbl := Table_Def {
		schema_name = schema_name,
		name        = name,
		line        = name_tok.line,
		col         = name_tok.col,
		offset      = u64(name_tok.lo),
	}
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
			// Check for duplicate column names (SQL case-insensitive for unquoted).
			for existing in cols {
				if ascii_eq_fold(existing.name, col.name) {
					p_fail(p, .Duplicate_Column, "duplicate column name in CREATE TABLE", Token{lo = u32(col.offset), line = col.line, col = col.col}, table = tbl.name, column = col.name)
					return
				}
			}
			if _, aerr := append(&cols, col); aerr != nil {
				p_oom(p)
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

	// Skip trailing table options (`ENGINE=InnoDB`, `WITHOUT ROWID`, `STRICT`, `WITH (...)`, etc.) up to `;` or EOF.
	skip_table_options(p)
	if p.err.kind != .None {
		return
	}

	tbl.columns = cols[:]
	tbl.uniques = uniques[:]
	tbl.foreign_keys = fks[:]
	tbl.checks = checks[:]

	if _, aerr := append(&p.tables, tbl); aerr != nil {
		p_oom(p)
	}
}

@(private = "file")
skip_table_options :: proc(p: ^Parser) {
	depth := 0
	for p.cur.kind != .Eof && p.err.kind == .None {
		if p.cur.kind == .LParen {
			depth += 1
		} else if p.cur.kind == .RParen {
			if depth > 0 {
				depth -= 1
			} else {
				p_fail(p, .Syntax, "unexpected ')' in table options", p.cur)
				return
			}
		} else if p.cur.kind == .Semi && depth == 0 {
			p_advance(p)
			return
		} else if depth == 0 && p_is_kw(p, "CREATE") {
			// Next statement started without a semicolon.
			return
		}
		p_advance(p)
	}
}

@(private = "file")
is_table_constraint_start :: proc(p: ^Parser) -> bool {
	if p.cur.kind != .Ident {
		return false
	}
	if p_is_kw(p, "CONSTRAINT") || p_is_kw(p, "PRIMARY") || p_is_kw(p, "UNIQUE") ||
		p_is_kw(p, "FOREIGN") || p_is_kw(p, "CHECK") || p_is_kw(p, "FULLTEXT") || p_is_kw(p, "SPATIAL") {
		return true
	}
	// MySQL inline `INDEX [name] (col)` or `KEY [name] (col)` — distinguish from a column named `key TEXT`
	// by peeking: after `INDEX`/`KEY`, if next token is `(` or if next-next is `(`, it's a table index.
	if p_is_kw(p, "INDEX") || p_is_kw(p, "KEY") {
		pk := p_peek(p)
		if pk.kind == .LParen {
			return true
		}
		// Only treat `KEY idx_name (...)` as index if next token is an identifier that is NOT a SQL type keyword
		if pk.kind == .Ident || pk.kind == .Quoted_Ident {
			if pk.kind == .Ident && is_known_type_start(token_raw(p.src, pk)) {
				return false
			}
			return true
		}
	}
	return false
}

@(private = "file")
is_known_type_start :: proc "contextless" (s: string) -> bool {
	return ascii_eq_fold(s, "INT") || ascii_eq_fold(s, "INTEGER") || ascii_eq_fold(s, "BIGINT") ||
		ascii_eq_fold(s, "SMALLINT") || ascii_eq_fold(s, "TINYINT") || ascii_eq_fold(s, "TEXT") ||
		ascii_eq_fold(s, "VARCHAR") || ascii_eq_fold(s, "CHAR") || ascii_eq_fold(s, "CHARACTER") ||
		ascii_eq_fold(s, "BOOL") || ascii_eq_fold(s, "BOOLEAN") || ascii_eq_fold(s, "REAL") ||
		ascii_eq_fold(s, "FLOAT") || ascii_eq_fold(s, "DOUBLE") || ascii_eq_fold(s, "NUMERIC") ||
		ascii_eq_fold(s, "DECIMAL") || ascii_eq_fold(s, "UUID") || ascii_eq_fold(s, "DATE") ||
		ascii_eq_fold(s, "TIME") || ascii_eq_fold(s, "TIMESTAMP") || ascii_eq_fold(s, "TIMESTAMPTZ") ||
		ascii_eq_fold(s, "DATETIME") || ascii_eq_fold(s, "JSON") || ascii_eq_fold(s, "JSONB") ||
		ascii_eq_fold(s, "BYTEA") || ascii_eq_fold(s, "BLOB") || ascii_eq_fold(s, "ENUM") ||
		ascii_eq_fold(s, "SERIAL") || ascii_eq_fold(s, "BIGSERIAL")
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
		if _, aerr := append(uniques, Unique_Constraint{name = cname, columns = cols, primary = true}); aerr != nil {
			p_oom(p)
		}
		return
	}

	if p_eat_kw(p, "UNIQUE") {
		// Optional `NULLS [NOT] DISTINCT` (PostgreSQL 15+) or `INDEX`/`KEY` + optional index name (MySQL)
		if p_eat_kw(p, "NULLS") {
			_ = p_eat_kw(p, "NOT")
			_ = p_eat_kw(p, "DISTINCT")
		}
		_ = p_eat_kw(p, "INDEX") || p_eat_kw(p, "KEY")
		if p.cur.kind != .LParen && (p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident) {
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
		if _, aerr := append(uniques, Unique_Constraint{name = cname, columns = cols, primary = false}); aerr != nil {
			p_oom(p)
		}
		return
	}

	if p_eat_kw(p, "FOREIGN") {
		if !p_eat_kw(p, "KEY") {
			p_fail(p, .Syntax, "expected KEY after FOREIGN", p.cur, table = tbl.name)
			return
		}
		// Optional MySQL index name before `(`
		if p.cur.kind != .LParen && (p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident) {
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
		fk, fok := parse_references_clause(p, cname, cols, tbl.name)
		if !fok {
			return
		}
		if _, aerr := append(fks, fk); aerr != nil {
			p_oom(p)
		}
		return
	}

	if p_eat_kw(p, "CHECK") {
		if !p_expect(p, .LParen, "expected '(' after CHECK") {
			return
		}
		ex := parse_expr(p)
		if p.err.kind != .None {
			return
		}
		if !p_expect(p, .RParen, "expected ')' closing CHECK expression") {
			return
		}
		skip_constraint_tail(p)
		if _, aerr := append(checks, ex); aerr != nil {
			p_oom(p)
		}
		return
	}

	// MySQL `INDEX` / `KEY` / `FULLTEXT` / `SPATIAL` table-level index definitions: skip up to `,` or `)`
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
		if _, aerr := append(&list, nm); aerr != nil {
			p_oom(p)
			return nil
		}
		// Optional MySQL prefix length `(10)` and optional `ASC`/`DESC` / `NULLS FIRST|LAST` / `COLLATE x`
		if p.cur.kind == .LParen {
			skip_balanced_parens(p)
		}
		for {
			if p_eat_kw(p, "ASC") || p_eat_kw(p, "DESC") {
				continue
			}
			if p_eat_kw(p, "COLLATE") {
				if p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident || p.cur.kind == .String {
					p_advance(p)
				}
				continue
			}
			if p_eat_kw(p, "NULLS") {
				_ = p_eat_kw(p, "FIRST") || p_eat_kw(p, "LAST")
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
	// Consume optional referential actions (`MATCH ...`, `ON DELETE ...`, `ON UPDATE ...`, `DEFERRABLE ...`)
	for p.err.kind == .None {
		if p_eat_kw(p, "MATCH") {
			if p.cur.kind == .Ident {
				p_advance(p)
			}
			continue
		}
		if p_eat_kw(p, "ON") {
			_ = p_eat_kw(p, "DELETE") || p_eat_kw(p, "UPDATE")
			if p_eat_kw(p, "NO") {
				_ = p_eat_kw(p, "ACTION")
			} else if p_eat_kw(p, "SET") {
				_ = p_eat_kw(p, "NULL") || p_eat_kw(p, "DEFAULT")
				if p.cur.kind == .LParen {
					skip_balanced_parens(p)
				}
			} else if p_eat_kw(p, "CASCADE") || p_eat_kw(p, "RESTRICT") {
				// consumed
			}
			continue
		}
		break
	}
	// Cleanly consume DEFERRABLE / INITIALLY / NOT DEFERRABLE / NOT ENFORCED without stealing `NOT NULL`.
	consume_deferrable(p)

	return Foreign_Key {
		name        = cname,
		columns     = cols,
		ref_table   = full_ref,
		ref_columns = ref_cols,
	}, true
}

@(private = "file")
consume_deferrable :: proc(p: ^Parser) {
	for p.err.kind == .None {
		if p_is_kw(p, "NOT") && (p_peek_is_kw(p, "DEFERRABLE") || p_peek_is_kw(p, "ENFORCED") || p_peek_is_kw(p, "VALID")) {
			p_advance(p)
			p_advance(p)
			continue
		}
		if p_eat_kw(p, "DEFERRABLE") || p_eat_kw(p, "ENFORCED") {
			continue
		}
		if p_eat_kw(p, "INITIALLY") {
			_ = p_eat_kw(p, "DEFERRED") || p_eat_kw(p, "IMMEDIATE")
			continue
		}
		break
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
skip_balanced_parens :: proc(p: ^Parser) {
	if p.cur.kind != .LParen {
		return
	}
	depth := 0
	for p.cur.kind != .Eof && p.err.kind == .None {
		if p.cur.kind == .LParen {
			depth += 1
		} else if p.cur.kind == .RParen {
			depth -= 1
			if depth == 0 {
				p_advance(p)
				return
			}
		}
		p_advance(p)
	}
}

@(private = "file")
parse_column_def :: proc(p: ^Parser, table_name: string) -> (col: Column_Def, ok: bool) {
	tok := p.cur
	cname, nok := p_read_ident(p)
	if !nok {
		p_fail(p, .Syntax, "expected column name in CREATE TABLE", tok, table = table_name)
		return {}, false
	}
	col.name = cname
	col.line = tok.line
	col.col = tok.col
	col.offset = u64(tok.lo)

	typ, tok_ok := parse_sql_type(p, table_name, cname)
	if !tok_ok {
		return {}, false
	}
	col.type = typ

	checks := make([dynamic]Expr_Index, p.a)

	// Parse zero or more column constraints until `,` or `)`
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
				continue
			}
			if p_eat_kw(p, "DEFERRABLE") || p_eat_kw(p, "ENFORCED") || p_eat_kw(p, "VALID") {
				continue
			}
			p_fail(p, .Syntax, "expected NULL after NOT in column constraint", p.cur, table = table_name, column = col.name)
			return {}, false
		}

		if p_eat_kw(p, "NULL") {
			// Explicitly nullable (default behavior)
			continue
		}

		if p_eat_kw(p, "PRIMARY") {
			if !p_eat_kw(p, "KEY") {
				p_fail(p, .Syntax, "expected KEY after PRIMARY", p.cur, table = table_name, column = col.name)
				return {}, false
			}
			col.primary_key = true
			col.not_null = true
			col.unique = true
			// Optional SQLite `ASC`/`DESC`/`AUTOINCREMENT`/`ON CONFLICT ...`
			_ = p_eat_kw(p, "ASC") || p_eat_kw(p, "DESC")
			_ = p_eat_kw(p, "AUTOINCREMENT")
			if p_eat_kw(p, "ON") && p_eat_kw(p, "CONFLICT") && p.cur.kind == .Ident {
				p_advance(p)
			}
			continue
		}

		if p_eat_kw(p, "UNIQUE") {
			col.unique = true
			if p_eat_kw(p, "NULLS") {
				_ = p_eat_kw(p, "NOT")
				_ = p_eat_kw(p, "DISTINCT")
			}
			if p_eat_kw(p, "ON") && p_eat_kw(p, "CONFLICT") && p.cur.kind == .Ident {
				p_advance(p)
			}
			continue
		}

		if p_eat_kw(p, "DEFAULT") {
			col.has_default = true
			lit, has_lit := parse_default_value(p)
			if p.err.kind != .None {
				return {}, false
			}
			if has_lit {
				col.has_default_lit = true
				col.default_lit = lit
			}
			continue
		}

		if p_eat_kw(p, "CHECK") {
			if !p_expect(p, .LParen, "expected '(' after CHECK") {
				return {}, false
			}
			ex := parse_expr(p)
			if p.err.kind != .None {
				return {}, false
			}
			if !p_expect(p, .RParen, "expected ')' closing CHECK expression") {
				return {}, false
			}
			if _, aerr := append(&checks, ex); aerr != nil {
				p_oom(p)
				return {}, false
			}
			continue
		}

		if p_eat_kw(p, "REFERENCES") {
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
			continue
		}

		if p_eat_kw(p, "AUTO_INCREMENT") || p_eat_kw(p, "AUTOINCREMENT") {
			continue
		}

		if p_eat_kw(p, "GENERATED") {
			_ = p_eat_kw(p, "ALWAYS") || (p_eat_kw(p, "BY") && p_eat_kw(p, "DEFAULT"))
			if p_eat_kw(p, "AS") {
				if p_eat_kw(p, "IDENTITY") {
					if p.cur.kind == .LParen {
						skip_balanced_parens(p)
					}
				} else if p.cur.kind == .LParen {
					skip_balanced_parens(p)
					_ = p_eat_kw(p, "STORED") || p_eat_kw(p, "VIRTUAL")
				}
			}
			continue
		}

		if p_eat_kw(p, "COLLATE") {
			if p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident || p.cur.kind == .String {
				p_advance(p)
			}
			continue
		}

		if p_eat_kw(p, "COMMENT") {
			if p.cur.kind == .String {
				p_advance(p)
			}
			continue
		}

		if p_eat_kw(p, "ON") {
			// MySQL `ON UPDATE CURRENT_TIMESTAMP`
			_ = p_eat_kw(p, "UPDATE") || p_eat_kw(p, "DELETE")
			for p.cur.kind != .Comma && p.cur.kind != .RParen && p.cur.kind != .Eof && p.err.kind == .None &&
				!p_is_kw(p, "NOT") && !p_is_kw(p, "NULL") && !p_is_kw(p, "PRIMARY") &&
				!p_is_kw(p, "UNIQUE") && !p_is_kw(p, "DEFAULT") && !p_is_kw(p, "CHECK") &&
				!p_is_kw(p, "REFERENCES") && !p_is_kw(p, "CONSTRAINT") && !p_is_kw(p, "COMMENT") {
				if p.cur.kind == .LParen {
					skip_balanced_parens(p)
				} else {
					p_advance(p)
				}
			}
			continue
		}

		if p_eat_kw(p, "DEFERRABLE") || p_eat_kw(p, "INITIALLY") || p_eat_kw(p, "ENFORCED") {
			consume_deferrable(p)
			continue
		}

		p_fail(p, .Syntax, "unexpected token in column definition", p.cur, table = table_name, column = col.name)
		return {}, false
	}

	col.checks = checks[:]
	return col, true
}

@(private = "file")
parse_sql_type :: proc(p: ^Parser, table_name, col_name: string) -> (t: Sql_Type, ok: bool) {
	// Handle optional leading `UNSIGNED` / `SIGNED` iteratively (never recursing on repeated `UNSIGNED`).
	leading_unsigned := false
	if p.cur.kind == .Ident && ascii_eq_fold(token_raw(p.src, p.cur), "UNSIGNED") {
		leading_unsigned = true
		p_advance(p)
		if p.cur.kind == .Ident && ascii_eq_fold(token_raw(p.src, p.cur), "UNSIGNED") {
			p_fail(p, .Syntax, "duplicate UNSIGNED modifier in SQL type", p.cur, table = table_name, column = col_name)
			return {}, false
		}
	} else if p.cur.kind == .Ident && ascii_eq_fold(token_raw(p.src, p.cur), "SIGNED") {
		p_advance(p)
		if p.cur.kind == .Ident && (ascii_eq_fold(token_raw(p.src, p.cur), "SIGNED") || ascii_eq_fold(token_raw(p.src, p.cur), "UNSIGNED")) {
			p_fail(p, .Syntax, "duplicate signedness modifier in SQL type", p.cur, table = table_name, column = col_name)
			return {}, false
		}
	}

	tok := p.cur
	if tok.kind != .Ident && tok.kind != .Quoted_Ident {
		p_fail(p, .Syntax, "expected SQL type name for column", tok, table = table_name, column = col_name)
		return {}, false
	}

	// Qualified custom type `schema.my_enum` or plain type name
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
		t.kind = .Named
		t.named = second_name
		parse_array_suffix(p, &t)
		return t, true
	}

	if first_quoted {
		t.kind = .Named
		t.named = first_name
		parse_array_suffix(p, &t)
		return t, true
	}

	// Match multi-word & standard SQL types (case-insensitive)
	switch {
	case ascii_eq_fold(first_raw, "TINYINT"):
		t.kind = .TinyInt
		parse_type_params(p, &t)
		parse_signedness(p, &t)
	case ascii_eq_fold(first_raw, "SMALLINT") || ascii_eq_fold(first_raw, "INT2"):
		t.kind = .SmallInt
		parse_type_params(p, &t)
		parse_signedness(p, &t)
	case ascii_eq_fold(first_raw, "MEDIUMINT"):
		t.kind = .MediumInt
		parse_type_params(p, &t)
		parse_signedness(p, &t)
	case ascii_eq_fold(first_raw, "INT") || ascii_eq_fold(first_raw, "INTEGER") || ascii_eq_fold(first_raw, "INT4"):
		t.kind = .Int
		parse_type_params(p, &t)
		parse_signedness(p, &t)
	case ascii_eq_fold(first_raw, "BIGINT") || ascii_eq_fold(first_raw, "INT8"):
		t.kind = .BigInt
		parse_type_params(p, &t)
		parse_signedness(p, &t)
	case ascii_eq_fold(first_raw, "SMALLSERIAL") || ascii_eq_fold(first_raw, "SERIAL2"):
		t.kind = .SmallSerial
	case ascii_eq_fold(first_raw, "SERIAL") || ascii_eq_fold(first_raw, "SERIAL4"):
		t.kind = .Serial
	case ascii_eq_fold(first_raw, "BIGSERIAL") || ascii_eq_fold(first_raw, "SERIAL8"):
		t.kind = .BigSerial
	case ascii_eq_fold(first_raw, "REAL") || ascii_eq_fold(first_raw, "FLOAT") || ascii_eq_fold(first_raw, "FLOAT4"):
		t.kind = .Float
		parse_type_params(p, &t)
		parse_signedness(p, &t)
	case ascii_eq_fold(first_raw, "DOUBLE") || ascii_eq_fold(first_raw, "FLOAT8"):
		_ = p_eat_kw(p, "PRECISION")
		t.kind = .Double
		parse_type_params(p, &t)
		parse_signedness(p, &t)
	case ascii_eq_fold(first_raw, "NUMERIC") || ascii_eq_fold(first_raw, "DECIMAL") ||
		ascii_eq_fold(first_raw, "DEC") || ascii_eq_fold(first_raw, "FIXED") || ascii_eq_fold(first_raw, "MONEY"):
		t.kind = .Numeric
		parse_type_params(p, &t)
		parse_signedness(p, &t)
	case ascii_eq_fold(first_raw, "BOOL") || ascii_eq_fold(first_raw, "BOOLEAN"):
		t.kind = .Bool
	case ascii_eq_fold(first_raw, "BIT"):
		parse_type_params(p, &t)
		if p.err.kind != .None {
			return {}, false
		}
		if !t.has_len || t.len == 1 {
			t.kind = .Bool
		} else {
			t.kind = .Bytes
		}
	case ascii_eq_fold(first_raw, "CHARACTER") || ascii_eq_fold(first_raw, "CHAR") ||
		ascii_eq_fold(first_raw, "NCHAR") || ascii_eq_fold(first_raw, "BPCHAR"):
		if p_eat_kw(p, "VARYING") {
			t.kind = .Varchar
		} else {
			t.kind = .Char
		}
		parse_type_params(p, &t)
		skip_charset(p)
	case ascii_eq_fold(first_raw, "VARCHAR") || ascii_eq_fold(first_raw, "NVARCHAR") || ascii_eq_fold(first_raw, "VARCHAR2"):
		t.kind = .Varchar
		parse_type_params(p, &t)
		skip_charset(p)
	case ascii_eq_fold(first_raw, "TEXT") || ascii_eq_fold(first_raw, "CLOB") ||
		ascii_eq_fold(first_raw, "TINYTEXT") || ascii_eq_fold(first_raw, "MEDIUMTEXT") ||
		ascii_eq_fold(first_raw, "LONGTEXT") || ascii_eq_fold(first_raw, "STRING") ||
		ascii_eq_fold(first_raw, "CITEXT"):
		t.kind = .Text
		parse_type_params(p, &t)
		skip_charset(p)
	case ascii_eq_fold(first_raw, "UUID"):
		t.kind = .Uuid
	case ascii_eq_fold(first_raw, "DATE"):
		t.kind = .Date
	case ascii_eq_fold(first_raw, "TIME") || ascii_eq_fold(first_raw, "TIMETZ"):
		t.kind = .Time
		parse_type_params(p, &t)
		skip_time_zone(p)
	case ascii_eq_fold(first_raw, "TIMESTAMP") || ascii_eq_fold(first_raw, "TIMESTAMPTZ") || ascii_eq_fold(first_raw, "DATETIME"):
		t.kind = .Timestamp
		parse_type_params(p, &t)
		skip_time_zone(p)
	case ascii_eq_fold(first_raw, "JSON") || ascii_eq_fold(first_raw, "JSONB"):
		t.kind = .Json
	case ascii_eq_fold(first_raw, "BYTEA") || ascii_eq_fold(first_raw, "BLOB") ||
		ascii_eq_fold(first_raw, "TINYBLOB") || ascii_eq_fold(first_raw, "MEDIUMBLOB") ||
		ascii_eq_fold(first_raw, "LONGBLOB") || ascii_eq_fold(first_raw, "BINARY") ||
		ascii_eq_fold(first_raw, "VARBINARY"):
		t.kind = .Bytes
		parse_type_params(p, &t)
	case ascii_eq_fold(first_raw, "ENUM"):
		t.kind = .Enum
		if !p_expect(p, .LParen, "expected '(' after ENUM") {
			return {}, false
		}
		vals := make([dynamic]string, p.a)
		for p.cur.kind != .RParen && p.cur.kind != .Eof && p.err.kind == .None {
			s, sok := p_read_string(p)
			if !sok {
				p_fail(p, .Syntax, "expected string literal inside ENUM(...)", p.cur, table = table_name, column = col_name)
				return {}, false
			}
			if _, aerr := append(&vals, s); aerr != nil {
				p_oom(p)
				return {}, false
			}
			if p.cur.kind == .Comma {
				p_advance(p)
				continue
			}
			break
		}
		if !p_expect(p, .RParen, "expected ')' after ENUM values") {
			return {}, false
		}
		t.enum_values = vals[:]
	case:
		// User-defined type (such as `CREATE TYPE status AS ENUM (...)`) or dialect type
		t.kind = .Named
		t.named = first_name
		if p.cur.kind == .LParen {
			skip_balanced_parens(p)
		}
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
parse_nonneg_int_param :: proc(p: ^Parser, msg: string) -> (val: u64, ok: bool) {
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
	p_advance(p) // consume '('
	if p_is_kw(p, "MAX") {
		// SQL Server `VARCHAR(MAX)` / `NVARCHAR(MAX)` -> unbounded
		p_advance(p)
	} else {
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
	// Allow optional Oracle `CHAR` / `BYTE` length unit (e.g. `VARCHAR2(50 CHAR)`)
	if p_is_kw(p, "CHAR") || p_is_kw(p, "BYTE") {
		p_advance(p)
	}
	_ = p_expect(p, .RParen, "expected ')' closing type parameters")
}

@(private = "file")
parse_signedness :: proc(p: ^Parser, t: ^Sql_Type) {
	for {
		if p_eat_kw(p, "UNSIGNED") {
			t.unsigned = true
			continue
		}
		if p_eat_kw(p, "SIGNED") || p_eat_kw(p, "ZEROFILL") {
			continue
		}
		break
	}
}

@(private = "file")
skip_time_zone :: proc(p: ^Parser) {
	if p_eat_kw(p, "WITH") || p_eat_kw(p, "WITHOUT") {
		_ = p_eat_kw(p, "TIME")
		_ = p_eat_kw(p, "ZONE")
	}
}

@(private = "file")
skip_charset :: proc(p: ^Parser) {
	if p_eat_kw(p, "CHARACTER") && p_eat_kw(p, "SET") {
		if p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident {
			p_advance(p)
		}
	} else if p_eat_kw(p, "CHARSET") {
		if p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident {
			p_advance(p)
		}
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
parse_default_value :: proc(p: ^Parser) -> (lit: Literal, has_lit: bool) {
	// Optional surrounding parentheses around literal: `DEFAULT (0)` or `DEFAULT ('a')`
	unwrapped := false
	if p.cur.kind == .LParen {
		// Peek inside to see if it's a complex expression vs simple literal
		p_advance(p)
		unwrapped = true
	}

	if l, ok := try_parse_literal(p); ok {
		skip_pg_cast(p)
		if unwrapped {
			if p.cur.kind == .RParen {
				p_advance(p)
				skip_pg_cast(p)
				return l, true
			}
			// Complex expression starting with literal inside parens, e.g. `DEFAULT (1 + 2)`
			depth := 1
			for p.cur.kind != .Eof && depth > 0 && p.err.kind == .None {
				if p.cur.kind == .LParen {
					depth += 1
				} else if p.cur.kind == .RParen {
					depth -= 1
				}
				p_advance(p)
			}
			skip_pg_cast(p)
			return {}, false
		}
		// If followed by binary operator (e.g. `DEFAULT 1 + 2`), skip rest of expression
		if p.cur.kind == .Plus || p.cur.kind == .Minus || p.cur.kind == .Star ||
			p.cur.kind == .Slash || p.cur.kind == .Concat {
			skip_default_expr_tail(p)
			return {}, false
		}
		return l, true
	}

	// Non-literal default expression (`CURRENT_TIMESTAMP`, `NOW()`, `gen_random_uuid()`, `(expr)`)
	if unwrapped {
		depth := 1
		for p.cur.kind != .Eof && depth > 0 && p.err.kind == .None {
			if p.cur.kind == .LParen {
				depth += 1
			} else if p.cur.kind == .RParen {
				depth -= 1
			}
			p_advance(p)
		}
		skip_pg_cast(p)
		return {}, false
	}

	skip_default_expr_tail(p)
	return {}, false
}

@(private = "file")
skip_default_expr_tail :: proc(p: ^Parser) {
	depth := 0
	for p.cur.kind != .Eof && p.err.kind == .None {
		if p.cur.kind == .LParen {
			depth += 1
			p_advance(p)
			continue
		}
		if p.cur.kind == .RParen {
			if depth == 0 {
				return
			}
			depth -= 1
			p_advance(p)
			continue
		}
		if depth == 0 {
			if p.cur.kind == .Comma {
				return
			}
			if p_is_kw(p, "NOT") || p_is_kw(p, "NULL") || p_is_kw(p, "PRIMARY") ||
				p_is_kw(p, "UNIQUE") || p_is_kw(p, "CHECK") || p_is_kw(p, "REFERENCES") ||
				p_is_kw(p, "CONSTRAINT") || p_is_kw(p, "COLLATE") || p_is_kw(p, "COMMENT") ||
				p_is_kw(p, "AUTO_INCREMENT") || p_is_kw(p, "AUTOINCREMENT") ||
				p_is_kw(p, "GENERATED") || p_is_kw(p, "ON") || p_is_kw(p, "DEFERRABLE") {
				return
			}
		}
		p_advance(p)
	}
}

@(private = "file")
skip_pg_cast :: proc(p: ^Parser) {
	for p.cur.kind == .Cast {
		p_advance(p)
		// Consume cast target type (`text`, `character varying(50)`, `numeric(10, 2)`, `text[]`, etc.)
		if p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident {
			p_advance(p)
			if p.cur.kind == .Dot {
				p_advance(p)
				if p.cur.kind == .Ident || p.cur.kind == .Quoted_Ident {
					p_advance(p)
				}
			}
			_ = p_eat_kw(p, "VARYING") || p_eat_kw(p, "PRECISION")
			if p.cur.kind == .LParen {
				skip_balanced_parens(p)
			}
			skip_time_zone(p)
			for p.cur.kind == .Empty_Brackets {
				p_advance(p)
			}
		}
	}
}

@(private = "file")
try_parse_literal :: proc(p: ^Parser) -> (lit: Literal, ok: bool) {
	if p_eat_kw(p, "NULL") {
		return Literal{kind = .Null}, true
	}
	if p_eat_kw(p, "TRUE") {
		return Literal{kind = .Bool, bool_val = true}, true
	}
	if p_eat_kw(p, "FALSE") {
		return Literal{kind = .Bool, bool_val = false}, true
	}
	if p.cur.kind == .String {
		s, sok := p_read_string(p)
		if !sok {
			return {}, false
		}
		return Literal{kind = .String, text = s}, true
	}
	neg := false
	signed := false
	if p.cur.kind == .Minus || p.cur.kind == .Plus {
		pk := p_peek(p)
		if pk.kind != .Number {
			return {}, false
		}
		neg = p.cur.kind == .Minus
		signed = true
		p_advance(p)
	}
	if p.cur.kind == .Number {
		raw := token_raw(p.src, p.cur)
		p_advance(p)
		text := raw
		if signed {
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
		} else {
			text = p_clone(p, raw)
		}
		// Normalize `.5` -> `0.5` and `5.` -> `5` directly into arena `p.a`
		if !rules.valid_decimal_text(text) || strings.has_prefix(text, ".") || strings.has_prefix(text, "-.") || strings.has_suffix(text, ".") {
			norm, _, nok := rules.normalize_decimal_text(text, nil, p.a)
			if nok {
				text = norm
			}
		}
		is_int := !strings.contains_any(text, ".eE")
		if is_int {
			if iv, iok := strconv.parse_i64(text); iok {
				return Literal{kind = .Integer, int_val = iv, text = text}, true
			}
		}
		return Literal{kind = .Decimal, text = text}, true
	}
	return {}, false
}

// ============================================================================
// Explicit-stack, bounded-depth SQL `CHECK` expression parser
// ============================================================================

@(private = "file")
Op_Kind :: enum u8 {
	LParen,
	Or,
	And,
	Not,
}

@(private = "file")
Op_Entry :: struct {
	kind:   Op_Kind,
	line:   u32,
	col:    u32,
	offset: u64,
}

@(private = "file")
op_prec :: proc "contextless" (k: Op_Kind) -> int {
	switch k {
	case .LParen:
		return 0
	case .Or:
		return 1
	case .And:
		return 2
	case .Not:
		return 3
	}
	return 0
}

@(private = "file")
reduce_op :: proc(p: ^Parser, op: Op_Entry, vals: ^[dynamic]Expr_Index) -> bool {
	if op.kind == .Not {
		if len(vals) < 1 {
			p_fail(p, .Syntax, "missing operand for NOT in CHECK expression", Token{lo = u32(op.offset), line = op.line, col = op.col})
			return false
		}
		child := pop(vals)
		idx := p_add_expr(p, Expr{kind = .Not, lhs = child, line = op.line, col = op.col, offset = op.offset})
		if idx == NO_EXPR {
			return false
		}
		if _, aerr := append(vals, idx); aerr != nil {
			p_oom(p)
			return false
		}
		return true
	}
	if op.kind == .And || op.kind == .Or {
		if len(vals) < 2 {
			p_fail(p, .Syntax, "missing operand for boolean operator in CHECK expression", Token{lo = u32(op.offset), line = op.line, col = op.col})
			return false
		}
		rhs := pop(vals)
		lhs := pop(vals)
		ek: Expr_Kind = .And if op.kind == .And else .Or
		idx := p_add_expr(p, Expr{kind = ek, lhs = lhs, rhs = rhs, line = op.line, col = op.col, offset = op.offset})
		if idx == NO_EXPR {
			return false
		}
		if _, aerr := append(vals, idx); aerr != nil {
			p_oom(p)
			return false
		}
		return true
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
			if p.cur.kind == .LParen {
				paren_depth += 1
				if paren_depth + not_chain > MAX_EXPR_DEPTH {
					p_fail(p, .Depth_Limit, "CHECK expression nesting depth exceeded", p.cur)
					return NO_EXPR
				}
				tok := p_advance(p)
				if _, aerr := append(&ops, Op_Entry{kind = .LParen, line = tok.line, col = tok.col, offset = u64(tok.lo)}); aerr != nil {
					p_oom(p)
					return NO_EXPR
				}
				continue
			}
			if p_is_kw(p, "NOT") {
				not_chain += 1
				if paren_depth + not_chain > MAX_EXPR_DEPTH {
					p_fail(p, .Depth_Limit, "CHECK expression nesting depth exceeded", p.cur)
					return NO_EXPR
				}
				tok := p_advance(p)
				if _, aerr := append(&ops, Op_Entry{kind = .Not, line = tok.line, col = tok.col, offset = u64(tok.lo)}); aerr != nil {
					p_oom(p)
					return NO_EXPR
				}
				continue
			}

			// Parse an atomic term + optional comparison/predicate (`=`, `IN`, `BETWEEN`, `IS NULL`, `LIKE`)
			atom := parse_predicate(p)
			if p.err.kind != .None {
				return NO_EXPR
			}
			if _, aerr := append(&vals, atom); aerr != nil {
				p_oom(p)
				return NO_EXPR
			}
			not_chain = 0
			expect_operand = false
			continue
		}

		// Expecting binary operator (`AND`, `OR`) or closing `)`
		if p.cur.kind == .RParen {
			if paren_depth == 0 {
				break // Closing ')' of the surrounding `CHECK (...)`!
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
			// Handle parenthesized term followed by predicate operator, e.g. `(age) >= 0`
			if len(vals) > 0 && is_predicate_continuation(p) {
				lhs := pop(&vals)
				pred := parse_predicate_rhs(p, lhs)
				if p.err.kind != .None {
					return NO_EXPR
				}
				if _, aerr := append(&vals, pred); aerr != nil {
					p_oom(p)
					return NO_EXPR
				}
			}
			continue
		}

		if p_is_kw(p, "AND") || p_is_kw(p, "OR") {
			tok := p_advance(p)
			okind: Op_Kind = .And if token_is_kw(p.src, tok, "AND") else .Or
			prec := op_prec(okind)
			for len(ops) > 0 {
				top := ops[len(ops) - 1]
				if top.kind == .LParen || op_prec(top.kind) < prec {
					break
				}
				pop(&ops)
				if !reduce_op(p, top, &vals) {
					return NO_EXPR
				}
			}
			if _, aerr := append(&ops, Op_Entry{kind = okind, line = tok.line, col = tok.col, offset = u64(tok.lo)}); aerr != nil {
				p_oom(p)
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
	#partial switch p.cur.kind {
	case .Eq, .Neq, .Lt, .Lte, .Gt, .Gte, .Plus, .Minus, .Star, .Slash, .Percent, .Concat:
		return true
	}
	if p_is_kw(p, "BETWEEN") || p_is_kw(p, "IN") || p_is_kw(p, "IS") || p_is_kw(p, "LIKE") || p_is_kw(p, "ILIKE") {
		return true
	}
	if p_is_kw(p, "NOT") {
		if p_peek_is_kw(p, "BETWEEN") || p_peek_is_kw(p, "IN") || p_peek_is_kw(p, "LIKE") || p_peek_is_kw(p, "ILIKE") {
			return true
		}
	}
	return false
}

@(private = "file")
parse_predicate :: proc(p: ^Parser) -> Expr_Index {
	lhs := parse_term(p)
	if p.err.kind != .None {
		return NO_EXPR
	}
	return parse_predicate_rhs(p, lhs)
}

@(private = "file")
parse_predicate_rhs :: proc(p: ^Parser, lhs: Expr_Index) -> Expr_Index {
	// If arithmetic / string-concat follows, skip the unsupported expression atom cleanly.
	if p.cur.kind == .Plus || p.cur.kind == .Minus || p.cur.kind == .Star ||
		p.cur.kind == .Slash || p.cur.kind == .Percent || p.cur.kind == .Concat {
		tok := p.cur
		skip_unsupported_atom(p)
		return p_add_expr(p, Expr{kind = .Unsupported, line = tok.line, col = tok.col, offset = u64(tok.lo)})
	}

	// `IS [NOT] NULL` / `IS [NOT] TRUE|FALSE`
	if p_is_kw(p, "IS") {
		tok := p_advance(p)
		neg := p_eat_kw(p, "NOT")
		if p_eat_kw(p, "NULL") {
			return p_add_expr(p, Expr{kind = .Is_Null, lhs = lhs, negated = neg, line = tok.line, col = tok.col, offset = u64(tok.lo)})
		}
		if p_is_kw(p, "TRUE") || p_is_kw(p, "FALSE") {
			bval := p_is_kw(p, "TRUE")
			btok := p_advance(p)
			lit_idx := p_add_expr(p, Expr{
				kind   = .Literal,
				lit    = Literal{kind = .Bool, bool_val = bval},
				line   = btok.line,
				col    = btok.col,
				offset = u64(btok.lo),
			})
			if lit_idx == NO_EXPR {
				return NO_EXPR
			}
			return p_add_expr(p, Expr{
				kind   = .Compare,
				cmp    = .Neq if neg else .Eq,
				lhs    = lhs,
				rhs    = lit_idx,
				line   = tok.line,
				col    = tok.col,
				offset = u64(tok.lo),
			})
		}
		p_fail(p, .Syntax, "expected NULL after IS", p.cur)
		return NO_EXPR
	}

	// Optional `NOT` prefix for `NOT BETWEEN`, `NOT IN`, `NOT LIKE`
	neg := false
	start_tok := p.cur
	if p_is_kw(p, "NOT") && (p_peek_is_kw(p, "BETWEEN") || p_peek_is_kw(p, "IN") || p_peek_is_kw(p, "LIKE") || p_peek_is_kw(p, "ILIKE")) {
		neg = true
		p_advance(p)
	}

	// `[NOT] BETWEEN lo AND hi`
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
		return p_add_expr(p, Expr{kind = .Between, lhs = lhs, rhs = lo, hi = hi, negated = neg, line = start_tok.line, col = start_tok.col, offset = u64(start_tok.lo)})
	}

	// `[NOT] IN (lit1, lit2, ...)`
	if p_eat_kw(p, "IN") {
		if !p_expect(p, .LParen, "expected '(' after IN") {
			return NO_EXPR
		}
		lits := make([dynamic]Literal, p.a)
		unsupported := false
		for p.cur.kind != .RParen && p.cur.kind != .Eof && p.err.kind == .None {
			l, lok := try_parse_literal(p)
			if !lok {
				unsupported = true
				skip_until_comma_or_rparen(p)
			} else {
				skip_pg_cast(p)
				if _, aerr := append(&lits, l); aerr != nil {
					p_oom(p)
					return NO_EXPR
				}
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
			return p_add_expr(p, Expr{kind = .Unsupported, line = start_tok.line, col = start_tok.col, offset = u64(start_tok.lo)})
		}
		return p_add_expr(p, Expr{kind = .In_List, lhs = lhs, literals = lits[:], negated = neg, line = start_tok.line, col = start_tok.col, offset = u64(start_tok.lo)})
	}

	// `[NOT] LIKE 'pat' [ESCAPE 'c']`
	if p_eat_kw(p, "LIKE") {
		pat, pok := p_read_string(p)
		if !pok {
			skip_unsupported_atom(p)
			return p_add_expr(p, Expr{kind = .Unsupported, line = start_tok.line, col = start_tok.col, offset = u64(start_tok.lo)})
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
		return p_add_expr(p, Expr{kind = .Like, lhs = lhs, pattern = pat, escape = esc, negated = neg, line = start_tok.line, col = start_tok.col, offset = u64(start_tok.lo)})
	}

	if p_eat_kw(p, "ILIKE") {
		skip_unsupported_atom(p)
		return p_add_expr(p, Expr{kind = .Unsupported, line = start_tok.line, col = start_tok.col, offset = u64(start_tok.lo)})
	}

	// Comparison operators: `=`, `!=`, `<>`, `<`, `<=`, `>`, `>=`
	cmp, is_cmp := token_to_cmp(p.cur.kind)
	if is_cmp {
		tok := p_advance(p)
		rhs := parse_term(p)
		if p.err.kind != .None {
			return NO_EXPR
		}
		// If arithmetic continues on RHS (e.g. `a < b + 1`), mark unsupported and skip cleanly
		if p.cur.kind == .Plus || p.cur.kind == .Minus || p.cur.kind == .Star ||
			p.cur.kind == .Slash || p.cur.kind == .Percent || p.cur.kind == .Concat {
			skip_unsupported_atom(p)
			return p_add_expr(p, Expr{kind = .Unsupported, line = tok.line, col = tok.col, offset = u64(tok.lo)})
		}
		return p_add_expr(p, Expr{kind = .Compare, cmp = cmp, lhs = lhs, rhs = rhs, line = tok.line, col = tok.col, offset = u64(tok.lo)})
	}

	return lhs
}

@(private = "file")
token_to_cmp :: proc "contextless" (k: Token_Kind) -> (Cmp_Op, bool) {
	#partial switch k {
	case .Eq:
		return .Eq, true
	case .Neq:
		return .Neq, true
	case .Lt:
		return .Lt, true
	case .Lte:
		return .Lte, true
	case .Gt:
		return .Gt, true
	case .Gte:
		return .Gte, true
	}
	return .Eq, false
}

@(private = "file")
parse_term :: proc(p: ^Parser) -> Expr_Index {
	tok := p.cur
	if lit, lok := try_parse_literal(p); lok {
		skip_pg_cast(p)
		return p_add_expr(p, Expr{kind = .Literal, lit = lit, line = tok.line, col = tok.col, offset = u64(tok.lo)})
	}

	// Function call or identifier: `LENGTH(col)`, `CHAR_LENGTH(col)`, `CHARACTER_LENGTH(col)`, `col`, `table.col`
	if tok.kind == .Ident || tok.kind == .Quoted_Ident {
		first_raw := token_raw(p.src, tok)
		is_unquoted := tok.kind == .Ident
		name, nok := p_read_ident(p)
		if !nok {
			return NO_EXPR
		}

		// Function call `NAME(...)`
		if p.cur.kind == .LParen {
			if is_unquoted && (ascii_eq_fold(first_raw, "LENGTH") || ascii_eq_fold(first_raw, "CHAR_LENGTH") || ascii_eq_fold(first_raw, "CHARACTER_LENGTH")) {
				p_advance(p) // consume '('
				arg_qual, arg_col, aok := p_read_qualified_name(p)
				if aok && p.cur.kind == .RParen {
					p_advance(p)
					skip_pg_cast(p)
					return p_add_expr(p, Expr{
						kind       = .Length_Call,
						ident      = arg_col,
						table_qual = arg_qual,
						line       = tok.line,
						col        = tok.col,
						offset     = u64(tok.lo),
					})
				}
				// Complex argument inside LENGTH(...): skip to matching ')' and return Unsupported
				depth := 1
				for p.cur.kind != .Eof && depth > 0 && p.err.kind == .None {
					if p.cur.kind == .LParen {
						depth += 1
					} else if p.cur.kind == .RParen {
						depth -= 1
					}
					p_advance(p)
				}
				skip_pg_cast(p)
				return p_add_expr(p, Expr{kind = .Unsupported, line = tok.line, col = tok.col, offset = u64(tok.lo)})
			}
			// Unknown function call (e.g. `LOWER(col)`, `TRIM(col)`, `COALESCE(...)`): skip cleanly as Unsupported
			skip_balanced_parens(p)
			skip_pg_cast(p)
			return p_add_expr(p, Expr{kind = .Unsupported, line = tok.line, col = tok.col, offset = u64(tok.lo)})
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
		return p_add_expr(p, Expr{kind = .Ident, ident = name, table_qual = qual, line = tok.line, col = tok.col, offset = u64(tok.lo)})
	}

	// `CASE ... END` or other SQL expression: skip cleanly as Unsupported
	if p_is_kw(p, "CASE") {
		depth := 1
		p_advance(p)
		for p.cur.kind != .Eof && depth > 0 && p.err.kind == .None {
			if p_is_kw(p, "CASE") {
				depth += 1
			} else if p_is_kw(p, "END") {
				depth -= 1
			}
			p_advance(p)
		}
		return p_add_expr(p, Expr{kind = .Unsupported, line = tok.line, col = tok.col, offset = u64(tok.lo)})
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
			p_advance(p)
			continue
		}
		if p.cur.kind == .RParen {
			if depth == 0 {
				return
			}
			depth -= 1
			p_advance(p)
			continue
		}
		if depth == 0 && (p_is_kw(p, "AND") || p_is_kw(p, "OR")) {
			return
		}
		p_advance(p)
	}
}

@(private = "file")
skip_until_comma_or_rparen :: proc(p: ^Parser) {
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
