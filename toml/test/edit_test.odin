// TOML edits: values, members and elements changed in place, lines and sections placed and removed with the comments
// above them, comment facts, and the edits the TOML spelling refuses.
package toml_tests

import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import write "../../core/write"
import toml ".."
import walktest "../../walktest"

@(private)
Plan :: proc(list: ^core.Edit_List, doc: ^core.Document) -> core.Error

// The member of table `parent` named `name`, or `core.NO_NODE`.
@(private)
member :: proc(doc: ^core.Document, parent: core.Node_Index, name: string) -> core.Node_Index {
	it := core.pairs(doc, parent)
	buf: [256]u8
	for key, val in core.pair_next(&it) {
		if text, _ := core.text(doc, key, buf[:]); text == name {
			return val
		}
	}
	return core.NO_NODE
}

// The text `src` becomes when `plan` records its edits and the list is committed.
@(private)
edited :: proc(src: string, plan: Plan) -> (out: string, err: core.Error) {
	doc, berr := toml.build(transmute([]u8)src, .Toml_1_1, allocator = context.temp_allocator)
	if berr != nil {
		return "", berr
	}
	list := toml.edit_list_init(&doc, .Toml_1_1, context.temp_allocator)
	if perr := plan(&list, &doc); perr != nil {
		return "", perr
	}
	bytes, _, cerr := compose.commit(&list, allocator = context.temp_allocator)
	return string(bytes), cerr
}

@(test)
set_replaces_a_value_and_keeps_the_rest :: proc(t: ^testing.T) {
	out, err := edited("# top\na = 1 # note\nb = \"x\"\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, member(d, core.ROOT, "a"), typed.Raw("22"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "# top\na = 22 # note\nb = \"x\"\n")
}

@(test)
set_through_a_path :: proc(t: ^testing.T) {
	src := "[t]\nk = [1, 2, 3]\n\n[u]\nz = true\n"
	out, err := toml.set(transmute([]u8)src, .Toml_1_1, core.Path{steps = {core.Name("t"), core.Name("k"), core.Index(1)}}, typed.Raw("20"), allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(out), "[t]\nk = [1, 20, 3]\n\n[u]\nz = true\n")
}

@(test)
set_refuses_a_table :: proc(t: ^testing.T) {
	_, err := edited("[t]\nk = 1\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, member(d, core.ROOT, "t"), typed.Raw("1"))
	})
	walktest.expect_kind(t, err, core.Document_Error_Kind.Frozen)
}

@(test)
set_refuses_a_result_that_is_not_one_value :: proc(t: ^testing.T) {
	_, err := edited("a = 1\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, member(d, core.ROOT, "a"), typed.Raw("1\nb = 2"))
	})
	walktest.expect_kind(t, err, core.Document_Error_Kind.Bad_Value)
}

@(test)
insert_into_root_goes_before_the_sections :: proc(t: ^testing.T) {
	out, err := edited("a = 1\n\n[t]\nx = 1\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.insert(l, core.ROOT, 1, "b", typed.Raw("2"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a = 1\nb = 2\n\n[t]\nx = 1\n")
}

@(test)
insert_into_a_header_table_goes_after_its_last_line :: proc(t: ^testing.T) {
	out, err := edited("[t]\nx = 1\n\n[u]\ny = 2\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.insert(l, member(d, core.ROOT, "t"), 1, "z", typed.Raw("3"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "[t]\nx = 1\nz = 3\n\n[u]\ny = 2\n")
}

@(test)
insert_into_inline_containers :: proc(t: ^testing.T) {
	out, err := edited("a = [1, 2]\nb = {x = 1}\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		if e := write.insert(l, member(d, core.ROOT, "a"), 2, typed.Raw("3")); e != nil {
			return e
		}
		return write.insert(l, member(d, core.ROOT, "b"), 1, "y", typed.Raw("2"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a = [1, 2, 3]\nb = {x = 1, y = 2}\n")
}

@(test)
remove_takes_the_comment_lines_above :: proc(t: ^testing.T) {
	out, err := edited("# about a\na = 1\nb = 2 # keep\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.remove(l, member(d, core.ROOT, "a"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "b = 2 # keep\n")
}

@(test)
remove_takes_a_section_whole :: proc(t: ^testing.T) {
	out, err := edited("a = 1\n\n# the t table\n[t]\nx = 1\n\n[u]\ny = 2\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.remove(l, member(d, core.ROOT, "t"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a = 1\n\n[u]\ny = 2\n")
}

@(test)
remove_from_an_inline_array :: proc(t: ^testing.T) {
	out, err := edited("a = [1, 2, 3]\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		it := core.children(d, member(d, core.ROOT, "a"))
		core.child_next(&it)
		return core.remove(l, core.child_next(&it) or_else core.NO_NODE)
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a = [1, 3]\n")
}

// Removed elements that end an inline array go with the separators before them, and a new element takes the
// separator of the first gap, or a line of its own after an element that starts a line.
@(test)
inline_arrays_keep_their_separators :: proc(t: ^testing.T) {
	out, err := edited("a = [1, 2, 3]\nb = [1,2]\nc = [\n  1,\n  2\n]\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		a := member(d, core.ROOT, "a")
		for k in 1 ..= 2 {
			v, _ := core.child_at(d, a, k)
			core.remove(l, v) or_return
		}
		write.insert(l, member(d, core.ROOT, "b"), 2, typed.Raw("3")) or_return
		return write.insert(l, member(d, core.ROOT, "c"), 2, typed.Raw("3"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a = [1]\nb = [1,2,3]\nc = [\n  1,\n  2,\n  3\n]\n")
}

@(test)
rename_a_key :: proc(t: ^testing.T) {
	out, err := edited("a = 1 # n\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		it := core.pairs(d, core.ROOT)
		key, _, _ := core.pair_next(&it)
		return write.set(l, key, typed.Raw("a b"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "\"a b\" = 1 # n\n")
}

@(test)
head_comment_is_set_above_the_statement :: proc(t: ^testing.T) {
	out, err := edited("a = 1\nb = 2\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.set_fact(l, member(d, core.ROOT, "b"), .Comment, "about b", padded = true)
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a = 1\n# about b\nb = 2\n")
}

@(test)
inline_comment_is_set_and_removed :: proc(t: ^testing.T) {
	out, err := edited("a = 1\nb = 2 # old\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		if e := core.set_fact(l, member(d, core.ROOT, "a"), .Comment_Inline, "new", padded = true); e != nil {
			return e
		}
		return core.remove_fact(l, member(d, core.ROOT, "b"), .Comment_Inline)
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a = 1 # new\nb = 2\n")
}

@(test)
tag_facts_and_reorders_are_refused :: proc(t: ^testing.T) {
	_, err := edited("a = 1\nb = 2\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.set_fact(l, member(d, core.ROOT, "a"), .Tag, "!x")
	})
	walktest.expect_kind(t, err, core.Document_Error_Kind.Frozen)
	_, err = edited("a = 1\nb = 2\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.reorder(l, core.ROOT, {1, 0})
	})
	walktest.expect_kind(t, err, core.Document_Error_Kind.Frozen)
}

@(test)
two_edits_of_one_node_conflict :: proc(t: ^testing.T) {
	_, err := edited("a = 1\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		a := member(d, core.ROOT, "a")
		if e := write.set(l, a, typed.Raw("2")); e != nil {
			return e
		}
		return write.set(l, a, typed.Raw("3"))
	})
	walktest.expect_kind(t, err, core.Document_Error_Kind.Conflicting_Edits)
}

@(test)
crlf_text_keeps_its_line_ends :: proc(t: ^testing.T) {
	out, err := edited("a = 1\r\n[t]\r\nx = 1\r\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.insert(l, member(d, core.ROOT, "t"), 1, "y", typed.Raw("2"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a = 1\r\n[t]\r\nx = 1\r\ny = 2\r\n")
}

@(test)
remove_takes_every_element_of_an_array_of_tables :: proc(t: ^testing.T) {
	out, err := edited("a = 1\n\n[[p]]\nn = 1\n\n[[p]]\nn = 2\n\n[[p]]\nn = 3\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.remove(l, member(d, core.ROOT, "p"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a = 1\n")
}

@(test)
removing_every_member_and_inserting_rewrites_the_inline_table :: proc(t: ^testing.T) {
	out, err := edited("a = {x = 1}\nb = [1, 2]\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		a := member(d, core.ROOT, "a")
		it := core.pairs(d, a)
		_, x, _ := core.pair_next(&it)
		if e := core.remove(l, x); e != nil {
			return e
		}
		if e := write.insert(l, a, 0, "y", typed.Raw("2")); e != nil {
			return e
		}
		b := member(d, core.ROOT, "b")
		ch := core.children(d, b)
		for v in core.child_next(&ch) {
			if e := core.remove(l, v); e != nil {
				return e
			}
		}
		return write.insert(l, b, 0, typed.Raw("3"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a = { y = 2 }\nb = [3]\n")
}

@(test)
a_new_table_is_a_section_after_its_parents_sections :: proc(t: ^testing.T) {
	out, err := edited("a = 1\n\n[t]\nk = 1\n\n[t.u]\nj = 1\n\n[v]\ny = 2\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		if e := write.insert(l, member(d, core.ROOT, "t"), 1, "z", typed.Raw("{ a = 1, c = { d = 2 } }")); e != nil {
			return e
		}
		return write.insert(l, core.ROOT, 2, "w", typed.Raw("{ q = 1 }"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a = 1\n\n[t]\nk = 1\n\n[t.u]\nj = 1\n\n[t.z]\na = 1\n\n[t.z.c]\nd = 2\n\n[v]\ny = 2\n\n[w]\nq = 1\n")
}

@(test)
a_new_array_of_tables_is_one_section_per_element :: proc(t: ^testing.T) {
	out, err := edited("a = 1\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.insert(l, core.ROOT, 1, "p", typed.Raw("[{ n = 1, s = { q = 1 } }, { n = 2 }]"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a = 1\n\n[[p]]\nn = 1\n\n[p.s]\nq = 1\n\n[[p]]\nn = 2\n")
}

@(test)
a_new_table_in_an_implicit_table_is_a_section :: proc(t: ^testing.T) {
	out, err := edited("[a.b]\nx = 1\n\n[z]\nq = 1\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.insert(l, member(d, core.ROOT, "a"), 1, "c", typed.Raw("{ y = 2 }"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "[a.b]\nx = 1\n\n[a.c]\ny = 2\n\n[z]\nq = 1\n")
}

@(test)
a_new_table_stays_inline_where_a_section_would_not_join :: proc(t: ^testing.T) {
	out, err := edited("a.b = 1\n[x]\n[[p]]\nn = 1\n[[p]]\nn = 2\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		first := core.children(d, member(d, core.ROOT, "p"))
		elem, _ := core.child_next(&first)
		if e := write.insert(l, member(d, core.ROOT, "a"), 1, "c", typed.Raw("{ y = 2 }")); e != nil {
			return e
		}
		return write.insert(l, elem, 1, "t", typed.Raw("{ y = 2 }"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a.b = 1\na.c = { y = 2 }\n[x]\n[[p]]\nn = 1\nt = { y = 2 }\n[[p]]\nn = 2\n")
}

@(test)
a_new_element_of_an_array_of_tables_takes_its_tables :: proc(t: ^testing.T) {
	out, err := edited("[[p]]\nn = 1\n[p.s]\nq = 1\n\n[[p]]\nn = 2\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.insert(l, member(d, core.ROOT, "p"), 2, typed.Raw("{ n = 3, s = { q = 9 } }"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "[[p]]\nn = 1\n[p.s]\nq = 1\n\n[[p]]\nn = 2\n\n[[p]]\nn = 3\n\n[p.s]\nq = 9\n")
}

@(test)
a_new_table_in_crlf_text_keeps_its_line_ends :: proc(t: ^testing.T) {
	out, err := edited("a = 1\r\n[t]\r\nx = 1\r\n", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.insert(l, core.ROOT, 2, "u", typed.Raw("{ y = 2 }"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "a = 1\r\n[t]\r\nx = 1\r\n\r\n[u]\r\ny = 2\r\n")
}
