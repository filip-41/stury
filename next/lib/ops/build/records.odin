package build

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The batch reads of a text's records over a format's framing and walk, each record judged as a read of its bytes
// alone judges them, in place in the text. A format gives `$frame`, which finds the next record, and per hook a
// `$walk` of one record, both procs of its own that reach the walk it keeps in its records past the `tape.Records`.

// What a format's walk of one record gives: the walk's result, the record's end, whether the record must be walked
// again alone (`again`), as the walk in the whole text read it as no walk of its bytes alone would, whether the walk
// took a rule of `Options.tolerate`, and false in `ok` once the records have ended.
Record_Walk :: struct {
	res:       hook.Walk_Result,
	hi:        u64,
	again:     bool,
	tolerated: bool,
	ok:        bool,
}

// A format's framing: the next record's first byte and the end its walk may read to, or false once the records have
// ended, with `err` set by the format when a fault ends them. Its `$walk` walks the record from `lo` to `cut` for the
// read's hook, first in the walk of the whole text, or with `alone` as a text of its bytes alone, which gives only
// `res` and `tolerated`.
Record_Frame :: #type proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool)

records_validate :: proc(r: ^tape.Records, out: []tape.Record, format: ^tape.Format, rules: ^tape.Rules, caller: runtime.Allocator, $frame: Record_Frame, $walk: proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> Record_Walk) -> (n: int) {
	if !validate_dups(format, r.opts) {
		records_stop(r, tape.Bad_Option{"dups"})
		return
	}
	m: hook.Memory_Budget
	ctx := context
	h: hook.No_Hooks
	regs: hook.Regs
	for n < len(out) {
		allocator := read_allocator(&m, r.opts, caller)
		lo, cut := frame(r) or_break
		w := walk(r, lo, cut, false, &h, &regs, allocator, &ctx)
		if !w.ok {
			break
		}
		if w.again {
			w.res = walk(r, lo, cut, true, &h, &regs, allocator, &ctx).res
		}
		_, err, _ := hook.walk_error(w.res, rules)
		out[n] = record_end(r, lo, w.hi, hook.memory_budget_error(&m, err))
		n += 1
	}
	records_window_end(r)
	return
}

records_find :: proc(r: ^tape.Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, format: ^tape.Format, rules: ^tape.Rules, read: tape.Read_Options, caller: runtime.Allocator, respell: proc "contextless" (src: []u8, lo, hi: u64) -> u16, rewalk: proc "contextless" (h: ^Finder, lo: u64) -> hook.Walk_Result, $frame: Record_Frame, $walk: proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^Finder, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> Record_Walk) -> (n: int) {
	read := read
	if !record_reads(r, &read, format) {
		return
	}
	steps, followed := find_steps(path)
	if !followed {
		records_stop(r, tape.Bad_Option{"path"})
		return
	}
	out := out
	out = out[:min(len(out), len(answers))]
	m: hook.Memory_Budget
	ctx := context
	room: Find_Room = ---
	f: Finder
	defer finder_end(&f)
	for n < len(out) {
		allocator := read_allocator(&m, r.opts, caller)
		lo, cut := frame(r) or_break
		if err := find_begin(&f, r.src, format, steps, r.opts.dups, read, respell, rewalk, &room, allocator); err != nil {
			records_stop(r, hook.memory_budget_error(&m, err))
			break
		}
		regs: hook.Regs
		w := walk(r, lo, cut, false, &f, &regs, allocator, &ctx)
		if !w.ok {
			break
		}
		if w.again {
			if err := find_begin(&f, r.src, format, steps, r.opts.dups, read, respell, rewalk, &room, allocator, true); err != nil {
				records_stop(r, hook.memory_budget_error(&m, err))
				break
			}
			regs = {}
			a := walk(r, lo, cut, true, &f, &regs, allocator, &ctx)
			w.res, w.tolerated = a.res, a.tolerated
		}
		_, werr, _ := hook.walk_error(w.res, rules)
		if werr == nil && f.refused {
			werr = runtime.Allocator_Error.Out_Of_Memory
		}
		if werr != nil {
			out[n], answers[n] = record_end(r, lo, w.hi, hook.memory_budget_error(&m, werr)), {outcome = .Missing}
			n += 1
			continue
		}
		answers[n] = finder_answer(&f)
		answers[n].tolerated = w.tolerated
		out[n] = record_end(r, lo, w.hi, nil)
		n += 1
	}
	records_window_end(r)
	return
}

records_scan :: proc(r: ^tape.Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, format: ^tape.Format, rules: ^tape.Rules, read: tape.Read_Options, caller: runtime.Allocator, rewalk: Rewalk, $bound: proc "contextless" (src: []u8, depth: u64) -> u64, $frame: Record_Frame, $walk: proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^Scanner, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> Record_Walk) -> (n: int) {
	read := read
	if !record_reads(r, &read, format) {
		return
	}
	if scan_refuses(demand) {
		records_stop(r, tape.Bad_Option{"path"})
		return
	}
	out := out
	out = out[:min(len(out), len(docs))]
	m: hook.Memory_Budget
	frames: [FRAME_DEPTH]u64 = ---
	room: Scan_Room = ---
	h: Scanner
	for n < len(out) {
		allocator := read_allocator(&m, r.opts, caller)
		lo, cut := frame(r) or_break
		depth := min(read_depth(r.opts), cut - lo)
		most := node_most(bound(r.src[lo:cut], depth), r.opts)
		if err := scanner_restart(&h, r.src, format, demand, r.opts.dups, read, rewalk, SCAN_NODES, most, frames[:min(depth, FRAME_DEPTH)], &room, allocator); err != nil {
			records_stop(r, hook.memory_budget_error(&m, err))
			break
		}
		regs := builder_regs(&h.b)
		w := walk(r, lo, cut, false, &h, &regs, allocator, &h.b.ctx)
		if !w.ok || w.again {
			// The walk's tokens are dropped with what the scanner built of them.
			_, _ = scanner_end(&h, regs, 0, runtime.Allocator_Error.Out_Of_Memory)
			if !w.ok {
				break
			}
			if err := scanner_restart(&h, r.src, format, demand, r.opts.dups, read, rewalk, SCAN_NODES, most, frames[:min(depth, FRAME_DEPTH)], &room, allocator); err != nil {
				records_stop(r, hook.memory_budget_error(&m, err))
				break
			}
			regs = builder_regs(&h.b)
			a := walk(r, lo, cut, true, &h, &regs, allocator, &h.b.ctx)
			w.res, w.tolerated = a.res, a.tolerated
		}
		root_close, werr, _ := hook.walk_error(w.res, rules)
		if werr == nil && r.opts.pieces != nil {
			// A window's bytes may go once the batch ends, so the document holds the bytes it reads.
			h.held.allocator, h.bytes.allocator = allocator, allocator
			if e := scanner_hold(&h, regs, r.src); e != nil {
				werr = e
			}
		}
		doc, e := scanner_end(&h, regs, root_close, werr)
		e = read_end(&doc, e, &m, w.tolerated, caller)
		out[n], docs[n] = record_end(r, lo, w.hi, e), doc
		n += 1
	}
	records_window_end(r)
	return
}

// Readies `f` for the next record: started when it is not, or when `fresh` or its levels are allocated, otherwise reset
// with its room kept.
@(private)
find_begin :: #force_inline proc(f: ^Finder, src: []u8, format: ^tape.Format, path: []tape.Step, dups: tape.Duplicates, read: tape.Read_Options, respell: proc "contextless" (src: []u8, lo, hi: u64) -> u16, rewalk: proc "contextless" (h: ^Finder, lo: u64) -> hook.Walk_Result, room: ^Find_Room, allocator: runtime.Allocator, fresh := false) -> runtime.Allocator_Error {
	if f.format == nil || f.block != nil || fresh {
		finder_end(f)
		f^ = {}
		return finder_start(f, src, format, path, dups, read, respell, rewalk, room, allocator)
	}
	finder_reset(f, room)
	return nil
}

// Ends the records with `err`, which no record holds.
@(private, cold)
records_stop :: proc "contextless" (r: ^tape.Records, err: tape.Error) {
	r.err, r.at = err, .Done
}

// Whether a path read under `read` and the records' options may go on, which ends the records with `tape.Bad_Option`
// for the build-only policies a path read refuses. Under a framing other than `.Lines` it reads each record to its end, as the next starts there.
@(private)
record_reads :: proc "contextless" (r: ^tape.Records, read: ^tape.Read_Options, format: ^tape.Format) -> bool {
	if !path_dups(format, r.opts) {
		records_stop(r, tape.Bad_Option{"dups"})
		return false
	}
	if r.framing != .Lines {
		read.stop_early = false
	}
	return true
}

// Sets the pieces of records of a text in pieces for the next window once a batch ends: the records go on while they
// have not ended, from `pos`, where the next record is looked for, or from the text's start while they are at their
// start, whose bytes a format may read once its opening is whole.
records_window_end :: #force_inline proc "contextless" (r: ^tape.Records) {
	if p := r.opts.pieces; p != nil {
		p.more, p.at, p.keep = r.at != .Done, u64(len(r.src)), r.pos if r.at != .Start else 0
	}
}

// The record from `lo` to `hi` with error `err`, counted among those read.
@(private)
record_end :: #force_inline proc "contextless" (r: ^tape.Records, lo, hi: u64, err: tape.Error) -> tape.Record {
	r.index += 1
	return {index = r.index - 1, lo = lo, hi = hi, err = err, key = r.key}
}
