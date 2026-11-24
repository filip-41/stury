package json_tests

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// The value the steps reach from the root by the readers, or the outcome that stopped them, and for a container or
// null its length and its children, an object's as `key:value`.
describe :: proc(doc: ^tape.Document, steps: []tape.Step, dups: tape.Duplicates, index: ^tape.Doc_Index = nil) -> string {
	x := tape.Reader{doc, index}
	at, p := tape.root(x)
	for step in steps {
		if p != .Found {
			break
		}
		switch s in step {
		case tape.Name:
			at, p = tape.member(x, at, string(s), dups)
		case tape.Index:
			at, p = tape.element(x, at, int(s))
		case tape.All, tape.Slice, tape.Descend:
			panic("describe takes no `All`, `Slice` or `Descend`")
		}
	}
	if p != .Found {
		return fmt.tprint(p)
	}
	b := strings.builder_make(context.temp_allocator)
	testkit.render_node(&b, doc, int(at))
	if doc.nodes[at].kind < .Array && doc.nodes[at].kind != .Null {
		return strings.to_string(b)
	}
	if n, lp, _ := tape.length(x, at, context.temp_allocator); lp == .Found {
		fmt.sbprintf(&b, " #%d [", n)
	} else {
		fmt.sbprintf(&b, " #%v [", lp)
	}
	c, cp, _ := tape.children(x, at, context.temp_allocator)
	defer tape.destroy(&c)
	for i := 0; cp == .Found; i += 1 {
		key, value, vp := tape.next_child(x, &c, dups)
		if vp != .Found {
			cp = vp
			break
		}
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		if key != tape.NO_NODE {
			testkit.render_node(&b, doc, int(key))
			strings.write_byte(&b, ':')
		}
		testkit.render_node(&b, doc, int(value))
	}
	if cp != .Missing {
		if !strings.has_suffix(strings.to_string(b), "[") {
			strings.write_byte(&b, ',')
		}
		fmt.sbprint(&b, cp)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// A read by steps under `dups` and what it gives on the whole document and on the partial one.
Read_Case :: struct {
	steps:   []tape.Step,
	dups:    tape.Duplicates,
	full:    string,
	partial: string,
}

// Each read over the build of `src` and over its scan by `paths` under `read`, each the same through an index.
expect_reads :: proc(t: ^testing.T, src: string, paths: [][]tape.Step, read: tape.Read_Options, reads: []Read_Case, spec := json.Spec.Json, grains: []tape.Grain = nil, dups := tape.Duplicates.Default, loc := #caller_location) {
	text := transmute([]u8)src
	doc, berr := json.build(text, spec)
	defer tape.destroy(&doc)
	d, derr := tape.demand_of(paths, grains)
	defer tape.destroy(&d)
	r, serr := json.scan(text, &d, spec, read, {dups = dups})
	defer tape.destroy(&r)
	testing.expectf(t, berr == nil && derr == nil && serr == nil, "%q: %v %v %v", src, berr, derr, serr, loc = loc)
	full_index := tape.Doc_Index{allocator = context.allocator}
	defer tape.destroy(&full_index)
	partial_index := tape.Doc_Index{allocator = context.allocator}
	defer tape.destroy(&partial_index)
	for c in reads {
		full := describe(&doc, c.steps, c.dups)
		partial := describe(&r, c.steps, c.dups)
		testing.expectf(t, full == c.full, "%q %v %v: whole %q", src, c.steps, c.dups, full, loc = loc)
		testing.expectf(t, partial == c.partial, "%q scan %v %v: %v %v partial %q of %q", src, paths, read, c.steps, c.dups, partial, testkit.render_doc(&r), loc = loc)
		testing.expect_value(t, describe(&doc, c.steps, c.dups, &full_index), full, loc = loc)
		testing.expect_value(t, describe(&r, c.steps, c.dups, &partial_index), partial, loc = loc)
	}
}

@(test)
navigate_tells_missing_from_not_loaded :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	A :: tape.All{}
	src := `{"a":1,"b":{"x":2},"b":3,"c":[1,2,3],"n":null}`
	expect_reads(t, src, {{N("a")}}, {}, {
		{{}, .Default, `{"a":1,"b":{"x":2},"b":3,"c":[1,2,3],"n":null} #4 ["a":1,"b":3,"c":[1,2,3],"n":null]`, `~{"a":1} #Not_Loaded [Not_Loaded]`},
		{{}, .First, `{"a":1,"b":{"x":2},"b":3,"c":[1,2,3],"n":null} #4 ["a":1,"b":{"x":2},"c":[1,2,3],"n":null]`, `~{"a":1} #Not_Loaded [Not_Loaded]`},
		{{N("a")}, .Default, `1`, `1`},
		{{N("b")}, .Last, `3`, `Not_Loaded`},
		{{N("b")}, .First, `{"x":2} #1 ["x":2]`, `Not_Loaded`},
		{{N("z")}, .Default, `Missing`, `Not_Loaded`},
		{{N("c")}, .Default, `[1,2,3] #3 [1,2,3]`, `Not_Loaded`},
		{{N("c"), I(-1)}, .Default, `3`, `Not_Loaded`},
		{{N("c"), I(3)}, .Default, `Missing`, `Not_Loaded`},
		{{N("c"), I(-4)}, .Default, `Missing`, `Not_Loaded`},
		{{N("a"), N("x")}, .Default, `Wrong_Kind`, `Wrong_Kind`},
		{{N("a"), I(0)}, .Default, `Wrong_Kind`, `Wrong_Kind`},
		{{N("c"), N("x")}, .Default, `Wrong_Kind`, `Not_Loaded`},
		{{I(0)}, .Default, `Wrong_Kind`, `Wrong_Kind`},
		{{N("n")}, .Default, `null #0 [Wrong_Kind]`, `Not_Loaded`},
		{{N("n"), N("x")}, .Default, `Missing`, `Not_Loaded`},
		{{N("n"), I(-1)}, .Default, `Missing`, `Not_Loaded`},
	})
	expect_reads(t, src, {{N("n"), N("x")}, {N("z")}, {N("b"), N("x")}}, {}, {
		{{}, .Default, `{"a":1,"b":{"x":2},"b":3,"c":[1,2,3],"n":null} #4 ["a":1,"b":3,"c":[1,2,3],"n":null]`, `~{"b":{"x":2},"b":3,"n":null} #Not_Loaded [Not_Loaded]`},
		{{N("z")}, .Default, `Missing`, `Missing`},
		{{N("b")}, .Default, `3`, `3`},
		{{N("b")}, .First, `{"x":2} #1 ["x":2]`, `{"x":2} #1 ["x":2]`},
		{{N("n")}, .Default, `null #0 [Wrong_Kind]`, `null #0 [Wrong_Kind]`},
		{{N("n"), N("x")}, .Default, `Missing`, `Missing`},
		{{N("a")}, .Default, `1`, `Not_Loaded`},
	})
	expect_reads(t, `[10,20,30]`, {{I(1)}}, {}, {
		{{}, .Default, `[10,20,30] #3 [10,20,30]`, `~[20] #3 [Not_Loaded]`},
		{{I(1)}, .Default, `20`, `20`},
		{{I(-2)}, .Default, `20`, `20`},
		{{I(0)}, .Default, `10`, `Not_Loaded`},
		{{I(-1)}, .Default, `30`, `Not_Loaded`},
		{{I(3)}, .Default, `Missing`, `Missing`},
		{{I(-4)}, .Default, `Missing`, `Missing`},
		{{N("x")}, .Default, `Wrong_Kind`, `Wrong_Kind`},
	})
	expect_reads(t, `[{"id":1,"x":0},{"id":2}]`, {{A, N("id")}}, {}, {
		{{}, .Default, `[{"id":1,"x":0},{"id":2}] #2 [{"id":1,"x":0},{"id":2}]`, `[~{"id":1},{"id":2}] #2 [~{"id":1},{"id":2}]`},
		{{I(0)}, .Default, `{"id":1,"x":0} #2 ["id":1,"x":0]`, `~{"id":1} #Not_Loaded [Not_Loaded]`},
		{{I(0), N("x")}, .Default, `0`, `Not_Loaded`},
		{{I(1), N("x")}, .Default, `Missing`, `Missing`},
		{{I(1)}, .Default, `{"id":2} #1 ["id":2]`, `{"id":2} #1 ["id":2]`},
		{{I(-1), N("id")}, .Default, `2`, `2`},
	})
	expect_reads(t, `[{"id":1},{"id":2},{"id":3}]`, {{I(-1), N("id")}}, {}, {
		{{}, .Default, `[{"id":1},{"id":2},{"id":3}] #3 [{"id":1},{"id":2},{"id":3}]`, `~[{"id":3}] #3 [Not_Loaded]`},
		{{I(-1)}, .Default, `{"id":3} #1 ["id":3]`, `{"id":3} #1 ["id":3]`},
		{{I(2)}, .Default, `{"id":3} #1 ["id":3]`, `{"id":3} #1 ["id":3]`},
		{{I(0)}, .Default, `{"id":1} #1 ["id":1]`, `Not_Loaded`},
		{{I(-3)}, .Default, `{"id":1} #1 ["id":1]`, `Not_Loaded`},
		{{I(3)}, .Default, `Missing`, `Missing`},
	})
	// An unread container and an object a name is missing from.
	expect_reads(t, `[[1],{"b":[2]},{"a":{"b":1}}]`, {{A, N("b")}}, {}, {
		{{I(0)}, .Default, `[1] #1 [1]`, `~[] #Not_Loaded [Not_Loaded]`},
		{{I(0), I(0)}, .Default, `1`, `Not_Loaded`},
		{{I(0), I(-1)}, .Default, `1`, `Not_Loaded`},
		{{I(0), I(5)}, .Default, `Missing`, `Not_Loaded`},
		{{I(1), N("b")}, .Default, `[2] #1 [2]`, `[2] #1 [2]`},
		{{I(2)}, .Default, `{"a":{"b":1}} #1 ["a":{"b":1}]`, `~{} #1 [Not_Loaded]`},
		{{I(2), N("b")}, .Default, `Missing`, `Missing`},
		{{I(2), N("a")}, .Default, `{"b":1} #1 ["b":1]`, `Not_Loaded`},
	})
}

// Under `.Last` a scan keeps every member of a key it keeps, under `.First` the first only.
@(test)
navigate_takes_duplicates_by_policy :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	src := `{"a":1,"b":0,"a":2}`
	expect_reads(t, src, {{N("a")}}, {}, {
		{{}, .Last, `{"a":1,"b":0,"a":2} #2 ["a":2,"b":0]`, `~{"a":1,"a":2} #Not_Loaded [Not_Loaded]`},
		{{}, .First, `{"a":1,"b":0,"a":2} #2 ["a":1,"b":0]`, `~{"a":1,"a":2} #Not_Loaded [Not_Loaded]`},
		{{N("a")}, .Last, `2`, `2`},
		{{N("a")}, .First, `1`, `1`},
		{{N("b")}, .Last, `0`, `Not_Loaded`},
	}, dups = .Last)
	expect_reads(t, src, {{N("a")}}, {}, {
		{{N("a")}, .First, `1`, `1`},
		{{N("a")}, .Last, `2`, `Not_Loaded`},
	}, dups = .First)
	expect_reads(t, `{"a":1,"a":2}`, {{N("a")}}, {}, {{{}, .Default, `{"a":1,"a":2} #1 ["a":2]`, `{"a":1,"a":2} #1 ["a":2]`}})
	expect_reads(t, `{"a":1,"a":2}`, {{N("a")}}, {}, {
		{{}, .Default, `{"a":1,"a":2} #1 ["a":2]`, `~{"a":1} #Not_Loaded [Not_Loaded]`},
	}, dups = .First)
	expect_reads(t, `{"a\n":1,"b":2,"a\u000a":3}`, {{N("a\n")}}, {}, {
		{{}, .Default, `{"a\n":1,"b":2,"a\u000a":3} #2 ["a\n":3,"b":2]`, `~{"a\n":1,"a\u000a":3} #Not_Loaded [Not_Loaded]`},
		{{N("a\n")}, .First, `1`, `1`},
		{{N("a\n")}, .Last, `3`, `3`},
	})
}

// A stop leaves the containers it is inside of a count not known.
@(test)
navigate_reads_a_stopped_scan :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	expect_reads(t, `{"x":[10,20,30],"y":{"z":1},"w":2}`, {{N("x"), I(0)}}, {stop_early = true}, {
		{{}, .First, `{"x":[10,20,30],"y":{"z":1},"w":2} #3 ["x":[10,20,30],"y":{"z":1},"w":2]`, `~{"x":~[10]} #Not_Loaded [Not_Loaded]`},
		{{N("x"), I(0)}, .First, `10`, `10`},
		{{N("x"), I(1)}, .First, `20`, `Not_Loaded`},
		{{N("x"), I(-1)}, .First, `30`, `Not_Loaded`},
		{{N("x"), I(3)}, .First, `Missing`, `Not_Loaded`},
		{{N("x")}, .First, `[10,20,30] #3 [10,20,30]`, `~[10] #Not_Loaded [10,Not_Loaded]`},
		{{N("x")}, .Last, `[10,20,30] #3 [10,20,30]`, `Not_Loaded`},
		{{N("y")}, .First, `{"z":1} #1 ["z":1]`, `Not_Loaded`},
	}, dups = .First)
	expect_reads(t, `[[1,2],[3]]`, {{I(0), I(0)}}, {stop_early = true}, {
		{{}, .Default, `[[1,2],[3]] #2 [[1,2],[3]]`, `~[~[1]] #Not_Loaded [~[1],Not_Loaded]`},
		{{I(0), I(0)}, .Default, `1`, `1`},
		{{I(0), I(1)}, .Default, `2`, `Not_Loaded`},
		{{I(1)}, .Default, `[3] #1 [3]`, `Not_Loaded`},
		{{I(2)}, .Default, `Missing`, `Not_Loaded`},
	})
}

// JSONC and JSON5 texts, with keys that need decoding.
@(test)
navigate_reads_every_spec :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	expect_reads(t, "/* c */ {\"a\": [1, /* d */ 2,], // e\n\"b\": 3}", {{N("a"), I(1)}}, {}, {
		{{N("a"), I(1)}, .Default, `2`, `2`},
		{{N("a"), I(0)}, .Default, `1`, `Not_Loaded`},
		{{N("a")}, .Default, `[1,2] #2 [1,2]`, `~[2] #2 [Not_Loaded]`},
		{{N("b")}, .Default, `3`, `Not_Loaded`},
	}, .Jsonc)
	src := "{a:1, 'b':+2, c:[.5,], \"\\u0061\":7, 'x\\\ny':3, a\\u0062:4}"
	expect_reads(t, src, {{N("a")}}, {}, {
		{{}, .Default, `{a:1,"b":+2,c:[.5],"\u0061":7,"x\` + "\n" + `y":3,a\u0062:4} #5 [a:7,"b":+2,c:[.5],"x\` + "\n" + `y":3,a\u0062:4]`, `~{a:1,"\u0061":7} #Not_Loaded [Not_Loaded]`},
		{{N("a")}, .Last, `7`, `7`},
		{{N("a")}, .First, `1`, `1`},
		{{N("xy")}, .Default, `3`, `Not_Loaded`},
		{{N("ab")}, .Default, `4`, `Not_Loaded`},
		{{N("c"), I(-1)}, .Default, `.5`, `Not_Loaded`},
	}, .Json5)
}

// A container of more children than a spelling holds keeps its count, and the readers settle from the scan's document
// alone what its lists tell.
@(test)
navigate_reads_wide_documents :: proc(t: ^testing.T) {
	testkit.deadline(t)
	COUNT :: 70_000
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"a":[`)
	for i in 0 ..< COUNT {
		fmt.sbprintf(&b, "%s%d", "," if i > 0 else "", i)
	}
	strings.write_string(&b, `],"b":1}`)
	src := transmute([]u8)strings.to_string(b)
	d, _ := tape.demand_of([][]tape.Step{{tape.Name("a"), tape.Index(5)}})
	defer tape.destroy(&d)
	r, err := json.scan(src, &d)
	defer tape.destroy(&r)
	testing.expect(t, err == nil)
	x := tape.Reader{doc = &r}
	a, ap := tape.member(x, tape.ROOT, "a")
	n, np, _ := tape.length(x, a, context.temp_allocator)
	testing.expect(t, ap == .Found && np == .Found && n == COUNT)
	_, lp := tape.element(x, a, -1)
	_, mp := tape.element(x, a, COUNT)
	five, fp := tape.element(x, a, 5)
	testing.expect(t, lp == .Not_Loaded && mp == .Missing && fp == .Found && string(src[r.nodes[five].lo:][:1]) == "5")
	_, bp := tape.member(x, tape.ROOT, "b")
	_, zp := tape.member(x, tape.ROOT, "zz")
	_, first := tape.member(x, tape.ROOT, "a", .First)
	_, last := tape.member(x, tape.ROOT, "a", .Last)
	testing.expect(t, bp == .Not_Loaded && zp == .Not_Loaded && first == .Found && last == .Found)

	none, _ := tape.demand_of([][]tape.Step{})
	defer tape.destroy(&none)
	e, eerr := json.scan(src, &none)
	defer tape.destroy(&e)
	_, rp := tape.root({doc = &e})
	testing.expect(t, eerr == nil && rp == .Not_Loaded)
}

// The fewest members past which an index lists an object.
HASHED_MEMBERS :: 9

// An object whose distinct keys come from a table gives the keys, values and length that comparing every key with
// every other gives, with repeats spelled with and without escapes, as a whole document and as an object a scan kept
// whole.
@(test)
navigate_finds_distinct_keys_of_wide_objects :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state := u64(7)
	for round in 0 ..< 200 {
		members := HASHED_MEMBERS + round % 70
		names := 2 + round % 60
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"o":{`)
		keys := make([]string, members, context.temp_allocator)
		for i in 0 ..< members {
			state = state * 6364136223846793005 + 1442695040888963407
			// Every fourth object holds each key once.
			keys[i] = fmt.tprintf("k%d", i if round % 4 == 0 else int((state >> 33) % u64(names)))
			// The same key written with an escape for its first byte.
			spelled := keys[i] if state >> 20 & 1 == 0 else fmt.tprintf(`\u006b%s`, keys[i][1:])
			fmt.sbprintf(&b, `%s"%s":%d`, "," if i > 0 else "", spelled, i)
		}
		strings.write_string(&b, `},"p":0}`)
		src := transmute([]u8)strings.to_string(b)
		// Each distinct key in text order with the index of its first and last member.
		Want :: struct {
			key:         string,
			first, last: int,
		}
		want := make([dynamic]Want, context.temp_allocator)
		outer: for k, i in keys {
			for &w in want {
				if w.key == k {
					w.last = i
					continue outer
				}
			}
			append(&want, Want{k, i, i})
		}
		doc, err := json.build(src)
		defer tape.destroy(&doc)
		d, _ := tape.demand_of([][]tape.Step{{tape.Name("o")}})
		defer tape.destroy(&d)
		r, serr := json.scan(src, &d)
		defer tape.destroy(&r)
		testing.expect(t, err == nil && serr == nil)
		expect_distinct(t, &doc, want[:], members)
		expect_distinct(t, &r, want[:], members)
	}
	expect_distinct :: proc(t: ^testing.T, doc: ^tape.Document, want: []$W, members: int) {
		index := tape.Doc_Index{allocator = context.temp_allocator}
		defer tape.destroy(&index)
		for x in ([]tape.Reader{{doc, nil}, {doc, &index}}) {
			expect_distinct_by(t, x, want, members)
		}
	}
	expect_distinct_by :: proc(t: ^testing.T, x: tape.Reader, want: []$W, members: int) {
		doc := x.doc
		o, _ := tape.member(x, tape.ROOT, "o")
		n, p, err := tape.length(x, o, context.temp_allocator)
		testing.expectf(t, n == len(want) && p == .Found && err == nil, "length %d %v %v, want %d", n, p, err, len(want))
		if x.index != nil {
			testing.expect_value(t, repeats_in(x, o), len(want) < members)
		}
		for dups in ([]tape.Duplicates{.Last, .First}) {
			c, cp, cerr := tape.children(x, o, context.temp_allocator)
			defer tape.destroy(&c)
			testing.expect(t, cp == .Found && cerr == nil && (c.members == nil) == (len(want) == members))
			for w in want {
				key, value, vp := tape.next_child(x, &c, dups)
				if !testing.expect(t, vp == .Found) {
					break
				}
				text := key_value_text(doc, key)
				at := w.last if dups == .Last else w.first
				testing.expectf(t, text == w.key && string(doc.src[doc.nodes[value].lo:][:doc.nodes[value].n]) == fmt.tprint(at), "%v: %s %v, want %v", dups, text, value, w)
				vk, _ := tape.member(x, o, w.key, dups)
				testing.expect(t, vk == value)
			}
			_, _, end := tape.next_child(x, &c, dups)
			testing.expect_value(t, end, tape.Presence.Missing)
		}
	}
	key_value_text :: proc(doc: ^tape.Document, at: tape.Node_Index) -> string {
		buf := make([]u8, doc.nodes[at].n, context.temp_allocator)
		text, _ := tape.node_text(doc, at, buf)
		return strings.clone(text, context.temp_allocator)
	}
}

// Over every text of the suites and generated ones that builds and scans by paths made of its own keys and indexes,
// each path's own steps read the same over the partial document as over the whole one, and every other read the
// partial document answers is the whole one's, or `.Not_Loaded` where the whole one has a value or lacks it. Every
// read of a text that does not build refuses it as the build does. The texts are split among tests, so that the runner
// reads them at once.
@(test)
navigate_agrees_with_the_build_on_json_files :: proc(t: ^testing.T) {
	testkit.deadline(t)
	agree_files(t, .Json, {texts = 70, refused = 120, scans = 50_000, on_path = 150_000, shapes = 35})
}

@(test)
navigate_agrees_with_the_build_on_json5_files :: proc(t: ^testing.T) {
	testkit.deadline(t)
	agree_files(t, .Json5, {texts = 60, refused = 20, scans = 40_000, on_path = 200_000, shapes = 25})
}

@(test)
navigate_agrees_with_the_build_on_jsonc_files :: proc(t: ^testing.T) {
	testkit.deadline(t)
	agree_files(t, .Jsonc, {texts = 25, refused = 50, scans = 20_000, on_path = 100_000, shapes = 25})
}

@(test)
navigate_agrees_with_the_build_on_generated_texts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	a: testkit.Agreement
	defer delete(a.shapes)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xa63ee)
	for f in FLAVORS {
		for _ in 0 ..< testkit.rounds(4) {
			testkit.readers_agree(t, json.reads(f.spec), json.as(f.spec), random_text(f), flavor_options(f), "generated", &a)
		}
	}
	testkit.expect_agreement(t, &a, {texts = 12, refused = 0, scans = 20_000, on_path = 60_000, shapes = 30})
}

agree_files :: proc(t: ^testing.T, spec: json.Spec, floor: testkit.Agreement_Floor) {
	a: testkit.Agreement
	defer delete(a.shapes)
	files := corpus_files()
	defer delete(files)
	for file in files {
		if file.spec == spec {
			testkit.readers_agree(t, json.reads(file.spec), json.as(file.spec), file.data, {}, file.name, &a)
		}
	}
	testkit.expect_agreement(t, &a, floor)
}

// An object a `.Keys` grain kept answers its length, its keys and its scalar values, a container value answering only
// its node, and a key it lacks `.Missing`. An array kept so answers its length, and a container a `.Kind` grain kept
// answers only its node.
@(test)
navigate_reads_grains :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	src := `{"a":{"b":1,"c":[2],"b":3},"d":[1,2,3],"e":{"x":1}}`
	reads := []Read_Case {
		{{N("a")}, .Last, `{"b":1,"c":[2],"b":3} #2 ["b":3,"c":[2]]`, `{"b":1,"c":~[],"b":3} #2 ["b":3,"c":~[]]`},
		{{N("a")}, .First, `{"b":1,"c":[2],"b":3} #2 ["b":1,"c":[2]]`, `{"b":1,"c":~[],"b":3} #2 ["b":1,"c":~[]]`},
		{{N("a"), N("b")}, .Last, `3`, `3`},
		{{N("a"), N("c")}, .Last, `[2] #1 [2]`, `~[] #Not_Loaded [Not_Loaded]`},
		{{N("a"), N("c"), I(0)}, .Last, `2`, `Not_Loaded`},
		{{N("a"), N("z")}, .Last, `Missing`, `Missing`},
		{{N("d")}, .Last, `[1,2,3] #3 [1,2,3]`, `~[] #3 [Not_Loaded]`},
		{{N("d"), I(1)}, .Last, `2`, `Not_Loaded`},
		{{N("d"), I(-4)}, .Last, `Missing`, `Missing`},
		{{N("e")}, .Last, `{"x":1} #1 ["x":1]`, `~{} #Not_Loaded [Not_Loaded]`},
		{{N("e"), N("x")}, .Last, `1`, `Not_Loaded`},
	}
	paths := [][]tape.Step{{N("a")}, {N("d")}, {N("e")}}
	expect_reads(t, src, paths, {}, reads, grains = {.Keys, .Keys, .Exists})
	// A value a longer path takes is kept with the keys, and read through them.
	expect_reads(t, src, {{N("a")}, {N("a"), N("b")}}, {}, {
		{{N("a")}, .Last, `{"b":1,"c":[2],"b":3} #2 ["b":3,"c":[2]]`, `{"b":1,"c":~[],"b":3} #2 ["b":3,"c":~[]]`},
		{{N("a"), N("b")}, .First, `1`, `1`},
		{{N("a"), N("c")}, .Last, `[2] #1 [2]`, `~[] #Not_Loaded [Not_Loaded]`},
	}, grains = {.Keys})
}

// A `.Keys` grain keeps each member, so a scalar member reads as in the whole document and a container member reads as
// a node whose children were not kept.
@(test)
navigate_reads_members_a_keys_grain_kept :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	src := `{"a":{"x":1,"y":[1,2],"z":"s","w":{"q":0}},"b":2}`
	for read in ([]tape.Read_Options{{}, {stop_early = true}}) {
		dups := tape.Duplicates.First if read.stop_early else .Default
		expect_reads(t, src, {{N("a")}}, read, {
			{{N("a"), N("x")}, .First, `1`, `1`},
			{{N("a"), N("z")}, .First, `"s"`, `"s"`},
			{{N("a"), N("y")}, .First, `[1,2] #2 [1,2]`, `~[] #Not_Loaded [Not_Loaded]`},
			{{N("a"), N("y"), I(0)}, .First, `1`, `Not_Loaded`},
			{{N("a"), N("w"), N("q")}, .First, `0`, `Not_Loaded`},
			{{N("a"), N("v")}, .First, `Missing`, `Missing`},
			{{N("b")}, .First, `2`, `Not_Loaded`},
		}, grains = {.Keys}, dups = dups)
	}
}

// Whether the index found the object at `at` repeating a key, which a walk over its children examines.
repeats_in :: proc(r: tape.Reader, at: tape.Node_Index) -> bool {
	c, _, _ := tape.children(r, at, context.temp_allocator)
	tape.destroy(&c)
	x := r.index
	assert(x.examined[at / 64] & (1 << uint(at % 64)) != 0)
	return x.repeats[at / 64] & (1 << uint(at % 64)) != 0
}

// An index marks each object whose members share a key, and only such an object, by comparing its keys, with a table
// past 8 members, a key that needs decoding taken by its decoded text.
@(test)
navigate_marks_objects_that_repeat_keys :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state := u64(11)
	for round in 0 ..< 400 {
		members := 1 + round % 40
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `[0,`)
		keys := make([]string, members, context.temp_allocator)
		repeat := false
		strings.write_byte(&b, '{')
		for i in 0 ..< members {
			state = state * 6364136223846793005 + 1442695040888963407
			// Long keys that differ only in their middle, and short ones.
			n := (state >> 40) % u64(4 * members)
			keys[i] = fmt.tprintf("k%d", n) if state >> 20 & 1 == 0 else fmt.tprintf("long-key-%d-with-a-tail", n)
			for k in keys[:i] {
				repeat ||= k == keys[i]
			}
			spelled := keys[i]
			if state >> 30 & 7 == 0 {
				spelled = fmt.tprintf(`\u%04x%s`, keys[i][0], keys[i][1:])
			}
			value := `[1,{"x":2}]` if state >> 25 & 3 == 0 else "0"
			fmt.sbprintf(&b, `%s"%s":%s`, "," if i > 0 else "", spelled, value)
		}
		strings.write_string(&b, "}]")
		doc, err := json.build(transmute([]u8)strings.to_string(b))
		defer tape.destroy(&doc)
		index := tape.Doc_Index{allocator = context.allocator}
		defer tape.destroy(&index)
		testing.expectf(t, err == nil && repeats_in(tape.Reader{&doc, &index}, 2) == repeat, "%d members, repeat %v", members, repeat)
	}
}

// Every element and member read through an index is the read with none, over wide arrays and objects with repeated
// keys and with none.
@(test)
navigate_index_agrees_with_the_walk :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state := u64(5)
	for round in 0 ..< 60 {
		b := strings.builder_make(context.temp_allocator)
		width := 1 + round * 3
		strings.write_string(&b, `{"arr":[`)
		for i in 0 ..< width {
			fmt.sbprintf(&b, `%s[%d,%s%d%s]`, "," if i > 0 else "", i, `{"v":`, i, "}")
		}
		strings.write_string(&b, `],"obj":{`)
		names := make([]string, width, context.temp_allocator)
		for i in 0 ..< width {
			state = state * 6364136223846793005 + 1442695040888963407
			names[i] = fmt.tprintf("m%d", (state >> 33) % u64(width if round % 2 == 0 else 4 * width))
			fmt.sbprintf(&b, `%s"%s":%d`, "," if i > 0 else "", names[i], i)
		}
		strings.write_string(&b, `}}`)
		doc, err := json.build(transmute([]u8)strings.to_string(b))
		defer tape.destroy(&doc)
		index := tape.Doc_Index{allocator = context.allocator}
		defer tape.destroy(&index)
		testing.expectf(t, err == nil, "%v", err)
		walk, through := tape.Reader{&doc, nil}, tape.Reader{&doc, &index}
		arr, _ := tape.member(through, tape.ROOT, "arr")
		obj, _ := tape.member(through, tape.ROOT, "obj")
		for i in -width - 1 ..= width {
			v, p := tape.element(walk, arr, i)
			iv, ip := tape.element(through, arr, i)
			testing.expectf(t, v == iv && p == ip, "element %d of %d: %v %v, indexed %v %v", i, width, v, p, iv, ip)
		}
		for name in names {
			for dups in ([]tape.Duplicates{.Default, .First, .Last}) {
				v, p := tape.member(walk, obj, name, dups)
				iv, ip := tape.member(through, obj, name, dups)
				testing.expectf(t, v == iv && p == ip, "member %s %v: %v %v, indexed %v %v", name, dups, v, p, iv, ip)
			}
		}
		_, absent := tape.member(through, obj, "absent")
		testing.expect_value(t, absent, tape.Presence.Missing)
		for at in ([]tape.Node_Index{arr, obj}) {
			n, _, _ := tape.length(walk, at, context.temp_allocator)
			m, _, _ := tape.length(through, at, context.temp_allocator)
			testing.expect_value(t, m, n)
			for dups in ([]tape.Duplicates{.First, .Last}) {
				c, _, _ := tape.children(walk, at, context.allocator)
				defer tape.destroy(&c)
				ic, _, _ := tape.children(through, at, context.allocator)
				defer tape.destroy(&ic)
				for {
					k, v, p := tape.next_child(walk, &c, dups)
					ik, iv, ip := tape.next_child(through, &ic, dups)
					testing.expect(t, k == ik && v == iv && p == ip)
					if p != .Found || ip != .Found {
						break
					}
				}
			}
		}
	}
}

// An index lists a container's table the first time a read needs it, and only that container's: a far element lists
// its array once, a near one lists nothing, and the length of a wide object that repeats a key reuses its table.
@(test)
navigate_index_fills_per_container :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"a":[`)
	for i in 0 ..< 5000 {
		fmt.sbprintf(&b, "%s%d", "," if i > 0 else "", i)
	}
	strings.write_string(&b, `],"b":[`)
	for i in 0 ..< 100 {
		fmt.sbprintf(&b, "%s%d", "," if i > 0 else "", i)
	}
	strings.write_string(&b, `],"o":{`)
	for i in 0 ..< 40 {
		fmt.sbprintf(&b, `%s"k%d":%d`, "," if i > 0 else "", i % 30, i)
	}
	strings.write_string(&b, `}}`)
	doc, err := json.build(transmute([]u8)strings.to_string(b))
	defer tape.destroy(&doc)
	testing.expect(t, err == nil)
	index := tape.Doc_Index{allocator = context.allocator}
	defer tape.destroy(&index)
	r := tape.Reader{&doc, &index}
	a, _ := tape.member(r, tape.ROOT, "a")
	bb, _ := tape.member(r, tape.ROOT, "b")
	testing.expect_value(t, len(index.entries), 0)
	_, p := tape.element(r, bb, 3)
	testing.expect(t, p == .Found && len(index.entries) == 0)
	v, vp := tape.element(r, a, 4999)
	testing.expect(t, vp == .Found && string(doc.src[doc.nodes[v].lo:][:doc.nodes[v].n]) == "4999" && len(index.entries) == 1)
	for i in ([]int{20, 4000, -1, -5000}) {
		e, ep := tape.element(r, a, i)
		want, _ := tape.element(tape.Reader{&doc, nil}, a, i)
		testing.expect(t, ep == .Found && e == want)
	}
	testing.expect_value(t, len(index.entries), 1)
	o, _ := tape.member(r, tape.ROOT, "o")
	for _ in 0 ..< 3 {
		n, lp, lerr := tape.length(r, o, runtime.nil_allocator())
		testing.expect(t, n == 30 && lp == .Found && lerr == nil)
	}
	testing.expect_value(t, len(index.entries), 2)
	k, kp := tape.member(r, o, "k5")
	testing.expect(t, kp == .Found && string(doc.src[doc.nodes[k].lo:][:doc.nodes[k].n]) == "35")
}

// A stopped scan's array holds an unknown count: its walk names the child it kept and then, for every place
// past it, a child the scan did not keep, and only a caller that knows the count ends the walk.
@(test)
navigate_walks_a_stopped_scan_partial_array :: proc(t: ^testing.T) {
	testkit.deadline(t)
	demand, _ := tape.demand_of([][]tape.Step{{tape.Index(0)}}, allocator = context.temp_allocator)
	src := transmute([]u8)string(`[1,2,3]`)
	doc, err := json.scan(src, &demand, .Json, {stop_early = true}, {}, context.temp_allocator)
	if !testing.expect_value(t, err != nil, false) {
		return
	}
	defer tape.destroy(&doc)
	r := tape.Reader{doc = &doc}
	root, rp := tape.root(r)
	c, p, cerr := tape.children(r, root, context.temp_allocator)
	if !testing.expect_value(t, rp, .Found) || !testing.expect_value(t, p, .Found) || !testing.expect_value(t, cerr != nil, false) {
		return
	}
	_, _, cp := tape.next_child(r, &c)
	if !testing.expect_value(t, cp, .Found) {
		return
	}
	_, _, cp = tape.next_child(r, &c)
	testing.expect_value(t, cp, .Not_Loaded)
}
