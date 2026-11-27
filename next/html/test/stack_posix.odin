#+build darwin, linux, freebsd, openbsd, netbsd
package html_tests

import "core:strings"
import "core:testing"
import "stury:html"
import "stury:lib/core/tape"
import "stury:testkit"

@(private = "file")
nested_text :: proc(depth: int) -> []u8 {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for _ in 0 ..< depth {
		strings.write_string(&b, "<div>")
	}
	strings.write_string(&b, "1")
	for _ in 0 ..< depth {
		strings.write_string(&b, "</div>")
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
read_nested :: proc(read: int, text: []u8) -> bool {
	opts := html.Options{budget = {depth = 200_000}}
	if read < testkit.DEEP_CORE_READS {
		return testkit.deep_core_read(
			read, html.reads(.Fragment), html.as(.Fragment), text, opts,
			{tape.Name("div"), tape.Name("div")},
			{{tape.Name("div"), tape.Name("div")}},
			{{tape.Descend{}, tape.Name("div")}},
			.Concatenated, nil,
		)
	}
	switch read - testkit.DEEP_CORE_READS {
	case 0:
		doc, err := html.build(text, .Fragment, opts)
		defer html.destroy(&doc)
		d, _ := html.member({&doc, nil}, html.ROOT, "div")
		end, ok := doc.format.close_end(&doc, d)
		return err == nil && ok && end == u64(len(text))
	case:
		doc, err := html.build(text, .Fragment, opts)
		defer html.destroy(&doc)
		if err != nil {
			return false
		}
		out, _, werr := html.write(&doc, .Fragment)
		defer delete(out)
		return werr == nil && len(out) == len(text)
	}
}

// A thread with 1 MiB stack reads and writes 100,000 nested `<div>` elements cleanly with zero stack overflow.
@(test)
reads_nest_100000_levels_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testkit.expect_reads_on_thread(t, 1 << 20, testkit.DEEP_CORE_READS + 2, nested_text(100_000), "html_elements", read_nested)
	free_all(context.temp_allocator)
}
