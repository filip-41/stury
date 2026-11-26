package engine

import "base:runtime"
import "core:strconv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/query"

// Hint 2: `.Projection_Direct` directly scans demanded leaf fields and writes compact JSON/CSV/TSV
// rows straight to `opts.emit` with zero evaluator invocation.
// Defers CSV/TSV header emission until after the first valid record/document succeeds formatting.
@(private)
exec_projection_direct :: proc(plan: ^query.Plan, dec: ^Decision, src: []u8, opts: ^Exec_Options) -> Exec_Result {
	pr := &plan.hints.projection
	if pr.shape == .None || len(pr.fields) == 0 || dups_needs_build(dec.entry, opts.read.dups) {
		return exec_whole(dec, src, opts) if dec.framing == .Single else exec_records(plan, dec, src, opts, dec.parallel)
	}
	field_paths, fp_err := make([][]tape.Step, len(pr.fields), opts.allocator)
	if fp_err != nil {
		return {err = .No_Memory, read_err = fp_err}
	}
	defer delete(field_paths, opts.allocator)
	for f, i in pr.fields {
		field_paths[i] = f.path
	}
	dem, derr := tape.demand_of(field_paths, nil, nil, false, opts.allocator)
	if derr != nil {
		return {err = .No_Memory, read_err = derr}
	}
	defer tape.destroy_demand(&dem)

	row_buf := make([dynamic]u8, 0, 256, opts.allocator)
	defer delete(row_buf)
	hdr_buf := make([dynamic]u8, 0, 128, opts.allocator)
	defer delete(hdr_buf)
	res: Exec_Result
	need_header := opts.direct_csv_header && (opts.direct_out == .Csv || opts.direct_out == .Tsv)
	header_emitted := false

	tf, framed := to_tape_framing(dec.framing)
	if !framed {
		ro := build_tape_opts(opts, allow_parallel = false)
		doc, serr := scan(src, &dem, dec.spec, {}, ro, opts.allocator)
		if serr != nil {
			return {err = .No_Memory if is_alloc_err(serr) else .Read_Error, read_err = serr}
		}
		defer tape.destroy(&doc)

		ok, wrong, werr := emit_projected_doc(
			&doc,
			pr,
			opts.direct_out,
			need_header,
			&header_emitted,
			&hdr_buf,
			&row_buf,
			opts.emit,
			&res.emitted,
			opts.allocator,
		)
		if !ok {
			if wrong && opts.eval != nil {
				return exec_whole(dec, src, opts)
			}
			finish_projected_error(&res, werr, wrong)
			return res
		}
		res.records = 1
		return res
	}

	ro := build_tape_opts(opts, allow_parallel = dec.parallel && opts.runner != nil && opts.runner.threads > 0)
	recs, open_err_res, open_ok := open_framed_records(src, dec.spec, tf, ro, nil, opts)
	if !open_ok {
		return open_err_res
	}
	defer tape.destroy_records(recs)

	out_recs: [RECORD_BATCH_SIZE]tape.Record
	docs: [RECORD_BATCH_SIZE]tape.Document
	for {
		n := tape.records_scan(recs, &dem, out_recs[:], docs[:], {}, opts.allocator)
		if n == 0 {
			break
		}
		for i in 0 ..< n {
			r_info := out_recs[i]
			if r_info.err != nil {
				if !handle_bad_record(opts, src, r_info, &res) {
					return res
				}
				continue
			}
			raw := record_slice(src, r_info)
			res.records += 1
			ok, wrong, werr := emit_projected_doc(
				&docs[i],
				pr,
				opts.direct_out,
				need_header,
				&header_emitted,
				&hdr_buf,
				&row_buf,
				opts.emit,
				&res.emitted,
				opts.allocator,
			)
			if !ok {
				if wrong && opts.eval != nil && can_build_single_record(dec, raw) {
					meta := make_record_meta(opts, res.records - 1, r_info, raw)
					sub := exec_single_record_whole(dec, raw, meta, opts)
					res.emitted += sub.emitted
					if sub.err != .None {
						res.err = sub.err
						res.read_err = sub.read_err
						return res
					}
					continue
				}
				finish_projected_error(&res, werr, wrong)
				return res
			}
		}
	}
	if recs.err != nil {
		res.err = .No_Memory if is_alloc_err(recs.err) else .Read_Error
		res.read_err = recs.err
	}
	return res
}

@(private = "file")
finish_projected_error :: proc "contextless" (res: ^Exec_Result, werr: write.Error, wrong: bool) {
	if werr != nil {
		if aerr, is_a := werr.(runtime.Allocator_Error); is_a {
			res.err = .No_Memory
			res.read_err = aerr
		} else {
			res.err = .Write_Error
			res.write_err = werr
		}
	} else if wrong {
		res.err = .Failed
	} else {
		res.err = .Stopped
	}
}

@(private = "file")
write_direct_header :: proc(buf: ^[dynamic]u8, pr: ^query.Projection_Template, delim: u8) {
	clear(buf)
	idx_buf: [24]u8
	for f, i in pr.fields {
		if i > 0 {
			append(buf, delim)
		}
		name := f.key
		if len(name) == 0 && len(f.path) > 0 {
			#partial switch step in f.path[len(f.path) - 1] {
			case tape.Name:
				name = string(step)
			case tape.Index:
				name = strconv.write_int(idx_buf[:], i64(step), 10)
			}
		}
		append_dsv_escaped(buf, name, delim)
	}
}

@(private = "file")
emit_projected_doc :: proc(
	doc: ^tape.Document,
	pr: ^query.Projection_Template,
	mode: Direct_Output,
	need_header: bool,
	header_emitted: ^bool,
	hdr_buf: ^[dynamic]u8,
	buf: ^[dynamic]u8,
	emit: Emitter,
	emitted: ^u64,
	alloc: runtime.Allocator,
) -> (
	ok: bool,
	wrong_kind: bool,
	werr: write.Error,
) {
	r := tape.Reader{doc = doc}
	n_fields := len(pr.fields)
	for i in 0 ..< n_fields {
		_, p, has := tape.answer(r, i, 0)
		if !has {
			continue
		}
		if p == .Wrong_Kind || p == .Not_Loaded {
			return false, true, nil
		}
	}

	if mode == .Csv || mode == .Tsv {
		clear(buf)
		delim := u8('\t') if mode == .Tsv else u8(',')
		for i in 0 ..< n_fields {
			if i > 0 {
				append(buf, delim)
			}
			node, p, has := tape.answer(r, i, 0)
			if !has || p != .Found {
				continue
			}
			append_node_dsv_cell(buf, doc, node, delim, alloc) or_return
		}
		if need_header && !header_emitted^ {
			write_direct_header(hdr_buf, pr, delim)
			if !emit_bytes(emit, hdr_buf[:]) {
				return false, false, nil
			}
			emitted^ += 1
			header_emitted^ = true
		}
		if !emit_bytes(emit, buf[:]) {
			return false, false, nil
		}
		emitted^ += 1
		return true, false, nil
	}

	switch pr.shape {
	case .Single:
		clear(buf)
		node, p, has := tape.answer(r, 0, 0)
		if !has || p != .Found {
			append(buf, "null")
		} else {
			append_node_compact_json(buf, doc, node, alloc) or_return
		}
		if !emit_bytes(emit, buf[:]) {
			return false, false, nil
		}
		emitted^ += 1
	case .Stream:
		for i in 0 ..< n_fields {
			clear(buf)
			node, p, has := tape.answer(r, i, 0)
			if !has || p != .Found {
				append(buf, "null")
			} else {
				append_node_compact_json(buf, doc, node, alloc) or_return
			}
			if !emit_bytes(emit, buf[:]) {
				return false, false, nil
			}
			emitted^ += 1
		}
	case .Array:
		clear(buf)
		append(buf, '[')
		for i in 0 ..< n_fields {
			if i > 0 {
				append(buf, ',')
			}
			node, p, has := tape.answer(r, i, 0)
			if !has || p != .Found {
				append(buf, "null")
			} else {
				append_node_compact_json(buf, doc, node, alloc) or_return
			}
		}
		append(buf, ']')
		if !emit_bytes(emit, buf[:]) {
			return false, false, nil
		}
		emitted^ += 1
	case .Object:
		clear(buf)
		append(buf, '{')
		for f, i in pr.fields {
			if i > 0 {
				append(buf, ',')
			}
			append_json_string(buf, f.key)
			append(buf, ':')
			node, p, has := tape.answer(r, i, 0)
			if !has || p != .Found {
				append(buf, "null")
			} else {
				append_node_compact_json(buf, doc, node, alloc) or_return
			}
		}
		append(buf, '}')
		if !emit_bytes(emit, buf[:]) {
			return false, false, nil
		}
		emitted^ += 1
	case .None:
		return false, true, nil
	}
	return true, false, nil
}

// Appends node `node` of `doc` formatted as compact JSON into `buf` without extra copies where possible.
@(private = "file")
append_node_compact_json :: proc(buf: ^[dynamic]u8, doc: ^tape.Document, node: tape.Node_Index, alloc: runtime.Allocator) -> write.Error {
	if node == tape.NO_NODE || int(node) >= len(doc.nodes) {
		append(buf, "null")
		return nil
	}
	t := doc.nodes[node]
	if doc.format == nil || .Binary not_in doc.format.caps {
		#partial switch t.kind {
		case .Null:
			append(buf, "null")
			return nil
		case .False:
			append(buf, "false")
			return nil
		case .True:
			append(buf, "true")
			return nil
		case .String:
			if t.spelling & tape.SPELLING_DECODE == 0 && doc.format != nil && doc.format.name == "json" {
				raw := tape.span_bytes(doc, t.lo, t.n)
				append(buf, '"')
				append(buf, ..raw)
				append(buf, '"')
				return nil
			}
		case .Number:
			// Guard `NUMBER_KIND == 0` so tolerant `.Non_Finite` (`NaN`/`Infinity`) and JSON5 forms delegate to `json.write`.
			if doc.format != nil && doc.format.name == "json" && (t.spelling & (tape.SPELLING_DECODE | tape.NUMBER_KIND)) == 0 {
				raw := tape.span_bytes(doc, t.lo, t.n)
				append(buf, ..raw)
				return nil
			}
		}
	}
	text, _, err := json.write(doc, .Json, {node = node}, alloc)
	if err != nil {
		return err
	}
	defer delete(text, alloc)
	append(buf, ..text)
	return nil
}

@(private = "file")
append_node_dsv_cell :: proc(buf: ^[dynamic]u8, doc: ^tape.Document, node: tape.Node_Index, delim: u8, alloc: runtime.Allocator) -> write.Error {
	if node == tape.NO_NODE || int(node) >= len(doc.nodes) {
		return nil
	}
	t := doc.nodes[node]
	#partial switch t.kind {
	case .Null:
		return nil
	case .True:
		append(buf, "true")
		return nil
	case .False:
		append(buf, "false")
		return nil
	case .Number:
		is_binary := doc.format != nil && .Binary in doc.format.caps
		if !is_binary && (t.spelling & tape.NUMBER_KIND) == 0 && doc.format != nil && doc.format.name != "toml" && doc.format.name != "toml-1.1" {
			s := string(tape.span_bytes(doc, t.lo, t.n))
			append_dsv_escaped(buf, s, delim)
			return nil
		}
		text, _, err := json.write(doc, .Json, {node = node}, alloc)
		if err != nil {
			return err
		}
		defer delete(text, alloc)
		append_dsv_escaped(buf, string(text), delim)
		return nil
	case .String, .Plain, .Bytes:
		room := tape.text_room(doc, node)
		if room == 0 && doc.format != nil && .Binary not_in doc.format.caps {
			s := string(tape.span_bytes(doc, t.lo, t.n))
			append_dsv_escaped(buf, s, delim)
			return nil
		}
		tmp, merr := make([]u8, max(room, int(t.n), 64), alloc)
		if merr != nil {
			return merr
		}
		defer delete(tmp, alloc)
		if text, ok := tape.node_text(doc, node, tmp); ok {
			append_dsv_escaped(buf, text, delim)
			return nil
		}
	}
	return write.Refused{node = node, why = .No_Spelling}
}

@(private = "file")
append_dsv_escaped :: proc(buf: ^[dynamic]u8, s: string, delim: u8) {
	if delim == '\t' {
		for c in transmute([]u8)s {
			switch c {
			case '\t': append(buf, "\\t")
			case '\n': append(buf, "\\n")
			case '\r': append(buf, "\\r")
			case '\\': append(buf, "\\\\")
			case 0:    append(buf, "\\0")
			case:      append(buf, c)
			}
		}
		return
	}
	needs_quote := false
	for c in transmute([]u8)s {
		if c == delim || c == '"' || c == '\n' || c == '\r' {
			needs_quote = true
			break
		}
	}
	if !needs_quote {
		append(buf, s)
		return
	}
	append(buf, '"')
	for c in transmute([]u8)s {
		if c == '"' {
			append(buf, "\"\"")
		} else {
			append(buf, c)
		}
	}
	append(buf, '"')
}

@(private = "file")
append_json_string :: proc(buf: ^[dynamic]u8, s: string) {
	append(buf, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"':  append(buf, "\\\"")
		case '\\': append(buf, "\\\\")
		case '\b': append(buf, "\\b")
		case '\f': append(buf, "\\f")
		case '\n': append(buf, "\\n")
		case '\r': append(buf, "\\r")
		case '\t': append(buf, "\\t")
		case:
			if c < 0x20 {
				hex := "0123456789abcdef"
				append(buf, "\\u00")
				append(buf, hex[c >> 4], hex[c & 15])
			} else {
				append(buf, c)
			}
		}
	}
	append(buf, '"')
}
