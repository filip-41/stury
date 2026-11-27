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

@(private = "file")
read_nested :: proc(read: int, text: []u8) -> bool {
	opts := xml.Options{budget = {depth = 200_000}}
	if read < testkit.DEEP_CORE_READS {
		return testkit.deep_core_read(
			read, xml.reads(.Xml), xml.as(.Xml), text, opts,
			{tape.Name("a"), tape.Name("a")},
			{{tape.Name("a"), tape.Name("a")}},
			{{tape.Descend{}, tape.Name("a")}},
			.Concatenated, nil,
		)
	}
	doc, err := xml.build(text, opts = opts)
	defer tape.destroy(&doc)
	a, _ := xml.member({&doc, nil}, xml.ROOT, "a")
	end, ok := doc.format.close_end(&doc, a)
	return err == nil && ok && end == u64(len(text))
}

// A thread of one MiB reads a text of 100,000 levels, which the levels past the frame take from the allocator and not
// from the stack.
@(test)
reads_nest_100000_levels_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testkit.expect_reads_on_thread(t, 1 << 20, testkit.DEEP_CORE_READS + 1, nested_text(100_000), "elements", read_nested)
	free_all(context.temp_allocator)
}
