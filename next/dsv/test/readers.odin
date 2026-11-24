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

// A validate counts the containers a text opens against `Budget.steps` as a build does, whatever else in the text it
// refuses.
@(test)
validates_count_steps_as_builds_do :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x57e9)
	for _ in 0 ..< testkit.rounds(400) {
		src, spec, opts := random_text()
		for steps in ([]u64{1, 2, 3, 4, 7}) {
			counted := opts
			counted.budget.steps = steps
			doc, built := dsv.build(src, spec, counted)
			dsv.destroy(&doc)
			testing.expectf(t, built == dsv.validate(src, spec, counted), "%q %v %v: build %v", src, spec, counted, built)
		}
	}
}

// A random delimited text with quoted cells, escapes, empty cells, comment lines and CR LF line ends, and the options
// it reads with. A text of a few records may be ragged, `.Ragged` tolerated or not, and may end in a bare quote. An
// `even` text has up to 40 records of the header's width, its names `k0` and on or repeated `k0` to `k2`, and now and
// then a record of another width or a byte a read refuses.
random_text :: proc(even := false) -> ([]u8, dsv.Spec, dsv.Options) {
	spec := dsv.Spec(rand.int_max(3))
	o: dsv.Options
	d := dsv.Dsv_Options{no_header = rand.int_max(6 if even else 4) == 0, infer = rand.int_max(2) == 0, comment = '#' if rand.int_max(4 if even else 3) == 0 else 0}
	o.format = d
	if even {
		if rand.int_max(3) == 0 {
			o.tolerate += {.Bare_Quote}
		}
		if rand.int_max(3) == 0 {
			o.tolerate += {.Invalid_Utf8}
		}
	} else if rand.int_max(3) == 0 {
		o.tolerate = {.Ragged}
	}
	b := strings.builder_make(context.temp_allocator)
	delim := u8('\t') if spec == .Tsv else ','
	width := 1 + rand.int_max(6 if even else 4)
	repeats := !even || rand.int_max(3) == 0
	cells := []string{"", "x", "12", "-3.5", "true", "a b", "\xc3\xa9"}
	for row in 0 ..< 1 + rand.int_max(40 if even else 6) {
		if d.comment != 0 && rand.int_max(8 if even else 4) == 0 {
			strings.write_string(&b, "# note\n")
		}
		w := width
		if rand.int_max(30) == 0 if even else .Ragged in o.tolerate {
			w = 1 + rand.int_max(7 if even else 5)
		}
		for col in 0 ..< w {
			if col > 0 {
				strings.write_byte(&b, delim)
			}
			switch {
			case even && row == 0:
				fmt.sbprintf(&b, "k%d", col % 3 if repeats else col)
			case spec == .Csv && rand.int_max(5 if even else 4) == 0:
				strings.write_string(&b, "\"q,\"\"\n\"")
			case spec == .Tsv && rand.int_max(5 if even else 4) == 0:
				strings.write_string(&b, "t\\tu")
			case row == 0 && !d.no_header:
				fmt.sbprintf(&b, "k%d", col % 3)
			case even && rand.int_max(60) == 0:
				strings.write_string(&b, rand.choice([]string{"x\"y", "\xff", "a\rb", "\\q"}))
			case:
				strings.write_string(&b, rand.choice(cells))
			}
		}
		strings.write_string(&b, "\r\n" if rand.int_max(3) == 0 else "\n")
	}
	if !even && rand.int_max(5) == 0 {
		strings.write_string(&b, "x\"y")
	}
	return transmute([]u8)strings.to_string(b), spec, o
}

// Every prefix of generated texts gets the same verdict from validate, build, a find, a scan and the records, whichever
// read judges it, each read from a copy that ends at an unreadable page, so a load past the text faults.
@(test)
prefixes_get_one_verdict_from_every_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x91)
	defer free_all(context.temp_allocator)
	fence: testkit.Fence
	defer testkit.fence_release(&fence)
	path := []tape.Step{tape.Index(-1)}
	demand, _ := tape.demand_of({{tape.All{}, tape.Index(0)}})
	defer tape.destroy_demand(&demand)
	for _ in 0 ..< testkit.rounds(30) {
		text, spec, opts := random_text()
		for n in 0 ..= len(text) {
			prefix := testkit.fence_copy(&fence, text[:n])
			verdict := dsv.validate(prefix, spec, opts)
			doc, built := dsv.build(prefix, spec, opts)
			dsv.destroy(&doc)
			_, found := dsv.find(prefix, path, spec, {}, opts)
			scanned, scan_err := dsv.scan(prefix, &demand, spec, {}, opts)
			dsv.destroy(&scanned)
			r := dsv.records_open(prefix, .Lines, spec, opts)
			defer tape.destroy_records(&r)
			out: [4]dsv.Record
			bad := false
			for {
				k := dsv.records_validate(&r, out[:])
				for rec in out[:k] {
					bad ||= rec.err != 0
				}
				if k < len(out) {
					break
				}
			}
			// A text whose records all hold is one the validate accepts, and one with a record that faults is not.
			records_ok := r.err == nil && !bad
			if !testing.expectf(t, built == verdict && found == verdict && scan_err == verdict && records_ok == (verdict == nil), "%q %v: validate %v, build %v, find %v, scan %v, records %v %v", prefix, spec, verdict, built, found, scan_err, r.err, bad) {
				return
			}
		}
	}
}
