// The yaml-test-suite cases against the walk: the tokens of each `in.yaml`, printed as the suite's event stream, must
// equal its `test.event`, and a case with an `error` marker must fault in both `walk` and `validate`.
package yaml_tests

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:yaml"

@(private = "file")
Frame :: struct {
	seq:     bool,
	bracket: bool,
	mark:    int,
}

@(private = "file")
Printer :: struct {
	src:      []u8,
	out:      strings.Builder,
	handles:  map[string]string,
	stack:    [dynamic]Frame,
	alias:    bool,
	skip:     int,
	props:    [2]string,
	protocol: hook.Protocol(hook.NO_HOOKS_CAPS, hook.Unused, hook.Unused, hook.Unused),
}

@(private = "file")
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

@(private = "file")
unpercent :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
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

@(private = "file")
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

@(private = "file")
properties :: proc(pr: ^Printer) {
	if pr.props[0] != "" {
		fmt.sbprintf(&pr.out, " &%s", pr.props[0])
	}
	if pr.props[1] != "" {
		fmt.sbprintf(&pr.out, " %s", resolve_tag(pr, pr.props[1]))
	}
	pr.props = {}
}

@(private = "file")
decode_scalar_event :: proc(src: []u8, t: tape.Token, buf: []u8) -> (string, bool) {
	f := yaml.as(.Yaml_1_2)
	if t.kind == .Number {
		if t.spelling & tape.NUMBER_KIND == 0 || !tape.text_decodes(t) {
			return string(src[t.lo:][:t.n]), true
		}
		// Decode quoted/block/raw number token back to its unescaped text (not canonical key text!).
		tmp_t := t
		tmp_t.kind = .String
		tmp_t.spelling |= tape.SPELLING_DECODE
		if s, ok := f.decode(src, tmp_t, buf, nil); ok {
			return s, true
		}
		return string(src[t.lo:][:t.n]), true
	}
	if t.kind != .String && t.kind != .Plain && t.kind != .Bytes {
		return string(src[t.lo:][:t.n]), true
	}
	if t.kind == .Bytes {
		tmp_t := t
		tmp_t.kind = .String
		tmp_t.role = .Value
		return f.decode(src, tmp_t, buf, nil)
	}
	if t.spelling & tape.SPELLING_DECODE == 0 {
		return string(src[t.lo:][:t.n]), true
	}
	return f.decode(src, t, buf, nil)
}

@(private = "file")
record :: proc "contextless" (r: ^Printer, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	context = runtime.default_context()
	text := string(r.src[t.lo:t.lo + u64(t.n)])
	#partial switch t.role {
	case .Comment, .Comment_Inline, .Comment_Foot, .Directive:
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
		properties(r)
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
		properties(r)
		style := ":"
		head, _ := yaml.as(.Yaml_1_2).bounds(r.src, t)
		if head != 0 {
			if r.src[t.lo - 1] == '\'' {
				style = "'"
			} else if r.src[t.lo - 1] == '"' {
				style = "\""
			}
		} else if t.n > 0 {
			switch r.src[t.lo] {
			case '|': style = "|"
			case '>': style = ">"
			}
		}
		buf := make([]u8, 3 * int(t.n) + 16, context.temp_allocator)
		decoded, ok := decode_scalar_event(r.src, t, buf)
		strings.write_byte(&r.out, ' ')
		strings.write_string(&r.out, style)
		escaped(&r.out, decoded if ok else "<overflow>")
		strings.write_byte(&r.out, '\n')
	}
	return s, .Next
}

@(private = "file")
read_handles :: proc(pr: ^Printer, lo: u64) {
	clear(&pr.handles)
	rest := string(pr.src[lo:])
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "---") || strings.has_prefix(line, "...") {
			break
		}
		if strings.has_prefix(line, "%TAG ") {
			f := strings.fields(line, context.temp_allocator)
			if len(f) >= 3 {
				pr.handles[f[1]] = f[2]
			}
		}
	}
}

@(private = "file")
events :: proc(src: []u8) -> (text: string, err: tape.Error) {
	r := Printer{src = src}
	r.out.buf.allocator = context.temp_allocator
	r.handles.allocator = context.temp_allocator
	r.stack.allocator = context.temp_allocator
	strings.write_string(&r.out, "+STR\n")
	lo := u64(0)
	for lo < u64(len(src)) {
		read_handles(&r, lo)
		mark := strings.builder_len(r.out)
		strings.write_string(&r.out, "+DOC\n")
		regs: hook.Regs
		hi: u64
		hi, err, _ = yaml.walk_next(src, lo, .Yaml_1_2, {}, &r, &regs, record)
		if err != nil {
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
	return strings.to_string(r.out), err
}

@(private = "file")
normalize_events :: proc(expected: string) -> string {
	e, _ := strings.replace_all(expected, "+DOC ---", "+DOC", context.temp_allocator)
	e, _ = strings.replace_all(e, "-DOC ...", "-DOC", context.temp_allocator)
	return e
}

@(private = "file")
check_suite_events :: proc(c: Suite_Case) -> string {
	src, _ := read_suite_file(c.dir, "in.yaml", context.temp_allocator)
	_, is_error := read_suite_file(c.dir, "error", context.temp_allocator)
	text, err := events(src)
	if is_error {
		if err == nil {
			return "accepted"
		}
		if v := yaml.validate(src, .Yaml_1_2); v == nil {
			return "validate accepts"
		}
		return ""
	}
	if err != nil {
		return fmt.tprintf("refused: %v", err)
	}
	if v := yaml.validate(src, .Yaml_1_2); v != nil {
		return "validate refuses"
	}
	want, _ := read_suite_file(c.dir, "test.event", context.temp_allocator)
	if normalize_events(string(want)) != text {
		return fmt.tprintf("events differ\n--- want\n%s--- got\n%s", normalize_events(string(want)), text)
	}
	return ""
}

@(test)
suite_cases_match_events :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	list := load_suite_cases(context.allocator)
	defer free_suite_cases(list, context.allocator)
	failures, total := 0, 0
	for c in list {
		total += 1
		if failed := check_suite_events(c); failed != "" {
			failures += 1
			if failures <= 20 {
				fmt.eprintfln("%s: %s", c.name, failed)
			}
		}
	}
	testing.expect(t, total > 340)
	testing.expectf(t, failures == 0, "%d/%d suite event failures", failures, total)
}

@(private = "file")
Bad_Action_Hook :: struct {
	action:   hook.Action,
	protocol: hook.Protocol(hook.Capabilities{}, hook.Unused, hook.Unused, hook.Unused),
}

@(private = "file")
bad_action_on :: proc "contextless" (h: ^Bad_Action_Hook, s: hook.Regs, _: tape.Token) -> (hook.Regs, hook.Action) {
	return s, h.action
}

@(test)
hook_errors_oom_and_budget_steps_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// 1. Identical `Budget.steps` fault offset across `validate`, `build`, `find`, and `scan` (even across !LAX/LAX split).
	src := transmute([]u8)string("a: [1, [2, 3]]\nb: {c: 4}\n")
	for steps in ([?]u64{1, 2, 3}) {
		opts := yaml.Options{budget = {steps = steps}}
		verr := yaml.validate(src, .Yaml_1_2, opts)
		vf, vok := verr.(yaml.Exceeded)
		testing.expect(t, vok && vf.kind == .Steps)

		bdoc, berr := yaml.build(src, .Yaml_1_2, opts)
		yaml.destroy(&bdoc)
		bf, bok := berr.(yaml.Exceeded)
		testing.expectf(t, bok && bf.kind == vf.kind && bf.at == vf.at, "steps=%d build=%v validate=%v", steps, berr, verr)

		_, ferr := yaml.find(src, {yaml.Name("missing")}, .Yaml_1_2, {}, opts)
		ff, fok := ferr.(yaml.Exceeded)
		testing.expectf(t, fok && ff.kind == vf.kind && ff.at == vf.at, "steps=%d find=%v validate=%v", steps, ferr, verr)

		d, _ := yaml.demand_of({{yaml.Name("b")}})
		defer yaml.destroy(&d)
		sdoc, serr := yaml.scan(src, &d, .Yaml_1_2, {}, opts)
		yaml.destroy(&sdoc)
		sf, sok := serr.(yaml.Exceeded)
		testing.expectf(t, sok && sf.kind == vf.kind && sf.at == vf.at, "steps=%d scan=%v validate=%v", steps, serr, verr)
	}
	testing.expect_value(t, yaml.validate(src, .Yaml_1_2, {budget = {steps = 4}}), nil)

	// 2. Unsupported hook actions return `Bad_Option{"action"}` cleanly.
	for bad_act in ([?]hook.Action{.Skip, .Rest, .Keep, .Keep_Stubs}) {
		bh := Bad_Action_Hook{action = bad_act}
		regs: hook.Regs
		_, werr, _ := yaml.walk(src, .Yaml_1_2, {}, &bh, &regs, bad_action_on)
		testing.expectf(t, werr == yaml.Error(yaml.Bad_Option{"action"}), "walk bad action %v -> %v", bad_act, werr)
	}

	// 3. Tight `Budget.memory` & failing-allocator sweep on `yaml.build` and `yaml.scan` (covering `rooms_grow` in both outer & inner hooks!).
	sweep_src := transmute([]u8)string("items:\n  - {k: 1, v: [a, b, c]}\n  - &anc {k: 2, v: [d, e]}\n  - *anc\n")
	Sweep_Data :: struct {
		src: []u8,
	}
	sweep_build := proc(data: rawptr, a: runtime.Allocator) {
		sd := (^Sweep_Data)(data)
		doc, err := yaml.build(sd.src, .Yaml_Merge, {}, a)
		if err == nil {
			yaml.destroy(&doc)
		}
	}
	sweep_scan := proc(data: rawptr, a: runtime.Allocator) {
		sd := (^Sweep_Data)(data)
		d, derr := yaml.demand_of({{yaml.Name("items"), yaml.All{}}}, allocator = a)
		if derr != nil {
			return
		}
		defer yaml.destroy(&d)
		doc, err := yaml.scan(sd.src, &d, .Yaml_Merge, {}, {}, a)
		if err == nil {
			yaml.destroy(&doc)
		}
	}
	sd := Sweep_Data{sweep_src}
	sb := testkit.sweep_failures(sweep_build, &sd)
	ss := testkit.sweep_failures(sweep_scan, &sd)
	testing.expectf(t, sb.bad == 0 && sb.refused >= 1, "build OOM sweep: %v", sb)
	testing.expectf(t, ss.bad == 0 && ss.refused >= 1, "scan OOM sweep: %v", ss)
}
