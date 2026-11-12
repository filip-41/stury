// Reads and writes of documents, and the built value of one, nested as deep as a text and its aliases make them, on a
// thread whose stack is a quarter of the 1 MB a Windows thread has by default: a pass whose native recursion grows with
// the depth overflows it on every platform.
package yaml_tests

import "core:strings"
import "core:testing"
import core "../../core"
import walktest "../../walktest"
import yaml ".."

@(private = "file")
nested :: proc(levels: int, leaf: string) -> string {
	return strings.concatenate({strings.repeat("[", levels, context.temp_allocator), leaf, strings.repeat("]", levels, context.temp_allocator)}, context.temp_allocator)
}

@(test)
deep_documents_are_read_and_written_on_a_small_stack :: proc(t: ^testing.T) {
	walktest.on_small_stack(t, proc(t: ^testing.T) {
		defer free_all(context.temp_allocator)
		deep_aliases_build(t)

		// A flow collection nested to the walk's limit, judged, built, spanned and written back.
		inner := nested(core.MAX_DEPTH - 1, "7")
		text := strings.concatenate({"a: ", inner, "\n"}, context.temp_allocator)
		walktest.expect_nil(t, yaml.validate(transmute([]u8)text, .Yaml_1_2))
		doc, err := core.build(transmute([]u8)text, yaml.as(.Yaml_1_2))
		defer core.destroy(&doc)
		walktest.expect_nil(t, err)
		a, _ := core.member(&doc, core.ROOT, "a")
		testing.expect_value(t, string(core.span(&doc, a)), inner)
		for pretty in ([]bool{false, true}) {
			out, _, werr := core.write(&doc, {pretty = pretty}, yaml.as(.Yaml_1_2))
			defer delete(out)
			walktest.expect_nil(t, werr)
			testing.expect(t, strings.contains(string(out), inner))
		}

		// Sorted keys write an alias as the node it names, here 1,200 levels deep: 600 block sequences, then the 600 flow
		// collections of `x`.
		alias_text := strings.concatenate({"a: &x ", nested(600, "7"), "\nb:\n", strings.repeat("- ", 600, context.temp_allocator), "*x\n"}, context.temp_allocator)
		adoc, aerr := core.build(transmute([]u8)alias_text, yaml.as(.Yaml_1_2))
		defer core.destroy(&adoc)
		walktest.expect_nil(t, aerr)
		out, _, werr := core.write(&adoc, {pretty = true, sort_keys = true}, yaml.as(.Yaml_1_2))
		defer delete(out)
		walktest.expect_nil(t, werr)
		testing.expect_value(t, strings.count(string(out), "["), 1200)

		// The built value of the alias's host holds its 1,200 levels.
		b, _ := core.member(&adoc, core.ROOT, "b")
		{
			context.allocator = context.temp_allocator
			v := core.built_value(core.Node_Ref{&adoc, b})
			levels := 0
			for {
				inner, ok := core.value_child_at(v, 0)
				if !ok {
					break
				}
				v = inner
				levels += 1
			}
			testing.expect_value(t, levels, 1200)
			testing.expect_value(t, v.(f64), 7)
		}
	})
}
