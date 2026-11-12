// YAML edits: a rule per junction of the text, values, members and elements at their indentation, block scalars,
// flow collections, comments and properties kept or written, and the edits refused; then the yaml-test-suite law that
// every node set to its own text gives the source back and set to another value reads back with only that change.
package yaml_tests

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import records "../../core/records"
import json_pkg "../../json"
import walktest "../../walktest"
import yaml ".."

@(private = "file")
Op :: enum u8 {
	Set,
	Insert,
	Remove,
	Fact,
	Unfact,
}

// One edit of `src` at the node `path` names, a dotted run of keys and indexes, with the text it gives or the code of
// the refusal.
@(private = "file")
Rule :: struct {
	src:     string,
	op:      Op,
	path:    string,
	text:    string,
	key:     string,
	at:      int,
	role:    core.Role,
	want:    string,
	refused: string,
}

@(private = "file")
node_at :: proc(doc: ^core.Document, path: string) -> core.Node_Index {
	i := core.ROOT
	if path == "" {
		return i
	}
	for step in strings.split(path, ".", context.temp_allocator) {
		if k, is_index := strconv.parse_int(step); is_index {
			i, _ = core.child_at(doc, i, k)
		} else if step == "@key" {
			i -= 1
		} else {
			i, _ = core.member(doc, i, step)
		}
	}
	return i
}

// The refusal `err` holds as an edit gives it: a fault of the text is `.Walk` with the fault in `inner`.
@(private = "file")
document_error :: proc(err: core.Error) -> core.Document_Error {
	switch e in err {
	case core.Document_Error:
		return e
	case core.Fault:
		return {kind = .Walk, at = e.at, inner = e}
	case runtime.Allocator_Error:
		return {kind = .No_Memory}
	case core.Path_Error, core.Typed_Error, core.Typed_Error_Kind:
		return {kind = .Bad_Value}
	case nil:
	}
	return {}
}

// Records `text`, a value as the caller spelled it, as the value or the key of `node`.
@(private = "file")
set :: proc(list: ^core.Edit_List, node: core.Node_Index, text: string) -> core.Document_Error {
	return document_error(core.set_text(list, node, text))
}

@(private = "file")
commit :: proc(list: ^core.Edit_List) -> (out: []u8, dropped: int, err: core.Document_Error) {
	refusal: core.Error
	out, dropped, refusal = compose.commit(list, allocator = context.temp_allocator)
	return out, dropped, document_error(refusal)
}

// The text `r` makes of its source, or its error.
@(private = "file")
apply :: proc(r: Rule, opts := yaml.Options{}) -> (out: string, err: core.Document_Error) {
	doc, built := core.build(transmute([]u8)r.src, yaml.as(.Yaml_1_2, opts), allocator = context.temp_allocator)
	if built != nil {
		return "", document_error(built)
	}
	list := core.edit_list_init(&doc, context.temp_allocator)
	n := node_at(&doc, r.path)
	switch r.op {
	case .Set:
		err = set(&list, n, r.text)
	case .Insert:
		err = insert(&list, n, r.at, r.key, core.kind(&doc, n) == .Object, r.text)
	case .Remove:
		err = document_error(core.remove(&list, n))
	case .Fact:
		err = document_error(core.set_fact(&list, n, r.role, r.text, padded = true))
	case .Unfact:
		err = document_error(core.remove_fact(&list, n, r.role))
	}
	if err.kind != .None {
		return "", err
	}
	bytes, _, cerr := commit(&list)
	return string(bytes), cerr
}

@(private = "file")
expect_rules :: proc(t: ^testing.T, rules: []Rule, opts := yaml.Options{}, loc := #caller_location) {
	for r in rules {
		out, err := apply(r, opts)
		if r.refused != "" {
			code := core.rule_of(err.inner).code if err.inner.rules != nil else fmt.tprint(err.kind)
			testing.expectf(t, code == r.refused, "%q %v %s: refused %s, want %s", r.src, r.op, r.path, code, r.refused, loc = loc)
			continue
		}
		testing.expectf(t, err.kind == .None && out == r.want, "%q %v %s %q:\n got %q (%v)\nwant %q", r.src, r.op, r.path, r.text, out, err.kind, r.want, loc = loc)
	}
}

@(test)
scalars_are_set_in_their_place :: proc(t: ^testing.T) {
	expect_rules(t, {
		{src = "a: 1  # c\nb: 2\n", path = "a", text = "2", want = "a: 2  # c\nb: 2\n"},
		{src = "a: 1\nb: 2", path = "b", text = "'x'", want = "a: 1\nb: 'x'"},
		{src = "- x\n- y\n", path = "1", text = "z", want = "- x\n- z\n"},
		{src = "a:\nb: 1\n", path = "a", text = "2", want = "a: 2\nb: 1\n"},
		{src = "a:\n  1\nb: 2\n", path = "a", text = "3", want = "a:\n  3\nb: 2\n"},
		{src = "a: one\n  two\nb: 1\n", path = "a", text = "x", want = "a: x\nb: 1\n"},
		{src = "a: x\n", path = "a", text = "\"line\n  two\"", want = "a: \"line\n  two\"\n"},
		{src = "--- # c\na: 1\n...\n", path = "a", text = "2", want = "--- # c\na: 2\n...\n"},
		{src = "a: 1\n", path = "", text = "- 1", want = "- 1\n"},
		{src = "a: !!str 1\n", path = "a", text = "x", want = "a: !!str x\n"},
		{src = "a: 1\n", path = "a.@key", text = "b", want = "b: 1\n"},
		{src = "a: 1\n", path = "a.@key", text = "x: y", want = "'x: y': 1\n"},
		{src = "f: {a: 1}\n", path = "f.a.@key", text = "b, c", want = "f: {'b, c': 1}\n"},
	})
}

@(test)
block_scalars_are_replaced_whole :: proc(t: ^testing.T) {
	expect_rules(t, {
		{src = "a: |\n  one\n  two\nb: 1\n", path = "a", text = "x", want = "a: x\nb: 1\n"},
		{src = "a: |+\n  one\n\n", path = "a", text = "x", want = "a: x\n"},
		{src = "a: >-\n  one\n  two\nb: 1\n", path = "a", text = "|-\n  x\n  y", want = "a: |-\n  x\n  y\nb: 1\n"},
		{src = "a: x\nb: 1\n", path = "a", text = "|\n  x\n  y\n", want = "a: |\n  x\n  y\nb: 1\n"},
		{src = "- |\n  one\n- 2\n", path = "0", text = ">\n  z\n", want = "- >\n  z\n- 2\n"},
		{src = "a: 1\n", path = "a", text = "|-\n  x", want = "a: |-\n  x\n"},
	})
}

@(test)
collections_take_block_form_at_the_site :: proc(t: ^testing.T) {
	expect_rules(t, {
		{src = "a: 1  # c\nb: 2\n", path = "a", text = "k: 1\nl: 2", want = "a:  # c\n  k: 1\n  l: 2\nb: 2\n"},
		{src = "a: 1\n", path = "a", text = "- 1\n- 2", want = "a:\n  - 1\n  - 2\n"},
		{src = "l:\n- x\na: 1\n", path = "a", text = "- 1\n- 2", want = "l:\n- x\na:\n- 1\n- 2\n"},
		{src = "top:\n    a: 1\n", path = "top.a", text = "k: 1\nl:\n  - 2", want = "top:\n    a:\n        k: 1\n        l:\n          - 2\n"},
		{src = "a:\n  k: 1\nb: 2\n", path = "a", text = "3", want = "a: 3\nb: 2\n"},
		{src = "a: !t\n  k: 1\n", path = "a", text = "3", want = "a: !t 3\n"},
		{src = "a:  # c\n  k: 1\n", path = "a", text = "3", want = "a: 3 # c\n"},
		{src = "- x\n- y\n", path = "0", text = "k: 1\nl: 2", want = "- k: 1\n  l: 2\n- y\n"},
		{src = "- x\n", path = "0", text = "- 1\n- 2", want = "- - 1\n  - 2\n"},
		{src = "a:\n  - 1\n", path = "a", text = "k: v", want = "a:\n  k: v\n"},
		{src = "c: {p: q}\n", path = "c", text = "- 1", want = "c: [1]\n"},
		{src = "a:\nb: 1\n", path = "a", text = "k: v", want = "a:\n  k: v\nb: 1\n"},
		{src = "k: 1\n", path = "", text = "- 1\n- 2", want = "- 1\n- 2\n"},
	})
}

@(test)
block_members_go_at_their_indentation :: proc(t: ^testing.T) {
	expect_rules(t, {
		{src = "a: 1\nb: 2\n", op = .Insert, at = 2, key = "c", text = "3", want = "a: 1\nb: 2\nc: 3\n"},
		{src = "a: 1\nb: 2", op = .Insert, at = 2, key = "c", text = "3", want = "a: 1\nb: 2\nc: 3"},
		{src = "a: 1\nb: 2\n", op = .Insert, at = 0, key = "c", text = "3", want = "c: 3\na: 1\nb: 2\n"},
		{src = "a: 1\nb: 2\n", op = .Insert, at = 1, key = "c", text = "k: v", want = "a: 1\nc:\n  k: v\nb: 2\n"},
		{src = "top:\n    a: 1\n", op = .Insert, path = "top", at = 1, key = "b", text = "x", want = "top:\n    a: 1\n    b: x\n"},
		{src = "top:\n    a: 1\n", op = .Insert, path = "top", at = 1, key = "b", text = "!!map\nk: v", want = "top:\n    a: 1\n    b: !!map\n        k: v\n"},
		{src = "l:\n  - x\n", op = .Insert, path = "l", at = 1, text = "y", want = "l:\n  - x\n  - y\n"},
		{src = "l:\n- x\n", op = .Insert, path = "l", at = 0, text = "k: 1\nm: 2", want = "l:\n- k: 1\n  m: 2\n- x\n"},
		{src = "- a: 1\n  b: 2\n", op = .Insert, path = "0", at = 2, key = "z", text = "1", want = "- a: 1\n  b: 2\n  z: 1\n"},
		{src = "- a: 1\n  b: 2\n", op = .Insert, path = "0", at = 0, key = "z", text = "1", want = "- z: 1\n  a: 1\n  b: 2\n"},
		{src = "a:\n  k: 1\n  # inner\nb: 2\n", op = .Insert, path = "a", at = 1, key = "l", text = "2", want = "a:\n  k: 1\n  l: 2\n  # inner\nb: 2\n"},
		{src = "a: 1\r\nb: 2\r\n", op = .Insert, at = 2, key = "c", text = "k: v", want = "a: 1\r\nb: 2\r\nc:\r\n  k: v\r\n"},
		{src = "a: 1\r\n", path = "a", text = "k: 1\nl: 2", want = "a:\r\n  k: 1\r\n  l: 2\r\n"},
	})
}

@(test)
block_members_go_with_their_lines :: proc(t: ^testing.T) {
	expect_rules(t, {
		{src = "a: 1\n# about b\nb: 2\nc: 3\n", op = .Remove, path = "b", want = "a: 1\nc: 3\n"},
		{src = "a: 1\nb: 2\n# foot\n", op = .Remove, path = "b", want = "a: 1\n# foot\n"},
		{src = "a: 1\nb:\n  k: 1\n  # inner\nc: 3\n", op = .Remove, path = "b", want = "a: 1\nc: 3\n"},
		{src = "m:\n  a: 1\nn: 2\n", op = .Remove, path = "m.a", want = "m: {}\nn: 2\n"},
		{src = "l:\n  - 1\n", op = .Remove, path = "l.0", want = "l: []\n"},
		{src = "- a: 1\n  b: 2\n", op = .Remove, path = "0.a", want = "- b: 2\n"},
		{src = "- a: 1\n  b: 2\n", op = .Remove, path = "0.b", want = "- a: 1\n"},
		{src = "- a: 1\n- b: 2\n", op = .Remove, path = "0", want = "- b: 2\n"},
		{src = "- x\n- y", op = .Remove, path = "1", want = "- x\n"},
		{src = "a: 1\r\nb: 2\r\n", op = .Remove, path = "a", want = "b: 2\r\n"},
	})
}

@(test)
flow_members_take_their_separators :: proc(t: ^testing.T) {
	expect_rules(t, {
		{src = "f: [1, 2, 3]\n", op = .Remove, path = "f.1", want = "f: [1, 3]\n"},
		{src = "f: [1, 2, 3]\n", op = .Remove, path = "f.2", want = "f: [1, 2]\n"},
		{src = "f: [1,2]\n", op = .Insert, path = "f", at = 2, text = "3", want = "f: [1,2,3]\n"},
		{src = "f: [1, 2]\n", op = .Insert, path = "f", at = 0, text = "0", want = "f: [0, 1, 2]\n"},
		{src = "m: {}\n", op = .Insert, path = "m", at = 0, key = "a", text = "1", want = "m: {a: 1}\n"},
		{src = "m: []\n", op = .Insert, path = "m", at = 0, text = "k: v", want = "m: [{k: v}]\n"},
		{src = "f: {a: 1}\n", path = "f.a", text = "- 1\n- 2", want = "f: {a: [1, 2]}\n"},
		{src = "f: {a: 1}\n", path = "f.a", text = "a, b", want = "f: {a: 'a, b'}\n"},
		{src = "f: {a: 1, b: 2}\n", op = .Remove, path = "f.a", want = "f: {b: 2}\n"},
		{src = "f: [[1], {k: v}]\n", op = .Remove, path = "f.0", want = "f: [{k: v}]\n"},
		{src = "f: [a: 1]\n", op = .Insert, path = "f.0", at = 1, key = "b", text = "2", refused = "implicit_pair"},
	})
}

@(test)
comments_and_properties_are_facts :: proc(t: ^testing.T) {
	expect_rules(t, {
		{src = "a: 1\nb: 2\n", op = .Fact, path = "b", role = .Comment, text = "note", want = "a: 1\n# note\nb: 2\n"},
		{src = "a: 1\n# old\nb: 2\n", op = .Fact, path = "b", role = .Comment, text = "new", want = "a: 1\n# new\nb: 2\n"},
		{src = "a: 1\n# old\nb: 2\n", op = .Unfact, path = "b", role = .Comment, want = "a: 1\nb: 2\n"},
		{src = "a: 1\nb: 2\n", op = .Fact, path = "b", role = .Comment_Inline, text = "note", want = "a: 1\nb: 2 # note\n"},
		{src = "a: 1 # old\n", op = .Fact, path = "a", role = .Comment_Inline, text = "new", want = "a: 1 # new\n"},
		{src = "a: 1 # old\n", op = .Unfact, path = "a", role = .Comment_Inline, want = "a: 1\n"},
		{src = "a:\n  k: 1\n", op = .Fact, path = "a", role = .Comment_Foot, text = "end", want = "a:\n  k: 1\n  # end\n"},
		{src = "a: 1\n", op = .Fact, path = "a", role = .Tag, text = "str", want = "a: !str 1\n"},
		{src = "a: 1\n", op = .Fact, path = "a", role = .Tag, text = "!!str", want = "a: !!str 1\n"},
		{src = "a: !!str 1\n", op = .Unfact, path = "a", role = .Tag, want = "a: 1\n"},
		{src = "a: !!str 1\n", op = .Fact, path = "a", role = .Tag, text = "!x", want = "a: !x 1\n"},
		{src = "a:\n  k: 1\n", op = .Fact, path = "a", role = .Anchor, text = "x", want = "a: &x\n  k: 1\n"},
		{src = "- k: 1\n", op = .Fact, path = "0", role = .Anchor, text = "x", want = "- &x\n  k: 1\n"},
		{src = "k: 1\n", op = .Fact, role = .Tag, text = "!!map", want = "!!map\nk: 1\n"},
		{src = "a:\nb: 1\n", op = .Fact, path = "a", role = .Anchor, text = "x", want = "a: &x\nb: 1\n"},
		{src = "a: &x 1\nb: 2\n", op = .Fact, path = "b", role = .Alias, text = "x", want = "a: &x 1\nb: *x\n"},
		{src = "a: &x 1\nc: &y 2\nb: *x\n", op = .Fact, path = "b", role = .Alias, text = "y", want = "a: &x 1\nc: &y 2\nb: *y\n"},
		{src = "a: &x 1\nb: *x\n", op = .Fact, path = "b", role = .Alias, text = "y", refused = "undefined_alias"},
		{src = "f: [1, 2]\n", op = .Fact, path = "f.0", role = .Comment, text = "c", refused = "flow_comment"},
		{src = "a:\n  k: 1\n", op = .Fact, path = "a", role = .Comment_Inline, text = "c", refused = "block_comment"},
	})
}

@(test)
aliases_and_merges_freeze_what_they_read :: proc(t: ^testing.T) {
	expect_rules(t, {
		{src = "a: &x 1\nb: *x\n", path = "a", text = "2", refused = "anchored"},
		{src = "a: &x\n  k: 1\nb: *x\n", path = "a.k", text = "2", refused = "anchored"},
		{src = "a: &x\n  k: 1\nb: *x\n", path = "b.k", text = "2", refused = "aliased"},
		{src = "a: &x\n  k: 1\nb: *x\n", path = "b", text = "2", want = "a: &x\n  k: 1\nb: 2\n"},
		{src = "a: &x\n  k: 1\nb: *x\n", op = .Insert, path = "b", at = 1, key = "l", text = "2", refused = "alias_node"},
		{src = "a: &x 1\nb: 2\n", path = "a", text = "2", want = "a: &x 2\nb: 2\n"},
		{src = "a: 1\nb: 2\n", path = "a", text = "1", op = .Remove, want = "b: 2\n"},
	})
	expect_rules(t, {{src = "a: &x {k: 1}\nb:\n  <<: *x\n  l: 2\n", path = "b.l", text = "3", refused = "merged"}}, {merge_keys = true})
}

@(test)
edits_that_meet_conflict :: proc(t: ^testing.T) {
	doc, _ := build("a: 1\nb:\n  k: 1\n")
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc, context.temp_allocator)
	b, _ := core.member(&doc, core.ROOT, "b")
	k, _ := core.member(&doc, b, "k")
	testing.expect_value(t, set(&list, b, "2").kind, core.Document_Error_Kind.None)
	testing.expect_value(t, set(&list, k, "3").kind, core.Document_Error_Kind.None)
	_, _, err := commit(&list)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Conflicting_Edits)
}

@(test)
texts_that_are_no_value_are_refused :: proc(t: ^testing.T) {
	for text in ([]string{"", " 1", "# c", "1\n---\n2", "%YAML 1.2\n--- 1", "a: 1\n...\n"}) {
		_, err := apply({src = "a: 1\n", path = "a", text = text})
		testing.expectf(t, err.kind == .Bad_Value, "%q: %v", text, err.kind)
	}
}

@(test)
set_through_a_path :: proc(t: ^testing.T) {
	src := "t:\n  k: [1, 2, 3]\nu: true\n"
	out, err := yaml.set(transmute([]u8)src, .Yaml_1_2, core.Path{steps = {core.Name("t"), core.Name("k"), core.Index(1)}}, typed.Raw("20"), allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(out), "t:\n  k: [1, 20, 3]\nu: true\n")
	out, err = yaml.set(transmute([]u8)src, .Yaml_1_2, core.Path{steps = {core.Name("t"), core.Name("z")}}, typed.Raw("x"), allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(out), "t:\n  k: [1, 2, 3]\n  z: x\nu: true\n")
}

// The suite law. `Tally` counts the edits each document took and the ones the spelling refused, by reason.
@(private = "file")
Tally :: struct {
	kept, changed, refused, failed: int,
	reasons:                        map[string]int,
}

@(private = "file")
refusal :: proc(err: core.Document_Error) -> string {
	if err.inner.rules != nil {
		return core.rule_of(err.inner).code
	}
	name, _ := fmt.enum_value_to_string(err.kind)
	return name
}

// Whether `b`'s node `bn` is `a`'s node `an` with node `target` changed by `change`, which says what `target` became.
@(private = "file")
equal_except :: proc(a: ^core.Document, an: core.Node_Index, b: ^core.Document, bn: core.Node_Index, target: core.Node_Index, change: proc(a: ^core.Document, an: core.Node_Index, b: ^core.Document, bn: core.Node_Index, data: rawptr) -> bool, data: rawptr) -> bool {
	if an == target {
		return change(a, an, b, bn, data)
	}
	if target < an || int(target) >= int(an) + subtree(a, an) {
		return core.equal(core.Node_Ref{a, an}, core.Node_Ref{b, bn})
	}
	ka, kb := core.kind(a, an), core.kind(b, bn)
	if ka != kb || core.length(a, an) != core.length(b, bn) {
		return false
	}
	if ka == .Object {
		ia, ib := core.pairs(a, an), core.pairs(b, bn)
		for {
			ak, av, more := core.pair_next(&ia)
			bk, bv, _ := core.pair_next(&ib)
			if !more {
				return true
			}
			if !equal_except(a, ak, b, bk, target, change, data) || !equal_except(a, av, b, bv, target, change, data) {
				return false
			}
		}
	}
	ia, ib := core.children(a, an), core.children(b, bn)
	for {
		av, more := core.child_next(&ia)
		bv, _ := core.child_next(&ib)
		if !more {
			return true
		}
		if !equal_except(a, av, b, bv, target, change, data) {
			return false
		}
	}
}

@(private = "file")
subtree :: proc(doc: ^core.Document, i: core.Node_Index) -> int {
	k := core.kind(doc, i)
	if k != .Object && k != .Array {
		return 1
	}
	return int(doc.nodes[i].n)
}

// A change the law makes to node `node` of `doc`, recorded on `list`, and what the node becomes.
@(private = "file")
Change :: struct {
	text:  string,
	value: ^core.Document,
	key:   string,
	at:    int,
	kind:  Op,
}

@(private = "file")
became :: proc(a: ^core.Document, an: core.Node_Index, b: ^core.Document, bn: core.Node_Index, data: rawptr) -> bool {
	c := (^Change)(data)
	switch c.kind {
	case .Set:
		if a.nodes[an].role == .Key {
			name, _ := core.text_clone(b, bn, context.temp_allocator)
			return name == c.key
		}
		return core.equal(core.Node_Ref{c.value, core.ROOT}, core.Node_Ref{b, bn})
	case .Insert, .Remove:
		if core.kind(a, an) != core.kind(b, bn) || core.length(b, bn) != core.length(a, an) + (1 if c.kind == .Insert else -1) {
			return false
		}
		object := core.kind(a, an) == .Object
		ia, ib := core.children(a, an), core.children(b, bn)
		for k := 0; ; k += 1 {
			if c.kind == .Insert && k == c.at {
				bv, _ := core.child_next(&ib)
				name, _ := core.text_clone(b, bv - 1, context.temp_allocator)
				if !core.equal(core.Node_Ref{c.value, core.ROOT}, core.Node_Ref{b, bv}) || object && name != c.key {
					return false
				}
			}
			av, more := core.child_next(&ia)
			if !more {
				return true
			}
			if c.kind == .Remove && k == c.at {
				continue
			}
			bv, _ := core.child_next(&ib)
			if !core.equal(core.Node_Ref{a, av}, core.Node_Ref{b, bv}) || object && !core.equal(core.Node_Ref{a, av - 1}, core.Node_Ref{b, bv - 1}) {
				return false
			}
		}
	case .Fact, .Unfact:
	}
	return false
}

// Commits the edits on `list` and checks the text against `want` when it is set, else reads it back as `doc` with
// node `node` changed as `c` says.
@(private = "file")
judge_law :: proc(tally: ^Tally, name: string, doc: ^core.Document, list: ^core.Edit_List, node: core.Node_Index, c: ^Change, want: string) {
	out, _, err := commit(list)
	// A kept tag the new value does not fit, and an alias whose anchor an edit took away, are the YAML validate's
	// refusals of the result.
	reason := refusal(err)
	if err.kind == .Frozen || reason == "tag_mismatch" || reason == "undefined_alias" {
		tally.refused += 1
		tally.reasons[reason] += 1
		return
	}
	if err.kind != .None {
		tally.failed += 1
		if tally.failed <= 200 {
			fmt.eprintfln("%s: node %d %v %q: %v %s %q", name, node, c.kind, c.text, err.kind, refusal(err), string(doc.src))
		}
		return
	}
	if want != "" {
		if string(out) != want {
			tally.failed += 1
			if tally.failed <= 200 {
				fmt.eprintfln("%s: node %d set to its own text: %q gives %q", name, node, want, string(out))
			}
			return
		}
		tally.kept += 1
		return
	}
	again, aerr := core.build(out, doc.as, allocator = context.temp_allocator)
	if aerr != nil || !equal_except(doc, core.ROOT, &again, core.ROOT, node, became, c) {
		tally.failed += 1
		if tally.failed <= 200 {
			fmt.eprintfln("%s: node %d %v %q reads back otherwise (%v): %q gives %q", name, node, c.kind, c.text, aerr, string(doc.src), string(out))
		}
		return
	}
	tally.changed += 1
}

@(private = "file")
law_document :: proc(tally: ^Tally, name: string, doc: ^core.Document) {
	values: [2]core.Document
	texts := [2]string{"stury", "- 1\n- k: v"}
	for text, k in texts {
		values[k], _ = build(text)
	}
	defer for &v in values {
		core.destroy(&v)
	}
	for i in 0 ..< len(doc.nodes) {
		node := core.Node_Index(i)
		role := doc.nodes[i].role
		if role > .Key {
			continue
		}
		list := core.edit_list_init(doc, context.temp_allocator)
		if role == .Key {
			c := Change{kind = .Set, key = "stury key"}
			if err := set(&list, node, c.key); err.kind != .None {
				tally.refused += 1
				tally.reasons[refusal(err)] += 1
				continue
			}
			judge_law(tally, name, doc, &list, node, &c, "")
			continue
		}
		own, fits := core.services_of(doc.as).edit.relocate(doc, node, {placed = true}, context.temp_allocator)
		if !fits {
			tally.failed += 1
			fmt.eprintfln("%s: node %d does not move", name, node)
			continue
		}
		// An empty value has no text a set takes.
		if len(own) == 0 {
			tally.reasons["empty"] += 1
			continue
		}
		same := Change{kind = .Set, text = string(own)}
		if err := set(&list, node, same.text); err.kind != .None {
			tally.failed += 1
			fmt.eprintfln("%s: node %d own text %q refused: %v", name, node, same.text, err.kind)
			continue
		}
		judge_law(tally, name, doc, &list, node, &same, string(doc.src))
		for &v, k in values {
			c := Change{kind = .Set, text = texts[k], value = &v}
			list = core.edit_list_init(doc, context.temp_allocator)
			set(&list, node, c.text)
			judge_law(tally, name, doc, &list, node, &c, "")
		}
		kind := core.kind(doc, node)
		if kind != .Object && kind != .Array {
			continue
		}
		n := core.length(doc, node)
		for at in ([]int{0, n}) {
			c := Change{kind = .Insert, text = texts[0], value = &values[0], key = "stury key", at = at}
			list = core.edit_list_init(doc, context.temp_allocator)
			if err := insert(&list, node, at, c.key, kind == .Object, c.text); err.kind != .None {
				tally.refused += 1
				tally.reasons[refusal(err)] += 1
				continue
			}
			judge_law(tally, name, doc, &list, node, &c, "")
		}
		for at in 0 ..< n {
			child, _ := core.child_at(doc, node, at)
			c := Change{kind = .Remove, at = at}
			list = core.edit_list_init(doc, context.temp_allocator)
			if err := document_error(core.remove(&list, child)); err.kind != .None {
				tally.refused += 1
				tally.reasons[refusal(err)] += 1
				continue
			}
			judge_law(tally, name, doc, &list, node, &c, "")
		}
	}
}

@(test)
suite_documents_keep_every_byte_an_edit_does_not_reach :: proc(t: ^testing.T) {
	tally := Tally{reasons = make(map[string]int)}
	defer delete(tally.reasons)
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	list: [dynamic]Case
	cases(&list, SUITE_DIR, "")
	documents := 0
	for c in list {
		// A case's reads and edits are freed before the next, so the suite's peak is one case's.
		guard := runtime.default_temp_allocator_temp_begin()
		defer runtime.default_temp_allocator_temp_end(guard)
		src, _ := read_file(c.dir, "in.yaml")
		if _, is_error := read_file(c.dir, "error"); is_error {
			continue
		}
		it := records.open(src, yaml.as(.Yaml_1_2), .Concatenated, allocator = context.temp_allocator)
		for {
			rec, more := records.next(&it)
			if !more {
				break
			}
			doc, err := records.build(&it, rec, context.temp_allocator)
			if err != nil {
				continue
			}
			law_document(&tally, c.name, &doc)
			documents += 1
		}
	}
	fmt.eprintfln("yaml edit law: %d documents, %d kept, %d changed, %d refused %v, %d failed", documents, tally.kept, tally.changed, tally.refused, tally.reasons, tally.failed)
	testing.expect(t, documents > 250)
	testing.expectf(t, tally.failed == 0, "%d edits failed", tally.failed)
}

@(private = "file")
insert :: proc(list: ^core.Edit_List, node: core.Node_Index, at: int, key: string, member: bool, text: string) -> core.Document_Error {
	return document_error(core.insert_input(list, node, at, key if member else "", member, {text = text, raw = true}))
}

// A value the format spells is placed as the text of that value is: block lines at the indentation the text shows
// for its site, flow text inside a flow collection, a string and a key quoted where a plain one would read as another
// type, and a node of the document with its own bytes moved to the site.
@(test)
spelled_values_take_their_site :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	src := "a: 1\nf: [1, 2]\nt:\n    k: v\n"
	held, herr := json_pkg.build(transmute([]u8)string(`{"k":[1,{"m":null}],"s":"x: y"}`), .Json)
	walktest.expect_nil(t, herr)
	value := core.Value(core.Node_Ref{&held, core.ROOT})
	Spelled :: struct {
		path:  string,
		value: any,
		want:  string,
	}
	cases := [?]Spelled {
		{".a", "x y", "a: x y\nf: [1, 2]\nt:\n    k: v\n"},
		{".a", "yes", "a: 'yes'\nf: [1, 2]\nt:\n    k: v\n"},
		{".a", 2.5, "a: 2.5\nf: [1, 2]\nt:\n    k: v\n"},
		{".a", value, "a:\n    k:\n      - 1\n      - m: null\n    s: 'x: y'\nf: [1, 2]\nt:\n    k: v\n"},
		{".f[0]", value, "a: 1\nf: [{k: [1, {m: null}], s: 'x: y'}, 2]\nt:\n    k: v\n"},
		{".t.k", value, "a: 1\nf: [1, 2]\nt:\n    k:\n        k:\n          - 1\n          - m: null\n        s: 'x: y'\n"},
		{".t.n", value, "a: 1\nf: [1, 2]\nt:\n    k: v\n    'n':\n        k:\n          - 1\n          - m: null\n        s: 'x: y'\n"},
	}
	for c in cases {
		path, perr := core.parse_path(c.path)
		walktest.expect_nil(t, perr)
		out, err := yaml.set(transmute([]u8)src, .Yaml_1_2, path, c.value)
		walktest.expect_nil(t, err)
		testing.expectf(t, string(out) == c.want, "%s:\n got %q\nwant %q", c.path, string(out), c.want)
	}
	// A node of the document keeps its bytes, with its lines at the new site's indentation.
	doc, _ := build(src)
	list := core.edit_list_init(&doc)
	a, _ := core.member(&doc, core.ROOT, "a")
	moved, _ := core.member(&doc, core.ROOT, "t")
	walktest.expect_nil(t, core.set_value(&list, a, core.Node_Ref{&doc, moved}))
	out, _, err := commit(&list)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, string(out), "a:\n    k: v\nf: [1, 2]\nt:\n    k: v\n")
}
