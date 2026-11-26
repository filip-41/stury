// CSS selectors over built HTML documents: element/attribute case folding, foreign camelCase, combinators, :has/:not/:is, paths.
package html_tests

import "core:strings"
import "core:testing"
import "stury:html"
import "stury:testkit"

@(private = "file")
PAGE :: `<!DOCTYPE html><HTML lang=en><BODY><MAIN id="main" class="page active"><SECTION id="s1" class="card featured"><H1>Heading</H1><P data-tag="alpha beta" lang="en-US">First <A HREF="/x">link</A></P></SECTION><SECTION id="s2" class="card"><P lang="fr">Second</P></SECTION><SVG viewBox="0 0 10 10"><foreignObject><DIV id="inner">hi</DIV></foreignObject><clipPath id="cp"/></SVG></MAIN></BODY></HTML>`

@(private = "file")
matched :: proc(t: ^testing.T, src, selector: string, from := html.ROOT, loc := #caller_location) -> string {
	doc, err := html.build(transmute([]u8)src, .Html, {}, context.temp_allocator)
	testing.expectf(t, err == nil, "%v", err, loc = loc)
	sel, serr := html.compile(selector, context.temp_allocator)
	if !testing.expectf(t, serr == nil, "%q: %v", selector, serr, loc = loc) {
		return ""
	}
	defer html.destroy_selector(&sel)
	found, ferr := html.select(&doc, from, &sel, context.temp_allocator)
	testing.expectf(t, ferr == nil, "%v", ferr, loc = loc)
	defer html.destroy_found(&found)
	b := strings.builder_make(context.temp_allocator)
	for m, idx in found.matches {
		if idx > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, text_of(&doc, m.value - 1))
		if id, has := attribute_value(&doc, m.value, "id"); has {
			strings.write_byte(&b, '#')
			strings.write_string(&b, id)
		}
	}
	return strings.to_string(b)
}

@(test)
css_selectors_fold_html_names_and_match_tree :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, matched(t, PAGE, "P"), "p p")
	testing.expect_value(t, matched(t, PAGE, "SECTION.featured > p a[href]"), "a")
	testing.expect_value(t, matched(t, PAGE, "#main > section"), "section#s1 section#s2")
	testing.expect_value(t, matched(t, PAGE, `.card:not(.featured)`), "section#s2")
	testing.expect_value(t, matched(t, PAGE, `:is(h1, clippath, #inner)`), "h1 div#inner clipPath#cp")
	testing.expect_value(t, matched(t, PAGE, `section:has(a)`), "section#s1")
	testing.expect_value(t, matched(t, PAGE, `p[lang|=en]`), "p")
	testing.expect_value(t, matched(t, PAGE, `p[data-tag~=beta]`), "p")
	testing.expect_value(t, matched(t, PAGE, `svg[viewbox]`), "svg")
	testing.expect_value(t, matched(t, PAGE, `section + section`), "section#s2")
	testing.expect_value(t, matched(t, PAGE, `section:nth-child(2)`), "section#s2")
}

@(test)
css_select_from_subtree_and_steps :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	doc, ok := built(t, PAGE, .Html)
	if !ok {
		return
	}
	sel1, _ := html.compile("#s2")
	defer html.destroy_selector(&sel1)
	f1, _ := html.select(&doc, &sel1)
	defer html.destroy_found(&f1)
	if !testing.expect_value(t, len(f1.matches), 1) {
		return
	}
	sub := f1.matches[0].value
	sel2, _ := html.compile("p")
	defer html.destroy_selector(&sel2)
	f2, err := html.select(&doc, sub, &sel2)
	defer html.destroy_found(&f2)
	testing.expect_value(t, err, nil)
	if testing.expect_value(t, len(f2.matches), 1) {
		steps := html.steps_of(&f2, f2.matches[0])
		testing.expect_value(t, len(steps), 1)
		testing.expect_value(t, text_of(&doc, steps[0].key), "p")
	}
}
