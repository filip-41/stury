package jq_tests

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "stury:testkit"

// `css(selector)` over XML documents, which a case's input gives as text that starts with `<`. A name that repeats
// inside one parent reads as an array of those elements, and its paths end in the place among them.

@(private)
CSS_BOOK :: `<lib><book id="a" lang="en-GB" class="new old"><title>A</title><note/></book><mag id="b"/></lib>`

@(private)
CSS_LIST :: `<r><a>1</a><b>x</b><a>2</a><a>3</a></r>`

@(private, rodata)
CSS := [?][3]string {
	{`[css("title")]`, CSS_BOOK, `["A"]`},
	{`[css("*") | type]`, CSS_BOOK, `["object","object","string","null","null"]`},
	{`[path(css("title, mag"))]`, CSS_BOOK, `[["lib","book","title"],["lib","mag"]]`},
	{`.lib | [path(css("note, title"))]`, CSS_BOOK, `[["book","title"],["book","note"]]`},
	{`.lib.book | [path(css("title"))]`, CSS_BOOK, `[["title"]]`},
	{`[css("book") | keys]`, CSS_BOOK, `[["note","title"]]`},
	{`[css("[id=b], [lang|=en] > note")]`, CSS_BOOK, `[null,null]`},
	{`[path(css(".old.new"))], [path(css("[lang^=en][lang$=GB]"))], [path(css("[id=B i]"))]`, CSS_BOOK, `[["lib","book"]]
[["lib","book"]]
[["lib","mag"]]`},
	{`[path(css("lib > :first-child, :last-child:empty"))]`, CSS_BOOK, `[["lib","book"],["lib","book","note"],["lib","mag"]]`},
	{`[path(css("book + mag, book ~ mag, mag:has(+ a)"))]`, CSS_BOOK, `[["lib","mag"]]`},
	{`[path(css(":root, :not(:root)"))] | length`, CSS_BOOK, `5`},
	{`[path(css("book:has(note)"))], [path(css("book:not(:has(mag))"))]`, CSS_BOOK, `[["lib","book"]]
[["lib","book"]]`},
	{`[.lib.title | css("*")]`, `<lib><title>A</title></lib>`, `[]`},
	{`css("title") |= ascii_downcase`, `<lib><a><title>ABC</title></a></lib>`, `{"lib":{"a":{"title":"abc"}}}`},
	{`del(css("a > title"))`, `<lib><a><title>ABC</title><u>1</u></a></lib>`, `{"lib":{"a":{"u":"1"}}}`},
	{`[css("title")] | length`, `<lib>text<a>x</a><b><title>t</title></b>more</lib>`, `1`},
	{`.lib.a | [css("*")]`, `<lib><a><b><c/></b></a></lib>`, `[{"c":null},null]`},
	{`[range(150) as $i | css("[n=\"" + ($i | tostring) + "\"]") | 1] | length`, `<r><e n="3"/><e2 n="140"/></r>`, `2`},
	{`[range(3) as $i | css("e") | 1] | length`, `<r><e/></r>`, `3`},
	{`try css("a:hover") catch .`, CSS_BOOK, `"\"a:hover\" (at offset 1) is not a valid selector: Unsupported pseudo-class"`},
	{`try css("a::before") catch .`, CSS_BOOK, `"\"a::before\" (at offset 1) is not a valid selector: Unsupported pseudo-element"`},
	{`try css("svg|a") catch .`, CSS_BOOK, `"\"svg|a\" (at offset 0) is not a valid selector: Unsupported namespace prefix"`},
	{`try css("a >") catch .`, CSS_BOOK, `"\"a >\" (at offset 3) is not a valid selector: Unfinished input"`},
	{`try css("a[b=]") catch .`, CSS_BOOK, `"\"a[b=]\" (at offset 4) is not a valid selector: Invalid selector"`},
	{`try css(1) catch .`, CSS_BOOK, `"number (1) cannot be a selector, as it is not a string"`},
	{`try css("a") catch .`, `{"a":1}`, `"object ({\"a\":1}) cannot be selected from, as it is not an element of an xml or html input"`},
	{`try css("a") catch .`, `[1]`, `"array ([1]) cannot be selected from, as it is not an element of an xml or html input"`},
	{`try (.lib.title | css("a")) catch .`, `<lib><title>A&amp;B</title></lib>`, `"string (\"A&B\") cannot be selected from, as it is not an element of an xml or html input"`},
	{`.r.a, .r.a[0], .r.a[1], (.r.b | type)`, CSS_LIST, `["1","2","3"]
"1"
"2"
"string"`},
	{`.r | keys, length, has("a"), (to_entries | map(.key))`, CSS_LIST, `["a","b"]
2
true
["a","b"]`},
	{`.r | tojson, ([..] | length), (.a | length)`, CSS_LIST, `"{\"a\":[\"1\",\"2\",\"3\"],\"b\":\"x\"}"
6
3`},
	{`[path(css("a"))], [path(css("a:first-child"))], [path(css("b"))]`, CSS_LIST, `[["r","a",0],["r","a",1],["r","a",2]]
[["r","a",0]]
[["r","b"]]`},
	{`[css("a")]`, CSS_LIST, `["1","2","3"]`},
	{`css("a") |= . + "!"`, CSS_LIST, `{"r":{"a":["1!","2!","3!"],"b":"x"}}`},
	{`del(css("a:first-child"))`, CSS_LIST, `{"r":{"a":["2","3"],"b":"x"}}`},
	{`del(css("a"))`, CSS_LIST, `{"r":{"a":[],"b":"x"}}`},
	{`del(.r.a)`, CSS_LIST, `{"r":{"b":"x"}}`},
	{`getpath(["r","a",2]), (setpath(["r","a",1]; "z") | .r.a)`, CSS_LIST, `"3"
["1","z","3"]`},
	{`.r.a == ["1","2","3"], (.r == {"b":"x","a":["1","2","3"]})`, CSS_LIST, `true
true`},
	{`[builtins | .[] | select(startswith("css"))]`, `null`, `["css/1"]`},
}

@(test)
css_selects_elements_of_xml_input_as_a_path_expression :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	for c, i in CSS {
		k := Case{file = "css", line = i, prog = c[0], input = c[1], want = strings.split(c[2], "\n")}
		testing.expectf(t, run_case(k, true) == .Pass, "%s", c[0])
	}
}

// A document 10,000 levels deep, each element the only child of the one around it.
@(test)
css_matches_a_deep_document_without_recursion :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	depth :: 10_000
	text := strings.concatenate({strings.repeat("<a>", depth - 1), "<a/>", strings.repeat("</a>", depth - 1)})
	for prog, i in ([]string{`[css("a a:empty") | 1] | length`, `[path(css(":empty"))[]] | length`, `[css("a:not(:empty) > a:empty") | 1] | length`}) {
		want := []string{"1", "10000", "1"}
		k := Case{file = "css deep", line = i, prog = prog, input = text, want = want[i:i + 1]}
		testing.expectf(t, run_case(k, true) == .Pass, "%s", prog)
	}
}
