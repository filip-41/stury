package cbor_tests

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"

// Reads of a CBOR text in pieces, each window starting at the read's `keep`, against reads of the whole text.

// Paths into the texts: the root, elements and members by name and index, from either end, and every child.
@(private = "file")
piece_paths :: proc() -> [][]cbor.Step {
	paths := make([dynamic][]cbor.Step, context.temp_allocator)
	add :: proc(paths: ^[dynamic][]cbor.Step, steps: ..cbor.Step) {
		append(paths, slice.clone(steps, context.temp_allocator))
	}
	add(&paths)
	add(&paths, cbor.Index(0))
	add(&paths, cbor.Index(-1))
	add(&paths, cbor.Index(2), cbor.Index(0))
	add(&paths, cbor.All{})
	add(&paths, cbor.Name("a"))
	add(&paths, cbor.Name("b"), cbor.Name("d"))
	add(&paths, cbor.Name("1"), cbor.Name("x"))
	add(&paths, cbor.All{}, cbor.Index(-1))
	return paths[:]
}

// A text with no byte, read in an empty window and a last one, ends its read with the fault `validate` gives.
@(test)
pieces_of_an_empty_text_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for spec in cbor.Spec {
		testkit.pieces_agree(t, cbor.reads(spec), cbor.as(spec), nil, {}, []int{0}, nil, "empty", framing = .Concatenated)
	}
}

// Every text of every spec, under the defaults, a tolerance, a step budget and a depth budget, read in pieces: the same
// verdict and fault, document, answers and scans as the whole reads, and no byte framed twice.
@(test)
pieces_agree_with_whole_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	options := []cbor.Options{{}, {tolerate = {.Invalid_Utf8}}, {budget = {steps = 3}}, {budget = {depth = 2}}, {dups = .First}}
	for h in PIECE_HEX {
		src := hex(h)
		for spec in cbor.Spec {
			for opts in options {
				if !testkit.agree_in_pieces(t, cbor.reads(spec), cbor.as(spec), src, opts, piece_paths(), h) {
					return
				}
			}
		}
	}
}

// Random items and their mutations, read in pieces at a sample of cuts.
@(test)
pieces_agree_on_generated_items :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xcb2)
	for _ in 0 ..< testkit.rounds(12) {
		paths := piece_paths()
		src := random_item()
		defer delete(src)
		bad := mutated(src)
		defer delete(bad)
		for text in ([2][]u8{src, bad}) {
			step := max(1, len(text) / 24)
			for k := 0; k <= len(text); k += step {
				cuts := [1]int{k}
				if !testkit.pieces_agree(t, cbor.reads(.Cbor), cbor.as(.Cbor), text, {}, cuts[:], paths, fmt.tprintf("generated %x", text), framing = .Concatenated) {
					return
				}
			}
			for size in ([]int{1, 3, 16}) {
				if !testkit.pieces_agree(t, cbor.reads(.Cbor), cbor.as(.Cbor), text, {}, testkit.cuts_by(len(text), size), paths, fmt.tprintf("generated %x", text), framing = .Concatenated) {
					return
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

// A window that cuts an element keeps the element's first byte, and the open path names the key of its array.
@(test)
pieces_keep_the_cut_item :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := hex("a2 61 61 01 61 62 82 01 63 636363")
	p := cbor.Pieces{allocator = context.allocator}
	defer cbor.destroy(&p)
	testing.expect_value(t, cbor.validate(src[:10], .Cbor, {pieces = &p}), nil)
	testing.expect(t, p.more)
	testing.expect_value(t, p.at, 10)
	testing.expect_value(t, p.keep, 8)
	testing.expect_value(t, len(p.open), 1)
	if len(p.open) == 1 {
		testing.expect_value(t, p.open[0], cbor.Step(cbor.Name("b")))
	}
	p.from, p.last = p.keep, true
	testing.expect_value(t, cbor.validate(src[p.keep:], .Cbor, {pieces = &p}), nil)
	testing.expect(t, !p.more)
}

// Sequences of the texts read in pieces: valid items one after another, each other text after a valid item, items
// nesting past the levels a framing across windows holds, a break out of place, a count past the text's end, and a
// map cut short.
@(private = "file")
sequence_texts :: proc() -> [][]u8 {
	texts := make([dynamic][]u8, context.temp_allocator)
	valid := make([dynamic]u8, context.temp_allocator)
	for h in PIECE_HEX[:5] {
		append(&valid, ..hex(h))
	}
	append(&texts, valid[:])
	for h in PIECE_HEX[5:] {
		text := make([dynamic]u8, context.temp_allocator)
		append(&text, ..hex(PIECE_HEX[0]))
		append(&text, ..hex(h))
		append(&texts, text[:])
	}
	deep := make([dynamic]u8, context.temp_allocator)
	append(&deep, 0x01)
	for _ in 0 ..< 70 {
		append(&deep, 0x81)
	}
	append(&deep, 0x9f, 0x7f, 0x61, 0x61, 0xff, 0xff, 0x02)
	append(&texts, deep[:], hex("01 82 01 ff 02"), hex("01 9b 0000000000000100 01 02 03"), hex("01 bf 61 61 01 ff a1 61"))
	return texts[:]
}

// The records of a sequence read a window at a time are the whole text's under every cut and window size, and the
// framing reads no byte twice.
@(test)
records_in_pieces_agree_with_whole_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	paths := piece_paths()
	d, _ := cbor.demand_of(paths, allocator = context.temp_allocator)
	options := []cbor.Options{{}, {tolerate = {.Invalid_Utf8}}, {budget = {steps = 3}}, {budget = {depth = 2}}}
	for src in sequence_texts() {
		for spec in cbor.Spec {
			for opts in options {
				run := testkit.Piece_Run{src, cbor.reads(spec), cbor.as(spec), opts, nil}
				for k in 0 ..= len(src) {
					cuts := [1]int{k}
					run.cuts = cuts[:]
					if !testkit.records_pieces_agree(t, run, .Concatenated, paths, &d, "sequence") {
						return
					}
				}
				for size in 1 ..= 40 {
					run.cuts = testkit.cuts_by(len(src), size)
					if !testkit.records_pieces_agree(t, run, .Concatenated, paths, &d, "sequence") {
						return
					}
				}
			}
		}
	}
}

// The elements and members of a root read in pieces are refused, as a fault among them ends the records with the
// fault of the whole text, which no window holds.
@(test)
records_in_pieces_take_a_sequence_only :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := hex("82 01 02")
	for framing in ([]cbor.Framing{.Elements, .Members}) {
		p := cbor.Pieces{allocator = context.allocator}
		defer cbor.destroy(&p)
		r := cbor.records_open(src, framing, opts = {pieces = &p})
		out: [1]cbor.Record
		testing.expect_value(t, cbor.records_validate(&r, out[:]), 0)
		testing.expect_value(t, r.err, cbor.Error(tape.Bad_Option{"pieces"}))
	}
}

// The chunks of an indefinite string a window held whole are read once: a read of the text in windows that start at the
// first byte, with the payload of every chunk the last window held whole overwritten by a byte no text holds, is the
// whole read's. The chunk the window cut is read again from its head.
@(test)
indefinite_chunks_are_read_once_across_windows :: proc(t: ^testing.T) {
	testkit.deadline(t)
	CHUNK :: 60
	src := make([dynamic]u8, context.temp_allocator)
	defer free_all(context.temp_allocator)
	for major in ([]u8{0x7f, 0x5f}) {
		clear(&src)
		append(&src, 0x9f, major)
		for _ in 0 ..< 40 {
			append(&src, major & 0xe0 | 0x18, CHUNK)
			for _ in 0 ..< CHUNK {
				append(&src, 'a')
			}
		}
		append(&src, 0xff, 0xff)
		for size in ([]int{7, 64, 100, 250}) {
			for opts in ([]cbor.Options{{}, {tolerate = {.Invalid_Utf8}}}) {
				text := slice.clone(src[:], context.temp_allocator)
				p := tape.Pieces {
					allocator = context.allocator,
				}
				defer cbor.destroy(&p)
				run := opts
				run.pieces = &p
				err: cbor.Error
				for to := size; ; to += size {
					to = min(to, len(text))
					p.last = to == len(text)
					err = cbor.validate(text[:to], .Cbor, run)
					if !p.more || err != nil {
						break
					}
					// Every chunk this window held whole, as the next window's read of its payload is not to be.
					for at := 2; at + 2 <= to; {
						n := int(text[at + 1])
						if at + 2 + n > to {
							break
						}
						slice.fill(text[at + 2:][:n], 0xff)
						at += 2 + n
					}
				}
				testing.expectf(t, err == nil, "window %d, %v, major %x: %v", size, opts.tolerate, major, err)
			}
		}
	}
}
