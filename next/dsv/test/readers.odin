package dsv_tests

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:testkit"

// The readers law over the texts the tests read and generated ones: a scan's partial document answers as the build
// does, and a text the build refuses is refused by every read.
@(test)
scans_agree_with_builds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	a: testkit.Agreement
	defer delete(a.shapes)
	for c in BUILT {
		testkit.readers_agree(t, dsv.reads(c.spec), dsv.as(c.spec), transmute([]u8)c.text, {format = c.opts, tolerate = c.tol}, c.text, &a)
	}
	for c in CSV_CASES {
		testkit.readers_agree(t, dsv.reads(.Csv), dsv.as(.Csv), transmute([]u8)c.text, {}, c.text, &a)
	}
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xd5f)
	for _ in 0 ..< testkit.rounds(40) {
		text, spec, opts := random_text()
		testkit.readers_agree(t, dsv.reads(spec), dsv.as(spec), text, opts, "generated", &a)
	}
	testkit.expect_agreement(t, &a, {texts = 40, refused = 10, scans = 2000, on_path = 2000, shapes = 10})
}

// A random delimited text of a few records, with quoted cells, escapes, empty cells, comment lines, ragged records and
// CR LF line ends, and the options it reads with.
random_text :: proc() -> ([]u8, dsv.Spec, dsv.Options) {
	spec := dsv.Spec(rand.int_max(3))
	o: dsv.Options
	d := dsv.Dsv_Options{no_header = rand.int_max(4) == 0, infer = rand.int_max(2) == 0, comment = '#' if rand.int_max(3) == 0 else 0}
	if rand.int_max(3) == 0 {
		o.tolerate = {.Ragged}
	}
	o.format = d
	b := strings.builder_make(context.temp_allocator)
	delim := u8('\t') if spec == .Tsv else ','
	width := 1 + rand.int_max(4)
	cells := []string{"", "x", "12", "-3.5", "true", "a b", "\xc3\xa9"}
	for row in 0 ..< 1 + rand.int_max(6) {
		if d.comment != 0 && rand.int_max(4) == 0 {
			strings.write_string(&b, "# note\n")
		}
		w := width if .Ragged not_in o.tolerate else 1 + rand.int_max(5)
		for col in 0 ..< w {
			if col > 0 {
				strings.write_byte(&b, delim)
			}
			switch {
			case spec == .Csv && rand.int_max(4) == 0:
				strings.write_string(&b, "\"q,\"\"\n\"")
			case spec == .Tsv && rand.int_max(4) == 0:
				strings.write_string(&b, "t\\tu")
			case row == 0 && !d.no_header:
				fmt.sbprintf(&b, "k%d", col % 3)
			case:
				strings.write_string(&b, rand.choice(cells))
			}
		}
		strings.write_string(&b, "\r\n" if rand.int_max(3) == 0 else "\n")
	}
	if rand.int_max(5) == 0 {
		strings.write_string(&b, "x\"y")
	}
	return transmute([]u8)strings.to_string(b), spec, o
}

// Every prefix of generated texts gets the same verdict from validate, build and a find, whichever read judges it.
@(test)
prefixes_get_one_verdict_from_every_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x91)
	defer free_all(context.temp_allocator)
	path := []tape.Step{tape.Index(-1)}
	for _ in 0 ..< testkit.rounds(30) {
		text, spec, opts := random_text()
		for n in 0 ..= len(text) {
			prefix := text[:n]
			verdict := dsv.validate(prefix, spec, opts)
			doc, built := dsv.build(prefix, spec, opts)
			dsv.destroy(&doc)
			_, found := dsv.find(prefix, path, spec, {}, opts)
			if !testing.expectf(t, built == verdict && found == verdict, "%q %v: validate %v, build %v, find %v", prefix, spec, verdict, built, found) {
				return
			}
		}
	}
}
