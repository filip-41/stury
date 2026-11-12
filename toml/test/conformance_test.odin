// Judges every case of the toml-test lists for each language version: a valid case reads, an invalid case is refused.
package toml_tests

import "core:strings"
import "core:testing"
import toml ".."
import walktest "../../walktest"

@(private)
check_list :: proc(t: ^testing.T, list: string, spec: toml.Spec) -> (cases: int) {
	rest := list
	for name in strings.split_lines_iterator(&rest) {
		if !strings.has_suffix(name, ".toml") {
			continue
		}
		data, found := case_data(name)
		if !testing.expectf(t, found, "%s is not vendored", name) {
			continue
		}
		fault, refused := walktest.fault_of(toml.validate(data, spec)).?
		switch {
		case strings.has_prefix(name, "valid/"):
			testing.expectf(t, !refused, "%s: %v", name, fault)
		case strings.has_prefix(name, "invalid/"):
			testing.expectf(t, refused, "%s", name)
		}
		cases += 1
	}
	return
}

@(test)
suite_toml_1_0 :: proc(t: ^testing.T) {
	testing.expect_value(t, check_list(t, LIST_1_0, .Toml_1_0), 717)
}

@(test)
suite_toml_1_1 :: proc(t: ^testing.T) {
	testing.expect_value(t, check_list(t, LIST_1_1, .Toml_1_1), 720)
}
