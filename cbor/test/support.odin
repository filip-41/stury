// Helpers the CBOR tests share: hex input, a neutral dump of a document, and a recorder for the tokens of a walk.
package cbor_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import core "../../core"

// The bytes of hex text, ignoring spaces, in the temporary allocator.
@(private)
hex :: proc(text: string) -> []u8 {
	out := make([dynamic]u8, 0, len(text) / 2, context.temp_allocator)
	high := -1
	for c in transmute([]u8)text {
		v: int
		switch c {
		case '0' ..= '9':
			v = int(c - '0')
		case 'a' ..= 'f':
			v = int(c - 'a' + 10)
		case 'A' ..= 'F':
			v = int(c - 'A' + 10)
		case:
			continue
		}
		if high < 0 {
			high = v
		} else {
			append(&out, u8(high << 4 | v))
			high = -1
		}
	}
	return out[:]
}

// Writes node `i` of `doc` as text both the document and the stock decoder's value can be written to: integers as
// `i:<value>`, floats as `f:<bits>` or `nan`, strings quoted, byte strings as `h:<hex>`, a simple value as `simple(n)`,
// and a key as its text.
@(private)
dump :: proc(b: ^strings.Builder, doc: ^core.Document, i: core.Node_Index) {
	switch core.kind(doc, i) {
	case .Null:
		if s := doc.nodes[i].spelling; s != 0 {
			fmt.sbprintf(b, "simple(%d)", int(s >> 1) - 1)
		} else {
			strings.write_string(b, "null")
		}
	case .False:
		strings.write_string(b, "false")
	case .True:
		strings.write_string(b, "true")
	case .Number:
		n, _ := core.number(doc, i)
		switch n.kind {
		case .Int:
			fmt.sbprintf(b, "i:%d", i64(n.bits))
		case .Uint:
			fmt.sbprintf(b, "i:%d", n.bits)
		case .Float:
			f := transmute(f64)n.bits
			if f != f {
				strings.write_string(b, "nan")
			} else {
				fmt.sbprintf(b, "f:%016x", n.bits)
			}
		case .Wide:
			buf: [4096]u8
			s, _ := core.doc_number_text(doc, i, buf[:])
			fmt.sbprintf(b, "i:%s", s)
		}
	case .Bytes:
		buf: [4096]u8
		p, _ := core.doc_bytes(doc, i, buf[:])
		hex_text(b, p)
	case .String, .Plain:
		buf: [4096]u8
		s, _ := core.text(doc, i, buf[:])
		fmt.sbprintf(b, "%q", s)
	case .Array:
		strings.write_byte(b, '[')
		it := core.children(doc, i)
		first := true
		for v in core.child_next(&it) {
			if !first {
				strings.write_byte(b, ',')
			}
			first = false
			dump(b, doc, v)
		}
		strings.write_byte(b, ']')
	case .Object:
		strings.write_byte(b, '{')
		it := core.pairs(doc, i)
		first := true
		for k, v in core.pair_next(&it) {
			if !first {
				strings.write_byte(b, ',')
			}
			first = false
			if core.kind(doc, k) == .Bytes {
				buf: [4096]u8
				p, _ := core.doc_bytes(doc, k, buf[:])
				hex_text(b, p)
			} else {
				buf: [4096]u8
				s, _ := core.text(doc, k, buf[:])
				fmt.sbprintf(b, "%q", s)
			}
			strings.write_byte(b, ':')
			dump(b, doc, v)
		}
		strings.write_byte(b, '}')
	case .End:
	}
}

// The tokens a walk passed, as `Kind` or `Role` names, with what a hook does at a token.
@(private)
Recorder :: struct {
	out:    strings.Builder,
	skip:   core.Kind, // the kind of token the hook skips, `.End` for none
	skip_key: bool, // skip the value of the first key
	stop:   int, // the number of tokens after which the hook stops, 0 for never
	tokens: int,
}

@(private)
record :: proc "contextless" (r: ^Recorder, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = runtime.default_context()
	name: string
	switch t.role {
	case .Value:
		name = fmt.tprint(t.kind)
	case .Key:
		name = "Key"
	case .Tag:
		name = "Tag"
	case .Comment, .Comment_Inline, .Comment_Foot, .Anchor, .Alias, .Instruction, .Doctype, .Attribute, .Partial:
		name = "Other"
	}
	fmt.sbprintf(&r.out, "%s ", name)
	r.tokens += 1
	if r.stop != 0 && r.tokens >= r.stop {
		return s, .Stop
	}
	if t.role == .Value && t.kind == r.skip || t.role == .Key && r.skip_key {
		return s, .Skip
	}
	return s, .Next
}

@(private)
hex_text :: proc(b: ^strings.Builder, p: []u8) {
	strings.write_string(b, "h:")
	for c in p {
		fmt.sbprintf(b, "%02x", c)
	}
}
