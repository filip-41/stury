package compose

import "base:runtime"
import "core:bytes"
import "core:encoding/endian"
import "core:slice"
import core ".."

// A commit runs the format's plan, composes the junctions, splices the chunks into the source and has the format read the
// result.

// Returns the source bytes `list`'s edits make, in the spec of `as`, through the format's edit services, or by the
// format's own `commit` where it has one. A nil `as` is the document's own spec, `as` of another format is
// `.Bad_Spec`, and only its spec counts. A text of another spec must
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
	// A partial document does not hold the members a commit composes.
	if doc.partial {
		return nil, 0, core.error_of(core.Document_Error{kind = .Bad_Index}, edit = true)
	}
	if list.edit.commit == nil {
		made, cut, refusal := commit_spec(list, target, allocator)
		return made, cut, core.error_of(refusal, edit = true)
	}
	made, cut, refusal := list.edit.commit(list, target.spec, allocator)
	if refusal.kind != .None {
		return nil, 0, core.error_of(refusal, edit = true)
	}
	// A format's own commit is judged by its validate under the document's options and the target spec.
	if list.edit.validate != nil {
		judged := doc.as
		judged.spec = target.spec
		if fault, bad := list.edit.validate(made, judged).?; bad {
			delete(made, allocator)
			return nil, 0, core.error_of(core.Document_Error{kind = .Bad_Result, inner = fault}, edit = true)
		}
	}
	return made, cut, nil
}

@(private)
commit_spec :: proc(list: ^core.Edit_List, target: core.As, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
	doc, spec := list.doc, target.spec
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

// A replacement of the source bytes `lo` through `hi` by `text`, for a format that commits its edits itself. A splice
// with `lo` equal to `hi` is an insert, and splices at one byte apply in the order of `seq`.
Splice :: struct {
	lo, hi: u64,
	text:   []u8,
	seq:    int,
}

// Returns `src` with `splices` applied, in one allocation of `allocator`. Two splices that overlap are
// `.Conflicting_Edits` at the later one's first byte. The splices are sorted in place.
apply_splices :: proc(src: []u8, splices: []Splice, allocator: runtime.Allocator) -> (out: []u8, err: core.Document_Error) {
	slice.sort_by(splices, proc(a, b: Splice) -> bool {
		if a.lo != b.lo {
			return a.lo < b.lo
		}
		if a.hi != b.hi {
			return a.hi < b.hi
		}
		return a.seq < b.seq
	})
	reach := u64(0)
	size := len(src)
	for s in splices {
		if s.lo < reach {
			return nil, {kind = .Conflicting_Edits, at = s.lo}
		}
		reach = max(reach, s.hi)
		size += len(s.text) - int(s.hi - s.lo)
	}
	failed: runtime.Allocator_Error
	out, failed = make([]u8, size, allocator)
	if failed != nil {
		return nil, {kind = .No_Memory}
	}
	w, at := 0, u64(0)
	for s in splices {
		w += copy(out[w:], src[at:s.lo])
		w += copy(out[w:], s.text)
		at = s.hi
	}
	copy(out[w:], src[at:])
	return out, {}
}

// The number of bodies a fact set writes.
@(private)
fact_count :: #force_inline proc(e: core.Edit) -> int {
	return max(1, len(e.key) / 4)
}

// Body `i` of a fact set.
@(private)
fact_body :: proc(e: core.Edit, i: int) -> []u8 {
	if len(e.key) == 0 {
		return e.text
	}
	at := 0
	for k in 0 ..< i {
		at += int(endian.unchecked_get_u32le(e.key[4 * k:]))
	}
	return e.text[at:][:endian.unchecked_get_u32le(e.key[4 * i:])]
}

// The lines the fact set `e` writes: each body split at line feeds, with a carriage return trimmed from each line. A
// removal writes none.
fact_lines :: proc(e: core.Edit, allocator: runtime.Allocator) -> [dynamic][]u8 {
	lines := make([dynamic][]u8, allocator)
	for k in 0 ..< (0 if e.op == .Remove_Fact else fact_count(e)) {
		for line in bytes.split(fact_body(e, k), []u8{'\n'}, allocator) {
			append(&lines, bytes.trim_right(line, []u8{'\r'}))
		}
	}
	return lines
}

// The facts of `e.node` that carry `e.role`.
role_facts :: proc(doc: ^core.Document, e: core.Edit, allocator: runtime.Allocator) -> [dynamic]core.Fact {
	facts := make([dynamic]core.Fact, allocator)
	for f in core.all_facts(doc, e.node) {
		if f.role == e.role {
			append(&facts, f)
		}
	}
	return facts
}

// Appends the strings `parts` to `b`.
puts :: proc(b: ^[dynamic]u8, parts: ..string) {
	for s in parts {
		append(b, s)
	}
}

// Refuses as `.Bad_Index` a reorder edit's order that does not name each survivor of a container and each of its
// `inserts` inserts once, and nothing else. `removed` marks the container's members a removal names. An order with no
// entries is refused for a container that holds a member or gets an insert.
order_check :: proc(order: []u8, removed: []bool, inserts: int, allocator: runtime.Allocator) -> core.Document_Error {
	n, count := len(removed), len(order) / 4
	seen, serr := make([]bool, n + inserts, allocator)
	if serr != nil {
		return {kind = .No_Memory}
	}
	for i in 0 ..< count {
		k := int(endian.unchecked_get_u32le(order[4 * i:]))
		if k >= len(seen) || seen[k] || k < n && removed[k] {
			return {kind = .Bad_Index}
		}
		seen[k] = true
	}
	for k in 0 ..< len(seen) {
		if !seen[k] && (k >= n || !removed[k]) || count == 0 {
			return {kind = .Bad_Index}
		}
	}
	return {}
}

// Records that an edit names `id` in `seen`, and sets `err` to `.Conflicting_Edits` and returns false for a second edit
// of it.
claim :: proc(seen: ^map[u64]struct{}, err: ^core.Document_Error, id: u64) -> bool {
	if id in seen {
		err^ = {kind = .Conflicting_Edits}
		return false
	}
	seen[id] = {}
	return true
}

// The start of the line holding `p`.
line_start :: proc(src: []u8, p: u64) -> u64 {
	i := min(p, u64(len(src)))
	for i > 0 && src[i - 1] != '\n' {
		i -= 1
	}
	return i
}

// One past the line feed that ends the line holding `p`, or the end of the text.
next_line :: proc(src: []u8, p: u64) -> u64 {
	i := min(p, u64(len(src)))
	for i < u64(len(src)) && src[i] != '\n' {
		i += 1
	}
	return min(i + 1, u64(len(src)))
}

// Whether only spaces and tabs stand before `p` on its line.
first_on_line :: proc(src: []u8, p: u64) -> bool {
	for b in src[line_start(src, p):p] {
		if b != ' ' && b != '\t' {
			return false
		}
	}
	return true
}

// An insert into a bracketed collection: its text, which goes before item `at`, or after the last item for an `at` past
// them.
Flow_Insert :: struct {
	at:   int,
	text: []u8,
}

// Adds the splices that take the items `removed` marks out of a bracketed collection, whose interior runs from `open`
// to `close`, and put `inserts`, sorted by `at`, in. A run of removed items goes with the separator after it, or before
// it for the last run. New items are separated as the first gap is when it holds a comma and no comment, else by a line
// end and the indent when the first item starts a line, and by ", " otherwise. A collection left with no item and no comment
// is written whole as its inserts, inside a space each side when `pad`.
flow_splices :: proc(splices: ^[dynamic]Splice, src: []u8, items: []$T, removed: []bool, inserts: []Flow_Insert, open, close: u64, eol: string, pad: bool, allocator: runtime.Allocator) {
	n := len(items)
	left := n
	for r in removed {
		left -= int(r)
	}
	if left == 0 && bytes.index_byte(src[open:close], '#') < 0 {
		b := make([dynamic]u8, allocator)
		for e, k in inserts {
			puts(&b, ", " if k > 0 else " " if pad else "", string(e.text))
		}
		if pad && len(inserts) > 0 {
			puts(&b, " ")
		}
		append(splices, Splice{lo = open, hi = close, text = b[:], seq = len(splices)})
		return
	}
	sep := ", "
	gap: []u8
	if n >= 2 {
		gap = src[items[0].end:items[1].start]
	}
	if bytes.index_byte(gap, '#') < 0 && bytes.index_byte(gap, ',') >= 0 {
		sep = string(gap)
	} else if n > 0 && first_on_line(src, items[0].start) {
		b := make([dynamic]u8, allocator)
		puts(&b, ",", eol, string(src[line_start(src, items[0].start):items[0].start]))
		sep = string(b[:])
	}
	// Where each slot's inserts go, and whether they follow an item there or precede one.
	pos := make([]u64, n + 1, allocator)
	follows := make([]bool, n + 1, allocator)
	for it, j in items {
		pos[j] = it.start
	}
	pos[n], follows[n] = items[n - 1].end if n > 0 else open, n > 0
	empty := n == 0
	for j := 0; j < n; {
		if !removed[j] {
			j += 1
			continue
		}
		r := j
		for j < n && removed[j] {
			j += 1
		}
		s := j - 1
		lo, hi := items[r].start, items[s].end
		switch {
		case s < n - 1:
			hi = items[s + 1].start
			for k in r + 1 ..= s {
				pos[k] = hi
			}
		case r > 0:
			lo = items[r - 1].end
			for k in r ..= n {
				pos[k], follows[k] = hi, true
			}
		case:
			// With every item goes the separator the last one leaves.
			for q := hi; q < close && src[q] != '#'; q += 1 {
				if src[q] == ',' {
					hi = q + 1
					break
				}
			}
			for k in 0 ..= n {
				pos[k] = hi
			}
			empty = true
		}
		append(splices, Splice{lo = lo, hi = hi, seq = len(splices)})
	}
	for e, k in inserts {
		b := make([dynamic]u8, allocator)
		switch {
		case empty:
			puts(&b, sep if k > 0 else "", string(e.text))
		case follows[e.at]:
			puts(&b, sep, string(e.text))
		case:
			puts(&b, string(e.text), sep)
		}
		append(splices, Splice{lo = pos[e.at], hi = pos[e.at], text = b[:], seq = len(splices)})
	}
}
