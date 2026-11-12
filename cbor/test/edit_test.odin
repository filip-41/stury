// CBOR edits: items set, inserted, removed and reordered with every other byte kept, the heads of the containers around
// them rewritten, tags kept or edited, and the results a spec refuses.
package cbor_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import cbor ".."
import walktest "../../walktest"

@(private)
Set_Case :: struct {
	src:  string,
	spec: cbor.Spec,
	path: string,
	raw:  string, // the hex of the item set, or empty to set `value`
	want: string, // the hex of the result, or the error's kind
}

// A set through a path, of an item's bytes or of a value CBOR writes, under a spec bound at compile time and one chosen
// at run time.
@(test)
set_through_a_path :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cases := [?]Set_Case {
		// a value in place, and a missing member after the last
		{"a2 61 61 01 61 62 02", .Cbor, ".a", "05", "a2 61 61 05 61 62 02"},
		{"a1 61 61 01", .Cbor, ".b", "02", "a2 61 61 01 61 62 02"},
		{"82 01 02", .Preferred, ".[2]", "03", "83 01 02 03"},
		// a head keeps its width under `.Cbor`, and grows when the count needs it
		{"98 02 01 02", .Cbor, ".[2]", "03", "98 03 01 02 03"},
		{"97 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16", .Cbor, ".[23]", "17", "98 18 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17"},
		// an indefinite container keeps its break and needs no count
		{"bf 61 61 01 ff", .Cbor, ".b", "02", "bf 61 61 01 61 62 02 ff"},
		{"9f 01 7f 61 61 ff ff", .Cbor, ".[0]", "0a", "9f 0a 7f 61 61 ff ff"},
		// a nested container and the containers around it
		{"a1 61 61 a1 61 62 80", .Cbor, ".a.b[0]", "01", "a1 61 61 a1 61 62 81 01"},
		// a tag stays with its item, and a bignum's own tag goes with its number
		{"a1 61 74 c1 05", .Cbor, ".t", "06", "a1 61 74 c1 06"},
		{"a1 61 6e c2 41 01", .Cbor, ".n", "01", "a1 61 6e 01"},
		// a deterministic map writes its members in key order
		{"a2 61 61 01 61 63 03", .Deterministic, ".b", "02", "a3 61 61 01 61 62 02 61 63 03"},
		{"a2 61 63 03 62 61 61 01", .Length_First, ".b", "02", "a3 61 62 02 61 63 03 62 61 61 01"},
		// a value CBOR writes
		{"a1 61 61 01", .Preferred, ".a", "", "a1 61 61 63 74 77 6f"},
		// refusals
		{"a1 61 61 01", .Cbor, ".a", "1a 00", "Bad_Value"},
		{"a1 61 74 c1 05", .Cbor, ".t", "61 78", "Bad_Result"},
		{"a1 61 61 01", .Preferred, ".a", "18 05", "Bad_Value"},
	}
	for c in cases {
		path, perr := core.parse_path(c.path)
		walktest.expect_nil(t, perr)
		defer core.path_destroy(&path)
		v: any = "two"
		if c.raw != "" {
			v = typed.Raw(string(hex(c.raw)))
		}
		got := [2]string{}
		for chosen, k in ([]bool{false, true}) {
			out: []u8
			err: core.Error
			switch {
			case chosen:
				out, err = cbor.set(hex(c.src), c.spec, path, v)
			case c.spec == .Cbor:
				out, err = cbor.set(hex(c.src), .Cbor, path, v)
			case c.spec == .Preferred:
				out, err = cbor.set(hex(c.src), .Preferred, path, v)
			case c.spec == .Deterministic:
				out, err = cbor.set(hex(c.src), .Deterministic, path, v)
			case:
				out, err = cbor.set(hex(c.src), .Length_First, path, v)
			}
			got[k] = kind_of(err) if err != nil else spaced(out)
		}
		testing.expectf(t, got[0] == c.want && got[1] == c.want, "%s %v %s: %v, want %s", c.src, c.spec, c.path, got, c.want)
	}
}

// The bytes `p` as the hex the cases spell, a space between two bytes.
@(private)
spaced :: proc(p: []u8) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c, i in p {
		fmt.sbprintf(&b, " %02x" if i > 0 else "%02x", c)
	}
	return strings.to_string(b)
}

// The kind of an edit's refusal, or the error as it prints.
@(private)
kind_of :: proc(err: core.Error) -> string {
	if e, refused := err.(core.Document_Error); refused {
		return fmt.tprint(e.kind)
	}
	return fmt.tprint(err)
}

@(private)
Edit_Plan :: proc(list: ^core.Edit_List, doc: ^core.Document) -> core.Error

// The hex of the item `src` becomes when `plan` records its edits and the list is committed, or the error's kind.
@(private)
edited :: proc(src: string, plan: Edit_Plan, spec := cbor.Spec.Cbor) -> string {
	doc, berr := cbor.build(hex(src), spec, allocator = context.temp_allocator)
	if berr != nil {
		return kind_of(berr)
	}
	list := cbor.edit_list_init(&doc, spec, context.temp_allocator)
	if perr := plan(&list, &doc); perr != nil {
		return kind_of(perr)
	}
	out, _, cerr := compose.commit(&list, allocator = context.temp_allocator)
	if cerr != nil {
		return kind_of(cerr)
	}
	return spaced(out)
}

@(private)
element :: proc(doc: ^core.Document, c: core.Node_Index, k: int) -> core.Node_Index {
	v, _ := core.child_at(doc, c, k)
	return v
}

// Removals and inserts change the count in a container's head, and a reorder moves members with the edits inside them.
@(test)
members_are_removed_inserted_and_reordered :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	testing.expect_value(t, edited("83 01 02 03", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.remove(l, element(d, core.ROOT, 1))
	}), "82 01 03")
	testing.expect_value(t, edited("a2 61 61 01 61 62 02", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.remove(l, element(d, core.ROOT, 0))
	}), "a1 61 62 02")
	testing.expect_value(t, edited("83 01 02 03", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		core.insert_input(l, core.ROOT, 0, "", false, {text = "\x0a", raw = true}) or_return
		core.remove(l, element(d, core.ROOT, 0)) or_return
		return core.insert_input(l, core.ROOT, 3, "", false, {text = "\x0b", raw = true})
	}), "84 0a 02 03 0b")
	testing.expect_value(t, edited("83 01 82 02 03 04", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		core.set_text(l, element(d, element(d, core.ROOT, 1), 0), "\x05") or_return
		return core.reorder(l, core.ROOT, {2, 1, 0})
	}), "83 04 82 05 03 01")
	testing.expect_value(t, edited("82 01 02", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		core.insert_input(l, core.ROOT, 2, "", false, {text = "\x03", raw = true}) or_return
		return core.reorder(l, core.ROOT, {2, 0})
	}), "Bad_Index")
	testing.expect_value(t, edited("82 01 02", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		core.remove(l, element(d, core.ROOT, 0)) or_return
		return core.reorder(l, core.ROOT, {1})
	}), "81 02")
	// A member's key takes a new name, and a member is inserted with a key.
	testing.expect_value(t, edited("a1 01 02", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		core.set_text(l, element(d, core.ROOT, 0) - 1, "k") or_return
		return core.insert_input(l, core.ROOT, 0, "a", true, {text = "\xf5", raw = true})
	}), "a2 61 61 f5 61 6b 02")
}

// Edits that meet are refused at the byte they share.
@(test)
edits_that_meet_conflict :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	testing.expect_value(t, edited("81 82 01 02", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		core.set_text(l, element(d, core.ROOT, 0), "\x00") or_return
		return core.set_text(l, element(d, element(d, core.ROOT, 0), 1), "\x00")
	}), "Conflicting_Edits")
	testing.expect_value(t, edited("82 81 01 02", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		core.remove(l, element(d, core.ROOT, 0)) or_return
		return core.insert_input(l, element(d, core.ROOT, 0), 0, "", false, {text = "\x00", raw = true})
	}), "Conflicting_Edits")
	testing.expect_value(t, edited("82 01 02", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		core.remove(l, element(d, core.ROOT, 0)) or_return
		return core.remove(l, element(d, core.ROOT, 0))
	}), "Conflicting_Edits")
}

// A tag edit replaces the tags an item has, a bignum keeping its own, and a fact CBOR has no place for is dropped.
@(test)
tags_are_edited_as_facts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	testing.expect_value(t, edited("81 01", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.set_fact(l, element(d, core.ROOT, 0), .Tag, "55799")
	}), "81 d9 d9 f7 01")
	testing.expect_value(t, edited("81 d9 d9 f7 d8 21 01", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.set_fact(l, element(d, core.ROOT, 0), .Tag, "32")
	}), "81 d8 20 01")
	testing.expect_value(t, edited("81 d8 20 01", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.remove_fact(l, element(d, core.ROOT, 0), .Tag)
	}), "81 01")
	testing.expect_value(t, edited("81 d8 20 c2 41 01", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.set_fact(l, element(d, core.ROOT, 0), .Tag, "33")
	}), "81 d8 21 c2 41 01")
	testing.expect_value(t, edited("81 01", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.set_fact(l, element(d, core.ROOT, 0), .Tag, "x")
	}), "Bad_Fact")
	doc, _ := cbor.build(hex("81 01"), .Cbor)
	list := cbor.edit_list_init(&doc, .Cbor)
	walktest.expect_nil(t, core.set_fact(&list, element(&doc, core.ROOT, 0), .Comment, "note"))
	out, dropped, err := compose.commit(&list)
	walktest.expect_nil(t, err)
	testing.expectf(t, spaced(out) == "81 01" && dropped == 1, "% 2x %d", out, dropped)
}

// A value taken from the document keeps its bytes but not its tags, and a value spelled as the item is still set.
@(test)
values_from_the_document :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	testing.expect_value(t, edited("82 41 01 d8 20 7f 61 61 ff", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.set_value(l, element(d, core.ROOT, 0), core.Node_Ref{d, element(d, core.ROOT, 1)})
	}), "82 7f 61 61 ff d8 20 7f 61 61 ff")
	testing.expect_value(t, edited("81 41 01", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.set_value(l, element(d, core.ROOT, 0), f64(1))
	}), "81 01")
	doc, _ := cbor.build(hex("d8 20 7f 61 61 ff"), .Cbor)
	out, _, err := cbor.write(&doc, .Cbor)
	walktest.expect_nil(t, err)
	testing.expect_value(t, spaced(out), "d8 20 7f 61 61 ff")
}
