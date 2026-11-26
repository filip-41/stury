package yaml_tests

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
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
ROLE_NAMES := [tape.Role]string {
	.Value            = "",
	.Key              = "Key:",
	.Comment          = "Comment:",
	.Comment_Inline   = "Inline:",
	.Comment_Foot     = "Foot:",
	.Tag              = "Tag:",
	.Anchor           = "Anchor:",
	.Alias            = "Alias:",
	.Instruction      = "Instruction:",
	.Instruction_Foot = "Instruction_Foot:",
	.Doctype          = "Doctype:",
	.Directive        = "Directive:",
	.Attribute        = "Attribute:",
}

@(private)
Token_Log :: struct {
	text:     []u8,
	out:      strings.Builder,
	skip:     string,
	stop:     int,
	given:    int,
	skipping: bool,
	protocol: hook.Protocol(hook.Capabilities{.Skips}, hook.Unused, hook.Unused, hook.Unused),
}

@(private)
log_token :: proc "contextless" (h: ^Token_Log, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	context = runtime.default_context()
	if h.out.buf != nil && len(h.out.buf) > 0 {
		strings.write_byte(&h.out, ' ')
	}
	h.given += 1
	switch {
	case t.role != .Value:
		fmt.sbprintf(&h.out, "%s%s", ROLE_NAMES[t.role], string(h.text[t.lo:][:t.n]))
	case t.kind > .Plain:
		fmt.sbprintf(&h.out, "%v", t.kind)
	case:
		star := "*" if t.spelling & tape.SPELLING_QUOTED != 0 else ""
		fmt.sbprintf(&h.out, "%v%s:%s", t.kind, star, string(h.text[t.lo:][:t.n]))
	}
	a := hook.Action.Next
	if h.skipping && t.kind > .Plain && t.kind != .End {
		h.skipping, a = false, .Skip
	}
	if t.role == .Key && string(h.text[t.lo:][:t.n]) == h.skip && h.skip != "" {
		h.skipping = true
	}
	if h.stop != 0 && h.given == h.stop {
		a = .Stop
	}
	return s, a
}

@(private)
tokens_of :: proc(text: string, spec := yaml.Spec.Yaml_1_2, opts := yaml.Options{}, skip := "", stop := 0) -> (tokens: string, hi: u64, err: tape.Error) {
	r := Token_Log {
		text = transmute([]u8)text,
		skip = skip,
		stop = stop,
	}
	strings.builder_init(&r.out, context.temp_allocator)
	regs: hook.Regs
	switch spec {
	case .Yaml_1_2:
		hi, err, _ = yaml.walk(r.text, .Yaml_1_2, opts, &r, &regs, log_token)
	case .Yaml_Merge:
		hi, err, _ = yaml.walk(r.text, .Yaml_Merge, opts, &r, &regs, log_token)
	}
	return strings.to_string(r.out), hi, err
}

@(private)
dump_node :: proc(b: ^strings.Builder, doc: ^tape.Document, i: tape.Node_Index) -> tape.Node_Index {
	node := doc.nodes[i]
	r := tape.Reader{doc = doc}
	switch node.kind {
	case .Null:
		strings.write_string(b, "null")
	case .False:
		strings.write_string(b, "false")
	case .True:
		strings.write_string(b, "true")
	case .Number:
		n, _ := tape.node_number(doc, i)
		switch n.kind {
		case .Int:
			fmt.sbprintf(b, "%d", i64(n.bits))
		case .Uint:
			fmt.sbprintf(b, "%d", n.bits)
		case .Float:
			f := transmute(f64)n.bits
			if f != f {
				strings.write_string(b, "nan")
			} else {
				fmt.sbprintf(b, "%v", f)
			}
		case .Wide:
			strings.write_string(b, "wide")
		}
	case .Bytes:
		room := max(tape.text_room(doc, i), int(node.n))
		buf := make([]u8, room, context.temp_allocator)
		s, _ := tape.node_text(doc, i, buf)
		fmt.sbprintf(b, "bin:%q", s)
	case .String, .Plain:
		room := max(tape.text_room(doc, i), int(node.n))
		buf := make([]u8, room, context.temp_allocator)
		s, _ := tape.node_text(doc, i, buf)
		fmt.sbprintf(b, "%q", s)
	case .Array, .Object:
		strings.write_byte(b, '[' if node.kind == .Array else '{')
		c, _, _ := tape.children(r, i, context.temp_allocator)
		defer tape.destroy(&c)
		for first := true; ; first = false {
			key, val, p := tape.next_child(r, &c)
			if p != .Found {
				break
			}
			if !first {
				strings.write_byte(b, ',')
			}
			if node.kind == .Object {
				dump_node(b, doc, key)
				strings.write_byte(b, ':')
			}
			dump_node(b, doc, val)
		}
		strings.write_byte(b, ']' if node.kind == .Array else '}')
		return i + tape.Node_Index(node.n)
	case .End:
	}
	return i + 1
}

@(private)
dumped :: proc(text: string, spec := yaml.Spec.Yaml_1_2, opts := yaml.Options{}) -> (out: string, err: tape.Error) {
	doc, derr := yaml.build(transmute([]u8)text, spec, opts, context.temp_allocator)
	if derr != nil {
		return "", derr
	}
	b := strings.builder_make(context.temp_allocator)
	dump_node(&b, &doc, yaml.ROOT)
	return strings.to_string(b), nil
}
