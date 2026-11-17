// The records of a CBOR text and its `.Entries`.
package cbor_tests

import "core:bytes"
import "core:fmt"
import "core:slice"
import "core:testing"
import core "../../core"
import host "../../host"
import records "../../core/records"
import testkit "../../testkit"
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
		testkit.expect_nil(t, err)
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
	testkit.expect_nil(t, perr)
	wr: records.Writer
	testing.expect_value(t, cbor.writer_init(&wr, {}, .Cbor), core.Typed_Error_Kind.None)
	testing.expect_value(t, records.write(&wr, Row{1}, &plan), core.Typed_Error_Kind.None)
	testing.expect_value(t, records.write(&wr, Row{300}, &plan), core.Typed_Error_Kind.None)
	text, werr := records.writer_end(&wr)
	testkit.expect_nil(t, werr)
	testing.expect_value(t, hex_of(text), "a162696401a162696419012c")
}

// `.Entries` gives the items of a root array and the values of a map's members, with each key's bytes, and a fault
// ends the records at the byte `validate` gives, after the members before it.
@(test)
entries_are_the_members_of_a_container :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	array := "\x83\x01\xa1aa\x02cabc"
	testkit.expect_entries(t, array, cbor.as(.Cbor), nil, "1  1\n2  {\"a\":2}\n6  \"abc\"\nend")
	named := "\xa2al\x82\x01\x02am\x00"
	testkit.expect_entries(t, named, cbor.as(.Cbor), {"l"}, "4  1\n5  2\nend")
	testkit.expect_entries(t, named, cbor.as(.Cbor), nil, "3 l [1,2]\n8 m 0\nend")
	testkit.expect_entries(t, named, cbor.as(.Deterministic), {"l"}, "4  1\n5  2\nend")
	unordered := "\xa3al\x82\x01\x02an\x01am\x00"
	late, _ := testkit.fault_in(cbor.validate(transmute([]u8)unordered, .Deterministic))
	testkit.expect_entries(t, unordered, cbor.as(.Deterministic), nil, fmt.tprintf("3 l [1,2]\n8 n 1\nfault %d", late.at))
	testkit.expect_framings(t, cbor.CAPABILITIES, cbor.as(.Cbor))
	bad := "\x82\x01\x1c"
	fault, _ := testkit.fault_in(cbor.validate(transmute([]u8)bad, .Cbor))
	testkit.expect_entries(t, bad, cbor.as(.Cbor), nil, fmt.tprintf("1  1\nfault %d", fault.at))
	it := cbor.records_open(transmute([]u8)array, .Cbor, framing = .Entries)
	testing.expect_value(t, testkit.entries_lines(&it), "1  1\n2  {\"a\":2}\n6  \"abc\"\nend")
}

// Reading the items of an array ten times as long under `.Entries` holds no more of the reader's memory at its peak,
// from a stream too: the cursor follows the window, which keeps no more than an item past the last record.
@(test)
entries_hold_one_member :: proc(t: ^testing.T) {
	item := "\xa2bidcabcdtagsx\x64" + "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
	testkit.expect_entries_bounded(t, cbor.as(.Cbor), nil, "\x9f", item, "\xff", true)
}

// A reader reads each member under `.Entries` into a value, opened by handle or by constant spec.
@(test)
entries_read_into_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	src := hex("83 01 02 03")
	plan, perr := cbor.plan_make(i32)
	testkit.expect_nil(t, perr)
	for reader in ([2]records.Reader{records.open(src, cbor.as(.Cbor), framing = .Entries), cbor.records_open(src, .Cbor, framing = .Entries)}) {
		it := reader
		defer records.close(&it)
		for want in 1 ..= 3 {
			v: i32
			err, more := records.read(&it, &v, &plan)
			testkit.expect_nil(t, err)
			testing.expect(t, more)
			testing.expect_value(t, int(v), want)
		}
		v: i32
		_, more := records.read(&it, &v, &plan)
		testing.expect(t, !more && it.fault == nil)
	}
}

// A sequence's items read into values under `.Concatenated`, by handle or by constant spec, with a refused item
// returned and passed over, a repeated key refused under `.Refuse`, and a fault ending the records after the items
// before it.
@(test)
sequence_items_read_into_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Pair :: struct {
		a: i32,
		b: string,
	}
	plan, perr := cbor.plan_make(Pair)
	testkit.expect_nil(t, perr)
	// {a: 1, b: "x"}, {a: "no"} (refused), {a: 3}
	src := hex("a2 6161 01 6162 6178  a1 6161 626e6f  a1 6161 03")
	for reader in ([2]records.Reader{records.open(src, cbor.as(.Cbor), .Concatenated), cbor.records_open(src, .Cbor)}) {
		it := reader
		defer records.close(&it)
		if it.docs == nil {
			it.docs = cbor.record_docs(.Cbor)
		}
		v: Pair
		err, more := records.read(&it, &v, &plan, {borrow_strings = true})
		testkit.expect_nil(t, err)
		testing.expect(t, more)
		testing.expect_value(t, v, Pair{1, "x"})
		v = {}
		err, more = records.read(&it, &v, &plan)
		testing.expect(t, err != nil && more)
		if typed, is_typed := err.(core.Typed_Error); is_typed {
			testing.expect_value(t, typed.kind, core.Typed_Error_Kind.Wrong_Kind)
			testing.expect_value(t, typed.at, u64(12))
		} else {
			testing.expect(t, false, "a typed refusal")
		}
		v = {}
		err, more = records.read(&it, &v, &plan)
		testkit.expect_nil(t, err)
		testing.expect_value(t, v, Pair{a = 3})
		_, more = records.read(&it, &v, &plan)
		testing.expect(t, !more && it.fault == nil)
	}
	faulted := hex("a1 6161 01 1c")
	it := records.open(faulted, cbor.as(.Cbor), .Concatenated)
	defer records.close(&it)
	v: Pair
	err, more := records.read(&it, &v, &plan)
	testkit.expect_nil(t, err)
	testing.expect(t, more)
	_, more = records.read(&it, &v, &plan)
	testing.expect(t, !more && it.fault != nil)
	repeated := hex("a2 6161 01 6161 02  a1 6161 03")
	again := records.open(repeated, cbor.as(.Cbor), .Concatenated)
	defer records.close(&again)
	err, more = records.read(&again, &v, &plan, {dups = .Refuse})
	testing.expect(t, err != nil && more)
	err, more = records.read(&again, &v, &plan, {dups = .Refuse})
	testkit.expect_nil(t, err)
	testing.expect(t, more)
	testing.expect_value(t, v.a, 3)
}

// A sequence read in pieces on threads against the same sequence read on one: the same faults at the same bytes, at every
// width. The tests cut pieces of a few bytes, so each starts inside an item, where its bytes read as other items.
@(test)
records_validate_on_threads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pools: [3]host.Pool
	for w, i in ([3]int{2, 6, 18}) {
		host.pool_init(&pools[i], w)
	}
	defer for &p in pools {
		host.pool_destroy(&p)
	}
	item := hex("a3 6474696d65 1a00010203 636d7367 6b68656c6c6f20776f726c64 6474616773 83 61 61 f5 9f 01 02 ff")
	src := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< 24 {
		append(&src, ..item)
	}
	breakers := hex("ff 1c 9b 7a 61 c3")
	buf := make([]u8, len(src), context.temp_allocator)
	for i in -1 ..< len(src) {
		for b in breakers {
			copy(buf, src[:])
			if i >= 0 {
				buf[i] = b
			}
			serial, _ := records.validate(buf, cbor.as(.Cbor), .Concatenated, context.temp_allocator)
			whole := records.validate_parallel(buf, cbor.as(.Cbor))
			for &pool in pools {
				got, _ := records.validate(buf, cbor.as(.Cbor), .Concatenated, context.temp_allocator, &pool.runner)
				if !testing.expectf(t, slice.equal(got, serial), "%d %x at width %d: %v, want %v", i, b, pool.runner.threads + 1, got, serial) {
					return
				}
				if v := records.validate_parallel(buf, cbor.as(.Cbor), &pool.runner); !testing.expectf(t, v == whole, "%d %x at width %d: %v, want %v", i, b, pool.runner.threads + 1, v, whole) {
					return
				}
			}
			if i < 0 {
				break
			}
		}
	}
}
