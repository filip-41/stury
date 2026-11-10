package dsv_tests

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import write "../../core/write"
import dsv ".."
import walktest "../../walktest"

// Edits over a delimited text: a cell's text, a record's line, the table's columns and the comment lines, which a commit
// decides from the whole list. Each case records its ops on a list over `src`, commits, and expects `want` and the count
// of dropped facts. A case with `fail` expects the first op or the commit to refuse with that kind.

@(private = "file")
Op_Kind :: enum {
	Set,
	Insert,
	Add,
	Remove,
	Member,
	Fact,
	Unfact,
	Facts,
}

@(private = "file")
Op :: struct {
	kind: Op_Kind,
	node: core.Node_Index,
	at:   int,
	role: core.Role,
	a, b: string,
}

@(private = "file")
Edit_Case :: struct {
	src, want: string,
	spec:      dsv.Spec,
	opts:      dsv.Options,
	ops:       []Op,
	fail:      core.Document_Error_Kind,
	dropped:   int,
}

@(private = "file")
put :: proc(node: core.Node_Index, text: string) -> Op {
	return {kind = .Set, node = node, a = text}
}

@(private = "file")
ins :: proc(node: core.Node_Index, at: int, text: string) -> Op {
	return {kind = .Insert, node = node, at = at, a = text}
}

@(private = "file")
add :: proc(node: core.Node_Index, at: int, name, text: string) -> Op {
	return {kind = .Add, node = node, at = at, a = name, b = text}
}

@(private = "file")
drop :: proc(node: core.Node_Index) -> Op {
	return {kind = .Remove, node = node}
}

@(private = "file")
drops :: proc(nodes: ..core.Node_Index) -> []Op {
	ops := make([]Op, len(nodes), context.temp_allocator)
	for n, i in nodes {
		ops[i] = drop(n)
	}
	return ops
}

@(private = "file")
fact :: proc(node: core.Node_Index, role: core.Role, text: string) -> Op {
	return {kind = .Fact, node = node, role = role, a = text}
}

@(private = "file")
apply :: proc(list: ^core.Edit_List, op: Op) -> core.Error {
	switch op.kind {
	case .Set:
		return write.set(list, op.node, typed.Raw(op.a))
	case .Insert:
		return write.insert(list, op.node, op.at, typed.Raw(op.a))
	case .Add:
		return write.insert(list, op.node, op.at, op.a, typed.Raw(op.b))
	case .Remove:
		return core.remove(list, op.node)
	case .Member:
		return write.set_member(list, op.node, op.a, typed.Raw(op.b))
	case .Fact:
		return core.set_fact(list, op.node, op.role, op.a)
	case .Facts:
		return core.set_facts(list, op.node, op.role, strings.split(op.a, "|", context.temp_allocator), padded = true)
	case .Unfact:
		return core.remove_fact(list, op.node, op.role)
	}
	return {}
}

@(private = "file")
expect_edits :: proc(t: ^testing.T, cases: []Edit_Case) {
	for c in cases {
		if !run_edit(t, c) {
			return
		}
	}
}

@(private = "file")
run_edit :: proc(t: ^testing.T, c: Edit_Case) -> bool {
	doc, err := build_any(c.src, c.spec, c.opts)
	defer core.destroy(&doc)
	if !testing.expectf(t, err == nil, "%q: build %v", c.src, err) {
		return false
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	got: core.Error
	for op in c.ops {
		if got = apply(&list, op); got != nil {
			break
		}
	}
	out: []u8
	dropped: int
	if got == nil {
		out, dropped, got = compose.commit(&list)
	}
	defer if len(out) > 0 {
		delete(out)
	}
	if !testing.expectf(t, (c.fail == .None ? got == nil : walktest.expect_kind(t, got, c.fail)), "%q %v: %v, want %v", c.src, c.ops, got, c.fail) || c.fail != .None {
		return c.fail != .None
	}
	if !testing.expectf(t, string(out) == c.want && dropped == c.dropped, "%q %v: committed %q with %d dropped, want %q with %d", c.src, c.ops, out, dropped, c.want, c.dropped) {
		return false
	}
	back, berr := build_any(string(out), c.spec, c.opts)
	defer core.destroy(&back)
	return testing.expectf(t, berr == nil, "committed %q does not read: %v", out, berr)
}

@(private = "file")
RAGGED :: dsv.Options{tolerate = {.Ragged}}

@(private = "file")
NO_HEADER :: dsv.Options{no_header = true}

@(private = "file")
COMMENT :: dsv.Options{comment = '#'}

@(test)
edit_cells :: proc(t: ^testing.T) {
	expect_edits(t, {
		{src = "a,b\n1,2\n", want = "a,b\n9,2\n", ops = {put(5, "9")}},
		{src = "a,b\n\"x,y\",2\n", want = "a,b\nz,2\n", ops = {put(5, "z")}},
		{src = "a,b\nx,2\n", want = "a,b\n\"p,q\",2\n", ops = {put(5, "\"p,q\"")}},
		{src = "a,b\nx,2\n", want = "a,b\n,2\n", ops = {put(5, "")}},
		{src = "a,b\n1,2\n", want = "z,b\n1,2\n", ops = {put(2, "z")}},
		{src = "a\tb\n1\t2\n", want = "a\tb\n1\t9\n", spec = .Tsv, ops = {put(6, "9")}},
		{src = "a\tb\nx\t2\n", want = "a\tb\nx\\ty\t2\n", spec = .Tsv, ops = {put(5, "x\\ty")}},
		{src = "1,2\n3,4", want = "5,2\n3,4", opts = NO_HEADER, ops = {put(2, "5")}},
		{src = "a\n1\n2\n", fail = .Bad_Width, ops = {put(4, "")}},
		{src = "a\n1\n", fail = .Bad_Width, ops = {put(2, "")}},
		{src = "1,2\n3\n", opts = {no_header = true, tolerate = {.Ragged}}, fail = .Bad_Width, ops = {put(5, "")}},
		{src = "1,2\n", want = ",2\n", opts = NO_HEADER, ops = {put(2, "")}},
		{src = "1\n", opts = NO_HEADER, fail = .Bad_Width, ops = {put(2, "")}},
	})
}

@(test)
edit_insert_record :: proc(t: ^testing.T) {
	expect_edits(t, {
		{src = "a,b\n1,2\n", want = "a,b\n7,8\n1,2\n", ops = {ins(core.ROOT, 0, "7,8")}},
		{src = "a,b\n1,2\n3,4\n", want = "a,b\n1,2\n7,8\n3,4\n", ops = {ins(core.ROOT, 1, "7,8")}},
		{src = "a,b\n1,2\n", want = "a,b\n1,2\n7,8\n", ops = {ins(core.ROOT, 1, "7,8")}},
		{src = "a,b\n1,2", want = "a,b\n1,2\n7,8", ops = {ins(core.ROOT, 1, "7,8")}},
		{src = "", want = "7,8\n", ops = {ins(core.ROOT, 0, "7,8")}},
		{src = "a,b\n", want = "a,b\n7,8\n", ops = {ins(core.ROOT, 0, "7,8")}},
		{src = "a,b", want = "a,b\n7,8", ops = {ins(core.ROOT, 0, "7,8")}},
		{src = "a,b\r\n1,2\r\n", want = "a,b\r\n1,2\r\n7,8\r\n", ops = {ins(core.ROOT, 1, "7,8")}},
		{src = "1,2\n", want = "3,4\n1,2\n", opts = NO_HEADER, ops = {ins(core.ROOT, 0, "3,4")}},
		{src = "a,b\n1,2\n", want = "a,b\n1,2\n\"x,y\",\"m\nn\"\n", ops = {ins(core.ROOT, 1, "\"x,y\",\"m\nn\"")}},
		{src = "a\tb\n1\t2\n", want = "a\tb\n1\t2\n3\t4\n", spec = .Tsv, ops = {ins(core.ROOT, 1, "3\t4")}},
		{src = "a,b\r\n1,2", want = "a,b\r\nv,v\r\n1,2", ops = {ins(core.ROOT, 0, "v,v")}},
		{src = "a,b\r\n1,2\r\n3,4\r\n", want = "a,b\r\nv,v\r\n1,2\r\n3,4\r\n", ops = {ins(core.ROOT, 0, "v,v")}},
		{src = "a,b\r\n", want = "a,b\r\nv,v\r\n", ops = {ins(core.ROOT, 0, "v,v")}},
		{src = "abc,de\r\n1,2,3", want = "abc,de\r\n1,2,3\r\n4,5,6", opts = RAGGED, ops = {ins(core.ROOT, 1, "4,5,6")}},
		{src = "a,b\n1,2\n", fail = .Bad_Width, ops = {ins(core.ROOT, 0, "7")}},
		{src = "a,b\n1,2\n", fail = .Bad_Width, ops = {drop(3), ins(core.ROOT, 0, "7,8")}},
		{src = "", fail = .Bad_Width, ops = {ins(core.ROOT, 0, "1,2"), ins(core.ROOT, 0, "3")}},
	})
}

@(test)
edit_insert_cell :: proc(t: ^testing.T) {
	expect_edits(t, {
		{src = "1,2\n", want = "1,2,3\n", opts = NO_HEADER, ops = {ins(1, 2, "3")}},
		{src = "1,2", want = "1,2,3", opts = NO_HEADER, ops = {ins(1, 2, "3")}},
		{src = "1,2\n", want = "1,0,2\n", opts = NO_HEADER, ops = {ins(1, 1, "0")}},
		{src = "a,b\n", want = "a,b,c\n", ops = {ins(1, 2, "c")}},
		{src = "1,2\n3\n", want = "1,2\n3,4\n", opts = {no_header = true, tolerate = {.Ragged}}, ops = {ins(4, 1, "4")}},
		{src = "a,", want = "a,x,,y", opts = NO_HEADER, ops = {ins(1, 1, "x"), ins(1, 2, "y")}},
		{src = "a,b\n1,2\n3,4\n", fail = .Wrong_Container, ops = {ins(4, 2, "9")}},
		{src = "a,b\n1,2\n3,4\n", fail = .Wrong_Container, ops = {ins(4, 0, "x,y")}},
		{src = "1,2\n3,4\n", fail = .Bad_Value, opts = NO_HEADER, ops = {ins(1, 0, "x,y")}},
		{src = "1,2\n3,4\n", fail = .Bad_Position, opts = NO_HEADER, ops = {ins(1, 9, "7")}},
	})
}

@(test)
edit_remove :: proc(t: ^testing.T) {
	expect_edits(t, {
		{src = "a,b\n1,2\n3,4\n", want = "a,b\n3,4\n", ops = {drop(4)}},
		{src = "a,b\n1,2\n3,4\n", want = "a,b\n1,2\n", ops = {drop(7)}},
		{src = "a,b\n1,2", want = "a,b\n", ops = {drop(4)}},
		{src = "1,2\n", want = "", opts = NO_HEADER, ops = {drop(1)}},
		{src = "a,b\r\n1,2\r\n", want = "a,b\r\n", ops = {drop(4)}},
		{src = "a\tb\n1\t2\n", want = "a\tb\n", spec = .Tsv, ops = {drop(4)}},
		{src = "a\n1\n2\n3\n", want = "a\n3\n", opts = NO_HEADER, ops = {drop(3), drop(5)}},
		{src = "a,b\n1,2\n", fail = .Bad_Index, ops = {drop(0)}},
		{src = "a,b\n1,2\n", fail = .Bad_Index, ops = {drop(1)}},
		{src = "1,2\n", want = "2\n", opts = NO_HEADER, ops = {drop(2)}},
		{src = "1,2\n", want = "1\n", opts = NO_HEADER, ops = {drop(3)}},
		{src = "1,2,3\n", want = "1,3\n", opts = NO_HEADER, ops = {drop(3)}},
		{src = "a,b\n", want = "a\n", ops = {drop(3)}},
		{src = "a,b\n1,2\n3,4\n", want = "a,b\n,2\n3,4\n", ops = {drop(5)}},
		{src = "1,2\n", fail = .Bad_Width, opts = NO_HEADER, ops = {drop(3), drop(2)}},
	})
}

@(test)
edit_wide_record :: proc(t: ^testing.T) {
	wide := "a,b\n1,2,3\n4,5\n"
	expect_edits(t, {
		{src = wide, want = "a,b\n1,2,9\n4,5\n", opts = RAGGED, ops = {put(8, "9")}},
		{src = wide, want = "a,b\n1,2\n4,5\n", opts = RAGGED, ops = {drop(8)}},
		{src = wide, want = "a,b\n1,2,3\n4,5,z\n", opts = RAGGED, ops = {{kind = .Member, node = 9, a = "3", b = "z"}}},
		{src = wide, fail = .Bad_Index, opts = RAGGED, ops = {put(4, "c")}},
		{src = wide, fail = .Bad_Width, opts = RAGGED, ops = {drop(2)}},
		{src = wide, fail = .Bad_Width, opts = RAGGED, ops = {{kind = .Member, node = 9, a = "c", b = "z"}}},
	})
	doc, err := core.build(transmute([]u8)string("abc,de\n1,2,3\n"), dsv.as(.Csv, RAGGED))
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(core.span(&doc, core.header_of(&doc))), "abc,de\n")
}

@(test)
edit_drop_column :: proc(t: ^testing.T) {
	abc := "a,b,c\n1,2,3\n4,5,6\n"
	lines := "a,b,c\n1\n2,3\n4,5,6\n"
	expect_edits(t, {
		{src = abc, want = "b,c\n2,3\n5,6\n", ops = drops(6, 10)},
		{src = abc, want = "a,c\n1,3\n4,6\n", ops = drops(7, 11)},
		{src = abc, want = "a,b\n1,2\n4,5\n", ops = drops(8, 12)},
		{src = abc, want = "a,c\n1,3\n4,6\n", ops = {drop(3)}},
		{src = "a,b\r\n1,2\r\n3,4\r\n", want = "a\r\n1\r\n3\r\n", ops = drops(6, 9)},
		{src = "a,\"b,c\",d\n1,\"2\n3\",4\n", want = "\"b,c\",d\n\"2\n3\",4\n", ops = {drop(6)}},
		{src = "1,2\n3,4\n", want = "1\n3\n", opts = NO_HEADER, ops = drops(3, 6)},
		{src = lines, want = "a,c\n1\n2\n4,6\n", opts = RAGGED, ops = drops(9, 12)},
		{src = lines, want = "a,b\n1\n2,3\n4,5\n", opts = RAGGED, ops = {drop(13)}},
		{src = "a,b\n1,2\n3,4\n", want = "a\n1\n", ops = drops(7, 6)},
		{src = "a,b\n\"\"\n1,2\n3,4\n", want = "a\n\"\"\n1\n3\n", opts = RAGGED, ops = drops(8, 11)},
		{src = "a,b\n1,\"#2\"\n", want = "b\n\"#2\"\n", opts = COMMENT, ops = {drop(2)}},
		{src = "a\n1\n", fail = .Bad_Width, ops = {drop(4)}},
		{src = "a,b\n1,2\n", fail = .Bad_Width, ops = drops(2, 3)},
		{src = "a\n1\n2\n", fail = .Bad_Width, ops = {drop(4)}},
		{src = "a,b\n1,#2\n", fail = .Bad_Width, opts = COMMENT, ops = {drop(2)}},
		{src = "a,b,c\n1,#2,3\n", fail = .Bad_Width, opts = COMMENT, ops = {drop(2)}},
		{src = "a,\xEF\xBB\xBFb\n1,2\n", fail = .Bad_Width, ops = {drop(2)}},
		{src = "a,b\n1,2\n", fail = .Conflicting_Edits, ops = drops(5, 5)},
		{src = "a,b\n1,2\n", fail = .Conflicting_Edits, ops = {drop(2), put(5, "9")}},
	})
}

@(test)
edit_add_column :: proc(t: ^testing.T) {
	ab := "a,b\n1,2\n3,4\n"
	expect_edits(t, {
		{src = ab, want = "a,b,c\n1,2,9\n3,4,\n", ops = {add(4, 2, "c", "9")}},
		{src = ab, want = "a,b,c\n1,2,8\n3,4,9\n", ops = {add(4, 2, "c", "8"), add(7, 2, "c", "9")}},
		{src = "a,b\n1,2\n", want = "a,b,c,d\n1,2,8,9\n", ops = {add(4, 2, "c", "8"), add(4, 2, "d", "9")}},
		{src = ab, want = "a,c,b\n1,9,2\n3,,4\n", ops = {add(4, 1, "c", "9")}},
		{src = ab, fail = .Bad_Position, ops = {add(4, 1, "c", "8"), add(7, 0, "c", "9")}},
		{src = "a\n1\n", want = "a,\"x,\"\"y\"\n1,9\n", ops = {add(3, 1, "x,\"y", "9")}},
		{src = "a\tb\n1\t2\n", want = "a\tb\tx\\ty\n1\t2\t9\n", spec = .Tsv, ops = {add(4, 2, "x\ty", "9")}},
		{src = ab, want = "a,b,c\n1,2,9\n3,4,\n", ops = {ins(1, 2, "c"), add(4, 2, "c", "9")}},
		{src = ab, want = "c,a,b\n,1,2\n,3,4\n", ops = {ins(1, 0, "c")}},
		{src = "a|b\n1|2\n", spec = .Plain, opts = {delimiter = '|'}, fail = .Bad_Value, ops = {add(4, 2, "x|y", "9")}},
		{src = "a,b\n1,2\n", fail = .Duplicate_Key, ops = {add(4, 2, "b", "9")}},
		{src = "1,2\n3,4\n", want = "1,2,9\n3,4,\n", opts = NO_HEADER, ops = {ins(1, 2, "9")}},
		{src = "1,2\n3,4\n", want = "1,2,8\n3,4,9\n", opts = NO_HEADER, ops = {ins(1, 2, "8"), ins(4, 2, "9")}},
		{src = "1,2\n3,4\n", want = "8,1,2\n,3,4\n", opts = NO_HEADER, ops = {ins(1, 0, "8")}},
		{src = "a,b\n1,2\n", want = "a,c\n1,9\n3,4\n", ops = {drop(3), add(4, 2, "c", "9"), ins(core.ROOT, 1, "3,4")}},
		{src = "a,b,c\n1\n", want = "a,b,c\n1,,9\n", opts = RAGGED, ops = {add(5, 1, "c", "9")}},
		{src = "a,b\n1\n2,3\n", want = "a,b,c\n1\n2,3,\n", opts = RAGGED, ops = {ins(1, 2, "c")}},
		{src = "a,b\n1\n2,3\n", want = "a,b,c\n1,,9\n2,3,\n", opts = RAGGED, ops = {add(4, 1, "c", "9")}},
		{src = "a,b\n1\n", fail = .Conflicting_Edits, opts = RAGGED, ops = {add(4, 1, "b", "8"), add(4, 1, "b", "9")}},
	})
}

@(test)
edit_errors :: proc(t: ^testing.T) {
	ab := "a,b\n1,2\n"
	expect_edits(t, {
		{src = ab, fail = .Bad_Index, ops = {put(0, "x")}},
		{src = ab, fail = .Bad_Index, ops = {put(4, "x")}},
		{src = ab, fail = .Bad_Index, ops = {put(99, "x")}},
		{src = ab, fail = .Bad_Value, ops = {put(5, "x,y")}},
		{src = ab, fail = .Bad_Value, ops = {put(5, "x\ny")}},
		{src = ab, fail = .Wrong_Container, ops = {ins(4, 0, "x,y")}},
		{src = ab, fail = .Bad_Position, ops = {ins(core.ROOT, 3, "7,8")}},
		{src = ab, fail = .Wrong_Container, ops = {ins(4, 9, "7")}},
		{src = ab, fail = .Wrong_Container, ops = {add(5, 0, "k", "v")}},
		{src = ab, fail = .Bad_Index, ops = {drop(99)}},
		{src = ab, fail = .Bad_Value, ops = {ins(core.ROOT, 0, "")}},
	})
}

@(test)
edit_options :: proc(t: ^testing.T) {
	semi := dsv.Options{delimiter = ';'}
	bar := dsv.Options{delimiter = '|'}
	expect_edits(t, {
		{src = "a;b\n1;2\n", want = "a;b\n9;2\n", opts = semi, ops = {put(5, "9")}},
		{src = "a;b\n1;2\n", want = "a;b\n1;2\n3;4\n", opts = semi, ops = {ins(core.ROOT, 1, "3;4")}},
		{src = "1;2\n", want = "1;2;3\n", opts = {delimiter = ';', no_header = true}, ops = {ins(1, 2, "3")}},
		{src = "a;b\nx;2\n", want = "a;b\na,b;2\n", opts = semi, ops = {put(5, "a,b")}},
		{src = "a;b\nx;2\n", fail = .Bad_Value, opts = semi, ops = {put(5, "p;q")}},
		{src = "a;b\nx;2\n", want = "a;b\n\"p;q\";2\n", opts = semi, ops = {put(5, "\"p;q\"")}},
		{src = "a|b\nx|2\n", fail = .Bad_Value, spec = .Plain, opts = bar, ops = {put(5, "p|q")}},
		{src = "a|b\nx|2\n", fail = .Bad_Value, spec = .Plain, opts = bar, ops = {put(5, "\"p|q\"")}},
		{src = "a|b\nx|2\n", want = "a|b\np q|2\n", spec = .Plain, opts = bar, ops = {put(5, "p q")}},
		{src = "a|b\n1|2\n", want = "a|b\n9|2\n", spec = .Plain, opts = bar, ops = {put(5, "9")}},
		{src = "a|b\n1|2\n", want = "a|b\n1|2\n3|4\n", spec = .Plain, opts = bar, ops = {ins(core.ROOT, 1, "3|4")}},
	})
}

@(test)
edit_beside_comment :: proc(t: ^testing.T) {
	headless := dsv.Options{comment = '#', no_header = true}
	expect_edits(t, {
		{src = "#c\na,b\n1,2\n", want = "1,2\n", opts = headless, ops = {drop(1)}},
		{src = "a,b\n#c\n1,2\n", want = "#c\n1,2\n", opts = headless, ops = {drop(1)}},
		{src = "a,b\n#c\n1,2\n", want = "a,b\n", opts = headless, ops = {drop(4)}},
		{src = "a,b\n#c\n", want = "#c\n", opts = headless, ops = {drop(1)}},
		{src = "#c\r\na\tb\r\n", want = "", spec = .Tsv, opts = headless, ops = {drop(1)}},
		{src = "#c\na,b\n", want = "x,y\n#c\na,b\n", opts = headless, ops = {ins(core.ROOT, 0, "x,y")}},
		{src = "a,b\n#c\n", want = "a,b\nx,y\n#c\n", opts = headless, ops = {ins(core.ROOT, 1, "x,y")}},
		{src = "#c", want = "x,y\n#c", opts = headless, ops = {ins(core.ROOT, 0, "x,y")}},
		{src = "a,b\n1,2\n", fail = .Bad_Value, opts = COMMENT, ops = {put(5, "#x")}},
		{src = "a,b\n1,2\n", want = "a,b\n\"#x\",2\n", opts = COMMENT, ops = {put(5, "\"#x\"")}},
		{src = "a,b\n1,2\n", fail = .Bad_Value, opts = COMMENT, ops = {ins(core.ROOT, 0, "#x,y")}},
	})
}

@(test)
edit_with_removed_records :: proc(t: ^testing.T) {
	expect_edits(t, {
		{src = "a,b\n1,2\n3,4\n", want = "a,b\n7,7\n8,8\n3,4\n", ops = {drop(4), ins(core.ROOT, 1, "7,7"), ins(core.ROOT, 1, "8,8")}},
		{src = "a,b\n1,2\n3,4", want = "a,b\n1,2\n9,9", ops = {drop(7), ins(core.ROOT, 1, "9,9")}},
		{src = "a,b\n1,2\n3,4", want = "a,b\n1,2\n9,9", ops = {drop(7), ins(core.ROOT, 2, "9,9")}},
		{src = "h\n1\n2\n", want = "h\nA\nB\n2\n", spec = .Plain, ops = {ins(core.ROOT, 1, "B"), ins(core.ROOT, 0, "A"), drop(3)}},
		{src = "a;b;c", want = "a;b;d\ne;f;g", opts = {no_header = true, delimiter = ';'}, ops = {ins(1, 3, "d"), drop(4), ins(core.ROOT, 1, "e;f;g")}},
		{src = "h\n1\n#f\n", want = "h\nA\n#f\n", spec = .Plain, opts = COMMENT, ops = {ins(core.ROOT, 1, "A"), drop(3)}},
		{src = "|1\n", fail = .Conflicting_Edits, spec = .Plain, opts = {no_header = true, delimiter = '|'}, ops = {drop(1), put(2, "x")}},
		{src = "1\n", fail = .Conflicting_Edits, spec = .Plain, opts = NO_HEADER, ops = {drop(1), ins(1, 0, "x")}},
	})
}

@(test)
edit_zero_width_cells :: proc(t: ^testing.T) {
	expect_edits(t, {
		{src = "a,b\n,2\n", want = "a,b\n3,4\n9,2\n", ops = {ins(core.ROOT, 0, "3,4"), put(5, "9")}},
		{src = "1,2\n3,", want = "1,2\n3,9\n7,8", opts = NO_HEADER, ops = {ins(core.ROOT, 2, "7,8"), put(6, "9")}},
		{src = "a,\n", want = "a,x,9,y\n", opts = NO_HEADER, ops = {ins(1, 1, "x"), ins(1, 2, "y"), put(3, "9")}},
	})
}

@(test)
set_and_remove_of_a_cell :: proc(t: ^testing.T) {
	for text in ([]string{"z", ""}) {
		for set_first in ([]bool{true, false}) {
			doc, _ := core.build(transmute([]u8)string("a\n1\n2\n"), dsv.as(.Csv))
			defer core.destroy(&doc)
			list := core.edit_list_init(&doc)
			defer core.edit_list_destroy(&list)
			first, second := put(4, text), drop(4)
			if !set_first {
				first, second = second, first
			}
			walktest.expect_nil(t, apply(&list, first))
			walktest.expect_nil(t, apply(&list, second))
			out, _, e := compose.commit(&list)
			delete(out)
			testing.expectf(t, walktest.document_of(e).kind == .Conflicting_Edits && walktest.at_of(e) == 2, "%q set first %v: %v", text, set_first, e)
		}
	}
}

@(test)
edit_tolerated_source :: proc(t: ^testing.T) {
	expect_edits(t, {
		{src = "a,b\n1\n", want = "a,b\n1\n", opts = RAGGED},
		{src = "a,b\n1\n", want = "a,b\n5\n", opts = RAGGED, ops = {put(5, "5")}},
	})
}

@(test)
edit_no_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	doc, err := core.build(transmute([]u8)string("a,b\n1,2\n3,4\n"), dsv.as(.Csv))
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	list := core.edit_list_init(&doc, allocator = alloc)
	for op in ([]Op{put(5, "9"), ins(core.ROOT, 2, "7,8"), put(6, "9")}) {
		walktest.expect_nil(t, apply(&list, op))
	}
	out, _, cerr := compose.commit(&list, allocator = alloc)
	walktest.expect_nil(t, cerr)
	delete(out, allocator = alloc)
	core.edit_list_destroy(&list)
	testing.expectf(t, len(track.allocation_map) == 0, "%d allocations left", len(track.allocation_map))
}

@(test)
edit_out_of_memory :: proc(t: ^testing.T) {
	doc, _ := core.build(transmute([]u8)string("a,b\n1,2\n"), dsv.as(.Csv))
	defer core.destroy(&doc)
	f := walktest.Failing_Alloc{inner = context.allocator, fail_at = -1}
	alloc := walktest.failing_allocator(&f)
	list := core.edit_list_init(&doc, allocator = alloc)
	defer core.edit_list_destroy(&list)
	landed := false
	for fail_at in 0 ..< 8 {
		f.n = 0
		f.fail_at = fail_at
		e := write.insert(&list, core.ROOT, 1, typed.Raw(string("7,8")))
		if _, oom := e.(runtime.Allocator_Error); oom {
			testing.expect_value(t, len(list.edits), 0)
			continue
		}
		walktest.expect_nil(t, e)
		landed = true
		break
	}
	testing.expect(t, landed)
	f.fail_at = -1
	committed := false
	for fail_at in 0 ..< 32 {
		f.n = 0
		f.fail_at = fail_at
		out, _, e := compose.commit(&list, allocator = alloc)
		if _, oom := e.(runtime.Allocator_Error); oom {
			continue
		}
		walktest.expect_nil(t, e)
		testing.expect_value(t, string(out), "a,b\n1,2\n7,8\n")
		delete(out, allocator = alloc)
		committed = true
		break
	}
	testing.expect(t, committed)
	f.fail_at = -1
}

// A spec change would respell every cell, so it is refused with `Bad_Spec` before anything is written.
@(test)
fact_spec_change_refused :: proc(t: ^testing.T) {
	doc, _ := core.build(transmute([]u8)string("a,b\n1,2\n"), dsv.as(.Csv))
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	out, _, err := compose.commit(&list, dsv.as(.Tsv))
	walktest.expect_kind(t, err, core.Document_Error_Kind.Bad_Spec)
	testing.expect(t, out == nil)
}

// A comment line belongs to the record that follows it, or to the root as its foot after the last record. Each role is
// written where the walk reads it, and a fact a text cannot spell is dropped and counted.
@(test)
fact_edits :: proc(t: ^testing.T) {
	ab := "a,b\n1,2\n"
	expect_edits(t, {
		{src = ab, want = "a,b\n#c\n1,2\n", opts = COMMENT, ops = {fact(4, .Comment, "c")}},
		{src = ab, want = ab, opts = COMMENT, dropped = 1, ops = {fact(4, .Comment_Inline, "c")}},
		{src = ab, want = "a,b\n1,2\n#c\n", opts = COMMENT, ops = {fact(core.ROOT, .Comment_Foot, "c")}},
		{src = ab, want = ab, opts = COMMENT, dropped = 1, ops = {fact(6, .Comment, "c")}},
		{src = ab, want = ab, opts = COMMENT, dropped = 1, ops = {fact(4, .Comment_Foot, "c")}},
		{src = ab, want = ab, opts = COMMENT, dropped = 1, ops = {fact(4, .Comment, "one\ntwo")}},
		{src = ab, want = ab, dropped = 1, ops = {fact(4, .Comment, "c")}},
		{src = ab, fail = .Bad_Fact, opts = COMMENT, ops = {fact(4, .Comment_Inline, "a\nb")}},
		{src = ab, want = "a,b\n#a b\n1,2\n", opts = COMMENT, ops = {fact(4, .Comment, "a b")}},
		{src = ab, want = "#c\na,b\n1,2\n", opts = COMMENT, ops = {fact(core.ROOT, .Comment, "c")}},
		{src = ab, want = ab, opts = {comment = '#', no_header = true}, dropped = 1, ops = {fact(core.ROOT, .Comment, "c")}},
		{src = ab, want = "a,b\n", opts = COMMENT, dropped = 1, ops = {fact(core.ROOT, .Comment, "c"), drop(4)}},
		{src = "#top\nh\n1\n", want = "#top\nh\n", opts = COMMENT, ops = {drop(3)}},
		{src = "a,b\n#old\n1,2\n", want = "a,b\n#new\n1,2\n", opts = COMMENT, ops = {fact(4, .Comment, "new")}},
		// Padded bodies, each on a line of its own.
		{src = "a,b\n#old\n1,2\n", want = "a,b\n# x\n# y\n1,2\n", opts = COMMENT, ops = {{kind = .Facts, node = 4, role = .Comment, a = "x|y"}}},
		{src = "a,b\n1,2\n", want = "a,b\n1,2\n# x\n# y\n", opts = COMMENT, ops = {{kind = .Facts, node = core.ROOT, role = .Comment_Foot, a = "x|y"}}},
		{src = "a,b\n#old\n1,2\n", want = "a,b\n1,2\n", opts = COMMENT, ops = {{kind = .Unfact, node = 4, role = .Comment}}},
		{src = "a,b\n1,2\n#old\n", want = "a,b\n1,2\n#new\n", opts = COMMENT, ops = {fact(core.ROOT, .Comment_Foot, "new")}},
		{src = "a,b\n1,2\n#old\n", want = "a,b\n1,2\n", opts = COMMENT, ops = {{kind = .Unfact, node = core.ROOT, role = .Comment_Foot}}},
		{src = "a,b\n#old\n1,2\n", want = "a,b\n#old\n1,9\n", opts = COMMENT, ops = {put(6, "9")}},
		{src = "1,2\n", want = "#c\n9,1,2\n", opts = {comment = '#', no_header = true}, ops = {fact(1, .Comment, "c"), ins(1, 0, "9")}},
		{src = "#h\nk\n", want = "#x\nk\n", opts = COMMENT, ops = {fact(core.ROOT, .Comment_Foot, "x")}},
		{src = "a\tb\n1\t2\n\t", want = "a\tb\n1\t2\n\t\n!x\n", spec = .Tsv, opts = {comment = '!'}, ops = {fact(core.ROOT, .Comment_Foot, "x")}},
		{src = "!#\n sp ^\"q\"\nx\\y^", want = "!#\n sp ^\"q\"\nx\\y^x\\y\n!\n", spec = .Plain, opts = {no_header = true, delimiter = '^', comment = '!'}, ops = {put(6, "x\\y"), fact(core.ROOT, .Comment_Foot, "")}},
		// A removed comment line leaves the next record's leading blanks, which are its cell's data.
		{src = "\xef\xbb\xbf& ;a\r\n12.5\r\na\r\n\"q\"\r\n&\\\\,\r\n sp \r\n", want = "\xef\xbb\xbf& ;a\r\n12.5\r\né\r\n\"q\"\r\n sp \r\n", opts = {no_header = true, delimiter = '#', comment = '&'}, ops = {put(4, "é"), {kind = .Unfact, node = 7, role = .Comment}}},
	})
}

// A cell that is not UTF-8 is refused where it is recorded, and the text stays as it was.
@(test)
value_edit_refuses_a_cell_that_is_not_utf8 :: proc(t: ^testing.T) {
	src := "a,b\n1,2\n"
	doc, _ := core.build(transmute([]u8)src, dsv.as(.Csv))
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	bad := [3]u8{'a', 0xff, 'b'}
	walktest.expect_kind(t, write.set(&list, cell_node(&doc, 0, 0), transmute(string)bad[:]), core.Document_Error_Kind.Bad_Value)
	out, _, err := compose.commit(&list, dsv.as(.Csv))
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(out), src)
	delete(out)
}
