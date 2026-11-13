// The yaml-test-suite cases against the walk: the tokens of each `in.yaml`, printed as the suite's event stream, must
// equal its `test.event`, and a case with an `error` marker must fault.
package yaml_tests

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import core "../../core"
import yaml ".."

@(private)
SUITE_DIR :: #directory + "suite"

@(private)
Frame :: struct {
	seq:     bool,
	bracket: bool, // the token sits on a bracket
	mark:    int, // where the flow marker goes in the output
}

@(private)
Printer :: struct {
	src:     []u8,
	out:     strings.Builder,
	handles: map[string]string,
	stack:   [dynamic]Frame,
	alias:   bool, // the next value token is an alias expansion
	skip:    int, // the depth inside an expansion being passed
}

@(private)
escaped :: proc(b: ^strings.Builder, s: string) {
	for c in transmute([]u8)s {
		switch c {
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\t': strings.write_string(b, "\\t")
		case '\r': strings.write_string(b, "\\r")
		case 8:    strings.write_string(b, "\\b")
		case 0:    strings.write_string(b, "\\0")
		case:      strings.write_byte(b, c)
		}
	}
}

@(private)
unpercent :: proc(s: string) -> string {
	b: strings.Builder
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			v, ok := strconv.parse_int(s[i + 1:i + 3], 16)
			if ok {
				strings.write_byte(&b, u8(v))
				i += 2
				continue
			}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

@(private)
resolve_tag :: proc(pr: ^Printer, tag: string) -> string {
	if strings.has_prefix(tag, "!<") {
		return fmt.tprintf("<%s>", tag[2:len(tag) - 1])
	}
	if tag == "!" {
		return "<!>"
	}
	if strings.has_prefix(tag, "!!") {
		prefix := pr.handles["!!"] or_else "tag:yaml.org,2002:"
		return fmt.tprintf("<%s%s>", prefix, unpercent(tag[2:]))
	}
	if i := strings.index_byte(tag[1:], '!'); i >= 0 {
		handle := tag[:i + 2]
		if prefix, ok := pr.handles[handle]; ok {
			return fmt.tprintf("<%s%s>", prefix, unpercent(tag[i + 2:]))
		}
	}
	prefix := pr.handles["!"] or_else "!"
	return fmt.tprintf("<%s%s>", prefix, unpercent(tag[1:]))
}

@(private)
properties :: proc(pr: ^Printer, props: ^[2]string) {
	if props[0] != "" {
		fmt.sbprintf(&pr.out, " &%s", props[0])
	}
	if props[1] != "" {
		fmt.sbprintf(&pr.out, " %s", resolve_tag(pr, props[1]))
	}
	props^ = {}
}

@(private)
Recorder :: struct {
	using printer: Printer,
	props:         [2]string, // anchor name, tag
}

@(private)
record :: proc "contextless" (r: ^Recorder, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = runtime.default_context()
	text := string(r.src[t.lo:t.lo + u64(t.n)])
	#partial switch t.role {
	case .Comment, .Comment_Inline, .Comment_Foot:
		return s, .Next
	case .Anchor:
		r.props[0] = text[1:]
		return s, .Next
	case .Tag:
		r.props[1] = text
		return s, .Next
	case .Alias:
		fmt.sbprintf(&r.out, "=ALI %s\n", text)
		r.alias = true
		return s, .Next
	}
	container := t.kind == .Array || t.kind == .Object
	if r.skip > 0 {
		if container {
			r.skip += 1
		} else if t.kind == .End {
			r.skip -= 1
		}
		return s, .Next
	}
	if r.alias {
		r.alias = false
		if container {
			r.skip = 1
		}
		return s, .Next
	}
	switch t.kind {
	case .Array, .Object:
		seq := t.kind == .Array
		strings.write_string(&r.out, "+SEQ" if seq else "+MAP")
		bracket := t.lo < u64(len(r.src)) && r.src[t.lo] == ('[' if seq else '{')
		append(&r.stack, Frame{seq, bracket, strings.builder_len(r.out)})
		properties(r, &r.props)
		strings.write_byte(&r.out, '\n')
	case .End:
		top := pop(&r.stack)
		parent_seq := len(r.stack) > 0 && r.stack[len(r.stack) - 1].seq && r.stack[len(r.stack) - 1].bracket
		if t.n == 1 || t.n == 0 && !top.seq && parent_seq {
			marker := " []" if top.seq else " {}"
			inject_at_elems(&r.out.buf, top.mark, marker[0], marker[1], marker[2])
		}
		strings.write_string(&r.out, "-SEQ\n" if top.seq else "-MAP\n")
	case .Null, .False, .True, .Number, .Bytes, .String, .Plain:
		strings.write_string(&r.out, "=VAL")
		properties(r, &r.props)
		style: string
		if t.n > 0 {
			switch r.src[t.lo] {
			case '\'': style = "'"
			case '"':  style = "\""
			case '|':  style = "|"
			case '>':  style = ">"
			}
		}
		if style == "" {
			style = ":"
		}
		buf := make([]u8, 3 * int(t.n) + 4)
		view := core.Token_View{src = r.src}
		decoded, ok := yaml.text(&view, t, buf)
		strings.write_byte(&r.out, ' ')
		strings.write_string(&r.out, style)
		escaped(&r.out, decoded if ok else "<overflow>")
		strings.write_byte(&r.out, '\n')
	}
	return s, .Next
}

// The suite's directive handles of the document that starts at `lo`.
@(private)
read_handles :: proc(pr: ^Printer, lo: u64) {
	clear(&pr.handles)
	rest := string(pr.src[lo:])
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "---") || strings.has_prefix(line, "...") {
			break
		}
		if strings.has_prefix(line, "%TAG ") {
			f := strings.fields(line)
			if len(f) >= 3 {
				pr.handles[f[1]] = f[2]
			}
		}
	}
}

// The event stream of `src`, and the fault the walk stopped on.
@(private)
events :: proc(src: []u8) -> (text: string, fault: Maybe(core.Fault)) {
	r := Recorder{}
	r.src = src
	strings.write_string(&r.out, "+STR\n")
	lo := u64(0)
	for lo < u64(len(src)) {
		read_handles(&r, lo)
		mark := strings.builder_len(r.out)
		strings.write_string(&r.out, "+DOC\n")
		hi: u64
		hi, fault = yaml.walk(src, lo, .Yaml_1_2, {}, &r, nil, record)
		if fault != nil {
			break
		}
		if strings.builder_len(r.out) == mark + 5 {
			resize(&r.out.buf, mark)
		} else {
			strings.write_string(&r.out, "-DOC\n")
		}
		if hi <= lo {
			break
		}
		lo = hi
	}
	strings.write_string(&r.out, "-STR\n")
	return strings.to_string(r.out), fault
}

// Normalizes the explicit markers the walk does not report.
@(private)
normalize :: proc(expected: string) -> string {
	e, _ := strings.replace_all(expected, "+DOC ---", "+DOC")
	e, _ = strings.replace_all(e, "-DOC ...", "-DOC")
	return e
}

@(private)
Case :: struct {
	name:   string,
	dir:    string,
	failed: string,
}

@(private)
cases :: proc(out: ^[dynamic]Case, dir, name: string) {
	infos, err := os.read_directory_by_path(dir, 0, context.allocator)
	if err != nil {
		return
	}
	has_input := false
	for fi in infos {
		if fi.name == "in.yaml" {
			has_input = true
		}
	}
	if has_input {
		append(out, Case{name = name, dir = dir})
		return
	}
	for fi in infos {
		if fi.type == .Directory {
			sub := fmt.aprintf("%s/%s", dir, fi.name)
			label := fi.name if name == "" else fmt.aprintf("%s/%s", name, fi.name)
			cases(out, sub, label)
		}
	}
}

@(private)
read_file :: proc(dir, name: string) -> (data: []u8, ok: bool) {
	err: os.Error
	data, err = os.read_entire_file_from_path(fmt.tprintf("%s/%s", dir, name), context.allocator)
	return data, err == nil
}

@(private)
check :: proc(c: Case) -> string {
	src, _ := read_file(c.dir, "in.yaml")
	_, is_error := read_file(c.dir, "error")
	text, fault := events(src)
	if is_error {
		if fault == nil {
			return "accepted"
		}
		if v := yaml.validate(src, .Yaml_1_2); v == nil {
			return "validate accepts"
		}
		return ""
	}
	if fault != nil {
		f := fault.?
		return fmt.tprintf("refused at %d: %v", f.at, f.kind)
	}
	if v := yaml.validate(src, .Yaml_1_2); v != nil {
		return "validate refuses"
	}
	want, _ := read_file(c.dir, "test.event")
	if normalize(string(want)) != text {
		return fmt.tprintf("events differ\n--- want\n%s--- got\n%s", normalize(string(want)), text)
	}
	return ""
}

@(test)
suite_cases :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	list: [dynamic]Case
	cases(&list, SUITE_DIR, "")
	testing.expect(t, len(list) > 300)
	failures := 0
	for &c in list {
		c.failed = check(c)
		if c.failed != "" {
			failures += 1
			fmt.eprintfln("%s: %s", c.name, c.failed)
		}
	}
	testing.expectf(t, failures == 0, "%d cases", failures)
}

@(test)
rules_cover_details :: proc(t: ^testing.T) {
	testing.expect_value(t, len(yaml.RULES.details), len(yaml.Detail))
}
