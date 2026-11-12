// A walk stopped and resumed through a cursor, and the answers iterator, against an unbroken walk and `each_answer`.
package yaml_tests

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:testing"
import core "../../core"
import yaml ".."

// A hook that logs every token, skips the value of the key `skip` and stops at every token in `stops`, or at every
// `every`th one when `every` is not 0. A skipped key is never a stop, so the tokens match those of a walk with no stops.
@(private)
Stopping :: struct {
	src:    []u8,
	tokens: [dynamic]core.Token,
	skip:   string,
	stop:   int,
	every:  int,
}

@(private)
stopping_hook :: proc "contextless" (h: ^Stopping, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = runtime.default_context()
	n := len(h.tokens)
	append(&h.tokens, t)
	r := core.Hook_Regs{s.a + 1, s.b, s.c}
	if t.role == .Key && string(h.src[t.lo:t.lo + u64(t.n)]) == h.skip {
		return r, .Skip
	}
	if h.every != 0 && (n + 1) % h.every == 0 || n + 1 == h.stop {
		return r, .Stop
	}
	return r, .Next
}

// The tokens, ends and faults of the walks of every document of `src` in turn, with a stop at token `stop` or at every
// `every`th and a resume after each.
@(private)
walk_stream :: proc(src: []u8, opts: yaml.Options, skip: string, stop, every: int) -> (h: Stopping, ends: [dynamic]string) {
	h = Stopping{src = src, skip = skip, stop = stop, every = every}
	h.tokens = make([dynamic]core.Token, 0, 256)
	ends = make([dynamic]string, context.temp_allocator)
	regs: core.Hook_Regs
	cursor: yaml.Cursor
	lo: u64
	for {
		hi, fault := yaml.walk(src, lo, .Yaml_1_2, opts, &h, &regs, stopping_hook, &cursor)
		for yaml.can_resume(&cursor) {
			hi, fault = yaml.walk_resume(src, &cursor, .Yaml_1_2, opts, &h, &regs, stopping_hook)
		}
		append(&ends, fmt.tprint(hi, fault, regs.a))
		if fault != nil || hi >= u64(len(src)) || hi <= lo {
			break
		}
		lo = hi
	}
	return
}

@(private)
CURSOR_TEXTS := [?]string {
	"a: 1\nb:\n  - x\n  - y # c\n  - {p: q}\nc: |\n  lit\n  more\nd: >-\n  folded\n",
	"{a: [1, 2, {b: c}], d: 'e', ? f : g, \"h\": [i, j: k, ? l], m: }",
	"- - - 1\n    - [2, [3, {x: [4]}]]\n  - ? k\n    : v\n- !!str tagged\n- &n {p: [q]}\n- *n\n",
	"base: &b {x: 1, y: 2}\nmore: &m\n  w: 0\nother:\n  <<: [*b, *m]\n  z: 3\nlist: &l [1, *b]\nagain: *l\n*b : key\n",
	"%YAML 1.2\n%TAG !e! tag:example.com,2000:\n---\na: !e!x 1\n...\n# between\n--- !!map\nb: [2]\n---\n- 3\n--- |\n  text\n",
	"# head\na: 1 # inline\n# between\nb:\n  # inner\n  c: 2 # two\n  # foot\n# end\nd: [1, # one\n  2]\n# last\n",
	"a: 1\nb: [1, 2\n",
	"a: 1\nb:\n  c: *nope\n",
	"a: 1\nb: 2\na: 3\n",
	"x:\n  - 1\n - 2\n",
	"a: [1, {b: 2}]\nc: \"open\n",
	"- {a: &x [1, 2]}\n- *x\n- [*x, *x]\n- !!int nope\n",
}

// A walk stopped at any one token, or at every one, and resumed gives the tokens, ends and faults of an unbroken walk,
// with skipped values, merge keys and the documents of a stream among them.
@(test)
cursor_resumes_after_any_token :: proc(t: ^testing.T) {
	for text in CURSOR_TEXTS {
		src := transmute([]u8)text
		for opts in ([]yaml.Options{{}, {merge_keys = true}}) {
			for skip in ([]string{"", "b", "list"}) {
				full, want := walk_stream(src, opts, skip, 0, 0)
				defer delete(full.tokens)
				for stop in 1 ..= len(full.tokens) + 1 {
					got, ends := walk_stream(src, opts, skip, stop, 0)
					defer delete(got.tokens)
					ok := testing.expectf(t, slice.equal(got.tokens[:], full.tokens[:]), "%q skip %q stop %d: %d tokens, want %d", text, skip, stop, len(got.tokens), len(full.tokens))
					ok &&= testing.expectf(t, slice.equal(ends[:], want[:]), "%q skip %q stop %d: %v, want %v", text, skip, stop, ends, want)
					if !ok {
						return
					}
				}
				for every in 1 ..= 3 {
					got, ends := walk_stream(src, opts, skip, 0, every)
					defer delete(got.tokens)
					ok := testing.expectf(t, slice.equal(got.tokens[:], full.tokens[:]), "%q skip %q every %d: %d tokens, want %d", text, skip, every, len(got.tokens), len(full.tokens))
					ok &&= testing.expectf(t, slice.equal(ends[:], want[:]), "%q skip %q every %d: %v, want %v", text, skip, every, ends, want)
					if !ok {
						return
					}
				}
			}
		}
	}
}

// A resume over another text, or of a cursor that holds no stop, is refused, and `destroy` frees a cursor no resume
// ended.
@(test)
cursor_refuses_another_text :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a: [1, 2]\n")
	h := Stopping{src = src, stop = 2}
	h.tokens = make([dynamic]core.Token, 0, 16)
	defer delete(h.tokens)
	cursor: yaml.Cursor
	_, fault := yaml.walk(src, 0, .Yaml_1_2, {}, &h, nil, stopping_hook, &cursor)
	testing.expect(t, fault == nil && yaml.can_resume(&cursor))
	other := transmute([]u8)string("a: [1, 3]\n")
	_, fault = yaml.walk_resume(other, &cursor, .Yaml_1_2, {}, &h, nil, stopping_hook)
	f, bad := fault.?
	testing.expect(t, bad && f.kind == .Bad_Option && yaml.can_resume(&cursor))
	yaml.destroy(&cursor)
	testing.expect(t, !yaml.can_resume(&cursor))
	_, fault = yaml.walk_resume(src, &cursor, .Yaml_1_2, {}, &h, nil, stopping_hook)
	f, bad = fault.?
	testing.expect(t, bad && f.kind == .Bad_Option)
}

@(private)
collect_answer :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	append((^[dynamic]core.Token_Answer)(state), a)
	return true
}

// The iterator gives the answers `each_answer` gives and ends with its error, whatever its largest batch, over texts
// with aliases, merge keys, comments, several documents and late faults, with paths that answer at once, at a
// container's close and at the text's end.
@(test)
answers_agree_with_each_answer :: proc(t: ^testing.T) {
	texts := [?]string{".a", ".[]", ".b[]", "...x", ".[-1]", "..", "limit(2; ...b)", ".other.z"}
	paths: [len(texts)]core.Path
	for text, i in texts {
		e: core.Error
		paths[i], e = core.parse_path(text)
		testing.expectf(t, e == nil, "%s: %v", text, e)
	}
	defer for &p in paths {
		core.path_destroy(&p)
	}
	srcs := [?]string {
		"b: [{x: 1}, {x: 2, y: [3]}, 4]\na: {x: 5}\nx: 6\n",
		"- x: 1\n- [2, 3]\n- {b: [x, y]}\n- 7\n",
		"b: &n [1, 2]\nc: *n\nx: last\n",
		"other:\n  <<: {z: 1, w: 2}\n  q: 3\nb: [1]\n",
	}
	want, got: [dynamic]core.Token_Answer
	defer delete(want)
	defer delete(got)
	for text in ([]string{CURSOR_TEXTS[0], CURSOR_TEXTS[2], CURSOR_TEXTS[3], CURSOR_TEXTS[5], CURSOR_TEXTS[6], CURSOR_TEXTS[8], CURSOR_TEXTS[10], srcs[0], srcs[1], srcs[2], srcs[3], CURSOR_TEXTS[4]}) {
		src := transmute([]u8)text
		for opts in ([]yaml.Options{{}, {merge_keys = true}}) {
			for path, i in paths {
				for early in ([]bool{false, true}) {
					read := core.Path_Options{stop_early = early}
					clear(&want)
					err := yaml.each_answer(src, .Yaml_1_2, path, &want, collect_answer, opts, read)
					for batch in ([]int{1, 3, 64}) {
						it := yaml.answers(src, .Yaml_1_2, path, opts, read)
						it.max_batch = batch
						clear(&got)
						for a in yaml.next(&it) {
							append(&got, a)
						}
						ok := testing.expectf(t, slice.equal(got[:], want[:]), "%q %s batch %d: %d answers, want %d", text, texts[i], batch, len(got), len(want))
						ok &&= testing.expectf(t, fmt.tprint(it.err) == fmt.tprint(err), "%q %s batch %d: %v, want %v", text, texts[i], batch, it.err, err)
						if !ok {
							return
						}
					}
				}
			}
		}
	}
}

// A loop that ends after the first answer leaves the text past it unjudged, and `destroy` frees the read. A fault after
// the last answer comes after it, in `err` once the loop ends.
@(test)
answers_break_early_and_fault_late :: proc(t: ^testing.T) {
	path, _ := core.parse_path(".[]")
	defer core.path_destroy(&path)
	for text in ([]string{"[1, x: , 3, 4, 5, 6, 7, 8]\n", "- 1\n- [2]\n- 3\n- 4\n- 5\n-  6\nnope\n"}) {
		src := transmute([]u8)text
		it := yaml.answers(src, .Yaml_1_2, path)
		first: core.Token_Answer
		for a in yaml.next(&it) {
			first = a
			break
		}
		testing.expectf(t, it.err == nil && first.outcome == .Found && string(src[first.lo:first.hi]) == "1", "%q: %v %v", text, first, it.err)
		yaml.destroy(&it)
	}
	late := transmute([]u8)string("- 1\n- 2\n- 3\nb: 4\n")
	it := yaml.answers(late, .Yaml_1_2, path)
	n := 0
	for _ in yaml.next(&it) {
		n += 1
	}
	want := yaml.each_answer(late, .Yaml_1_2, path, nil, proc(_: rawptr, _: core.Token_Answer) -> bool {return true})
	testing.expectf(t, n == 3 && it.err != nil && fmt.tprint(it.err) == fmt.tprint(want), "%d answers, %v, want %v", n, it.err, want)
}
