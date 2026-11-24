// The law every writer keeps: a text it writes reads back as the value it wrote, through the readers, with the facts
// its format holds.
package testkit

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// How values compare across a write.
Same :: struct {
	// Numbers compare by their value, kind and bits, where a write may respell them. Without it their bytes compare.
	number_values: bool,
	// Scalars of other kinds compare as their text: a target with no booleans or numbers reads them back as strings.
	scalars_as_text: bool,
	// The fact kinds that read back: compared as their kinds and bodies on each value, in order.
	facts: tape.Facts,
}

// Whether value `a` of `x` reads as value `b` of `y`: the same kinds, the same texts of strings and keys, the same
// numbers, the same children in order, and the facts `same.facts` names on each value. Reports the first difference,
// with its path, under `name`.
values_agree :: proc(t: ^testing.T, x: ^tape.Document, a: tape.Node_Index, y: ^tape.Document, b: tape.Node_Index, same: Same, name: string, loc := #caller_location) -> bool {
	path := strings.builder_make(context.temp_allocator)
	return agree_value(t, x, a, y, b, same, &path, name, loc)
}

@(private)
agree_value :: proc(t: ^testing.T, x: ^tape.Document, a: tape.Node_Index, y: ^tape.Document, b: tape.Node_Index, same: Same, path: ^strings.Builder, name: string, loc := #caller_location) -> bool {
	fail :: proc(t: ^testing.T, path: ^strings.Builder, name: string, what: string, loc: runtime.Source_Code_Location) -> bool {
		testing.expectf(t, false, "%s at %s: %s", name, strings.to_string(path^), what, loc = loc)
		return false
	}
	p, q := x.nodes[a], y.nodes[b]
	if !agree_facts_on(x, a, y, b, same.facts) {
		return fail(t, path, name, fmt.tprintf("facts %v, read back %v", facts_on(x, a, same.facts), facts_on(y, b, same.facts)), loc)
	}
	if p.kind <= .Plain || q.kind <= .Plain {
		if same.scalars_as_text && p.kind != .Null && q.kind != .Null && p.kind <= .Plain && q.kind <= .Plain {
			if scalar_text(x, a) != scalar_text(y, b) {
				return fail(t, path, name, fmt.tprintf("text %q, read back %q", scalar_text(x, a), scalar_text(y, b)), loc)
			}
			return true
		}
		text_kind :: proc(k: tape.Kind) -> tape.Kind {
			return .String if k == .Plain else k
		}
		if text_kind(p.kind) != text_kind(q.kind) {
			return fail(t, path, name, fmt.tprintf("kind %v, read back %v", p.kind, q.kind), loc)
		}
		#partial switch p.kind {
		case .Number:
			if same.number_values {
				m, _ := tape.node_number(x, a)
				n, _ := tape.node_number(y, b)
				if m != n && !(m.kind == .Wide && n.kind == .Wide) {
					return fail(t, path, name, fmt.tprintf("number %v, read back %v", m, n), loc)
				}
			} else if scalar_text(x, a) != scalar_text(y, b) {
				return fail(t, path, name, fmt.tprintf("number %s, read back %s", scalar_text(x, a), scalar_text(y, b)), loc)
			}
		case .String, .Plain:
			if scalar_text(x, a) != scalar_text(y, b) {
				return fail(t, path, name, fmt.tprintf("text %q, read back %q", scalar_text(x, a), scalar_text(y, b)), loc)
			}
		}
		return true
	}
	if p.kind != q.kind {
		return fail(t, path, name, fmt.tprintf("kind %v, read back %v", p.kind, q.kind), loc)
	}
	r, s := tape.Reader{x, nil}, tape.Reader{y, nil}
	c, _, _ := tape.children(r, a, context.temp_allocator)
	d, _, _ := tape.children(s, b, context.temp_allocator)
	at := len(path.buf)
	for k := 0; ; k += 1 {
		ka, va, pa := tape.next_child(r, &c, .Group)
		kb, vb, pb := tape.next_child(s, &d, .Group)
		if pa != pb {
			return fail(t, path, name, fmt.tprintf("child %d is %v, read back %v", k, pa, pb), loc)
		}
		if pa != .Found {
			return true
		}
		resize(&path.buf, at)
		if ka != tape.NO_NODE {
			if scalar_text(x, ka) != scalar_text(y, kb) {
				return fail(t, path, name, fmt.tprintf("key %q, read back %q", scalar_text(x, ka), scalar_text(y, kb)), loc)
			}
			fmt.sbprintf(path, ".%s", scalar_text(x, ka))
		} else {
			fmt.sbprintf(path, "[%d]", k)
		}
		if !agree_value(t, x, va, y, vb, same, path, name, loc) {
			return false
		}
	}
}

// The text of scalar node `at`, its decode or its bytes.
scalar_text :: proc(doc: ^tape.Document, at: tape.Node_Index) -> string {
	room := tape.text_room(doc, at)
	if room == 0 {
		t := doc.nodes[at]
		return string(tape.span_bytes(doc, t.lo, t.n))
	}
	buf := make([]u8, room, context.temp_allocator)
	s, _ := tape.node_text(doc, at, buf)
	return s
}

// The facts of kinds `kinds` on node `at`, as their kinds and bodies.
facts_on :: proc(doc: ^tape.Document, at: tape.Node_Index, kinds: tape.Facts) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for f in doc.facts {
		if f.node == at && f.kind in kinds {
			body, _ := write.comment_body(doc, f)
			append(&out, fmt.tprintf("%v %q", f.kind, string(body)))
		}
	}
	return out[:]
}

@(private)
agree_facts_on :: proc(x: ^tape.Document, a: tape.Node_Index, y: ^tape.Document, b: tape.Node_Index, kinds: tape.Facts) -> bool {
	if kinds == {} {
		return true
	}
	return slice.equal(facts_on(x, a, kinds), facts_on(y, b, kinds))
}
