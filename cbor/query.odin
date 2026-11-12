package cbor

import core "../core"
import engine "../core/build"

// The path reads of `core/build`, bound to CBOR's walk: `scan`, `each_answer` and `find` take `spec` and `opts`, and read
// as the same names in `core/build` do with `as(spec, opts)`. A step by name matches an integer key by its decimal
// digits.
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
	doc, err := scan_item(src, bound_as(S, opts), paths, read, nil, nil, allocator)
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
	doc, err := scan_item(src, bound_as(S, opts), paths, read, state, on, allocator)
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

// The answers `each_answer` gives, as an iterator that `next` takes them from: `for a in cbor.next(&it)`. A loop that
// ends before `next` returns false frees the read with `destroy(&it)`. `paths` is read at the first `next`, and each
// `next` that finds the buffer empty resumes the walk until it holds a batch.
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

// Answers `path` or `paths` over a document built whole, as `core.query` does. A document read as a constant spec holds
// no services, so `core.query` does not answer for it.
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
