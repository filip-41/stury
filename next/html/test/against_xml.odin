// Random markup that HTML fragment and XML read alike must produce identical shape and equal values (including facts).
package html_tests

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:html"
import "stury:testkit"
import "stury:xml"

@(private = "file")
NAMES := [?]string{"r", "x", "y", "z", "item", "note", "k-v"}
@(private = "file")
ATTRIBUTES := [?]string{"a", "id", "k", "data-x", "n"}
@(private = "file")
VALUES := [?]string{"v", "w x", "&amp;", "1", "&lt;"}
@(private = "file")
TEXTS := [?]string{"a", "b c", " ", "\n", "  \n  ", "&amp;", "&lt;", "x&amp;y", "1", "true", "é", "\t", "\r\n", "a\rb"}
@(private = "file")
COMMENTS := [?]string{"c", " d e ", "", "x\ny"}
@(private = "file")
INSTRUCTIONS := [?]string{"p d", "q", "t a b"}
@(private = "file")
AROUND := [?]string{"<!--pre-->", "<!--pre-->\n", "\n<!--post-->", "<?pi x?>", "<?pi y?>\n"}

@(private = "file")
random_element :: proc(b: ^strings.Builder, depth: int) {
	name := rand.choice(NAMES[:])
	fmt.sbprintf(b, "<%s", name)
	used: [len(ATTRIBUTES)]bool
	for _ in 0 ..< rand.int_max(3) {
		idx := rand.int_max(len(ATTRIBUTES))
		if used[idx] {
			continue
		}
		used[idx] = true
		quote := "\"" if rand.int_max(2) == 0 else "'"
		fmt.sbprintf(b, "%s%s=%s", " " if rand.int_max(4) > 0 else "\n  ", ATTRIBUTES[idx], quote)
		for _ in 0 ..< rand.int_max(3) {
			strings.write_string(b, rand.choice(VALUES[:]))
		}
		strings.write_string(b, quote)
	}
	strings.write_byte(b, '>')
	for _ in 0 ..< (rand.int_max(5) if depth < 4 else 0) {
		switch rand.int_max(6) {
		case 0, 1:
			for _ in 0 ..= rand.int_max(3) {
				strings.write_string(b, rand.choice(TEXTS[:]))
			}
		case 2, 3:
			random_element(b, depth + 1)
		case 4:
			fmt.sbprintf(b, "<!--%s-->", rand.choice(COMMENTS[:]))
		case 5:
			fmt.sbprintf(b, "<?%s?>", rand.choice(INSTRUCTIONS[:]))
		}
	}
	fmt.sbprintf(b, "</%s>", name)
}

@(test)
random_markup_builds_the_shape_xml_builds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)
	for round in 0 ..< 1000 {
		if round % 64 == 63 {
			free_all(context.temp_allocator)
		}
		b := strings.builder_make(context.temp_allocator)
		if rand.int_max(2) == 0 {
			strings.write_string(&b, rand.choice(AROUND[:2]))
		}
		random_element(&b, 0)
		if rand.int_max(2) == 0 {
			strings.write_string(&b, rand.choice(AROUND[2:]))
		}
		src := transmute([]u8)strings.to_string(b)
		for infer in ([2]bool{false, true}) {
			hdoc, err := html.build(src, .Fragment, {format = html.Xml_Options{infer = infer}}, context.temp_allocator)
			xdoc, xerr := xml.build(src, .Xml, {format = xml.Xml_Options{infer = infer}}, context.temp_allocator)
			if testing.expectf(t, err == nil && xerr == nil, "%q: %v, %v", src, err, xerr) {
				got, want := markup_shape(&hdoc), markup_shape(&xdoc)
				testing.expectf(t, got == want, "%q\n html %s\n xml  %s", src, got, want)
				testkit.values_agree(t, &hdoc, html.ROOT, &xdoc, xml.ROOT, {facts = {.Attribute, .Comment, .Instruction, .Instruction_Foot}}, "html vs xml")
			}
		}
	}
}
