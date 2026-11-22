package json_tests

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:slice"
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
		case tape.All, tape.Slice:
			panic("describe takes no `All` or `Slice`")
		}
	}
	if p != .Found {
		return fmt.tprint(p)
	}
	b := strings.builder_make(context.temp_allocator)
	render_node(&b, doc, int(at))
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
			render_node(&b, doc, int(key))
			strings.write_byte(&b, ':')
		}
		render_node(&b, doc, int(value))
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
expect_reads :: proc(t: ^testing.T, src: string, paths: [][]tape.Step, read: tape.Read_Options, reads: []Read_Case, spec := json.Spec.Json, grains: []tape.Grain = nil, loc := #caller_location) {
	text := transmute([]u8)src
	doc, berr := json.build(text, spec)
	defer tape.destroy(&doc)
	d, derr := tape.demand_of(paths, grains)
	defer tape.destroy(&d)
	r, serr := json.scan(text, &d, spec, read)
	defer tape.destroy(&r)
	testing.expectf(t, berr == nil && derr == nil && serr == nil, "%q: %v %v %v", src, berr, derr, serr, loc = loc)
	full_index := tape.index_of(&doc, context.allocator)
	defer tape.destroy(&full_index)
	partial_index := tape.index_of(&r, context.allocator)
	defer tape.destroy(&partial_index)
	for c in reads {
		full := describe(&doc, c.steps, c.dups)
		partial := describe(&r, c.steps, c.dups)
		testing.expectf(t, full == c.full, "%q %v %v: whole %q", src, c.steps, c.dups, full, loc = loc)
		testing.expectf(t, partial == c.partial, "%q scan %v %v: %v %v partial %q of %q", src, paths, read, c.steps, c.dups, partial, render_doc(&r), loc = loc)
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
	expect_reads(t, src, {{N("a")}}, {dups = .Last}, {
		{{}, .Last, `{"a":1,"b":0,"a":2} #2 ["a":2,"b":0]`, `~{"a":1,"a":2} #Not_Loaded [Not_Loaded]`},
		{{}, .First, `{"a":1,"b":0,"a":2} #2 ["a":1,"b":0]`, `~{"a":1,"a":2} #Not_Loaded [Not_Loaded]`},
		{{N("a")}, .Last, `2`, `2`},
		{{N("a")}, .First, `1`, `1`},
		{{N("b")}, .Last, `0`, `Not_Loaded`},
	})
	expect_reads(t, src, {{N("a")}}, {dups = .First}, {
		{{N("a")}, .First, `1`, `1`},
		{{N("a")}, .Last, `2`, `Not_Loaded`},
	})
	expect_reads(t, `{"a":1,"a":2}`, {{N("a")}}, {}, {{{}, .Default, `{"a":1,"a":2} #1 ["a":2]`, `{"a":1,"a":2} #1 ["a":2]`}})
	expect_reads(t, `{"a":1,"a":2}`, {{N("a")}}, {dups = .First}, {
		{{}, .Default, `{"a":1,"a":2} #1 ["a":2]`, `~{"a":1} #Not_Loaded [Not_Loaded]`},
	})
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
	expect_reads(t, `{"x":[10,20,30],"y":{"z":1},"w":2}`, {{N("x"), I(0)}}, {dups = .First, stop_early = true}, {
		{{}, .First, `{"x":[10,20,30],"y":{"z":1},"w":2} #3 ["x":[10,20,30],"y":{"z":1},"w":2]`, `~{"x":~[10]} #Not_Loaded [Not_Loaded]`},
		{{N("x"), I(0)}, .First, `10`, `10`},
		{{N("x"), I(1)}, .First, `20`, `Not_Loaded`},
		{{N("x"), I(-1)}, .First, `30`, `Not_Loaded`},
		{{N("x"), I(3)}, .First, `Missing`, `Not_Loaded`},
		{{N("x")}, .First, `[10,20,30] #3 [10,20,30]`, `~[10] #Not_Loaded [10,Not_Loaded]`},
		{{N("x")}, .Last, `[10,20,30] #3 [10,20,30]`, `Not_Loaded`},
		{{N("y")}, .First, `{"z":1} #1 ["z":1]`, `Not_Loaded`},
	})
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
		index := tape.index_of(doc, context.temp_allocator)
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
		text, _ := tape.node_text(doc, doc.nodes[at], buf)
		return strings.clone(text, context.temp_allocator)
	}
}

// What the partial reads of the agreement test answered.
Agreement :: struct {
	texts, refused, scans, on_path, reads: int,
	outcomes:                              [tape.Presence]int,
	shapes:                                map[u64]struct{}, // the kinds of steps of each path a scan read, `shape_of`
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
	a: Agreement
	defer delete(a.shapes)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xa63ee)
	for f in FLAVORS {
		for _ in 0 ..< testkit.rounds(4) {
			agree_over(t, random_text(f), f.spec, flavor_options(f), "generated", &a)
		}
	}
	expect_agreement(t, &a, {texts = 12, refused = 0, scans = 20_000, on_path = 60_000, shapes = 30})
}

// The least a run of the agreement law is to have read, so that a change that stops it reading fails it.
Agreement_Floor :: struct {
	texts, refused, scans, on_path, shapes: int,
}

agree_files :: proc(t: ^testing.T, spec: json.Spec, floor: Agreement_Floor) {
	a: Agreement
	defer delete(a.shapes)
	files := corpus_files()
	defer delete(files)
	for file in files {
		if file.spec == spec {
			agree_over(t, file.data, file.spec, {}, file.name, &a)
		}
	}
	expect_agreement(t, &a, floor)
}

expect_agreement :: proc(t: ^testing.T, a: ^Agreement, floor: Agreement_Floor) {
	log.infof("agreement: %d texts, %d refused, %d scans, %d path steps, %d other reads, %d path shapes, partial outcomes %v", a.texts, a.refused, a.scans, a.on_path, a.reads, len(a.shapes), a.outcomes)
	testing.expectf(t, a.texts >= floor.texts && a.refused >= floor.refused && a.scans >= floor.scans && a.on_path >= floor.on_path && len(a.shapes) >= floor.shapes, "%d texts, %d refused, %d scans, %d path steps, %d path shapes", a.texts, a.refused, a.scans, a.on_path, len(a.shapes))
	testing.expect(t, a.outcomes[.Not_Loaded] > 0 && a.outcomes[.Missing] > 0 && a.outcomes[.Wrong_Kind] > 0 && a.outcomes[.Found] > 0)
}

@(private = "file")
agree_over :: proc(t: ^testing.T, src: []u8, spec: json.Spec, opts: json.Options, name: string, a: ^Agreement) {
	defer free_all(context.temp_allocator)
	doc, err := json.build(src, spec, opts)
	defer tape.destroy(&doc)
	if err != nil {
		a.refused += 1
		reads_refuse(t, src, spec, opts, err, name)
		return
	}
	a.texts += 1
	full_index := tape.index_of(&doc, context.temp_allocator)
	defer tape.destroy(&full_index)
	paths := paths_of(&doc)
	sets := make([dynamic][][]tape.Step, context.temp_allocator)
	for i in 0 ..< len(paths) {
		append(&sets, paths[i:][:1])
		if i + 1 < len(paths) {
			append(&sets, paths[i:][:2])
		}
	}
	append(&sets, paths[:])
	Grained :: struct {
		paths:  [][]tape.Step,
		grains: []tape.Grain,
		limits: []int,
		facts:  bool,
	}
	runs := make([dynamic]Grained, context.temp_allocator)
	for set, i in sets {
		append(&runs, Grained{set, nil, nil, false})
		if len(set) == 1 || i + 1 == len(sets) {
			for grain in ([]tape.Grain{.Keys, .Kind}) {
				grains := make([]tape.Grain, len(set), context.temp_allocator)
				for &g, j in grains {
					g = grain if j % 3 != 2 else .Whole
				}
				append(&runs, Grained{set, grains, nil, false})
			}
			// Each path's first answer, or its first two, and every third path's every answer.
			for limit in 1 ..= 2 {
				limits := make([]int, len(set), context.temp_allocator)
				for &l, j in limits {
					l = limit if j % 3 != 2 else 0
				}
				append(&runs, Grained{set, nil, limits, false})
			}
		}
	}
	if spec != .Json {
		append(&runs, Grained{sets[len(sets) - 1], nil, nil, true})
	}
	for run in runs {
		set := run.paths
		d, derr := tape.demand_of(set, run.grains, run.limits, run.facts)
		testing.expect(t, derr == nil)
		defer tape.destroy(&d)
		for dups in ([]tape.Duplicates{.Last, .First, .Group}) {
			for stop in ([]bool{false, true}) {
				r, serr := json.scan(src, &d, spec, {dups = dups, stop_early = stop}, opts)
				defer tape.destroy(&r)
				if !testing.expectf(t, serr == nil, "%s %v: scan %v", name, spec, serr) {
					continue
				}
				a.scans += 1
				// The whole document's readers go through its index on a scan that ran to the end, and the partial one's
				// on a stopped scan, so each path is checked against the other.
				w := Agree_Walk{t, {&doc, nil}, {&r, nil}, dups, name, set, stop, a}
				partial_index := tape.index_of(&r, context.temp_allocator)
				defer tape.destroy(&partial_index)
				if stop {
					w.r.index = &partial_index
				} else {
					w.doc.index = &full_index
				}
				for path, i in set {
					a.shapes[shape_of(path)] = {}
					limit := run.limits[i] if i < len(run.limits) else 0
					// A path past its limit keeps no more, so only its answers are checked.
					if run.limits == nil {
						agree_on_path(&w, tape.ROOT, tape.ROOT, path, run.grains[i] if i < len(run.grains) else .Whole)
					}

					// A stopped scan's answers are the reference's once its paths are settled, which a stop leaves them.
					if !answers_agree(&doc, &r, i, path, dups, limit) {
						testing.expectf(t, false, "%s %v: answers of %v under %v limit %d stop %v: %s", name, spec, path, dups, limit, stop, render_answers(&r))
					}
				}
				if run.facts {
					agree_facts(t, &doc, &r, name)
				}

				if root, p := tape.root(w.r); p == .Found {
					agree_past(&w, tape.ROOT, root, 0)
				}
			}
		}
	}
}

// The kinds of the steps of a path, a name, an index from either end, an `All` with or without a limit, and a slice from
// either end, in one number.
@(private = "file")
shape_of :: proc(path: []tape.Step) -> (shape: u64) {
	for step in path {
		code := u64(0)
		switch s in step {
		case tape.Name:
			code = 1
		case tape.Index:
			code = 2 if s >= 0 else 3
		case tape.All:
			code = 4 if s.limit <= 0 else 5
		case tape.Slice:
			code = 6 if s.lo >= 0 else 7
		}
		shape = shape << 3 | code
	}
	return shape << 3 | u64(len(path))
}

@(private = "file")
Agree_Walk :: struct {
	t:     ^testing.T,
	doc:   tape.Reader,
	r:     tape.Reader,
	dups:  tape.Duplicates,
	name:  string,
	paths: [][]tape.Step,
	stop:  bool,
	a:     ^Agreement,
}

// The paths of a scan: the whole text, indexes from either end, every element, the first ones, slices, up to twelve
// of its keys in steps around them, with names it lacks, and the paths down to its first and its last leaf.
@(private = "file")
paths_of :: proc(doc: ^tape.Document) -> [][]tape.Step {
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	A :: tape.All{}
	out := make([dynamic][]tape.Step, context.temp_allocator)
	add :: proc(out: ^[dynamic][]tape.Step, steps: ..tape.Step) {
		path := make([]tape.Step, len(steps), context.temp_allocator)
		copy(path, steps)
		append(out, path)
	}
	add(&out)
	add(&out, I(0))
	add(&out, I(2))
	add(&out, I(1))
	add(&out, I(-1))
	add(&out, I(-2))
	add(&out, A)
	add(&out, A, A)
	add(&out, I(0), I(0))
	add(&out, I(-1), I(-1))
	add(&out, A, I(0))
	add(&out, N(""))
	add(&out, tape.All{1})
	add(&out, tape.All{2}, A)
	add(&out, A, tape.All{1})
	add(&out, tape.Slice{1, nil, 0})
	add(&out, tape.Slice{-2, nil, 0})
	add(&out, tape.Slice{0, -1, 0})
	add(&out, tape.Slice{1, 3, 1})
	add(&out, tape.Slice{-3, -1, 0}, A)
	keys := make([dynamic]string, context.temp_allocator)
	for node, i in doc.nodes {
		if node.role != .Key || len(keys) == 12 {
			continue
		}
		key := key_text(doc, tape.Node_Index(i))
		seen := false
		for k in keys {
			seen ||= k == key
		}
		if !seen {
			append(&keys, key)
		}
	}
	for k, n in keys {
		k2 := keys[(n + 1) % len(keys)]
		add(&out, N(k))
		add(&out, A, N(k))
		add(&out, I(0), N(k))
		add(&out, I(-1), N(k))
		add(&out, N(k), I(0))
		add(&out, N(k), I(-1))
		add(&out, N(k), A)
		add(&out, N(k), N(k2))
		add(&out, A, N(k), A)
		add(&out, N(k), N("zz_missing"))
		add(&out, N(k), A, N(k2))
		add(&out, tape.All{1}, N(k))
		add(&out, tape.Slice{-2, nil, 0}, N(k))
		add(&out, N(k), tape.Slice{1, nil, 1})
	}
	for last in ([]bool{false, true}) {
		down := make([dynamic]tape.Step, context.temp_allocator)
		for at := tape.ROOT; len(down) < 7; {
			node := doc.nodes[at]
			if node.kind < .Array || node.n == 1 {
				break
			}
			end := at + tape.Node_Index(node.n)
			member := at + 1
			for next := member; last && next < end; {
				member = next
				next += tape.Node_Index(doc.nodes[next].n) if doc.nodes[next].kind > .Plain else 1
				if node.kind == .Object {
					next += tape.Node_Index(doc.nodes[next].n) if doc.nodes[next].kind > .Plain else 1
				}
			}
			if node.kind == .Object {
				append(&down, tape.Step(tape.Name(key_text(doc, member))))
				at = member + 1
			} else {
				append(&down, tape.Step(tape.Index(-1 if last else 0)))
				at = member
			}
			if len(down) >= 3 {
				add(&out, ..down[:])
				add(&out, ..slice.concatenate([][]tape.Step{{A}, down[1:]}, context.temp_allocator))
			}
		}
	}
	return out[:]
}

key_text :: proc(doc: ^tape.Document, at: tape.Node_Index) -> string {
	buf := make([]u8, doc.nodes[at].n, context.temp_allocator)
	text, _ := tape.node_text(doc, doc.nodes[at], buf)
	return strings.clone(text, context.temp_allocator)
}

// Whether node `f` of the whole document and node `p` of the partial one are the same value of the text.
@(private = "file")
same_node :: proc(w: ^Agree_Walk, f, p: tape.Node_Index) -> bool {
	if f == tape.NO_NODE || p == tape.NO_NODE {
		return f == p
	}
	x, y := w.doc.doc.nodes[f], w.r.doc.nodes[p]
	return x.lo == y.lo && x.kind == y.kind && x.role == y.role && (x.kind > .Plain || x.n == y.n && x.spelling == y.spelling)
}

// Checks a step of a path the scan read, which the partial document answers as the whole one does.
@(private = "file")
agree_step :: proc(w: ^Agree_Walk, what: any, f, p: tape.Node_Index, fp, pp: tape.Presence, loc := #caller_location) -> bool {
	w.a.on_path += 1
	if fp == pp && (fp != .Found || same_node(w, f, p)) {
		return true
	}
	return testing.expectf(w.t, false, "%s scan %v %v stop %v: %v gives %v %v, whole %v %v; %s", w.name, w.paths, w.dups, w.stop, what, pp, p, fp, f, render_doc(w.r.doc), loc = loc)
}

// Checks a read past the scan's paths: the whole document's answer, or `.Not_Loaded` where the whole one has a value
// or lacks it.
@(private = "file")
agree_read :: proc(w: ^Agree_Walk, what: any, f, p: tape.Node_Index, fp, pp: tape.Presence, loc := #caller_location) -> bool {
	w.a.reads += 1
	w.a.outcomes[pp] += 1
	if pp == fp && (fp != .Found || same_node(w, f, p)) || pp == .Not_Loaded && fp != .Wrong_Kind {
		return true
	}
	return testing.expectf(w.t, false, "%s scan %v %v stop %v: %v gives %v %v, whole %v %v; %s", w.name, w.paths, w.dups, w.stop, what, pp, p, fp, f, render_doc(w.r.doc), loc = loc)
}

// Checks the steps of a path the scan read, and at their end what `grain` keeps.
@(private = "file")
agree_on_path :: proc(w: ^Agree_Walk, f, p: tape.Node_Index, steps: []tape.Step, grain: tape.Grain) {
	if len(steps) == 0 {
		agree_grain(w, f, p, grain)
		return
	}
	switch step in steps[0] {
	case tape.Name:
		if w.dups == .Group {
			fc, fp := tape.named(w.doc, f, string(step))
			pc, pp := tape.named(w.r, p, string(step))
			if !agree_step(w, step, tape.NO_NODE, tape.NO_NODE, fp, pp) || fp != .Found {
				return
			}
			for {
				fk, fv, fnp := tape.next_child(w.doc, &fc)
				pk, pv, pnp := tape.next_child(w.r, &pc)
				if !agree_step(w, "group member", fv, pv, fnp, pnp) || !same_node(w, fk, pk) || fnp != .Found {
					return
				}
				agree_on_path(w, fv, pv, steps[1:], grain)
			}
		}
		fv, fp := tape.member(w.doc, f, string(step), w.dups)

		pv, pp := tape.member(w.r, p, string(step), w.dups)
		if agree_step(w, step, fv, pv, fp, pp) && fp == .Found {
			agree_on_path(w, fv, pv, steps[1:], grain)
		}
	case tape.Index:
		fv, fp := tape.element(w.doc, f, int(step))
		pv, pp := tape.element(w.r, p, int(step))
		if agree_step(w, step, fv, pv, fp, pp) && fp == .Found {
			agree_on_path(w, fv, pv, steps[1:], grain)
		}
	case tape.All:
		node := w.doc.doc.nodes[f]
		if step.limit > 0 && node.kind == .Object && w.dups == .First {
			// Members past the limit are not kept, so the partial object is read by the keys of those before it.
			end := f + tape.Node_Index(node.n)
			for k, i := f + 1, i32(0); k < end && i < step.limit; i += 1 {
				key := key_text(w.doc.doc, k)
				fv, fp := tape.member(w.doc, f, key, .First)
				pv, pp := tape.member(w.r, p, key, .First)
				if agree_step(w, key, fv, pv, fp, pp) {
					agree_on_path(w, fv, pv, steps[1:], grain)
				}
				k += 1
				k += tape.Node_Index(w.doc.doc.nodes[k].n) if w.doc.doc.nodes[k].kind > .Plain else 1
			}
			return
		}
		fc, fp, _ := tape.children(w.doc, f, context.temp_allocator)
		pc, pp, _ := tape.children(w.r, p, context.temp_allocator)
		if !agree_step(w, "children", tape.NO_NODE, tape.NO_NODE, fp, pp) || fp != .Found {
			return
		}
		for i := i32(0); step.limit <= 0 || node.kind == .Object || i < step.limit; i += 1 {
			fk, fv, fnp := tape.next_child(w.doc, &fc, w.dups)
			pk, pv, pnp := tape.next_child(w.r, &pc, w.dups)
			if !agree_step(w, "next child", fv, pv, fnp, pnp) || !same_node(w, fk, pk) || fnp != .Found {
				break
			}
			agree_on_path(w, fv, pv, steps[1:], grain)
		}
	case tape.Slice:
		count, lp, _ := tape.length(w.doc, f, context.temp_allocator)
		if w.doc.doc.nodes[f].kind != .Array || lp != .Found {
			_, pp := tape.element(w.r, p, 0)
			agree_step(w, step, tape.NO_NODE, tape.NO_NODE, .Wrong_Kind if w.doc.doc.nodes[f].kind != .Null else .Missing, pp)
			return
		}
		lo := int(step.lo)
		from := max(lo + count if lo < 0 else lo, 0)
		hi := int(step.hi.? or_else i32(count))
		to := hi + count if hi < 0 else min(hi, count)
		if step.limit > 0 {
			to = min(to, from + int(step.limit))
		}
		for i in from ..< to {
			fv, fp := tape.element(w.doc, f, i)
			pv, pp := tape.element(w.r, p, i)
			if agree_step(w, step, fv, pv, fp, pp) {
				agree_on_path(w, fv, pv, steps[1:], grain)
			}
		}
	}
}

// Checks what `grain` keeps of the value `f` of the whole document and `p` of the partial one: its kind, and for a
// `.Keys` grain an array's length and an object's keys.
@(private = "file")
agree_grain :: proc(w: ^Agree_Walk, f, p: tape.Node_Index, grain: tape.Grain) {
	if !agree_step(w, grain, f, p, .Found, .Found) || grain != .Keys || w.doc.doc.nodes[f].kind < .Array {
		return
	}
	fn, fl, _ := tape.length(w.doc, f, context.temp_allocator)
	pn, pl, _ := tape.length(w.r, p, context.temp_allocator)
	if fl != pl || fn != pn {
		testing.expectf(w.t, false, "%s scan %v: keys length %v %d, whole %d; %s", w.name, w.paths, pl, pn, fn, render_doc(w.r.doc))
	}
	if w.doc.doc.nodes[f].kind != .Object {
		return
	}
	fc, _, _ := tape.children(w.doc, f, context.temp_allocator)
	pc, pcp, _ := tape.children(w.r, p, context.temp_allocator)
	if !agree_step(w, "keys", tape.NO_NODE, tape.NO_NODE, .Found, pcp) {
		return
	}
	for {
		fk, fv, fnp := tape.next_child(w.doc, &fc, w.dups)
		pk, pv, pnp := tape.next_child(w.r, &pc, w.dups)
		if fnp != .Found {
			agree_step(w, "last key", tape.NO_NODE, tape.NO_NODE, fnp, pnp)
			break
		}
		if !same_node(w, fk, pk) || pnp != .Not_Loaded && !(pnp == .Found && same_node(w, fv, pv)) {
			testing.expectf(w.t, false, "%s scan %v: key %v %v, whole %v; %s", w.name, w.paths, pk, pnp, fk, render_doc(w.r.doc))
			break
		}
	}
}

// Reads around the value `f` of the whole document and `p` of the partial one, and goes on into what both hold.
@(private = "file")
agree_past :: proc(w: ^Agree_Walk, f, p: tape.Node_Index, depth: int) {
	if !agree_read(w, "value", f, p, .Found, .Found) || depth > 64 {
		return
	}
	fn, fl, _ := tape.length(w.doc, f, context.temp_allocator)
	pn, pl, _ := tape.length(w.r, p, context.temp_allocator)
	agree_read(w, "length", tape.NO_NODE, tape.NO_NODE, fl, pl)
	if pl == .Found && fl == .Found {
		if fn != pn {
			testing.expectf(w.t, false, "%s scan %v: length %d, whole %d; %s", w.name, w.paths, pn, fn, render_doc(w.r.doc))
		}
	}
	for dups in ([]tape.Duplicates{.Last, .First}) {
		fc, fcp, _ := tape.children(w.doc, f, context.temp_allocator)
		pc, pcp, _ := tape.children(w.r, p, context.temp_allocator)
		if !agree_read(w, "children", tape.NO_NODE, tape.NO_NODE, fcp, pcp) || pcp != .Found {
			continue
		}
		for {
			fk, fv, fnp := tape.next_child(w.doc, &fc, dups)
			pk, pv, pnp := tape.next_child(w.r, &pc, dups)
			// A child the scan did not keep reads as not loaded, and the children past it go on.
			if !agree_read(w, "next child", fv, pv, fnp, pnp) || fnp != .Found {
				break
			}
			testing.expect(w.t, pnp != .Found || same_node(w, fk, pk))
		}
	}
	names := make([dynamic]string, context.temp_allocator)
	append(&names, "zz_missing", "")
	if w.doc.doc.nodes[f].kind == .Object {
		end := f + tape.Node_Index(w.doc.doc.nodes[f].n)
		for k := f + 1; k < end; {
			append(&names, key_text(w.doc.doc, k))
			k += 1
			k += tape.Node_Index(w.doc.doc.nodes[k].n) if w.doc.doc.nodes[k].kind > .Plain else 1
		}
	}
	for name, i in names {
		fv, fp := tape.member(w.doc, f, name, w.dups)
		pv, pp := tape.member(w.r, p, name, w.dups)
		if agree_read(w, name, fv, pv, fp, pp) && pp == .Found && i >= 2 {
			agree_past(w, fv, pv, depth + 1)
		}
		// A read under the policy the scan did not take.
		other := tape.Duplicates.First if w.dups == .Last else .Last
		fv, fp = tape.member(w.doc, f, name, other)
		pv, pp = tape.member(w.r, p, name, other)
		agree_read(w, name, fv, pv, fp, pp)
	}
	count := fn if fl == .Found else 0
	for i in -count - 2 ..= count + 1 {
		if i >= 64 && i < count - 2 || i <= -64 && i > -count + 2 {
			continue
		}
		fv, fp := tape.element(w.doc, f, i)
		pv, pp := tape.element(w.r, p, i)
		if agree_read(w, tape.Index(i), fv, pv, fp, pp) && pp == .Found && i >= 0 && w.doc.doc.nodes[f].kind == .Array {
			agree_past(w, fv, pv, depth + 1)
		}
	}
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
	expect_reads(t, src, paths, {}, reads, grains = {.Keys, .Keys, .Kind})
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
	for read in ([]tape.Read_Options{{}, {dups = .First, stop_early = true}}) {
		expect_reads(t, src, {{N("a")}}, read, {
			{{N("a"), N("x")}, .First, `1`, `1`},
			{{N("a"), N("z")}, .First, `"s"`, `"s"`},
			{{N("a"), N("y")}, .First, `[1,2] #2 [1,2]`, `~[] #Not_Loaded [Not_Loaded]`},
			{{N("a"), N("y"), I(0)}, .First, `1`, `Not_Loaded`},
			{{N("a"), N("w"), N("q")}, .First, `0`, `Not_Loaded`},
			{{N("a"), N("v")}, .First, `Missing`, `Missing`},
			{{N("b")}, .First, `2`, `Not_Loaded`},
		}, grains = {.Keys})
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
		index := tape.index_of(&doc, context.allocator)
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
		index := tape.index_of(&doc, context.allocator)
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
	index := tape.index_of(&doc, context.allocator)
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
