package toml_tests

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

// Reads of a TOML text in pieces, each window starting at the read's `keep`, against reads of the whole text.

// Paths into the texts: the root, members by name and index, from either end, and every child.
@(private = "file")
PIECE_PATHS := [?][]toml.Step {
	{},
	{toml.Name("a")},
	{toml.Name("t"), toml.Name("b")},
	{toml.Name("l"), toml.Index(0), toml.Name("n")},
	{toml.Name("l"), toml.Index(-1)},
	{toml.Name("u"), toml.Name("v"), toml.Name("c")},
	{toml.All{}},
	{toml.Name("t"), toml.All{}},
}

// Texts of tables written apart, arrays of tables, strings that run over lines, comments of every role and faults.
PIECE_TEXTS := [?]string {
	"",
	"a = 1\n",
	"a = 1",
	"# only a comment\n",
	"a = 1\n[t]\nb = [1, 2]\n[u.v]\nc = 3\n[t.w]\nd = 4\n",
	"[[l]]\nn = 1\n[l.sub]\ns = 'a'\n[[l]]\nn = 2\n[[l.k]]\n",
	"a = \"\"\"\nline\\\n   next\"\"\"\nb = '''\r\nraw\\'''\nc = \"\"\"q\"\"\"\"\"\n",
	"# head\n\n# above\na = [ # open\n  1, # one\n  # last\n]\n[t] # header\n# foot\n",
	"a = {b = 1, c = [1, 2, {d = 3}]}\n[t.x]\ny = 1\n",
	"a.b.c = 1\na.d = 2\n[t]\ne.f = \"x\\ty\"\n",
	"\xef\xbb\xbfa = 1\r\n[t]\r\nb = 2\r\n",
	"a = 1\na = 2\n",
	"a = [1, 2\nb = 3\n",
	"a = \"unterminated\nb = 1\n",
	"[a]\n[a]\n",
	"a = '''never closed\n\nb = 1\n",
	"[t]\nx = 1\n\n\n# trailing\n\n",
}

// Every text of every spec, under the defaults, a step budget and a depth budget, read in pieces: the same verdict and
// fault, document, answers and scans as the whole reads, and no byte framed twice.
@(test)
pieces_agree_with_whole_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	options := []toml.Options{{}, {budget = {steps = 3}}, {budget = {depth = 2}}}
	for text in PIECE_TEXTS {
		for spec in toml.Spec {
			for opts in options {
				if !testkit.agree_in_pieces(t, toml.reads(spec), toml.as(spec), transmute([]u8)text, opts, PIECE_PATHS[:], text) {
					return
				}
			}
		}
	}
}

// The toml-test cases that read, a sample of the other cases, and their cuts.
@(test)
pieces_agree_on_the_conformance_cases :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	rest := LIST_1_1
	k := 0
	for name in strings.split_lines_iterator(&rest) {
		if !strings.has_suffix(name, ".toml") {
			continue
		}
		k += 1
		if !testkit.sampled(8) {
			continue
		}
		data, found := case_data(name)
		if !found {
			continue
		}
		step := max(1, len(data) / 6)
		singles := make([dynamic]int, 0, 8, context.temp_allocator)
		for at := 0; at <= len(data); at += step {
			append(&singles, at)
		}
		cuts_list := make([dynamic][]int, 0, len(singles) + 3, context.temp_allocator)
		for i in 0 ..< len(singles) {
			append(&cuts_list, singles[i:i + 1])
		}
		for size in ([]int{1, 5, 29}) {
			append(&cuts_list, testkit.cuts_by(len(data), size))
		}
		if !testkit.pieces_agree_cuts(t, toml.reads(.Toml_1_1), toml.as(.Toml_1_1), data, {}, cuts_list[:], PIECE_PATHS[:], name, framing = .Concatenated) {
			return
		}
		free_all(context.temp_allocator)
	}
}

// Random texts and their mutations, read in pieces at a sample of cuts.
@(test)
pieces_agree_on_generated_texts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x701)
	for _ in 0 ..< testkit.rounds(12) {
		src := random_text()
		defer delete(src)
		raw := transmute([]u8)src
		bad := testkit.mutate(raw, TOML_MUTATE_ALPHABET)
		for text in ([2][]u8{raw, bad}) {
			step := max(1, len(text) / 24)
			singles := make([dynamic]int, 0, 26, context.temp_allocator)
			for k := 0; k <= len(text); k += step {
				append(&singles, k)
			}
			cuts_list := make([dynamic][]int, 0, len(singles) + 3, context.temp_allocator)
			for i in 0 ..< len(singles) {
				append(&cuts_list, singles[i:i + 1])
			}
			for size in ([]int{1, 3, 16}) {
				append(&cuts_list, testkit.cuts_by(len(text), size))
			}
			if !testkit.pieces_agree_cuts(t, toml.reads(.Toml_1_1), toml.as(.Toml_1_1), text, {}, cuts_list[:], PIECE_PATHS[:], fmt.tprintf("generated %q", text), framing = .Concatenated) {
				return
			}
		}
		free_all(context.temp_allocator)
	}
}

// A window that cuts a statement keeps the statement's first byte, the open path names the table the text is in, and a
// table later statements may add to holds back what follows it.
@(test)
pieces_keep_the_cut_statement :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a = 1\n[t]\nb = 2\n[u]\nc = [1,\n 2]\n")
	p := toml.Pieces{allocator = context.allocator}
	defer toml.destroy(&p)
	// The window ends inside the array of `c`.
	cut := len(src) - 3
	testing.expect_value(t, toml.validate(src[:cut], .Toml_1_0, {pieces = &p}), nil)
	testing.expect(t, p.more)
	testing.expect_value(t, p.at, u64(cut))
	testing.expect_value(t, p.keep, 19)
	testing.expect_value(t, len(p.open), 1)
	if len(p.open) == 1 {
		testing.expect_value(t, p.open[0], toml.Step(toml.Name("u")))
	}
	p.from, p.last = p.keep, true
	testing.expect_value(t, toml.validate(src[p.keep:], .Toml_1_0, {pieces = &p}), nil)
	testing.expect(t, !p.more)
}

// Records of a text in pieces: the text is one record, which no window gives before the last, and `.Members` is
// refused.
@(test)
records_in_pieces_agree_with_whole_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	paths := PIECE_PATHS[:]
	d, _ := toml.demand_of(paths, allocator = context.temp_allocator)
	for text in PIECE_TEXTS {
		src := transmute([]u8)text
		singles := make([]int, len(src) + 1, context.temp_allocator)
		cuts_list := make([dynamic][]int, 0, len(src) + 1 + 20, context.temp_allocator)
		for k in 0 ..= len(src) {
			singles[k] = k
			append(&cuts_list, singles[k:k + 1])
		}
		for size in 1 ..= 20 {
			append(&cuts_list, testkit.cuts_by(len(src), size))
		}
		for spec in toml.Spec {
			run := testkit.Piece_Run{src, toml.reads(spec), toml.as(spec), {}, nil}
			if !testkit.records_pieces_agree_cuts(t, run, cuts_list[:], .Concatenated, paths, &d, text) {
				return
			}
		}
	}
	p := tape.Pieces{last = true}
	r := toml.records_open(transmute([]u8)string("a = 1\n"), .Members, opts = {pieces = &p})
	out: [2]tape.Record
	testing.expect_value(t, toml.records_validate(&r, out[:]), 0)
	testing.expect_value(t, testkit.code_of(r.err), "bad option pieces")
}
