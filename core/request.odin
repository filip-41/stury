package core

// What every format's `Request` shares: the inputs, the paths parsed into storage it owns, and the answers its
// `scan` fills, grouped by path on demand. A format embeds `Request` (`using base`) beside its own scan state
// and gives `request_init`, `scan` and `answers` over it. `Route` names the engine a format answers a path with.

import "base:runtime"

// A request's inputs and answers, read and written through the format's procedures.
//
//	- `request_init` sets the inputs and parses each text path into storage the request owns. A caller that
//	  builds its `Path`s may set the fields and assign `paths` directly, and allocates nothing for them.
//	- `allocator` must not change once the request has been scanned.
Request :: struct($Opts: typeid) {
	using read: Opts,
	allocator:  runtime.Allocator,
	// The paths the request answers. An answer's `query` is its path's index here.
	paths:      []Path,
	// Every answer of the last scan, in the order the scan settles them until `answers` groups them by path.
	// Allocated with `allocator` on first use and cleared, not freed, by a rescan. Answers borrow the source,
	// and a rescan invalidates them.
	answers:    [dynamic]Answer,
	parsed:     Parsed_Paths,
	groups:     Answer_Groups,
}

// The storage of the paths `request_init` parsed: each text copied, with room for its escaped names, and its
// steps. `paths` borrows both.
@(private)
Parsed_Paths :: struct {
	paths: [dynamic]Path,
	steps: [dynamic]Step,
	text:  [dynamic]u8,
}

// `answers` grouped by path: `at[i]` is where path `i`'s answers start, and `spare` the buffer they are sorted
// into, swapped with `answers`. A scan clears `grouped`.
@(private)
Answer_Groups :: struct {
	at:      [dynamic]int,
	spare:   [dynamic]Answer,
	grouped: bool,
}

// Set `req`'s inputs, and parse each text path into storage the request owns (a `Path` is kept as it is, its
// steps the caller's). `req` is a format's request.
//
//	- A text that does not parse is `.Bad_Path` at the byte of that text the parser stopped on, and leaves
//	  `req.paths` empty. A refused allocation is `.Out_Of_Memory`.
//	- Calling it again replaces the paths and drops the last scan's answers.
@(require_results)
request_init :: proc(req: ^$R, paths: []Path_Spec, opts: $O, allocator: runtime.Allocator) -> Maybe(Error) {
	req.read = opts
	req.allocator = allocator
	req.paths = nil
	parsed_destroy(&req.parsed)
	clear(&req.answers)
	req.groups.grouped = false

	n_text := 0
	for spec in paths {
		if text, is_text := spec.(string); is_text {
			n_text += len(text)
		}
	}
	oom := Error{kind = .Out_Of_Memory}
	p := &req.parsed
	if make_into(&p.paths, len(paths), allocator) != nil {
		return oom
	}
	// Each text is copied beside room for its escaped names, which its length bounds (`parse_path`), and a step
	// takes at least one byte of text.
	if n_text > 0 && (make_into(&p.text, 2 * n_text, allocator) != nil || make_into(&p.steps, n_text, allocator) != nil) {
		return oom
	}
	text_used, steps_used := 0, 0
	for spec, i in paths {
		switch s in spec {
		case Path:
			p.paths[i] = s
		case string:
			text := p.text[text_used:][:len(s)]
			copy(text, s)
			names := p.text[text_used + len(s):][:len(s)]
			text_used += 2 * len(s)
			path, fault := parse_path(string(text), p.steps[steps_used:], names)
			if f, bad := fault.?; bad {
				return Error{kind = .Bad_Path, offset = f.offset}
			}
			steps_used += len(path.steps)
			p.paths[i] = path
		}
	}
	req.paths = p.paths[:]
	return nil
}

@(private = "file")
make_into :: proc(arr: ^[dynamic]$T, n: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	err: runtime.Allocator_Error
	arr^, err = make([dynamic]T, n, allocator)
	return err
}

// The answers to path `path` of the last scan of `req`, a format's request, in source order.
//
//	- A path naming one value gives one answer when it does not land, with outcome `.Missing` (or
//	  `.Type_Mismatch`).
//	- A `path` outside `req.paths` gives no answers.
//	- The first call after a scan of more than one path groups `req.answers` by path, a stable counting sort.
//	  A one-path request's answers are all `path` 0's.
//	- The grouping allocates with the request's allocator. A refusal is `.Out_Of_Memory`, with no answers and
//	  `req.answers` as the scan left it, and a later call tries again.
@(require_results)
answers :: proc(req: ^$R, path: int) -> (out: []Answer, err: Maybe(Error)) {
	if path < 0 || path >= max(len(req.paths), 1) {
		return nil, nil
	}
	if len(req.paths) <= 1 {
		return req.answers[:], nil
	}
	if !req.groups.grouped && !answers_group(&req.answers, &req.groups, len(req.paths), request_allocator(req)) {
		return nil, Error{kind = .Out_Of_Memory}
	}
	return req.answers[req.groups.at[path]:req.groups.at[path + 1]], nil
}

@(private = "file")
answers_group :: proc(answers: ^[dynamic]Answer, g: ^Answer_Groups, n_paths: int, alloc: runtime.Allocator) -> bool {
	adopt_allocator(&g.at, alloc)
	if resize(&g.at, n_paths + 1) != nil {
		return false
	}
	runtime.mem_zero(raw_data(g.at), size_of(int) * len(g.at))
	// Answers come grouped already when each path answers once, as plain names do: no scatter then.
	sorted := true
	last: u32 = 0
	for a in answers^ {
		g.at[a.query + 1] += 1
		sorted &&= a.query >= last
		last = a.query
	}
	for i in 1 ..= n_paths {
		g.at[i] += g.at[i - 1]
	}
	if !sorted {
		adopt_allocator(&g.spare, alloc)
		if resize(&g.spare, len(answers)) != nil {
			return false
		}
		// `at[q]` is each path's cursor, ending where the next path starts, and shifted back after.
		for a in answers^ {
			g.spare[g.at[a.query]] = a
			g.at[a.query] += 1
		}
		for i := n_paths; i > 0; i -= 1 {
			g.at[i] = g.at[i - 1]
		}
		g.at[0] = 0
		answers^, g.spare = g.spare, answers^
	}
	g.grouped = true
	return true
}

// The first answer of a one-path request's last scan, `MISSING` when it gave none.
request_first :: proc(req: ^$R) -> Answer {
	return req.answers[0] if len(req.answers) > 0 else MISSING
}

// Free what the shared part of `req` holds (the parsed paths, the answers and their grouping) and empty it.
// `paths` stays when the caller assigned it.
request_free :: proc(req: ^$R) {
	if raw_data(req.paths) == raw_data(req.parsed.paths) {
		req.paths = nil
	}
	parsed_destroy(&req.parsed)
	delete(req.answers)
	delete(req.groups.at)
	delete(req.groups.spare)
	req.answers, req.groups = {}, {}
}

@(private = "file")
parsed_destroy :: proc(p: ^Parsed_Paths) {
	delete(p.paths)
	delete(p.steps)
	delete(p.text)
	p^ = {}
}

request_allocator :: proc(req: ^$R) -> runtime.Allocator {
	return req.allocator if req.allocator.procedure != nil else context.allocator
}

// Wire `want` into an array that has no allocator of its own (a never-`make`d `[dynamic]` has the zero
// Allocator). Otherwise agree only if the array already carries that one. Writes to a caller-owned array, so
// only a wiring pass calls it, after the pre-flight has agreed every output's allocator.
adopt_allocator :: #force_inline proc(arr: ^[dynamic]$T, want: runtime.Allocator) -> bool {
	if arr.allocator.procedure == nil {
		arr.allocator = want
		return true
	}
	return arr.allocator == want
}

// Whether an output made with `have` can grow under `want`: one dynamic array has one allocator, so the
// scan cannot move it to another. An output with no allocator yet is compatible with anything. A
// mismatch comes from changing `Request.allocator` after a scan, or from filling its outputs by hand.
allocator_ok :: #force_inline proc(have, want: runtime.Allocator) -> bool {
	return have.procedure == nil || have == want
}

// The engine a format answers one path of a request with: its class, and why, a token the format names from
// its own enum (`json.Path_Route`, CSV's `"Columns"` and `"Unsupported_Path"`).
//
//	.Direct    a scan of the source answers the path
//	.Document  a document built from the source answers it
//	.Fallback  the general engine, or none, for a path the others do not serve
Route :: struct {
	class: Route_Class,
	why:   string,
}

Route_Class :: enum u8 {
	Direct,
	Document,
	Fallback,
}
