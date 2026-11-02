// Scan, stopped scan and query against a model that reads a built document through `member` and `child_at`, on texts
// with repeated keys, on the JSON test suites and, with `PATH_FIXTURES` set, on a directory's JSON files.
package json_tests

import "base:runtime"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:testing"
import core "../../core"
import json ".."
import walktest "../../walktest"

PATH_ROUNDS :: #config(PATH_ROUNDS, 4000)
PATH_FIXTURES :: #config(PATH_FIXTURES, "")

// One answer as the model reads it: an outcome, the span of the value or of its owner, and its child count.
@(private = "file")
Read :: struct {
	outcome: core.Answer_Outcome,
	bytes:   []u8,
	count:   int,
}

@(private = "file")
Model :: struct {
	doc:   ^core.Document,
	steps: []core.Step,
	dups:  core.Duplicates,
	reads: [dynamic]Read,
}

// Each key and how it is spelled. Two spellings of `a` and a long pair sharing a prefix test the compare.
@(private = "file", rodata)
KEYS := [][2]string {
	{"a", `"a"`},
	{"a", `"a"`},
	{"b", `"b"`},
	{"ab", `"ab"`},
	{"aaaaaaaaaaaaaaaaaaaaaaaab", `"aaaaaaaaaaaaaaaaaaaaaaaab"`},
	{"aaaaaaaaaaaaaaaaaaaaaaaac", `"aaaaaaaaaaaaaaaaaaaaaaaac"`},
}

@(private = "file")
gap :: proc(b: ^strings.Builder, comments: bool) {
	switch rand.int_max(6) {
	case 0:
		strings.write_byte(b, ' ')
	case 1:
		if comments {
			strings.write_string(b, "/*c*/")
		}
	}
}

@(private = "file")
write_value :: proc(b: ^strings.Builder, depth: int, comments: bool) {
	switch rand.int_max(6 if depth > 0 else 4) {
	case 0:
		strings.write_string(b, "null")
	case 1:
		strings.write_string(b, "true")
	case 2:
		strings.write_string(b, "12")
	case 3:
		strings.write_string(b, `"s"`)
	case 4:
		strings.write_byte(b, '[')
		for i in 0 ..< rand.int_max(4) {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			gap(b, comments)
			write_value(b, depth - 1, comments)
			gap(b, comments)
		}
		strings.write_byte(b, ']')
	case 5:
		strings.write_byte(b, '{')
		for i in 0 ..< rand.int_max(5) {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			gap(b, comments)
			strings.write_string(b, rand.choice(KEYS)[1])
			gap(b, comments)
			strings.write_byte(b, ':')
			gap(b, comments)
			write_value(b, depth - 1, comments)
			gap(b, comments)
		}
		strings.write_byte(b, '}')
	}
}

// Steps of any kind, which on a text with few keys reach values and miss them alike.
@(private = "file")
random_steps :: proc() -> []core.Step {
	steps := make([]core.Step, rand.int_max(5), context.temp_allocator)
	for &s in steps {
		switch rand.int_max(8) {
		case 0, 1:
			s = core.All{}
		case 2, 3:
			s = core.Index(rand.int_max(4))
		case 4:
			s = core.Name("zz")
		case:
			s = core.Name(rand.choice(KEYS)[0])
		}
	}
	return steps
}

// Steps that follow a random descent of `doc`, so a large text is answered below its root, with a miss now and then.
@(private = "file")
sampled_steps :: proc(doc: ^core.Document) -> []core.Step {
	steps := make([dynamic]core.Step, context.temp_allocator)
	at := core.ROOT
	for len(steps) < 6 {
		n := core.length(doc, at)
		if n == 0 || rand.int_max(6) == 0 {
			break
		}
		k := rand.int_max(n)
		#partial switch core.kind(doc, at) {
		case .Array:
			at, _ = core.child_at(doc, at, k)
			append(&steps, core.Step(core.Index(k)))
		case .Map:
			it := core.pairs(doc, at)
			key, value: core.Node_Index
			for _ in 0 ..= k {
				key, value, _ = core.pair_next(&it)
			}
			name, _ := core.text_clone(doc, key, context.temp_allocator)
			append(&steps, core.Step(core.Name(name)))
			at = value
		}
		if rand.int_max(5) == 0 {
			steps[len(steps) - 1] = core.All{}
		}
	}
	if len(steps) > 0 && rand.int_max(4) == 0 {
		steps[rand.int_max(len(steps))] = core.Name("zz") if rand.int_max(2) == 0 else core.Index(1 << 30)
	}
	return steps[:]
}

@(private = "file")
any_all :: proc(steps: []core.Step) -> bool {
	for s in steps {
		if _, all := s.(core.All); all {
			return true
		}
	}
	return false
}

@(private = "file")
say :: proc(m: ^Model, outcome: core.Answer_Outcome, i: core.Node_Index) {
	append(&m.reads, Read{outcome, core.span(m.doc, i), core.length(m.doc, i)})
}

@(private = "file")
miss :: proc(m: ^Model, i: core.Node_Index, k: int) {
	say(m, .Type_Mismatch if any_all(m.steps[k + 1:]) else .Missing, i)
}

// `parent` holds `i`, and is `i` at the root.
@(private = "file")
eval :: proc(m: ^Model, i, parent: core.Node_Index, k: int) {
	if k == len(m.steps) {
		say(m, .Found, i)
		return
	}
	kind := core.kind(m.doc, i)
	switch s in m.steps[k] {
	case core.All:
		if kind == .Array {
			it := core.children(m.doc, i)
			for c in core.child_next(&it) {
				eval(m, c, i, k + 1)
			}
			return
		}
		if kind == .Map {
			it := core.pairs(m.doc, i)
			for _, value in core.pair_next(&it) {
				eval(m, value, i, k + 1)
			}
			return
		}
	case core.Index:
		if kind == .Array {
			if c, ok := core.child_at(m.doc, i, int(s)); ok {
				eval(m, c, i, k + 1)
			} else {
				miss(m, i, k)
			}
			return
		}
	case core.Name:
		if kind == .Map {
			if c, ok := core.member(m.doc, i, string(s), m.dups); ok {
				eval(m, c, i, k + 1)
			} else {
				miss(m, i, k)
			}
			return
		}
	case core.Slice, core.Descend, core.Either:
	}
	if kind == .Null && !any_all(m.steps[k:]) {
		say(m, .Missing, parent)
	} else {
		say(m, .Type_Mismatch, i)
	}
}

@(private = "file")
same_bytes :: proc(a, b: []u8) -> bool {
	return raw_data(a) == raw_data(b) && len(a) == len(b)
}

@(private = "file")
same_reads :: proc(t: ^testing.T, doc: ^core.Document, answers: []core.Answer, want: []Read, label: string, steps: []core.Step) -> bool {
	ok := len(answers) == len(want)
	for a, i in answers {
		if !ok {
			break
		}
		node := a.node if a.outcome == .Found else a.owner
		ok = a.outcome == want[i].outcome && same_bytes(core.span(doc, node), want[i].bytes) && core.length(doc, node) == want[i].count
	}
	return testing.expectf(t, ok, "%s %v on %q: %v, want %v", label, steps, doc.src[:min(len(doc.src), 400)], answers, len(want))
}

// A stopped read may not reach an owner's end, so only outcomes and found values are compared.
@(private = "file")
same_stopped :: proc(t: ^testing.T, doc: ^core.Document, answers: []core.Answer, want: []Read, steps: []core.Step) -> bool {
	ok := len(answers) == len(want)
	for a, i in answers {
		if !ok {
			break
		}
		ok = a.outcome == want[i].outcome && (a.outcome != .Found || same_bytes(core.span(doc, a.node), want[i].bytes))
	}
	return testing.expectf(t, ok, "stopped %v on %q: %v, want %v", steps, doc.src[:min(len(doc.src), 400)], answers, len(want))
}

// Every way of reading `path` from `src`, under each repeated-key rule, against the model over `full`.
@(private = "file")
check_path :: proc(t: ^testing.T, src: []u8, $S: json.Spec, full: ^core.Document, steps: []core.Step, limit: Maybe(int)) -> bool {
	path := core.Path{steps = steps, limit = limit}
	for dups in core.Duplicates {
		if dups != .First && dups != .Last {
			continue
		}
		m := Model{doc = full, steps = steps, dups = dups}
		m.reads = make([dynamic]Read, context.temp_allocator)
		eval(&m, core.ROOT, core.ROOT, 0)
		want := m.reads[:]
		if n, limited := limit.?; limited {
			want = want[:min(n, len(want))]
		}
		scanned, err := json.query(src, S, path, read = {dups = dups})
		defer core.destroy(&scanned)
		testing.expectf(t, err.kind == .None, "%v: %v", steps, err) or_return
		same_reads(t, &scanned, scanned.answers, want, "scan", steps) or_return

		stopped, serr := json.query(src, S, path, read = {dups = dups, stop_early = true})
		defer core.destroy(&stopped)
		testing.expectf(t, serr.kind == .None, "%v: %v", steps, serr) or_return
		same_stopped(t, &stopped, stopped.answers, want, steps) or_return

		answers, qerr := json.query_document(full, path, {dups = dups})
		defer delete(answers)
		testing.expectf(t, qerr.kind == .None, "%v: %v", steps, qerr) or_return
		same_reads(t, full, answers, want, "query", steps) or_return
	}
	return true
}

// Reads paths sampled from `src`, or nothing where `S` refuses it.
@(private = "file")
check_text :: proc(t: ^testing.T, src: []u8, $S: json.Spec, paths: int) -> bool {
	full, err := json.build(src, S)
	defer core.destroy(&full)
	if err.kind != .None {
		return true
	}
	for _ in 0 ..< paths {
		check_path(t, src, S, &full, sampled_steps(&full), nil) or_return
		free_all(context.temp_allocator)
	}
	return true
}

@(private = "file")
check_round :: proc(t: ^testing.T, src: []u8, $S: json.Spec, limit: Maybe(int)) -> bool {
	full, _ := json.build(src, S)
	defer core.destroy(&full)
	return check_path(t, src, S, &full, random_steps(), limit)
}

@(test)
path_model :: proc(t: ^testing.T) {
	for i in 0 ..< PATH_ROUNDS {
		defer free_all(context.temp_allocator)
		comments := i & 1 == 1
		b := strings.builder_make(context.temp_allocator)
		write_value(&b, 4, comments)
		src := transmute([]u8)strings.to_string(b)
		limit := Maybe(int)(rand.int_max(3)) if rand.int_max(4) == 0 else nil
		if !(check_round(t, src, .Jsonc, limit) if comments else check_round(t, src, .Json, limit)) {
			return
		}
	}
}

@(test)
path_model_suites :: proc(t: ^testing.T) {
	files := make([dynamic]runtime.Load_Directory_File, 0, 512)
	defer delete(files)
	append(&files, ..#load_directory("conformance/JSONTestSuite/test_parsing"))
	for dir in walktest.JSON5_TESTS {
		append(&files, ..dir[:])
	}
	for file in files {
		src := file.data
		ok := check_text(t, src, .Json, 8) && check_text(t, src, .Jsonc, 8) && check_text(t, src, .Json5, 8)
		if !testing.expectf(t, ok, "%s", file.name) {
			return
		}
	}
}

@(test)
path_model_fixtures :: proc(t: ^testing.T) {
	if PATH_FIXTURES == "" {
		return
	}
	entries, err := os.read_all_directory_by_path(PATH_FIXTURES, context.allocator)
	testing.expect_value(t, err, nil)
	defer os.file_info_slice_delete(entries, context.allocator)
	for entry in entries {
		if !strings.has_suffix(entry.name, ".json") {
			continue
		}
		src, rerr := os.read_entire_file_from_path(entry.fullpath, context.allocator)
		testing.expect_value(t, rerr, nil)
		defer delete(src)
		check_text(t, src, .Json, 12)
		free_all(context.temp_allocator)
	}
}
