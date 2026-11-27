#+build darwin, linux, freebsd, openbsd, netbsd
package yaml_tests

import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"
import "stury:testkit"
import "stury:yaml"

@(private = "file")
nested_flow_arr :: proc(levels: int, leaf: string) -> []u8 {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, "a: ")
	for _ in 0 ..< levels {
		strings.write_byte(&b, '[')
	}
	strings.write_string(&b, leaf)
	for _ in 0 ..< levels {
		strings.write_byte(&b, ']')
	}
	strings.write_byte(&b, '\n')
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
nested_block_seq :: proc(levels: int, leaf: string) -> []u8 {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for _ in 0 ..< levels {
		strings.write_string(&b, "- ")
	}
	strings.write_string(&b, leaf)
	strings.write_byte(&b, '\n')
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
read_deep_flow :: proc(read: int, text: []u8) -> bool {
	opts := yaml.Options{budget = {depth = 200_000}}
	if read < testkit.DEEP_CORE_READS {
		at: []tape.Step
		if read == 6 {
			n := (len(text) - 5) / 2
			at = make([]tape.Step, n, context.temp_allocator)
			at[0] = tape.Name("a")
			for k in 1 ..< n {
				at[k] = tape.Index(0)
			}
		}
		return testkit.deep_core_read(
			read, yaml.reads(.Yaml_1_2), yaml.as(.Yaml_1_2), text, opts,
			{tape.Name("a")}, {{tape.Name("a")}},
			{{tape.Descend{}, tape.Index(0)}, {tape.Descend{}, tape.Name("a")}},
			.Elements, at,
		)
	}
	switch read - testkit.DEEP_CORE_READS {
	case 0:
		v: testkit.Value_Table
		err := yaml.unmarshal(text, &v, .Yaml_1_2, {}, opts)
		testkit.value_free(v)
		return err == nil
	case:
		doc, err := yaml.build(text, .Yaml_1_2, opts)
		defer yaml.destroy(&doc)
		a, _ := yaml.member({&doc, nil}, yaml.ROOT, "a")
		end, ok := yaml.as(.Yaml_1_2).close_end(&doc, a)
		return err == nil && ok && end == u64(len(text) - 1)
	}
}

@(private = "file")
read_deep_block_and_ops :: proc(read: int, text: []u8) -> bool {
	opts := yaml.Options{budget = {depth = 20_000}}
	switch read {
	case 0:
		return yaml.validate(text, .Yaml_1_2, opts) == nil
	case 1:
		doc, err := yaml.build(text, .Yaml_1_2, opts)
		defer yaml.destroy(&doc)
		if err != nil {
			return false
		}
		out, _, werr := yaml.write(&doc, .Yaml_1_2, {indent = 2})
		defer delete(out)
		return werr == nil && yaml.validate(out, .Yaml_1_2, opts) == nil
	case 2:
		d: rules.Description
		d.allocator = context.allocator
		defer rules.description_destroy(&d)
		append(&d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1})
		d.root = 0
		plan, _ := check.compile(&d)
		defer check.plan_destroy(&plan)
		res := yaml.check(text, &plan, .Yaml_1_2, {budget = {depth = 20_000}})
		defer check.result_destroy(&res)
		return res.valid
	case:
		doc, err := yaml.build(text, .Yaml_1_2, opts)
		defer yaml.destroy(&doc)
		if err != nil {
			return false
		}
		ov: yaml.Overlay
		if yaml.edit_init(&ov, &doc) != nil {
			return false
		}
		defer yaml.edit_destroy(&ov)
		// Walk down to deep leaf and replace it cleanly in 1 MiB stack!
		cur := yaml.ROOT
		for doc.nodes[cur].kind == .Array {
			cur = cur + 1
		}
		h, herr := edit.handle_for_base(&ov, cur)
		if herr != nil {
			return false
		}
		if edit.set(&ov, h, edit.val_int(99)) != nil {
			return false
		}
		res, cerr := yaml.commit(&ov, .Yaml_1_2)
		defer edit.destroy_commit_result(&res)
		return cerr == nil
	}
}

// A 1 MiB thread stack reads 100,000-level YAML flow arrays via iterative heap stacks without native recursion.
@(test)
reads_nest_100000_levels_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := nested_flow_arr(100_000, "7")
	testkit.expect_reads_on_thread(t, 1 << 20, testkit.DEEP_CORE_READS + 2, text, "yaml flow 100k", read_deep_flow)
	free_all(context.temp_allocator)
}

// A 1 MiB thread stack validates, builds, writes, checks, and byte-preservingly edits 12,000-level block YAML.
@(test)
deep_block_yaml_operations_run_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := nested_block_seq(12_000, "7")
	testkit.expect_reads_on_thread(t, 1 << 20, 4, text, "yaml block 12k ops", read_deep_block_and_ops)
	free_all(context.temp_allocator)
}
