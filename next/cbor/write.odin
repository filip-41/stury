package cbor

import "base:runtime"
import "core:io"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// CBOR's writer: the layout of a document's values as an item of `spec`, and the spelling of its scalars. `.Cbor`
// copies a whole CBOR document verbatim where it can; `.Preferred`, `.Deterministic` and `.Length_First` write every
// head in its shortest form, every float in its narrowest form (RFC 8949 section 4.1), and every container with a
// definite length. `.Deterministic` and `.Length_First` write each map's members in the order of their keys'
// encodings (length-first, then byte order for text keys) and refuse repeated keys. A number past 64 bits with an
// integer value is a bignum, a byte string is a byte string, and every other scalar is the text of its value. A tag of
// a CBOR document is kept on its value.

Write_Options :: write.Options
Write_Error :: write.Error
Token_Kind :: write.Token_Kind
Record_Framing :: write.Record_Framing
Refused :: write.Refused
Refusal :: write.Refusal

// Writes value `opts.node` of `doc`, a document of any format, as an item of `spec` in a buffer from `allocator` that
// the caller owns. Returns the kinds of the facts `doc` holds that the item does not: every kind but `.Tag`, and the
// tags of a document that is no CBOR's. A value with no CBOR spelling is `Refused` with its node: a number that is no
// integer past 64 bits, and under `.Deterministic` and `.Length_First` a key that is no text or a repeated key. A
// partial container is `Refused{.Partial}`.
write :: proc(doc: ^tape.Document, spec := Spec.Cbor, opts := Write_Options{}, allocator := context.allocator) -> (text: []u8, dropped: tape.Facts, err: Write_Error) {
	return write.to_buffer(doc, u8(spec), opts, allocator, write_out)
}

// `write` into `sink`, through a buffer of `write.SINK_BYTES` from `allocator`. A sink with no procedure is
// `Bad_Option{"sink"}`. On a refusal or a failed sink the sink may hold a prefix of the item.
write_to :: proc(sink: io.Writer, doc: ^tape.Document, spec := Spec.Cbor, opts := Write_Options{}, allocator := context.allocator) -> (dropped: tape.Facts, err: Write_Error) {
	return write.to_sink(sink, doc, u8(spec), opts, allocator, write_out)
}

@(private)
write_out :: proc(out: ^write.Out, doc: ^tape.Document, spec: u8, opts: Write_Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
	if spec > u8(max(Spec)) {
		return {}, tape.Bad_Option{"spec"}
	}
	if opts.format != nil || opts.indent != 0 || opts.tab || opts.ascii || opts.framing != .None || opts.grow_header || len(opts.header) > 0 {
		opt := "format" if opts.format != nil else "header" if len(opts.header) > 0 || opts.grow_header else "indent"
		return {}, tape.Bad_Option{opt}
	}
	strict := Spec(spec) != .Cbor
	if !strict {
		if text, whole := verbatim_item(doc, opts); whole {
			write.put(out, text)
			return doc.present - {.Tag}, out.err
		}
	}
	w: write.Tree
	if e := write.tree_start(&w, doc, opts, {.Tag}, allocator); e != nil {
		return {}, e
	}
	ordered := Spec(spec) == .Deterministic || Spec(spec) == .Length_First
	w.sort_keys, w.length_first, w.no_dups = w.sort_keys || ordered, ordered, ordered
	tagged := read_as_cbor(doc)
	facts, tables := write.tree_facts(&w), write.tree_tables(&w)
	lost := false
	switch {
	case facts && tables: write_steps(out, &w, strict, ordered, tagged, &lost, true, true)
	case facts: write_steps(out, &w, strict, ordered, tagged, &lost, true, false)
	case tables: write_steps(out, &w, strict, ordered, tagged, &lost, false, true)
	case: write_steps(out, &w, strict, ordered, tagged, &lost, false, false)
	}
	dropped := write.tree_end(&w)
	if lost && !tagged {
		dropped += {.Tag}
	}
	if w.err == nil {
		w.err = out.err
	}
	return dropped, w.err
}

// The source of a document read whole from CBOR, which `.Cbor` writes as it is: every item its source holds is valid
// there, a tag included. False for a document that holds less than its source, a subtree and a sorted write.
@(private)
verbatim_item :: proc "contextless" (doc: ^tape.Document, opts: Write_Options) -> (text: []u8, whole: bool) {
	if !read_as_cbor(doc) || opts.node != tape.ROOT || opts.sort_keys || doc.partial != nil || doc.ext != nil || len(doc.nodes) == 0 {
		return nil, false
	}
	if doc.flags - {.Owns_Src} != {} || doc.root_close != u64(len(doc.src)) || doc.nodes[0].role != .Value {
		return nil, false
	}
	return doc.src, true
}

@(private)
write_steps :: proc(out: ^write.Out, w: ^write.Tree, strict, ordered, tagged: bool, lost: ^bool, $FACTS, $TABLES: bool) {
	for {
		s := write.tree_next(w, FACTS, TABLES)
		if s.kind == .Done {
			return
		}
		if s.kind == .Close {
			continue
		}
		if s.key != tape.NO_NODE {
			if ordered && w.nodes[s.key].kind != .String && w.nodes[s.key].kind != .Plain {
				w.err = write.Refused{s.key, .No_Spelling}
				return
			}
			if !put_scalar(out, w, s.key, strict) {
				return
			}
		}
		when FACTS {
			if tagged {
				put_tags(out, w, s.node, s.facts, strict)
			} else {
				put_named_tags(out, w, s, lost)
			}
		}
		if s.kind == .Open {
			node := w.nodes[s.node]
			count := tape.child_count(w.doc, s.node, node)
			if count < 0 {
				w.err = write.Refused{s.node, .Partial}
				return
			}
			put_head(out, 5 if node.kind == .Object else 4, u64(count))
		} else if !put_scalar(out, w, s.node, strict) {
			return
		}
	}
}

// Writes the tags of node `s` that a document of another format holds, a date-time's type or the text of a tag, before
// the value, those CBOR spells. Sets `lost` for a tag it has no spelling of.
@(private)
put_named_tags :: proc(out: ^write.Out, w: ^write.Tree, s: write.Step, lost: ^bool) {
	doc := w.doc
	names: [MAX_PENDING_TAGS]string
	n := 0
	if doc.format.fact_name != nil {
		if name, ok := doc.format.fact_name(doc, s.node, .Tag); ok {
			names[0], n = name, 1
		}
	}
	for f in s.facts {
		if f.kind == .Tag && f.n > 0 && n < len(names) {
			names[n] = string(tape.span_bytes(doc, f.lo, f.n))
			n += 1
		}
	}
	if n == 0 {
		return
	}
	text: string
	if w.nodes[s.node].kind <= .Plain && w.nodes[s.node].kind != .Null {
		text, _ = write.text_of(w, s.node)
	}
	tags: [MAX_PENDING_TAGS]Text_Tag
	k := 0
	for name in names[:n] {
		if t, ok := text_tag_of(name); ok {
			tags[k] = t
			k += 1
		} else {
			lost^ = true
		}
	}
	lost^ ||= put_text_tags(out, tags[:k], text) < k
}

// Whether CBOR number node `t` is a tag-folded number (bignum, decimal fraction or bigfloat).
@(private)
is_cbor_folded :: #force_inline proc "contextless" (t: tape.Node) -> bool {
	if t.kind != .Number || t.n == 0 {
		return false
	}
	switch t.spelling & tape.NUMBER_KIND {
	case NUMBER_BIG, NUMBER_BIG_NEGATIVE, NUMBER_DECIMAL, NUMBER_BIGFLOAT:
		return true
	}
	return false
}

// Writes the tags of `facts` before their value, in the order they were read. Under `strict`, the innermost tag of a
// folded number (tags 2..5) is skipped because `put_cbor_folded` writes its preferred tag or collapses it to an integer.
@(private)
put_tags :: proc(out: ^write.Out, w: ^write.Tree, at: tape.Node_Index, facts: []tape.Fact, strict: bool) {
	skip := -1
	if strict && is_cbor_folded(w.nodes[at]) {
		for i := len(facts) - 1; i >= 0; i -= 1 {
			if facts[i].kind == .Tag && facts[i].n > 0 {
				skip = i
				break
			}
		}
	}
	for f, i in facts {
		if f.kind != .Tag || f.n == 0 || i == skip {
			continue
		}
		span := tape.span_bytes(w.doc, f.lo, f.n)
		_, arg, _ := head_of(span)
		put_head(out, 6, arg)
	}
}

// Writes the head of major type `major` with argument `arg`, in as few bytes as hold it.
@(private)
put_head :: proc(out: ^write.Out, major: u8, arg: u64) #no_bounds_check {
	p := write.room(out, 9)
	m := major << 5
	switch {
	case arg < 24:
		p[0] = m | u8(arg)
		out.cursor += 1
	case arg <= 0xFF:
		p[0], p[1] = m | 24, u8(arg)
		out.cursor += 2
	case arg <= 0xFFFF:
		p[0], p[1], p[2] = m | 25, u8(arg >> 8), u8(arg)
		out.cursor += 3
	case arg <= 0xFFFF_FFFF:
		p[0] = m | 26
		for i in 0 ..< 4 {
			p[1 + i] = u8(arg >> uint(24 - 8 * i))
		}
		out.cursor += 5
	case:
		p[0] = m | 27
		for i in 0 ..< 8 {
			p[1 + i] = u8(arg >> uint(56 - 8 * i))
		}
		out.cursor += 9
	}
}

// Writes the scalar at node `at`. False with `w.err` set when it has no spelling or memory is refused.
@(private)
put_scalar :: proc(out: ^write.Out, w: ^write.Tree, at: tape.Node_Index, strict: bool) -> bool {
	t := w.nodes[at]
	#partial switch t.kind {
	case .Null:
		write.put_byte(out, 0xF6)
	case .False:
		write.put_byte(out, 0xF4)
	case .True:
		write.put_byte(out, 0xF5)
	case .Number:
		return put_number(out, w, at, t, strict)
	case .Bytes, .String, .Plain:
		s, ok := write.text_of(w, at)
		if !ok {
			return false
		}
		put_head(out, 2 if t.kind == .Bytes else 3, u64(len(s)))
		write.put(out, transmute([]u8)s)
	}
	return true
}

// Re-encodes a CBOR bignum payload `span` (definite or indefinite byte string) into preferred form: an integer head if
// its stripped magnitude fits 64 bits, else tag 2/3 with a definite byte string with no leading zero bytes.
@(private)
put_cbor_bignum :: proc(out: ^write.Out, span: []u8, negative: bool) {
	r := string_run(span)
	total := 0
	arg: u64
	for chunk in text_next(&r) {
		for b in chunk {
			if total == 0 && b == 0 {
				continue
			}
			if total < 8 {
				arg = arg << 8 | u64(b)
			}
			total += 1
		}
	}
	if total <= 8 {
		put_head(out, 1 if negative else 0, arg)
		return
	}
	put_head(out, 6, 3 if negative else 2)
	put_head(out, 2, u64(total))
	r2 := string_run(span)
	started := false
	for chunk in text_next(&r2) {
		if started {
			write.put(out, chunk)
			continue
		}
		for b, i in chunk {
			if b != 0 {
				started = true
				write.put(out, chunk[i:])
				break
			}
		}
	}
}

// Re-encodes a CBOR folded number (bignum, decimal fraction or bigfloat) in preferred definite form.
@(private)
put_cbor_folded :: proc(out: ^write.Out, span: []u8, kind: u16) {
	switch kind {
	case NUMBER_BIG, NUMBER_BIG_NEGATIVE:
		put_cbor_bignum(out, span, kind == NUMBER_BIG_NEGATIVE)
	case NUMBER_DECIMAL, NUMBER_BIGFLOAT:
		put_head(out, 6, 5 if kind == NUMBER_BIGFLOAT else 4)
		write.put_byte(out, 0x82)
		pos := array_body(span)
		emajor, earg, ehl := head_of(span[pos:])
		put_head(out, emajor, earg)
		m := span[pos + ehl:]
		if m[0] >> 5 <= 1 {
			mmajor, marg, _ := head_of(m)
			put_head(out, mmajor, marg)
		} else {
			_, mtag, mhl := head_of(m)
			put_cbor_bignum(out, m[mhl:], mtag == 3)
		}
	}
}

@(private)
put_number :: proc(out: ^write.Out, w: ^write.Tree, at: tape.Node_Index, t: tape.Node, strict: bool) -> bool {
	// A number read from CBOR as a big number, decimal fraction or big float keeps its bytes under `.Cbor`, and is
	// re-encoded into preferred definite form under stricter specs.
	if read_as_cbor(w.doc) && is_cbor_folded(t) {
		span := tape.span_bytes(w.doc, t.lo, t.n)
		if !strict {
			write.put(out, span)
		} else {
			put_cbor_folded(out, span, t.spelling & tape.NUMBER_KIND)
		}
		return true
	}
	n, ok := tape.node_number(w.doc, at)
	if ok {
		switch n.kind {
		case .Int:
			if i64(n.bits) < 0 {
				put_head(out, 1, ~n.bits)
			} else {
				put_head(out, 0, n.bits)
			}
			return true
		case .Uint:
			put_head(out, 0, n.bits)
			return true
		case .Float:
			// A whole number past 64 bits reads as the nearest float, and is written by its text.
			buf: [write.NUMBER_ROOM]u8
			if text, spelled := write.number_text(w, at, &buf); spelled && is_integer_text(text) && put_bignum(out, text) {
				return true
			}
			put_float(out, transmute(f64)n.bits)
			return true
		case .Wide:
		}
	}
	buf: [write.NUMBER_ROOM]u8
	text, spelled := write.number_text(w, at, &buf)
	if spelled && is_integer_text(text) && put_bignum(out, text) {
		return true
	}
	if w.err == nil {
		w.err = write.Refused{at, .No_Spelling}
	}
	return false
}

// Writes the integer `text` (an optional minus sign and digits) as a bignum, tag 2 or 3 and its magnitude as a byte
// string. False for any other text, and for a magnitude past 4096 digits.
@(private)
put_bignum :: proc(out: ^write.Out, text: string) -> bool {
	negative := len(text) > 0 && text[0] == '-'
	digits := text[1:] if negative else text
	if len(digits) == 0 || len(digits) > 4096 {
		return false
	}
	// Base 10^9 limbs, most significant first, the first group padded with zeros on its left.
	limbs: [457]u32
	n := (len(digits) + 8) / 9
	lead := n * 9 - len(digits)
	for c, i in transmute([]u8)digits {
		if c < '0' || c > '9' {
			return false
		}
		g := (i + lead) / 9
		limbs[g] = limbs[g] * 10 + u32(c - '0')
	}
	// The magnitude of -n is n - 1 in the encoding of tag 3.
	if negative {
		for i := n - 1; i >= 0; i -= 1 {
			if limbs[i] == 0 {
				limbs[i] = 999_999_999
			} else {
				limbs[i] -= 1
				break
			}
		}
	}
	// Divide by 256 until nothing is left, the remainders the bytes from the least significant.
	bytes: [1792]u8
	k := 0
	for {
		zero := true
		carry := u64(0)
		for i in 0 ..< n {
			cur := carry * 1_000_000_000 + u64(limbs[i])
			limbs[i] = u32(cur / 256)
			carry = cur % 256
			zero &&= limbs[i] == 0
		}
		bytes[k] = u8(carry)
		k += 1
		if zero {
			break
		}
	}
	// A magnitude that fits 64 bits is an integer head, as the preferred form has it.
	if k <= 8 {
		arg := u64(0)
		for i := k - 1; i >= 0; i -= 1 {
			arg = arg << 8 | u64(bytes[i])
		}
		put_head(out, 1 if negative else 0, arg)
		return true
	}
	put_head(out, 6, 3 if negative else 2)
	put_head(out, 2, u64(k))
	for i := k - 1; i >= 0; i -= 1 {
		write.put_byte(out, bytes[i])
	}
	return true
}

// Writes `f` as the narrowest float that holds it: binary16, binary32 or binary64, and a NaN as `f97e00`.
@(private)
put_float :: proc(out: ^write.Out, f: f64) {
	p := write.room(out, 9)
	switch {
	case f != f:
		p[0], p[1], p[2] = 0xF9, 0x7E, 0x00
		out.cursor += 3
	case f64(f16(f)) == f:
		h := transmute(u16)f16(f)
		p[0], p[1], p[2] = 0xF9, u8(h >> 8), u8(h)
		out.cursor += 3
	case f64(f32(f)) == f:
		s := transmute(u32)f32(f)
		p[0] = 0xFA
		for i in 0 ..< 4 {
			p[1 + i] = u8(s >> uint(24 - 8 * i))
		}
		out.cursor += 5
	case:
		d := transmute(u64)f
		p[0] = 0xFB
		for i in 0 ..< 8 {
			p[1 + i] = u8(d >> uint(56 - 8 * i))
		}
		out.cursor += 9
	}
}

// Whether `text` is an optional minus sign and digits alone.
@(private)
is_integer_text :: proc "contextless" (text: string) -> bool {
	for c, i in transmute([]u8)text {
		if (c < '0' || c > '9') && !(c == '-' && i == 0) {
			return false
		}
	}
	return len(text) > 0
}

// Whether `doc` was read from CBOR, so its tag facts and number bytes are CBOR heads.
@(private)
read_as_cbor :: #force_inline proc "contextless" (doc: ^tape.Document) -> bool {
	return doc.format.id >= ID && doc.format.id < ID + tape.Format_Id(len(Spec))
}
