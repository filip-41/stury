package cbor_tests

import "core:fmt"
import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"

// The records of a CBOR text: the items of a sequence, the elements of the root array and the members of the root map.

// A sequence (RFC 8742) reads as its items, one record each, and a binary text has no byte order mark to skip.
@(test)
sequences_read_as_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reads, f := cbor.reads(.Cbor), cbor.as(.Cbor)
	got := testkit.read_binary_records(t, reads, f, testkit.hex("01 82 02 03 61 61"), .Concatenated)
	testing.expect_value(t, len(got.spans), 3)
	testing.expect(t, got.spans[1] == {1, 4} && got.spans[2] == {4, 6} && got.err == nil)
	// A byte order mark reads as simple value 15, then a map head cut short.
	bom := testkit.read_binary_records(t, reads, f, testkit.hex("ef bb bf 01"), .Concatenated)
	testing.expect_value(t, testkit.code_of(bom.err), "truncated")
	testing.expect(t, len(bom.spans) == 1 && bom.spans[0] == {0, 1})
	empty := testkit.read_binary_records(t, reads, f, nil, .Concatenated)
	testing.expect(t, len(empty.spans) == 0 && empty.err == nil)
	// A fault ends the records after those before it, as no item past it can be found.
	bad := testkit.read_binary_records(t, reads, f, testkit.hex("01 82 02 61 ff"), .Concatenated)
	testing.expect_value(t, len(bad.spans), 1)
	fault, _ := bad.err.(tape.Fault)
	testing.expect(t, fault.at == 4 && testkit.code_of(bad.err) == "invalid_utf8")
}

// The elements of the root array, definite or indefinite, are its records, and what follows the root is judged.
@(test)
elements_are_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reads, f := cbor.reads(.Cbor), cbor.as(.Cbor)
	for text in ([?]string{"83 01 a1 61 61 02 63 616263", "9f 01 a1 61 61 02 63 616263 ff"}) {
		got := testkit.read_binary_records(t, reads, f, testkit.hex(text), .Elements)
		testing.expectf(t, len(got.spans) == 3 && got.spans[0] == {1, 2} && got.spans[1] == {2, 6} && got.err == nil, "%s: %v", text, got)
	}
	empty := testkit.read_binary_records(t, reads, f, testkit.hex("80"), .Elements)
	testing.expect(t, len(empty.spans) == 0 && empty.err == nil)
	trailing := testkit.read_binary_records(t, reads, f, testkit.hex("81 01 00"), .Elements)
	testing.expect(t, len(trailing.spans) == 1 && testkit.code_of(trailing.err) == "trailing")
	not_array := testkit.read_binary_records(t, reads, f, testkit.hex("a0"), .Elements)
	testing.expect(t, len(not_array.spans) == 0 && not_array.err == tape.Error(tape.Bad_Option{"framing"}))
	inner := testkit.read_binary_records(t, reads, f, testkit.hex("82 01 61 80"), .Elements)
	testing.expect(t, len(inner.spans) == 1 && testkit.code_of(inner.err) == "invalid_utf8")
	preferred := testkit.read_binary_records(t, cbor.reads(.Preferred), cbor.as(.Preferred), testkit.hex("9f 01 ff"), .Elements)
	testing.expect(t, len(preferred.spans) == 0 && testkit.code_of(preferred.err) == "not_preferred")
}

// A tag on the root does not hide its container: the elements of a tagged array and the members of a tagged map are
// records, a tag that folds a number leaves none, and a tag whose content may not be a container ends them with the
// fault `validate` gives, at the root and under a path.
@(test)
tagged_roots_hold_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reads, f := cbor.reads(.Cbor), cbor.as(.Cbor)
	got := testkit.read_binary_records(t, reads, f, testkit.hex("d9d9f7 83 01 02 03"), .Elements)
	testing.expectf(t, len(got.spans) == 3 && got.spans[0] == {4, 5} && got.err == nil, "%v", got)
	nested := testkit.read_binary_records(t, reads, f, testkit.hex("d8 64 d9d9f7 82 01 02"), .Elements)
	testing.expectf(t, len(nested.spans) == 2 && nested.err == nil, "%v", nested)
	for text in ([]string{"c1 82 01 02", "c0 82 01 02", "d8 18 82 01 02", "d8 64 c1 82 01 02"}) {
		want := cbor.validate(testkit.hex(text))
		root := testkit.read_binary_records(t, reads, f, testkit.hex(text), .Elements)
		testing.expectf(t, len(root.spans) == 0 && root.err == want && want != nil, "%s: %v, validate %v", text, root, want)
		under := testkit.hex(fmt.tprintf("a1 61 61 %s", text))
		at := testkit.read_binary_records(t, reads, f, under, .Elements, at = {tape.Name("a")})
		testing.expectf(t, len(at.spans) == 0 && at.err == cbor.validate(under), "a: %s: %v", text, at)
	}
	members := testkit.read_binary_records(t, reads, f, testkit.hex("d9d9f7 a2 61 61 01 61 62 02"), .Members)
	testing.expectf(t, len(members.spans) == 2 && members.err == nil, "%v", members)
	number := testkit.read_binary_records(t, reads, f, testkit.hex("c4 82 20 01"), .Elements)
	testing.expectf(t, len(number.spans) == 0 && number.err == tape.Error(tape.Bad_Option{"framing"}), "%v", number)
	strict := testkit.read_binary_records(t, cbor.reads(.Preferred), cbor.as(.Preferred), testkit.hex("d8 02 83 01 02 03"), .Elements)
	testing.expect(t, len(strict.spans) == 0)
	for text in ([]string{"dc", "dd", "de", "df", "df 83 01 02 03", "d8"}) {
		for framing in ([]tape.Framing{.Elements, .Members}) {
			reserved := testkit.read_binary_records(t, reads, f, testkit.hex(text), framing)
			testing.expectf(t, len(reserved.spans) == 0, "%s: %v", text, reserved)
		}
	}
}

// The members of the root map are records, each with its key, of any kind a key has.
@(test)
members_are_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reads, f := cbor.reads(.Cbor), cbor.as(.Cbor)
	got := testkit.read_binary_records(t, reads, f, testkit.hex("a3 61 61 01 0a 82 02 03 41 ff f6"), .Members)
	testing.expect_value(t, len(got.keys), 3)
	testing.expectf(t, got.keys[0] == "a" && got.keys[1] == "10" && got.keys[2] == "/w==", "%v", got.keys)
	testing.expect(t, got.spans[1] == {5, 8} && got.err == nil)
	indefinite := testkit.read_binary_records(t, reads, f, testkit.hex("bf 61 61 01 ff"), .Members)
	testing.expect(t, len(indefinite.keys) == 1 && indefinite.err == nil)
	bad_key := testkit.read_binary_records(t, reads, f, testkit.hex("a1 80 01"), .Members)
	testing.expect(t, len(bad_key.spans) == 0 && testkit.code_of(bad_key.err) == "bad_key")
	ordered := testkit.read_binary_records(t, cbor.reads(.Deterministic), cbor.as(.Deterministic), testkit.hex("a2 61 62 01 61 61 02"), .Members)
	testing.expect(t, len(ordered.spans) == 1 && testkit.code_of(ordered.err) == "key_order")
}

// The records refuse options they cannot take before any is read.
@(test)
records_refuse_options_they_cannot_take :: proc(t: ^testing.T) {
	testkit.deadline(t)
	lines := cbor.records_open(testkit.hex("01"), .Lines)
	out: [1]tape.Record
	testing.expect(t, cbor.records_validate(&lines, out[:]) == 0 && lines.err == tape.Error(tape.Bad_Option{"framing"}))
	dups := cbor.records_open(testkit.hex("01"), opts = {dups = .Refuse})
	answers: [1]tape.Span_Answer
	testing.expect(t, cbor.records_find(&dups, {}, out[:], answers[:]) == 0 && dups.err == tape.Error(tape.Bad_Option{"dups"}))
}

// Each record's answers are those of its own bytes read alone, whole and in windows: the items of a sequence, the
// elements of a root array and the members' values of a root map, under every spec, with no limit a root's records
// share.
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
	append(&elements, 0x85)
	append(&members, 0xa5)
	for h, k in PIECE_HEX[:5] {
		append(&elements, ..testkit.hex(h))
		append(&members, 0x61, 'a' + u8(k))
		append(&members, ..testkit.hex(h))
	}
	paths := [][]tape.Step{{}, {cbor.Index(0)}, {cbor.Index(-1)}, {cbor.All{}}, {cbor.Name("a")}, {cbor.Name("b"), cbor.Name("d")}}
	texts := [?]struct {
		src:     []u8,
		framing: tape.Framing,
	}{{items[:], .Concatenated}, {elements[:], .Elements}, {members[:], .Members}}
	for text in texts {
		for spec in cbor.Spec {
			for opts in ([]cbor.Options{{}, {tolerate = {.Invalid_Utf8}}, {dups = .First}}) {
				for cuts in ([][]int{nil, {len(text.src) / 2}, {1, 2, 3}, testkit.cuts_by(len(text.src), 3), testkit.cuts_by(len(text.src), 17)}) {
					run := testkit.Piece_Run{text.src, cbor.reads(spec), cbor.as(spec), opts, cuts}
					name := fmt.tprintf("%v %v", text.framing, spec)
					if !testkit.records_alone_agree(t, run, {framing = text.framing}, paths, name) {
						return
					}
				}
			}
		}
	}
}

// The records a format picked at run time opens read as the package's.
@(test)
records_open_through_the_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := testkit.hex("01 02 03")
	r, err := cbor.reads(.Cbor).records(cbor.as(.Cbor), src, .Concatenated, {}, nil, context.allocator)
	testing.expect_value(t, err, nil)
	defer tape.destroy_records(r)
	out: [4]tape.Record
	testing.expect_value(t, tape.records_validate(r, out[:]), 0)
	testing.expect_value(t, r.index, 3)
}

// A tolerance a member's key takes is the record's: its answer reports it, as the value's own bytes would.
@(test)
members_report_the_tolerance_their_key_takes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := testkit.hex("a2 62 c328 01 61 62 02")
	r := cbor.records_open(src, .Members, opts = {tolerate = {.Invalid_Utf8}})
	out: [2]tape.Record
	answers: [2]tape.Span_Answer
	testing.expect_value(t, cbor.records_find(&r, {}, out[:], answers[:]), 2)
	testing.expect_value(t, r.err, nil)
	testing.expect(t, answers[0].tolerated && !answers[1].tolerated)
}

// A path takes as many steps as the text nests, each container of the framing held in memory past its first few, in
// a whole text and in one cut at every byte.
@(test)
records_at_a_long_path_read_through_every_step :: proc(t: ^testing.T) {
	testkit.deadline(t)
	DEPTH :: 100
	src := make([dynamic]u8, context.temp_allocator)
	path := make([dynamic]tape.Step, context.temp_allocator)
	for k in 0 ..< DEPTH {
		if k % 2 == 0 {
			append(&src, 0xa2, 0x61, 'z', 0x01, 0x61, 'k')
			append(&path, tape.Name("k"))
		} else {
			append(&src, 0x82, 0x00)
			append(&path, tape.Index(1))
		}
	}
	append(&src, 0x83, 0x01, 0x02, 0x03)
	got := testkit.read_binary_records(t, cbor.reads(.Cbor), cbor.as(.Cbor), src[:], .Elements, at = path[:])
	testing.expectf(t, len(got.spans) == 3 && got.spans[0] == {u64(len(src)) - 3, u64(len(src)) - 2} && got.err == nil, "%v", got)
	singles := make([]int, len(src) - 1, context.temp_allocator)
	cuts_list := make([][]int, len(src) - 1, context.temp_allocator)
	for cut in 1 ..< len(src) {
		singles[cut - 1] = cut
		cuts_list[cut - 1] = singles[cut - 1:cut]
	}
	run := testkit.Piece_Run{src[:], cbor.reads(.Cbor), cbor.as(.Cbor), {}, nil}
	testkit.records_pieces_agree_cuts(t, run, cuts_list, .Elements, nil, nil, "long path", path[:])
}

// A fault early in a window that more bytes follow ends the records there, and the window's caller keeps none of the
// text past it.
@(test)
records_in_pieces_end_at_a_fault_the_window_holds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := make([dynamic]u8, context.temp_allocator)
	append(&src, 0x01, 0x1c)
	for _ in 0 ..< 4096 {
		append(&src, 0x02)
	}
	p := tape.Pieces{allocator = context.allocator}
	defer tape.destroy(&p)
	r := cbor.records_open(src[:], .Concatenated, .Cbor, {pieces = &p})
	defer tape.destroy_records(&r)
	out: [4]tape.Record
	n := cbor.records_validate(&r, out[:])
	f, faulted := r.err.(tape.Fault)
	testing.expectf(t, faulted && f.at == 1 && !p.more && n == 0 && r.index == 1, "%d records of %d, %v, more %v keep %v", n, r.index, r.err, p.more, p.keep)
}

// A value off the path that the windows cut is passed a child at a time, nested values too, so each window's caller
// keeps only the child its end cuts.
@(test)
records_in_pieces_keep_only_the_child_a_window_cuts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	WINDOW :: 12
	src := make([dynamic]u8, context.temp_allocator)
	append(&src, 0xa2, 0x61, 's', 0x99, 0x01, 0x2c)
	for _ in 0 ..< 300 {
		append(&src, 0x82, 0x01, 0xa1, 0x61, 'b', 0x82, 0x02, 0x03)
	}
	append(&src, 0x61, 'a', 0x83, 0x01, 0x02, 0x03)
	p := tape.Pieces{allocator = context.allocator}
	defer tape.destroy(&p)
	r := cbor.records_open(src[:WINDOW], .Elements, .Cbor, {pieces = &p}, {tape.Name("a")})
	defer tape.destroy_records(&r)
	out: [4]tape.Record
	records, kept := 0, u64(0)
	for {
		records += cbor.records_validate(&r, out[:])
		if !p.more {
			break
		}
		kept = max(kept, p.at - p.keep)
		end := min(p.at + WINDOW, u64(len(src)))
		p.from, p.last = p.keep, end == u64(len(src))
		testing.expect_value(t, tape.records_window(&r, src[p.keep:end]), nil)
	}
	testing.expectf(t, r.err == nil && r.index == 3 && records == 0 && kept < WINDOW, "%d records, %v, kept %d", r.index, r.err, kept)
	// A count the text does not reach is refused at its head, before a fault in the container, at every cut.
	for text in ([]string{"a2 61 73 99 01 2c 82 01 ff 61 61 83 01 02 03", "a2 61 73 99 01 2c 82 01 02 61 61 83 01 02 03", "a2 61 73 83 82 01 02 01 02 61 61 83 01 02 03"}) {
		bad := testkit.hex(text)
		every := make([]int, len(bad) - 1, context.temp_allocator)
		cuts_list := make([dynamic][]int, 0, len(bad), context.temp_allocator)
		for cut in 1 ..< len(bad) {
			every[cut - 1] = cut
			append(&cuts_list, every[cut - 1:cut])
		}
		append(&cuts_list, every)
		run := testkit.Piece_Run{bad, cbor.reads(.Cbor), cbor.as(.Cbor), {}, nil}
		if !testkit.records_pieces_agree_cuts(t, run, cuts_list[:], .Elements, nil, nil, text, {tape.Name("a")}) {
			return
		}
	}
}
