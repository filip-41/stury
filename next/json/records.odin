package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The records of a text read in one walk, whose gap table goes on from each record to the next, so that a record is
// read with the gaps the records before it taught. Each record is judged as a read of its bytes alone judges them, in
// place in the text.

// The records of a text of a JSON spec, which `records_open` makes and each call of `records_validate`,
// `records_find` or `records_scan` reads in batches, as `tape.Records` says.
Records :: struct {
	using records: tape.Records,
	spec:          Spec,
	// What the walk learned, kept from record to record. A walk of any spec and hook is laid out as this one, or as its
	// front when it has no `LAX`.
	walk:          Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS),
	frame:         build.Frame(build.Frame_Level),
	// In a text in pieces, the first byte of the window the gaps were last checked against, and under `.Lines`/`.Seq`
	// where the framing stopped at the last window's end: `open` once the record at `pos` has begun, its delimiter
	// looked for up to `seen`.
	window:        u64,
	seen:          u64,
	open:          bool,
	// Under `.Seq`, `seq_rs` is set once a 0x1E record separator has been passed, and `seq_unframed` marks a record
	// framed before the first 0x1E. Under `.Concatenated` in pieces, `skip_line` skips to the next LF after a fault.
	seq_rs:        bool,
	seq_unframed:  bool,
	skip_line:     bool,
	// The reads of the spec and `LAX` the records were opened with, which `records_open` picks, so that a caller of one
	// spec links the walks of that spec alone: a read that switched on `spec` here would reach every spec's walks and
	// no build could drop the ones it never reads.
	validate_as:   Records_Validate,
	find_as:       Records_Find,
	scan_as:       Records_Scan,
}

// The batch reads one spec and `LAX` give, each an instance of `records_validate_as` and its kin, which `records_open`
// picks.
@(private)
Records_Validate :: #type proc(r: ^Records, out: []tape.Record, allocator: runtime.Allocator) -> int
@(private)
Records_Find :: #type proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read: tape.Read_Options, allocator: runtime.Allocator) -> int
@(private)
Records_Scan :: #type proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read: tape.Read_Options, allocator: runtime.Allocator) -> int

// The three batch reads of one spec and `LAX`, which `records_open` picks.
@(private)
Records_Reads :: struct {
	validate: Records_Validate,
	find:     Records_Find,
	scan:     Records_Scan,
}

#assert(size_of(Walk(.Json5, build.Scanner, false, build.SCANNER_CAPS)) <= size_of(Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS)))
#assert(offset_of(Walk(.Json5, build.Scanner, false, build.SCANNER_CAPS), gaps) == offset_of(Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS), gaps))

// A record's walk reads at most this far past its line, so a value that runs on past its line is refused after a
// bounded read, while every block the walk reads within the line has its bytes ahead.
@(private)
RECORD_AHEAD :: 256

// Opens the records of `src`, a text of `spec` framed as `framing`, each read under `opts`. Under `.Elements` and
// `.Members` the records are those of the container `path` reaches, the root for none, as `tape.Records` says: the
// framing passes the members and elements before it, judging each, and those after it. A path of more than seven steps,
// and in a text in pieces a value off the path that a window cuts more than seven levels deep, take memory from the
// context's allocator, which `tape.destroy_records` frees. The budget's limits hold for each
// record, but `Budget.steps` under `.Elements` and `.Members`, which counts the containers of the whole text. Options
// of another format family, and a `path` the framing or the policy for repeated keys does not take, end the records
// with `tape.Bad_Option` before any is read, as `build.records_path_refused` says. A text in pieces opens with its
// first window, as `tape.Records` says.
records_open :: #force_inline proc(src: []u8, framing := tape.Framing.Lines, spec := Spec.Json, opts := Options{}, path: []tape.Step = nil) -> (r: Records) {
	if spec > max(Spec) {
		panic("json: spec out of range")
	}
	r.src, r.framing, r.spec, r.opts, r.pos, r.path = src, framing, spec, opts, u64(spell.bom_length(src)), path
	if opts.pieces != nil {
		// The byte order mark is judged once the first record is framed, when the window may hold it.
		r.src, r.pos = tape.piece_src(src, opts.pieces.from), 0
	}
	if e := build.records_path_refused(&FORMATS[spec], framing, path, opts); e != nil {
		r.err, r.at = e, .Done
	} else if e := build.frame_init(&r.frame, path); e != nil {
		r.err, r.at = e, .Done
	}
	r.release = records_release
	if framing == .Concatenated {
		r.skip = records_skip_proc
	}
	if e := tape.options_refused(&FORMATS[spec], opts); e != nil {
		r.err, r.at = e, .Done
	}
	walk_init(&r.walk, src, nil, (^hook.No_Hooks)(nil), nil, {}, nil, build.read_depth(opts), opts.tolerate, opts.budget.steps)
	// The reads of this spec and `LAX`. The switch folds at the call site of an inlined `records_open` with a constant
	// spec and options, so the walks of the specs and `LAX` a caller never opens are dropped.
	lax := build.read_lax(opts)
	chosen: Records_Reads
	if spec == .Json {
		if lax {
			chosen = records_reads_of(.Json, true)
		} else {
			chosen = records_reads_of(.Json, false)
		}
	} else if spec == .Jsonc {
		if lax {
			chosen = records_reads_of(.Jsonc, true)
		} else {
			chosen = records_reads_of(.Jsonc, false)
		}
	} else {
		if lax {
			chosen = records_reads_of(.Json5, true)
		} else {
			chosen = records_reads_of(.Json5, false)
		}
	}
	r.validate_as, r.find_as, r.scan_as = chosen.validate, chosen.find, chosen.scan
	return
}

// Reads the next records of `r` and judges each, as `validate` judges its bytes alone, keeping in `out` those that do
// not read. Returns how many it filled, and fewer than `len(out)` once the records have ended, when `err` says why, nil
// at the text's end. Only a
// record nesting past `WALK_LEVELS` allocates, for its open levels. Needs `READ_STACK` bytes of stack and faults on a
// thread with less.
@(require_results)
records_validate :: #force_inline proc(r: ^Records, out: []tape.Record, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	return r.validate_as(r, out, allocator)
}

// Reads the next records of `r` into `out`, and for each the first value `path` reaches in it into the same place of
// `answers`, as `find` reads its bytes alone, with every offset from the text's first byte. Returns how many it filled,
// at most the shorter of the two slices, and fewer once the records have ended. Under `.Elements` and `.Members` the
// walk reads each value to its end whatever `read.stop_early` says, as the next starts there. Allocates as `find` does.
// Needs `READ_STACK` bytes of stack and faults on a thread with less.
@(require_results)
records_find :: #force_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	return r.find_as(r, path, out, answers, read, allocator)
}

// Reads the next records of `r` into `out`, and for each the document of its nodes the paths of `demand` reach into the
// same place of `docs`, as `scan` reads its bytes alone. Returns how many it filled, at most the shorter of the two
// slices, and fewer once the records have ended. Each document's nodes point into the text, and the documents are in the
// records' block, valid until the next call or `tape.destroy_records`, as `tape.Record_Block` says, so the memory the
// records hold is bounded by the slices a call is given. Under `.Elements` and `.Members` the walk
// reads each value to its end whatever `read.stop_early` says, as the next starts there. Needs `READ_STACK` bytes of
// stack and faults on a thread with less.
@(require_results)
records_scan :: #force_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	return r.scan_as(r, demand, out, docs, read, allocator)
}

// Builds a worker-local `Records` cursor for parallel chunk `chunk`, with locked `scratch` and serial runner.
@(private)
chunk_records :: #force_inline proc(parent: ^Records, $S: Spec, chunk: ^build.Record_Chunk, k: int, scratch: runtime.Allocator) -> Records {
	lr := Records {
		records = {src = parent.src[:chunk.hi], opts = parent.opts, framing = parent.framing, pos = chunk.lo, at = .Open, max_bytes = parent.max_bytes},
		spec    = S,
		seq_rs  = parent.seq_rs || k > 0,
	}
	lr.opts.runner = nil
	lr.opts.scratch = scratch
	walk_init(&lr.walk, lr.src, nil, (^hook.No_Hooks)(nil), nil, {}, nil, build.read_depth(lr.opts), lr.opts.tolerate, lr.opts.budget.steps)
	return lr
}

@(private)
sync_seq_rs :: #force_inline proc "contextless" (r: ^Records) {
	if r.framing == .Seq && r.pos > 0 && r.src[r.pos - 1] == 0x1e {
		r.seq_rs = true
	}
}

@(private)
cut_json_chunks :: proc "contextless" (r: ^Records, chunks: []build.Record_Chunk) -> int {
	delim := u8('\n') if r.framing == .Lines else 0x1e
	return build.cut_delim_chunks(r.src, r.pos, delim, r.opts.runner, chunks)
}

@(private)
records_validate_as :: #force_no_inline proc(r: ^Records, out: []tape.Record, $S: Spec, $LAX: bool, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records, a: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return record_frame_of(r, S, LAX, hook.No_Hooks, a)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walked(container_of(r, Records, "records"), S, LAX, lo, cut, alone, h, regs, a, ctx, hook.no_hook)
	}
	if (r.framing == .Lines || r.framing == .Seq) && r.opts.runner != nil && r.opts.runner.threads > 0 && r.opts.pieces == nil && r.at != .Done && len(out) > 0 && len(r.src) - int(r.pos) >= build.parallel_records_from() && build.validate_dups(&FORMATS[S], r.opts) {
		chunks: [build.MAX_RECORD_CHUNKS]build.Record_Chunk
		if nc := cut_json_chunks(r, chunks[:]); nc >= 2 {
			run_chunk :: proc(data: rawptr, chunk: ^build.Record_Chunk, k: int, max_bad: int, bad_out: ^[dynamic]build.Bad_Entry, alloc, scratch: runtime.Allocator) {
				cframe :: #force_inline proc(r: ^tape.Records, a: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
					return record_frame_of(r, S, LAX, hook.No_Hooks, a)
				}
				cwalk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
					return record_walked(container_of(r, Records, "records"), S, LAX, lo, cut, alone, h, regs, a, ctx, hook.no_hook)
				}
				lr := chunk_records((^Records)(data), S, chunk, k, scratch)
				bad_out.allocator = alloc
				for len(bad_out) < max_bad && lr.at != .Done {
					buf: [1]tape.Record
					got := build.records_validate(&lr, buf[:], &FORMATS[S], &RULES, alloc, cframe, cwalk)
					if got == 0 {
						break
					}
					if _, err := append(bad_out, build.Bad_Entry{rec = buf[0], index_after = lr.index, pos_after = lr.pos}); err != nil {
						chunk.fatal = err
						break
					}
				}
				chunk.count = lr.index
				chunk.end_pos = lr.pos
				if chunk.fatal == nil {
					chunk.fatal = lr.err
				}
			}
			n, done := build.records_validate_chunks(r, out, chunks[:nc], caller, r, run_chunk)
			sync_seq_rs(r)
			if done {
				return n
			}
			return n + build.records_validate(r, out[n:], &FORMATS[S], &RULES, caller, frame, walk)
		}
	}
	return build.records_validate(r, out, &FORMATS[S], &RULES, caller, frame, walk)
}

@(private)
records_find_as :: #force_no_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	rewalk :: proc "contextless" (h: ^build.Finder, lo: u64) -> hook.Walk_Result {
		regs: hook.Regs
		return walk_again((^Walk(S, build.Finder, LAX, build.FINDER_CAPS))(h.walk), h.src, lo, &regs, build.finder_hook)
	}
	frame :: #force_inline proc(r: ^tape.Records, a: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return record_frame_of(r, S, LAX, build.Finder, a)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walked(container_of(r, Records, "records"), S, LAX, lo, cut, alone, h, regs, a, ctx, build.finder_hook)
	}
	cap := min(len(out), len(answers))
	if (r.framing == .Lines || r.framing == .Seq) && r.opts.runner != nil && r.opts.runner.threads > 0 && r.opts.pieces == nil && r.quarantine == nil && r.at != .Done && cap >= 64 && len(r.src) - int(r.pos) >= build.parallel_records_from() && build.path_dups(&FORMATS[S], r.opts) {
		chunks: [build.MAX_RECORD_CHUNKS]build.Record_Chunk
		if nc := cut_json_chunks(r, chunks[:]); nc >= 2 {
			Find_Data :: struct {
				r:       ^Records,
				path:    []tape.Step,
				out:     []tape.Record,
				answers: []tape.Span_Answer,
				read:    tape.Read_Options,
			}
			count_chunk :: proc(data: rawptr, chunk: ^build.Record_Chunk, k: int) {
				d := (^Find_Data)(data)
				chunk.count = count_delim_records(d.r.src, chunk.lo, chunk.hi, d.r.framing, S)
			}
			run_chunk :: proc(data: rawptr, chunk: ^build.Record_Chunk, k: int, alloc, scratch: runtime.Allocator) {
				crew :: proc "contextless" (h: ^build.Finder, lo: u64) -> hook.Walk_Result {
					regs: hook.Regs
					return walk_again((^Walk(S, build.Finder, LAX, build.FINDER_CAPS))(h.walk), h.src, lo, &regs, build.finder_hook)
				}
				cframe :: #force_inline proc(r: ^tape.Records, a: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
					return record_frame_of(r, S, LAX, build.Finder, a)
				}
				cwalk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
					return record_walked(container_of(r, Records, "records"), S, LAX, lo, cut, alone, h, regs, a, ctx, build.finder_hook)
				}
				d := (^Find_Data)(data)
				if chunk.limit == 0 {
					chunk.end_pos = chunk.lo
					return
				}
				lr := chunk_records(d.r, S, chunk, k, scratch)
				chunk.done = build.records_find(&lr, d.path, d.out[chunk.offset:][:chunk.limit], d.answers[chunk.offset:][:chunk.limit], &FORMATS[S], &RULES, d.read, alloc, tape.number_respell, crew, cframe, cwalk)
				chunk.end_pos = lr.pos
				chunk.fatal = lr.err
			}
			fd := Find_Data{r = r, path = path, out = out, answers = answers, read = read}
			if n, done := build.records_find_chunks(r, &FORMATS[S], path, chunks[:nc], cap, caller, &fd, count_chunk, run_chunk); done {
				sync_seq_rs(r)
				return n
			}
		}
	}
	return build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, tape.number_respell, rewalk, frame, walk)
}

@(private)
records_scan_as :: #force_no_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	rewalk :: proc "contextless" (h: ^build.Scanner, regs: ^hook.Regs, lo: u64) -> hook.Walk_Result {
		return walk_again((^Walk(S, build.Scanner, LAX, build.SCANNER_CAPS))(h.walk), h.b.doc.src, lo, regs, build.scanner_hook)
	}
	frame :: #force_inline proc(r: ^tape.Records, a: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return record_frame_of(r, S, LAX, build.Scanner, a)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walked(container_of(r, Records, "records"), S, LAX, lo, cut, alone, h, regs, a, ctx, build.scanner_hook)
	}
	cap := min(len(out), len(docs))
	if (r.framing == .Lines || r.framing == .Seq) && r.opts.runner != nil && r.opts.runner.threads > 0 && r.opts.pieces == nil && r.quarantine == nil && r.at != .Done && cap >= 64 && len(r.src) - int(r.pos) >= build.parallel_records_from() {
		chunks: [build.MAX_RECORD_CHUNKS]build.Record_Chunk
		if nc := cut_json_chunks(r, chunks[:]); nc >= 2 {
			Scan_Data :: struct {
				r:      ^Records,
				demand: ^tape.Demand,
				out:    []tape.Record,
				docs:   []tape.Document,
				read:   tape.Read_Options,
			}
			count_chunk :: proc(data: rawptr, chunk: ^build.Record_Chunk, k: int) {
				d := (^Scan_Data)(data)
				chunk.count = count_delim_records(d.r.src, chunk.lo, chunk.hi, d.r.framing, S)
			}
			run_chunk :: proc(data: rawptr, chunk: ^build.Record_Chunk, k: int, block: ^tape.Record_Block, batch_alloc, scratch: runtime.Allocator) {
				crew :: proc "contextless" (h: ^build.Scanner, regs: ^hook.Regs, lo: u64) -> hook.Walk_Result {
					return walk_again((^Walk(S, build.Scanner, LAX, build.SCANNER_CAPS))(h.walk), h.b.doc.src, lo, regs, build.scanner_hook)
				}
				cframe :: #force_inline proc(r: ^tape.Records, a: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
					return record_frame_of(r, S, LAX, build.Scanner, a)
				}
				cwalk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
					return record_walked(container_of(r, Records, "records"), S, LAX, lo, cut, alone, h, regs, a, ctx, build.scanner_hook)
				}
				d := (^Scan_Data)(data)
				if chunk.limit == 0 {
					chunk.end_pos = chunk.lo
					return
				}
				lr := chunk_records(d.r, S, chunk, k, scratch)
				chunk.done = build.records_scan(&lr, d.demand, d.out[chunk.offset:][:chunk.limit], d.docs[chunk.offset:][:chunk.limit], &FORMATS[S], &RULES, d.read, block.backing, crew, node_bound, cframe, cwalk)
				for i in 0 ..< chunk.done {
					if d.docs[chunk.offset + i].allocator.procedure != nil {
						d.docs[chunk.offset + i].allocator = batch_alloc
					}
				}
				block^ = lr.block
				chunk.end_pos = lr.pos
				chunk.fatal = lr.err
			}
			sd := Scan_Data{r = r, demand = demand, out = out, docs = docs, read = read}
			if n, done := build.records_scan_chunks(r, &FORMATS[S], demand, docs, chunks[:nc], cap, caller, &sd, count_chunk, run_chunk); done {
				sync_seq_rs(r)
				return n
			}
		}
	}
	return build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, rewalk, node_bound, frame, walk)
}

// Counts non-empty records in `src[lo:hi]` under `.Lines` or `.Seq`, matching `record_frame` exactly.
@(private)
count_delim_records :: proc "contextless" (src: []u8, lo, hi: u64, framing: tape.Framing, $S: Spec) -> (count: u64) #no_bounds_check {
	base := raw_data(src)
	end := base[hi:]
	pos := lo
	if framing == .Lines {
		for pos < hi {
			p := u64(intrinsics.ptr_sub(kernel.skip_ws(base[pos:], end), base))
			if p >= hi {
				break
			}
			count += 1
			if i := kernel.index_byte(src[p:hi], '\n'); i >= 0 {
				pos = p + u64(i) + 1
			} else {
				break
			}
		}
		return
	}
	for pos < hi {
		w := kernel.skip_ws(base[pos:], end)
		when S == .Json5 {
			for k := ws5_len(w, end); k > 0; k = ws5_len(w, end) {
				w = kernel.skip_ws(w[k:], end)
			}
		}
		p := u64(intrinsics.ptr_sub(w, base))
		if p >= hi {
			break
		}
		if src[p] == 0x1e {
			pos = p + 1
			continue
		}
		count += 1
		if i := kernel.index_byte(src[p:hi], 0x1e); i >= 0 {
			pos = p + u64(i) + 1
		} else {
			break
		}
	}
	return
}

// The reads of each spec and `LAX` that `records_open` gives the records, so that the record entry procs need no switch
// on the spec: each entry is an instance of `records_validate_as` and its kin, and a build links only those an opened
// record names.
@(private)
records_reads_of :: #force_inline proc($S: Spec, $LAX: bool) -> Records_Reads {
	return {
		validate = proc(r: ^Records, out: []tape.Record, allocator: runtime.Allocator) -> int {
			return records_validate_as(r, out, S, LAX, allocator)
		},
		find = proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read: tape.Read_Options, allocator: runtime.Allocator) -> int {
			return records_find_as(r, path, out, answers, S, LAX, read, allocator)
		},
		scan = proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read: tape.Read_Options, allocator: runtime.Allocator) -> int {
			return records_scan_as(r, demand, out, docs, S, LAX, read, allocator)
		},
	}
}

// `record_frame` of the records `r` of a JSON spec, in the walk for hook `H`.
@(private)
record_frame_of :: #force_inline proc(r: ^tape.Records, $S: Spec, $LAX: bool, $H: typeid, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	j := container_of(r, Records, "records")
	return record_frame(j, (^Walk(S, H, LAX, C))(&j.walk), allocator)
}

// Frees the levels of the records `r` at a long path.
@(private)
records_release :: proc(r: ^tape.Records) {
	build.frame_free(&container_of(r, Records, "records").frame)
}

// Walks the record from `lo` to `cut` for hook `h`, first in the walk of the whole text, or with `alone` as a text of
// its bytes alone.
@(private)
record_walked :: #force_inline proc(r: ^Records, $S: Spec, $LAX: bool, lo, cut: u64, alone: bool, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	w := (^Walk(S, H, LAX, C))(&r.walk)
	if alone {
		walked.res, walked.hi, walked.ok = record_alone(r, w, lo, cut, h, regs, allocator, ctx, on), cut, true
	} else {
		walked.res, walked.hi, walked.again, walked.ok = record_first(r, w, lo, cut, h, regs, allocator, ctx, on)
	}
	if r.framing == .Seq && !r.seq_unframed && !walked.again && (u8(walked.res) == 0 || u8(walked.res) == hook.WALK_STOPPED) && seq_cut_number(r.src[lo:cut], S) {
		walked.res = hook.walk_result(cut, u8(tape.Fault_Kind.Bad_Number), u8(Detail.Cut_Number))
	}
	walked.tolerated = w.tolerated
	return
}

// The next record's first byte, and under `.Lines` its line's end less a CR, under `.Seq` the next 0x1E or text end,
// and under `.Concatenated`, `.Elements` and `.Members` the text's end. False once the records have ended, or in a text
// in pieces once the window holds no more.
@(private)
record_frame :: #force_inline proc(r: ^Records, w: ^Walk($S, $H, $LAX, $C), allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
	if r.at == .Done {
		return
	}
	if r.framing == .Lines {
		when LAX {
			if r.opts.pieces != nil {
				return record_frame_window(r, (^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS))(w))
			}
		}
		n := u64(len(r.src))
		base := raw_data(r.src)
		lo = u64(intrinsics.ptr_sub(kernel.skip_ws(base[r.pos:], base[n:]), base))
		if lo == n {
			r.at = .Done
			return
		}
		cut = n
		if i := kernel.index_byte(r.src[lo:], '\n'); i >= 0 {
			cut = lo + u64(i)
		}
		r.pos = min(cut + 1, n)
		if r.src[cut - 1] == '\r' {
			cut -= 1
		}
		return lo, cut, true
	}
	if r.framing == .Seq {
		when LAX {
			if r.opts.pieces != nil {
				return record_frame_seq_window(r, (^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS))(w))
			}
		}
		return record_frame_seq(r, S)
	}
	if r.framing == .Concatenated {
		return record_frame_concat(r, (^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS))(w))
	}
	return record_frame_other(r, S, LAX, allocator)
}

// `record_frame` under `.Seq` (RFC 7464): skips white space and empty 0x1E separators, noting whether the record lies
// before the first 0x1E (`seq_unframed`).
@(private)
record_frame_seq :: proc "contextless" (r: ^Records, $S: Spec) -> (lo, cut: u64, ok: bool) #no_bounds_check {
	n := u64(len(r.src))
	base := raw_data(r.src)
	end := base[n:]
	for {
		w := kernel.skip_ws(base[r.pos:], end)
		when S == .Json5 {
			for k := ws5_len(w, end); k > 0; k = ws5_len(w, end) {
				w = kernel.skip_ws(w[k:], end)
			}
		}
		lo = u64(intrinsics.ptr_sub(w, base))
		if lo == n {
			r.pos, r.at = n, .Done
			return
		}
		if r.src[lo] == 0x1e {
			r.seq_rs = true
			r.pos = lo + 1
			continue
		}
		r.seq_unframed = !r.seq_rs
		cut = n
		if i := kernel.index_byte(r.src[lo:], 0x1e); i >= 0 {
			cut = lo + u64(i)
			r.pos = cut + 1
			r.seq_rs = true
		} else {
			r.pos = n
		}
		return lo, cut, true
	}
}

// `record_frame` under `.Seq` in a text in pieces.
@(private)
record_frame_seq_window :: proc "contextless" (r: ^Records, w: ^Walk($S, hook.No_Hooks, $LAX, hook.NO_HOOKS_CAPS)) -> (lo, cut: u64, ok: bool) #no_bounds_check {
	n := u64(len(r.src))
	more := !r.opts.pieces.last
	if !piece_start(r, w) {
		return
	}
	base := raw_data(r.src)
	end := base[n:]
	if !r.open {
		for {
			q := kernel.skip_ws(base[r.pos:], end)
			when S == .Json5 {
				for k := ws5_len(q, end); k > 0; k = ws5_len(q, end) {
					q = kernel.skip_ws(q[k:], end)
				}
			}
			r.pos = u64(intrinsics.ptr_sub(q, base))
			if r.pos == n {
				if !more {
					r.at = .Done
				}
				return
			}
			when S == .Json5 {
				if more && r.src[r.pos] >= 0xc2 && n - r.pos < 3 {
					return
				}
			}
			if r.src[r.pos] == 0x1e {
				r.seq_rs = true
				r.pos += 1
				continue
			}
			r.open, r.seen, r.seq_unframed = true, r.pos, !r.seq_rs
			break
		}
	}
	cut = n
	if i := kernel.index_byte(r.src[r.seen:], 0x1e); i >= 0 {
		cut = r.seen + u64(i)
		lo = r.pos
		r.open, r.pos, r.seq_rs = false, cut + 1, true
		return lo, cut, true
	}
	if more {
		r.seen = n
		return
	}
	lo = r.pos
	r.open, r.pos = false, n
	return lo, cut, true
}

// `record_frame` under `.Concatenated`: skips white space and comments to the next value's first byte, keeping `r.pos`
// there until the record's walk succeeds.
@(private)
record_frame_concat :: proc "contextless" (r: ^Records, w: ^Walk($S, hook.No_Hooks, $LAX, hook.NO_HOOKS_CAPS)) -> (lo, cut: u64, ok: bool) #no_bounds_check {
	when LAX {
		if r.opts.pieces != nil {
			if !piece_start(r, w) {
				return
			}
			if r.skip_line {
				n := u64(len(r.src))
				if i := kernel.index_byte(r.src[r.pos:], '\n'); i >= 0 {
					r.pos += u64(i) + 1
					r.skip_line = false
				} else {
					r.pos = n
					if !window_more(r) {
						r.skip_line = false
						r.at = .Done
					}
					return
				}
			}
		}
	}
	base := raw_data(r.src)
	n := u64(len(r.src))
	end := base[n:]
	q := element_gap(base[r.pos:], end, S)
	if q == nil {
		// Unfinished or invalid comment in the gap before the next value.
		_ = frame_tail(r, w)
		return
	}
	if q == end {
		if window_more(r) {
			r.pos = u64(intrinsics.ptr_sub(kernel.skip_ws(base[r.pos:], end), base))
		} else {
			r.pos, r.at = n, .Done
		}
		return
	}
	lo = u64(intrinsics.ptr_sub(q, base))
	r.pos = lo
	return lo, n, true
}

// `record_frame` under `.Elements` and `.Members`: the shared framing over JSON's grammar.
@(private)
record_frame_other :: #force_inline proc(r: ^Records, $S: Spec, $LAX: bool, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
	W :: Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS)
	when LAX {
		if r.opts.pieces != nil && r.at != .Done && !piece_start(r, (^W)(&r.walk)) {
			return
		}
	}
	open :: proc(r: ^Records, _, _: ^build.Frame_Level, object: bool, depth: u64) -> build.Frame_Step {
		return frame_open(r, (^W)(&r.walk), object, depth)
	}
	child :: #force_inline proc(r: ^Records, lv: ^build.Frame_Level, object: bool) -> (u64, build.Frame_Step) {
		return frame_child(r, (^W)(&r.walk), lv, object)
	}
	pass :: proc(r: ^Records, _: ^build.Frame_Level, depth: u64, allocator: runtime.Allocator) -> build.Frame_Step {
		return frame_pass(r, (^W)(&r.walk), depth, allocator)
	}
	tail :: proc(r: ^Records) -> build.Frame_Step {
		return frame_tail(r, (^W)(&r.walk))
	}
	lo, ok = build.frame_path(r, &r.frame, &FORMATS[S], &RULES, allocator, open, child, pass, tail)
	return lo, u64(len(r.src)), ok
}

// JSON's `open` of the framing: the container of kind `object` past the gap at `pos`, which takes a step of
// `Budget.steps` and a level of the depth the read takes. Any other value, a gap that fails and a container past the
// budget are `pass`'s to judge.
@(private)
frame_open :: proc "contextless" (r: ^Records, w: ^Walk($S, hook.No_Hooks, $LAX, hook.NO_HOOKS_CAPS), object: bool, depth: u64) -> build.Frame_Step {
	base := raw_data(r.src)
	end := base[len(r.src):]
	q := element_gap(base[r.pos:], end, S)
	if q == nil || q == end || q[0] != ('{' if object else '[') || depth + 1 > build.read_depth(r.opts) {
		return .Other
	}
	when LAX {
		if w.steps[0] <= 1 {
			return .Other
		}
		w.steps[0] -= 1
	}
	r.pos = u64(intrinsics.ptr_sub(q, base)) + 1
	return .Done
}

// JSON's `child` of the framing: past the open bracket, or the value at `pos` and the comma after it, the next value,
// past its key and colon in an object, or the container's close. A byte these checks refuse is judged by the walk
// entered where the step started, whose fault is the step's.
@(private)
frame_child :: #force_inline proc "contextless" (r: ^Records, w: ^Walk($S, hook.No_Hooks, $LAX, hook.NO_HOOKS_CAPS), lv: ^build.Frame_Level, object: bool) -> (u64, build.Frame_Step) #no_bounds_check {
	base := raw_data(r.src)
	end := base[len(r.src):]
	close := u8('}') if object else ']'
	place := PLACE_OPEN if lv.passed == 0 else PLACE_AFTER
	q := element_gap(base[r.pos:], end, S)
	if q != nil && q != end && place == PLACE_AFTER && q[0] != close {
		q = element_gap(q[1:], end, S) if q[0] == ',' else nil
		if q != nil && q != end && S == .Json && q[0] == close {
			q = nil
		}
	}
	if q == nil || q == end {
		return 0, frame_refused(r, w, place, r.pos, object)
	}
	at := u64(intrinsics.ptr_sub(q, base))
	if q[0] == close {
		return at + 1, .End
	}
	if !object {
		return at, .Done
	}
	h: Member_Key
	regs: hook.Regs
	res := key_walk(r, (^Walk(S, Member_Key, LAX, hook.NO_HOOKS_CAPS))(w), at, &h, &regs)
	if u8(res) != hook.WALK_STOPPED {
		return 0, frame_refused(r, w, place, r.pos, object)
	}
	past := u64(res) >> 16
	q = element_gap(base[past:], end, S)
	q = element_gap(q[1:], end, S) if q != nil && q != end && q[0] == ':' else nil
	if q == nil || q == end {
		return 0, frame_refused(r, w, PLACE_COLON, past, true)
	}
	r.key = h.key
	return u64(intrinsics.ptr_sub(q, base)), .Done
}

// JSON's `pass` of the framing: judges the value past the white space at `pos`, `depth` containers deep, as the walk
// of the whole text judges it, and moves `pos` past it.
@(private)
frame_pass :: proc(r: ^Records, w: ^Walk($S, hook.No_Hooks, $LAX, hook.NO_HOOKS_CAPS), depth: u64, allocator: runtime.Allocator) -> build.Frame_Step {
	base := raw_data(r.src)
	n := u64(len(r.src))
	none: hook.No_Hooks
	regs: hook.Regs
	ctx := context
	when LAX {
		left := w.steps[0]
	}
	lo := u64(intrinsics.ptr_sub(kernel.skip_ws(base[r.pos:], base[n:]), base))
	res := record_walk(r, w, lo, base[n:], build.read_depth(r.opts) - depth, &none, &regs, allocator, &ctx, false, hook.no_hook)
	if u8(res) != 0 || window_more(r) && u64(res) >> 16 == n {
		when LAX {
			w.steps[0] = left
		}
		return walk_refused(r, res, S)
	}
	r.pos = u64(res) >> 16
	return .Done
}

// JSON's `tail` of the framing: the white space and comments past the root to the text's end, as the walk judges
// them. In a window that more bytes follow they are judged to its end, and read again from the first comment in the
// next, as the window's end may cut one.
@(private)
frame_tail :: proc "contextless" (r: ^Records, w: ^Walk($S, hook.No_Hooks, $LAX, hook.NO_HOOKS_CAPS)) -> build.Frame_Step {
	base := raw_data(r.src)
	end := base[len(r.src):]
	stack: [1]u32
	none: hook.No_Hooks
	regs: hook.Regs
	walk_start(w, r.src, raw_data(stack[:]), &none, &regs, {}, nil, 1, r.opts.tolerate, r.opts.budget.steps)
	when LAX {
		w.piece[0] = nil
	}
	res := walk_tail(w, hook.walk_result(r.pos, 0), end, hook.no_hook)
	w.hooks, w.regs, w.ctx, w.stack, w.allocator = nil, nil, nil, nil, {}
	if u8(res) != 0 && walk_refused(r, res, S) == .Fault {
		return .Fault
	}
	if window_more(r) {
		r.pos = u64(intrinsics.ptr_sub(kernel.skip_ws(base[r.pos:], end), base))
		return .Wait
	}
	return .Done
}

// The step's verdict on the bytes at `at`, at `place` in a container of kind `object`, which the framing's checks
// refuse: the walk entered there judges them.
@(private, cold)
frame_refused :: proc "contextless" (r: ^Records, w: ^Walk($S, hook.No_Hooks, $LAX, hook.NO_HOOKS_CAPS), place: u8, at: u64, object: bool) -> build.Frame_Step {
	stack: [2]u32
	none: hook.No_Hooks
	regs: hook.Regs
	when LAX {
		left := w.steps[0]
	}
	walk_start(w, r.src, raw_data(stack[:]), &none, &regs, {}, nil, build.read_depth(r.opts), r.opts.tolerate, r.opts.budget.steps)
	when LAX {
		w.piece[0] = nil
		w.steps[0] = left
	}
	w.depth = 2
	res := enter_place(place, raw_data(r.src)[at:], raw_data(r.src)[len(r.src):], 1 << 1 | u64(object), w, regs, hook.no_hook)
	w.hooks, w.regs, w.ctx, w.stack, w.allocator = nil, nil, nil, nil, {}
	return walk_refused(r, res, S)
}

// The verdict on a step whose walk gave `res`, a fault or a value that reached the window's end: `.Wait` in a window
// that more bytes follow when they may change it, else `.Fault` with the records ended at the walk's error.
@(private, cold)
walk_refused :: proc "contextless" (r: ^Records, res: hook.Walk_Result, $S: Spec) -> build.Frame_Step {
	base := raw_data(r.src)
	n := u64(len(r.src))
	if window_more(r) && piece_cut(r.src, res, S) {
		return .Wait
	}
	lo := base[r.opts.pieces.from:] if r.opts.pieces != nil else base
	_, r.err, _ = hook.walk_error(described(res, base, lo, base[n:], S == .Json5), &RULES)
	r.at = .Done
	return .Fault
}

// Whether more bytes follow the window of a text in pieces.
@(private)
window_more :: #force_inline proc "contextless" (r: ^Records) -> bool {
	return r.opts.pieces != nil && !r.opts.pieces.last
}

// Whether bytes past the window `src` may change the walk's result `res`: a value that ends at the window's end, as a
// number may go on, a fault at its end, which a token it cuts gives as `.Truncated`, a fault at a `/` or a JSON5 lead
// byte of white space that the window's end may cut, and one at a tolerated `Infinity` or `NaN` it cuts.
@(private)
piece_cut :: proc "contextless" (src: []u8, res: hook.Walk_Result, $S: Spec) -> bool #no_bounds_check {
	n := u64(len(src))
	at := u64(res) >> 16
	switch u8(res) {
	case 0:
		return at == n
	case u8(tape.Fault_Kind.Truncated):
		return true
	case u8(tape.Fault_Kind.Bad_Char), u8(tape.Fault_Kind.Bad_Number):
		if at >= n {
			return false
		}
		cut, infinity, nan := string(src[at:]), "Infinity", "NaN"
		if len(cut) < 8 && (cut == infinity[:len(cut)] || len(cut) < 3 && cut == nan[:len(cut)]) {
			return true
		}
		when S != .Json {
			return u8(res) == u8(tape.Fault_Kind.Bad_Char) && (src[at] == '/' && at + 1 == n || S == .Json5 && src[at] >= 0xc2 && n - at < 3)
		}
	}
	return false
}

// In a text in pieces, readies the records' walk for the window: its gap table drops what the last window held, and
// the byte order mark is judged once the window holds enough of it. False while it does not.
@(private)
piece_start :: proc "contextless" (r: ^Records, w: ^Walk($S, hook.No_Hooks, $LAX, hook.NO_HOOKS_CAPS)) -> bool {
	p := r.opts.pieces
	if p.from != r.window {
		gaps_drop(&w.gaps, p.from)
		r.window = p.from
	}
	if r.at == .Start {
		if !p.last && piece_bom_open(r.src) {
			return false
		}
		r.pos, r.at = u64(spell.bom_length(r.src)), .Open
	}
	return true
}

// `record_frame` under `.Lines` in a text in pieces: a record whose line end the window does not hold ends the batch,
// and its framing goes on in the next window where this one stopped. The record's walk reads up to its window's end, at
// most `RECORD_AHEAD` bytes past its line, where a walk of the whole text reads that far, which judges the record alike,
// as a walk that reads past the line walks the record again alone.
@(private)
record_frame_window :: proc "contextless" (r: ^Records, w: ^Walk($S, hook.No_Hooks, $LAX, hook.NO_HOOKS_CAPS)) -> (lo, cut: u64, ok: bool) {
	n := u64(len(r.src))
	more := !r.opts.pieces.last
	if !piece_start(r, w) {
		return
	}
	if !r.open {
		base := raw_data(r.src)
		r.pos = u64(intrinsics.ptr_sub(kernel.skip_ws(base[r.pos:], base[n:]), base))
		if r.pos == n {
			if !more {
				r.at = .Done
			}
			return
		}
		r.open, r.seen = true, r.pos
	}
	cut = n
	if i := kernel.index_byte(r.src[r.seen:], '\n'); i >= 0 {
		cut = r.seen + u64(i)
	} else if more {
		r.seen = n
		return
	}
	lo = r.pos
	r.open, r.pos = false, min(cut + 1, n)
	if r.src[cut - 1] == '\r' {
		cut -= 1
	}
	return lo, cut, true
}

// The first byte past the white space and comments from `p`, nil at a comment that does not end.
@(private)
element_gap :: #force_inline proc "contextless" (p, end: [^]u8, $S: Spec) -> [^]u8 {
	when S == .Json {
		return kernel.skip_ws(p, end)
	} else {
		q, _, kind := comment_run(p, end, false, S)
		return q if kind == .None else nil
	}
}

// Walks the record that `record_frame` framed from `lo` to `cut` for hook `h` from registers `regs`, and returns the
// walk's result, the record's end, and under `.Lines`/`.Seq` whether the record must be walked again alone, which the
// walk in the whole text reads as no walk of its span would. False once the records have ended, as under `.Elements`
// and `.Concatenated` a fault ends them, and in a text in pieces when the window ends inside the record.
@(private)
record_first :: #force_inline proc(r: ^Records, w: ^Walk($S, $H, $LAX, $C), lo, cut: u64, h: ^H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (res: hook.Walk_Result, hi: u64, alone, ok: bool) {
	base := raw_data(r.src)
	n := u64(len(r.src))
	if r.framing == .Lines {
		res = record_walk(r, w, lo, base[min(n, cut + RECORD_AHEAD):], build.read_depth(r.opts), h, regs, allocator, ctx, false, on)
		return res, cut, !line_read(r.src, res, cut, false), true
	}
	if r.framing == .Seq {
		if r.seq_unframed {
			return hook.walk_result(lo, u8(tape.Fault_Kind.Bad_Char), u8(Detail.Unframed)), cut, false, true
		}
		res = record_walk(r, w, lo, base[min(n, cut + RECORD_AHEAD):], build.read_depth(r.opts), h, regs, allocator, ctx, false, on)
		return res, cut, !line_read(r.src, res, cut, true), true
	}
	when LAX {
		left := w.steps[0]
	}
	depth := build.read_depth(r.opts) if r.framing == .Concatenated else build.read_depth(r.opts) - 1 - u64(len(r.path))
	res = record_walk(r, w, lo, base[n:], depth, h, regs, allocator, ctx, false, on)
	end := res
	if u8(res) == hook.WALK_STOPPED {
		// The hook refused the value, which leaves the walk short of its end, so a walk with no hook finds it.
		// The refusal is the record's error, as it is for a line.
		when LAX {
			w.steps[0] = left
		}
		plain := (^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS))(w)
		none: hook.No_Hooks
		none_regs: hook.Regs
		end = record_walk(r, plain, lo, base[n:], depth, &none, &none_regs, allocator, ctx, false, hook.no_hook)
	}
	if r.framing == .Concatenated && u8(end) == 0 && !(window_more(r) && u64(end) >> 16 == n) {
		if concat_runs_on(r.src, lo, u64(end) >> 16, S) {
			end = hook.walk_result(u64(end) >> 16, u8(tape.Fault_Kind.Bad_Char), u8(Detail.Trailing))
		}
	}
	if u8(end) != 0 || window_more(r) && u64(end) >> 16 == n {
		when LAX {
			w.steps[0] = left
		}
		_ = walk_refused(r, end, S)
		return
	}
	hi = u64(end) >> 16
	r.pos, r.at = hi, .After
	return res, hi, false, true
}

// The hook of the walk that reads a member's key, which keeps the key and stops the walk.
@(private)
Member_Key :: struct {
	protocol: hook.Protocol(hook.NO_HOOKS_CAPS, hook.Unused, hook.Unused, hook.Unused),
	key:      tape.Token,
}

#assert(size_of(Walk(.Json5, Member_Key, true, hook.NO_HOOKS_CAPS)) == size_of(Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS)))
#assert(offset_of(Walk(.Json5, Member_Key, true, hook.NO_HOOKS_CAPS), gaps) == offset_of(Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS), gaps))

@(private)
member_key_hook :: proc "contextless" (h: ^Member_Key, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	h.key = t
	return s, .Stop
}

// The level of the root object, as the walk's states name a container: its depth and its kind bit.
@(private)
MEMBER_LEVEL :: u64(1 << 1 | 1)

// Walks the key of the member at `at` for hook `h`, which stops on it, and returns the walk's result.
@(private)
key_walk :: proc "contextless" (r: ^Records, w: ^Walk($S, Member_Key, $LAX, $C), at: u64, h: ^Member_Key, regs: ^hook.Regs) -> hook.Walk_Result {
	stack: [2]u32
	when LAX {
		left := w.steps[0]
	}
	walk_start(w, r.src, raw_data(stack[:]), h, regs, {}, nil, build.read_depth(r.opts), r.opts.tolerate, r.opts.budget.steps)
	when LAX {
		w.piece[0] = nil
		w.steps[0] = left
	}
	w.depth = min(w.limit, WALK_LEVELS)
	res := enter_member(raw_data(r.src)[at:], raw_data(r.src)[len(r.src):], MEMBER_LEVEL, indent_start(w), w, regs^, GAP_OFF, member_key_hook)
	w.hooks, w.regs, w.ctx, w.stack, w.allocator = nil, nil, nil, nil, {}
	return res
}

// Walks the record from `lo` to `cut` as a text of those bytes alone, and returns the walk's result.
@(private, cold)
record_alone :: #force_no_inline proc(r: ^Records, w: ^Walk($S, $H, $LAX, $C), lo, cut: u64, h: ^H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	return record_walk(r, w, lo, raw_data(r.src)[cut:], build.read_depth(r.opts), h, regs, allocator, ctx, true, on)
}

// Whether the walk in the whole text with result `res` read the record that ends at `cut` as a walk of its bytes alone
// reads them: its value ended, or the hook stopped the walk, within them, and only white space follows the value.
@(private)
line_read :: #force_inline proc "contextless" (src: []u8, res: hook.Walk_Result, cut: u64, $ALLOW_LF: bool) -> bool #no_bounds_check {
	hi := u64(res) >> 16
	if hi > cut {
		return false
	}
	switch u8(res) {
	case 0:
		for c in src[hi:cut] {
			when ALLOW_LF {
				if c != ' ' && c != '\t' && c != '\r' && c != '\n' {
					return false
				}
			} else {
				if c != ' ' && c != '\t' && c != '\r' {
					return false
				}
			}
		}
		return true
	case hook.WALK_STOPPED:
		return true
	}
	return false
}

// Whether a `.Seq` record's span `text` is a top-level number with no white space after it, which RFC 7464 refuses as
// possibly truncated (`Detail.Cut_Number`). Under JSON5 this also covers hex literals, `Infinity`, and `NaN`.
@(private)
seq_cut_number :: #force_inline proc "contextless" (text: []u8, $S: Spec) -> bool {
	if len(text) == 0 {
		return false
	}
	when S == .Json5 {
		s := string(text)
		if s == "Infinity" || s == "+Infinity" || s == "-Infinity" || s == "NaN" || s == "+NaN" || s == "-NaN" {
			return true
		}
		for c in text {
			switch c {
			case '0' ..= '9', '-', '+', '.', 'e', 'E', 'a' ..= 'f', 'A' ..= 'F', 'x', 'X':
			case:
				return false
			}
		}
		return true
	} else {
		for c in text {
			switch c {
			case '0' ..= '9', '-', '+', '.', 'e', 'E':
			case:
				return false
			}
		}
		return true
	}
}

// Whether a scalar value under `.Concatenated` from `lo` to `hi` runs on into a byte that cannot follow a concatenated
// value (e.g. `1x`, `1,2`, `truefalse`), matching jq's concatenated JSON stream rules.
@(private)
concat_runs_on :: #force_inline proc "contextless" (src: []u8, lo, hi: u64, $S: Spec) -> bool #no_bounds_check {
	if hi >= u64(len(src)) {
		return false
	}
	switch src[lo] {
	case '[', '{', '"', '\'':
		return false
	}
	switch src[hi] {
	case ',', ':', ']', '}':
		return true
	case '/':
		return S == .Json
	case ' ', '\t', '\r', '\n', 0x1e, '[', '{', '"', '\'':
		return false
	}
	when S == .Json5 {
		if ws5_len(raw_data(src)[hi:], raw_data(src)[len(src):]) > 0 {
			return false
		}
	}
	return true
}

// Skips past a faulting `.Concatenated` record, resuming at the next LF after the fault (or at the fault's own line
// when the fault is its line's first non-whitespace byte). Mirrors v1 `records.skip` + `json.resume_spec`.
@(private)
records_skip_proc :: proc(base_r: ^tape.Records) -> (bad: tape.Bad_Record, ok: bool) #no_bounds_check {
	r := container_of(base_r, Records, "records")
	if r.framing != .Concatenated {
		return
	}
	f, is_fault := r.err.(tape.Fault)
	if !is_fault || f.rules == &tape.RECORDS_RULES || f.kind == .Too_Wide {
		return
	}
	src := r.src
	n := u64(len(src))
	from := min(f.at, n)
	lo := min(r.pos, from)
	// Find the first non-ws byte of the record to check if `from` starts a fresh line.
	first := lo
	for first < n && kernel.is_ws(src[first]) {
		first += 1
	}
	next: u64
	ls := from
	for ls > first && (src[ls - 1] == ' ' || src[ls - 1] == '\t' || src[ls - 1] == '\r') {
		ls -= 1
	}
	if ls > first && src[ls - 1] == '\n' {
		next = ls
	} else if from < n {
		if i := kernel.index_byte(src[from:], '\n'); i >= 0 {
			next = from + u64(i) + 1
		} else {
			next = n
			if window_more(r) {
				r.skip_line = true
			}
		}
	} else {
		next = n
		if window_more(r) {
			r.skip_line = true
		}
	}
	for lo < next && kernel.is_ws(src[lo]) {
		lo += 1
	}
	hi := next
	for hi > lo && kernel.is_ws(src[hi - 1]) {
		hi -= 1
	}
	bad = {lo = lo, hi = hi, err = r.err, text = src[lo:hi]}
	r.err = nil
	r.pos = next
	r.at = .Open if next < n || window_more(r) else .Done
	return bad, true
}

// The most objects deep `spine` looks for an array, and the most members and bytes of each it passes before one in an
// object.
@(private)
SPINE_LEVELS, SIDE_MEMBERS, SIDE_BYTES :: 4, 16, 4096

// Finds the array that holds the bulk of `src`, read as `spec`: its root array, or the array a root object holds up to
// `SPINE_LEVELS` objects deep, past at most `SIDE_MEMBERS` members in each object whose values end within `SIDE_BYTES`.
// A key on the way must be quoted with `"`. `at` is the array's `[` and `levels` the objects around it. False when
// there is none. Allocates nothing.
spine :: proc(src: []u8, spec := Spec.Json, opts := Options{}) -> (at: u64, levels: int, ok: bool) {
	switch spec {
	case .Json:
		return spine_of(src, opts, .Json)
	case .Jsonc:
		return spine_of(src, opts, .Jsonc)
	case .Json5:
		return spine_of(src, opts, .Json5)
	}
	return
}

@(private)
spine_of :: proc(src: []u8, opts: Options, $S: Spec) -> (at: u64, levels: int, ok: bool) {
	p := raw_data(src)
	end := p[len(src):]
	q := element_gap(p[spell.bom_length(src):], end, S)
	limit := build.read_depth(opts)
	for q != nil && q < end && u64(levels) < limit {
		if q[0] == '[' {
			return u64(intrinsics.ptr_sub(q, p)), levels, true
		}
		if q[0] != '{' || levels == SPINE_LEVELS {
			return
		}
		levels += 1
		for n := 0; ; n += 1 {
			q = element_gap(q[1:], end, S)
			if n == SIDE_MEMBERS || q == nil || q == end || q[0] != '"' {
				return
			}
			hi, err := spine_walk(src, q, end, S, opts)
			if err != nil {
				return
			}
			q = element_gap(p[hi:], end, S)
			if q == nil || q == end || q[0] != ':' {
				return
			}
			q = element_gap(q[1:], end, S)
			if q == nil || q == end {
				return
			}
			// A value that does not end within `SIDE_BYTES` is the one the spine runs through.
			pos := intrinsics.ptr_sub(q, p)
			bound := p[min(len(src), pos + SIDE_BYTES):]
			if hi, err = spine_walk(src, q, bound, S, opts); err != nil {
				break
			}
			q = element_gap(p[hi:], end, S)
			if q == nil || q == end || q[0] != ',' {
				return
			}
		}
	}
	return
}

@(private)
spine_walk :: proc "contextless" (src: []u8, q, end: [^]u8, $S: Spec, opts: Options) -> (hi: u64, err: tape.Error) {
	stack: [WALK_LEVELS]u32 = ---
	none: hook.No_Hooks
	regs: hook.Regs
	w: Walk(S, hook.No_Hooks, false, hook.NO_HOOKS_CAPS) = ---
	walk_init(&w, src, raw_data(stack[:]), &none, &regs, {}, nil, build.read_depth(opts), opts.tolerate, 0)
	w.depth = min(w.limit, WALK_LEVELS)
	res := enter(q, end, indent_start(&w), &w, regs, GAP_OFF, hook.no_hook)
	hi, err, _ = hook.walk_error(res, &RULES)
	return
}

// Walks the value at `lo` to `end` for hook `h` from registers `regs`, in the walk of `r` with its gap table, within
// `limit` levels. With `TAIL` what follows the value up to `end` is judged as a text's tail.
@(private)
record_walk :: #force_inline proc "contextless" (r: ^Records, w: ^Walk($S, $H, $LAX, $C), lo: u64, end: [^]u8, limit: u64, h: ^H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $TAIL: bool, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	stack: [WALK_LEVELS]u32 = ---
	when LAX {
		left := w.steps[0]
	}
	walk_start(w, r.src, raw_data(stack[:]), h, regs, allocator, ctx, limit, r.opts.tolerate, r.opts.budget.steps)
	when LAX {
		w.piece[0] = nil
		if r.framing == .Elements || r.framing == .Members {
			w.steps[0] = left
		}
	}
	w.depth = hook.held_depth(h, regs, min(w.limit, WALK_LEVELS))
	when .Walk in C {
		h.walk = w
	}
	res := enter(raw_data(r.src)[lo:], end, indent_start(w), w, regs^, GAP_START, on)
	when TAIL {
		res = walk_tail(w, res, end, on)
	}
	when .Walk in C {
		h.walk = nil
	}
	when LAX {
		if u8(res) == hook.WALK_STOPPED && w.steps[0] == 0 {
			res = hook.walk_result(u64(res) >> 16, hook.WALK_STEPS)
		}
	}
	if w.owned {
		hook.levels_free(w)
	}
	// The records keep the walk past the call, and none of the caller's frame.
	w.hooks, w.regs, w.ctx, w.stack, w.allocator = nil, nil, nil, nil, {}
	return res
}
