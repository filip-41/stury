// Writes the golden file in `next/json/test/golden`: the old tree's answer for every JSONTestSuite and json5-tests
// file per spec, one line per file and spec. Where `compare/json_oracle` accepts a difference between the trees by
// design, the line holds `next`'s answer and a marker naming the reason, so the test checks the agreed behaviour.
//
// Usage: golden <json golden dir>. `make golden` passes it.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import core "../../next/core"
import walktest "../../next/walktest"
import njson "../../next/json"
import oracle "../json_oracle"
import ojson "stury:json"

// The header the file starts with, for a reader who opens it. Lines starting with `#` are not texts.
JSON_HEADER ::
	"# The old tree's answer for each json text, one line per file and spec, written by compare/golden.\n" +
	"# f <spec> <file> <answer> is a suite file, spec 0 Json, 1 Jsonc, 2 JSON5. An answer is - for a pass, or\n" +
	"# <core.Fault_Kind>:<byte>. A trailing marker names a difference the oracle accepts by design, in which case the\n" +
	"# answer is next's: cap a digit or scale cap, j5-comment, j5-escape, j5-key, j5-word or j5-letter a JSON5 part.\n" +
	"# Regenerate with make -C ../compare golden.\n"

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: golden <json golden dir>")
		os.exit(2)
	}
	write_json(os.args[1])
}

// Writes the json golden file, whose identifier for a suite file is its name and spec.
write_json :: proc(dir: string) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, JSON_HEADER)
	files := make([dynamic]runtime.Load_Directory_File, 0, 512)
	defer delete(files)
	suite := #load_directory("../../next/json/test/conformance/JSONTestSuite/test_parsing")
	append(&files, ..suite[:])
	for dir in walktest.JSON5_TESTS {
		append(&files, ..dir[:])
	}
	slice.sort_by(files[:], proc(a, b: runtime.Load_Directory_File) -> bool { return a.name < b.name })
	for f in files {
		for spec in ([]njson.Spec{.Json, .Jsonc, .Json5}) {
			answer, marker, ok := json_answer(f.data, spec)
			if !ok {
				fmt.eprintfln("%s as %v: the trees disagree with no named reason", f.name, spec)
				os.exit(1)
			}
			fmt.sbprintf(&b, "f %d %s %s%s\n", u8(spec), f.name, answer, marker_text(marker))
		}
	}
	write(dir, "json.txt", strings.to_string(b))
}

// Returns next's answer for `src` as `-` or `<kind>:<byte>`, a marker for an accepted difference, and whether the old
// tree agrees or the oracle accepts the difference.
json_answer :: proc(src: []u8, spec: njson.Spec) -> (answer, marker: string, ok: bool) {
	old, old_bad := ojson.validate(src, {dialect = ojson.Dialect(spec)}).?
	got, got_bad := json_validate(src, spec).?
	answer = fault_answer(got, got_bad)
	if old_bad && (old.kind == .Limit_Digits || old.kind == .Limit_Scale) {
		return answer, "cap", true
	}
	if old_bad == got_bad && (!got_bad || ((fmt.tprint(old.kind) == fmt.tprint(got.kind) || old.kind == .Trailing && got.detail == u8(njson.Detail.Trailing)) && old.offset == got.at)) {
		return answer, "", true
	}
	if spec == .Json5 {
		part := oracle.json5_parts(src, got if got_bad else {}, old if old_bad else {})
		if part != .None {
			return answer, part_name(part), true
		}
	}
	return answer, "", false
}

part_name :: proc(part: oracle.Part) -> string {
	switch part {
	case .None:
		return ""
	case .Comment:
		return "j5-comment"
	case .Escape:
		return "j5-escape"
	case .Key:
		return "j5-key"
	case .Word:
		return "j5-word"
	case .Letter_Number:
		return "j5-letter"
	}
	return ""
}

marker_text :: proc(marker: string) -> string {
	return "" if marker == "" else fmt.tprintf(" %s", marker)
}

// `validate` takes its spec at compile time, so a run-time spec picks an instance.
json_validate :: proc(src: []u8, spec: njson.Spec) -> Maybe(core.Fault) {
	switch spec {
	case .Json:
		return njson.validate(src, .Json)
	case .Jsonc:
		return njson.validate(src, .Jsonc)
	case .Json5:
		return njson.validate(src, .Json5)
	}
	return nil
}

fault_answer :: proc(f: core.Fault, bad: bool) -> string {
	if !bad {
		return "-"
	}
	return fmt.tprintf("%d:%d", u8(f.kind), f.at)
}

// Writes `body` to `dir/name`, creating the directory when it is absent.
write :: proc(dir, name, body: string) {
	if !os.exists(dir) {
		if err := os.make_directory(dir); err != nil {
			fmt.eprintfln("golden: %s: %v", dir, err)
			os.exit(1)
		}
	}
	path := fmt.tprintf("%s/%s", dir, name)
	if err := os.write_entire_file(path, body); err != nil {
		fmt.eprintfln("golden: %s: %v", path, err)
		os.exit(1)
	}
	fmt.printfln("%s: %d bytes", path, len(body))
}
