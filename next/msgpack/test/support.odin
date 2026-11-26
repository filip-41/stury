package msgpack_tests

import "core:fmt"
import "core:strings"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:testkit"

// Shared helpers for MessagePack tests: hex decoding and neutral document dumps.

// Parses hex string `text` (ignoring spaces) into bytes allocated from `context.temp_allocator`.
hex :: proc(text: string) -> []u8 {
	out := make([dynamic]u8, 0, len(text) / 2, context.temp_allocator)
	high := -1
	for c in transmute([]u8)text {
		v := -1
		switch c {
		case '0' ..= '9':
			v = int(c - '0')
		case 'a' ..= 'f':
			v = int(c - 'a' + 10)
		case 'A' ..= 'F':
			v = int(c - 'A' + 10)
		}
		if v < 0 {
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

// Decodes scalar node `at` of `doc` using a temporary buffer sized by `text_room`.
text_of :: proc(doc: ^tape.Document, at: tape.Node_Index) -> (string, bool) {
	buf := make([]u8, max(tape.text_room(doc, at), int(doc.nodes[at].n)), context.temp_allocator)
	return msgpack.node_text(doc, at, buf)
}

// Writes a neutral textual dump of node `i` and returns the node index after its subtree.
dump :: proc(b: ^strings.Builder, doc: ^tape.Document, i: tape.Node_Index) -> tape.Node_Index {
	for f in tape.facts_of(doc, i) {
		if f.kind == .Tag {
			if n, ok := msgpack.fact_number(doc, f); ok {
				fmt.sbprintf(b, "ext(%d):", i64(n.bits))
			}
		}
	}
	node := doc.nodes[i]
	switch node.kind {
	case .Null:
		strings.write_string(b, "null")
	case .False:
		strings.write_string(b, "false")
	case .True:
		strings.write_string(b, "true")
	case .Number:
		if node.role == .Key {
			s, _ := text_of(doc, i)
			fmt.sbprintf(b, "%q", s)
			break
		}
		n, _ := msgpack.node_number(doc, i)
		switch n.kind {
		case .Int:
			fmt.sbprintf(b, "i:%d", i64(n.bits))
		case .Uint:
			fmt.sbprintf(b, "u:%d", n.bits)
		case .Float:
			f := transmute(f64)n.bits
			if f != f {
				strings.write_string(b, "nan")
			} else {
				fmt.sbprintf(b, "f:%016x", n.bits)
			}
		case .Wide:
			strings.write_string(b, "wide")
		}
	case .Bytes:
		if node.role == .Key {
			s, _ := text_of(doc, i)
			fmt.sbprintf(b, "%q", s)
			break
		}
		strings.write_string(b, "h:")
		payload := msgpack.span_bytes(doc, node.lo, node.n)
		for c in payload {
			fmt.sbprintf(b, "%02x", c)
		}
	case .String, .Plain:
		s, _ := text_of(doc, i)
		fmt.sbprintf(b, "%q", s)
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

// Returns the neutral dump of `src` under `spec`, or the fault code on error.
dumped :: proc(src: []u8, spec := msgpack.Spec.Msgpack, opts := msgpack.Options{}) -> string {
	doc, err := msgpack.build(src, spec, opts, context.temp_allocator)
	if err != nil {
		return testkit.code_of(err)
	}
	b := strings.builder_make(context.temp_allocator)
	dump(&b, &doc, msgpack.ROOT)
	return strings.to_string(b)
}
