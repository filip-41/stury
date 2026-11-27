package capi_test

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:capi"
import "stury:json"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"

// The chunks a walk delivers: every token in text order, and the size of each chunk. `refuse` is the chunk whose
// `take` ends the walk, 1-based, 0 for none.
Sink :: struct {
	tokens: [dynamic]tape.Token,
	sizes:  [dynamic]int,
	refuse: int,
	ctx:    runtime.Context,
}

take :: proc "c" (ctx: rawptr, tokens: [^]tape.Token, n: int) -> bool {
	s := (^Sink)(ctx)
	context = s.ctx
	append(&s.sizes, n)
	append(&s.tokens, ..tokens[:n])
	return len(s.sizes) != s.refuse
}

// The walk of a text for a chunk hook, as `json.walk` runs it for spec `S`.
@(private = "file")
Chunk_Walk :: #type proc(src: []u8, h: ^capi.Chunk_Hook, regs: ^hook.Regs) -> (u64, tape.Error)

@(private = "file")
chunk_walk_of :: proc($S: json.Spec) -> Chunk_Walk {
	return proc(src: []u8, h: ^capi.Chunk_Hook, regs: ^hook.Regs) -> (u64, tape.Error) {
		at, err, _ := json.walk(src, S, {}, h, regs, capi.chunk_hook)
		return at, err
	}
}

// The walk of a text for a `testkit.Probe`, the token-by-token path a chunk's stream must match.
@(private = "file")
probe_walk_of :: proc($S: json.Spec) -> testkit.Probe_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe, regs: ^hook.Regs) -> (u64, tape.Error) {
		at, err, _ := json.walk(src, S, opts, h, regs, testkit.probe_hook)
		return at, err
	}
}

// Walks `text` both ways and checks that the chunks hold every token the probe is given, in order, in chunks of `CHUNK`
// with the last as long as what is left. Answers the sink, its close and error, and the probe, ended by the caller.
@(private = "file")
chunks_match_probe :: proc(t: ^testing.T, chunk: Chunk_Walk, probe: testkit.Probe_Walk, text: string) -> (sink: Sink, close: u64, err: tape.Error, want: testkit.Probe) {
	src := transmute([]u8)text
	want = testkit.probe_start(1024, 1024)
	regs := testkit.probe_regs(&want)
	want_close, want_err := probe(src, {}, &want, &regs)
	sink.ctx = context
	h := capi.Chunk_Hook {
		take = take,
		ctx  = &sink,
	}
	got_regs := capi.chunk_regs(&h)
	close, err = chunk(src, &h, &got_regs)
	flushed := capi.chunk_flush(&h, got_regs)
	testing.expectf(t, flushed, "%q: the flush refused", text)
	testing.expectf(t, err == want_err, "%q: %v, want %v", text, err, want_err)
	testing.expectf(t, close == want_close, "%q: close %d, want %d", text, close, want_close)
	if !testing.expectf(t, len(sink.tokens) == len(want.tokens), "%q: %d tokens, want %d", text, len(sink.tokens), len(want.tokens)) {
		return
	}
	for got, i in sink.tokens {
		if !testing.expectf(t, got == want.tokens[i], "%q: token %d is %v, want %v", text, i, got, want.tokens[i]) {
			return
		}
	}
	if want_err != nil {
		return
	}
	// A whole read gives full chunks while one is left, and the rest last.
	chunks := (len(want.tokens) + capi.CHUNK - 1) / capi.CHUNK
	if !testing.expectf(t, len(sink.sizes) == chunks, "%q: %d chunks, want %d", text, len(sink.sizes), chunks) {
		return
	}
	for size, i in sink.sizes {
		rest := len(want.tokens) - i * capi.CHUNK
		if !testing.expectf(t, size == min(rest, capi.CHUNK), "%q: chunk %d holds %d tokens, want %d", text, i, size, min(rest, capi.CHUNK)) {
			return
		}
	}
	return
}

@(private = "file")
free_sink :: proc(sink: ^Sink) {
	delete(sink.tokens)
	delete(sink.sizes)
}

// A JSON array of `n` zeros, whose tokens are the open bracket, the `n` numbers and the close.
@(private = "file")
zeros :: proc(n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for i in 0 ..< n {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '0')
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// An array of arrays of numbers, long enough for the walk's block reading of them.
@(private = "file")
number_blocks :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for i in 0 ..< 40 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '[')
		for k in 0 ..< 20 {
			if k > 0 {
				strings.write_byte(&b, ',')
			}
			fmt.sbprintf(&b, "%d", i * 200 + k)
		}
		strings.write_byte(&b, ']')
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

@(test)
chunks_hand_every_token_in_order :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	chunk := chunk_walk_of(.Json)
	probe := probe_walk_of(.Json)
	// Texts whose token counts are below, at and past a chunk's end, and an array of numbers read in blocks.
	texts := []string{
		`{"a":1,"b":[true,false,null,"x"],"c":{"d":1.5}}`,
		zeros(1),
		zeros(int(capi.CHUNK) - 2),
		zeros(int(capi.CHUNK) - 1),
		zeros(int(capi.CHUNK)),
		zeros(2 * int(capi.CHUNK) - 2),
		zeros(2 * int(capi.CHUNK) + 10),
		number_blocks(),
	}
	for text in texts {
		sink, _, _, want := chunks_match_probe(t, chunk, probe, text)
		free_sink(&sink)
		testkit.probe_end(&want)
	}
}

@(test)
chunks_carry_the_facts_of_a_jsonc_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	sink, _, err, want := chunks_match_probe(t, chunk_walk_of(.Jsonc), probe_walk_of(.Jsonc), `// head
{"a": /* in */ 1, "b": [2, 3] /* foot */} // tail`)
	defer free_sink(&sink)
	defer testkit.probe_end(&want)
	testing.expectf(t, err == nil, "%v", err)
}

@(test)
a_chunk_the_consumer_refuses_ends_the_walk :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	text := number_blocks()
	src := transmute([]u8)text
	chunk := chunk_walk_of(.Json)
	probe := probe_walk_of(.Json)
	want := testkit.probe_start(1024, 1024)
	defer testkit.probe_end(&want)
	regs := testkit.probe_regs(&want)
	_, want_err := probe(src, {}, &want, &regs)
	testing.expectf(t, want_err == nil, "%v", want_err)
	for refuse in 1 ..= 2 {
		sink := Sink {
			ctx    = context,
			refuse = refuse,
		}
		h := capi.Chunk_Hook {
			take = take,
			ctx  = &sink,
		}
		got_regs := capi.chunk_regs(&h)
		close, err := chunk(src, &h, &got_regs)
		testing.expectf(t, err == nil, "chunk %d: %v", refuse, err)
		testing.expectf(t, len(sink.sizes) == refuse, "chunk %d: %d chunks, want %d", refuse, len(sink.sizes), refuse)
		testing.expectf(t, len(sink.tokens) == refuse * int(capi.CHUNK), "chunk %d: %d tokens, want %d", refuse, len(sink.tokens), refuse * int(capi.CHUNK))
		// The walk ends at the token after the refused chunk, which is not delivered.
		stop := want.tokens[refuse * int(capi.CHUNK)]
		testing.expectf(t, close == stop.lo + u64(stop.n), "chunk %d: close %d, want %d", refuse, close, stop.lo + u64(stop.n))
		testing.expectf(t, capi.chunk_flush(&h, got_regs), "chunk %d: the flush refused", refuse)
		testing.expectf(t, len(sink.sizes) == refuse, "chunk %d: the flush handed a chunk", refuse)
		free_sink(&sink)
	}
}

@(test)
a_fault_flushes_what_the_walk_gave :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	full := zeros(2 * int(capi.CHUNK) + 10)
	text := full[:len(full) - 1] // no close bracket: every token before the end is given, then a truncation
	sink, _, err, want := chunks_match_probe(t, chunk_walk_of(.Json), probe_walk_of(.Json), text)
	defer free_sink(&sink)
	defer testkit.probe_end(&want)
	testing.expectf(t, err != nil, "%q read whole", text)
	testing.expectf(t, len(sink.tokens) == len(want.tokens), "%d tokens, want %d", len(sink.tokens), len(want.tokens))
}
