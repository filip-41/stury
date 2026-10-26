package json

// The JSON codec's public surface. The scanner is in the scan/ package; the aliases below spell the surface
// `json.*`. The public names live in these files:
//
//	json.odin           the shared types (aliases of scan/, scan/walk/ and core/ names), `validate`, `parse_path`,
//	                    `decode_span`, `error_position` and `render_error`
//	request.odin        `Request`, `request_init`, `answers`, `find`, `validate_remaining`, `Duplicates`
//	request_scan.odin   `scan` and `prepare`
//	document.odin       `Document`, `Node`, `NO_NODE`, `ROOT`, the `get_*` readers, `kind`, `facts`, `fact_text`
//	document_build.odin `build` and `destroy`
//	document_walk.odin  `child`, `child_count`, `children`, `members`, `Members`, `pointer`
//	document_query.odin `query`
//	unmarshal.odin      `unmarshal`, `unmarshal_check`, `Unmarshal_Opts`, `Unknown_Fields`, `Unmarshal_Error`
//	marshal.odin        `marshal` and its writer and append forms (marshal_struct.odin writes structs)
//	type_plan.odin      `Type_Plan` and its options and hooks, for `marshal` and `unmarshal`, `plan_cache_clear`
//	route_of.odin       `route_of`, `Path_Route`: which engine answers a path, or why the automaton does
//	edit.odin           `set`, `insert`, `remove` and `splice` (the geometry is in edit_ops.odin and
//	                    edit_jsonc.odin)
//	records.odin        `records`, `next_record`, `Framing`, `Record`
//	record_read.odin    `Record_Read`, `record_read_init`, `record_read_at` and `unmarshal` of one record
//	record_split.odin   `split_record`
//	each_record.odin    `each_record`, `validate_records` and `Batch_Runner`, for threads from `stury:host`
//	encode.odin         `Marshal_Opts` and `marshal_document`
//	format.odin         `format`
//
// The other files (request_walk.odin, route*.odin) are internal.

import scan_pkg "scan"
import core_pkg "../core"
import "scan/walk"

// How much of each value a read checks, and whether a scan may stop early.
//
//	.Strict      everything RFC 8259 requires: brackets and commas, string escapes and UTF-8, number
//	             grammar (`01` and `1e` are refused), literal spelling (`truX`), control characters in
//	             strings, truncated values, and the number limits of `Limits`. The default.
//	.Structural  only the shape of the text: brackets, commas, colons, string keys, where each string ends,
//	             the nesting limit and UTF-8. The inside of a scalar is not checked: `tru`, `01`, `\q` and a
//	             raw control character in a string pass, and the number limits do not apply (`1e5000`).
//	.Lazy        checks each value it reads as `.Strict` does, and a scan may stop once every answer is
//	             final (a `Request` needs `duplicates == .First` or `.Refuse` for it). A value no query
//	             reads may be skipped without checking, so `.Lazy` may accept or refuse an unread
//	             malformed value.
//
// Every level checks the shape, nesting limit and UTF-8 of the values it visits; `.Lazy` may skip
// unread values, so their bytes are unchecked. Only `.Strict` can build a `Document`.
Strictness :: scan_pkg.Strictness

// Caps a scan enforces:
//
//	- `max_depth` (default 1024, `MAX_DEPTH`, ceiling `DEPTH_CEILING`) is `.Too_Deep` past it.
//	- `max_scalar_digits` (default 256 mantissa digits) is `.Limit_Digits`.
//	- `max_scalar_scale` (default 4096, an exponent's or scale's magnitude) is `.Limit_Scale`.
//	- A cap asked past what a scan can carry is clamped to that.
//
// A `max_depth` past MAX_DEPTH is the deep reading:
//
//	- `validate`, `build` and `scan` keep their nesting state in `context.allocator` memory (24 bytes a
//	  level, freed before return) once the input nests past MAX_DEPTH, and a refused allocation is
//	  `.Out_Of_Memory`.
//	- It keeps the strictness of the values it reads: `.Strict` and `.Lazy` check each value they
//	  read, `.Lazy` with no early stop past MAX_DEPTH, and `.Structural` checks the shape of every
//	  byte and no scalar's body.
//	- `unmarshal` holds the cap to MAX_DEPTH, and `marshal` of a document read deeper than MAX_DEPTH is
//	  `.Too_Deep`.
Limits :: scan_pkg.Limits

// How a read takes its source: one struct for `validate`, `find`, `build`, `request_init` and `split_record`,
// embedded in `Request` and `Unmarshal_Opts`. The zero value is strict RFC 8259 JSON with no raised caps, the last
// of a repeated key answering. A procedure that does not read a field says so.
Read_Opts :: struct {
	dialect:    Dialect,
	strictness: Strictness,
	duplicates: Duplicates,
	limits:     Limits,
}

// The default nesting cap. A scan refuses deeper input unless `Limits.max_depth` raises it, and the
// writer refuses to open a container past it.
MAX_DEPTH :: scan_pkg.MAX_DEPTH

// The largest `max_depth` a scan takes, 1 << 20: a larger one is clamped to it. Its frames are 24 MiB.
DEPTH_CEILING :: scan_pkg.DEPTH_CEILING

// The longest source whose values a `Document`'s rows can address (4 GiB - 2): `build`, `.Nodes` and `.Dom` refuse a
// longer one before reading it. `validate` has no such cap.
MAX_ROW_SOURCE :: scan_pkg.TAPE_MAX_SOURCE

// A fault in the document, or in what `build` could not hold of it. A syntax fault carries the offset of
// the first byte that cannot extend the construct (`len(src)` when the input ended). A limit fault the
// first byte of the construct that exceeded the cap. A value, owning nothing.
Error :: scan_pkg.Error

// What an `Error` is.
//
//	- A syntax fault: `Truncated`, `Bad_Char`, `Bad_Escape`, `Bad_Literal`, `Bad_Number`, `Trailing`.
//	- A cap: `Limit_Digits`, `Limit_Scale`, `Too_Deep`.
//	- A repeated key under `Duplicates.Refuse`: `Duplicate_Key`.
//	- A refusal no byte is at: `Source_Too_Wide`, `Out_Of_Memory`, `Bad_Option`, `Over_Capacity`.
//	- `Bad_Path`: a path text `request_init` could not parse, at the byte of that text the parser stopped on.
//	- `Field_Count`, `Limit_Fields` and `Limit_Record` are CSV record errors; JSON never reports them. The
//	  enum is core's, so code over several formats reads one `Error` and one `Unmarshal_Error`.
Error_Kind :: core_pkg.Error_Kind

// The 1-based line and column `err` points at in `src`. Columns count bytes. It is (0, 0) when `err` points
// at no byte of `src`: an offset past `src`, a `.Source_Too_Wide` (a limit), an `.Out_Of_Memory`, a `.Bad_Option`,
// an `.Over_Capacity` or a `.Bad_Path`.
@(require_results)
error_position :: proc(src: []byte, err: Error) -> (line, col: int) {
	return core_pkg.error_position(src, err)
}

// `err` as `line:col: <kind>`, the kind written as its enum name, or `offset N: <kind>` where it has no
// position (`error_position`), or the bare kind where it has no offset either.
//
//	- The text is allocated with `allocator`.
//	- For a fault of a `Records`, pass the input the iterator was made from.
//
// The other refusals read the same way, with `src` the text the fault's offset is into:
//
//	- An `Unmarshal_Error` as `line:col: <kind>` (`: <syntax>` after a `.Syntax`), then ` at .a[3]."b c"` for
//	  its path (`[]` for a map value or element of any index, a leading `…` when `truncated`).
//	- A `Path_Error` as `line:col: <kind>` for `.Bad_Source`, `offset N: <kind>` for `.Bad_Path`, `.Bad_Result`
//	  and `.Out_Of_Memory`, with the `syntax` or `encode` result after it.
@(require_results)
render_error :: proc(src: []byte, err: $E, allocator := context.allocator) -> string {
	return core_pkg.render_error(src, err, allocator)
}

// How much of the item a result covers. `.Full` means the scan read the whole item and skipped
// nothing, `.Partial` is a stop, a fault, or a value skipped without results (never how many bytes). `validate_remaining` is
// the only thing that upgrades it.
Validity :: scan_pkg.Validity

// A path built by hand. `steps` from a value, and `limit`, the most `.Found` answers it gives (0 is every
// one, `first(P)` is 1). It borrows `steps`, which the caller keeps alive while the path is used (an empty
// `steps` is the value itself).
Path :: core_pkg.Path

// One step of a `Path` (`Name`, `Index` or `Any`).
Step :: core_pkg.Step

// An object's member, compared by its decoded key.
Name :: core_pkg.Name

// An array's element: 0-based from the start when non-negative, 1-based from the end when negative.
Index :: core_pkg.Index

// Every member of an object, or element of an array.
Any :: core_pkg.Any

// The most steps a text path names wherever the library parses one (`query`, `request_init`, the edits),
// and the most steps a path may have in a `Request`.
MAX_PATH_STEPS :: core_pkg.MAX_PATH_STEPS

// Parse `text` that is a path in the jq path subset: `.a.b`, `.[0]`, `.[-1]`, `.[]`,
// `."quoted"`, `first(P)`, `limit(N; P)`.
//
//	- It allocates nothing. The path borrows `steps`, `text`, and `names`, into which a quoted name's
//	  escapes decode (`len(text)` bytes always suffice, a lone surrogate is `.Bad_Escape`).
//	- A fault is the zero `Path` and a `Path_Error`: `.Bad_Path` at the byte of `text` the parser stopped on, or
//	  `.Over_Capacity` when `steps` or `names` is too small.
@(require_results)
parse_path :: #force_inline proc(text: string, steps: []Step, names: []u8 = nil) -> (p: Path, err: Maybe(Path_Error)) {
	return core_pkg.parse_path(text, steps, names)
}

// A path as `query`, `request_init` and the edits take it.
Path_Spec :: core_pkg.Path_Spec

// A path query's answer, one per occurrence.
//
//	query    the path's index in `Request.paths`
//	outcome  the `Path_Outcome`
//	kind     the value's kind
//	lo, hi   the value's span in the scanned source
//	owner    the offset of the container the answer is about: the one holding the value, or the one lacking a
//	         `.Missing` member (offset 0 for the root container). `NO_OWNER` when there is none: the root
//	         value, or a miss of the document as a whole (`find` on a refused scan)
//	node     the value in `Request.doc` under `.Nodes` (`NO_NODE` otherwise)
Path_Answer :: walk.Path_Answer

// `Path_Answer.owner` of an answer no container holds.
NO_OWNER :: walk.NO_OWNER

// Whether a path landed. Gives `.Found`, `.Missing` (no such member or element), or `.Type_Mismatch` (a step met
// a value of another kind, such as a name on an array).
Path_Outcome :: walk.Path_Outcome

// The kinds of answer a `Request` is specialized over (`Request` says what each fills):
//
//	.Path   answers, in `Request.answers` (`answers` reads one path's)
//	.Nodes  a document, in `Request.doc`
//	.Dom    a document with decoded values
Query :: scan_pkg.Query

// What a JSON value is: `Null`, `False`, `True`, `Number`, `String`, `Array` or `Object`.
Kind :: scan_pkg.Kind

// How a number's binary64 value relates to the authored one: `Exact` (bit for bit), `Inexact` (correctly
// rounded), `Underflowed` (nonzero, read as +-0), or `None` (no binary64 value, such as `1e400`, the value
// is 0). `Exact` is the zero value.
Exactness :: core_pkg.Exactness

// A number as binary64 (`value`) and its `exactness`. This is the f64 view: `Digits` keeps the authored text.
// `marshal` writes `value`, and refuses `.None` with `.Non_Finite` (use `Digits` or `Raw` to carry `1e400`
// through). The zero value is the exact 0, so an unset `Number` marshals as `0`.
Number :: scan_pkg.Number

// The authored text of one JSON value. `unmarshal` fills it with a value's span of the source (borrowed),
// and `marshal` copies it after checking it is exactly one strict value (`.Bad_Raw` otherwise); an empty
// `Raw` marshals as `null`.
Raw :: scan_pkg.Raw

// The grammar a source is read in.
Dialect :: scan_pkg.Dialect

// Something attached to a value of a document (`facts`): its span in the source, the value, and where
// it sits relative to the value. A JSONC document's comments are its facts.
Fact :: scan_pkg.Fact

// Where a fact sits relative to its value: `.Lead` on the lines before the entry, `.Inline` between a
// member's key and value, `.Trail` after the entry on its line, `.Foot` inside a container after its last
// entry's line. A document's leading comments lead the root and its trailing ones trail it.
Fact_Place :: scan_pkg.Fact_Place

// The `null` value: `Decoded`'s arm for it, and an `unmarshal` target that takes only `null`.
Null :: scan_pkg.Null

// One decoded scalar: `Null`, `bool`, `i64` (an integer token that fits and is not `-0`), `u64` (an integer
// past `max(i64)`), `Number` (any other number with a binary64 value), `Digits` (a finished number with none)
// or `string`. `1` and `1.0` land in different arms as the authored text is the value's identity.
Decoded :: scan_pkg.Decoded

// The authored text of a finished number no `i64`, `u64` or binary64 holds, as a slice of `src`. `marshal`
// writes it as that number (an empty one as `null`), and as an `unmarshal` target it takes any number's text.
Digits :: scan_pkg.Digits

// Decode one scalar from its span `[lo, hi)` of `src`, `kind` being the kind a scan read off its first byte
// (a `Path_Answer`'s `kind`, `lo` and `hi`).
//
//	- An escape-free string is a slice of `src` with `escaped` false. An escaped string is decoded into
//	  `allocator`, `escaped` true, and the caller frees it.
//	- `ok` is false, and nothing is kept, for a span that is not one token of `kind`: a container kind, a
//	  span past `src`, a literal not written exactly, a string that is not one quoted token or has a
//	  malformed or truncated escape, a raw control byte or bytes that are not UTF-8, a number that is not a
//	  finished one, a span holding a BOM.
//	- `ok` is false too for an escaped string `allocator` refuses.
//	- A lone surrogate escape (a high half no low half follows, or a low half alone) is a malformed escape.
@(require_results)
decode_span :: #force_inline proc(
	src: []byte,
	lo, hi: u64,
	kind: Kind,
	allocator := context.allocator,
) -> (d: Decoded, escaped: bool, ok: bool) {
	return scan_pkg.decode_span(src, lo, hi, kind, allocator)
}

// Validate `src` and answer only whether it is well-formed: one pass, no document, and always a whole-item
// result.
//
//	- No allocation but the deep reading's frames (`Limits`), which only input nesting past MAX_DEPTH under
//	  a raised cap takes.
//	- `opts.duplicates` is not read: a repeated key is not a fault here.
//	- `.Jsonc` validates comments and trailing commas as well, every other byte as `.Strict` does whatever
//	  `strictness` is, and appends each comment to `facts` when it is not nil, attached to nothing (`node`
//	  is `NO_NODE`), an append its allocator refuses being `.Out_Of_Memory`; a `.Json` source has none.
//	- A fault carries its kind and an absolute offset into `src`.
//	- One leading UTF-8 BOM is tolerated at offset 0 and nowhere else, so no caller-visible offset is
//	  shifted.
//	- A lone surrogate escape (`"\uD800"` with no low half right after it, or a low half such as `"\uDC00"`
//	  alone) is `.Bad_Escape` at its backslash wherever escapes are validated: it writes no Unicode scalar,
//	  so no reader could return it as UTF-8.
@(require_results)
validate :: #force_inline proc(src: []byte, opts := Read_Opts{}, facts: ^[dynamic]Fact = nil) -> Maybe(Error) {
	if opts.dialect != .Json {
		return scan_pkg.validate_dialect(src, opts.dialect, facts, opts.limits)
	}
	if opts.limits.max_depth > MAX_DEPTH {
		return scan_pkg.scan_plain_deep(src, opts.strictness, opts.limits)
	}
	return scan_pkg.scan_plain(src, opts.strictness, opts.limits)
}
