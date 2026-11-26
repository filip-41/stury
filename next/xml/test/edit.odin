package xml_tests

import "base:runtime"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:testkit"
import "stury:xml"

@(test)
xml_edit_preserves_attrs_pi_cdata_and_edits_attrs :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string(`<?pi keep?><!-- lead --><root><a B='1' c="2">old</a><keep><![CDATA[raw <tag>]]></keep></root>`)
	doc, err := xml.build(src, .Xml, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	ov: xml.Overlay
	testing.expect(t, xml.edit_init(&ov, &doc, alloc) == nil)
	defer xml.edit_destroy(&ov)

	// Edit `<a>` text, update attribute `B` (preserving single quotes & case!), add `id`, delete `c`.
	ha, e1 := edit.set_path(&ov, {tape.Name("root"), tape.Name("a")}, edit.val_string("new & safe"))
	testing.expect(t, e1 == nil)
	testing.expect(t, edit.set_fact(&ov, ha, .Attribute, {"99"}, "B") == nil)
	testing.expect(t, edit.set_fact(&ov, ha, .Attribute, {"x1"}, "id") == nil)
	testing.expect(t, edit.del_fact(&ov, ha, .Attribute, "c") == nil)

	res, cerr := xml.commit(&ov, {}, alloc)
	testing.expect(t, cerr == nil)
	defer edit.destroy_commit_result(&res)

	got := string(res.bytes)
	testing.expect(t, strings.has_prefix(got, `<?pi keep?><!-- lead --><root>`))
	testing.expect(t, strings.contains(got, `<a B='99' id="x1">new &amp; safe</a>`))
	testing.expect(t, strings.contains(got, `<keep><![CDATA[raw <tag>]]></keep>`))
}

@(test)
xml_edit_reorder_self_closing_and_group1_refusals :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// Reorder child elements & expand self-closing element.
	{
		src := transmute([]u8)string(`<root><a/><b>2</b><c>3</c></root>`)
		doc, err := xml.build(src, .Xml, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: xml.Overlay
		testing.expect(t, xml.edit_init(&ov, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov)

		_, e1 := edit.set_path(&ov, {tape.Name("root"), tape.Name("a")}, edit.val_string("1"))
		testing.expect(t, e1 == nil)
		rn, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "root")
		rh, _ := edit.handle_for_base(&ov, rn)
		testing.expect(t, edit.reorder(&ov, rh, {2, 1, 0}) == nil)

		res, cerr := xml.commit(&ov, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), `<root><c>3</c><b>2</b><a>1</a></root>`)
	}

	// Group 1 refusals (must stay refused even under `reflow = true`!):
	// 1. XML comment containing `--`
	// 2. Invalid XML attribute/element name
	// 3. Array as document root
	// 4. Empty array on element
	{
		src := transmute([]u8)string(`<root><a>1</a></root>`)
		doc, err := xml.build(src, .Xml, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		// `--` in comment
		ov1: xml.Overlay
		testing.expect(t, xml.edit_init(&ov1, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov1)
		rn, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "root")
		an, _ := tape.member(tape.Reader{doc = &doc}, rn, "a")
		ha1, _ := edit.handle_for_base(&ov1, an)
		_ = edit.set_fact(&ov1, ha1, .Comment, {"bad -- comment"})
		_, ec := xml.commit(&ov1, {reflow = true}, alloc)
		rc, okc := ec.(edit.Refusal)
		testing.expect(t, okc && rc.kind == .Bad_Xml_Comment && rc.group == .Format_Impossible)

		// Invalid XML attribute name
		ov2: xml.Overlay
		testing.expect(t, xml.edit_init(&ov2, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov2)
		ha2, _ := edit.handle_for_base(&ov2, an)
		_ = edit.set_fact(&ov2, ha2, .Attribute, {"v"}, "1bad")
		_, en := xml.commit(&ov2, {reflow = true}, alloc)
		rn2, okn := en.(edit.Refusal)
		testing.expect(t, okn && rn2.kind == .Bad_Name && rn2.group == .Format_Impossible)

		// Array as document root
		ov3: xml.Overlay
		testing.expect(t, xml.edit_init(&ov3, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov3)
		rh3, _ := edit.ensure_root(&ov3)
		_ = edit.set(&ov3, rh3, edit.val_array())
		_, er := xml.commit(&ov3, {reflow = true}, alloc)
		rr3, okr := er.(edit.Refusal)
		testing.expect(t, okr && rr3.kind == .Root_Shape && rr3.group == .Format_Impossible)

		// Empty array on element
		ov4: xml.Overlay
		testing.expect(t, xml.edit_init(&ov4, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov4)
		ha4, _ := edit.handle_for_base(&ov4, an)
		_ = edit.set(&ov4, ha4, edit.val_array())
		_, ea := xml.commit(&ov4, {reflow = true}, alloc)
		ra4, oka := ea.(edit.Refusal)
		testing.expect(t, oka && ra4.kind == .Empty_Markup_Array && ra4.group == .Format_Impossible)
	}
}

@(test)
xml_edit_qnames_dtd_attlist_root_foot_multi_insert_and_escapes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. QNames with `:` (`xmlns:ns`, `xml:lang`, `ns:item`), root `.Comment_Foot` after `</root>`, and `\r` / attr escapes.
	{
		src := transmute([]u8)string(`<root xmlns:ns="urn:test"><ns:item xml:lang="en">hi</ns:item></root>`)
		doc, err := xml.build(src, .Xml, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: xml.Overlay
		testing.expect(t, xml.edit_init(&ov, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov)

		ha, e1 := edit.set_path(&ov, {tape.Name("root"), tape.Name("ns:item")}, edit.val_string("line1\rline2"))
		testing.expect(t, e1 == nil)
		testing.expect(t, edit.set_fact(&ov, ha, .Attribute, {"a\tb\nc\rd"}, "ns:attr") == nil)
		root_h, _ := edit.ensure_root(&ov)
		testing.expect(t, edit.set_fact(&ov, root_h, .Comment_Foot, {"epilogue"}, padded = true) == nil)

		res, cerr := xml.commit(&ov, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		got := string(res.bytes)
		testing.expect(t, strings.contains(got, `ns:attr="a&#9;b&#10;c&#13;d"`))
		testing.expect(t, strings.contains(got, `line1&#13;line2`))
		testing.expect(t, strings.has_suffix(got, `</root><!-- epilogue -->`))
	}

	// 2. DTD `<!ATTLIST>` defaulted attribute does NOT corrupt the DTD when setting that attribute explicitly on the element!
	{
		src := transmute([]u8)string(`<!DOCTYPE root [<!ATTLIST a role CDATA "def">]><root><a id="1">hi</a></root>`)
		doc, err := xml.build(src, .Xml, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: xml.Overlay
		testing.expect(t, xml.edit_init(&ov, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov)
		rn, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "root")
		an, _ := tape.member(tape.Reader{doc = &doc}, rn, "a")
		ah, _ := edit.handle_for_base(&ov, an)
		testing.expect(t, edit.set_fact(&ov, ah, .Attribute, {"custom"}, "role") == nil)

		res, cerr := xml.commit(&ov, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		got := string(res.bytes)
		testing.expect(t, strings.contains(got, `<!ATTLIST a role CDATA "def">`))
		testing.expect(t, strings.contains(got, `<a id="1" role="custom">hi</a>`))
	}

	// 3. Multi-child replacement of self-closing `<p/>` expands `<p/>` ONCE cleanly!
	{
		src := transmute([]u8)string(`<root><p/></root>`)
		doc, err := xml.build(src, .Xml, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: xml.Overlay
		testing.expect(t, xml.edit_init(&ov, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov)
		ha, _ := edit.new_node(&ov, edit.val_string("1"))
		hb, _ := edit.new_node(&ov, edit.val_string("2"))
		entries := [2]edit.Object_Entry{{key = "a", value = ha}, {key = "b", value = hb}}
		_, e1 := edit.set_path(&ov, {tape.Name("root"), tape.Name("p")}, edit.val_object(entries[:]))
		testing.expect(t, e1 == nil)

		res, cerr := xml.commit(&ov, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), `<root><p><a>1</a><b>2</b></p></root>`)
	}
}

@(test)
xml_edit_dtd_underflow_uris_delete_insert_and_text_reflow :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. DTD `<!ATTLIST>` default attribute + `In_Place` entity before/after shrinking element via `commit_document`:
	//    must NOT underflow `u64` offsets on nodes/facts sitting BEFORE a shrinking splice!
	{
		src := transmute([]u8)string(`<!DOCTYPE root [<!ATTLIST b role CDATA "def"><!ENTITY e "long-expanded">]><root><a id="1">hi</a><b>&e;</b><c>after</c></root>`)
		doc, err := xml.build(src, .Xml, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: xml.Overlay
		testing.expect(t, xml.edit_init(&ov, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov)
		_, _ = edit.set_path(&ov, {tape.Name("root"), tape.Name("a")}, edit.val_string("x"))
		_, _ = edit.set_path(&ov, {tape.Name("root"), tape.Name("c")}, edit.val_string("much-longer-after"))

		spliced, res, cerr := xml.commit_document(&ov, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)

		fresh, ferr := xml.build(res.bytes, .Xml, {}, alloc)
		testing.expect(t, ferr == nil)
		defer tape.destroy_document(&fresh)
		testing.expect_value(t, len(spliced.nodes), len(fresh.nodes))
		for i in 0 ..< len(fresh.nodes) {
			testing.expect_value(t, spliced.nodes[i].lo, fresh.nodes[i].lo)
		}
	}

	// 2. Equal-count delete + insert attribute edit on element with `Markup_Ext.uris` (`xmlns:ns="urn:&amp;1"`):
	//    `xml.namespace(&spliced, ...)` must stay accurate!
	{
		src := transmute([]u8)string(`<root xmlns:ns="urn:&amp;1"><ns:a old="drop" keep="yes">hi</ns:a></root>`)
		doc, err := xml.build(src, .Xml, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: xml.Overlay
		testing.expect(t, xml.edit_init(&ov, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov)
		rn, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "root")
		an, _ := tape.member(tape.Reader{doc = &doc}, rn, "ns:a")
		ah, _ := edit.handle_for_base(&ov, an)
		testing.expect(t, edit.del_fact(&ov, ah, .Attribute, "old") == nil)
		testing.expect(t, edit.set_fact(&ov, ah, .Attribute, {"x1"}, "id") == nil)

		spliced, res, cerr := xml.commit_document(&ov, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)

		srn, _ := tape.member(tape.Reader{doc = &spliced}, tape.ROOT, "root")
		san, _ := tape.member(tape.Reader{doc = &spliced}, srn, "ns:a")
		uri, pres := xml.namespace(&spliced, san)
		testing.expect_value(t, pres, tape.Presence.Found)
		testing.expect_value(t, uri, "urn:&1")
	}

	// 3. Delete + insert at index 0 with leading whitespace (`[lead, hi)` merged with `[lo, lo)`) -> no overlap!
	{
		src := transmute([]u8)string("<root>\n  <a>1</a>\n  <b>2</b>\n</root>")
		doc, err := xml.build(src, .Xml, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: xml.Overlay
		testing.expect(t, xml.edit_init(&ov, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov)
		rn, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "root")
		rh, _ := edit.handle_for_base(&ov, rn)
		testing.expect(t, edit.del_member(&ov, rh, "a") == nil)
		_, _ = edit.insert_member(&ov, rh, 0, "c", edit.val_string("3"))

		res, cerr := xml.commit(&ov, {}, alloc)
		testing.expectf(t, cerr == nil, "XML del+ins at 0 failed: %v", cerr)
		defer edit.destroy_commit_result(&res)
		testing.expect(t, strings.contains(string(res.bytes), "<c>3</c>"))
		testing.expect(t, !strings.contains(string(res.bytes), "<a>1</a>"))
		chk, berr := xml.build(res.bytes, .Xml, {}, alloc)
		testing.expect(t, berr == nil)
		tape.destroy_document(&chk)
	}

	// 4. XML element with `#text` runs reordered: refuses with `reflow = false`, succeeds and sets `rewritten` with `reflow = true`!
	{
		src := transmute([]u8)string(`<r>hello<a>1</a>world<b>2</b></r>`)
		doc, err := xml.build(src, .Xml, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: xml.Overlay
		testing.expect(t, xml.edit_init(&ov, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov)
		rn, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "r")
		rh, _ := edit.handle_for_base(&ov, rn)
		testing.expect(t, edit.reorder(&ov, rh, {1, 0, 3, 2}) == nil)

		res0, cerr0 := xml.commit(&ov, {reflow = false}, alloc)
		edit.destroy_commit_result(&res0)
		ref, is_ref := cerr0.(edit.Refusal)
		testing.expect(t, is_ref && ref.kind == .Layout_Reflow_Needed)

		res1, cerr1 := xml.commit(&ov, {reflow = true}, alloc)
		testing.expectf(t, cerr1 == nil, "XML reflow reorder failed: %v", cerr1)
		defer edit.destroy_commit_result(&res1)
		testing.expect_value(t, string(res1.bytes), `<r><a>1</a>hello<b>2</b>world</r>`)
		testing.expect(t, len(res1.rewritten) > 0)
	}
}
