package main

// Encode lanes. The document lanes report source bytes per second, comparable with the scan lanes on the
// same fixture. The number and marshal lanes report output bytes per second, as yy_bench does. The edit lanes
// (`set_*`, `remove_*`, `insert_*`, `splice_*`) also report `ratio`: their median divided by the median of a
// reference job.

import json "stury:json"
import "core:bytes"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:reflect"
import "core:strings"
import "core:time"

ENCODE_NUMBERS :: 1_000_000
ENCODE_SEED :: 20261008

// SplitMix64, the same generator as yy_bench.c, so both writers format the same values.
splitmix64 :: proc(s: ^u64) -> u64 {
	s^ += 0x9E3779B97F4A7C15
	z := s^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

// A writer that discards its input, so the streaming lanes time the encoder, not a sink. `n` counts the bytes
// written.
Discard :: struct {
	n: int,
}

discard_writer :: proc(d: ^Discard) -> io.Writer {
	return {procedure = discard_proc, data = d}
}

discard_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, _: i64, _: io.Seek_From) -> (i64, io.Error) {
	#partial switch mode {
	case .Write:
		(^Discard)(data).n += len(p)
		return i64(len(p)), nil
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Unsupported
}

// Times `marshal` of the built document at `opts`; with `to_writer` it streams into a `Discard` writer.
// `copy_gb_per_s`, the baseline, times a plain copy of the same bytes into a warm buffer.
bench_encode_doc :: proc(data: []byte, opts: json.Marshal_Opts, to_writer := false) -> bool {
	doc, berr := json.build(data)
	if berr != nil {
		return false
	}
	defer json.destroy(&doc)
	times, copies: [TIMED_ITERS]i64
	out_len := 0
	for i in 0 ..< WARMUP_ITERS + TIMED_ITERS {
		d: i64
		if to_writer {
			sink: Discard
			t := time.tick_now()
			err := json.marshal_to_writer(discard_writer(&sink), &doc, opts)
			d = i64(time.tick_since(t))
			if err != .None {
				return false
			}
			out_len = sink.n
		} else {
			t := time.tick_now()
			out, err := json.marshal(&doc, opts)
			d = i64(time.tick_since(t))
			if err != .None {
				return false
			}
			out_len = len(out)
			delete(out)
		}
		keep_timed(&times, i, d)
	}
	dst := make([]u8, len(data))
	defer delete(dst)
	copy(dst, data) // faults the pages in, so the timed copies write to a warm buffer
	for i in 0 ..< TIMED_ITERS {
		t := time.tick_now()
		copy(dst, data)
		copies[i] = i64(time.tick_since(t))
	}
	fmt.printf("gb_per_s=%.4g copy_gb_per_s=%.4g out_bytes=%d rss_bytes=%d\n",
		f64(len(data)) / f64(median(times)), f64(len(data)) / f64(median(copies)), out_len, rss_growth(RSS_MARK))
	return true
}

// Times `marshal` of every string value of the document as one array. The strings are decoded once,
// outside the clock. Reports decoded string bytes per second.
bench_encode_string :: proc(data: []byte) -> bool {
	doc, berr := json.build(data)
	if berr != nil {
		return false
	}
	defer json.destroy(&doc)
	strs: [dynamic]string
	defer delete(strs)
	total := 0
	for nd, i in doc.rows {
		if nd.kind != .String {
			continue
		}
		s, ok := json.get_string(&doc, json.Node(i))
		if !ok {
			return false
		}
		append(&strs, s)
		total += len(s)
	}
	times: [TIMED_ITERS]i64
	for i in 0 ..< WARMUP_ITERS + TIMED_ITERS {
		t := time.tick_now()
		out, err := json.marshal(strs[:])
		d := i64(time.tick_since(t))
		delete(out)
		if err != .None {
			return false
		}
		keep_timed(&times, i, d)
	}
	fmt.printf("gb_per_s=%.4g strings=%d rss_bytes=%d\n", f64(total) / f64(median(times)), len(strs), rss_growth(RSS_MARK))
	return true
}

// Times `marshal` of ENCODE_NUMBERS SplitMix64 values as one array, in output bytes per second. A non-finite
// f64 bit pattern is redrawn, as yy_bench does.
bench_encode_numbers :: proc($T: typeid) -> bool where T == f64 || T == i64 {
	vals := make([]T, ENCODE_NUMBERS)
	defer delete(vals)
	s := u64(ENCODE_SEED)
	for &v in vals {
		bits := splitmix64(&s)
		when T == f64 {
			for (bits >> 52) & 0x7ff == 0x7ff {
				bits = splitmix64(&s)
			}
		}
		v = transmute(T)bits
	}
	times: [TIMED_ITERS]i64
	n := 0
	for i in 0 ..< WARMUP_ITERS + TIMED_ITERS {
		t := time.tick_now()
		out, err := json.marshal(vals)
		d := i64(time.tick_since(t))
		n = len(out)
		delete(out)
		if err != .None {
			return false
		}
		keep_timed(&times, i, d)
	}
	fmt.printf("gb_per_s=%.4g out_bytes=%d rss_bytes=%d\n", f64(n) / f64(median(times)), n, rss_growth(RSS_MARK))
	return true
}

Log_Record :: struct {
	ts, level, service, msg: string,
	status, bytes:           i64,
	duration_ms:             f64,
	id:                      string,
}

// Reads logs.json's records from the built document; called outside the clock.
load_log_records :: proc(doc: ^json.Document) -> (records: [dynamic]Log_Record, ok: bool) {
	logs := json.child(doc, json.ROOT, "logs")
	if logs == json.NO_NODE {
		return
	}
	r_it := json.children(doc, logs)
	for r in json.children(&r_it) {
		rec: Log_Record
		rec.ts = log_string(doc, r, "ts") or_return
		rec.level = log_string(doc, r, "level") or_return
		rec.service = log_string(doc, r, "service") or_return
		rec.msg = log_string(doc, r, "msg") or_return
		rec.status = i64(log_number(doc, r, "status") or_return)
		rec.bytes = i64(log_number(doc, r, "bytes") or_return)
		rec.duration_ms = log_number(doc, r, "duration_ms") or_return
		rec.id = log_string(doc, r, "id") or_return
		append(&records, rec)
	}
	return records, true
}

log_string :: proc(doc: ^json.Document, rec: json.Node, name: string) -> (string, bool) {
	i := json.child(doc, rec, name)
	if i == json.NO_NODE {
		return "", false
	}
	return json.get_string(doc, i)
}

log_number :: proc(doc: ^json.Document, rec: json.Node, name: string) -> (f64, bool) {
	return json.get_float(doc, json.child(doc, rec, name))
}

// logs.json's records with `level` and `service` as enums, which marshal writes by name.
Log_Level :: enum u8 {
	trace,
	debug,
	info,
	warn,
	error,
}

Log_Service :: enum u8 {
	auth,
	cart,
	checkout,
	inventory,
	payments,
	profile,
	search,
	shipping,
}

Log_Enum_Record :: struct {
	ts:          string,
	level:       Log_Level,
	service:     Log_Service,
	msg:         string,
	status:      i64,
	bytes:       i64,
	duration_ms: f64,
	id:          string,
}

// Times `marshal` of logs.json's records with a reused plan, in output bytes per second. `enums` marshals
// them as Log_Enum_Record; `to_writer` streams into a `Discard` writer.
bench_marshal_logs :: proc(data: []byte, enums := false, to_writer := false) -> bool {
	doc, berr := json.build(data)
	if berr != nil {
		return false
	}
	defer json.destroy(&doc)
	records, ok := load_log_records(&doc)
	defer delete(records)
	if !ok {
		return false
	}
	if !enums {
		return time_marshal(records[:], to_writer)
	}
	typed := make([]Log_Enum_Record, len(records))
	defer delete(typed)
	for r, i in records {
		level, lok := reflect.enum_from_name(Log_Level, r.level)
		service, sok := reflect.enum_from_name(Log_Service, r.service)
		if !lok || !sok {
			return false
		}
		typed[i] = {r.ts, level, service, r.msg, r.status, r.bytes, r.duration_ms, r.id}
	}
	return time_marshal(typed, to_writer)
}

time_marshal :: proc(records: []$T, to_writer: bool) -> bool {
	plan := json.type_plan_init([]T)
	defer json.destroy(&plan)
	times: [TIMED_ITERS]i64
	out_len := 0
	for i in 0 ..< WARMUP_ITERS + TIMED_ITERS {
		d: i64
		if to_writer {
			sink: Discard
			t := time.tick_now()
			err := json.marshal_to_writer(discard_writer(&sink), records, plan = &plan)
			d = i64(time.tick_since(t))
			if err != .None {
				return false
			}
			out_len = sink.n
		} else {
			t := time.tick_now()
			out, err := json.marshal(records, plan = &plan)
			d = i64(time.tick_since(t))
			if err != .None {
				return false
			}
			out_len = len(out)
			delete(out)
		}
		keep_timed(&times, i, d)
	}
	fmt.printf("gb_per_s=%.4g records=%d out_bytes=%d rss_bytes=%d\n", f64(out_len) / f64(median(times)), len(records), out_len, rss_growth(RSS_MARK))
	return true
}

// Which path edit `bench_edit` times; `.Insert` adds member `"tag"`.
Bench_Edit :: enum {
	Set,
	Remove,
	Insert,
}

// Returns a fresh copy of `data`, the copy half of each edit lane's reference job.
copy_of :: proc(data: []byte) -> (fresh: []byte, ok: bool) {
	aerr: mem.Allocator_Error
	fresh, aerr = mem.alloc_bytes_non_zeroed(len(data))
	if aerr != nil {
		return nil, false
	}
	copy(fresh, data)
	return fresh, true
}

edit_scan_reference :: proc(data: []byte, req: ^json.Request({.Path})) -> (ns: i64, ok: bool) {
	t := time.tick_now()
	if !scan_ok(data, req) {
		return 0, false
	}
	fresh := copy_of(data) or_return
	ns = i64(time.tick_since(t))
	delete(fresh)
	return ns, true
}

apply_edit :: proc(data: []byte, op: Bench_Edit, path: string, value: any) -> (out: []byte, err: Maybe(json.Path_Error)) {
	switch op {
	case .Set:
		return json.set(data, path, value)
	case .Remove:
		return json.remove(data, path)
	case .Insert:
		return json.insert(data, path, "tag", value)
	}
	return
}

edit_timed :: proc(data: []byte, op: Bench_Edit, path: string, value: any) -> (ns: i64, ok: bool) {
	t := time.tick_now()
	out, err := apply_edit(data, op, path, value)
	ns = i64(time.tick_since(t))
	if err != nil {
		return 0, false
	}
	delete(out)
	return ns, true
}

// Runs one untimed edit and checks that it took effect: the output differs from the source and is valid
// JSON.
edit_took_effect :: proc(data: []byte, op: Bench_Edit, path: string, value: any) -> bool {
	out, err := apply_edit(data, op, path, value)
	if err != nil {
		return false
	}
	defer delete(out)
	_, bad := json.validate(out).?
	return !bad && !bytes.equal(out, data)
}

// Times a path edit against its reference job: the same `.Strict` path scan plus one fresh copy of the
// source. The two arms alternate which runs first, so a load swing cannot favour one.
bench_edit :: proc(data: []byte, op: Bench_Edit, path: string, value: any = nil) -> bool {
	steps: [32]json.Step
	p, perr := json.parse_path(path, steps[:])
	if perr != nil {
		return false
	}
	paths := [1]json.Path{p}
	req: json.Request({.Path})
	req.strictness = .Strict
	req.paths = paths[:]
	defer json.destroy(&req)
	if !edit_took_effect(data, op, path, value) {
		return false
	}
	ref, got: [TIMED_ITERS]i64
	for i in 0 ..< WARMUP_ITERS + TIMED_ITERS {
		r, g: i64
		ref_ok, got_ok: bool
		if i % 2 == 0 {
			r, ref_ok = edit_scan_reference(data, &req)
			g, got_ok = edit_timed(data, op, path, value)
		} else {
			g, got_ok = edit_timed(data, op, path, value)
			r, ref_ok = edit_scan_reference(data, &req)
		}
		if !ref_ok || !got_ok {
			return false
		}
		if i >= WARMUP_ITERS {
			ref[i - WARMUP_ITERS] = r
			got[i - WARMUP_ITERS] = g
		}
	}
	fmt.printf("gb_per_s=%.4g ratio=%.4g rss_bytes=%d\n",
		f64(len(data)) / f64(median(got)), f64(median(got)) / f64(median(ref)), rss_growth(RSS_MARK))
	return true
}

edit_validate_reference :: proc(data: []byte) -> (ns: i64, ok: bool) {
	t := time.tick_now()
	fresh := copy_of(data) or_return
	_, bad := json.validate(fresh).?
	ns = i64(time.tick_since(t))
	delete(fresh)
	return ns, !bad
}

splice_timed :: proc(data: []byte, edits: []json.Edit) -> (ns: i64, ok: bool) {
	t := time.tick_now()
	out, err := json.splice(data, edits)
	ns = i64(time.tick_since(t))
	if err != nil {
		return 0, false
	}
	delete(out)
	return ns, true
}

// Times `splice` of the first record's `level` value against a reference job: a fresh copy of the source
// plus `validate` of the copy.
bench_splice_logs :: proc(data: []byte) -> bool {
	text := string(data)
	at := strings.index(text, `"level":"`)
	if at < 0 {
		return false
	}
	lo := at + len(`"level":`)
	end := strings.index_byte(text[lo + 1:], '"')
	if end < 0 {
		return false
	}
	edits := [1]json.Edit{{lo = u64(lo), hi = u64(lo + 1 + end + 1), bytes = transmute([]u8)string(`"error"`)}}
	ref, got: [TIMED_ITERS]i64
	for i in 0 ..< WARMUP_ITERS + TIMED_ITERS {
		r, g: i64
		ref_ok, got_ok: bool
		if i % 2 == 0 {
			r, ref_ok = edit_validate_reference(data)
			g, got_ok = splice_timed(data, edits[:])
		} else {
			g, got_ok = splice_timed(data, edits[:])
			r, ref_ok = edit_validate_reference(data)
		}
		if !ref_ok || !got_ok {
			return false
		}
		if i >= WARMUP_ITERS {
			ref[i - WARMUP_ITERS] = r
			got[i - WARMUP_ITERS] = g
		}
	}
	fmt.printf("gb_per_s=%.4g ratio=%.4g rss_bytes=%d\n",
		f64(len(data)) / f64(median(got)), f64(median(got)) / f64(median(ref)), rss_growth(RSS_MARK))
	return true
}
