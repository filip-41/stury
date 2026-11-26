package engine

import "base:runtime"
import "core:strconv"
import "core:sync"
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
			opts.direct_append_nl,
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
	if dec.parallel &&
		ro.runner != nil &&
		ro.runner.threads > 0 &&
		dec.entry.family == .Json &&
		(tf == .Lines || tf == .Seq) &&
		ro.pieces == nil &&
		len(src) >= max(RECORDS_PARALLEL_FROM, 4096) {
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
				opts.direct_append_nl,
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
) -> (
	res: Exec_Result,
	handled: bool,
) {
	delim := u8('\n') if tf == .Lines else 0x1e
	bom := u64(spell.bom_length(src))
	chunks: [ops_build.MAX_RECORD_CHUNKS]ops_build.Record_Chunk = ---
	nc := ops_build.cut_delim_chunks(src, bom, delim, ro.runner, chunks[:])
	if nc < 2 {
		return {}, false
	}
	jspec, is_json := dec.spec.(json.Spec)
	if !is_json {
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
		src:         []u8,
		tf:          tape.Framing,
		jspec:       json.Spec,
		ro:          tape.Options,
		pr:          ^query.Projection_Template,
		dem:         ^tape.Demand,
		opts:        ^Exec_Options,
		chunks:      []ops_build.Record_Chunk,
		slots:       []Direct_Chunk_Slot,
		use_lock:    bool,
		lock_scratch: bool,
		alloc_lock:  sync.Mutex,
	}

	locked_alloc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_ptr: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
		j := (^Direct_Job)(data)
		sync.mutex_guard(&j.alloc_lock)
		return j.opts.allocator.procedure(j.opts.allocator.data, mode, size, alignment, old_ptr, old_size, loc)
	}

	locked_scratch :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_ptr: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
		j := (^Direct_Job)(data)
		sync.mutex_guard(&j.alloc_lock)
		return j.ro.scratch.procedure(j.ro.scratch.data, mode, size, alignment, old_ptr, old_size, loc)
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
		use_lock     = !is_thread_safe_heap(opts.allocator),
		lock_scratch = has_custom_scratch(ro.scratch),
	}

	run_chunk :: proc(arg: rawptr, k: int) {
		j := (^Direct_Job)(arg)
		lalloc := runtime.Allocator{procedure = locked_alloc, data = j} if j.use_lock else j.opts.allocator
		slot := &j.slots[k]
		c := j.chunks[k]
		chunk_len := int(c.hi - c.lo)
		slot.buf = make([dynamic]u8, 0, max(chunk_len / 2, 256), lalloc)
		slot.events.allocator = lalloc

		chunk_ro := j.ro
		chunk_ro.runner = nil
		if j.lock_scratch {
			chunk_ro.scratch = runtime.Allocator{procedure = locked_scratch, data = j}
		}
		base_off := u64(0)
		chunk_src := j.src[:c.hi]
		if j.tf == .Seq && k > 0 {
			base_off = c.lo - 1
			chunk_src = j.src[base_off:c.hi]
		}
		lr := json.records_open(chunk_src, j.tf, j.jspec, chunk_ro)
		defer tape.destroy_records(&lr)
		lr.skip_bad = j.opts.skip_bad
		lr.max_bytes = j.opts.max_bytes
		if j.tf == .Lines && k > 0 {
			lr.pos = c.lo
			lr.at = .Open
		}
		if lr.err != nil {
			err_v := adjust_err_offset(lr.err, base_off)
			slot.err = .No_Memory if is_alloc_err(err_v) else .Read_Error
			slot.read_err = err_v
			return
		}

		flushed := 0
		flush_pending :: proc(slot: ^Direct_Chunk_Slot, flushed: ^int, rows, recs: ^u64) -> bool {
			if len(slot.buf) > flushed^ || recs^ > 0 {
				if _, aerr := append(&slot.events, Direct_Event{
					kind  = .Emit_Slice,
					off   = flushed^,
					sz    = len(slot.buf) - flushed^,
					count = rows^,
					recs  = recs^,
				}); aerr != nil {
					slot.err = .No_Memory
					slot.read_err = aerr
					return false
				}
				flushed^ = len(slot.buf)
				rows^ = 0
				recs^ = 0
			}
			return true
		}

		pending_rows := u64(0)
		pending_recs := u64(0)
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
						slot.err = .No_Memory
						slot.read_err = aerr
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
						slot.err = .No_Memory
						slot.read_err = aerr
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
						slot.err = .No_Memory
						slot.read_err = aerr
					} else {
						slot.err = .Write_Error
						slot.write_err = werr
					}
					return
				}
				slot.emitted_rows += row_count
				pending_rows += row_count
				if !j.opts.coalesce_emit {
					if !flush_pending(slot, &flushed, &pending_rows, &pending_recs) {
						return
					}
				}
			}
		}
		if len(slot.events) > 0 {
			if !flush_pending(slot, &flushed, &pending_rows, &pending_recs) {
				return
			}
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
	emit_hdr_if_needed :: proc(need_header: bool, header_emitted: ^bool, hdr_buf: ^[dynamic]u8, pr: ^query.Projection_Template, mode: Direct_Output, append_nl: bool, emit: Emitter, emitted: ^u64) -> bool {
		if !need_header || header_emitted^ {
			return true
		}
		delim := u8('\t') if mode == .Tsv else u8(',')
		write_direct_header(hdr_buf, pr, delim)
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

	for &slot in slots {
		if len(slot.events) == 0 {
			if len(slot.buf) > 0 {
				if !emit_hdr_if_needed(need_header, &header_emitted, &hdr_buf, pr, opts.direct_out, opts.direct_append_nl, opts.emit, &res.emitted) {
					res.err = .Stopped
					return res, true
				}
				if !emit_bytes(opts.emit, slot.buf[:]) {
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
						if !emit_hdr_if_needed(need_header, &header_emitted, &hdr_buf, pr, opts.direct_out, opts.direct_append_nl, opts.emit, &res.emitted) {
							res.err = .Stopped
							return res, true
						}
						if !emit_bytes(opts.emit, slot.buf[ev.off:][:ev.sz]) {
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
						if !emit_hdr_if_needed(need_header, &header_emitted, &hdr_buf, pr, opts.direct_out, opts.direct_append_nl, opts.emit, &res.emitted) {
							res.err = .Stopped
							return res, true
						}
						meta := make_record_meta(opts, rec_idx, ev.rec, raw)
						sub := exec_single_record_whole(dec, raw, meta, opts)
						res.emitted += sub.emitted
						if sub.err != .None {
							res.err = sub.err
							res.read_err = sub.read_err
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
			res.err = slot.err
			res.read_err = slot.read_err
			res.write_err = slot.write_err
			return res, true
		}
	}
	return res, true
}

@(private = "file")
adjust_err_offset :: proc "contextless" (err: tape.Error, base_off: u64) -> tape.Error {
	if err == nil || base_off == 0 {
		return err
	}
	if f, ok := err.(tape.Fault); ok && f.at != tape.NO_BYTE {
		f.at += base_off
		return f
	}
	if ex, ok := err.(tape.Exceeded); ok && ex.at != tape.NO_BYTE {
		ex.at += base_off
		return ex
	}
	return err
}

@(private = "file")
adjust_rec_offset :: proc "contextless" (r: tape.Record, base_off: u64) -> tape.Record {
	if base_off == 0 {
		return r
	}
	out := r
	out.lo += base_off
	out.hi += base_off
	out.err = adjust_err_offset(out.err, base_off)
	return out
}

// Appends one formatted row (or `.Stream` sequence of rows) directly into `buf` without calling `emit`.
// When `append_nl` is true on JSON shapes (or CSV/TSV), appends `\n` after each logical output line.
@(private = "file")
format_projected_row :: proc(
	doc: ^tape.Document,
	pr: ^query.Projection_Template,
	mode: Direct_Output,
	buf: ^[dynamic]u8,
	alloc: runtime.Allocator,
	append_nl: bool,
	row_count: ^u64,
) -> (
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
			return true, nil
		}
	}

	if mode == .Csv || mode == .Tsv {
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
		if append_nl {
			append(buf, '\n')
		}
		row_count^ = 1
		return false, nil
	}

	switch pr.shape {
	case .Single:
		node, p, has := tape.answer(r, 0, 0)
		if !has || p != .Found {
			append(buf, "null")
		} else {
			append_node_compact_json(buf, doc, node, alloc) or_return
		}
		if append_nl {
			append(buf, '\n')
		}
		row_count^ = 1
	case .Stream:
		for i in 0 ..< n_fields {
			node, p, has := tape.answer(r, i, 0)
			if !has || p != .Found {
				append(buf, "null")
			} else {
				append_node_compact_json(buf, doc, node, alloc) or_return
			}
			if append_nl {
				append(buf, '\n')
			}
		}
		row_count^ = u64(n_fields)
	case .Array:
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
		if append_nl {
			append(buf, '\n')
		}
		row_count^ = 1
	case .Object:
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
) -> (
	ok: bool,
	wrong_kind: bool,
	werr: write.Error,
) {
	if mode == .Csv || mode == .Tsv {
		r := tape.Reader{doc = doc}
		n_fields := len(pr.fields)
		for i in 0 ..< n_fields {
			_, p, has := tape.answer(r, i, 0)
			if has && (p == .Wrong_Kind || p == .Not_Loaded) {
				return false, true, nil
			}
		}
		clear(buf)
		delim := u8('\t') if mode == .Tsv else u8(',')
		row_cnt: u64
		wrong, rerr := format_projected_row(doc, pr, mode, buf, alloc, append_nl, &row_cnt)
		if wrong || rerr != nil {
			return false, wrong, rerr
		}
		if need_header && !header_emitted^ {
			write_direct_header(hdr_buf, pr, delim)
			if append_nl {
				append(hdr_buf, '\n')
			}
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

	if pr.shape == .Stream {
		r := tape.Reader{doc = doc}
		n_fields := len(pr.fields)
		for i in 0 ..< n_fields {
			_, p, has := tape.answer(r, i, 0)
			if has && (p == .Wrong_Kind || p == .Not_Loaded) {
				return false, true, nil
			}
		}
		for i in 0 ..< n_fields {
			clear(buf)
			node, p, has := tape.answer(r, i, 0)
			if !has || p != .Found {
				append(buf, "null")
			} else {
				append_node_compact_json(buf, doc, node, alloc) or_return
			}
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
	if !emit_bytes(emit, buf[:]) {
		return false, false, nil
	}
	emitted^ += row_cnt
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
