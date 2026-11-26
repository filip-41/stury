// Shared helpers for HTML5 tests: fault rule codes, built documents, navigation, attributes, markup shape, and walk token logging.
package html_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:html"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// The rule code of `err`, "" when nil.
code_of :: proc(err: tape.Error) -> string {
	switch e in err {
	case tape.Fault:
		return tape.fault_rule(e).code
	case tape.Exceeded:
		return fmt.tprintf("exceeded %v", e.kind)
	case tape.Bad_Option:
		return fmt.tprintf("bad option %s", e.option)
	case tape.Piece_Gap:
		return "piece gap"
	case runtime.Allocator_Error:
		return "memory"
	}
	return ""
}

// The fault `validate` returns for `text`, as `code@at`, or "" when accepted.
refusal :: proc(text: string, spec := html.Spec.Html, opts := html.Options{}) -> string {
	err := html.validate(transmute([]u8)text, spec, opts)
	if f, ok := err.(tape.Fault); ok {
		return fmt.tprintf("%s@%d", code_of(err), f.at)
	}
	return code_of(err)
}

// Builds an HTML5 document of `text` into the temporary allocator.
built :: proc(t: ^testing.T, text: string, spec := html.Spec.Html, opts := html.Options{}, loc := #caller_location) -> (doc: tape.Document, ok: bool) {
	d, err := html.build(transmute([]u8)text, spec, opts, context.temp_allocator)
	testing.expectf(t, err == nil, "%v", err, loc = loc)
	return d, err == nil
}

// Builds an HTML5 fragment document of `text` with explicit fragment options into the temporary allocator.
built_fragment :: proc(t: ^testing.T, text: string, fopts := html.Fragment_Options{}, opts := html.Options{}, loc := #caller_location) -> (doc: tape.Document, ok: bool) {
	d, err := html.build_fragment(transmute([]u8)text, fopts, opts, context.temp_allocator)
	testing.expectf(t, err == nil, "%v", err, loc = loc)
	return d, err == nil
}

reader :: proc(doc: ^tape.Document) -> tape.Reader {
	return {doc = doc}
}

token_text :: proc(doc: ^tape.Document, tok: tape.Token) -> string {
	buf := make([]u8, max(tape.text_room(doc, tok), int(tok.n)), context.temp_allocator)
	s, _ := tape.node_text(doc, tok, buf)
	return s
}

text_of :: proc(doc: ^tape.Document, at: tape.Node_Index) -> string {
	buf := make([]u8, max(tape.text_room(doc, at), int(doc.nodes[at].n)), context.temp_allocator)
	s, _ := html.node_text(doc, at, buf)
	return s
}

member_at :: proc(doc: ^tape.Document, path: []string, dups := tape.Duplicates.Default) -> (at: tape.Node_Index, found: bool) {
	at = html.ROOT
	for name in path {
		p: tape.Presence
		at, p = html.member(reader(doc), at, name, dups)
		if p != .Found {
			return html.NO_NODE, false
		}
	}
	return at, true
}

nth_member :: proc(doc: ^tape.Document, container: tape.Node_Index, name: string, index: int) -> (at: tape.Node_Index, found: bool) {
	c, p := html.named(reader(doc), container, name)
	if p != .Found {
		return html.NO_NODE, false
	}
	for i := 0; ; i += 1 {
		_, val, np := html.next_child(reader(doc), &c)
		if np != .Found {
			return html.NO_NODE, false
		}
		if i == index {
			return val, true
		}
	}
}

text_at :: proc(doc: ^tape.Document, path: ..string) -> (string, tape.Kind) {
	at, found := member_at(doc, path)
	if !found {
		return "", .Null
	}
	return text_of(doc, at), doc.nodes[at].kind
}

Attribute :: struct {
	name, value: string,
}

attributes_of :: proc(doc: ^tape.Document, at: tape.Node_Index) -> []Attribute {
	out := make([dynamic]Attribute, context.temp_allocator)
	for f in html.facts_of(doc, at) {
		if f.kind == .Attribute {
			name, value := doc.format.attribute(doc, f)
			append(&out, Attribute{token_text(doc, name), token_text(doc, value)})
		}
	}
	return out[:]
}

attribute_value :: proc(doc: ^tape.Document, at: tape.Node_Index, name: string) -> (value: string, found: bool) {
	for a in attributes_of(doc, at) {
		if a.name == name {
			return a.value, true
		}
	}
	return "", false
}

// Structural canonical shape string for markup documents (objects, keys, attributes, comments, instructions, doctype).
markup_shape :: proc(doc: ^tape.Document) -> string {
	b := strings.builder_make(context.temp_allocator)
	shape_node(&b, doc, tape.ROOT)
	return strings.to_string(b)
}

@(private = "file")
shape_node :: proc(b: ^strings.Builder, doc: ^tape.Document, at: tape.Node_Index) {
	facts := strings.builder_make(context.temp_allocator)
	for f in tape.facts_of(doc, at) {
		if f.kind == .Attribute {
			name, value := doc.format.attribute(doc, f)
			fmt.sbprintf(&facts, "@%s=%q ", token_text(doc, name), token_text(doc, value))
			continue
		}
		body, _ := write.comment_body(doc, f)
		#partial switch f.kind {
		case .Comment:
			fmt.sbprintf(&facts, "<!--%s--> ", string(body))
		case .Comment_Inline:
			fmt.sbprintf(&facts, "<!--%s-->^ ", string(body))
		case .Comment_Foot:
			fmt.sbprintf(&facts, "<!--%s-->$ ", string(body))
		case .Instruction, .Instruction_Foot:
			fmt.sbprintf(&facts, "<?%s?> ", string(body))
		case .Doctype:
			fmt.sbprintf(&facts, "<!%s> ", string(body))
		}
	}
	nd := doc.nodes[at]
	if nd.kind != .Object {
		if strings.builder_len(facts) > 0 {
			fmt.sbprintf(b, "(%s", strings.to_string(facts))
		}
		switch nd.kind {
		case .Null:
			strings.write_string(b, "null")
		case .True, .False, .Number:
			strings.write_string(b, text_of(doc, at))
		case .Bytes, .String, .Plain, .Array, .Object, .End:
			fmt.sbprintf(b, "%q", text_of(doc, at))
		}
		if strings.builder_len(facts) > 0 {
			strings.write_byte(b, ')')
		}
		return
	}
	fmt.sbprintf(b, "{{%s", strings.to_string(facts))
	r := reader(doc)
	c, _, _ := html.children(r, at, context.temp_allocator)
	first := true
	for {
		kn, vn, p := html.next_child(r, &c, .Group)
		if p != .Found {
			break
		}
		if !first {
			strings.write_string(b, ", ")
		}
		first = false
		fmt.sbprintf(b, "%q: ", text_of(doc, kn))
		shape_node(b, doc, vn)
	}
	strings.write_byte(b, '}')
}

shape :: proc(t: ^testing.T, text: string, spec := html.Spec.Fragment, opts := html.Options{}, loc := #caller_location) -> string {
	doc, ok := built(t, text, spec, opts, loc)
	if !ok {
		return ""
	}
	return markup_shape(&doc)
}

shape_fragment :: proc(t: ^testing.T, text: string, fopts := html.Fragment_Options{}, opts := html.Options{}, loc := #caller_location) -> string {
	doc, ok := built_fragment(t, text, fopts, opts, loc)
	if !ok {
		return ""
	}
	return markup_shape(&doc)
}

// A hook that logs an HTML walk's tokens in preorder.
Token_Log :: struct {
	text:     []u8,
	out:      strings.Builder,
	skip:     string,
	stop:     int,
	tokens:   int,
	last:     string,
	ctx:      runtime.Context,
	protocol: hook.Protocol(hook.Capabilities{.Skips}, hook.Unused, hook.Unused, hook.Unused),
}

log_token :: proc "contextless" (r: ^Token_Log, s: hook.Regs, tok: tape.Token) -> (hook.Regs, hook.Action) {
	context = r.ctx
	span := string(r.text[tok.lo:tok.lo + u64(tok.n)])
	name: string
	switch tok.role {
	case .Value:
		name = fmt.tprint(tok.kind)
	case .Key:
		name = "Key"
	case .Comment:
		name = "Comment"
	case .Comment_Inline:
		name = "Inline"
	case .Comment_Foot:
		name = "Foot"
	case .Instruction, .Instruction_Foot, .Doctype, .Directive, .Attribute, .Tag, .Anchor, .Alias:
		name = fmt.tprint(tok.role)
	}
	if tok.spelling & tape.SPELLING_DECODE != 0 && tok.role == .Value {
		name = fmt.tprintf("%s*", name)
	}
	if span != "" {
		fmt.sbprintf(&r.out, "%s:%s ", name, span)
	} else {
		fmt.sbprintf(&r.out, "%s ", name)
	}
	r.tokens += 1
	if r.stop != 0 && r.tokens >= r.stop {
		return s, .Stop
	}
	if tok.role == .Key {
		r.last = span
	}
	if tok.role == .Value && tok.kind >= .Array && tok.kind != .End && r.skip != "" && r.last == r.skip {
		r.last = ""
		return s, .Skip
	}
	return s, .Next
}

tokens_of :: proc(text: string, spec := html.Spec.Fragment, opts := html.Options{}, skip := "", stop := 0) -> (tokens: string, hi: u64, err: tape.Error) {
	r := Token_Log {
		text = transmute([]u8)text,
		skip = skip,
		stop = stop,
		ctx  = context,
	}
	r.out = strings.builder_make(context.temp_allocator)
	regs: hook.Regs
	switch spec {
	case .Html:
		hi, err, _ = html.walk(r.text, .Html, opts, &r, &regs, log_token, context.temp_allocator)
	case .Fragment:
		hi, err, _ = html.walk(r.text, .Fragment, opts, &r, &regs, log_token, context.temp_allocator)
	}
	return strings.trim_space(strings.to_string(r.out)), hi, err
}
