package html

import "base:runtime"
import core "../core"
import engine "../core/build"

// The path reads of `core/build`. `scan`, `each_answer` and `find` take `spec` and `opts`. They answer over the
// document a build of the text gives, since the tree is whole before its first token.
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

// The answers `each_answer` gives, as an iterator that `next` takes them from: `for a in html.next(&it)`. A loop that
// ends before `next` returns false frees the read with `destroy(&it)`. `path` is read at the first `next`, which builds
// the whole text.
answers :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return engine.answers_whole(src, bound_as(spec, opts), path, read, allocator, build_handle)
}

// HTML's `Services.scan`. The document is built whole and answers the paths.
@(private)
scan_handle :: proc(src: []u8, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (core.Document, core.Path_Error) {
	doc, built := build_spec(src, Spec(handle.spec), handle, false, allocator)
	return engine.scan_built(&doc, built, paths, read, state, on, allocator)
}
