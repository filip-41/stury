package json_tests

// Shared happy-path scan fixtures.

import json "../.."
import "core:mem"
import "core:strings"
import "core:testing"

@(private)
raw :: proc(src: string) -> []byte {
	return transmute([]byte)src
}

// `n` arrays nested, `inner` at the middle, on the temp allocator.
@(private)
nested_arrays :: proc(n: int, inner := "") -> string {
	return strings.concatenate({strings.repeat("[", n, context.temp_allocator), inner, strings.repeat("]", n, context.temp_allocator)}, context.temp_allocator)
}

// The result `validate` gives at `strictness` under `limits`, by way of a scan with nothing to ask.
@(private)
verdict_under :: proc(src: []byte, strictness: json.Strictness, limits: json.Limits) -> Maybe(json.Error) {
	req: json.Request({})
	req.strictness = strictness
	req.limits = limits
	return scan_fault(json.scan(src, &req))
}

// The document's fault in a scan's result, or nil (a refusal is not one).
@(private)
scan_fault :: proc(err: Maybe(json.Error)) -> Maybe(json.Error) {
	e, faulted := err.?
	if !faulted {
		return nil
	}
	#partial switch e.kind {
	case .Bad_Option, .Over_Capacity, .Bad_Path:
		return nil
	}
	return e
}

// One scan of `.Path` queries with every part of the outcome captured. `json.destroy(&r.req)` releases it.
@(private)
Path_Run :: struct {
	req:     json.Request({.Path}),
	err:     Maybe(json.Error),
	answers: []json.Path_Answer, // borrowed from `req`
}

@(private)
paths_run :: proc(
	src: []byte,
	paths: []json.Path,
	strictness := json.Strictness.Strict,
	duplicates := json.Duplicates.Last,
	limits := json.Limits{},
) -> (r: Path_Run) {
	r.req.strictness = strictness
	r.req.duplicates = duplicates
	r.req.limits = limits
	r.req.paths = paths
	r.err = json.scan(src, &r.req)
	r.answers = r.req.answers[:]
	return
}

// The text of `query`'s answers in `src`, joined with `,`.
@(private)
answer_texts :: proc(answers: []json.Path_Answer, src: string, query: u32 = 0) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for a in answers {
		if a.query != query {
			continue
		}
		if strings.builder_len(b) > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, src[a.lo:a.hi])
	}
	return strings.to_string(b)
}

// Expect `err` to be a refusal of kind `want`, and answer it.
@(private)
request_refused :: proc(t: ^testing.T, err: Maybe(json.Error), want: json.Error_Kind, loc := #caller_location) -> json.Error {
	r, refused := err.?
	testing.expectf(t, refused && r.kind == want, "%v, want %v", err, want, loc = loc)
	return r
}

// `build` of `text`, which must be valid. The caller destroys the document.
@(private)
build_ok :: proc(t: ^testing.T, text: string, loc := #caller_location) -> json.Document {
	doc, err := json.build(raw(text))
	e, has := err.?
	testing.expectf(t, !has, "%q must build, got %v", text, e, loc = loc)
	return doc
}

// An allocator that grants `left` allocations from `backing` and refuses every one after.
Budget :: struct {
	backing: mem.Allocator,
	left:    int,
	refused: bool,
}

budget_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	b := (^Budget)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if b.left == 0 {
			b.refused = true
			return nil, .Out_Of_Memory
		}
		b.left -= 1
	}
	return b.backing.procedure(b.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(private)
budget_allocator :: proc(b: ^Budget) -> mem.Allocator {
	return {budget_proc, b}
}

// The refusal sweep: `for b, k in next_budget(&sweep)` runs the body with the k-th allocation and every later
// one refused (`b.refused` tells whether this pass hit it), k counting up until a pass refuses nothing.
// `expect_swept` fails a sweep that hit its limit first.
@(private)
Budget_Sweep :: struct {
	budget: Budget,
	k:      int,
	limit:  int,
}

@(private)
next_budget :: proc(s: ^Budget_Sweep) -> (b: ^Budget, k: int, more: bool) {
	if s.k > 0 && !s.budget.refused || s.k == s.limit {
		return nil, 0, false
	}
	s.budget = {backing = context.allocator, left = s.k}
	s.k += 1
	return &s.budget, s.k - 1, true
}

@(private)
expect_swept :: proc(t: ^testing.T, s: ^Budget_Sweep, loc := #caller_location) {
	testing.expect(t, !s.budget.refused, "the sweep never completed", loc = loc)
}
