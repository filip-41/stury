package formats

import "core:fmt"
import "core:os"
import core "../../core"
import "../timing"

// The binary64 bits of a number's value, the form every arm's reader holds. Zero folds as +0, since one arm's reader
// keeps no sign on it, and a `Wide` number has no binary64 value and folds as 0.
number_bits :: proc(num: core.Number) -> u64 {
	v: f64
	switch num.kind {
	case .Int:
		v = f64(i64(num.bits))
	case .Uint:
		v = f64(num.bits)
	case .Float:
		v = transmute(f64)num.bits
	case .Wide:
		return 0
	}
	if v == 0 {
		return 0
	}
	return transmute(u64)v
}

// The byte each value adds, matching the other arms' visitors.
value_tag :: #force_inline proc(kind: core.Kind) -> u8 {
	switch kind {
	case .Object:
		return 'o'
	case .Array:
		return 'a'
	case .String, .Bytes, .Plain:
		return 's'
	case .Number:
		return 'n'
	case .True:
		return 't'
	case .False:
		return 'f'
	case .Null:
		return 'z'
	case .End:
		return 0
	}
	return 0
}

// The decoded byte count of text node `i`, through `buf` when the text fits and a clone when it does not.
text_length :: proc(doc: ^core.Document, i: core.Node_Index, buf: []u8) -> int {
	if s, ok := core.text(doc, i, buf); ok {
		return len(s)
	}
	long, read := core.text_clone(doc, i)
	if !read {
		fmt.eprintf("read: text of node %d failed\n", i)
		os.exit(1)
	}
	defer delete(long)
	return len(long)
}

// The read check of a document: in document order each value's kind tag as its format resolves it, then for a string
// its decoded byte count and for a number its binary64 bits. A key is no value. It is the doc lane's read check, so a
// text a writer made is judged by the check of the text it was read from.
read_check :: proc(doc: ^core.Document) -> u64 {
	h := timing.CHECK_OFFSET
	buf: [4096]u8
	for n, i in doc.nodes {
		if n.role != .Value {
			continue
		}
		kind := core.kind(doc, core.Node_Index(i))
		h = timing.fnv(h, value_tag(kind))
		#partial switch kind {
		case .String, .Plain, .Bytes:
			h = timing.fnv_u64(h, u64(text_length(doc, core.Node_Index(i), buf[:])))
		case .Number:
			num, _ := core.number(doc, core.Node_Index(i))
			h = timing.fnv_u64(h, number_bits(num))
		}
	}
	return h
}
