package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Builds a text on the threads of a `tape.Runner`, whichever value holds most of the text. The text is cut into
// chunks, and each chunk is read for its strings, comments and brackets from the two places its first byte is most
// often in: outside strings and comments, and inside a `"` string. Then, in text order, each chunk starts in the place
// the chunk before it ends in, which selects its reading. A chunk whose place is a rarer one is read from that place.
// A chunk's first comma outside strings and comments is a seam, where a walk starts inside the containers that the
// brackets before it leave open. The text between two seams is built by its own walk, and the parts are joined
// (`build.segments_join`) into the document that a single walk would build.
//
// A reading agrees with the single walk over any text that walk accepts. So when the single walk accepts the text up
// to a seam, the walk from that seam continues it exactly, and the first part in text order whose walk does not reach
// the next seam gives the error the single walk would give. A text whose readings cannot be joined, a text that nests
// past `SEAM_LEVELS`, a build that is refused memory and a build under `Budget.memory` of a text with comments or with
// a duplicate policy past `.Default` are built on one thread, which gives the answer.

// The shortest text built on a runner's threads. A shorter text is built sooner on one thread. A chunk is at least a
// sixteenth of this length.
@(private)
PARALLEL_FROM :: #config(JSON_PARALLEL_FROM, 1 << 19)

// The chunks cut per thread, so that a thread that starts late or a slow chunk leaves no thread idle long.
@(private)
CHUNKS_PER_THREAD :: 4

// The container levels a part's walk holds in its frame, so a part's walk allocates nothing. A text that nests deeper
// is built on one thread.
@(private)
SEAM_LEVELS :: WALK_LEVELS - 1

// The most open brackets a reading of a stretch records. A stretch that leaves more open makes the plan fail.
@(private)
SEAM_OPENS :: 64

// The places a byte of the text can lie in during a reading.
@(private)
Lex :: enum u8 {
	Out, // outside strings and comments
	Double, // in a `"` string
	Single, // in a JSON5 `'` string
	Line, // in a `//` comment
	Block, // in a `/* */` comment
}

// The effect of a stretch of a text on the containers open at its start: `pops` of them close, then the `n` brackets in
// `opens` stay open, innermost last. `peak` is the most levels open above its start at once, `comments` the comments
// that start in it, and `nodes` the nodes that follow its open brackets, commas and colons, or more where the reading
// cannot tell that a close bracket follows one of them.
@(private)
Lex_Profile :: struct {
	pops, n, peak, comments, nodes: int,
	opens:                          [SEAM_OPENS]u8,
}

// A chunk read from a place. Holds the place at its end, its seam (one past its first comma outside strings and
// comments that no comment touches, -1 for none), and the profiles of its bytes before the seam and from it. While the
// chunk is read, `end` is the place reached, `at` the first byte not yet read, `comment_end` one past the last
// comment's last byte, `comment_from` the first byte of the comment it is in, and `comment_bytes` the comments' bytes
// in the block read last.
@(private)
Lex_Run :: struct {
	pre, post:       Lex_Profile,
	seam:            int,
	at, comment_end: int,
	comment_from:    int,
	comment_bytes:   u64,
	end:             Lex,
	read:            bool,
	// Set when a close bracket comes before any byte of the chunk other than white space and comments. Such a
	// bracket follows no node when the chunks before it end in an open bracket or a comma. `tail` is what this chunk
	// ends in.
	lead_close:      bool,
	tail:            Lex_Before,
}

// A chunk and its readings from outside strings and comments and from inside a `"` string, and whether the chunk
// after it starts past a line end.
@(private)
Lex_Chunk :: struct {
	lo, hi: int,
	runs:   [2]Lex_Run, // by `Lex`
	line:   bool,
}

// The number of bytes past a cut in which a spec with comments looks for a line end, to cut after it instead.
@(private)
CUT_LINE :: 4096

// The text a part's walk reads, from a seam, or the text's start, to the next seam, or the text's end.
@(private)
Seam_Part :: struct {
	from, to:  int,
	opens:     []u8, // the brackets open at `from`, outermost first
	levels:    int, // the most containers open at once in it
	comments:  int,
	nodes:     int, // the nodes its walk stores, or more
	close:     u64, // where its walk ended
	err:       tape.Error,
	tolerated: bool,
}

@(private)
Lex_Job :: struct {
	src:    []u8,
	chunks: []Lex_Chunk,
	next:   int,
}

@(private)
Part_Job :: struct {
	src:      []u8,
	parts:    []Seam_Part,
	segs:     []build.Segment,
	opts:     Options,
	counting: bool,
	next:     int,
}

// `build` on the threads of `opts.runner`.
@(private)
build_on_threads :: #force_no_inline proc(src: []u8, spec: Spec, opts: Options, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	switch spec {
	case .Json:
		return build_parallel(src, .Json, opts, allocator)
	case .Jsonc:
		return build_parallel(src, .Jsonc, opts, allocator)
	case .Json5:
		return build_parallel(src, .Json5, opts, allocator)
	}
	panic("json: spec out of range")
}

@(private)
build_parallel :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	doc: tape.Document
	err: tape.Error
	built: bool
	if opts.tolerate != {} {
		doc, err, built = build_parts(src, S, true, opts, caller)
	} else {
		doc, err, built = build_parts(src, S, false, opts, caller)
	}
	if built {
		return doc, err
	}
	one := opts
	one.runner = nil
	if one.tolerate != {} || one.budget.steps != 0 {
		return build_as(src, S, true, one, caller)
	}
	return build_as(src, S, false, one, caller)
}

// Builds `src` in parts and returns its document and error, or `built` false for a text built on one thread.
@(private)
build_parts :: proc(src: []u8, $S: Spec, $LAX: bool, opts: Options, caller: runtime.Allocator) -> (doc: tape.Document, err: tape.Error, built: bool) {
	m: hook.Memory_Budget
	allocator := read_allocator(&m, opts, caller)
	start := bom_length(src)
	want := min((opts.runner.threads + 1) * CHUNKS_PER_THREAD, (len(src) - start) / max(PARALLEL_FROM / 16, 1))
	if want < 2 {
		return {}, nil, false
	}
	chunks, cerr := make([]Lex_Chunk, want, allocator)
	if cerr != nil || raw_data(chunks) == nil {
		return {}, nil, false
	}
	defer delete(chunks, allocator)
	lex_cut(src, start, chunks, S)
	lex :: proc(arg: rawptr) {
		j := (^Lex_Job)(arg)
		for {
			k := intrinsics.atomic_add(&j.next, 1)
			if k >= len(j.chunks) {
				return
			}
			// A chunk that starts past a line end is read from outside strings and comments only. It is read from
			// another place only for a text the walk refuses or a block comment across the line end.
			c := &j.chunks[k]
			if k > 0 && !j.chunks[k - 1].line {
				c.runs = lex_pair(j.src, c.lo, c.hi, S)
			} else {
				c.runs[int(Lex.Out)] = lex_run(j.src, c.lo, c.hi, .Out, S)
			}
		}
	}
	lj := Lex_Job{src = src, chunks = chunks}
	hook.fan(opts.runner, lex, &lj)
	limit := depth_limit(opts)
	parts, opens, planned := seam_plan(src, chunks, S, limit, allocator)
	defer delete(parts, allocator)
	defer delete(opens, allocator)
	if !planned || len(parts) < 2 {
		return {}, nil, false
	}
	segs, serr := make([]build.Segment, len(parts), allocator)
	if serr != nil || raw_data(segs) == nil {
		return {}, nil, false
	}
	defer {
		for &s in segs {
			build.segment_free(&s)
		}
		delete(segs, allocator)
	}
	levels := 0
	for p in parts {
		levels += p.levels + 1
	}
	frames, ferr := make([]u64, levels, allocator)
	if ferr != nil || levels > 0 && raw_data(frames) == nil {
		return {}, nil, false
	}
	defer delete(frames, allocator)
	// Each part's walk stores its nodes where a single walk would, after the nodes the parts before it plan. The
	// nodes for the containers open at its seam go after the nodes of all parts.
	total, scratch, comments := 0, 0, 0
	for p, k in parts {
		total += max(p.nodes, 0)
		scratch += len(p.opens) + 1 if k > 0 else 0
		comments += p.comments
	}
	// Under a memory budget the facts and the scratch of a duplicate policy take blocks that one thread sizes as it
	// reads and the parts as the plan counted, so a build that needs either is made on one thread.
	if total > node_most(max(u64), opts) || opts.budget.memory != 0 && (comments > 0 || opts.dups != .Default) {
		return {}, nil, false
	}
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
	kinds: [SEAM_LEVELS]tape.Kind
	for p, k in parts {
		for c, i in p.opens {
			kinds[i] = .Object if c == '{' else .Array
		}
		nodes := max(p.nodes, 0)
		segs[k] = build.segment_start(src, &FORMATS[S], room, first, nodes, scratch, kinds[:len(p.opens)], facts[fact:][:p.comments], frames[levels:][:p.levels + 1], seams[seam:][:len(p.opens)], allocator)
		levels += p.levels + 1
		first += nodes
		fact += p.comments
		seam += len(p.opens)
		scratch += len(p.opens) + 1 if k > 0 else 0
		if segs[k].b.err != nil {
			return {}, nil, false
		}
	}
	walk :: proc(arg: rawptr) {
		j := (^Part_Job)(arg)
		ctx := context
		for {
			k := intrinsics.atomic_add(&j.next, 1)
			if k >= len(j.parts) {
				return
			}
			p, s := &j.parts[k], &j.segs[k]
			on :: build.builder_hook_facts when S != .Json else build.builder_hook
			if k == 0 {
				p.close, p.err, p.tolerated = walk_text(j.src[:p.to], S, LAX, j.opts, &s.b, &s.regs, {}, &ctx, on)
			} else {
				r, took := walk_seam(j.src[:p.to], p.from, p.opens, S, LAX, j.opts.tolerate, depth_limit(j.opts), &s.b, &s.regs, &ctx, on)
				p.close, p.err, _ = hook.walk_error(r, &RULES)
				p.tolerated = took
			}
			if j.counting {
				for n in build.segment_nodes(s) {
					s.containers += int(n.kind == .Array || n.kind == .Object)
				}
			}
		}
	}
	pj := Part_Job{src = src, parts = parts, segs = segs, opts = opts, counting = opts.budget.steps != 0}
	pj.opts.budget.steps = 0
	hook.fan(opts.runner, walk, &pj)
	// The first part in text order that does not reach the next seam gives the build's error, unless a container past
	// `Budget.steps` comes first.
	containers := 0
	for p, k in parts {
		s := &segs[k]
		if opts.budget.steps != 0 && u64(containers + s.containers) > opts.budget.steps {
			for n in build.segment_nodes(s) {
				containers += int(n.kind == .Array || n.kind == .Object)
				if u64(containers) > opts.budget.steps {
					return {}, tape.Exceeded{at = n.lo + 1, kind = .Steps}, true
				}
			}
		}
		if s.b.err != nil {
			return {}, nil, false
		}
		if k < len(parts) - 1 {
			if f, ok := p.err.(tape.Fault); ok && f.kind == .Truncated && f.at == u64(p.to) {
				containers += s.containers
				continue
			}
		} else if p.err == nil {
			break
		}
		if _, refused := p.err.(runtime.Allocator_Error); refused || p.err == nil {
			return {}, nil, false
		}
		return {}, p.err, true
	}
	jerr: runtime.Allocator_Error
	doc, joined, jerr = build.segments_join(segs, room, facts, parts[len(parts) - 1].close, opts.runner, allocator)
	if jerr != nil || !joined {
		return {}, nil, false
	}
	for p in parts {
		if p.tolerated {
			doc.flags += {.Tolerated}
		}
	}
	if e := build.segments_dups(&doc, segs, opts.dups, &RULES, opts.runner); e != nil {
		if _, refused := e.(runtime.Allocator_Error); refused {
			return {}, nil, false
		}
		return {}, e, true
	}
	doc.allocator = caller
	return doc, nil, true
}

// Cuts `src` from `start` into `len(chunks)` chunks of about equal size. A chunk never starts at a byte that follows a
// backslash, `/` or `*`, so no escape or comment marker is split, or at a UTF-8 continuation byte. In a spec with
// comments a chunk starts after a line end when one lies within `CUT_LINE` bytes of the cut, because in a text the
// walk accepts that position is outside strings and line comments.
@(private)
lex_cut :: proc "contextless" (src: []u8, start: int, chunks: []Lex_Chunk, $S: Spec) {
	lo := start
	for &c, k in chunks {
		hi := len(src) if k == len(chunks) - 1 else max(lo, start + (len(src) - start) * (k + 1) / len(chunks))
		when S != .Json {
			for i in hi ..< min(hi + CUT_LINE, len(src)) {
				if src[i] == '\n' {
					hi, c.line = i + 1, true
					break
				}
			}
		}
		for !c.line && hi < len(src) && hi > lo && (src[hi - 1] == '\\' || src[hi - 1] == '/' || src[hi - 1] == '*' || src[hi] & 0xC0 == 0x80) {
			hi += 1
		}
		c.lo, c.hi = lo, hi
		lo = hi
	}
}

// The reading of `src[lo:hi]` from place `from`.
@(private)
lex_run :: proc "contextless" (src: []u8, lo, hi: int, from: Lex, $S: Spec) -> (run: Lex_Run) {
	run = {seam = -1, end = from, read = true, at = lo, comment_end = -1, comment_from = lo}
	lex_on(&run, src, lo, hi, lo, 0, S)
	return
}

// The readings of `src[lo:hi]` from outside strings and comments and from inside a `"` string, made in a single pass
// while their blocks hold no comment marker or JSON5 `'`. Both readings find the same quotes, and each reads the
// brackets and commas outside its own strings, which are the other reading's strings.
@(private)
lex_pair :: proc "contextless" (src: []u8, lo, hi: int, $S: Spec) -> (runs: [2]Lex_Run) #no_bounds_check {
	runs[0] = {seam = -1, end = .Out, read = true, comment_end = -1}
	runs[1] = {seam = -1, end = .Double, read = true, comment_end = -1}
	text := src[:hi]
	odd: u64
	base := lo
	for ; base < hi; base += 64 {
		b := kernel.load_block(STATE_TIER, text, base)
		when S != .Json {
			if lex_marks(b, S) != 0 {
				break
			}
		}
		q := kernel.pack(kernel.eq(b, '"')) &~ kernel.escaped(kernel.pack(kernel.eq(b, '\\')), &odd)
		inside := kernel.prefix_xor(STATE_TIER, q) ~ (max(u64) if runs[0].end == .Double else 0)
		m := lex_brackets(b)
		lex_block(&runs[0], src, lo, base, m, ~inside, 0, 0, S)
		lex_block(&runs[1], src, lo, base, m, inside, 0, 0, S)
		runs[0].end = .Double if inside >> 63 != 0 else .Out
		runs[1].end = .Out if inside >> 63 != 0 else .Double
	}
	for &r in runs {
		r.at = base
		lex_on(&r, src, lo, hi, base, odd, S)
	}
	return
}

// The comment markers, and in JSON5 the `'`, of block `b`.
@(private)
lex_marks :: #force_inline proc "contextless" (b: kernel.Block, $S: Spec) -> u64 {
	when S == .Json5 {
		return kernel.pack(kernel.either(kernel.eq(b, '/'), kernel.eq(b, '\'')))
	} else when S == .Jsonc {
		return kernel.pack(kernel.eq(b, '/'))
	} else {
		return 0
	}
}

// The open brackets, close brackets, commas and colons of block `b`.
@(private)
lex_brackets :: #force_inline proc "contextless" (b: kernel.Block) -> [4]u64 {
	return kernel.pack_n([4]kernel.Block{kernel.either(kernel.eq(b, '['), kernel.eq(b, '{')), kernel.either(kernel.eq(b, ']'), kernel.eq(b, '}')), kernel.eq(b, ','), kernel.eq(b, ':')})
}

// Reads the brackets, commas and colons `m` of the block at `base` that lie in `outside`, outside the strings and
// comments of `run`, of which `comments` holds the comments' bytes and `starts` their first bytes. Each node but the
// root follows an open bracket, a comma or a colon, and each of those is followed by a node unless a close bracket
// comes next. The seam's comma counts in the profile after it, whose part holds that node.
@(private)
lex_block :: #force_inline proc "contextless" (run: ^Lex_Run, src: []u8, lo, base: int, m: [4]u64, outside, comments, starts: u64, $S: Spec) #no_bounds_check {
	opens, closes := m[0] & outside, m[1] & outside
	after := max(u64) if run.seam >= 0 else 0
	p := &run.post if run.seam >= 0 else &run.pre
	commas := m[2] & outside if run.seam < 0 else 0
	for bits := opens | closes | commas; bits != 0; bits &= bits - 1 {
		k := base + int(intrinsics.count_trailing_zeros(bits))
		bit := bits & -bits
		switch {
		case opens & bit != 0:
			lex_open(p, src[k])
		case closes & bit != 0:
			lex_close(p)
			switch lex_follows_open(src, lo, base, k, run, comments, S) {
			case .Open:
				p.nodes -= 1
			case .Chunk:
				run.lead_close = true
			case .Unknown, .Other:
			}
		case run.seam < 0 && seam_at(src, lo, base, k, run, comments, S):
			run.seam = k + 1
			after = -bit
			p = &run.post
		}
	}
	intro := (m[0] | m[2] | m[3]) & outside
	run.pre.nodes += int(intrinsics.count_ones(intro &~ after))
	run.post.nodes += int(intrinsics.count_ones(intro & after))
	run.pre.comments += int(intrinsics.count_ones(starts &~ after))
	run.post.comments += int(intrinsics.count_ones(starts & after))
}

// Reads on from the block at `base` to `hi`, in the place `run.end`, from byte `run.at`, with `odd` set when the byte
// before `base` escapes the one at it. A block that starts outside comments and holds no comment marker or JSON5 `'`
// outside its `"` strings is read whole from its masks. Any other block's strings and comments are read from its
// quotes, comment markers and line ends only, and its brackets then from masks too.
@(private)
lex_on :: proc "contextless" (run: ^Lex_Run, src: []u8, lo, hi, base: int, odd: u64, $S: Spec) #no_bounds_check {
	text := src[:hi]
	odd := odd
	base := base
	for ; base < hi; base += 64 {
		b := kernel.load_block(STATE_TIER, text, base)
		escaped := kernel.escaped(kernel.pack(kernel.eq(b, '\\')), &odd)
		q := kernel.pack(kernel.eq(b, '"')) &~ escaped
		m := lex_brackets(b)
		if run.end <= .Double && run.at <= base {
			inside := kernel.prefix_xor(STATE_TIER, q) ~ (max(u64) if run.end == .Double else 0)
			if lex_marks(b, S) &~ inside == 0 {
				lex_block(run, src, lo, base, m, ~inside, 0, 0, S)
				run.end = .Double if inside >> 63 != 0 else .Out
				run.comment_bytes = 0
				continue
			}
		}
		strings, comments, starts := lex_comments(run, src, hi, base, b, q, escaped, S)
		lex_block(run, src, lo, base, m, ~(strings | comments), comments, starts, S)
		run.comment_bytes = comments
	}
	switch run.end {
	case .Out:
		run.tail = lex_follows_open(src, lo, base, hi, run, 0, S)
	case .Line, .Block:
		run.tail = lex_follows_open(src, lo, base, run.comment_from, run, 0, S)
	case .Double, .Single:
		run.tail = .Other
	}
}

// The bytes of the block at `base` in strings and in comments, and the comments' first bytes, read from the place
// `run.end` from byte `run.at` with masks: the strings of its quotes `q` up to the first comment marker outside them,
// then that comment up to its end, and so on. `run.comment_end` records where the last comment ended. `escaped` marks
// the bytes a backslash escapes, which matter only for a quote, since no comment ends at a byte that a backslash in it
// could escape. A block with a JSON5 `'` string is read by `lex_events`.
@(private)
lex_comments :: #force_inline proc "contextless" (run: ^Lex_Run, src: []u8, hi, base: int, b: kernel.Block, q, escaped: u64, $S: Spec) -> (strings, comments, starts: u64) #no_bounds_check {
	marks := kernel.pack_n([3]kernel.Block{kernel.eq(b, '/'), kernel.eq(b, '*'), kernel.either(kernel.eq(b, '\n'), kernel.eq(b, '\r'))})
	slash, star, lines := marks[0], marks[1], marks[2]
	// The byte past the block, which a marker at the block's last byte pairs with.
	next := src[base + 64] if base + 64 < hi else 0
	opens := slash & ((slash | star) >> 1 | u64(next == '/' || next == '*') << 63)
	closes := star & (slash >> 1 | u64(next == '/') << 63)
	when S == .Json5 {
		singles := kernel.pack(kernel.eq(b, '\'')) &~ escaped
		lines |= kernel.pack(kernel.eq(b, 0xe2))
	}
	pos, from := 0, 0
	if run.at > base {
		pos = run.at - base
		if run.end == .Out {
			comments = 1
		}
	}
	for pos < 64 {
		above := max(u64) << uint(pos)
		switch run.end {
		case .Line:
			ends := lines & above
			when S == .Json5 {
				for ends != 0 && !line_end(raw_data(src)[base + int(intrinsics.count_trailing_zeros(ends)):], raw_data(src)[len(src):], S) {
					ends &= ends - 1
				}
			}
			if ends == 0 {
				comments |= max(u64) << uint(from)
				return
			}
			e := int(intrinsics.count_trailing_zeros(ends))
			comments |= lex_span(from, e)
			run.end, run.comment_end, pos = .Out, base + e, e + 1
		case .Block:
			ends := closes & above
			if ends == 0 {
				comments |= max(u64) << uint(from)
				return
			}
			e := int(intrinsics.count_trailing_zeros(ends))
			comments |= lex_span(from, e + 1)
			run.end, run.comment_end, run.at, pos = .Out, base + e + 2, base + e + 2, e + 2
		case .Single:
			when S == .Json5 {
				s, c, t := lex_events(run, src, hi, base, b, q, singles, pos, from, S)
				return strings | s, comments | c, starts | t
			}
		case .Out, .Double:
			inside := kernel.prefix_xor(STATE_TIER, q & above) ~ (above if run.end == .Double else 0)
			first := opens &~ inside & above
			when S == .Json5 {
				first |= singles &~ inside & above
			}
			if first == 0 {
				strings |= inside & above
				run.end = .Double if inside >> 63 != 0 else .Out
				return
			}
			j := int(intrinsics.count_trailing_zeros(first))
			strings |= inside & above & ~(max(u64) << uint(j))
			when S == .Json5 {
				if singles >> uint(j) & 1 != 0 {
					run.end = .Out
					s, c, t := lex_events(run, src, hi, base, b, q, singles, j, j, S)
					return strings | s, comments | c, starts | t
				}
			}
			run.end = .Line if src[base + j + 1] == '/' else .Block
			run.at, run.comment_from = base + j + 2, base + j
			starts |= 1 << uint(j)
			from, pos = j, j + 2
		}
	}
	return
}

// Continues `lex_comments` from byte `pos` of the block, in the place `run.end` since byte `from`, reading event by
// event. Used for a JSON5 block with a `'` string. `singles` holds its unescaped `'`.
@(private)
lex_events :: proc "contextless" (run: ^Lex_Run, src: []u8, hi, base: int, b: kernel.Block, q, singles: u64, pos, from: int, $S: Spec) -> (strings, comments, starts: u64) #no_bounds_check {
	end := raw_data(src)[len(src):]
	marks := kernel.pack_n([4]kernel.Block{kernel.eq(b, '/'), kernel.eq(b, '*'), kernel.either(kernel.eq(b, '\n'), kernel.eq(b, '\r')), kernel.eq(b, 0xe2)})
	events := (q | singles | marks[0] | marks[1] | marks[2] | marks[3]) & (max(u64) << uint(pos))
	from := from
	for ; events != 0; events &= events - 1 {
		bit := int(intrinsics.count_trailing_zeros(events))
		k := base + bit
		c := src[k]
		switch run.end {
		case .Out:
			switch c {
			case '"':
				run.end, from = .Double, bit
			case '\'':
				run.end, from = .Single, bit
			case '/':
				if k + 1 < hi && (src[k + 1] == '/' || src[k + 1] == '*') {
					run.end = .Line if src[k + 1] == '/' else .Block
					from, run.at, run.comment_from = bit, k + 2, k
					starts |= 1 << uint(bit)
					events &= ~(2 << uint(bit))
				}
			}
		case .Double, .Single:
			if c == ('"' if run.end == .Double else '\'') {
				strings |= lex_span(from, bit)
				run.end = .Out
			}
		case .Line:
			if line_end(raw_data(src)[k:], end, S) {
				comments |= lex_span(from, bit)
				run.end, run.comment_end = .Out, k
			}
		case .Block:
			if c == '*' && k + 1 < hi && src[k + 1] == '/' {
				comments |= lex_span(from, bit + 1)
				run.end, run.comment_end, run.at = .Out, k + 2, k + 2
				events &= ~(2 << uint(bit))
			}
		}
	}
	switch run.end {
	case .Double, .Single:
		strings |= max(u64) << uint(from)
	case .Line, .Block:
		comments |= max(u64) << uint(from)
	case .Out:
	}
	return
}

// A mask of the bits `lo` to `hi`, both included. `hi` may be 64.
@(private)
lex_span :: #force_inline proc "contextless" (lo, hi: int) -> u64 {
	return (max(u64) << uint(lo)) & ~(max(u64) << uint(hi + 1)) if hi < 63 else max(u64) << uint(lo)
}

@(private)
lex_open :: #force_inline proc "contextless" (p: ^Lex_Profile, c: u8) {
	if p.n < SEAM_OPENS {
		p.opens[p.n] = c
	}
	p.n += 1
	p.peak = max(p.peak, p.n - p.pops)
}

@(private)
lex_close :: #force_inline proc "contextless" (p: ^Lex_Profile) {
	if p.n > 0 {
		p.n -= 1
	} else {
		p.pops += 1
	}
}

// Whether the byte at `y` lies in a comment, or may. `comments` is the comment mask of the block at `base` that `run`
// is reading. A `y` in that block is judged by `comments`, a `y` in the block before it by `run.comment_bytes`, and an
// earlier `y` by `run.comment_end`.
@(private)
lex_in_comment :: #force_inline proc "contextless" (y, base: int, run: ^Lex_Run, comments: u64) -> bool {
	switch {
	case y >= base:
		return comments >> uint(y - base) & 1 != 0
	case y >= base - 64:
		return run.comment_bytes >> uint(y - base + 64) & 1 != 0
	}
	return y < run.comment_end
}

// What the last byte before a position is to a chunk's reading, past white space and comments.
@(private)
Lex_Before :: enum u8 {
	Unknown, // a byte that may lie in a comment the reading has passed
	Chunk, // the search reached the chunk's start
	Open, // an open bracket or a comma, which a close bracket at `k` follows with no node between
	Other,
}

// Classifies the last byte before `k`, past white space and comments, for the reading `run` of a chunk from `lo`, in
// the block at `base` whose comment bytes are `comments`.
@(private)
lex_follows_open :: #force_inline proc "contextless" (src: []u8, lo, base, k: int, run: ^Lex_Run, comments: u64, $S: Spec) -> Lex_Before #no_bounds_check {
	for y := k - 1; y >= lo; y -= 1 {
		c := src[y]
		if kernel.is_ws(c) || S == .Json5 && (c == 0x0b || c == 0x0c) {
			continue
		}
		if !lex_in_comment(y, base, run, comments) {
			return .Open if c == ',' || c == '[' || c == '{' else .Other
		}
		if y < base - 64 {
			return .Unknown
		}
	}
	return .Chunk
}

// Whether cutting the text after the comma at `k`, outside strings and comments, leaves the walks reading it as a
// single walk does. A comment before the comma, with only white space between, would take its role from the token
// after the cut, so that comma is no seam. A comment that starts after the comma takes the same role either way.
@(private)
seam_at :: #force_inline proc "contextless" (src: []u8, lo, base, k: int, run: ^Lex_Run, comments: u64, $S: Spec) -> bool #no_bounds_check {
	when S == .Json {
		return true
	} else {
		y := k - 1
		for y >= lo && (kernel.is_ws(src[y]) || S == .Json5 && (src[y] == 0x0b || src[y] == 0x0c || src[y] >= 0x80)) {
			y -= 1
		}
		return y >= lo && !lex_in_comment(y, base, run, comments)
	}
}

// Plans the parts of the text from the chunks' readings, picked in text order. The brackets open at each part's seam
// are kept in `opens`. `ok` is false when the readings cannot be joined or the text nests past `SEAM_LEVELS`, counting
// levels up to `limit`.
@(private)
seam_plan :: proc(src: []u8, chunks: []Lex_Chunk, $S: Spec, limit: u64, allocator: runtime.Allocator) -> (parts: []Seam_Part, opens: []u8, ok: bool) {
	list: [dynamic]Seam_Part
	list.allocator = allocator
	held: [dynamic]u8
	held.allocator = allocator
	open: [dynamic]u8
	open.allocator = allocator
	defer delete(open)
	defer if !ok {
		delete(list)
		delete(held)
	}
	apply :: proc(open: ^[dynamic]u8, p: ^Lex_Profile, limit: u64, part: ^Seam_Part) -> bool {
		levels := min(len(open) + p.peak, int(limit))
		if p.pops > len(open) || p.n > SEAM_OPENS || levels > SEAM_LEVELS {
			return false
		}
		part.levels = max(part.levels, levels)
		part.comments += p.comments
		part.nodes += p.nodes
		resize(open, len(open) - p.pops)
		_, err := append(open, ..p.opens[:p.n])
		return err == nil
	}
	if _, err := append(&list, Seam_Part{nodes = 1}); err != nil {
		return
	}
	state := Lex.Out
	tail_open := false
	for &c, k in chunks {
		rare: Lex_Run
		r := &c.runs[int(state)] if state <= .Double else &rare
		if !r.read {
			r^ = lex_run(src, c.lo, c.hi, state, S)
		}
		if !apply(&open, &r.pre, limit, &list[len(list) - 1]) {
			return
		}
		list[len(list) - 1].nodes -= int(r.lead_close && tail_open)
		tail_open = r.tail == .Open || r.tail == .Chunk && tail_open
		if r.seam >= 0 {
			if k > 0 {
				if len(open) == 0 {
					return
				}
				list[len(list) - 1].to = r.seam
				part := Seam_Part{from = r.seam, opens = transmute([]u8)runtime.Raw_Slice{data = rawptr(uintptr(len(held))), len = len(open)}, levels = len(open)}
				if _, err := append(&list, part); err != nil {
					return
				}
				if _, err := append(&held, ..open[:]); err != nil {
					return
				}
			}
			if !apply(&open, &r.post, limit, &list[len(list) - 1]) {
				return
			}
		}
		state = r.end
	}
	list[len(list) - 1].to = len(src)
	// Shrunk to their lengths so that the caller's `delete` of the returned slices frees the whole blocks.
	shrink(&list)
	shrink(&held)
	// A part's `opens` holds an offset into `held` until the shrink has settled where `held` lives.
	for &p in list {
		p.opens = held[uintptr(raw_data(p.opens)):][:len(p.opens)]
	}
	return list[:], held[:], true
}

// Walks `src` from `from`, one past a comma inside the containers whose open brackets `opens` holds, outermost first.
// Returns the walk's result and whether it used a rule of `tolerate`. Hook `h`'s registers `regs` hold those
// containers, and `ctx` is the context for the hook's calls. The levels stay in the walk's frame and the hook's,
// because no part nests past either, so a deeper text is refused memory. A text cut at the end of `src` ends there as
// `Truncated`.
@(private)
walk_seam :: proc "contextless" (src: []u8, from: int, opens: []u8, $S: Spec, $LAX: bool, tolerate: tape.Tolerances, limit: u64, h: ^$H, regs: ^hook.Regs, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (hook.Walk_Result, bool) {
	hook.check(H)
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	#assert(.Walk not_in C)
	stack: [WALK_LEVELS]u32 = ---
	w: Walk(S, H, LAX, C) = ---
	walk_init(&w, src, raw_data(stack[:]), h, regs, {}, ctx, limit, tolerate, 0)
	w.depth = min(w.limit, u64(hook.levels_held(h)))
	stack[0] = u32(']') | u32(GAP_OFF) << 8
	for i in 1 ..< len(opens) {
		stack[i] = u32(']') | u32(opens[i - 1] == '{') << 5 | u32(GAP_OFF) << 8
	}
	when LAX {
		w.piece[0] = nil
	}
	w.gap_lo = GAP_UNLEARNABLE
	d := u64(len(opens)) << 1 | u64(opens[len(opens) - 1] == '{')
	// An object matches its members against its own row, live from its first member, because the seam's members
	// continue the shape the part before it read. An array gives each of its objects a row, as the root does.
	m := u64(GAP_START)
	if gaps_rows(m) && d & 1 != 0 {
		gap_new_row(&w.gaps, m)
		m = gap_row_live(&w.gaps, m)
	}
	end := raw_data(src)[len(src):]
	r := enter_member(raw_data(src)[from:], end, d, INDENT_START, &w, regs^, m, on)
	r = walk_tail(&w, r, end, on)
	return r, w.tolerated when LAX else false
}
