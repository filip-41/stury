package cli

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:engine"
import "stury:lib/core/tape"
import "stury:lib/query"

DEFAULT_COLORS :: [8]string{"\e[0;90m", "\e[0;39m", "\e[0;39m", "\e[0;39m", "\e[0;32m", "\e[1;39m", "\e[1;39m", "\e[1;34m"}
ANSI_RESET :: "\e[0m"
TOO_DEEP_TEXT :: "<skipped: too deep>"
STREAM_CHUNK_FLUSH :: 32 * 1024

Render_Config :: struct {
	raw:          bool,
	join:         bool,
	raw0:         bool,
	compact:      bool,
	tab:          bool,
	sort_keys:    bool,
	ascii:        bool,
	seq:          bool,
	color:        bool,
	to_non_json:  bool,
	to_tabular:   bool,
	to_render:    Output_Render,
	one_doc:      bool,
	grow_header:  bool,
	indent:       i8,
	colors:       [8]string,
	colors_owned: [8]bool,
	to_spec:      engine.Spec,
	to_framing:   engine.Framing,
	to_name:      string,
	write_opts:   engine.Write_Options,
	dsv_out:      tape.Dsv_Options,
	docs_emitted: u64,
}

@(private = "file", rodata)
RENDER_TAG_TABLE := [1]string{"table"}
@(private = "file", rodata)
RENDER_TAG_MARKDOWN := [1]string{"markdown"}

make_write_opts :: proc(o: ^Options, sp: engine.Spec, indent_val: i8) -> engine.Write_Options {
	if sp == nil {
		if o.to_render == .Table {
			return {indent = 0 if o.compact else 1, sort_keys = o.sort_keys, grow_header = o.dsv_out.no_header, header = RENDER_TAG_TABLE[:]}
		}
		if o.to_render == .Markdown {
			return {indent = 0 if o.compact else 1, sort_keys = o.sort_keys, header = RENDER_TAG_MARKDOWN[:]}
		}
		return {}
	}
	e, ok := engine.entry_of_spec(sp)
	if !ok { return {} }
	ind := u8(0) if o.compact else u8(max(indent_val, 0))
	tab := o.tab && !o.compact
	switch e.family {
	case .Json:
		fr := engine.Write_Record_Framing.Seq if (o.seq || o.to_framing == .Seq) else (.Lines if (o.to_framing == .Lines && (o.compact || o.to_name == "ndjson")) else .None)
		return {indent = ind, tab = tab, sort_keys = o.sort_keys, ascii = o.ascii, framing = fr}
	case .Toml:    return {indent = ind, tab = tab, sort_keys = o.sort_keys}
	case .Xml:     return {indent = ind, tab = tab}
	case .Dsv:     return {sort_keys = o.sort_keys, grow_header = o.grow_header, format = o.dsv_out if o.dsv_out_set else nil}
	case .Cbor, .Msgpack: return {sort_keys = o.sort_keys}
	case .Yaml:    return {indent = ind, tab = tab, sort_keys = o.sort_keys, format = tape.Yaml_Options{dialect = o.yaml_schema} if o.yaml_schema_set else nil}
	case .Html:    return {indent = ind, tab = tab, ascii = o.ascii}
	}
	return {}
}

write_doc_render_to :: proc(sink_w: io.Writer, doc: ^tape.Document, kind: Output_Render, sort_keys, compact, no_header: bool, node: tape.Node_Index, alloc: runtime.Allocator) -> engine.Write_Error {
	switch kind {
	case .Table:    return engine.write_table_to(sink_w, doc, {node = node, style = .Compact if compact else .Plain, sort_keys = sort_keys, no_header = no_header}, alloc)
	case .Markdown: return engine.write_markdown_to(sink_w, doc, {node = node, sort_keys = sort_keys, compact = compact}, alloc)
	case .None:
	}
	return tape.Bad_Option{"to"}
}

write_doc_render :: proc(doc: ^tape.Document, kind: Output_Render, sort_keys, compact, no_header: bool, node: tape.Node_Index, alloc: runtime.Allocator) -> ([]u8, engine.Write_Error) {
	switch kind {
	case .Table:    return engine.write_table(doc, {node = node, style = .Compact if compact else .Plain, sort_keys = sort_keys, no_header = no_header}, alloc)
	case .Markdown: return engine.write_markdown(doc, {node = node, sort_keys = sort_keys, compact = compact}, alloc)
	case .None:
	}
	return nil, tape.Bad_Option{"to"}
}

// Parses `$JQ_COLORS` as jq's `jq_set_colors`.
parse_jq_colors :: proc(spec: string, alloc: runtime.Allocator) -> (colors: [8]string, owned: [8]bool, ok: bool) {
	colors = DEFAULT_COLORS
	if spec == "" { return colors, owned, true }
	codes: [8]string
	n, rest := 0, spec
	for {
		span := 0
		for span < len(rest) && (rest[span] == ';' || ('0' <= rest[span] && rest[span] <= '9')) { span += 1 }
		codes[n], rest = rest[:span], rest[span:]
		if len(rest) == 0 || n + 1 == len(codes) { break }
		if rest[0] != ':' { return DEFAULT_COLORS, {}, false }
		rest = rest[1:]
		n += 1
	}
	if codes[n] != "" { n += 1 }
	for k in 0 ..< n {
		colors[k], owned[k] = fmt.aprintf("\e[%sm", codes[k], allocator = alloc), true
	}
	return colors, owned, true
}

render_config_destroy :: proc(cfg: ^Render_Config, alloc: runtime.Allocator) {
	for owned, i in cfg.colors_owned {
		if owned { delete(cfg.colors[i], alloc) }
	}
	cfg.colors_owned = {}
}

where_prefix :: proc(b: ^strings.Builder, file: string, p: tape.Place) {
	if file != "" {
		strings.write_string(b, file)
		strings.write_byte(b, ':')
	}
	if p.line == 0 {
		fmt.sbprintf(b, "byte %d: ", p.byte)
	} else {
		fmt.sbprintf(b, "%d:%d: ", p.line, p.col)
	}
}

@(private = "file")
Key_Val :: struct { k, v: query.Value }

@(private = "file")
Render_Frame :: struct {
	v:      query.Value,
	c:      query.Cursor,
	sorted: [dynamic]Key_Val,
	i:      int,
	first:  bool,
	object: bool,
}

@(private = "file")
color_wrap :: proc(out: ^[dynamic]u8, cfg: ^Render_Config, slot: int, open: bool) {
	if cfg.color { append(out, cfg.colors[slot] if open else ANSI_RESET) }
}

@(private = "file")
append_colored :: proc(out: ^[dynamic]u8, cfg: ^Render_Config, slot: int, text: string) {
	color_wrap(out, cfg, slot, true)
	append(out, text)
	color_wrap(out, cfg, slot, false)
}

jq_double :: proc(buf: []u8, f: f64) -> string {
	if math.is_nan(f) { return "null" }
	x := clamp(f, -max(f64), max(f64))
	n := 0
	if x < 0 || (x == 0 && (transmute(u64)x >> 63) != 0) {
		if x != 0 { buf[0] = '-'; n = 1 }
		x = -x
	}
	if x == 0 {
		buf[n] = '0'
		return string(buf[:n + 1])
	}
	digits: [17]u8
	count, point := query.double_digits(x, &digits)
	if point <= -4 || point > count + 15 {
		buf[n] = digits[0]
		n += 1
		if count > 1 {
			buf[n] = '.'
			copy(buf[n + 1:], digits[1:count])
			n += count
		}
		e := point - 1
		buf[n], buf[n + 1] = 'e', '-' if e < 0 else '+'
		n += 2
		ea := abs(e)
		if ea < 10 { buf[n] = '0'; n += 1 }
		tmp: [8]u8
		es := strconv.write_int(tmp[:], i64(ea), 10)
		copy(buf[n:], es)
		return string(buf[:n + len(es)])
	}
	if point <= 0 {
		buf[n], buf[n + 1] = '0', '.'
		n += 2
		for _ in 0 ..< -point { buf[n] = '0'; n += 1 }
		copy(buf[n:], digits[:count])
		return string(buf[:n + count])
	}
	if point >= count {
		copy(buf[n:], digits[:count])
		n += count
		for _ in 0 ..< point - count { buf[n] = '0'; n += 1 }
		return string(buf[:n])
	}
	copy(buf[n:], digits[:point])
	n += point
	buf[n] = '.'
	copy(buf[n + 1:], digits[point:count])
	return string(buf[:n + 1 + count - point])
}

@(private = "file")
append_indent_nl :: proc(out: ^[dynamic]u8, cfg: ^Render_Config, depth: int) {
	if cfg.compact { return }
	append(out, '\n')
	if cfg.tab {
		for _ in 0 ..< depth { append(out, '\t') }
		return
	}
	for _ in 0 ..< depth * int(max(cfg.indent, 0)) { append(out, ' ') }
}

@(private = "file")
write_json_scalar :: proc(h: ^query.Heap, out: ^[dynamic]u8, v: query.Value, cfg: ^Render_Config) -> query.Status {
	#partial switch query.type_of(v) {
	case .Absent, .Null: append_colored(out, cfg, 0, "null")
	case .False:         append_colored(out, cfg, 1, "false")
	case .True:          append_colored(out, cfg, 2, "true")
	case .String:
		color_wrap(out, cfg, 4, true)
		st := query.write_text(h, out, query.text_of(v), cfg.ascii)
		color_wrap(out, cfg, 4, false)
		return st
	case .Number:
		if v.kind == .Double && math.is_nan(v.f) {
			append_colored(out, cfg, 0, "null")
			return .Ok
		}
		color_wrap(out, cfg, 3, true)
		st := query.write_json(h, out, v, {double = jq_double})
		color_wrap(out, cfg, 3, false)
		return st
	}
	return .Ok
}

render_value_to_emitter :: proc(
	h: ^query.Heap,
	v: query.Value,
	cfg: ^Render_Config,
	prefix: []u8,
	scratch: ^[dynamic]u8,
	emit: engine.Emitter,
	stream_chunks: bool,
	nul_err: ^bool,
) -> (st: query.Status, stopped: bool) {
	clear(scratch)
	if len(prefix) > 0 { append(scratch, ..prefix) }
	if cfg.raw && query.type_of(v) == .String {
		txt := query.text_of(v)
		if cfg.ascii {
			if st = query.write_text(h, scratch, txt, true); st != .Ok { return st, false }
		} else {
			if cfg.raw0 && strings.index_byte(txt, 0) >= 0 {
				nul_err^ = true
				return .Error, false
			}
			append(scratch, txt)
		}
	} else {
		if cfg.seq { append(scratch, 0x1e) }
		if t := query.type_of(v); t != .Array && t != .Object {
			if st = write_json_scalar(h, scratch, v, cfg); st != .Ok { return st, false }
		} else {
			stack := make([dynamic]Render_Frame, 0, 8, h.allocator)
			defer {
				for &f in stack { drop_render_frame(h, &f) }
				delete(stack)
			}
			if st = open_render_container(h, scratch, &stack, query.retain(v), cfg); st != .Ok { return st, false }
			depth_cap := query.depth_limit(h)
			for len(stack) > 0 {
				if stream_chunks && emit.fn != nil && len(scratch) >= STREAM_CHUNK_FLUSH {
					if !engine.emit_bytes(emit, scratch[:]) { return .Ok, true }
					clear(scratch)
				}
				f := &stack[len(stack) - 1]
				k, x: query.Value
				more: bool
				if f.sorted != nil {
					if more = f.i < len(f.sorted); more {
						kv := f.sorted[f.i]
						k, x = query.retain(kv.k), query.retain(kv.v)
						f.i += 1
					}
				} else {
					ns: query.Status
					k, x, more, ns = query.cursor_next(h, &f.c)
					if ns != .Ok { return ns, false }
				}
				cslot := 6 if f.object else 5
				if !more {
					if !f.first { append_indent_nl(scratch, cfg, len(stack) - 1) }
					append_colored(scratch, cfg, cslot, "}" if f.object else "]")
					drop_render_frame(h, f)
					pop(&stack)
					continue
				}
				if !f.first { append_colored(scratch, cfg, cslot, ",") }
				f.first = false
				append_indent_nl(scratch, cfg, len(stack))
				if f.object {
					color_wrap(scratch, cfg, 7, true)
					st = query.write_text(h, scratch, query.text_of(k), cfg.ascii)
					color_wrap(scratch, cfg, 7, false)
					query.release(h, k)
					if st != .Ok {
						query.release(h, x)
						return st, false
					}
					append_colored(scratch, cfg, 6, ":")
					if !cfg.compact { append(scratch, ' ') }
				}
				if xt := query.type_of(x); xt == .Array || xt == .Object {
					if len(stack) > depth_cap {
						query.release(h, x)
						append(scratch, TOO_DEEP_TEXT)
						continue
					}
					if st = open_render_container(h, scratch, &stack, x, cfg); st != .Ok { return st, false }
					continue
				}
				st = write_json_scalar(h, scratch, x, cfg)
				query.release(h, x)
				if st != .Ok { return st, false }
			}
		}
	}
	if cfg.raw0 {
		append(scratch, 0)
	} else if !cfg.join {
		append(scratch, '\n')
	}
	if len(scratch) > 0 && !engine.emit_bytes(emit, scratch[:]) {
		return .Ok, true
	}
	return .Ok, false
}

@(private = "file")
drop_render_frame :: proc(h: ^query.Heap, f: ^Render_Frame) {
	query.cursor_close(&f.c)
	for kv in f.sorted {
		query.release(h, kv.k)
		query.release(h, kv.v)
	}
	delete(f.sorted)
	query.release(h, f.v)
	f^ = {}
}

@(private = "file")
open_render_container :: proc(h: ^query.Heap, out: ^[dynamic]u8, stack: ^[dynamic]Render_Frame, v: query.Value, cfg: ^Render_Config) -> query.Status {
	object := query.type_of(v) == .Object
	cslot := 6 if object else 5
	if query.length_of(h, v) == 0 {
		query.release(h, v)
		append_colored(out, cfg, cslot, "{}" if object else "[]")
		return .Ok
	}
	append_colored(out, cfg, cslot, "{" if object else "[")
	f := Render_Frame{v = v, first = true, object = object}
	if object && cfg.sort_keys {
		c := query.cursor_open(h, v) or_return
		defer query.cursor_close(&c)
		f.sorted = make([dynamic]Key_Val, 0, max(query.length_of(h, v), 0), h.allocator)
		for {
			k, x, more, ns := query.cursor_next(h, &c)
			if ns != .Ok {
				drop_render_frame(h, &f)
				return ns
			}
			if !more { break }
			append(&f.sorted, Key_Val{k, x})
		}
		slice.sort_by(f.sorted[:], proc(a, b: Key_Val) -> bool { return query.text_of(a.k) < query.text_of(b.k) })
	} else {
		f.c = query.cursor_open(h, v) or_return
	}
	append(stack, f)
	return .Ok
}

// Unified iterative walker emitting tokens from `root` to `sink`.
value_emit_tokens :: proc(
	h: ^query.Heap,
	root: query.Value,
	sink: rawptr,
	take: proc(sink: rawptr, kind: engine.Write_Token_Kind, text: string) -> engine.Write_Error,
) -> bool {
	Task :: struct {
		close: bool,
		k, v:  query.Value,
	}
	stack := make([dynamic]Task, 0, 16, h.allocator)
	defer {
		for item in stack { query.release(h, item.k); query.release(h, item.v) }
		delete(stack)
	}
	num_buf := make([dynamic]u8, 0, 32, h.allocator)
	defer delete(num_buf)
	append(&stack, Task{v = query.retain(root)})
	for len(stack) > 0 {
		t := pop(&stack)
		if t.close {
			if take(sink, .Close, "") != nil { return false }
			continue
		}
		if t.k.kind != .Absent {
			ok := take(sink, .Key, query.text_of(t.k)) == nil
			query.release(h, t.k)
			if !ok { query.release(h, t.v); return false }
		}
		v := t.v
		defer query.release(h, v)
		#partial switch query.type_of(v) {
		case .Absent, .Null: if take(sink, .Null, "") != nil { return false }
		case .False:         if take(sink, .False, "") != nil { return false }
		case .True:          if take(sink, .True, "") != nil { return false }
		case .String:        if take(sink, .String, query.text_of(v)) != nil { return false }
		case .Number:
			clear(&num_buf)
			if query.write_json(h, &num_buf, v, {double = jq_double}) != .Ok || take(sink, .Number, string(num_buf[:])) != nil {
				return false
			}
		case .Array, .Object:
			is_obj := query.type_of(v) == .Object
			if take(sink, .Object if is_obj else .Array, "") != nil { return false }
			c, cs := query.cursor_open(h, v)
			if cs != .Ok { return false }
			defer query.cursor_close(&c)
			ch := make([dynamic]Task, 0, 8, h.allocator)
			defer delete(ch)
			for {
				ck, cx, more, ns := query.cursor_next(h, &c)
				if ns != .Ok {
					for item in ch { query.release(h, item.k); query.release(h, item.v) }
					return false
				}
				if !more { break }
				append(&ch, Task{k = ck if is_obj else query.ABSENT, v = cx})
				if !is_obj { query.release(h, ck) }
			}
			append(&stack, Task{close = true})
			#reverse for item in ch { append(&stack, item) }
		}
	}
	return true
}

@(private = "file")
token_tape_sink :: proc(sink: rawptr, kind: engine.Write_Token_Kind, text: string) -> engine.Write_Error {
	return engine.token_tape_take((^engine.Write_Token_Tape)(sink), kind, text)
}

@(private = "file")
table_writer_sink :: proc(sink: rawptr, kind: engine.Write_Token_Kind, text: string) -> engine.Write_Error {
	return engine.table_writer_token((^engine.Write_Table_Writer)(sink), kind, text)
}

write_table_row :: proc(h: ^query.Heap, v: query.Value, tw: ^engine.Write_Table_Writer) -> bool {
	return value_emit_tokens(h, v, tw, table_writer_sink)
}

// Unified streaming collector for `--to table` and `--to markdown`.
Render_Table_Writer :: struct {
	kind:      Output_Render,
	sort_keys: bool,
	compact:   bool,
	no_header: bool,
	tokens:    engine.Write_Token_Tape,
	count:     u64,
	failed:    bool,
	err:       engine.Write_Error,
	sink:      io.Writer,
	allocator: runtime.Allocator,
}

render_table_writer_start :: proc(rtw: ^Render_Table_Writer, kind: Output_Render, o: ^Options, sink_w: io.Writer, alloc: runtime.Allocator) -> bool {
	rtw^ = {kind = kind, sort_keys = o.sort_keys, compact = o.compact, no_header = o.dsv_out.no_header, sink = sink_w, allocator = alloc}
	if kind != .Table && kind != .Markdown {
		rtw.err = tape.Bad_Option{"to"}
		return false
	}
	if err := engine.token_tape_start(&rtw.tokens, true, 0, alloc); err != nil {
		rtw.err, rtw.kind = err, .None
		return false
	}
	return true
}

render_table_writer_value :: proc(rtw: ^Render_Table_Writer, h: ^query.Heap, v: query.Value) -> bool {
	if rtw.failed { return false }
	sink :: proc(s: rawptr, kind: engine.Write_Token_Kind, text: string) -> engine.Write_Error {
		r := (^Render_Table_Writer)(s)
		err := engine.token_tape_take(&r.tokens, kind, text)
		if err != nil { r.err = err }
		return err
	}
	if !value_emit_tokens(h, v, rtw, sink) {
		rtw.failed = true
		return false
	}
	rtw.count += 1
	return true
}

render_table_writer_drop :: proc(rtw: ^Render_Table_Writer) {
	if rtw == nil { return }
	engine.token_tape_drop(&rtw.tokens)
	rtw^ = {}
}

render_table_writer_end :: proc(rtw: ^Render_Table_Writer) -> engine.Write_Error {
	if rtw == nil { return nil }
	defer render_table_writer_drop(rtw)
	if rtw.failed || rtw.count == 0 { return nil }
	if !engine.token_tape_done(&rtw.tokens) {
		return engine.Write_Refused{tape.Node_Index(rtw.tokens.seq.taken), .Malformed}
	}
	doc := engine.token_tape_document(&rtw.tokens) or_return
	return write_doc_render_to(rtw.sink, &doc, rtw.kind, rtw.sort_keys, rtw.compact, rtw.no_header, tape.Node_Index(1) if rtw.count == 1 else tape.ROOT, rtw.allocator)
}

@(private = "file")
emit_doc_direct :: proc(doc: ^tape.Document, to: engine.Spec, wopts: engine.Write_Options, out: ^[dynamic]u8, sink_w: io.Writer, alloc: runtime.Allocator) -> (ok, refused: bool, msg: string) {
	if sink_w.procedure != nil {
		_, werr := engine.write_to(sink_w, doc, to, wopts, alloc)
		if werr == nil { return true, false, "" }
		if _, is_r := werr.(engine.Write_Refused); is_r { return false, true, "" }
		return false, false, write_error_string(werr, alloc)
	}
	text, _, werr := engine.write(doc, to, wopts, alloc)
	if werr == nil {
		defer delete(text, alloc)
		append(out, ..text)
		return true, false, ""
	}
	if _, is_r := werr.(engine.Write_Refused); is_r { return false, true, "" }
	return false, false, write_error_string(werr, alloc)
}

write_value_as_format :: proc(
	h: ^query.Heap,
	v: query.Value,
	to: engine.Spec,
	wopts: engine.Write_Options,
	out: ^[dynamic]u8,
	sink_w: io.Writer,
	max_depth: int,
	alloc: runtime.Allocator,
) -> (bool, string) {
	rkind := Output_Render.None
	if to == nil && len(wopts.header) == 1 {
		rkind = .Table if wopts.header[0] == "table" else .Markdown if wopts.header[0] == "markdown" else .None
	}
	if rkind == .None {
		entry, found := engine.entry_of_spec(to)
		if !wopts.sort_keys && !wopts.ascii && found && !entry.tabular {
			ov_ob := (^query.Overlay_Block)(v.p) if v.kind == .Overlay else (^query.Overlay_Block)(h.write_fact_data)
			if ov_ob != nil && ov_ob.ov != nil && ov_ob.ov.base != nil && entry.format == ov_ob.ov.base.format {
				if v.kind == .Overlay && !ov_ob.ov.dirty && ov_ob.doc_block != nil {
					if en, ok := engine.edit_get_node_by_idx(ov_ob.ov, v.n); ok && en.base != tape.NO_NODE {
						lo := wopts
						lo.node = en.base
						if dok, ref, dmsg := emit_doc_direct(&ov_ob.doc_block.doc, to, lo, out, sink_w, alloc); dok || !ref {
							return dok, dmsg
						}
					}
				} else if ov_ob.ov.dirty || v.kind == .Overlay {
					yopts, _ := wopts.format.(tape.Yaml_Options)
					if cres, cerr := engine.reconcile_edit(h, ov_ob.ov, v, to, {indent = wopts.indent, tab = wopts.tab}, alloc, yopts); cerr == nil {
						defer engine.destroy_commit_result(&cres)
						if sink_w.procedure != nil {
							if write_all_to(sink_w, cres.bytes) { return true, "" }
							return false, strings.clone("writing output failed", alloc)
						}
						append(out, ..cres.bytes)
						return true, ""
					}
				}
			}
			if v.kind == .Node {
				if db := (^query.Doc_Block)(v.p); db != nil {
					lo := wopts
					lo.node = tape.Node_Index(v.n)
					if dok, ref, dmsg := emit_doc_direct(&db.doc, to, lo, out, sink_w, alloc); dok || !ref {
						return dok, dmsg
					}
				}
			}
		}
	}

	tt: engine.Write_Token_Tape
	if engine.token_tape_start(&tt, false, max_depth, alloc) != nil {
		return false, strings.clone("out of memory", alloc)
	}
	defer engine.token_tape_drop(&tt)
	if !value_emit_tokens(h, v, &tt, token_tape_sink) {
		return false, strings.clone("cannot serialize value", alloc)
	}
	doc, derr := engine.token_tape_document(&tt)
	if derr != nil {
		return false, strings.clone("out of memory", alloc)
	}
	if rkind != .None {
		if sink_w.procedure != nil {
			if werr := write_doc_render_to(sink_w, &doc, rkind, wopts.sort_keys, wopts.indent == 0, wopts.grow_header, tape.ROOT, alloc); werr != nil {
				return false, write_error_string(werr, alloc)
			}
			return true, ""
		}
		text, werr := write_doc_render(&doc, rkind, wopts.sort_keys, wopts.indent == 0, wopts.grow_header, tape.ROOT, alloc)
		if werr != nil { return false, write_error_string(werr, alloc) }
		defer delete(text, alloc)
		append(out, ..text)
		return true, ""
	}
	if sink_w.procedure != nil {
		if _, werr := engine.write_to(sink_w, &doc, to, wopts, alloc); werr != nil {
			return false, write_error_string(werr, alloc)
		}
		return true, ""
	}
	text, _, werr := engine.write(&doc, to, wopts, alloc)
	if werr != nil { return false, write_error_string(werr, alloc) }
	defer delete(text, alloc)
	append(out, ..text)
	return true, ""
}

write_all_to :: proc(w: io.Writer, b: []u8) -> bool {
	for left := b; len(left) > 0; {
		wrote, err := io.write(w, left)
		if err != .None || wrote <= 0 { return false }
		left = left[wrote:]
	}
	return true
}

write_error_string :: proc(werr: engine.Write_Error, alloc: runtime.Allocator) -> string {
	#partial switch e in werr {
	case engine.Write_Refused:
		msgs := [engine.Write_Refusal]string{
			.No_Spelling = "value cannot be spelled in target format",
			.Not_A_Table = "target format requires an array of table rows",
			.Row_Keys    = "row keys do not match table header",
			.Partial     = "cannot write partial value",
			.Malformed   = "malformed output sequence",
		}
		return strings.clone(msgs[e.why], alloc)
	case tape.Bad_Option:
		return fmt.aprintf("invalid option: %s", e.option, allocator = alloc)
	case runtime.Allocator_Error:
		return strings.clone("out of memory", alloc)
	case io.Error:
		return fmt.aprintf("I/O error: %v", e, allocator = alloc)
	}
	return strings.clone("write failed", alloc)
}
