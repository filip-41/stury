// The read laws of `testkit` over random HTML5 documents, threads, pieces, and hooks.
package html_tests

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:host"
import "stury:html"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"

@(private = "file")
NAMES := [?]string{"div", "p", "span", "ul", "li", "b", "section"}

@(private = "file")
put_html_text :: proc(b: ^strings.Builder) {
	switch rand.int_max(6) {
	case 0:
		strings.write_string(b, "x&amp;y")
	case 1:
		strings.write_string(b, "&#65;&#x42;")
	case 2:
		strings.write_int(b, rand.int_max(1000))
	case 3:
		strings.write_string(b, "true")
	case:
		strings.write_string(b, "txét")
	}
}

@(private = "file")
put_html_element :: proc(b: ^strings.Builder, depth: int) {
	name := NAMES[rand.int_max(len(NAMES))]
	fmt.sbprintf(b, "<%s", name)
	for idx in 0 ..< rand.int_max(3) {
		strings.write_string(b, " id" if idx == 0 else " class")
		strings.write_string(b, `="v&lt;1"` if rand.int_max(4) == 0 else `='a b'`)
	}
	strings.write_byte(b, '>')
	for _ in 0 ..< rand.int_max(4 if depth > 0 else 2) {
		switch rand.int_max(5) {
		case 0, 1:
			put_html_text(b)
		case 2:
			strings.write_string(b, "<!--c-->")
		case:
			if depth > 0 && name != "p" {
				put_html_element(b, depth - 1)
			}
		}
	}
	fmt.sbprintf(b, "</%s>", name)
}

@(private = "file")
random_html_document :: proc() -> []u8 {
	b := strings.builder_make()
	if rand.int_max(2) == 0 {
		strings.write_string(&b, "<!DOCTYPE html>")
	}
	strings.write_string(&b, "<!--lead-->")
	if rand.int_max(3) == 0 {
		strings.write_string(&b, `<main id="top"><head></head><div class="box">`)
		for _ in 0 ..< 1 + rand.int_max(3) {
			put_html_element(&b, 3)
		}
		strings.write_string(&b, "</div></main>")
	} else {
		strings.write_string(&b, `<div id="top" class="box">`)
		for _ in 0 ..< 1 + rand.int_max(4) {
			put_html_element(&b, 3)
		}
		strings.write_string(&b, "</div>")
	}
	strings.write_string(&b, "<!--tail-->")
	return b.buf[:]
}

@(test)
reads_agree_on_generated_documents :: proc(t: ^testing.T) {
	testkit.deadline(t)
	a: testkit.Agreement
	defer delete(a.shapes)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x0b1)
	infer := html.Options{format = html.Xml_Options{infer = true}}
	for round in 0 ..< testkit.rounds(40) {
		src := random_html_document()
		defer delete(src)
		testkit.readers_agree(t, html.reads(.Fragment), html.as(.Fragment), src, {}, "frag", &a)
		testkit.readers_agree(t, html.reads(.Fragment), html.as(.Fragment), src, infer, "frag-infer", &a)
		testkit.readers_agree(t, html.reads(.Html), html.as(.Html), src, {}, "html", &a)
		// HTML5 recovers syntax mutations, so also verify agreement on mutated inputs and hard refusal laws (budget & encoding).
		bad := testkit.mutate(src, "<>&;/=\"' !?-]div")
		testkit.readers_agree(t, html.reads(.Fragment), html.as(.Fragment), bad, {}, "mutated", &a)
		tight := html.Options{budget = {depth = 1 + u32(round % 2), steps = 1 + u64(round % 3)}}
		testkit.readers_agree(t, html.reads(.Html), html.as(.Html), src, tight, "budget", &a)
		enc_bad := "<meta charset=latin2><p>caf\xe9"
		testkit.readers_agree(t, html.reads(.Html), html.as(.Html), transmute([]u8)enc_bad, {}, "encoding", &a)
		free_all(context.temp_allocator)
	}
	testkit.expect_agreement(t, &a, {texts = 60, refused = 60, scans = 20_000, on_path = 20_000, shapes = 30})
}

@(test)
builds_on_threads_agree :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pool: host.Pool
	host.pool_init(&pool, 3)
	defer host.pool_destroy(&pool)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x0b2)
	for _ in 0 ..< testkit.rounds(10) {
		src := random_html_document()
		defer delete(src)
		testkit.threads_agree(t, html.reads(.Fragment), html.as(.Fragment), src, {}, &pool.runner, "frag")
		testkit.threads_agree(t, html.reads(.Html), html.as(.Html), src, {}, &pool.runner, "html")
	}
}

@(rodata, private = "file")
PIECE_TEXTS := [?]string {
	"",
	"<div/>",
	"<div>hello &amp; world</div>",
	"<!DOCTYPE html><html lang=en><head><title>T</title></head><body><p>1</p><p>2</p></body></html>",
	"<table>a<tr><td>1</td></tr>b&amp;c</table>",
	"<b>1<p>2</b>3</p>",
	"<svg viewbox='0 0 1 1'><foreignobject><p>x</p></foreignobject></svg>",
	"<div><!--a--><a>1</a><!--b--><span>2</span><!--foot--></div>",
	"<meta charset=latin2><p>caf\xe9",
}

@(test)
pieces_agree_with_whole_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	paths := [][]html.Step {
		{},
		{html.Name("div")},
		{html.Name("div"), html.Name("p")},
		{html.Name("html"), html.Name("body"), html.Name("table"), html.Name("tbody")},
		{html.Name("div"), html.All{}},
		{html.Name("table"), html.Name("tbody"), html.Name("tr"), html.Name("td")},
	}
	options := [?]tape.Options{{}, {format = html.Xml_Options{infer = true}}, {budget = {steps = 3}}, {budget = {depth = 2}}}
	for text in PIECE_TEXTS {
		for opts in options {
			if !testkit.agree_in_pieces(t, html.reads(.Fragment), html.as(.Fragment), transmute([]u8)text, opts, paths, text) {
				return
			}
			if !testkit.agree_in_pieces(t, html.reads(.Html), html.as(.Html), transmute([]u8)text, opts, paths, text) {
				return
			}
		}
	}
}

@(private = "file")
probe_walk :: proc(src: []u8, opts: tape.Options, h: ^testkit.Probe, regs: ^hook.Regs) -> (u64, tape.Error) {
	at, err, _ := html.walk(src, .Fragment, opts, h, regs, testkit.probe_hook)
	return at, err
}

@(private = "file")
bare_walk :: proc(src: []u8, opts: tape.Options, h: ^testkit.Probe_Bare, regs: ^hook.Regs) -> (u64, tape.Error) {
	at, err, _ := html.walk(src, .Fragment, opts, h, regs, testkit.bare_hook)
	return at, err
}

@(private = "file")
probe_walk_doc :: proc(src: []u8, opts: tape.Options, h: ^testkit.Probe, regs: ^hook.Regs) -> (u64, tape.Error) {
	at, err, _ := html.walk(src, .Html, opts, h, regs, testkit.probe_hook)
	return at, err
}

@(rodata, private = "file")
PROTOCOL_TEXTS := [?]string {
	"<div></div>",
	"<a>hi</a>",
	`<a x="1" y='2'>t</a>`,
	"<r><a>1</a><b/><a>2</a></r>",
	"<r>x<b>y</b><!--c--><?p d?></r>",
	`<!DOCTYPE html><!--pre--><div><section><p id="x">deep</p></section></div>`,
	"<table>a<tr><td>1</td></tr>b</table>",
}

@(test)
html_walks_keep_the_hook_protocol :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testkit.hook_protocol(t, probe_walk, PROTOCOL_TEXTS[:])
	testkit.hook_inner_rooms(t, bare_walk, PROTOCOL_TEXTS[:])
	testkit.hook_protocol(t, probe_walk_doc, PROTOCOL_TEXTS[:])
	testkit.hook_protocol_in_pieces(t, probe_walk, PROTOCOL_TEXTS[:])
	testkit.hook_inner_rooms_in_pieces(t, bare_walk, PROTOCOL_TEXTS[:])
}

@(test)
html_walk_cancels_through_a_flag :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<div>")
	for _ in 0 ..< 200 {
		strings.write_string(&b, "<a><b>1</b><c>2</c></a>")
	}
	strings.write_string(&b, "</div>")
	testkit.hook_cancel(t, probe_walk, strings.to_string(b), 300)
}
