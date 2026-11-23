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

// An answer of a path read: the value found, or the outcome, with the node the readers stopped at.
Ref_Answer :: struct {
	node:    tape.Node_Index,
	outcome: tape.Presence,
}

// The answers of `steps` over the whole document `doc` under `dups`, in document order, by its readers and the step
// rules: null and a child a container lacks read as missing past the last `All` and as the wrong kind before it, an
// `All` takes an object's members as written, and a `Name` under `.Group` each member of its key.
reference_answers :: proc(doc: ^tape.Document, steps: []tape.Step, dups: tape.Duplicates, out: ^[dynamic]Ref_Answer) {
	alls_end := u64(0)
	for step, i in steps {
		if _, all := step.(tape.All); all {
			alls_end = u64(i + 1)
		}
	}
	reference_from(doc, tape.ROOT, steps, 0, alls_end, dups, out)
}

@(private = "file")
reference_from :: proc(doc: ^tape.Document, at: tape.Node_Index, steps: []tape.Step, taken, alls_end: u64, dups: tape.Duplicates, out: ^[dynamic]Ref_Answer) {
	if taken == u64(len(steps)) {
		append(out, Ref_Answer{at, .Found})
		return
	}
	r := tape.Reader{doc, nil}
	node := doc.nodes[at]
	step := steps[taken]
	if !tape.step_enters(step, node.kind) {
		append(out, Ref_Answer{at, tape.path_refused(taken, alls_end) if node.kind == .Null else .Wrong_Kind})
		return
	}
	missing := Ref_Answer{at, tape.path_refused(taken + 1, alls_end)}
	end := at + tape.Node_Index(node.n)
	switch s in step {
	case tape.Name:
		if dups == .Group {
			c, p := tape.named(r, at, string(s))
			if p != .Found {
				append(out, missing)
				return
			}
			for {
				_, value, vp := tape.next_child(r, &c)
				if vp != .Found {
					return
				}
				reference_from(doc, value, steps, taken + 1, alls_end, dups, out)
			}
		}
		value, p := tape.member(r, at, string(s), dups)
		if p != .Found {
			append(out, missing)
			return
		}
		reference_from(doc, value, steps, taken + 1, alls_end, dups, out)
	case tape.Index:
		value, p := tape.element(r, at, int(s))
		if p != .Found {
			append(out, missing)
			return
		}
		reference_from(doc, value, steps, taken + 1, alls_end, dups, out)
	case tape.All:
		k := at + 1
		for i := u64(0); k < end; i += 1 {
			value := k
			if node.kind == .Object {
				value = k + 1
			}
			if !tape.all_takes(s.limit, i, node.kind == .Object, dups) {
				return
			}
			reference_from(doc, value, steps, taken + 1, alls_end, dups, out)
			k = value + tape.Node_Index(doc.nodes[value].n) if doc.nodes[value].kind > .Plain else value + 1
		}
	case tape.Slice:
		count, _, _ := tape.length(r, at, context.temp_allocator)
		for e in 0 ..< u64(count) {
			if tape.slice_takes(s, e, u64(count)) {
				value, _ := tape.element(r, at, int(e))
				reference_from(doc, value, steps, taken + 1, alls_end, dups, out)
			}
		}
	}
}

// Whether node `f` of `whole` and node `p` of `part` are the same value of the text.
same_value :: proc(whole: ^tape.Document, f: tape.Node_Index, part: ^tape.Document, p: tape.Node_Index) -> bool {
	if f == tape.NO_NODE || p == tape.NO_NODE {
		return f == p
	}
	x, y := whole.nodes[f], part.nodes[p]
	return x.lo == y.lo && x.kind == y.kind && x.role == y.role && (x.kind > .Plain || x.n == y.n)
}

// Whether the answers of path `path` of the scan `r` are the reference's over the build `doc`, its first `limit` for a
// limit past 0, their outcomes and found values in document order.
answers_agree :: proc(doc, r: ^tape.Document, path: int, steps: []tape.Step, dups: tape.Duplicates, limit: int) -> bool {
	want := make([dynamic]Ref_Answer, context.temp_allocator)
	reference_answers(doc, steps, dups, &want)
	if limit > 0 && len(want) > limit {
		resize(&want, limit)
	}
	for w, k in want {
		node, p, ok := tape.answer({doc = r}, path, k)
		if !ok || p != w.outcome || p == .Found && !same_value(doc, w.node, r, node) {
			return false
		}
	}
	_, _, more := tape.answer({doc = r}, path, len(want))
	return !more
}

// A grammar a generated text follows, and whether its read tolerates what the grammar refuses.
Flavor :: struct {
	spec:     json.Spec,
	tolerant: bool,
}

FLAVORS := [?]Flavor{{.Json, false}, {.Json, true}, {.Jsonc, false}, {.Jsonc, true}, {.Json5, false}, {.Json5, true}}

flavor_options :: proc(f: Flavor) -> json.Options {
	return {tolerate = {.Invalid_Utf8, .Non_Finite, .Lone_Surrogate} if f.tolerant else {}}
}

// A text of the suites a spec reads, which the reads over it must agree on whether it builds.
Corpus_File :: struct {
	name: string,
	data: []u8,
	spec: json.Spec,
}

// The JSONTestSuite files as JSON, and the JSON5 suite's as JSON5 and as JSONC.
corpus_files :: proc() -> [dynamic]Corpus_File {
	files := make([dynamic]Corpus_File)
	for f in #load_directory("conformance/JSONTestSuite/test_parsing") {
		append(&files, Corpus_File{f.name, f.data, .Json})
	}
	json5 := [?][]runtime.Load_Directory_File {
		#load_directory("conformance/json5-tests/arrays"),
		#load_directory("conformance/json5-tests/comments"),
		#load_directory("conformance/json5-tests/misc"),
		#load_directory("conformance/json5-tests/new-lines"),
		#load_directory("conformance/json5-tests/numbers"),
		#load_directory("conformance/json5-tests/objects"),
		#load_directory("conformance/json5-tests/strings"),
	}
	for dir in json5 {
		for f in dir {
			append(&files, Corpus_File{f.name, f.data, .Json5}, Corpus_File{f.name, f.data, .Jsonc})
		}
	}
	return files
}

// Whether two errors of reads of one text are the same: the same fault at the same byte, or the same other error.
same_refusal :: proc(a, b: tape.Error) -> bool {
	x, x_fault := a.(tape.Fault)
	y, y_fault := b.(tape.Fault)
	if x_fault || y_fault {
		return x_fault && y_fault && x.at == y.at && x.kind == y.kind && x.detail == y.detail
	}
	return a == b
}

// Whether every read of `src` that checks the whole text refuses it with the fault `want`, which a build gave.
// Returns false after reporting the first that does not.
reads_refuse :: proc(t: ^testing.T, src: []u8, spec: json.Spec, opts: json.Options, want: tape.Error, name: string, loc := #caller_location) -> bool {
	same := true
	check :: proc(t: ^testing.T, same: ^bool, what: string, got, want: tape.Error, src: []u8, name: string, loc: runtime.Source_Code_Location) {
		same^ &&= testing.expectf(t, same_refusal(got, want), "%s %q: %s refuses with %v, build with %v", name, src, what, got, want, loc = loc)
	}
	check(t, &same, "validate", json.validate(src, spec, opts), want, src, name, loc)
	for dups in ([]tape.Duplicates{.Last, .First}) {
		_, ferr := json.find(src, {tape.Name("a"), tape.Index(-1)}, spec, {dups = dups}, opts)
		check(t, &same, "find", ferr, want, src, name, loc)
	}
	_, ferr := json.find(src, {}, spec, {}, opts)
	check(t, &same, "find of the root", ferr, want, src, name, loc)
	d, _ := tape.demand_of({{tape.All{}}, {tape.Name("a")}})
	defer tape.destroy(&d)
	r, serr := json.scan(src, &d, spec, {}, opts)
	tape.destroy(&r)
	check(t, &same, "scan", serr, want, src, name, loc)
	return same
}

// Over random texts of every grammar, strict and tolerant, and the suites' files, a find's answer is the first of the
// paths' reference answers over the build, and a text the build refuses is refused alike by every read.
@(test)
find_agrees_with_the_build :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x5eed)
	finds, found, refused := 0, 0, 0
	agree :: proc(t: ^testing.T, src: []u8, f: Flavor, paths: int, name: string, finds, found, refused: ^int) {
		defer free_all(context.temp_allocator)
		opts := flavor_options(f)
		doc, err := json.build(src, f.spec, opts)
		defer tape.destroy(&doc)
		if err != nil {
			refused^ += 1
			reads_refuse(t, src, f.spec, opts, err, name)
			return
		}
		names := key_names_of(&doc)
		want := make([dynamic]Ref_Answer, context.temp_allocator)
		for _ in 0 ..< paths {
			steps := random_path(names)
			for dups in ([]tape.Duplicates{.Last, .First, .Group}) {
				clear(&want)
				reference_answers(&doc, steps, dups, &want)
				for stop in ([]bool{false, true}) {
					a, ferr := json.find(src, steps, f.spec, {dups = dups, stop_early = stop}, opts)
					finds^ += 1
					ok := ferr == nil
					if len(want) == 0 {
						ok &&= a.outcome == .Missing
					} else if first := want[0]; first.outcome == .Found {
						found^ += 1
						node := doc.nodes[first.node]
						got := tape.answer_node(a)
						ok &&= a.outcome == .Found && got.lo == node.lo && got.kind == node.kind && (node.kind > .Plain || got.n == node.n && got.spelling == node.spelling)
					} else {
						ok &&= a.outcome == first.outcome
					}
					testing.expectf(t, ok, "%s %v %q %v stop %v: %v, reference %v", name, f, src, steps, stop, a, want[:])
				}
			}
		}
	}
	for f in FLAVORS {
		for _ in 0 ..< testkit.rounds(200) {
			src := random_text(f)
			if rand.int_max(5) == 0 {
				corrupt(src)
			}
			agree(t, src, f, 25, "generated", &finds, &found, &refused)
		}
	}
	files := corpus_files()
	defer delete(files)
	for file in files {
		agree(t, file.data, {file.spec, false}, 6, file.name, &finds, &found, &refused)
		agree(t, file.data, {file.spec, true}, 6, file.name, &finds, &found, &refused)
	}
	log.infof("find agreement: %d finds, %d found, %d texts refused", finds, found, refused)
	testing.expectf(t, finds > 20000 && found > finds / 10 && refused > 50, "%d finds, %d found, %d refused", finds, found, refused)
}

// Replaces one byte of `src` or cuts it short, so that the text is often not one any grammar reads.
@(private = "file")
corrupt :: proc(src: []u8) {
	if len(src) == 0 {
		return
	}
	bytes := [?]u8{'}', ']', ',', '"', 'x', ':', '/', 0xff}
	src[rand.int_max(len(src))] = bytes[rand.int_max(len(bytes))]
}

// The distinct keys of `doc`, the first dozen, and two a text lacks.
@(private = "file")
key_names_of :: proc(doc: ^tape.Document) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	append(&names, "zz", "")
	for node, i in doc.nodes {
		if node.role != .Key || len(names) == 14 {
			continue
		}
		buf := make([]u8, node.n * 3, context.temp_allocator)
		text, _ := tape.node_text(doc, tape.Node_Index(i), buf)
		if !slice.contains(names[:], text) {
			append(&names, strings.clone(text, context.temp_allocator))
		}
	}
	return names[:]
}

// A white space, a comment where the grammar allows one, or nothing.
@(private = "file")
random_gap :: proc(b: ^strings.Builder, f: Flavor) {
	switch rand.int_max(8 if f.spec != .Json else 3) {
	case 0:
		strings.write_byte(b, ' ')
	case 1:
		strings.write_byte(b, '\n')
	case 2:
	case 3, 4:
		strings.write_string(b, `/* c * ] } " ' */`)
	case:
		strings.write_string(b, "// c ] } \" '\n")
	}
}

@(private = "file")
random_string :: proc(b: ^strings.Builder, f: Flavor) {
	quote := u8('\'') if f.spec == .Json5 && rand.int_max(3) == 0 else '"'
	strings.write_byte(b, quote)
	switch rand.int_max(6 if f.tolerant else 4) {
	case 0:
		strings.write_string(b, "s")
	case 1:
		strings.write_string(b, "ab\\n\\u00e9")
	case 2:
		strings.write_string(b, "a longer string of text that passes thirty-two bytes, and past sixty-four of them too")
	case 3:
		strings.write_string(b, "é€\U0001f600")
	case 4:
		strings.write_string(b, "a\xffb\xe2\x82")
	case:
		strings.write_string(b, "\\ud800 \\udc00x")
	}
	strings.write_byte(b, quote)
}

@(private = "file")
random_number :: proc(b: ^strings.Builder, f: Flavor) {
	switch rand.int_max(8 if f.spec == .Json5 || f.tolerant else 4) {
	case 0, 1:
		fmt.sbprint(b, rand.int_max(100))
	case 2:
		fmt.sbprint(b, "-1.5e3")
	case 3:
		fmt.sbprint(b, rand.int_max(100000), rand.int_max(100), sep = ".")
	case 4:
		strings.write_string(b, "NaN")
	case 5:
		strings.write_string(b, "-Infinity")
	case 6:
		strings.write_string(b, "+.5" if f.spec == .Json5 else "Infinity")
	case:
		strings.write_string(b, "0x1F" if f.spec == .Json5 else "NaN")
	}
}

// A random text of the grammar `f` in the temporary allocator.
random_text :: proc(f: Flavor) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	random_value(&b, 0, f)
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
random_value :: proc(b: ^strings.Builder, depth: int, f: Flavor) {
	keys := [?]string{"a", "b", "c", "long_key_x", "a_key_of_more_than_sixteen_bytes", "é", "seven77", "exactly8", "sixteen_bytes_16"}
	r := rand.int_max(10 if depth < 5 else 5)
	switch r {
	case 0:
		strings.write_string(b, "null")
	case 1:
		random_number(b, f)
	case 2:
		random_string(b, f)
	case 3:
		strings.write_string(b, "true" if rand.int_max(2) == 0 else "false")
	case 4:
		strings.write_string(b, `"ab"`)
	case 5, 6:
		strings.write_byte(b, '[')
		count := rand.int_max(5 if rand.int_max(8) != 0 else 40)
		for i in 0 ..< count {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			random_gap(b, f)
			random_value(b, depth + 1, f)
			random_gap(b, f)
		}
		if f.spec != .Json && count > 0 && rand.int_max(4) == 0 {
			strings.write_byte(b, ',')
		}
		strings.write_byte(b, ']')
	case:
		strings.write_byte(b, '{')
		count := rand.int_max(5 if rand.int_max(8) != 0 else 20)
		for i in 0 ..< count {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			random_gap(b, f)
			key := keys[rand.int_max(len(keys))]
			// An escaped key reads as its plain spelling.
			switch {
			case key == "b" && rand.int_max(3) == 0:
				key = `b`
			case key == "é" && rand.int_max(3) == 0:
				key = `é`
			}
			if f.spec == .Json5 && rand.int_max(3) == 0 && !strings.contains(key, "\\") && key != "é" {
				strings.write_string(b, key)
			} else {
				fmt.sbprintf(b, `"%s"`, key)
			}
			random_gap(b, f)
			strings.write_byte(b, ':')
			random_gap(b, f)
			random_value(b, depth + 1, f)
			random_gap(b, f)
		}
		if f.spec != .Json && count > 0 && rand.int_max(4) == 0 {
			strings.write_byte(b, ',')
		}
		strings.write_byte(b, '}')
	}
}

@(private = "file")
random_path :: proc(names: []string) -> []tape.Step {
	steps := make([]tape.Step, rand.int_max(6), context.temp_allocator)
	for &s in steps {
		switch rand.int_max(8) {
		case 0, 1:
			s = tape.Name(names[rand.int_max(len(names))])
		case 2:
			s = tape.Index(rand.int_max(7) - 3)
		case 3:
			s = tape.All{}
		case 4:
			s = tape.All{i32(rand.int_max(3))}
		case 5:
			s = tape.Slice{i32(rand.int_max(5) - 2), nil, 0}
		case 6:
			s = tape.Slice{i32(rand.int_max(3)), i32(rand.int_max(5) - 2), i32(rand.int_max(2))}
		case:
			s = tape.Slice{i32(rand.int_max(5) - 4), i32(rand.int_max(5) - 3), 0}
		}
	}
	return steps
}

// Checks the facts a scan kept with its nodes against the build's: each kept fact is the build's fact of the same
// value, and each fact the build gives a value the scan kept is kept, but a foot of a container the scan kept unread,
// whose insides it passed. A stopped scan read no fact past its stop.
agree_facts :: proc(t: ^testing.T, doc, r: ^tape.Document, name: string, loc := #caller_location) {
	Key :: struct {
		lo:   u64,
		role: tape.Role,
	}
	whole := make(map[Key]tape.Node_Index, context.temp_allocator)
	for node, i in doc.nodes {
		whole[{node.lo, node.role}] = tape.Node_Index(i)
	}
	has :: proc(facts: []tape.Fact, node: tape.Node_Index, f: tape.Fact) -> bool {
		for g in facts {
			if g.node == node && g.lo == f.lo && g.kind == f.kind {
				return true
			}
		}
		return false
	}
	for f in r.facts {
		node := r.nodes[f.node]
		at, ok := whole[{node.lo, node.role}]
		testing.expectf(t, ok && has(doc.facts, at, f), "%s: scan fact %v on %v is not the build's", name, f, node, loc = loc)
	}
	if .Stopped in r.flags {
		return
	}
	kept := make(map[tape.Node_Index]tape.Node_Index, context.temp_allocator)
	for node, i in r.nodes {
		if at, ok := whole[{node.lo, node.role}]; ok {
			kept[at] = tape.Node_Index(i)
		}
	}
	for f in doc.facts {
		at, ok := kept[f.node]
		if !ok {
			continue
		}
		node := r.nodes[at]
		unread := node.kind >= .Array && node.n == 1 && node.spelling & tape.CONTAINER_PARTIAL != 0
		if f.kind == .Comment_Foot && unread {
			continue
		}
		testing.expectf(t, has(r.facts, at, f), "%s: build fact %v of kept %v is not the scan's", name, f, node, loc = loc)
	}
}
