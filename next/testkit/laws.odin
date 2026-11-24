// The laws every format's reads keep, over its `tape.Reads` and format handle: a text in pieces reads as the whole
// text, a build on many threads gives the document of one, and a scan's partial document answers as the build does.
package testkit

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// An answer of a path read: the value found, or the outcome, with the node the readers stopped at.
Ref_Answer :: struct {
	node:    tape.Node_Index,
	outcome: tape.Presence,
}

// The answers of `steps` over the whole document `doc` under `dups`, in document order, by its readers and the step
// rules: null and a child a container lacks read as missing past the last `All` and as the wrong kind before it, an
// `All` takes an object's members as written, and a `Name` under `.Group` each member of its key. A `Descend` takes the
// value and each value under it, its object members as written, past it a `Name` takes each member of its key, a value
// the steps cannot follow gives no answer, and each value answers once.
reference_answers :: proc(doc: ^tape.Document, steps: []tape.Step, dups: tape.Duplicates, out: ^[dynamic]Ref_Answer) {
	alls_end := u64(0)
	deep := false
	for step, i in steps {
		#partial switch _ in step {
		case tape.All:
			alls_end = u64(i + 1)
		case tape.Descend:
			deep = true
		}
	}
	from := len(out)
	reference_from(doc, tape.ROOT, steps, 0, alls_end, dups, false, out)
	if deep {
		// Answers by place in the document, the misses past a container's nodes, once each.
		place :: proc(doc: ^tape.Document, a: Ref_Answer) -> u64 {
			if a.outcome != .Missing || doc.nodes[a.node].kind <= .Plain {
				return 2 * u64(a.node)
			}
			return 2 * u64(a.node + tape.Node_Index(doc.nodes[a.node].n)) - 1
		}
		got := out[from:]
		context.user_ptr = doc
		slice.stable_sort_by(got, proc(a, b: Ref_Answer) -> bool {
			doc := (^tape.Document)(context.user_ptr)
			return place(doc, a) < place(doc, b)
		})
		n := 0
		for a in got {
			if n == 0 || got[n - 1] != a {
				got[n] = a
				n += 1
			}
		}
		resize(out, from + n)
	}
}

@(private)
reference_from :: proc(doc: ^tape.Document, at: tape.Node_Index, steps: []tape.Step, taken, alls_end: u64, dups: tape.Duplicates, deep: bool, out: ^[dynamic]Ref_Answer) {
	if taken == u64(len(steps)) {
		append(out, Ref_Answer{at, .Found})
		return
	}
	r := tape.Reader{doc, nil}
	node := doc.nodes[at]
	step := steps[taken]
	if _, descends := step.(tape.Descend); descends {
		reference_from(doc, at, steps, taken + 1, alls_end, dups, true, out)
		if node.kind == .Array || node.kind == .Object {
			c, _, _ := tape.children(r, at, context.temp_allocator)
			for {
				_, value, p := tape.next_child(r, &c, .Group)
				if p != .Found {
					break
				}
				reference_from(doc, value, steps, taken, alls_end, dups, true, out)
			}
		}
		return
	}
	if !tape.step_enters(step, node.kind) {
		if !deep {
			append(out, Ref_Answer{at, tape.path_refused(taken, alls_end) if node.kind == .Null else .Wrong_Kind})
		}
		return
	}
	missing := Ref_Answer{at, tape.path_refused(taken + 1, alls_end)}
	switch s in step {
	case tape.Descend:
	case tape.Name:
		if dups == .Group || deep {
			c, p := tape.named(r, at, string(s))
			if p != .Found {
				if !deep {
					append(out, missing)
				}
				return
			}
			for {
				_, value, vp := tape.next_child(r, &c)
				if vp != .Found {
					return
				}
				reference_from(doc, value, steps, taken + 1, alls_end, dups, deep, out)
			}
		}
		value, p := tape.member(r, at, string(s), dups)
		if p != .Found {
			if !deep {
				append(out, missing)
			}
			return
		}
		reference_from(doc, value, steps, taken + 1, alls_end, dups, deep, out)
	case tape.Index:
		value, p := tape.element(r, at, int(s))
		if p != .Found {
			if !deep {
				append(out, missing)
			}
			return
		}
		reference_from(doc, value, steps, taken + 1, alls_end, dups, deep, out)
	case tape.All:
		c, _, _ := tape.children(r, at, context.temp_allocator)
		for i := u64(0); ; i += 1 {
			_, value, p := tape.next_child(r, &c, .Group)
			if p != .Found || !tape.all_takes(s.limit, i, node.kind == .Object, dups) {
				return
			}
			reference_from(doc, value, steps, taken + 1, alls_end, dups, deep, out)
		}
	case tape.Slice:
		count, _, _ := tape.length(r, at, context.temp_allocator)
		for e in 0 ..< u64(count) {
			if tape.slice_takes(s, e, u64(count)) {
				value, _ := tape.element(r, at, int(e))
				reference_from(doc, value, steps, taken + 1, alls_end, dups, deep, out)
			}
		}
	}
}

// Whether node `f` of `whole` and node `p` of `part` are the same value of the text.
same_value :: proc(whole: ^tape.Document, f: tape.Node_Index, part: ^tape.Document, p: tape.Node_Index) -> bool {
	if f == tape.NO_NODE || p == tape.NO_NODE {
		return f == p
	}
	x, y := whole.nodes[f], part.nodes[p]
	return x.lo == y.lo && x.kind == y.kind && x.role == y.role && (x.kind > .Plain || x.n == y.n)
}

// Whether the answers of path `path` of the scan `r` are the reference's over the build `doc`, its first `limit` for a
// limit past 0, their outcomes and found values in document order.
answers_agree :: proc(doc, r: ^tape.Document, path: int, steps: []tape.Step, dups: tape.Duplicates, limit: int) -> bool {
	want := make([dynamic]Ref_Answer, context.temp_allocator)
	reference_answers(doc, steps, dups, &want)
	if limit > 0 && len(want) > limit {
		resize(&want, limit)
	}
	for w, k in want {
		node, p, ok := tape.answer({doc = r}, path, k)
		if !ok || p != w.outcome || p == .Found && !same_value(doc, w.node, r, node) {
			return false
		}
	}
	_, _, more := tape.answer({doc = r}, path, len(want))
	return !more
}

// Whether two errors of reads of one text are the same: the same fault at the same byte, or the same other error.
same_refusal :: proc(a, b: tape.Error) -> bool {
	x, x_fault := a.(tape.Fault)
	y, y_fault := b.(tape.Fault)
	if x_fault || y_fault {
		return x_fault && y_fault && x.at == y.at && x.kind == y.kind && x.detail == y.detail
	}
	return a == b
}

// Whether every read of `src` that checks the whole text refuses it with the fault `want`, which a build gave.
// Returns false after reporting the first that does not.
reads_refuse :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, want: tape.Error, name: string, loc := #caller_location) -> bool {
	same := true
	check :: proc(t: ^testing.T, same: ^bool, what: string, got, want: tape.Error, src: []u8, name: string, loc: runtime.Source_Code_Location) {
		same^ &&= testing.expectf(t, same_refusal(got, want), "%s %q: %s refuses with %v, build with %v", name, src, what, got, want, loc = loc)
	}
	check(t, &same, "validate", reads.validate(f, src, opts, context.allocator), want, src, name, loc)
	for dups in ([]tape.Duplicates{.Last, .First}) {
		find_opts := opts
		find_opts.dups = dups
		_, ferr := reads.find(f, src, {tape.Name("a"), tape.Index(-1)}, {}, find_opts, context.allocator)
		check(t, &same, "find", ferr, want, src, name, loc)
	}
	_, ferr := reads.find(f, src, {}, {}, opts, context.allocator)
	check(t, &same, "find of the root", ferr, want, src, name, loc)
	d, _ := tape.demand_of({{tape.All{}}, {tape.Name("a")}})
	defer tape.destroy(&d)
	r, serr := reads.scan(f, src, &d, {}, opts, context.allocator)
	tape.destroy(&r)
	check(t, &same, "scan", serr, want, src, name, loc)
	return same
}

// Checks the facts a scan kept with its nodes against the build's: each kept fact is the build's fact of the same
// value, and each fact the build gives a value the scan kept is kept, but a foot of a container the scan kept unread,
// whose insides it passed. A stopped scan read no fact past its stop.
agree_facts :: proc(t: ^testing.T, doc, r: ^tape.Document, name: string, loc := #caller_location) {
	// A container may start where its first child does, as a delimited record starts at its first cell.
	Key :: struct {
		lo:   u64,
		role: tape.Role,
		kind: tape.Kind,
	}
	// The root is known by its place, as a markup document's root starts where its root element's value does. A key of
	// more than one node, as each reference to a markup entity reads its text anew, names `NO_NODE`.
	whole := make(map[Key]tape.Node_Index, context.temp_allocator)
	for node, i in doc.nodes[1:] {
		k := Key{node.lo, node.role, node.kind}
		whole[k] = tape.NO_NODE if k in whole else tape.Node_Index(i + 1)
	}
	// Whether a node of the build known by `key` holds fact `f`.
	some_has :: proc(doc: ^tape.Document, key: Key, f: tape.Fact) -> bool {
		for g in doc.facts {
			node := doc.nodes[g.node]
			if g.node != tape.ROOT && g.lo == f.lo && g.kind == f.kind && (Key{node.lo, node.role, node.kind}) == key {
				return true
			}
		}
		return false
	}
	whole_of :: proc(whole: map[Key]tape.Node_Index, r: ^tape.Document, i: tape.Node_Index) -> (tape.Node_Index, bool) {
		if i == tape.ROOT {
			return tape.ROOT, true
		}
		node := r.nodes[i]
		return whole[{node.lo, node.role, node.kind}]
	}
	has :: proc(facts: []tape.Fact, node: tape.Node_Index, f: tape.Fact) -> bool {
		for g in facts {
			if g.node == node && g.lo == f.lo && g.kind == f.kind {
				return true
			}
		}
		return false
	}
	for f in r.facts {
		node := r.nodes[f.node]
		at, ok := whole_of(whole, r, f.node)
		held := has(doc.facts, at, f) if at != tape.NO_NODE else some_has(doc, {node.lo, node.role, node.kind}, f)
		testing.expectf(t, ok && held, "%s: scan fact %v on %v is not the build's", name, f, node, loc = loc)
	}
	if .Stopped in r.flags {
		return
	}
	kept := make(map[tape.Node_Index]tape.Node_Index, context.temp_allocator)
	for i in 0 ..< len(r.nodes) {
		if at, ok := whole_of(whole, r, tape.Node_Index(i)); ok && at != tape.NO_NODE {
			kept[at] = tape.Node_Index(i)
		}
	}
	for f in doc.facts {
		at, ok := kept[f.node]
		if !ok {
			continue
		}
		node := r.nodes[at]
		unread := node.kind >= .Array && node.n == 1 && node.spelling & tape.CONTAINER_PARTIAL != 0
		if f.kind == .Comment_Foot && unread {
			continue
		}
		testing.expectf(t, has(r.facts, at, f), "%s: build fact %v of kept %v is not the scan's", name, f, node, loc = loc)
	}
}

// Writes node `i` of `doc` and its kept subtree, a partial container marked `~`, and returns the node after it.
render_node :: proc(b: ^strings.Builder, doc: ^tape.Document, i: int) -> int {
	n := doc.nodes[i]
	if n.kind <= .Plain {
		text := string(tape.span_bytes(doc, n.lo, n.n))
		if n.kind == .String && n.spelling & tape.SPELLING_QUOTED != 0 {
			fmt.sbprintf(b, `"%s"`, text)
		} else {
			strings.write_string(b, text)
		}
		return i + 1
	}
	if n.spelling & tape.CONTAINER_PARTIAL != 0 {
		strings.write_byte(b, '~')
	}
	strings.write_byte(b, '[' if n.kind == .Array else '{')
	j := i + 1
	for first := true; j < i + int(n.n); first = false {
		if !first {
			strings.write_byte(b, ',')
		}
		if doc.nodes[j].role == .Key {
			j = render_node(b, doc, j)
			strings.write_byte(b, ':')
		}
		j = render_node(b, doc, j)
	}
	strings.write_byte(b, ']' if n.kind == .Array else '}')
	return j
}

render_answers :: proc(doc: ^tape.Document) -> string {
	b := strings.builder_make(context.temp_allocator)
	for path := 0; doc.partial != nil && path + 1 < len(doc.partial.starts); path += 1 {
		for k := 0; ; k += 1 {
			node, p, ok := tape.answer({doc = doc}, path, k)
			if !ok {
				break
			}
			if len(b.buf) > 0 {
				strings.write_byte(&b, ' ')
			}
			fmt.sbprintf(&b, "%d=", path)
			if p == .Found {
				render_node(&b, doc, int(node))
			} else {
				fmt.sbprintf(&b, "%v", p)
			}
		}
	}
	return strings.to_string(b)
}

render_doc :: proc(doc: ^tape.Document) -> string {
	b := strings.builder_make(context.temp_allocator)
	if len(doc.nodes) > 0 {
		render_node(&b, doc, 0)
	}
	return strings.to_string(b)
}

Piece_Run :: struct {
	src:   []u8,
	reads: ^tape.Reads,
	f:     ^tape.Format,
	opts:  tape.Options,
	cuts:  []int, // where each window but the last ends
}

// Feeds `r.src` to `read` one window at a time, each from the last read's `keep` to the next cut, the last to the
// text's end, and gives the result of the read that ended. Each window is a copy of its bytes, overwritten with a byte
// no text holds once its read returns and another follows, so a read that keeps a pointer into a window it was given
// reads no byte of the text. The copy of the last, which a document may hold, is the caller's to free.
feed :: proc(r: Piece_Run, p: ^tape.Pieces, read: proc(window: []u8, r: Piece_Run, opts: tape.Options) -> bool) -> (text: []u8) {
	opts := r.opts
	opts.pieces = p
	p.allocator = context.allocator
	dropped: u64
	for i := 0; ; i += 1 {
		end := r.cuts[i] if i < len(r.cuts) else len(r.src)
		p.from, p.last = p.keep, i >= len(r.cuts)
		assert(p.keep >= dropped, "a read needs bytes its last read let go")
		dropped = p.keep
		// The window before is freed once this one is made, so the two hold no byte in common.
		window := slice.clone(r.src[p.keep:end])
		delete(text)
		text = window
		if !read(text, r, opts) || !p.more || p.last {
			return
		}
		slice.fill(text, 0xFF)
	}
}

// Whether two reads of one text gave the same document: its lists, flags, spans and partial lists, a document that holds
// the bytes it keeps reading as one that borrows the text.
same_documents :: proc(a, b: tape.Document) -> bool {
	a, b := a, b
	same :: proc(x, y: []$T) -> bool {
		return mem.compare(slice.to_bytes(x), slice.to_bytes(y)) == 0
	}
	// A read of a text in pieces may hold the bytes it keeps, whose text a whole read borrows.
	held := tape.Doc_Flags{.Held, .Owns_Src}
	if !same(a.nodes, b.nodes) || !same(a.facts, b.facts) || !same(a.counts, b.counts) || a.flags - held != b.flags - held {
		return false
	}
	if a.root_close != b.root_close || a.present != b.present {
		return false
	}
	for n in a.nodes {
		if n.kind <= .Plain && n.n > 0 && string(tape.span_bytes(&a, n.lo, n.n)) != string(tape.span_bytes(&b, n.lo, n.n)) {
			return false
		}
	}
	for f in a.facts {
		if string(tape.span_bytes(&a, f.lo, f.n)) != string(tape.span_bytes(&b, f.lo, f.n)) {
			return false
		}
	}
	if (a.partial == nil) != (b.partial == nil) {
		return false
	}
	if a.partial == nil {
		return true
	}
	x, y := a.partial, b.partial
	return same(x.answers, y.answers) && same(x.starts, y.starts) && same(x.kept, y.kept) && same(x.missing, y.missing) && same(x.names, y.names) && x.dups == y.dups
}

// `pieces_agree` over `src` cut in two at every byte, in three at a sample of pairs, and in windows of every size up
// to a few dozen bytes, for a format whose records frame the text as one, and with `containers` as the children of a
// container too.
agree_in_pieces :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, paths: [][]tape.Step, name: string, containers := false) -> bool {
	for k in 0 ..= len(src) {
		cuts := [1]int{k}
		pieces_agree(t, reads, f, src, opts, cuts[:], paths, name, framing = .Concatenated, containers = containers) or_return
	}
	if len(src) >= 8 {
		for k in 0 ..< 12 {
			i := (k * 7919) % len(src)
			j := i + 1 + (k * 104729) % (len(src) - i)
			cuts := [2]int{i, j}
			pieces_agree(t, reads, f, src, opts, cuts[:], paths, name, framing = .Concatenated, containers = containers) or_return
		}
	}
	for size in 1 ..= 40 {
		pieces_agree(t, reads, f, src, opts, cuts_by(len(src), size), paths, name, framing = .Concatenated, containers = containers) or_return
	}
	return true
}

// The reads of `src` in pieces cut at `cuts` give what the whole reads give: the verdict and fault, the document, the
// answer of each path and the scan of them, and the records of `src` framed as `framing`, with `containers` under
// `.Elements` and `.Members` too, as `records_pieces_agree_at` reads them.
pieces_agree :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, cuts: []int, paths: [][]tape.Step, name: string, limits: []int = nil, framing := tape.Framing.Lines, containers := false) -> bool {
	r := Piece_Run{src, reads, f, opts, cuts}
	whole_err := reads.validate(f, src, opts, context.allocator)
	{
		p: tape.Pieces
		defer tape.destroy(&p)
		got: tape.Error
		context.user_ptr = &got
		window := feed(r, &p, proc(window: []u8, r: Piece_Run, opts: tape.Options) -> bool {
			err := r.reads.validate(r.f, window, opts, context.allocator)
			(^tape.Error)(context.user_ptr)^ = err
			return err == nil
		})
		defer delete(window)
		if !testing.expectf(t, got == whole_err && !p.more, "%s %v cut %v: validate %v, whole %v", name, f.name, cuts, got, whole_err) {
			return false
		}
	}
	whole, berr := reads.build(f, src, opts, context.allocator)
	defer tape.destroy(&whole)
	{
		p: tape.Pieces
		defer tape.destroy(&p)
		Got :: struct {
			doc: tape.Document,
			err: tape.Error,
		}
		got: Got
		defer tape.destroy(&got.doc)
		context.user_ptr = &got
		window := feed(r, &p, proc(window: []u8, r: Piece_Run, opts: tape.Options) -> bool {
			g := (^Got)(context.user_ptr)
			doc, err := r.reads.build(r.f, window, opts, context.allocator)
			tape.destroy(&g.doc)
			g.doc, g.err = doc, err
			return err == nil
		})
		defer delete(window)
		if !testing.expectf(t, got.err == berr && same_documents(got.doc, whole), "%s %v cut %v: build %v, whole %v", name, f.name, cuts, got.err, berr) {
			return false
		}
	}
	{
		// Each document so far of a text that builds holds in its root's subtree the scalars of the whole document's,
		// up to the cut.
		p := tape.Pieces{so_far = true}
		defer tape.destroy(&p)
		Got :: struct {
			doc:   tape.Document,
			err:   tape.Error,
			whole: ^tape.Document,
			apart: bool,
		}
		got := Got{whole = &whole}
		defer tape.destroy(&got.doc)
		context.user_ptr = &got
		window := feed(r, &p, proc(window: []u8, r: Piece_Run, opts: tape.Options) -> bool {
			g := (^Got)(context.user_ptr)
			doc, err := r.reads.build(r.f, window, opts, context.allocator)
			tape.destroy(&g.doc)
			g.doc, g.err = doc, err
			if err == nil && opts.pieces.more && len(g.whole.nodes) > 0 && !scalars_lead(&doc, g.whole) {
				g.apart = true
			}
			return err == nil
		})
		defer delete(window)
		if !testing.expectf(t, got.err == berr && !got.apart && same_documents(got.doc, whole), "%s %v cut %v: build so far %v, whole %v, apart %v", name, f.name, cuts, got.err, berr, got.apart) {
			return false
		}
	}
	for path in paths {
		for stop in ([]bool{false, true}) {
			read := tape.Read_Options{stop_early = stop}
			want, ferr := reads.find(f, src, path, read, opts, context.allocator)
			p: tape.Pieces
			Got :: struct {
				a:    tape.Span_Answer,
				err:  tape.Error,
				path: []tape.Step,
				read: tape.Read_Options,
			}
			got := Got{path = path, read = read}
			context.user_ptr = &got
			window := feed(r, &p, proc(window: []u8, r: Piece_Run, opts: tape.Options) -> bool {
				g := (^Got)(context.user_ptr)
				g.a, g.err = r.reads.find(r.f, window, g.path, g.read, opts, context.allocator)
				return g.err == nil
			})
			defer delete(window)
			text := string(p.text)
			ok := got.err == ferr && (ferr != nil || got.a == want && (want.outcome != .Found || text == string(src[want.lo:want.hi])))
			tape.destroy(&p)
			if !testing.expectf(t, ok, "%s %v cut %v: find %v stop %v: %v %v, whole %v %v", name, f.name, cuts, path, stop, got.a, got.err, want, ferr) {
				return false
			}
		}
	}
	d, derr := tape.demand_of(paths, nil, limits, f.facts != {})
	defer tape.destroy(&d)
	if derr != nil {
		return records_pieces_agree_at(t, r, framing, paths, nil, name, containers)
	}
	for stop in ([]bool{false, true}) {
		read := tape.Read_Options{stop_early = stop}
		want, serr := reads.scan(f, src, &d, read, opts, context.allocator)
		defer tape.destroy(&want)
		p: tape.Pieces
		Got :: struct {
			doc:  tape.Document,
			err:  tape.Error,
			d:    ^tape.Demand,
			read: tape.Read_Options,
		}
		got := Got{d = &d, read = read}
		context.user_ptr = &got
		window := feed(r, &p, proc(window: []u8, r: Piece_Run, opts: tape.Options) -> bool {
			g := (^Got)(context.user_ptr)
			doc, err := r.reads.scan(r.f, window, g.d, g.read, opts, context.allocator)
			tape.destroy(&g.doc)
			g.doc, g.err = doc, err
			return err == nil
		})
		defer delete(window)
		ok := got.err == serr && same_documents(got.doc, want)
		tape.destroy(&got.doc)
		tape.destroy(&p)
		if !testing.expectf(t, ok, "%s %v cut %v: scan stop %v: %v, whole %v", name, f.name, cuts, stop, got.err, serr) {
			return false
		}
	}
	return records_pieces_agree_at(t, r, framing, paths, &d, name, containers)
}

// How a records law reads each record: judged, with the answer of `path`, or with the document of `demand`.
@(private)
Records_Read :: struct {
	how:    enum u8 {
		Validate,
		Find,
		Scan,
	},
	path:   []tape.Step,
	demand: ^tape.Demand,
	read:   tape.Read_Options,
}

// What a read of a text's records gave: each record, the answer or document of each, and why the records ended.
@(private)
Records_Got :: struct {
	records: [dynamic]tape.Record,
	answers: [dynamic]tape.Span_Answer,
	docs:    [dynamic]tape.Document,
	err:     tape.Error,
}

@(private)
records_got_free :: proc(g: ^Records_Got) {
	for &d in g.docs {
		tape.destroy(&d)
	}
	delete(g.records)
	delete(g.answers)
	delete(g.docs)
}

// The records of a batch, fewer than a text holds so that a window ends between batches.
@(private)
RECORDS_BATCH :: 3

// Reads the next batch of records of `r` as `how` says into `got`, and returns how many it read.
@(private)
records_batch :: proc(r: ^tape.Records, how: Records_Read, got: ^Records_Got) -> int {
	out: [RECORDS_BATCH]tape.Record
	n: int
	switch how.how {
	case .Validate:
		n = tape.records_validate(r, out[:])
	case .Find:
		answers: [RECORDS_BATCH]tape.Span_Answer
		n = tape.records_find(r, how.path, out[:], answers[:], how.read)
		append(&got.answers, ..answers[:n])
	case .Scan:
		docs: [RECORDS_BATCH]tape.Document
		n = tape.records_scan(r, how.demand, out[:], docs[:], how.read)
		// A batch's documents last until the next, so those kept are cloned.
		for &d in docs[:n] {
			c, err := tape.clone_document(&d)
			assert(err == nil, "a clone of a record's document was refused")
			append(&got.docs, c)
		}
	}
	append(&got.records, ..out[:n])
	return n
}

// Reads the records of `run.src` framed as `framing` as `how` says, the whole text at once, or with `pieces` a window
// at a time, each from the last batch's `keep` to the next cut, of a copy whose bytes before `keep` are overwritten as
// `feed` overwrites them.
@(private)
records_read :: proc(run: Piece_Run, framing: tape.Framing, how: Records_Read, pieces: bool, at: []tape.Step = nil) -> (got: Records_Got) {
	opts := run.opts
	p := tape.Pieces{allocator = context.allocator}
	defer tape.destroy(&p)
	text := run.src
	end := len(text)
	if pieces {
		opts.pieces = &p
		text = slice.clone(run.src)
		if len(run.cuts) > 0 {
			end = run.cuts[0]
		}
		p.last = len(run.cuts) == 0
	}
	defer if pieces {
		delete(text)
	}
	r, e := run.reads.records(run.f, text[:end], framing, opts, at, context.allocator)
	if e != nil {
		got.err = e
		return
	}
	defer tape.destroy_records(r)
	dropped: u64
	for i := 1; ; i += 1 {
		for records_batch(r, how, &got) == RECORDS_BATCH {
		}
		if !pieces || !p.more || p.last {
			break
		}
		end = run.cuts[i] if i < len(run.cuts) else len(run.src)
		p.from, p.last = p.keep, i >= len(run.cuts)
		assert(p.keep >= dropped, "a read needs bytes its last read let go")
		dropped = p.keep
		// Each window is a copy of its own, as `feed` gives them, the one before overwritten and freed once it is made.
		window := slice.clone(run.src[p.keep:end])
		slice.fill(text, 0xFF)
		delete(text)
		text = window
		if err := tape.records_window(r, text); err != nil {
			got.err = err
			return
		}
	}
	got.err = r.err
	return
}

// `records_pieces_agree` under `framing`, and with `containers` under `.Elements` and `.Members` of the root and of each
// of `paths` of at most two steps, each a member's name or a place from the start.
@(private)
records_pieces_agree_at :: proc(t: ^testing.T, run: Piece_Run, framing: tape.Framing, paths: [][]tape.Step, demand: ^tape.Demand, name: string, containers: bool) -> bool {
	records_pieces_agree(t, run, framing, paths, demand, name) or_return
	if !containers {
		return true
	}
	for nested in ([]tape.Framing{.Elements, .Members}) {
		records_pieces_agree(t, run, nested, paths, demand, name) or_return
	}
	outer: for at in paths {
		if len(at) == 0 || len(at) > 2 {
			continue
		}
		for step in at {
			#partial switch s in step {
			case tape.Name:
			case tape.Index:
				if s < 0 {
					continue outer
				}
			case:
				continue outer
			}
		}
		for nested in ([]tape.Framing{.Elements, .Members}) {
			records_pieces_agree(t, run, nested, paths, demand, name, at) or_return
		}
	}
	return true
}

// Whether the records of a text framed as `framing`, those of the container `at` reaches, read a window at a time are
// the whole text's, with the same answers and documents: judged, with each path's answer and with the documents of
// `demand`, nil when the paths make none. The framing of the windows reads no byte twice.
records_pieces_agree :: proc(t: ^testing.T, run: Piece_Run, framing: tape.Framing, paths: [][]tape.Step, demand: ^tape.Demand, name: string, at: []tape.Step = nil) -> bool {
	reads := make([dynamic]Records_Read, context.temp_allocator)
	append(&reads, Records_Read{})
	for path in paths {
		append(&reads, Records_Read{how = .Find, path = path}, Records_Read{how = .Find, path = path, read = {stop_early = true}})
	}
	if demand != nil {
		append(&reads, Records_Read{how = .Scan, demand = demand}, Records_Read{how = .Scan, demand = demand, read = {stop_early = true}})
	}
	for how in reads {
		whole := records_read(run, framing, how, false, at)
		defer records_got_free(&whole)
		got := records_read(run, framing, how, true, at)
		defer records_got_free(&got)
		ok := got.err == whole.err && len(got.records) == len(whole.records) && slice.equal(got.answers[:], whole.answers[:])
		for k := 0; ok && k < len(got.records); k += 1 {
			a, b := got.records[k], whole.records[k]
			ok = a.lo == b.lo && a.hi == b.hi && a.err == b.err && a.key == b.key
			ok = ok && (how.how != .Scan || same_documents(got.docs[k], whole.docs[k]))
		}
		if !testing.expectf(t, ok, "%s %v cut %v: records %v at %v %v %v: %v records, %v, whole %v records, %v", name, run.f.name, run.cuts, framing, at, how.how, how.path, len(got.records), got.err, len(whole.records), whole.err) {
			return false
		}
		if how.how == .Validate && run.opts.dups != .All {
			validate_keeps_faults(t, run, framing, &whole, at, name) or_return
		}
	}
	return true
}

// Whether the records a validate kept, those that do not read, are the records of a find with no path whose error is
// set, in order and ending alike. A find refuses `.All`, which a validate takes.
@(private)
validate_keeps_faults :: proc(t: ^testing.T, run: Piece_Run, framing: tape.Framing, kept: ^Records_Got, at: []tape.Step, name: string) -> bool {
	every := records_read(run, framing, {how = .Find}, false, at)
	defer records_got_free(&every)
	bad := make([dynamic]tape.Record, context.temp_allocator)
	for rec in every.records {
		if rec.err != nil {
			append(&bad, rec)
		}
	}
	ok := every.err == kept.err && len(bad) == len(kept.records)
	for k := 0; ok && k < len(bad); k += 1 {
		a, b := bad[k], kept.records[k]
		ok = a.lo == b.lo && a.hi == b.hi && a.err == b.err && a.key == b.key
	}
	return testing.expectf(t, ok, "%s %v: validate under %v at %v keeps %v records ending %v, a find's faulting records are %v ending %v", name, run.f.name, framing, at, len(kept.records), kept.err, len(bad), every.err)
}

// The law of records at a path over `src`, under each policy for repeated keys: for each value a path of names and
// places from the start reaches in the build that keeps every member, the records under `.Elements` or `.Members`
// are the children of the containers of the framing's kind the path takes, as written, each from its first byte, a
// tag's where it has one, to its end with its key, and each record's scan document is the build's subtree of the
// child. A `Name` step takes the first member of its key under `.First`, every one in document order under `.Group`,
// and under `.Last` each in turn, until one is met once a record was given, which ends the records with
// `.Duplicate_Key` at its key. A value the path reaches last of another kind ends the records with
// `build.records_kind_refusal`, under `.Last` once no later member may take its place, and a path the text has no
// value for holds no records. The records end with the verdict `validate` gives for the text, or a refusal before it.
// Returns the containers whose records it read.
records_at_agree :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, name: string) -> (read: int) {
	defer free_all(context.temp_allocator)
	every := opts
	every.dups = .All
	doc, err := reads.build(f, src, every, context.allocator)
	defer tape.destroy(&doc)
	whole := tape.Demand{}
	derr: runtime.Allocator_Error
	if whole, derr = tape.demand_of({{}}); derr != nil {
		return
	}
	defer tape.destroy(&whole)
	Got :: struct {
		lo, hi: u64,
		key:    tape.Token,
		doc:    tape.Document,
	}
	records_of :: proc(reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, framing: tape.Framing, path: []tape.Step, demand: ^tape.Demand) -> (got: [dynamic]Got, end: tape.Error) {
		got = make([dynamic]Got, context.temp_allocator)
		r, e := reads.records(f, src, framing, opts, path, context.allocator)
		if e != nil {
			return got, e
		}
		defer tape.destroy_records(r)
		out: [2]tape.Record
		docs: [2]tape.Document
		for {
			n := tape.records_scan(r, demand, out[:], docs[:])
			for k in 0 ..< n {
				c, err := tape.clone_document(&docs[k])
				assert(err == nil, "a clone of a record's document was refused")
				append(&got, Got{out[k].lo, out[k].hi, out[k].key, c})
			}
			if n < len(out) {
				break
			}
		}
		return got, r.err
	}
	free_got :: proc(got: [dynamic]Got) {
		for &g in got {
			tape.destroy(&g.doc)
		}
	}
	refusal :: proc(e: tape.Error) -> bool {
		x, fault := e.(tape.Fault)
		return e == build.records_kind_refusal() || fault && x.kind == .Duplicate_Key
	}
	for dups in ([]tape.Duplicates{.Default, .First, .Last, .Group, .All}) {
		o := opts
		o.dups = dups
		verdict := reads.validate(f, src, o, context.allocator)
		if !build.path_dups(f, o) {
			for path in ([][]tape.Step{{tape.Name("a")}, {tape.Index(0)}}) {
				got, end := records_of(reads, f, src, o, .Elements, path, &whole)
				free_got(got)
				testing.expectf(t, len(got) == 0 && end == tape.Error(tape.Bad_Option{"dups"}), "%s %v: records at %v under %v: %d records, %v", name, f.name, path, dups, len(got), end)
			}
			continue
		}
		if err != nil {
			for path in ([][]tape.Step{{tape.Name("a")}, {tape.Index(0)}, {tape.Index(0), tape.Index(0)}}) {
				for framing in ([]tape.Framing{.Elements, .Members}) {
					got, end := records_of(reads, f, src, o, framing, path, &whole)
					free_got(got)
					testing.expectf(t, same_refusal(end, verdict) || refusal(end), "%s %v: records at %v %v under %v: %v, validate %v", name, f.name, path, framing, dups, end, verdict)
				}
			}
			continue
		}
		read += records_at_policy(t, reads, f, src, o, &doc, &whole, name, records_of, free_got)
	}
	return
}

// `records_at_agree` under the policy of `opts` over a valid `src`, whose build keeps every member in `doc`.
@(private)
records_at_policy :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, doc: ^tape.Document, whole: ^tape.Demand, name: string, records_of: proc(reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, framing: tape.Framing, path: []tape.Step, demand: ^tape.Demand) -> (got: [dynamic]$G, end: tape.Error), free_got: proc(got: [dynamic]G)) -> (read: int) {
	dups := f.dups if opts.dups == .Default else opts.dups
	r := tape.Reader{doc, nil}
	reached := make([dynamic][]tape.Step, context.temp_allocator)
	Reach :: struct {
		path: []tape.Step,
		at:   tape.Node_Index,
	}
	todo := make([dynamic]Reach, context.temp_allocator)
	append(&todo, Reach{nil, tape.ROOT})
	for i := 0; i < len(todo) && len(todo) < 40; i += 1 {
		from := todo[i]
		if len(from.path) == 3 {
			continue
		}
		c, p, _ := tape.children(r, from.at, context.temp_allocator)
		if p != .Found {
			continue
		}
		seen := make([dynamic]string, context.temp_allocator)
		for place := 0; ; place += 1 {
			key, value, vp := tape.next_child(r, &c, .Group)
			if vp != .Found {
				break
			}
			step: tape.Step = tape.Index(place)
			if key != tape.NO_NODE {
				text := scalar_text(doc, key)
				if slice.contains(seen[:], text) {
					continue
				}
				append(&seen, text)
				step = tape.Name(text)
			}
			path := slice.concatenate([][]tape.Step{from.path, {step}}, context.temp_allocator)
			append(&todo, Reach{path, value})
		}
	}
	for x in todo[1:] {
		append(&reached, x.path)
	}
	append(&reached, []tape.Step{tape.Name("zz_missing")}, []tape.Step{tape.Index(1 << 20)})
	if doc.nodes[tape.ROOT].kind <= .Plain {
		append(&reached, []tape.Step{})
	}
	// The records the policy gives at `path`, in order, and how they end.
	Want :: struct {
		children: [dynamic][2]tape.Node_Index, // each record's key, `NO_NODE` in an array, and value
		end:      tape.Error,
		given:    bool,
		pending:  bool,
		done:     bool,
	}
	visit :: proc(r: tape.Reader, f: ^tape.Format, src: []u8, at: tape.Node_Index, path: []tape.Step, framing: tape.Framing, dups: tape.Duplicates, w: ^Want) {
		doc := r.doc
		kind := doc.nodes[at].kind
		if len(path) == 0 {
			if kind != (.Array if framing == .Elements else .Object) {
				if dups == .Last {
					w.pending = true
				} else {
					w.end, w.done = build.records_kind_refusal(), true
				}
				return
			}
			c, _, _ := tape.children(r, at, context.temp_allocator)
			for {
				key, value, vp := tape.next_child(r, &c, .Group)
				if vp != .Found {
					break
				}
				append(&w.children, [2]tape.Node_Index{key, value})
				w.given = true
			}
			return
		}
		#partial switch s in path[0] {
		case tape.Index:
			if kind != .Array {
				return
			}
			c, _, _ := tape.children(r, at, context.temp_allocator)
			for place := 0; ; place += 1 {
				_, value, vp := tape.next_child(r, &c, .Group)
				if vp != .Found {
					return
				}
				if place == int(s) {
					w.pending = false
					visit(r, f, src, value, path[1:], framing, dups, w)
					return
				}
			}
		case tape.Name:
			if kind != .Object {
				return
			}
			c, _, _ := tape.children(r, at, context.temp_allocator)
			for {
				key, value, vp := tape.next_child(r, &c, .Group)
				if vp != .Found || w.done {
					return
				}
				if !tape.key_names(f, src, doc.nodes[key], string(s)) {
					continue
				}
				if dups == .Last && w.given {
					head, _ := f.bounds(src, doc.nodes[key])
					w.end, w.done = tape.Fault{at = doc.nodes[key].lo - u64(head), kind = .Duplicate_Key}, true
					return
				}
				w.pending = false
				visit(r, f, src, value, path[1:], framing, dups, w)
				if dups == .First {
					return
				}
			}
		}
	}
	for path in reached {
		for framing in ([]tape.Framing{.Elements, .Members}) {
			got, end := records_of(reads, f, src, opts, framing, path, whole)
			defer free_got(got)
			want := Want{children = make([dynamic][2]tape.Node_Index, context.temp_allocator)}
			visit(r, f, src, tape.ROOT, path, framing, dups, &want)
			if !want.done && want.pending {
				want.end = build.records_kind_refusal()
			}
			ok := len(got) == len(want.children) && same_refusal(end, want.end)
			if !testing.expectf(t, ok, "%s %v: records at %v %v under %v: %d records ending %v, want %d ending %v", name, f.name, path, framing, dups, len(got), end, len(want.children), want.end) {
				continue
			}
			read += int(len(want.children) > 0)
			for kv, k in want.children {
				g := got[k]
				key, value := kv[0], kv[1]
				node := doc.nodes[value]
				lo, hi := node.lo, node.lo + u64(node.n)
				if node.kind > .Plain {
					hi, _ = f.close_end(doc, value)
				} else {
					head, tail := f.bounds(src, node)
					lo, hi = lo - u64(head), hi + u64(tail)
				}
				for fact in doc.facts {
					if fact.node == value && fact.kind == .Tag {
						lo = min(lo, fact.lo)
					}
				}
				want_doc := strings.builder_make(context.temp_allocator)
				render_node(&want_doc, doc, int(value))
				ok = g.lo == lo && g.hi == hi && render_doc(&g.doc) == strings.to_string(want_doc)
				ok &&= key == tape.NO_NODE || g.key.lo == doc.nodes[key].lo && g.key.n == doc.nodes[key].n
				testing.expectf(t, ok, "%s %v: records at %v %v under %v: record %d %v..%v %s, child %v..%v %s", name, f.name, path, framing, dups, k, g.lo, g.hi, render_doc(&g.doc), lo, hi, strings.to_string(want_doc))
			}
		}
	}
	return
}

// What precedes a record in its own text, in a text whose records take their shape from bytes before them.
Alone_Head :: enum u8 {
	Nothing, // the record's bytes alone
	Text_Before_First, // the bytes before the first record, which hold a table's header
	First_Record, // the first record's line, whose width the others take, for every record past the first
}

// How a record's own text is made from the text its records are read from: its bytes after `head`. With `rows` the own
// text is a list of rows and a read of it reaches the record through its index, so that a read of a record at a path
// answers as the own text at that index and the path does.
Alone :: struct {
	head:    Alone_Head,
	rows:    bool,
	framing: tape.Framing, // the framing the records are read as, `.Lines` for a zero value
}

// `err` with the offset it names moved by `by`, as a record read in place in a text names what the read of its own text
// names in that text.
@(private)
moved_error :: proc(err: tape.Error, by: i64) -> tape.Error {
	#partial switch e in err {
	case tape.Fault:
		f := e
		f.at = u64(i64(f.at) + by)
		return f
	case tape.Exceeded:
		x := e
		if x.kind != .Memory {
			x.at = u64(i64(x.at) + by)
		}
		return x
	}
	return err
}

// Whether the records of `run.src`, read as `how` says whole or in pieces, answer as the reads of each record's own
// text do: the record's verdict is the verdict of its own text, with the fault's offset moved to the record's place, its
// find answer is the own text's answer at `alone.lead` and the path, and its scan document answers the paths as the
// own text's scan does. A text with no record has nothing to compare.
@(private)
records_alone_check :: proc(t: ^testing.T, run: Piece_Run, alone: Alone, how: Records_Read, own_demands: ^[2]tape.Demand, pieces: bool, name: string) -> bool {
	// A validate keeps only the records that do not read, so every record's verdict is a find's with no path, of which
	// the validate's must be those that do not read.
	read := how
	if how.how == .Validate {
		read = {how = .Find}
		if run.opts.dups != .All {
			kept := records_read(run, alone.framing, how, pieces)
			defer records_got_free(&kept)
			validate_keeps_faults(t, run, alone.framing, &kept, nil, name) or_return
		}
	}
	got := records_read(run, alone.framing, read, pieces)
	defer records_got_free(&got)
	if len(got.records) == 0 {
		return true
	}
	for rec, k in got.records {
		head: []u8
		switch alone.head {
		case .Nothing:
		case .Text_Before_First:
			head = run.src[:got.records[0].lo]
		case .First_Record:
			if k > 0 {
				head = slice.concatenate([][]u8{run.src[got.records[0].lo:got.records[0].hi], {'\n'}}, context.temp_allocator)
			}
		}
		text := slice.concatenate([][]u8{head, run.src[rec.lo:rec.hi]}, context.temp_allocator)
		// The own text holds the first record's line before a later record, which is then its row 1.
		row := 1 if alone.head == .First_Record && k > 0 else 0
		own_path := how.path
		if alone.rows {
			own_path = slice.concatenate([][]tape.Step{{tape.Index(row)}, how.path}, context.temp_allocator)
		}
		by := i64(rec.lo) - i64(len(head))
		want: tape.Error
		same := true
		detail: string
		switch how.how {
		case .Validate:
			want = run.reads.validate(run.f, text, run.opts, context.allocator)
		case .Find:
			a, err := run.reads.find(run.f, text, own_path, how.read, run.opts, context.allocator)
			want = err
			if err == nil && rec.err == nil {
				got_answer := got.answers[k]
				detail = fmt.tprintf("answer %v %q, own text's %v %q", got_answer, run.src[got_answer.lo:got_answer.hi], a, text[a.lo:a.hi])
				same = a.outcome == got_answer.outcome && a.kind == got_answer.kind
				same &&= a.outcome != .Found || string(text[a.lo:a.hi]) == string(run.src[got_answer.lo:got_answer.hi])
			}
		case .Scan:
			d, err := run.reads.scan(run.f, text, &own_demands[row], how.read, run.opts, context.allocator)
			defer tape.destroy(&d)
			want = err
			if err == nil && rec.err == nil {
				detail = fmt.tprintf("answers %s, own text's %s", render_answers(&got.docs[k]), render_answers(&d))
				same = render_answers(&d) == render_answers(&got.docs[k])
			}
		}
		// A read that stops at its answer judges the bytes it reads, so it may stop before a fault that the read of the
		// own text finds in the rest of the record.
		if how.read.stop_early && rec.err == nil && want != nil {
			continue
		}
		if !testing.expectf(t, same_refusal(rec.err, moved_error(want, by)) && same, "%s %v cut %v pieces %v: %v %v %v record %d %q: reads as %v, its own text as %v, %s", name, run.f.name, run.cuts, pieces, how.how, how.path, how.read, k, string(text), rec.err, want, detail) {
			return false
		}
	}
	return true
}

// Whether every record's answers equal the whole-text answers of that record's own text, for the verdict, each of
// `paths` found with and without `stop_early`, and the scan of all of them, whole and read in the windows `run.cuts`
// cut. Returns false after reporting the first record that differs.
records_alone_agree :: proc(t: ^testing.T, run: Piece_Run, alone: Alone, paths: [][]tape.Step, name: string) -> bool {
	reads := make([dynamic]Records_Read, context.temp_allocator)
	append(&reads, Records_Read{})
	for path in paths {
		append(&reads, Records_Read{how = .Find, path = path}, Records_Read{how = .Find, path = path, read = {stop_early = true}})
	}
	demand, derr := tape.demand_of(paths, nil, nil, run.f.facts != {})
	defer tape.destroy(&demand)
	own_demands: [2]tape.Demand
	defer for &d in own_demands {
		tape.destroy(&d)
	}
	oerr: runtime.Allocator_Error
	for &d, row in own_demands {
		own_paths := make([][]tape.Step, len(paths), context.temp_allocator)
		for path, i in paths {
			own_paths[i] = path
			if alone.rows {
				own_paths[i] = slice.concatenate([][]tape.Step{{tape.Index(row)}, path}, context.temp_allocator)
			}
		}
		d, oerr = tape.demand_of(own_paths, nil, nil, run.f.facts != {})
	}
	if derr == nil && oerr == nil {
		append(&reads, Records_Read{how = .Scan, demand = &demand}, Records_Read{how = .Scan, demand = &demand, read = {stop_early = true}})
	}
	cut := run
	cut.cuts = slice.clone(run.cuts, context.temp_allocator)
	for &at in cut.cuts {
		at = min(at, len(run.src))
	}
	for how in reads {
		for pieces in ([]bool{false, true}) {
			if !records_alone_check(t, cut, alone, how, &own_demands, pieces, name) {
				return false
			}
		}
	}
	return true
}

// Whether the scalars of the root's subtree of `part`, a document so far, are the first scalars of `whole`'s root.
@(private)
scalars_lead :: proc(part, whole: ^tape.Document) -> bool {
	if len(part.nodes) == 0 {
		return true
	}
	if len(whole.nodes) == 0 {
		return false
	}
	k := 0
	whole_end := int(whole.nodes[0].n) if whole.nodes[0].kind > .Plain else 1
	for n in part.nodes[:int(part.nodes[0].n) if part.nodes[0].kind > .Plain else 1] {
		if n.kind > .Plain {
			continue
		}
		for k < whole_end && whole.nodes[k].kind > .Plain {
			k += 1
		}
		if k >= whole_end || whole.nodes[k] != n {
			return false
		}
		k += 1
	}
	return true
}

// Whether two builds of one text gave the same document over the same bytes.
@(private)
same_build :: proc(a, b: tape.Document) -> bool {
	return same_documents(a, b) && a.flags == b.flags && a.partial == nil && b.partial == nil && raw_data(a.src) == raw_data(b.src)
}

// Whether the build of `src` on `runner` gives the document and error of the build on one thread, and whether that
// build gave a document.
threads_agree :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, runner: ^tape.Runner, name: string) -> (ok, built: bool) {
	want, werr := reads.build(f, src, opts, context.allocator)
	defer tape.destroy(&want)
	wide := opts
	wide.runner = runner
	got, gerr := reads.build(f, src, wide, context.allocator)
	defer tape.destroy(&got)
	ok = testing.expectf(t, same_refusal(gerr, werr) && same_build(got, want), "%s %v %v on %d threads: %v, one thread %v (%d and %d nodes)", name, f.name, opts, runner.threads, gerr, werr, len(got.nodes), len(want.nodes))
	return ok, werr == nil
}

// Whether the build of `src` on `runner` under a memory budget in `opts` gives the document and error of the build on one
// thread with no budget, or the refusal of the budget, which a build that counts its parts' blocks may give. It never
// gives another document.
threads_fit :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, runner: ^tape.Runner, name: string) -> bool {
	free := opts
	free.budget.memory = 0
	want, werr := reads.build(f, src, free, context.allocator)
	defer tape.destroy(&want)
	wide := opts
	wide.runner = runner
	got, gerr := reads.build(f, src, wide, context.allocator)
	defer tape.destroy(&got)
	if refused, is_exceeded := gerr.(tape.Exceeded); is_exceeded && refused.kind == .Memory {
		return true
	}
	return testing.expectf(t, same_refusal(gerr, werr) && same_build(got, want), "%s %v %v on %d threads: %v, one thread %v (%d and %d nodes)", name, f.name, opts, runner.threads, gerr, werr, len(got.nodes), len(want.nodes))
}

// The answers of the partial reads in the agreement test.
Agreement :: struct {
	texts, refused, scans, on_path, reads: int,
	// The queries over builds, and the paths a query over a scan's partial document read as the build, or not loaded.
	queries, query_reads, query_unread:   int,
	outcomes:                              [tape.Presence]int,
	shapes:                                map[u64]struct{}, // the kinds of steps of each path a scan read, `shape_of`
}

// The least a run of the agreement test must have read. A change that stops it reading fails the test.
Agreement_Floor :: struct {
	texts, refused, scans, on_path, shapes: int,
}

expect_agreement :: proc(t: ^testing.T, a: ^Agreement, floor: Agreement_Floor) {
	log.infof("agreement: %d texts, %d refused, %d scans, %d path steps, %d other reads, %d path shapes, partial outcomes %v", a.texts, a.refused, a.scans, a.on_path, a.reads, len(a.shapes), a.outcomes)
	testing.expectf(t, a.texts >= floor.texts && a.refused >= floor.refused && a.scans >= floor.scans && a.on_path >= floor.on_path && len(a.shapes) >= floor.shapes, "%d texts, %d refused, %d scans, %d path steps, %d path shapes", a.texts, a.refused, a.scans, a.on_path, len(a.shapes))
	testing.expect(t, a.outcomes[.Not_Loaded] > 0 && a.outcomes[.Missing] > 0 && a.outcomes[.Wrong_Kind] > 0 && a.outcomes[.Found] > 0)
	log.infof("queries: %d of builds, over partial documents %d paths read as the build and %d not loaded", a.queries, a.query_reads, a.query_unread)
	testing.expectf(t, a.queries >= floor.scans / 6 && a.query_reads > 0 && a.query_unread > 0, "%d queries, %d paths read, %d not loaded", a.queries, a.query_reads, a.query_unread)
}

// The readers law over `src`: each path of scans by paths of its own keys and indexes reads over the partial document
// as over the build, and every other read the partial document answers is the build's, or `.Not_Loaded` where the build
// has a value or lacks it. A text the build refuses is refused alike by every read. `a` counts what was read.
readers_agree :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, name: string, a: ^Agreement) {
	defer free_all(context.temp_allocator)
	doc, err := reads.build(f, src, opts, context.allocator)
	defer tape.destroy(&doc)
	if err != nil {
		a.refused += 1
		reads_refuse(t, reads, f, src, opts, err, name)
		return
	}
	a.texts += 1
	full_index := tape.Doc_Index{allocator = context.temp_allocator}
	defer tape.destroy(&full_index)
	paths := paths_of(&doc)
	scanned := make([dynamic][]tape.Step, context.temp_allocator)
	for path in paths {
		if deep_back(path) {
			deep_back_agree(t, reads, f, src, opts, &doc, path, name)
		} else {
			append(&scanned, path)
		}
	}
	sets := make([dynamic][][]tape.Step, context.temp_allocator)
	for i in 0 ..< len(scanned) {
		append(&sets, scanned[i:][:1])
		if i + 1 < len(scanned) {
			append(&sets, scanned[i:][:2])
		}
	}
	append(&sets, scanned[:])
	Grained :: struct {
		paths:  [][]tape.Step,
		grains: []tape.Grain,
		limits: []int,
		facts:  bool,
	}
	runs := make([dynamic]Grained, context.temp_allocator)
	for set, i in sets {
		append(&runs, Grained{set, nil, nil, false})
		if len(set) == 1 || i + 1 == len(sets) {
			for grain in ([]tape.Grain{.Keys, .Exists}) {
				grains := make([]tape.Grain, len(set), context.temp_allocator)
				for &g, j in grains {
					g = grain if j % 3 != 2 else .Whole
				}
				append(&runs, Grained{set, grains, nil, false})
			}
			// Each path's first answer, or its first two, and every third path's every answer.
			for limit in 1 ..= 2 {
				limits := make([]int, len(set), context.temp_allocator)
				for &l, j in limits {
					l = limit if j % 3 != 2 else 0
				}
				append(&runs, Grained{set, nil, limits, false})
			}
		}
	}
	if f.facts != {} {
		append(&runs, Grained{sets[len(sets) - 1], nil, nil, true})
	}
	all, aerr := tape.demand_of(paths)
	testing.expect(t, aerr == nil)
	defer tape.destroy(&all)
	for run in runs {
		set := run.paths
		d, derr := tape.demand_of(set, run.grains, run.limits, run.facts)
		testing.expect(t, derr == nil)
		defer tape.destroy(&d)
		for dups in ([]tape.Duplicates{.Last, .First, .Group}) {
			for stop in ([]bool{false, true}) {
				scan_opts := opts
				scan_opts.dups = dups
				r, serr := reads.scan(f, src, &d, {stop_early = stop}, scan_opts, context.allocator)
				defer tape.destroy(&r)
				if !testing.expectf(t, serr == nil, "%s %v: scan %v", name, f.name, serr) {
					continue
				}
				a.scans += 1
				// The whole document's readers go through its index on a scan that ran to the end, and the partial one's
				// on a stopped scan, so each path is checked against the other.
				w := Agree_Walk{t, {&doc, nil}, {&r, nil}, dups, name, set, stop, a}
				partial_index := tape.Doc_Index{allocator = context.temp_allocator}
				defer tape.destroy(&partial_index)
				if stop {
					w.r.index = &partial_index
				} else {
					w.doc.index = &full_index
				}
				for path, i in set {
					a.shapes[shape_of(path)] = {}
					limit := run.limits[i] if i < len(run.limits) else 0
					// A path past its limit keeps no more, so only its answers are checked.
					if run.limits == nil {
						agree_on_path(&w, tape.ROOT, tape.ROOT, path, run.grains[i] if i < len(run.grains) else .Whole)
					}

					// A stopped scan's answers are the reference's once its paths are settled, which a stop leaves them.
					if !answers_agree(&doc, &r, i, path, dups, limit) {
						testing.expectf(t, false, "%s %v: answers of %v under %v limit %d stop %v: %s", name, f.name, path, dups, limit, stop, render_answers(&r))
					}
				}
				if run.facts {
					agree_facts(t, &doc, &r, name)
				}
				plain := run.grains == nil && run.limits == nil
				if !stop {
					build_query_agrees(t, reads, f, src, scan_opts, &doc, &d, set, run.limits, plain && len(set) == 1, name, a)
				}
				scan_query_agrees(t, f, &doc, &r, &d, set, run.limits, dups, stop, name)
				// The query of every path over the scan is checked on the scans that keep each path whole.
				if plain && len(paths) > 0 {
					wide_query_agrees(t, f, &doc, &r, &all, paths, dups, stop, name, a)
				}

				if root, p := tape.root(w.r); p == .Found {
					agree_past(&w, tape.ROOT, root, 0)
				}
			}
		}
	}
}

// Whether a path of `set` has a step with a limit.
@(private)
step_limited :: proc(set: [][]tape.Step) -> bool {
	for path in set {
		for step in path {
			#partial switch s in step {
			case tape.All:
				if s.limit > 0 {
					return true
				}
			case tape.Slice:
				if s.limit > 0 {
					return true
				}
			}
		}
	}
	return false
}

// Whether `path` has a step from the end past a `Descend`, which a scan refuses.
@(private)
deep_back :: proc(path: []tape.Step) -> bool {
	descends := false
	for step in path {
		if tape.step_reach(step) > 0 && descends {
			return true
		}
		_, d := step.(tape.Descend)
		descends ||= d
	}
	return false
}

// The law of a path a scan refuses: its scan ends with `tape.Bad_Option` for the path under every policy and limit, and
// a query of the build `doc` answers it as the reference does.
@(private)
deep_back_agree :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, doc: ^tape.Document, path: []tape.Step, name: string) {
	for limit in 0 ..= 2 {
		d, derr := tape.demand_of({path}, nil, {limit})
		if !testing.expect(t, derr == nil) {
			return
		}
		defer tape.destroy(&d)
		for dups in ([]tape.Duplicates{.Last, .First, .Group}) {
			o := opts
			o.dups = dups
			r, serr := reads.scan(f, src, &d, {}, o, context.allocator)
			tape.destroy(&r)
			bad, refused := serr.(tape.Bad_Option)
			testing.expectf(t, refused && bad.option == "path", "%s %v: scan of %v: %v", name, f.name, path, serr)
			q, qerr := build.query({doc, nil}, &d, {dups = dups})
			defer tape.destroy(&q)
			testing.expectf(t, qerr == nil && answers_agree(doc, &q, 0, path, dups, limit), "%s %v: query of the build, answers of %v under %v limit %d: %v %s", name, f.name, path, dups, limit, qerr, render_answers(&q))
		}
	}
}

// The query law over the build `doc` of `src`: a query of `d`, a demand of `set`, answers as the reference does. With
// `single`, a find of the one path under `opts` answers the first of the query's answers.
@(private)
build_query_agrees :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, doc: ^tape.Document, d: ^tape.Demand, set: [][]tape.Step, limits: []int, single: bool, name: string, a: ^Agreement) {
	dups := opts.dups
	q, err := build.query({doc, nil}, d, {dups = dups})
	defer tape.destroy(&q)
	if !testing.expectf(t, err == nil, "%s %v: query of the build %v", name, f.name, err) {
		return
	}
	a.queries += 1
	for path, i in set {
		limit := limits[i] if i < len(limits) else 0
		if !answers_agree(doc, &q, i, path, dups, limit) {
			testing.expectf(t, false, "%s %v: query of the build, answers of %v under %v limit %d: %s", name, f.name, path, dups, limit, render_answers(&q))
		}
	}
	if !single {
		return
	}
	fa, ferr := reads.find(f, src, set[0], {}, opts, context.allocator)
	k, kp, any := tape.answer({doc = &q}, 0, 0)
	ok := true
	if bad, refused := ferr.(tape.Bad_Option); refused && bad.option == "path" {
	} else if ferr != nil {
		ok = false
	} else if !any {
		ok = fa.outcome == .Missing
	} else if kp == .Found {
		node := doc.nodes[k]
		got := tape.answer_node(fa)
		ok = fa.outcome == .Found && got.lo == node.lo && got.kind == node.kind && (node.kind > .Plain || got.n == node.n)
	} else {
		ok = fa.outcome == kp
	}
	testing.expectf(t, ok, "%s %v: find %v under %v: %v %v, query %v %v", name, f.name, set[0], dups, fa, ferr, kp, k)
}

// The query law over the scan `r` by `d`, a demand of `set`, against the build `doc`: a query of `d` over `r` answers as
// the reference does, where a stopped scan, or one a limit on a path or a step cut short, may leave a path `.Not_Loaded`.
@(private)
scan_query_agrees :: proc(t: ^testing.T, f: ^tape.Format, doc, r: ^tape.Document, d: ^tape.Demand, set: [][]tape.Step, limits: []int, dups: tape.Duplicates, stop: bool, name: string) {
	q, err := build.query({r, nil}, d, {dups = dups})
	defer tape.destroy(&q)
	if !testing.expectf(t, err == nil, "%s %v: query of the scan %v", name, f.name, err) {
		return
	}
	cut := stop || limits != nil || step_limited(set)
	for path, i in set {
		limit := limits[i] if i < len(limits) else 0
		if !answers_agree(doc, &q, i, path, dups, limit) && !(cut && not_loaded(&q, i)) {
			testing.expectf(t, false, "%s %v: query of the scan stop %v, answers of %v under %v limit %d: %s", name, f.name, stop, path, dups, limit, render_answers(&q))
		}
	}
}

// The query law of `all`, the demand of `every` path, over the scan `r` of fewer paths: each path answers as the
// reference, the build `doc`, does, or with a `.Not_Loaded` where the scan did not keep what it reads.
@(private)
wide_query_agrees :: proc(t: ^testing.T, f: ^tape.Format, doc, r: ^tape.Document, all: ^tape.Demand, every: [][]tape.Step, dups: tape.Duplicates, stop: bool, name: string, a: ^Agreement) {
	wide, err := build.query({r, nil}, all, {dups = dups})
	defer tape.destroy(&wide)
	if !testing.expectf(t, err == nil, "%s %v: query of every path over the scan %v", name, f.name, err) {
		return
	}
	for path, i in every {
		if answers_agree(doc, &wide, i, path, dups, 0) {
			a.query_reads += 1
		} else if not_loaded(&wide, i) {
			a.query_unread += 1
		} else {
			testing.expectf(t, false, "%s %v: query of every path over the scan stop %v, answers of %v under %v: %s", name, f.name, stop, path, dups, render_answers(&wide))
		}
	}
}

// Whether some answer of path `path` of `q` is `.Not_Loaded`.
@(private)
not_loaded :: proc(q: ^tape.Document, path: int) -> bool {
	for k := 0; ; k += 1 {
		_, p, ok := tape.answer({doc = q}, path, k)
		if !ok {
			return false
		}
		if p == .Not_Loaded {
			return true
		}
	}
}

// The kinds of the steps of a path, a name, an index from either end, an `All` with or without a limit, and a slice from
// either end, in one number.
@(private)
shape_of :: proc(path: []tape.Step) -> (shape: u64) {
	for step in path {
		code := u64(0)
		switch s in step {
		case tape.Name:
			code = 1
		case tape.Index:
			code = 2 if s >= 0 else 3
		case tape.All:
			code = 4 if s.limit <= 0 else 5
		case tape.Slice:
			code = 6 if s.lo >= 0 else 7
		case tape.Descend:
			code = 8
		}
		shape = shape << 3 | code
	}
	return shape << 3 | u64(len(path))
}

@(private)
Agree_Walk :: struct {
	t:     ^testing.T,
	doc:   tape.Reader,
	r:     tape.Reader,
	dups:  tape.Duplicates,
	name:  string,
	paths: [][]tape.Step,
	stop:  bool,
	a:     ^Agreement,
}

// The paths of a scan: the whole text, indexes from either end, every element, the first ones, slices, up to twelve
// of its keys in steps around them, with names it lacks, and the paths down to its first and its last leaf.
@(private)
paths_of :: proc(doc: ^tape.Document) -> [][]tape.Step {
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	A :: tape.All{}
	out := make([dynamic][]tape.Step, context.temp_allocator)
	add :: proc(out: ^[dynamic][]tape.Step, steps: ..tape.Step) {
		path := make([]tape.Step, len(steps), context.temp_allocator)
		copy(path, steps)
		append(out, path)
	}
	add(&out)
	add(&out, I(0))
	add(&out, I(2))
	add(&out, I(1))
	add(&out, I(-1))
	add(&out, I(-2))
	add(&out, A)
	add(&out, A, A)
	add(&out, I(0), I(0))
	add(&out, I(-1), I(-1))
	add(&out, A, I(0))
	add(&out, N(""))
	add(&out, tape.All{1})
	add(&out, tape.All{2}, A)
	add(&out, A, tape.All{1})
	add(&out, tape.Slice{1, nil, 0})
	add(&out, tape.Slice{-2, nil, 0})
	add(&out, tape.Slice{0, -1, 0})
	add(&out, tape.Slice{1, 3, 1})
	add(&out, tape.Slice{-3, -1, 0}, A)
	D :: tape.Descend{}
	add(&out, D)
	add(&out, D, I(0))
	add(&out, D, A)
	add(&out, D, I(-1))
	add(&out, I(0), D)
	add(&out, D, D)
	add(&out, D, tape.Slice{-2, nil, 0})
	keys := make([dynamic]string, context.temp_allocator)
	for node, i in doc.nodes {
		if node.role != .Key || node.kind > .Plain || len(keys) == 12 {
			continue
		}
		key := scalar_text(doc, tape.Node_Index(i))
		seen := false
		for k in keys {
			seen ||= k == key
		}
		if !seen {
			append(&keys, key)
		}
	}
	for k, n in keys {
		k2 := keys[(n + 1) % len(keys)]
		add(&out, N(k))
		add(&out, A, N(k))
		add(&out, I(0), N(k))
		add(&out, I(-1), N(k))
		add(&out, N(k), I(0))
		add(&out, N(k), I(-1))
		add(&out, N(k), A)
		add(&out, N(k), N(k2))
		add(&out, A, N(k), A)
		add(&out, N(k), N("zz_missing"))
		add(&out, N(k), A, N(k2))
		add(&out, tape.All{1}, N(k))
		add(&out, tape.Slice{-2, nil, 0}, N(k))
		add(&out, N(k), tape.Slice{1, nil, 1})
		if n < 4 {
			add(&out, D, N(k))
			add(&out, N(k), D)
			add(&out, D, N(k), A)
			add(&out, A, D, N(k2))
			add(&out, D, N(k), D, N(k2))
		}
	}
	for last in ([]bool{false, true}) {
		down := make([dynamic]tape.Step, context.temp_allocator)
		for at := tape.ROOT; len(down) < 7; {
			node := doc.nodes[at]
			if node.kind < .Array || node.n == 1 {
				break
			}
			r := tape.Reader{doc, nil}
			c, _, _ := tape.children(r, at, context.temp_allocator)
			key, member, _ := tape.next_child(r, &c, .Group)
			for last {
				k, v, p := tape.next_child(r, &c, .Group)
				if p != .Found {
					break
				}
				key, member = k, v
			}
			if node.kind == .Object {
				append(&down, tape.Step(tape.Name(scalar_text(doc, key))))
			} else {
				append(&down, tape.Step(tape.Index(-1 if last else 0)))
			}
			at = member
			if len(down) >= 3 {
				add(&out, ..down[:])
				add(&out, ..slice.concatenate([][]tape.Step{{A}, down[1:]}, context.temp_allocator))
			}
		}
	}
	return out[:]
}

// Whether node `f` of the whole document and node `p` of the partial one are the same value of the text.
@(private)
same_node :: proc(w: ^Agree_Walk, f, p: tape.Node_Index) -> bool {
	if f == tape.NO_NODE || p == tape.NO_NODE {
		return f == p
	}
	x, y := w.doc.doc.nodes[f], w.r.doc.nodes[p]
	return x.lo == y.lo && x.kind == y.kind && x.role == y.role && (x.kind > .Plain || x.n == y.n && x.spelling == y.spelling)
}

// Checks a step of a path the scan read, which the partial document answers as the whole one does.
@(private)
agree_step :: proc(w: ^Agree_Walk, what: any, f, p: tape.Node_Index, fp, pp: tape.Presence, loc := #caller_location) -> bool {
	w.a.on_path += 1
	if fp == pp && (fp != .Found || same_node(w, f, p)) {
		return true
	}
	return testing.expectf(w.t, false, "%s scan %v %v stop %v: %v gives %v %v, whole %v %v; %s", w.name, w.paths, w.dups, w.stop, what, pp, p, fp, f, render_doc(w.r.doc), loc = loc)
}

// Checks a read past the scan's paths: the whole document's answer, or `.Not_Loaded` where the whole one has a value
// or lacks it.
@(private)
agree_read :: proc(w: ^Agree_Walk, what: any, f, p: tape.Node_Index, fp, pp: tape.Presence, loc := #caller_location) -> bool {
	w.a.reads += 1
	w.a.outcomes[pp] += 1
	if pp == fp && (fp != .Found || same_node(w, f, p)) || pp == .Not_Loaded && fp != .Wrong_Kind {
		return true
	}
	return testing.expectf(w.t, false, "%s scan %v %v stop %v: %v gives %v %v, whole %v %v; %s", w.name, w.paths, w.dups, w.stop, what, pp, p, fp, f, render_doc(w.r.doc), loc = loc)
}

// Checks the steps of a path the scan read, and at their end what `grain` keeps.
@(private)
agree_on_path :: proc(w: ^Agree_Walk, f, p: tape.Node_Index, steps: []tape.Step, grain: tape.Grain) {
	if len(steps) == 0 {
		agree_grain(w, f, p, grain)
		return
	}
	switch step in steps[0] {
	case tape.Descend:
		agree_on_path(w, f, p, steps[1:], grain)
		if kind := w.doc.doc.nodes[f].kind; kind == .Array || kind == .Object {
			fc, fp, _ := tape.children(w.doc, f, context.temp_allocator)
			pc, pp, _ := tape.children(w.r, p, context.temp_allocator)
			if !agree_step(w, "children", tape.NO_NODE, tape.NO_NODE, fp, pp) || fp != .Found {
				return
			}
			for {
				fk, fv, fnp := tape.next_child(w.doc, &fc, .Group)
				pk, pv, pnp := tape.next_child(w.r, &pc, .Group)
				if !agree_step(w, "descendant", fv, pv, fnp, pnp) || !same_node(w, fk, pk) || fnp != .Found {
					break
				}
				agree_on_path(w, fv, pv, steps, grain)
			}
		}
	case tape.Name:
		if w.dups == .Group {
			fc, fp := tape.named(w.doc, f, string(step))
			pc, pp := tape.named(w.r, p, string(step))
			if !agree_step(w, step, tape.NO_NODE, tape.NO_NODE, fp, pp) || fp != .Found {
				return
			}
			for {
				fk, fv, fnp := tape.next_child(w.doc, &fc)
				pk, pv, pnp := tape.next_child(w.r, &pc)
				if !agree_step(w, "group member", fv, pv, fnp, pnp) || !same_node(w, fk, pk) || fnp != .Found {
					return
				}
				agree_on_path(w, fv, pv, steps[1:], grain)
			}
		}
		fv, fp := tape.member(w.doc, f, string(step), w.dups)

		pv, pp := tape.member(w.r, p, string(step), w.dups)
		if agree_step(w, step, fv, pv, fp, pp) && fp == .Found {
			agree_on_path(w, fv, pv, steps[1:], grain)
		}
	case tape.Index:
		fv, fp := tape.element(w.doc, f, int(step))
		pv, pp := tape.element(w.r, p, int(step))
		if agree_step(w, step, fv, pv, fp, pp) && fp == .Found {
			agree_on_path(w, fv, pv, steps[1:], grain)
		}
	case tape.All:
		node := w.doc.doc.nodes[f]
		if step.limit > 0 && node.kind == .Object && w.dups == .First {
			// Members past the limit are not kept, so the partial object is read by the keys of those before it.
			c, _, _ := tape.children(w.doc, f, context.temp_allocator)
			for i := i32(0); i < step.limit; i += 1 {
				k, _, kp := tape.next_child(w.doc, &c, .Group)
				if kp != .Found {
					break
				}
				key := scalar_text(w.doc.doc, k)
				fv, fp := tape.member(w.doc, f, key, .First)
				pv, pp := tape.member(w.r, p, key, .First)
				if agree_step(w, key, fv, pv, fp, pp) {
					agree_on_path(w, fv, pv, steps[1:], grain)
				}
			}
			return
		}
		fc, fp, _ := tape.children(w.doc, f, context.temp_allocator)
		pc, pp, _ := tape.children(w.r, p, context.temp_allocator)
		if !agree_step(w, "children", tape.NO_NODE, tape.NO_NODE, fp, pp) || fp != .Found {
			return
		}
		for i := i32(0); step.limit <= 0 || node.kind == .Object || i < step.limit; i += 1 {
			fk, fv, fnp := tape.next_child(w.doc, &fc, w.dups)
			pk, pv, pnp := tape.next_child(w.r, &pc, w.dups)
			if !agree_step(w, "next child", fv, pv, fnp, pnp) || !same_node(w, fk, pk) || fnp != .Found {
				break
			}
			agree_on_path(w, fv, pv, steps[1:], grain)
		}
	case tape.Slice:
		count, lp, _ := tape.length(w.doc, f, context.temp_allocator)
		if w.doc.doc.nodes[f].kind != .Array || lp != .Found {
			_, pp := tape.element(w.r, p, 0)
			agree_step(w, step, tape.NO_NODE, tape.NO_NODE, .Wrong_Kind if w.doc.doc.nodes[f].kind != .Null else .Missing, pp)
			return
		}
		lo := int(step.lo)
		from := max(lo + count if lo < 0 else lo, 0)
		hi := int(step.hi.? or_else i32(count))
		to := hi + count if hi < 0 else min(hi, count)
		if step.limit > 0 {
			to = min(to, from + int(step.limit))
		}
		for i in from ..< to {
			fv, fp := tape.element(w.doc, f, i)
			pv, pp := tape.element(w.r, p, i)
			if agree_step(w, step, fv, pv, fp, pp) {
				agree_on_path(w, fv, pv, steps[1:], grain)
			}
		}
	}
}

// Checks what `grain` keeps of the value `f` of the whole document and `p` of the partial one: its kind, and for a
// `.Keys` grain an array's length and an object's keys.
@(private)
agree_grain :: proc(w: ^Agree_Walk, f, p: tape.Node_Index, grain: tape.Grain) {
	if !agree_step(w, grain, f, p, .Found, .Found) || grain != .Keys || w.doc.doc.nodes[f].kind < .Array {
		return
	}
	fn, fl, _ := tape.length(w.doc, f, context.temp_allocator)
	pn, pl, _ := tape.length(w.r, p, context.temp_allocator)
	if fl != pl || fn != pn {
		testing.expectf(w.t, false, "%s scan %v: keys length %v %d, whole %d; %s", w.name, w.paths, pl, pn, fn, render_doc(w.r.doc))
	}
	if w.doc.doc.nodes[f].kind != .Object {
		return
	}
	fc, _, _ := tape.children(w.doc, f, context.temp_allocator)
	pc, pcp, _ := tape.children(w.r, p, context.temp_allocator)
	if !agree_step(w, "keys", tape.NO_NODE, tape.NO_NODE, .Found, pcp) {
		return
	}
	for {
		fk, fv, fnp := tape.next_child(w.doc, &fc, w.dups)
		pk, pv, pnp := tape.next_child(w.r, &pc, w.dups)
		if fnp != .Found {
			agree_step(w, "last key", tape.NO_NODE, tape.NO_NODE, fnp, pnp)
			break
		}
		if !same_node(w, fk, pk) || pnp != .Not_Loaded && !(pnp == .Found && same_node(w, fv, pv)) {
			testing.expectf(w.t, false, "%s scan %v: key %v %v, whole %v; %s", w.name, w.paths, pk, pnp, fk, render_doc(w.r.doc))
			break
		}
	}
}

// Reads around the value `f` of the whole document and `p` of the partial one, and goes on into what both hold.
@(private)
agree_past :: proc(w: ^Agree_Walk, f, p: tape.Node_Index, depth: int) {
	if !agree_read(w, "value", f, p, .Found, .Found) || depth > 64 {
		return
	}
	fn, fl, _ := tape.length(w.doc, f, context.temp_allocator)
	pn, pl, _ := tape.length(w.r, p, context.temp_allocator)
	agree_read(w, "length", tape.NO_NODE, tape.NO_NODE, fl, pl)
	if pl == .Found && fl == .Found {
		if fn != pn {
			testing.expectf(w.t, false, "%s scan %v: length %d, whole %d; %s", w.name, w.paths, pn, fn, render_doc(w.r.doc))
		}
	}
	for dups in ([]tape.Duplicates{.Last, .First}) {
		fc, fcp, _ := tape.children(w.doc, f, context.temp_allocator)
		pc, pcp, _ := tape.children(w.r, p, context.temp_allocator)
		if !agree_read(w, "children", tape.NO_NODE, tape.NO_NODE, fcp, pcp) || pcp != .Found {
			continue
		}
		for {
			fk, fv, fnp := tape.next_child(w.doc, &fc, dups)
			pk, pv, pnp := tape.next_child(w.r, &pc, dups)
			// A child the scan did not keep reads as not loaded, and the children past it go on.
			if !agree_read(w, "next child", fv, pv, fnp, pnp) || fnp != .Found {
				break
			}
			testing.expect(w.t, pnp != .Found || same_node(w, fk, pk))
		}
	}
	names := make([dynamic]string, context.temp_allocator)
	append(&names, "zz_missing", "")
	if w.doc.doc.nodes[f].kind == .Object {
		end := f + tape.Node_Index(w.doc.doc.nodes[f].n)
		for k := f + 1; k < end; {
			append(&names, scalar_text(w.doc.doc, k))
			k += 1
			k += tape.Node_Index(w.doc.doc.nodes[k].n) if w.doc.doc.nodes[k].kind > .Plain else 1
		}
	}
	for name, i in names {
		fv, fp := tape.member(w.doc, f, name, w.dups)
		pv, pp := tape.member(w.r, p, name, w.dups)
		if agree_read(w, name, fv, pv, fp, pp) && pp == .Found && i >= 2 {
			agree_past(w, fv, pv, depth + 1)
		}
		// A read under the policy the scan did not take.
		other := tape.Duplicates.First if w.dups == .Last else .Last
		fv, fp = tape.member(w.doc, f, name, other)
		pv, pp = tape.member(w.r, p, name, other)
		agree_read(w, name, fv, pv, fp, pp)
	}
	count := fn if fl == .Found else 0
	for i in -count - 2 ..= count + 1 {
		if i >= 64 && i < count - 2 || i <= -64 && i > -count + 2 {
			continue
		}
		fv, fp := tape.element(w.doc, f, i)
		pv, pp := tape.element(w.r, p, i)
		if agree_read(w, tape.Index(i), fv, pv, fp, pp) && pp == .Found && i >= 0 && w.doc.doc.nodes[f].kind == .Array {
			agree_past(w, fv, pv, depth + 1)
		}
	}
}

// Whether the value a find reaches by each of `names` from the root of `src`, an object, is the member the readers take
// from the build of `src`, under every policy for repeated keys a path reads by: the same member, or none in both. A
// format whose keys differ in kind reads a name that two kinds of key spell by the same policy in both.
find_agrees_with_member :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, src: []u8, names: []string, name: string) -> bool {
	for dups in ([]tape.Duplicates{.Default, .First, .Last}) {
		opts := tape.Options {
			dups = dups,
		}
		doc, err := reads.build(f, src, opts, context.allocator)
		defer tape.destroy(&doc)
		if err != nil {
			continue
		}
		index := tape.Doc_Index {
			allocator = context.allocator,
		}
		defer tape.destroy_index(&index)
		reader := tape.Reader{&doc, &index}
		// A length first, which has the index keep whether the object repeats a key.
		_, _, _ = tape.length(reader, tape.ROOT, context.allocator)
		for key in names {
			a, ferr := reads.find(f, src, []tape.Step{tape.Name(key)}, {}, opts, context.allocator)
			at, p := tape.member(reader, tape.ROOT, key, dups)
			ok := ferr == nil && a.outcome == p
			if ok && p == .Found {
				ok = a.lo + u64(a.head) == doc.nodes[at].lo
			}
			if !testing.expectf(t, ok, "%s %v %v name %q: find %v %v, member %v at %v", name, f.name, dups, key, a, ferr, p, at) {
				return false
			}
		}
	}
	return true
}
