package write_tests

import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:testkit"

// The compact write of a strict JSON text over its source's bytes against the other routes, at the edges of its
// blocks and segments: the dense write of a strict read is the text the rows of a JSONC read and the walk of a JSON5
// read write.

// Writes `src` read as JSON, whose tokens the dense route writes when they are short, as JSONC, which the rows write,
// and as JSON5, which the walk writes, and checks that the three texts are one, and that the strict read writes the
// same text as JSON5. A `bound` above zero also checks that the source has fewer bytes per node than that.
@(private = "file")
dense_agrees :: proc(t: ^testing.T, src: []u8, bound := 26, loc := #caller_location) -> bool {
	strict, serr := json.build(src, .Json)
	defer json.destroy(&strict)
	rows, rerr := json.build(src, .Jsonc)
	defer json.destroy(&rows)
	walked, werr := json.build(src, .Json5)
	defer json.destroy(&walked)
	if !testing.expectf(t, serr == nil && rerr == nil && werr == nil, "build %.100q: %v %v %v", src, serr, rerr, werr, loc = loc) {
		return false
	}
	if !testing.expectf(t, bound == 0 || len(src) < bound * len(strict.nodes), "%d bytes in %d nodes is not a dense text", len(src), len(strict.nodes), loc = loc) {
		return false
	}
	for opts in ([?]json.Write_Options{{}, {indent = 2}}) {
		dense, _, derr := json.write(&strict, .Json, opts)
		defer delete(dense)
		by_rows, _, rwerr := json.write(&rows, .Json, opts)
		defer delete(by_rows)
		by_walk, _, wwerr := json.write(&walked, .Json, opts)
		defer delete(by_walk)
		if !testing.expectf(t, derr == nil && rwerr == nil && wwerr == nil, "write %.100q: %v %v %v", src, derr, rwerr, wwerr, loc = loc) {
			return false
		}
		if !testing.expectf(t, string(dense) == string(by_rows) && string(dense) == string(by_walk), "%.100q under %v: dense %.200q, rows %.200q, walk %.200q", src, opts, dense, by_rows, by_walk, loc = loc) {
			return false
		}
		as_json5, _, jerr := json.write(&strict, .Json5, opts)
		defer delete(as_json5)
		if !testing.expectf(t, jerr == nil && string(as_json5) == string(dense), "%.100q under %v as JSON5: %v %.200q", src, opts, jerr, as_json5, loc = loc) {
			return false
		}
	}
	return true
}

// Fills `out` with `[`, `body`, and enough short items after it that the whole is a dense text.
@(private = "file")
dense_text :: proc(out: ^[dynamic]u8, body: []u8) {
	append(out, '[')
	append(out, ..body)
	for _ in 0 ..< len(body) / 8 + 8 {
		append(out, ",0")
	}
	append(out, ']')
}

// A string holds each pair of a quote or a backslash run with blanks and multibyte text, put at every offset in a block.
@(test)
dense_string_edges :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xd5e)
	PIECES := [?]string{" ", "  ", `\"`, `\\`, `\\\\`, `\n`, `\t`, ` `, `\/`, "é", "日", "😀", "a", `\"\"`, `é`, `😀`}
	for trial in 0 ..< testkit.rounds(600) {
		b: strings.Builder
		defer strings.builder_destroy(&b)
		for _ in 0 ..< 1 + rand.int_max(5) {
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
		if !dense_agrees(t, src[:]) {
			return
		}
	}
}

@(private = "file")
dense_sweep_piece :: proc(t: ^testing.T, starts: []int, lo_off, hi_off: int, pieces: []string, suffix: string, trail_nl: bool, loc := #caller_location) -> bool {
	for base in starts {
		for n in base + lo_off ..< base + hi_off {
			for piece in pieces {
				b: strings.Builder
				defer strings.builder_destroy(&b)
				strings.write_byte(&b, '"')
				for _ in 0 ..< n {
					strings.write_byte(&b, 'a')
				}
				strings.write_string(&b, piece)
				strings.write_string(&b, suffix)
				src: [dynamic]u8
				defer delete(src)
				dense_text(&src, transmute([]u8)strings.to_string(b))
				if trail_nl {
					append(&src, '\n')
				}
				if !dense_agrees(t, src[:], loc = loc) {
					return false
				}
			}
		}
	}
	return true
}

// Backslash runs, escapes, and multibyte characters at each offset around the end of the writer's 2 KB segments,
// including a trailing newline after the value.
@(test)
dense_segment_edges :: proc(t: ^testing.T) {
	testkit.deadline(t)
	if !dense_sweep_piece(t, []int{2030, 2078, 4126, 8222}, 0, 30, []string{`\" ", " "`, `\\", " "`, `\\\" ", " "`, `é", " "`, `\\\\", " "`}, "", true) {
		return
	}
	dense_sweep_piece(t, []int{2048, 4096, 6144}, -16, 4, []string{`😀`, `é`, `\/`, `\\`, `\"`}, `bc"`, false)
}

// A document read tolerating ill-formed UTF-8 is written as it decodes, which the dense route does not do.
@(test)
dense_tolerant_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := []u8{'[', '"', 'a', 0xFF, 'b', '"', ',', '0', ',', '0', ',', '0', ',', '0', ']'}
	doc, err := json.build(src, .Json, {tolerate = {.Invalid_Utf8}})
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	text, _, werr := json.write(&doc)
	defer delete(text)
	testing.expect_value(t, werr, nil)
	testing.expect_value(t, string(text), "[\"a\xef\xbf\xbdb\",0,0,0,0]")
}

// Layout is not the dense route's, and a JSONC or JSON5 text is not strict: indented text is the walk's, and a trailing
// comma is not written.
@(test)
dense_leaves_other_layouts_to_the_walk :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`[ "<é>" , 1 , 2 , 3 , 4 , 5 , 6 , 7 ]`)
	doc, _ := json.build(src)
	defer json.destroy(&doc)
	text, _, err := json.write(&doc, .Json, {indent = 1})
	defer delete(text)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(text), "[\n \"<é>\",\n 1,\n 2,\n 3,\n 4,\n 5,\n 6,\n 7\n]")
	trailing := transmute([]u8)string(`[1,2,3,4,5,6,7,8,]`)
	for spec in ([?]json.Spec{.Jsonc, .Json5}) {
		other, oerr := json.build(trailing, spec)
		defer json.destroy(&other)
		testing.expect_value(t, oerr, nil)
		written, _, werr := json.write(&other)
		defer delete(written)
		testing.expect_value(t, werr, nil)
		testing.expect_value(t, string(written), `[1,2,3,4,5,6,7,8]`)
	}
}

@(private = "file")
dense_repeated_strings_agree :: proc(t: ^testing.T, count: int, blank, unit: string, width, bound: int, loc := #caller_location) -> bool {
	src: [dynamic]u8
	defer delete(src)
	append(&src, '[')
	for i in 0 ..< count {
		if i > 0 {
			append(&src, ',')
			append(&src, ..transmute([]u8)blank)
		}
		append(&src, '"')
		for _ in 0 ..< width {
			append(&src, ..transmute([]u8)unit)
		}
		append(&src, '"')
	}
	append(&src, ']')
	return dense_agrees(t, src[:], bound, loc)
}

// Texts of 8 to 25 bytes per node and long strings with and without escapes, written by the dense route or by rows
// depending on blanks in the first 2 KB: either way the text is one.
@(test)
dense_sampled_and_long_strings :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for blank in ([?]string{"", " ", "\n\t", "    "}) {
		for width in ([?]int{4, 8, 14, 18}) {
			if !dense_repeated_strings_agree(t, 400, blank, "k", width, 26) {
				return
			}
		}
	}
	for spelling in ([?]string{"x", "x y", `x\n`, `x \"y\"`, `xé`, `x\/`}) {
		for width in ([?]int{20, 60, 100}) {
			if !dense_repeated_strings_agree(t, 40, "", spelling, width, 0) {
				return
			}
		}
	}
}

// Strings with escapes of every kind, a stretch with no blank outside them that the dense route stores unread, then one
// with blanks that reads the string state the first left over: a backslash run that ends a block, and a quote after it.
@(test)
dense_escapes_before_blanks :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xb11d)
	pieces := [?]string{`a`, `\\`, `\"`, `\n`, `\u` + `0041`, `\\\"`, `é`, `\/`, `\\\\`, ` `}
	for _ in 0 ..< testkit.rounds(300) {
		src := strings.builder_make(context.temp_allocator)
		strings.write_byte(&src, '[')
		unspaced := 40 + rand.int_max(300)
		for i in 0 ..< unspaced + 100 {
			if i > 0 {
				strings.write_string(&src, "," if i < unspaced else " , ")
			}
			strings.write_byte(&src, '"')
			for _ in 0 ..< 1 + rand.int_max(40) {
				strings.write_string(&src, rand.choice(pieces[:9] if i < unspaced else pieces[:]))
			}
			strings.write_byte(&src, '"')
		}
		strings.write_byte(&src, ']')
		if !dense_agrees(t, src.buf[:], bound = 0) {
			return
		}
	}
}
