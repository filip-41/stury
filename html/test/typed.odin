// `html.unmarshal` reads an element at a struct as XML's does: its attributes, child elements and `#text`, a list
// collecting the siblings of its name, and a text read by the member's type, in the tree a browser builds.
package html_tests

import "core:testing"
import core "../../core"
import typed "../../core/typed"
import html ".."
import testkit "../../testkit"

@(private = "file")
Cell :: struct {
	class: string,
	value: f64 `html:"#text"`,
}

@(private = "file")
Row :: struct {
	td: [dynamic]Cell,
}

@(private = "file")
Page :: struct {
	html: struct {
		head: struct {
			title: string,
		},
		body: struct {
			table: struct {
				tbody: struct {
					tr: [dynamic]Row,
				},
			},
		},
	},
}

@(test)
unmarshal_reads_the_tree_a_browser_builds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	text := `<!doctype html><title>Prices &amp; more</title>
<table><tr><td class=a>1.5<td class=b>2</tr><tr><td class=c>3</table>`
	v: Page
	err := html.unmarshal(transmute([]u8)string(text), .Document, &v)
	testkit.expect_nil(t, err)
	testing.expect_value(t, v.html.head.title, "Prices & more")
	rows := v.html.body.table.tbody.tr
	if !testing.expect_value(t, len(rows), 2) || !testing.expect_value(t, len(rows[0].td), 2) {
		return
	}
	testing.expect_value(t, rows[0].td[0].class, "a")
	testing.expect_value(t, rows[0].td[0].value, 1.5)
	testing.expect_value(t, rows[0].td[1].value, 2)
	testing.expect_value(t, rows[1].td[0].class, "c")

	chosen :: html.Spec.Document
	again: Page
	testkit.expect_nil(t, html.unmarshal(transmute([]u8)string(text), chosen, &again))
	testing.expect_value(t, len(again.html.body.table.tbody.tr), 2)

	plan, perr := html.plan_make(Page, .Document)
	testkit.expect_nil(t, perr)
	defer html.destroy(&plan)
	planned: Page
	testkit.expect_nil(t, html.unmarshal(transmute([]u8)string(text), .Document, &planned, &plan))
	testing.expect_value(t, len(planned.html.body.table.tbody.tr), 2)
}

@(test)
check_gives_every_refusal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	V :: struct {
		a: struct {
			n, m, k: int,
		},
	}
	plan, perr := html.plan_make(V, .Fragment)
	testkit.expect_nil(t, perr)
	defer typed.plan_destroy(&plan)
	v: V
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	err := html.check(transmute([]u8)string(`<a n=x m=2 k=y>t</a>`), .Fragment, &v, &plan, {sink = &sink})
	refused, is_typed := err.(core.Typed_Error)
	testing.expect(t, is_typed)
	testing.expect_value(t, refused.kind, core.Typed_Error_Kind.Wrong_Kind)
	testing.expect_value(t, len(sink.entries), 2)
	testing.expect_value(t, v.a.m, 2)
}

// A text whose character references decode to exactly a JSON number reads into a number.
@(test)
unmarshal_reads_a_number_a_text_decodes_to :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	v: struct {
		b: struct {
			n:     int,
			text: f64 `html:"#text"`,
		},
		i: int,
	}
	src := `<b n="&#45;&#55;">&#49;.&#53;</b><i>&#55;</i>`
	testkit.expect_nil(t, html.unmarshal(transmute([]u8)string(src), .Fragment, &v))
	testing.expect_value(t, v.b.n, -7)
	testing.expect_value(t, v.b.text, 1.5)
	testing.expect_value(t, v.i, 7)
}

// A check of a list member over repeated elements takes every element, as `unmarshal` does.
@(test)
check_takes_a_list_of_repeated_elements :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	V :: struct {
		ul: struct {
			li: [dynamic]string,
		},
	}
	plan, perr := html.plan_make(V, .Fragment)
	testkit.expect_nil(t, perr)
	defer typed.plan_destroy(&plan)
	v: V
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	testkit.expect_nil(t, html.check(transmute([]u8)string(`<ul><li>a<li>b</ul>`), .Fragment, &v, &plan, {sink = &sink}))
	testing.expect_value(t, len(sink.entries), 0)
	testing.expect_value(t, len(v.ul.li), 2)
}

// A nil `any` is a null, which HTML cannot write at the top, so it is refused as any null is.
@(test)
a_nil_any_is_refused_as_a_null :: proc(t: ^testing.T) {
	nothing: any
	text, err := html.marshal(nothing, allocator = context.temp_allocator)
	testing.expect(t, text == nil)
	testkit.expect_kind(t, err, core.Typed_Error_Kind.Unwritable)
}
