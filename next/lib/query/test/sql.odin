package query_test

import "core:strings"
import "stury:lib/query"

// A small SQL over an array of records, a second language over the engine to prove it holds no jq: SELECT with
// WHERE, GROUP BY, ORDER BY and the aggregates COUNT, SUM, AVG, MIN, MAX and MEDIAN, with SQL's semantics. NULL is
// three-valued and an absent column reads as NULL; `/` of integers truncates; NULLs sort last, as `SQL_ORDER` says;
// groups are found by the engine's hash and sorted by its order.

SQL_ORDER :: query.Collation {
	rank = {.False = 0, .True = 1, .Number = 2, .String = 3, .Array = 4, .Object = 5, .Null = 6, .Absent = 6},
}

@(private)
Sql_Kind :: enum u8 {
	Column,
	Literal,
	Not,
	Negate,
	Binary,
	Is_Null,
	Is_Not_Null,
	Aggregate,
}

@(private)
Sql_Op :: enum u8 {
	None,
	Or,
	And,
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
	Add,
	Sub,
	Mul,
	Div,
	Rem,
	Concat,
}

@(private)
Sql_Agg :: enum u8 {
	Count,
	Sum,
	Avg,
	Min,
	Max,
	Median,
}

@(private)
Sql_Expr :: struct {
	kind:  Sql_Kind,
	op:    Sql_Op,
	agg:   Sql_Agg,
	star:  bool, // COUNT(*)
	name:  string,
	value: query.Value,
	a, b:  ^Sql_Expr,
}

@(private)
Sql_Item :: struct {
	expr: ^Sql_Expr, // nil for `*`
	name: string,
}

@(private)
Sql_Key :: struct {
	expr: ^Sql_Expr,
	desc: bool,
}

@(private)
Sql_Query :: struct {
	items:    [dynamic]Sql_Item,
	filter:   ^Sql_Expr,
	group:    [dynamic]^Sql_Expr,
	order:    [dynamic]Sql_Key,
	literals: [dynamic]query.Value,
	grouped:  bool, // GROUP BY or an aggregate: one output row per group
}

@(private)
Sql_Parser :: struct {
	h:     ^query.Heap,
	src:   string,
	at:    int,
	tok:   string, // the current token, "" at the end
	start: int, // where it starts
	quote: bool, // the token is a quoted text, its contents in `tok`
	q:     ^Sql_Query,
	err:   string,
}

// The rows SQL statement `src` selects from array `input`, as an array of objects, or the parse error.
sql_run :: proc(h: ^query.Heap, src: string, input: query.Value) -> (res: query.Value, err: string, status: query.Status) {
	// The statement and the rows it groups live for the call only.
	context.allocator = context.temp_allocator
	q: Sql_Query
	defer {
		for v in q.literals {
			query.release(h, v)
		}
	}
	p := Sql_Parser{h = h, src = src, q = &q}
	advance(&p)
	if !parse_query(&p) {
		return query.NULL, p.err, .Ok
	}
	res, status = sql_select(h, &q, input)
	return res, "", status
}

@(private)
advance :: proc(p: ^Sql_Parser) {
	s := p.src
	for p.at < len(s) && strings.is_space(rune(s[p.at])) {
		p.at += 1
	}
	start := p.at
	p.start, p.quote = start, false
	if p.at >= len(s) {
		p.tok = ""
		return
	}
	c := s[p.at]
	switch {
	case c == '\'':
		p.at += 1
		for p.at < len(s) && s[p.at] != '\'' {
			p.at += 1
		}
		p.tok, p.quote = s[start + 1:p.at], true
		p.at = min(p.at + 1, len(s))
		return
	case is_word(c) || c >= '0' && c <= '9':
		for p.at < len(s) && (is_word(s[p.at]) || s[p.at] >= '0' && s[p.at] <= '9' || s[p.at] == '.') {
			p.at += 1
		}
	case strings.has_prefix(s[p.at:], "<=") || strings.has_prefix(s[p.at:], ">=") || strings.has_prefix(s[p.at:], "<>") || strings.has_prefix(s[p.at:], "!=") || strings.has_prefix(s[p.at:], "||"):
		p.at += 2
	case:
		p.at += 1
	}
	p.tok = s[start:p.at]
}

@(private)
is_word :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_'
}

// Whether the current token is keyword or symbol `w`, taking it when it is.
@(private)
take :: proc(p: ^Sql_Parser, w: string) -> bool {
	if p.quote || !strings.equal_fold(p.tok, w) {
		return false
	}
	advance(p)
	return true
}

@(private)
expect :: proc(p: ^Sql_Parser, w: string) -> bool {
	if take(p, w) {
		return true
	}
	if p.err == "" {
		p.err = strings.concatenate({"expected ", w, " at '", p.tok, "'"}, context.temp_allocator)
	}
	return false
}

@(private)
KEYWORDS := [?]string{"select", "from", "where", "group", "order", "by", "as", "and", "or", "not", "is", "null", "asc", "desc"}

@(private)
parse_query :: proc(p: ^Sql_Parser) -> bool {
	q := p.q
	expect(p, "select") or_return
	for {
		if take(p, "*") {
			append(&q.items, Sql_Item{})
		} else {
			start := p.start
			e := parse_expr(p) or_return
			item := Sql_Item{expr = e, name = strings.trim_space(p.src[start:p.start])}
			if e.kind == .Column {
				item.name = e.name
			}
			if take(p, "as") {
				item.name = p.tok
				advance(p)
			}
			append(&q.items, item)
		}
		if !take(p, ",") {
			break
		}
	}
	if take(p, "from") {
		advance(p)
	}
	if take(p, "where") {
		q.filter = parse_expr(p) or_return
	}
	if take(p, "group") {
		expect(p, "by") or_return
		for {
			append(&q.group, parse_expr(p) or_return)
			if !take(p, ",") {
				break
			}
		}
		q.grouped = true
	}
	if take(p, "order") {
		expect(p, "by") or_return
		for {
			k := Sql_Key{expr = parse_expr(p) or_return}
			if take(p, "desc") {
				k.desc = true
			} else {
				take(p, "asc")
			}
			append(&q.order, k)
			if !take(p, ",") {
				break
			}
		}
	}
	if p.tok != "" && p.err == "" {
		p.err = strings.concatenate({"unexpected '", p.tok, "'"}, context.temp_allocator)
	}
	return p.err == ""
}

@(private)
node :: proc(e: Sql_Expr) -> ^Sql_Expr {
	n := new(Sql_Expr, context.temp_allocator)
	n^ = e
	return n
}

@(private)
parse_expr :: proc(p: ^Sql_Parser) -> (e: ^Sql_Expr, ok: bool) {
	return parse_binary(p, 0)
}

// The binary operators by precedence, lowest first.
@(private)
LEVELS := [?][]struct {
	sym: string,
	op:  Sql_Op,
}{{{"or", .Or}}, {{"and", .And}}, {{"=", .Eq}, {"<>", .Ne}, {"!=", .Ne}, {"<=", .Le}, {">=", .Ge}, {"<", .Lt}, {">", .Gt}}, {{"+", .Add}, {"-", .Sub}, {"||", .Concat}}, {{"*", .Mul}, {"/", .Div}, {"%", .Rem}}}

@(private)
parse_binary :: proc(p: ^Sql_Parser, level: int) -> (e: ^Sql_Expr, ok: bool) {
	if level == len(LEVELS) {
		return parse_unary(p)
	}
	if level == 2 && take(p, "not") {
		a := parse_binary(p, 2) or_return
		return node({kind = .Not, a = a}), true
	}
	a := parse_binary(p, level + 1) or_return
	outer: for {
		if level == 2 && take(p, "is") {
			kind := Sql_Kind.Is_Not_Null if take(p, "not") else .Is_Null
			expect(p, "null") or_return
			a = node({kind = kind, a = a})
			continue
		}
		for o in LEVELS[level] {
			if take(p, o.sym) {
				b := parse_binary(p, level + 1) or_return
				a = node({kind = .Binary, op = o.op, a = a, b = b})
				continue outer
			}
		}
		return a, true
	}
}

@(private)
parse_unary :: proc(p: ^Sql_Parser) -> (e: ^Sql_Expr, ok: bool) {
	tok := p.tok
	switch {
	case p.quote:
		advance(p)
		v, s := query.text_value(p.h, tok)
		if s != .Ok {
			return nil, false
		}
		append(&p.q.literals, v)
		return node({kind = .Literal, value = v}), true
	case take(p, "-"):
		a := parse_unary(p) or_return
		return node({kind = .Negate, a = a}), true
	case take(p, "("):
		a := parse_expr(p) or_return
		expect(p, ")") or_return
		return a, true
	case take(p, "null"):
		return node({kind = .Literal, value = query.NULL}), true
	case take(p, "true"):
		return node({kind = .Literal, value = query.TRUE}), true
	case take(p, "false"):
		return node({kind = .Literal, value = query.FALSE}), true
	case tok != "" && tok[0] >= '0' && tok[0] <= '9':
		advance(p)
		v, read, s := query.parse_number(p.h, tok)
		if s != .Ok || !read {
			p.err = "bad number"
			return nil, false
		}
		append(&p.q.literals, v)
		return node({kind = .Literal, value = v}), true
	case tok != "" && is_word(tok[0]):
		advance(p)
		for name, agg in AGGREGATES {
			if strings.equal_fold(tok, name) && take(p, "(") {
				e = node({kind = .Aggregate, agg = agg})
				if agg == .Count && take(p, "*") {
					e.star = true
				} else {
					e.a = parse_expr(p) or_return
				}
				expect(p, ")") or_return
				p.q.grouped = true
				return e, true
			}
		}
		for k in KEYWORDS {
			if strings.equal_fold(tok, k) {
				p.err = strings.concatenate({"unexpected '", tok, "'"}, context.temp_allocator)
				return nil, false
			}
		}
		return node({kind = .Column, name = tok}), true
	}
	p.err = strings.concatenate({"unexpected '", tok, "'"}, context.temp_allocator)
	return nil, false
}

@(private)
AGGREGATES := [Sql_Agg]string {
	.Count  = "count",
	.Sum    = "sum",
	.Avg    = "avg",
	.Min    = "min",
	.Max    = "max",
	.Median = "median",
}

@(private)
sql_select :: proc(h: ^query.Heap, q: ^Sql_Query, input: query.Value) -> (res: query.Value, status: query.Status) {
	if query.type_of(input) != .Array {
		return query.NULL, query.fail(h, .Types, .Iterate, input)
	}
	all := query.built(h, input) or_return
	defer query.release(h, all)
	kept := make([dynamic]query.Value, context.temp_allocator)
	for r in query.items_of(all) {
		if q.filter != nil {
			c := sql_eval(h, q.filter, r, nil) or_return
			if c.kind != .True {
				query.release(h, c)
				continue
			}
		}
		append(&kept, r)
	}
	out := query.make_array(h, len(kept)) or_return
	if q.grouped {
		status = sql_groups(h, q, kept[:], &out)
	} else {
		for r in kept {
			if status = sql_row(h, q, r, nil, &out); status != .Ok {
				break
			}
		}
	}
	if status == .Ok {
		status = sql_order(h, q, &out)
	}
	if status != .Ok {
		query.release(h, out)
		return query.NULL, status
	}
	return out, .Ok
}

// One output row per group of `rows` with equal GROUP BY values, in the order each group first occurs; with no GROUP
// BY, one group of every row.
@(private)
sql_groups :: proc(h: ^query.Heap, q: ^Sql_Query, rows: []query.Value, out: ^query.Value) -> query.Status {
	keys := make([]query.Value, len(rows), context.temp_allocator)
	defer {
		for k in keys {
			query.release(h, k)
		}
	}
	for r, i in rows {
		k := query.make_array(h, len(q.group)) or_return
		keys[i] = k
		for g in q.group {
			x := sql_eval(h, g, r, nil) or_return
			query.append_owned(h, &keys[i], x) or_return
		}
	}
	ids, n := query.group_ids(h, keys) or_return
	defer delete(ids, h.allocator)
	groups := make([][dynamic]query.Value, n, context.temp_allocator)
	for id, i in ids {
		append(&groups[id], rows[i])
	}
	if len(q.group) == 0 && len(rows) == 0 {
		return sql_row(h, q, query.NULL, {}, out)
	}
	for g in groups {
		sql_row(h, q, g[0], g[:], out) or_return
	}
	return .Ok
}

// Appends to `out` the row the select list makes of `row`, aggregates over `group`.
@(private)
sql_row :: proc(h: ^query.Heap, q: ^Sql_Query, row: query.Value, group: []query.Value, out: ^query.Value) -> query.Status {
	obj := query.make_object(h, len(q.items)) or_return
	for it in q.items {
		s: query.Status
		if it.expr == nil {
			c: query.Cursor
			c, s = query.cursor_open(h, row)
			for s == .Ok {
				k, x, more, e := query.cursor_next(h, &c)
				if s = e; !more || s != .Ok {
					break
				}
				s = query.object_put(h, &obj, k, x)
			}
			query.cursor_close(&c)
		} else {
			x: query.Value
			x, s = sql_eval(h, it.expr, row, group)
			if s == .Ok {
				s = query.object_put(h, &obj, query.text_borrowed(it.name), x)
			}
		}
		if s != .Ok {
			query.release(h, obj)
			return s
		}
	}
	return query.append_owned(h, out, obj)
}

// Sorts the output rows by the ORDER BY keys, each read from an output row: one stable sort per key, the last first.
@(private)
sql_order :: proc(h: ^query.Heap, q: ^Sql_Query, out: ^query.Value) -> query.Status {
	rows := query.items_of(out^)
	keys := make([]query.Value, len(rows), context.temp_allocator)
	#reverse for k in q.order {
		s: query.Status
		for r, i in rows {
			if keys[i], s = sql_eval(h, k.expr, r, nil); s != .Ok {
				break
			}
		}
		if s == .Ok {
			s = query.sort_values(h, rows, keys, SQL_ORDER, k.desc)
		}
		for &x in keys {
			query.release(h, x)
			x = query.NULL
		}
		s or_return
	}
	return .Ok
}

// The value of `e` for `row`, an aggregate's over the rows of `group`.
@(private)
sql_eval :: proc(h: ^query.Heap, e: ^Sql_Expr, row: query.Value, group: []query.Value) -> (res: query.Value, status: query.Status) {
	switch e.kind {
	case .Column:
		if query.type_of(row) != .Object {
			return query.NULL, .Ok
		}
		x := query.member(h, row, e.name) or_return
		return query.NULL if x.kind == .Absent else x, .Ok
	case .Literal:
		return query.retain(e.value), .Ok
	case .Is_Null, .Is_Not_Null:
		x := sql_eval(h, e.a, row, group) or_return
		defer query.release(h, x)
		return query.bool_value((query.type_of(x) == .Null) == (e.kind == .Is_Null)), .Ok
	case .Not:
		x := sql_eval(h, e.a, row, group) or_return
		#partial switch x.kind {
		case .True:
			return query.FALSE, .Ok
		case .False:
			return query.TRUE, .Ok
		case .Null:
			return query.NULL, .Ok
		}
		defer query.release(h, x)
		return query.NULL, query.fail(h, .Types, .Negate, x)
	case .Negate:
		x := sql_eval(h, e.a, row, group) or_return
		defer query.release(h, x)
		if query.type_of(x) == .Null {
			return query.NULL, .Ok
		}
		if !query.is_number(x) {
			return query.NULL, query.fail(h, .Types, .Negate, x)
		}
		return query.num_neg(h, x)
	case .Binary:
		return sql_binary(h, e, row, group)
	case .Aggregate:
		return sql_aggregate(h, e, group)
	}
	return query.NULL, .Ok
}

@(private)
sql_binary :: proc(h: ^query.Heap, e: ^Sql_Expr, row: query.Value, group: []query.Value) -> (res: query.Value, status: query.Status) {
	a := sql_eval(h, e.a, row, group) or_return
	defer query.release(h, a)
	b := sql_eval(h, e.b, row, group) or_return
	defer query.release(h, b)
	ta, tb := query.type_of(a), query.type_of(b)
	if e.op == .And || e.op == .Or {
		for t in ([]query.Type{ta, tb}) {
			if t != .Null && t != .True && t != .False {
				return query.NULL, query.fail(h, .Types, .Compare, a, b)
			}
		}
		// A false operand decides AND and a true one OR; else NULL leaves it unknown.
		decides := query.Type.False if e.op == .And else .True
		switch {
		case ta == decides || tb == decides:
			return query.bool_value(decides == .True), .Ok
		case ta == .Null || tb == .Null:
			return query.NULL, .Ok
		}
		return query.bool_value(decides != .True), .Ok
	}
	if ta == .Null || tb == .Null {
		return query.NULL, .Ok
	}
	#partial switch e.op {
	case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
		c := query.compare(h, a, b, SQL_ORDER) or_return
		#partial switch e.op {
		case .Eq:
			return query.bool_value(c == 0), .Ok
		case .Ne:
			return query.bool_value(c != 0), .Ok
		case .Lt:
			return query.bool_value(c < 0), .Ok
		case .Le:
			return query.bool_value(c <= 0), .Ok
		case .Gt:
			return query.bool_value(c > 0), .Ok
		}
		return query.bool_value(c >= 0), .Ok
	case .Concat:
		if ta != .String || tb != .String {
			return query.NULL, query.fail(h, .Types, .Add, a, b)
		}
		return query.text_concat(h, a, b)
	}
	if ta != .Number || tb != .Number {
		return query.NULL, query.fail(h, .Types, .Add, a, b)
	}
	#partial switch e.op {
	case .Add:
		return query.num_add(h, a, b)
	case .Sub:
		return query.num_sub(h, a, b)
	case .Mul:
		return query.num_mul(h, a, b)
	case .Div:
		return query.num_quotient(h, a, b)
	}
	return query.num_rem(h, a, b, false)
}

// An aggregate over the values its argument gives for the rows of `group`, the NULLs left out.
@(private)
sql_aggregate :: proc(h: ^query.Heap, e: ^Sql_Expr, group: []query.Value) -> (res: query.Value, status: query.Status) {
	if e.star {
		return query.int_value(i64(len(group))), .Ok
	}
	xs := query.make_array(h, len(group)) or_return
	defer query.release(h, xs)
	for r in group {
		x := sql_eval(h, e.a, r, nil) or_return
		if query.type_of(x) == .Null {
			query.release(h, x)
			continue
		}
		query.append_owned(h, &xs, x) or_return
	}
	switch e.agg {
	case .Count:
		return query.int_value(i64(query.length_of(h, xs))), .Ok
	case .Sum:
		return query.sum(h, xs)
	case .Avg:
		return query.mean(h, xs)
	case .Median:
		return query.median(h, xs)
	case .Min:
		return query.extreme_by(h, xs, query.ABSENT, false, SQL_ORDER)
	case .Max:
		return query.extreme_by(h, xs, query.ABSENT, true, SQL_ORDER)
	}
	return query.NULL, .Ok
}
