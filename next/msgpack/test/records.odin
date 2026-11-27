package msgpack_tests

import "core:fmt"
import "core:testing"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:testkit"

// MessagePack records across `.Concatenated`, `.Elements`, and `.Members` framings.

@(test)
sequences_read_as_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	reads, f := msgpack.reads(.Msgpack), msgpack.as(.Msgpack)
	got := testkit.read_binary_records(t, reads, f, testkit.hex("01 92 02 03 a1 61"), .Concatenated)
	testing.expect_value(t, len(got.spans), 3)
	testing.expect(t, got.spans[1] == {1, 4} && got.spans[2] == {4, 6} && got.err == nil)

	empty := testkit.read_binary_records(t, reads, f, nil, .Concatenated)
	testing.expect(t, len(empty.spans) == 0 && empty.err == nil)

	bad := testkit.read_binary_records(t, reads, f, testkit.hex("01 92 02 a1 ff"), .Concatenated)
	testing.expect_value(t, len(bad.spans), 1)
	fault, _ := bad.err.(tape.Fault)
	testing.expect(t, fault.at == 4 && testkit.code_of(bad.err) == "invalid_utf8")
}

@(test)
elements_are_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	reads, f := msgpack.reads(.Msgpack), msgpack.as(.Msgpack)
	got := testkit.read_binary_records(t, reads, f, testkit.hex("93 01 81 a1 61 02 a3 616263"), .Elements)
	testing.expectf(t, len(got.spans) == 3 && got.spans[0] == {1, 2} && got.spans[1] == {2, 6} && got.err == nil, "%v", got)

	empty := testkit.read_binary_records(t, reads, f, testkit.hex("90"), .Elements)
	testing.expect(t, len(empty.spans) == 0 && empty.err == nil)

	trailing := testkit.read_binary_records(t, reads, f, testkit.hex("91 01 00"), .Elements)
	testing.expect(t, len(trailing.spans) == 1 && testkit.code_of(trailing.err) == "trailing")

	not_array := testkit.read_binary_records(t, reads, f, testkit.hex("80"), .Elements)
	testing.expect(t, len(not_array.spans) == 0 && not_array.err == tape.Error(tape.Bad_Option{"framing"}))

	compact := testkit.read_binary_records(t, msgpack.reads(.Compact), msgpack.as(.Compact), testkit.hex("dc 00 01 01"), .Elements)
	testing.expect(t, len(compact.spans) == 0 && testkit.code_of(compact.err) == "not_preferred")
}

@(test)
members_are_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	reads, f := msgpack.reads(.Msgpack), msgpack.as(.Msgpack)
	got := testkit.read_binary_records(t, reads, f, testkit.hex("83 a1 61 01 0a 92 02 03 c4 01 ff c0"), .Members)
	testing.expect_value(t, len(got.keys), 3)
	testing.expectf(t, got.keys[0] == "a" && got.keys[1] == "10" && got.keys[2] == "/w==", "%v", got.keys)
	testing.expect(t, got.spans[1] == {5, 8} && got.err == nil)

	bad_key := testkit.read_binary_records(t, reads, f, testkit.hex("81 90 01"), .Members)
	testing.expect(t, len(bad_key.spans) == 0 && testkit.code_of(bad_key.err) == "bad_key")
}

@(test)
records_refuse_options_they_cannot_take :: proc(t: ^testing.T) {
	testkit.deadline(t)
	lines := msgpack.records_open(testkit.hex("01"), .Lines)
	defer tape.destroy_records(&lines)
	out: [1]tape.Record
	testing.expect(t, msgpack.records_validate(&lines, out[:]) == 0 && lines.err == tape.Error(tape.Bad_Option{"framing"}))

	dups := msgpack.records_open(testkit.hex("01"), opts = {dups = .Refuse})
	defer tape.destroy_records(&dups)
	answers: [1]tape.Span_Answer
	testing.expect(t, msgpack.records_find(&dups, {}, out[:], answers[:]) == 0 && dups.err == tape.Error(tape.Bad_Option{"dups"}))
}

@(test)
records_answer_as_their_bytes_alone :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	items := make([dynamic]u8, context.temp_allocator)
	for h in PIECE_HEX[:5] {
		append(&items, ..testkit.hex(h))
	}
	elements := make([dynamic]u8, context.temp_allocator)
	members := make([dynamic]u8, context.temp_allocator)
	append(&elements, 0x95)
	append(&members, 0x85)
	for h, k in PIECE_HEX[:5] {
		append(&elements, ..testkit.hex(h))
		append(&members, 0xa1, 'a' + u8(k))
		append(&members, ..testkit.hex(h))
	}
	paths := [][]tape.Step{{}, {msgpack.Index(0)}, {msgpack.Index(-1)}, {msgpack.All{}}, {msgpack.Name("a")}, {msgpack.Name("b"), msgpack.Name("d")}}
	texts := [?]struct {
		src:     []u8,
		framing: tape.Framing,
	}{{items[:], .Concatenated}, {elements[:], .Elements}, {members[:], .Members}}
	for text in texts {
		for spec in msgpack.Spec {
			for opts in ([]msgpack.Options{{}, {tolerate = {.Invalid_Utf8}}, {dups = .First}}) {
				for cuts in ([][]int{nil, {len(text.src) / 2}, {1, 2, 3}, testkit.cuts_by(len(text.src), 3), testkit.cuts_by(len(text.src), 17)}) {
					run := testkit.Piece_Run{text.src, msgpack.reads(spec), msgpack.as(spec), opts, cuts}
					name := fmt.tprintf("%v %v", text.framing, spec)
					if !testkit.records_alone_agree(t, run, {framing = text.framing}, paths, name) {
						return
					}
				}
			}
		}
	}
}

@(test)
records_open_through_the_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := testkit.hex("01 02 03")
	r, err := msgpack.reads(.Msgpack).records(msgpack.as(.Msgpack), src, .Concatenated, {}, nil, context.allocator)
	testing.expect_value(t, err, nil)
	defer tape.destroy_records(r)
	out: [4]tape.Record
	testing.expect_value(t, tape.records_validate(r, out[:]), 0)
	testing.expect_value(t, r.index, 3)
}

@(test)
members_report_the_tolerance_their_key_takes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := testkit.hex("82 a2 c328 01 a1 62 02")
	r := msgpack.records_open(src, .Members, opts = {tolerate = {.Invalid_Utf8}})
	defer tape.destroy_records(&r)
	out: [2]tape.Record
	answers: [2]tape.Span_Answer
	testing.expect_value(t, msgpack.records_find(&r, {}, out[:], answers[:]), 2)
	testing.expect_value(t, r.err, nil)
	testing.expect(t, answers[0].tolerated && !answers[1].tolerated)
}

@(test)
records_at_a_long_path_read_through_every_step :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	DEPTH :: 100
	src := make([dynamic]u8, context.temp_allocator)
	path := make([dynamic]tape.Step, context.temp_allocator)
	for k in 0 ..< DEPTH {
		if k % 2 == 0 {
			append(&src, 0x82, 0xa1, 'z', 0x01, 0xa1, 'k')
			append(&path, tape.Name("k"))
		} else {
			append(&src, 0x92, 0x00)
			append(&path, tape.Index(1))
		}
	}
	append(&src, 0x93, 0x01, 0x02, 0x03)
	got := testkit.read_binary_records(t, msgpack.reads(.Msgpack), msgpack.as(.Msgpack), src[:], .Elements, at = path[:])
	testing.expectf(t, len(got.spans) == 3 && got.spans[0] == {u64(len(src)) - 3, u64(len(src)) - 2} && got.err == nil, "%v", got)
	singles := make([]int, len(src) - 1, context.temp_allocator)
	cuts_list := make([][]int, len(src) - 1, context.temp_allocator)
	for cut in 1 ..< len(src) {
		singles[cut - 1] = cut
		cuts_list[cut - 1] = singles[cut - 1:cut]
	}
	run := testkit.Piece_Run{src[:], msgpack.reads(.Msgpack), msgpack.as(.Msgpack), {}, nil}
	testkit.records_pieces_agree_cuts(t, run, cuts_list, .Elements, nil, nil, "long path", path[:])
}

@(test)
records_members_step_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	// `{"a": [1], "b": [2]}` has 3 containers total: root `{`, `"a"` `[1]`, `"b"` `[2]`.
	src := testkit.hex("82 a1 61 91 01 a1 62 91 02")
	out: [2]tape.Record

	r1 := msgpack.records_open(src, .Members, .Msgpack, {budget = {steps = 1}})
	defer tape.destroy_records(&r1)
	testing.expect_value(t, msgpack.records_validate(&r1, out[:]), 0)
	ex1, is_ex1 := r1.err.(tape.Exceeded)
	testing.expectf(t, is_ex1 && ex1.kind == .Steps, "steps=1: %v", r1.err)

	r2 := msgpack.records_open(src, .Members, .Msgpack, {budget = {steps = 2}})
	defer tape.destroy_records(&r2)
	testing.expect_value(t, msgpack.records_validate(&r2, out[:]), 0)
	ex2, is_ex2 := r2.err.(tape.Exceeded)
	testing.expectf(t, is_ex2 && ex2.kind == .Steps, "steps=2: %v", r2.err)

	r3 := msgpack.records_open(src, .Members, .Msgpack, {budget = {steps = 3}})
	defer tape.destroy_records(&r3)
	testing.expect_value(t, msgpack.records_validate(&r3, out[:]), 0)
	testing.expect_value(t, r3.err, nil)
	testing.expect_value(t, r3.index, u64(2))
}
