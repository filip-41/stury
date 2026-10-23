package json

// The query engine's front door: a `Request` names what to read, and holds the answers `scan` fills (request_scan.odin).

import "base:runtime"
import core_pkg "../core"
import "scan/walk"
import scan_pkg "scan"

// Which occurrence of a key repeated within one object answers a path: core's `Duplicates`. A path through
// `Any` still answers once per match, each holder object resolving its own repeats.
//
//	.Default `.Last`
//	.Last    the last occurrence (no prefix settles it)
//	.First   the first occurrence (with `.Refuse`, the only readings `.Lazy` accepts)
//	.All     every occurrence answers
//	.Refuse  none: a key that, decoded, repeats one of its own object's refuses the document
//	         (`.Duplicate_Key` at the repeat). `.Strict` and `.Structural` check every object, and `.Lazy` reads
//	         as under `.First` and may stop before a repeat. Keys past the first 64 open at once are
//	         remembered in the request's allocator, given back before the scan returns.
Duplicates :: core_pkg.Duplicates

// What to read from a text and where the answers go. `scan` fills it in one pass. `$KINDS` lists the kinds of
// answer wanted, and a kind left out costs nothing.
//
//	.Path   answers: one `Path_Answer` per occurrence of each of `paths`, a range of `src`, in `answers`
//	.Nodes  a document in `doc`, read through the `Document` procedures. Escaped strings and keys decode
//	        on first read
//	.Dom    a document with decoded values: `.Nodes` with every number and escaped string decoded at the
//	        scan
//
//	- `request_init` sets the inputs and parses text paths. A caller that prebuilds its `Path`s may set the
//	  fields and assign `paths` directly, and allocates nothing for them. `destroy` frees what the request
//	  holds.
//	- A field filled for a kind outside `$KINDS` is refused (`.Query_Not_In_Set`), and so is a `.Path` in `$KINDS`
//	  with no `paths`.
//	- A request is limited to `MAX_PATH_QUERIES` (16) paths, `MAX_PATH_STEPS` (32) steps in a path, and 16
//	  identical key names among its paths. Past a limit it may be refused as `.Over_Capacity` before any
//	  byte is read, and `Request_Error.capacity` says which. Some simple paths are answered another way and
//	  are not counted.
//	- `dialect == .Jsonc` reads comments and trailing commas, checked as `.Strict` whatever `strictness`
//	  says, and with `.Nodes` each comment is attached to its value. A JSON request never pays for this.
//	- `allocator` must not change once the request has been scanned.
//
// `strictness` is documented at `Strictness`. `.Lazy` here needs `duplicates` `.First` or `.Refuse`
// (`.Lazy_Needs_First`), and `.Structural` is refused beside `.Nodes` or `.Dom` (`.Nodes_Need_Strict`).
Request :: struct($KINDS: bit_set[Query]) {
	strictness: Strictness,
	dialect:    Dialect,
	duplicates: Duplicates,
	limits:     Limits,
	allocator:  runtime.Allocator,
	// The paths `.Path` answers. An answer's `query` is its path's index here.
	paths:      []Path,

	// The outputs, allocated with `allocator` on first use and cleared, not freed, by a rescan. Answers
	// borrow `src` and, for decoded strings, the document's arena. A rescan invalidates them.
	//
	// Every answer of the last scan, in walk order until `answers` groups them by path. A path through
	// `Any` answers once per match, in document order, the rest in the order the walk settles them.
	answers:    [dynamic]Path_Answer,
	// Filled when `.Nodes` or `.Dom` is in `$KINDS`.
	doc:        Document,
	// How much of the item the last scan's result covers: `.Partial` (a stop, a fault, a skipped region)
	// means "valid over what was visited", which `validate_remaining` upgrades. `stop` is where a `.Lazy`
	// walk stopped.
	coverage:   Validity,
	stop:       Maybe(u64),

	// The request's own: the last scan's source and result (for `validate_remaining`), the router's plan
	// (route.odin, kept so routing allocates nothing in steady state), the paths `request_init` parsed,
	// and `answers`' grouping.
	src:        []byte,
	verdict:    Maybe(Error),
	route:      Route,
	parsed:     Parsed_Paths,
	groups:     Answer_Groups,
}

// A scan's result: `nil` means valid over what the scan visited (`Request.coverage`). An `Error` is the
// document's fault, or `.Out_Of_Memory` when the scan ran but an output could not grow (a document fault
// comes first). A `Request_Error` is a refusal, and nothing was scanned.
Scan_Error :: union {
	Error,
	Request_Error,
}

// The storage of the paths `request_init` parsed: each text copied, with room for its escaped names, and
// its steps. `paths` borrows both.
@(private)
Parsed_Paths :: struct {
	paths: [dynamic]Path,
	steps: [dynamic]Step,
	text:  [dynamic]u8,
}

// `answers` grouped by path: `at[i]` is where path `i`'s answers start, and `spare` the buffer they are
// sorted into, swapped with `answers`.
@(private)
Answer_Groups :: struct {
	at:      [dynamic]int,
	spare:   [dynamic]Path_Answer,
	grouped: bool,
}

// Set `req`'s inputs, and parse each text path into storage the request owns (a `Path` is kept as it is, its
// steps the caller's).
//
//	- A text that does not parse is `.Bad_Path`, naming it and the byte it stopped on, and leaves
//	  `req.paths` empty. A refused allocation is `.Out_Of_Memory`.
//	- Calling it again replaces the paths, drops the last scan's answers, and the request may be rescanned.
@(require_results)
request_init :: proc(
	req: ^Request($KINDS),
	paths: ..Path_Spec,
	strictness := Strictness.Strict,
	dialect := Dialect.Json,
	duplicates := Duplicates.Last,
	limits := Limits{},
	allocator := context.allocator,
) -> Maybe(Request_Error) {
	req.strictness = strictness
	req.dialect = dialect
	req.duplicates = duplicates
	req.limits = limits
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
	oom := Request_Error{kind = .Out_Of_Memory, query_kind = .Path}
	p := &req.parsed
	if make_into(&p.paths, len(paths), allocator) != nil {
		return oom
	}
	// Each text is copied beside room for its escaped names, which its length bounds (`parse_path`), and a
	// step takes at least one byte of text.
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
				return Request_Error{kind = .Bad_Path, query_kind = .Path, path = i, offset = f.offset}
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

// The answers to path `path` of the last scan, in document order.
//
//	- A path with no match still gives one answer, with outcome `.Missing` (or `.Type_Mismatch`).
//	- A `path` outside `req.paths` gives no answers.
//	- The first call after a scan of more than one path groups `req.answers` by path, a stable counting
//	  sort. A one-path request's answers are all `path` 0's.
//	- The grouping allocates with the request's allocator. A refusal is `.Out_Of_Memory`, with no answers
//	  and `req.answers` as the scan left it, and a later call tries again.
@(require_results)
answers :: proc(req: ^Request($KINDS), path: int) -> (out: []Path_Answer, err: Maybe(Error)) {
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
answers_group :: proc(answers: ^[dynamic]Path_Answer, g: ^Answer_Groups, n_paths: int, alloc: runtime.Allocator) -> bool {
	walk.adopt_allocator(&g.at, alloc)
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
		walk.adopt_allocator(&g.spare, alloc)
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

// The first answer to one path in `src`: one scan, and no `Request` to keep. A `.Found` answer's `lo` and
// `hi` bound the value in `src`; otherwise it is `.Missing` or `.Type_Mismatch` (`Path_Answer`).
//
//	- `path` is text in the jq subset or a built `Path`. Its `limit` becomes 1, so `.logs[].id` answers the
//	  first id. `per_element` is kept, so the first element decides, as jq's `first(.[].x)` may be null.
//	- The result is `scan`'s: nil, the text's fault, or a refusal. On a non-nil result the answer is
//	  `.Missing` and bounds nothing.
//	- The request's storage comes from `allocator` and is freed before return. For several paths, every
//	  answer, or many sources, keep a `Request` (`request_init`, `scan`, `answers`, `prepare`).
//	- `strictness = .Lazy` with `duplicates = .First` lets the walk stop once the answer is final.
@(require_results)
find :: proc(
	src: []byte,
	path: Path_Spec,
	strictness := Strictness.Strict,
	dialect := Dialect.Json,
	duplicates := Duplicates.Last,
	limits := Limits{},
	allocator := context.allocator,
) -> (a: Path_Answer, err: Scan_Error) {
	a = Path_Answer{outcome = .Missing, owner = walk.NO_OWNER, node = NO_NODE}
	req: Request({.Path})
	defer destroy(&req)
	if refused, bad := request_init(&req, path, strictness = strictness, dialect = dialect, duplicates = duplicates, limits = limits, allocator = allocator).?; bad {
		return a, refused
	}
	req.paths[0].limit = 1
	if err = scan(src, &req); err != nil {
		return a, err
	}
	// One path: `answers` groups nothing and cannot fail.
	out, _ := answers(&req, 0)
	if len(out) > 0 {
		a = out[0]
	}
	return a, nil
}

// The whole-document result over the bytes the last scan read. `nil` is the only claim "this document is
// valid".
//
//	- A no-op when that scan covered them (`coverage == .Full`, no stop), else a `.Strict` re-walk under the
//	  request's limits.
//	- A refused scan covered nothing.
//	- The result is committed to the request: `coverage` becomes `.Full`, `stop` nil, so a second call is
//	  the no-op.
//	- Under `Duplicates.Refuse` the re-walk refuses a repeated key too. A refused spill of its keys is
//	  `.Out_Of_Memory` at offset 0.
@(require_results)
validate_remaining :: proc(req: ^Request($KINDS)) -> Maybe(Error) {
	// The key check keeps its spilled keys in `context.allocator`, as `scan` does, given back
	// on return.
	prev := context.allocator
	context.allocator = request_allocator(req)
	defer context.allocator = prev
	err, validity := scan_pkg.validate_remaining(req.src, req.verdict, req.coverage, req.stop, req.limits, REFUSE_DUPLICATES && req.duplicates == .Refuse)
	req.verdict, req.coverage, req.stop = err, validity, nil
	return err
}

// Free everything the request holds, the document and the parsed paths included, and empty it. The inputs
// stay set, and `paths` too when the caller assigned them.
@(private)
request_destroy :: proc(req: ^Request($KINDS)) {
	if raw_data(req.paths) == raw_data(req.parsed.paths) {
		req.paths = nil
	}
	parsed_destroy(&req.parsed)
	delete(req.answers)
	destroy(&req.doc)
	route_destroy(&req.route)
	delete(req.groups.at)
	delete(req.groups.spare)
	req.answers = {}
	req.route = {}
	req.groups = {}
	req.src, req.verdict, req.coverage, req.stop = nil, nil, .Partial, nil
}

@(private = "file")
parsed_destroy :: proc(p: ^Parsed_Paths) {
	delete(p.paths)
	delete(p.steps)
	delete(p.text)
	p^ = {}
}

@(private)
request_allocator :: proc(req: ^Request($KINDS)) -> runtime.Allocator {
	return req.allocator if req.allocator.procedure != nil else context.allocator
}
