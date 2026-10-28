package json

// The pieces of a spine's array (`split_array`), each framed (`frame_entries`) as a text of its own and run on a
// `Batch_Runner`'s threads with the verdict and the rows one thread's read gives.
//
//	- The split reads the text at `.Structural`: it finds where entries start and end and judges nothing, so on a
//	  malformed text it may cut anywhere. A piece that fails says only that the threads cannot vouch for the text,
//	  and the caller reads it whole on one thread for the verdict and its offset.
//	- Every piece passing does vouch for the container: the pieces, framed, hold its entries between its separators,
//	  each with at least one entry, at the container's own depth.

import "base:runtime"
import core_pkg "../core"

// Whether every piece frames and passes `check(own, text)`, on `runner`'s threads. Claims stop at the first that
// does not.
pieces_pass :: proc(
	src: []byte,
	pieces: []Piece,
	check: proc(own: ^$T, text: []byte) -> Maybe(Error),
	own: ^T,
	runner: ^Batch_Runner,
) -> bool {
	Job :: struct {
		src:    []byte,
		pieces: []Piece,
		check:  proc(own: ^T, text: []byte) -> Maybe(Error),
		own:    ^T,
	}
	task :: proc(job: ^Job, k: int, scratch: ^[dynamic]byte) -> bool {
		text, _ := frame_entries(job.src, job.pieces[k], scratch) or_return
		return job.check(job.own, text) == nil
	}
	job := Job{src = src, pieces = pieces, check = check, own = own}
	return core_pkg.piece_fan(runner, len(pieces), task, &job)
}

// Each piece's rows built on `runner`'s threads by `build(own, text)`, a document over `src` whose root is the
// piece's frame and whose spans are `src`'s: the root's children are the piece's entries as one build of the
// container gives them. The documents and `docs` are the caller's, in what `build` and `allocator` allocate. False,
// with nothing kept, when a piece does not frame or build.
pieces_docs :: proc(
	src: []byte,
	pieces: []Piece,
	build: proc(own: ^$T, text: []byte) -> (Document, Maybe(Error)),
	own: ^T,
	runner: ^Batch_Runner,
	allocator: runtime.Allocator,
) -> (
	docs: []Document,
	ok: bool,
) {
	Job :: struct {
		src:    []byte,
		pieces: []Piece,
		build:  proc(own: ^T, text: []byte) -> (Document, Maybe(Error)),
		own:    ^T,
		docs:   []Document,
	}
	// Piece `k` framed and built, its spans shifted into `src` while its rows are in the building thread's cache.
	task :: proc(job: ^Job, k: int, scratch: ^[dynamic]byte) -> bool {
		text, at := frame_entries(job.src, job.pieces[k], scratch) or_return
		d := &job.docs[k]
		err: Maybe(Error)
		d^, err = job.build(job.own, text)
		if err != nil {
			return false
		}
		shift := u32(at)
		for &r in d.rows {
			r.lo += shift
			r.hi += shift
			if r.key_lo != core_pkg.NO_KEY {
				r.key_lo += shift
				r.key_hi += shift
			}
		}
		d.src = job.src
		return true
	}
	aerr: runtime.Allocator_Error
	docs, aerr = make([]Document, len(pieces), allocator)
	if aerr != nil {
		return
	}
	job := Job{src = src, pieces = pieces, build = build, own = own, docs = docs}
	if !core_pkg.piece_fan(runner, len(pieces), task, &job) {
		for &d in docs {
			core_pkg.row_document_destroy(&d)
		}
		delete(docs, allocator)
		return nil, false
	}
	return docs, true
}

// The rows of the container src[lo:hi] built from its pieces on `runner`'s threads: the rows one build of the
// container gives, in `allocator`, its spans into `src`. False, with nothing kept, when a piece does not frame or
// build, or an allocation is refused. A piece's facts are not joined: a format whose pieces carry facts does not
// split.
pieces_build :: proc(
	src: []byte,
	lo, hi: int,
	pieces: []Piece,
	build: proc(own: ^$T, text: []byte) -> (Document, Maybe(Error)),
	own: ^T,
	runner: ^Batch_Runner,
	allocator: runtime.Allocator,
) -> (
	doc: Document,
	ok: bool,
) {
	heap := runtime.heap_allocator()
	job := Join_Job{}
	job.docs = pieces_docs(src, pieces, build, own, runner, heap) or_return
	job.at = make([][3]int, len(pieces), heap)
	defer {
		for &d in job.docs {
			core_pkg.row_document_destroy(&d)
		}
		delete(job.docs, heap)
		delete(job.at, heap)
	}
	// Each piece's rows but its frame's root, its decoded bytes and its decoded keys follow those of the pieces
	// before it.
	first := &job.docs[0]
	doc = Document {
		src           = src,
		spelling      = first.spelling,
		distinct_keys = true,
		decoded       = first.decoded,
	}
	rows, values, keys, members := 1, 0, 0, 0
	for &d, k in job.docs {
		if len(d.rows) == 0 || len(d.facts) > 0 {
			return {}, false
		}
		job.at[k] = {rows, values, keys}
		rows += len(d.rows) - 1
		values += len(d.values)
		keys += len(d.key_texts)
		members += int(d.rows[0].cnt)
		doc.deep ||= d.deep
		doc.distinct_keys &&= d.distinct_keys
		doc.pruned ||= d.pruned
	}
	if make_exact(&doc.rows, rows, allocator) != nil || make_exact(&doc.values, values, allocator) != nil || make_exact(&doc.key_texts, keys, allocator) != nil {
		core_pkg.row_document_destroy(&doc)
		return {}, false
	}
	root := first.rows[0]
	root.lo, root.hi, root.subtree_size, root.cnt = u32(lo), u32(hi), u32(rows), u32(members)
	doc.rows[0] = root
	job.out = &doc
	core_pkg.piece_fan(runner, len(pieces), join_piece, &job)
	return doc, true
}

// `pieces_build`'s join: where each piece's rows, decoded bytes and decoded keys start in `out`.
@(private = "file")
Join_Job :: struct {
	docs: []Document,
	at:   [][3]int,
	out:  ^Document,
}

// Piece `k`'s rows, decoded bytes and decoded keys moved into `out`, and its own rows freed.
@(private = "file")
join_piece :: proc(job: ^Join_Job, k: int, _: ^[dynamic]byte) -> bool {
	d := &job.docs[k]
	rows_at, values_at, keys_at := job.at[k][0], u32(job.at[k][1]), job.at[k][2]
	out := job.out
	copy(out.rows[rows_at:], d.rows[1:])
	if values_at > 0 {
		for &r in out.rows[rows_at:][:len(d.rows) - 1] {
			if r.kind == .String && r.flags & {.Str_Escaped, .Decoded} == {.Str_Escaped, .Decoded} {
				r.payload.str.off += values_at
			}
		}
	}
	copy(out.values[values_at:], d.values[:])
	for kt, i in d.key_texts {
		out.key_texts[keys_at + i] = {node = kt.node + Node(rows_at - 1), str = {kt.str.off + values_at, kt.str.len}}
	}
	core_pkg.row_document_destroy(d)
	return true
}

// A dynamic array of exactly `n` elements, in `allocator`, its contents unset.
@(private = "file")
make_exact :: proc(a: ^[dynamic]$E, n: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	a^ = make([dynamic]E, 0, n, allocator) or_return
	non_zero_resize(a, n) or_return
	return nil
}
