// Seeded delimited texts for the walk's tests: valid texts that use every quote, escape, line end and UTF-8 width,
// texts with random run-time options, and the bytes a mutation may write.
package dsv_gen

import "core:math/rand"
import dsv "../.."

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

// The delimiters a case may pick: no CR, LF, non-ASCII byte or quote. A quote is left to the tests that check it
// under each spec.
DELIMITERS :: []byte{',', '\t', ';', '|', ':', '^', '~', '#'}

// The comment bytes a case may pick: no CR, LF, non-ASCII byte, backslash or quote. A case keeps its comment byte
// away from its delimiter.
COMMENTS :: []byte{'#', ';', '%', '!', '@', '&'}

// A cell's body for each spec, spelled as that spec writes it: CSV quotes or not, TSV escapes, Plain text.
CSV_PLAIN :: []string{"", "a", "12.5", "sp ace", "é", "日本", "😀"}
CSV_QUOTED :: []string{"", "a", "a,b", "x\"\"y", "multi\nline", "cr\r\nlf", "é", "😀"}
TSV_CELLS :: []string{"", "a", "\\t", "\\n", "\\r", "\\0", "\\\\", "x\\ty", "\"q\"", "12.5", "é", "😀"}
PLAIN_CELLS :: []string{"", "a", "\"q\"", "x\\y", "12.5", "é", "😀", " sp "}

// A generated text's spec, delimiter and comment byte.
Options_Case :: struct {
	spec:    dsv.Spec,
	delim:   byte,
	comment: byte,
}

// Returns a case whose spec, delimiter and comment byte are drawn from their sets, with the comment byte away from
// the delimiter.
pick_case :: proc() -> Options_Case {
	spec := rand.choice([]dsv.Spec{.Csv, .Tsv, .Plain})
	delim := rand.choice(DELIMITERS)
	comment: byte
	if rand.int_max(2) == 0 {
		for {
			comment = rand.choice(COMMENTS)
			if comment != delim {
				break
			}
		}
	}
	return {spec, delim, comment}
}

// Appends a valid text of a case to `out`: a header and records of one width, a comment line before the header and
// now and then between records, a line end at the end or not, and now and then a BOM. A comment line holds arbitrary
// text bytes, including a delimiter, a quote and a CR.
options_text :: proc(out: ^[dynamic]u8, c: Options_Case) {
	clear(out)
	if rand.int_max(10) == 0 {
		append(out, "\xef\xbb\xbf")
	}
	width := 1 + rand.int_max(5)
	rows := rand.int_max(6)
	crlf := rand.int_max(3) == 0
	line_end := []string{"\r\n", "\n"}
	le := line_end[0 if crlf else 1]
	for r in 0 ..= rows {
		if c.comment != 0 && (r == 0 || rand.int_max(2) == 0) {
			append(out, c.comment)
			for _ in 0 ..< rand.int_max(10) {
				append(out, rand.choice([]byte{'a', '#', ';', ',', '"', '\\', ' ', '\r', '|'}))
			}
			append(out, le)
		}
		for col in 0 ..< width {
			if col > 0 {
				append(out, c.delim)
			}
			switch c.spec {
			case .Csv:
				if rand.int_max(2) == 0 {
					append(out, '"')
					append(out, rand.choice(CSV_QUOTED))
					append(out, '"')
				} else {
					append(out, rand.choice(CSV_PLAIN))
				}
			case .Tsv:
				append(out, rand.choice(TSV_CELLS))
			case .Plain:
				append(out, rand.choice(PLAIN_CELLS))
			}
		}
		if r < rows || rand.int_max(2) == 0 {
			append(out, le)
		}
		if r < rows && rand.int_max(8) == 0 {
			append(out, le)
		}
	}
}
