package json_tests

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// Reads of a text in pieces, each window starting at the read's `keep`, against reads of the whole text.

@(private = "file")
Piece_Run :: struct {
	src:   []u8,
	spec:  json.Spec,
	opts:  tape.Options,
	cuts:  []int, // where each window but the last ends
}

// Feeds `r.src` to `read` one window at a time, each from the last read's `keep` to the next cut, the last to the
// text's end, and gives the result of the read that ended. The windows are of a copy of the text whose bytes before
// `keep` are overwritten with a byte no text holds, so a read that reads before its window reads no byte of the text.
// The copy, which a document may hold, is the caller's to free.
@(private = "file")
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

@(private = "file")
same_docs :: proc(a, b: tape.Document) -> bool {
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
@(private = "file")
agree_in_pieces :: proc(t: ^testing.T, src: []u8, spec: json.Spec, opts: tape.Options, cuts: []int, paths: [][]tape.Step, name: string) -> bool {
	r := Piece_Run{src, spec, opts, cuts}
	whole_err := json.validate(src, spec, opts)
	{
		p: tape.Pieces
		defer tape.destroy(&p)
		got: tape.Error
		context.user_ptr = &got
		window := feed(r, &p, proc(window: []u8, r: Piece_Run, opts: tape.Options) -> bool {
			err := json.validate(window, r.spec, opts)
			(^tape.Error)(context.user_ptr)^ = err
			return err == nil
		})
		defer delete(window)
		if !testing.expectf(t, got == whole_err && !p.more, "%s %v cut %v: validate %v, whole %v", name, spec, cuts, got, whole_err) {
			return false
		}
	}
	whole, berr := json.build(src, spec, opts)
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
			doc, err := json.build(window, r.spec, opts)
			tape.destroy(&g.doc)
			g.doc, g.err = doc, err
			return err == nil
		})
		defer delete(window)
		if !testing.expectf(t, got.err == berr && same_docs(got.doc, whole), "%s %v cut %v: build %v, whole %v", name, spec, cuts, got.err, berr) {
			return false
		}
	}
	for path in paths {
		for stop in ([]bool{false, true}) {
			read := tape.Read_Options{stop_early = stop}
			want, ferr := json.find(src, path, spec, read, opts)
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
				g.a, g.err = json.find(window, g.path, r.spec, g.read, opts)
				return g.err == nil
			})
			defer delete(window)
			text := string(p.text)
			ok := got.err == ferr && got.a == want && (want.outcome != .Found || text == string(src[want.lo:want.hi]))
			tape.destroy(&p)
			if !testing.expectf(t, ok, "%s %v cut %v: find %v stop %v: %v %v, whole %v %v", name, spec, cuts, path, stop, got.a, got.err, want, ferr) {
				return false
			}
		}
	}
	d, derr := tape.demand_of(paths, nil, nil, spec != .Json)
	defer tape.destroy(&d)
	if derr != nil {
		return true
	}
	for stop in ([]bool{false, true}) {
		read := tape.Read_Options{stop_early = stop}
		want, serr := json.scan(src, &d, spec, read, opts)
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
			doc, err := json.scan(window, g.d, r.spec, g.read, opts)
			tape.destroy(&g.doc)
			g.doc, g.err = doc, err
			return err == nil
		})
		defer delete(window)
		ok := got.err == serr && same_docs(got.doc, want)
		tape.destroy(&got.doc)
		tape.destroy(&p)
		if !testing.expectf(t, ok, "%s %v cut %v: scan stop %v: %v, whole %v", name, spec, cuts, stop, got.err, serr) {
			return false
		}
	}
	return true
}

// Paths that reach into most texts: the root, its first and last children, every child, and the first key's value.
@(private = "file")
paths_into :: proc(doc: ^tape.Document) -> [][]tape.Step {
	paths := make([dynamic][]tape.Step, context.temp_allocator)
	add :: proc(paths: ^[dynamic][]tape.Step, steps: ..tape.Step) {
		append(paths, slice.clone(steps, context.temp_allocator))
	}
	add(&paths)
	add(&paths, tape.Index(0))
	add(&paths, tape.Index(-1))
	add(&paths, tape.All{})
	add(&paths, tape.Index(-2), tape.Index(0))
	if len(doc.nodes) > 1 && doc.nodes[0].kind == .Object && doc.nodes[1].role == .Key {
		buf: [256]u8
		if name, ok := tape.node_text(doc, doc.nodes[1], buf[:]); ok {
			name := tape.Name(fmt.tprint(name))
			add(&paths, name)
			add(&paths, tape.All{}, name)
		}
	}
	return paths[:]
}

@(private = "file")
Corpus :: struct {
	texts, reads: int,
}

// The size of a text from which the splits are random, as each split reads it whole a few dozen times.
@(private = "file")
SAMPLED_FROM :: 64 << 10

// Splits `src` in two at some random bytes and in three at some random pairs, and checks each split's reads.
@(private = "file")
agree_over_sampled_splits :: proc(t: ^testing.T, src: []u8, spec: json.Spec, opts: tape.Options, name: string, c: ^Corpus, paths: [][]tape.Step) {
	for _ in 0 ..< testkit.rounds(2) {
		cuts := [1]int{rand.int_max(len(src) + 1)}
		c.reads += 1
		if !agree_in_pieces(t, src, spec, opts, cuts[:], paths, name) {
			return
		}
	}
	for _ in 0 ..< testkit.rounds(1) {
		i := rand.int_max(len(src))
		cuts := [2]int{i, i + 1 + rand.int_max(len(src) - i)}
		c.reads += 1
		if !agree_in_pieces(t, src, spec, opts, cuts[:], paths, name) {
			return
		}
	}
}

// Splits `src` in two at every byte, or at 256 of them, and in three at a sample of byte pairs, and checks each split's
// reads.
@(private = "file")
agree_over_splits :: proc(t: ^testing.T, src: []u8, spec: json.Spec, opts: tape.Options, name: string, c: ^Corpus) {
	defer free_all(context.temp_allocator)
	doc, err := json.build(src, spec, opts)
	defer tape.destroy(&doc)
	paths: [][]tape.Step
	if err == nil {
		paths = paths_into(&doc)
	}
	c.texts += 1
	if len(src) > SAMPLED_FROM {
		agree_over_sampled_splits(t, src, spec, opts, name, c, paths)
		return
	}
	// A long text is split at a sample of its bytes, as each split reads it whole a few dozen times.
	step := max(1, len(src) / 256)
	for k := 0; k <= len(src); k += step {
		cuts := [1]int{k}
		c.reads += 1
		if !agree_in_pieces(t, src, spec, opts, cuts[:], paths, name) {
			return
		}
	}
	if len(src) < 8 {
		return
	}
	for k in 0 ..< 16 {
		i := (k * 7919) % len(src)
		j := i + 1 + (k * 104729) % (len(src) - i)
		cuts := [2]int{i, j}
		c.reads += 1
		if !agree_in_pieces(t, src, spec, opts, cuts[:], paths, name) {
			return
		}
	}
}

@(private = "file")
FIXTURES_DIR :: #directory + "../../../bench/fixtures/corpus/"

@(private = "file")
FIXTURES := [?]string{"canada.json", "citm_catalog.json", "twitter.json"}

// Over every text of the suites, read whole and in pieces split at every byte, strict and tolerant, and over the
// fixture texts split at random bytes: the same verdict and fault, document, answers and scans.
@(test)
pieces_agree_with_whole_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	c: Corpus
	tolerant := tape.Options{tolerate = {.Invalid_Utf8, .Non_Finite, .Lone_Surrogate}}
	for f in #load_directory("conformance/JSONTestSuite/test_parsing") {
		agree_over_splits(t, f.data, .Json, {}, f.name, &c)
		agree_over_splits(t, f.data, .Json, tolerant, f.name, &c)
	}
	json5 := [?][]runtime.Load_Directory_File {
		#load_directory("conformance/json5-tests/arrays"),
		#load_directory("conformance/json5-tests/comments"),
		#load_directory("conformance/json5-tests/misc"),
		#load_directory("conformance/json5-tests/new-lines"),
		#load_directory("conformance/json5-tests/numbers"),
		#load_directory("conformance/json5-tests/objects"),
		#load_directory("conformance/json5-tests/strings"),
	}
	for dir in json5 {
		for f in dir {
			agree_over_splits(t, f.data, .Json5, {}, f.name, &c)
			agree_over_splits(t, f.data, .Jsonc, {}, f.name, &c)
			agree_over_splits(t, f.data, .Json5, tolerant, f.name, &c)
		}
	}
	testing.expectf(t, c.texts > 500, "%d texts, %d splits", c.texts, c.reads)
	sampled := c.texts
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x91ece5)
	// The fixture texts, where a checkout has them, are larger than the suites' and are split at random bytes.
	for name in FIXTURES {
		src, err := os.read_entire_file(fmt.tprintf("%s%s", FIXTURES_DIR, name), context.allocator)
		if err != nil {
			continue
		}
		agree_over_splits(t, src, .Json, {}, name, &c)
		if name == "twitter.json" {
			agree_over_splits(t, src, .Json5, {}, name, &c)
		}
		delete(src)
	}
	log.infof("%d suite texts, %d fixture texts, %d splits", sampled, c.texts - sampled, c.reads)
	free_all(context.temp_allocator)
}

@(private = "file")
Cut_Case :: struct {
	src:   string,
	kinds: []tape.Kind, // the document's nodes
	open:  []tape.Step,
}

// A build of a text that ends inside its root value gives the values so far, its open containers closed at the cut,
// and the path to the value it ended inside. A scalar cut short and a key with no value are left out.
@(test)
builds_of_cut_texts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	cases := []Cut_Case {
		{`{"a": [1, 2, {"b": "hel`, {.Object, .String, .Array, .Number, .Number, .Object}, {N("a"), I(2), N("b")}},
		{`[1, 2, 3`, {.Array, .Number, .Number}, {}},
		{`[1, 2, 3,`, {.Array, .Number, .Number, .Number}, {}},
		{`{"a": tr`, {.Object}, {N("a")}},
		{`{"a"`, {.Object}, {N("a")}},
		{`"abc`, {}, {}},
		{`12`, {}, {}},
		{`{"a": {"b": 1}, "c": [true, nul`, {.Object, .String, .Object, .String, .Number, .String, .Array, .True}, {N("c")}},
		{`[[[`, {.Array, .Array, .Array}, {I(0), I(0)}},
		{`{"ka": [{"x": 1`, {.Object, .String, .Array, .Object}, {N("ka"), I(0), N("x")}},
		{`[{"a":1},{"a":2},{"a":3`, {.Array, .Object, .String, .Number, .Object, .String, .Number, .Object}, {I(2), N("a")}},
		{`{"a": 1 `, {.Object, .String, .Number}, {}},
	}
	for c in cases {
		p := tape.Pieces{so_far = true, allocator = context.allocator}
		doc, err := json.build(transmute([]u8)c.src, .Json, {pieces = &p})
		kinds := make([dynamic]tape.Kind, context.temp_allocator)
		for n in doc.nodes {
			append(&kinds, n.kind)
		}
		ok := err == nil && p.more && p.at == u64(len(c.src)) && .Cut in doc.flags && slice.equal(kinds[:], c.kinds) && slice.equal(p.open, c.open)
		if ok && len(doc.nodes) > 0 {
			// Every node lies inside the root's subtree, as a closed document's do.
			ok = int(doc.nodes[0].n) == len(doc.nodes) || doc.nodes[0].kind <= .Plain
		}
		testing.expectf(t, ok, "%q: %v %v at %d open %v, nodes %v", c.src, err, p.more, p.at, p.open, kinds[:])
		tape.destroy(&doc)
		tape.destroy(&p)
	}
	free_all(context.temp_allocator)
}

// A scan of a text that ends inside its root value gives the answers so far, its open containers closed at the cut and
// marked partial where it kept only some of their children, and holds every byte its document reads.
@(test)
scans_of_cut_texts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	cases := []struct {
		src:           string,
		paths:         [][]tape.Step,
		answers, doc: string,
	} {
		{`{"a": 1, "b": [true, "x`, {{N("a")}, {N("b"), tape.All{}}}, `0=1 1=true`, `{"a":1,"b":[true]}`},
		{`{"a": {"b": "hel`, {{N("a"), N("b")}}, ``, `{"a":{}}`},
		{`[{"id": 1}, {"id": 2}, {"id"`, {{tape.All{}, N("id")}}, `0=1 0=2`, `[{"id":1},{"id":2},{}]`},
		{`{"k": [1, 2, 3], "z": nu`, {{N("k"), tape.Index(-1)}}, `0=3`, `{"k":~[3]}`},
		{`{"k": [1, 2, 3, 4`, {{N("k"), tape.Index(0)}}, `0=1`, `{"k":~[1]}`},
	}
	for c in cases {
		d, derr := tape.demand_of(c.paths)
		defer tape.destroy(&d)
		p := tape.Pieces{so_far = true, allocator = context.allocator}
		text := slice.clone(transmute([]u8)c.src)
		doc, err := json.scan(text, &d, .Json, {}, {pieces = &p})
		// The document holds every byte it reads, so the text may go.
		slice.fill(text, 0xFF)
		delete(text)
		answers, kept := render_answers(&doc), render_doc(&doc)
		ok := derr == nil && err == nil && p.more && doc.flags >= {.Cut, .Held} && answers == c.answers && kept == c.doc
		testing.expectf(t, ok, "%q: %v %v %v: %q, doc %q", c.src, err, p.more, doc.flags, answers, kept)
		tape.destroy(&doc)
		tape.destroy(&p)
	}
	free_all(context.temp_allocator)
}

// A scan of a text in pieces holds the bytes of what it keeps, so a path through a key at the text's start holds no
// window of the text after it, and a container's close is not known in its document.
@(test)
scans_in_pieces_hold_a_bounded_window :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"items": [`)
	for i in 0 ..< 2000 {
		fmt.sbprintf(&b, `%s{{"id": %d, "name": "n%d", "pad": "................"}}`, "," if i > 0 else "", i, i)
	}
	strings.write_string(&b, `]}`)
	src := transmute([]u8)strings.to_string(b)
	paths := [][]tape.Step{{tape.Name("items"), tape.Index(-1), tape.Name("name")}, {tape.Name("items"), tape.Index(0)}}
	d, _ := tape.demand_of(paths)
	defer tape.destroy(&d)
	want, werr := json.scan(src, &d)
	defer tape.destroy(&want)
	p := tape.Pieces{allocator = context.allocator}
	cuts := make([dynamic]int, context.temp_allocator)
	for at := 256; at < len(src); at += 256 {
		append(&cuts, at)
	}
	Got :: struct {
		doc:    tape.Document,
		d:      ^tape.Demand,
		widest: int,
	}
	got := Got{d = &d}
	context.user_ptr = &got
	text := feed({src, .Json, {}, cuts[:]}, &p, proc(window: []u8, r: Piece_Run, opts: tape.Options) -> bool {
		g := (^Got)(context.user_ptr)
		g.widest = max(g.widest, len(window))
		doc, err := json.scan(window, g.d, r.spec, {}, opts)
		tape.destroy(&g.doc)
		g.doc = doc
		return err == nil
	})
	defer delete(text)
	defer tape.destroy(&got.doc)
	defer tape.destroy(&p)
	testing.expect(t, werr == nil && same_docs(got.doc, want) && .Held in got.doc.flags)
	testing.expectf(t, got.widest <= 512, "a window of %d bytes", got.widest)
	testing.expect_value(t, render_answers(&got.doc), render_answers(&want))
	_, closed := got.doc.format.close_end(&got.doc, 1)
	testing.expect(t, !closed)
	free_all(context.temp_allocator)
}

@(private = "file")
Read_Kind :: enum {
	Validate,
	Build,
	Find,
	Scan,
}

@(private = "file")
Budgeted :: struct {
	kind:   Read_Kind,
	path:   []tape.Step,
	demand: ^tape.Demand,
	err:    tape.Error,
}

// Reads `src` in pieces cut at `cuts` as `kind` under `memory` bytes of `Budget.memory`, and gives the error of the
// read that ended.
@(private = "file")
read_in_pieces_within :: proc(src: []u8, cuts: []int, kind: Read_Kind, memory: u64) -> tape.Error {
	path := []tape.Step{tape.Index(0)}
	demand, derr := tape.demand_of([][]tape.Step{path})
	defer tape.destroy_demand(&demand)
	if derr != nil {
		return derr
	}
	got := Budgeted{kind, path, &demand, nil}
	context.user_ptr = &got
	p: tape.Pieces
	defer tape.destroy(&p)
	window := feed(Piece_Run{src, .Json, {budget = {memory = memory}}, cuts}, &p, proc(window: []u8, r: Piece_Run, opts: tape.Options) -> bool {
		g := (^Budgeted)(context.user_ptr)
		switch g.kind {
		case .Validate:
			g.err = json.validate(window, r.spec, opts)
		case .Build:
			doc, err := json.build(window, r.spec, opts)
			tape.destroy(&doc)
			g.err = err
		case .Find:
			_, g.err = json.find(window, g.path, r.spec, {}, opts)
		case .Scan:
			doc, err := json.scan(window, g.demand, r.spec, {}, opts)
			tape.destroy(&doc)
			g.err = err
		}
		return g.err == nil
	})
	defer delete(window)
	return got.err
}

// A memory budget counts one read from its first window to its last, with the lists the read keeps between windows: a
// deep text in windows that each fit is refused once all of them do not.
@(test)
pieces_hold_one_memory_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	DEPTH, WINDOW :: 3000, 100
	src := make([]u8, 2 * DEPTH, context.temp_allocator)
	for i in 0 ..< DEPTH {
		src[i], src[DEPTH + i] = '[', ']'
	}
	cuts := make([]int, 2 * DEPTH / WINDOW - 1, context.temp_allocator)
	for &cut, i in cuts {
		cut = (i + 1) * WINDOW
	}
	for kind in Read_Kind {
		err := read_in_pieces_within(src, cuts, kind, 64 << 10)
		x, exceeded := err.(tape.Exceeded)
		testing.expectf(t, exceeded && x.kind == .Memory, "%v within 64 KiB: %v", kind, err)
		err = read_in_pieces_within(src, cuts, kind, 64 << 20)
		testing.expectf(t, err == nil, "%v within 64 MiB: %v", kind, err)
	}
	free_all(context.temp_allocator)
}

// A window must hold the bytes from the read's `keep` to where the last one ended.
@(test)
pieces_refuse_a_window_with_a_gap :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`{"a": [1, 2, 3], "b": "x"}`)
	p := tape.Pieces{allocator = context.allocator}
	defer tape.destroy(&p)
	err := json.validate(src[:10], .Json, {pieces = &p})
	testing.expect(t, err == nil && p.more && p.at == 10)
	keep := p.keep
	p.from = keep + 1
	err = json.validate(src[keep + 1:], .Json, {pieces = &p})
	_, gap := err.(tape.Piece_Gap)
	testing.expectf(t, gap, "a window past keep: %v", err)
	p.from = keep
	err = json.validate(src[keep:9], .Json, {pieces = &p})
	_, gap = err.(tape.Piece_Gap)
	testing.expectf(t, gap, "a window short of at: %v", err)
	p.from, p.last = keep, true
	testing.expect(t, json.validate(src[keep:], .Json, {pieces = &p}) == nil && !p.more)
}

// A token far longer than a window is read on in each window from where the last stopped. A validate whose windows
// start at its `keep` reads each byte about once, with the bytes before the window overwritten by `poison`, which the
// grammar refuses where they were, and the reads in 1 KiB pieces give what the whole reads give.
@(private = "file")
long_token_agrees :: proc(t: ^testing.T, src: []u8, spec: json.Spec, paths: [][]tape.Step, poison: u8, name: string) {
	PIECE :: 1024
	err, read := validate_in_windows(src, spec, PIECE, poison)
	testing.expectf(t, err == nil && read <= 4 * len(src), "%s %v: validate %v, %d bytes read of %d", name, spec, err, read, len(src))
	p := tape.Pieces{allocator = context.allocator}
	cuts := make([dynamic]int, 0, len(src) / PIECE)
	defer delete(cuts)
	for k := PIECE; k < len(src); k += PIECE {
		append(&cuts, k)
	}
	r := Piece_Run{src, spec, {}, cuts[:]}
	Got :: struct {
		doc:    tape.Document,
		answer: tape.Span_Answer,
		err:    tape.Error,
		path:   []tape.Step,
		d:      ^tape.Demand,
	}
	whole, werr := json.build(src, spec, {})
	got: Got
	context.user_ptr = &got
	window := feed(r, &p, proc(window: []u8, r: Piece_Run, opts: tape.Options) -> bool {
		g := (^Got)(context.user_ptr)
		tape.destroy(&g.doc)
		g.doc, g.err = json.build(window, r.spec, opts)
		return g.err == nil
	})
	testing.expectf(t, werr == nil && got.err == nil && same_docs(got.doc, whole), "%s %v: build %v, whole %v", name, spec, got.err, werr)
	tape.destroy(&got.doc)
	tape.destroy(&p)
	tape.destroy(&whole)
	delete(window)
	for path in paths {
		want, ferr := json.find(src, path, spec, {}, {})
		got.path = path
		found := feed(r, &p, proc(window: []u8, r: Piece_Run, opts: tape.Options) -> bool {
			g := (^Got)(context.user_ptr)
			g.answer, g.err = json.find(window, g.path, r.spec, {}, opts)
			return g.err == nil
		})
		defer delete(found)
		ok := ferr == nil && got.err == nil && got.answer == want && want.outcome == .Found && string(p.text) == string(src[want.lo:want.hi])
		testing.expectf(t, ok, "%s %v: find %v: %v %v, whole %v %v", name, spec, path, got.answer, got.err, want, ferr)
		tape.destroy(&p)
	}
	d, derr := tape.demand_of(paths, nil, nil, spec != .Json)
	defer tape.destroy(&d)
	want, serr := json.scan(src, &d, spec, {}, {})
	defer tape.destroy(&want)
	got.d = &d
	scanned := feed(r, &p, proc(window: []u8, r: Piece_Run, opts: tape.Options) -> bool {
		g := (^Got)(context.user_ptr)
		tape.destroy(&g.doc)
		g.doc, g.err = json.scan(window, g.d, r.spec, {}, opts)
		return g.err == nil
	})
	defer delete(scanned)
	ok := derr == nil && serr == nil && got.err == nil && same_docs(got.doc, want)
	testing.expectf(t, ok, "%s %v: scan %v, whole %v", name, spec, got.err, serr)
	tape.destroy(&got.doc)
	tape.destroy(&p)
}

// The bytes of a long string, fewer under a sanitizer, whose shadow memory a 64 MiB text would take past the tests'
// memory cap. A read that went back over the string per window would pass its bound at either size.
@(private = "file")
LONG :: 4 << 20 when ODIN_SANITIZER_FLAGS != {} else 64 << 20

// `src` with `body` repeated to `n` bytes in place of its `*`.
@(private = "file")
long_text :: proc(src, body: string, n: int) -> []u8 {
	k := strings.index_byte(src, '*')
	out := make([dynamic]u8, 0, len(src) + n + len(body))
	append(&out, src[:k])
	for len(out) - k < n {
		append(&out, body)
	}
	append(&out, src[k + 1:])
	return out[:]
}

// A `LONG` string, with its escapes and UTF-8 sequences at every place a window ends, and a long key.
@(test)
pieces_read_a_long_json_string_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := long_text(`{"s": "*", "n": 1}`, `abc\néé€😀😀\\\"xy/ `, LONG)
	long_token_agrees(t, src, .Json, {{tape.Name("s")}}, '\n', "string")
	delete(src)
	key := strings.repeat("k", 1 << 20)
	defer delete(key)
	src = long_text(`{"*": [1]}`, key, len(key))
	long_token_agrees(t, src, .Json, {{tape.Name(key), tape.Index(0)}}, '\n', "key")
	delete(src)
}

// A `LONG` JSON5 string, with JSON5's escapes as well, a line continuation's CR LF among them, and a long key.
@(test)
pieces_read_a_long_json5_string_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := long_text(`{s: '*', n: 1,}`, "abc\\x41\\0z\\'\"é€😀\\ud83d\\ude00\\\\\\\r\n\\\nxy ", LONG)
	long_token_agrees(t, src, .Json5, {{tape.Name("s")}}, '\n', "string")
	delete(src)
	key := strings.repeat("k", 1 << 20)
	defer delete(key)
	src = long_text(`{'*': [1]}`, key, len(key))
	long_token_agrees(t, src, .Json5, {{tape.Name(key), tape.Index(0)}}, '\n', "key")
	delete(src)
}

// Numbers of a few MiB of digits, with a fraction and an exponent, and JSON5's forms.
@(test)
pieces_read_a_long_number_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	D :: "1234567890"
	M :: 1 << 20
	digits := strings.repeat(D, 4 * M / len(D))
	defer delete(digits)
	src := fmt.aprintf("[1, 1%s, -%s.%se+%s, 0]", digits, digits[:2 * M], digits[:2 * M], digits[:M])
	long_token_agrees(t, transmute([]u8)src, .Json, {{tape.Index(1)}, {tape.Index(2)}}, 'x', "numbers")
	delete(src)
	src = fmt.aprintf("9%s", digits)
	long_token_agrees(t, transmute([]u8)src, .Json, {{}}, 'x', "root number")
	delete(src)
	src = fmt.aprintf("[+%s, 0x%sabcdef, .%se5, 5%s., -%s.%s]", digits[:M], digits[:M], digits[:M], digits[:M], digits[:M], digits[:M])
	paths := [][]tape.Step{{tape.Index(0)}, {tape.Index(1)}, {tape.Index(2)}, {tape.Index(3)}, {tape.Index(4)}}
	long_token_agrees(t, transmute([]u8)src, .Json5, paths, 'x', "numbers")
	delete(src)
}

// A JSON5 unquoted key of 4 MiB, with `\u` escapes and UTF-8 letters at every place a window ends.
@(test)
pieces_read_a_long_json5_identifier_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: (4 << 20) / 13
	key := strings.repeat(`kÉ\u0041_$9z`, N)
	defer delete(key)
	name := strings.repeat(`kÉA_$9z`, N)
	defer delete(name)
	src := long_text(`{*: [1], b: 2}`, key, len(key))
	long_token_agrees(t, src, .Json5, {{tape.Name(name), tape.Index(0)}, {tape.Name("b")}}, '#', "identifier")
	delete(src)
}

// Runs of comments far longer than a window where a value, a key and a colon must start, past a value, with the run's
// comma in it and before it, in empty containers and before and past the root, with block and line comments that hold
// brackets and quotes and every kind of line end. The run past the first member's value is `LONG`, and the rest a 64th
// of it.
@(test)
pieces_read_long_comment_runs_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Each comment holds a run of text, so that the run's comments are few to its bytes.
	X :: "0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz"
	JSONC :: "/* a { [ \"x' é " + X + " */ // } ] \" ' , { " + X + "\n\t/* \r\n" + X + " */\r" +
		"// \"q\" [" + X + "\r\n/**/ // " + X + "\r"
	JSON5 :: JSONC + "\v\f\u00a0\ufeff\u2028// } " + X + "\u2029/* \u2028 " + X + " */\u2029 "
	for spec in ([]json.Spec{.Jsonc, .Json5}) {
		body := JSONC if spec == .Jsonc else JSON5
		short := comment_run_text(body, LONG / 64)
		long := comment_run_text(body, LONG / 2)
		parts := []string{"{", `"a"`, ":", "1", ",", `"b": [`, "2", "],", `"c": {`, `}, "d": [3,`, `4], "e": [`, "]}"}
		b := strings.builder_make(0, 2 * len(long) + (len(parts) + 1) * (len(short) + 16))
		for part, i in parts {
			// Past the first value the run holds its comma.
			if i == 4 {
				fmt.sbprintf(&b, "%s,%s", long, long)
				continue
			}
			fmt.sbprintf(&b, "%s%s", short, part)
		}
		strings.write_string(&b, short)
		delete(short)
		delete(long)
		src := transmute([]u8)strings.to_string(b)
		paths := [][]tape.Step{
			{tape.Name("a")},
			{tape.Name("b"), tape.Index(0)},
			{tape.Name("c")},
			{tape.Name("d"), tape.Index(1)},
			{tape.Name("e")},
		}
		long_token_agrees(t, src, spec, paths, 0x01, "comments")
		strings.builder_destroy(&b)
	}
}

// Runs of white space far longer than a window where a value, a key and a colon must start, past a value, with the
// run's comma in it, past a key with its colon in it, in empty containers and before and past the root, with every
// kind of line end, runs of spaces with none, and in JSON5 runs of its own white space, whose characters windows cut.
// The run past the first member's value is `LONG`, and the rest a 64th of it.
@(test)
pieces_read_long_white_space_runs_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for spec in ([]json.Spec{.Json, .Jsonc, .Json5}) {
		// Past the first two, JSON5's own white space, of odd length so that windows cut its characters, with and
		// without a line end.
		bodies := []string{" \t\r\n  \n\r\n\t", "    ", "\u00a0 \u3000\ufeff\v ", "\u00a0\u2028 \u3000"}
		for body in bodies[:4 if spec == .Json5 else 2] {
			short := comment_run_text(body, LONG / 64)
			long := comment_run_text(body, LONG / 2)
			parts := []string{"{", `"a"`, ":", "1", ",", `"b"`, ": [", "2", "],", `"c": {`, `}, "d": [3,`, `4], "e": [`, "]}"}
			b := strings.builder_make(0, 2 * len(long) + (len(parts) + 1) * (len(short) + 16))
			for part, i in parts {
				// Past the first value the run holds its comma, and past the second key its colon.
				switch i {
				case 4:
					fmt.sbprintf(&b, "%s,%s", long, long)
				case 6:
					fmt.sbprintf(&b, "%s:%s[", short, short)
				case:
					fmt.sbprintf(&b, "%s%s", short, part)
				}
			}
			strings.write_string(&b, short)
			delete(short)
			delete(long)
			src := transmute([]u8)strings.to_string(b)
			paths := [][]tape.Step{
				{tape.Name("a")},
				{tape.Name("b"), tape.Index(0)},
				{tape.Name("c")},
				{tape.Name("d"), tape.Index(1)},
				{tape.Name("e")},
			}
			long_token_agrees(t, src, spec, paths, 0x01, "white space")
			strings.builder_destroy(&b)
		}
	}
}

// The validate of `src` in windows of `piece` bytes past where more bytes are needed, each from its `keep`, with the
// bytes before it overwritten by `poison`, and the bytes the windows read, past `4 * len(src)` once they read more.
@(private = "file")
validate_in_windows :: proc(src: []u8, spec: json.Spec, piece: int, poison: u8) -> (err: tape.Error, read: int) {
	buf := slice.clone(src)
	defer delete(buf)
	p := tape.Pieces{allocator = context.allocator}
	defer tape.destroy(&p)
	dropped: int
	for read <= 4 * len(src) {
		to := min(int(p.at) + piece, len(buf))
		p.from, p.last = p.keep, to == len(buf)
		read += to - int(p.keep)
		if err = json.validate(buf[p.keep:to], spec, {pieces = &p}); err != nil || !p.more {
			return
		}
		for ; dropped < int(p.keep); dropped += 1 {
			buf[dropped] = poison
		}
	}
	return
}

// Runs of JSON5's own white space longer than a window, at each place a value, a key or a colon may follow and past
// the root, are read about once by windows that cut their characters at every phase. A cut character that may be white
// space where a key may start is read as white space.
@(test)
pieces_read_json5_white_space_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Around :: struct {
		head, tail: string,
	}
	texts := []Around {
		{`{`, `"a":1}`},
		{`{"a":1,`, `"b":2}`},
		{`[1,`, `2]`},
		{`{"a"`, `:1}`},
		{`{"a":`, `1}`},
		{`{"a":1`, `}`},
		{`[`, `1]`},
		{`[1`, `]`},
		{``, `1`},
		{`1`, ``},
	}
	for a in texts {
		for body in ([]string{"\u00a0", "\u3000 ", "\u00a0 \u3000\ufeff\v ", "\u00a0\u2028 \u3000"}) {
			run := strings.repeat(body, 3000, context.temp_allocator)
			src := transmute([]u8)strings.concatenate({a.head, run, a.tail}, context.temp_allocator)
			for piece in ([]int{1024, 1023, 61}) {
				err, read := validate_in_windows(src, .Json5, piece, 0x01)
				ok := err == nil && read <= 4 * len(src)
				testing.expectf(t, ok, "%q in %v, windows of %d: %v, %d bytes read of %d", body, a, piece, err, read, len(src))
			}
		}
	}
}

// Comments of `body` repeated to at least `n` bytes.
@(private = "file")
comment_run_text :: proc(body: string, n: int) -> string {
	return strings.repeat(body, (n + len(body) - 1) / len(body))
}
