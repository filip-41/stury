#+build darwin, linux, freebsd, openbsd, netbsd
package xml_tests

import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

// A text of `depth` elements `a`, each the only child of the one around it, with a text in the innermost.
@(private = "file")
nested_text :: proc(depth: int) -> []u8 {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for _ in 0 ..< depth {
		strings.write_string(&b, "<a>")
	}
	strings.write_string(&b, "1")
	for _ in 0 ..< depth {
		strings.write_string(&b, "</a>")
	}
	return transmute([]u8)strings.to_string(b)
}

// Reads the nested text five ways: a verdict, a document, the outermost element's value, a scan, and where a
// document's root element closes.
@(private = "file")
read_nested :: proc(read: int, text: []u8) -> bool {
	opts := xml.Options{budget = {depth = 200_000}}
	switch read {
	case 0:
		return xml.validate(text, opts = opts) == nil
	case 1:
		doc, err := xml.build(text, opts = opts)
		tape.destroy(&doc)
		return err == nil
	case 2:
		answer, err := xml.find(text, {tape.Name("a"), tape.Name("a")}, opts = opts)
		return err == nil && answer.outcome == .Found
	case 3:
		d, _ := tape.demand_of({{tape.Name("a"), tape.Name("a")}})
		r, err := xml.scan(text, &d, opts = opts)
		tape.destroy(&r)
		tape.destroy(&d)
		return err == nil
	case:
		doc, err := xml.build(text, opts = opts)
		defer tape.destroy(&doc)
		a, _ := xml.member({&doc, nil}, xml.ROOT, "a")
		end, ok := doc.format.close_end(&doc, a)
		return err == nil && ok && end == u64(len(text))
	}
}

// A thread of one MiB reads a text of 100,000 levels, which the levels past the frame take from the allocator and not
// from the stack.
@(test)
reads_nest_100000_levels_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testkit.expect_reads_on_thread(t, 1 << 20, 5, nested_text(100_000), "elements", read_nested)
	free_all(context.temp_allocator)
}
