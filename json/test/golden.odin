// Checks every text of `golden/json.txt` against the answer the file records for each JSONTestSuite and json5-tests
// file. A marker names the reason where an answer was decided by design.
package json_tests

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:testing"
import core "../../core"
import json ".."
import walktest "../../walktest"

@(private)
GOLDEN :: #load("golden/json.txt")

@(test)
golden_answers :: proc(t: ^testing.T) {
	files := make([dynamic]runtime.Load_Directory_File, 0, 512)
	defer delete(files)
	append(&files, ..#load_directory("conformance/JSONTestSuite/test_parsing"))
	for dir in walktest.JSON5_TESTS {
		append(&files, ..dir[:])
	}
	suite_lines, marked := 0, 0
	rest := string(GOLDEN)
	for line in strings.split_lines_iterator(&rest) {
		if line == "" || line[0] == '#' {
			continue
		}
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 3 {
			testing.expectf(t, false, "short line %q", line)
			return
		}
		answer := fields[len(fields) - 1]
		marker := ""
		if answer != "-" && !strings.contains(answer, ":") {
			marker = answer
			answer = fields[len(fields) - 2]
		}
		kind, at, ok := parse_answer(answer)
		if !ok {
			testing.expectf(t, false, "answer %q in %q", answer, line)
			return
		}
		if fields[0] != "f" {
			testing.expectf(t, false, "line %q names no suite file", line)
			return
		}
		spec := json.Spec(to_int(fields[1]))
		name := fields[2]
		src: []u8
		found := false
		for f in files {
			if f.name == name {
				src, found = f.data, true
				break
			}
		}
		if !testing.expectf(t, found, "no file named %q", name) {
			return
		}
		if !expect_answer(t, src, spec, kind, at, line) {
			return
		}
		suite_lines += 1
		if marker != "" {
			marked += 1
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, suite_lines == len(files) * 3, "%d suite lines, want %d", suite_lines, len(files) * 3)
	testing.expect(t, marked > 0)
}

@(private)
to_int :: proc(field: string) -> int {
	n, _ := strconv.parse_int(field, 10)
	return n
}

// Reads `-` or `<kind>:<byte>`.
@(private)
parse_answer :: proc(field: string) -> (kind: core.Fault_Kind, at: u64, ok: bool) {
	if field == "-" {
		return .None, 0, true
	}
	colon := strings.index_byte(field, ':')
	if colon < 0 {
		return
	}
	k, kok := strconv.parse_int(field[:colon], 10)
	a, aok := strconv.parse_u64(field[colon + 1:], 10)
	if !kok || !aok || k < 0 || k > 255 {
		return
	}
	return core.Fault_Kind(k), a, true
}

@(private)
expect_answer :: proc(t: ^testing.T, src: []u8, spec: json.Spec, kind: core.Fault_Kind, at: u64, line: string) -> bool {
	got, bad := validate_spec(src, spec)
	if !bad {
		return testing.expectf(t, kind == .None, "%q: pass, want %v at %d", line, kind, at)
	}
	return testing.expectf(t, kind == got.kind && at == got.at, "%q: %v at %d, want %v at %d", line, got.kind, got.at, kind, at)
}

@(private)
validate_spec :: proc(src: []u8, spec: json.Spec) -> (core.Fault, bool) {
	switch spec {
	case .Json:
		return json.validate(src, .Json).?
	case .Jsonc:
		return json.validate(src, .Jsonc).?
	case .Json5:
		return json.validate(src, .Json5).?
	}
	return {}, true
}
