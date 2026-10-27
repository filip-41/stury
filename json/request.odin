package json

// The query engine's front door: a `Request` names what to read, and holds the answers `scan` fills (request_scan.odin).

import core_pkg "../core"
import "scan/walk"

// Duplicates selects which occurrence of a key repeated within one object answers a path (core's
// `Duplicates`). A path through `Any` still answers once per match, and each object resolves its own repeats.
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
//	.Path   answers: one `Answer` per occurrence of each of `paths`, a range of `src`, in `answers`
//	.Nodes  a document in `doc`, read through the `Document` procedures. Escaped strings and keys decode
//	        on first read
//	.Dom    a document with decoded values: `.Nodes` with every number and escaped string decoded at the
//	        scan
//
//	- `request_init`, `answers` and the fields shared with every format are core's `Request`. `destroy` frees
//	  what the request holds.
//	- `paths` filled without `.Path` in `$KINDS` is refused (`.Bad_Option`), and so is a `.Path` in `$KINDS`
//	  with no `paths`.
//	- A request is limited to `MAX_PATH_QUERIES` (16) paths, `MAX_PATH_STEPS` (32) steps in a path, and 16
//	  identical key names among its paths. Past a limit it may be refused as `.Over_Capacity` before any
//	  byte is read. Some simple paths are answered another way and are not counted.
//	- `dialect == .Jsonc` reads comments and trailing commas, checked as `.Strict` whatever `strictness`
//	  says, and with `.Nodes` each comment is attached to its value. A JSON request never pays for this.
//	- `dialect == .Json5` reads JSON5 as `.Jsonc` reads JSONC. A string or key row spelled outside JSON
//	  (single-quoted, unquoted or escaped) is decoded by JSON5's escapes, and a number row spelled outside
//	  JSON (hex, `.5`, `5.`, `+1`, `Infinity`, `NaN`) by JSON5's numbers.
//
// `strictness` is documented at `Strictness`. `.Lazy` here needs `duplicates` `.First` or `.Refuse`, and
// `.Structural` is refused beside `.Nodes` or `.Dom`, both as `.Bad_Option`.
Request :: struct($KINDS: bit_set[Query]) {
	// A path through `Any` answers once per match, in document order, the rest in the order the walk settles
	// them. Decoded strings borrow the document's arena.
	using base: core_pkg.Request(Read_Opts),
	// Filled when `.Nodes` or `.Dom` is in `$KINDS`, allocated with `allocator` on first use and cleared, not
	// freed, by a rescan.
	doc:        Document,
	// How much of the item the last scan's result covers: `.Partial` (a stop, a fault, a skipped region)
	// means "valid over what was visited", which `validate_remaining` upgrades. `stop` is where a `.Lazy`
	// walk stopped.
	coverage:   Validity,
	stop:       Maybe(u64),

	// The request's own, which the scans keep between calls.
	state:      Request_State,
}

// The last scan's source and result (for `validate_remaining`), the router's plan (route.odin, kept so routing
// allocates nothing in steady state), and what `prepare` planned.
@(private)
Request_State :: struct {
	src:     []byte,
	verdict: Maybe(Error),
	route:   Route,
	// Whether the plan on `route` is `prepare`'s, for every source whose root is an object. Cleared by a
	// request `prepare` refuses, or one it cannot plan for every source: those scan unplanned every time.
	planned: bool,
	// The walk's resolution of the plan's queries, kept by the first planned scan for the rest.
	kept:    walk.Resolved_Queries,
}

// Set `req`'s inputs, and parse each text path into storage the request owns (core's `request_init`). A
// planned request is planned no more.
@(require_results)
request_init :: proc(req: ^Request($KINDS), paths: ..Path_Spec, opts := Read_Opts{}, allocator := context.allocator) -> Maybe(Error) {
	req.state.planned = false
	return core_pkg.request_init(req, paths, opts, allocator)
}

answers :: core_pkg.answers

// The first answer to one path in `src`: one scan, and no `Request` to keep. A `.Found` answer's `lo` and
// `hi` bound the value in `src`; otherwise it is `.Missing` or `.Type_Mismatch` (`Answer`).
//
//	- `path` is text in the jq subset or a built `Path`. Its `limit` becomes 1, so `.logs[].id` answers the
//	  first id. `per_element` is kept, so the first element decides, as jq's `first(.[].x)` may be null.
//	- The result is `request_init`'s or `scan`'s: nil, the text's fault, or a refusal. On a non-nil result the
//	  answer is `.Missing` and bounds nothing.
//	- The request's storage comes from `allocator` and is freed before return. For several paths, every
//	  answer, or many sources, keep a `Request` (`request_init`, `scan`, `answers`, `prepare`).
//	- `strictness = .Lazy` with `duplicates = .First` lets the walk stop once the answer is final.
@(require_results)
find :: proc(
	src: []byte,
	path: Path_Spec,
	opts := Read_Opts{},
	allocator := context.allocator,
) -> (a: Answer, err: Maybe(Error)) {
	a = core_pkg.MISSING
	req: Request({.Path})
	defer destroy(&req)
	request_init(&req, path, opts = opts, allocator = allocator) or_return
	req.paths[0].limit = 1
	scan(src, &req) or_return
	return core_pkg.request_first(&req), nil
}

// Free everything the request holds (the document, the parsed paths and what `prepare` planned) and empty
// it. The inputs stay set, and `paths` too when the caller assigned them.
@(private)
request_destroy :: proc(req: ^Request($KINDS)) {
	core_pkg.request_free(req)
	destroy(&req.doc)
	route_destroy(&req.state.route)
	req.state = {}
	req.coverage, req.stop = .Partial, nil
}
