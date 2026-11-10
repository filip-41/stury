package compose

import "base:runtime"
import "core:slice"
import core ".."

// A commit runs the format's plan, composes the junctions, splices the chunks into the source and has the format read the
// result.

// Returns the source bytes `list`'s edits make, in the spec of `as`, through the format's edit services. A nil `as` is the
// document's own spec, `as` of another format is `.Bad_Spec`, and only its spec counts. A text of another spec must
// read strictly, since the source's reading under its own spec is no evidence, and a delimited text refuses a spec
// change as `.Bad_Spec`, since it would respell every cell. The caller frees the result with `allocator`. An edit that
// another covers, a second edit of one node, and a second fact edit of one node and role are `.Conflicting_Edits` at
// the byte where the two meet. An insert whose index lies in a removal run moves to the run's cut end, so it is no
// conflict. A result that reads less strictly than the source is `.Bad_Result`. A fact the output cannot hold is dropped
// with its source bytes. `dropped` counts the source facts and fact edits the output cannot hold. A fact that is
// removed with a removed member or a set's span is not counted.
commit :: proc(list: ^core.Edit_List, as: Maybe(core.As) = nil, allocator := context.allocator) -> (out: []u8, dropped: int, err: core.Error) {
	doc := list.doc
	if doc == nil || doc.readers == nil || list.edit == nil {
		return nil, 0, core.error_of(core.Document_Error{kind = .Bad_Index, reason = .No_Document})
	}
	target := as.? or_else doc.as
	if target.readers == nil || target.readers.format != doc.readers.format {
		return nil, 0, core.error_of(core.Document_Error{kind = .Bad_Spec})
	}
	made, cut, refusal := commit_spec(list, target, allocator)
	return made, cut, core.error_of(refusal, edit = true)
}

@(private)
commit_spec :: proc(list: ^core.Edit_List, target: core.As, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
	doc, spec := list.doc, target.spec
	if doc == nil || doc.readers == nil {
		return nil, 0, {kind = .Bad_Index}
	}
	// A partial document does not hold the members a commit composes.
	if doc.partial {
		return nil, 0, {kind = .Bad_Index}
	}
	// Refused before any chunk is built or spliced, rather than after the output fails to read.
	if core.is_flat(doc) && spec != doc.as.spec {
		return nil, 0, {kind = .Bad_Spec}
	}
	// All a commit writes but its output lives only as long as the commit, so one arena frees it.
	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 64 * 1024}
	defer runtime.arena_destroy(&arena)
	scratch := runtime.arena_allocator(&arena)
	planned := core.Edit_List{doc = doc, allocator = scratch, edits = list.edits, edit = list.edit}
	if list.edit != nil && list.edit.plan != nil {
		written, _ := make([dynamic]core.Edit, scratch)
		changed, e := list.edit.plan(doc, list, &written, scratch)
		if e.kind != .None {
			return nil, 0, e
		}
		if changed {
			planned.edits = written
		}
	}
	cx := Compose{doc = doc, edit = list.edit, list = &planned, allocator = scratch, err = {kind = .No_Memory}}
	if edit := list.edit; edit != nil && edit.comment != nil {
		cx.style, cx.comment_byte = edit.comment(doc, spec)
	}
	if !compose_tree(&cx) {
		return nil, 0, cx.err
	}
	if !order_chunks(&cx) {
		return nil, 0, cx.err
	}
	seps: []u64
	if edit := list.edit; edit != nil && edit.separators != nil && edit.separators(doc, spec) {
		seps = line_separators(doc, scratch)
	}
	out, err = splice(doc, cx.chunks[:], cx.text[:], cx.segments[:], seps, allocator)
	if err.kind != .None {
		return nil, 0, err
	}
	// A byte order mark at the output's start is the text's, not the edit's, so one only an edit put there is refused.
	if core.text_start(out, 0) != 0 && core.text_start(doc.src, 0) == 0 {
		delete(out, allocator)
		return nil, 0, {kind = .Bad_Result}
	}
	if e := reads_as_source(list.edit, doc, out, target); e.kind != .None {
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
reads_as_source :: proc(edit: ^core.Edit_Services, doc: ^core.Document, out: []u8, target: core.As) -> core.Document_Error {
	spec := target.spec
	strict := doc.as
	strict.tolerate = {}
	// The list's own validate reads its own spec. Another spec of the format is judged by the target's handle, which
	// holds that spec's walk.
	validate := edit.validate
	if spec != doc.as.spec {
		services := core.services_of(target)
		if services == nil || services.validate == nil {
			return {kind = .Bad_Spec}
		}
		strict.readers, strict.spec = target.readers, spec
		validate = services.validate
	}
	f, faulted := validate(out, strict).?
	if !faulted {
		return {}
	}
	tolerant := strict
	tolerant.tolerate = ~bit_set[core.Tolerance; u8]{}
	if g, still := validate(out, tolerant).?; still {
		return {kind = .Bad_Result, inner = g}
	}
	if spec != doc.as.spec {
		return {kind = .Bad_Result, inner = f}
	}
	if _, src_bad := validate(doc.src, strict).?; !src_bad {
		return {kind = .Bad_Result, inner = f}
	}
	return {}
}

// Builds the output in one allocation: the source bytes between chunks, and each chunk's text in its place.
// Returns `.No_Memory` when the allocation is refused.
@(private)
splice :: proc(doc: ^core.Document, chunks: []Chunk, text: []u8, segments: []Segment, seps: []u64, allocator: runtime.Allocator) -> (out: []u8, err: core.Document_Error) {
	if len(segments) > 0 || len(seps) > 0 {
		grown := make([dynamic]u8, 0, len(doc.src) + len(text) + 3 * len(seps), allocator)
		if splice_range(&grown, doc, chunks, text, segments, seps, 0, u64(len(doc.src))) {
			return grown[:], {}
		}
		delete(grown)
		return nil, {kind = .No_Memory}
	}
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

// Appends the source bytes `lo` through `hi` with `chunks`, the sorted chunks that lie inside them, applied. A
// reordered container's chunk writes its segments, each source segment with the chunks inside it.
@(private)
splice_range :: proc(out: ^[dynamic]u8, doc: ^core.Document, chunks: []Chunk, text: []u8, segments: []Segment, seps: []u64, lo, hi: u64) -> bool {
	at := lo
	for i := 0; i < len(chunks); {
		c := chunks[i]
		j := i + 1
		if c.ordered {
			for j < len(chunks) && chunks[j].lo < c.hi {
				j += 1
			}
		}
		if c.lo > at {
			push_src(out, doc, seps, at, c.lo) or_return
		}
		if !c.ordered {
			push_all(out, text[c.from:c.to]) or_return
		}
		inner := chunks[i + 1:j]
		segs := segments[c.from:c.to] if c.ordered else nil
		for s in segs {
			if s.written {
				push_all(out, text[s.lo:s.hi]) or_return
				continue
			}
			a := 0
			for a < len(inner) && inner[a].lo < s.lo {
				a += 1
			}
			b := a
			for b < len(inner) && inner[b].hi <= s.hi && (inner[b].lo < s.hi || inner[b].lo == s.lo) {
				b += 1
			}
			splice_range(out, doc, inner[a:b], text, segments, seps, s.lo, s.hi) or_return
		}
		at = max(at, c.hi)
		i = j
	}
	if hi > at {
		push_src(out, doc, seps, at, hi) or_return
	}
	return true
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

// The offsets of the U+2028 and U+2029 inside the source's line comments, sorted. JSON5 ends a line comment at one, so a
// commit to JSON5 respells each as text.
@(private)
line_separators :: proc(doc: ^core.Document, allocator: runtime.Allocator) -> []u64 {
	found := make([dynamic]u64, allocator)
	for f in doc.facts {
		if f.role > .Comment_Foot || core.comment_tail(f.spelling) != 0 {
			continue
		}
		end := f.lo + u64(f.n)
		for i := f.lo; i + 2 < end; i += 1 {
			if doc.src[i] == 0xE2 && doc.src[i+1] == 0x80 && doc.src[i+2] | 1 == 0xA9 {
				append(&found, i)
			}
		}
	}
	slice.sort(found[:])
	return found[:]
}

// Appends the source bytes `lo` through `hi`, a line separator in `seps` written as `\u2028` or `\u2029`.
@(private)
push_src :: proc(out: ^[dynamic]u8, doc: ^core.Document, seps: []u64, lo, hi: u64) -> bool {
	at := lo
	for s in seps {
		if s < lo || s >= hi {
			continue
		}
		push_all(out, doc.src[at:s]) or_return
		push_all(out, transmute([]u8)string("\\u2028" if doc.src[s+2] == 0xA8 else "\\u2029")) or_return
		at = s + 3
	}
	_, ok := push_all(out, doc.src[at:hi])
	return ok
}
