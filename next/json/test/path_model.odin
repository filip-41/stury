// Scan, stopped scan and query against a model that reads a built document through `member` and `child_at`, on texts
// with repeated keys, on the JSON test suites and, with `PATH_FIXTURES` set, on a directory's JSON files.
package json_tests

import "base:runtime"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import json ".."
import walktest "../../walktest"

PATH_ROUNDS :: #config(PATH_ROUNDS, 4000)
PATH_FIXTURES :: #config(PATH_FIXTURES, "")

// One answer as the model reads it: an outcome, the span of the value or of its owner, its child count, its place in the
// text and its path.
@(private = "file")
Read :: struct {
	outcome: core.Answer_Outcome,
	bytes:   []u8,
	count:   int,
	kind:    core.Kind,
	pos:     u64,
	path:    u32,
}

@(private = "file")
Model :: struct {
	doc:      ^core.Document,
	steps:    []core.Step,
	optional: bit_set[0 ..< core.MAX_STEPS; u64],
	dups:     core.Duplicates,
	every:    bool,
	path:     u32,
	reads:    [dynamic]Read,
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

@(private = "file")
random_step :: proc() -> core.Step {
	switch rand.int_max(12) {
	case 0, 1:
		return core.All{}
	case 2, 3:
		return core.Index(rand.int_max(4))
	case 4:
		return core.Index(-1 - rand.int_max(4))
	case 5, 6:
		lo := rand.int_max(7) - 3
		if rand.int_max(3) == 0 {
			return core.Slice{lo = lo}
		}
		return core.Slice{lo, rand.int_max(7) - 3}
	case 7:
		return core.Name("zz")
	}
	return core.Name(rand.choice(KEYS)[0])
}

// Steps of any kind, which on a text with few keys reach values and miss them alike.
@(private = "file")
random_steps :: proc() -> []core.Step {
	steps := make([]core.Step, rand.int_max(5), context.temp_allocator)
	for &s in steps {
		s = random_step()
	}
	if len(steps) > 0 && rand.int_max(5) == 0 {
		steps[rand.int_max(len(steps))] = core.Descend{}
	}
	return steps
}

// A path of `steps` with a `?` now and then, and a limit now and then.
@(private = "file")
random_path :: proc(steps: []core.Step) -> core.Path {
	path := core.Path{steps = steps}
	if len(steps) > 0 && rand.int_max(4) == 0 {
		path.optional += {rand.int_max(len(steps))}
	}
	if rand.int_max(4) == 0 {
		path.limit = rand.int_max(3)
	}
	return path
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
first_all :: proc(steps: []core.Step) -> (int, bool) {
	for s, i in steps {
		if _, all := s.(core.All); all {
			return i, true
		}
	}
	return 0, false
}

@(private = "file")
offset :: proc(m: ^Model, bytes: []u8) -> u64 {
	return u64(uintptr(raw_data(bytes)) - uintptr(raw_data(m.doc.src)))
}

@(private = "file")
say :: proc(m: ^Model, outcome: core.Answer_Outcome, i: core.Node_Index, pos: u64) {
	append(&m.reads, Read{outcome, core.span(m.doc, i), core.length(m.doc, i), core.kind(m.doc, i), pos, m.path})
}

@(private = "file")
value_pos :: proc(m: ^Model, i: core.Node_Index) -> u64 {
	return 2 * offset(m, core.span(m.doc, i))
}

// A member or an element `i` does not hold. The close knows.
@(private = "file")
miss :: proc(m: ^Model, i: core.Node_Index, k: int) {
	bytes := core.span(m.doc, i)
	pos := 2 * (offset(m, bytes) + u64(len(bytes)) - 1) + 1
	if at, later := first_all(m.steps[k + 1:]); later {
		if k + 1 + at not_in m.optional {
			say(m, .Type_Mismatch, i, pos)
		}
	} else {
		say(m, .Missing, i, pos)
	}
}

// `parent` holds `i`, and is `i` at the root.
@(private = "file")
eval :: proc(m: ^Model, i, parent: core.Node_Index, k: int) {
	if k == len(m.steps) {
		say(m, .Found, i, value_pos(m, i))
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
			at := int(s) if s >= 0 else core.length(m.doc, i) + int(s)
			if c, ok := core.child_at(m.doc, i, at); ok && at >= 0 {
				eval(m, c, i, k + 1)
			} else {
				miss(m, i, k)
			}
			return
		}
	case core.Slice:
		if kind == .Array {
			n := core.length(m.doc, i)
			lo := s.lo if s.lo >= 0 else max(n + s.lo, 0)
			hi := s.hi.? or_else n
			hi = hi if hi >= 0 else n + hi
			for at in lo ..< min(hi, n) {
				c, _ := core.child_at(m.doc, i, at)
				eval(m, c, i, k + 1)
			}
			return
		}
	case core.Name:
		if kind == .Map {
			if m.every {
				any := false
				it := core.pairs(m.doc, i)
				for key, value in core.pair_next(&it) {
					if text, _ := core.text_clone(m.doc, key, context.temp_allocator); text == string(s) {
						any = true
						eval(m, value, i, k + 1)
					}
				}
				if !any {
					miss(m, i, k)
				}
			} else if c, ok := core.member(m.doc, i, string(s), m.dups); ok {
				eval(m, c, i, k + 1)
			} else {
				miss(m, i, k)
			}
			return
		}
	case core.Descend:
		eval(m, i, parent, k + 1)
		if kind == .Array {
			it := core.children(m.doc, i)
			for c in core.child_next(&it) {
				eval(m, c, i, k)
			}
		} else if kind == .Map {
			it := core.pairs(m.doc, i)
			for _, value in core.pair_next(&it) {
				eval(m, value, i, k)
			}
		}
		return
	case core.Either:
	}
	at, later := first_all(m.steps[k:])
	failed := k + at if kind == .Null else k
	if kind == .Null && !later {
		say(m, .Missing, parent, value_pos(m, i))
	} else if failed not_in m.optional {
		say(m, .Type_Mismatch, i, value_pos(m, i))
	}
}

@(private = "file")
read_less :: proc(a, b: Read) -> bool {
	if a.pos != b.pos {
		return a.pos < b.pos
	}
	if a.path != b.path {
		return a.path < b.path
	}
	return a.outcome < b.outcome
}

// The model's answers of `paths`, in the order a read gives them.
@(private = "file")
model_reads :: proc(full: ^core.Document, paths: []core.Path, dups: core.Duplicates, every: bool) -> []Read {
	all := make([dynamic]Read, context.temp_allocator)
	for path, p in paths {
		m := Model{doc = full, steps = path.steps, optional = path.optional, dups = dups, every = every, path = u32(p)}
		m.reads = make([dynamic]Read, context.temp_allocator)
		eval(&m, core.ROOT, core.ROOT, 0)
		slice.sort_by(m.reads[:], read_less)
		want := m.reads[:]
		if n, limited := path.limit.?; limited {
			want = want[:min(n, len(want))]
		}
		append(&all, ..want)
	}
	slice.sort_by(all[:], read_less)
	return all[:]
}

@(private = "file")
same_bytes :: proc(a, b: []u8) -> bool {
	return raw_data(a) == raw_data(b) && len(a) == len(b)
}

@(private = "file")
same_reads :: proc(t: ^testing.T, doc: ^core.Document, answers: []core.Answer, want: []Read, label: string, steps: []core.Path) -> bool {
	ok := len(answers) == len(want)
	for a, i in answers {
		if !ok {
			break
		}
		node := a.node if a.outcome == .Found else a.owner
		ok = a.outcome == want[i].outcome && a.path == want[i].path && same_bytes(core.span(doc, node), want[i].bytes) && core.length(doc, node) == want[i].count
	}
	return testing.expectf(t, ok, "%s %v on %q: %v, want %v", label, steps, doc.src[:min(len(doc.src), 400)], answers, len(want))
}

// A stopped read may not reach an owner's end, so only outcomes and found values are compared.
@(private = "file")
same_stopped :: proc(t: ^testing.T, doc: ^core.Document, answers: []core.Answer, want: []Read, steps: []core.Path) -> bool {
	ok := len(answers) == len(want)
	for a, i in answers {
		if !ok {
			break
		}
		ok = a.outcome == want[i].outcome && a.path == want[i].path && (a.outcome != .Found || same_bytes(core.span(doc, a.node), want[i].bytes))
	}
	return testing.expectf(t, ok, "stopped %v on %q: %v, want %v", steps, doc.src[:min(len(doc.src), 400)], answers, len(want))
}

// What `each_answer` gave, tallied for the comparison with the model, which is by path and not by order.
@(private = "file")
Given :: struct {
	path:    u32,
	outcome: core.Answer_Outcome,
	hi:      u64,
}

@(private = "file")
given_less :: proc(a, b: Given) -> bool {
	if a.path != b.path {
		return a.path < b.path
	}
	if a.outcome != b.outcome {
		return a.outcome < b.outcome
	}
	return a.hi < b.hi
}

@(private = "file")
Stream :: struct {
	given: [dynamic]Given,
}

// A string's token is its inside, so only other kinds' ends are compared.
@(private = "file")
on_answer :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	s := (^Stream)(state)
	append(&s.given, Given{a.path, a.outcome, a.hi if a.outcome == .Found && a.token.kind != .String else 0})
	return true
}

@(private = "file")
same_stream :: proc(t: ^testing.T, src: []u8, $S: json.Spec, paths: []core.Path, want: []Read, read: core.Path_Options) -> bool {
	stream := Stream{make([dynamic]Given, context.temp_allocator)}
	err := json.each_answer(src, S, paths, &stream, on_answer, read = read)
	testing.expectf(t, err.kind == .None, "stream %v: %v", paths, err) or_return
	wanted := make([]Given, len(want), context.temp_allocator)
	for r, i in want {
		hi: u64
		if r.outcome == .Found && r.kind != .String {
			hi = u64(uintptr(raw_data(r.bytes)) - uintptr(raw_data(src))) + u64(len(r.bytes))
		}
		wanted[i] = {r.path, r.outcome, hi}
	}
	slice.sort_by(stream.given[:], given_less)
	slice.sort_by(wanted, given_less)
	return testing.expectf(t, slice.equal(stream.given[:], wanted), "stream %v on %q: %v, want %v", paths, src[:min(len(src), 400)], stream.given, wanted)
}

// Every way of reading `paths` from `src`, under each repeated-key rule, against the model over `full`.
@(private = "file")
check_paths :: proc(t: ^testing.T, src: []u8, $S: json.Spec, full: ^core.Document, paths: []core.Path) -> bool {
	for dups in core.Duplicates {
		if dups != .First && dups != .Last {
			continue
		}
		for every in ([]bool{false, true}) {
			if every && dups == .First {
				continue
			}
			want := model_reads(full, paths, dups, every)
			scanned, err := json.query(src, S, paths, read = {dups = dups, every_key = every})
			defer core.destroy(&scanned)
			testing.expectf(t, err.kind == .None, "%v: %v", paths, err) or_return
			same_reads(t, &scanned, scanned.answers, want, "scan", paths) or_return

			stopped, serr := json.query(src, S, paths, read = {dups = dups, stop_early = true, every_key = every})
			defer core.destroy(&stopped)
			testing.expectf(t, serr.kind == .None, "%v: %v", paths, serr) or_return
			same_stopped(t, &stopped, stopped.answers, want, paths) or_return

			answers, qerr := json.query_document(full, paths, {dups = dups, every_key = every})
			defer delete(answers)
			testing.expectf(t, qerr.kind == .None, "%v: %v", paths, qerr) or_return
			same_reads(t, full, answers, want, "query", paths) or_return

			same_stream(t, src, S, paths, want, {dups = dups, every_key = every}) or_return
		}
	}
	return true
}

@(private = "file")
check_path :: proc(t: ^testing.T, src: []u8, $S: json.Spec, full: ^core.Document, path: core.Path) -> bool {
	paths := [1]core.Path{path}
	return check_paths(t, src, S, full, paths[:])
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
		check_path(t, src, S, &full, core.Path{steps = sampled_steps(&full)}) or_return
		few := [3]core.Path{{steps = sampled_steps(&full)}, random_path(random_steps()), {steps = sampled_steps(&full)}}
		check_paths(t, src, S, &full, few[:]) or_return
		free_all(context.temp_allocator)
	}
	return true
}

@(private = "file")
check_round :: proc(t: ^testing.T, src: []u8, $S: json.Spec) -> bool {
	full, _ := json.build(src, S)
	defer core.destroy(&full)
	paths := make([]core.Path, 1 + rand.int_max(3), context.temp_allocator)
	for &p in paths {
		p = random_path(random_steps())
	}
	return check_paths(t, src, S, &full, paths) && check_commit(t, src, S, &full, paths[0], rand.int_max(2) == 0)
}

// The answers' nodes as edits, on a partial document and on the built one, commit to the same text or the same refusal.
check_commit :: proc(t: ^testing.T, src: []u8, $S: json.Spec, full: ^core.Document, path: core.Path, removing: bool) -> bool {
	record :: proc(doc: ^core.Document, answers: []core.Answer, removing: bool) -> (out: []u8, err: core.Document_Error) {
		list := core.edit_list_init(doc, context.temp_allocator)
		for a in answers {
			if a.outcome != .Found {
				continue
			}
			e := core.remove(&list, a.node) if removing else core.set(&list, a.node, "0")
			if e.kind != .None {
				return nil, e
			}
		}
		out, _, err = core.commit(&list, context.temp_allocator)
		return
	}
	scanned, err := json.query(src, S, path)
	defer core.destroy(&scanned)
	testing.expectf(t, err.kind == .None, "%v: %v", path, err) or_return
	answers, qerr := json.query_document(full, path)
	defer delete(answers)
	testing.expectf(t, qerr.kind == .None, "%v: %v", path, qerr) or_return
	got, gerr := record(&scanned, scanned.answers, removing)
	want, werr := record(full, answers, removing)
	testing.expectf(t, gerr.kind == werr.kind, "%q %v: %v want %v", string(src), path, gerr, werr) or_return
	return testing.expectf(t, string(got) == string(want), "%q %v: %q want %q", string(src), path, string(got), string(want))
}

@(test)
path_model :: proc(t: ^testing.T) {
	for i in 0 ..< PATH_ROUNDS {
		defer free_all(context.temp_allocator)
		comments := i & 1 == 1
		b := strings.builder_make(context.temp_allocator)
		write_value(&b, 4, comments)
		src := transmute([]u8)strings.to_string(b)
		if !(check_round(t, src, .Jsonc) if comments else check_round(t, src, .Json)) {
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
