package yaml_tests

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:yaml"

@(private)
SUITE_DIR :: #directory + "../../../yaml/test/suite"

@(private)
Suite_Case :: struct {
	name: string,
	dir:  string,
}

@(private)
collect_suite_cases :: proc(out: ^[dynamic]Suite_Case, dir, name: string, allocator := context.allocator) {
	infos, err := os.read_directory_by_path(dir, 0, context.temp_allocator)
	if err != nil {
		return
	}
	has_input := false
	for fi in infos {
		if fi.name == "in.yaml" {
			has_input = true
			break
		}
	}
	if has_input {
		append(out, Suite_Case{
			name = strings.clone(name, allocator),
			dir  = strings.clone(dir, allocator),
		})
		return
	}
	for fi in infos {
		if fi.type == .Directory {
			sub := fmt.tprintf("%s/%s", dir, fi.name)
			label := fi.name if name == "" else fmt.tprintf("%s/%s", name, fi.name)
			collect_suite_cases(out, sub, label, allocator)
		}
	}
}

@(private)
load_suite_cases :: proc(allocator := context.allocator) -> []Suite_Case {
	out := make([dynamic]Suite_Case, allocator)
	collect_suite_cases(&out, SUITE_DIR, "", allocator)
	slice.sort_by(out[:], proc(a, b: Suite_Case) -> bool {
		return a.name < b.name
	})
	return out[:]
}

@(private)
free_suite_cases :: proc(list: []Suite_Case, allocator := context.allocator) {
	for c in list {
		delete(c.name, allocator)
		delete(c.dir, allocator)
	}
	delete(list, allocator)
}

@(private)
read_suite_file :: proc(dir, name: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	path := fmt.tprintf("%s/%s", dir, name)
	err: os.Error
	data, err = os.read_entire_file_from_path(path, allocator)
	return data, err == nil
}

@(private)
expect_nil :: proc(t: ^testing.T, err: tape.Error, loc := #caller_location) -> bool {
	return testing.expectf(t, err == nil, "error %v", err, loc = loc)
}

@(private)
faults_with :: proc(err: tape.Error, detail: yaml.Detail) -> bool {
	fault, is_fault := err.(tape.Fault)
	return is_fault && fault.detail == u8(detail)
}

@(private)
tokens_of :: proc(text: string, spec := yaml.Spec.Yaml_1_2, opts := yaml.Options{}, skip := "", stop := 0) -> (tokens: string, hi: u64, err: tape.Error) {
	r := testkit.Token_Log {
		text = transmute([]u8)text,
		skip = skip,
		stop = stop,
		mode = .Yaml,
		ctx  = context,
	}
	strings.builder_init(&r.out, context.temp_allocator)
	regs: hook.Regs
	switch spec {
	case .Yaml_1_2:
		hi, err, _ = yaml.walk(r.text, .Yaml_1_2, opts, &r, &regs, testkit.log_token)
	case .Yaml_Merge:
		hi, err, _ = yaml.walk(r.text, .Yaml_Merge, opts, &r, &regs, testkit.log_token)
	}
	return strings.to_string(r.out), hi, err
}
