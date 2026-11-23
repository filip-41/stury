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
	end := at + tape.Node_Index(node.n)
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
		k := at + 1
		for i := u64(0); k < end; i += 1 {
			value := k
			if node.kind == .Object {
				value = k + 1
			}
			if !tape.all_takes(s.limit, i, node.kind == .Object, dups) {
				return
			}
			reference_from(doc, value, steps, taken + 1, alls_end, dups, out)
			k = value + tape.Node_Index(doc.nodes[value].n) if doc.nodes[value].kind > .Plain else value + 1
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
	Key :: struct {
		lo:   u64,
		role: tape.Role,
	}
	whole := make(map[Key]tape.Node_Index, context.temp_allocator)
	for node, i in doc.nodes {
		whole[{node.lo, node.role}] = tape.Node_Index(i)
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
		at, ok := whole[{node.lo, node.role}]
		testing.expectf(t, ok && has(doc.facts, at, f), "%s: scan fact %v on %v is not the build's", name, f, node, loc = loc)
	}
	if .Stopped in r.flags {
		return
	}
	kept := make(map[tape.Node_Index]tape.Node_Index, context.temp_allocator)
	for node, i in r.nodes {
		if at, ok := whole[{node.lo, node.role}]; ok {
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
// answer of each path and the scan of them.
pieces_agree :: proc(t: ^testing.T, reads: ^tape.Reads, f: ^tape.Format, src: []u8, opts: tape.Options, cuts: []int, paths: [][]tape.Step, name: string, limits: []int = nil) -> bool {
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
		return true
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
		if node.role != .Key || len(keys) == 12 {
			continue
		}
		key := key_text(doc, tape.Node_Index(i))
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
			end := at + tape.Node_Index(node.n)
			member := at + 1
			for next := member; last && next < end; {
				member = next
				next += tape.Node_Index(doc.nodes[next].n) if doc.nodes[next].kind > .Plain else 1
				if node.kind == .Object {
					next += tape.Node_Index(doc.nodes[next].n) if doc.nodes[next].kind > .Plain else 1
				}
			}
			if node.kind == .Object {
				append(&down, tape.Step(tape.Name(key_text(doc, member))))
				at = member + 1
			} else {
				append(&down, tape.Step(tape.Index(-1 if last else 0)))
				at = member
			}
			if len(down) >= 3 {
				add(&out, ..down[:])
				add(&out, ..slice.concatenate([][]tape.Step{{A}, down[1:]}, context.temp_allocator))
			}
		}
	}
	return out[:]
}

key_text :: proc(doc: ^tape.Document, at: tape.Node_Index) -> string {
	buf := make([]u8, doc.nodes[at].n, context.temp_allocator)
	text, _ := tape.node_text(doc, at, buf)
	return strings.clone(text, context.temp_allocator)
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
			end := f + tape.Node_Index(node.n)
			for k, i := f + 1, i32(0); k < end && i < step.limit; i += 1 {
				key := key_text(w.doc.doc, k)
				fv, fp := tape.member(w.doc, f, key, .First)
				pv, pp := tape.member(w.r, p, key, .First)
				if agree_step(w, key, fv, pv, fp, pp) {
					agree_on_path(w, fv, pv, steps[1:], grain)
				}
				k += 1
				k += tape.Node_Index(w.doc.doc.nodes[k].n) if w.doc.doc.nodes[k].kind > .Plain else 1
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
			append(&names, key_text(w.doc.doc, k))
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
