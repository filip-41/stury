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
			testkit.reads_refuse(t, json.reads(f.spec), json.as(f.spec), src, opts, err, name)
			return
		}
		names := key_names_of(&doc)
		want := make([dynamic]testkit.Ref_Answer, context.temp_allocator)
		for _ in 0 ..< paths {
			steps := random_path(names)
			for dups in ([]tape.Duplicates{.Last, .First, .Group}) {
				clear(&want)
				testkit.reference_answers(&doc, steps, dups, &want)
				for stop in ([]bool{false, true}) {
					find_opts := opts
					find_opts.dups = dups
					a, ferr := json.find(src, steps, f.spec, {stop_early = stop}, find_opts)
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
