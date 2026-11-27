#+build darwin, linux, freebsd, openbsd, netbsd
package css_tests

import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/ops/css"
import "stury:testkit"
import "stury:xml"

DEPTH :: 100_000

// A text of `DEPTH` elements `a`, each the only child of the one around it, the innermost empty.
@(private = "file")
nested :: proc() -> []u8 {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for _ in 0 ..< DEPTH - 1 {
		strings.write_string(&b, "<a>")
	}
	strings.write_string(&b, "<a/>")
	for _ in 0 ..< DEPTH - 1 {
		strings.write_string(&b, "</a>")
	}
	return transmute([]u8)strings.to_string(b)
}

// Selects the innermost element of the nested text through each family of combinator, each with a different selector,
// and checks its path is as deep as the text.
@(private = "file")
select_innermost :: proc(read: int, text: []u8) -> bool {
	selectors := [?]string{"a a:empty", "a > a:empty", "a:empty", "a:last-child:empty", "a:not(a a):first-child", "a:nth-last-of-type(1):empty"}
	doc, err := xml.build(text, .Xml, {budget = {depth = DEPTH + 1}}, context.allocator)
	if err != nil {
		return false
	}
	defer tape.destroy(&doc)
	sel, serr := css.compile(selectors[read])
	if serr != nil {
		return false
	}
	defer css.destroy(&sel)
	found, e := css.select(&doc, tape.ROOT, &sel, {attribute = xml.attribute})
	if e != nil {
		return false
	}
	defer css.destroy_found(&found)
	if read == 4 {
		return len(found.matches) == 1 && len(css.steps_of(&found, found.matches[0])) == 1
	}
	return len(found.matches) == 1 && len(css.steps_of(&found, found.matches[0])) == DEPTH
}

@(test)
a_deep_document_costs_no_native_stack :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	testkit.expect_reads_on_thread(t, 128 * 1024, 6, nested(), "nested elements", select_innermost)
}
