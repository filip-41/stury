// A walk stopped and resumed through a cursor, and the answers iterator, against an unbroken walk and `each_answer`.
package toml_tests

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:testing"
import core "../../core"
import toml ".."

// A hook that logs every token, skips the value of the key `skip` and stops at token `stop`, or at every `every`th one
// when `every` is not 0. A skipped key is never a stop, so the tokens match those of a walk with no stops.
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

// The tokens, end and fault of the walk of `src`, with a stop at token `stop` or at every `every`th and a resume after
// each.
@(private)
walk_stopping :: proc(src: []u8, skip: string, stop, every: int) -> (h: Stopping, end: string) {
	h = Stopping{src = src, skip = skip, stop = stop, every = every}
	h.tokens = make([dynamic]core.Token, 0, 256)
	regs: core.Hook_Regs
	cursor: toml.Cursor
	hi, fault := toml.walk(src, 0, .Toml_1_1, {}, &h, &regs, stopping_hook, &cursor)
	for toml.can_resume(&cursor) {
		hi, fault = toml.walk_resume(src, &cursor, .Toml_1_1, {}, &h, &regs, stopping_hook)
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
	for text in CURSOR_TEXTS {
		src := transmute([]u8)text
		for skip in ([]string{"", "b", "t", "arr", "inline", "a"}) {
			full, want := walk_stopping(src, skip, 0, 0)
			defer delete(full.tokens)
			for stop in 1 ..= len(full.tokens) + 1 {
				got, end := walk_stopping(src, skip, stop, 0)
				defer delete(got.tokens)
				ok := testing.expectf(t, slice.equal(got.tokens[:], full.tokens[:]), "%q skip %q stop %d: %d tokens, want %d", text, skip, stop, len(got.tokens), len(full.tokens))
				ok &&= testing.expectf(t, end == want, "%q skip %q stop %d: %v, want %v", text, skip, stop, end, want)
				if !ok {
					return
				}
			}
			for every in 1 ..= 3 {
				got, end := walk_stopping(src, skip, 0, every)
				defer delete(got.tokens)
				ok := testing.expectf(t, slice.equal(got.tokens[:], full.tokens[:]), "%q skip %q every %d: %d tokens, want %d", text, skip, every, len(got.tokens), len(full.tokens))
				ok &&= testing.expectf(t, end == want, "%q skip %q every %d: %v, want %v", text, skip, every, end, want)
				if !ok {
					return
				}
			}
		}
	}
}

// A resume over another text, or of a cursor that holds no stop, is refused, and `destroy` frees a cursor no resume
// ended.
@(test)
cursor_refuses_another_text :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a = [1, 2]\n")
	h := Stopping{src = src, stop = 2}
	h.tokens = make([dynamic]core.Token, 0, 16)
	defer delete(h.tokens)
	cursor: toml.Cursor
	_, fault := toml.walk(src, 0, .Toml_1_1, {}, &h, nil, stopping_hook, &cursor)
	testing.expect(t, fault == nil && toml.can_resume(&cursor))
	other := transmute([]u8)string("a = [1, 3]\n")
	_, fault = toml.walk_resume(other, &cursor, .Toml_1_1, {}, &h, nil, stopping_hook)
	f, bad := fault.?
	testing.expect(t, bad && f.kind == .Bad_Option && toml.can_resume(&cursor))
	toml.destroy(&cursor)
	testing.expect(t, !toml.can_resume(&cursor))
	_, fault = toml.walk_resume(src, &cursor, .Toml_1_1, {}, &h, nil, stopping_hook)
	f, bad = fault.?
	testing.expect(t, bad && f.kind == .Bad_Option)
}

@(private)
collect_answer :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	append((^[dynamic]core.Token_Answer)(state), a)
	return true
}

// The iterator gives the answers `each_answer` gives and ends with its error, whatever its largest batch, over texts
// whose tables are written apart and texts the walk refuses.
@(test)
answers_agree_with_each_answer :: proc(t: ^testing.T) {
	texts := [?]string{".a", ".[]", ".arr[].x", "...x", ".arr[-1]", "..", "limit(2; ...x)", ".t.u.z"}
	paths: [len(texts)]core.Path
	for text, i in texts {
		e: core.Error
		paths[i], e = core.parse_path(text)
		testing.expectf(t, e == nil, "%s: %v", text, e)
	}
	defer for &p in paths {
		core.path_destroy(&p)
	}
	want, got: [dynamic]core.Token_Answer
	defer delete(want)
	defer delete(got)
	for text in CURSOR_TEXTS {
		src := transmute([]u8)text
		for path, i in paths {
			for early in ([]bool{false, true}) {
				read := core.Path_Options{stop_early = early}
				clear(&want)
				err := toml.each_answer(src, .Toml_1_1, path, &want, collect_answer, {}, read)
				for batch in ([]int{1, 3, 64}) {
					it := toml.answers(src, .Toml_1_1, path, {}, read)
					it.max_batch = batch
					clear(&got)
					for a in toml.next(&it) {
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

// A loop that ends after the first answer frees the read with `destroy`.
@(test)
answers_break_early :: proc(t: ^testing.T) {
	path, _ := core.parse_path(".[]")
	defer core.path_destroy(&path)
	src := transmute([]u8)string("a = 1\nb = 2\nc = 3\n")
	spec := toml.Spec.Toml_1_0
	it := toml.answers(src, spec, path)
	first: core.Token_Answer
	for a in toml.next(&it) {
		first = a
		break
	}
	testing.expectf(t, it.err == nil && first.outcome == .Found && string(src[first.lo:first.hi]) == "1", "%v %v", first, it.err)
	toml.destroy(&it)
}
