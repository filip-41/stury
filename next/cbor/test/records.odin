package cbor_tests

import "core:fmt"
import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"

// The records of a CBOR text: the items of a sequence, the elements of the root array and the members of the root map.

// The records of `src` under `framing`, each read with every read: their spans and keys, and the error that ended them.
Records_Read :: struct {
	spans: [][2]u64,
	keys:  []string,
	err:   tape.Error,
}

read_records :: proc(t: ^testing.T, src: []u8, framing: tape.Framing, spec := cbor.Spec.Cbor, opts := cbor.Options{}, loc := #caller_location) -> (got: Records_Read) {
	spans := make([dynamic][2]u64, context.temp_allocator)
	keys := make([dynamic]string, context.temp_allocator)
	r := cbor.records_open(src, framing, spec, opts)
	out: [2]tape.Record
	for {
		n := cbor.records_validate(&r, out[:])
		for rec in out[:n] {
			testing.expectf(t, rec.err == nil, "record %d: %v", rec.index, rec.err, loc = loc)
			append(&spans, [2]u64{rec.lo, rec.hi})
			if framing == .Members {
				buf: [64]u8
				key, _ := cbor.node_text(cbor.as(spec), src, rec.key, buf[:])
				append(&keys, clone_text(key))
			}
		}
		if n < len(out) {
			break
		}
	}
	got = {spans[:], keys[:], r.err}
	// Find and scan read the same records, each answering as a read of its bytes alone.
	f := cbor.records_open(src, framing, spec, opts)
	answers: [1]tape.Span_Answer
	fout: [1]tape.Record
	k := 0
	for cbor.records_find(&f, {}, fout[:], answers[:]) == 1 {
		testing.expectf(t, k < len(spans) && fout[0].lo == spans[k][0] && fout[0].hi == spans[k][1], "find record %d: %v", k, fout[0], loc = loc)
		testing.expectf(t, answers[0].lo == fout[0].lo && answers[0].hi == fout[0].hi, "find answer %d: %v", k, answers[0], loc = loc)
		k += 1
	}
	testing.expectf(t, k == len(spans) && testkit.same_refusal(f.err, r.err), "find: %d records, %v", k, f.err, loc = loc)
	demand, _ := tape.demand_of([][]tape.Step{{}}, allocator = context.temp_allocator)
	s := cbor.records_open(src, framing, spec, opts)
	docs: [1]tape.Document
	k = 0
	for cbor.records_scan(&s, &demand, fout[:], docs[:], {}, context.temp_allocator) == 1 {
		whole, _ := cbor.build(src[fout[0].lo:fout[0].hi], spec, opts, context.temp_allocator)
		testing.expectf(t, len(docs[0].nodes) == len(whole.nodes), "scan record %d: %d nodes, %d", k, len(docs[0].nodes), len(whole.nodes), loc = loc)
		k += 1
	}
	testing.expectf(t, k == len(spans) && testkit.same_refusal(s.err, r.err), "scan: %d records, %v", k, s.err, loc = loc)
	return
}

clone_text :: proc(s: string) -> string {
	b := make([]u8, len(s), context.temp_allocator)
	copy(b, s)
	return string(b)
}

// A sequence (RFC 8742) reads as its items, one record each, and a binary text has no byte order mark to skip.
@(test)
sequences_read_as_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got := read_records(t, hex("01 82 02 03 61 61"), .Concatenated)
	testing.expect_value(t, len(got.spans), 3)
	testing.expect(t, got.spans[1] == {1, 4} && got.spans[2] == {4, 6} && got.err == nil)
	// A byte order mark reads as simple value 15, then a map head cut short.
	bom := read_records(t, hex("ef bb bf 01"), .Concatenated)
	testing.expect_value(t, code_of(bom.err), "truncated")
	testing.expect(t, len(bom.spans) == 1 && bom.spans[0] == {0, 1})
	empty := read_records(t, nil, .Concatenated)
	testing.expect(t, len(empty.spans) == 0 && empty.err == nil)
	// A fault ends the records after those before it, as no item past it can be found.
	bad := read_records(t, hex("01 82 02 61 ff"), .Concatenated)
	testing.expect_value(t, len(bad.spans), 1)
	f, _ := bad.err.(tape.Fault)
	testing.expect(t, f.at == 4 && code_of(bad.err) == "invalid_utf8")
}

// The elements of the root array, definite or indefinite, are its records, and what follows the root is judged.
@(test)
elements_are_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for text in ([?]string{"83 01 a1 61 61 02 63 616263", "9f 01 a1 61 61 02 63 616263 ff"}) {
		got := read_records(t, hex(text), .Elements)
		testing.expectf(t, len(got.spans) == 3 && got.spans[0] == {1, 2} && got.spans[1] == {2, 6} && got.err == nil, "%s: %v", text, got)
	}
	empty := read_records(t, hex("80"), .Elements)
	testing.expect(t, len(empty.spans) == 0 && empty.err == nil)
	trailing := read_records(t, hex("81 01 00"), .Elements)
	testing.expect(t, len(trailing.spans) == 1 && code_of(trailing.err) == "trailing")
	not_array := read_records(t, hex("a0"), .Elements)
	testing.expect(t, len(not_array.spans) == 0 && not_array.err == nil)
	inner := read_records(t, hex("82 01 61 80"), .Elements)
	testing.expect(t, len(inner.spans) == 1 && code_of(inner.err) == "invalid_utf8")
	preferred := read_records(t, hex("9f 01 ff"), .Elements, .Preferred)
	testing.expect(t, len(preferred.spans) == 0 && code_of(preferred.err) == "not_preferred")
}

// A tag on the root does not hide its container: the elements of a tagged array and the members of a tagged map are
// records, and a tag that folds a number leaves none.
@(test)
tagged_roots_hold_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got := read_records(t, hex("d9d9f7 83 01 02 03"), .Elements)
	testing.expectf(t, len(got.spans) == 3 && got.spans[0] == {4, 5} && got.err == nil, "%v", got)
	nested := read_records(t, hex("c1 d8 18 82 01 02"), .Elements)
	testing.expectf(t, len(nested.spans) == 2 && nested.err == nil, "%v", nested)
	members := read_records(t, hex("d9d9f7 a2 61 61 01 61 62 02"), .Members)
	testing.expectf(t, len(members.spans) == 2 && members.err == nil, "%v", members)
	number := read_records(t, hex("c4 82 20 01"), .Elements)
	testing.expectf(t, len(number.spans) == 0 && number.err == nil, "%v", number)
	strict := read_records(t, hex("d8 02 83 01 02 03"), .Elements, .Preferred)
	testing.expect(t, len(strict.spans) == 0)
	for text in ([]string{"dc", "dd", "de", "df", "df 83 01 02 03", "d8"}) {
		for framing in ([]tape.Framing{.Elements, .Members}) {
			reserved := read_records(t, hex(text), framing)
			testing.expectf(t, len(reserved.spans) == 0, "%s: %v", text, reserved)
		}
	}
}

// The members of the root map are records, each with its key, of any kind a key has.
@(test)
members_are_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got := read_records(t, hex("a3 61 61 01 0a 82 02 03 41 ff f6"), .Members)
	testing.expect_value(t, len(got.keys), 3)
	testing.expectf(t, got.keys[0] == "a" && got.keys[1] == "10" && got.keys[2] == "/w==", "%v", got.keys)
	testing.expect(t, got.spans[1] == {5, 8} && got.err == nil)
	indefinite := read_records(t, hex("bf 61 61 01 ff"), .Members)
	testing.expect(t, len(indefinite.keys) == 1 && indefinite.err == nil)
	bad_key := read_records(t, hex("a1 80 01"), .Members)
	testing.expect(t, len(bad_key.spans) == 0 && code_of(bad_key.err) == "bad_key")
	ordered := read_records(t, hex("a2 61 62 01 61 61 02"), .Members, .Deterministic)
	testing.expect(t, len(ordered.spans) == 1 && code_of(ordered.err) == "key_order")
}

// The records refuse options they cannot take before any is read.
@(test)
records_refuse_options_they_cannot_take :: proc(t: ^testing.T) {
	testkit.deadline(t)
	lines := cbor.records_open(hex("01"), .Lines)
	out: [1]tape.Record
	testing.expect(t, cbor.records_validate(&lines, out[:]) == 0 && lines.err == tape.Error(tape.Bad_Option{"framing"}))
	pieces: tape.Pieces
	piece := cbor.records_open(hex("81 01"), .Elements, opts = {pieces = &pieces})
	testing.expect(t, cbor.records_validate(&piece, out[:]) == 0 && piece.err == tape.Error(tape.Bad_Option{"pieces"}))
	dups := cbor.records_open(hex("01"), opts = {dups = .Refuse})
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
		append(&items, ..hex(h))
	}
	elements := make([dynamic]u8, context.temp_allocator)
	members := make([dynamic]u8, context.temp_allocator)
	append(&elements, 0x85)
	append(&members, 0xa5)
	for h, k in PIECE_HEX[:5] {
		append(&elements, ..hex(h))
		append(&members, 0x61, 'a' + u8(k))
		append(&members, ..hex(h))
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
	src := hex("01 02 03")
	r, err := cbor.reads(.Cbor).records(cbor.as(.Cbor), src, .Concatenated, {}, context.allocator)
	testing.expect_value(t, err, nil)
	defer tape.destroy_records(r)
	out: [4]tape.Record
	testing.expect_value(t, tape.records_validate(r, out[:]), 3)
}

// A tolerance a member's key takes is the record's: its answer reports it, as the value's own bytes would.
@(test)
members_report_the_tolerance_their_key_takes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := hex("a2 62 c328 01 61 62 02")
	r := cbor.records_open(src, .Members, opts = {tolerate = {.Invalid_Utf8}})
	out: [2]tape.Record
	answers: [2]tape.Span_Answer
	testing.expect_value(t, cbor.records_find(&r, {}, out[:], answers[:]), 2)
	testing.expect_value(t, r.err, nil)
	testing.expect(t, answers[0].tolerated && !answers[1].tolerated)
}
