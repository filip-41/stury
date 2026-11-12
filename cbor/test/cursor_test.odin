// A walk stopped and resumed through a cursor against an unbroken walk.
package cbor_tests

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:testing"
import core "../../core"
import cbor ".."

// A hook that logs every token, skips the value of the text key `skip` and stops at token `stop`, or at every `every`th
// one when `every` is not 0. A skipped key is never a stop, so the tokens match those of a walk with no stops.
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
	if t.role == .Key && t.kind == .String && string(h.src[t.lo:t.lo + u64(t.n)]) == h.skip {
		return r, .Skip
	}
	if h.every != 0 && (n + 1) % h.every == 0 || n + 1 == h.stop {
		return r, .Stop
	}
	return r, .Next
}

// The tokens, end and fault of the walk of `src` as spec `S`, with a stop at token `stop` or at every `every`th and a
// resume after each.
@(private)
walk_stopping :: proc(src: []u8, $S: cbor.Spec, skip: string, stop, every: int) -> (h: Stopping, end: string) {
	h = Stopping{src = src, skip = skip, stop = stop, every = every}
	h.tokens = make([dynamic]core.Token, 0, 64)
	regs: core.Hook_Regs
	cursor: cbor.Cursor
	hi, fault := cbor.walk(src, 0, S, {}, &h, &regs, stopping_hook, &cursor)
	for cbor.can_resume(&cursor) {
		hi, fault = cbor.walk_resume(src, &cursor, S, {}, &h, &regs, stopping_hook)
	}
	return h, fmt.tprint(hi, fault, regs.a)
}

@(private)
CURSOR_TEXTS := [?]string {
	"a2 61 61 01 61 62 83 01 02 a1 61 63 03",
	"bf 61 73 9f 01 02 ff 61 74 5f 41 01 42 02 03 ff ff",
	"82 c2 41 01 c4 82 21 19 6a b3",
	"a3 01 80 02 a0 03 c0 74 32 30 31 33 2d 30 33 2d 32 31 54 32 30 3a 30 34 3a 30 30 5a",
	"d9 d9 f7 a2 61 73 c4 82 20 03 61 75 c1 01",
	"a2 61 73 a1 61 73 01 61 75 82 80 a0",
	"a2 61 62 01 61 61 02",
	"83 01 82 02",
	"82 01 c2 61 61",
}

// A walk stopped at any one token, or at every one, and resumed gives the tokens, end and fault of an unbroken walk,
// with skipped values among them, under the spec that reads every item and one that sorts keys.
@(test)
cursor_resumes_after_any_token :: proc(t: ^testing.T) {
	resumes :: proc(t: ^testing.T, $S: cbor.Spec) -> bool {
		for text in CURSOR_TEXTS {
			src := hex(text)
			for skip in ([]string{"", "a", "b", "s"}) {
				full, want := walk_stopping(src, S, skip, 0, 0)
				defer delete(full.tokens)
				for stop in 1 ..= len(full.tokens) + 1 {
					got, end := walk_stopping(src, S, skip, stop, 0)
					defer delete(got.tokens)
					ok := testing.expectf(t, slice.equal(got.tokens[:], full.tokens[:]), "%v %s skip %q stop %d: %d tokens, want %d", S, text, skip, stop, len(got.tokens), len(full.tokens))
					ok &&= testing.expectf(t, end == want, "%v %s skip %q stop %d: %v, want %v", S, text, skip, stop, end, want)
					if !ok {
						return false
					}
				}
				for every in 1 ..= 3 {
					got, end := walk_stopping(src, S, skip, 0, every)
					defer delete(got.tokens)
					ok := testing.expectf(t, slice.equal(got.tokens[:], full.tokens[:]), "%v %s skip %q every %d: %d tokens, want %d", S, text, skip, every, len(got.tokens), len(full.tokens))
					ok &&= testing.expectf(t, end == want, "%v %s skip %q every %d: %v, want %v", S, text, skip, every, end, want)
					if !ok {
						return false
					}
				}
			}
		}
		return true
	}
	if resumes(t, .Cbor) {
		resumes(t, .Deterministic)
	}
}

// A resume over another text, or of a cursor that holds no stop, is refused, and `destroy` frees a cursor no resume
// ended.
@(test)
cursor_refuses_another_text :: proc(t: ^testing.T) {
	src := hex("82 01 02")
	h := Stopping{src = src, stop = 2}
	h.tokens = make([dynamic]core.Token, 0, 16)
	defer delete(h.tokens)
	cursor: cbor.Cursor
	_, fault := cbor.walk(src, 0, .Cbor, {}, &h, nil, stopping_hook, &cursor)
	testing.expect(t, fault == nil && cbor.can_resume(&cursor))
	other := hex("82 01 03")
	_, fault = cbor.walk_resume(other, &cursor, .Cbor, {}, &h, nil, stopping_hook)
	f, bad := fault.?
	testing.expect(t, bad && f.kind == .Bad_Option && cbor.can_resume(&cursor))
	cbor.destroy(&cursor)
	testing.expect(t, !cbor.can_resume(&cursor))
	_, fault = cbor.walk_resume(src, &cursor, .Cbor, {}, &h, nil, stopping_hook)
	f, bad = fault.?
	testing.expect(t, bad && f.kind == .Bad_Option)
}

@(private)
collect_answer :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	append((^[dynamic]core.Token_Answer)(state), a)
	return true
}

// The iterator gives the answers `each_answer` gives and ends with its error, whatever its largest batch, over items
// the walk reads and items it refuses.
@(test)
answers_agree_with_each_answer :: proc(t: ^testing.T) {
	texts := [?]string{".a", ".[]", ".b[]", "..", ".b[-1]", "limit(2; ..)", ".s.s", ".[1]"}
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
		src := hex(text)
		for path, i in paths {
			for early in ([]bool{false, true}) {
				read := core.Path_Options{stop_early = early}
				clear(&want)
				err := cbor.each_answer(src, .Cbor, path, &want, collect_answer, {}, read)
				for batch in ([]int{1, 3, 64}) {
					it := cbor.answers(src, .Cbor, path, {}, read)
					it.max_batch = batch
					clear(&got)
					for a in cbor.next(&it) {
						append(&got, a)
					}
					ok := testing.expectf(t, slice.equal(got[:], want[:]), "%s %s batch %d: %d answers, want %d", text, texts[i], batch, len(got), len(want))
					ok &&= testing.expectf(t, fmt.tprint(it.err) == fmt.tprint(err), "%s %s batch %d: %v, want %v", text, texts[i], batch, it.err, err)
					if !ok {
						return
					}
				}
			}
		}
	}
}

// A loop that ends after the first answer frees the read with `destroy`, and the spec chosen at run time answers alike.
@(test)
answers_break_early :: proc(t: ^testing.T) {
	path, _ := core.parse_path(".[]")
	defer core.path_destroy(&path)
	src := hex("83 01 02 03")
	spec := cbor.Spec.Preferred
	it := cbor.answers(src, spec, path)
	first: core.Token_Answer
	for a in cbor.next(&it) {
		first = a
		break
	}
	testing.expectf(t, it.err == nil && first.outcome == .Found && first.lo == 1 && first.hi == 2, "%v %v", first, it.err)
	cbor.destroy(&it)
}
