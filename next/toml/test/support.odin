// Helpers the TOML tests share: the vendored toml-test cases, a hook that logs a walk's tokens, a neutral dump of a
// document.
package toml_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

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

// A hook that writes each token it is given into `out`, skips the container whose key is `skip` and stops after
// token `stop` when it is not 0.
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
		if t.kind == .End {
			break
		}
		// The style bits of an inline container and of a dotted table.
		switch t.spelling & tape.CONTAINER_STYLE >> 13 {
		case 1:
			strings.write_string(&h.out, "~")
		case 2:
			strings.write_string(&h.out, ".")
		}
	case:
		fmt.sbprintf(&h.out, "%v:%s", t.kind, string(h.text[t.lo:][:t.n]))
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

// The tokens a walk of `text` gives, written one after another, where the walk ended and its error.
@(private)
tokens_of :: proc(text: string, spec := toml.Spec.Toml_1_1, skip := "", stop := 0, opts := toml.Options{}) -> (tokens: string, hi: u64, err: tape.Error) {
	r := Token_Log {
		text = transmute([]u8)text,
		skip = skip,
		stop = stop,
	}
	strings.builder_init(&r.out, context.temp_allocator)
	regs: hook.Regs
	switch spec {
	case .Toml_1_0:
		hi, err, _ = toml.walk(r.text, .Toml_1_0, opts, &r, &regs, log_token)
	case .Toml_1_1:
		hi, err, _ = toml.walk(r.text, .Toml_1_1, opts, &r, &regs, log_token)
	}
	return strings.to_string(r.out), hi, err
}

// Whether `err` is nil, reporting it at the caller when it is not.
@(private)
expect_nil :: proc(t: ^testing.T, err: tape.Error, loc := #caller_location) -> bool {
	return testing.expectf(t, err == nil, "error %v", err, loc = loc)
}

// Writes node `i` of `doc` and returns the node after it: strings and keys quoted, numbers as their value, a
// date-time as `dt:` and its text.
@(private)
dump :: proc(b: ^strings.Builder, doc: ^tape.Document, i: tape.Node_Index) -> tape.Node_Index {
	node := doc.nodes[i]
	switch node.kind {
	case .Null:
		strings.write_string(b, "null")
	case .False:
		strings.write_string(b, "false")
	case .True:
		strings.write_string(b, "true")
	case .Number:
		n, _ := toml.node_number(doc, i)
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
	case .Bytes, .String, .Plain:
		buf := make([]u8, max(toml.text_room(doc, i), int(node.n)), context.temp_allocator)
		s, _ := toml.node_text(doc, i, buf)
		if node.role == .Value && node.spelling & tape.SPELLING_QUOTED == 0 {
			fmt.sbprintf(b, "dt:%s", s)
		} else {
			fmt.sbprintf(b, "%q", s)
		}
	case .Array, .Object:
		strings.write_byte(b, '[' if node.kind == .Array else '{')
		end := i + tape.Node_Index(node.n)
		k := i + 1
		for first := true; k < end; first = false {
			if !first {
				strings.write_byte(b, ',')
			}
			if node.kind == .Object {
				k = dump(b, doc, k)
				strings.write_byte(b, ':')
			}
			k = dump(b, doc, k)
		}
		strings.write_byte(b, ']' if node.kind == .Array else '}')
		return end
	case .End:
	}
	return i + 1
}

// The dump of the whole document of `text` read as `spec`, or its error's code.
@(private)
dumped :: proc(text: string, spec := toml.Spec.Toml_1_1) -> string {
	doc, err := toml.build(transmute([]u8)text, spec, {}, context.temp_allocator)
	if err != nil {
		return testkit.code_of(err)
	}
	b := strings.builder_make(context.temp_allocator)
	dump(&b, &doc, toml.ROOT)
	return strings.to_string(b)
}
