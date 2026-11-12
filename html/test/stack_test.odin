// A document nested to the walk's limit, read, built, written as JSON and turned into its value, on a thread whose stack
// is a quarter of the 1 MB a Windows thread has by default: a pass whose native recursion grows with the depth
// overflows it on every platform.
package html_tests

import "core:strings"
import "core:testing"
import core "../../core"
import json "../../json"
import walktest "../../walktest"
import html ".."

@(test)
a_deep_document_is_read_and_written_on_a_small_stack :: proc(t: ^testing.T) {
	walktest.on_small_stack(t, proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)
		// The tree puts `html` and `body` above the divs, and the divs' text is one level below the last.
		levels := core.MAX_DEPTH - 4
		text := strings.concatenate({"<!DOCTYPE html>", strings.repeat("<div>", levels, context.temp_allocator), "x", strings.repeat("</div>", levels, context.temp_allocator)}, context.temp_allocator)
		walktest.expect_nil(t, html.validate(transmute([]u8)text, .Document))
		doc, err := core.build(transmute([]u8)text, html.as(.Document))
		defer core.destroy(&doc)
		walktest.expect_nil(t, err)

		for pretty in ([]bool{false, true}) {
			out, _, werr := core.write(&doc, {pretty = pretty}, json.as(.Json))
			defer delete(out)
			walktest.expect_nil(t, werr)
			testing.expect_value(t, strings.count(string(out), "{"), levels + 2)
		}

		context.allocator = context.temp_allocator
		v := core.built_value(core.Node_Ref{&doc, core.ROOT})
		// Down `html`, `body` and each div to the innermost div's text.
		depth := 0
		for name in ([]string{"html", "body"}) {
			v, _ = core.value_member(v, name)
			depth += 1
		}
		for core.value_kind(v) == .Object {
			inner, ok := core.value_member(v, "div")
			if !ok {
				break
			}
			v = inner
			depth += 1
		}
		testing.expect_value(t, depth, levels + 2)
		leaf, is_text := v.(string)
		testing.expect(t, is_text && leaf == "x", "the innermost div's text is x")
	})
}
