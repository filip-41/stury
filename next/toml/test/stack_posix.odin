#+build darwin, linux, freebsd, openbsd, netbsd
package toml_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

// The ways a TOML text nests: values in arrays or inline tables, and tables in a header's path or a dotted key.
@(private = "file")
Nesting :: enum {
	Arrays,
	Inline_Tables,
	Header,
	Dotted_Key,
}

// A text whose member `a` nests `depth` levels the way `nesting` says.
@(private = "file")
nested_text :: proc(depth: int, nesting: Nesting) -> []u8 {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	switch nesting {
	case .Arrays, .Inline_Tables:
		strings.write_string(&b, "a = ")
		for _ in 0 ..< depth {
			strings.write_string(&b, "{a=" if nesting == .Inline_Tables else "[")
		}
		strings.write_string(&b, "1")
		for _ in 0 ..< depth {
			strings.write_string(&b, "}" if nesting == .Inline_Tables else "]")
		}
	case .Header, .Dotted_Key:
		strings.write_string(&b, "[a" if nesting == .Header else "a")
		for _ in 1 ..< depth {
			strings.write_string(&b, ".a")
		}
		strings.write_string(&b, "]" if nesting == .Header else " = 1")
	}
	strings.write_string(&b, "\n")
	return transmute([]u8)strings.to_string(b)
}

// Reads the nested text six ways, a verdict, a document, the value of `a`, a scan, where a document's `a` closes and a
// typed read, and `testkit.deep_read`'s ways, which take the records of the innermost container that holds one.
@(private = "file")
read_nested :: proc(read: int, text: []u8) -> bool {
	opts := toml.Options{budget = {depth = 200_000}}
	if read < testkit.DEEP_CORE_READS {
		arrays := text[4] == '['
		at: []tape.Step
		if read == 6 {
			// The steps to the innermost container of each `nested_text`, from its length.
			inline := text[4] == '{'
			steps := (len(text) - 6) / 2 if arrays else (len(text) - 6) / 4 if inline else (len(text) - 2) / 2 - 1 if text[0] == '[' else (len(text) - 4) / 2 - 1
			at = make([]tape.Step, steps, context.temp_allocator)
			for &step, k in at {
				step = tape.Index(0) if arrays && k > 0 else tape.Name("a")
			}
		}
		return testkit.deep_core_read(
			read, toml.reads(.Toml_1_0), toml.as(.Toml_1_0), text, opts,
			{tape.Name("a")}, {{tape.Name("a")}},
			{{tape.Descend{}, tape.Index(0)}, {tape.Descend{}, tape.Name("a")}},
			.Elements if arrays else .Members, at,
		)
	}
	switch read - testkit.DEEP_CORE_READS {
	case 0:
		v: testkit.Value_Table
		err := toml.unmarshal(text, &v, opts = opts)
		testkit.value_free(v)
		return err == nil
	case:
		doc, err := toml.build(text, opts = opts)
		defer tape.destroy(&doc)
		a, _ := toml.member({&doc, nil}, toml.ROOT, "a")
		end, ok := doc.format.close_end(&doc, a)
		return err == nil && ok && end == u64(len(text) - 1)
	}
}

@(private = "file")
write_nested_dotted :: proc(_: int, text: []u8) -> bool {
	doc, err := toml.build(text, .Toml_1_0, {budget = {depth = 20_000}})
	if err != nil {
		return false
	}
	defer tape.destroy(&doc)
	out, _, werr := toml.write(&doc, .Toml_1_0)
	defer delete(out)
	return werr == nil && string(out) == string(text)
}

// A thread of one MiB reads a text of 100,000 levels, which the levels past the frame take from the allocator and not
// from the stack.
@(test)
reads_nest_100000_levels_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for nesting in Nesting {
		text := nested_text(100_000, nesting)
		testkit.expect_reads_on_thread(t, 1 << 20, testkit.DEEP_CORE_READS + 2, text, fmt.tprint(nesting), read_nested)
		free_all(context.temp_allocator)
	}
}

// A thread of one MiB writes 10,000+ nested dotted keys without overflowing the native stack.
@(test)
writes_deep_dotted_keys_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := nested_text(12_000, .Dotted_Key)
	testkit.expect_reads_on_thread(t, 1 << 20, 1, text, "Dotted_Key write", write_nested_dotted)
	free_all(context.temp_allocator)
}
