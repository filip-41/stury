package msgpack

import "base:runtime"
import "core:encoding/endian"
import "core:io"
import "core:math"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// MessagePack encoder: writes a `tape.Document` (from MessagePack or any other format) under `.Msgpack` or `.Compact`,
// converting timestamps (`"datetime"` / CBOR tag 0 & 1 / `ext -1`), binaries (`.Bytes`), and `ext` facts.

Write_Options :: write.Options
Write_Error :: write.Error
Token_Kind :: write.Token_Kind
Record_Framing :: write.Record_Framing
Refused :: write.Refused
Refusal :: write.Refusal

// Writes value `opts.node` of `doc` as MessagePack of `spec` in a buffer from `allocator`.
write :: proc(doc: ^tape.Document, spec := Spec.Msgpack, opts := Write_Options{}, allocator := context.allocator) -> (text: []u8, dropped: tape.Facts, err: Write_Error) {
	return write.to_buffer(doc, u8(spec), opts, allocator, write_out)
}

// Writes value `opts.node` of `doc` into `sink` as MessagePack of `spec`.
write_to :: proc(sink: io.Writer, doc: ^tape.Document, spec := Spec.Msgpack, opts := Write_Options{}, allocator := context.allocator) -> (dropped: tape.Facts, err: Write_Error) {
	return write.to_sink(sink, doc, u8(spec), opts, allocator, write_out)
}

@(private)
check_write_opts :: #force_inline proc "contextless" (spec: u8, opts: Write_Options) -> Write_Error {
	if spec > u8(max(Spec)) {
		return tape.Bad_Option{"spec"}
	}
	if opts.format != nil || opts.indent != 0 || opts.tab || opts.ascii || opts.framing != .None || opts.grow_header || len(opts.header) > 0 {
		opt := "format" if opts.format != nil else "header" if len(opts.header) > 0 || opts.grow_header else "indent"
		return tape.Bad_Option{opt}
	}
	return nil
}

@(private)
write_out :: proc(out: ^write.Out, doc: ^tape.Document, spec: u8, opts: Write_Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
	if err := check_write_opts(spec, opts); err != nil {
		return {}, err
	}
	strict := Spec(spec) == .Compact
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
	is_msgpack := read_as_msgpack(doc)
	facts, tables := write.tree_facts(&w), write.tree_tables(&w)
	lost := false
	switch {
	case facts && tables: write_steps(out, &w, strict, is_msgpack, &lost, true, true)
	case facts: write_steps(out, &w, strict, is_msgpack, &lost, true, false)
	case tables: write_steps(out, &w, strict, is_msgpack, &lost, false, true)
	case: write_steps(out, &w, strict, is_msgpack, &lost, false, false)
	}
	dropped := write.tree_end(&w)
	if lost {
		dropped += {.Tag}
	}
	if w.err == nil {
		w.err = out.err
	}
	return dropped, w.err
}

@(private)
verbatim_item :: proc "contextless" (doc: ^tape.Document, opts: Write_Options) -> (text: []u8, whole: bool) {
	if !read_as_msgpack(doc) || opts.node != tape.ROOT || opts.sort_keys || doc.partial != nil || doc.ext != nil || len(doc.nodes) == 0 {
		return nil, false
	}
	if doc.flags - {.Owns_Src} != {} || doc.root_close == 0 || doc.root_close != u64(len(doc.src)) || doc.nodes[0].role != .Value {
		return nil, false
	}
	return doc.src, true
}

@(private)
read_as_msgpack :: #force_inline proc "contextless" (doc: ^tape.Document) -> bool {
	return doc.format != nil && doc.format.id >= ID && doc.format.id < ID + tape.Format_Id(len(Spec))
}

@(private)
write_steps :: proc(out: ^write.Out, w: ^write.Tree, strict, is_msgpack: bool, lost: ^bool, $FACTS, $TABLES: bool) {
	for {
		s := write.tree_next(w, FACTS, TABLES)
		if w.err != nil {
			return
		}
		if s.kind == .Done {
			return
		}
		if s.kind == .Close {
			continue
		}
		when TABLES {
			if s.cell {
				if !put_cell_key(out, w) {
					return
				}
			}
		}
		if s.key != tape.NO_NODE {
			if !put_key(out, w, s.key, strict, is_msgpack) {
				return
			}
		}
		if s.kind == .Open {
			when FACTS {
				for f in s.facts {
					if f.kind == .Tag {
						lost^ = true
						break
					}
				}
				if !lost^ && !is_msgpack && w.doc.format != nil && w.doc.format.fact_name != nil {
					if _, has := w.doc.format.fact_name(w.doc, s.node, .Tag); has {
						lost^ = true
					}
				}
			}
			node := w.nodes[s.node]
			count := tape.child_count(w.doc, s.node, node)
			if count < 0 {
				w.err = write.Refused{s.node, .Partial}
				return
			}
			if node.kind == .Object {
				f := &w.frames[w.depth - 1]
				if f.sorted {
					count = len(w.pairs) - int(f.pairs_lo)
				} else {
					when TABLES {
						if w.in_row {
							if w.row.once {
								count = min(count, int(w.row.keys_n))
							} else {
								rc := w.row
								count = 0
								for {
									_, _, p := tape.next_child(w.reader, &rc, .Group)
									if p != .Found {
										break
									}
									count += 1
								}
							}
						}
					}
				}
			}
			if u64(count) > u64(max(u32)) {
				w.err = write.Refused{s.node, .No_Spelling}
				return
			}
			put_container_head(out, node.kind == .Object, u32(count))
			continue
		}
		when FACTS {
			handled, ok := try_put_tagged_scalar(out, w, s, strict, is_msgpack, lost)
			if !ok {
				return
			}
			if handled {
				continue
			}
		}
		if !put_scalar(out, w, s.node, strict, is_msgpack) {
			return
		}
	}
}

@(private)
try_put_tagged_scalar :: proc(out: ^write.Out, w: ^write.Tree, s: write.Step, strict, is_msgpack: bool, lost: ^bool) -> (handled, ok: bool) {
	doc := w.doc
	t := w.nodes[s.node]
	if is_msgpack {
		tag_fact: tape.Fact
		has_tag := false
		for f in s.facts {
			if f.kind == .Tag && f.n > 0 {
				tag_fact = f
				has_tag = true
			}
		}
		if !has_tag {
			return false, true
		}
		head := tape.span_bytes(doc, tag_fact.lo, tag_fact.n)
		payload := tape.span_bytes(doc, t.lo, t.n)
		ext_type := i8(head[len(head) - 1])
		if ext_type == -1 {
			if !strict {
				write.put(out, head)
				write.put(out, payload)
			} else {
				sec, nsec, ts_ok := timestamp_decode(payload)
				if !ts_ok {
					w.err = write.Refused{s.node, .No_Spelling}
					return true, false
				}
				put_timestamp(out, sec, nsec)
			}
			return true, true
		}
		if !strict {
			write.put(out, head)
			write.put(out, payload)
		} else {
			put_ext(out, ext_type, payload)
		}
		return true, true
	}

	// Foreign document tags: convert date-time tags (`"datetime"` / `"!!timestamp"` / CBOR tag 0/1) to Timestamp `ext -1`.
	is_dt := false
	cbor_tag1 := false
	has_unknown := false
	if doc.format != nil && doc.format.fact_name != nil {
		if name, has := doc.format.fact_name(doc, s.node, .Tag); has {
			if name == "datetime" || name == "!!timestamp" {
				is_dt = true
			} else {
				has_unknown = true
			}
		}
	}
	cbor_binary := doc.format != nil && doc.format.id >= tape.FORMAT_ID_CBOR && doc.format.id < tape.FORMAT_ID_CBOR + 4
	for f in s.facts {
		if f.kind != .Tag || f.n == 0 {
			continue
		}
		if cbor_binary {
			if num, fok := tape.fact_number(doc, f); fok && (num.kind == .Uint || num.kind == .Int) {
				if num.bits == 0 {
					is_dt = true
					continue
				}
				if num.bits == 1 {
					cbor_tag1 = true
					continue
				}
			}
			has_unknown = true
		} else {
			name := string(tape.span_bytes(doc, f.lo, f.n))
			if name == "datetime" || name == "!!timestamp" {
				is_dt = true
			} else {
				has_unknown = true
			}
		}
	}
	if cbor_tag1 && t.kind == .Number {
		if n, nok := tape.node_number(doc, s.node); nok {
			if sec, nsec, eok := epoch_to_timestamp(n); eok {
				if has_unknown {
					lost^ = true
				}
				put_timestamp(out, sec, nsec)
				return true, true
			}
		}
		has_unknown = true
	}
	if is_dt && (t.kind == .String || t.kind == .Plain) {
		if text, tok := write.text_of(w, s.node); tok {
			if sec, nsec, ts_ok := spell.date_time_utc(text); ts_ok {
				if has_unknown {
					lost^ = true
				}
				put_timestamp(out, sec, nsec)
				return true, true
			}
		} else {
			return true, false
		}
		has_unknown = true
	}
	if is_dt || cbor_tag1 || has_unknown {
		lost^ = true
	}
	return false, true
}

@(private)
put_cell_key :: proc(out: ^write.Out, w: ^write.Tree) -> bool {
	s, ok := write.text_of_token(w, w.cell)
	if !ok {
		return false
	}
	if u64(len(s)) > u64(max(u32)) {
		at := w.frames[w.depth - 1].node if w.depth > 0 else tape.ROOT
		w.err = write.Refused{at, .No_Spelling}
		return false
	}
	put_str_head(out, u32(len(s)))
	write.put(out, transmute([]u8)s)
	return true
}

@(private)
put_key :: proc(out: ^write.Out, w: ^write.Tree, at: tape.Node_Index, strict, is_msgpack: bool) -> bool {
	t := w.nodes[at]
	#partial switch t.kind {
	case .Number:
		if is_msgpack && !strict {
			write.put(out, tape.span_bytes(w.doc, t.lo, t.n))
			return true
		}
		n, ok := tape.node_number(w.doc, at)
		if !ok {
			if w.err == nil {
				w.err = write.Refused{at, .No_Spelling}
			}
			return false
		}
		#partial switch n.kind {
		case .Int:
			put_i64(out, i64(n.bits))
			return true
		case .Uint:
			put_u64(out, n.bits)
			return true
		case:
			w.err = write.Refused{at, .No_Spelling}
			return false
		}
	case .Bytes, .String, .Plain:
		return put_scalar(out, w, at, strict, is_msgpack)
	case:
		w.err = write.Refused{at, .No_Spelling}
		return false
	}
}

@(private)
put_scalar :: proc(out: ^write.Out, w: ^write.Tree, at: tape.Node_Index, strict, is_msgpack: bool) -> bool {
	t := w.nodes[at]
	#partial switch t.kind {
	case .Null:
		write.put_byte(out, 0xc0)
	case .False:
		write.put_byte(out, 0xc2)
	case .True:
		write.put_byte(out, 0xc3)
	case .Number:
		return put_number(out, w, at, t, strict, is_msgpack)
	case .Bytes:
		// Read raw binary payload directly so `.Bytes` map keys (whose `decode` emits base64) preserve raw bytes;
		// foreign chunked binary values (`SPELLING_DECODE`) decode through `write.text_of`.
		raw: []u8
		if t.role == .Value && !is_msgpack && t.spelling & tape.SPELLING_DECODE != 0 {
			s, ok := write.text_of(w, at)
			if !ok {
				return false
			}
			raw = transmute([]u8)s
		} else {
			raw = tape.span_bytes(w.doc, t.lo, t.n)
		}
		if u64(len(raw)) > u64(max(u32)) {
			w.err = write.Refused{at, .No_Spelling}
			return false
		}
		put_bin_head(out, u32(len(raw)))
		write.put(out, raw)
	case .String, .Plain:
		s, ok := write.text_of(w, at)
		if !ok {
			return false
		}
		if u64(len(s)) > u64(max(u32)) {
			w.err = write.Refused{at, .No_Spelling}
			return false
		}
		put_str_head(out, u32(len(s)))
		write.put(out, transmute([]u8)s)
	case:
		w.err = write.Refused{at, .No_Spelling}
		return false
	}
	return true
}

@(private)
put_number :: proc(out: ^write.Out, w: ^write.Tree, at: tape.Node_Index, t: tape.Node, strict, is_msgpack: bool) -> bool {
	if is_msgpack && !strict {
		write.put(out, tape.span_bytes(w.doc, t.lo, t.n))
		return true
	}
	n, ok := tape.node_number(w.doc, at)
	if !ok {
		if w.err == nil {
			w.err = write.Refused{at, .No_Spelling}
		}
		return false
	}
	#partial switch n.kind {
	case .Int:
		put_i64(out, i64(n.bits))
		return true
	case .Uint:
		put_u64(out, n.bits)
		return true
	case .Float:
		put_float_bits(out, n.bits)
		return true
	case .Wide:
		if w.err == nil {
			w.err = write.Refused{at, .No_Spelling}
		}
		return false
	}
	if w.err == nil {
		w.err = write.Refused{at, .No_Spelling}
	}
	return false
}

// Writes `i64` in canonical shortest MessagePack encoding.
@(private)
put_i64 :: proc(out: ^write.Out, v: i64) #no_bounds_check {
	if v >= 0 {
		put_u64(out, u64(v))
		return
	}
	p := write.room(out, 9)
	switch {
	case v >= -32:
		p[0] = u8(i8(v))
		out.cursor += 1
	case v >= -128:
		p[0], p[1] = 0xd0, u8(i8(v))
		out.cursor += 2
	case v >= -32768:
		p[0] = 0xd1
		endian.unchecked_put_u16be(p[1:3], u16(i16(v)))
		out.cursor += 3
	case v >= -2_147_483_648:
		p[0] = 0xd2
		endian.unchecked_put_u32be(p[1:5], u32(i32(v)))
		out.cursor += 5
	case:
		p[0] = 0xd3
		endian.unchecked_put_u64be(p[1:9], u64(v))
		out.cursor += 9
	}
}

// Writes `u64` in canonical shortest MessagePack encoding.
@(private)
put_u64 :: proc(out: ^write.Out, v: u64) #no_bounds_check {
	p := write.room(out, 9)
	switch {
	case v <= 0x7f:
		p[0] = u8(v)
		out.cursor += 1
	case v <= 0xff:
		p[0], p[1] = 0xcc, u8(v)
		out.cursor += 2
	case v <= 0xffff:
		p[0] = 0xcd
		endian.unchecked_put_u16be(p[1:3], u16(v))
		out.cursor += 3
	case v <= 0xffff_ffff:
		p[0] = 0xce
		endian.unchecked_put_u32be(p[1:5], u32(v))
		out.cursor += 5
	case:
		p[0] = 0xcf
		endian.unchecked_put_u64be(p[1:9], v)
		out.cursor += 9
	}
}

// Writes IEEE binary64 bits in canonical shortest float32 (`0xca`) or float64 (`0xcb`), preserving `-0.0` and NaN/Inf.
@(private)
put_float_bits :: proc(out: ^write.Out, bits: u64) #no_bounds_check {
	p := write.room(out, 9)
	if double_fits_single(bits) {
		p[0] = 0xca
		sbits: u32
		if bits >> 52 & 0x7ff == 0x7ff {
			sign := u32(bits >> 32) & 0x8000_0000
			if bits & 0xf_ffff_ffff_ffff == 0 {
				sbits = sign | 0x7f80_0000
			} else {
				sbits = sign | 0x7f80_0000 | u32((bits & 0xf_ffff_ffff_ffff) >> 29)
			}
		} else {
			sbits = transmute(u32)f32(transmute(f64)bits)
		}
		endian.unchecked_put_u32be(p[1:5], sbits)
		out.cursor += 5
		return
	}
	p[0] = 0xcb
	endian.unchecked_put_u64be(p[1:9], bits)
	out.cursor += 9
}

@(private)
put_str_head :: proc(out: ^write.Out, n: u32) #no_bounds_check {
	p := write.room(out, 5)
	switch {
	case n <= 31:
		p[0] = 0xa0 | u8(n)
		out.cursor += 1
	case n <= 0xff:
		p[0], p[1] = 0xd9, u8(n)
		out.cursor += 2
	case n <= 0xffff:
		p[0] = 0xda
		endian.unchecked_put_u16be(p[1:3], u16(n))
		out.cursor += 3
	case:
		p[0] = 0xdb
		endian.unchecked_put_u32be(p[1:5], n)
		out.cursor += 5
	}
}

@(private)
put_bin_head :: proc(out: ^write.Out, n: u32) #no_bounds_check {
	p := write.room(out, 5)
	switch {
	case n <= 0xff:
		p[0], p[1] = 0xc4, u8(n)
		out.cursor += 2
	case n <= 0xffff:
		p[0] = 0xc5
		endian.unchecked_put_u16be(p[1:3], u16(n))
		out.cursor += 3
	case:
		p[0] = 0xc6
		endian.unchecked_put_u32be(p[1:5], n)
		out.cursor += 5
	}
}

@(private)
put_container_head :: proc(out: ^write.Out, object: bool, count: u32) #no_bounds_check {
	p := write.room(out, 5)
	switch {
	case count <= 15:
		p[0] = (0x80 if object else 0x90) | u8(count)
		out.cursor += 1
	case count <= 0xffff:
		p[0] = 0xde if object else 0xdc
		endian.unchecked_put_u16be(p[1:3], u16(count))
		out.cursor += 3
	case:
		p[0] = 0xdf if object else 0xdd
		endian.unchecked_put_u32be(p[1:5], count)
		out.cursor += 5
	}
}

@(private)
put_ext_head :: proc(out: ^write.Out, ext_type: i8, n: u32) #no_bounds_check {
	p := write.room(out, 6)
	switch n {
	case 1:
		p[0], p[1] = 0xd4, u8(ext_type)
		out.cursor += 2
	case 2:
		p[0], p[1] = 0xd5, u8(ext_type)
		out.cursor += 2
	case 4:
		p[0], p[1] = 0xd6, u8(ext_type)
		out.cursor += 2
	case 8:
		p[0], p[1] = 0xd7, u8(ext_type)
		out.cursor += 2
	case 16:
		p[0], p[1] = 0xd8, u8(ext_type)
		out.cursor += 2
	case:
		switch {
		case n <= 0xff:
			p[0], p[1], p[2] = 0xc7, u8(n), u8(ext_type)
			out.cursor += 3
		case n <= 0xffff:
			p[0] = 0xc8
			endian.unchecked_put_u16be(p[1:3], u16(n))
			p[3] = u8(ext_type)
			out.cursor += 4
		case:
			p[0] = 0xc9
			endian.unchecked_put_u32be(p[1:5], n)
			p[5] = u8(ext_type)
			out.cursor += 6
		}
	}
}

@(private)
put_ext :: proc(out: ^write.Out, ext_type: i8, payload: []u8) {
	put_ext_head(out, ext_type, u32(len(payload)))
	write.put(out, payload)
}

@(private)
put_timestamp :: proc(out: ^write.Out, sec: i64, nsec: u32) #no_bounds_check {
	p := write.room(out, 15)
	if nsec == 0 && sec >= 0 && sec <= 0xFFFF_FFFF {
		p[0], p[1] = 0xd6, 0xff
		endian.unchecked_put_u32be(p[2:6], u32(sec))
		out.cursor += 6
		return
	}
	if sec >= 0 && sec <= 0x3_FFFF_FFFF {
		p[0], p[1] = 0xd7, 0xff
		val := (u64(nsec) << 34) | u64(sec)
		endian.unchecked_put_u64be(p[2:10], val)
		out.cursor += 10
		return
	}
	p[0], p[1], p[2] = 0xc7, 12, 0xff
	endian.unchecked_put_u32be(p[3:7], nsec)
	endian.unchecked_put_u64be(p[7:15], u64(sec))
	out.cursor += 15
}

@(private)
epoch_to_timestamp :: proc "contextless" (n: spell.Number) -> (sec: i64, nsec: u32, ok: bool) {
	#partial switch n.kind {
	case .Int:
		return i64(n.bits), 0, true
	case .Uint:
		if n.bits <= u64(max(i64)) {
			return i64(n.bits), 0, true
		}
		return 0, 0, false
	case .Float:
		f := transmute(f64)n.bits
		if math.is_nan(f) || math.is_inf(f) || f < f64(min(i64)) || f >= f64(max(i64)) {
			return 0, 0, false
		}
		whole := math.floor(f)
		frac := f - whole
		ns := i64(math.round(frac * 1e9))
		s := i64(whole)
		if ns >= 1_000_000_000 {
			s += 1
			ns -= 1_000_000_000
		} else if ns < 0 {
			s -= 1
			ns += 1_000_000_000
		}
		return s, u32(ns), true
	}
	return 0, 0, false
}
