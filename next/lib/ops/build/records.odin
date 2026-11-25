package build

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The batch reads of a text's records over a format's framing and walk, each record judged as a read of its bytes
// alone judges them, in place in the text. A format gives `$frame`, which finds the next record, and per hook a
// `$walk` of one record, both procs of its own that reach the walk it keeps in its records past the `tape.Records`.

// What a format's walk of one record gives: the walk's result, the record's end, whether the record must be walked
// again alone (`again`), as the walk in the whole text read it as no walk of its bytes alone would, whether the walk
// took a rule of `Options.tolerate`, and false in `ok` once the records have ended, or in a text in pieces once the
// window ends inside the record, which the next window reads again.
Record_Walk :: struct {
	res:       hook.Walk_Result,
	hi:        u64,
	again:     bool,
	tolerated: bool,
	ok:        bool,
}

// A format's framing: the next record's first byte and the end its walk may read to, or false once the records have
// ended, with `err` set by the format when a fault ends them, judging what it passes with memory from `allocator`, the
// record's. Its `$walk` walks the record from `lo` to `cut` for the
// read's hook, first in the walk of the whole text, or with `alone` as a text of its bytes alone, which gives only
// `res` and `tolerated`.
Record_Frame :: #type proc(r: ^tape.Records, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool)

// Reads the next records of `r`, judges each, and keeps in `out` those that do not read. With `one` it reads one
// record.
records_validate :: proc(r: ^tape.Records, out: []tape.Record, format: ^tape.Format, rules: ^tape.Rules, caller: runtime.Allocator, $frame: Record_Frame, $walk: proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> Record_Walk, one := false) -> (n: int) {
	if !validate_dups(format, r.opts) {
		records_stop(r, tape.Bad_Option{"dups"})
		return
	}
	m: hook.Read_Budget
	ctx := context
	h: hook.No_Hooks
	regs: hook.Regs
	for n < len(out) {
		allocator := hook.read_budget(&m, r.opts, caller)
		lo, cut, framed := frame(r, allocator)
		if !framed {
			r.err = hook.memory_budget_error(&m.main, r.err)
			if r.err == nil && window_too_wide(r) {
				records_stop(r, tape.record_too_long(r.pos if r.at != .Start else 0))
				break
			}
			if r.err != nil && (r.skip_bad || r.quarantine != nil) {
				if bad, skipped := tape.records_skip(r); skipped {
					if !quarantine_add(r, bad) {
						break
					}
					r.index += 1
					out[n] = {lo = bad.lo, hi = bad.hi, err = bad.err}
					n += 1
					if one {
						break
					}
					continue
				}
			}
			break
		}
		if (r.framing == .Lines || r.framing == .Seq) && cut < u64(len(r.src)) && record_too_wide(r, lo, cut) {
			records_stop(r, tape.record_too_long(lo))
			break
		}
		w := walk(r, lo, cut, false, &h, &regs, allocator, &ctx)
		if !w.ok {
			r.err = hook.memory_budget_error(&m.main, r.err)
			if r.err == nil && window_too_wide(r) {
				records_stop(r, tape.record_too_long(r.pos if r.at != .Start else 0))
				break
			}
			if r.err != nil && (r.skip_bad || r.quarantine != nil) {
				if bad, skipped := tape.records_skip(r); skipped {
					if !quarantine_add(r, bad) {
						break
					}
					r.index += 1
					out[n] = {lo = bad.lo, hi = bad.hi, err = bad.err}
					n += 1
					if one {
						break
					}
					continue
				}
			}
			break
		}
		if record_too_wide(r, lo, w.hi) {
			records_stop(r, tape.record_too_long(lo))
			break
		}
		if w.again {
			w.res = walk(r, lo, cut, true, &h, &regs, allocator, &ctx).res
		}
		_, err, _ := hook.walk_error(w.res, rules)
		if rec := record_end(r, lo, w.hi, hook.memory_budget_error(&m.main, err)); rec.err != nil {
			if !quarantine_record(r, rec) {
				break
			}
			out[n] = rec
			n += 1
		}
		if one {
			break
		}
	}
	records_window_end(r)
	return
}

records_find :: proc(r: ^tape.Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, format: ^tape.Format, rules: ^tape.Rules, read: tape.Read_Options, caller: runtime.Allocator, respell: proc "contextless" (src: []u8, lo, hi: u64) -> u16, rewalk: proc "contextless" (h: ^Finder, lo: u64) -> hook.Walk_Result, $frame: Record_Frame, $walk: proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^Finder, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> Record_Walk) -> (n: int) {
	steps, refused := find_path(format, r.opts, path)
	if refused != nil {
		records_stop(r, refused)
		return
	}
	// Under a framing other than `.Lines` and `.Seq` each record is read to its end, as the next starts there.
	read := read
	read.stop_early &&= r.framing == .Lines || r.framing == .Seq
	out := out
	out = out[:min(len(out), len(answers))]
	m: hook.Read_Budget
	ctx := context
	room: Find_Room = ---
	f: Finder
	defer finder_end(&f)
	for n < len(out) {
		allocator := hook.read_budget(&m, r.opts, caller)
		lo, cut, framed := frame(r, allocator)
		if !framed {
			r.err = hook.memory_budget_error(&m.main, r.err)
			if r.err == nil && window_too_wide(r) {
				records_stop(r, tape.record_too_long(r.pos if r.at != .Start else 0))
				break
			}
			if r.err != nil && (r.skip_bad || r.quarantine != nil) {
				if bad, skipped := tape.records_skip(r); skipped {
					if !quarantine_add(r, bad) {
						break
					}
					r.index += 1
					if r.quarantine == nil {
						out[n], answers[n] = {lo = bad.lo, hi = bad.hi, err = bad.err}, {outcome = .Missing}
						n += 1
					}
					continue
				}
			}
			break
		}
		if (r.framing == .Lines || r.framing == .Seq) && cut < u64(len(r.src)) && record_too_wide(r, lo, cut) {
			records_stop(r, tape.record_too_long(lo))
			break
		}
		if err := find_begin(&f, r.src, format, steps, r.opts.dups, read, respell, rewalk, &room, allocator); err != nil {
			records_stop(r, hook.memory_budget_error(&m.main, err))
			break
		}
		regs: hook.Regs
		w := walk(r, lo, cut, false, &f, &regs, allocator, &ctx)
		if !w.ok {
			r.err = hook.memory_budget_error(&m.main, r.err)
			if r.err == nil && window_too_wide(r) {
				records_stop(r, tape.record_too_long(r.pos if r.at != .Start else 0))
				break
			}
			if r.err != nil && (r.skip_bad || r.quarantine != nil) {
				if bad, skipped := tape.records_skip(r); skipped {
					if !quarantine_add(r, bad) {
						break
					}
					r.index += 1
					if r.quarantine == nil {
						out[n], answers[n] = {lo = bad.lo, hi = bad.hi, err = bad.err}, {outcome = .Missing}
						n += 1
					}
					continue
				}
			}
			break
		}
		if record_too_wide(r, lo, w.hi) {
			records_stop(r, tape.record_too_long(lo))
			break
		}
		if w.again {
			if err := find_begin(&f, r.src, format, steps, r.opts.dups, read, respell, rewalk, &room, allocator, true); err != nil {
				records_stop(r, hook.memory_budget_error(&m.main, err))
				break
			}
			regs = {}
			a := walk(r, lo, cut, true, &f, &regs, allocator, &ctx)
			w.res, w.tolerated = a.res, a.tolerated
		}
		_, werr, _ := hook.walk_error(w.res, rules)
		answer, err := finder_result(&f, werr, w.tolerated)
		if err != nil {
			answer = {outcome = .Missing}
		}
		rec := record_end(r, lo, w.hi, hook.memory_budget_error(&m.main, err))
		if rec.err != nil && r.quarantine != nil {
			if !quarantine_record(r, rec) {
				break
			}
			continue
		}
		out[n], answers[n] = rec, answer
		n += 1
	}
	records_window_end(r)
	return
}

records_scan :: proc(r: ^tape.Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, format: ^tape.Format, rules: ^tape.Rules, read: tape.Read_Options, caller: runtime.Allocator, rewalk: Rewalk, $bound: proc "contextless" (src: []u8, depth: u64) -> u64, $frame: Record_Frame, $walk: proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^Scanner, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> Record_Walk) -> (n: int) {
	if refused := scan_refused(format, r.opts, demand); refused != nil {
		records_stop(r, refused)
		return
	}
	read := read
	read.stop_early &&= r.framing == .Lines || r.framing == .Seq
	out := out
	out = out[:min(len(out), len(docs))]
	// The documents of the batch are in the records' block, which the last batch's documents leave.
	block := tape.record_block_batch(&r.block, caller)
	m: hook.Read_Budget
	scratch_local: hook.Memory_Budget
	frames: [FRAME_DEPTH]u64 = ---
	room: Scan_Room = ---
	h: Scanner
	// Each record is built in one node room the batch lends, and its nodes are copied out to their own block. A memory
	// budget counts each record's own room instead.
	lent: []tape.Node
	for n < len(out) {
		allocator := hook.read_budget(&m, r.opts, block)
		scratch := hook.scratch(r.opts, allocator, &scratch_local)
		budget := &m.main if r.opts.budget.memory != 0 else nil
		lo, cut, framed := frame(r, allocator)
		if !framed {
			r.err = hook.memory_budget_error(&m.main, r.err)
			if r.err == nil && window_too_wide(r) {
				records_stop(r, tape.record_too_long(r.pos if r.at != .Start else 0))
				break
			}
			if r.err != nil && (r.skip_bad || r.quarantine != nil) {
				if bad, skipped := tape.records_skip(r); skipped {
					if !quarantine_add(r, bad) {
						break
					}
					r.index += 1
					if r.quarantine == nil {
						out[n], docs[n] = {lo = bad.lo, hi = bad.hi, err = bad.err}, {}
						n += 1
					}
					continue
				}
			}
			break
		}
		if (r.framing == .Lines || r.framing == .Seq) && cut < u64(len(r.src)) && record_too_wide(r, lo, cut) {
			records_stop(r, tape.record_too_long(lo))
			break
		}
		depth := min(read_depth(r.opts), cut - lo)
		most := node_most(bound(r.src[lo:cut], depth), r.opts)
		if r.opts.budget.memory == 0 && lent == nil {
			raw, err := tape.record_block_take(&r.block, SCAN_NODES * size_of(tape.Node), align_of(tape.Node))
			if err != nil {
				records_stop(r, err)
				break
			}
			lent = ([^]tape.Node)(raw_data(raw))[:SCAN_NODES]
		}
		if err := scanner_restart(&h, r.src, format, demand, r.opts.dups, read, rewalk, SCAN_NODES, most, frames[:min(depth, FRAME_DEPTH)], &room, allocator, lent, budget, scratch); err != nil {
			records_stop(r, hook.memory_budget_error(&m.main, err))
			break
		}
		regs := builder_regs(&h.b)
		w := walk(r, lo, cut, false, &h, &regs, allocator, &h.b.ctx)
		if !w.ok || w.again {
			// The walk's tokens are dropped with what the scanner built of them.
			_, _ = scanner_end(&h, regs, 0, runtime.Allocator_Error.Out_Of_Memory)
			if lent != nil {
				lent = h.b.doc.nodes
			}
			if !w.ok {
				r.err = hook.memory_budget_error(&m.main, r.err)
				if r.err == nil && window_too_wide(r) {
					records_stop(r, tape.record_too_long(r.pos if r.at != .Start else 0))
					break
				}
				if r.err != nil && (r.skip_bad || r.quarantine != nil) {
					if bad, skipped := tape.records_skip(r); skipped {
						if !quarantine_add(r, bad) {
							break
						}
						r.index += 1
						if r.quarantine == nil {
							out[n], docs[n] = {lo = bad.lo, hi = bad.hi, err = bad.err}, {}
							n += 1
						}
						continue
					}
				}
				break
			}
			if record_too_wide(r, lo, w.hi) {
				records_stop(r, tape.record_too_long(lo))
				break
			}
			if err := scanner_restart(&h, r.src, format, demand, r.opts.dups, read, rewalk, SCAN_NODES, most, frames[:min(depth, FRAME_DEPTH)], &room, allocator, lent, budget, scratch); err != nil {
				records_stop(r, hook.memory_budget_error(&m.main, err))
				break
			}
			regs = builder_regs(&h.b)
			a := walk(r, lo, cut, true, &h, &regs, allocator, &h.b.ctx)
			w.res, w.tolerated = a.res, a.tolerated
		}
		if record_too_wide(r, lo, w.hi) {
			_, _ = scanner_end(&h, regs, 0, runtime.Allocator_Error.Out_Of_Memory)
			if lent != nil {
				lent = h.b.doc.nodes
			}
			records_stop(r, tape.record_too_long(lo))
			break
		}
		root_close, werr, _ := hook.walk_error(w.res, rules)
		if werr == nil && r.opts.pieces != nil {
			// A window's bytes may go once the batch ends, so the document holds the bytes it reads.
			if e := scanner_hold(&h, regs, r.src); e != nil {
				werr = e
			}
		}
		doc, e := scanner_end(&h, regs, root_close, werr)
		if lent != nil {
			lent = h.b.doc.nodes
			if e == nil {
				e = record_nodes_own(&r.block, &doc)
			}
		}
		e = read_end(&doc, e, &m.main, w.tolerated, block)
		rec := record_end(r, lo, w.hi, e)
		if rec.err != nil && r.quarantine != nil {
			if !quarantine_record(r, rec) {
				break
			}
			continue
		}
		out[n], docs[n] = rec, doc
		n += 1
	}
	records_window_end(r)
	return
}

// Whether a record spanning `[lo, hi)` exceeds `Records.max_bytes`.
@(private)
record_too_wide :: #force_inline proc "contextless" (r: ^tape.Records, lo, hi: u64) -> bool {
	return r.max_bytes != 0 && hi > lo && hi - lo > r.max_bytes
}

// Whether an unfinished streaming window holds more unread bytes than `Records.max_bytes`.
@(private)
window_too_wide :: #force_inline proc "contextless" (r: ^tape.Records) -> bool {
	if r.max_bytes == 0 || r.opts.pieces == nil || r.at == .Done {
		return false
	}
	keep := r.pos if r.at != .Start else 0
	return u64(len(r.src)) > keep && u64(len(r.src)) - keep > r.max_bytes
}

// Appends `bad` to `r.quarantine` when set. On OOM stops `r` with the allocator error and returns false.
@(private, cold)
quarantine_add :: proc(r: ^tape.Records, bad: tape.Bad_Record) -> bool {
	if r.quarantine == nil {
		return true
	}
	if _, err := append(r.quarantine, bad); err != nil {
		records_stop(r, err)
		return false
	}
	return true
}

@(private, cold)
quarantine_record :: proc(r: ^tape.Records, rec: tape.Record) -> bool {
	if r.quarantine == nil {
		return true
	}
	text: []u8
	if rec.lo <= rec.hi && rec.hi <= u64(len(r.src)) {
		text = r.src[rec.lo:rec.hi]
	}
	return quarantine_add(r, {lo = rec.lo, hi = rec.hi, err = rec.err, text = text})
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
	return {lo = lo, hi = hi, err = err, key = r.key}
}

// Moves the nodes of `doc`, built in a lent room, to a block of their own.
@(private)
record_nodes_own :: proc(b: ^tape.Record_Block, doc: ^tape.Document) -> tape.Error {
	raw, err := tape.record_block_take(b, len(doc.nodes) * size_of(tape.Node), align_of(tape.Node))
	if err != nil {
		tape.destroy(doc)
		return err
	}
	nodes := ([^]tape.Node)(raw_data(raw))[:len(doc.nodes)]
	copy(nodes, doc.nodes)
	doc.nodes = nodes
	return nil
}

// `tape.Bad_Option` for records at `path` that the records of `format` under `framing` and `opts` do not take: a path
// under a framing but `.Elements` and `.Members`, one with a step other than a `Name` or an `Index` from the start,
// which a read finds before the records with no document, and under a path a policy `opts.dups` that a path read
// refuses. Else nil.
records_path_refused :: proc "contextless" (format: ^tape.Format, framing: tape.Framing, path: []tape.Step, opts: tape.Options) -> tape.Error {
	if len(path) == 0 {
		return nil
	}
	if framing != .Elements && framing != .Members {
		return tape.Bad_Option{"path"}
	}
	for step in path {
		#partial switch s in step {
		case tape.Name:
		case tape.Index:
			if s < 0 {
				return tape.Bad_Option{"path"}
			}
		case:
			return tape.Bad_Option{"path"}
		}
	}
	if !path_dups(format, opts) {
		return tape.Bad_Option{"dups"}
	}
	return nil
}

// The refusal that ends the records at a path reaching a value of another kind than the framing takes, the same in
// every format.
records_kind_refusal :: #force_inline proc "contextless" () -> tape.Error {
	return tape.Bad_Option{"framing"}
}
