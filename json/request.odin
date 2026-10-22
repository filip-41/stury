package json

// The query engine's front door: a `Request` names what to read, `scan` fills it with the answers.

import "base:runtime"
import core_pkg "../core"
import scan_pkg "scan"

// Which occurrence of a key repeated within one object answers a path. A path through
// `Any` still answers once per match, each holder object resolving its own repeats.
//
//	.Last    the last occurrence (no prefix settles it)
//	.First   the first occurrence (with `.Refuse`, the only readings `.Lazy` accepts)
//	.All     every occurrence answers
//	.Refuse  none: a key that, decoded, repeats one of its own object's refuses the document
//	         (`.Duplicate_Key` at the repeat). `.Strict` and `.Structural` check every object, and `.Lazy` reads
//	         as under `.First` and may stop before a repeat. Keys past the first 64 open at once are
//	         remembered in the request's allocator, given back before the scan returns.
Duplicates :: enum {
	Last,
	First,
	All,
	Refuse,
}

// What to read from a text and where the answers go. `scan` fills it in one pass. `$Q` lists the kinds of
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
//	- A field filled for a kind outside `$Q` is refused (`.Query_Not_In_Set`), and so is a `.Path` in `$Q`
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
Request :: struct($Q: bit_set[Query]) {
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
	// Filled when `.Nodes` or `.Dom` is in `$Q`.
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

// The most queries one scan hands the walk: every walk kind once but `.Unique`, which answers none, plus
// the repeatable `.Path`.
@(private = "file")
MAX_WALK_QUERIES :: len(scan_pkg.Walk_Kind) - 1 + core_pkg.MAX_PATH_QUERIES

// Set `req`'s inputs, and parse each text path into storage the request owns (a `Path` is kept as it is, its
// steps the caller's).
//
//	- A text that does not parse is `.Bad_Path`, naming it and the byte it stopped on, and leaves
//	  `req.paths` empty. A refused allocation is `.Out_Of_Memory`.
//	- Calling it again replaces the paths, drops the last scan's answers, and the request may be rescanned.
request_init :: proc(
	req: ^Request($Q),
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

// Scan `src` for what the request asks and fill its outputs. The request is a `^Request` or a `^Prepared`
// from `prepare` (the same scan, without repeating the setup that does not depend on the source).
//
//	- Returns nil when the text is valid over what the scan visited (`Request.coverage`).
//	- An `Error` is the text's fault, or `.Out_Of_Memory` when an output could not grow.
//	- A `Request_Error` means the request was refused before any byte was read, and the outputs are untouched.
scan :: proc {
	scan_plain,
	scan_prepared,
}

@(private)
scan_plain :: #force_inline proc(src: []byte, req: ^Request($Q)) -> Scan_Error {
	return scan_request(src, req, planned = false)
}

// `planned`: the request holds its plan for `src` already (`scan_prepared`), so the checks and the routing are
// skipped. One body for both, so a program's scans share one copy of the walks.
@(private = "file")
scan_request :: #force_no_inline proc(src: []byte, req: ^Request($Q), planned: bool) -> Scan_Error {
	alloc := request_allocator(req)
	// `Q` as walk kinds, the same names. `.Dom` decodes the `.Nodes` rows. Written out kind by kind: a
	// conversion between two enums' bit_sets is no constant.
	W :: bit_set[scan_pkg.Walk_Kind]
	NONE :: W{}
	WALK ::
		(W{.Path} when .Path in Q else NONE) |
		(W{.Nodes} when .Nodes in Q || .Dom in Q else NONE) |
		(W{.Dom} when .Dom in Q else NONE)
	if !planned {
		if err, refused := request_fault(src, req, alloc).?; refused {
			return err
		}
		// `.Refuse` and JSONC walks serve every path through the automaton (`automaton_only`), so no matcher
		// is planned.
		if tape_routable(req) && scan_tape(src, req, alloc) {
			return nil
		}
		if err, refused := route_paths(&req.route, src, req.paths, req.duplicates, alloc, automaton_only(req)).?; refused {
			return err
		}
	}
	req.src, req.verdict, req.coverage, req.stop = src, nil, .Partial, nil
	req.groups.grouped = false
	req.route.unresolved = false
	err := scan_error(req.verdict, scan_routed(src, req, WALK, alloc))
	if req.route.unresolved && !req.route.every_member && (req.duplicates == .First || req.duplicates == .Last) {
		// A text another follows was read whole and answered (`.Trailing`), so its answers are settled too.
		if e, faulted := err.(Error); err == nil || faulted && e.kind == .Trailing {
			if settled := settle_wild(src, req, alloc); settled != nil {
				return settled
			}
		}
	}
	return err
}

// A request planned once for the scans of many sources, such as the records of a stream. `prepare` makes
// one.
//
//	- `scan(src, &p)` answers as `scan(src, p.req)` does, result, refusal and outputs alike, without
//	  repeating the setup that does not depend on the source.
//	- It borrows the request, whose outputs each scan fills, so one is used on one thread at a time. Each
//	  worker of a pool prepares a request of its own.
//	- The request's inputs must not change while it is in use (prepare again after), and `destroy(&req)`
//	  frees what both hold.
Prepared :: struct($Q: bit_set[Query]) {
	req:     ^Request(Q),
	// Whether the plan on the request is the prepared one. A request `prepare` refuses, or one it cannot
	// plan for every source, scans as `scan(src, req)` does every time.
	planned: bool,
	// The walk's resolution of the plan's queries, kept by the first planned scan for the rest.
	kept:    core_pkg.Resolved_Queries,
}

// Prepare `req` for many scans.
//
//	- A refusal is one `scan` gives every source, found before any is read. A refusal of the paths' routing
//	  comes from each scan, as from `scan`. Either way the `Prepared` is usable: its scans refuse as `scan`
//	  does.
//	- Allocates only what `scan` would, the storage for more than `MAX_PATH_QUERIES` names, with the
//	  request's allocator.
prepare :: proc(req: ^Request($Q)) -> (p: Prepared(Q), err: Maybe(Request_Error)) {
	p.req = req
	if err = request_fault(nil, req, request_allocator(req)); err == nil {
		p.planned = prepared_plan(req)
	}
	return
}

// Plan `req` over every source whose root is an object (`PLAN_SRC`), the plan any other one's `scan`
// re-plans. False for a request with no such plan: one the tape route may answer, or one routing refuses
// (each scan then routes as `scan` does, and gives the refusal).
@(private = "file")
prepared_plan :: proc(req: ^Request($Q)) -> bool {
	plan_src := transmute([]byte)string(PLAN_SRC)
	// Inlined here, so `scan_request` stays their one call and inlines them too.
	return !#force_inline tape_routable(req) &&
		#force_inline route_paths(&req.route, plan_src, req.paths, req.duplicates, request_allocator(req), automaton_only(req)) == nil
}

@(private)
scan_prepared :: proc(src: []byte, p: ^Prepared($Q)) -> Scan_Error {
	req := p.req
	// `request_fault`'s one check of the source.
	fits := true
	when .Nodes in Q || .Dom in Q {
		fits = u64(len(src)) <= MAX_ROW_SOURCE
	}
	if p.planned && fits && route_rebase(&req.route, src) {
		req.route.kept = &p.kept
		defer req.route.kept = nil
		return scan_request(src, req, planned = true)
	}
	err := scan_request(src, req, planned = false)
	if p.planned {
		// A plan made again holds its keys anew.
		p.planned, p.kept.ok = prepared_plan(req), false
	}
	return err
}

// The automaton is the one engine a JSONC walk and a `.Refuse` walk carry.
@(private = "file")
automaton_only :: #force_inline proc(req: ^Request($Q)) -> bool {
	return req.dialect == .Jsonc || req.duplicates == .Refuse
}

// The public result of a walk that returned `fault` beside `verdict`.
@(private)
scan_error :: proc(verdict: Maybe(Error), fault: scan_pkg.Walk_Fault) -> Scan_Error {
	if fault.capacity != .None {
		return Request_Error{kind = .Over_Capacity, query_kind = .Path, capacity = fault.capacity}
	}
	if e, bad := verdict.?; bad {
		return e
	}
	if fault.oom {
		return Error{kind = .Out_Of_Memory}
	}
	return nil
}

// The answers to path `path` of the last scan, in document order.
//
//	- A path with no match still gives one answer, with outcome `.Missing` (or `.Type_Mismatch`).
//	- A `path` outside `req.paths` gives no answers.
//	- The first call after a scan of more than one path groups `req.answers` by path, a stable counting
//	  sort. A one-path request's answers are all `path` 0's.
//	- The grouping allocates with the request's allocator. A refusal is `.Out_Of_Memory`, with no answers
//	  and `req.answers` as the scan left it, and a later call tries again.
answers :: proc(req: ^Request($Q), path: int) -> (out: []Path_Answer, err: Maybe(Error)) {
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
	core_pkg.adopt_allocator(&g.at, alloc)
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
		core_pkg.adopt_allocator(&g.spare, alloc)
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

// The walk the router's plan and `duplicates` pick for `$WALK`.
@(private = "file")
scan_routed :: #force_inline proc(src: []byte, req: ^Request($Q), $WALK: bit_set[scan_pkg.Walk_Kind], alloc: runtime.Allocator) -> scan_pkg.Walk_Fault {
	when .Path in WALK {
		// Which engines run is the plan's, decided per call. Each combination is its own walk.
		if req.route.matcher != .None {
			if req.route.n_auto > 0 {
				return scan_walk(src, req, WALK + {.Demand}, alloc)
			}
			return scan_walk(src, req, (WALK - {.Path}) + {.Demand}, alloc)
		}
	}
	// Built without its walks, `.Refuse` was refused before the scan (`request_fault`).
	when REFUSE_DUPLICATES {
		if req.duplicates == .Refuse {
			return scan_refuse(src, req, WALK, alloc)
		}
	}
	return scan_walk(src, req, WALK, alloc)
}

// Whether `Duplicates.Refuse` is compiled in. A build define (`-define:REFUSE_DUPLICATES=false`), not a name of
// the contract: its walks are a copy of each scan walk with the key check, dead weight in a program that
// never refuses (the CLI, as jq keeps the last of a repeated key). Built without, `scan` refuses a `.Refuse` request
// as `.Refuse_Compiled_Out` and `build` as `.Bad_Option`, before any byte is read. `unmarshal` keeps it.
@(private)
REFUSE_DUPLICATES :: #config(REFUSE_DUPLICATES, true)

// The walk of a `Duplicates.Refuse` scan. Out of line so `scan`'s other walks keep inlining. `.Refuse`
// requests are the rare case.
@(private = "file")
scan_refuse :: #force_no_inline proc(src: []byte, req: ^Request($Q), $WALK: bit_set[scan_pkg.Walk_Kind], alloc: runtime.Allocator) -> scan_pkg.Walk_Fault {
	// The walk keeps its spilled keys in `context.allocator`, given back on return.
	prev := context.allocator
	context.allocator = alloc
	defer context.allocator = prev
	return scan_walk(src, req, WALK + {.Unique}, alloc)
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
validate_remaining :: proc(req: ^Request($Q)) -> Maybe(Error) {
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
request_destroy :: proc(req: ^Request($Q)) {
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

@(private = "file")
duplicates_resolution :: proc(d: Duplicates) -> scan_pkg.Resolution {
	switch d {
	case .Last:  return .Last
	case .First: return .First
	case .All:   return .All
	// Every repeat refuses, so the first occurrence is the answer whenever there is one.
	case .Refuse: return .First
	}
	return .Last
}

@(private = "file")
request_allocator :: proc(req: ^Request($Q)) -> runtime.Allocator {
	return req.allocator if req.allocator.procedure != nil else context.allocator
}

// Everything the walk cannot serve about `req` over `src`, found before anything is touched: the
// pre-flight. Each limit of `Capacity` is checked here, or in `route_paths` where the router's shapes
// decide it, so no refusal follows a write. The walk's own checks (`resolve_queries`) only restate these.
@(private = "file")
request_fault :: proc(src: []byte, req: ^Request($Q), alloc: runtime.Allocator) -> Maybe(Request_Error) {
	when !REFUSE_DUPLICATES {
		if req.duplicates == .Refuse {
			return Request_Error{kind = .Refuse_Compiled_Out}
		}
	}
	if req.strictness == .Lazy && req.duplicates != .First && req.duplicates != .Refuse {
		return Request_Error{kind = .Lazy_Needs_First}
	}
	when .Nodes in Q || .Dom in Q {
		if req.strictness == .Structural {
			return Request_Error{kind = .Nodes_Need_Strict, query_kind = .Dom if .Dom in Q else .Nodes}
		}
	}
	// `paths` and `.Path` in `$Q` come together.
	when .Path in Q {
		if len(req.paths) == 0 {
			return Request_Error{kind = .Query_Not_In_Set, query_kind = .Path}
		}
	} else {
		if len(req.paths) > 0 {
			return Request_Error{kind = .Query_Not_In_Set, query_kind = .Path}
		}
	}
	// A row's `u32` spans cannot address more: refused, not truncated.
	when .Nodes in Q || .Dom in Q {
		if u64(len(src)) > MAX_ROW_SOURCE {
			return Request_Error{kind = .Over_Capacity, query_kind = .Dom if .Dom in Q else .Nodes, capacity = .Node_Source_Bytes}
		}
	}
	return outputs_fault(req, len(req.paths) > 0, alloc)
}

// The first output the request owns that was made with another allocator than the request's, or none.
// `paths_used` says the walk will write `answers`. A fresh output has no allocator and agrees with any.
@(private = "file")
outputs_fault :: #force_inline proc(req: ^Request($Q), paths_used: bool, alloc: runtime.Allocator) -> Maybe(Request_Error) {
	mismatch :: proc(k: Query) -> Request_Error {
		return Request_Error{kind = .Allocator_Mismatch, query_kind = k}
	}
	if paths_used && !core_pkg.allocator_ok(req.answers.allocator, alloc) {
		return mismatch(.Path)
	}
	// The plan's spill arrays are bound together, so one speaks for all.
	if !core_pkg.allocator_ok(req.route.spill.keys.allocator, alloc) {
		return mismatch(.Path)
	}
	when .Nodes in Q || .Dom in Q {
		if !core_pkg.allocator_ok(req.doc.rows.allocator, alloc) {
			return mismatch(.Dom if .Dom in Q else .Nodes)
		}
	}
	// Decoded strings live in the document's arena.
	when .Dom in Q {
		if !core_pkg.allocator_ok(req.doc.values.allocator, alloc) || !core_pkg.allocator_ok(req.doc.arena.blocks.allocator, alloc) {
			return mismatch(.Dom)
		}
	}
	return nil
}

// Fill `sink` with `req`'s storage for the arrays of `$K`: array headers copied in, so `sink_store` must
// follow the walk. The rest of the sink is left unset, and the walk never reads it. An out-parameter: a
// sink returned by value is zeroed whole.
@(private = "file")
sink_of :: #force_inline proc(req: ^Request($Q), sink: ^core_pkg.Scan_Query_Sink, $K: bit_set[scan_pkg.Walk_Kind]) {
	when .Path in K {
		sink.paths = req.answers
		sink.paths_retracted = 0
		sink.paths_unresolved = 0
	}
	when .Nodes in K { sink.nodes = req.doc.rows }
	when .Dom in K { sink.value_bytes = req.doc.values }
}

@(private = "file")
sink_store :: #force_inline proc(req: ^Request($Q), sink: core_pkg.Scan_Query_Sink, $K: bit_set[scan_pkg.Walk_Kind]) {
	when .Path in K { req.answers = sink.paths }
	when .Nodes in K { req.doc.rows = sink.nodes }
	when .Dom in K {
		// `req` still holds the header the scan started from.
		values := sink.value_bytes
		core_pkg.value_bytes_trim(&values, cap(req.doc.values))
		req.doc.values = values
	}
}

// Empty the arrays of `$K` for a rescan, keeping capacity and the allocator each is bound to. The arenas
// restart from their first block.
@(private = "file")
output_reset :: #force_inline proc(req: ^Request($Q), $K: bit_set[scan_pkg.Walk_Kind]) {
	when .Path in K { clear(&req.answers) }
	when .Nodes in K {
		doc := &req.doc
		clear(&doc.rows)
		clear(&doc.keys)
		clear(&doc.strings)
		clear(&doc.members)
		clear(&doc.member_at)
		clear(&doc.facts)
		core_pkg.name_arena_reset(&doc.arena)
	}
	when .Dom in K { clear(&req.doc.values) }
}

// The walk of `src` that builds `req.doc.rows`, with the route's plan cleared (the caller restores it if the
// request keeps it): the tape and wildcard routes answer from the rows.
@(private)
scan_rows :: proc(src: []byte, req: ^Request($Q), alloc: runtime.Allocator) -> scan_pkg.Walk_Fault {
	req.route.matcher, req.route.n_auto, req.route.gate.gated = .None, 0, 0
	// Sized to the document's usual density, before the scan seeds it larger (`seed_row_cap`).
	core_pkg.adopt_allocator(&req.doc.rows, alloc)
	_ = core_pkg.edge_reserve(&req.doc.rows, len(src) / core_pkg.SEEDED_ROW_BYTES)
	return scan_walk(src, req, {.Nodes}, alloc)
}

// The walk over `req` specialized for `$WALK`. It returns the walk's own fault and leaves the result on
// `req`.
@(private)
scan_walk :: proc(src: []byte, req: ^Request($Q), $WALK: bit_set[scan_pkg.Walk_Kind], alloc: runtime.Allocator) -> (fault: scan_pkg.Walk_Fault) {
	plan := &req.route
	// The router gates only a demand-only walk. A gate is a walk of its own, so no other walk compiles one.
	when .Demand in WALK && .Path not_in WALK && .Gate not_in WALK {
		if plan.gate.gated != 0 {
			return #force_no_inline scan_walk(src, req, WALK + {.Gate}, alloc)
		}
	}
	// The arrays the walk touches: a path or demand writes `answers`.
	K :: WALK | {.Path} when .Demand in WALK else WALK
	output_reset(req, K)
	// The matcher writes its rows, and the slots' answers, into `answers`. `outputs_fault` agreed its
	// allocator.
	if plan.matcher != .None {
		core_pkg.adopt_allocator(&req.answers, alloc)
	}

	sink: core_pkg.Scan_Query_Sink = ---
	sink_of(req, &sink, K)
	queries: [MAX_WALK_QUERIES]scan_pkg.Scan_Query = ---
	nq := 0
	// Each automaton path answers under its own index in `req.paths`.
	for pi in plan.auto[:plan.n_auto] {
		queries[nq] = scan_pkg.Scan_Query{kind = .Path, allocator = alloc, sink = &sink, path = req.paths[pi], tag = pi}
		nq += 1
	}
	when .Nodes in WALK {
		queries[nq] = scan_pkg.Scan_Query{kind = .Nodes, allocator = alloc, sink = &sink}
		nq += 1
		when .Dom in WALK {
			queries[nq] = scan_pkg.Scan_Query{kind = .Dom, allocator = alloc, sink = &sink}
			nq += 1
		}
	}
	when .Demand in WALK {
		store := route_store(plan, plan.n_keys)
		spec := core_pkg.Demand_Spec{keys = store.keys, depth = plan.depth}
		when .Gate in WALK {
			spec.gate = &plan.gate
		}
		if plan.matcher == .Slots {
			spec.out = store.fields
		} else {
			spec.rows = &sink.paths
			spec.row_keys = store.row_keys
		}
		queries[nq] = scan_pkg.Scan_Query{kind = .Demand, allocator = alloc, sink = &sink, demand = spec}
		nq += 1
	}

	// `.Lazy` stops only where the first occurrence is final: `scan_queries` reads that off the resolution.
	facts: ^[dynamic]Fact
	when .Nodes in WALK {
		if req.dialect == .Jsonc {
			core_pkg.adopt_allocator(&req.doc.facts, alloc)
			facts = &req.doc.facts
		}
	}
	// An empty path's answer is the whole root, which settles only with the walk: `.Lazy` would only skip
	// bytes of an answer it hands out, so it reads as `.Strict`.
	strictness := req.strictness
	when .Path in Q {
		if strictness == .Lazy {
			for p in req.paths {
				if len(p.steps) == 0 {
					strictness = .Strict
				}
			}
		}
	}
	err: Maybe(Error)
	if req.limits.max_depth > MAX_DEPTH {
		err, fault = scan_pkg.scan_queries_deep(
			src, queries[:nq], strictness, req.limits, WALK, &req.coverage, duplicates_resolution(req.duplicates), req.dialect, facts,
		)
	} else if req.dialect == .Jsonc {
		err, fault = scan_pkg.scan_queries_jsonc(
			src, queries[:nq], req.limits, WALK, &req.coverage, duplicates_resolution(req.duplicates), facts,
		)
	} else {
		err, fault = scan_pkg.scan_queries(
			src, queries[:nq], strictness, req.limits, WALK,
			&req.stop, &req.coverage, duplicates_resolution(req.duplicates), plan.kept,
		)
	}
	req.verdict = err
	when .Path in K {
		req.route.unresolved = sink.paths_unresolved > 0
	}
	sink_store(req, sink, K)
	req.doc.src = src
	req.doc.dialect = req.dialect
	req.doc.deep = req.limits.max_depth > MAX_DEPTH
	if facts != nil {
		attached := err == nil && scan_pkg.jsonc_attach(req.doc.rows[:], src, facts[:])
		if err == nil && !attached {
			fault.oom = true
		}
		if !attached {
			// Unattached, they would read as nothing's.
			clear(facts)
		}
	}

	if plan.matcher == .Slots {
		// The automaton owes a miss only to a walk that reached the end.
		reached_end := req.stop == nil
		if e, faulted := err.?; faulted && e.kind != .Trailing {
			reached_end = false
		}
		fault.oom ||= !route_slots(&req.answers, plan, reached_end)
	} else if plan.matcher == .Names {
		fault.oom ||= !route_missing(&req.answers, plan, req.stop, err)
	}
	// `.Last` repeats retract rows the sweep drops: a gate's, or a wildcard path's.
	retracted := false
	when .Gate in WALK {
		retracted = plan.gate.retracted
	}
	when .Path in WALK {
		retracted = sink.paths_retracted > 0
	}
	if plan.any_limit || .Nodes in WALK || retracted {
		finish_answers(&req.answers, req.doc.rows[:], plan, req.paths, .Nodes in WALK)
	}
	return fault
}
