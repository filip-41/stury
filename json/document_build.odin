package json

// Building a `Document` from a source and freeing it, and the debug checks of the rows a document's readers trust.

import "scan/walk"

// A debug build's check of what the readers and the writer trust of a `Document` (its fields are exported, so
// a caller can break them). `check_document` walks every row (a scoped request's rows may be several roots):
// preorder, each run `[i, i + subtree_size)` and each span inside `src` and inside its parent's. `check_node`
// checks the one row `n` and its run. Compiled out unless `ODIN_DEBUG`.
when ODIN_DEBUG {
	check_document :: proc(doc: ^Document, loc := #caller_location) {
		// Open runs, on the stack, since a test may leave no allocator but the caller's. Rows nested past
		// MAX_DEPTH (a document read under a raised `max_depth`) are not checked.
		ends: [MAX_DEPTH]int
		parents: [MAX_DEPTH]int
		open := 0
		rows := doc.rows[:]
		for r, i in rows {
			for open > 0 && ends[open - 1] <= i {
				open -= 1
			}
			ok := row_ok(doc, i)
			ok &&= i == 0 || r.lo > rows[i - 1].lo
			if open > 0 {
				p := rows[parents[open - 1]]
				ok &&= i + int(r.subtree_size) <= ends[open - 1] && r.lo >= p.lo && r.hi <= p.hi
			}
			assert(ok, "Document is corrupt: a row breaks the preorder, a run or a span", loc)
			if open == MAX_DEPTH {
				return
			}
			ends[open], parents[open] = i + int(r.subtree_size), i
			open += 1
		}
	}

	check_node :: proc(doc: ^Document, n: Node, loc := #caller_location) {
		assert(!walk.dom_has(doc.rows[:], n) || row_ok(doc, int(n)), "Document is corrupt: a row's run or span is out of range", loc)
	}

	@(private = "file")
	row_ok :: proc(doc: ^Document, i: int) -> bool {
		r := doc.rows[i]
		return r.subtree_size >= 1 && i + int(r.subtree_size) <= len(doc.rows) && r.lo <= r.hi && int(r.hi) <= len(doc.src) &&
			(r.kind == .Array || r.kind == .Object || r.subtree_size == 1)
	}
}

// Validate `src` at `.Strict` and decode every value onto a row, allocating with `allocator`. The result is
// exactly a `Request({.Dom})` scan's rows. `opts.strictness` is not read: a document is always built `.Strict`.
//
//	- Numbers are the exception: a number is checked and its digits counted here, and decoded when it is
//	  read (`get_number`).
//	- `duplicates == .Last`, the default, builds every member, as the rows hold them. `child` by key reads
//	  the last.
//	- `.Refuse` refuses a key that, decoded, repeats one of its own object's (`.Duplicate_Key` at the
//	  repeat). Keys past the first 64 open at once are remembered in `allocator`, and a refusal there is
//	  `.Out_Of_Memory`.
//
// The rows are reserved up front, one per 8 bytes of `src` (a 32-byte row each, so 4 times `src`), without
// touching the pages, and grown by 4 past that for a denser text. The reserve stops at 2^21 rows (64 MiB) from
// an arena or any allocator but the heap, and at 2^24 rows (512 MiB of address space, a 128 MiB `src`) from
// the heap, so a sparse text reserves more than it fills.
//
// `err` is a document fault or one of `build`'s own, with `Document` the zero value.
//
//	.Source_Too_Wide  `src` is longer than row offsets (u32) address. `offset` is that limit, the first
//	                  position a row could not address. Refused before any byte is read.
//	.Out_Of_Memory    the allocator refused a row or a decoded string. `offset` is 0, the scan goes on
//	                  past a refused append to reach the result, so no one byte is where it failed.
//	.Bad_Option       `duplicates` is `.First` or `.All`, which choose among a path's answers, and a
//	                  document has none, or `.Refuse` in a build with `-define:REFUSE_DUPLICATES=false`.
//	                  `offset` is 0, refused before any byte is read.
@(require_results)
build :: proc(src: []byte, opts := Read_Opts{}, allocator := context.allocator) -> (doc: Document, err: Maybe(Error)) {
	if opts.duplicates == .First || opts.duplicates == .All {
		return {}, Error{kind = .Bad_Option}
	}
	req: Request({.Dom})
	req.read = opts
	req.strictness = .Strict
	req.allocator = allocator
	err = scan(src, &req)
	if err == nil {
		doc = req.doc
		req.doc = {}
	}
	request_destroy(&req)
	return
}

// Free everything an owner holds, and empty it. Strings read from a document dangle after it.
destroy :: proc {
	document_destroy,
	request_destroy,
	type_plan_destroy,
	record_read_destroy,
}

@(private)
document_destroy :: proc(doc: ^Document) {
	delete(doc.rows)
	delete(doc.values)
	delete(doc.keys)
	delete(doc.strings)
	delete(doc.members)
	delete(doc.member_at)
	delete(doc.facts)
	walk.name_arena_destroy(&doc.arena)
	doc^ = {}
}
