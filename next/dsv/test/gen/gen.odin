// Seeded delimited texts for the walk's tests: valid texts that touch every quote, escape, line end and UTF-8 width,
// and mutations of them that break at a random byte.
package dsv_gen

import "core:math/rand"

// A valid text: a header and records of one width, LF or CRLF line ends, empty lines now and then, a final line end
// or not, and now and then a BOM. Its cells now and then run past the 64-byte blocks the walk reads.
text :: proc(out: ^[dynamic]u8, tsv: bool) {
	clear(out)
	if rand.int_max(10) == 0 {
		append(out, "\xef\xbb\xbf")
	}
	sep := u8('\t') if tsv else ','
	width := 1 + rand.int_max(5)
	rows := rand.int_max(6)
	crlf := rand.int_max(3) == 0
	for r in 0 ..= rows {
		for c in 0 ..< width {
			if c > 0 {
				append(out, sep)
			}
			cell(out, tsv)
		}
		if r < rows || rand.int_max(2) == 0 {
			append(out, "\r\n" if crlf else "\n")
		}
		if r < rows && rand.int_max(8) == 0 {
			append(out, "\r\n" if rand.int_max(2) == 0 else "\n")
		}
	}
}

// `src` with one random edit: a byte replaced, deleted or inserted, or the text cut short.
mutate :: proc(out: ^[dynamic]u8, src: []u8) {
	clear(out)
	append(out, ..src)
	if len(src) == 0 {
		append(out, pick(SHARP))
		return
	}
	i := rand.int_max(len(src))
	switch rand.int_max(4) {
	case 0:
		out[i] = pick(SHARP)
	case 1:
		ordered_remove(out, i)
	case 2:
		inject_at(out, i, pick(SHARP))
	case:
		resize(out, i)
	}
}

// The bytes a mutation writes: every byte the grammars branch on, and the bytes that break UTF-8.
@(private)
SHARP :: "\",\t\n\r\\tnr0 a\x00\x01\x1f\x7f\x80\xbf\xc0\xc2\xe0\xed\xf0\xf4\xf5\xff"

@(private)
pick :: proc(s: string) -> u8 {
	return s[rand.int_max(len(s))]
}

@(private)
cell :: proc(out: ^[dynamic]u8, tsv: bool) {
	CSV :: []string{"", "a", "12.5", "\"q\"", "\"a,b\"", "\"x\"\"y\"", "\"multi\nline\"", "\"cr\r\nlf\"", "\"\"", "é", "日本", "😀", " sp ", "\\"}
	TSV :: []string{"", "a", "12.5", "\"q\"", "a,b", "\\t", "\\n", "\\\\", "\\r", "\\0", "x\\ty", "é", "日本", "😀", " sp "}
	if rand.int_max(8) != 0 {
		append(out, rand.choice(TSV if tsv else CSV))
		return
	}
	// A long cell: plain, or (CSV) quoted with quotes, delimiters and line ends inside, so the bytes inside quotes
	// cross a block.
	quoted := !tsv && rand.int_max(2) == 0
	if quoted {
		append(out, '"')
	}
	for _ in 0 ..< rand.int_max(150) {
		switch {
		case quoted && rand.int_max(16) == 0:
			append(out, rand.choice([]string{"\"\"", ",", "\n", "\r\n", "é"}))
		case tsv && rand.int_max(16) == 0:
			append(out, rand.choice([]string{"\\t", "\\\\", "é"}))
		case:
			append(out, 'a')
		}
	}
	if quoted {
		append(out, '"')
	}
}
