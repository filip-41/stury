// Helpers the XML tests share: a fault's rule code, a built document, readers by name, attributes and a log of a walk's
// tokens.
package xml_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:xml"

// The rule code of the fault in `err`, "" for none and the error's arm for another error.
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

// The fault `validate` returns for `text`, as `code@at`, or "" for a text it accepts.
refusal :: proc(text: string, opts := xml.Options{}) -> string {
	err := xml.validate(transmute([]u8)text, .Xml, opts)
	if f, ok := err.(tape.Fault); ok {
		return fmt.tprintf("%s@%d", code_of(err), f.at)
	}
	return code_of(err)
}

// The document of `text`, in the temporary allocator.
built :: proc(t: ^testing.T, text: string, opts := xml.Options{}, loc := #caller_location) -> (doc: tape.Document, ok: bool) {
	d, err := xml.build(transmute([]u8)text, .Xml, opts, context.temp_allocator)
	testing.expectf(t, err == nil, "%v", err, loc = loc)
	return d, err == nil
}

// The reader over `doc`, which holds no index.
reader :: proc(doc: ^tape.Document) -> tape.Reader {
	return {doc = doc}
}

// The text of node `at` of `doc`, read with a buffer `text_room` sizes.
text_of :: proc(doc: ^tape.Document, at: tape.Node_Index) -> string {
	buf := make([]u8, max(tape.text_room(doc, at), int(doc.nodes[at].n)), context.temp_allocator)
	s, _ := xml.node_text(doc, at, buf)
	return s
}

// The node the names of `path` reach from the root, each by `dups`.
member_at :: proc(doc: ^tape.Document, path: []string, dups := tape.Duplicates.Default) -> (at: tape.Node_Index, found: bool) {
	at = xml.ROOT
	for name in path {
		p: tape.Presence
		at, p = xml.member(reader(doc), at, name, dups)
		if p != .Found {
			return xml.NO_NODE, false
		}
	}
	return at, true
}

// The text and kind of the node `path` reaches, a null with no text when a name is missing.
text_at :: proc(doc: ^tape.Document, path: ..string) -> (string, tape.Kind) {
	at, found := member_at(doc, path)
	if !found {
		return "", .Null
	}
	return text_of(doc, at), doc.nodes[at].kind
}

// The attributes of the element whose value is node `at`, as their names and values read as attribute values, in the
// temporary allocator, and the decoded value of the one written `name` among them.
Attribute :: struct {
	name, value: string,
}

attributes_of :: proc(doc: ^tape.Document, at: tape.Node_Index) -> []Attribute {
	out := make([dynamic]Attribute, context.temp_allocator)
	for f in doc.facts {
		if f.node == at && f.kind == .Attribute {
			name, value := xml.attribute(doc, f)
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

// The text of token `t` of `doc`'s source.
token_text :: proc(doc: ^tape.Document, t: tape.Token) -> string {
	buf := make([]u8, max(tape.text_room(doc.format, doc.src, t, doc.allocator), int(t.n)), context.temp_allocator)
	s, _ := tape.node_text(doc.format, doc.src, t, buf, doc.allocator)
	return s
}

// A hook that logs a walk's tokens as one line: each token as its kind for a value, `Key`, `Comment`, `Inline`,
// `Foot` or its role, a `*` after a value whose text needs decoding, and `:` and its span when it has one. It answers
// `Skip` at the container of the member whose key is spelled `skip` and `Stop` after `stop` tokens, 0 for never.
Token_Log :: struct {
	text:     []u8,
	out:      strings.Builder,
	skip:     string,
	stop:     int,
	tokens:   int,
	last:     string, // the key before the token
	ctx:      runtime.Context,
	protocol: hook.Protocol(hook.Capabilities{.Skips}, hook.Unused, hook.Unused, hook.Unused),
}

log_token :: proc "contextless" (r: ^Token_Log, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	context = r.ctx
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
	case .Instruction, .Doctype, .Directive, .Attribute, .Tag, .Anchor, .Alias:
		name = fmt.tprint(t.role)
	}
	if t.spelling & tape.SPELLING_DECODE != 0 && t.role == .Value {
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
	if t.role == .Key {
		r.last = text
	}
	if t.role == .Value && t.kind >= .Array && t.kind != .End && r.skip != "" && r.last == r.skip {
		r.last = ""
		return s, .Skip
	}
	return s, .Next
}

// The tokens of the walk of `text` as `Token_Log` writes them, where the walk ended and its error, in the temporary
// allocator.
tokens_of :: proc(text: string, opts := xml.Options{}, skip := "", stop := 0) -> (tokens: string, hi: u64, err: tape.Error) {
	r := Token_Log {
		text = transmute([]u8)text,
		skip = skip,
		stop = stop,
		ctx  = context,
	}
	r.out = strings.builder_make(context.temp_allocator)
	regs: hook.Regs
	hi, err, _ = xml.walk(r.text, .Xml, opts, &r, &regs, log_token, context.temp_allocator)
	return strings.trim_space(strings.to_string(r.out)), hi, err
}
