package json_tests

import "core:math/rand"
import "core:strings"
import "core:testing"
import core "../../core"
import json ".."
import gen "gen"

// Writes `src` as a JSON document, which the dense path writes when its tokens are short, and as a JSONC document, which
// the rows path writes, and checks that the two and `format` give the same text.
check_dense :: proc(t: ^testing.T, src: []u8) -> bool {
	doc, err := json.build(src, .Json)
	if !testing.expectf(t, err.kind == .None, "build %q: %v", src, err) {
		return false
	}
	defer core.destroy(&doc)
	if !testing.expectf(t, len(src) < 26 * len(doc.nodes), "%d bytes in %d nodes is not a dense text", len(src), len(doc.nodes)) {
		return false
	}
	rows_doc, rerr := json.build(src, .Jsonc)
	if !testing.expectf(t, rerr.kind == .None, "build as JSONC %q: %v", src, rerr) {
		return false
	}
	defer core.destroy(&rows_doc)
	dense, _, derr := core.write(&doc)
	defer delete(dense)
	rows, _, wrerr := core.write(&rows_doc)
	defer delete(rows)
	direct, ferr := json.format(src, .Json)
	defer delete(direct)
	ok := derr.kind == .None && wrerr.kind == .None && ferr.kind == .None
	if !testing.expectf(t, ok, "write %q: %v %v %v", src, derr, wrerr, ferr) {
		return false
	}
	return testing.expectf(t, string(dense) == string(rows) && string(dense) == string(direct), "%q: dense %q, rows %q, format %q", src, dense, rows, direct)
}

// Fills `out` with `[`, `body`, and enough short items after it that the whole is a dense text.
dense_text :: proc(out: ^[dynamic]u8, body: []u8) {
	append(out, '[')
	append(out, ..body)
	for _ in 0 ..< len(body) / 8 + 8 {
		append(out, ",0")
	}
	append(out, ']')
}

@(test)
write_dense_generated :: proc(t: ^testing.T) {
	rand.reset(7)
	for _ in 0 ..< 400 {
		body: [dynamic]u8
		defer delete(body)
		gen.text(&body, 1 + rand.int_max(5), .Json)
		// Leading blanks move every block boundary in the text past the quotes and escapes.
		pad := rand.int_max(70)
		src: [dynamic]u8
		defer delete(src)
		for _ in 0 ..< pad {
			append(&src, ' ')
		}
		dense_text(&src, body[:])
		if !check_dense(t, src[:]) {
			return
		}
	}
}

// A string holds each pair of a quote or a backslash run with blanks and multibyte text, put at every offset in a block.
@(test)
write_dense_string_edges :: proc(t: ^testing.T) {
	PIECES := [?]string{" ", "  ", `\"`, `\\`, `\\\\`, `\n`, `\t`, ` `, `\/`, "é", "日", "😀", "a", `\"\"`}
	rand.reset(11)
	for trial in 0 ..< 600 {
		b: strings.Builder
		defer strings.builder_destroy(&b)
		items := 1 + rand.int_max(5)
		for _ in 0 ..< items {
			strings.write_string(&b, rand.choice([]string{" ", "\n", "\t ", "\r\n  "}))
			strings.write_byte(&b, '"')
			for _ in 0 ..< rand.int_max(40) {
				strings.write_string(&b, rand.choice(PIECES[:]))
			}
			// A string that ends in `\\` must close with its own quote.
			strings.write_byte(&b, '"')
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, "null")
		src: [dynamic]u8
		defer delete(src)
		if trial % 5 == 0 {
			append(&src, 0xEF, 0xBB, 0xBF)
		}
		for _ in 0 ..< trial % 70 {
			append(&src, '\t')
		}
		dense_text(&src, transmute([]u8)strings.to_string(b))
		if !check_dense(t, src[:]) {
			return
		}
	}
}

// A backslash run ends at each offset around the end of the writer's first 2 KB, whose escape state the next 2 KB take, and
// of later segments, which are written blind while no space shows. A newline after the value is dropped.
@(test)
write_dense_segment_edges :: proc(t: ^testing.T) {
	for start in ([]int{2030, 2078, 4126, 8222}) {
		for n in start ..< start + 30 {
			for piece in ([]string{`\" ", " "`, `\\", " "`, `\\\" ", " "`}) {
				b: strings.Builder
				defer strings.builder_destroy(&b)
				strings.write_byte(&b, '"')
				for _ in 0 ..< n {
					strings.write_byte(&b, 'a')
				}
				strings.write_string(&b, piece)
				src: [dynamic]u8
				defer delete(src)
				dense_text(&src, transmute([]u8)strings.to_string(b))
				append(&src, '\n')
				if !check_dense(t, src[:]) {
					return
				}
			}
		}
	}
}

// A document read tolerating ill-formed UTF-8 is written as it decodes, so it does not take the dense path.
@(test)
write_dense_tolerant_read :: proc(t: ^testing.T) {
	src := []u8{'[', '"', 'a', 0xFF, 'b', '"', ',', '0', ',', '0', ',', '0', ',', '0', ']'}
	doc, err := json.build(src, .Json, {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&doc)
	if !testing.expect_value(t, err.kind, core.Document_Error_Kind.None) {
		return
	}
	text, _, werr := core.write(&doc)
	defer delete(text)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), "[\"a\xef\xbf\xbdb\",0,0,0,0]")
}

// Pretty text, `ascii` and `escape_html` respell what the source copy would keep, and a JSONC or JSON5 text is not strict.
@(test)
write_dense_leaves_other_options_to_rows :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`[ "<é>" , 1 , 2 , 3 , 4 , 5 , 6 , 7 ]`)
	doc, _ := json.build(src, .Json)
	defer core.destroy(&doc)
	for opts in ([?]core.Write_Options{{ascii = true}, {escape_html = true}}) {
		text, _, err := core.write(&doc, opts)
		defer delete(text)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		testing.expect(t, string(text) != `["<é>",1,2,3,4,5,6,7]`)
	}
	trailing := transmute([]u8)string(`[1,2,3,4,5,6,7,8,]`)
	jsonc, _ := json.build(trailing, .Jsonc)
	defer core.destroy(&jsonc)
	text, _, err := core.write(&jsonc)
	defer delete(text)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), `[1,2,3,4,5,6,7,8]`)
}

// Texts of 8 to 25 bytes per node, which the dense path writes unless the first 2 KB hold blanks outside strings. Either
// way the text is the rows path's.
@(test)
write_dense_sampled_route :: proc(t: ^testing.T) {
	for blank in ([?]string{"", " ", "\n\t", "    "}) {
		for width in ([?]int{4, 8, 14, 18}) {
			src: [dynamic]u8
			defer delete(src)
			append(&src, '[')
			for i in 0 ..< 400 {
				if i > 0 {
					append(&src, ',')
					append(&src, ..transmute([]u8)blank)
				}
				append(&src, '"')
				for _ in 0 ..< width {
					append(&src, 'k')
				}
				append(&src, '"')
			}
			append(&src, ']')
			if !check_dense(t, src[:]) {
				return
			}
		}
	}
}
