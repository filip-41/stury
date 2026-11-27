package msgpack_tests

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:testing"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:testkit"

// Piece-by-piece streaming MessagePack reads across arbitrary cuts and window sizes.

@(private = "file")
PIECE_PATHS := [?][]msgpack.Step {
	{},
	{msgpack.Index(0)},
	{msgpack.Index(-1)},
	{msgpack.Index(2), msgpack.Index(0)},
	{msgpack.All{}},
	{msgpack.Name("a")},
	{msgpack.Name("b"), msgpack.Name("d")},
	{msgpack.Name("1"), msgpack.Name("x")},
	{msgpack.All{}, msgpack.Index(-1)},
}

@(test)
pieces_of_an_empty_text_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for spec in msgpack.Spec {
		testkit.pieces_agree(t, msgpack.reads(spec), msgpack.as(spec), nil, {}, []int{0}, nil, "empty", framing = .Concatenated)
	}
}

@(test)
pieces_agree_with_whole_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	options := []msgpack.Options{{}, {tolerate = {.Invalid_Utf8}}, {budget = {steps = 3}}, {budget = {depth = 2}}, {dups = .First}}
	for h in PIECE_HEX {
		src := testkit.hex(h)
		for spec in msgpack.Spec {
			for opts in options {
				if !testkit.agree_in_pieces(t, msgpack.reads(spec), msgpack.as(spec), src, opts, PIECE_PATHS[:], h) {
					return
				}
			}
		}
	}
}

@(test)
pieces_agree_on_generated_items :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x99a2)
	for _ in 0 ..< testkit.rounds(12) {
		src := random_item()
		defer delete(src)
		bad := testkit.mutate(src)
		for text in ([2][]u8{src, bad}) {
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
			if !testkit.pieces_agree_cuts(t, msgpack.reads(.Msgpack), msgpack.as(.Msgpack), text, {}, cuts_list[:], PIECE_PATHS[:], fmt.tprintf("gen %x", text), framing = .Concatenated, containers = true) {
				return
			}
		}
		free_all(context.temp_allocator)
	}
}

@(test)
pieces_keep_the_cut_item :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := testkit.hex("82 a1 61 01 a1 62 92 01 a3 636363")
	p := msgpack.Pieces{allocator = context.allocator}
	defer msgpack.destroy(&p)
	testing.expect_value(t, msgpack.validate(src[:10], .Msgpack, {pieces = &p}), nil)
	testing.expect(t, p.more)
	testing.expect_value(t, p.at, 10)
	testing.expect_value(t, p.keep, 8)
	testing.expect_value(t, len(p.open), 1)
	if len(p.open) == 1 {
		testing.expect_value(t, p.open[0], msgpack.Step(msgpack.Name("b")))
	}
	p.from, p.last = p.keep, true
	testing.expect_value(t, msgpack.validate(src[p.keep:], .Msgpack, {pieces = &p}), nil)
	testing.expect(t, !p.more)
}

@(private = "file")
sequence_texts :: proc() -> [][]u8 {
	texts := make([dynamic][]u8, context.temp_allocator)
	valid := make([dynamic]u8, context.temp_allocator)
	for h in PIECE_HEX[:5] {
		append(&valid, ..testkit.hex(h))
	}
	append(&texts, valid[:])
	for h in PIECE_HEX[5:] {
		text := make([dynamic]u8, context.temp_allocator)
		append(&text, ..testkit.hex(PIECE_HEX[0]))
		append(&text, ..testkit.hex(h))
		append(&texts, text[:])
	}
	return texts[:]
}

@(test)
records_in_pieces_agree_with_whole_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	paths := PIECE_PATHS[:]
	d, _ := msgpack.demand_of(paths, allocator = context.temp_allocator)
	options := []msgpack.Options{{}, {tolerate = {.Invalid_Utf8}}, {budget = {steps = 3}}, {budget = {depth = 2}}}
	for src in sequence_texts() {
		singles := make([]int, len(src) + 1, context.temp_allocator)
		cuts_list := make([dynamic][]int, 0, len(src) + 1 + 40, context.temp_allocator)
		for k in 0 ..= len(src) {
			singles[k] = k
			append(&cuts_list, singles[k:k + 1])
		}
		for size in 1 ..= 40 {
			append(&cuts_list, testkit.cuts_by(len(src), size))
		}
		for spec in msgpack.Spec {
			for opts in options {
				run := testkit.Piece_Run{src, msgpack.reads(spec), msgpack.as(spec), opts, nil}
				if !testkit.records_pieces_agree_cuts(t, run, cuts_list[:], .Concatenated, paths, &d, "sequence") {
					return
				}
			}
		}
	}
}

@(test)
container_records_in_pieces_agree_with_whole_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	paths := PIECE_PATHS[:]
	d, _ := msgpack.demand_of(paths, allocator = context.temp_allocator)
	texts := []string {
		"93 01 92 02 03 81 a1 61 04",
		"83 a1 61 92 01 02 a1 62 81 a1 62 05 a1 63 06",
		"82 a1 62 01 a1 61 02",
		"82 a1 61 01 a1 61 02",
		"81 a1 61 82 a1 62 01 a1 62 02",
		"93 01 02",
		"92 01 02 03",
		"92 01 c1",
		"dd 00 00 01 00 01 02 03",
		"83 a1 61 01 a1 62 02",
	}
	ats := [][]tape.Step{nil, {tape.Name("a")}, {tape.Index(0)}, {tape.Name("a"), tape.Index(1)}}
	options := []msgpack.Options{{}, {tolerate = {.Invalid_Utf8}}, {budget = {steps = 3}}, {budget = {depth = 2}}}
	for h in texts {
		src := testkit.hex(h)
		singles := make([]int, len(src) + 1, context.temp_allocator)
		cuts_list := make([dynamic][]int, 0, len(src) + 1 + 12, context.temp_allocator)
		for k in 0 ..= len(src) {
			singles[k] = k
			append(&cuts_list, singles[k:k + 1])
		}
		for size in 1 ..= 12 {
			append(&cuts_list, testkit.cuts_by(len(src), size))
		}
		for spec in msgpack.Spec {
			for opts in options {
				run := testkit.Piece_Run{src, msgpack.reads(spec), msgpack.as(spec), opts, nil}
				for at in ats {
					for framing in ([]msgpack.Framing{.Elements, .Members}) {
						if !testkit.records_pieces_agree_cuts(t, run, cuts_list[:], framing, paths, &d, h, at) {
							return
						}
					}
				}
			}
		}
	}
}

@(test)
so_far_drops_facts_past_cut :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	// Map {"a": ts(0)} cut inside timestamp payload; array [ext(1, 0xaa)] cut after header.
	cases := [?]struct {
		full: string,
		cut:  int,
	}{
		{"81 a1 61 d6 ff 00000001", 6},
		{"91 d4 01 aa", 2},
	}
	for c in cases {
		src := testkit.hex(c.full)
		p := tape.Pieces{so_far = true, allocator = context.allocator}
		defer msgpack.destroy(&p)
		doc, err := msgpack.build(src[:c.cut], .Msgpack, {pieces = &p})
		defer tape.destroy(&doc)
		testing.expectf(t, err == nil, "%s cut %d: %v", c.full, c.cut, err)
		for f in doc.facts {
			testing.expectf(t, int(f.node) < len(doc.nodes), "%s: OOB fact node %d >= %d", c.full, f.node, len(doc.nodes))
		}
	}
}

@(test)
pieces_open_inside_skipped_and_kept_containers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// 1. `.Skip` in `find` (`[[{"deep":[{"leaf":"hello"}]}], {"target":42}]`, path `{Index(1), Name("target")}`):
	//    Element 0 is skipped wholesale; cutting inside `"hello"` must record the exact open path with no duplicate levels.
	{
		// [[{"deep":[{"leaf":"hello"}]}], {"target":42}]
		src := testkit.hex("92 91 81 a4 64656570 91 81 a4 6c656166 a5 68656c6c6f 81 a6 746172676574 2a")
		p := msgpack.Pieces{allocator = context.allocator}
		defer msgpack.destroy(&p)
		path := []msgpack.Step{msgpack.Index(1), msgpack.Name("target")}
		// Cut inside `"hello"` (`len = 22`, cuts 2 bytes before `"target"` key -> right inside `"hello"`).
		_, ferr1 := msgpack.find(src[:19], path, .Msgpack, {}, {pieces = &p})
		testing.expect_value(t, ferr1, nil)
		testing.expect(t, p.more)
		want_open := []msgpack.Step{msgpack.Index(0), msgpack.Index(0), msgpack.Name("deep"), msgpack.Index(0), msgpack.Name("leaf")}
		testing.expectf(t, slice.equal(p.open, want_open), "find skip open=%v, want %v", p.open, want_open)

		p.from, p.last = p.keep, true
		ans, ferr2 := msgpack.find(src[p.keep:], path, .Msgpack, {}, {pieces = &p})
		testing.expect_value(t, ferr2, nil)
		testing.expect(t, !p.more && len(p.open) == 0 && ans.lo == u64(len(src) - 1))
	}

	// 2. `.Rest` in `find` (`[{"target":42}, {"tail":{"sub":[9, {"leaf":"hello"}]}}]`, path `{Index(0), Name("target")}`):
	//    After element 0 settles, `find` answers `.Rest` on element 1; cutting inside `"hello"` must keep exact `open`,
	//    and completing must leave `open` empty (not leaked from `.Rest`).
	{
		src := testkit.hex("92 81 a6 746172676574 2a 81 a4 7461696c 81 a3 737562 92 09 81 a4 6c656166 a5 68656c6c6f")
		p := msgpack.Pieces{allocator = context.allocator}
		defer msgpack.destroy(&p)
		path := []msgpack.Step{msgpack.Index(0), msgpack.Name("target")}
		_, ferr1 := msgpack.find(src[:len(src) - 1], path, .Msgpack, {}, {pieces = &p})
		testing.expect_value(t, ferr1, nil)
		testing.expect(t, p.more)
		want_open := []msgpack.Step{msgpack.Index(1), msgpack.Name("tail"), msgpack.Name("sub"), msgpack.Index(1), msgpack.Name("leaf")}
		testing.expectf(t, slice.equal(p.open, want_open), "find rest open=%v, want %v", p.open, want_open)

		p.from, p.last = p.keep, true
		ans, ferr2 := msgpack.find(src[p.keep:], path, .Msgpack, {}, {pieces = &p})
		testing.expect_value(t, ferr2, nil)
		testing.expect(t, !p.more && len(p.open) == 0 && ans.lo == 9)
	}

	// 3. `.Keep` and `.Keep_Stubs` in `scan`:
	//    `{"k":[1, {"nest":[{"leaf":"hello"}]}], "stubs":{"a":1, "b":{"leaf":"hello"}}, "z":9}`
	{
		src := testkit.hex("83 a1 6b 92 01 81 a4 6e657374 91 81 a4 6c656166 a5 68656c6c6f a5 7374756273 82 a1 61 01 a1 62 81 a4 6c656166 a5 68656c6c6f a1 7a 09")
		// Cut inside `"leaf":"hello"` inside `"nest"` (byte 22): `"k"` is `.Keep`.
		p := msgpack.Pieces{allocator = context.allocator}
		defer msgpack.destroy(&p)
		d, _ := msgpack.demand_of({{msgpack.Name("k")}}, allocator = context.temp_allocator)
		doc1, serr1 := msgpack.scan(src[:21], &d, .Msgpack, {}, {pieces = &p})
		tape.destroy(&doc1)
		testing.expect_value(t, serr1, nil)
		testing.expect(t, p.more)
		want_keep_open := []msgpack.Step{msgpack.Name("k"), msgpack.Index(1), msgpack.Name("nest"), msgpack.Index(0), msgpack.Name("leaf")}
		testing.expectf(t, slice.equal(p.open, want_keep_open), "scan keep open=%v, want %v", p.open, want_keep_open)

		p.from, p.last = p.keep, true
		doc2, serr2 := msgpack.scan(src[p.keep:], &d, .Msgpack, {}, {pieces = &p})
		defer tape.destroy(&doc2)
		testing.expect_value(t, serr2, nil)
		testing.expect(t, !p.more && len(p.open) == 0)

		whole, _ := msgpack.scan(src, &d, .Msgpack, {}, {}, context.temp_allocator)
		testing.expect_value(t, len(doc2.nodes), len(whole.nodes))

		// Test `.Keep_Stubs` on `"stubs"` (`Grain.Keys`) cutting inside `"b"` -> `"leaf":"hello"` (2 bytes before `a1 7a 09`).
		p2 := msgpack.Pieces{allocator = context.allocator}
		defer msgpack.destroy(&p2)
		d_stubs, _ := msgpack.demand_of({{msgpack.Name("stubs")}}, grains = {msgpack.Grain.Keys}, allocator = context.temp_allocator)
		sd1, sserr1 := msgpack.scan(src[:len(src) - 4], &d_stubs, .Msgpack, {}, {pieces = &p2})
		tape.destroy(&sd1)
		testing.expect_value(t, sserr1, nil)
		testing.expect(t, p2.more)
		want_stubs_open := []msgpack.Step{msgpack.Name("stubs"), msgpack.Name("b"), msgpack.Name("leaf")}
		testing.expectf(t, slice.equal(p2.open, want_stubs_open), "scan keep_stubs open=%v, want %v", p2.open, want_stubs_open)

		p2.from, p2.last = p2.keep, true
		sd2, sserr2 := msgpack.scan(src[p2.keep:], &d_stubs, .Msgpack, {}, {pieces = &p2})
		defer tape.destroy(&sd2)
		testing.expect_value(t, sserr2, nil)
		testing.expect(t, !p2.more && len(p2.open) == 0)
	}
}
