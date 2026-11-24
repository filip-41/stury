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
	if read >= 6 {
		// The steps to the innermost container of each `nested_text`, from its length.
		arrays, inline := text[4] == '[', text[4] == '{'
		steps := (len(text) - 6) / 2 if arrays else (len(text) - 6) / 4 if inline else (len(text) - 2) / 2 - 1 if text[0] == '[' else (len(text) - 4) / 2 - 1
		at := make([]tape.Step, steps, context.temp_allocator)
		for &step, k in at {
			step = tape.Index(0) if arrays && k > 0 else tape.Name("a")
		}
		paths := [][]tape.Step{{tape.Descend{}, tape.Index(0)}, {tape.Descend{}, tape.Name("a")}}
		return testkit.deep_read(read - 6, toml.reads(.Toml_1_0), toml.as(.Toml_1_0), text, opts, paths, .Elements if arrays else .Members, at)
	}
	switch read {
	case 0:
		return toml.validate(text, opts = opts) == nil
	case 1:
		doc, err := toml.build(text, opts = opts)
		tape.destroy(&doc)
		return err == nil
	case 2:
		answer, err := toml.find(text, {tape.Name("a")}, opts = opts)
		return err == nil && answer.outcome == .Found
	case 3:
		d, _ := tape.demand_of({{tape.Name("a")}})
		r, err := toml.scan(text, &d, opts = opts)
		tape.destroy(&r)
		tape.destroy(&d)
		return err == nil
	case 5:
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

// A thread of one MiB reads a text of 100,000 levels, which the levels past the frame take from the allocator and not
// from the stack.
@(test)
reads_nest_100000_levels_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for nesting in Nesting {
		text := nested_text(100_000, nesting)
		testkit.expect_reads_on_thread(t, 1 << 20, 6 + testkit.DEEP_READS, text, fmt.tprint(nesting), read_nested)
		free_all(context.temp_allocator)
	}
}
