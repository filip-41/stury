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

// Reads the next records of `r` into `out` and judges each. With `batched` it reads a part of a format's batch, whose
// earlier records' errors the records' `faults` keep.
records_validate :: proc(r: ^tape.Records, out: []tape.Record, format: ^tape.Format, rules: ^tape.Rules, caller: runtime.Allocator, $frame: Record_Frame, $walk: proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> Record_Walk, batched := false) -> (n: int) {
	if !validate_dups(format, r.opts) {
		records_stop(r, tape.Bad_Option{"dups"})
		return
	}
	if !batched {
		clear(&r.faults)
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
		out[n] = record_end(r, lo, w.hi, hook.memory_budget_error(&m, err), caller) or_break
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
	clear(&r.faults)
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
			out[n] = record_end(r, lo, w.hi, hook.memory_budget_error(&m, werr), caller) or_break
			answers[n] = {outcome = .Missing}
			n += 1
			continue
		}
		answers[n] = finder_answer(&f)
		answers[n].tolerated = w.tolerated
		out[n], _ = record_end(r, lo, w.hi, nil, caller)
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
	clear(&r.faults)
	// The documents of the batch are in the records' block, which the last batch's documents leave.
	block := record_block_batch(&r.block, caller)
	m: hook.Memory_Budget
	frames: [FRAME_DEPTH]u64 = ---
	room: Scan_Room = ---
	h: Scanner
	// Each record is built in one node room the batch lends, and its nodes are copied out to their own block. A memory
	// budget counts each record's own room instead.
	lent: []tape.Node
	for n < len(out) {
		allocator := read_allocator(&m, r.opts, block)
		lo, cut := frame(r) or_break
		depth := min(read_depth(r.opts), cut - lo)
		most := node_most(bound(r.src[lo:cut], depth), r.opts)
		if r.opts.budget.memory == 0 && lent == nil {
			raw, err := record_block_take(&r.block, SCAN_NODES * size_of(tape.Node), align_of(tape.Node))
			if err != nil {
				records_stop(r, err)
				break
			}
			lent = ([^]tape.Node)(raw_data(raw))[:SCAN_NODES]
		}
		if err := scanner_restart(&h, r.src, format, demand, r.opts.dups, read, rewalk, SCAN_NODES, most, frames[:min(depth, FRAME_DEPTH)], &room, allocator, lent); err != nil {
			records_stop(r, hook.memory_budget_error(&m, err))
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
				break
			}
			if err := scanner_restart(&h, r.src, format, demand, r.opts.dups, read, rewalk, SCAN_NODES, most, frames[:min(depth, FRAME_DEPTH)], &room, allocator, lent); err != nil {
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
		if lent != nil {
			lent = h.b.doc.nodes
			if e == nil {
				e = record_nodes_own(&r.block, &doc)
			}
		}
		e = read_end(&doc, e, &m, w.tolerated, block)
		out[n] = record_end(r, lo, w.hi, e, caller) or_break
		docs[n] = doc
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

// The record from `lo` to `hi` with error `err`, counted among those read, its error kept in the records' `faults`,
// which `caller` holds. False with the records ended when memory for it is refused.
@(private)
record_end :: #force_inline proc(r: ^tape.Records, lo, hi: u64, err: tape.Error, caller: runtime.Allocator) -> (rec: tape.Record, ok: bool) {
	rec = {lo = lo, hi = hi, key = r.key}
	if err != nil {
		if r.faults.allocator.procedure == nil {
			r.faults.allocator = caller
		}
		if _, e := append(&r.faults, err); e != nil {
			records_stop(r, e)
			return
		}
		rec.err = u32(len(r.faults))
	}
	r.index += 1
	return rec, true
}

// Moves the nodes of `doc`, built in a lent room, to a block of their own.
@(private)
record_nodes_own :: proc(b: ^tape.Record_Block, doc: ^tape.Document) -> tape.Error {
	raw, err := record_block_take(b, len(doc.nodes) * size_of(tape.Node), align_of(tape.Node))
	if err != nil {
		tape.destroy(doc)
		return err
	}
	nodes := ([^]tape.Node)(raw_data(raw))[:len(doc.nodes)]
	copy(nodes, doc.nodes)
	doc.nodes = nodes
	return nil
}

// `tape.Bad_Option{"path"}` for a `path` the records under `framing` do not take: any under `.Lines` and
// `.Concatenated`, and one with a step other than a `Name` or an `Index` from the start, which a read finds before the
// records with no document. Else nil.
records_path_refused :: proc "contextless" (framing: tape.Framing, path: []tape.Step) -> tape.Error {
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
	return nil
}

// The allocator of the documents of the next batch of `b`, whose last batch's documents it frees. `caller` gives the
// chunks when `b` has none.
@(private)
record_block_batch :: proc(b: ^tape.Record_Block, caller: runtime.Allocator) -> runtime.Allocator {
	if b.backing.procedure == nil {
		b.backing = caller
		b.outgrown.allocator = caller
	}
	if len(b.outgrown) > 0 {
		want := b.spent + b.used
		for c in b.outgrown {
			runtime.mem_free_with_size(raw_data(c), len(c), b.backing)
		}
		clear(&b.outgrown)
		runtime.mem_free_with_size(raw_data(b.chunk), len(b.chunk), b.backing)
		b.chunk, b.spent = nil, 0
		if data, err := runtime.mem_alloc_non_zeroed(want, 64, b.backing); err == nil {
			b.chunk = data
		}
	}
	b.used, b.last = 0, -1
	return {record_block_proc, b}
}

@(private)
RECORD_CHUNK :: 64 * 1024

@(private)
record_block_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	b := (^tape.Record_Block)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		out, err := record_block_take(b, size, alignment)
		if err == nil && mode == .Alloc {
			runtime.mem_zero(raw_data(out), size)
		}
		return out, err
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			return record_block_proc(data, .Alloc if mode == .Resize else .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
		}
		at := int(uintptr(old_memory) - uintptr(raw_data(b.chunk)))
		if at == b.last && at + size <= len(b.chunk) {
			// The last allocation grows or shrinks where it is.
			b.used = at + size
			if mode == .Resize && size > old_size {
				runtime.mem_zero(&b.chunk[at + old_size], size - old_size)
			}
			return b.chunk[at:][:size], nil
		}
		if size <= old_size {
			return ([^]u8)(old_memory)[:size], nil
		}
		out, err := record_block_take(b, size, alignment)
		if err != nil {
			return nil, err
		}
		runtime.mem_copy_non_overlapping(raw_data(out), old_memory, old_size)
		if mode == .Resize {
			runtime.mem_zero(&out[old_size], size - old_size)
		}
		return out, nil
	case .Free, .Free_All:
		return nil, nil
	case .Query_Features:
		if set := (^runtime.Allocator_Mode_Set)(old_memory); set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Free_All, .Query_Features}
		}
		return nil, nil
	}
	return nil, .Mode_Not_Implemented
}

// Takes `size` bytes aligned to `alignment` from the chunk of `b`, starting a larger chunk when it has no room.
@(private)
record_block_take :: proc(b: ^tape.Record_Block, size, alignment: int) -> ([]u8, runtime.Allocator_Error) {
	align := max(alignment, 1)
	base := uintptr(raw_data(b.chunk))
	at := int((base + uintptr(b.used) + uintptr(align - 1)) &~ uintptr(align - 1) - base)
	if b.chunk == nil || at + size > len(b.chunk) {
		grown := max(2 * len(b.chunk), RECORD_CHUNK, size + align)
		data, err := runtime.mem_alloc_non_zeroed(grown, 64, b.backing)
		if err != nil {
			return nil, err
		}
		if b.chunk != nil {
			if _, err = append(&b.outgrown, b.chunk); err != nil {
				runtime.mem_free_with_size(raw_data(data), grown, b.backing)
				return nil, err
			}
			b.spent += b.used
		}
		b.chunk, b.used, at = data, 0, 0
	}
	b.last, b.used = at, at + size
	return b.chunk[at:][:size], nil
}
