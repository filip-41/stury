package dsv_tests

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"
import "stury:testkit"

// A hook that records the tokens of a walk.
Log :: struct {
	tokens:   [dynamic]tape.Token,
	protocol: hook.Protocol({}, hook.Unused, hook.Unused, hook.Unused),
}

log_hook :: proc "contextless" (h: ^Log, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	context = runtime.default_context()
	append(&h.tokens, t)
	return s, .Next
}

// The tokens of a walk: a ragged record's missing columns make no tokens and its extra ones are named by position, a
// bare quote is a byte of its cell, a quoted cell's span leaves out its quotes, an empty unquoted cell is null, and a
// byte order mark past the text's first byte is a byte of its cell.
@(test)
walk_tokens :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Each token is `{lo, n, kind, role, spelling}`, the form a hook is given.
	Tokens :: struct {
		text:   string,
		tol:    tape.Tolerances,
		tokens: []tape.Token,
	}
	PLACED :: tape.SPELLING_DECODE | tape.SPELLING_PLACED
	QUOTED :: tape.SPELLING_QUOTED
	for c in ([]Tokens {
		{"a,b,c\n1,2\n", {.Ragged}, {{0, 0, .Array, .Value, 0}, {6, 0, .Object, .Value, 0}, {0, 1, .String, .Key, 0}, {6, 1, .String, .Value, 0}, {2, 1, .String, .Key, 0}, {8, 1, .String, .Value, 0}, {9, 1, .End, .Value, 0}, {10, 0, .End, .Value, 0}}},
		{"a,b\n1,2,3\n", {.Ragged}, {{0, 0, .Array, .Value, 0}, {4, 0, .Object, .Value, 0}, {0, 1, .String, .Key, 0}, {4, 1, .String, .Value, 0}, {2, 1, .String, .Key, 0}, {6, 1, .String, .Value, 0}, {3, 0, .String, .Key, PLACED}, {8, 1, .String, .Value, 0}, {9, 1, .End, .Value, 0}, {10, 0, .End, .Value, 0}}},
		{"a\"b,c\n1,\"2\"", {.Bare_Quote}, {{0, 0, .Array, .Value, 0}, {6, 0, .Object, .Value, 0}, {0, 3, .String, .Key, 0}, {6, 1, .String, .Value, 0}, {4, 1, .String, .Key, 0}, {9, 1, .String, .Value, QUOTED}, {11, 0, .End, .Value, 0}, {11, 0, .End, .Value, 0}}},
		{"a,b\n\xef\xbb\xbfx,y\n", {}, {{0, 0, .Array, .Value, 0}, {4, 0, .Object, .Value, 0}, {0, 1, .String, .Key, 0}, {4, 4, .String, .Value, 0}, {2, 1, .String, .Key, 0}, {9, 1, .String, .Value, 0}, {10, 1, .End, .Value, 0}, {11, 0, .End, .Value, 0}}},
		{"a,b\n,\"\"\r\n", {}, {{0, 0, .Array, .Value, 0}, {4, 0, .Object, .Value, 0}, {0, 1, .String, .Key, 0}, {4, 0, .Null, .Value, 0}, {2, 1, .String, .Key, 0}, {6, 0, .String, .Value, QUOTED}, {7, 2, .End, .Value, 0}, {9, 0, .End, .Value, 0}}},
	}) {
		log: Log
		defer delete(log.tokens)
		regs: hook.Regs
		at, err, _ := dsv.walk(transmute([]u8)c.text, .Csv, {tolerate = c.tol}, &log, &regs, log_hook)
		testing.expectf(t, err == nil && at == u64(len(c.text)), "%q: %d %v", c.text, at, err)
		testing.expectf(t, len(log.tokens) == len(c.tokens), "%q: %v", c.text, log.tokens[:])
		for tok, i in log.tokens {
			if i < len(c.tokens) && tok != c.tokens[i] {
				testing.expectf(t, false, "%q: token %d is %v, want %v", c.text, i, tok, c.tokens[i])
				break
			}
		}
	}
}

@(private = "file")
walk_of :: proc($S: dsv.Spec, $NO_HEADER: bool) -> testkit.Probe_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe, regs: ^hook.Regs) -> (u64, tape.Error) {
		o := opts
		o.format = dsv.Dsv_Options{no_header = NO_HEADER, comment = '#'}
		at, err, _ := dsv.walk(src, S, o, h, regs, testkit.probe_hook)
		return at, err
	}
}

// Every action at every token, a room that starts full or grows at every node, a refused stack and a step budget at
// every count of containers.
@(test)
walks_keep_the_hook_protocol :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	texts := []string{"a,b\n1,2\n#c\n\"x\"\"y\",\n", "a,b\r\n1,2", ""}
	testkit.hook_protocol(t, walk_of(.Csv, false), texts)
	testkit.hook_protocol(t, walk_of(.Csv, true), texts)
	testkit.hook_protocol(t, walk_of(.Tsv, false), {"a\tb\n1\t\\t\n"})
	testkit.hook_protocol(t, walk_of(.Plain, false), {"a,b\n1,2\n3,4"})
}

// A builder that stores the keys the walk gives, as `builder_hook` does, gets room for each of them: only the table
// hook, which drops them, goes without. The room starts at one node and the first record is sparse, so its growth is
// no larger than the nodes it must hold.
@(test)
walks_make_room_for_the_keys_a_hook_stores :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for columns in 1 ..= 24 {
		head := strings.builder_make(context.temp_allocator)
		dense := strings.builder_make(context.temp_allocator)
		for c in 0 ..< columns {
			sep := "," if c > 0 else ""
			fmt.sbprintf(&head, "%sh%d", sep, c)
			fmt.sbprintf(&dense, "%s1", sep)
		}
		sparse := strings.repeat("x", 300, context.temp_allocator)
		text := fmt.tprintf("%s\n%s\n%s\n%s\n", strings.to_string(head), sparse, strings.to_string(dense), strings.to_string(dense))
		src := transmute([]u8)text
		frames: [4]u64
		b: build.Builder
		build.builder_start(&b, src, dsv.as(.Csv), 1, 10_000, frames[:], context.allocator)
		regs := build.builder_regs(&b)
		at, werr, _ := dsv.walk(src, .Csv, {tolerate = {.Ragged}}, &b, &regs, build.builder_hook)
		stored := (regs.a - u64(uintptr(raw_data(b.doc.nodes)))) / size_of(tape.Node)
		testing.expectf(t, stored <= u64(len(b.doc.nodes)), "%d columns: %d nodes stored in a room of %d", columns, stored, len(b.doc.nodes))
		doc, err := build.builder_end(&b, regs, at, werr)
		dsv.destroy(&doc)
		testing.expect_value(t, err, nil)
	}
}

// Walks `src` as CSV or TSV with a hook that logs every token, and returns the walk's end and error.
walk_log :: proc(src: []u8, tsv, no_header: bool, tol: tape.Tolerances, log: ^Log) -> (u64, tape.Error) {
	opts := tape.Options {
		format   = dsv.Dsv_Options{no_header = no_header},
		tolerate = tol,
	}
	regs: hook.Regs
	if tsv {
		at, err, _ := dsv.walk(src, .Tsv, opts, log, &regs, log_hook)
		return at, err
	}
	at, err, _ := dsv.walk(src, .Csv, opts, log, &regs, log_hook)
	return at, err
}

// The token of a cell at `lo` of `n` bytes as written, which a quoted CSV cell gives without its quotes.
cell_token :: proc(lo, n: int, role: tape.Role, tsv, quoted: bool) -> tape.Token {
	if quoted && !tsv {
		return {u64(lo + 1), u32(n - 2), .String, role, tape.SPELLING_QUOTED}
	}
	return {u64(lo), u32(n), .String, role, 0}
}

// A record of cells joined by `sep` and written to `out`, each cell in quotes when `quoted`. Gives the record's start and
// the token of each cell as `role` says.
write_record :: proc(out: ^[dynamic]u8, cells: []string, sep: u8, quoted: bool, role: tape.Role, tsv: bool, tokens: ^[dynamic]tape.Token) -> (lo: int) {
	lo = len(out)
	for c, i in cells {
		if i > 0 {
			append(out, sep)
		}
		cell_lo := len(out)
		if quoted {
			append(out, '"')
		}
		append(out, c)
		if quoted {
			append(out, '"')
		}
		append(tokens, cell_token(cell_lo, len(out) - cell_lo, role, tsv, quoted))
	}
	return
}

// For a record wider than the header the walk gives its opening, the cells up to the header's width, and faults at the
// delimiter that starts the next cell. For a narrower one it gives its opening and all its cells, and faults at its
// line end. Neither has an `End`. Empty lines before the table move the record over every byte of a 64-byte block and
// across the boundary between two.
@(test)
walks_stop_at_a_record_of_the_wrong_width :: proc(t: ^testing.T) {
	testkit.deadline(t)
	log: Log
	defer delete(log.tokens)
	text: [dynamic]u8
	defer delete(text)
	want: [dynamic]tape.Token
	defer delete(want)
	keys, cells: [dynamic]tape.Token
	defer delete(keys)
	defer delete(cells)
	HEADER := []string{"h0", "h1", "h2"}
	FIRST := []string{"a0", "a1", "a2"}
	VALID := []string{"v0", "v1", "v2"}
	for tsv in ([]bool{false, true}) {
		sep := u8('\t') if tsv else ','
		for header in ([]bool{false, true}) {
			for quoted in ([]bool{false, true}) {
				for bad in ([][]string{{"w0", "w1", "w2", "w3"}, {"w0", "w1", "w2", "w3", "w4"}, {"s0", "s1"}}) {
					for final_lf in ([]bool{false, true}) {
						for k in 0 ..< 130 {
							clear(&text)
							clear(&want)
							for _ in 0 ..< k {
								append(&text, '\n')
							}
							append(&want, tape.Token{0, 0, .Array, .Value, 0})
							clear(&keys)
							if header {
								write_record(&text, HEADER, sep, quoted, .Key, tsv, &keys)
								append(&text, '\n')
							} else {
								clear(&cells)
								lo := write_record(&text, FIRST, sep, quoted, .Value, tsv, &cells)
								append(&want, tape.Token{u64(lo), 0, .Array, .Value, 0})
								append(&want, ..cells[:])
								append(&want, tape.Token{u64(len(text)), 1, .End, .Value, 0})
								append(&text, '\n')
							}
							clear(&cells)
							lo := write_record(&text, VALID, sep, quoted, .Value, tsv, &cells)
							append(&want, tape.Token{u64(lo), 0, .Object if header else .Array, .Value, 0})
							for cell, i in cells {
								if header {
									append(&want, keys[i])
								}
								append(&want, cell)
							}
							append(&want, tape.Token{u64(len(text)), 1, .End, .Value, 0})
							append(&text, '\n')
							clear(&cells)
							bad_lo := write_record(&text, bad, sep, quoted, .Value, tsv, &cells)
							append(&want, tape.Token{u64(bad_lo), 0, .Object if header else .Array, .Value, 0})
							for i in 0 ..< min(len(bad), len(HEADER)) {
								if header {
									append(&want, keys[i])
								}
								append(&want, cells[i])
							}
							fault_at := len(text)
							rule := "too_few_fields"
							if len(bad) > len(HEADER) {
								// The delimiter after the last cell the header names starts the cell past the width.
								last := cells[len(HEADER) - 1]
								fault_at = int(last.lo) + int(last.n) + (1 if quoted && !tsv else 0)
								rule = "too_many_fields"
							}
							if final_lf {
								append(&text, '\n')
							}
							clear(&log.tokens)
							at, err := walk_log(text[:], tsv, !header, {}, &log)
							expected := Case{"", .Bad_Width, u64(fault_at), rule}
							if !testing.expectf(t, at == u64(fault_at) && fault_is(err, expected, 0), "%q tsv %v header %v quoted %v lf %v: %d %v, want %d %s", text[:], tsv, header, quoted, final_lf, at, err, fault_at, rule) {
								return
							}
							if !testing.expectf(t, slice.equal(log.tokens[:], want[:]), "%q tsv %v header %v quoted %v lf %v: %v, want %v", text[:], tsv, header, quoted, final_lf, log.tokens[:], want[:]) {
								return
							}
						}
					}
				}
			}
		}
	}
}

// A text with no record gives the text's opening and end alone, an empty line and a byte order mark among them.
@(test)
walks_give_a_text_with_no_record_no_tokens_between :: proc(t: ^testing.T) {
	testkit.deadline(t)
	log: Log
	defer delete(log.tokens)
	for text in ([]string{"", "\r\n\n", "\xef\xbb\xbf"}) {
		clear(&log.tokens)
		at, err := walk_log(transmute([]u8)text, false, false, {}, &log)
		want := []tape.Token{{0, 0, .Array, .Value, 0}, {u64(len(text)), 0, .End, .Value, 0}}
		testing.expectf(t, err == nil && at == u64(len(text)) && slice.equal(log.tokens[:], want), "%q: %d %v %v", text, at, err, log.tokens[:])
	}
}

// Stops the walk on the key numbered `target`, counting from 0.
Key_Stopper :: struct {
	target, keys: int,
	protocol:     hook.Protocol({}, hook.Unused, hook.Unused, hook.Unused),
}

stop_on_key :: proc "contextless" (h: ^Key_Stopper, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role == .Key {
		h.keys += 1
		if h.keys > h.target {
			return s, .Stop
		}
	}
	return s, .Next
}

// A stop on a column's key ends the walk at the end of the cell the key names in the record, for a header cell's key and
// for a ragged cell's past the header, whether the cell is last in its record or ends at a delimiter.
@(test)
walks_stopped_on_a_key_end_at_its_cell :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Stop_Case :: struct {
		text: string,
		tol:  tape.Tolerances,
		key:  int,
		at:   u64,
	}
	for c in ([]Stop_Case{{"a,b\n1,2\n", {}, 0, 5}, {"a,b\n1,2\n", {}, 1, 7}, {"a\n1,2,3\n", {.Ragged}, 1, 5}, {"a\n1,2,3\n", {.Ragged}, 2, 7}}) {
		stopper := Key_Stopper {
			target = c.key,
		}
		regs: hook.Regs
		at, err, _ := dsv.walk(transmute([]u8)c.text, .Csv, {tolerate = c.tol}, &stopper, &regs, stop_on_key)
		testing.expectf(t, err == nil && at == c.at, "%q key %d: stopped at %d %v, want %d", c.text, c.key, at, err, c.at)
	}
}

// Whether a token's span holds what its kind says: a cell holds no line end or delimiter outside quotes, an opening
// token is empty, and a record's end is its line end.
token_spans_its_kind :: proc(src: []u8, t: tape.Token, delimiter: u8) -> bool {
	b := src[t.lo:][:t.n]
	switch t.kind {
	case .String, .True, .False, .Number:
		if t.spelling & tape.SPELLING_QUOTED == 0 {
			for c in b {
				if c == '\n' || c == '\r' || c == delimiter {
					return false
				}
			}
		}
		return true
	case .Null:
		return t.n == 0
	case .Array, .Object:
		return t.n == 0 && t.role == .Value
	case .End:
		return string(b) == "" || string(b) == "\n" || string(b) == "\r\n"
	case .Plain:
		return t.role != .Value && t.role != .Key && len(b) > 0 && !slice.contains(b, u8('\n'))
	case .Bytes:
	}
	return false
}

// The tokens of generated texts, valid or not, each span what its kind says up to the walk's fault.
@(test)
walked_tokens_span_what_their_kind_says :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x77)
	log: Log
	defer delete(log.tokens)
	defer free_all(context.temp_allocator)
	for _ in 0 ..< testkit.rounds(300) {
		src, spec, opts := random_text()
		clear(&log.tokens)
		regs: hook.Regs
		delimiter := u8('\t') if spec == .Tsv else u8(',')
		switch spec {
		case .Csv:
			_, _, _ = dsv.walk(src, .Csv, opts, &log, &regs, log_hook)
		case .Tsv:
			_, _, _ = dsv.walk(src, .Tsv, opts, &log, &regs, log_hook)
		case .Plain:
			_, _, _ = dsv.walk(src, .Plain, opts, &log, &regs, log_hook)
		}
		for tok in log.tokens {
			if !testing.expectf(t, token_spans_its_kind(src, tok, delimiter), "%q: %v", src, tok) {
				return
			}
		}
	}
}
