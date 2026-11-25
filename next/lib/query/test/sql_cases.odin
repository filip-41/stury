package query_test

import "core:testing"
import "stury:lib/query"
import "stury:testkit"

@(private)
STAFF :: `[{"dept":"a","name":"x","pay":10,"age":30},{"dept":"b","name":"y","pay":7,"age":null},{"dept":"a","name":"z","pay":5},{"dept":null,"name":"w","pay":3,"age":40},{"name":"v","pay":2.5,"age":25}]`

@(private)
Sql_Case :: struct {
	sql, input, want: string,
}

@(private, rodata)
SQL_CASES := [?]Sql_Case {
	{"SELECT name FROM t WHERE pay > 4 ORDER BY name", STAFF, `[{"name":"x"},{"name":"y"},{"name":"z"}]`},
	// A comparison with NULL, or with an absent column, is unknown, and so is its negation.
	{"SELECT name WHERE age > 26", STAFF, `[{"name":"x"},{"name":"w"}]`},
	{"SELECT name WHERE NOT age > 26", STAFF, `[{"name":"v"}]`},
	{"SELECT name WHERE age IS NULL ORDER BY name", STAFF, `[{"name":"y"},{"name":"z"}]`},
	{"SELECT name WHERE age > 26 OR pay = 7", STAFF, `[{"name":"x"},{"name":"y"},{"name":"w"}]`},
	{"SELECT name WHERE age > 26 AND pay = 7", STAFF, `[]`},
	{"SELECT name WHERE age IS NOT NULL AND NOT (pay < 3 OR age < 35)", STAFF, `[{"name":"w"}]`},
	// `/` of integers truncates toward zero, of any other number divides.
	{"SELECT pay / 3 AS q, pay % 4 AS r, -7 / 2 AS n, 7.0 / 2 AS d, 6 / 3 AS e WHERE name = 'x'", STAFF, `[{"q":3,"r":2,"n":-3,"d":3.5,"e":2}]`},
	{"SELECT 100000000000 * 100000000000 / 7 AS q WHERE name = 'x'", STAFF, `[{"q":1428571428571428571428}]`},
	// An absent group key is NULL's group, which sorts last.
	{
		"SELECT dept, COUNT(*) AS n, SUM(pay) AS s, AVG(pay) AS m, MIN(age) AS lo, MAX(age) AS hi, MEDIAN(pay) AS md, COUNT(age) AS na FROM t GROUP BY dept ORDER BY dept",
		STAFF,
		`[{"dept":"a","n":2,"s":15,"m":7.5,"lo":30,"hi":30,"md":7.5,"na":1},{"dept":"b","n":1,"s":7,"m":7,"lo":null,"hi":null,"md":7,"na":0},{"dept":null,"n":2,"s":5.5,"m":2.75,"lo":25,"hi":40,"md":2.75,"na":2}]`,
	},
	{"SELECT dept, name ORDER BY dept DESC, name", STAFF, `[{"dept":null,"name":"v"},{"dept":null,"name":"w"},{"dept":"b","name":"y"},{"dept":"a","name":"x"},{"dept":"a","name":"z"}]`},
	{"SELECT dept, SUM(pay) AS s GROUP BY dept ORDER BY s DESC", STAFF, `[{"dept":"a","s":15},{"dept":"b","s":7},{"dept":null,"s":5.5}]`},
	// With no GROUP BY, the aggregates of no rows make one row; with one, no group and no row.
	{"SELECT COUNT(*) AS n, SUM(pay) AS s, AVG(pay) AS m WHERE pay > 100", STAFF, `[{"n":0,"s":null,"m":null}]`},
	{"SELECT dept, COUNT(*) AS n WHERE pay > 100 GROUP BY dept", STAFF, `[]`},
	{"SELECT COUNT(*) WHERE pay > 4", STAFF, `[{"COUNT(*)":3}]`},
	// Numbers group and compare by value, and integers stay exact.
	{"SELECT k, COUNT(*) AS n GROUP BY k ORDER BY k", `[{"k":2},{"k":1},{"k":1.0}]`, `[{"k":1,"n":2},{"k":2,"n":1}]`},
	{"SELECT SUM(v) AS s, AVG(v) AS m", `[{"v":9007199254740993},{"v":1}]`, `[{"s":9007199254740994,"m":4503599627370497}]`},
	{"SELECT * WHERE name = 'y'", STAFF, `[{"dept":"b","name":"y","pay":7,"age":null}]`},
	{"SELECT name || '!' AS e WHERE pay = 10", STAFF, `[{"e":"x!"}]`},
	{"SELECT name WHERE dept = NULL", STAFF, `[]`},
}

@(test)
sql_over_the_engine_has_sqls_semantics :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in SQL_CASES {
		x: Test_Heap
		heap_start(&x)
		h := &x.h
		input := read_json(t, h, c.input)
		got, err, s := sql_run(h, c.sql, input)
		query.release(h, input)
		testing.expectf(t, err == "" && s == .Ok, "%s: %s %v", c.sql, err, h.err.kind)
		testing.expectf(t, as_json(h, got) == c.want, "%s\n  want %s\n  got  %s", c.sql, c.want, as_json(h, got))
		query.release(h, got)
		query.clear_error(h)
		heap_done(t, &x)
	}
}

@(test)
sql_refuses_what_it_cannot_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	input := read_json(t, h, STAFF)
	defer query.release(h, input)
	for src in ([]string{"SELECT", "SELECT name WHERE", "SELECT name GROUP dept", "SELECT name ORDER BY name extra"}) {
		got, err, _ := sql_run(h, src, input)
		testing.expectf(t, err != "", "%s reads", src)
		query.release(h, got)
	}
	_, err, s := sql_run(h, "SELECT name || 1 AS e", input)
	testing.expect(t, err == "" && s == .Error && h.err.kind == .Types)
	query.clear_error(h)
}
