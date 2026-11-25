package json_tests

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"
import "stury:testkit"

// The typed read: each field rule, each refusal with its place and path, and who owns what a failed read leaves.

@(private = "file")
Point :: struct {
	x, y: i32,
}

@(private = "file")
Color :: enum u8 {
	Red,
	Green,
	Blue = 7,
}

// Reads `text` into `target` with the temp allocator.
@(private = "file")
read :: proc(text: string, target: ^$T, spec := json.Spec.Json, r := json.Unmarshal_Options{}, opts := json.Options{}) -> tape.Error {
	return json.unmarshal(transmute([]u8)text, target, spec, r, opts, context.temp_allocator)
}

// The refusal `e` holds, `.None` when `e` is no refused value.
@(private = "file")
refusal_of :: proc(e: tape.Error) -> json.Typed_Refusal {
	f, is_fault := e.(tape.Fault)
	if !is_fault || f.kind != .Refused || f.rules == nil || f.rules.format != "typed" {
		return .None
	}
	return json.Typed_Refusal(f.detail)
}

// The first byte of the value `e` refuses.
@(private = "file")
at_of :: proc(e: tape.Error) -> u64 {
	f, _ := e.(tape.Fault)
	return f.at
}

@(private = "file")
expect_nil :: proc(t: ^testing.T, e: tape.Error, loc := #caller_location) -> bool {
	return testing.expectf(t, e == nil, "got the error %v", e, loc = loc)
}

@(private = "file")
expect_refusal :: proc(t: ^testing.T, e: tape.Error, want: json.Typed_Refusal, loc := #caller_location) -> bool {
	return testing.expectf(t, refusal_of(e) == want, "got %v, want the refusal %v", e, want, loc = loc)
}

@(private = "file")
expect_path :: proc(t: ^testing.T, path: [dynamic]tape.Step, want: ..tape.Step, loc := #caller_location) {
	if !testing.expectf(t, len(path) == len(want), "path %v, want %v", path[:], want, loc = loc) {
		return
	}
	for step, i in want {
		testing.expectf(t, path[i] == step, "path %v, want %v", path[:], want, loc = loc)
	}
}

@(private = "file")
path_in :: proc() -> [dynamic]tape.Step {
	return make([dynamic]tape.Step, context.temp_allocator)
}

@(private = "file")
expect_bad_option :: proc(t: ^testing.T, e: tape.Error, loc := #caller_location) -> (option: string) {
	b, ok := e.(tape.Bad_Option)
	testing.expectf(t, ok, "got %v, want a Bad_Option", e, loc = loc)
	return b.option
}

@(test)
absent_member_keeps_the_destination :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	p := Point{1, 2}
	expect_nil(t, read(`{"y":5}`, &p))
	testing.expect_value(t, p, Point{1, 5})
}

@(test)
members_in_any_order_and_repeated :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		a: Point,
		b: []i32,
		c: string,
	}
	s: S
	expect_nil(t, read(`{"c":"x","b":[1],"a":{"x":1},"b":[2,3],"a":{"y":2},"c":"y"}`, &s))
	// A later occurrence replaces the earlier one whole, so `a.x` does not survive.
	testing.expect_value(t, s.a, Point{0, 2})
	testing.expect_value(t, len(s.b), 2)
	testing.expect_value(t, s.b[1], 3)
	testing.expect_value(t, s.c, "y")
}

@(private = "file")
Keyed :: struct {
	a:                        i64,
	eight_ch:                 string,
	nine_char:                i64,
	sixteen_chars_ab:         string,
	seventeen_chars_a:        i64,
	twenty_four_characters_x: string,
	inner:                    Point,
	l:                        []i32,
}

// The members of a `Keyed` object in the order of each shape: the type's order, with a key the type lacks, reversed,
// with a repeat, and with members absent.
@(private = "file")
KEYED_SHAPES := [?][]string {
	{"a", "eight_ch", "nine_char", "sixteen_chars_ab", "seventeen_chars_a", "twenty_four_characters_x", "inner", "l"},
	{"a", "eight_ch", "unknown_key", "nine_char", "sixteen_chars_ab", "seventeen_chars_a", "twenty_four_characters_x", "inner", "l"},
	{"l", "inner", "twenty_four_characters_x", "seventeen_chars_a", "sixteen_chars_ab", "nine_char", "eight_ch", "a"},
	{"a", "eight_ch", "nine_char", "sixteen_chars_ab", "a", "seventeen_chars_a", "twenty_four_characters_x", "inner", "l"},
	{"a", "nine_char", "seventeen_chars_a", "inner"},
}

// A text of `n` `Keyed` objects in an array, most in the type's order, so that the walk matches their keys in its
// member gaps, each value from `k`, the object's index. `pretty` puts each member on a line of its own.
@(private = "file")
keyed_text :: proc(n: int, pretty: bool) -> (text: string, objects: []string) {
	b := strings.builder_make(context.temp_allocator)
	spans := make([][2]int, n, context.temp_allocator)
	strings.write_byte(&b, '[')
	for k in 0 ..< n {
		if k > 0 {
			strings.write_byte(&b, ',')
		}
		shape := KEYED_SHAPES[0] if k % 7 < 3 else KEYED_SHAPES[k % len(KEYED_SHAPES)]
		from := strings.builder_len(b)
		strings.write_byte(&b, '{')
		for key, i in shape {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			if pretty {
				strings.write_string(&b, "\n    ")
			}
			fmt.sbprintf(&b, `"%s":`, key)
			switch key {
			case "inner":
				fmt.sbprintf(&b, `{{"x":%d,"y":%d}}`, k, -k)
			case "l":
				fmt.sbprintf(&b, `[%d,%d]`, k, i)
			case "eight_ch", "sixteen_chars_ab", "twenty_four_characters_x":
				fmt.sbprintf(&b, `"%s%d"`, key[:3], k)
			case:
				fmt.sbprintf(&b, `%d`, k * 10 + i)
			}
		}
		strings.write_byte(&b, '}')
		spans[k] = {from, strings.builder_len(b)}
	}
	strings.write_byte(&b, ']')
	text = strings.to_string(b)
	objects = make([]string, n, context.temp_allocator)
	for span, k in spans {
		objects[k] = text[span[0]:span[1]]
	}
	return
}

@(private = "file")
keyed_equal :: proc(x, y: Keyed) -> bool {
	if len(x.l) != len(y.l) {
		return false
	}
	for v, i in x.l {
		if y.l[i] != v {
			return false
		}
	}
	return x.a == y.a && x.eight_ch == y.eight_ch && x.nine_char == y.nine_char && x.sixteen_chars_ab == y.sixteen_chars_ab && x.seventeen_chars_a == y.seventeen_chars_a && x.twenty_four_characters_x == y.twenty_four_characters_x && x.inner == y.inner
}

// The objects of a long array read as each reads alone, where the walk matches their keys in the gaps it learned from
// the objects before: keys of each length class, a key the type lacks, members out of order, repeated and absent.
@(test)
keys_matched_in_gaps_read_as_an_object_alone :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for pretty in ([]bool{false, true}) {
		text, objects := keyed_text(96, pretty)
		for dups in ([]tape.Duplicates{.Last, .First}) {
			all: []Keyed
			if !expect_nil(t, read(text, &all, opts = {dups = dups})) || !testing.expect_value(t, len(all), len(objects)) {
				continue
			}
			for o, k in objects {
				alone: Keyed
				expect_nil(t, read(o, &alone, opts = {dups = dups}))
				testing.expectf(t, keyed_equal(all[k], alone), "object %d (pretty %v, %v): %v, alone %v", k, pretty, dups, all[k], alone)
			}
		}
	}
}

@(private = "file")
Nest :: struct {
	s: string,
	l: []string,
	d: [dynamic]string,
	m: map[string][]string,
	p: ^Nest,
	u: union {
		string,
		[]string,
	},
	o: Maybe([]string),
	a: [2]string,
}

@(private = "file")
Nests :: struct {
	n:    Nest,
	list: []Nest,
	m:    map[string]Nest,
	x:    string,
}

// Frees what a read put in `n` with `allocator`: every string but a span of `text`, every list, map and pointer.
@(private = "file")
free_nest :: proc(n: ^Nest, text: []u8, allocator: runtime.Allocator) {
	context.allocator = allocator
	free_text :: proc(s: string, text: []u8) {
		if uintptr(raw_data(s)) - uintptr(raw_data(text)) >= uintptr(len(text)) {
			delete(s)
		}
	}
	free_list :: proc(l: []string, text: []u8) {
		for s in l {
			free_text(s, text)
		}
		delete(l)
	}
	free_text(n.s, text)
	free_list(n.l, text)
	free_list(n.d[:], text)
	for k, v in n.m {
		free_text(k, text)
		free_list(v, text)
	}
	delete(n.m)
	if n.p != nil {
		free_nest(n.p, text, allocator)
		free(n.p)
	}
	switch u in n.u {
	case string:
		free_text(u, text)
	case []string:
		free_list(u, text)
	}
	if o, ok := n.o.?; ok {
		free_list(o, text)
	}
	for s in n.a {
		free_text(s, text)
	}
}

// A repeat under `.Last` frees what the value it replaces holds, at every depth and in every container, and nothing
// the target held: a read and a free of what it gave leave nothing allocated and free no block twice.
@(test)
a_repeat_frees_what_it_replaces :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	nest := `{"s":"ab","l":["c","d\n"],"d":["e"],"m":{"k":["f"],"k":["g\t"]},"p":{"s":"h","p":{"l":["i"],"l":["j"]},"p":{"s":"k"}},"u":"l","u":["m"],"o":["n"],"a":["o","p"],"s":"q","l":["r"],"d":["s"],"o":["t"],"a":["u","v"],"m":{"v":["w"]}}`
	text := transmute([]u8)strings.concatenate({`{"n":`, nest, `,"list":[`, nest, `,{"p":{"p":{"s":"x"}},"p":{"m":{"y":["z"],"y":["za"]}}}],"m":{"k":`, nest, `,"k":`, nest, `},"x":"zb","n":`, nest, `,"x":"zc","list":[`, nest, `],"m":{"j":{"s":"zd"},"j":{"s":"ze"}}}`}, context.temp_allocator)
	plan, err := json.plan_make(Nests, allocator = context.temp_allocator)
	expect_nil(t, err)
	for borrow in ([]bool{false, true}) {
		got: Nests
		expect_nil(t, json.unmarshal(text, &got, read = {borrow_strings = borrow, plan = &plan}, allocator = alloc))
		testing.expect_value(t, got.n.s, "q")
		testing.expect_value(t, got.x, "zc")
		testing.expect_value(t, len(got.list), 1)
		testing.expect_value(t, got.m["j"].s, "ze")
		spans := text if borrow else nil
		free_nest(&got.n, spans, alloc)
		for &n in got.list {
			free_nest(&n, spans, alloc)
		}
		delete(got.list, alloc)
		for k, &v in got.m {
			if !borrow {
				delete(k, alloc)
			}
			free_nest(&v, spans, alloc)
		}
		delete(got.m)
		if !borrow {
			delete(got.x, alloc)
		}
		testing.expectf(t, len(track.allocation_map) == 0, "borrow %v: %d blocks live", borrow, len(track.allocation_map))
		testing.expectf(t, len(track.bad_free_array) == 0, "borrow %v: %d bad frees", borrow, len(track.bad_free_array))
		mem.tracking_allocator_clear(&track)
	}
	// A value the target held stays allocated, and what the read put in it is freed.
	kept, pointee := strings.clone("kept", alloc), new(Nest, alloc)
	got := Nests {
		x = "literal",
		n = {s = kept, p = pointee},
	}
	got.m = make(map[string]Nest, alloc)
	got.m["held"] = {s = "literal"}
	expect_nil(t, json.unmarshal(transmute([]u8)string(`{"n":{"l":["a"],"p":{"s":"b"}},"n":{"l":["c"]},"m":{"held":{"s":"d"},"held":{"s":"e"},"new":{"s":"f"},"new":{"s":"g"}}}`), &got, read = {plan = &plan}, allocator = alloc))
	testing.expect_value(t, got.n.l[0], "c")
	testing.expect_value(t, got.m["held"].s, "e")
	testing.expect_value(t, got.m["new"].s, "g")
	testing.expect_value(t, got.x, "literal")
	// The repeat set back the target's string and pointer, and its pointee as the target held it.
	testing.expect(t, raw_data(got.n.s) == raw_data(kept) && got.n.p == pointee)
	testing.expect_value(t, pointee.s, "")
	free(pointee, alloc)
	delete(kept, alloc)
	delete(got.n.l[0], alloc)
	delete(got.n.l, alloc)
	for k, v in got.m {
		if k != "held" {
			delete(k, alloc)
		}
		delete(v.s, alloc)
	}
	delete(got.m)
	testing.expectf(t, len(track.allocation_map) == 0, "%d blocks live", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "%d bad frees", len(track.bad_free_array))
}

// A repeat into a pointee or a map the target held frees what the read put there and sets back what the target held:
// the pointee's bytes, and the map's entries, the target's own kept and the read's taken out.
@(test)
a_repeat_into_a_block_the_target_held_keeps_the_targets :: proc(t: ^testing.T) {
	testkit.deadline(t)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	Held :: struct {
		p: ^Nest,
		m: map[string]string,
	}
	texts := [?]struct {
		text:   string,
		s:      string, // the pointee's string after the read, "own" for the target's
		listed: bool, // the pointee holds the target's list
		m:      string, // the map's entries after the read, sorted
	} {
		{`{"p":{"s":"x","s":"y"}}`, "y", true, "k0=v0"},
		{`{"p":{"s":"x","l":["a"]},"p":{"s":"y"}}`, "y", true, "k0=v0"},
		{`{"p":{"s":"x","l":["a"]},"p":{"d":["b"]}}`, "own", true, "k0=v0"},
		{`{"m":{"a":"1","b":"2"},"m":{"a":"3"}}`, "own", true, "a=3 k0=v0"},
		{`{"m":{"k0":"x","b":"2"},"m":{"c":"4"}}`, "own", true, "c=4 k0=v0"},
		{`{"m":{"k0":"x"},"p":{"s":"z"},"m":{"k0":"y","e":"5"},"p":null,"p":{}}`, "own", true, "e=5 k0=y"},
	}
	for c in texts {
		own, list := strings.clone("own"), make([]string, 1)
		list[0] = strings.clone("listed")
		pointee := new(Nest)
		pointee.s, pointee.l = own, list
		k0, v0 := strings.clone("k0"), strings.clone("v0")
		got := Held {
			p = pointee,
		}
		got.m = make(map[string]string)
		got.m[k0] = v0
		expect_nil(t, json.unmarshal(transmute([]u8)c.text, &got))
		testing.expectf(t, got.p == pointee && pointee.s == c.s && raw_data(pointee.l) == raw_data(list) == c.listed, "%s: %v", c.text, pointee^)
		keys := make([dynamic]string, context.temp_allocator)
		for k, v in got.m {
			append(&keys, strings.concatenate({k, "=", v}, context.temp_allocator))
		}
		slice.sort(keys[:])
		testing.expectf(t, strings.join(keys[:], " ", context.temp_allocator) == c.m, "%s: %v", c.text, got.m)
		// What is left is the target's blocks and the strings, lists and keys the read put in.
		if raw_data(pointee.s) != raw_data(own) {
			delete(pointee.s)
		}
		if raw_data(pointee.l) != raw_data(list) {
			delete(pointee.l)
		}
		for e in pointee.d {
			delete(e)
		}
		delete(pointee.d)
		for k, v in got.m {
			if raw_data(k) != raw_data(k0) {
				delete(k)
			}
			if raw_data(v) != raw_data(v0) {
				delete(v)
			}
		}
		delete(got.m)
		delete(k0)
		delete(v0)
		delete(list[0])
		delete(list)
		delete(own)
		free(pointee)
		free_all(context.temp_allocator)
		testing.expectf(t, len(track.allocation_map) == 0, "%s: %d blocks live", c.text, len(track.allocation_map))
		testing.expectf(t, len(track.bad_free_array) == 0, "%s: %d bad frees", c.text, len(track.bad_free_array))
		mem.tracking_allocator_clear(&track)
	}
}

@(test)
first_occurrence_is_kept_and_later_ones_judged_by_syntax_only :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		a: Point,
		m: map[string]i32,
		n: i32,
	}
	opts := json.Options {
		dups = .First,
	}
	s: S
	expect_nil(t, read(`{"n":1,"a":{"x":1},"m":{"k":1,"k":2},"a":{"y":2},"n":2}`, &s, opts = opts))
	testing.expect_value(t, s.a, Point{1, 0})
	testing.expect_value(t, s.n, 1)
	testing.expect_value(t, s.m["k"], 1)
	// A later occurrence of the wrong class is skipped, as only its syntax is judged.
	s = {}
	expect_nil(t, read(`{"n":1,"n":"no","a":{"x":2},"a":{"x":"y"},"a":[1]}`, &s, opts = opts))
	testing.expect_value(t, s.n, 1)
	testing.expect_value(t, s.a.x, 2)
	text := `{"n":1,"n":01}`
	testing.expect_value(t, read(text, &s, opts = opts), json.validate(transmute([]u8)text))
}

// Under `.Refuse` the read judges each object's keys in its walk, with no document: a repeat refuses as a build refuses
// it, in a value the read passes, past a refusal and before a later fault, and a fault before the repeat wins.
@(test)
refuse_duplicates_judges_the_keys_in_the_walk :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i32,
		l: []Point,
		m: map[string]i32,
	}
	opts := json.Options {
		dups = .Refuse,
	}
	wide := strings.builder_make(context.temp_allocator)
	strings.write_string(&wide, `{"m":{`)
	for i in 0 ..< 40 {
		fmt.sbprintf(&wide, `"k%d":%d,`, i, i)
	}
	strings.write_string(&wide, `"k17":1}}`)
	texts := []string {
		`{"a":{"b":1,"b":2}}`,
		`{"a":"x","a":2}`,
		`{"a":1,"skipped":{"k":1,"k":2},"l":[]}`,
		`{"l":[{"x":1,"y":2},{"x":1,"x":3}]}`,
		`{"a":"no","z":{"q":1,"q":2}}`,
		`{"a":1,"z":{"q":1,"q":2},"a":01}`,
		`{"a":01,"z":{"q":1,"q":2}}`,
		`{"z":{"q":1,"\u0071":2}}`,
		`{"z":[{"q":1},{"q":1}],"m":{"a":1,"b":2,"a":3}}`,
		`{"x":1,"y":2}`,
		`{"a":1,"l":[{"x":1,"y":2}]`,
		strings.to_string(wide),
	}
	for text in texts {
		_, built := json.build(transmute([]u8)text, opts = opts, allocator = context.temp_allocator)
		s: S
		e := read(text, &s, opts = opts)
		if built == nil {
			testing.expectf(t, refusal_of(e) != .None || e == nil, "%s: %v", text, e)
		} else {
			testing.expectf(t, e == built, "%s: %v, the build's %v", text, e, built)
		}
	}
	// The read needs no document, so a budget a document passes still reads it.
	text := strings.builder_make(context.temp_allocator)
	strings.write_byte(&text, '[')
	for i in 0 ..< 100_000 {
		strings.write_string(&text, `{"x":1,"y":2},` if i < 99_999 else `{"x":1,"y":2}]`)
	}
	src := transmute([]u8)strings.to_string(text)
	budget := json.Options {
		dups = .Refuse,
		budget = {memory = 2 << 20},
	}
	_, built := json.build(src, opts = budget, allocator = context.temp_allocator)
	testing.expect(t, built != nil)
	points: []Point
	expect_nil(t, read(string(src), &points, opts = budget))
	testing.expect_value(t, len(points), 100_000)
}

@(test)
dups_all_and_group_are_refused_as_a_member_holds_one_value :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	p: Point
	for policy in ([]tape.Duplicates{.All, .Group}) {
		e := read(`{"x":1}`, &p, opts = {dups = policy})
		testing.expect_value(t, expect_bad_option(t, e), "dups")
	}
}

@(test)
a_nil_target_and_foreign_options_are_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	var: ^Point
	e := read(`{}`, var)
	testing.expect_value(t, expect_bad_option(t, e), "target")
	p: Point
	e = read(`{}`, &p, opts = {format = tape.Dsv_Options{}})
	testing.expect_value(t, expect_bad_option(t, e), "format")
}

@(private = "file")
Many :: struct {
	m0, m1, m2, m3, m4, m5, m6, m7, m8, m9:           i32,
	m10, m11, m12, m13, m14, m15, m16, m17, m18, m19: i32,
	m20, m21, m22, m23, m24, m25, m26, m27, m28, m29: i32,
	m30, m31, m32, m33, m34, m35, m36, m37, m38, m39: i32,
	m40, m41, m42, m43, m44, m45, m46, m47, m48, m49: i32,
	m50, m51, m52, m53, m54, m55, m56, m57, m58, m59: i32,
	m60, m61, m62, m63, m64, m65, m66, m67, m68, m69: i32,
}

@(private = "file")
Many_Required :: struct {
	m0, m1, m2, m3, m4, m5, m6, m7, m8, m9: i32 `json:",required"`,
	m10, m11, m12, m13, m14, m15, m16, m17, m18, m19: i32 `json:",required"`,
	m20, m21, m22, m23, m24, m25, m26, m27, m28, m29: i32 `json:",required"`,
	m30, m31, m32, m33, m34, m35, m36, m37, m38, m39: i32 `json:",required"`,
	m40, m41, m42, m43, m44, m45, m46, m47, m48, m49: i32 `json:",required"`,
	m50, m51, m52, m53, m54, m55, m56, m57, m58, m59: i32 `json:",required"`,
	m60, m61, m62, m63, m64, m65, m66, m67, m68, m69: i32 `json:",required"`,
}

// The members `m69` down to `m0` as an object, each with its number as its value, then `tail`.
@(private = "file")
reversed_members :: proc(tail: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	for i := 69; i >= 0; i -= 1 {
		fmt.sbprintf(&b, `"m%d":%d`, i, i)
		if i != 0 {
			strings.write_byte(&b, ',')
		}
	}
	strings.write_string(&b, tail)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(test)
members_past_the_62nd_read_in_reverse_with_repeats :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	text := reversed_members(`,"m65":-65,"m3":-3,"m69":-69`)
	last: Many
	expect_nil(t, read(text, &last))
	testing.expect_value(t, last.m0, 0)
	testing.expect_value(t, last.m62, 62)
	testing.expect_value(t, last.m63, 63)
	testing.expect_value(t, last.m65, -65)
	testing.expect_value(t, last.m69, -69)
	testing.expect_value(t, last.m3, -3)
	first: Many
	expect_nil(t, read(text, &first, opts = {dups = .First}))
	testing.expect_value(t, first.m65, 65)
	testing.expect_value(t, first.m69, 69)
	testing.expect_value(t, first.m3, 3)
	testing.expect_value(t, first.m0, 0)
	// A repeat of the wrong class past the 62nd member is skipped under `.First` and refused under `.Last`.
	wrong := reversed_members(`,"m68":"no"`)
	skipped: Many
	expect_nil(t, read(wrong, &skipped, opts = {dups = .First}))
	testing.expect_value(t, skipped.m68, 68)
	refused: Many
	expect_refusal(t, read(wrong, &refused), .Expected_Integer)
}

@(test)
members_past_the_tracked_word :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	W :: struct {
		f0, f1, f2, f3, f4, f5, f6, f7, f8, f9: i32,
		g0, g1, g2, g3, g4, g5, g6, g7, g8, g9: i32,
		h0, h1, h2, h3, h4, h5, h6, h7, h8, h9: i32,
		i0, i1, i2, i3, i4, i5, i6, i7, i8, i9: i32,
		j0, j1, j2, j3, j4, j5, j6, j7, j8, j9: i32,
		k0, k1, k2, k3, k4, k5, k6, k7, k8, k9: i32,
		l0, l1, l2:                             i32,
		last:                                   Point,
		tail:                                   Point `json:"tail,required"`,
	}
	w: W
	expect_nil(t, read(`{"last":{"x":1},"f0":1,"tail":{"x":2},"last":{"y":3}}`, &w))
	testing.expect_value(t, w.last, Point{0, 3})
	testing.expect_value(t, w.tail.x, 2)
	w = {}
	path := path_in()
	e := read(`{"f0":1,"last":{}}`, &w, r = {path = &path})
	expect_refusal(t, e, .Missing_Field)
	expect_path(t, path, tape.Name("tail"))
}

@(test)
tags_flatten_and_rename :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Base :: struct {
		base_id: i32,
	}
	S :: struct {
		using base: Base,
		long_name:  i32,
		out:        i32 `json:"-"`,
		shared:     i32 `stury:"common"`,
		own:        i32 `json:"mine"`,
	}
	s: S
	expect_nil(t, read(`{"base_id":1,"long_name":2,"out":3,"common":4,"mine":5}`, &s))
	testing.expect_value(t, s, S{base = {1}, long_name = 2, shared = 4, own = 5})

	plan, err := json.plan_make(S, {rename = .Camel}, context.temp_allocator)
	expect_nil(t, err)
	defer json.plan_destroy(&plan)
	s = {}
	expect_nil(t, read(`{"baseId":1,"longName":2,"long_name":9}`, &s, r = {plan = &plan}))
	testing.expect_value(t, s.long_name, 2)
	testing.expect_value(t, s.base_id, 1)
}

@(test)
a_bad_tag_or_a_clash_is_a_plan_error :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Bad :: struct {
		a: i32 `json:"a,nonsense"`,
	}
	Clash :: struct {
		a: i32 `json:"same"`,
		b: i32 `json:"same"`,
	}
	_, e := json.plan_make(Bad, allocator = context.temp_allocator)
	testing.expect_value(t, expect_bad_option(t, e), "a")
	_, e = json.plan_make(Clash, allocator = context.temp_allocator)
	testing.expect_value(t, expect_bad_option(t, e), "b")
	free_all(context.temp_allocator)
}

@(test)
a_plan_refusal_names_the_member_or_the_type :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Leaf :: struct {
		f: proc(),
	}
	Mid :: struct {
		leaf: Leaf,
	}
	Arm :: struct {
		u: union {
			proc(),
		},
	}
	_, e := json.plan_make(struct {
			top: Mid,
		}, allocator = context.temp_allocator)
	testing.expect_value(t, expect_bad_option(t, e), "f")
	_, e = json.plan_make(Arm, allocator = context.temp_allocator)
	// An arm that no read takes names its type, as it has no name of its own.
	testing.expect_value(t, expect_bad_option(t, e), "type")
	_, e = json.plan_make(proc(), allocator = context.temp_allocator)
	testing.expect_value(t, expect_bad_option(t, e), "type")
}

@(test)
a_plan_for_another_type_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	plan, err := json.plan_make(Point, allocator = context.temp_allocator)
	expect_nil(t, err)
	defer json.plan_destroy(&plan)
	wrong: Color
	e := read(`{}`, &wrong, r = {plan = &plan})
	testing.expect_value(t, expect_bad_option(t, e), "plan")
	// A plan of Point is no plan of a pointer to Point.
	var: ^Point
	e = read(`{}`, &var, r = {plan = &plan})
	testing.expect_value(t, expect_bad_option(t, e), "plan")
	p: Point
	expect_nil(t, read(`{"x":4}`, &p, r = {plan = &plan}))
	testing.expect_value(t, p.x, 4)
}

@(test)
refusal_names_the_value_and_its_path :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		l: []Point,
		m: map[string]Point,
	}
	s: S
	path := path_in()
	e := read(`{"l":[{"x":1},{"y":"no"}]}`, &s, r = {path = &path})
	expect_refusal(t, e, .Expected_Integer)
	testing.expect_value(t, at_of(e), 19)
	expect_path(t, path, tape.Name("l"), tape.Index(1), tape.Name("y"))

	src := `{"m":{"key":{"x":300000000000}}}`
	s = {}
	clear(&path)
	e = read(src, &s, r = {path = &path})
	expect_refusal(t, e, .Above_Maximum)
	testing.expect_value(t, at_of(e), 17)
	expect_path(t, path, tape.Name("m"), tape.Name("key"), tape.Name("x"))
	buf: [128]u8
	testing.expect_value(t, tape.error_message(buf[:], e, transmute([]u8)src), "1:18: Number above the type's maximum")
}

@(test)
a_refusal_inside_a_struct_in_a_list_in_a_map_has_the_whole_path :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Item :: struct {
		id:   i32,
		tags: [2]string,
	}
	Bag :: struct {
		by_name: map[string][]Item,
	}
	text := `{"by_name":{"a":[{"id":1,"tags":["p","q"]}],"bé":[{"id":2,"tags":["p","q"]},{"id":3,"tags":["p"]}]}}`
	bag: Bag
	path := path_in()
	e := read(text, &bag, r = {path = &path})
	expect_refusal(t, e, .Too_Few)
	expect_path(t, path, tape.Name("by_name"), tape.Name("bé"), tape.Index(1), tape.Name("tags"))
	// Too few elements are known at the array's close, which is where the refusal is.
	testing.expect_value(t, text[at_of(e)], u8(']'))
	// A read that refuses nothing leaves the path empty.
	good: Bag
	expect_nil(t, read(`{"by_name":{"a":[{"id":1,"tags":["p","q"]}]}}`, &good, r = {path = &path}))
	testing.expect_value(t, len(path), 0)
}

@(test)
a_deep_path_is_kept_whole :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	v: [][][][][][][][][][]i32
	path := path_in()
	e := read(`[[[[[[[[[["no"]]]]]]]]]]`, &v, r = {path = &path})
	expect_refusal(t, e, .Expected_Integer)
	testing.expect_value(t, len(path), 10)
	for step in path {
		testing.expect_value(t, step, tape.Step(tape.Index(0)))
	}
}

@(test)
a_syntax_fault_is_the_validate_error_even_after_a_refusal :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	p: Point
	for text in ([]string{`{"x":1,}`, `{"x":"no","y":01}`, `{"x":"no"} 7`, `{"x":300000000000,"y":[}`, `{"x":"no"`}) {
		want := json.validate(transmute([]u8)text)
		testing.expectf(t, want != nil, "%s: validate accepts it", text)
		testing.expect_value(t, read(text, &p), want)
	}
	// The same through a path, which a syntax fault leaves as it was.
	path := path_in()
	e := read(`{"x":"no","y":01}`, &p, r = {path = &path})
	testing.expect_value(t, refusal_of(e), json.Typed_Refusal.None)
}

@(test)
numbers_at_each_width :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i8,
		b: u8,
		c: i64,
		d: u64,
		e: f32,
		f: f64,
	}
	s: S
	expect_nil(t, read(`{"a":-128,"b":255,"c":-9223372036854775808,"d":18446744073709551615,"e":0.1,"f":-0}`, &s))
	testing.expect_value(t, s.a, -128)
	testing.expect_value(t, s.b, 255)
	testing.expect_value(t, s.c, min(i64))
	testing.expect_value(t, s.d, max(u64))
	testing.expect_value(t, s.e, 0.1)
	testing.expect_value(t, transmute(u64)s.f, u64(1) << 63)
	for text in ([]string{`{"a":128}`, `{"b":-1}`, `{"c":9223372036854775808}`, `{"d":18446744073709551616}`, `{"f":1e400}`, `{"e":1e39}`}) {
		got := refusal_of(read(text, &s))
		want := json.Typed_Refusal.Below_Minimum if text == `{"b":-1}` else .Above_Maximum
		testing.expectf(t, got == want, "%s: %v", text, got)
	}
	expect_refusal(t, read(`{"a":1.0}`, &s), .Expected_Integer)
	expect_refusal(t, read(`{"a":null}`, &s), .Expected_Integer)
	expect_refusal(t, read(`{"e":"1"}`, &s), .Expected_Number)
}

@(test)
json5_non_finite_numbers_fill_floats :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		f: f64,
		g: f32,
	}
	s: S
	expect_nil(t, read(`{f: -Infinity, g: Infinity}`, &s, .Json5))
	testing.expect_value(t, s.f, math.inf_f64(-1))
	testing.expect_value(t, s.g, math.inf_f32(1))
	expect_nil(t, read(`{f: NaN, g: -NaN}`, &s, .Json5))
	testing.expect(t, math.is_nan(s.f) && math.is_nan(f64(s.g)))
	for text in ([]string{`{f: 1e400}`, `{g: 1e39}`, `{g: 0xffffffffffffffffffffffffffffffffffff}`}) {
		got := refusal_of(read(text, &s, .Json5))
		testing.expectf(t, got == .Above_Maximum, "%s: %v", text, got)
	}
}

@(test)
lists_arrays_and_their_lengths :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		a: [2]i32,
		f: [dynamic]i32,
		d: [dynamic]string,
	}
	s: S
	expect_nil(t, read(`{"a":[1,2],"f":[3],"d":["x","y"]}`, &s))
	testing.expect_value(t, s.a, [2]i32{1, 2})
	testing.expect_value(t, len(s.f), 1)
	testing.expect_value(t, s.f[0], 3)
	testing.expect_value(t, s.d[1], "y")
	expect_refusal(t, read(`{"a":[1]}`, &s), .Too_Few)
	expect_refusal(t, read(`{"a":[1,2,3]}`, &s), .Too_Many)
	expect_nil(t, read(`{"f":[1,2,3]}`, &s))
	testing.expect_value(t, len(s.f), 3)
	one: [1]string
	e := read(`["a","b"]`, &one)
	expect_refusal(t, e, .Too_Many)
	testing.expect_value(t, at_of(e), 5)
	Weekday :: enum u8 {
		Mon,
		Tue,
	}
	days: [Weekday]i32
	expect_nil(t, read(`[1,2]`, &days))
	testing.expect_value(t, days[.Tue], 2)
	expect_refusal(t, read(`[1]`, &days), .Too_Few)
}

@(test)
enums_bit_sets_and_map_keys :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		e:  Color,
		s:  bit_set[Color; u8],
		b:  bit_set[0 ..< 10],
		mi: map[i16]bool,
		me: map[Color]bool,
	}
	s: S
	expect_nil(t, read(`{"e":"Blue","s":["Red","Blue"],"b":[1,9],"mi":{"-3":true},"me":{"Green":true}}`, &s))
	testing.expect_value(t, s.e, Color.Blue)
	testing.expect(t, .Blue in s.s && .Green not_in s.s)
	testing.expect(t, 9 in s.b)
	testing.expect(t, s.mi[-3])
	testing.expect(t, s.me[.Green])
	expect_refusal(t, read(`{"e":"Pink"}`, &s), .Not_A_Member)
	expect_refusal(t, read(`{"e":1}`, &s), .Expected_Name)
	expect_refusal(t, read(`{"b":[10]}`, &s), .Above_Maximum)
	// An integer past `i64` is past the maximum, as it is for an integer field, and a fraction is no integer.
	expect_refusal(t, read(`{"b":[99999999999999999999]}`, &s), .Above_Maximum)
	expect_refusal(t, read(`{"b":[1.0]}`, &s), .Expected_Integer)
	expect_refusal(t, read(`{"mi":{"x":true}}`, &s), .Expected_Integer)
	narrow: map[i8]i32
	expect_refusal(t, read(`{"300":1}`, &narrow), .Above_Maximum)
	ints, err := json.plan_make(Color, {enums = .Int}, context.temp_allocator)
	expect_nil(t, err)
	defer json.plan_destroy(&ints)
	c: Color
	expect_nil(t, read(`7`, &c, r = {plan = &ints}))
	testing.expect_value(t, c, Color.Blue)
	expect_refusal(t, read(`3`, &c, r = {plan = &ints}), .Not_A_Member)
}

@(test)
pointers_and_maybes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		p: ^Point,
		l: ^[]i32,
		m: Maybe(i32),
	}
	held := Point{1, 2}
	s := S {
		p = &held,
	}
	expect_nil(t, read(`{"p":{"y":9},"l":[1,2],"m":4}`, &s))
	// A pointer the destination holds is read through.
	testing.expect(t, s.p == &held)
	testing.expect_value(t, held, Point{1, 9})
	testing.expect_value(t, len(s.l^), 2)
	testing.expect_value(t, s.m.?, 4)
	expect_nil(t, read(`{"p":null,"m":null}`, &s))
	testing.expect(t, s.p == nil && s.m == nil)
	fresh: S
	expect_nil(t, read(`{"p":{"x":3}}`, &fresh))
	testing.expect(t, fresh.p != nil && fresh.p.x == 3)
}

@(test)
unions_by_class :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	U :: union {
		i64,
		string,
		[]i32,
	}
	us: []U
	expect_nil(t, read(`[1,"s",[2],null]`, &us))
	testing.expect_value(t, us[0].(i64), 1)
	testing.expect_value(t, us[1].(string), "s")
	testing.expect_value(t, us[2].([]i32)[0], 2)
	testing.expect(t, us[3] == nil)
	expect_refusal(t, read(`[true]`, &us), .No_Arm)
	expect_refusal(t, read(`[{"a":1}]`, &us), .No_Arm)
	B :: union {
		bool,
		Point,
		f64,
	}
	bs: []B
	expect_nil(t, read(`[true,{"x":1},2.5]`, &bs))
	testing.expect_value(t, bs[0].(bool), true)
	testing.expect_value(t, bs[1].(Point), Point{1, 0})
	testing.expect_value(t, bs[2].(f64), 2.5)
}

@(test)
two_arms_of_one_class_refuse_the_plan :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	_, e := json.plan_make(union {
			i32,
			f64,
		}, allocator = context.temp_allocator)
	expect_bad_option(t, e)
	_, e = json.plan_make(union {
			Point,
			map[string]i32,
		}, allocator = context.temp_allocator)
	expect_bad_option(t, e)
}

@(test)
an_any_is_refused_by_the_plan :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for text in ([?]string{`{"a":[1,"s"]}`, `null`, `1`}) {
		v: any
		expect_bad_option(t, read(text, &v))
	}
	S :: struct {
		a: any,
	}
	s: S
	testing.expect_value(t, expect_bad_option(t, read(`{"a":1}`, &s)), "a")
}

@(test)
raw_holds_the_span :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		a: json.Raw,
		b: []json.Raw,
		c: Point,
	}
	s: S
	text := `{"a":{"k": [1, {}]},"b":["s\n",2,[3],null],"c":{"x":1}}`
	expect_nil(t, read(text, &s))
	testing.expect_value(t, s.a, json.Raw(`{"k": [1, {}]}`))
	testing.expect_value(t, s.b[0], json.Raw(`"s\n"`))
	testing.expect_value(t, s.b[2], json.Raw(`[3]`))
	testing.expect_value(t, s.b[3], json.Raw(`null`))
	testing.expect_value(t, s.c.x, 1)
	testing.expect(t, raw_data(string(s.a)) != raw_data(text)[5:])
	// A malformed value inside is the walk's to refuse.
	broken := `{"a":{"k":01}}`
	testing.expect_value(t, read(broken, &s), json.validate(transmute([]u8)broken))
	s = {}
	expect_nil(t, read(text, &s, r = {borrow_strings = true}))
	testing.expect(t, raw_data(string(s.a)) == raw_data(text)[5:])
	testing.expect(t, raw_data(string(s.b[2])) == raw_data(text)[(strings.index(text, "[3]")):])
	// A Raw is any value, so it refuses nothing of its own.
	var: json.Raw
	for each in ([]string{`1`, `"x"`, `[]`, `{}`, `true`, `null`}) {
		expect_nil(t, read(each, &var))
		testing.expect_value(t, var, json.Raw(each))
	}
}

@(test)
refuse_unknown_refuses_a_key_no_member_names :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	p: Point
	// A key the type does not name is passed by default.
	expect_nil(t, read(`{"x":1,"nope":[2,{"a":1}],"y":3}`, &p))
	testing.expect_value(t, p, Point{1, 3})
	path := path_in()
	e := read(`{"x":1,"nope":2}`, &p, r = {refuse_unknown = true, path = &path})
	expect_refusal(t, e, .Unknown_Field)
	expect_path(t, path, tape.Name("nope"))
	expect_refusal(t, read(`{"":1}`, &p, r = {refuse_unknown = true}), .Unknown_Field)
	// A key spelled with an escape is matched by what it decodes to.
	expect_nil(t, read(`{"x":5}`, &p, r = {refuse_unknown = true}))
	testing.expect_value(t, p.x, 5)
	// A member the tag leaves out is unknown.
	S :: struct {
		a: i32,
		b: i32 `json:"-"`,
	}
	s: S
	expect_refusal(t, read(`{"a":1,"b":2}`, &s, r = {refuse_unknown = true}), .Unknown_Field)
	// An unknown key deep in a list of structs.
	l: []Point
	clear(&path)
	expect_refusal(t, read(`[{"x":1},{"z":1}]`, &l, r = {refuse_unknown = true, path = &path}), .Unknown_Field)
	expect_path(t, path, tape.Index(1), tape.Name("z"))
}

@(test)
wide_bit_sets_round_trip_and_required_omitempty_is_accepted :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Wide_Bits :: struct {
		b: bit_set[0 ..= 127; u128],
	}
	w: Wide_Bits
	expect_nil(t, read(`{"b":[0,127]}`, &w))
	testing.expect_value(t, w.b, bit_set[0 ..= 127; u128]{0, 127})

	Flags :: struct {
		a: i32 `json:"a,required,omitempty,omitunset"`,
	}
	f: Flags
	expect_nil(t, read(`{"a":1}`, &f))
	testing.expect_value(t, f.a, 1)
	expect_refusal(t, read(`{}`, &f), .Missing_Field)
}

@(test)
strings_are_copied_unless_borrowed :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	text := `["plain","a\nb"]`
	src := transmute([]u8)text
	v: []string
	expect_nil(t, read(text, &v))
	testing.expect(t, raw_data(v[0]) != raw_data(src[2:]))
	testing.expect_value(t, v[0], "plain")
	w: []string
	expect_nil(t, read(text, &w, r = {borrow_strings = true}))
	testing.expect(t, raw_data(w[0]) == raw_data(src[2:]))
	// A string with an escape is decoded, so it is no span of the text.
	testing.expect_value(t, w[1], "a\nb")
	testing.expect(t, raw_data(w[1]) < raw_data(src) || raw_data(w[1]) >= raw_data(src)[len(src):])
}

@(test)
borrowed_strings_point_into_the_text_in_every_place :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		name: string,
		list: [dynamic]string,
		m:    map[string]string,
		fix:  [1]string,
		opt:  Maybe(string),
	}
	text := `{"name":"alpha","list":["b","c"],"m":{"key":"val"},"fix":["fixed"],"opt":"maybe"}`
	src := transmute([]u8)text
	inside :: proc(s: string, src: []u8) -> bool {
		lo := uintptr(raw_data(src))
		at := uintptr(raw_data(s))
		return at >= lo && at + uintptr(len(s)) <= lo + uintptr(len(src))
	}
	s: S
	expect_nil(t, read(text, &s, r = {borrow_strings = true}))
	testing.expect(t, inside(s.name, src))
	testing.expect(t, inside(s.list[1], src))
	testing.expect(t, inside(s.fix[0], src))
	testing.expect(t, inside(s.opt.?, src))
	for k, v in s.m {
		testing.expect(t, inside(v, src))
		testing.expect_value(t, k, "key")
	}
	testing.expect_value(t, s.name, "alpha")
	// With no borrowing nothing points into the text.
	c: S
	expect_nil(t, read(text, &c))
	testing.expect(t, !inside(c.name, src))
	testing.expect(t, !inside(c.list[1], src))
	testing.expect(t, !inside(c.fix[0], src))
	testing.expect_value(t, c.name, "alpha")
}

// A copied empty string is the zero string, so a caller deleting each string frees nothing of the text.
@(test)
copied_empty_strings_are_the_zero_string :: proc(t: ^testing.T) {
	testkit.deadline(t)
	S :: struct {
		s:  string,
		l:  []string,
		m:  map[string]string,
		q:  Maybe(string),
		ps: ^string,
	}
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	context.allocator = mem.tracking_allocator(&tracking)
	s: S
	expect_nil(t, json.unmarshal(transmute([]u8)string(`{"s":"","l":["","a"],"m":{"":""},"q":"","ps":""}`), &s))
	testing.expect(t, raw_data(s.s) == nil && raw_data(s.l[0]) == nil && raw_data(s.q.?) == nil && raw_data(s.ps^) == nil)
	delete(s.s)
	for e in s.l {
		delete(e)
	}
	delete(s.l)
	for k, v in s.m {
		delete(k)
		delete(v)
	}
	delete(s.m)
	delete(s.q.?)
	delete(s.ps^)
	free(s.ps)
	testing.expect_value(t, len(tracking.bad_free_array), 0)
	testing.expect_value(t, len(tracking.allocation_map), 0)
}

@(test)
what_a_refused_read_allocated_stays_reachable :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Row :: struct {
		s: string,
		l: []string,
		m: map[string]string,
		p: ^Point,
	}
	free_row :: proc(r: Row) {
		delete(r.s)
		for s in r.l {
			delete(s)
		}
		delete(r.l)
		for k, v in r.m {
			delete(k)
			delete(v)
		}
		delete(r.m)
		free(r.p)
	}
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	alloc := mem.tracking_allocator(&tracking)
	plan, _ := json.plan_make([]Row, allocator = context.temp_allocator)
	defer free_all(context.temp_allocator)
	texts := []string {
		`[{"s":"a","l":["b","c"],"m":{"k":"v"},"p":{"x":1}},{"s":"d","l":["e",1]}]`,
		`[{"s":"a","l":["b","c","d","e","f","g","h","i","j"]`,
		`[{"m":{"k":"v","j":2}}]`,
		`[{"p":{"x":"no"}}]`,
		`[{"s":"a"},7]`,
	}
	for text in texts {
		rows: []Row
		e := json.unmarshal(transmute([]u8)text, &rows, read = {plan = &plan}, allocator = alloc)
		testing.expect(t, e != nil)
		for r in rows {
			context.allocator = alloc
			free_row(r)
		}
		delete(rows, alloc)
		testing.expect_value(t, len(tracking.allocation_map), 0)
		testing.expect_value(t, len(tracking.bad_free_array), 0)
	}
}

@(test)
json5_and_jsonc_read_alike :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i32,
		b: f64,
		c: string,
	}
	want := S{5, 16, "x"}
	s: S
	expect_nil(t, read(`{a:+5,'b':0x10,c:'x',/*c*/}`, &s, .Json5))
	testing.expect_value(t, s, want)
	s = {}
	expect_nil(t, read(`{"a":5,"b":16,/*c*/"c":"x",}`, &s, .Jsonc))
	testing.expect_value(t, s, want)
	// A skipped member takes a spelling of its own and leaves the cursor where it stood.
	s = {}
	expect_nil(t, read(`{a:1,zz:-0x10,b:2,zz:1.,c:'y'}`, &s, .Json5))
	testing.expect_value(t, s, S{1, 2, "y"})
	// A point, a fraction or an exponent is no integer in any spelling, however far out of range.
	for text in ([]string{`{a:1e9999}`, `{a:+1e9999}`, `{a:.5e9999}`, `{a:5.}`}) {
		got := refusal_of(read(text, &s, .Json5))
		testing.expectf(t, got == .Expected_Integer, "%s: %v", text, got)
	}
	// A bit_set reads an integer in any spelling a plain field does.
	B :: struct {
		b: bit_set[0 ..< 10],
	}
	bits: B
	expect_nil(t, read(`{b:[0,0x5,+7]}`, &bits, .Json5))
	testing.expect_value(t, bits.b, bit_set[0 ..< 10]{0, 5, 7})
	// Plain JSON refuses what only JSON5 and JSONC spell.
	expect_nil(t, read(`{"a":1}`, &s, .Json))
	testing.expect_value(t, read(`{"a":1,}`, &s, .Json), json.validate(transmute([]u8)string(`{"a":1,}`)))
}

// `depth` objects, each holding the next under "d", around a null.
@(private = "file")
nested_text :: proc(depth: int) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< depth {
		strings.write_string(&b, `{"d":`)
	}
	strings.write_string(&b, "null")
	for _ in 0 ..< depth {
		strings.write_byte(&b, '}')
	}
	return transmute([]u8)strings.to_string(b)
}

@(test)
max_depth_past_the_stack_form :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Deep :: struct {
		d: ^Deep,
	}
	depth := tape.DEFAULT_DEPTH + 100
	d: Deep
	src := nested_text(depth)
	expect_nil(t, json.unmarshal(src, &d, opts = json.Options{budget = {depth = u32(depth)}}, allocator = context.temp_allocator))
	e := json.unmarshal(src, &d, allocator = context.temp_allocator)
	testing.expect_value(t, e, json.validate(src))
	testing.expect(t, e != nil)
}

@(test)
recursive_types_through_slices_and_pointers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Tree :: struct {
		v:    i32,
		kids: []Tree,
		next: ^Tree,
		by:   map[string]Tree,
	}
	tree: Tree
	text := `{"v":1,"kids":[{"v":2,"kids":[{"v":3}]},{"v":4,"next":{"v":5}}],"next":{"v":6,"by":{"k":{"v":7}}}}`
	expect_nil(t, read(text, &tree))
	testing.expect_value(t, tree.v, 1)
	testing.expect_value(t, len(tree.kids), 2)
	testing.expect_value(t, tree.kids[0].kids[0].v, 3)
	testing.expect_value(t, tree.kids[1].next.v, 5)
	testing.expect_value(t, tree.next.v, 6)
	testing.expect_value(t, tree.next.by["k"].v, 7)
	path := path_in()
	bad: Tree
	e := read(`{"kids":[{"v":1},{"next":{"kids":[{"v":"no"}]}}]}`, &bad, r = {path = &path})
	expect_refusal(t, e, .Expected_Integer)
	expect_path(t, path, tape.Name("kids"), tape.Index(1), tape.Name("next"), tape.Name("kids"), tape.Index(0), tape.Name("v"))
	// A plan of a recursive type is made once and shared.
	plan, err := json.plan_make(Tree, allocator = context.temp_allocator)
	expect_nil(t, err)
	defer json.plan_destroy(&plan)
	again: Tree
	expect_nil(t, read(text, &again, r = {plan = &plan}))
	testing.expect_value(t, again.next.by["k"].v, 7)
}

@(private = "file")
Wide :: struct {
	a0, a1, a2, a3, a4, a5, a6, a7, a8, a9: i32,
	b0, b1, b2, b3, b4, b5, b6, b7, b8, b9: i32,
	c0, c1, c2, c3, c4, c5, c6, c7, c8, c9: i32,
	d0, d1, d2, d3, d4, d5, d6, d7, d8, d9: i32,
	e0, e1, e2, e3, e4, e5, e6, e7, e8, e9: i32,
	f0, f1, f2, f3, f4, f5, f6, f7, f8, f9: i32,
	g0, g1, g2, g3, g4:                     i32,
}

@(test)
a_struct_past_the_tracked_word_starts_with_no_repeats :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	w: []Wide
	expect_nil(t, read(`[{"g4":1,"g4":2},{"g4":3}]`, &w, opts = {dups = .First}))
	testing.expect_value(t, w[0].g4, 1)
	testing.expect_value(t, w[1].g4, 3)
}

@(test)
a_value_a_wrapper_refuses_has_the_wrappers_path :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		m: Maybe(i32),
		p: ^i32,
		u: union {
			i32,
			string,
		},
		w: Maybe(^Maybe(i32)),
	}
	plan, err := json.plan_make(S, allocator = context.temp_allocator)
	expect_nil(t, err)
	for name in ([]string{"m", "p", "u", "w"}) {
		s: S
		path := path_in()
		e := read(strings.concatenate({`{"`, name, `":1.5}`}, context.temp_allocator), &s, r = {path = &path, plan = &plan})
		testing.expect_value(t, refusal_of(e) != .None, true)
		expect_path(t, path, tape.Name(name))
	}
	l: []^i32
	path := path_in()
	list_plan, list_err := json.plan_make([]^i32, allocator = context.temp_allocator)
	expect_nil(t, list_err)
	e := read(`[1,2,1.5]`, &l, r = {path = &path, plan = &list_plan})
	expect_refusal(t, e, .Expected_Integer)
	expect_path(t, path, tape.Index(2))
}

@(test)
a_pointer_maybe_reads_repeats_and_marshals_within_its_bytes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		w: Maybe(^Point),
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	s: S
	expect_nil(t, json.unmarshal(transmute([]u8)string(`{"w":{"x":1,"y":2},"w":{"x":3,"y":4}}`), &s, opts = {dups = .Last}, allocator = alloc))
	p, ok := s.w.?
	testing.expect_value(t, ok, true)
	testing.expect_value(t, p^, Point{3, 4})
	out, merr := json.marshal(&s, allocator = context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, string(out), `{"w":{"x":3,"y":4}}`)
	free(p, alloc)
	s.w = nil

	expect_nil(t, json.unmarshal(transmute([]u8)string(`{"w":{"x":5,"y":6},"w":null}`), &s, opts = {dups = .Last}, allocator = alloc))
	testing.expect_value(t, s.w == nil, true)
	out_nil, merr_nil := json.marshal(&s, allocator = context.temp_allocator)
	testing.expect_value(t, merr_nil, nil)
	testing.expect_value(t, string(out_nil), `{"w":null}`)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
a_refused_wrapper_element_leaves_the_rest_as_it_was_and_nothing_allocated :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	S :: struct {
		m: Maybe(i32),
		p: ^Point,
		w: Maybe(^i32),
		u: union {
			i32,
			string,
		},
		l: []Maybe(i32),
		q: []^i32,
	}
	kept := i32(3)
	for text in ([]string{`{"m":1.5}`, `{"p":[1]}`, `{"w":"x"}`, `{"u":2.5}`, `{"l":[1,2.5]}`, `{"q":[1,"x"]}`}) {
		s := S {
			m = 5,
			w = &kept,
			u = "keep",
		}
		e := json.unmarshal(transmute([]u8)text, &s, allocator = alloc)
		testing.expectf(t, refusal_of(e) != .None, "%s: %v", text, e)
		testing.expect_value(t, s.m, 5)
		testing.expect(t, s.w == &kept)
		testing.expect_value(t, s.u.(string), "keep")
		// A pointer the read allocated stays reachable, so the caller frees it.
		free(s.p, alloc)
		// The list a refusal ends holds the elements read so far, at most the ones the text has.
		testing.expectf(t, len(s.q) <= 2 && len(s.l) <= 2, "%s: lists of %d and %d", text, len(s.q), len(s.l))
		if len(s.q) <= 2 {
			for e in s.q {
				free(e, alloc)
			}
		}
		if len(s.q) <= 2 && len(s.l) <= 2 {
			delete(s.q, alloc)
			delete(s.l, alloc)
		}
		testing.expectf(t, len(track.allocation_map) == 0, "%s leaves %d allocations", text, len(track.allocation_map))
		testing.expect_value(t, len(track.bad_free_array), 0)
	}
	// A wrapper that held nothing still holds nothing.
	Nil :: struct {
		m: Maybe(i32),
		u: union {
			i64,
			string,
		},
		t: Maybe(time.Time),
	}
	for text in ([]string{`{"m":"x"}`, `{"u":1.5}`, `{"t":5}`}) {
		s: Nil
		e := json.unmarshal(transmute([]u8)text, &s, allocator = alloc)
		testing.expectf(t, refusal_of(e) != .None, "%s: %v", text, e)
		testing.expectf(t, s.m == nil && s.u == nil && s.t == nil, "%s: %v", text, s)
	}
}

@(test)
a_missing_member_keeps_the_path_to_its_struct :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	In :: struct {
		b: i32 `json:",required"`,
	}
	S :: struct {
		a: In,
	}
	s: S
	text := `{"a":{}}`
	path := path_in()
	e := read(text, &s, r = {path = &path})
	expect_refusal(t, e, .Missing_Field)
	expect_path(t, path, tape.Name("a"), tape.Name("b"))
	// The place is the close of the struct that lacks the member.
	testing.expect_value(t, at_of(e), 6)
}

@(test)
unknown_members_between_required_members_are_skipped :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i32 `json:",required"`,
		b: i32 `json:",required"`,
	}
	s: S
	expect_nil(t, read(`{"z":1,"a":1,"b":2,"y":3}                `, &s))
	testing.expect_value(t, s, S{1, 2})
	expect_nil(t, read(`{"z":{"q":[1]},"b":4,"y":[],"a":3}`, &s))
	testing.expect_value(t, s, S{3, 4})
	expect_refusal(t, read(`{"z":1,"a":1,"y":3}`, &s), .Missing_Field)
}

@(test)
a_tolerated_string_may_decode_longer_than_it_is :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	s: string
	expect_nil(t, read("\"\xff\xff\"", &s, opts = {tolerate = {.Invalid_Utf8}}))
	testing.expect_value(t, s, "��")
}

@(test)
a_refused_plan_leaves_nothing_allocated :: proc(t: ^testing.T) {
	testkit.deadline(t)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	U :: union {
		i32,
		string,
	}
	S :: struct {
		u:    U,
		bad:  rawptr,
		need: i32 `json:",required"`,
	}
	_, e := json.plan_make(S, allocator = mem.tracking_allocator(&track))
	testing.expect_value(t, expect_bad_option(t, e), "bad")
	testing.expect_value(t, len(track.allocation_map), 0)
	// A one-shot read of the same type refuses before it reads and leaves nothing either.
	s: S
	e = json.unmarshal(transmute([]u8)string(`{}`), &s, allocator = mem.tracking_allocator(&track))
	testing.expect_value(t, expect_bad_option(t, e), "bad")
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
an_enum_map_key_past_i64_is_no_member :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	E :: enum i64 {
		A = -1,
	}
	plan, err := json.plan_make(map[E]i32, {enums = .Int}, context.temp_allocator)
	expect_nil(t, err)
	m: map[E]i32
	e := read(`{"18446744073709551615":1}`, &m, r = {plan = &plan})
	testing.expect(t, refusal_of(e) != .None)
	expect_nil(t, read(`{"-1":1}`, &m, r = {plan = &plan}))
	testing.expect_value(t, m[.A], 1)
}

@(private = "file")
Poison_Free :: struct {
	inner: runtime.Allocator,
}

// An allocator that fills a block with 0xdd when it is freed with its size.
@(private = "file")
poison_free_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	p := (^Poison_Free)(data)
	if mode == .Free && old_memory != nil && old_size > 0 {
		mem.set(old_memory, 0xdd, old_size)
	}
	return p.inner.procedure(p.inner.data, mode, size, alignment, old_memory, old_size, loc)
}

// A plan error names the Odin member, which outlives the plan, a clash the later of the two.
@(test)
a_plan_error_names_its_field_after_the_plan_is_gone :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	inner := Poison_Free {
		inner = context.temp_allocator,
	}
	poisoned := runtime.Allocator{poison_free_proc, &inner}
	_, e := json.plan_make(struct {
			a: proc() `json:"al\pha"`,
		}, allocator = poisoned)
	testing.expect_value(t, expect_bad_option(t, e), "a")
	_, e = json.plan_make(struct {
			a: i32 `json:"al\pha"`,
			b: i32 `json:"al\pha"`,
		}, allocator = poisoned)
	testing.expect_value(t, expect_bad_option(t, e), "b")
}

// A read with no plan frees the one it makes, so its path names a member whose key the plan unescaped by its Odin name.
@(test)
a_one_shot_read_names_a_spelled_member_by_its_field :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i32 `json:"al\pha"`,
		b: i32 `json:"be\ta"`,
	}
	inner := Poison_Free {
		inner = context.temp_allocator,
	}
	poisoned := runtime.Allocator{poison_free_proc, &inner}
	s: S
	expect_nil(t, json.unmarshal(transmute([]u8)string(`{"alpha":1,"beta":2}`), &s, allocator = poisoned))
	testing.expect_value(t, s, S{1, 2})
	path := path_in()
	e := json.unmarshal(transmute([]u8)string(`{"alpha":"x"}`), &s, read = {path = &path}, allocator = poisoned)
	expect_refusal(t, e, .Expected_Integer)
	expect_path(t, path, tape.Name("a"))
}

// Numbers read into f32 with one rounding. The cases sit on or next to an f32 midpoint where the binary64 lands on
// the midpoint.
@(test)
f32_rounds_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	OUT :: 0x7f800000 // infinity, which a read refuses as out of range
	cases := []struct {
		text: string,
		want: u32,
	} {
		{"1.000000059604644775390625", 0x3f800000},
		{"1000000059604644775390625000001000000059e-39", 0x3f800001},
		{"1000000059604644775390624999998999999940e-39", 0x3f800000},
		{"1.000000178813934326171875", 0x3f800002},
		{"1000000178813934326171875000001000000178e-39", 0x3f800002},
		{"1000000178813934326171874999998999999821e-39", 0x3f800001},
		{"2101947696487225606385594374934874196920392912814773657635602425834686624028790902229957282543182373046875e-150", 0x00000002},
		{"2101947696487225606385594374936976144616e-84", 0x00000002},
		{"2101947696487225606385594374932772249223e-84", 0x00000001},
		{"700649232162408535461864791644958065640130970938257885878534141944895541342930300743319094181060791015625e-150", 0x00000000},
		{"7006492321624085354618647916456587148722e-85", 0x00000001},
		{"7006492321624085354618647916442574164079e-85", 0x00000000},
		{"340282356779733661637539395458142568448", OUT},
		{"3402823567797336616375393954578022860912e-1", 0x7f7fffff},
		{"0xe5c9908000000001", 0x5f65c991},
		{"0x2633b3dffffffff", 0x5c18cecf},
		{"0x100000100000000000000001", 0x6d800001},
		{"-0x100000100000000000000001", 0xed800001},
		{"0x1000000fffffffffffffffff", 0x6d800000},
		{"0x1000000000000000000000000000000000", OUT},
	}
	plan, _ := json.plan_make([]f32, allocator = context.temp_allocator)
	for c in cases {
		text := strings.concatenate({"[", c.text, "]"}, context.temp_allocator)
		got: []f32
		e := read(text, &got, .Json5, {plan = &plan})
		if c.want == OUT {
			testing.expectf(t, refusal_of(e) == .Above_Maximum, "%s: %v, want Above_Maximum", c.text, e)
		} else {
			ok := e == nil && len(got) == 1 && transmute(u32)got[0] == c.want
			testing.expectf(t, ok, "%s: %v %v, want %08x", c.text, got, e, c.want)
		}
	}
}

@(test)
types_the_plan_refuses :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Empty :: struct {}
	Bits :: bit_field u8 {
		a: u8 | 8,
	}
	refused := []typeid {
		[]Empty, [dynamic]Empty, [2]Empty, rawptr, Maybe(rawptr), []Maybe(rawptr), [^]i32, proc(), typeid, Bits, #simd[4]f32,
		matrix[2, 2]f32, complex64, quaternion256, cstring, any, string16, #soa[]Point, [dynamic; 2]i32,
	}
	for T in refused {
		_, e := typed.plan_make(T, "json", allocator = context.temp_allocator)
		testing.expectf(t, e != nil, "%v is taken", T)
	}
	_, e := json.plan_make(map[string]Empty, allocator = context.temp_allocator)
	expect_nil(t, e)
}

// Odin's Windows build refuses the array counts these types take (1 << 29 and more).
when ODIN_OS != .Windows {
	@(test)
	types_past_4_gib :: proc(t: ^testing.T) {
		testkit.deadline(t)
		defer free_all(context.temp_allocator)
		Huge :: struct {
			big: [1 << 29]u64,
			x:   i32,
		}
		Past_4_Gib :: [1 << 32 + 8]u8
		// A plan holds no size of a type, so a type past 4 GiB is no reason to refuse it.
		for T in ([]typeid{Huge, []Past_4_Gib, ^Huge, map[string]Past_4_Gib}) {
			_, e := typed.plan_make(T, "json", allocator = context.temp_allocator)
			expect_nil(t, e)
		}
		_, e := json.plan_make([1 << 32 - 1]u8, allocator = context.temp_allocator)
		expect_nil(t, e)
	}
}

@(test)
required_members_read_in_any_order_past_the_63rd_bit :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	text := reversed_members("")
	v: Many_Required
	expect_nil(t, read(text, &v))
	testing.expect_value(t, v.m0, 0)
	testing.expect_value(t, v.m69, 69)
	// The 70th member absent is the one reported.
	cut := strings.index(text, `"m69":69,`)
	missing := strings.concatenate({text[:cut], text[cut + len(`"m69":69,`):]}, context.temp_allocator)
	w: Many_Required
	path := path_in()
	e := read(missing, &w, r = {path = &path})
	expect_refusal(t, e, .Missing_Field)
	expect_path(t, path, tape.Name("m69"))
	// A middle member absent past the 63rd bit, and the first one.
	for name in ([]string{"m64", "m0"}) {
		// The last member in the text has no comma after it.
		needle := fmt.tprintf(`"%s":%s,`, name, name[1:]) if name != "m0" else `,"m0":0`
		at := strings.index(text, needle)
		without := strings.concatenate({text[:at], text[at + len(needle):]}, context.temp_allocator)
		clear(&path)
		expect_refusal(t, read(without, &w, r = {path = &path}), .Missing_Field)
		expect_path(t, path, tape.Name(name))
	}
	// A repeat of a required member satisfies it once and the later value wins.
	again: Many_Required
	expect_nil(t, read(reversed_members(`,"m66":-1`), &again))
	testing.expect_value(t, again.m66, -1)
}

@(test)
a_required_struct_inside_a_list_inside_a_required_struct :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Leaf :: struct {
		x: i32 `json:",required"`,
	}
	Mid :: struct {
		leaves: []Leaf `json:",required"`,
		tag:    string,
	}
	Top :: struct {
		mids: []Mid `json:",required"`,
	}
	v: Top
	expect_nil(t, read(`{"mids":[{"leaves":[{"x":1},{"x":2}],"tag":"a"},{"leaves":[],"tag":"b"}]}`, &v))
	testing.expect_value(t, len(v.mids), 2)
	testing.expect_value(t, v.mids[0].leaves[1].x, 2)
	w: Top
	path := path_in()
	e := read(`{"mids":[{"leaves":[{"x":1},{}]}]}`, &w, r = {path = &path})
	expect_refusal(t, e, .Missing_Field)
	expect_path(t, path, tape.Name("mids"), tape.Index(0), tape.Name("leaves"), tape.Index(1), tape.Name("x"))
	clear(&path)
	expect_refusal(t, read(`{"mids":[{"tag":"a"}]}`, &w, r = {path = &path}), .Missing_Field)
	expect_path(t, path, tape.Name("mids"), tape.Index(0), tape.Name("leaves"))
	clear(&path)
	expect_refusal(t, read(`{}`, &w, r = {path = &path}), .Missing_Field)
	expect_path(t, path, tape.Name("mids"))
}

@(test)
a_repeated_key_is_refused_inside_a_skipped_value_and_a_list :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i32,
		l: []Point,
	}
	opts := json.Options {
		dups = .Refuse,
	}
	s: S
	e := read(`{"a":1,"skipped":{"k":1,"k":2},"l":[]}`, &s, opts = opts)
	f, _ := e.(tape.Fault)
	testing.expect_value(t, f.kind, tape.Fault_Kind.Duplicate_Key)
	testing.expect_value(t, f.at, 24)
	l: S
	e = read(`{"l":[{"x":1,"y":2},{"x":1,"x":3}]}`, &l, opts = opts)
	f, _ = e.(tape.Fault)
	testing.expect_value(t, f.kind, tape.Fault_Kind.Duplicate_Key)
	testing.expect_value(t, f.at, 27)
	ok: S
	expect_nil(t, read(`{"l":[{"x":1,"y":2}]}`, &ok, opts = opts))
	testing.expect_value(t, len(ok.l), 1)
}

// A syntax fault past `FRAME_ROOM` (64 levels) settles open frames before freeing the frame buffer (no UAF under ASan),
// and frame growth accounts to the caller's allocator and `Budget.memory`.
@(test)
deep_syntax_fault_past_frame_room_settles_before_freeing_frames :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Node :: struct {
		kids: []Node,
	}
	free_node :: proc(n: Node, a: runtime.Allocator) {
		for child in n.kids {
			free_node(child, a)
		}
		delete(n.kids, a)
	}
	depth := 80
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< depth {
		strings.write_string(&b, `{"kids":[`)
	}
	strings.write_string(&b, `{"kids":[!`) // mid-stream syntax fault at depth > 64 (160 frames open)
	src := transmute([]u8)strings.to_string(b)

	plan, perr := json.plan_make(Node, allocator = context.temp_allocator)
	expect_nil(t, perr)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	root: Node
	e := json.unmarshal(src, &root, read = {plan = &plan}, allocator = alloc)
	_, is_fault := e.(tape.Fault)
	testing.expectf(t, is_fault && refusal_of(e) == .None, "expected syntax fault, got %v", e)
	free_node(root, alloc)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)

	// Deep nesting past `FRAME_ROOM` charges frame growth to `Budget.memory`.
	Deep :: struct {
		d: ^Deep,
	}
	deep_plan, dperr := json.plan_make(Deep, allocator = context.temp_allocator)
	expect_nil(t, dperr)
	deep_src := nested_text(80)
	deep: Deep
	be := json.unmarshal(deep_src, &deep, read = {plan = &deep_plan}, opts = {budget = {memory = 512}}, allocator = alloc)
	ex, is_ex := be.(tape.Exceeded)
	testing.expectf(t, is_ex && ex.kind == .Memory, "expected memory budget exceeded, got %v", be)
	for cur := deep.d; cur != nil; {
		next := cur.d
		free(cur, alloc)
		cur = next
	}
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// Under `.First`, a target larger than `BEFORE_ROOM` (128 B) allocates no snapshot, so scalar/borrowed reads succeed
// under `mem.nil_allocator()` and tight memory budgets. Also verifies `path` is cleared before early option errors.
@(test)
first_policy_skips_before_snapshot_and_path_clears_early :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Big :: struct {
		a:   i64,
		s:   string,
		pad: [32]u64,
	}
	#assert(size_of(Big) > 128)
	plan, perr := json.plan_make(Big, allocator = context.temp_allocator)
	expect_nil(t, perr)
	dst := Big{a = 9, s = "keep"}
	dst.pad[31] = 77
	src := transmute([]u8)string(`{"a":1,"s":"ok","a":2,"s":"ignored"}`)
	expect_nil(t, json.unmarshal(src, &dst, read = {plan = &plan, borrow_strings = true}, opts = {dups = .First}, allocator = mem.nil_allocator()))
	testing.expect_value(t, dst.a, 1)
	testing.expect_value(t, dst.s, "ok")
	testing.expect_value(t, dst.pad[31], 77)

	// Reused `path` is cleared even when `read` returns early on `Bad_Option`.
	path := path_in()
	append(&path, tape.Name("stale"))
	e := json.unmarshal(src, &dst, read = {plan = &plan, path = &path}, opts = {dups = .All}, allocator = context.temp_allocator)
	testing.expect_value(t, expect_bad_option(t, e), "dups")
	testing.expect_value(t, len(path), 0)
}

// Plain `0`, `-0`, `0.0`, `-0.0`, and `f32` boundary/special values keep bit-exact IEEE-754 results, and deep map paths
// record and free cleanly.
@(test)
float_zero_f32_edges_long_keys_and_map_paths :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	// Signed zeros into f64 and f32.
	f64s: []f64
	expect_nil(t, read(`[0,-0,0.0,-0.0]`, &f64s))
	if testing.expect_value(t, len(f64s), 4) {
		testing.expect_value(t, transmute(u64)f64s[0], u64(0x0000_0000_0000_0000))
		testing.expect_value(t, transmute(u64)f64s[1], u64(0x8000_0000_0000_0000))
		testing.expect_value(t, transmute(u64)f64s[2], u64(0x0000_0000_0000_0000))
		testing.expect_value(t, transmute(u64)f64s[3], u64(0x8000_0000_0000_0000))
	}
	f32s: []f32
	expect_nil(t, read(`[0,-0,0.0,-0.0,1.17549435e-38,1.1754942e-38,3.4028234663852886e+38,-3.4028234663852886e+38]`, &f32s))
	if testing.expect_value(t, len(f32s), 8) {
		testing.expect_value(t, transmute(u32)f32s[0], u32(0x0000_0000))
		testing.expect_value(t, transmute(u32)f32s[1], u32(0x8000_0000))
		testing.expect_value(t, transmute(u32)f32s[2], u32(0x0000_0000))
		testing.expect_value(t, transmute(u32)f32s[3], u32(0x8000_0000))
		testing.expect_value(t, transmute(u32)f32s[4], u32(0x0080_0000)) // smallest normal f32 (2^-126)
		testing.expect_value(t, transmute(u32)f32s[5], u32(0x007f_ffff)) // largest subnormal f32
		testing.expect_value(t, transmute(u32)f32s[6], u32(0x7f7f_ffff)) // +max(f32)
		testing.expect_value(t, transmute(u32)f32s[7], u32(0xff7f_ffff)) // -max(f32)
	}
	special: []f32
	expect_nil(t, read(`[Infinity,-Infinity,NaN]`, &special, .Json5))
	if testing.expect_value(t, len(special), 3) {
		testing.expect(t, math.is_inf(special[0], 1))
		testing.expect(t, math.is_inf(special[1], -1))
		testing.expect(t, math.is_nan(special[2]))
	}
	// Long keys (> 16 B): same first 8 + last 8 bytes, differing only in middle [8:n-8].
	Long :: struct {
		abcdefgh_MID1_12345678: i64,
		abcdefgh_MID2_12345678: i64,
	}
	lg: Long
	expect_nil(t, read(`{"abcdefgh_MID1_12345678":11,"abcdefgh_XXXX_12345678":99,"abcdefgh_MID2_12345678":22}`, &lg))
	testing.expect_value(t, lg, Long{11, 22})

	// Deep nested maps (> 16 levels) record map keys in cold side array and free cleanly.
	Map_Node :: struct {
		m: map[string]Map_Node,
		v: i64,
	}
	free_mnode :: proc(n: Map_Node, a: runtime.Allocator) {
		for k, val in n.m {
			delete(k, a)
			free_mnode(val, a)
		}
		delete(n.m)
	}
	mb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 20 {
		fmt.sbprintf(&mb, `{{"m":{{"k%d":`, i)
	}
	strings.write_string(&mb, `{"v":"bad"}`)
	for _ in 0 ..< 20 {
		strings.write_string(&mb, `}}`)
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	mpath := make([dynamic]tape.Step, alloc)
	defer delete(mpath)
	mplan, mperr := json.plan_make(Map_Node, allocator = context.temp_allocator)
	expect_nil(t, mperr)
	mroot: Map_Node
	me := json.unmarshal(transmute([]u8)strings.to_string(mb), &mroot, read = {plan = &mplan, path = &mpath}, allocator = alloc)
	expect_refusal(t, me, .Expected_Integer)
	testing.expect_value(t, len(mpath), 41)
	testing.expect_value(t, mpath[0], tape.Step(tape.Name("m")))
	testing.expect_value(t, mpath[1], tape.Step(tape.Name("k0")))
	testing.expect_value(t, mpath[39], tape.Step(tape.Name("k19")))
	testing.expect_value(t, mpath[40], tape.Step(tape.Name("v")))
	free_mnode(mroot, alloc)
	delete(mpath)
	mpath = {}
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// Deep typed unmarshal routes frames and walk levels through `hook.scratch` so the caller's arena holds only target
// allocations, explicit `Options.scratch` receives scratch with no leaks, and `Budget.memory` caps both together.
@(test)
deep_unmarshal_scratch_and_peak_memory :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Chain :: struct {
		v:   i64,
		kid: ^Chain,
	}
	DEPTH :: 2048
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< DEPTH - 1 {
		strings.write_string(&b, `{"v":1,"kid":`)
	}
	strings.write_string(&b, `{"v":1}`)
	for _ in 0 ..< DEPTH - 1 {
		strings.write_byte(&b, '}')
	}
	src := transmute([]u8)strings.to_string(b)
	plan, perr := json.plan_make(Chain, allocator = context.temp_allocator)
	expect_nil(t, perr)
	want_target_bytes := (DEPTH - 1) * size_of(Chain)

	// 1. Default scratch (heap): caller's arena holds only target `^Chain` allocations.
	words := make([]u64, (want_target_bytes + 4096) / size_of(u64), context.temp_allocator)
	buf := ([^]u8)(raw_data(words))[:len(words) * size_of(u64)]
	ar: mem.Arena
	mem.arena_init(&ar, buf)
	root: Chain
	err := json.unmarshal(src, &root, read = {plan = &plan}, opts = {budget = {depth = DEPTH + 16}}, allocator = mem.arena_allocator(&ar))
	expect_nil(t, err)
	testing.expect_value(t, ar.peak_used, want_target_bytes)

	// 2. Explicit `Options.scratch`: receives frames and walk levels, freed cleanly with zero leaks.
	mem.arena_free_all(&ar)
	scratch_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&scratch_track, context.allocator)
	defer mem.tracking_allocator_destroy(&scratch_track)
	root = {}
	err = json.unmarshal(src, &root, read = {plan = &plan}, opts = {budget = {depth = DEPTH + 16}, scratch = mem.tracking_allocator(&scratch_track)}, allocator = mem.arena_allocator(&ar))
	expect_nil(t, err)
	testing.expect_value(t, ar.peak_used, want_target_bytes)
	testing.expect(t, scratch_track.peak_memory_allocated > 0)
	testing.expect_value(t, len(scratch_track.allocation_map), 0)
	testing.expect_value(t, len(scratch_track.bad_free_array), 0)

	// 3. `Budget.memory` counts both target and scratch together and refuses when tight.
	mem.arena_free_all(&ar)
	root = {}
	err = json.unmarshal(src, &root, read = {plan = &plan}, opts = {budget = {depth = DEPTH + 16, memory = u64(want_target_bytes + 1024)}}, allocator = mem.arena_allocator(&ar))
	ex, is_ex := err.(tape.Exceeded)
	testing.expectf(t, is_ex && ex.kind == .Memory, "got %v, want Exceeded(.Memory)", err)
}

// The typed read law over the suites' files and random texts of every grammar, strict and tolerant: a read into a
// `testkit.Value` is what the build converts to, and a text the build refuses is refused alike.
@(test)
unmarshal_agrees_with_the_build :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x7ed)
	read_value :: proc(f: ^tape.Format, src: []u8, v: ^testkit.Value, opts: tape.Options, allocator: runtime.Allocator) -> tape.Error {
		return json.unmarshal(src, v, json.Spec(f.id - 1), opts = opts, allocator = allocator)
	}
	a: testkit.Typed_Agreement
	files := corpus_files()
	defer delete(files)
	for file in files {
		for dups in ([]tape.Duplicates{.Default, .First}) {
			testkit.unmarshal_agrees(t, json.reads(file.spec), json.as(file.spec), read_value, file.data, {dups = dups}, file.name, &a)
		}
	}
	for f in FLAVORS {
		for _ in 0 ..< testkit.rounds(200) {
			src := random_text(f)
			if rand.int_max(5) == 0 {
				corrupt(src)
			}
			testkit.unmarshal_agrees(t, json.reads(f.spec), json.as(f.spec), read_value, src, flavor_options(f), "generated", &a)
			free_all(context.temp_allocator)
		}
	}
	testing.expectf(t, a.read > 500 && a.refused > 500, "%v", a)
}
