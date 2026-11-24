package dsv

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Builds a long delimited text on the threads of a `tape.Runner`. The text is cut into chunks, each starting one past
// an LF. That LF ends a line or, in CSV, lies inside a quoted cell that goes on. A chunk is read in one pass from both
// places: the prefix XOR of its quotes is the same for both, and only the side of it that lies inside quotes differs.
// Each reading carries the pass's block state (the open quoted cell, the separator or closing quote before a block, an
// open comment line) and finds the chunk's seam, one past the LF that ends the first record whose line starts in the
// chunk. Then, in text order, each chunk starts in the place the chunk before it ends in, which selects its reading.
// A walk from a seam starts inside the root's array between two records, with no comment line held, and is given the
// width of the first record, as a single walk is at that point. The text between two seams is walked into a segment of
// its own. The segments are joined (`build.parts_build`) into the document a single walk builds, and the header is
// stored past the root as a single walk stores it.
//
// A reading agrees with the pass over any text the pass accepts, so the first part in text order whose walk faults
// gives the fault a single walk gives. A part whose walk ends other than between two records, or a text with no seam
// past its header, is built on one thread. A build under `Budget.memory` counts the blocks its parts take. If a block
// is refused, the text is built on one thread and the refusal of that build is the answer. The parts may fit a budget a
// single build is refused, as they size their rooms by the plan.

// The places the first byte of a chunk, one past an LF, can lie in.
@(private)
Place :: enum u8 {
	Line, // at a line's first byte
	Quoted, // inside a quoted CSV cell
}

// Counts for the bytes of a chunk before or from its seam: at least the nodes their records make, and their comment
// lines.
@(private)
Tally :: struct {
	nodes, comments: int,
}

// A chunk read from a place. `seam` is one past the LF that ends the chunk's first record line, -1 for none. While the
// chunk is read, `in_quote`, `start`, `close` and `line` are the masks the pass carries from one block to the next,
// `comment` says that a comment line is open, and `line_lo` is the first byte of the line being read. It is -1 for a
// line that started before the chunk inside a quoted cell, which makes it a record.
@(private)
Reading :: struct {
	pre, post:                    Tally,
	seam:                         int,
	line_lo:                      int,
	in_quote, start, close, line: u64,
	comment:                      bool,
}

@(private)
Chunk :: struct {
	lo, hi: int,
	runs:   [Place]Reading,
}

@(private)
Chunk_Job :: struct {
	src:    []u8,
	chunks: []Chunk,
	p:      Pass_Options,
}

// Shared by every part's walk: the pass options, the width of the first record, and the header's keys, which the first
// part's walk fills. A part past the first gives each cell a key of no bytes, which the table hook drops. `widest`
// holds the most cells a record of each part had.
@(private)
Part_Data :: struct {
	p:      Pass_Options,
	width:  int,
	keys:   []tape.Token,
	blank:  []tape.Token,
	widest: []int,
	most:   int, // the most nodes the build may store, header included
}

// The containers open at a seam: the root's array.
@(private, rodata)
SEAM_OPENS := [1]tape.Kind{.Array}

// `build` on the threads of `opts.runner`, else on the calling thread.
@(private)
build_parallel :: #force_no_inline proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	doc, err, built := build_parts(src, S, opts, caller)
	if built {
		return doc, err
	}
	one := opts
	one.runner = nil
	return build_as(src, S, one, caller)
}

// Builds `src` in parts and returns its document and error, or `built` false for a text built on one thread.
@(private)
build_parts :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (doc: tape.Document, err: tape.Error, built: bool) {
	m: hook.Memory_Budget
	allocator := build.read_allocator(&m, opts, caller)
	p, _ := pass_options(S, opts)
	start := int(text_start(src, 0))
	want := build.chunk_count(opts.runner, len(src) - start)
	if want < 2 {
		return {}, nil, false
	}
	chunks, cerr := make([]Chunk, want, allocator)
	if cerr != nil || raw_data(chunks) == nil {
		return {}, nil, false
	}
	defer delete(chunks, allocator)
	cut_chunks(src, start, chunks)
	read :: proc(arg: rawptr, k: int) {
		j := (^Chunk_Job)(arg)
		read_chunk(j.src, &j.chunks[k], S, j.p, S == .Csv && k > 0)
	}
	cj := Chunk_Job{src = src, chunks = chunks, p = p}
	hook.fan_each(opts.runner, len(chunks), read, &cj)
	// The first record. Parts past the first take their width from it, and read as a header it holds the keys.
	first := record_start(src, start, p.comment)
	if first >= len(src) {
		return {}, nil, false
	}
	head := scan_record(src, first, 0, S, p.delim)
	parts := seam_plan(src, chunks, head.line_end + 1 if !p.no_header else 0, head.cells + 1 if !p.no_header else 0, allocator)
	defer delete(parts, allocator)
	if len(parts) < 2 {
		return {}, nil, false
	}
	count := 0 if p.no_header else head.cells
	keys, kerr := make([]tape.Token, 2 * count, allocator)
	if kerr != nil || count > 0 && raw_data(keys) == nil {
		return {}, nil, false
	}
	defer delete(keys, allocator)
	widest, werr := make([]int, len(parts), allocator)
	if werr != nil || raw_data(widest) == nil {
		return {}, nil, false
	}
	defer delete(widest, allocator)
	data := Part_Data{p = p, width = head.cells, keys = keys[:count], blank = keys[count:], widest = widest}
	data.most = build.node_most(node_bound(src, 0), opts)
	walk :: proc(src: []u8, parts: []build.Part, k: int, s: ^build.Segment, opts: Options, data: rawptr) {
		d := (^Part_Data)(data)
		p := &parts[k]
		r: hook.Walk_Result
		if k == 0 {
			r, d.widest[k], p.tolerated, p.astray = walk_part(src[:p.to], S, d.p, &s.b, &s.regs, 0, d.keys, 0, k == len(parts) - 1)
		} else {
			r, d.widest[k], p.tolerated, p.astray = walk_part(src[:p.to], S, d.p, &s.b, &s.regs, p.from, d.blank, d.width, k == len(parts) - 1)
		}
		p.close, p.err, _ = hook.walk_error(r, &RULES)
	}
	finish :: proc(doc: ^tape.Document, segs: []build.Segment, opts: Options, data: rawptr) -> tape.Error {
		d := (^Part_Data)(data)
		if len(d.keys) > 0 {
			wide := 0
			for w in d.widest {
				wide = max(wide, w)
			}
			wide = max(wide, len(d.keys))
			// A single build stores the header in the room the rows leave within `Budget.nodes`.
			if len(doc.nodes) + 1 + wide > d.most {
				tape.destroy(doc)
				return runtime.Allocator_Error.Out_Of_Memory
			}
			if e := append_keys(doc, d.keys, wide, 1 + len(d.keys)); e != nil {
				return e
			}
		}
		return finish_table(doc, headed(doc), opts)
	}
	doc, err, built = build.parts_build(src, &FORMATS[S], &RULES, parts, opts, 0, 1 + count, allocator, caller, walk, finish, &data)
	err = repeat_first(err, src, S, p, data.keys, opts, allocator)
	return
}

// Cuts `src` from `start` into `len(chunks)` chunks of about equal size, each but the first starting one past an LF.
// A chunk whose stretch holds no LF is empty, and the next chunk starts at the same byte.
@(private)
cut_chunks :: proc "contextless" (src: []u8, start: int, chunks: []Chunk) #no_bounds_check {
	lo := start
	n := len(src) - start
	for &c, k in chunks {
		hi := len(src)
		if k < len(chunks) - 1 {
			at := start + n * (k + 1) / len(chunks)
			next := start + n * (k + 2) / len(chunks)
			hi = lo
			for i in max(at - 1, lo) ..< next {
				if src[i] == '\n' {
					hi = i + 1
					break
				}
			}
		}
		c.lo, c.hi = lo, hi
		lo = hi
	}
}

// The state of a reading of a chunk that starts at `lo` in place `from`, before it reads a block.
@(private)
reading_from :: #force_inline proc "contextless" (lo: int, from: Place) -> Reading {
	return {seam = -1, line_lo = lo if from == .Line else -1, in_quote = max(u64) if from == .Quoted else 0, start = 1, line = 1}
}

// Reads chunk `c` of `src`, a text of `S` under `p`, from the start of a line and, with `both`, from inside a quoted
// cell, loading each block once for both readings. The reading is compiled for the tier the CPU runs, so that the
// quote masks are one carry-less multiply where the tier has it.
@(private)
read_chunk :: #force_inline proc "contextless" (src: []u8, c: ^Chunk, $S: Spec, p: Pass_Options, both: bool) {
	when ODIN_ARCH == .amd64 {
		if kernel.tier() == .V3 {
			read_chunk_v3(src, c, S, p, both)
			return
		}
	}
	read_chunk_floor(src, c, S, p, both)
}

@(private, enable_target_feature = PASS_FLOOR_FEATURES)
read_chunk_floor :: #force_no_inline proc "contextless" (src: []u8, c: ^Chunk, $S: Spec, p: Pass_Options, both: bool) {
	read_chunk_in(src, c, S, p, both, PASS_FLOOR)
}

@(private)
read_chunk_in :: #force_inline proc "contextless" (src: []u8, c: ^Chunk, $S: Spec, p: Pass_Options, both: bool, $T: kernel.Tier) #no_bounds_check {
	c.runs[.Line] = reading_from(c.lo, .Line)
	c.runs[.Quoted] = reading_from(c.lo, .Quoted)
	text := src[:c.hi]
	bare := S == .Csv && .Bare_Quote in p.tolerate
	for base := c.lo; base < c.hi; base += 64 {
		b := kernel.load(raw_data(text)[base:]) if c.hi - base >= 64 else kernel.load_padded(text, base)
		m := kernel.pack_n([4]kernel.Block{kernel.eq(b, '"'), kernel.eq(b, p.delim), kernel.eq(b, '\n'), kernel.eq(b, p.comment)})
		q := m[0] if S == .Csv else 0
		marks := m[3] if p.comment != 0 else 0
		read_block(&c.runs[.Line], src, base, q, m[1], m[2], marks, bare, T)
		if both {
			read_block(&c.runs[.Quoted], src, base, q, m[1], m[2], marks, bare, T)
		}
	}
}

// Reads the block at `base` for reading `r`, from the masks of its quotes `q`, delimiters `d`, LFs `nl` and comment
// bytes `marks`, as the pass reads them: a comment line's bytes are text, and with `bare` a quote that opens a run
// anywhere but at a cell's first byte is a bare quote, which is text.
@(private)
read_block :: #force_inline proc "contextless" (r: ^Reading, src: []u8, base: int, q, d, nl, marks: u64, bare: bool, $T: kernel.Tier) #no_bounds_check {
	q, d := q, d
	comments, ends, starts: u64
	if marks != 0 || r.comment {
		if r.comment {
			run, lf := comment_span(nl, 0, true)
			comments, ends = run, lf
			q &= ~run
			d &= ~run
		}
		for left := ((nl << 1) | r.line) & marks; left != 0; {
			s := left & -left
			left &~= s
			if bare {
				drop_bare(r, &q, d | nl, s - 1, T)
			}
			if s & (kernel.prefix_xor(T, q) ~ r.in_quote) != 0 {
				continue
			}
			run, lf := comment_span(nl, s, false)
			comments |= run
			ends |= lf
			starts |= s
			q &= ~run
			d &= ~run
		}
		r.comment = comments >> 63 != 0
	}
	if bare {
		drop_bare(r, &q, d | nl, max(u64), T)
	}
	outside := ~(kernel.prefix_xor(T, q) ~ r.in_quote)
	lfs := nl & outside
	r.in_quote = u64(0) - (~outside >> 63)
	r.start = ((d | nl) & outside) >> 63
	r.close = (q & outside) >> 63
	line := r.line
	r.line = nl >> 63
	// An LF at a line's first byte ends an empty line, no record.
	tally(r, src, base, lfs, lfs &~ ends &~ ((nl << 1) | line), d & outside, ends, starts)
}

// Drops from `q` the bare quotes of the block among the bits of `among`, as `.Bare_Quote` has the pass read them.
@(private)
drop_bare :: #force_inline proc "contextless" (r: ^Reading, q: ^u64, seps, among: u64, $T: kernel.Tier) {
	for {
		_, _, _, b := quote_masks(T, q^, seps, r.in_quote, r.start, r.close)
		if b &= among; b == 0 {
			return
		}
		q^ &~= b & -b
	}
}

// Counts into `r` the nodes and comment lines of the block at `base`, those before the seam into `pre` and those from
// it into `post`, and finds the seam while the reading has none. The masks are `lfs`, the LFs outside quoted cells,
// `records`, those of them that end a line neither empty nor a comment, `ds`, the delimiters outside quoted cells and
// comment lines, `starts`, the comment lines that start in the block, and `ends`, the LFs that end one. A record makes
// a node and one per cell, and its cells end at its delimiters and its LF, so twice its LFs and once its delimiters
// are its nodes. The count is exact for a text with no line holding only a CR.
@(private)
tally :: #force_inline proc "contextless" (r: ^Reading, src: []u8, base: int, lfs, records, ds, ends, starts: u64) #no_bounds_check {
	before := u64(0)
	if r.seam < 0 {
		before = max(u64)
		for m := lfs; m != 0; m &= m - 1 {
			k := uint(intrinsics.count_trailing_zeros(m))
			at := base + int(k)
			lo := r.line_lo
			r.line_lo = at + 1
			// An empty line, a line holding only a CR, and a comment line are no records.
			if lo < 0 || at > lo && !(at == lo + 1 && src[lo] == '\r') && (ends >> k) & 1 == 0 {
				r.seam = at + 1
				before = (u64(2) << k) - 1
				break
			}
		}
	}
	r.pre.nodes += int(intrinsics.count_ones(ds & before) + 2 * intrinsics.count_ones(records & before))
	r.pre.comments += int(intrinsics.count_ones(starts & before))
	r.post.nodes += int(intrinsics.count_ones(ds &~ before) + 2 * intrinsics.count_ones(records &~ before))
	r.post.comments += int(intrinsics.count_ones(starts &~ before))
}

// Plans the parts of the text from the chunks' readings, taking in text order the reading that each chunk's place
// selects, from the first chunk's start at a line. A part ends at a seam past `head_end`, so the first part holds the
// header and a record past it, which tells the comment lines before the header apart from the root's foot. The
// header's line makes no row and counts as `header` nodes.
@(private)
seam_plan :: proc(src: []u8, chunks: []Chunk, head_end, header: int, allocator: runtime.Allocator) -> []build.Part {
	parts := make([dynamic]build.Part, allocator)
	// The root node, and two levels per part, the root's and a record's. A part that plans more nodes than it stores
	// has every part after it moved down when they are joined.
	if _, err := append(&parts, build.Part{nodes = 1 - header, levels = 2}); err != nil {
		delete(parts)
		return nil
	}
	place := Place.Line
	for &c, k in chunks {
		r := &c.runs[place]
		part := &parts[len(parts) - 1]
		part.nodes += r.pre.nodes
		part.comments += r.pre.comments
		if k > 0 && r.seam > head_end {
			part.to = r.seam
			if _, err := append(&parts, build.Part{from = r.seam, opens = SEAM_OPENS[:], levels = 2}); err != nil {
				delete(parts)
				return nil
			}
			part = &parts[len(parts) - 1]
		}
		part.nodes += r.post.nodes
		part.comments += r.post.comments
		place = .Quoted if r.in_quote != 0 else .Line
	}
	// The last record may end at the text's end with no LF.
	last := &parts[len(parts) - 1]
	last.to = len(src)
	last.nodes += 2
	// Shrunk to its length so that the caller's `delete` of the slice frees the whole block.
	shrink(&parts)
	return parts[:]
}

// Walks the part of a text `src` from `from`, a seam or the text's start, to its end, for the builder `h` from its
// registers `regs`. A part past the first starts inside the root's array with `width` the records' width. Each cell's
// key comes from `keys`, which the first part fills with the header's keys. A part before the last, which does not
// `end` the text, gives no `End` of the root. Returns the walk's result, the most cells a record had, whether the walk
// used a tolerance, and whether a part before the last ended other than between two records with no comment line
// held, which a seam the plan misread gives.
@(private)
walk_part :: proc "contextless" (src: []u8, $S: Spec, p: Pass_Options, h: ^build.Builder, regs: ^hook.Regs, from: int, keys: []tape.Token, width: int, end: bool) -> (r: hook.Walk_Result, widest: int, tolerated, astray: bool) {
	w: Pass(S, build.Builder, false, build.BUILDER_CAPS)
	pass_start(&w, len(src), h, p, 0)
	w.p, w.keys, w.width, w.in_header = p, keys, width, !p.no_header && from == 0
	w.opened, w.unclosed = from > 0, !end
	r = run(&w, src, u64(from), p, regs, build.builder_hook_rows)
	// A walk faults as `Truncated` only at the text's end, which a part before the last does not hold.
	astray = !end && (u8(r) == u8(tape.Fault_Kind.Truncated) || u8(r) == 0 && (w.held != 0 || w.rec_lo != len(src)))
	return r, w.widest, w.tolerated, astray
}
