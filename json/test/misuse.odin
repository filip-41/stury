package json_tests

import "base:runtime"
import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import cw "../../core/write"
import records "../../core/records"
import json ".."
import walktest "../../walktest"

// Calls with a zero document, a nil plan or services, or a cursor past the input return an error and read nothing.

@(test)
a_zero_document_is_refused :: proc(t: ^testing.T) {
	zero: core.Document
	_, qerr := json.query(&zero, core.Path{})
	walktest.expect_kind(t, qerr, core.Path_Error_Kind.Unsupported)
	_, _, cerr := compose.commit(&core.Edit_List{doc = &zero})
	walktest.expect_kind(t, cerr, core.Document_Error_Kind.Bad_Index)
	_, _, jerr := compose.commit(&core.Edit_List{doc = &zero}, json.as(.Json))
	walktest.expect_kind(t, jerr, core.Document_Error_Kind.Bad_Index)
}

@(test)
a_member_insert_without_edit_services_is_refused :: proc(t: ^testing.T) {
	doc, err := json.build(transmute([]u8)string(`{"a":1}`), .Json)
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	list.edit = nil
	walktest.expect_kind(t, cw.insert(&list, core.ROOT, 1, "b", typed.Raw("2")), core.Document_Error_Kind.Wrong_Container)
}

@(test)
a_nil_plan_is_refused :: proc(t: ^testing.T) {
	_, err := cw.marshal(1, nil)
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Unsupported)
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
	walktest.expect_kind(t, err, core.Document_Error_Kind.Bad_Index)
	// A reader no `open` made reads nothing.
	zero: records.Reader
	_, more = records.next(&zero)
	_, _, _, scanned := records.scan(&zero, {})
	f, faulted = zero.fault.?
	testing.expect(t, !more && !scanned && faulted && f.kind == .Bad_Option && records.column(&zero, "a") == -1)
	records.close(&zero)
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
	doc, err := core.build(src, json.as(.Json, opts), .Last, alloc)
	walktest.expect_nil(t, err)
	text, _, werr := core.write(&doc, allocator = alloc)
	walktest.expect_nil(t, werr)
	delete(text, alloc)
	core.destroy(&doc)
	one, _ := core.parse_path(".[0]", context.temp_allocator)
	two, _ := core.parse_path(".[0]..", context.temp_allocator)
	for paths in ([][]core.Path{{one}, {one, two}}) {
		scanned, perr := json.scan(src, .Json, paths, opts = opts, allocator = alloc)
		walktest.expect_nil(t, perr)
		core.destroy(&scanned)
	}
	n: [1]i32
	walktest.expect_nil(t, json.unmarshal(src, json.Spec.Json, &n, read = {}, opts = opts, allocator = alloc))
	as := json.as(.Json)
	as.max_depth = 1 << 30
	it := records.open(src, as, allocator = alloc)
	defer records.close(&it)
	plan, _ := json.plan_make([1]i32, allocator = context.temp_allocator)
	defer typed.plan_destroy(&plan)
	rerr, _ := records.read(&it, &n, &plan)
	walktest.expect_nil(t, rerr)
	testing.expect(t, big.size < 1 << 20, "largest request was too large")
	testing.expect_value(t, walktest.fault_of(json.validate(src, .Json, opts)) == nil, true)
}
