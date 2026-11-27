// Shared markup navigation, attribute reading, and walk token-logging helpers for format test suites.
package testkit

import "base:runtime"
import "core:fmt"
import "core:strings"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// An element's decoded attribute name and value.
Attribute :: struct {
	name, value: string,
}

// Decoded attributes of the element at node `at` of `doc`, in the temporary allocator.
attributes_of :: proc(doc: ^tape.Document, at: tape.Node_Index) -> []Attribute {
	out := make([dynamic]Attribute, context.temp_allocator)
	for f in tape.facts_of(doc, at) {
		if f.kind == .Attribute {
			name, value := doc.format.attribute(doc, f)
			append(&out, Attribute{token_text(doc, name), token_text(doc, value)})
		}
	}
	return out[:]
}

// Decoded value of the attribute named `name` on node `at` of `doc`.
attribute_value :: proc(doc: ^tape.Document, at: tape.Node_Index, name: string) -> (value: string, found: bool) {
	for a in attributes_of(doc, at) {
		if a.name == name {
			return a.value, true
		}
	}
	return "", false
}

// The node reached from the root by `path` of member names under `dups`.
member_at :: proc(doc: ^tape.Document, path: []string, dups := tape.Duplicates.Default) -> (at: tape.Node_Index, found: bool) {
	at = tape.ROOT
	r := tape.Reader{doc = doc}
	for name in path {
		p: tape.Presence
		at, p = tape.member(r, at, name, dups)
		if p != .Found {
			return tape.NO_NODE, false
		}
	}
	return at, true
}

// The decoded text and kind of the node `path` reaches, or `("", .Null)` when missing.
text_at :: proc(doc: ^tape.Document, path: ..string) -> (string, tape.Kind) {
	at, found := member_at(doc, path)
	if !found {
		return "", .Null
	}
	return scalar_text(doc, at), doc.nodes[at].kind
}

// Formatting dialect for `Token_Log`.
Token_Log_Mode :: enum u8 {
	Markup, // XML / HTML: marks `.Value` tokens with `SPELLING_DECODE` using `*`, omits empty spans.
	Toml,   // TOML: marks inline (`~`) and dotted (`.`) container styles, prints `Role:span` / `Kind:span`.
	Yaml,   // YAML: marks scalars with `SPELLING_QUOTED` using `*`, prints `Role:span` / `Kind*:span`.
}

// A hook that logs a walk's tokens as one space-separated line, skipping the container whose key is `skip` and
// stopping after `stop` tokens (0 for never).
Token_Log :: struct {
	text:     []u8,
	out:      strings.Builder,
	skip:     string,
	stop:     int,
	tokens:   int,
	last:     string,
	skipping: bool,
	mode:     Token_Log_Mode,
	ctx:      runtime.Context,
	protocol: hook.Protocol(hook.Capabilities{.Skips}, hook.Unused, hook.Unused, hook.Unused),
}

@(private = "file", rodata)
TOKEN_LOG_ROLE_NAMES := [tape.Role]string{
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

log_token :: proc "contextless" (h: ^Token_Log, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	context = h.ctx if h.ctx.allocator.procedure != nil else runtime.default_context()
	span := string(h.text[t.lo:][:t.n])
	if h.mode == .Markup {
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
		case .Instruction, .Instruction_Foot, .Doctype, .Directive, .Attribute, .Tag, .Anchor, .Alias:
			name = fmt.tprint(t.role)
		}
		if t.spelling & tape.SPELLING_DECODE != 0 && t.role == .Value {
			name = fmt.tprintf("%s*", name)
		}
		if span != "" {
			fmt.sbprintf(&h.out, "%s:%s ", name, span)
		} else {
			fmt.sbprintf(&h.out, "%s ", name)
		}
		h.tokens += 1
		if h.stop != 0 && h.tokens >= h.stop {
			return s, .Stop
		}
		if t.role == .Key {
			h.last = span
		}
		if t.role == .Value && t.kind >= .Array && t.kind != .End && h.skip != "" && h.last == h.skip {
			h.last = ""
			return s, .Skip
		}
		return s, .Next
	}
	if h.out.buf != nil && len(h.out.buf) > 0 {
		strings.write_byte(&h.out, ' ')
	}
	h.tokens += 1
	switch {
	case t.role != .Value:
		fmt.sbprintf(&h.out, "%s%s", TOKEN_LOG_ROLE_NAMES[t.role], span)
	case t.kind > .Plain:
		fmt.sbprintf(&h.out, "%v", t.kind)
		if h.mode == .Toml && t.kind != .End {
			switch t.spelling & tape.CONTAINER_STYLE >> 13 {
			case 1:
				strings.write_string(&h.out, "~")
			case 2:
				strings.write_string(&h.out, ".")
			}
		}
	case:
		star := "*" if h.mode == .Yaml && t.spelling & tape.SPELLING_QUOTED != 0 else ""
		fmt.sbprintf(&h.out, "%v%s:%s", t.kind, star, span)
	}
	a := hook.Action.Next
	if h.skipping && t.kind > .Plain && t.kind != .End {
		h.skipping, a = false, .Skip
	}
	if t.role == .Key && span == h.skip && h.skip != "" {
		h.skipping = true
	}
	if h.stop != 0 && h.tokens == h.stop {
		a = .Stop
	}
	return s, a
}
