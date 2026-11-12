// What the html5lib cases do not reach: the hook's actions, a stop, CDATA in foreign content, attributes past the
// inline room, running out of memory, `decode`'s spans, ill-formed UTF-8 and runs across 64-byte blocks.
package html_tests

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import core "../../core"
import html ".."

// Collects tokens as `Collector` does, and answers a start tag with the action `actions` names for it.
@(private)
Driver :: struct {
	using col: Collector,
	actions:   map[string]html.Internal_Action,
	stop_at:   int, // stop at this token, from 1, 0 for never
	seen:      int,
}

@(private)
drive :: proc "contextless" (d: ^Driver, t: ^html.Internal_Token) -> html.Internal_Action {
	collect(&d.col, t)
	d.seen += 1
	if d.seen == d.stop_at {
		return .Stop
	}
	if t.kind == .Start_Tag {
		context = runtime.default_context()
		context.allocator = d.alloc
		if a, ok := d.actions[read(d.src, t.name)]; ok {
			return a
		}
	}
	return .Next
}

@(private)
Run :: struct {
	tokens, errors: []string,
	hi:             u64,
	fault:          Maybe(core.Fault),
	stopped:        bool,
}

@(private)
run :: proc(src: string, actions: map[string]html.Internal_Action = nil, stop_at := 0) -> Run {
	d := Driver{col = {src = transmute([]u8)src, alloc = context.allocator}, actions = actions, stop_at = stop_at}
	strings.builder_init(&d.text)
	r: Run
	r.hi, r.fault, r.stopped = html.internal_tokenize(transmute([]u8)src, &d, drive)
	flush_text(&d.col)
	r.tokens, r.errors = d.tokens[:], d.errors[:]
	return r
}

@(private)
expect_tokens :: proc(t: ^testing.T, r: Run, want: ..string, loc := #caller_location) {
	got := fmt.tprint(r.tokens)
	testing.expect_value(t, got, fmt.tprint(want), loc)
}

@(private)
scratch :: proc(t: ^testing.T) -> (virtual.Arena, bool) {
	arena: virtual.Arena
	return arena, testing.expect(t, virtual.arena_init_growing(&arena) == nil)
}

@(test)
hook_switches_text_states :: proc(t: ^testing.T) {
	arena, ok := scratch(t)
	if !ok {
		return
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	actions := make(map[string]html.Internal_Action)
	actions["title"] = .Rcdata
	actions["style"] = .Rawtext
	actions["script"] = .Script_Data
	actions["plaintext"] = .Plaintext
	r := run("<title>a &amp; <b></TITLE><style>&amp;<i></style><script><!--<script></script>--></script>", actions)
	expect_tokens(t, r,
		`StartTag "title" {}`, `Character "a & <b>"`, `EndTag "title"`,
		`StartTag "style" {}`, `Character "&amp;<i>"`, `EndTag "style"`,
		`StartTag "script" {}`, `Character "<!--<script></script>-->"`, `EndTag "script"`)
	testing.expect_value(t, len(r.errors), 0)
	r = run("<plaintext></plaintext>&amp;", actions)
	expect_tokens(t, r, `StartTag "plaintext" {}`, `Character "</plaintext>&amp;"`)
}

@(test)
cdata_only_in_foreign_content :: proc(t: ^testing.T) {
	arena, ok := scratch(t)
	if !ok {
		return
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	actions := make(map[string]html.Internal_Action)
	actions["svg"] = .Foreign
	actions["p"] = .Html
	r := run("<svg><![CDATA[a<b]]]>c</svg><p><![CDATA[x]]>", actions)
	expect_tokens(t, r,
		`StartTag "svg" {}`, `Character "a<b]c"`, `EndTag "svg"`,
		`StartTag "p" {}`, `Comment "[CDATA[x]]"`)
	testing.expect_value(t, fmt.tprint(r.errors), `["cdata-in-html-content 1:40"]`)
}

@(test)
stop_ends_the_read :: proc(t: ^testing.T) {
	arena, ok := scratch(t)
	if !ok {
		return
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	src := "ab<i>cd<b>ef"
	r := run(src, stop_at = 2)
	expect_tokens(t, r, `Character "ab"`, `StartTag "i" {}`)
	testing.expect(t, r.stopped && r.fault == nil)
	testing.expect_value(t, r.hi, 5)
	// A stop on an error token ends the read at the error.
	r = run("a\x00b", stop_at = 1)
	testing.expect(t, r.stopped)
	testing.expect_value(t, r.hi, 1)
	r = run(src)
	testing.expect(t, !r.stopped && r.fault == nil)
	testing.expect_value(t, r.hi, u64(len(src)))
}

// Attributes past the inline room move to the heap and their duplicates are found through the hash table, which a
// later tag with fewer attributes does not read stale.
@(test)
many_attributes :: proc(t: ^testing.T) {
	arena, ok := scratch(t)
	if !ok {
		return
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	b := strings.builder_make()
	strings.write_string(&b, "<a")
	for i in 0 ..< 40 {
		fmt.sbprintf(&b, " A%d=%d", i, i)
	}
	strings.write_string(&b, " a7=x a39=y a\x00=1 a\x00=2><b a1 A1 a20 a20>")
	r := run(strings.to_string(b))
	testing.expect_value(t, len(r.tokens), 2)
	testing.expect(t, strings.has_prefix(r.tokens[0], `StartTag "a" {"a0"="0" "a1"="1" "a10"="10"`))
	testing.expect(t, strings.contains(r.tokens[0], `"a39"="39"`))
	testing.expect(t, strings.contains(r.tokens[0], `"a\uFFFD"="1"`) || strings.contains(r.tokens[0], "\"a\uFFFD\"=\"1\""))
	testing.expect_value(t, strings.count(r.tokens[0], "="), 41)
	testing.expect_value(t, r.tokens[1], `StartTag "b" {"a1"="" "a20"=""}`)
	testing.expect_value(t, strings.count(fmt.tprint(r.errors), "duplicate-attribute"), 5)
}

@(private)
refuse :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	return nil, .Out_Of_Memory if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize else .None
}

@(test)
attributes_out_of_memory :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<a")
	for i in 0 ..< 17 {
		fmt.sbprintf(&b, " x%d", i)
	}
	strings.write_string(&b, ">")
	src := transmute([]u8)strings.to_string(b)
	nothing: struct {}
	ignore :: proc "contextless" (h: ^struct {}, t: ^html.Internal_Token) -> html.Internal_Action {return .Next}
	_, fault, _ := html.internal_tokenize(src, &nothing, ignore, allocator = runtime.Allocator{procedure = refuse})
	f, refused := fault.?
	testing.expect(t, refused && f.kind == .No_Memory)
	_, fault, _ = html.internal_tokenize(src[:len(src) - 7], &nothing, ignore, allocator = runtime.Allocator{procedure = refuse})
	testing.expect(t, fault == nil)
}

@(test)
decode_spans :: proc(t: ^testing.T) {
	arena, ok := scratch(t)
	if !ok {
		return
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	// A plain span is its source bytes, no copy.
	src := "<p>plain text</p>"
	Spans :: struct {
		spans: [dynamic]html.Internal_Span,
		alloc: runtime.Allocator,
	}
	spans := Spans{alloc = context.allocator}
	keep :: proc "contextless" (s: ^Spans, t: ^html.Internal_Token) -> html.Internal_Action {
		context = runtime.default_context()
		context.allocator = s.alloc
		if t.kind == .Text {
			append(&s.spans, t.data)
		}
		return .Next
	}
	html.internal_tokenize(transmute([]u8)src, &spans, keep)
	testing.expect_value(t, len(spans.spans), 1)
	text := html.internal_decode(transmute([]u8)src, spans.spans[0], nil)
	testing.expect_value(t, text, "plain text")
	testing.expect(t, raw_data(text) == raw_data(src[3:]))
	// A span that needs writing is refused a buffer shorter than its room.
	clear(&spans.spans)
	upper := "<P>a&amp;b</P>"
	html.internal_tokenize(transmute([]u8)upper, &spans, keep)
	room: [32]u8
	_, wrote := html.internal_decode(transmute([]u8)upper, spans.spans[0], room[:html.internal_decode_room(spans.spans[0]) - 1])
	testing.expect(t, !wrote)
	amp, fits := html.internal_decode(transmute([]u8)upper, spans.spans[0], room[:])
	testing.expect(t, fits && amp == "a&b")
	// CR LF and lone CRs read as LF, ill-formed UTF-8 as U+FFFD per maximal subpart, with no parse error.
	r := run("a\r\nb\rc\xe2\x82d\xff<x y='\r\n\xc0'>")
	expect_tokens(t, r, "Character \"a\\nb\\nc\uFFFDd\uFFFD\"", "StartTag \"x\" {\"y\"=\"\\n\uFFFD\"}")
	testing.expect_value(t, len(r.errors), 0)
}

// Text runs of every length up to past two blocks, ended by each byte the data state stops at, and the controls
// across a block's end.
@(test)
runs_across_blocks :: proc(t: ^testing.T) {
	arena, ok := scratch(t)
	if !ok {
		return
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	for n in 0 ..< 140 {
		run_text := strings.repeat("x", n)
		r := run(fmt.tprintf("%s<i>", run_text))
		want := `StartTag "i" {}` if n == 0 else fmt.tprintf(`Character "%s"`, run_text)
		testing.expectf(t, len(r.tokens) == (1 if n == 0 else 2) && r.tokens[0] == want, "%d: %v", n, r.tokens)
		r = run(fmt.tprintf("%s&lt;", run_text))
		testing.expectf(t, len(r.tokens) == 1 && r.tokens[0] == fmt.tprintf(`Character "%s<"`, run_text), "%d: %v", n, r.tokens)
		r = run(fmt.tprintf("%s\x01", run_text))
		testing.expectf(t, fmt.tprint(r.errors) == fmt.tprintf(`["control-character-in-input-stream 1:%d"]`, n + 1), "%d: %v", n, r.errors)
		r = run(fmt.tprintf("%s\uFDD0y", run_text))
		testing.expectf(t, fmt.tprint(r.errors) == fmt.tprintf(`["noncharacter-in-input-stream 1:%d"]`, n + 1), "%d: %v", n, r.errors)
	}
}
