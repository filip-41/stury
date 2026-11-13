package cbor

// The document writer. Every node is written as one item: a container's head holds its count, a key is a text string
// or, from a CBOR source, the integer it was, and a byte string is a byte string. An item read from CBOR in an encoding
// the target accepts is copied as it was read, a tag with it, and any other is written again from its value in
// preferred serialization. A deterministic target writes a map's members in the order of their encoded keys, and a
// key two members write alike is `.Unwritable`. A comment, a text tag and any other fact CBOR has no place for is
// dropped and counted.

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:slice"
import core "../core"
import write "../core/write"

@(private)
Emit :: struct {
	doc:    ^core.Document,
	out:    write.Out,
	enc:    Spec,
	own:    bool, // the source is CBOR
	sorted: bool, // a map's members follow their encoded keys
	kept:   int, // the facts written as tags
}

// The handle's `write`: node `node` of `doc` as one CBOR item of `as`'s spec.
@(private)
document_write :: proc(doc: ^core.Document, opts: core.Write_Options, as: core.As, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, dropped: int, err: core.Typed_Refusal) {
	if doc.partial {
		return nil, 0, {kind = .Unsupported}
	}
	spill: [write.ROOM_MAX]u8 = ---
	e := Emit{doc = doc, enc = Spec(as.spec), own = doc.readers != nil && doc.readers.format == format_rules}
	source := Spec(doc.as.spec)
	// A deterministic text is in preferred serialization, and a preferred one need not have its keys in order.
	verbatim := e.own && (e.enc == .Cbor || source == e.enc || e.enc == .Preferred && source > .Preferred)
	e.sorted = e.enc >= .Deterministic || opts.sort_keys
	write.init(&e.out, &spill, allocator, stream, len(doc.src) + write.ROOM_MAX if e.own else 0)
	kind: core.Typed_Error_Kind
	if verbatim {
		put_verbatim(&e, node)
	} else if !e.sorted && core.header_of(doc) == 0 {
		kind = put_preorder(&e, node)
	} else {
		kind = put_node(&e, node, 0)
	}
	text, err = write.finish(&e.out, {kind = kind})
	if err.kind != .None {
		return nil, 0, err
	}
	if verbatim {
		return text, 0, err
	}
	return text, len(core.subtree_facts(doc, node)) - e.kept, err
}

// Copies the bytes node `i` was read from, its tags first, as one span.
@(private)
put_verbatim :: proc(e: ^Emit, i: core.Node_Index) {
	tags, _, hi := item_span(e.doc, i)
	write.put_text(&e.out, string(e.doc.src[tags:hi]))
}

// The bytes node `i` of a document read from CBOR was read from: the first byte of its outermost tag, the first byte
// of its item, which is a string's head or the tag a bignum, a decimal fraction or a bigfloat is spelled with, and the
// byte past the item, which is past an indefinite string's break.
@(private)
item_span :: proc(doc: ^core.Document, i: core.Node_Index) -> (tags, lo, hi: u64) {
	n := doc.nodes[i]
	facts := core.all_facts(doc, i)
	lo, hi = n.lo, n.lo + u64(n.n)
	#partial switch n.kind {
	case .String, .Bytes:
		lo -= u64(n.spelling >> HEAD_SHIFT & 15)
		hi += 1 if n.spelling & STR_INDEF != 0 else 0
	case .Number:
		if n.spelling & 14 >= CN_BIG {
			lo = facts[len(facts) - 1].lo
		}
	case .Array, .Object:
		hi = close_end(doc, i)
	}
	tags = facts[0].lo if len(facts) > 0 else lo
	return
}

// Writes the subtree of node `i` in preorder, each node with its tags as one item. A container's head holds its count
// and its items follow it, a member's key before its value, in the order a document with no shared keys holds its
// nodes. The walk holds no stack, so no depth bounds it.
@(private)
put_preorder :: proc(e: ^Emit, i: core.Node_Index) -> core.Typed_Error_Kind {
	doc := e.doc
	end := i + core.Node_Index(core.subtree_size(doc, i))
	for j in i ..< end {
		put_tags(e, j)
		#partial switch k := core.kind(doc, j); k {
		case .Array:
			e.out.cursor += write.put_head(write.room(&e.out, 9), u64(core.length(doc, j)), TREE, .Array)
		case .Object:
			e.out.cursor += write.put_head(write.room(&e.out, 9), u64(core.length(doc, j)), TREE, .Map)
		case:
			put_leaf(e, j, k) or_return
		}
	}
	return e.out.err
}

// Writes node `i`, `depth` containers deep, with its tags.
@(private)
put_node :: proc(e: ^Emit, i: core.Node_Index, depth: int) -> core.Typed_Error_Kind {
	doc := e.doc
	put_tags(e, i)
	#partial switch k := core.kind(doc, i); k {
	case .Array, .Object:
		if depth == core.MAX_DEPTH {
			return .Too_Deep
		}
		if k == .Array {
			e.out.cursor += write.put_head(write.room(&e.out, 9), u64(core.length(doc, i)), TREE, .Array)
			it := core.children(doc, i)
			for c in core.child_next(&it) {
				put_node(e, c, depth + 1) or_return
			}
			return e.out.err
		}
		return put_map(e, i, depth)
	case:
		return put_leaf(e, i, k)
	}
}

// Writes node `i`, which holds no other, of kind `k`, without its tags.
@(private)
put_leaf :: #force_inline proc(e: ^Emit, i: core.Node_Index, k: core.Kind) -> core.Typed_Error_Kind {
	n := e.doc.nodes[i]
	#partial switch k {
	case .Null, .False, .True:
		if e.own && n.kind != .Plain {
			write.put_text(&e.out, string(span_of(e, i)))
		} else {
			write.put_text(&e.out, TREE[.Null] if k == .Null else TREE[.True] if k == .True else TREE[.False])
		}
	case .Number:
		return put_number(e, i)
	case .String, .Bytes:
		return put_string_node(e, i, k)
	case:
		return .Unsupported
	}
	return e.out.err
}

// Writes the tags of node `i` that are CBOR tags, the outermost first. The tag of a bignum, a decimal fraction or a
// bigfloat is its number's, which `put_number` writes.
@(private)
put_tags :: #force_inline proc(e: ^Emit, i: core.Node_Index) {
	if len(e.doc.facts) == 0 {
		return
	}
	facts := core.all_facts(e.doc, i)
	if number_tagged(e, i) {
		facts = facts[:len(facts) - 1]
		e.kept += 1
	}
	for f in facts {
		if f.role != .Tag || f.kind != .Number {
			continue
		}
		e.kept += 1
		if tag, ok := core.fact_number(e.doc, f); ok {
			e.out.cursor += write.put_head(write.room(&e.out, 9), tag.bits, TREE, .Tag)
		}
	}
}

// Whether node `i` is a CBOR number whose last tag is its own.
@(private)
number_tagged :: #force_inline proc(e: ^Emit, i: core.Node_Index) -> bool {
	n := e.doc.nodes[i]
	return e.own && n.kind == .Number && n.spelling & 14 >= CN_BIG
}

// The span node `i` was read from: a string's head, a number's own tag and the item.
@(private)
span_of :: proc(e: ^Emit, i: core.Node_Index) -> []u8 {
	_, lo, hi := item_span(e.doc, i)
	return e.doc.src[lo:hi]
}

// Copies the span of number node `i`, read from CBOR, when its bytes are of the target's spec.
@(private)
put_copied :: proc(e: ^Emit, i: core.Node_Index) -> bool {
	if !e.own {
		return false
	}
	span := span_of(e, i)
	if validate_text(span, {max_depth = 1, spec = e.enc}) != nil {
		return false
	}
	write.put_text(&e.out, string(span))
	return true
}

@(private)
put_number :: proc(e: ^Emit, i: core.Node_Index) -> core.Typed_Error_Kind {
	doc := e.doc
	n := doc.nodes[i]
	v: core.Number
	ok := true
	if !e.own || n.kind != .Number {
		v, ok = core.number(doc, i)
	} else if n.spelling & core.NUMBER_KIND_MASK == CN_INT {
		// An integer read from CBOR is written again from its head, as short as its argument allows.
		major, arg, _ := head_of(doc.src[n.lo:n.lo + u64(n.n)])
		p := write.room(&e.out, 9)
		e.out.cursor += write.put_head(p, arg, TREE, .Nint) if major == 1 else write.put_head(p, arg, TREE, .Uint)
		return e.out.err
	} else if n.spelling & core.NUMBER_KIND_MASK == CN_FLOAT {
		v = {float(doc.src[n.lo:n.lo + u64(n.n)]), .Float}
	} else {
		v, ok = core.number(doc, i)
	}
	if !ok {
		return .Unsupported
	}
	// A float, and an integer `Int` holds, written again from its value is as short as preferred serialization asks.
	if (v.kind == .Wide || number_tagged(e, i)) && put_copied(e, i) {
		return e.out.err
	}
	if v.kind == .Float && e.enc >= .Deterministic && v.bits & (1 << 63 - 1) > 0x7ff0000000000000 {
		write.put_text(&e.out, DEFAULT_NAN)
		return e.out.err
	}
	if v.kind == .Int || v.kind == .Uint || v.kind == .Float && !spelled_past_float(e, i, v) {
		return write.put_binary_number(&e.out, v, TREE)
	}
	stack: [64]u8 = ---
	digits, fit := write.node_number_text(doc, i, stack[:])
	if !fit {
		return .No_Memory
	}
	if len(digits) == 0 {
		// An infinity or a NaN the source spells as a word.
		return write.put_binary_number(&e.out, v, TREE) if v.kind == .Float else .Non_Finite
	}
	return write.put_binary_number_text(&e.out, digits, TREE)
}

// Whether the float `v` of number node `i` may be other than its source's value, which its digits then say: a CBOR
// bignum, decimal fraction or bigfloat, and a decimal text that is an integer, out of binary64's range or rounded to
// zero.
@(private)
spelled_past_float :: proc(e: ^Emit, i: core.Node_Index, v: core.Number) -> bool {
	n := e.doc.nodes[i]
	if e.own {
		return n.spelling & 14 >= CN_BIG
	}
	if n.kind != .Number || n.spelling & core.NUMBER_KIND_MASK > core.NUMBER_DECIMAL {
		return n.kind == .Plain
	}
	return core.number_shape(n.spelling) < 32 || v.bits & (1 << 63 - 1) >= 0x7ff0000000000000 || v.bits << 1 == 0
}

@(private)
put_string_node :: proc(e: ^Emit, i: core.Node_Index, k: core.Kind) -> core.Typed_Error_Kind {
	doc := e.doc
	n := doc.nodes[i]
	if e.own && n.spelling & INT_KEY != 0 {
		v, _ := integer(doc.src[n.lo:n.lo + u64(n.n)])
		return write.put_binary_number(&e.out, v, TREE)
	}
	// A definite string read from CBOR is valid as it stands, and only its head may be other than the shortest.
	text: string
	if e.own && n.spelling & (STR_INDEF | core.SPELLING_LAX) == 0 {
		text = string(doc.src[n.lo:n.lo + u64(n.n)])
	} else {
		buf, failed := make([]u8, core.text_room(doc, i), context.temp_allocator)
		if failed != nil {
			return .No_Memory
		}
		ok: bool
		text, ok = core.text(doc, i, buf)
		if !ok {
			return .No_Memory
		}
		if k == .String && !utf8_valid(transmute([]u8)text) {
			return .Invalid_Utf8
		}
	}
	short := len(text) <= write.ROOM_MAX - 9
	p := write.room(&e.out, 9 + len(text) if short else 9)
	h := write.put_head(p, u64(len(text)), TREE, .Bytes) if k == .Bytes else write.put_head(p, u64(len(text)), TREE, .Text)
	if !short {
		e.out.cursor += h
		write.put_text(&e.out, text)
		return e.out.err
	}
	intrinsics.mem_copy_non_overlapping(p[h:], raw_data(text), len(text))
	e.out.cursor += h + len(text)
	return e.out.err
}

// The one NaN a deterministic text has.
@(private)
DEFAULT_NAN :: "\xf9\x7e\x00"

// A member of a map a deterministic write sorts: the bytes its key is written with, and its nodes.
@(private)
Pair :: struct {
	key:   []u8,
	k, v:  core.Node_Index,
}

// Writes the object `i` as a map, its members in their order, or sorted by their encoded keys.
@(private)
put_map :: proc(e: ^Emit, i: core.Node_Index, depth: int) -> core.Typed_Error_Kind {
	doc := e.doc
	count := core.length(doc, i)
	e.out.cursor += write.put_head(write.room(&e.out, 9), u64(count), TREE, .Map)
	it := core.pairs(doc, i)
	if !e.sorted || count < 2 {
		for k, v in core.pair_next(&it) {
			put_node(e, k, depth + 1) or_return
			put_node(e, v, depth + 1) or_return
		}
		return e.out.err
	}
	// Each key is written to scratch first, and the members follow the order of those bytes.
	scratch: write.Out
	spill: [write.ROOM_MAX]u8 = ---
	write.init(&scratch, &spill, context.temp_allocator)
	defer write.destroy(&scratch)
	members, failed := make([dynamic]Pair, 0, count, context.temp_allocator)
	if failed != nil {
		return .No_Memory
	}
	defer delete(members)
	ends, no_ends := make([dynamic]int, 0, count, context.temp_allocator)
	if no_ends != nil {
		return .No_Memory
	}
	defer delete(ends)
	held := e.out
	e.out = scratch
	for k, v in core.pair_next(&it) {
		if kind := put_node(e, k, depth + 1); kind != .None {
			scratch, e.out = e.out, held
			return kind
		}
		append(&members, Pair{k = k, v = v})
		append(&ends, e.out.cursor)
	}
	scratch, e.out = e.out, held
	if scratch.err != .None {
		return scratch.err
	}
	at := 0
	for &m, j in members {
		m.key = scratch.buf[at:ends[j]]
		at = ends[j]
	}
	if e.enc == .Length_First {
		slice.sort_by(members[:], proc(a, b: Pair) -> bool {
			return len(a.key) < len(b.key) || len(a.key) == len(b.key) && string(a.key) < string(b.key)
		})
	} else {
		slice.sort_by(members[:], proc(a, b: Pair) -> bool {return string(a.key) < string(b.key)})
	}
	for m, j in members {
		if j > 0 && string(m.key) == string(members[j - 1].key) {
			return .Unwritable
		}
		write.put_text(&e.out, string(m.key))
		put_node(e, m.v, depth + 1) or_return
	}
	return e.out.err
}
