// The oracle's arms share these types, the fixtures they read and the directed values. Each arm's `arm` writes a value
// as delimited text, or `REFUSED` when the writer refuses it, to `<out>/<name>.txt`, and oracle.py compares them.
#+feature dynamic-literals
package dsv_marshal_oracle

import "core:fmt"
import "core:os"

Spec :: enum {
	Csv,
	Tsv,
	Plain,
}

Layout :: struct {
	delimiter, comment:         u8,
	no_header, crlf, sort_keys: bool,
}

Table_Row :: struct {
	id, ts:       i64,
	lat, lon:     f64,
	qty:          i64,
	price, score: f64,
	ok:           bool,
	code:         string,
}

Text_Row :: struct {
	id:                      i64,
	name, city, quote, note: string,
}

Color :: enum u8 {
	Red,
	Green,
	Blue = 7,
}

Kinds_Row :: struct {
	a: i8,
	b: i16,
	c: i32,
	d: u8,
	e: u16,
	f: u32,
	g: u64,
	h: f32,
	i: f64,
	j: bool,
	k: b32,
	l: string,
	m: cstring,
	n: Color,
	v: Maybe(i64),
	w: Maybe(i64),
	x: Maybe(string),
	y: Maybe(string),
}

One :: struct {
	s: string,
}

Number_Row :: struct {
	n: i64,
	f: f64,
}

// Strings a cell may have to quote, escape or refuse.
TEXTS :: [?]string{"", "plain", "a,b", "a;b", "q\"q", "l\nl", "c\rc", "t\tt", "b\\s", "n\x00n", "#hash", "x#", "\xEF\xBB\xBFbom", " sp ", "é日本語", "1", "-2.5e3", "a,b\"c\nd,e", "long text with many words and a comma, then a quote \" and more words after it to pass sixteen"}

LAYOUTS :: [?]Layout{{}, {no_header = true}, {crlf = true}, {delimiter = ';'}, {delimiter = '\t'}, {comment = '#'}, {comment = '#', delimiter = '|', no_header = true}, {delimiter = '1'}, {comment = '1'}, {comment = '\t', delimiter = ';'}}

SPECS :: [?]Spec{.Csv, .Tsv, .Plain}

kinds_rows :: proc() -> []Kinds_Row {
	rows := make([]Kinds_Row, 3)
	rows[0] = {a = -8, b = -300, c = -70000, d = 200, e = 60000, f = 4000000000, g = max(u64), h = 1.25, i = -0.000123, j = true, k = true, l = "a,b", m = "cs", n = .Blue, v = 5, x = "m"}
	rows[1] = {a = 127, b = 32767, c = max(i32), h = 3.4e38, i = 1e21, l = "", m = nil, n = .Red, w = -7, y = "q\"q"}
	rows[2] = {i = 123456789.123456789, h = 16777216, l = "é", n = .Green}
	return rows
}

marshal_values :: proc() {
	dir := os.args[1]
	table_src, e1 := os.read_entire_file(fmt.tprintf("%s/table.csv", dir), context.allocator)
	text_src, e2 := os.read_entire_file(fmt.tprintf("%s/text.csv", dir), context.allocator)
	assert(e1 == nil && e2 == nil)
	table: []Table_Row
	text: []Text_Row
	read_table(table_src, &table)
	read_text(text_src, &text)
	table, text = table[:100], text[:100]
	for spec in SPECS {
		for layout, k in LAYOUTS {
			name := fmt.tprintf("%v_%d", spec, k)
			arm(fmt.tprintf("table_%s", name), table, spec, layout)
			arm(fmt.tprintf("text_%s", name), text, spec, layout)
			arm(fmt.tprintf("kinds_%s", name), kinds_rows(), spec, layout)
			sorted := layout
			sorted.sort_keys = true
			arm(fmt.tprintf("kinds_sorted_%s", name), kinds_rows(), spec, sorted)
			numbers := []Number_Row{{1, 1.5}, {-12, 1e16}, {111, 0.00001}, {0, 100}}
			arm(fmt.tprintf("numbers_%s", name), numbers, spec, layout)
			for s, i in TEXTS {
				cases := [?]One{{s}, {"x"}}
				arm(fmt.tprintf("one_%s_%d", name, i), cases[:], spec, layout)
				arm(fmt.tprintf("one_later_%s_%d", name, i), []One{{"x"}, {s}}, spec, layout)
				lists := [][]string{{s, "y"}, {"z", s}}
				arm(fmt.tprintf("list_%s_%d", name, i), lists, spec, layout)
				maps := []map[string]string{{"k" = s, "j" = "v"}, {"j" = "w"}}
				arm(fmt.tprintf("map_%s_%d", name, i), maps, spec, layout)
			}
		}
	}
}

write_text :: proc(name: string, text: []u8) {
	assert(os.write_entire_file(fmt.tprintf("%s/%s.txt", os.args[2], name), text) == nil, name)
}
