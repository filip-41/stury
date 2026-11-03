package compose

import "base:runtime"
import "core:bytes"
import core ".."

// A commit: what a format's `Edit_Spelling.commit` calls. It runs the format's plan, composes the junctions, splices the
// chunks into the source and has the format read the result.

// The two services that take the composing state, nil for a format whose text has brackets. A text with these is flat,
// so its `Edit_Spelling.flat` is set.
Root_Spelling :: struct {
	root_head:     proc(cx: ^Compose, open: u64) -> bool,
	root_junction: proc(cx: ^Compose, open, close: u64, l, r: int, inserts: []core.Edit) -> bool,
}

// Returns the source bytes the edits make: every byte no edit touched, the edits' texts in their places, and the
// separators the format supplies, in the document's own spec. The caller frees the result with `allocator`. An edit
// that another covers, a second edit of one node, and a second fact edit of one node and role are
// `.Conflicting_Edits` at the byte where the two meet. An insert whose index lies in a removal run moves to the run's
// cut end, so it is no conflict. The result is checked by the format, and a result that reads less strictly than the
// source is `.Bad_Result`. A fact the output cannot hold is dropped with its source bytes. `dropped` counts the source
// facts and fact edits the output cannot hold. A fact that is removed with a removed member or a set's span is not
// counted.
commit :: proc(list: ^core.Edit_List, spec: u8, root: ^Root_Spelling, allocator := context.allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
	doc := list.doc
	if doc == nil || doc.spelling == nil {
		return nil, 0, {kind = .Bad_Index}
	}
	// A partial document does not hold the members a commit composes.
	if doc.partial {
		return nil, 0, {kind = .Bad_Index}
	}
	// Refused before any chunk is built or spliced, rather than after the output fails to read.
	if core.is_flat(doc) && spec != doc.read.spec {
		return nil, 0, {kind = .Bad_Spec}
	}
	// All a commit writes but its output lives only as long as the commit, so one arena frees it.
	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 64 * 1024}
	defer runtime.arena_destroy(&arena)
	scratch := runtime.arena_allocator(&arena)
	planned := core.Edit_List{doc = doc, allocator = scratch, edits = list.edits}
	if doc.spelling.edit != nil && doc.spelling.edit.plan != nil {
		written, _ := make([dynamic]core.Edit, scratch)
		changed, e := doc.spelling.edit.plan(doc, list, &written, scratch)
		if e.kind != .None {
			return nil, 0, e
		}
		if changed {
			planned.edits = written
		}
	}
	cx := Compose{doc = doc, list = &planned, root = root, allocator = scratch, err = {kind = .No_Memory}}
	cx.style, cx.comment_byte = comment_style(doc, spec)
	if !compose_tree(&cx) {
		return nil, 0, cx.err
	}
	if !order_chunks(&cx) {
		return nil, 0, cx.err
	}
	out, err = splice(doc, cx.chunks[:], cx.text[:], allocator)
	if err.kind != .None {
		return nil, 0, err
	}
	if e := reads_as_source(doc, out, spec); e.kind != .None {
		delete(out, allocator)
		return nil, 0, e
	}
	return out, cx.dropped, {}
}

// The output must read as strictly as the source. A text that needs a tolerance only the source needed is the edit's
// own defect. A tolerance is accepted only when the output keeps the document's spec, since under another spec the
// source's own reading is no evidence and the output must read strictly. A text that fails even the format's tolerant
// read returns `.Bad_Result`.
@(private)
reads_as_source :: proc(doc: ^core.Document, out: []u8, spec: u8) -> core.Document_Error {
	edit := doc.spelling.edit
	if edit == nil || edit.reads == nil {
		return {}
	}
	f, faulted := edit.reads(doc, out, false, spec)
	if !faulted {
		return {}
	}
	if g, still := edit.reads(doc, out, true, spec); still {
		return {kind = .Bad_Result, inner = g}
	}
	if spec != doc.read.spec {
		return {kind = .Bad_Result, inner = f}
	}
	if _, src_bad := edit.reads(doc, doc.src, false, spec); !src_bad {
		return {kind = .Bad_Result, inner = f}
	}
	return {}
}

// Builds the output in one allocation: the source bytes between chunks, and each chunk's text in its place.
// Returns `.No_Memory` when the allocation is refused.
@(private)
splice :: proc(doc: ^core.Document, chunks: []Chunk, text: []u8, allocator: runtime.Allocator) -> (out: []u8, err: core.Document_Error) {
	total := i64(len(doc.src))
	for c in chunks {
		total += i64(c.to-c.from) - i64(c.hi-c.lo)
	}
	raw, aerr := runtime.mem_alloc_non_zeroed(int(total), 1, allocator)
	if aerr != nil {
		return nil, {kind = .No_Memory}
	}
	out = raw[:int(total)]
	w := 0
	at := u64(0)
	for c in chunks {
		if c.lo > at {
			w += copy(out[w:], doc.src[at:c.lo])
		}
		w += copy(out[w:], text[c.from:c.to])
		at = max(at, c.hi)
	}
	copy(out[w:], doc.src[at:])
	return out, {}
}

// Replaces `src[lo:hi]` with `text[from:to]`. `rank` orders chunks at one byte. `cut` says the chunk takes a fact out and
// writes nothing, and `drop` that the output cannot hold that fact, so it counts unless a set replaces its bytes.
@(private)
Chunk :: struct {
	lo, hi: u64,
	from:   int,
	to:     int,
	rank:   Rank,
	cut:    bool,
	drop:   bool,
}

// Returns the first byte of member `v` of `parent`, without the comments it holds: its key's first byte or its own.
// Only an inline-key `Map`'s member has a key node before it. A shared-key root's first member follows the shared keys,
// whose last also has role `Key` and names no member of the root.
@(private)
value_lo :: proc(doc: ^core.Document, parent, v: core.Node_Index) -> u64 {
	if doc.shared_keys == 0 && doc.nodes[parent].kind == .Map && doc.nodes[v-1].role == .Key {
		return core.node_start(doc.nodes[v-1])
	}
	return core.node_start(doc.nodes[v])
}

// Returns the bytes where container `c`'s members go: those between its brackets, or a format's `interior`.
@(private)
interior :: proc(doc: ^core.Document, c: core.Node_Index) -> (lo, hi: u64) {
	if edit := doc.spelling.edit; edit != nil && edit.interior != nil {
		return edit.interior(doc, c)
	}
	hi = doc.spelling.close_end(doc, c)
	return doc.nodes[c].lo + 1, hi - 1
}

// Returns `lo` moved past each space or tab before `hi`.
@(private)
blanks_end :: #force_inline proc(src: []u8, lo, hi: u64) -> u64 {
	p := lo
	for p < hi && (src[p] == ' ' || src[p] == '\t') {
		p += 1
	}
	return p
}

// Whether `body` holds a line end a JSON line comment ends at: LF, CR, or a Unicode line separator. `line_end_len`
// reads the same set.
@(private)
body_line_end :: #force_inline proc(body: []u8) -> bool {
	return core.has_line_end(body) || bytes.index(body, transmute([]u8)string("\xE2\x80\xA8")) >= 0 || bytes.index(body, transmute([]u8)string("\xE2\x80\xA9")) >= 0
}

// Returns the indent of the line holding `pos` and whether bytes stand before `pos` on that line. A U+2028 or U+2029
// separator is a line end only in a tree, as JSON5 reads one.
@(private)
line_shape :: proc(doc: ^core.Document, pos: u64) -> (indent: []u8, lead: bool) {
	src := doc.src
	unicode := !core.is_flat(doc)
	lo := pos
	for lo > 0 && src[lo-1] != '\n' && src[lo-1] != '\r' {
		if unicode && lo >= 3 && src[lo-3] == 0xE2 && src[lo-2] == 0x80 && src[lo-1] | 1 == 0xA9 {
			break
		}
		lo -= 1
	}
	hi := blanks_end(src, lo, pos)
	return src[lo:hi], hi < pos
}

push :: proc(d: ^[dynamic]$T, v: T) -> (int, bool) {
	count, err := append(d, v)
	return count, err == nil
}

push_all :: proc(d: ^[dynamic]$T, vs: []T) -> (count: int, ok: bool) {
	if _, err := append(d, ..vs); err != nil {
		return 0, false
	}
	return len(vs), true
}

// Returns how `spec`'s output spells a comment and its marker byte, from the format's `edit.comment`. Returns
// `.None` and 0 for a format with no comment service.
@(private)
comment_style :: #force_inline proc(doc: ^core.Document, spec: u8) -> (style: core.Comment_Spelling, b: u8) {
	if edit := doc.spelling.edit; edit != nil && edit.comment != nil {
		return edit.comment(doc, spec)
	}
	return .None, 0
}

// Whether the output can hold a fact of `role` on `node`. A tree writes a foot on a container or the root, whose close
// or text's end it precedes, and on no other node. A format with a `fact_slot` says its own. An output with no marker
// holds no fact. The role's shape and the body's spelling are checked where the fact is written. `emptied` says the
// list removes every member of the root.
@(private)
fact_slot :: #force_inline proc(doc: ^core.Document, node: core.Node_Index, role: core.Role, style: core.Comment_Spelling, emptied: bool) -> bool {
	if style == .None {
		return false
	}
	if edit := doc.spelling.edit; edit != nil && edit.fact_slot != nil {
		return edit.fact_slot(doc, node, role, emptied)
	}
	n := doc.nodes[node]
	return role != .Comment_Foot || node == core.ROOT || n.kind == .Array || n.kind == .Map
}
