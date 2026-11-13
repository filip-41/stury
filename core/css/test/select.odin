// Selectors compiled and matched over xml and html documents: each family, the case rules of each format, scoping
// to a node, and the faults a selector compiles to.
package css_tests

import "core:strings"
import "core:testing"
import core "../.."
import css ".."
import html "../../../html"
import xml "../../../xml"

@(private)
Format :: enum {
	Xml,
	Html,
}

// The elements `selector` matches in `text`, as their names with `#` and their id when they have one.
@(private)
matched :: proc(t: ^testing.T, format: Format, text, selector: string, loc := #caller_location) -> string {
	doc: core.Document
	err: core.Error
	switch format {
	case .Xml:
		doc, err = xml.build(transmute([]u8)text, .Xml)
	case .Html:
		doc, err = html.build(transmute([]u8)text, .Fragment)
	}
	if !testing.expectf(t, err == nil, "%v", err, loc = loc) {
		return ""
	}
	defer core.destroy(&doc)
	return described(t, &doc, selector, core.ROOT, loc)
}

@(private)
described :: proc(t: ^testing.T, doc: ^core.Document, selector: string, from: core.Node_Index, loc := #caller_location) -> string {
	sel, err := css.compile(selector)
	if !testing.expectf(t, err == nil, "%q: %v", selector, err, loc = loc) {
		return ""
	}
	defer css.destroy(&sel)
	found, e := css.select(doc, &sel, from)
	testing.expectf(t, e == nil, "%v", e, loc = loc)
	defer delete(found)
	b := strings.builder_make(context.temp_allocator)
	for v, i in found {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		name, _ := core.token_text(doc.readers, &doc.view, doc.nodes[v - 1], context.temp_allocator)
		strings.write_string(&b, name)
		it := core.attributes_of(doc, v)
		for n, value in core.attribute_next(&it) {
			if s, _ := core.token_text(doc.readers, &doc.view, n, context.temp_allocator); s == "id" {
				id, _ := core.token_text(doc.readers, &doc.view, value, context.temp_allocator)
				strings.write_byte(&b, '#')
				strings.write_string(&b, id)
			}
		}
	}
	return strings.to_string(b)
}

// The fault `selector` compiles to: its detail, `.None` for a selector cut short, and its byte offset.
@(private)
refused :: proc(t: ^testing.T, selector: string, detail: css.Detail, at: u64, loc := #caller_location) {
	sel, err := css.compile(selector)
	defer css.destroy(&sel)
	f, ok := err.(core.Fault)
	if !testing.expectf(t, ok, "%q compiled: %v", selector, err, loc = loc) {
		return
	}
	kind := core.Fault_Kind.Truncated if detail == .None else .Bad_Char
	testing.expectf(t, f.kind == kind && css.Detail(f.detail) == detail && f.at == at, "%q: %v", selector, f, loc = loc)
}

@(private)
BOOK :: `<lib><book id="a" lang="en-GB" class="new  old"><title>A</title><note/></book><mag id="b"/><book id="c" lang="en"><title>C</title></book><book id="d" lang="fr" data-x="a b"/><!--c--><mag id="e">text</mag></lib>`

@(test)
types_ids_and_classes :: proc(t: ^testing.T) {
	testing.expect_value(t, matched(t, .Xml, BOOK, "book"), "book#a book#c book#d")
	testing.expect_value(t, matched(t, .Xml, BOOK, "*"), "lib book#a title note mag#b book#c title book#d mag#e")
	testing.expect_value(t, matched(t, .Xml, BOOK, "#c"), "book#c")
	testing.expect_value(t, matched(t, .Xml, BOOK, "book#c, mag#b"), "mag#b book#c")
	testing.expect_value(t, matched(t, .Xml, BOOK, ".old"), "book#a")
	testing.expect_value(t, matched(t, .Xml, BOOK, ".new.old"), "book#a")
	testing.expect_value(t, matched(t, .Xml, BOOK, ".ne"), "")
	testing.expect_value(t, matched(t, .Xml, BOOK, "Book"), "")
}

@(test)
attributes_by_each_operator :: proc(t: ^testing.T) {
	testing.expect_value(t, matched(t, .Xml, BOOK, "[lang]"), "book#a book#c book#d")
	testing.expect_value(t, matched(t, .Xml, BOOK, "[lang=en]"), "book#c")
	testing.expect_value(t, matched(t, .Xml, BOOK, `[lang="EN" i]`), "book#c")
	testing.expect_value(t, matched(t, .Xml, BOOK, `[lang="EN" s]`), "")
	testing.expect_value(t, matched(t, .Xml, BOOK, "[lang|=en]"), "book#a book#c")
	testing.expect_value(t, matched(t, .Xml, BOOK, "[lang^=en]"), "book#a book#c")
	testing.expect_value(t, matched(t, .Xml, BOOK, "[lang$='GB']"), "book#a")
	testing.expect_value(t, matched(t, .Xml, BOOK, "[lang*=n-]"), "book#a")
	testing.expect_value(t, matched(t, .Xml, BOOK, "[data-x~=b]"), "book#d")
	testing.expect_value(t, matched(t, .Xml, BOOK, "[data-x~='a b']"), "")
	testing.expect_value(t, matched(t, .Xml, BOOK, "[lang^='']"), "")
	testing.expect_value(t, matched(t, .Xml, BOOK, `[id="\61"]`), "book#a")
}

@(test)
combinators_relate_elements :: proc(t: ^testing.T) {
	testing.expect_value(t, matched(t, .Xml, BOOK, "lib title"), "title title")
	testing.expect_value(t, matched(t, .Xml, BOOK, "lib > title"), "")
	testing.expect_value(t, matched(t, .Xml, BOOK, "#a > *"), "title note")
	testing.expect_value(t, matched(t, .Xml, BOOK, "book + mag"), "mag#b mag#e")
	testing.expect_value(t, matched(t, .Xml, BOOK, "mag + book"), "book#c")
	testing.expect_value(t, matched(t, .Xml, BOOK, "#b ~ *"), "book#c book#d mag#e")
	testing.expect_value(t, matched(t, .Xml, BOOK, "lib>book~book title"), "title")
}

@(test)
logical_pseudo_classes :: proc(t: ^testing.T) {
	testing.expect_value(t, matched(t, .Xml, BOOK, "book:not(#a, [lang=fr])"), "book#c")
	testing.expect_value(t, matched(t, .Xml, BOOK, ":is(mag, #a) > title, :where(#d)"), "title book#d")
	testing.expect_value(t, matched(t, .Xml, BOOK, "book:has(> title)"), "book#a book#c")
	testing.expect_value(t, matched(t, .Xml, BOOK, "lib:has(note)"), "lib")
	testing.expect_value(t, matched(t, .Xml, BOOK, "*:has(+ mag)"), "book#a book#d")
	testing.expect_value(t, matched(t, .Xml, BOOK, "*:has(~ #e)"), "book#a mag#b book#c book#d")
	testing.expect_value(t, matched(t, .Xml, BOOK, "book:has(title + note)"), "book#a")
	testing.expect_value(t, matched(t, .Xml, BOOK, "book:not(:has(*))"), "book#d")
}

@(test)
structural_pseudo_classes :: proc(t: ^testing.T) {
	testing.expect_value(t, matched(t, .Xml, BOOK, ":root"), "lib")
	testing.expect_value(t, matched(t, .Xml, BOOK, "lib > :first-child, lib > :last-child"), "book#a mag#e")
	testing.expect_value(t, matched(t, .Xml, BOOK, ":only-child"), "lib title")
	testing.expect_value(t, matched(t, .Xml, BOOK, "lib > :first-of-type"), "book#a mag#b")
	testing.expect_value(t, matched(t, .Xml, BOOK, "lib > :last-of-type"), "book#d mag#e")
	testing.expect_value(t, matched(t, .Xml, BOOK, ":only-of-type"), "lib title note title")
	testing.expect_value(t, matched(t, .Xml, BOOK, "lib > :nth-child(2n+1)"), "book#a book#c mag#e")
	testing.expect_value(t, matched(t, .Xml, BOOK, "lib > :nth-child(even)"), "mag#b book#d")
	testing.expect_value(t, matched(t, .Xml, BOOK, "lib > :nth-child(-n+2)"), "book#a mag#b")
	testing.expect_value(t, matched(t, .Xml, BOOK, "lib > :nth-last-child(2)"), "book#d")
	testing.expect_value(t, matched(t, .Xml, BOOK, "book:nth-of-type(2)"), "book#c")
	testing.expect_value(t, matched(t, .Xml, BOOK, "book:nth-last-of-type(n+2)"), "book#a book#c")
	testing.expect_value(t, matched(t, .Xml, BOOK, ":nth-child(2 of [lang])"), "book#c")
	testing.expect_value(t, matched(t, .Xml, BOOK, ":nth-last-child(1 of book)"), "book#d")
	testing.expect_value(t, matched(t, .Xml, BOOK, ":empty"), "note mag#b book#d")
}

@(test)
text_is_no_element :: proc(t: ^testing.T) {
	text := `<p>one<b>two</b>three<i/>four</p>`
	testing.expect_value(t, matched(t, .Xml, text, "p > *"), "b i")
	testing.expect_value(t, matched(t, .Xml, text, "b + i"), "i")
	testing.expect_value(t, matched(t, .Xml, text, "b:first-child, i:last-child"), "b i")
	testing.expect_value(t, matched(t, .Xml, text, "p:empty, i:empty"), "i")
}

@(test)
html_names_fold_and_values_do_not :: proc(t: ^testing.T) {
	text := `<DIV ID=x Class="Big"><P>a</P><svg viewBox="0 0 1 1"><foreignObject/></svg></DIV>`
	testing.expect_value(t, matched(t, .Html, text, "div > p"), "p")
	testing.expect_value(t, matched(t, .Html, text, "DIV[CLASS=Big]"), "div#x")
	testing.expect_value(t, matched(t, .Html, text, ".big"), "")
	testing.expect_value(t, matched(t, .Html, text, "[viewbox]"), "svg")
	testing.expect_value(t, matched(t, .Html, text, "foreignobject"), "foreignObject")
	testing.expect_value(t, matched(t, .Xml, `<a B="c"/>`, "[b]"), "")
}

@(test)
an_html_document_has_its_implied_elements :: proc(t: ^testing.T) {
	doc, err := html.build(transmute([]u8)string(`<title>t</title><p class=a>x<p>y`), .Document)
	if !testing.expectf(t, err == nil, "%v", err) {
		return
	}
	defer core.destroy(&doc)
	testing.expect_value(t, described(t, &doc, ":root", core.ROOT), "html")
	testing.expect_value(t, described(t, &doc, "body > p:last-child, head > *", core.ROOT), "title p")
	testing.expect_value(t, described(t, &doc, "p:not(.a)", core.ROOT), "p")
}

@(test)
a_select_reaches_inside_its_node :: proc(t: ^testing.T) {
	doc, err := xml.build(transmute([]u8)string(BOOK), .Xml)
	if !testing.expectf(t, err == nil, "%v", err) {
		return
	}
	defer core.destroy(&doc)
	first, _ := css.compile("#c")
	defer css.destroy(&first)
	found, _ := css.select(&doc, &first)
	defer delete(found)
	if !testing.expect_value(t, len(found), 1) {
		return
	}
	testing.expect_value(t, described(t, &doc, "*", found[0]), "title")
	testing.expect_value(t, described(t, &doc, "lib > book > title", found[0]), "title")
	testing.expect_value(t, described(t, &doc, "book", found[0]), "")
	testing.expect_value(t, described(t, &doc, "title:only-child", found[0] + 1), "")
}

@(test)
a_document_with_no_elements_matches_none :: proc(t: ^testing.T) {
	doc, err := xml.build(transmute([]u8)string(`<a>text</a>`), .Xml)
	if !testing.expectf(t, err == nil, "%v", err) {
		return
	}
	defer core.destroy(&doc)
	testing.expect_value(t, described(t, &doc, "*", 2), "")
	testing.expect_value(t, described(t, &doc, "a", core.ROOT), "a")
}

@(test)
faults_say_where_and_why :: proc(t: ^testing.T) {
	refused(t, "", .None, 0)
	refused(t, "a,", .None, 2)
	refused(t, "a >", .None, 3)
	refused(t, "a[b", .None, 3)
	refused(t, "a[b=]", .Syntax, 4)
	refused(t, "a[b=c x]", .Syntax, 6)
	refused(t, "a:hover", .Pseudo_Class, 1)
	refused(t, "a:is(b):focus-within", .Pseudo_Class, 7)
	refused(t, "p:nth-child(2n+)", .Syntax, 15)
	refused(t, "p::before", .Pseudo_Element, 1)
	refused(t, "p:first-line", .Pseudo_Element, 1)
	refused(t, "svg|a", .Namespace, 0)
	refused(t, "*|a", .Namespace, 0)
	refused(t, "[svg|href]", .Namespace, 1)
	refused(t, "a::", .Pseudo_Element, 1)
	refused(t, "#1a", .Syntax, 1)
	refused(t, "a)", .Syntax, 1)
	refused(t, ":has()", .Syntax, 5)
}
