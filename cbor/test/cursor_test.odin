// A walk stopped and resumed through a cursor against an unbroken walk.
package cbor_tests

import "core:fmt"
import "core:testing"
import core "../../core"
import testkit "../../testkit"
import cbor ".."

// The tokens, end and fault of the walk of the hex `text` as spec `S`, with a stop at token `stop` or at every `every`th
// and a resume after each.
@(private)
walk_as :: proc(text: string, $S: cbor.Spec, skip: string, stop, every: int) -> (h: testkit.Stopping, end: string) {
	src := hex(text)
	h = testkit.Stopping{src = src, skip = skip, stop = stop, every = every}
	h.tokens = make([dynamic]core.Token, 0, 64)
	regs: core.Hook_Regs
	cursor: cbor.Cursor
	hi, fault := cbor.walk(src, 0, S, {}, &h, &regs, testkit.stopping_hook, &cursor)
	for cbor.can_resume(&cursor) {
		hi, fault = cbor.walk_resume(src, &cursor, S, {}, &h, &regs, testkit.stopping_hook)
	}
	return h, fmt.tprint(hi, fault, regs.a)
}

// `walk_as` under the spec that reads every item, then the one that sorts keys.
@(private)
walk_stopping :: proc(text: string, skip: string, stop, every, variant: int) -> (testkit.Stopping, string) {
	if variant == 0 {
		return walk_as(text, .Cbor, skip, stop, every)
	}
	return walk_as(text, .Deterministic, skip, stop, every)
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
	testkit.expect_resumes(t, CURSOR_TEXTS[:], {"", "a", "b", "s"}, 2, walk_stopping)
}

// A resume over another text, or of a cursor that holds no stop, is refused, and `destroy` frees a cursor no resume
// ended.
@(test)
cursor_refuses_another_text :: proc(t: ^testing.T) {
	src := hex("82 01 02")
	h := testkit.Stopping{src = src, stop = 2}
	h.tokens = make([dynamic]core.Token, 0, 16)
	defer delete(h.tokens)
	cursor: cbor.Cursor
	_, fault := cbor.walk(src, 0, .Cbor, {}, &h, nil, testkit.stopping_hook, &cursor)
	testing.expect(t, fault == nil && cbor.can_resume(&cursor))
	other := hex("82 01 03")
	_, fault = cbor.walk_resume(other, &cursor, .Cbor, {}, &h, nil, testkit.stopping_hook)
	f, bad := fault.?
	testing.expect(t, bad && f.kind == .Bad_Option && cbor.can_resume(&cursor))
	cbor.destroy(&cursor)
	testing.expect(t, !cbor.can_resume(&cursor))
	_, fault = cbor.walk_resume(src, &cursor, .Cbor, {}, &h, nil, testkit.stopping_hook)
	f, bad = fault.?
	testing.expect(t, bad && f.kind == .Bad_Option)
}

// The iterator gives the answers `each_answer` gives and ends with its error, whatever its largest batch, over items
// the walk reads and items it refuses, and for several paths at once.
@(test)
answers_agree_with_each_answer :: proc(t: ^testing.T) {
	run := testkit.Answer_Run {
		each = proc(src: []u8, paths: []core.Path, _: int, early: bool, out: ^[dynamic]core.Token_Answer) -> core.Error {
			return cbor.each_answer(src, .Cbor, paths, out, testkit.collect_answer, {}, {stop_early = early})
		},
		iter = proc(src: []u8, paths: []core.Path, _: int, early: bool, batch: int, out: ^[dynamic]core.Token_Answer) -> core.Error {
			it := cbor.answers(src, .Cbor, paths, {}, {stop_early = early})
			it.max_batch = batch
			return testkit.drain_answers(&it, out)
		},
	}
	texts: [len(CURSOR_TEXTS)]string
	for text, i in CURSOR_TEXTS {
		texts[i] = string(hex(text))
	}
	testkit.expect_answers_agree(t, texts[:], {".a", ".[]", ".b[]", "..", ".b[-1]", "limit(2; ..)", ".s.s", ".[1]"}, 1, run)
}

// A loop that ends after the first answer frees the read with `destroy`, and the spec chosen at run time answers alike.
@(test)
answers_break_early :: proc(t: ^testing.T) {
	path, _ := core.parse_path(".[]")
	defer core.path_destroy(&path)
	src := hex("83 01 02 03")
	spec :: cbor.Spec.Preferred
	it := cbor.answers(src, spec, path)
	first: core.Token_Answer
	for a in cbor.next(&it) {
		first = a
		break
	}
	testing.expectf(t, it.err == nil && first.outcome == .Found && first.lo == 1 && first.hi == 2, "%v %v", first, it.err)
	cbor.destroy(&it)
}
