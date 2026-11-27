package engine

import "base:runtime"
import "core:strconv"
import "stury:json"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import ops_build "stury:lib/ops/build"
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
		doc, serr := scan(src, &dem, dec.spec, {}, build_tape_opts(opts, allow_parallel = false), opts.allocator)
		if serr != nil {
			return {err = .No_Memory if is_alloc_err(serr) else .Read_Error, read_err = serr}
		}
		defer tape.destroy(&doc)

		ok, wrong, werr := emit_projected_doc(&doc, pr, opts.direct_out, need_header, &header_emitted, &hdr_buf, &row_buf, opts.emit, &res.emitted, opts.allocator, opts.direct_append_nl)
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
	if dec.parallel && ro.runner != nil && ro.runner.threads > 0 && dec.entry.family == .Json && (tf == .Lines || tf == .Seq) && ro.pieces == nil && len(src) >= max(RECORDS_PARALLEL_FROM, 4096) {
		if cres, handled := exec_direct_coarse_parallel(dec, src, tf, ro, pr, &dem, need_header, opts); handled {
			return cres
		}
	}

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
			ok, wrong, werr := emit_projected_doc(&docs[i], pr, opts.direct_out, need_header, &header_emitted, &hdr_buf, &row_buf, opts.emit, &res.emitted, opts.allocator, opts.direct_append_nl)
			if !ok {
				if wrong && opts.eval != nil && can_build_single_record(dec, raw) {
					sub := exec_single_record_whole(dec, raw, make_record_meta(opts, res.records - 1, r_info, raw), opts)
					merge_result(&res, sub)
					if sub.err != .None {
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
	} else {
		res.err = .Failed if wrong else .Stopped
	}
}

@(private = "file")
emit_direct_header :: proc(
	need_header: bool,
	header_emitted: ^bool,
	hdr_buf: ^[dynamic]u8,
	pr: ^query.Projection_Template,
	mode: Direct_Output,
	append_nl: bool,
	emit: Emitter,
	emitted: ^u64,
) -> bool {
	if !need_header || header_emitted^ {
		return true
	}
	delim := u8('\t') if mode == .Tsv else u8(',')
	clear(hdr_buf)
	idx_buf: [24]u8
	for f, i in pr.fields {
		if i > 0 {
			append(hdr_buf, delim)
		}
		name := f.key
		if len(name) == 0 && len(f.path) > 0 {
			#partial switch step in f.path[len(f.path) - 1] {
			case tape.Name:  name = string(step)
			case tape.Index: name = strconv.write_int(idx_buf[:], i64(step), 10)
			}
		}
		append_dsv_escaped(hdr_buf, name, delim)
	}
	if append_nl {
		append(hdr_buf, '\n')
	}
	if !emit_bytes(emit, hdr_buf[:]) {
		return false
	}
	emitted^ += 1
	header_emitted^ = true
	return true
}

@(private = "file")
Direct_Event_Kind :: enum u8 {
	Emit_Slice,
	Wrong_Kind,
	Bad_Record,
}

@(private = "file")
Direct_Event :: struct {
	kind:    Direct_Event_Kind,
	off, sz: int,
	count:   u64,
	recs:    u64,
	rec:     tape.Record,
}

@(private = "file")
Direct_Chunk_Slot :: struct {
	buf:          [dynamic]u8,
	events:       [dynamic]Direct_Event,
	records:      u64,
	emitted_rows: u64,
	err:          Exec_Error,
	read_err:     tape.Error,
	write_err:    write.Error,
}

@(private = "file")
exec_direct_coarse_parallel :: proc(
	dec: ^Decision,
	src: []u8,
	tf: tape.Framing,
	ro: tape.Options,
	pr: ^query.Projection_Template,
	dem: ^tape.Demand,
	need_header: bool,
	opts: ^Exec_Options,
) -> (res: Exec_Result, handled: bool) {
	jspec, is_json := dec.spec.(json.Spec)
	if !is_json {
		return {}, false
	}
	delim := u8('\n') if tf == .Lines else 0x1e
	chunks: [ops_build.MAX_RECORD_CHUNKS]ops_build.Record_Chunk = ---
	nc := ops_build.cut_delim_chunks(src, u64(spell.bom_length(src)), delim, ro.runner, chunks[:])
	if nc < 2 {
		return {}, false
	}
	slots, serr := make([]Direct_Chunk_Slot, nc, opts.allocator)
	if serr != nil {
		return {err = .No_Memory, read_err = serr}, true
	}
	defer {
		for &s in slots {
			delete(s.buf)
			delete(s.events)
		}
		delete(slots, opts.allocator)
	}

	Direct_Job :: struct {
		src:          []u8,
		tf:           tape.Framing,
		jspec:        json.Spec,
		ro:           tape.Options,
		pr:           ^query.Projection_Template,
		dem:          ^tape.Demand,
		opts:         ^Exec_Options,
		chunks:       []ops_build.Record_Chunk,
		slots:        []Direct_Chunk_Slot,
		alloc_wrap:   Locked_Allocator,
		scratch_wrap: Locked_Allocator,
		lock_scratch: bool,
	}

	job := Direct_Job{
		src          = src,
		tf           = tf,
		jspec        = jspec,
		ro           = ro,
		pr           = pr,
		dem          = dem,
		opts         = opts,
		chunks       = chunks[:nc],
		slots        = slots,
		lock_scratch = has_custom_scratch(ro.scratch),
	}
	locked_alloc_init(&job.alloc_wrap, opts.allocator)
	if job.lock_scratch {
		locked_alloc_init(&job.scratch_wrap, ro.scratch, force_lock = true)
	}

	run_chunk :: proc(arg: rawptr, k: int) {
		j := (^Direct_Job)(arg)
		lalloc := locked_allocator(&j.alloc_wrap)
		slot := &j.slots[k]
		c := j.chunks[k]
		slot.buf = make([dynamic]u8, 0, max(int(c.hi - c.lo) / 2, 256), lalloc)
		slot.events.allocator = lalloc

		chunk_ro := j.ro
		chunk_ro.runner = nil
		if j.lock_scratch {
			chunk_ro.scratch = locked_allocator(&j.scratch_wrap)
		}
		lr, base_off, oerr_k, oerr_v := open_json_chunk_records(j.src, c, k, j.tf, j.jspec, chunk_ro, j.opts)
		if oerr_k != .None {
			slot.err, slot.read_err = oerr_k, oerr_v
			return
		}
		defer tape.destroy_records(&lr)

		flushed := 0
		pending_rows, pending_recs := u64(0), u64(0)
		flush_pending :: proc(slot: ^Direct_Chunk_Slot, flushed: ^int, rows, recs: ^u64) -> bool {
			if len(slot.buf) > flushed^ || recs^ > 0 {
				if _, aerr := append(&slot.events, Direct_Event{kind = .Emit_Slice, off = flushed^, sz = len(slot.buf) - flushed^, count = rows^, recs = recs^}); aerr != nil {
					slot.err, slot.read_err = .No_Memory, aerr
					return false
				}
				flushed^, rows^, recs^ = len(slot.buf), 0, 0
			}
			return true
		}

		out_recs: [RECORD_BATCH_SIZE]tape.Record = ---
		docs: [RECORD_BATCH_SIZE]tape.Document = ---
		for {
			n := json.records_scan(&lr, j.dem, out_recs[:], docs[:], {}, lalloc)
			if n == 0 {
				break
			}
			for i in 0 ..< n {
				r_info := adjust_rec_offset(out_recs[i], base_off)
				if r_info.err != nil {
					if !flush_pending(slot, &flushed, &pending_rows, &pending_recs) {
						return
					}
					if _, aerr := append(&slot.events, Direct_Event{kind = .Bad_Record, rec = r_info}); aerr != nil {
						slot.err, slot.read_err = .No_Memory, aerr
						return
					}
					continue
				}
				row_start := len(slot.buf)
				row_count := u64(0)
				wrong, werr := format_projected_row(&docs[i], j.pr, j.opts.direct_out, &slot.buf, lalloc, j.opts.direct_append_nl, &row_count)
				if wrong {
					resize(&slot.buf, row_start)
					if !flush_pending(slot, &flushed, &pending_rows, &pending_recs) {
						return
					}
					if _, aerr := append(&slot.events, Direct_Event{kind = .Wrong_Kind, rec = r_info}); aerr != nil {
						slot.err, slot.read_err = .No_Memory, aerr
						return
					}
					continue
				}
				slot.records += 1
				pending_recs += 1
				if werr != nil {
					resize(&slot.buf, row_start)
					if len(slot.events) > 0 {
						_ = flush_pending(slot, &flushed, &pending_rows, &pending_recs)
					}
					if aerr, is_a := werr.(runtime.Allocator_Error); is_a {
						slot.err, slot.read_err = .No_Memory, aerr
					} else {
						slot.err, slot.write_err = .Write_Error, werr
					}
					return
				}
				slot.emitted_rows += row_count
				pending_rows += row_count
				if !j.opts.coalesce_emit && !flush_pending(slot, &flushed, &pending_rows, &pending_recs) {
					return
				}
			}
		}
		if len(slot.events) > 0 && !flush_pending(slot, &flushed, &pending_rows, &pending_recs) {
			return
		}
		if lr.err != nil {
			err_v := adjust_err_offset(lr.err, base_off)
			slot.err = .No_Memory if is_alloc_err(err_v) else .Read_Error
			slot.read_err = err_v
		}
	}

	tape.fan_each(ro.runner, nc, run_chunk, &job)

	hdr_buf := make([dynamic]u8, 0, 128, opts.allocator)
	defer delete(hdr_buf)
	header_emitted := false

	for &slot in slots {
		if len(slot.events) == 0 {
			if len(slot.buf) > 0 {
				if !emit_direct_header(need_header, &header_emitted, &hdr_buf, pr, opts.direct_out, opts.direct_append_nl, opts.emit, &res.emitted) ||
				   !emit_bytes(opts.emit, slot.buf[:]) {
					res.err = .Stopped
					return res, true
				}
				res.emitted += slot.emitted_rows
			}
			res.records += slot.records
		} else {
			for ev in slot.events {
				switch ev.kind {
				case .Emit_Slice:
					res.records += ev.recs
					if ev.sz > 0 {
						if !emit_direct_header(need_header, &header_emitted, &hdr_buf, pr, opts.direct_out, opts.direct_append_nl, opts.emit, &res.emitted) ||
						   !emit_bytes(opts.emit, slot.buf[ev.off:][:ev.sz]) {
							res.err = .Stopped
							return res, true
						}
						res.emitted += ev.count
					}
				case .Bad_Record:
					if !handle_bad_record(opts, src, ev.rec, &res) {
						return res, true
					}
				case .Wrong_Kind:
					raw := record_slice(src, ev.rec)
					rec_idx := res.records
					res.records += 1
					if opts.eval != nil && can_build_single_record(dec, raw) {
						if !emit_direct_header(need_header, &header_emitted, &hdr_buf, pr, opts.direct_out, opts.direct_append_nl, opts.emit, &res.emitted) {
							res.err = .Stopped
							return res, true
						}
						sub := exec_single_record_whole(dec, raw, make_record_meta(opts, rec_idx, ev.rec, raw), opts)
						merge_result(&res, sub)
						if sub.err != .None {
							return res, true
						}
						continue
					}
					finish_projected_error(&res, nil, true)
					return res, true
				}
			}
		}
		if slot.err != .None {
			res.err, res.read_err, res.write_err = slot.err, slot.read_err, slot.write_err
			return res, true
		}
	}
	return res, true
}

@(private = "file")
has_wrong_projected_field :: proc "contextless" (r: tape.Reader, n_fields: int) -> bool {
	for i in 0 ..< n_fields {
		if _, p, has := tape.answer(r, i, 0); has && (p == .Wrong_Kind || p == .Not_Loaded) {
			return true
		}
	}
	return false
}

@(private = "file")
append_answer_json :: proc(buf: ^[dynamic]u8, doc: ^tape.Document, r: tape.Reader, idx: int, alloc: runtime.Allocator) -> write.Error {
	node, p, has := tape.answer(r, idx, 0)
	if !has || p != .Found {
		append(buf, "null")
		return nil
	}
	return append_node_compact_json(buf, doc, node, alloc)
}

// Appends one formatted row (or `.Stream` sequence of rows) directly into `buf` without calling `emit`.
@(private = "file")
format_projected_row :: proc(
	doc: ^tape.Document,
	pr: ^query.Projection_Template,
	mode: Direct_Output,
	buf: ^[dynamic]u8,
	alloc: runtime.Allocator,
	append_nl: bool,
	row_count: ^u64,
) -> (wrong_kind: bool, werr: write.Error) {
	r := tape.Reader{doc = doc}
	n_fields := len(pr.fields)
	if has_wrong_projected_field(r, n_fields) {
		return true, nil
	}
	if mode == .Csv || mode == .Tsv {
		delim := u8('\t') if mode == .Tsv else u8(',')
		for i in 0 ..< n_fields {
			if i > 0 {
				append(buf, delim)
			}
			if node, p, has := tape.answer(r, i, 0); has && p == .Found {
				append_node_dsv_cell(buf, doc, node, delim, alloc) or_return
			}
		}
		if append_nl {
			append(buf, '\n')
		}
		row_count^ = 1
		return false, nil
	}

	switch pr.shape {
	case .Single:
		append_answer_json(buf, doc, r, 0, alloc) or_return
		if append_nl {
			append(buf, '\n')
		}
		row_count^ = 1
	case .Stream:
		for i in 0 ..< n_fields {
			append_answer_json(buf, doc, r, i, alloc) or_return
			if append_nl {
				append(buf, '\n')
			}
		}
		row_count^ = u64(n_fields)
	case .Array, .Object:
		is_obj := pr.shape == .Object
		append(buf, '{' if is_obj else '[')
		for f, i in pr.fields {
			if i > 0 {
				append(buf, ',')
			}
			if is_obj {
				append_json_string(buf, f.key)
				append(buf, ':')
			}
			append_answer_json(buf, doc, r, i, alloc) or_return
		}
		append(buf, '}' if is_obj else ']')
		if append_nl {
			append(buf, '\n')
		}
		row_count^ = 1
	case .None:
		return true, nil
	}
	return false, nil
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
	append_nl := false,
) -> (ok: bool, wrong_kind: bool, werr: write.Error) {
	if mode == .Json && pr.shape == .Stream {
		r := tape.Reader{doc = doc}
		n_fields := len(pr.fields)
		if has_wrong_projected_field(r, n_fields) {
			return false, true, nil
		}
		for i in 0 ..< n_fields {
			clear(buf)
			append_answer_json(buf, doc, r, i, alloc) or_return
			if append_nl {
				append(buf, '\n')
			}
			if !emit_bytes(emit, buf[:]) {
				return false, false, nil
			}
			emitted^ += 1
		}
		return true, false, nil
	}

	clear(buf)
	row_cnt: u64
	wrong, rerr := format_projected_row(doc, pr, mode, buf, alloc, append_nl, &row_cnt)
	if wrong || rerr != nil {
		return false, wrong, rerr
	}
	if mode != .Json && !emit_direct_header(need_header, header_emitted, hdr_buf, pr, mode, append_nl, emit, emitted) {
		return false, false, nil
	}
	if !emit_bytes(emit, buf[:]) {
		return false, false, nil
	}
	emitted^ += row_cnt
	return true, false, nil
}

@(private = "file")
append_node_compact_json :: proc(buf: ^[dynamic]u8, doc: ^tape.Document, node: tape.Node_Index, alloc: runtime.Allocator) -> write.Error {
	if node == tape.NO_NODE || int(node) >= len(doc.nodes) {
		append(buf, "null")
		return nil
	}
	t := doc.nodes[node]
	if doc.format == nil || .Binary not_in doc.format.caps {
		#partial switch t.kind {
		case .Null:  append(buf, "null"); return nil
		case .False: append(buf, "false"); return nil
		case .True:  append(buf, "true"); return nil
		case .String:
			if t.spelling & tape.SPELLING_DECODE == 0 && doc.format != nil && doc.format.name == "json" {
				append(buf, '"')
				append(buf, ..tape.span_bytes(doc, t.lo, t.n))
				append(buf, '"')
				return nil
			}
		case .Number:
			if doc.format != nil && doc.format.name == "json" && (t.spelling & (tape.SPELLING_DECODE | tape.NUMBER_KIND)) == 0 {
				append(buf, ..tape.span_bytes(doc, t.lo, t.n))
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
	case .Null:  return nil
	case .True:  append(buf, "true"); return nil
	case .False: append(buf, "false"); return nil
	case .Number:
		is_binary := doc.format != nil && .Binary in doc.format.caps
		if !is_binary && (t.spelling & tape.NUMBER_KIND) == 0 && doc.format != nil && doc.format.name != "toml" && doc.format.name != "toml-1.1" {
			append_dsv_escaped(buf, string(tape.span_bytes(doc, t.lo, t.n)), delim)
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
			append_dsv_escaped(buf, string(tape.span_bytes(doc, t.lo, t.n)), delim)
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
