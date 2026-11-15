// The records of a CBOR text and its `.Entries`.
package cbor_tests

import "core:bytes"
import "core:fmt"
import "core:testing"
import core "../../core"
import records "../../core/records"
import walktest "../../walktest"
import cbor ".."

// The record entry points bind CBOR's framing: a reader frames and judges each item, builds one once it holds the
// record reads, and a writer puts nothing between the items.
@(test)
record_entry_points_bind_the_framing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	src := hex("a1 6161 01 82 02 03 6161")
	it := cbor.records_open(src, .Cbor)
	defer records.close(&it)
	it.docs = cbor.record_docs(.Cbor)
	count := 0
	for rec in records.next(&it) {
		doc, err := records.build(&it, rec)
		walktest.expect_nil(t, err)
		testing.expect_value(t, core.span(&doc, core.ROOT)[0], rec.text[0])
		count += 1
	}
	testing.expect_value(t, count, 3)
	testing.expect(t, it.fault == nil)
	faults, failed := cbor.records_validate(hex("01 82 02"), .Cbor)
	testing.expect(t, failed == nil)
	testing.expect_value(t, len(faults), 1)
	other := cbor.records_open(src, .Cbor, framing = .Lines)
	defer records.close(&other)
	_, any := records.next(&other)
	testing.expect(t, !any && other.fault != nil)

	// A stream gives its items through a window that grows to hold a whole one.
	long := make([dynamic]u8, context.temp_allocator)
	for i in 0 ..< 30000 {
		append(&long, 0x83, 0x19, u8(i >> 8), u8(i), 0x63, 'a', 'b', 'c', 0xf5)
	}
	input: bytes.Reader
	stream := cbor.records_open_stream(bytes.reader_init(&input, long[:]), .Cbor)
	defer records.close(&stream)
	streamed := 0
	for rec in records.next(&stream) {
		testing.expect(t, len(rec.text) == 9 && rec.text[1] == 0x19 && int(rec.text[2]) << 8 | int(rec.text[3]) == streamed)
		streamed += 1
	}
	testing.expect_value(t, streamed, 30000)
	testing.expect(t, stream.fault == nil)

	Row :: struct {
		id: int,
	}
	plan, perr := cbor.plan_make(Row)
	walktest.expect_nil(t, perr)
	wr: records.Writer
	testing.expect_value(t, cbor.writer_init(&wr, {}, .Cbor), core.Typed_Error_Kind.None)
	testing.expect_value(t, records.write(&wr, Row{1}, &plan), core.Typed_Error_Kind.None)
	testing.expect_value(t, records.write(&wr, Row{300}, &plan), core.Typed_Error_Kind.None)
	text, werr := records.writer_end(&wr)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, hex_of(text), "a162696401a162696419012c")
}

// `.Entries` gives the items of a root array and the values of a map's members, with each key's bytes, and a fault
// ends the records at the byte `validate` gives, after the members before it.
@(test)
entries_are_the_members_of_a_container :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	array := "\x83\x01\xa1aa\x02cabc"
	walktest.expect_entries(t, array, cbor.as(.Cbor), nil, "1  1\n2  {\"a\":2}\n6  \"abc\"\nend")
	named := "\xa2al\x82\x01\x02am\x00"
	walktest.expect_entries(t, named, cbor.as(.Cbor), {"l"}, "4  1\n5  2\nend")
	walktest.expect_entries(t, named, cbor.as(.Cbor), nil, "3 l [1,2]\n8 m 0\nend")
	walktest.expect_entries(t, named, cbor.as(.Deterministic), {"l"}, "4  1\n5  2\nend")
	unordered := "\xa3al\x82\x01\x02an\x01am\x00"
	late, _ := walktest.fault_in(cbor.validate(transmute([]u8)unordered, .Deterministic))
	walktest.expect_entries(t, unordered, cbor.as(.Deterministic), nil, fmt.tprintf("3 l [1,2]\n8 n 1\nfault %d", late.at))
	walktest.expect_framings(t, cbor.CAPABILITIES, cbor.as(.Cbor))
	bad := "\x82\x01\x1c"
	fault, _ := walktest.fault_in(cbor.validate(transmute([]u8)bad, .Cbor))
	walktest.expect_entries(t, bad, cbor.as(.Cbor), nil, fmt.tprintf("1  1\nfault %d", fault.at))
	it := cbor.records_open(transmute([]u8)array, .Cbor, framing = .Entries)
	testing.expect_value(t, walktest.entries_lines(&it), "1  1\n2  {\"a\":2}\n6  \"abc\"\nend")
}

// Reading the items of an array ten times as long under `.Entries` holds no more of the reader's memory at its peak,
// from a stream too: the cursor follows the window, which keeps no more than an item past the last record.
@(test)
entries_hold_one_member :: proc(t: ^testing.T) {
	item := "\xa2bidcabcdtagsx\x64" + "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
	walktest.expect_entries_bounded(t, cbor.as(.Cbor), nil, "\x9f", item, "\xff", true)
}
