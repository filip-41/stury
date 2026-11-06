package core_test

import "core:math/rand"
import "core:testing"
import core ".."
import build "../build"
import dsv "../../dsv"
import dsv_gen "../../dsv/test/gen"
import json "../../json"
import json_gen "../../json/test/gen"
import walktest "../../walktest"

// The tokens a hook sees, the node each came from and the byte past each. An open's `n` and `spelling` and an `End`'s
// span are the walk's or the document's own, so `logged` clears them and keeps the byte past an `End` in `hi`.
@(private = "file")
Stream :: struct {
	tokens: [walktest.MAX_TOKENS]core.Token,
	at:     [walktest.MAX_TOKENS]core.Node_Index,
	hi:     [walktest.MAX_TOKENS]u64,
	n:      int,
	rule:   u64,
	opts:   dsv.Options, // a delimited walk's
	doc:    ^core.Document, // a replay's
	open:   [1100]core.Node_Index, // the containers a replay's step opened
	depth:  int,
}

@(private = "file")
logged :: proc "contextless" (h: ^Stream, t: core.Token, at: core.Node_Index) -> core.Action {
	t := t
	a := answer(h.rule, u64(h.n), t)
	h.hi[h.n] = t.lo + u64(t.n)
	if t.kind > .Plain {
		t.n, t.spelling = 0, 0
	}
	if t.kind == .End {
		t.lo = 0
	}
	h.tokens[h.n] = t
	h.at[h.n] = at
	h.n += 1
	return a
}

// `walktest.ask`, with `Keep` in place of `Next` on some containers.
@(private = "file")
answer :: proc "contextless" (rule, i: u64, t: core.Token) -> core.Action {
	a := walktest.ask(rule, i, t)
	if a == .Next && (t.kind == .Array || t.kind == .Map) && (i * 0x9e37_79b9_7f4a_7c15 + rule) >> 63 == 0 {
		return .Keep
	}
	return a
}

// A walk's hook. A comment makes no node, so it is not logged and takes no action.
@(private = "file")
walk_step :: proc "contextless" (h: ^Stream, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if t.role > .Key {
		return s, .Next
	}
	return s, logged(h, t, core.NO_NODE)
}

@(private = "file")
replay_step :: proc "contextless" (h: ^Stream, s: core.Hook_Regs, t: core.Token, at: core.Node_Index) -> (core.Hook_Regs, core.Action) {
	a := logged(h, t, at)
	if t.kind == .End {
		h.depth -= 1
	} else if t.kind > .Plain && (a == .Next || a == .Keep) {
		h.open[h.depth] = at
		h.depth += 1
	}
	return s, a
}

// The key of cell `i` of the record `open`, as the typed read of a document finds it.
@(private = "file")
replay_keyed :: proc "contextless" (h: ^Stream, _: core.Hook_Regs, i, open: core.Node_Index) -> (core.Node_Index, bool) {
	return h.doc.shared_keys + 1 + (i - open - 1), h.doc.nodes[open].kind == .Map
}

// The same key without `$OPEN`, from the containers the step opened.
@(private = "file")
replay_keyed_step :: proc "contextless" (h: ^Stream, s: core.Hook_Regs, i, _: core.Node_Index) -> (core.Node_Index, bool) {
	return replay_keyed(h, s, i, h.open[h.depth - 1])
}

// The tokens of `all` a hook answering by `rule` sees: a `Skip` on a container passes it through its `End`, one on a
// key passes the value the key names, and a `Stop` ends the stream after its token.
@(private = "file")
expected :: proc(all: []core.Token, rule: u64, out: ^[dynamic]core.Token) {
	clear(out)
	for j := 0; j < len(all); j += 1 {
		t := all[j]
		a := answer(rule, u64(len(out)), t)
		append(out, t)
		switch a {
		case .Stop:
			return
		case .Skip:
			if t.role == .Key {
				j += 1
				t = all[j]
			}
			if t.kind == .Array || t.kind == .Map {
				for depth := 0; j < len(all); j += 1 {
					#partial switch all[j].kind {
					case .Array, .Map:
						depth += 1
					case .End:
						depth -= 1
					}
					if depth == 0 {
						break
					}
				}
			}
		case .Next, .Keep:
		}
	}
}

// Replays nodes `from ..< to` of `doc` under `rule` with and without `$OPEN`, checks both give the same tokens and
// that they are `want`. `r` holds the replay with `$OPEN`.
@(private = "file")
replay_is :: proc(t: ^testing.T, doc: ^core.Document, from, to: u32, rule: u64, want: []core.Token, r, flat: ^Stream) -> bool {
	ends: [2 * 1100]u32
	regs: core.Hook_Regs
	r^ = {doc = doc, rule = rule}
	build.feed_nodes(doc, from, to, r, &regs, ends[:], replay_step, replay_keyed, true)
	flat^ = {doc = doc, rule = rule}
	build.feed_nodes(doc, from, to, flat, &regs, ends[:], replay_step, replay_keyed_step, false)
	if !testing.expectf(t, r.n == len(want) && flat.n == len(want), "%q [%d, %d) rule %x: replay %d and %d tokens, want %d", doc.src, from, to, rule, r.n, flat.n, len(want)) {
		return false
	}
	for k in 0 ..< r.n {
		if !testing.expectf(t, r.tokens[k] == want[k] && flat.tokens[k] == want[k], "%q [%d, %d) rule %x: token %d %v and %v, want %v", doc.src, from, to, rule, k, r.tokens[k], flat.tokens[k], want[k]) {
			return false
		}
	}
	return true
}

// Checks one text. The replay of the whole document gives the walk's tokens, comments aside, and each `End` names a
// container whose bytes end where the walk's `End` does. Under a rule of `Skip`, `Keep` and `Stop`, the walk and the
// replay give the tokens those answers leave. The replay of a value's nodes gives the walk's tokens from its open to
// its `End`, under a rule of its own.
@(private = "file")
replay_agrees :: proc(t: ^testing.T, src: []u8, doc: ^core.Document, opts: dsv.Options, walk: proc(src: []u8, h: ^Stream)) -> bool {
	w := new(Stream)
	defer free(w)
	r := new(Stream)
	defer free(r)
	flat := new(Stream)
	defer free(flat)
	w.opts = opts
	walk(src, w)
	all := make([]core.Token, w.n)
	defer delete(all)
	copy(all, w.tokens[:w.n])
	whole := u32(len(doc.nodes))
	if !replay_is(t, doc, 0, whole, 0, all, r, flat) {
		return false
	}
	for k in 0 ..< r.n {
		if r.tokens[k].kind == .End {
			end := doc.spelling.close_end(doc, r.at[k])
			if !testing.expectf(t, w.hi[k] == end, "%q: node %d ends at %d, its End at %d", src, r.at[k], end, w.hi[k]) {
				return false
			}
		}
	}
	node_of := make([]core.Node_Index, len(all))
	defer delete(node_of)
	copy(node_of, r.at[:r.n])
	want: [dynamic]core.Token
	defer delete(want)
	for _ in 0 ..< 4 {
		rule := (rand.uint64() | 1 << 63) &~ 0xffff_ffff | u64(rand.int_max(len(all) + 4))
		expected(all, rule, &want)
		w^ = {rule = rule, opts = opts}
		walk(src, w)
		if !testing.expectf(t, w.n == len(want), "%q rule %x: walk %d tokens, want %d", src, rule, w.n, len(want)) {
			return false
		}
		for k in 0 ..< w.n {
			if !testing.expectf(t, w.tokens[k] == want[k], "%q rule %x: token %d walk %v, want %v", src, rule, k, w.tokens[k], want[k]) {
				return false
			}
		}
		if !replay_is(t, doc, 0, whole, rule, want[:], r, flat) {
			return false
		}
	}
	for k in 0 ..< len(all) {
		tok := all[k]
		if tok.role != .Value || tok.kind == .End {
			continue
		}
		node := node_of[k]
		stop := k + 1
		to := u32(node) + 1
		if tok.kind > .Plain {
			for !(all[stop].kind == .End && node_of[stop] == node) {
				stop += 1
			}
			stop += 1
			to = u32(node) + doc.nodes[node].n
		}
		for rule in ([]u64{0, (rand.uint64() | 1 << 63) &~ 0xffff_ffff | u64(rand.int_max(stop - k + 2))}) {
			expected(all[k:stop], rule, &want)
			if !replay_is(t, doc, u32(node), to, rule, want[:], r, flat) {
				return false
			}
		}
	}
	return true
}

// On generated texts of every JSON spec, compact and pretty, a document's replay gives a hook the walk's tokens.
@(test)
replay_json :: proc(t: ^testing.T) {
	state := rand.create(7)
	context.random_generator = rand.default_random_generator(&state)
	text: [dynamic]u8
	defer delete(text)
	for round in 0 ..< 600 {
		spec := json.Spec(round % 3)
		clear(&text)
		if round % 2 == 0 {
			json_gen.text(&text, 4, spec)
		} else {
			json_gen.pretty(&text, 4, spec)
		}
		doc, err := json.build(text[:], spec)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "%v %q: %v", spec, text[:], err) {
			return
		}
		ok: bool
		switch spec {
		case .Json:  ok = replay_agrees(t, text[:], &doc, {}, json_walk(.Json))
		case .Jsonc: ok = replay_agrees(t, text[:], &doc, {}, json_walk(.Jsonc))
		case .Json5: ok = replay_agrees(t, text[:], &doc, {}, json_walk(.Json5))
		}
		if !ok {
			return
		}
	}
}

@(private = "file")
json_walk :: proc($S: json.Spec) -> proc(src: []u8, h: ^Stream) {
	return proc(src: []u8, h: ^Stream) {
		regs: core.Hook_Regs
		json.walk(src, 0, S, {}, h, &regs, walk_step)
	}
}

// On generated delimited texts of every spec, headed and not, with other delimiters and comment lines, ragged under
// `.Ragged`, and broken under every tolerance, a document's replay gives a hook the walk's tokens, each cell of a headed
// record after its column's key.
@(test)
replay_dsv :: proc(t: ^testing.T) {
	state := rand.create(9)
	context.random_generator = rand.default_random_generator(&state)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	for round in 0 ..< 1600 {
		c := dsv_gen.Options_Case{spec = .Tsv if round % 2 == 1 else .Csv}
		if round % 16 >= 8 {
			c = dsv_gen.pick_case()
			dsv_gen.options_text(&text, c)
		} else {
			dsv_gen.text(&text, c.spec == .Tsv)
		}
		opts := dsv.Options{no_header = round % 4 >= 2, delimiter = c.delim, comment = c.comment}
		if round % 8 >= 4 {
			opts.tolerate = {.Ragged}
			ragged(&text, c.delim if c.delim != 0 else '\t' if c.spec == .Tsv else ',')
		}
		src := text[:]
		if round % 32 >= 16 {
			walktest.mutate(&broken, text[:], dsv_gen.SHARP)
			src = broken[:]
			opts.tolerate = {.Invalid_Utf8, .Ragged, .Bare_Quote}
		}
		ok: bool
		switch c.spec {
		case .Csv:   ok = dsv_agrees(t, src, .Csv, opts)
		case .Tsv:   ok = dsv_agrees(t, src, .Tsv, opts)
		case .Plain: ok = dsv_agrees(t, src, .Plain, opts)
		}
		if !ok {
			return
		}
	}
}

// Widens the last record by one to three cells, or adds a record of one cell.
@(private = "file")
ragged :: proc(text: ^[dynamic]u8, delim: u8) {
	if rand.int_max(2) == 0 {
		append(text, '\n', 'z')
		return
	}
	n := len(text)
	for n > 0 && (text[n - 1] == '\n' || text[n - 1] == '\r') {
		n -= 1
	}
	tail: [2]u8
	end := copy(tail[:], text[n:])
	resize(text, n)
	for _ in 0 ..< 1 + rand.int_max(3) {
		append(text, delim, 'x')
	}
	append(text, ..tail[:end])
}

@(private = "file")
dsv_agrees :: proc(t: ^testing.T, src: []u8, $S: dsv.Spec, opts: dsv.Options) -> bool {
	doc, err := dsv.build(src, S, opts)
	defer core.destroy(&doc)
	if err.kind != .None {
		// A broken text that breaks a rule no tolerance covers.
		return testing.expectf(t, err.kind == .Walk, "%v %q: %v", S, src, err)
	}
	return replay_agrees(t, src, &doc, opts, proc(src: []u8, h: ^Stream) {
		regs: core.Hook_Regs
		dsv.walk(src, 0, S, h.opts, h, &regs, walk_step)
	})
}
