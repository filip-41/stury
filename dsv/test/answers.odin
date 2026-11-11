package dsv_tests

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:testing"
import core "../../core"
import walktest "../../walktest"
import dsv ".."
import gen "gen"

collect :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	append((^[dynamic]core.Token_Answer)(state), a)
	return true
}

// Under `.Refuse` a repeated header cell faults before any answer, and the text is read with the caller's options: a
// tolerated ragged record gives the answers `each_answer` gives.
@(test)
answers_refuse :: proc(t: ^testing.T) {
	read := core.Path_Options{dups = .Refuse}
	path, _ := core.parse_path(".[].a")
	defer core.path_destroy(&path)
	got, want: [dynamic]core.Token_Answer
	defer delete(got)
	defer delete(want)

	it := dsv.answers(transmute([]u8)string("a,a\n1,2\n"), .Csv, path, read = read)
	for a in dsv.next(&it) {
		append(&got, a)
	}
	testing.expectf(t, len(got) == 0 && it.err != nil, "%d answers, %v", len(got), it.err)

	ragged := transmute([]u8)string("a,b\n1,2,3\n4\n5,6\n")
	opts := dsv.Options{tolerate = {.Ragged}}
	want_err := dsv.each_answer(ragged, .Csv, path, &want, collect, opts, read)
	testing.expectf(t, want_err == nil && len(want) == 3, "each_answer: %d answers, %v", len(want), want_err)
	it = dsv.answers(ragged, .Csv, path, opts, read)
	clear(&got)
	for a in dsv.next(&it) {
		append(&got, a)
	}
	testing.expectf(t, slice.equal(got[:], want[:]) && it.err == nil, "%d answers, want %d: %v", len(got), len(want), it.err)
}

// An iterator gives the answers `each_answer` gives and ends with its error, whatever its largest batch, over valid
// and broken texts with and without a header.
@(test)
answers_agree :: proc(t: ^testing.T) {
	state := rand.create(5)
	context.random_generator = rand.default_random_generator(&state)
	texts := [?]string{".[]", ".[][0]", ".[1:]", ".[-1]", ".[0][]", ".."}
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
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	for round in 0 ..< 100 {
		tsv := round % 4 >= 2
		opts := dsv.Options{no_header = round % 8 >= 4}
		gen.text(&text, tsv)
		if round % 10 == 9 {
			// Enough records for every batch size to fill several times over.
			for i in 0 ..< 200 {
				append(&text, "\n1,2" if i % 2 == 0 else "\n3,4")
			}
		}
		src := text[:]
		if round % 2 == 1 {
			walktest.mutate(&broken, text[:], gen.SHARP)
			src = broken[:]
		}
		spec := dsv.Spec.Tsv if tsv else .Csv
		for path, i in paths {
			clear(&want)
			err := dsv.each_answer(src, spec, path, &want, collect, opts)
			for batch in ([]int{1, 3, 64}) {
				it := dsv.answers(src, spec, path, opts)
				it.max_batch = batch
				clear(&got)
				for a in dsv.next(&it) {
					append(&got, a)
				}
				ok := testing.expectf(t, slice.equal(got[:], want[:]), "%v %q %s batch %d: %d answers, want %d", spec, src, texts[i], batch, len(got), len(want))
				ok &&= testing.expectf(t, fmt.tprint(it.err) == fmt.tprint(err), "%v %q %s batch %d: %v, want %v", spec, src, texts[i], batch, it.err, err)
				if !ok {
					return
				}
			}
		}
	}
}
