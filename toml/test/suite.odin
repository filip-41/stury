// The vendored toml-test cases: their directories as embedded files, and the lists of the cases each language version
// is held to.
package toml_tests

import "base:runtime"
import "core:strings"

@(private)
Directory :: struct {
	prefix: string,
	files:  []runtime.Load_Directory_File,
}

@(private)
SUITE := [?]Directory {
	{"valid/", #load_directory("conformance/toml-test/valid")},
	{"valid/array/", #load_directory("conformance/toml-test/valid/array")},
	{"valid/bool/", #load_directory("conformance/toml-test/valid/bool")},
	{"valid/comment/", #load_directory("conformance/toml-test/valid/comment")},
	{"valid/datetime/", #load_directory("conformance/toml-test/valid/datetime")},
	{"valid/float/", #load_directory("conformance/toml-test/valid/float")},
	{"valid/inline-table/", #load_directory("conformance/toml-test/valid/inline-table")},
	{"valid/integer/", #load_directory("conformance/toml-test/valid/integer")},
	{"valid/key/", #load_directory("conformance/toml-test/valid/key")},
	{"valid/spec-1.0.0/", #load_directory("conformance/toml-test/valid/spec-1.0.0")},
	{"valid/spec-1.1.0/", #load_directory("conformance/toml-test/valid/spec-1.1.0")},
	{"valid/string/", #load_directory("conformance/toml-test/valid/string")},
	{"valid/table/", #load_directory("conformance/toml-test/valid/table")},
	{"invalid/", #load_directory("conformance/toml-test/invalid")},
	{"invalid/array/", #load_directory("conformance/toml-test/invalid/array")},
	{"invalid/bool/", #load_directory("conformance/toml-test/invalid/bool")},
	{"invalid/control/", #load_directory("conformance/toml-test/invalid/control")},
	{"invalid/datetime/", #load_directory("conformance/toml-test/invalid/datetime")},
	{"invalid/encoding/", #load_directory("conformance/toml-test/invalid/encoding")},
	{"invalid/float/", #load_directory("conformance/toml-test/invalid/float")},
	{"invalid/inline-table/", #load_directory("conformance/toml-test/invalid/inline-table")},
	{"invalid/integer/", #load_directory("conformance/toml-test/invalid/integer")},
	{"invalid/key/", #load_directory("conformance/toml-test/invalid/key")},
	{"invalid/local-date/", #load_directory("conformance/toml-test/invalid/local-date")},
	{"invalid/local-datetime/", #load_directory("conformance/toml-test/invalid/local-datetime")},
	{"invalid/local-time/", #load_directory("conformance/toml-test/invalid/local-time")},
	{"invalid/spec-1.0.0/", #load_directory("conformance/toml-test/invalid/spec-1.0.0")},
	{"invalid/spec-1.1.0/", #load_directory("conformance/toml-test/invalid/spec-1.1.0")},
	{"invalid/string/", #load_directory("conformance/toml-test/invalid/string")},
	{"invalid/table/", #load_directory("conformance/toml-test/invalid/table")},
}

@(private)
LIST_1_0 :: #load("conformance/toml-test/files-toml-1.0.0", string)
@(private)
LIST_1_1 :: #load("conformance/toml-test/files-toml-1.1.0", string)

// The case `name`, such as `valid/array/array.toml`, as its bytes.
@(private)
case_data :: proc(name: string) -> (data: []u8, ok: bool) {
	for dir in SUITE {
		if !strings.has_prefix(name, dir.prefix) || strings.contains(name[len(dir.prefix):], "/") {
			continue
		}
		for file in dir.files {
			if file.name == name[len(dir.prefix):] {
				return file.data, true
			}
		}
	}
	return nil, false
}
