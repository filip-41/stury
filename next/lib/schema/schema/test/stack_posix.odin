#+build darwin, linux, freebsd, openbsd, netbsd
// Proves `infer_document` + `infer_merge` + `inferred` handle 10,000-level deep documents inside a 1 MiB thread stack!
package schema_test

import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"
import "stury:lib/schema/schema"
import "stury:testkit"

@(private = "file")
run_deep_infer_on_thread :: proc(_: int, text: []u8) -> bool {
	doc, berr := json.build(text, .Json, {budget = {depth = 10_016}})
	if berr != nil {
		return false
	}
	defer tape.destroy_document(&doc)

	inf := schema.Inferred{ranges = true}
	defer schema.inferred_destroy(&inf)
	if schema.infer_document(&inf, &doc) != .None {
		return false
	}
	inf2 := schema.Inferred{ranges = true}
	defer schema.inferred_destroy(&inf2)
	if schema.infer_merge(&inf2, &inf) != .None {
		return false
	}
	desc, ierr := schema.inferred(&inf2)
	if ierr != .None {
		return false
	}
	defer rules.description_destroy(&desc)
	return len(desc.nodes) == 10_001
}

@(test)
infer_10000_levels_in_one_mib_stack :: proc(t: ^testing.T) {
	testkit.deadline(t)
	DEPTH :: 10_000
	// Nested arrays
	ba := strings.builder_make(0, DEPTH * 2 + 4)
	defer strings.builder_destroy(&ba)
	for _ in 0 ..< DEPTH {
		strings.write_byte(&ba, '[')
	}
	strings.write_byte(&ba, '1')
	for _ in 0 ..< DEPTH {
		strings.write_byte(&ba, ']')
	}
	testkit.expect_reads_on_thread(t, 1 << 20, 1, transmute([]u8)strings.to_string(ba), "infer 10k arrays", run_deep_infer_on_thread)

	// Nested objects
	bo := strings.builder_make(0, DEPTH * 6 + 4)
	defer strings.builder_destroy(&bo)
	for _ in 0 ..< DEPTH {
		strings.write_string(&bo, `{"k":`)
	}
	strings.write_byte(&bo, '1')
	for _ in 0 ..< DEPTH {
		strings.write_byte(&bo, '}')
	}
	testkit.expect_reads_on_thread(t, 1 << 20, 1, transmute([]u8)strings.to_string(bo), "infer 10k objects", run_deep_infer_on_thread)
}

@(private = "file")
run_deep_write_on_thread :: proc(_: int, text: []u8) -> bool {
	doc, berr := json.build(text, .Json, {budget = {depth = 5000}})
	if berr != nil {
		return false
	}
	defer tape.destroy_document(&doc)

	written, werr := schema.convert_to_2020_12(&doc)
	if werr.kind != .None {
		schema.error_destroy(&werr)
		return false
	}
	defer delete(written)
	return len(written) > 20_000
}

@(test)
write_schema_deep_2000_levels_in_one_mib_stack :: proc(t: ^testing.T) {
	testkit.deadline(t)
	DEPTH :: 2_000
	b := strings.builder_make(0, DEPTH * 36 + 32)
	defer strings.builder_destroy(&b)
	for _ in 0 ..< DEPTH {
		strings.write_string(&b, `{"type":"object","properties":{"a":`)
	}
	strings.write_string(&b, `{"type":"integer"}`)
	for _ in 0 ..< DEPTH {
		strings.write_string(&b, `}}`)
	}
	testkit.expect_reads_on_thread(t, 1 << 20, 1, transmute([]u8)strings.to_string(b), "write_schema 2k deep", run_deep_write_on_thread)
}
