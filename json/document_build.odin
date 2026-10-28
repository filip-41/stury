package json

// Building a `Document` from a source and freeing it, and the debug checks of the rows a document's readers trust.

import core_pkg "../core"

// A debug build's check of what the readers and the writer trust of a `Document` (its fields are exported, so
// a caller can break them). `check_document` walks every row (a scoped request's rows may be several roots):
// preorder, each run `[i, i + subtree_size)` and each span inside `src` and inside its parent's (`core.check_node`
// checks one row and its run). Compiled out unless `ODIN_DEBUG`.
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
			ok := core_pkg.row_ok(doc, i)
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
}

// Validate `src` at `.Strict` and decode every value onto a row, allocating with `allocator`. The result is
// exactly a `Request({.Dom})` scan's rows. `opts.strictness` is not read: a document is always built `.Strict`.
//
//	- Numbers are the exception: a number is checked and its digits counted here, and decoded when it is
//	  read (`get_number`).
//	- `duplicates` `.Last`, the default, and `.All` build every member, as the rows hold them. `child` by key
//	  reads the last.
//	- `.First` builds only the first member of a key repeated in its object: a later one leaves the rows with
//	  its value.
//	- `.Refuse` refuses a key that, decoded, repeats one of its own object's (`.Duplicate_Key` at the
//	  repeat). Keys past the first 64 open at once are remembered in `allocator`, and a refusal there is
//	  `.Out_Of_Memory`.
//
// The rows are reserved up front, one per 8 bytes of `src` (a 32-byte row each, so 4 times `src`), without
// touching the pages, and grown by 4 past that for a denser text. The reserve stops at 2^21 rows (64 MiB) from
// an arena or any allocator but the heap, and at 2^24 rows (512 MiB of address space, a 128 MiB `src`) from
// the heap, so a sparse text reserves more than it fills.
//
// On `runner`'s threads, a large root array is built in its pieces (`split_array`), with the rows, fault and offset one
// thread's build gives: a piece that fails leaves the text to that one build.
//
// `err` is a document fault or one of `build`'s own, with `Document` the zero value.
//
//	.Source_Too_Wide  `src` is longer than row offsets (u32) address. `offset` is that limit, the first
//	                  position a row could not address. Refused before any byte is read.
//	.Out_Of_Memory    the allocator refused a row or a decoded string. `offset` is 0, the scan goes on
//	                  past a refused append to reach the result, so no one byte is where it failed.
//	.Bad_Option       `duplicates` is `.Refuse` in a build with `-define:REFUSE_DUPLICATES=false`. `offset`
//	                  is 0, refused before any byte is read.
@(require_results)
build :: proc(src: []byte, opts := Read_Opts{}, allocator := context.allocator, runner: ^Batch_Runner = nil) -> (doc: Document, err: Maybe(Error)) {
	req: Request({.Dom})
	req.inputs.read = opts
	req.inputs.read.strictness = .Strict
	req.inputs.allocator = allocator
	if runner != nil && build_pieces(src, req.inputs.read, runner, allocator, &doc) {
		return
	}
	if e, refused := scan(src, &req).?; refused {
		err, _ = core_pkg.source_error(e)
	} else {
		doc = req.doc
		req.doc = {}
	}
	request_destroy(&req)
	if err == nil {
		#partial switch opts.duplicates {
		case .First:
			if err = keep_first_members(&doc); err != nil {
				destroy(&doc)
			}
		case .Refuse:
			doc.distinct_keys = true
		}
	}
	return
}

// A container whose rows `keep_first_members` is walking: the row, the row its run ends before, and the rows of
// the members dropped inside it.
@(private = "file")
Open_Run :: struct {
	row, end, dropped: u32,
}

// `doc` with every member whose key repeats an earlier one of its object removed with its subtree. A first pass
// marks those members and corrects the sizes and counts of the containers holding them, a second moves the kept
// rows over them, and the escaped keys and the facts follow their rows.
@(private = "file")
keep_first_members :: proc(doc: ^Document) -> Maybe(Error) {
	OOM :: Error{kind = .Out_Of_Memory}
	alloc := doc.rows.allocator
	rows := doc.rows[:]
	// Each row's index once the dropped ones are gone; NO_NODE marks a dropped member, then each row it held.
	at, aerr := make([]Node, len(rows), alloc)
	if aerr != nil {
		return OOM
	}
	defer delete(at, alloc)
	open := make([dynamic]Open_Run, alloc)
	defer delete(open)
	seen := make(map[string]struct{}, alloc)
	defer delete(seen)
	for i := 0; i <= len(rows); {
		for len(open) > 0 && int(open[len(open) - 1].end) <= i {
			e := pop(&open)
			rows[e.row].subtree_size -= e.dropped
			if len(open) > 0 {
				open[len(open) - 1].dropped += e.dropped
			}
		}
		if i == len(rows) {
			break
		}
		r := &rows[i]
		if at[i] == NO_NODE {
			i += int(r.subtree_size)
			continue
		}
		dropped: u32
		if r.kind == .Object && r.cnt > 1 {
			clear(&seen)
			for j := i + 1; j < i + int(r.subtree_size); j += int(rows[j].subtree_size) {
				key, _ := core_pkg.get_key(doc, Node(j))
				_, _, fresh, merr := map_entry(&seen, key)
				if merr != nil {
					return OOM
				}
				if !fresh {
					at[j] = NO_NODE
					dropped += rows[j].subtree_size
					r.cnt -= 1
				}
			}
		}
		if r.subtree_size > 1 {
			if _, perr := append(&open, Open_Run{row = u32(i), end = u32(i) + r.subtree_size, dropped = dropped}); perr != nil {
				return OOM
			}
		}
		i += 1
	}
	w := 0
	for i := 0; i < len(rows); {
		if at[i] == NO_NODE {
			end := i + int(rows[i].subtree_size)
			for ; i < end; i += 1 {
				at[i] = NO_NODE
			}
			continue
		}
		at[i] = Node(w)
		rows[w] = rows[i]
		w += 1
		i += 1
	}
	resize(&doc.rows, w)
	kept := 0
	for k in doc.key_texts {
		if n := at[k.node]; n != NO_NODE {
			doc.key_texts[kept] = {node = n, str = k.str}
			kept += 1
		}
	}
	resize(&doc.key_texts, kept)
	kept = 0
	for f in doc.facts {
		f := f
		if f.node != NO_NODE {
			if f.node = at[f.node]; f.node == NO_NODE {
				continue
			}
		}
		doc.facts[kept] = f
		kept += 1
	}
	resize(&doc.facts, kept)
	doc.distinct_keys = true
	doc.pruned = w < len(rows)
	return nil
}

// Free everything an owner holds, and empty it: a `Document`, a `Request`, a `Type_Plan`, a `Record_Read`,
// `Records` or a `Record_Reader`. Strings read from a document dangle after it.
destroy :: proc {
	core_pkg.row_document_destroy,
	request_destroy,
	core_pkg.shared_plan_destroy,
	core_pkg.record_read_destroy,
	records_destroy,
	reader_destroy,
}
