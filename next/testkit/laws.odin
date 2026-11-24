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

// An answer of a path read: the value found, or the outcome, with the node the readers stopped at.
Ref_Answer :: struct {
	node:    tape.Node_Index,
	outcome: tape.Presence,
}

// The answers of `steps` over the whole document `doc` under `dups`, in document order, by its readers and the step
// rules: null and a child a container lacks read as missing past the last `All` and as the wrong kind before it, an
// `All` takes an object's members as written, and a `Name` under `.Group` each member of its key.
reference_answers :: proc(doc: ^tape.Document, steps: []tape.Step, dups: tape.Duplicates, out: ^[dynamic]Ref_Answer) {
	alls_end := u64(0)
	for step, i in steps {
		if _, all := step.(tape.All); all {
			alls_end = u64(i + 1)
		}
	}
	reference_from(doc, tape.ROOT, steps, 0, alls_end, dups, out)
}

@(private)
reference_from :: proc(doc: ^tape.Document, at: tape.Node_Index, steps: []tape.Step, taken, alls_end: u64, dups: tape.Duplicates, out: ^[dynamic]Ref_Answer) {
	if taken == u64(len(steps)) {
		append(out, Ref_Answer{at, .Found})
		return
	}
	r := tape.Reader{doc, nil}
	node := doc.nodes[at]
	step := steps[taken]
	if !tape.step_enters(step, node.kind) {
		append(out, Ref_Answer{at, tape.path_refused(taken, alls_end) if node.kind == .Null else .Wrong_Kind})
		return
	}
	missing := Ref_Answer{at, tape.path_refused(taken + 1, alls_end)}
	switch s in step {
	case tape.Name:
		if dups == .Group {
			c, p := tape.named(r, at, string(s))
			if p != .Found {
				append(out, missing)
				return
			}
			for {
				_, value, vp := tape.next_child(r, &c)
				if vp != .Found {
					return
				}
				reference_from(doc, value, steps, taken + 1, alls_end, dups, out)
			}
		}
		value, p := tape.member(r, at, string(s), dups)
		if p != .Found {
			append(out, missing)
			return
		}
		reference_from(doc, value, steps, taken + 1, alls_end, dups, out)
	case tape.Index:
		value, p := tape.element(r, at, int(s))
		if p != .Found {
			append(out, missing)
			return
		}
		reference_from(doc, value, steps, taken + 1, alls_end, dups, out)
	case tape.All:
		c, _, _ := tape.children(r, at, context.temp_allocator)
		for i := u64(0); ; i += 1 {
			_, value, p := tape.next_child(r, &c, .Group)
			if p != .Found || !tape.all_takes(s.limit, i, node.kind == .Object, dups) {
				return
			}
			reference_from(doc, value, steps, taken + 1, alls_end, dups, out)
		}
	case tape.Slice:
		count, _, _ := tape.length(r, at, context.temp_allocator)
		for e in 0 ..< u64(count) {
			if tape.slice_takes(s, e, u64(count)) {
				value, _ := tape.element(r, at, int(e))
				reference_from(doc, value, steps, taken + 1, alls_end, dups, out)
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
	whole := make(map[Key]tape.Node_Index, context.temp_allocator)
	for node, i in doc.nodes {
		whole[{node.lo, node.role, node.kind}] = tape.Node_Index(i)
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
		at, ok := whole[{node.lo, node.role, node.kind}]
		testing.expectf(t, ok && has(doc.facts, at, f), "%s: scan fact %v on %v is not the build's", name, f, node, loc = loc)
	}
	if .Stopped in r.flags {
		return
	}
	kept := make(map[tape.Node_Index]tape.Node_Index, context.temp_allocator)
	for node, i in r.nodes {
		if at, ok := whole[{node.lo, node.role, node.kind}]; ok {
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
// text's end, and gives the result of the read that ended. The windows are of a copy of the text whose bytes before
// `keep` are overwritten with a byte no text holds, so a read that reads before its window reads no byte of the text.
// The copy, which a document may hold, is the caller's to free.
feed :: proc(r: Piece_Run, p: ^tape.Pieces, read: proc(window: []u8, r: Piece_Run, opts: tape.Options) -> bool) -> (text: []u8) {
	opts := r.opts
	opts.pieces = p
	p.allocator = context.allocator
	text = slice.clone(r.src)
	dropped: u64
	for i := 0; ; i += 1 {
		end := r.cuts[i] if i < len(r.cuts) else len(r.src)
		p.from, p.last = p.keep, i >= len(r.cuts)
		assert(p.keep >= dropped, "a read needs bytes its last read let go")
		slice.fill(text[dropped:p.keep], 0xFF)
		dropped = p.keep
		if !read(text[p.keep:end], r, opts) || !p.more || p.last {
			return
		}
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

// The reads of `src` in pieces cut at `cuts` give what the whole reads give: the verdict and fault, the document, the
// answer of each path and the scan of them, and the records of `src` framed as `framing`.
pieces_agree :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, cuts: []int, paths: [][]tape.Step, name: string, limits: []int = nil, framing := tape.Framing.Lines) -> bool {
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
		return records_pieces_agree(t, r, framing, paths, nil, name)
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
	return records_pieces_agree(t, r, framing, paths, &d, name)
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
		append(&got.docs, ..docs[:n])
	}
	append(&got.records, ..out[:n])
	return n
}

// Reads the records of `run.src` framed as `framing` as `how` says, the whole text at once, or with `pieces` a window
// at a time, each from the last batch's `keep` to the next cut, of a copy whose bytes before `keep` are overwritten as
// `feed` overwrites them.
@(private)
records_read :: proc(run: Piece_Run, framing: tape.Framing, how: Records_Read, pieces: bool) -> (got: Records_Got) {
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
	r, e := run.reads.records(run.f, text[:end], framing, opts, context.allocator)
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
		slice.fill(text[dropped:p.keep], 0xFF)
		dropped = p.keep
		if err := tape.records_window(r, text[p.keep:end]); err != nil {
			got.err = err
			return
		}
	}
	got.err = r.err
	return
}

// Whether the records of a text framed as `framing` read a window at a time are the whole text's, with the same answers
// and documents: judged, with each path's answer and with the documents of `demand`, nil when the paths make none. The
// framing of the windows reads no byte twice.
records_pieces_agree :: proc(t: ^testing.T, run: Piece_Run, framing: tape.Framing, paths: [][]tape.Step, demand: ^tape.Demand, name: string) -> bool {
	reads := make([dynamic]Records_Read, context.temp_allocator)
	append(&reads, Records_Read{})
	for path in paths {
		append(&reads, Records_Read{how = .Find, path = path}, Records_Read{how = .Find, path = path, read = {stop_early = true}})
	}
	if demand != nil {
		append(&reads, Records_Read{how = .Scan, demand = demand}, Records_Read{how = .Scan, demand = demand, read = {stop_early = true}})
	}
	for how in reads {
		whole := records_read(run, framing, how, false)
		defer records_got_free(&whole)
		got := records_read(run, framing, how, true)
		defer records_got_free(&got)
		ok := got.err == whole.err && len(got.records) == len(whole.records) && slice.equal(got.answers[:], whole.answers[:])
		for k := 0; ok && k < len(got.records); k += 1 {
			a, b := got.records[k], whole.records[k]
			ok = a.index == b.index && a.lo == b.lo && a.hi == b.hi && a.err == b.err && a.key == b.key
			ok = ok && (how.how != .Scan || same_documents(got.docs[k], whole.docs[k]))
		}
		if !testing.expectf(t, ok, "%s %v cut %v: records %v %v: %v records, %v, whole %v records, %v", name, run.f.name, run.cuts, how.how, how.path, len(got.records), got.err, len(whole.records), whole.err) {
			return false
		}
	}
	return true
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
	got := records_read(run, alone.framing, how, pieces)
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
	sets := make([dynamic][][]tape.Step, context.temp_allocator)
	for i in 0 ..< len(paths) {
		append(&sets, paths[i:][:1])
		if i + 1 < len(paths) {
			append(&sets, paths[i:][:2])
		}
	}
	append(&sets, paths[:])
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

				if root, p := tape.root(w.r); p == .Found {
					agree_past(&w, tape.ROOT, root, 0)
				}
			}
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
