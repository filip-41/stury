package yaml

import "base:runtime"
import core "../core"
import engine "../core/build"
import "../core/records"

// YAML's `Services.scan` walk and its record service, which `core/build`'s path reads run. A read walks the document
// once from its first byte, the walk's tokens passing the filter to the read's hook, which skips what no path needs. A
// read that reaches an alias it does not skip answers from the built document instead.

// What a read's walk keeps beside the read: the filter its tokens pass, and the log of every token when a path counts
// from the end, whose ring of elements is read again from the log once the container's length is known.
@(private)
Scanner :: struct {
	filter: Filter,
	log:    Token_Log,
	sink:   Token_Sink,
}

// A stream's `on` and the answers it was given, which a read that answers from the built document does not give again.
@(private)
Counted :: struct {
	state: rawptr,
	on:    proc(state: rawptr, a: core.Token_Answer) -> bool,
	given: int,
}

@(private)
count_answer :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	c := (^Counted)(state)
	c.given += 1
	return c.on(c.state, a)
}

// How the scan picks among the matches of a name. A text that reads holds no repeated key, so the first match is the
// only one: a read that stops early answers at it, and any other read answers at its container's close, in the order a
// query of the built document gives.
@(private)
scan_policy :: #force_inline proc "contextless" (read: core.Path_Options) -> core.Duplicates {
	return .First if read.stop_early else .Last
}

// The handle's `scan`: the text's one document, and the fault of any later one.
@(private)
scan_as :: proc(src: []u8, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (doc: core.Document, err: core.Path_Error) {
	if f, bad := policy_fault(read.dups).?; bad {
		return {}, {kind = .Walk, inner = f}
	}
	read := read
	read.dups = scan_policy(read)
	opts := options_of(handle)
	// The scan's room as words, which an uninitialized declaration leaves unwritten where a struct's padding would not.
	room: [size_of(engine.Scan) / 8]u64 = ---
	h := (^engine.Scan)(rawptr(&room))
	frames: [core.MAX_DEPTH]u64 = ---
	counted := Counted{state = state, on = on}
	if e := engine.scan_start(h, src, handle, paths, read, false, allocator, min(core.reserve_depth(opts.max_depth, len(src)), core.MAX_DEPTH), frames[:], on != nil, &counted, count_answer if on != nil else nil); e.kind != .None {
		return {}, e
	}
	regs := engine.BUILDER_REGS
	hi, fault, stopped, found, aliased := scan_document(h, src, 0, opts, on != nil, paths, &regs)
	if aliased {
		engine.scan_end(h, regs, 0, core.Fault{at = hi, rules = &RULES, kind = .Truncated}, &doc)
		return answer_built(src, handle, paths, read, &counted, allocator)
	}
	if fault == nil && !stopped {
		if fault = tail_fault(src, hi, opts); fault == nil && !found {
			at := u64(len(src))
			fault = core.Fault{at = at, rules = &RULES, kind = .Truncated, detail = u8(Detail.No_Document)}
		}
	}
	err = engine.scan_end(h, regs, 0, fault, &doc)
	return
}

// Answers `paths` over the built document of `src`, and gives a stream the answers past those it was given.
@(private)
answer_built :: proc(src: []u8, handle: core.As, paths: []core.Path, read: core.Path_Options, counted: ^Counted, allocator: runtime.Allocator) -> (core.Document, core.Path_Error) {
	built, berr := build_as(src, handle, true, allocator)
	if berr.kind != .None {
		return {}, core.path_error(berr)
	}
	doc, err := built_answers(&built, paths)
	if err.kind != .None || counted.on == nil {
		return doc, err
	}
	for a in doc.answers[min(counted.given, len(doc.answers)):] {
		if !counted.on(counted.state, token_answer(&doc, a)) {
			break
		}
	}
	return doc, {}
}

// Answers `paths` over the document `built`, which it returns with the answers, or destroys on an error.
@(private)
built_answers :: proc(built: ^core.Document, paths: []core.Path) -> (core.Document, core.Path_Error) {
	answers, e := engine.query(built, paths, {}, built.allocator)
	if e.kind == .None {
		defer delete(answers, built.allocator)
		built.answers, built.kept, built.missing = answers, nil, nil
		if core.own_reads(built) == nil {
			return built^, {}
		}
		e = {kind = .No_Memory}
	}
	core.destroy(built)
	return {}, e
}

// The answer `each_answer` gives for answer `a` of the built document `doc`.
@(private)
token_answer :: proc(doc: ^core.Document, a: core.Answer) -> core.Token_Answer {
	t := core.Token{kind = .Null}
	lo, hi: u64
	if a.node != core.NO_NODE && (a.outcome == .Found || a.outcome == .Wrong_Kind) {
		t = doc.nodes[a.node]
		if a.outcome == .Found {
			lo, hi = core.scalar_ends(t)
			if t.kind > .Plain {
				lo, hi = t.lo, close_end(doc, a.node)
			}
		}
	} else if a.owner != core.NO_NODE {
		t = core.Token{lo = close_end(doc, a.owner), kind = .End}
	}
	return {t, lo, hi, a.path, a.outcome}
}

// Walks the document at `lo` of `src` with the hook of the read `h` of `paths`, the stream's when `stream` is set, from
// and into `regs`. Returns the byte after the document, the fault, whether the read stopped the walk, whether there
// was a document and whether the walk stopped at an alias.
@(private)
scan_document :: proc(h: ^engine.Scan, src: []u8, lo: u64, opts: Options, stream: bool, paths: []core.Path, regs: ^core.Hook_Regs) -> (hi: u64, fault: Maybe(core.Fault), stopped, found, aliased: bool) {
	sc := Scanner{filter = {scan = h, stream = stream, src = src}, sink = hook_sink(Filter, read_filter_hook)}
	defer {
		delete(sc.log.tokens)
		delete(sc.log.opens)
	}
	w := Walk_State(Filter){h = &sc.filter, regs = regs^}
	if h.many != nil && counts_from_end(paths) {
		w.log = &sc.log
		h.rewalk = rewalk
	}
	h.opts = &sc
	defer h.opts = nil
	p: Parser
	parser_init(&p, src, opts, sc.sink, &w)
	defer parser_destroy(&p)
	p.pos = core.text_start(src, lo)
	p.ls = p.pos
	ok: bool
	if found, ok = read_document(&p); ok {
		p.fail = core.fault_at(p.pos, .None)
	}
	regs^ = w.regs
	hi, fault, stopped = core.result_of(p.fail, &RULES)
	if sc.filter.aliased {
		return hi, nil, false, found, true
	}
	if sc.filter.found {
		fault, stopped = complex_key(sc.filter.complex), false
	}
	return
}

// An iterator over the answers of `paths`, or of `one` when `paths` is nil, in a text read with handle `handle`.
@(private)
answers_of :: proc(src: []u8, handle: core.As, paths: []core.Path, one: core.Path, read: core.Path_Options, allocator: runtime.Allocator) -> engine.Answer_Iter {
	return {src = src, as = handle, paths = paths, one = one, read = read, allocator = allocator, fill = answers_fill, max_batch = engine.ANSWER_BATCH}
}

// What an iterator's walk keeps across fills, from the iterator's allocator, its address in the iterator's `cursor`:
// the scan's filter and log, the walk's cursor, and the number of answers the fills before gave, which a read that
// reaches an alias does not give again.
@(private)
Answer_Walk :: struct {
	scanner: Scanner,
	cursor:  Cursor,
	log:     ^Token_Log, // `scanner.log` when a path counts from the end, nil else
	given:   int,
}

// The fill of an iterator: the walk with a cursor, which stops once the buffer holds a batch. It ends the read as
// `scan_as` does.
@(private)
answers_fill :: proc(it: ^engine.Answer_Iter) {
	h := &it.scan
	src := it.src
	opts := options_of(it.as)
	slot := (^^Answer_Walk)(&it.cursor)
	hi: u64
	fault: Maybe(core.Fault)
	found := true
	if it.state == .Fresh {
		if f, bad := policy_fault(it.read.dups).?; bad {
			engine.answers_fail(it, core.error_of(core.Path_Error{kind = .Walk, inner = f}))
			return
		}
		it.read.dups = scan_policy(it.read)
		if !engine.answers_start(it, false, min(core.reserve_depth(opts.max_depth, len(src)), core.MAX_DEPTH)) {
			return
		}
		aw, e := new(Answer_Walk, it.allocator)
		if e != nil {
			engine.answers_fail(it, core.error_of(core.Path_Error{kind = .No_Memory}))
			return
		}
		slot^ = aw
		it.release = answers_release
		aw.scanner = {filter = {scan = h, stream = true, src = src}, sink = hook_sink(Filter, read_filter_hook)}
		paths := it.paths if it.paths != nil else ([^]core.Path)(&it.one)[:1]
		if h.many != nil && counts_from_end(paths) {
			aw.log = &aw.scanner.log
			h.rewalk = rewalk
		}
		h.pause_on_flush = true
		it.regs = engine.BUILDER_REGS
		h.opts = &aw.scanner
		hi, fault, found = walk_saving(src, 0, opts, &aw.scanner.filter, &it.regs, read_filter_hook, &aw.cursor, aw.log)
	} else {
		h.opts = &slot^.scanner
		hi, fault = resume_held(src, &slot^.cursor, opts, &slot^.scanner.filter, &it.regs, read_filter_hook, slot^.log)
	}
	h.opts = nil
	aw := slot^
	filter := &aw.scanner.filter
	if filter.aliased {
		answers_built(it, aw.given + len(it.buffer), hi)
		return
	}
	if !h.stopped && !filter.found && can_resume(&aw.cursor) {
		aw.given += len(it.buffer)
		return
	}
	if filter.found {
		fault = complex_key(filter.complex)
	} else if fault == nil && !h.stopped {
		if fault = tail_fault(src, hi, opts); fault == nil && !found {
			fault = core.Fault{at = u64(len(src)), rules = &RULES, kind = .Truncated, detail = u8(Detail.No_Document)}
		}
	}
	engine.answers_end(it, 0, fault)
}

// Ends the read of an iterator whose walk stopped at an alias at `hi`, past `given` answers: the rest come from the
// built document, as `answer_built` gives them.
@(private)
answers_built :: proc(it: ^engine.Answer_Iter, given: int, hi: u64) {
	doc: core.Document
	_ = engine.scan_end(&it.scan, it.regs, 0, core.Fault{at = hi, rules = &RULES, kind = .Truncated}, &doc)
	core.destroy(&doc)
	built, berr := build_as(it.src, it.as, true, it.allocator)
	if berr.kind != .None {
		engine.answers_fail(it, core.error_of(core.path_error(berr)))
		return
	}
	paths := it.paths if it.paths != nil else ([^]core.Path)(&it.one)[:1]
	answered, err := built_answers(&built, paths)
	defer core.destroy(&answered)
	if err.kind == .None {
		for a in answered.answers[min(given, len(answered.answers)):] {
			if _, e := append(&it.buffer, token_answer(&answered, a)); e != nil {
				err = {kind = .No_Memory}
				break
			}
		}
	}
	engine.answers_fail(it, core.error_of(err))
}

// The iterator's `release`: frees its walk.
@(private)
answers_release :: proc(it: ^engine.Answer_Iter) {
	slot := (^^Answer_Walk)(&it.cursor)
	aw := slot^
	if aw == nil {
		return
	}
	cursor_destroy(&aw.cursor)
	delete(aw.scanner.log.tokens)
	delete(aw.scanner.log.opens)
	free(aw, it.allocator)
	slot^ = nil
}

// Whether a step of `paths` counts from the end of its container.
@(private)
counts_from_end :: proc(paths: []core.Path) -> bool {
	for path in paths {
		for step in path.steps {
			#partial switch x in step {
			case core.Index:
				if x < 0 {
					return true
				}
			case core.Slice:
				if x.lo < 0 || (x.hi.? or_else 0) < 0 {
					return true
				}
			}
		}
	}
	return false
}

// The read's `rewalk`: the tokens of the container that opened at `lo`, from the log, the latest such container being
// the ring's element.
@(private)
rewalk :: proc "contextless" (h: ^engine.Scan, s: ^core.Hook_Regs, lo: u64, _: core.Node_Index) {
	sc := (^Scanner)(h.opts)
	log := &sc.log
	k := len(log.opens) - 1
	for k >= 0 && log.tokens[log.opens[k]].lo != lo {
		k -= 1
	}
	if k < 0 {
		return
	}
	w := Walk_State(Filter){h = &sc.filter, regs = s^}
	depth := 0
	for t in log.tokens[log.opens[k]:] {
		if t.kind == .Array || t.kind == .Object {
			depth += 1
		} else if t.kind == .End {
			depth -= 1
		}
		if !sc.sink(&w, t) || depth == 0 {
			break
		}
	}
	s^ = w.regs
}

// The record service `scan`: the walk that frames a document reads `path` in it. A read that stops early leaves the
// document's end to a walk with no hook, and one that reaches an alias builds the document.
@(private)
scan_record :: proc(it: ^records.Reader, h: ^engine.Scan, last: ^core.Document, path: core.Path, read: core.Path_Options) -> (rec: records.Record, err: core.Path_Error, ok: bool) {
	lo := it.pos
	if lo >= u64(len(it.src)) || it.to != 0 && lo >= it.to {
		return
	}
	if f, bad := policy_fault(read.dups).?; bad {
		it.fault = f
		return rec, {kind = .Walk, inner = f}, false
	}
	read := read
	read.dups = scan_policy(read)
	opts := options_of(it.as)
	frames: [core.MAX_DEPTH]u64 = ---
	// The builder keeps `room` past the read, unread until `scan_again` replaces it.
	room := ([^]u64)(rawptr(&frames))[:core.MAX_DEPTH]
	depth := min(core.reserve_depth(opts.max_depth, len(it.src)), core.MAX_DEPTH)
	started: core.Path_Error
	if h.again {
		started = engine.scan_again(h, it.src, it.as, it.allocator, room[:depth])
	} else {
		core.destroy(last)
		started = engine.scan_start(h, it.src, it.as, []core.Path{path}, read, false, it.allocator, depth, room)
		h.again = started.kind == .None && h.many == nil
	}
	if started.kind != .None {
		rec, ok = next_document(it)
		return rec, started, ok
	}
	regs := engine.BUILDER_REGS
	paths := [1]core.Path{path}
	hi, fault, stopped, found, aliased := scan_document(h, it.src, lo, opts, false, paths[:], &regs)
	if aliased {
		return built_record(it, h, regs, last, paths[:], read)
	}
	switch {
	case stopped:
		rec, ok = next_document(it)
	case fault != nil:
		it.fault = fault
	case !found || hi <= lo:
		it.pos = u64(len(it.src))
	case:
		it.pos = hi
		rec, ok = {text = it.src[lo:hi], at = lo}, true
	}
	// The records' end, which is no fault of theirs, ends the read with one and is no error.
	ended := it.fault
	if !ok && ended == nil {
		ended = core.Fault{at = u64(len(it.src)), rules = &RULES, kind = .Truncated}
	}
	e := engine.scan_end(h, regs, 0, ended, last)
	if !ok && it.fault == nil {
		return rec, {}, false
	}
	return rec, e, ok
}

// Ends the read `h` that reached an alias in the document at the reader's position, and answers `paths` over the
// document built into `last`. The next record starts a new read, since `last` holds none of the read's buffers.
@(private)
built_record :: proc(it: ^records.Reader, h: ^engine.Scan, regs: core.Hook_Regs, last: ^core.Document, paths: []core.Path, read: core.Path_Options) -> (rec: records.Record, err: core.Path_Error, ok: bool) {
	engine.scan_end(h, regs, 0, core.Fault{at = it.pos, rules = &RULES, kind = .Truncated}, last)
	if h.again {
		engine.scan_free(h, it.allocator)
		h.again = false
	}
	last^ = {}
	if rec, ok = next_document(it); !ok {
		return
	}
	built, berr := build_document(it, rec, it.allocator)
	if berr.kind != .None {
		return rec, core.path_error(berr), true
	}
	last^, err = built_answers(&built, paths)
	return rec, err, true
}
