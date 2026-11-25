package json_tests

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// Reads of a text in pieces, each window starting at the read's `keep`, against reads of the whole text.

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
		if name, ok := tape.node_text(doc, 1, buf[:]); ok {
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
		if !testkit.pieces_agree(t, json.reads(spec), json.as(spec), src, opts, cuts[:], paths, name, containers = true) {
			return
		}
	}
	for _ in 0 ..< testkit.rounds(1) {
		i := rand.int_max(len(src))
		cuts := [2]int{i, i + 1 + rand.int_max(len(src) - i)}
		c.reads += 1
		if !testkit.pieces_agree(t, json.reads(spec), json.as(spec), src, opts, cuts[:], paths, name, containers = true) {
			return
		}
	}
}

// Splits `src` in two at every byte, or at a sample of them past 96 bytes, and in three at a sample of byte pairs, and
// checks each split's reads.
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
	step := max(1, len(src) / testkit.rounds(96))
	for k := 0; k <= len(src); k += step {
		cuts := [1]int{k}
		c.reads += 1
		if !testkit.pieces_agree(t, json.reads(spec), json.as(spec), src, opts, cuts[:], paths, name, containers = true) {
			return
		}
	}
	if len(src) < 8 {
		return
	}
	for k in 0 ..< testkit.rounds(6) {
		i := (k * 7919) % len(src)
		j := i + 1 + (k * 104729) % (len(src) - i)
		cuts := [2]int{i, j}
		c.reads += 1
		if !testkit.pieces_agree(t, json.reads(spec), json.as(spec), src, opts, cuts[:], paths, name, containers = true) {
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

// Split at every byte, a read whose paths a limit settles judges the text past them as a read of the whole text does,
// and a scan keeps the same nodes.
@(test)
pieces_judge_the_text_past_a_limit :: proc(t: ^testing.T) {
	testkit.deadline(t)
	whole := []string{`[1,2,3]`, `[1,[2,3],{"a":4}]`, `{"a":[1,[2]],"b":[3]}`, "[1, /* c */ 2, x", "[1,2] // c", `{"a":[1 /* c */]} /* d */`}
	for texts in ([][]string{LIMITED_TEXTS, whole}) {
		for src in texts {
			for spec in ([]json.Spec{.Json, .Jsonc}) {
				for cut in 0 ..= len(src) {
					cuts := [1]int{cut}
					if !testkit.pieces_agree(t, json.reads(spec), json.as(spec), transmute([]u8)src, {}, cuts[:], limited_paths, "limited", limited_limits) {
						return
					}
				}
			}
		}
	}
}

// A text of many short escaped keys, with escaped values around them, cut at every byte: the builds, finds and scans in
// pieces give the whole read's, wherever a key lies against a window's end.
@(test)
pieces_read_short_escaped_keys_as_whole_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for i in 0 ..< 12 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, `{"n\u0061me":"v\u0061l","\u0069d":1,"t\u0061gs":["\n","x"],"\u00e9":{"k\u0061":null}}`)
	}
	strings.write_byte(&b, ']')
	src := transmute([]u8)strings.to_string(b)
	doc, err := json.build(src)
	defer tape.destroy(&doc)
	testing.expect_value(t, err, nil)
	paths := paths_into(&doc)
	for k in 0 ..= len(src) {
		cuts := [1]int{k}
		if !testkit.pieces_agree(t, json.reads(.Json), json.as(.Json), src, {}, cuts[:], paths, "escaped keys") {
			return
		}
	}
}

// A text of ASCII and other strings and keys split anywhere gives the spellings of the whole read.
@(test)
pieces_spell_ascii_texts_as_whole_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	c: Corpus
	for spec in json.Spec {
		agree_over_splits(t, transmute([]u8)ascii_text(spec), spec, {}, "ascii", &c)
	}
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
		answers, kept := testkit.render_answers(&doc), testkit.render_doc(&doc)
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
	text := testkit.feed({src, json.reads(.Json), json.as(.Json), {}, cuts[:]}, &p, proc(window: []u8, r: testkit.Piece_Run, opts: tape.Options) -> bool {
		g := (^Got)(context.user_ptr)
		g.widest = max(g.widest, len(window))
		doc, err := r.reads.scan(r.f, window, g.d, {}, opts, context.allocator)
		tape.destroy(&g.doc)
		g.doc = doc
		return err == nil
	})
	defer delete(text)
	defer tape.destroy(&got.doc)
	defer tape.destroy(&p)
	testing.expect(t, werr == nil && testkit.same_documents(got.doc, want) && .Held in got.doc.flags)
	testing.expectf(t, got.widest <= 512, "a window of %d bytes", got.widest)
	testing.expect_value(t, testkit.render_answers(&got.doc), testkit.render_answers(&want))
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
	window := testkit.feed(testkit.Piece_Run{src, json.reads(.Json), json.as(.Json), {budget = {memory = memory}}, cuts}, &p, proc(window: []u8, r: testkit.Piece_Run, opts: tape.Options) -> bool {
		g := (^Budgeted)(context.user_ptr)
		switch g.kind {
		case .Validate:
			g.err = r.reads.validate(r.f, window, opts, context.allocator)
		case .Build:
			doc, err := r.reads.build(r.f, window, opts, context.allocator)
			tape.destroy(&doc)
			g.err = err
		case .Find:
			_, g.err = r.reads.find(r.f, window, g.path, {}, opts, context.allocator)
		case .Scan:
			doc, err := r.reads.scan(r.f, window, g.demand, {}, opts, context.allocator)
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
// grammar refuses where they were, and the reads in pieces of 1 KiB, or a 4096th of a longer text, give what the whole
// reads give. A document keeps its text, so each window is a copy of everything read so far, and a longer text in pieces
// of 1 KiB takes the square of its length in copies.
@(private = "file")
long_token_agrees :: proc(t: ^testing.T, src: []u8, spec: json.Spec, paths: [][]tape.Step, poison: u8, name: string) {
	PIECE := max(1024, len(src) / 4096)
	err, read := validate_in_windows(src, spec, PIECE, poison)
	testing.expectf(t, err == nil && read <= 4 * len(src), "%s %v: validate %v, %d bytes read of %d", name, spec, err, read, len(src))
	p := tape.Pieces{allocator = context.allocator}
	cuts := make([dynamic]int, 0, len(src) / PIECE)
	defer delete(cuts)
	for k := PIECE; k < len(src); k += PIECE {
		append(&cuts, k)
	}
	r := testkit.Piece_Run{src, json.reads(spec), json.as(spec), {}, cuts[:]}
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
	window := testkit.feed(r, &p, proc(window: []u8, r: testkit.Piece_Run, opts: tape.Options) -> bool {
		g := (^Got)(context.user_ptr)
		tape.destroy(&g.doc)
		g.doc, g.err = r.reads.build(r.f, window, opts, context.allocator)
		return g.err == nil
	})
	testing.expectf(t, werr == nil && got.err == nil && testkit.same_documents(got.doc, whole), "%s %v: build %v, whole %v", name, spec, got.err, werr)
	tape.destroy(&got.doc)
	tape.destroy(&p)
	tape.destroy(&whole)
	delete(window)
	for path in paths {
		want, ferr := json.find(src, path, spec, {}, {})
		got.path = path
		found := testkit.feed(r, &p, proc(window: []u8, r: testkit.Piece_Run, opts: tape.Options) -> bool {
			g := (^Got)(context.user_ptr)
			g.answer, g.err = r.reads.find(r.f, window, g.path, {}, opts, context.allocator)
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
	scanned := testkit.feed(r, &p, proc(window: []u8, r: testkit.Piece_Run, opts: tape.Options) -> bool {
		g := (^Got)(context.user_ptr)
		tape.destroy(&g.doc)
		g.doc, g.err = r.reads.scan(r.f, window, g.d, {}, opts, context.allocator)
		return g.err == nil
	})
	defer delete(scanned)
	ok := derr == nil && serr == nil && got.err == nil && testkit.same_documents(got.doc, want)
	testing.expectf(t, ok, "%s %v: scan %v, whole %v", name, spec, got.err, serr)
	tape.destroy(&got.doc)
	tape.destroy(&p)
}

// The bytes of a long string, 64 MiB at `-define:ROUNDS=16` and fewer by default and under a sanitizer, whose shadow
// memory a 64 MiB text would take past the tests' memory cap. A read that went back over the string per window would
// pass its bound at either size.
@(private = "file")
LONG :: 64 << 20 when ODIN_SANITIZER_FLAGS == {} && testkit.ROUNDS >= 16 else 4 << 20

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

// Reads `src` in two windows cut at `cut`, as a validation or as a build, and gives the error of the read that ended.
@(private = "file")
read_in_two_windows :: proc(src: []u8, spec: json.Spec, cut: int, build: bool) -> tape.Error {
	p := tape.Pieces{allocator = context.allocator}
	defer tape.destroy(&p)
	for end := cut; ; end = len(src) {
		p.from, p.last = p.keep, end == len(src)
		err: tape.Error
		if build {
			doc: tape.Document
			doc, err = json.build(src[p.keep:end], spec, {pieces = &p})
			tape.destroy(&doc)
		} else {
			err = json.validate(src[p.keep:end], spec, {pieces = &p})
		}
		if err != nil || !p.more || p.last {
			return err
		}
	}
}

// Arrays of numbers, whose runs the walk reads in blocks, are judged by a validation in pieces and under a steps budget
// as by a build under the same.
@(test)
validation_judges_number_blocks_as_a_build_does :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[[0")
	for i in 1 ..< 200 {
		fmt.sbprintf(&b, "],[%d,%d", i, i)
	}
	strings.write_string(&b, "]]")
	texts := [?]string{
		`[[[0,0],[12789012345678901234567890],123456789012345678901234567890],[false,false]]`,
		`[[1,2],[3,4],[5.5,6],[7,8],[9,10],[11,12],[13,14],[15,16],[17,18],[19,20],[21,22],[23,24],[25,26],[27,28],[29,30]]`,
		strings.to_string(b),
	}
	for text, i in texts {
		src := transmute([]u8)text
		for spec in json.Spec {
			for cut in 1 ..< len(src) {
				got, want := read_in_two_windows(src, spec, cut, false), read_in_two_windows(src, spec, cut, true)
				if !testing.expectf(t, testkit.same_refusal(got, want), "text %d %v cut %d: validate gives %v, build %v", i, spec, cut, got, want) {
					return
				}
			}
			for steps in 1 ..< u64(300) {
				opts := json.Options{budget = {steps = steps}}
				got := json.validate(src, spec, opts)
				doc, want := json.build(src, spec, opts)
				tape.destroy(&doc)
				if !testing.expectf(t, testkit.same_refusal(got, want), "text %d %v steps %d: validate gives %v, build %v", i, spec, steps, got, want) {
					return
				}
			}
		}
	}
	free_all(context.temp_allocator)
}

// The records of a text of lines in pieces, at every cut and in windows of every size up to past the bytes a record's
// walk reads beyond its line: the records, answers, documents and faults of the whole text's records.
@(test)
records_in_pieces_agree_with_whole_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	long := strings.repeat("x", 300, context.temp_allocator)
	Case :: struct {
		name: string,
		spec: json.Spec,
		text: string,
	}
	cases := []Case {
		{"lines", .Json, "{\"a\":1,\"b\":[1,2]}\n{\"a\":\"x\"}\r\n\n  [3]\n{\"b\":true}"},
		{"byte order mark", .Json, "\xEF\xBB\xBF{\"a\":1}\n{\"a\":2}\n"},
		{"value past its line", .Json, "{\"a\":1}\n{\"a\":\n2}\n{\"a\":3}\n"},
		{"fault", .Json, "{\"a\":1}\n{\"a\" 1}\n{\"a\":tru}\n{\"a\":4}\n"},
		{"long lines", .Json, fmt.tprintf("{{\"a\":\"%s\"}}\n{{\"b\":1}}\n[\"%s\"]\n", long, long)},
		{"comments", .Jsonc, "// head\n{\"a\":1} // tail\n/* x */ {\"a\":2}\n"},
		{"json5", .Json5, "{a:1,}\n{a:'two'}\n"},
	}
	paths := [][]tape.Step{{}, {tape.Name("a")}, {tape.All{}}, {tape.Index(0)}}
	for c in cases {
		src := transmute([]u8)c.text
		reads, f := json.reads(c.spec), json.as(c.spec)
		for k in 0 ..= len(src) {
			cuts := [1]int{k}
			if !testkit.pieces_agree(t, reads, f, src, {}, cuts[:], paths, c.name) {
				break
			}
		}
		for size in ([]int{1, 2, 3, 7, 64, 100, 300}) {
			cuts := make([dynamic]int, context.temp_allocator)
			for k := size; k < len(src); k += size {
				append(&cuts, k)
			}
			if !testkit.pieces_agree(t, reads, f, src, {}, cuts[:], paths, c.name) {
				break
			}
		}
	}
}

// The records of a text in pieces are read a window at a time, a record the window's end cuts read in the next, and
// each window lets go of the records read before it.
@(test)
records_in_pieces_read_a_window_at_a_time :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	text := fmt.tprintf("{{\"a\":1}}\n%s{{\"a\":[2]}}\n{{\"b\":3}}\n", strings.repeat(" ", 600, context.temp_allocator))
	src := transmute([]u8)text
	p := json.Pieces{allocator = context.allocator}
	defer json.destroy(&p)
	r := json.records_open(src[:100], .Lines, .Json, {pieces = &p})
	got := make([dynamic]string, context.temp_allocator)
	keeps := make([dynamic]u64, context.temp_allocator)
	for {
		out: [4]tape.Record
		answers: [4]tape.Span_Answer
		n := json.records_find(&r, {tape.Name("a")}, out[:], answers[:])
		for a in answers[:n] {
			append(&got, string(src[a.lo:a.hi]) if a.outcome == .Found else "missing")
		}
		if !p.more {
			break
		}
		append(&keeps, p.keep)
		p.from = p.keep
		end := min(p.at + 100, u64(len(src)))
		p.last = end == u64(len(src))
		testing.expect_value(t, tape.records_window(&r, src[p.from:end]), nil)
	}
	testing.expectf(t, r.err == nil && slice.equal(got[:], []string{"1", "[2]", "missing"}), "%v %q", r.err, got[:])
	testing.expectf(t, len(keeps) > 2 && keeps[len(keeps) - 1] >= 600, "keeps %v", keeps[:])
}
