package xml

import "base:runtime"
import core "../core"
import engine "../core/build"

// The path reads of `core/build`. `scan`, `each_answer` and `find` take `spec` and `opts`. A name step in `{uri}local`
// form matches an element by its namespace and local name.
scan :: proc {scan_bound_one, scan_bound_many, scan_chosen_one, scan_chosen_many}

@(private)
scan_bound_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return scan_bound_many(src, S, []core.Path{path}, opts, read, allocator)
}

@(private)
scan_bound_many :: proc(src: []u8, $S: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	if read.dups == .Refuse {
		built, e := build_bound(src, S, opts, .Refuse, allocator)
		return engine.query_built(&built, e, paths, read)
	}
	doc, err := scan_spec(src, S, bound_as(S, opts), paths, read, nil, nil, allocator)
	return doc, core.error_of(err)
}

@(private)
scan_chosen_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return engine.scan_one(src, as(spec, opts), path, read, allocator)
}

@(private)
scan_chosen_many :: #force_inline proc(src: []u8, spec: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return engine.scan_many(src, as(spec, opts), paths, read, allocator)
}

each_answer :: proc {each_answer_bound_one, each_answer_bound_many, each_answer_chosen_one, each_answer_chosen_many}

@(private)
each_answer_bound_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return each_answer_bound_many(src, S, []core.Path{path}, state, on, opts, read, allocator)
}

@(private)
each_answer_bound_many :: proc(src: []u8, $S: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	if read.dups == .Refuse {
		built, e := build_bound(src, S, opts, .Refuse, allocator)
		core.destroy(&built)
		if e != nil {
			return e
		}
	}
	doc, err := scan_spec(src, S, bound_as(S, opts), paths, read, state, on, allocator)
	core.destroy(&doc)
	return core.error_of(err)
}

@(private)
each_answer_chosen_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return engine.each_answer_one(src, as(spec, opts), path, state, on, read, allocator)
}

@(private)
each_answer_chosen_many :: #force_inline proc(src: []u8, spec: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return engine.each_answer_many(src, as(spec, opts), paths, state, on, read, allocator)
}

find :: proc {find_bound, find_chosen}

@(private)
find_bound :: proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: core.Answer, err: core.Error) {
	one := path
	one.limit = min(path.limit.? or_else 1, 1)
	doc, err = scan_bound_one(src, S, one, opts, read, allocator)
	answer = doc.answers[0] if len(doc.answers) > 0 else {core.NO_NODE, core.NO_NODE, 0, .Missing}
	return
}

@(private)
find_chosen :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: core.Answer, err: core.Error) {
	return engine.find(src, as(spec, opts), path, read, allocator)
}

// The answers `each_answer` gives, as an iterator that `next` takes them from: `for a in xml.next(&it)`. A loop that
// ends before `next` returns false frees the read with `destroy(&it)`. `paths` is read at the first `next`, which
// builds the whole text, as a stream of answers of XML does.
answers :: proc {answers_bound_one, answers_bound_many, answers_chosen_one, answers_chosen_many}

@(private)
answers_bound_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, bound_as(S, opts), nil, path, read, allocator)
}

@(private)
answers_bound_many :: #force_inline proc(src: []u8, $S: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, bound_as(S, opts), paths, {}, read, allocator)
}

@(private)
answers_chosen_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, as(spec, opts), nil, path, read, allocator)
}

@(private)
answers_chosen_many :: #force_inline proc(src: []u8, spec: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, as(spec, opts), paths, {}, read, allocator)
}

// An iterator over the answers of `paths`, or of `one` when `paths` is nil, in a text read with handle `handle`.
@(private)
answers_of :: proc(src: []u8, handle: core.As, paths: []core.Path, one: core.Path, read: core.Path_Options, allocator: runtime.Allocator) -> engine.Answer_Iter {
	return {src = src, as = handle, paths = paths, one = one, read = read, allocator = allocator, fill = answers_fill, max_batch = engine.ANSWER_BATCH}
}

// The fill of an iterator: the first builds the text, under `.Refuse` refusing a repeated element, fills the buffer
// with every answer and ends the read.
@(private)
answers_fill :: proc(it: ^engine.Answer_Iter) {
	paths := it.paths if it.paths != nil else ([^]core.Path)(&it.one)[:1]
	it.buffer = make([dynamic]core.Token_Answer, 0, it.max_batch, it.allocator)
	doc, built := build_spec(it.src, .Xml, it.as, it.read.dups == .Refuse, it.allocator)
	if built.kind != .None && it.read.dups == .Refuse {
		core.destroy(&doc)
		engine.answers_fail(it, core.error_of(built))
		return
	}
	_, err := engine.scan_built(&doc, built, paths, it.read, &it.buffer, proc(state: rawptr, a: core.Token_Answer) -> bool {
		_, e := append((^[dynamic]core.Token_Answer)(state), a)
		return e == nil
	}, it.allocator)
	core.destroy(&doc)
	engine.answers_fail(it, core.error_of(err))
}

// Answers `path` or `paths` over a document built whole. A document read as a constant spec holds no services, so
// `core.query` does not answer for it.
query :: proc {query_one, query_many}

@(private)
query_one :: proc(doc: ^core.Document, path: core.Path, read := core.Query_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Error) {
	return query_many(doc, []core.Path{path}, read, allocator)
}

@(private)
query_many :: proc(doc: ^core.Document, paths: []core.Path, read := core.Query_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Error) {
	if doc == nil || doc.readers == nil {
		return nil, core.error_of(core.Path_Error{kind = .Unsupported})
	}
	found, refusal := engine.query(doc, paths, read, allocator)
	return found, core.error_of(refusal)
}

// XML's `Services.scan` walk of spec `S`. A read of one path that gives no stream walks the text with the scan's hook,
// so it builds only what the path reaches, and a walk judges every byte it passes. A read of several paths, a stream of
// answers, and a path with an expanded name, which needs the declarations around an element that the scan does not
// keep, build the document and answer from it.
@(private)
scan_spec :: proc(src: []u8, $S: Spec, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (doc: core.Document, err: core.Path_Error) {
	if on != nil || len(paths) != 1 || expanded_step(paths[0]) {
		return scan_built(src, S, handle, paths, read, state, on, allocator)
	}
	opts := options_of(handle)
	// The scan's room as words, which an uninitialized declaration leaves unwritten where a struct's padding would not.
	room: [size_of(engine.Scan) / 8]u64 = ---
	h := (^engine.Scan)(rawptr(&room))
	frames: [core.MAX_DEPTH]u64 = ---
	if e := engine.scan_start(h, src, handle, paths, read, false, allocator, min(core.reserve_depth(opts.max_depth, len(src)), core.MAX_DEPTH), frames[:]); e.kind != .None {
		return {}, e
	}
	if h.many != nil {
		engine.scan_free(h, allocator)
		_, _ = engine.builder_end(&h.b, engine.BUILDER_REGS, nil)
		return scan_built(src, S, handle, paths, read, state, on, allocator)
	}
	regs := engine.BUILDER_REGS
	hi, fault, kept := walk_keeping(src, opts, h, &regs, engine.scan_hook)
	err = engine.scan_end(h, regs, hi, fault, &doc)
	if !keep_state(&doc, kept, err.kind == .None, allocator) {
		core.destroy(&doc)
		return {}, {kind = .No_Memory}
	}
	return
}

// Whether a step of `path` is an expanded name.
@(private)
expanded_step :: proc(path: core.Path) -> bool {
	for step in path.steps {
		if name, ok := step.(core.Name); ok && len(name) > 0 && name[0] == '{' {
			return true
		}
	}
	return false
}

// Builds the document and answers `paths` from it, giving each answer to `on` when it is set.
@(private)
scan_built :: proc(src: []u8, $S: Spec, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (doc: core.Document, err: core.Path_Error) {
	built: core.Document_Error
	doc, built = build_spec(src, S, handle, false, allocator)
	return engine.scan_built(&doc, built, paths, read, state, on, allocator)
}
