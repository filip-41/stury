package json

// The query engine's front door: a `Request` names what to read, and holds the answers `scan` fills (request_scan.odin).

import "core:bytes"
import core_pkg "../core"
import scan_pkg "scan"
import "scan/walk"

// Duplicates selects which occurrence of a key repeated within one object answers a path (core's
// `Duplicates`). A path through `Any` still answers once per match, and each object resolves its own repeats.
//
//	.Default `.Last`
//	.Last    the last occurrence (no prefix settles it)
//	.First   the first occurrence (with `.Refuse`, the only readings a `.Lazy` scan may stop early under)
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
//	- `request_init`, `answers` and the `answers` field are core's `Request`; the inputs are set only by
//	  `request_init`. `destroy` frees what the request holds.
//	- Paths given without `.Path` in `$KINDS` are refused (`.Bad_Option`), and so is a `.Path` in `$KINDS`
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
// `strictness` is documented at `Strictness`. `.Lazy` under `duplicates` `.Last` or `.All` reads as `.Strict`, as
// no answer is final before the walk ends, and `.Structural` is refused beside `.Nodes` or `.Dom` as `.Bad_Option`.
Request :: struct($KINDS: bit_set[Query]) {
	// A path through `Any` answers once per match, in document order, the rest in the order the walk settles
	// them. Decoded strings borrow the document's arena.
	using base: core_pkg.Request(Read_Opts),
	// Filled when `.Nodes` or `.Dom` is in `$KINDS`, allocated with `allocator` on first use and cleared, not
	// freed, by a rescan.
	doc:        Document,
	// The request's own, which the scans keep between calls.
	state:      Request_State,
}

// The last scan's source, result and reach, the router's plan (route.odin, kept so routing allocates nothing in
// steady state), and the plan a rescan reuses.
@(private)
Request_State :: struct {
	src:        []byte,
	verdict:    Maybe(Error),
	// How much of the source the last scan's result covers: `.Partial` (a stop, a fault, a skipped region) is
	// "valid over what was visited". `stop` is where a `.Lazy` walk stopped.
	coverage:   scan_pkg.Validity,
	stop:       Maybe(u64),
	route:      Route,
	// Whether the plan on `route` is `plan_request`'s, for every source whose root is an object. A request
	// rescanned under the inputs `request_init` set is planned at its second scan (`plan_tried`), once.
	planned:    bool,
	scanned:    bool,
	plan_tried: bool,
	// The walk's resolution of the plan's queries, kept by the first planned scan for the rest.
	kept:       walk.Resolved_Queries,
}

// Set `req`'s inputs, and parse each text path into storage the request owns (core's `request_init`). The inputs
// are set only here: a request rescanned under them plans its routing once, at its second scan, and the scans
// after skip the setup that does not depend on the source.
@(require_results)
request_init :: proc(req: ^Request($KINDS), paths: ..Path_Spec, opts := Read_Opts{}, allocator := context.allocator) -> Maybe(Path_Error) {
	req.state.planned, req.state.scanned, req.state.plan_tried = false, false, false
	return core_pkg.request_init(req, paths, opts, allocator)
}

answers :: core_pkg.answers

// The first answer to one path in `src`: one scan, and no `Request` to keep. A `.Found` answer's `lo` and
// `hi` bound the value in `src`; otherwise it is `.Missing` or `.Type_Mismatch` (`Answer`).
//
//	- `path` is text in the jq subset or a built `Path`. Its `limit` becomes 1, so `.logs[].id` answers the
//	  first id. `per_element` is kept, so the first element decides, as jq's `first(.[].x)` may be null.
//	- The result is `request_init`'s or `scan`'s: nil, the path's fault, the text's (`.Bad_Source`), or a
//	  refusal. On a non-nil result the answer is `.Missing` and bounds nothing.
//	- The request's storage comes from `allocator` and is freed before return. For several paths, every
//	  answer, or many sources, keep a `Request` (`request_init`, `scan`, `answers`).
//	- `strictness = .Lazy` with `duplicates = .First` lets the walk stop once the answer is final; under the
//	  default `.Last` it reads as `.Strict`.
@(require_results)
find :: proc(
	src: []byte,
	path: Path_Spec,
	opts := Read_Opts{},
	allocator := context.allocator,
) -> (a: Answer, err: Maybe(Path_Error)) {
	req: Request({.Path})
	defer destroy(&req)
	return core_pkg.find(src, path, opts, allocator, &req, scan)
}

// The text of answer `a`, a scalar a path read from `src` in `opts.dialect`: a string decoded by the dialect's
// escapes, any other scalar as written. A slice of `src` has `escaped` false; a string with an escape is decoded
// into `allocator`, `escaped` true, which the caller frees. `ok` is false for an answer that is not a found
// scalar (a container, a miss), a string that does not decode (`decode_span`), or a decode `allocator` refuses.
// CSV's `answer_text` has the same shape.
@(require_results)
answer_text :: proc(src: []byte, a: Answer, opts := Read_Opts{}, allocator := context.allocator) -> (text: string, escaped: bool, ok: bool) {
	if a.outcome != .Found || a.kind == .Array || a.kind == .Object || a.lo > a.hi || a.hi > u64(len(src)) {
		return
	}
	if a.kind != .String {
		return string(src[a.lo:a.hi]), false, true
	}
	if .Json5_Scalars not_in scan_pkg.grammar_of(opts.dialect) {
		d: Decoded
		d, escaped, ok = decode_span(src, a.lo, a.hi, .String, allocator)
		return d.(string) or_else "", escaped, ok
	}
	// A JSON5 string, single- or double-quoted, as its walk accepted it.
	if a.hi - a.lo < 2 {
		return
	}
	inner := src[a.lo + 1:a.hi - 1]
	if bytes.index_byte(inner, '\\') < 0 {
		return string(inner), false, true
	}
	buf, aerr := make([]byte, len(inner), allocator)
	if aerr != nil {
		return
	}
	n := scan_pkg.json5_unescape_into(buf, src, a.lo, a.hi, 0)
	return string(buf[:n]), true, true
}

// Free everything the request holds (the document, the parsed paths and the plan) and empty
// it. The read options stay set; the paths go.
@(private)
request_destroy :: proc(req: ^Request($KINDS)) {
	core_pkg.request_free(req)
	destroy(&req.doc)
	route_destroy(&req.state.route)
	req.state = {}
}
