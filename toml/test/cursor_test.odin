// A walk stopped and resumed through a cursor, and the answers iterator, against an unbroken walk and `each_answer`.
package toml_tests

import "core:fmt"
import "core:testing"
import core "../../core"
import testkit "../../testkit"
import toml ".."

// The tokens, end and fault of the walk of `text`, with a stop at token `stop` or at every `every`th and a resume after
// each.
@(private)
walk_stopping :: proc(text: string, skip: string, stop, every, _: int) -> (h: testkit.Stopping, end: string) {
	src := transmute([]u8)text
	h = testkit.Stopping{src = src, skip = skip, stop = stop, every = every}
	h.tokens = make([dynamic]core.Token, 0, 256)
	regs: core.Hook_Regs
	cursor: toml.Cursor
	hi, fault := toml.walk(src, 0, .Toml_1_1, {}, &h, &regs, testkit.stopping_hook, &cursor)
	for toml.can_resume(&cursor) {
		hi, fault = toml.walk_resume(src, &cursor, .Toml_1_1, {}, &h, &regs, testkit.stopping_hook)
	}
	return h, fmt.tprint(hi, fault, regs.a)
}

@(private)
CURSOR_TEXTS := [?]string {
	"a = 1\nb = [1, 2, {c = 3}]\n",
	"# head\nx = 1 # one\n[t] # table\n# inner\ny = [ # open\n  1, # elem\n]\n[t.u]\nz = 'q'\n# foot\n",
	"[[arr]]\nx = 1\n[other]\ny = 2\n[[arr]]\nx = 3\n[arr.sub]\nw = true\n",
	"[a.b]\nk = 1\n[a]\nj = 2\nd.e.f = 3\ninline = {p = [1, [2]], q = {}}\n",
	"empty = []\nt = {}\n[s]\n",
	"",
	"a = 1\na = 2\n",
	"x = [1, 2\n",
}

// A walk stopped at any one token, or at every one, and resumed gives the tokens, end and fault of an unbroken walk,
// with skipped values among them.
@(test)
cursor_resumes_after_any_token :: proc(t: ^testing.T) {
	testkit.expect_resumes(t, CURSOR_TEXTS[:], {"", "b", "t", "arr", "inline", "a"}, 1, walk_stopping)
}

// A resume over another text, or of a cursor that holds no stop, is refused, and `destroy` frees a cursor no resume
// ended.
@(test)
cursor_refuses_another_text :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a = [1, 2]\n")
	h := testkit.Stopping{src = src, stop = 2}
	h.tokens = make([dynamic]core.Token, 0, 16)
	defer delete(h.tokens)
	cursor: toml.Cursor
	_, fault := toml.walk(src, 0, .Toml_1_1, {}, &h, nil, testkit.stopping_hook, &cursor)
	testing.expect(t, fault == nil && toml.can_resume(&cursor))
	other := transmute([]u8)string("a = [1, 3]\n")
	_, fault = toml.walk_resume(other, &cursor, .Toml_1_1, {}, &h, nil, testkit.stopping_hook)
	f, bad := fault.?
	testing.expect(t, bad && f.kind == .Bad_Option && toml.can_resume(&cursor))
	toml.destroy(&cursor)
	testing.expect(t, !toml.can_resume(&cursor))
	_, fault = toml.walk_resume(src, &cursor, .Toml_1_1, {}, &h, nil, testkit.stopping_hook)
	f, bad = fault.?
	testing.expect(t, bad && f.kind == .Bad_Option)
}

// The iterator gives the answers `each_answer` gives and ends with its error, whatever its largest batch, over texts
// whose tables are written apart and texts the walk refuses, and for several paths at once.
@(test)
answers_agree_with_each_answer :: proc(t: ^testing.T) {
	run := testkit.Answer_Run {
		each = proc(src: []u8, paths: []core.Path, _: int, early: bool, out: ^[dynamic]core.Token_Answer) -> core.Error {
			return toml.each_answer(src, .Toml_1_1, paths, out, testkit.collect_answer, {}, {stop_early = early})
		},
		iter = proc(src: []u8, paths: []core.Path, _: int, early: bool, batch: int, out: ^[dynamic]core.Token_Answer) -> core.Error {
			it := toml.answers(src, .Toml_1_1, paths, {}, {stop_early = early})
			it.max_batch = batch
			for a in toml.next(&it) {
				append(out, a)
			}
			return it.err
		},
	}
	testkit.expect_answers_agree(t, CURSOR_TEXTS[:], {".a", ".[]", ".arr[].x", "...x", ".arr[-1]", "..", "limit(2; ...x)", ".t.u.z", ".b[]"}, 1, run)
}

// A loop that ends after the first answer frees the read with `destroy`.
@(test)
answers_break_early :: proc(t: ^testing.T) {
	path, _ := core.parse_path(".[]")
	defer core.path_destroy(&path)
	src := transmute([]u8)string("a = 1\nb = 2\nc = 3\n")
	spec :: toml.Spec.Toml_1_0
	it := toml.answers(src, spec, path)
	first: core.Token_Answer
	for a in toml.next(&it) {
		first = a
		break
	}
	testing.expectf(t, it.err == nil && first.outcome == .Found && string(src[first.lo:first.hi]) == "1", "%v %v", first, it.err)
	toml.destroy(&it)
}
