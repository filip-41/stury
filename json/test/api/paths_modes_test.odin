package json_tests

import json "../.."
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "../../scan/walk"

// One `Open_Frame` (`json/scan/walk/scanner.odin`): the scan's cost per nesting level past `MAX_DEPTH`.
FRAME_BYTES :: 24

// A path scan answers the same whichever engine the router gives it, and its coverage and stop (the request's
// private state) are the walk's own. The suite is built twice (`make test-modes`), with and without `FORCE_AUTOMATON`, so every
// value pinned here has to hold on the demand matcher and on the automaton.
//
// Each row is one request. `want[i]` is query `i`'s answers in walk order.
@(test)
test_path_coverage_and_stop_are_engine_independent :: proc(t: ^testing.T) {
	a, b := json.Name("a"), json.Name("b")
	any, any_any := json.Any{}, json.Any{}
	xa := []json.Step{any, a}
	axa := []json.Step{a, any_any, a}
	xa_path := []json.Path{{steps = xa}}
	axa_path := []json.Path{{steps = axa}}

	hit :: proc(query: u32, lo, hi, owner: u64, kind: json.Kind) -> json.Answer {
		return {outcome = .Found, query = query, lo = lo, hi = hi, owner = owner, kind = kind, node = json.NO_NODE}
	}
	miss :: proc(query: u32, owner: u64) -> json.Answer {
		return {outcome = .Missing, query = query, owner = owner, node = json.NO_NODE}
	}
	mismatch :: proc(query: u32) -> json.Answer {
		return {outcome = .Type_Mismatch, query = query, owner = max(u64), node = json.NO_NODE}
	}
	Case :: struct {
		src:      string,
		paths:    []json.Path,
		level:    json.Strictness,
		dups:     json.Duplicates,
		coverage: walk.Validity,
		stop:     Maybe(u64),
		err:      Maybe(json.Error),
		want:     [][]json.Answer,
	}
	cases := []Case{
		{src = `{"a":1}`, paths = xa_path, level = .Lazy, dups = .First, coverage = .Partial},
		{src = `1`, paths = xa_path, level = .Lazy, dups = .First, coverage = .Partial, stop = 0},
		{src = `[1]`, paths = xa_path, level = .Lazy, dups = .First, coverage = .Partial},
		{src = `[1]`, paths = axa_path, level = .Lazy, dups = .First, coverage = .Partial, stop = 1},
		{src = `1`, paths = axa_path, level = .Lazy, dups = .First, coverage = .Partial, stop = 0},
		{src = `[]`, paths = axa_path, level = .Lazy, dups = .First, coverage = .Partial, stop = 1},
		{src = `{"a":[1,2]}`, paths = axa_path, level = .Lazy, dups = .First, coverage = .Partial},
		{src = `[[1]]`, paths = xa_path, level = .Lazy, dups = .First, coverage = .Partial},
		{src = `{"x":[{"a":1}]}`, paths = xa_path, level = .Lazy, dups = .First, coverage = .Partial},
		{src = `{"x":{"a":1}}`, paths = xa_path, level = .Lazy, dups = .First, coverage = .Full,
		 want = {{hit(0, 10, 11, 5, .Number)}}},
		{src = `[{"a":1},{"a":2}]`, paths = xa_path, level = .Lazy, dups = .First, coverage = .Full,
		 want = {{hit(0, 6, 7, 1, .Number), hit(0, 14, 15, 9, .Number)}}},
		{src = `{"a":1}`, paths = []json.Path{{steps = []json.Step{any}}}, level = .Lazy, dups = .First,
		 coverage = .Full, want = {{hit(0, 5, 6, 0, .Number)}}},
		{src = `{"a":1}`, paths = []json.Path{{steps = []json.Step{a}}}, level = .Lazy, dups = .First,
		 coverage = .Partial, stop = 6, want = {{hit(0, 5, 6, 0, .Number)}}},
		{src = `{"a":1,"b":2}`, paths = xa_path, level = .Lazy, dups = .First, coverage = .Partial},
		{src = `{"a":{"b":1}}`, paths = axa_path, level = .Lazy, dups = .First, coverage = .Partial},
		{src = `{"a":{"a":1}}`, paths = axa_path, level = .Lazy, dups = .First, coverage = .Partial},
		{src = `{"x":{"a":1}}`, paths = []json.Path{{steps = xa, limit = 1}}, level = .Lazy, dups = .First,
		 coverage = .Partial, stop = 11, want = {{hit(0, 10, 11, 5, .Number)}}},
		{src = `{"a":01}`, paths = xa_path, level = .Lazy, dups = .First, coverage = .Partial},
		{src = `{"a":1}`, paths = []json.Path{{steps = xa}, {steps = []json.Step{json.Index(0)}}},
		 level = .Lazy, dups = .First, coverage = .Partial, want = {{}, {mismatch(1)}}},
		{src = `1`, paths = []json.Path{{steps = xa}, {steps = []json.Step{json.Index(0)}}},
		 level = .Lazy, dups = .First, coverage = .Partial, stop = 0, want = {{}, {mismatch(1)}}},
		{src = `{"a":1}`, paths = []json.Path{{steps = []json.Step{b}}, {steps = xa}}, level = .Lazy,
		 dups = .First, coverage = .Partial, want = {{miss(0, 0)}, {}}},
		{src = `{"a":1}`, paths = xa_path, level = .Strict, dups = .Last, coverage = .Full},
		{src = `{"a":1}`, paths = xa_path, level = .Structural, dups = .Last, coverage = .Partial},
		{src = `{"a":1}x`, paths = xa_path, level = .Lazy, dups = .First, coverage = .Partial,
		 err = json.Error{offset = 7, kind = .Trailing}},
		{src = `{"a":1`, paths = xa_path, level = .Lazy, dups = .First, coverage = .Partial,
		 err = json.Error{offset = 6, kind = .Truncated}},
		{src = ` `, paths = xa_path, level = .Lazy, dups = .First, coverage = .Partial,
		 err = json.Error{offset = 1, kind = .Truncated}},
	}
	for c, i in cases {
		r := paths_run(raw(c.src), c.paths, c.level, c.dups)
		defer json.destroy(&r.req)
		testing.expectf(t, r.err == source(c.err), "case %d %q: %v, want %v", i, c.src, r.err, c.err)
		testing.expectf(t, r.req.state.coverage == c.coverage, "case %d %q: coverage %v, want %v", i, c.src, r.req.state.coverage, c.coverage)
		testing.expectf(t, r.req.state.stop == c.stop, "case %d %q: stop %v, want %v", i, c.src, r.req.state.stop, c.stop)
		for _, pi in c.paths {
			got, gerr := json.answers(&r.req, pi)
			want: []json.Answer
			if pi < len(c.want) {
				want = c.want[pi]
			}
			testing.expectf(t, gerr == nil, "case %d %q: query %d: %v", i, c.src, pi, gerr)
			testing.expectf(t, slice.equal(got, want), "case %d %q: query %d: %v, want %v", i, c.src, pi, got, want)
		}
	}
}

// An allocator over a fixed pool that counts what it grants and what it gives back.
POOL_BYTES :: 1 << 20

Ledger :: struct {
	pool:    []byte,
	at:      int,
	allocs:  int,
	frees:   int,
	live:    int,
	total:   int,
	biggest: int,
}

ledger_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	l := (^Ledger)(data)
	grant :: proc(l: ^Ledger, size, alignment: int) -> ([]byte, mem.Allocator_Error) {
		at := mem.align_formula(l.at, alignment)
		if size < 0 || at + size > len(l.pool) {
			return nil, .Out_Of_Memory
		}
		mem := l.pool[at:][:size]
		l.at = at + size
		l.allocs += 1
		l.total += size
		l.biggest = max(l.biggest, size)
		return mem, nil
	}
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		mem, err := grant(l, size, alignment)
		if err == nil {
			l.live += 1
		}
		return mem, err
	case .Resize, .Resize_Non_Zeroed:
		mem, err := grant(l, size, alignment)
		if err == nil {
			if old_memory == nil {
				l.live += 1
			} else {
				copy(mem, ([^]u8)(old_memory)[:min(old_size, size)])
			}
		}
		return mem, err
	case .Free:
		l.frees += 1
		l.live -= 1
		return nil, nil
	}
	return nil, nil
}

ledger_allocator :: proc(l: ^Ledger) -> mem.Allocator {
	return mem.Allocator{procedure = ledger_proc, data = l}
}

member_object :: proc(n: int, alloc: mem.Allocator) -> string {
	letters := "abcdefghijklmnopqrstuvwxyz"
	b: strings.Builder
	strings.builder_init(&b, alloc)
	strings.write_byte(&b, '{')
	for i in 0 ..< n {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '"')
		strings.write_byte(&b, letters[i / 26])
		strings.write_byte(&b, letters[i % 26])
		strings.write_string(&b, `":0`)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// A `.Path` scan's wildcard key scratch is the request's: an ambient allocator that refuses every
// allocation leaves the scan untouched, and the request's own allocator sees the keys and gets them back.
@(test)
test_path_wildcard_keys_use_the_request_allocator :: proc(t: ^testing.T) {
	src := member_object(100, context.temp_allocator)
	paths := []json.Path{{steps = []json.Step{json.Any{}}}}
	// The result with no allocator pressure: an object of 100 numbers answers once per member.
	plain := paths_run(raw(src), paths, .Lazy, .First)
	defer json.destroy(&plain.req)
	testing.expectf(t, plain.err == nil && len(plain.answers) == 100, "%v, %d answers", plain.err, len(plain.answers))

	old := context.allocator
	defer context.allocator = old
	amb: Budget
	amb.backing = old
	context.allocator = mem.Allocator{procedure = budget_proc, data = &amb}
	led: Ledger
	led.pool = make([]byte, POOL_BYTES, context.temp_allocator)
	req: json.Request({.Path})
	_ = request_of(&req, paths, {strictness = .Lazy, duplicates = .First}, ledger_allocator(&led))
	err := json.scan(raw(src), &req)
	context.allocator = old
	testing.expectf(t, err == nil, "%v", err)
	testing.expectf(t, slice.equal(req.answers[:], plain.answers), "%v, want %v", req.answers, plain.answers)
	testing.expectf(t, !amb.refused, "the scan allocated on the ambient allocator")
	testing.expectf(t, led.allocs >= 2, "the key set's spill and the answers are the request's, got %d allocations", led.allocs)
	json.destroy(&req)
	testing.expectf(t, led.live == 0, "%d blocks of the request's allocator were not given back", led.live)
}

// Past `MAX_DEPTH` the open frames spill to `context.allocator`, doubling from `MAX_DEPTH` as the input nests
// deeper: a deep document costs about its own depth, not the `max_depth` it was allowed.
@(test)
test_deep_walk_spill_grows_with_the_document :: proc(t: ^testing.T) {
	DEPTH :: 5000
	src := raw(nested_arrays(DEPTH))
	old := context.allocator
	defer context.allocator = old
	led: Ledger
	led.pool = make([]byte, POOL_BYTES, context.temp_allocator)
	context.allocator = ledger_allocator(&led)
	err := json.validate(src, {strictness = .Strict, limits = {max_depth = json.DEPTH_CEILING}})
	context.allocator = old
	testing.expectf(t, err == nil, "%v", err)
	testing.expectf(t, led.live == 0, "%d bytes of frames left behind", led.live)
	// The spill's last growth holds the frames in hand, and doubling past the document's depth is the cost
	// of not knowing that depth up front.
	testing.expectf(t, led.biggest <= 2 * DEPTH * FRAME_BYTES, "%d bytes in one allocation, want <= %d",
		led.biggest, 2 * DEPTH * FRAME_BYTES)
	testing.expectf(t, led.total <= 4 * DEPTH * FRAME_BYTES, "%d bytes allocated in all, want <= %d",
		led.total, 4 * DEPTH * FRAME_BYTES)
	// The failure path survives the growth: a document past `max_depth` is `.Too_Deep`, and the spill is
	// given back.
	led = Ledger{pool = make([]byte, POOL_BYTES, context.temp_allocator)}
	context.allocator = ledger_allocator(&led)
	err = json.validate(src, {strictness = .Strict, limits = {max_depth = 1200}})
	context.allocator = old
	e, faulted := err.?
	testing.expectf(t, faulted && e.kind == .Too_Deep, "a document past max_depth is .Too_Deep, got %v", err)
	testing.expectf(t, led.live == 0, "%d bytes of frames left behind on the failure path", led.live)
}
