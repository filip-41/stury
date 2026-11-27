package cbor_tests

import "core:fmt"
import "core:strings"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"

// Helpers the CBOR tests share: a neutral dump of a document.

// The text of node `at` of `doc`, read with a buffer `text_room` sizes.
text_of :: proc(doc: ^tape.Document, at: tape.Node_Index) -> (string, bool) {
	buf := make([]u8, max(tape.text_room(doc, at), int(doc.nodes[at].n)), context.temp_allocator)
	return cbor.node_text(doc, at, buf)
}

// Writes node `i` of `doc` and returns the node after it: integers as `i:<value>`, floats as `f:<bits>` or `nan`,
// strings quoted, byte strings as `h:<hex>` of their payload, a simple value as `simple(n)`, a key as its
// text, and a value past every 64-bit one as `wide`.
dump :: proc(b: ^strings.Builder, doc: ^tape.Document, i: tape.Node_Index) -> tape.Node_Index {
	node := doc.nodes[i]
	switch node.kind {
	case .Null:
		if s := node.spelling; s != 0 {
			fmt.sbprintf(b, "simple(%d)", int(s >> 1) - 1)
		} else {
			strings.write_string(b, "null")
		}
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
		n, _ := cbor.node_number(doc, i)
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
			strings.write_string(b, "wide")
		}
	case .Bytes:
		if node.role == .Key {
			s, _ := text_of(doc, i)
			fmt.sbprintf(b, "%q", s)
			break
		}
		strings.write_string(b, "h:")
		payload := cbor.span_bytes(doc, node.lo, node.n)
		if node.spelling & tape.SPELLING_DECODE != 0 {
			s, _ := doc.format.decode(doc.src, node, make([]u8, node.n, context.temp_allocator), nil)
			payload = transmute([]u8)s
		}
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

// The dump of the whole document of `src` read as `spec`, or its error's code.
dumped :: proc(src: []u8, spec := cbor.Spec.Cbor, opts := cbor.Options{}) -> string {
	doc, err := cbor.build(src, spec, opts, context.temp_allocator)
	if err != nil {
		return testkit.code_of(err)
	}
	b := strings.builder_make(context.temp_allocator)
	dump(&b, &doc, cbor.ROOT)
	return strings.to_string(b)
}
