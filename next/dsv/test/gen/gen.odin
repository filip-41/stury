// Seeded delimited texts for the walk's tests: valid texts that use every quote, escape, line end and UTF-8 width,
// and the bytes a mutation may write.
package dsv_gen

import "core:math/rand"

// Appends a valid text to `out`: a header and records of one width, LF or CRLF line ends, empty lines now and then,
// a final line end or not, and now and then a BOM. A cell now and then extends past the 64-byte block the walk reads.
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

// The bytes a mutation writes: every byte the grammars branch on, and the bytes that break UTF-8.
SHARP :: "\",\t\n\r\\tnr0 a\x00\x01\x1f\x7f\x80\xbf\xc0\xc2\xe0\xed\xf0\xf4\xf5\xff"

@(private)
cell :: proc(out: ^[dynamic]u8, tsv: bool) {
	CSV :: []string{"", "a", "12.5", "\"q\"", "\"a,b\"", "\"x\"\"y\"", "\"multi\nline\"", "\"cr\r\nlf\"", "\"\"", "é", "日本", "😀", " sp ", "\\"}
	TSV :: []string{"", "a", "12.5", "\"q\"", "a,b", "\\t", "\\n", "\\\\", "\\r", "\\0", "x\\ty", "é", "日本", "😀", " sp "}
	if rand.int_max(8) != 0 {
		append(out, rand.choice(TSV if tsv else CSV))
		return
	}
	// A long cell, plain or (CSV) quoted with quotes, delimiters and line ends inside, so bytes inside quotes cross a
	// block.
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
