package build

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/tape"

// A build of a text in parts on the threads of a `tape.Runner`. A format reads its text for seams, positions where a
// walk can start inside the containers that the text before them leaves open, and plans a part from each seam to the
// next. Each part is walked into a `Segment` of its own, and the segments are joined into the document a single walk
// would build. Only the calling thread calls the allocator.

// The shortest text built on a runner's threads. A shorter text is built sooner on one thread. A chunk is at least a
// sixteenth of this length.
PARALLEL_FROM :: #config(BUILD_PARALLEL_FROM, 1 << 19)

// The chunks cut per thread, so that a thread that starts late or a slow chunk leaves no thread idle long.
@(private)
CHUNKS_PER_THREAD :: 4

// The chunks a text of `n` bytes is cut into for the threads of `runner`, fewer than two for a text built on one
// thread.
chunk_count :: proc "contextless" (runner: ^tape.Runner, n: int) -> int {
	return min((runner.threads + 1) * CHUNKS_PER_THREAD, n / max(PARALLEL_FROM / 16, 1))
}

// The text a part's walk reads, from a seam, or the text's start, to the next seam, or the text's end, and what its
// walk gave.
Part :: struct {
	from, to:  int,
	opens:     []tape.Kind, // the containers open at `from`, outermost first
	// Where `opens` is in the plan's kinds, which `parts_opens` places once the plan is whole, as appending to them may
	// move them.
	opens_at:  int,
	opens_n:   int,
	levels:    int, // the most containers open at once in it
	comments:  int, // the facts its walk stores, or more
	nodes:     int, // the nodes its walk stores, or more
	close:     u64, // where its walk ended
	err:       tape.Error, // the walk's error, nil when it reached `to` as the plan has it
	// The walk ended at `to` other than as the plan has it, so the plan misread the text, which is then built on one
	// thread.
	astray:    bool,
	tolerated: bool, // the walk used a rule of the read's tolerances
}

// Places the `opens` of each of `parts` in `kinds`, from the `opens_at` and `opens_n` each holds.
parts_opens :: proc "contextless" (parts: []Part, kinds: []tape.Kind) {
	for &p in parts {
		p.opens = kinds[p.opens_at:][:p.opens_n]
	}
}

// Settles the error of part `p`, one before the last, after its walk. A part ends inside the containers open at the
// next seam, which its walk reads as a text cut short there, and one that ends otherwise had the plan misread the text.
part_cut_short :: proc "contextless" (p: ^Part) {
	if f, ok := p.err.(tape.Fault); ok && f.kind == .Truncated && f.at == u64(p.to) {
		p.err = nil
	} else if p.err == nil {
		p.astray = true
	}
}

// The walk of part `k` of `parts` over `src`, into the segment `s` its builder fills, which sets the part's `close`,
// `err`, `astray` and `tolerated`. It runs on any thread and allocates nothing. `data` is the format's own.
Part_Walk :: proc(src: []u8, parts: []Part, k: int, s: ^Segment, opts: tape.Options, data: rawptr)

// Builds `src`, a text of `format`, in `parts`, each walked by `walk` on the threads of `opts.runner`, and returns its
// document and error, or `built` false for a text built on one thread. `finish` settles the joined document from the
// segments, destroying it on an error, and an `Allocator_Error` from it has the text built on one thread. A nil
// `finish` settles the repeated keys by `segments_dups`, under `rules`. Under `Budget.steps` the error is at the first
// container past the budget, `opened` bytes past its node's `lo`, unless a part's error comes before it. Every block comes from
// `allocator`, and the document is left with `caller`, the allocator the read was called with.
parts_build :: proc(src: []u8, format: ^tape.Format, rules: ^tape.Rules, parts: []Part, opts: tape.Options, opened: u64, allocator, caller: runtime.Allocator, walk: Part_Walk, finish: proc(doc: ^tape.Document, segs: []Segment, opts: tape.Options, data: rawptr) -> tape.Error, data: rawptr) -> (doc: tape.Document, err: tape.Error, built: bool) {
	segs, serr := make([]Segment, len(parts), allocator)
	if serr != nil || raw_data(segs) == nil {
		return {}, nil, false
	}
	defer {
		for &s in segs {
			segment_free(&s)
		}
		delete(segs, allocator)
	}
	// Each part's walk stores its nodes where a single walk would, after the nodes the parts before it plan. The nodes
	// for the containers open at its seam go after the nodes of all parts.
	levels, total, scratch, comments := 0, 0, 0, 0
	for p, k in parts {
		levels += p.levels + 1
		total += max(p.nodes, 0)
		scratch += len(p.opens) + 1 if k > 0 else 0
		comments += p.comments
	}
	if total > node_most(max(u64), opts) {
		return {}, nil, false
	}
	frames, ferr := make([]u64, levels, allocator)
	if ferr != nil || levels > 0 && raw_data(frames) == nil {
		return {}, nil, false
	}
	defer delete(frames, allocator)
	room, rerr := non_zero_make([]tape.Node, total + 1 + scratch, allocator)
	if rerr != nil || raw_data(room) == nil {
		return {}, nil, false
	}
	joined: bool
	defer if !joined {
		delete(room, allocator)
	}
	facts, ferr2 := non_zero_make([]tape.Fact, comments, allocator)
	if ferr2 != nil || comments > 0 && raw_data(facts) == nil {
		return {}, nil, false
	}
	defer if !joined {
		delete(facts, allocator)
	}
	seams, serr2 := non_zero_make([]tape.Node_Index, scratch, allocator)
	if serr2 != nil || scratch > 0 && raw_data(seams) == nil {
		return {}, nil, false
	}
	defer delete(seams, allocator)
	levels = 0
	first, fact, seam := 0, 0, 0
	scratch = total + 1
	for p, k in parts {
		nodes := max(p.nodes, 0)
		segs[k] = segment_start(src, format, room, first, nodes, scratch, p.opens, facts[fact:][:p.comments], frames[levels:][:p.levels + 1], seams[seam:][:len(p.opens)], allocator)
		levels += p.levels + 1
		first += nodes
		fact += p.comments
		seam += len(p.opens)
		scratch += len(p.opens) + 1 if k > 0 else 0
		if segs[k].b.err != nil {
			return {}, nil, false
		}
	}
	task :: proc(arg: rawptr, k: int) {
		j := (^Parts_Job)(arg)
		s := &j.segs[k]
		j.walk(j.src, j.parts, k, s, j.opts, j.data)
		if j.counting {
			for n in segment_nodes(s) {
				s.containers += int(n.kind == .Array || n.kind == .Object)
			}
		}
	}
	j := Parts_Job{src = src, parts = parts, segs = segs, opts = opts, walk = walk, data = data, counting = opts.budget.steps != 0}
	j.opts.budget.steps = 0
	tape.fan_each(opts.runner, len(parts), task, &j)
	// The first part in text order whose walk does not reach its end gives the build's error, unless a container past
	// `Budget.steps` comes first.
	containers := 0
	for p, k in parts {
		s := &segs[k]
		if s.b.err != nil || p.astray {
			return {}, nil, false
		}
		if opts.budget.steps != 0 && u64(containers + s.containers) > opts.budget.steps {
			for n in segment_nodes(s) {
				containers += int(n.kind == .Array || n.kind == .Object)
				if u64(containers) > opts.budget.steps {
					return {}, tape.Exceeded{at = n.lo + opened, kind = .Steps}, true
				}
			}
		}
		if p.err == nil {
			containers += s.containers
			continue
		}
		if _, refused := p.err.(runtime.Allocator_Error); refused {
			return {}, nil, false
		}
		// Under `.Refuse` a repeated key before the fault comes first, which the build on one thread judges.
		if _, is_fault := p.err.(tape.Fault); is_fault && opts.dups == .Refuse {
			return {}, nil, false
		}
		return {}, p.err, true
	}
	jerr: runtime.Allocator_Error
	doc, joined, jerr = segments_join(segs, room, facts, parts[len(parts) - 1].close, opts.runner, allocator)
	if jerr != nil || !joined {
		return {}, nil, false
	}
	for p in parts {
		if p.tolerated {
			doc.flags += {.Tolerated}
		}
	}
	e := finish(&doc, segs, opts, data) if finish != nil else segments_dups_fast(&doc, segs, opts.dups, rules, opts.runner)
	if e != nil {
		if _, refused := e.(runtime.Allocator_Error); refused {
			return {}, nil, false
		}
		return {}, e, true
	}
	doc.allocator = caller
	return doc, nil, true
}

@(private)
Parts_Job :: struct {
	src:      []u8,
	parts:    []Part,
	segs:     []Segment,
	opts:     tape.Options,
	walk:     Part_Walk,
	data:     rawptr,
	counting: bool,
}
