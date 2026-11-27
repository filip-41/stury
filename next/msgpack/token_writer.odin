package msgpack

import "base:runtime"
import "core:io"
import "core:math"
import "core:unicode/utf8"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import ops_write "stury:lib/ops/write"

// Streaming token writer for MessagePack. Since MessagePack has only definite-length containers,
// tokens buffer cleanly into `nodes`/`data` until `writer_end` emits exact header counts into `Out`.

@(private)
Open_Container :: struct {
	at:           tape.Node_Index,
	children:     u32,
	object:       bool,
	awaiting_val: bool,
}

Writer :: struct {
	seq:        ops_write.Sequence,
	nodes:      [dynamic]tape.Node,
	data:       [dynamic]u8,
	facts:      [dynamic]tape.Fact,
	counts:     [dynamic]tape.Child_Count,
	open:       [dynamic]Open_Container,
	opts:       Write_Options,
	sink:       io.Writer,
	allocator:  runtime.Allocator,
	spec:       Spec,
	pending_dt: bool, // `"datetime"` tag staged for the next `.String` token
}

// Starts `w` to write a MessagePack item of `spec` into `sink` (or buffer when `sink` has no procedure).
@(require_results)
writer_start :: proc(w: ^Writer, spec := Spec.Msgpack, opts := Write_Options{}, sink := io.Writer{}, allocator := context.allocator) -> Write_Error {
	if opts.node != tape.ROOT {
		return tape.Bad_Option{"node"}
	}
	if err := check_write_opts(u8(spec), opts); err != nil {
		return err
	}
	w^ = {opts = opts, sink = sink, allocator = allocator, spec = spec}
	w.nodes.allocator = allocator
	w.data.allocator = allocator
	w.facts.allocator = allocator
	w.counts.allocator = allocator
	w.open.allocator = allocator
	ops_write.sequence_start(&w.seq, false, 0, allocator)
	return nil
}

// Stages a semantic tag (such as `"datetime"`) before a matching scalar token, clearing prior incompatible tags.
@(require_results)
tag :: proc(w: ^Writer, name: string) -> Write_Error {
	w.pending_dt = name == "datetime" || name == "!!timestamp"
	return nil
}

// Writes the value at `node` of `doc` as tokens into `w`.
@(require_results)
put :: proc(w: ^Writer, doc: ^tape.Document, node := tape.ROOT) -> Write_Error {
	return ops_write.tokens_of(doc, node, w, token, w.allocator, tag)
}

// Writes one token into `w`. Refuses invalid sequence transitions as `.Malformed` and unspellable values as `.No_Spelling`.
@(require_results)
token :: proc(w: ^Writer, kind: Token_Kind, text := "") -> Write_Error {
	index := tape.Node_Index(w.seq.taken)
	if kind == .Close {
		w.pending_dt = false
		if _, err := ops_write.sequence_take(&w.seq, kind); err != nil {
			return err
		}
		closed := pop(&w.open)
		count := closed.children
		node := &w.nodes[closed.at]
		node.n = u32(len(w.nodes)) - u32(closed.at)
		node.spelling = u16(min(count, u32(tape.MAX_CHILDREN)))
		if count >= u32(tape.MAX_CHILDREN) {
			if _, aerr := append(&w.counts, tape.Child_Count{node = closed.at, count = count}); aerr != nil {
				return aerr
			}
		}
		return nil
	}

	dt := w.pending_dt
	ts_sec: i64
	ts_nsec: u32
	num: spell.Number
	is_dt_str := false

	switch kind {
	case .Key, .String:
		if !utf8.valid_string(text) {
			return ops_write.Refused{index, .No_Spelling}
		}
		if dt && kind == .String {
			sec, nsec, ok := spell.date_time_utc(text)
			if !ok {
				return ops_write.Refused{index, .No_Spelling}
			}
			ts_sec, ts_nsec = sec, nsec
			is_dt_str = true
		}
	case .Number:
		ok := false
		num, ok = parse_token_number(text)
		if !ok {
			return ops_write.Refused{index, .No_Spelling}
		}
	case .Object, .Array, .True, .False, .Null:
	case .Close:
	}

	if _, err := ops_write.sequence_take(&w.seq, kind); err != nil {
		return err
	}
	w.pending_dt = false

	count_child(w, kind == .Key)
	if len(w.open) > 0 {
		w.open[len(w.open) - 1].awaiting_val = kind == .Key
	}
	role := tape.Role.Key if kind == .Key else .Value
	node := tape.Node{lo = u64(len(w.data)), role = role}

	switch kind {
	case .Object:
		node.kind = .Object
		append(&w.open, Open_Container{at = tape.Node_Index(len(w.nodes)), object = true}) or_return
	case .Array:
		node.kind = .Array
		append(&w.open, Open_Container{at = tape.Node_Index(len(w.nodes)), object = false}) or_return
	case .Key, .String:
		if is_dt_str {
			node_idx := tape.Node_Index(len(w.nodes))
			push_timestamp_bytes(w, node_idx, ts_sec, ts_nsec) or_return
			return nil
		}
		node.kind = .String
		if u64(len(text)) > u64(max(u32)) {
			return ops_write.Refused{index, .No_Spelling}
		}
		node.n = u32(len(text))
		append(&w.data, text) or_return
	case .Number:
		node.kind = .Number
		lo := len(w.data)
		put_compact_number_bytes(&w.data, num) or_return
		node.lo = u64(lo)
		node.n = u32(len(w.data) - lo)
		node.spelling = NUMBER_FLOAT if num.kind == .Float else NUMBER_INT
	case .True:
		node.kind = .True
		append(&w.data, 0xc3) or_return
		node.n = 1
	case .False:
		node.kind = .False
		append(&w.data, 0xc2) or_return
		node.n = 1
	case .Null:
		node.kind = .Null
		append(&w.data, 0xc0) or_return
		node.n = 1
	case .Close:
	}

	if _, aerr := append(&w.nodes, node); aerr != nil {
		return aerr
	}
	return nil
}

// Writes a binary payload (`bin 8/16/32`) at the next value or key position.
@(require_results)
bytes :: proc(w: ^Writer, payload: []u8) -> Write_Error {
	index := tape.Node_Index(w.seq.taken)
	if u64(len(payload)) > u64(max(u32)) {
		return ops_write.Refused{index, .No_Spelling}
	}
	expecting_key := len(w.open) > 0 && w.open[len(w.open) - 1].object && !w.open[len(w.open) - 1].awaiting_val
	seq_kind := ops_write.Token_Kind.Key if expecting_key else .String
	if _, err := ops_write.sequence_take(&w.seq, seq_kind); err != nil {
		return err
	}
	w.pending_dt = false
	count_child(w, expecting_key)
	if len(w.open) > 0 {
		w.open[len(w.open) - 1].awaiting_val = expecting_key
	}
	lo := u64(len(w.data))
	append(&w.data, ..payload) or_return
	role := tape.Role.Key if expecting_key else .Value
	spelling := tape.SPELLING_DECODE if expecting_key else u16(0)
	append(&w.nodes, tape.Node{lo = lo, n = u32(len(payload)), kind = .Bytes, role = role, spelling = spelling}) or_return
	return nil
}

// Writes a MessagePack `ext` item (`type` in `-128..127`) at the next value position.
@(require_results)
ext :: proc(w: ^Writer, ext_type: i8, payload: []u8) -> Write_Error {
	index := tape.Node_Index(w.seq.taken)
	if u64(len(payload)) > u64(max(u32)) {
		return ops_write.Refused{index, .No_Spelling}
	}
	if ext_type == -1 {
		if _, _, ok := timestamp_decode(payload); !ok {
			return ops_write.Refused{index, .No_Spelling}
		}
	}
	if _, err := ops_write.sequence_take(&w.seq, .String); err != nil {
		return err
	}
	w.pending_dt = false
	count_child(w, false)
	if len(w.open) > 0 {
		w.open[len(w.open) - 1].awaiting_val = false
	}
	node_idx := tape.Node_Index(len(w.nodes))
	head_lo := u64(len(w.data))
	append_ext_head_bytes(&w.data, ext_type, u32(len(payload))) or_return
	head_len := u64(len(w.data)) - head_lo
	pay_lo := u64(len(w.data))
	append(&w.data, ..payload) or_return
	append(&w.facts, tape.Fact{lo = head_lo, n = u32(head_len), node = node_idx, kind = .Tag}) or_return
	vkind := tape.Kind.String if ext_type == -1 else .Bytes
	vspell := head_spelling(head_len) | STR_EXT | (tape.SPELLING_DECODE | tape.SPELLING_LAX | STR_TIMESTAMP if ext_type == -1 else 0)
	append(&w.nodes, tape.Node{lo = pay_lo, n = u32(len(payload)), kind = vkind, role = .Value, spelling = vspell}) or_return
	return nil
}

// Writes a MessagePack Timestamp (`ext -1`) encoded in shortest 32/64/96-bit form.
@(require_results)
timestamp :: proc(w: ^Writer, sec: i64, nsec: u32 = 0) -> Write_Error {
	index := tape.Node_Index(w.seq.taken)
	if nsec > 999_999_999 {
		return ops_write.Refused{index, .No_Spelling}
	}
	if _, err := ops_write.sequence_take(&w.seq, .String); err != nil {
		return err
	}
	w.pending_dt = false
	count_child(w, false)
	if len(w.open) > 0 {
		w.open[len(w.open) - 1].awaiting_val = false
	}
	node_idx := tape.Node_Index(len(w.nodes))
	push_timestamp_bytes(w, node_idx, sec, nsec) or_return
	return nil
}

// Finishes `w`, returning the encoded MessagePack buffer (or nil for a sink writer).
@(require_results)
writer_end :: proc(w: ^Writer) -> (item: []u8, err: Write_Error) {
	defer writer_drop(w)
	if !ops_write.sequence_done(&w.seq) {
		return nil, ops_write.Refused{tape.Node_Index(w.seq.taken), .Malformed}
	}
	present := tape.Facts{.Tag} if len(w.facts) > 0 else tape.Facts{}
	doc := tape.Document {
		src       = w.data[:],
		nodes     = w.nodes[:],
		facts     = w.facts[:],
		counts    = w.counts[:],
		present   = present,
		format    = as(w.spec),
		allocator = w.allocator,
	}
	if w.sink.procedure != nil {
		_, err = write_to(w.sink, &doc, w.spec, w.opts, w.allocator)
		return nil, err
	}
	item, _, err = write(&doc, w.spec, w.opts, w.allocator)
	return item, err
}

// Frees all buffers owned by `w` without producing output.
writer_drop :: proc(w: ^Writer) {
	ops_write.sequence_drop(&w.seq)
	delete(w.nodes)
	delete(w.data)
	delete(w.facts)
	delete(w.counts)
	delete(w.open)
	w^ = {}
}

@(private)
count_child :: #force_inline proc "contextless" (w: ^Writer, is_key: bool) {
	if len(w.open) > 0 && w.open[len(w.open) - 1].object == is_key {
		w.open[len(w.open) - 1].children += 1
	}
}

@(private)
push_timestamp_bytes :: proc(w: ^Writer, node_idx: tape.Node_Index, sec: i64, nsec: u32) -> runtime.Allocator_Error {
	head_lo := u64(len(w.data))
	buf: [15]u8 = ---
	total, head_len := encode_timestamp(&buf[0], sec, nsec)
	append(&w.data, ..buf[:total]) or_return
	pay_lo := head_lo + u64(head_len)
	pay_len := u64(total - head_len)
	append(&w.facts, tape.Fact{lo = head_lo, n = u32(head_len), node = node_idx, kind = .Tag}) or_return
	append(&w.nodes, tape.Node {
		lo       = pay_lo,
		n        = u32(pay_len),
		kind     = .String,
		role     = .Value,
		spelling = head_spelling(u64(head_len)) | tape.SPELLING_DECODE | tape.SPELLING_LAX | STR_EXT | STR_TIMESTAMP,
	}) or_return
	return nil
}

@(private)
append_ext_head_bytes :: proc(dst: ^[dynamic]u8, ext_type: i8, n: u32) -> runtime.Allocator_Error {
	buf: [6]u8 = ---
	k := encode_ext_head(&buf[0], ext_type, n)
	_, err := append(dst, ..buf[:k])
	return err
}

// Parses a token `.Number` string into a `spell.Number`, allowing `"NaN"`, `"Inf"`, `"+Inf"`, `"-Inf"`
// alongside finite JSON numbers within 64-bit integer or IEEE binary64 range.
@(private)
parse_token_number :: proc "contextless" (text: string) -> (spell.Number, bool) {
	switch text {
	case "NaN":
		return {transmute(u64)math.nan_f64(), .Float}, true
	case "Inf", "+Inf":
		return {transmute(u64)math.inf_f64(1), .Float}, true
	case "-Inf":
		return {transmute(u64)math.inf_f64(-1), .Float}, true
	}
	if !ops_write.is_json_number(transmute([]u8)text) {
		return {}, false
	}
	num, ok := spell.number_strict(transmute([]u8)text, 0, u64(len(text)))
	if !ok || num.kind == .Wide {
		return {}, false
	}
	if num.kind == .Float {
		f := transmute(f64)num.bits
		if math.is_nan(f) || math.is_inf(f) {
			return {}, false
		}
	}
	return num, true
}

@(private)
put_compact_number_bytes :: proc(dst: ^[dynamic]u8, n: spell.Number) -> runtime.Allocator_Error {
	buf: [9]u8 = ---
	k: int
	#partial switch n.kind {
	case .Int:
		k = encode_i64(&buf[0], i64(n.bits))
	case .Uint:
		k = encode_u64(&buf[0], n.bits)
	case .Float:
		k = encode_float_bits(&buf[0], n.bits)
	case:
		return nil
	}
	_, err := append(dst, ..buf[:k])
	return err
}
