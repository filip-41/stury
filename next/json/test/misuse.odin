package json_tests

import "base:runtime"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import cw "../../core/write"
import records "../../core/records"
import json ".."

// Calls with a zero document, a nil plan or services, or a cursor past the input return an error and read nothing.

@(test)
a_zero_document_is_refused :: proc(t: ^testing.T) {
	zero: core.Document
	_, qerr := core.query(&zero, core.Path{})
	testing.expect_value(t, qerr.kind, core.Path_Error_Kind.Unsupported)
	_, _, cerr := core.commit(&core.Edit_List{doc = &zero})
	testing.expect_value(t, cerr.kind, core.Document_Error_Kind.Bad_Index)
	_, _, jerr := json.commit(&core.Edit_List{doc = &zero}, .Json)
	testing.expect_value(t, jerr.kind, core.Document_Error_Kind.Bad_Index)
}

@(test)
a_nil_plan_is_refused :: proc(t: ^testing.T) {
	_, err := cw.marshal(1, nil)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Unsupported)
	wr: records.Writer
	testing.expect_value(t, records.write(&wr, 1, nil), core.Typed_Error_Kind.Plan_Mismatch)
}

@(test)
records_past_the_input_or_without_services_are_refused :: proc(t: ^testing.T) {
	src := transmute([]u8)string("1\n2\n")
	it := records.open(src, json.as(.Json), at = 100)
	defer records.close(&it)
	_, more := records.next(&it)
	testing.expect(t, !more)
	f, faulted := it.fault.?
	testing.expect(t, faulted && f.kind == .Bad_Option)
	bare := records.open(src, {})
	defer records.close(&bare)
	_, err := records.build(&bare, {text = src})
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Bad_Index)
}

// Remembers the largest request made through it.
@(private = "file")
Largest :: struct {
	inner: runtime.Allocator,
	size:  int,
}

@(private = "file")
largest_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	l := (^Largest)(data)
	l.size = max(l.size, size)
	return l.inner.procedure(l.inner.data, mode, size, alignment, old, old_size, loc)
}

// A depth limit of a billion asks for room by the text's own depth, never by the limit.
@(test)
a_huge_depth_limit_reserves_by_the_input :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	big := Largest{inner = context.allocator}
	alloc := runtime.Allocator{largest_proc, &big}
	src := transmute([]u8)string("[1]")
	opts := json.Options{max_depth = 1 << 30}
	doc, err := json.build(src, .Json, opts, false, alloc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	text, _, werr := core.write(&doc, allocator = alloc)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	delete(text, alloc)
	core.destroy(&doc)
	one, _ := core.parse_path(".[0]", context.temp_allocator)
	two, _ := core.parse_path(".[0]..", context.temp_allocator)
	for paths in ([][]core.Path{{one}, {one, two}}) {
		scanned, perr := json.scan(src, .Json, paths, opts = opts, allocator = alloc)
		testing.expect_value(t, perr.kind, core.Path_Error_Kind.None)
		core.destroy(&scanned)
	}
	n: [1]i32
	testing.expect_value(t, json.unmarshal(src, json.Spec.Json, &n, {}, opts, alloc).kind, core.Typed_Error_Kind.None)
	as := json.as(.Json)
	as.max_depth = 1 << 30
	it := records.open(src, as, allocator = alloc)
	defer records.close(&it)
	plan, _ := json.plan_make([1]i32, allocator = context.temp_allocator)
	defer typed.plan_destroy(&plan)
	_, rerr := records.read(&it, &n, &plan)
	testing.expect_value(t, rerr.kind, core.Typed_Error_Kind.None)
	testing.expect(t, big.size < 1 << 20, "largest request was too large")
	testing.expect_value(t, json.validate(src, .Json, opts) == nil, true)
}
