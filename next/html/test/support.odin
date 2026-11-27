// Shared helpers for HTML5 tests: built documents, markup shape, and walk token logging.
package html_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:html"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"

// The fault `validate` returns for `text`, as `code@at`, or "" when accepted.
refusal :: proc(text: string, spec := html.Spec.Html, opts := html.Options{}) -> string {
	err := html.validate(transmute([]u8)text, spec, opts)
	if f, ok := err.(tape.Fault); ok {
		return fmt.tprintf("%s@%d", testkit.code_of(err), f.at)
	}
	return testkit.code_of(err)
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
			fmt.sbprintf(&facts, "@%s=%q ", testkit.token_text(doc, name), testkit.token_text(doc, value))
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
			strings.write_string(b, testkit.scalar_text(doc, at))
		case .Bytes, .String, .Plain, .Array, .Object, .End:
			fmt.sbprintf(b, "%q", testkit.scalar_text(doc, at))
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
		fmt.sbprintf(b, "%q: ", testkit.scalar_text(doc, kn))
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

tokens_of :: proc(text: string, spec := html.Spec.Fragment, opts := html.Options{}, skip := "", stop := 0) -> (tokens: string, hi: u64, err: tape.Error) {
	r := testkit.Token_Log {
		text = transmute([]u8)text,
		skip = skip,
		stop = stop,
		mode = .Markup,
		ctx  = context,
	}
	r.out = strings.builder_make(context.temp_allocator)
	regs: hook.Regs
	switch spec {
	case .Html:
		hi, err, _ = html.walk(r.text, .Html, opts, &r, &regs, testkit.log_token, context.temp_allocator)
	case .Fragment:
		hi, err, _ = html.walk(r.text, .Fragment, opts, &r, &regs, testkit.log_token, context.temp_allocator)
	}
	return strings.trim_space(strings.to_string(r.out)), hi, err
}
