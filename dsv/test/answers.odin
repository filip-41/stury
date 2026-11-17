package dsv_tests

import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import testkit "../../testkit"
import dsv ".."
import gen "gen"

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
	want_err := dsv.each_answer(ragged, .Csv, path, &want, testkit.collect_answer, opts, read)
	testing.expectf(t, want_err == nil && len(want) == 3, "each_answer: %d answers, %v", len(want), want_err)
	it = dsv.answers(ragged, .Csv, path, opts, read)
	clear(&got)
	for a in dsv.next(&it) {
		append(&got, a)
	}
	testing.expectf(t, slice.equal(got[:], want[:]) && it.err == nil, "%d answers, want %d: %v", len(got), len(want), it.err)
}

// An iterator gives the answers `each_answer` gives and ends with its error, whatever its largest batch, over valid
// and broken texts, as CSV and as TSV, with and without a header.
@(test)
answers_agree :: proc(t: ^testing.T) {
	state := rand.create(5)
	context.random_generator = rand.default_random_generator(&state)
	texts: [100]string
	defer for text in texts {
		delete(text)
	}
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	for round in 0 ..< len(texts) {
		gen.text(&text, round % 4 >= 2)
		if round % 10 == 9 {
			// Enough records for every batch size to fill several times over.
			for i in 0 ..< 200 {
				append(&text, "\n1,2" if i % 2 == 0 else "\n3,4")
			}
		}
		src := text[:]
		if round % 2 == 1 {
			testkit.mutate(&broken, text[:], gen.SHARP)
			src = broken[:]
		}
		texts[round] = strings.clone(string(src))
	}
	// A variant's bit 0 spells the text as TSV and its bit 1 reads it with no header.
	run := testkit.Answer_Run {
		each = proc(src: []u8, paths: []core.Path, variant: int, early: bool, out: ^[dynamic]core.Token_Answer) -> core.Error {
			opts := dsv.Options{no_header = variant >= 2}
			if variant % 2 == 1 {
				return dsv.each_answer(src, .Tsv, paths, out, testkit.collect_answer, opts, {stop_early = early})
			}
			return dsv.each_answer(src, .Csv, paths, out, testkit.collect_answer, opts, {stop_early = early})
		},
		iter = proc(src: []u8, paths: []core.Path, variant: int, early: bool, batch: int, out: ^[dynamic]core.Token_Answer) -> core.Error {
			opts := dsv.Options{no_header = variant >= 2}
			it := dsv.answers(src, .Tsv, paths, opts, {stop_early = early}) if variant % 2 == 1 else dsv.answers(src, .Csv, paths, opts, {stop_early = early})
			it.max_batch = batch
			for a in dsv.next(&it) {
				append(out, a)
			}
			return it.err
		},
	}
	testkit.expect_answers_agree(t, texts[:], {".[]", ".[][0]", ".[1:]", ".[-1]", ".[0][]", ".."}, 4, run)
}
