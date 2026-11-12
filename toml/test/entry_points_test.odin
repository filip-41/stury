// The entry points of the package: a constant spec and a spec chosen at run time give the same answers, a document of
// either is queried, edited and written, and an edit takes a built value, which the format spells.
package toml_tests

import "core:strings"
import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import write "../../core/write"
import toml ".."
import walktest "../../walktest"

@(private = "file")
TEXT :: "a = 1\n\n[t]\nk = [1, 2, 3]\ns = \"x\"\n"

@(test)
a_constant_and_a_chosen_spec_agree :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string(TEXT)
	path := core.Path{steps = {core.Name("t"), core.Name("k"), core.Index(2)}}
	for spec in toml.Spec {
		walktest.expect_nil(t, toml.validate(src, spec))
		chosen, built := toml.build(src, spec, allocator = context.temp_allocator)
		walktest.expect_nil(t, built)
		testing.expect(t, core.services_of(chosen.as) != nil)
		found, answer, err := toml.find(src, spec, path, allocator = context.temp_allocator)
		walktest.expect_nil(t, err)
		n, _ := core.number(&found, answer.node)
		testing.expect_value(t, n.bits, 3)
		scanned, serr := toml.scan(src, spec, path, allocator = context.temp_allocator)
		walktest.expect_nil(t, serr)
		testing.expect_value(t, len(scanned.answers), 1)
	}
	walktest.expect_nil(t, toml.validate(src, .Toml_1_0))
	walktest.expect_kind(t, toml.validate(transmute([]u8)string("a = 07:32\n"), .Toml_1_0), core.Document_Error_Kind.Walk)
	walktest.expect_nil(t, toml.validate(transmute([]u8)string("a = 07:32\n"), .Toml_1_1))
	bound, built := toml.build(src, .Toml_1_1, allocator = context.temp_allocator)
	walktest.expect_nil(t, built)
	testing.expect(t, core.services_of(bound.as) == nil)
	answers, qerr := toml.query(&bound, path, allocator = context.temp_allocator)
	walktest.expect_nil(t, qerr)
	testing.expect(t, len(answers) == 1 && answers[0].outcome == .Found)
	scanned, serr := toml.scan(src, .Toml_1_1, path, allocator = context.temp_allocator)
	walktest.expect_nil(t, serr)
	testing.expect_value(t, len(scanned.answers), 1)
	_, missing, merr := toml.find(src, .Toml_1_0, core.Path{steps = {core.Name("t"), core.Name("none")}}, allocator = context.temp_allocator)
	walktest.expect_nil(t, merr)
	testing.expect_value(t, missing.outcome, core.Presence.Missing)
}

@(test)
a_document_of_either_form_is_written_and_edited :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string(TEXT)
	bound, _ := toml.build(src, .Toml_1_0, allocator = context.temp_allocator)
	text, _, werr := toml.write(&bound, .Toml_1_0, allocator = context.temp_allocator)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(text), TEXT)
	spec := toml.Spec.Toml_1_0
	chosen, _ := toml.build(src, spec, allocator = context.temp_allocator)
	again, _, aerr := toml.write(&chosen, spec, allocator = context.temp_allocator)
	walktest.expect_nil(t, aerr)
	testing.expect_value(t, string(again), TEXT)
	_, _, kerr := toml.write(&bound, .Toml_1_0, node = 1, allocator = context.temp_allocator)
	walktest.expect_kind(t, kerr, core.Typed_Error_Kind.Unsupported)

	// The list of a document read by a handle takes the handle's edit services, and one of a constant spec the spec's.
	lists := [?]core.Edit_List{core.edit_list_init(&chosen, context.temp_allocator), toml.edit_list_init(&chosen, spec, context.temp_allocator), toml.edit_list_init(&bound, .Toml_1_0, context.temp_allocator)}
	for &list in lists {
		a, _ := core.member(list.doc, core.ROOT, "a")
		walktest.expect_nil(t, write.set(&list, a, 2))
		out, _, cerr := compose.commit(&list, allocator = context.temp_allocator)
		walktest.expect_nil(t, cerr)
		testing.expect_value(t, string(out), "a = 2\n\n[t]\nk = [1, 2, 3]\ns = \"x\"\n")
	}
}

@(test)
an_edit_spells_a_built_value :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string(TEXT)
	doc, _ := toml.build(src, .Toml_1_1)
	list := toml.edit_list_init(&doc, .Toml_1_1)
	table, _ := core.member(&doc, core.ROOT, "t")
	s, _ := core.member(&doc, table, "s")
	walktest.expect_nil(t, write.set(&list, s, "a\"b"))
	walktest.expect_nil(t, write.insert(&list, table, 2, "f", 2.5))
	walktest.expect_nil(t, write.insert(&list, table, 2, "on", true))
	point := core.new_object()
	core.object_put(point, "x", 1.5)
	core.object_put(point, "tags", core.new_array())
	walktest.expect_nil(t, write.insert(&list, table, 2, "p", point))
	inner := core.new_object()
	core.object_put(inner, "y z", "q")
	walktest.expect_nil(t, write.insert(&list, core.ROOT, 1, "b", inner))
	out, _, err := compose.commit(&list)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(out), "a = 1\n\n[t]\nk = [1, 2, 3]\ns = \"a\\\"b\"\nf = 2.5\non = true\n\n[t.p]\nx = 1.5\ntags = []\n\n[b]\n\"y z\" = \"q\"\n")

	// Null has no TOML spelling.
	walktest.expect_kind(t, core.set_value(&list, s, nil), core.Typed_Error_Kind.Unwritable)
}

@(test)
set_spells_a_value_at_a_path :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string(TEXT)
	path := core.Path{steps = {core.Name("t"), core.Name("k"), core.Index(1)}}
	out, err := toml.set(src, .Toml_1_1, path, 20, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(out), "a = 1\n\n[t]\nk = [1, 20, 3]\ns = \"x\"\n")
	spec := toml.Spec.Toml_1_0
	out, err = toml.set(src, spec, core.Path{steps = {core.Name("t"), core.Name("n")}}, "new", allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(out), "a = 1\n\n[t]\nk = [1, 2, 3]\ns = \"x\"\nn = \"new\"\n")
	Point :: struct {
		x, y: int,
	}
	plan, perr := toml.plan_make(Point, reads = toml.reads(.Toml_1_0))
	defer typed.plan_destroy(&plan)
	walktest.expect_nil(t, perr)
	out, err = toml.set(src, .Toml_1_0, core.Path{steps = {core.Name("a")}}, Point{1, 2}, &plan, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(out), "a = { x = 1, y = 2 }\n\n[t]\nk = [1, 2, 3]\ns = \"x\"\n")
}

// A value taken from the list's own document is written where it goes as the format spells it there: a table that
// stands as a section is an inline table in a line.
@(test)
an_edit_moves_a_node_of_the_document :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string("a = 1\nlist = []\n\n[t]\nk = [1, 2]\n\n[t.u]\nv = 'w'\n")
	doc, _ := toml.build(src, .Toml_1_1, allocator = context.temp_allocator)
	list := toml.edit_list_init(&doc, .Toml_1_1, context.temp_allocator)
	table, _ := core.member(&doc, core.ROOT, "t")
	items, _ := core.member(&doc, core.ROOT, "list")
	a, _ := core.member(&doc, core.ROOT, "a")
	k, _ := core.member(&doc, table, "k")
	walktest.expect_nil(t, write.insert(&list, items, 0, core.Node_Ref{&doc, table}))
	walktest.expect_nil(t, write.set(&list, a, core.Node_Ref{&doc, k}))
	out, _, err := compose.commit(&list, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(out), "a = [1, 2]\nlist = [{ k = [1, 2], u = { v = 'w' } }]\n\n[t]\nk = [1, 2]\n\n[t.u]\nv = 'w'\n")
}

@(test)
a_plan_reads_a_text_and_a_node :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Table :: struct {
		k: []int,
		s: string,
	}
	Root :: struct {
		a: int,
		t: Table,
	}
	src := transmute([]u8)string(TEXT)
	plan, perr := toml.plan_make(Root, .Toml_1_1)
	defer typed.plan_destroy(&plan)
	walktest.expect_nil(t, perr)
	root: Root
	walktest.expect_nil(t, toml.unmarshal(src, .Toml_1_1, &root, &plan, allocator = context.temp_allocator))
	testing.expect(t, root.a == 1 && len(root.t.k) == 3 && root.t.s == "x")
	other: struct {
		a: string,
	}
	walktest.expect_kind(t, toml.unmarshal(src, .Toml_1_1, &other, &plan, allocator = context.temp_allocator), core.Typed_Error_Kind.Plan_Mismatch)

	inner, ierr := toml.plan_make(Table)
	defer typed.plan_destroy(&inner)
	walktest.expect_nil(t, ierr)
	for spec in toml.Spec {
		doc, _ := toml.build(src, spec, allocator = context.temp_allocator)
		node, _ := core.member(&doc, core.ROOT, "t")
		table: Table
		walktest.expect_nil(t, typed.unmarshal(&doc, node, &table, &inner, allocator = context.temp_allocator))
		testing.expect(t, len(table.k) == 3 && table.k[2] == 3 && table.s == "x")
		// A nil plan is made from the document's handle.
		made: Table
		walktest.expect_nil(t, typed.unmarshal(&doc, node, &made, nil, allocator = context.temp_allocator))
		testing.expect_value(t, made.s, "x")
	}
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	bad: Root
	refused := toml.unmarshal(transmute([]u8)string("a = \"one\"\n[t]\nk = [1, \"two\"]\ns = 3\n"), .Toml_1_0, &bad, &plan, read = {sink = &sink}, allocator = context.temp_allocator)
	testing.expect(t, refused != nil)
	testing.expect_value(t, len(sink.errors), 3)
}

@(test)
a_built_value_is_written_as_a_document :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	root := core.new_object()
	core.object_put(root, "n", 1.5)
	table := core.new_object()
	core.object_put(table, "s", "x")
	core.object_put(root, "t", table)
	text, err := write.write_value(root, toml.as(.Toml_1_0))
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(text), "n = 1.5\n\n[t]\ns = \"x\"\n")
}

// A token write lays its text out once it is whole, so it refuses a stream, where a typed write lays out into one.
@(test)
a_token_write_refuses_a_stream :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	out := strings.builder_make(context.temp_allocator)
	w: write.Tokens
	testing.expect_value(t, write.tokens_init(&w, toml.as(.Toml_1_0), allocator = context.temp_allocator, stream = strings.to_stream(&out)), core.Typed_Error_Kind.Unsupported)
	_, err := write.tokens_finish(&w)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Unsupported)
	testing.expect_value(t, strings.builder_len(out), 0)
	Point :: struct {
		x: int,
		p: struct {
			y: f64,
		},
	}
	plan, perr := toml.plan_make(Point, reads = toml.reads(.Toml_1_0))
	defer typed.plan_destroy(&plan)
	walktest.expect_nil(t, perr)
	walktest.expect_nil(t, write.marshal_stream(strings.to_stream(&out), Point{x = 1, p = {y = 2}}, &plan, allocator = context.temp_allocator))
	testing.expect_value(t, strings.to_string(out), "x = 1\n\n[p]\ny = 2.0\n")
}
