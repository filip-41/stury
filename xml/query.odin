package xml

import "base:runtime"
import core "../core"
import engine "../core/build"

// The path reads of `core/build`. `scan`, `each_answer` and `find` take `spec` and `opts`. A name step in `{uri}local`
// form matches an element by its namespace and local name.
scan :: proc {scan_one, scan_many}

@(private)
scan_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return scan_many(src, spec, []core.Path{path}, opts, read, allocator)
}

@(private)
scan_many :: proc(src: []u8, spec: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return engine.scan_with(src, bound_as(spec, opts), paths, read, allocator, build_handle, scan_handle)
}

each_answer :: proc {each_answer_one, each_answer_many}

@(private)
each_answer_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return each_answer_many(src, spec, []core.Path{path}, state, on, opts, read, allocator)
}

@(private)
each_answer_many :: proc(src: []u8, spec: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return engine.each_answer_with(src, bound_as(spec, opts), paths, state, on, read, allocator, build_handle, scan_handle)
}

find :: proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: core.Answer, err: core.Error) {
	doc, err = scan_one(src, spec, engine.first_path(path), opts, read, allocator)
	return doc, engine.first_answer(&doc), err
}

// The answers `each_answer` gives, as an iterator that `next` takes them from: `for a in xml.next(&it)`. A loop that
// ends before `next` returns false frees the read with `destroy(&it)`. `path` is read at the first `next`, which
// builds the whole text, as a stream of answers of XML does.
answers :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return engine.answers_whole(src, bound_as(spec, opts), path, read, allocator, build_handle)
}

// XML's `Services.scan`. A read of one path that gives no stream walks the text with the scan's hook,
// so it builds only what the path reaches, and a walk judges every byte it passes. A read of several paths, a stream of
// answers, and a path with an expanded name, which needs the declarations around an element that the scan does not
// keep, build the document and answer from it.
@(private)
scan_handle :: proc(src: []u8, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (doc: core.Document, err: core.Path_Error) {
	if on != nil || len(paths) != 1 || expanded_step(paths[0]) {
		return scan_built(src, .Xml, handle, paths, read, state, on, allocator)
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
		return scan_built(src, .Xml, handle, paths, read, state, on, allocator)
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
scan_built :: proc(src: []u8, spec: Spec, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (doc: core.Document, err: core.Path_Error) {
	built: core.Document_Error
	doc, built = build_spec(src, spec, handle, false, allocator)
	return engine.scan_built(&doc, built, paths, read, state, on, allocator)
}
