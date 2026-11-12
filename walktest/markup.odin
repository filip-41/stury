package walktest

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import core "../core"

// The reads the markup formats' tests share over a built document: a node's text, a member reached by names and an
// element's attributes.

// The decoded text of string or plain node `i`, in the temp allocator.
node_text :: proc(t: ^testing.T, doc: ^core.Document, i: core.Node_Index, loc := #caller_location) -> string {
	buf := make([]u8, core.text_room(doc, i), context.temp_allocator)
	s, ok := core.text(doc, i, buf)
	testing.expect(t, ok, loc = loc)
	return s
}

// The node `path`, a path of names from the root, reaches, and false when a name is missing.
member_at :: proc(t: ^testing.T, doc: ^core.Document, path: string, loc := #caller_location) -> (node: core.Node_Index, found: bool) {
	p, perr := core.parse_path(path)
	testing.expect(t, perr == nil, loc = loc)
	defer core.path_destroy(&p)
	node = core.ROOT
	for step in p.steps {
		name, is_name := step.(core.Name)
		testing.expect(t, is_name, loc = loc)
		node = core.member(doc, node, string(name)) or_return
	}
	return node, true
}

// The text and the kind of the node `path` reaches, `.Null` with no text when a name is missing.
text_at :: proc(t: ^testing.T, doc: ^core.Document, path: string, loc := #caller_location) -> (string, core.Kind) {
	node, found := member_at(t, doc, path, loc)
	if !found {
		return "", .Null
	}
	return node_text(t, doc, node, loc), core.kind(doc, node)
}

// The next attribute of `it` as its name and its decoded value, in the temp allocator.
attribute_texts :: proc(it: ^core.Attribute_Iter) -> (name, value: string, found: bool) {
	n, v := core.attribute_next(it) or_return
	doc := it.doc
	name, _ = core.token_text(doc.readers, &doc.view, n, context.temp_allocator)
	value, _ = core.token_text(doc.readers, &doc.view, v, context.temp_allocator)
	return name, value, true
}

// The fault arm of `err`, and whether `err` is one.
fault_in :: proc "contextless" (err: core.Error) -> (core.Fault, bool) {
	f, bad := err.(core.Fault)
	return f, bad
}

// A fault's rule as `format.code`, or the kind's code for a fault with no detail.
rule_code :: proc(f: core.Fault) -> string {
	if f.detail == 0 {
		return core.rule_of(f).code
	}
	return fmt.tprintf("%s.%s", f.rules.format, core.rule_of(f).code)
}

// A hook's log of a markup walk's tokens as one line: each token as its kind for a value, `Key`, `Comment`, `Inline`,
// `Foot` or its role, a `*` after a value whose text needs decoding, and `:` and its span when it has one. The hook
// skips the value of the key spelled `skip` and stops after `stop` tokens, 0 for never.
Token_Log :: struct {
	text:   []u8,
	out:    strings.Builder,
	skip:   string,
	stop:   int,
	tokens: int,
}

log_token :: proc "contextless" (r: ^Token_Log, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = runtime.default_context()
	text := string(r.text[t.lo:t.lo + u64(t.n)])
	name: string
	switch t.role {
	case .Value:
		name = fmt.tprint(t.kind)
	case .Key:
		name = "Key"
	case .Comment:
		name = "Comment"
	case .Comment_Inline:
		name = "Inline"
	case .Comment_Foot:
		name = "Foot"
	case .Instruction, .Doctype, .Attribute, .Tag, .Anchor, .Alias, .Partial:
		name = fmt.tprint(t.role)
	}
	if t.spelling & core.SPELLING_DECODE != 0 && t.role == .Value {
		name = fmt.tprintf("%s*", name)
	}
	if text != "" {
		fmt.sbprintf(&r.out, "%s:%s ", name, text)
	} else {
		fmt.sbprintf(&r.out, "%s ", name)
	}
	r.tokens += 1
	if r.stop != 0 && r.tokens >= r.stop {
		return s, .Stop
	}
	if t.role == .Key && r.skip != "" && text == r.skip {
		return s, .Skip
	}
	return s, .Next
}

// The log a walk wrote, without its last space.
log_line :: proc(r: ^Token_Log) -> string {
	return strings.trim_space(strings.to_string(r.out))
}
