#+build darwin, linux, freebsd, openbsd, netbsd
package html_tests

import "core:strings"
import "core:testing"
import "stury:html"
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
	switch read {
	case 0:
		return html.validate(text, .Fragment, opts) == nil
	case 1:
		doc, err := html.build(text, .Fragment, opts)
		defer html.destroy(&doc)
		return err == nil
	case 2:
		answer, err := html.find(text, {html.Name("div"), html.Name("div")}, .Fragment, {}, opts)
		return err == nil && answer.outcome == .Found
	case 3:
		d, _ := html.demand_of({{html.Name("div"), html.Name("div")}})
		defer html.destroy(&d)
		r, err := html.scan(text, &d, .Fragment, {}, opts)
		defer html.destroy(&r)
		return err == nil
	case 4:
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
	testkit.expect_reads_on_thread(t, 1 << 20, 6, nested_text(100_000), "html_elements", read_nested)
	free_all(context.temp_allocator)
}
