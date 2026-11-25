// Selectors compiled and matched over XML documents: each family, the case rules, scoping to a node, the paths of the
// elements found, and the faults a selector compiles to.
package css_tests

import "base:runtime"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/ops/css"
import "stury:testkit"
import "stury:xml"

@(private)
OPTIONS :: css.Options {
	attribute = xml.attribute,
}

@(private)
document :: proc(t: ^testing.T, text: string, loc := #caller_location) -> (doc: tape.Document, ok: bool) {
	d, err := xml.build(transmute([]u8)text, .Xml, {}, context.temp_allocator)
	testing.expectf(t, err == nil, "%v", err, loc = loc)
	return d, err == nil
}

// The text of token `t` of `doc`.
@(private)
token_text :: proc(doc: ^tape.Document, t: tape.Token) -> string {
	buf := make([]u8, max(tape.text_room(doc, t), int(t.n)), context.temp_allocator)
	s, _ := tape.node_text(doc, t, buf)
	return s
}

// The elements `selector` selects below node `from` of `doc`, as their names with `#` and their id when they have one.
@(private)
described :: proc(t: ^testing.T, doc: ^tape.Document, selector: string, from: tape.Node_Index, opts := OPTIONS, loc := #caller_location) -> string {
	sel, err := css.compile(selector)
	if !testing.expectf(t, err == nil, "%q: %v", selector, err, loc = loc) {
		return ""
	}
	defer css.destroy(&sel)
	found, e := css.select(doc, from, &sel, opts)
	testing.expectf(t, e == nil, "%v", e, loc = loc)
	defer css.destroy_found(&found)
	b := strings.builder_make(context.temp_allocator)
	for match, i in found.matches {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, token_text(doc, doc.nodes[match.value - 1]))
		for f in tape.facts_of(doc, match.value) {
			if f.kind != .Attribute {
				continue
			}
			name, value := xml.attribute(doc, f)
			if token_text(doc, name) == "id" {
				strings.write_byte(&b, '#')
				strings.write_string(&b, token_text(doc, value))
			}
		}
	}
	return strings.to_string(b)
}

// The elements `selector` matches in `text`.
@(private)
matched :: proc(t: ^testing.T, text, selector: string, opts := OPTIONS, loc := #caller_location) -> string {
	doc, ok := document(t, text, loc)
	if !ok {
		return ""
	}
	return described(t, &doc, selector, tape.ROOT, opts, loc)
}

// The fault `selector` compiles to: its detail, `.None` for a selector cut short, and its byte offset.
@(private)
refused :: proc(t: ^testing.T, selector: string, detail: css.Detail, at: u64, loc := #caller_location) {
	sel, err := css.compile(selector)
	defer css.destroy(&sel)
	f, ok := err.(tape.Fault)
	if !testing.expectf(t, ok, "%q compiled: %v", selector, err, loc = loc) {
		return
	}
	kind := tape.Fault_Kind.Truncated if detail == .None else .Bad_Char
	testing.expectf(t, f.kind == kind && css.Detail(f.detail) == detail && f.at == at, "%q: %v", selector, f, loc = loc)
}

@(private)
BOOK :: `<lib><book id="a" lang="en-GB" class="new  old"><title>A</title><note/></book><mag id="b"/><book id="c" lang="en"><title>C</title></book><book id="d" lang="fr" data-x="a b"/><!--c--><mag id="e">text</mag></lib>`

@(test)
types_ids_and_classes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, matched(t, BOOK, "book"), "book#a book#c book#d")
	testing.expect_value(t, matched(t, BOOK, "*"), "lib book#a title note mag#b book#c title book#d mag#e")
	testing.expect_value(t, matched(t, BOOK, "#c"), "book#c")
	testing.expect_value(t, matched(t, BOOK, "book#c, mag#b"), "mag#b book#c")
	testing.expect_value(t, matched(t, BOOK, ".old"), "book#a")
	testing.expect_value(t, matched(t, BOOK, ".new.old"), "book#a")
	testing.expect_value(t, matched(t, BOOK, ".ne"), "")
	testing.expect_value(t, matched(t, BOOK, "Book"), "")
}

@(test)
attributes_by_each_operator :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, matched(t, BOOK, "[lang]"), "book#a book#c book#d")
	testing.expect_value(t, matched(t, BOOK, "[lang=en]"), "book#c")
	testing.expect_value(t, matched(t, BOOK, `[lang="EN" i]`), "book#c")
	testing.expect_value(t, matched(t, BOOK, `[lang="EN" s]`), "")
	testing.expect_value(t, matched(t, BOOK, "[lang|=en]"), "book#a book#c")
	testing.expect_value(t, matched(t, BOOK, "[lang^=en]"), "book#a book#c")
	testing.expect_value(t, matched(t, BOOK, "[lang$='GB']"), "book#a")
	testing.expect_value(t, matched(t, BOOK, "[lang*=n-]"), "book#a")
	testing.expect_value(t, matched(t, BOOK, "[data-x~=b]"), "book#d")
	testing.expect_value(t, matched(t, BOOK, "[data-x~='a b']"), "")
	testing.expect_value(t, matched(t, BOOK, "[lang^='']"), "")
	testing.expect_value(t, matched(t, BOOK, `[id="\61"]`), "book#a")
}

@(test)
combinators_relate_elements :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, matched(t, BOOK, "lib title"), "title title")
	testing.expect_value(t, matched(t, BOOK, "lib > title"), "")
	testing.expect_value(t, matched(t, BOOK, "#a > *"), "title note")
	testing.expect_value(t, matched(t, BOOK, "book + mag"), "mag#b mag#e")
	testing.expect_value(t, matched(t, BOOK, "mag + book"), "book#c")
	testing.expect_value(t, matched(t, BOOK, "#b ~ *"), "book#c book#d mag#e")
	testing.expect_value(t, matched(t, BOOK, "lib>book~book title"), "title")
}

@(test)
logical_pseudo_classes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, matched(t, BOOK, "book:not(#a, [lang=fr])"), "book#c")
	testing.expect_value(t, matched(t, BOOK, ":is(mag, #a) > title, :where(#d)"), "title book#d")
	testing.expect_value(t, matched(t, BOOK, "book:has(> title)"), "book#a book#c")
	testing.expect_value(t, matched(t, BOOK, "lib:has(note)"), "lib")
	testing.expect_value(t, matched(t, BOOK, "*:has(+ mag)"), "book#a book#d")
	testing.expect_value(t, matched(t, BOOK, "*:has(~ #e)"), "book#a mag#b book#c book#d")
	testing.expect_value(t, matched(t, BOOK, "book:has(title + note)"), "book#a")
	testing.expect_value(t, matched(t, BOOK, "book:not(:has(*))"), "book#d")
}

@(test)
structural_pseudo_classes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, matched(t, BOOK, ":root"), "lib")
	testing.expect_value(t, matched(t, BOOK, "lib > :first-child, lib > :last-child"), "book#a mag#e")
	testing.expect_value(t, matched(t, BOOK, ":only-child"), "lib title")
	testing.expect_value(t, matched(t, BOOK, "lib > :first-of-type"), "book#a mag#b")
	testing.expect_value(t, matched(t, BOOK, "lib > :last-of-type"), "book#d mag#e")
	testing.expect_value(t, matched(t, BOOK, ":only-of-type"), "lib title note title")
	testing.expect_value(t, matched(t, BOOK, "lib > :nth-child(2n+1)"), "book#a book#c mag#e")
	testing.expect_value(t, matched(t, BOOK, "lib > :nth-child(even)"), "mag#b book#d")
	testing.expect_value(t, matched(t, BOOK, "lib > :nth-child(-n+2)"), "book#a mag#b")
	testing.expect_value(t, matched(t, BOOK, "lib > :nth-last-child(2)"), "book#d")
	testing.expect_value(t, matched(t, BOOK, "book:nth-of-type(2)"), "book#c")
	testing.expect_value(t, matched(t, BOOK, "book:nth-last-of-type(n+2)"), "book#a book#c")
	testing.expect_value(t, matched(t, BOOK, ":nth-child(2 of [lang])"), "book#c")
	testing.expect_value(t, matched(t, BOOK, ":nth-last-child(1 of book)"), "book#d")
	testing.expect_value(t, matched(t, BOOK, ":empty"), "note mag#b book#d")
}

@(test)
text_is_no_element :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := `<p>one<b>two</b>three<i/>four</p>`
	testing.expect_value(t, matched(t, text, "p > *"), "b i")
	testing.expect_value(t, matched(t, text, "b + i"), "i")
	testing.expect_value(t, matched(t, text, "b:first-child, i:last-child"), "b i")
	testing.expect_value(t, matched(t, text, "p:empty, i:empty"), "i")
}

@(test)
names_fold_when_the_options_say_so :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := `<DIV ID="x" Class="Big"><P>a</P><svg viewBox="0 0 1 1"><foreignObject/></svg></DIV>`
	folded := OPTIONS
	folded.fold = true
	testing.expect_value(t, matched(t, text, "div > p", folded), "P")
	testing.expect_value(t, matched(t, text, "DIV[CLASS=Big]", folded), "DIV")
	testing.expect_value(t, matched(t, text, ".big", folded), "")
	testing.expect_value(t, matched(t, text, "[viewbox]", folded), "svg")
	testing.expect_value(t, matched(t, text, "foreignobject", folded), "foreignObject")
	testing.expect_value(t, matched(t, text, "div > p"), "")
	testing.expect_value(t, matched(t, text, "[viewbox]"), "")
}

@(test)
a_select_reaches_inside_its_node :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := document(t, BOOK)
	if !ok {
		return
	}
	first, _ := css.compile("#c")
	defer css.destroy(&first)
	found, err := css.select(&doc, tape.ROOT, &first, OPTIONS)
	defer css.destroy_found(&found)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(found.matches), 1) {
		return
	}
	inside := found.matches[0].value
	testing.expect_value(t, described(t, &doc, "*", inside), "title")
	testing.expect_value(t, described(t, &doc, "lib > book > title", inside), "title")
	testing.expect_value(t, described(t, &doc, "book", inside), "")
	testing.expect_value(t, described(t, &doc, "title:only-child", inside + 1), "")
}

@(test)
a_node_that_holds_no_element_has_no_matches :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := document(t, `<a>text<b/></a>`)
	if !ok {
		return
	}
	testing.expect_value(t, described(t, &doc, "*", 2), "b")
	testing.expect_value(t, described(t, &doc, "*", 2 + tape.Node_Index(doc.nodes[2].n) - 1), "")
	testing.expect_value(t, described(t, &doc, "a", tape.ROOT), "a")
	// The key of a member is no element's value.
	testing.expect_value(t, described(t, &doc, "*", 1), "")
}

@(test)
text_members_are_skipped_in_the_chain_and_the_counts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, matched(t, `<r>x<a/>y<a/>z</r>`, "a:nth-child(2)"), "a")
	testing.expect_value(t, matched(t, `<r>x<a/>y<a/>z</r>`, "a + a"), "a")
}

// The path of each match, as the names and the places among repeated names a selector's result gives.
@(private)
paths :: proc(t: ^testing.T, text, selector: string, loc := #caller_location) -> string {
	doc, ok := document(t, text, loc)
	if !ok {
		return ""
	}
	sel, err := css.compile(selector)
	if !testing.expectf(t, err == nil, "%q: %v", selector, err, loc = loc) {
		return ""
	}
	defer css.destroy(&sel)
	found, e := css.select(&doc, tape.ROOT, &sel, OPTIONS)
	testing.expect_value(t, e, nil, loc = loc)
	defer css.destroy_found(&found)
	b := strings.builder_make(context.temp_allocator)
	for match, i in found.matches {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		for step in css.steps_of(&found, match) {
			strings.write_byte(&b, '/')
			strings.write_string(&b, token_text(&doc, doc.nodes[step.key]))
			if step.index >= 0 {
				strings.write_byte(&b, '[')
				strings.write_int(&b, int(step.index))
				strings.write_byte(&b, ']')
			}
		}
	}
	return strings.to_string(b)
}

@(test)
paths_count_the_members_of_a_repeated_name :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, paths(t, BOOK, "title"), "/lib/book[0]/title /lib/book[1]/title")
	testing.expect_value(t, paths(t, BOOK, "mag, #c > title"), "/lib/mag[0] /lib/book[1]/title /lib/mag[1]")
	testing.expect_value(t, paths(t, BOOK, ":root"), "/lib")
	testing.expect_value(t, paths(t, `<r><a/><b/><a/><a/></r>`, "a:last-child, b"), "/r/b /r/a[2]")
	testing.expect_value(t, paths(t, `<r><a/><b/><a/><a/></r>`, "a"), "/r/a[0] /r/a[1] /r/a[2]")
}

@(test)
paths_through_long_runs_of_siblings :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<r>")
	for _ in 0 ..< 2000 {
		strings.write_string(&b, "<i><j/><k/><j/></i><o/>")
	}
	strings.write_string(&b, "</r>")
	doc, ok := document(t, strings.to_string(b))
	if !ok {
		return
	}
	sel, _ := css.compile("j + k + j")
	defer css.destroy(&sel)
	found, err := css.select(&doc, tape.ROOT, &sel, OPTIONS)
	defer css.destroy_found(&found)
	testing.expect_value(t, err, nil)
	if testing.expect_value(t, len(found.matches), 2000) {
		last := css.steps_of(&found, found.matches[1999])
		testing.expect_value(t, len(last), 3)
		testing.expect_value(t, last[1].index, 1999)
		testing.expect_value(t, last[2].index, 1)
	}
}

@(test)
faults_say_where_and_why :: proc(t: ^testing.T) {
	testkit.deadline(t)
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

@(test)
nesting_and_compound_counts_are_bounded :: proc(t: ^testing.T) {
	testkit.deadline(t)
	deep := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< css.MAX_NESTING + 1 {
		strings.write_string(&deep, ":not(")
	}
	strings.write_string(&deep, "a")
	for _ in 0 ..< css.MAX_NESTING + 1 {
		strings.write_byte(&deep, ')')
	}
	sel, err := css.compile(strings.to_string(deep))
	css.destroy(&sel)
	f, ok := err.(tape.Fault)
	testing.expect(t, ok && css.Detail(f.detail) == .Nesting, "a nesting past the limit compiles")
	long := strings.repeat("a ", css.MAX_COMPOUNDS + 1, context.temp_allocator)
	sel, err = css.compile(long)
	css.destroy(&sel)
	f, ok = err.(tape.Fault)
	testing.expect(t, ok && css.Detail(f.detail) == .Nesting, "a complex past the limit compiles")
}

@(private)
Select_Job :: struct {
	doc:      ^tape.Document,
	selector: string,
}

@(private)
select_with :: proc(data: rawptr, allocator: runtime.Allocator) {
	job := (^Select_Job)(data)
	sel, err := css.compile(job.selector, allocator)
	defer css.destroy(&sel)
	if err != nil {
		return
	}
	found, e := css.select(job.doc, tape.ROOT, &sel, OPTIONS, allocator)
	if e == nil {
		css.destroy_found(&found)
	}
}

@(test)
a_refused_allocation_leaves_nothing_behind :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := document(t, BOOK)
	if !ok {
		return
	}
	for selector in ([]string{"book:has(> title), lib > :nth-last-child(2 of [id])", "#a ~ * title"}) {
		job := Select_Job{&doc, selector}
		sweep := testkit.sweep_failures(select_with, &job)
		testing.expectf(t, sweep.bad == 0 && sweep.refused > 0, "%q: %v", selector, sweep)
	}
}
